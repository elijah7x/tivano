import Foundation

/// Shared CLI helpers for Pi (`pi`) and omp (`omp`): thinking levels, support
/// file installation, throwaway RPC probes, auth summary formatting, and model
/// catalog construction.
enum PiCLISupport {
    /// `--thinking` levels shared by Pi and omp, mapped 1:1 to Tivano effort strings.
    static let thinkingLevels = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func homeDirectory(environment: [String: String]) -> String {
        environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? LoginEnvironment.homeDirectory
    }

    static func subdirectory(_ name: String, in directory: URL) throws -> URL {
        let subdirectory = directory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        return subdirectory
    }

    /// Writes `contents` into `directory/name` and returns its path. Rewritten
    /// only when the bytes changed, so a new build's extension replaces the old one.
    static func installFile(in directory: URL, named name: String, contents: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        let data = Data(contents.utf8)
        if (try? Data(contentsOf: file)) != data {
            try data.write(to: file, options: .atomic)
        }
        return file
    }

    /// Summarizes distinct signed-in provider names, falling back to bare API key
    /// environment variables when provided.
    static func authStatus(
        providers: [String],
        environment: [String: String] = [:],
        fallbackAPIKeys: [String] = []
    ) -> ProviderStatus.Auth {
        let names = Set(providers).sorted()
        if !names.isEmpty {
            return .signedIn(names.joined(separator: ", "))
        }
        for key in fallbackAPIKeys {
            if let value = environment[key], !value.isEmpty {
                return .signedIn(nil)
            }
        }
        return .signedOut
    }

    /// Launches a throwaway line-framed RPC process, sends `requests`, waits up to
    /// `timeout` until every request id receives a reply (or stdout closes), then
    /// terminates the process.
    static func probeRPC(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        requests: [(id: String, type: String)],
        timeout: Duration
    ) async throws -> [String: JSONValue] {
        let home = homeDirectory(environment: environment)
        let process = StdioProcess(
            executable: executable,
            arguments: arguments,
            directory: URL(fileURLWithPath: home),
            environment: environment,
            framing: .lines
        )
        try process.start()
        for request in requests {
            process.send(["type": .string(request.type), "id": .string(request.id)])
        }
        let expectedIDs = Set(requests.map(\.id))
        var responses: [String: JSONValue] = [:]
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            process.terminate()
        }
        for await message in process.messages {
            if let id = message["id"]?.string, expectedIDs.contains(id) {
                responses[id] = message
                if responses.count == expectedIDs.count { break }
            }
        }
        timeoutTask.cancel()
        process.terminate()
        return responses
    }

    static func stateModel(from response: JSONValue?) -> (provider: String, id: String)? {
        guard let model = (response?["data"] ?? response)?["model"],
              let provider = model["provider"]?.string,
              let id = model["id"]?.string else { return nil }
        return (provider, id)
    }

    static func modelOptions(
        from items: [JSONValue],
        emptyError: String,
        efforts: (JSONValue) -> (efforts: [String], defaultEffort: String?),
        isDefault: (_ provider: String, _ id: String, _ fullID: String) -> Bool
    ) throws -> [ModelOption] {
        var options: [ModelOption] = []
        for item in items {
            guard let provider = item["provider"]?.string, let id = item["id"]?.string else { continue }
            let fullID = "\(provider)/\(id)"
            let effortSpec = efforts(item)
            options.append(ModelOption(
                id: fullID,
                name: item["name"]?.string ?? id,
                detail: provider,
                efforts: effortSpec.efforts,
                defaultEffort: effortSpec.defaultEffort,
                isDefault: isDefault(provider, id, fullID)
            ))
        }
        guard !options.isEmpty else {
            throw ProviderError.failed(emptyError)
        }
        return options.sorted { ($0.detail ?? "", $0.name) < ($1.detail ?? "", $1.name) }
    }
}
