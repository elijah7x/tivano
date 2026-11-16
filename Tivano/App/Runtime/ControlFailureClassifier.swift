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

        // Providers can supply already-localized errors. Match every supported language;
        // the localized lists mirror the provider error entries in Localizable.xcstrings.
        let text = error.localizedDescription.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        func hasWord(_ word: String) -> Bool { text.split { !$0.isLetter }.contains { $0 == word } }
        let frenchAccountConnect = has("se connecter", "connecter", "reconnecter", "pas connecté", "déconnecté")
            && has("compte", "identifiants", "jeton", "token", "login", "oauth")
        let category: String
        if has("auth", "sign in", "api key",
               "认证", "登录", "密钥",
               "認證", "登入", "金鑰", "驗證",
               "認証", "サインイン", "ログイン", "api キー", "apiキー",
               "인증", "로그인", "api 키",
               "authentif", "identifiants", "identifiez-vous",
               "connectez-vous", "reconnectez-vous", "vous connecter", "vous reconnecter", "vous êtes déconnecté",
               "clé api", "clé d'api", "clé standard api", "clé studio api", "clés api", "clés standard api")
            || frenchAccountConnect {
            category = "authentication"
        } else if has("resume", "conversation", "context window", "context overflow",
                      "恢复原会话", "恢复原对话", "恢复此对话", "对话历史", "对话不可用",
                      "对话已保留", "对话回退", "回退点创建对话", "压缩对话", "回退对话",
                      "后续对话的位置", "不存在此对话", "没有这段对话", "上下文窗口", "上下文溢出",
                      "恢復原工作階段", "恢復原會話", "恢復原對話", "恢復此對話", "對話歷史", "對話紀錄", "對話不可用",
                      "對話已保留", "對話回退", "對話回溯", "回退點建立對話", "回復點建立對話", "壓縮對話", "回退對話", "回溯對話",
                      "後續對話的位置", "不存在此對話", "沒有這段對話", "上下文視窗", "內容視窗", "上下文溢位", "上下文溢出",
                      "再開", "会話履歴", "会話の履歴", "会話は利用できません", "会話を圧縮", "会話を巻き戻", "会話が保持",
                      "ロールバック", "スレッドが残っていません", "会話がなくな", "会話が存在しない", "ターンを見つけられません",
                      "コンテキストウィンドウ", "コンテキストオーバーフロー",
                      "재개", "대화 기록", "대화 내역", "대화 이력", "대화를 압축", "대화를 되돌",
                      "대화 롤백", "되돌리기 지점", "대화가 더 이상", "대화를 이어가지 못", "대화 압축",
                      "컨텍스트 창", "컨텍스트 윈도우", "컨텍스트 오버플로",
                      "reprendre", "reprise", "fenêtre de contexte", "dépassement de contexte", "débordement de contexte")
                    || ((has("session", "thread", "rollout",
                             "会话", "对话",
                             "工作階段", "會話", "對話", "執行緒",
                             "セッション", "スレッド", "ロールアウト", "会話",
                             "세션", "스레드", "롤아웃", "대화")
                         || hasWord("fil"))
                        && has("not found", "does not exist",
                               "找不到", "未找到", "无法继续",
                               "不存在", "無法繼續",
                               "見つかりません", "見つかりませんでした", "存在しません", "続行できません",
                               "찾을 수 없", "존재하지 않", "계속할 수 없",
                               "introuvable", "n'existe pas", "non trouvé", "non trouvée", "impossible de continuer"))
                    || has("no session found", "no thread found", "no rollout found", "aucune session", "aucun fil") {
            category = "continuation"
        } else if has("limit", "quota",
                      "额度", "用量", "上限", "限制", "配额",
                      "額度", "使用量", "配額",
                      "クォータ", "利用枠", "制限",
                      "한도", "제한", "할당량", "사용량",
                      "limite", "plafond", "forfait") {
            category = "usage_limit"
        } else if has("install", "安装", "安裝", "インストール", "설치") {
            category = "not_installed"
        } else if has("permission", "denied",
                      "权限", "拒绝",
                      "權限", "拒絕",
                      "権限", "アクセス権", "拒否", "許可されていません", "許可がありません",
                      "권한", "거부",
                      "autorisation", "refusé", "refusée") {
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
