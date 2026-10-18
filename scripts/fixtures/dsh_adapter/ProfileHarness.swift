import Foundation

@main
struct ProfileHarness {
    static func main() async throws {
        let plan = try await DshCLI.prepareLaunch(
            executable: URL(fileURLWithPath: CommandLine.arguments[1]),
            mode: CommandLine.arguments.count > 2 ? (DshAgentMode(rawValue: CommandLine.arguments[2]) ?? .standard) : .standard,
            delegationOff: false,
            environment: ProcessInfo.processInfo.environment
        )
        // The fixture parent owns this temporary tree and keeps it until its CLI exits.
        let output: [String: Any] = ["executable": plan.executable.path,
                                    "arguments": plan.arguments,
                                    "environment": plan.environment,
                                    "ownedDirectory": plan.ownedDirectory?.path as Any? ?? NSNull()]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data([0x0a]))
    }
}
