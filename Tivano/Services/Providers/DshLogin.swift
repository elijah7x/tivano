import AppKit
import Darwin
import Foundation

@MainActor
enum DshLogin {
    private enum LoginError: LocalizedError {
        case launchFailed, openFailed, failed, timedOut, cancelled

        var errorDescription: String? {
            switch self {
            case .launchFailed: AppText.localized("Could not start DeepSeek Harness sign-in. Try updating DeepSeek Harness.")
            case .openFailed: AppText.localized("Could not open DeepSeek Harness sign-in.")
            case .failed: AppText.localized("DeepSeek Harness account sign-in failed. Try again.")
            case .timedOut: AppText.localized("DeepSeek Harness sign-in timed out. Try again.")
            case .cancelled: AppText.localized("DeepSeek Harness sign-in was cancelled.")
            }
        }
    }

    static func signIn(executable: URL, environment: [String: String]) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        var server: LoginServer?
        do {
            try Task.checkCancellation()
            if DshCLI.hasAccountLogin(environment: environment) { return }
            let defaultHome = URL(fileURLWithPath: LoginEnvironment.homeDirectory, isDirectory: true)
                .appendingPathComponent(".dsh", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            let application = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app", isDirectory: true)
            if DshCLI.accountHome(environment: environment) == defaultHome,
               FileManager.default.fileExists(atPath: application.path) {
                guard NSWorkspace.shared.open(application) else { throw LoginError.openFailed }
            } else {
                let started = try LoginServer(executable: executable, environment: environment)
                server = started
                let launchURL = try await started.launchURL()
                let loginURL = try await accountLoginURL(launchURL: launchURL, executable: executable)
                try Task.checkCancellation()
                guard NSWorkspace.shared.open(loginURL) else { throw LoginError.openFailed }
            }
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if DshCLI.hasAccountLogin(environment: environment) {
                    await server?.stop()
                    return
                }
                try await Task.sleep(for: .seconds(2))
            }
            throw LoginError.timedOut
        } catch {
            await server?.stop()
            if Task.isCancelled || error is CancellationError { throw LoginError.cancelled }
            throw (error as? LoginError) ?? LoginError.failed
        }
    }

    private static func accountLoginURL(launchURL: URL, executable: URL) async throws -> URL {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var authentication = URLRequest(url: launchURL)
        authentication.timeoutInterval = 20
        let (_, response) = try await session.data(for: authentication)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw LoginError.failed }
        guard var origin = URLComponents(url: launchURL, resolvingAgainstBaseURL: false) else { throw LoginError.failed }
        origin.path = ""
        origin.query = nil
        guard let baseURL = origin.url else { throw LoginError.failed }
        guard let version = await DshCLI.installedVersion(of: executable) else { throw LoginError.launchFailed }
        let client: JSONValue = .object([
            "version": .string(version),
            "locale": .string(Locale.current.identifier),
            "timezoneOffsetSeconds": .int(TimeZone.current.secondsFromGMT()),
        ])
        // Shipped rc.2 has no GET login route (or account UI in plain Web). Its authenticated
        // account/startSignIn RPC owns PKCE; the wire format comes from dsh-client-connection
        // and dsh-api-account-controller in @deepseek-ai's 0.2.0-rc.2 packages.
        var state = try await accountRPC("startSignIn", arguments: [
            "client": client,
            "callbackOrigin": .string(baseURL.absoluteString),
            "loginSource": .string("web"),
        ], baseURL: baseURL, session: session)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let address = state["attempt"]?["authorizeUrl"]?.string,
               let url = URL(string: address), url.scheme == "https", url.host != nil,
               url.path == "/dsh/authorize", url.user == nil, url.password == nil, url.fragment == nil {
                return url
            }
            if let phase = state["attempt"]?["phase"]?.string, ["failed", "expired", "cancelled"].contains(phase) {
                throw LoginError.failed
            }
            try await Task.sleep(for: .seconds(2))
            state = try await accountRPC("getState", arguments: [:], baseURL: baseURL, session: session)
        }
        throw LoginError.failed
    }

    private static func accountRPC(_ method: String, arguments: [String: JSONValue], baseURL: URL, session: URLSession) async throws -> JSONValue {
        let endpoint = "account/" + method
        let id = UUID().uuidString
        var request = URLRequest(url: baseURL.appendingPathComponent("api/" + endpoint))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.httpBody = JSONValue.object([
            "type": .string("client-request"), "rpcId": .string(id), "method": .string(endpoint),
            "payload": .object(["args": .object(arguments)]),
        ]).data()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let envelope = JSONValue.parse(data), envelope["type"]?.string == "server-response",
              envelope["rpcId"]?.string == id, envelope["result"]?["ok"]?.bool == true,
              let value = envelope["result"]?["value"] else { throw LoginError.failed }
        return value
    }

    @MainActor
    private final class LoginServer {
        private let pid: pid_t
        private let directory: URL
        private let output: URL
        private var stopped = false

        init(executable: URL, environment: [String: String]) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tivano-dsh-login-" + UUID().uuidString, isDirectory: true)
            let output = directory.appendingPathComponent("web.log")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let child: pid_t
            do {
                child = try Self.spawn(executable: executable, environment: environment, output: output)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
            self.directory = directory
            self.output = output
            self.pid = child
        }

        func launchURL() async throws -> URL {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
                for line in text.components(separatedBy: .newlines) {
                    guard let range = line.range(of: "dsh web: http://127.0.0.1:"),
                          let address = line[range.lowerBound...].dropFirst("dsh web: ".count).split(whereSeparator: \.isWhitespace).first,
                          let components = URLComponents(string: String(address)), components.scheme == "http",
                          components.host == "127.0.0.1", let port = components.port, (1...65535).contains(port),
                          components.path == "/", components.user == nil, components.password == nil,
                          components.fragment == nil, components.queryItems?.contains(where: { $0.name == "token" && !($0.value ?? "").isEmpty }) == true,
                          let url = components.url else { continue }
                    return url
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw LoginError.launchFailed
        }

        func stop() async {
            guard !stopped else { return }
            stopped = true
            // The unreaped group leader keeps this PID reserved until the whole owned group is killed.
            kill(-pid, SIGTERM)
            try? await Task.sleep(for: .seconds(1))
            kill(-pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            try? FileManager.default.removeItem(at: directory)
        }

        private static func spawn(executable: URL, environment: [String: String], output: URL) throws -> pid_t {
            let fd = Darwin.open(output.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw LoginError.launchFailed }
            defer { Darwin.close(fd) }
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw LoginError.launchFailed }
            defer { posix_spawn_file_actions_destroy(&actions) }
            var attributes: posix_spawnattr_t?
            guard posix_spawnattr_init(&attributes) == 0 else { throw LoginError.launchFailed }
            defer { posix_spawnattr_destroy(&attributes) }
            guard posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO) == 0,
                  posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO) == 0,
                  posix_spawn_file_actions_addclose(&actions, fd) == 0,
                  posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
                  posix_spawn_file_actions_addchdir_np(&actions, environment["HOME"] ?? LoginEnvironment.homeDirectory) == 0,
                  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)) == 0,
                  posix_spawnattr_setpgroup(&attributes, 0) == 0 else { throw LoginError.launchFailed }
            let arguments = [executable.path, "web", "--host", "127.0.0.1", "--port", "0", "--no-open"].map { strdup($0) }
            let variables = environment.map { strdup("\($0.key)=\($0.value)") }
            defer {
                arguments.forEach { free($0) }
                variables.forEach { free($0) }
            }
            var argv = arguments + [nil]
            var envp = variables + [nil]
            var child: pid_t = 0
            let result = argv.withUnsafeMutableBufferPointer { argv in
                envp.withUnsafeMutableBufferPointer { envp in
                    posix_spawn(&child, executable.path, &actions, &attributes, argv.baseAddress!, envp.baseAddress!)
                }
            }
            guard result == 0 else { throw LoginError.launchFailed }
            return child
        }
    }
}
