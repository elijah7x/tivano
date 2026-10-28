import Foundation

// Hydra 2.0: shadow decision points and their outcomes. See docs/hydra-decisions.md.
extension AppModel {
    func hydraJobRunsDecisions(_ jobID: UUID, of leadID: UUID) -> Bool {
        guard !CaptureRun.isEnabled else { return false }
        return settings.isDecisionsEnabled
            && thread(leadID)?.hydraJobs.first(where: { $0.id == jobID })?.decisions == true
    }

    func runHydraDecision(_ request: HydraDecisionRequest, leadID: UUID, jobID: UUID, headID: UUID? = nil) {
        let at = Date.now.ISO8601Format()
        Task.detached(priority: .utility) {
            var record: [String: JSONValue] = [
                "v": .int(1),
                "kind": .string("decision"),
                "id": .string(UUID().uuidString),
                "at": .string(at),
                "point": .string(request.point.rawValue),
                "leadID": .string(leadID.uuidString),
                "jobID": .string(jobID.uuidString),
                "engine": .string("typesafe"),
                "model": .string(TypeSafeAPI.model),
                "responseModel": .null,
                "status": .string("skipped"),
                "error": .string(TypeSafeAPI.Failure.missingKey.rawValue),
                "latencyMs": .null,
                "inputTokens": .null,
                "outputTokens": .null,
                "state": request.state,
                "questions": .object(request.questions),
                "answers": .null
            ]
            if let headID { record["headID"] = .string(headID.uuidString) }
            if let key = TypeSafeAPI.readKey() {
                let clock = ContinuousClock()
                let start = clock.now
                let result = await TypeSafeAPI.evaluate(state: request.state, questions: request.questions, key: key)
                record["latencyMs"] = .int(Int((start.duration(to: clock.now) / .milliseconds(1)).rounded()))
                switch result {
                case .success(let evaluation):
                    record["status"] = .string("ok")
                    record["error"] = .null
                    record["responseModel"] = evaluation.model.map(JSONValue.string) ?? .null
                    record["inputTokens"] = evaluation.inputTokens.map(JSONValue.int) ?? .null
                    record["outputTokens"] = evaluation.outputTokens.map(JSONValue.int) ?? .null
                    record["answers"] = evaluation.answers
                case .failure(let failure):
                    record["status"] = .string("failed")
                    record["error"] = .string(failure.rawValue)
                }
            }
            await DecisionLedger.shared.append(.object(record))
        }
    }

    func recordHydraDecisionOutcome(leadID: UUID, jobID: UUID, reviewer: String, findings: Int, findingPaths: [String]) {
        let record: JSONValue = .object([
            "v": .int(1),
            "kind": .string("outcome"),
            "at": .string(Date.now.ISO8601Format()),
            "point": .string(HydraDecisionPoint.preReview.rawValue),
            "leadID": .string(leadID.uuidString),
            "jobID": .string(jobID.uuidString),
            "reviewer": .string(reviewer),
            "findings": .int(findings),
            "findingPaths": .array(findingPaths.map(JSONValue.string))
        ])
        Task.detached(priority: .utility) {
            await DecisionLedger.shared.append(record)
        }
    }
}
