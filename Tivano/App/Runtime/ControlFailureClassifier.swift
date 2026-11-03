import Foundation

enum ControlFailureClassifier {
    static func classify(_ error: Error) -> ControlFailure {
        if let failure = error as? ControlFailure { return failure }
        if let error = error as? ProviderError {
            switch error {
            case .notInstalled(let provider):
                return failure(provider.isAPIKeyBased ? "authentication" : "not_installed")
            case .notRunning:
                return failure("provider_or_transport")
            case .failed:
                break
            }
        }
        if let error = error as? TypeSafeAPI.Failure {
            switch error {
            case .missingKey, .authRejected: return failure("authentication")
            case .rateLimited: return failure("usage_limit")
            default: return failure("provider_or_transport")
            }
        }
        if let error = error as? ClaudeAccountValidationError {
            switch error {
            case .authentication, .settingsConflict: return failure("authentication")
            default: return failure("provider_or_transport")
            }
        }
        if let error = error as? ResetCreditError, case .codexUnavailable = error {
            return failure("not_installed")
        }
        if let error = error as? ClaudeCredentialError {
            switch error {
            case .invalidCredential, .missingCredential, .activationRequired:
                return failure("authentication")
            default: return failure("provider_or_transport")
            }
        }

        // Providers can supply already-localized errors. Match both languages;
        // the Chinese lists mirror the provider error entries in Localizable.xcstrings.
        let text = error.localizedDescription.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        let category: String
        if has("auth", "sign in", "api key", "认证", "登录", "密钥") {
            category = "authentication"
        } else if has("resume", "conversation", "context window", "context overflow",
                      "恢复原会话", "恢复原对话", "恢复此对话", "对话历史", "对话不可用",
                      "对话已保留", "对话回退", "回退点创建对话", "压缩对话", "回退对话",
                      "后续对话的位置", "不存在此对话", "没有这段对话", "上下文窗口", "上下文溢出")
                    || (has("session", "thread", "rollout", "会话", "对话")
                        && has("not found", "does not exist", "找不到", "未找到", "无法继续"))
                    || has("no session found", "no thread found", "no rollout found") {
            category = "continuation"
        } else if has("limit", "quota", "额度", "用量", "上限", "限制", "配额") {
            category = "usage_limit"
        } else if has("install", "安装") {
            category = "not_installed"
        } else if has("permission", "denied", "权限", "拒绝") {
            category = "permission"
        } else {
            category = "provider_or_transport"
        }
        return failure(category)
    }

    private static func failure(_ category: String) -> ControlFailure {
        ControlFailure(code: category == "continuation" ? .continuationUnavailable : .providerFailure,
                       detail: category)
    }
}
