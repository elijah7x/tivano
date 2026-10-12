import Foundation

struct CheckError: Error { let message: String }
@MainActor final class Recorder {
    var ends: [TurnStatus] = []; var texts:[String]=[]; var deltas=0; var approvals=0; var questions=0; var resolved=0; var todos:[TodoStep]=[]; var limits:[Date?]=[]; var tools:[ToolUpdate]=[]; var titles:[String]=[]; var spends=0; var sessions:[String]=[]; var exits=0
    func consume(_ event: ProviderEvent, session: OmpSession, approval: String?) {
        switch event {
        case .turnCompleted(let status,_): ends.append(status)
        case .messageCompleted(_,let text): texts.append(text)
        case .messageDelta: deltas += 1
        case .approval(let request): approvals += 1; if let approval { session.resolveApproval(request.id,optionID:approval) }
        case .question: questions += 1
        case .requestResolved: resolved += 1
        case .todos(let value): todos=value
        case .usageLimit(let reset): limits.append(reset)
        case .toolUpdated(_,let update): tools.append(update)
        case .title(let title): titles.append(title)
        case .tokenSpend(let spend): if spend.agentID == nil { spends += spend.totalTokens }
        case .sessionReady(let id): sessions.append(id)
        case .exited: exits += 1
        default: break
        }
    }
}
@main struct Harness {
    @MainActor static func wait(_ condition: ()->Bool, seconds:Double=3) async throws {
        let start=Date.now
        while !condition() { if Date.now.timeIntervalSince(start)>seconds { throw CheckError(message:"deadline") }; try await Task.sleep(for:.milliseconds(5)) }
    }
    static func require(_ condition: Bool,_ reason:String) throws { if !condition { throw CheckError(message:reason) } }
    @MainActor static func config(_ name:String, extra:[String:String]=[:],mode:RuntimeMode = .supervised) -> SessionConfiguration {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["T08_STORAGE"]!).appendingPathComponent(name)
        try! FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var env=["PATH":ProcessInfo.processInfo.environment["PATH"]!,"HOME":root.path,"T08_CASE_ROOT":root.path]
        env.merge(extra){_,n in n}
        return SessionConfiguration(provider:.omp,executable:URL(fileURLWithPath:CommandLine.arguments[1]),workingDirectory:root,environment:env,resumeID:nil,resumeAt:nil,model:nil,effort:nil,runtimeMode:mode,interactionMode:.build,apiKey:nil,hydra:nil)
    }
    static func input(_ text:String,model:String?=nil,effort:String?=nil,mode:RuntimeMode = .supervised)->TurnInput { TurnInput(text:text,images:[],model:model,effort:effort,runtimeMode:mode,interactionMode:.build) }
    @MainActor static func check(_ name:String) async throws -> [String:Any] {
        let start=Date.now
        let mode:RuntimeMode = name == "unsupported" ? .auto : .supervised
        var extra:[String:String]=[:]
        if name == "missing-gate" || name == "bad-state" || name == "waiting-state" { extra["T08_START"]=name }
        if name == "grant" { extra["T08_APPROVAL"]="always" }
        if name == "branch-deny" { extra["T08_BRANCH"]="deny" }
        let session=OmpSession(configuration:config(name,extra:extra,mode:mode)); let r=Recorder()
        let decision:String? = name == "approval-deny" ? "deny" : name == "grant" ? "always" : name == "approval" ? "allow" : nil
        session.onEvent={ [weak session] e in if let session { r.consume(e,session:session,approval:decision) } }
        defer { session.stop() }
        if name == "waiting-state" {
            let task=Task { try await session.start() }
            try await Task.sleep(for:.milliseconds(80));session.stop()
            do { _=try await task.value;throw CheckError(message:"stop while waiting unexpectedly started") } catch is CheckError { throw CheckError(message:"stop while waiting unexpectedly started") } catch {}
            try require(Date.now.timeIntervalSince(start)<1,"stop waited for request timeout")
        } else if ["missing-gate","bad-state","unsupported"].contains(name) {
            do { _=try await session.start();throw CheckError(message:"invalid startup succeeded") } catch is CheckError { throw CheckError(message:"invalid startup succeeded") } catch {}
            try require(!session.isRunning,"invalid startup left running session")
        } else {
            _=try await session.start()
            if name == "branch" || name == "branch-deny" {
                if name == "branch-deny" {
                    var rejected=false
                    do { _=try await session.rollback(removing:["remove target"]) } catch { rejected=true }
                    try require(rejected,"rejected branch succeeded")
                } else {
                    let id=try await session.rollback(removing:["remove target"])
                    try require(id.hasSuffix("session-fork.jsonl"),"wrong fork point")
                }
            } else {
                if name == "model" || name == "effort" {
                    do { try await session.send(input("ok",model:name == "model" ? "fixture/new" : nil,effort:name == "effort" ? "high" : nil)); throw CheckError(message:"rejected selection succeeded") }
                    catch is CheckError { throw CheckError(message:"rejected selection succeeded") } catch {}
                    try require(r.ends.isEmpty,"selection error emitted phantom turn")
                }
                if name == "rename" {
                    let rename=Task { await session.requestTitle() }
                    try await wait { !r.titles.isEmpty }
                    try await session.send(input("ok"));try await wait { !r.ends.isEmpty };rename.cancel()
                } else {
                    let prompt=["approval-deny","grant"].contains(name) ? "approval" : ["model","effort"].contains(name) || name.hasPrefix("cycle-") ? "ok" : name
                    try await session.send(input(prompt))
                    if name == "abort" { await session.interrupt() }
                    try await wait { !r.ends.isEmpty }
                }
                try require(r.ends.count==1,"duplicate turn completion")
                let expected:TurnStatus = name == "abort" ? .interrupted : ["exit","usage"].contains(name) ? .failed : .completed
                try require(r.ends[0]==expected,"wrong turn status")
                if name == "wrong-id" || name == "retry" { try require(Date.now.timeIntervalSince(start)>0.04 && r.texts.last=="ok","premature completion") }
                if name == "large" { let want=(0..<20000).map{String($0)+":中文🙂e\u{301}\n"}.joined();try require(r.texts.last==want,"large Unicode truncated") }
                if name == "flood" { try require(r.deltas==1000 && r.texts.last==String(repeating:"中文🙂",count:1000),"flood lost events") }
                if name == "todo" { try require(r.todos.map(\.status)==[.active,.pending,.done],"todo state mismatch") }
                if name == "tool" { try require(r.tools.count==1 && r.tools[0].edits?.count==1 && r.tools[0].edits?[0].diff?.contains("+new")==true,"missing file diff") }
                if name == "cancel" { try require(r.questions==1 && r.resolved==1,"cancel left request unresolved") }
                if name == "usage" { try require(r.limits.count==1 && (r.limits[0]?.timeIntervalSinceNow ?? 0)>1700,"usage reset missing") }
                if name == "grant" { try require(r.approvals==1 && r.tools.count==2,"session grant did not cover next command") }
                if name == "approval-deny" { try require(r.approvals==1 && r.tools.first?.status == .declined,"decline not reflected") }
                if ["direct-decline","wrapped-decline","wrapped-decline-stack","quoted-decline","successful-decline-text"].contains(name) {
                    let status:ToolCall.Status = name == "quoted-decline" ? .failed : name == "successful-decline-text" ? .completed : .declined
                    try require(r.tools.count==1 && r.tools[0].status==status,"refusal boundary status mismatch: \(r.tools)")
                    var output = name == "quoted-decline" ? "Execution failed while quoting Error: Declined: in a log." : name == "successful-decline-text" ? "Error: Declined: the user declined this command." : AppText.localized("Declined: the user declined this command.")
                    if name == "wrapped-decline-stack" { output += "\n    at fixture\nCommand exited with code 1" }
                    try require(r.tools[0].output==output,"refusal display mismatch: \(r.tools)")
                }
            }
        }
        session.stop();try await Task.sleep(for:.milliseconds(15))
        return ["name":name,"passed":true,"seconds":Date.now.timeIntervalSince(start),"turns":r.ends.count,"deltas":r.deltas,"approvals":r.approvals]
    }
    @MainActor static func main() async {
        var results:[[String:Any]]=[]
        let names=["missing-gate","bad-state","unsupported","waiting-state","ok","wrong-id","retry","large","flood","tool","todo","cancel","usage","approval","approval-deny","grant","abort","exit","model","effort","branch","branch-deny","rename","direct-decline","wrapped-decline","wrapped-decline-stack","quoted-decline","successful-decline-text"]
        for name in names {
            do { results.append(try await check(name)) } catch { results.append(["name":name,"passed":false,"error":String(describing:error)]) }
        }
        await withTaskGroup(of:[String:Any].self) { group in
            for worker in 0..<4 { group.addTask { var count=0;do { for i in 0..<(Int(CommandLine.arguments.last ?? "10") ?? 10) { _=try await check("cycle-\(worker)-\(i)");count += 1 };return ["name":"cycles-\(worker)","passed":true,"cycles":count] } catch { return ["name":"cycles-\(worker)","passed":false,"cycles":count,"error":String(describing:error)] } } }
            for await row in group { results.append(row) }
        }
        let dir=StoragePaths.directory("omp")
        let leftovers=(try? FileManager.default.subpathsOfDirectory(atPath:dir.path))?.filter{ $0.hasSuffix(".json") || $0.hasSuffix(".yml") } ?? []
        results.append(["name":"launch-file-cleanup","passed":leftovers.isEmpty,"leftovers":leftovers])
        let summary:[String:Any]=["passed":results.allSatisfy{$0["passed"] as? Bool == true},"results":results]
        let data=try! JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
        try! data.write(to:URL(fileURLWithPath:ProcessInfo.processInfo.environment["T08_STORAGE"]!).appendingPathComponent("summary.json"))
    }
}
