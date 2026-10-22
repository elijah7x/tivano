import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class GitHubConnection {
    static let shared = GitHubConnection()

    enum Phase: Equatable {
        case checking, disconnected, connecting, awaitingBrowser(GitHubDeviceCode), connected
    }

    private(set) var phase: Phase = .checking
    private(set) var user: GitHubUser?
    private(set) var source: GitHubTokenSource?
    private(set) var cliIsSignedIn = false
    var errorMessage: String?

    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var connectionGeneration = UUID()
    var isConnected: Bool { phase == .connected }
    var canSignInWithBrowser: Bool { !GitHubAPI.clientID.isEmpty }

    func start() {
        guard !CaptureRun.isEnabled else {
            phase = .disconnected
            return
        }
        let generation = connectionGeneration
        if let storedToken = GitHubCredentials.storedToken() {
            source = .tivano
            LoginEnvironment.setOverlay(GitHubCredentials.environment(token: storedToken))
            if let data = UserDefaults.standard.data(forKey: "GitHubUser") {
                user = try? JSONDecoder().decode(GitHubUser.self, from: data)
            }
            phase = .connected
            signInTask = Task {
                do {
                    let account = try await GitHubAPI.user(token: storedToken)
                    guard !Task.isCancelled, connectionGeneration == generation else { return }
                    finish(token: storedToken, user: account, source: .tivano)
                } catch GitHubError.unauthorized {
                    guard !Task.isCancelled, connectionGeneration == generation else { return }
                    expireSignIn()
                } catch {
                    // Offline validation leaves the cached account usable.
                }
            }
        } else if !UserDefaults.standard.bool(forKey: "GitHubCLIDeclined") {
            signInTask = Task {
                if let cliToken = await GitHubCredentials.cliToken(),
                   let account = try? await GitHubAPI.user(token: cliToken) {
                    guard !Task.isCancelled, connectionGeneration == generation else { return }
                    cliIsSignedIn = true
                    finish(token: cliToken, user: account, source: .githubCLI)
                } else {
                    guard !Task.isCancelled, connectionGeneration == generation else { return }
                    phase = .disconnected
                }
            }
        } else {
            phase = .disconnected
        }
    }

    private func finish(token: String, user: GitHubUser, source: GitHubTokenSource) {
        self.user = user
        self.source = source
        LoginEnvironment.setOverlay(GitHubCredentials.environment(token: token))
        if let data = try? JSONEncoder().encode(user) {
            UserDefaults.standard.set(data, forKey: "GitHubUser")
        }
        errorMessage = nil
        phase = .connected
    }

    func signInWithBrowser() {
        guard canSignInWithBrowser else { return }
        cancelSignIn()
        let generation = connectionGeneration
        phase = .connecting
        errorMessage = nil
        signInTask = Task {
            do {
                let code = try await GitHubAPI.startDeviceFlow()
                try Task.checkCancellation()
                guard connectionGeneration == generation else { return }
                phase = .awaitingBrowser(code)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURI)
                let newToken = try await GitHubAPI.awaitDeviceToken(code)
                let account = try await GitHubAPI.user(token: newToken)
                try Task.checkCancellation()
                guard connectionGeneration == generation else { return }
                GitHubCredentials.store(newToken)
                finish(token: newToken, user: account, source: .tivano)
            } catch {
                guard connectionGeneration == generation else { return }
                phase = .disconnected
                if !(error is CancellationError) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        connectionGeneration = UUID()
        phase = .disconnected
    }

    func connect(token: String) async {
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newToken.isEmpty else { return }
        cancelSignIn()
        let generation = connectionGeneration
        phase = .connecting
        errorMessage = nil
        do {
            let account = try await GitHubAPI.user(token: newToken)
            guard connectionGeneration == generation else { return }
            GitHubCredentials.store(newToken)
            finish(token: newToken, user: account, source: .tivano)
        } catch {
            guard connectionGeneration == generation else { return }
            phase = .disconnected
            errorMessage = (error as? GitHubError) == .unauthorized
                ? Chrome.localized("GitHub did not accept that token.") : error.localizedDescription
        }
    }

    func useGitHubCLI() async {
        cancelSignIn()
        let generation = connectionGeneration
        UserDefaults.standard.removeObject(forKey: "GitHubCLIDeclined")
        phase = .connecting
        errorMessage = nil
        if let cliToken = await GitHubCredentials.cliToken(),
           let account = try? await GitHubAPI.user(token: cliToken) {
            guard connectionGeneration == generation else { return }
            cliIsSignedIn = true
            finish(token: cliToken, user: account, source: .githubCLI)
        } else {
            guard connectionGeneration == generation else { return }
            phase = .disconnected
            errorMessage = Chrome.localized("The GitHub CLI is not signed in. Run gh auth login first.")
        }
    }

    func disconnect() {
        cancelSignIn()
        if source == .tivano { GitHubCredentials.remove() }
        if source == .githubCLI { UserDefaults.standard.set(true, forKey: "GitHubCLIDeclined") }
        LoginEnvironment.setOverlay([:])
        user = nil
        source = nil
        UserDefaults.standard.removeObject(forKey: "GitHubUser")
        phase = .disconnected
    }

    /// A rejected token is forgotten, but an expired CLI login is not a refusal of the CLI.
    private func expireSignIn() {
        GitHubCredentials.remove()
        source = nil
        disconnect()
        errorMessage = Chrome.localized("Your GitHub sign-in expired. Connect again.")
    }

    func refreshCLIStatus() async {
        cliIsSignedIn = (await GitHubCredentials.cliToken()) != nil
    }

}
