import Foundation
@main struct RealHarness {
    @MainActor static func wait(_ condition:()->Bool, seconds:Double=10) async throws { let start=Date.now;while !condition(){if Date.now.timeIntervalSince(start)>seconds{throw CheckError(message:"deadline")};try await Task.sleep(for:.milliseconds(10))} }
    static func require(_ ok:Bool,_ why:String)throws{if !ok{throw CheckError(message:why)}}
    @MainActor static func config(_ name:String,mode:RuntimeMode,plan:Bool=false,resume:String?=nil,hydra:Bool=false)->SessionConfiguration {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["T08_STORAGE"]!).appendingPathComponent("live")
        let directory=root.appendingPathComponent("project");let home=root.appendingPathComponent("home")
        let env=["PATH":ProcessInfo.processInfo.environment["PATH"]!,"HOME":home.path,"TMPDIR":root.appendingPathComponent("tmp").path,"NO_PROXY":"127.0.0.1,localhost"]
        return SessionConfiguration(provider:.omp,executable:URL(fileURLWithPath:CommandLine.arguments[1]),workingDirectory:directory,environment:env,resumeID:resume,resumeAt:nil,model:"tivano-offline/offline",effort:nil,runtimeMode:mode,interactionMode:plan ? .plan : .build,apiKey:nil,hydra:hydra ? HydraLaunch() : nil)
    }
    static func prompt(_ id:String,tool:String="write",path:String)->String {
        let args:[String:String]=tool=="read" ? ["path":path] : tool=="bash" ? ["command":"printf gate-ok > '"+path+"'"] : ["path":path,"content":"gate-ok"]
        let value:[String:Any]=["id":id,"tool":tool,"input":args]
        return "TIVANO_GATE_CASE "+String(decoding:try! JSONSerialization.data(withJSONObject:value),as:UTF8.self)
    }
    @MainActor static func main()async {
        let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["T08_STORAGE"]!);var rows:[[String:Any]]=[]
        for (name,mode,tool,decision,plan,allowed) in [("supervised-write",RuntimeMode.supervised,"write","allow",false,true),("supervised-deny",.supervised,"write","deny",false,false),("session-grant",.supervised,"bash","always",false,true),("auto-write",.autoAcceptEdits,"write","",false,true),("full-bash",.fullAccess,"bash","",false,true),("plan-write",.fullAccess,"write","",true,false)] {
            let session=OmpSession(configuration:config(name,mode:mode,plan:plan));let r=Recorder();let marker=root.appendingPathComponent(name+".txt")
            session.onEvent={ [weak session] e in if let session{r.consume(e,session:session,approval:decision.isEmpty ? nil : decision)} }
            let start=Date.now
            do {
                _=try await session.start()
                let input=TurnInput(text:prompt(name,tool:tool,path:marker.path),images:[],model:nil,effort:nil,runtimeMode:mode,interactionMode:plan ? .plan : .build)
                try await session.send(input);try await wait{!r.ends.isEmpty}
                try require(r.ends == [.completed],"wrong terminal status")
                try require(FileManager.default.fileExists(atPath:marker.path)==allowed,"gate side effect mismatch")
                try require(r.tools.count==1 && r.tools[0].status==(allowed ? .completed : .declined),"gate tool status mismatch")
                if name=="session-grant" {
                    try await session.send(input);try await wait{r.ends.count==2};try require(r.approvals==1,"session grant asked twice")
                }
                rows.append(["name":name,"passed":true,"seconds":Date.now.timeIntervalSince(start),"approvals":r.approvals])
            }catch{rows.append(["name":name,"passed":false,"error":String(describing:error)])}
            session.stop();try? await Task.sleep(for:.milliseconds(60))
        }
        let session=OmpSession(configuration:config("fork",mode:.fullAccess));let r=Recorder();session.onEvent={ [weak session] e in if let session{r.consume(e,session:session,approval:nil)} }
        do {
            _=try await session.start()
            let one=prompt("fork-one",path:root.appendingPathComponent("fork-one.txt").path),two=prompt("fork-two",path:root.appendingPathComponent("fork-two.txt").path)
            for (i,text) in [one,two].enumerated(){try await session.send(TurnInput(text:text,images:[],model:nil,effort:nil,runtimeMode:.fullAccess,interactionMode:.build));try await wait{r.ends.count==i+1}}
            let before=r.sessions.last;let after=try await session.rollback(removing:[two]);try require(before != after && FileManager.default.fileExists(atPath:after),"fork did not create new conversation")
            rows.append(["name":"real-fork","passed":true,"new_session":after])
            session.stop();try? await Task.sleep(for:.milliseconds(100))
            let restored=OmpSession(configuration:config("restored",mode:.fullAccess,resume:after));let rr=Recorder();restored.onEvent={ [weak restored] e in if let restored{rr.consume(e,session:restored,approval:nil)} }
            defer{restored.stop()}
            _=try await restored.start();try await restored.send(TurnInput(text:prompt("restored",path:root.appendingPathComponent("restored.txt").path),images:[],model:nil,effort:nil,runtimeMode:.fullAccess,interactionMode:.build));try await wait{rr.ends.count==1};try require(rr.ends[0] == .completed,"resume failed")
            rows.append(["name":"real-resume-after-fork","passed":true])
        }catch{rows.append(["name":"real-fork-resume","passed":false,"error":String(describing:error)]);session.stop()}
        let nativeTask:[String:Any]=["i":"local probe","context":"No tools, no network.","tasks":[["task":"Reply child-finished with no tools.","solutionSpace":"One reply","model":"tivano-offline/offline"]]]
        let evalAgent:[String:Any]=["language":"js","code":"const h=await agent('Reply child-finished without tools.',{model:'tivano-offline/offline'}); return await h.wait(10);","timeout":10]
        let todo:[String:Any]=["op":"init","i":"fixture todo","items":["one","two","three"]]
        for (name,tool,args,denied) in [("native-task-hydra","task",nativeTask,true),("native-eval-hydra","eval",evalAgent,true),("real-todo","todo",todo,false)] {
            let s=OmpSession(configuration:config(name,mode:.fullAccess,hydra:true));let rr=Recorder();s.onEvent={ [weak s] e in if let s{rr.consume(e,session:s,approval:nil)} }
            do {
                _=try await s.start();let value:[String:Any]=["id":name,"tool":tool,"input":args]
                let text="TIVANO_GATE_CASE "+String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
                try await s.send(TurnInput(text:text,images:[],model:nil,effort:nil,runtimeMode:.fullAccess,interactionMode:.build));try await wait{rr.ends.count==1}
                if denied{
                    try require(rr.ends == [.completed],"native gate refusal changed terminal status: \(String(describing:rr.ends))")
                    try require(rr.tools.last?.status == .declined && !rr.tools.contains{$0.status == .failed},"native gate refusal tool results: \(String(describing:rr.tools))")
                }
                else{try require(rr.todos.count==3 && rr.todos.first?.status == .active,"actual todo not mapped")}
                rows.append(["name":name,"passed":true,"terminal_statuses":rr.ends.map{String(describing:$0)},"tool_results":rr.tools.map{String(describing:$0)}])
            }catch{rows.append(["name":name,"passed":false,"error":String(describing:error),"terminal_statuses":rr.ends.map{String(describing:$0)},"tool_results":rr.tools.map{String(describing:$0)}])}
            s.stop();try? await Task.sleep(for:.milliseconds(60))
        }
        let naming=OmpSession(configuration:config("real-title",mode:.fullAccess));let nr=Recorder();naming.onEvent={ [weak naming] e in if let naming{nr.consume(e,session:naming,approval:nil)} }
        do{
            _=try await naming.start();try await naming.send(TurnInput(text:prompt("title-before",path:root.appendingPathComponent("title-before.txt").path),images:[],model:nil,effort:nil,runtimeMode:.fullAccess,interactionMode:.build));try await wait{nr.ends.count==1}
            let namingTask=Task{await naming.requestTitle()};defer{namingTask.cancel()};try await wait({!nr.titles.isEmpty},seconds:15);try require(!nr.titles[0].isEmpty,"no title")
            rows.append(["name":"real-rename","passed":true,"title":nr.titles[0]])
        }catch{rows.append(["name":"real-rename","passed":false,"error":String(describing:error)])};naming.stop()
        let json:[String:Any]=["passed":rows.allSatisfy{$0["passed"] as? Bool == true},"results":rows]
        let data=try! JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]);try! data.write(to:root.appendingPathComponent("summary-real.json"));print(String(decoding:data,as:UTF8.self))
    }
}
