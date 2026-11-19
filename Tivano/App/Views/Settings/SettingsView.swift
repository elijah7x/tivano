import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance
    case conversation
    case providers
    case models
    case hydra
    case connections
    case shortcuts
    case archive
    case tokenUsage
    case alpha
    case about
    case credits

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .conversation: "Conversation"
        case .providers: "Provider management"
        case .models: "Model selection"
        case .hydra: "Sub-agents & Combos"
        case .connections: "Connections"
        case .shortcuts: "Shortcuts"
        case .archive: "Storage"
        case .tokenUsage: "Token usage"
        case .alpha: "Labs"
        case .about: "Version"
        case .credits: "Credits"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .conversation: "bubble.left.and.bubble.right"
        case .providers: "cpu"
        case .models: "slider.horizontal.3"
        case .hydra: "point.3.connected.trianglepath.dotted"
        case .connections: "puzzlepiece.extension"
        case .shortcuts: "command"
        case .archive: "internaldrive"
        case .tokenUsage: "chart.bar.xaxis"
        case .alpha: "flask"
        case .about: "info.circle"
        case .credits: "tag"
        }
    }

    var tint: Color {
        switch self {
        case .appearance: Color(red: 0.85, green: 0.44, blue: 0.36)
        case .conversation: Chrome.gray
        case .providers: Chrome.blue
        case .models: Color(red: 0.686, green: 0.322, blue: 0.871)
        case .hydra: Color(red: 0.188, green: 0.690, blue: 0.780)
        case .connections: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .shortcuts: Color(red: 0.32, green: 0.48, blue: 0.93)
        case .archive: Chrome.orange
        case .tokenUsage: Color(red: 0.36, green: 0.55, blue: 0.95)
        case .alpha: Color(red: 0.95, green: 0.55, blue: 0.20)
        case .about: Color(red: 0.204, green: 0.780, blue: 0.349)
        case .credits: Color(red: 0.204, green: 0.780, blue: 0.349)
        }
    }

    var keywords: [String] {
        switch self {
        case .appearance: [
            "appearance", "language", "languages", "theme", "style", "liquid glass", "texture", "create", "creation", "serif", "solid", "transparency", "transparent", "opacity", "glass", "dark", "light", "system", "accent", "accent color", "tint", "avocado", "matcha", "emerald", "glacier", "sea blue", "sky blue", "lavender", "rose", "raspberry", "coral", "honey", "text", "size", "font", "zoom", "wallpaper", "softness", "weather", "weather window", "porthole", "full window",
            "外观", "语言", "主题", "液态玻璃", "质感", "创作", "衬线", "透明度", "强调色", "牛油果", "抹茶", "翡翠", "冰川", "海蓝", "天蓝", "薰衣草", "玫瑰", "树莓", "珊瑚", "蜂蜜", "壁纸", "柔化", "天气窗", "舷窗", "落地窗", "字号",
            "外觀", "語言", "主題", "液態玻璃", "質感", "創作", "襯線", "透明度", "強調色", "酪梨綠", "抹茶", "翡翠", "冰川藍", "海藍", "天藍", "薰衣草紫", "玫瑰", "覆盆子", "珊瑚紅", "蜂蜜金", "桌布", "柔化", "天氣窗", "字級",
            "外観", "言語", "テーマ", "Liquid Glass", "質感", "クリエイション", "セリフ", "透明度", "アクセントカラー", "アボカド", "抹茶", "エメラルド", "グレイシャー", "シーブルー", "スカイブルー", "ラベンダー", "ローズ", "ラズベリー", "コーラル", "ハニー", "壁紙", "やわらかさ", "天気ウィンドウ", "文字サイズ",
            "화면 스타일", "외관", "언어", "테마", "질감", "크리에이션", "세리프", "투명도", "강조 색상", "아보카도", "말차", "에메랄드", "글레이셔", "바다 파랑", "하늘 파랑", "라벤더", "로즈", "라즈베리", "코랄", "허니", "배경화면", "부드러움", "날씨 창", "글자 크기",
            "apparence", "langue", "langues", "thème", "style", "verre liquide", "texture", "création", "empattements", "transparence", "opacité", "sombre", "clair", "couleur d'accentuation", "vert avocat", "matcha", "émeraude", "glacier", "bleu mer", "bleu ciel", "lavande", "rose", "framboise", "corail", "miel", "fond d'écran", "douceur", "fenêtre météo", "taille du texte", "police",
        ]
        case .conversation: [
            "general", "conversation", "new thread", "location", "default model", "permissions", "workspace", "worktree", "downloads", "recent downloads", "reasoning", "thinking", "working line", "finish", "finished", "sound", "chime", "predictions", "composer", "auto-hide", "top controls", "sleep", "power", "awake", "titles", "thread titles", "delete", "confirm", "shelve", "auto-shelve", "voice", "speech", "talk", "call", "microphone", "mic", "realtime", "orb", "codex", "style",
            "对话", "通用", "位置", "权限", "工作区", "最近下载", "思考", "提示音", "预测", "休眠", "标题", "删除", "搁置", "语音", "麦克风", "通话",
            "對話", "一般", "位置", "權限", "工作區", "最近下載", "思考", "提示音", "預測", "睡眠", "標題", "刪除", "封存", "暫存", "語音", "麥克風", "通話",
            "一般", "会話", "場所", "権限", "ワークスペース", "最近のダウンロード", "思考", "チャイム", "予測", "スリープ", "タイトル", "削除", "一時退避", "音声", "マイク", "通話",
            "대화", "일반", "위치", "권한", "작업 공간", "최근 다운로드", "추론", "알림음", "예측", "잠자기", "제목", "삭제", "보관", "보류", "음성", "마이크", "통화",
            "général", "conversation", "emplacement", "autorisations", "permissions", "espace de travail", "téléchargements récents", "raisonnement", "son", "prédictions", "veille", "titres", "supprimer", "mettre de côté", "voix", "micro", "microphone", "appel",
        ]
        case .providers: [
            "providers", "provider", "setup", "management", "kimi", "pi", "codex", "claude", "cursor", "opencode", "opencode zen", "opencode go", "zen", "grok", "deepseek", "deepseek harness", "dsh", "meta", "muse", "spark", "zai", "z.ai", "zcode", "glm", "coding plan", "devin", "cognition", "antigravity", "agy", "google", "gemini", "copilot", "github", "command code", "commandcode", "cmd", "minimax", "mcode", "binary", "path", "sign in", "login", "api key", "usage", "limits", "limit", "plan", "quota", "credits", "balance",
            "服务商", "管理",
            "供應商", "提供者", "管理", "登入", "金鑰", "用量", "額度", "配額", "餘額", "路徑",
            "プロバイダー", "管理", "サインイン", "ログイン", "api キー", "使用量", "上限", "クォータ", "残高", "パス",
            "제공자", "공급자", "관리", "로그인", "api 키", "사용량", "한도", "할당량", "잔액", "경로",
            "fournisseur", "fournisseurs", "gestion", "connexion", "clé api", "utilisation", "limites", "quota", "crédits", "solde", "chemin",
        ]
        case .models: [
            "model", "models", "effort", "reasoning", "fast", "slider", "picker", "group", "outdated", "text generation", "background model", "commit", "commit message", "instructions",
            "模型", "后台模型", "文本生成", "提交",
            "模型", "背景模型", "文字生成", "提交", "群組", "推理強度",
            "モデル", "バックグラウンドモデル", "テキスト生成", "コミット", "グループ", "推論レベル",
            "모델", "백그라운드 모델", "텍스트 생성", "커밋", "그룹", "추론 강도",
            "modèle", "modèles", "modèle en arrière-plan", "génération de texte", "commit", "groupe", "effort", "raisonnement", "rapide",
        ]
        case .hydra: [
            "hydra", "chimera", "heads", "subagents", "sub-agents", "subagent", "agents", "team", "orchestrator", "worker", "casting", "presets", "roles", "parallel", "delegate", "delegation", "review", "queue", "combo", "combos", "pair", "pairs", "same-model", "preset", "adaptive", "strengths", "suggested",
            "组合", "同模型", "预设子代理", "自适应", "启发式", "模型特长", "推荐组合", "主代理", "子代理", "子智能体", "选角", "预设", "角色", "委派", "审查",
            "組合", "同模型", "預設子代理", "自適應", "模型專長", "推薦組合", "主代理", "子代理", "指派", "預設", "角色", "委派", "審查", "佇列",
            "コンボ", "同一モデル", "プリセット", "アダプティブ", "得意分野", "おすすめコンボ", "リード", "サブエージェント", "チーム", "割り当て", "役割", "委譲", "レビュー", "キュー",
            "콤보", "동일 모델", "프리셋", "적응형", "모델 강점", "추천 콤보", "리드", "하위 에이전트", "서브에이전트", "팀", "배정", "역할", "위임", "검토", "대기열",
            "combinaisons", "combos", "même modèle", "préréglage", "adaptatif", "points forts", "équipe", "agent principal", "sous-agent", "sous-agents", "déléguer", "rôles", "revue", "file",
        ]
        case .connections: [
            "connections", "mcp", "model context protocol", "servers", "tools", "connect", "integrations", "local control", "control", "cli", "remote mcp", "remote", "code hosts", "git", "pull request", "github", "gitlab", "gitea", "cursor origin", "origin", "repository", "repositories", "repo", "account", "playwright", "notion", "linear", "slack", "figma", "supabase", "stripe", "resend", "email", "context7", "sentry", "postgres", "browser", "netlify", "deploy", "hosting",
            "连接", "本地控制", "远程", "代码托管",
            "連線", "本機控制", "遠端", "程式碼託管", "伺服器", "儲存庫", "拉取請求",
            "接続", "ローカル制御", "リモート", "コードホスト", "サーバー", "リポジトリ",
            "연결", "로컬 제어", "원격", "코드 호스트", "서버", "저장소",
            "connexions", "contrôle local", "distant", "hébergeurs de code", "serveur", "serveurs", "dépôt",
        ]
        case .shortcuts: [
            "shortcuts", "keyboard", "keys", "hotkey",
            "快捷键",
            "快速鍵", "鍵盤", "按鍵",
            "ショートカット", "キーボード", "キー",
            "단축키", "키보드", "키",
            "raccourcis", "clavier", "touches",
        ]
        case .archive: [
            "storage", "space", "disk", "worktree", "worktrees", "reveal", "finder", "build", "cache", "clean", "archive", "archived", "restore",
            "存储", "空间", "工作树", "归档", "清理", "缓存",
            "儲存空間", "空間", "磁碟", "工作樹", "封存", "清理", "快取", "還原",
            "ストレージ", "容量", "ディスク", "キャッシュ", "削除", "アーカイブ", "復元",
            "저장 공간", "디스크", "캐시", "정리", "보관", "복원",
            "stockage", "espace", "disque", "cache", "nettoyer", "archiver", "archive", "restaurer",
        ]
        case .tokenUsage: [
            "token", "tokens", "usage", "cost", "spend", "token taken", "tokentaken", "statistics", "data source",
            "词元", "词元用量", "Token 用量", "用量", "统计", "费用", "花费",
            "詞元", "詞元用量", "Token 用量", "用量", "統計", "費用",
            "使用量", "統計", "コスト", "費用",
            "사용량", "통계", "비용",
            "utilisation", "statistiques", "jeton", "jetons", "coût",
        ]
        case .alpha: [
            "alpha", "labs", "experimental", "beta", "preview",
            "实验室", "实验",
            "實驗室", "實驗", "搶先體驗",
            "ラボ", "実験", "実験的", "プレビュー",
            "실험실", "실험", "미리보기",
            "labo", "laboratoire", "expérimental", "aperçu",
        ]
        case .about: [
            "about", "version", "update", "updates", "software update", "auto-update", "release", "changelog",
            "版本", "关于", "更新",
            "版本", "關於", "更新",
            "バージョン", "情報", "アップデート", "更新",
            "버전", "정보", "업데이트",
            "version", "à propos", "mise à jour", "mises à jour",
        ]
        case .credits: [
            "credits", "acknowledgements", "thanks", "license", "licenses", "droppy", "zeron", "swiftterm", "orbs", "trademark", "keepsake", "keepsakes", "early supporter",
            "致谢", "许可证", "开源", "信物",
            "致謝", "授權條款", "許可證", "開源", "信物", "紀念物", "早期支持者",
            "クレジット", "謝辞", "ライセンス", "オープンソース", "記念品", "初期サポーター",
            "크레딧", "감사의 글", "라이선스", "오픈 소스", "기념품", "초기 후원자",
            "crédits", "remerciements", "licence", "licences", "souvenir", "souvenirs", "premiers soutiens",
        ]
        }
    }

    private static var visibleCases: [SettingsPage] {
        allCases.filter { $0 != .alpha }
    }

    static func filtered(matching rawQuery: String) -> [SettingsPage] {
        let query = rawQuery.trimmed
        guard !query.isEmpty else { return visibleCases }
        return visibleCases.filter { page in
            ([page.title] + page.keywords).contains { key in
                [key, Chrome.localized(key)].contains {
                    $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    private(set) var isPresented = false
    var page: SettingsPage = .appearance

    private static var transitionAnimation: Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : .easeOut(duration: 0.14)
    }

    func present(page: SettingsPage? = nil) {
        withAnimation(Self.transitionAnimation) {
            if let page { self.page = page }
            isPresented = true
        }
    }

    func dismiss() {
        guard isPresented else { return }
        withAnimation(Self.transitionAnimation) { isPresented = false }
    }
}

struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @Bindable private var navigation = SettingsNavigation.shared
    @State private var scrollTracker = SettingsScrollTracker()

    private var page: SettingsPage { navigation.page }

    private var visiblePages: [SettingsPage] {
        SettingsPage.filtered(matching: "")
    }

    var body: some View {
        let visiblePages = self.visiblePages
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: Chrome.trafficLightDiameter)
                .padding(.top, Chrome.trafficLightTop)
            SettingsBackRow {
                WindowManager.shared.hideSettings()
            }
            .padding(.horizontal, Chrome.listInset)
            .padding(.top, 10)
            ScrollView {
                SettingsPageList(
                    pages: visiblePages,
                    selected: page,
                    hasUnseenKeepsakes: model.hasUnseenKeepsakes,
                    isFrozen: scrollTracker.isFrozen
                ) { navigation.page = $0 }
            }
            .padding(.top, 14)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, _ in
                scrollTracker.note()
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { scrollTracker.note() } else { scrollTracker.coast() }
            }
            .scrollIndicators(.never)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background { WindowDragArea() }
        .onDisappear { scrollTracker.end() }
        .onChange(of: visiblePages) { _, pages in
            guard !pages.isEmpty, !pages.contains(page), let first = pages.first else { return }
            navigation.page = first
        }
    }
}

private struct SettingsBackRow: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                Text("Home")
                    .font(.ui(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering ? 1 : 0.85))
            .padding(.horizontal, Chrome.rowHorizontalPadding)
            .frame(height: Chrome.rowHeight + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background {
            shape
                .fill(isHovering ? Chrome.overlay(0.06) : .clear)
                .animation(Chrome.hover, value: isHovering)
        }
        .onHover { hovering in
            guard isHovering != hovering else { return }
            isHovering = hovering
        }
        .help(Text(verbatim: Chrome.localized("Back to your threads")))
        .accessibilityLabel(Text("Back to your threads"))
    }
}

private enum SettingsSidebarMetrics {
    static let rowSpacing: CGFloat = 1
    static let textLeading: CGFloat = 20
    static let tickHeight: CGFloat = 2
    static let minorTickHeight: CGFloat = 1.5
    static var pitch: CGFloat { Chrome.rowHeight + rowSpacing }
}

/// Icon-less settings page list with a leading tick scale and neighbour magnification on hover,
/// following `TimelineMinimapRail`'s pitch-mapped continuous hover geometry.
private struct SettingsPageList: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WindowLiveResize.self) private var liveResize

    let pages: [SettingsPage]
    let selected: SettingsPage
    let hasUnseenKeepsakes: Bool
    let isFrozen: Bool
    let select: (SettingsPage) -> Void

    @State private var hoveredIndex: Int?

    private var hoverAnimation: Animation? {
        if liveResize.isActive || reduceMotion { return nil }
        return .smooth(duration: 0.22)
    }

    var body: some View {
        Group {
            if pages.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No results")
                        .font(.ui(.body, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText.opacity(0.92))
                    Text("Try a setting or a provider name.")
                        .font(.ui(.subheadline))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: SettingsSidebarMetrics.rowSpacing) {
                        ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                            SettingsPlainSidebarRow(
                                page: item,
                                isSelected: selected == item,
                                hoverDistance: hoveredIndex.map { abs($0 - index) },
                                showsUpdateDot: item == .about && UpdateChecker.shared.updateAvailable,
                                showsKeepsakeDot: item == .credits && hasUnseenKeepsakes
                            ) {
                                select(item)
                            }
                        }
                    }
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let pitch = SettingsSidebarMetrics.pitch
                            let totalHeight = CGFloat(pages.count) * pitch - SettingsSidebarMetrics.rowSpacing
                            guard location.y >= 0, location.y <= totalHeight else {
                                if hoveredIndex != nil { hoveredIndex = nil }
                                return
                            }
                            let index = min(max(0, Int(floor(location.y / pitch))), pages.count - 1)
                            if hoveredIndex != index { hoveredIndex = index }
                        case .ended:
                            if hoveredIndex != nil { hoveredIndex = nil }
                        }
                    }

                    tickScale
                        .opacity(hoveredIndex == nil ? 0 : 1)
                        .allowsHitTesting(false)
                }
                .animation(hoverAnimation, value: hoveredIndex)
                .animation(hoverAnimation, value: selected)
            }
        }
        .padding(.horizontal, Chrome.listInset)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .allowsHitTesting(!isFrozen)
    }

    private var tickScale: some View {
        let rowHeight = Chrome.rowHeight
        let pitch = SettingsSidebarMetrics.pitch
        return ZStack(alignment: .topLeading) {
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                let isSelected = selected == item
                let distance = hoveredIndex.map { abs($0 - index) }
                let isHovered = distance == 0
                let width: CGFloat = if isHovered {
                    14
                } else if isSelected {
                    11
                } else if distance == 1 {
                    9
                } else {
                    5.5
                }
                let style: AnyShapeStyle = if isSelected && !isHovered {
                    AnyShapeStyle(Chrome.accent)
                } else if isHovered {
                    AnyShapeStyle(.primary.opacity(0.95))
                } else if distance == 1 {
                    AnyShapeStyle(.primary.opacity(0.52))
                } else {
                    AnyShapeStyle(.primary.opacity(0.28))
                }
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(style)
                    .frame(width: width, height: SettingsSidebarMetrics.tickHeight)
                    .offset(y: CGFloat(index) * pitch + (rowHeight - SettingsSidebarMetrics.tickHeight) / 2)

                if index < pages.count - 1 {
                    RoundedRectangle(cornerRadius: 0.75, style: .continuous)
                        .fill(.primary.opacity(0.16))
                        .frame(width: 3, height: SettingsSidebarMetrics.minorTickHeight)
                        .offset(y: CGFloat(index) * pitch + rowHeight + (SettingsSidebarMetrics.rowSpacing - SettingsSidebarMetrics.minorTickHeight) / 2)
                }
            }
        }
        .padding(.leading, 2)
        .accessibilityHidden(true)
    }
}

private struct SettingsPlainSidebarRow: View {
    let page: SettingsPage
    let isSelected: Bool
    let hoverDistance: Int?
    let showsUpdateDot: Bool
    let showsKeepsakeDot: Bool
    let action: () -> Void

    private var isHovered: Bool { hoverDistance == 0 }

    private var textScale: CGFloat {
        guard let hoverDistance else { return 1 }
        switch hoverDistance {
        case 0: return 1.09
        case 1: return 1.035
        default: return 1
        }
    }

    private var textOffset: CGFloat {
        guard let hoverDistance else { return 0 }
        switch hoverDistance {
        case 0: return 4
        case 1: return 1.5
        default: return 0
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.rowCornerRadius, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                Text(verbatim: Chrome.localized(page.title))
                    .font(.ui(.body, weight: isSelected || isHovered ? .medium : .regular))
                    .foregroundStyle(Chrome.primaryText.opacity(isSelected || isHovered ? 1 : 0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .scaleEffect(textScale, anchor: .leading)
                    .offset(x: textOffset)
                Spacer(minLength: 4)
                if showsUpdateDot {
                    UpdateAvailableDot(inline: true)
                } else if showsKeepsakeDot {
                    Circle()
                        .fill(Chrome.accent)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .padding(.leading, SettingsSidebarMetrics.textLeading)
            .padding(.trailing, Chrome.rowHorizontalPadding)
            .frame(height: Chrome.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .background {
            shape.fill(isSelected ? Chrome.overlay(0.12) : (isHovered ? Chrome.overlay(0.05) : .clear))
        }
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

struct SettingsDetail: View {
    let page: SettingsPage
    @State private var contentReady = false

    var body: some View {
        SettingsPageScroll(page: page, contentReady: contentReady)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                guard !contentReady else { return }
                DispatchQueue.main.async {
                    contentReady = true
                }
            }
    }
}

private struct SettingsPageScroll: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var keepsakeOverlayShown = false
    let page: SettingsPage
    let contentReady: Bool
    @State private var archiveFilter = ArchiveFilter()
    @State private var scrollChrome = ChromeScrollModel()
    @State private var stickyContext = SettingsScrollOffset()
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollTracker = SettingsScrollTracker()

    var body: some View {
        pageScroll
        .onDisappear { scrollTracker.end() }
        .onChange(of: page, initial: true) {
            scrollChrome.update(travel: 0)
            stickyContext.travel = 0
            archiveFilter = ArchiveFilter()
        }
    }

    private var contentTopInset: CGFloat {
        Chrome.chromeTopPadding + Chrome.capsuleHeight + 16
    }

    private var pageScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
                if contentReady {
                    pageContent
                }
            }
            .environment(\.chromeSectionHeaderSpacing, Chrome.pageSectionHeaderSpacing)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, Chrome.contentHorizontalPadding * 2)
            .frame(maxWidth: .infinity)
            .padding(.top, contentTopInset)
            .padding(.bottom, Chrome.contentHorizontalPadding * 2)
            .coordinateSpace(.named(SettingsStickyCoordinates.space))
            .environment(\.settingsStickyContext, stickyContext)
            .onChange(of: contentTopInset, initial: true) { _, inset in
                stickyContext.topInset = inset + 8
            }
            .allowsHitTesting(!scrollTracker.isFrozen)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: stickyContext.scrollRequest) { _, request in
            guard let request else { return }
            stickyContext.scrollRequest = nil
            // One unanimated update: scrolling a frame before the swap shows the page jump twice.
            withTransaction(Transaction(animation: nil)) {
                scrollPosition.scrollTo(y: request.y)
                request.then()
            }
        }
        .onPreferenceChange(KeepsakeOverlayPreference.self) { keepsakeOverlayShown = $0 }
        // The expanded keepsake is placed at the card's frame; scrolling would separate them.
        .scrollDisabled(keepsakeOverlayShown)
        .scrollIndicators(.never)
        .id(page)
        .onScrollGeometryChange(for: CGFloat.self, of: Self.travel) { _, travel in
            scrollTracker.note()
            scrollChrome.update(travel: travel)
            stickyContext.travel = travel
        }
        .onScrollPhaseChange { _, phase in
            if phase == .interacting { scrollTracker.note() } else { scrollTracker.coast() }
        }
        .chromeEdgeFade(scrollChrome)
        .overlay(alignment: .top) {
            if pageHasChromeControls {
                SettingsPageChrome(page: page)
                    .opacity(keepsakeOverlayShown ? 0 : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: keepsakeOverlayShown)
            }
        }
    }

    private var pageHasChromeControls: Bool {
        page == .providers || page == .models || page == .hydra || page == .connections || page == .about
    }

    @ViewBuilder
    private var pageContent: some View {
        switch page {
        case .appearance: AppearanceSettingsPage()
        case .conversation: ConversationSettingsPage()
        case .providers: ProvidersSettingsPage(query: "")
        case .models: ModelsSettingsPage(query: "")
        case .hydra: HydraSettingsPage(query: "")
        case .connections: ConnectionsSettingsPage(query: "")
        case .shortcuts: ShortcutsSettingsPage()
        case .archive: StorageSettingsPage(filter: $archiveFilter)
        case .tokenUsage: TokenUsageSettingsPage()
        case .alpha: AlphaSettingsPage()
        case .about: VersionSettingsPage()
        case .credits: CreditsSettingsPage()
        }
    }

    private nonisolated static func travel(_ geometry: ScrollGeometry) -> CGFloat {
        geometry.contentOffset.y + geometry.contentInsets.top
    }
}

private struct SettingsPageChrome: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            if page == .providers {
                ProvidersRefreshButton()
            }
            if page == .about {
                AboutUpdateChromeAccessory()
            }
        }
        .frame(minHeight: Chrome.capsuleHeight)
        .padding(.horizontal, Chrome.chromeHorizontalPadding)
        .padding(.top, Chrome.chromeTopPadding)
    }
}

struct SettingsSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

typealias DefaultModelPickerButton = ModelChoiceButton
typealias DefaultModelPopover = NewThreadModelPicker

struct ModelChoiceButton<Popover: View>: View {
    let title: String
    let help: String
    let iconName: String?
    let accessibilityLabel: String
    var width: CGFloat? = nil
    @Binding var isPresented: Bool
    @ViewBuilder let popover: () -> Popover

    var body: some View {
        Button {
                isPresented = true
            } label: {
                Group {
                    if let width {
                        choiceLabel.frame(width: width, alignment: .leading)
                    } else {
                        // Caps a long title without claiming 190 points for a short one, so the
                        // row's detail keeps the width the capsule does not need.
                        choiceLabel.frame(maxWidth: 190)
                    }
                }
                .frame(height: Chrome.capsuleContentHeight)
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .chromeGlassCapsule()
            .fixedSize()
            .foregroundStyle(Chrome.primaryText)
            .help(Text(verbatim: help))
            .accessibilityLabel(Text(verbatim: Chrome.localized(accessibilityLabel)))
            .accessibilityValue(Text(verbatim: help))
            .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                popover()
                    .frame(width: 360)
                    .presentedChrome()
            }
            .background { NoWindowDragArea() }
    }

    private var choiceLabel: some View {
        HStack(spacing: 6) {
            if let iconName {
                Image(iconName)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
            }
            Text(verbatim: title)
                .font(.ui(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if width != nil { Spacer(minLength: 0) }
            Image(systemName: "chevron.down")
                .font(Chrome.chevronFont)
                .foregroundStyle(Chrome.secondaryText)
        }
        .padding(.horizontal, Chrome.capsuleHorizontalPadding)
    }
}

struct NewThreadModelPicker: View {
    @Environment(AppModel.self) private var model
    let selection: NewThreadModelSelection?
    let selectedModelID: String?
    let automaticTitle: String
    let showsAutomaticChoice: Bool
    let allowedProviders: [ProviderKind]?
    let offSelected: Bool
    let selectOff: (() -> Void)?
    let select: (NewThreadModelSelection?) -> Void
    @State private var selectedProvider: ProviderKind?

    init(
        selection: NewThreadModelSelection?,
        selectedModelID: String?,
        initialProvider: ProviderKind?,
        automaticTitle: String = "Last selection",
        showsAutomaticChoice: Bool = true,
        allowedProviders: [ProviderKind]? = nil,
        offSelected: Bool = false,
        selectOff: (() -> Void)? = nil,
        select: @escaping (NewThreadModelSelection?) -> Void
    ) {
        self.selection = selection
        self.selectedModelID = selectedModelID
        self.automaticTitle = automaticTitle
        self.showsAutomaticChoice = showsAutomaticChoice
        self.allowedProviders = allowedProviders
        self.offSelected = offSelected
        self.selectOff = selectOff
        self.select = select
        _selectedProvider = State(initialValue: initialProvider)
    }

    var body: some View {
        let registry = model.providers
        let providers = registry.availableProviders.filter { allowedProviders?.contains($0) ?? true }
        let provider = selectedProvider.flatMap { providers.contains($0) ? $0 : nil }
        let providerPrompt = selectedProvider.map {
            String(format: Chrome.localized("%@ (unavailable)"), $0.displayName)
        } ?? Chrome.localized("Choose a provider")
        let providerOptions = (provider == nil ? [(ProviderKind?.none, providerPrompt)] : [])
            + providers.map { (Optional($0), $0.displayName) }
        let options = provider.map { model.pickerModels(for: $0, keeping: selectedModelID.map { Set([$0]) } ?? []) } ?? []
        let selectedOption = selection?.provider == provider
            ? options.first { $0.id == selectedModelID }
            : nil
        let modelTitle = selectedOption?.name ?? Chrome.localized("Choose a model")
        let effortTitle = Chrome.localized(ModelOption.effortTitle(
            selection?.effort.flatMap { selectedOption?.efforts.contains($0) == true ? $0 : nil }
                ?? selectedOption?.defaultEffort ?? ""
        ))
        let isLoading = provider.map { registry.loadingCatalogs.contains($0) } ?? false
        let error = provider.flatMap { registry.status($0).catalogError }
        VStack(alignment: .leading, spacing: 0) {
            if showsAutomaticChoice {
                PopoverItem(automaticTitle, isChecked: selection == nil && !offSelected) {
                    select(nil)
                }
                .padding(.horizontal, 6)
                .padding(.top, 6)
                if let selectOff {
                    PopoverItem("Off", isChecked: offSelected, action: selectOff)
                        .padding(.horizontal, 6)
                }
                Divider()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                // Shares the Last selection row's checkmark column so the two choices read as peers.
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(Chrome.primaryText)
                        .opacity(selection == nil || offSelected ? 0 : 1)
                        .frame(width: 14)
                    Text(verbatim: Chrome.localized("Specific model"))
                        .font(.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                }
                .padding(.leading, 14)
                .padding(.top, 2)
                .padding(.bottom, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Specific model"))
                .accessibilityAddTraits(selection == nil || offSelected ? .isHeader : [.isHeader, .isSelected])
            }
            editorRow("Provider") {
                GlassPickerButton(
                    options: providerOptions,
                    selection: Binding(
                        get: { provider },
                        set: { if let provider = $0 { selectedProvider = provider } }
                    ),
                    asset: { $0?.iconName },
                    maxWidth: 190
                )
                .disabled(providers.isEmpty)
                .help(Text(verbatim: provider?.displayName ?? providerPrompt))
                .accessibilityLabel(Text("Provider"))
                .accessibilityValue(Text(verbatim: provider?.displayName ?? providerPrompt))
            }
            editorRow("Model") {
                GlassPickerButton(
                    options: [(String?.none, "Choose a model")] + options.map { (Optional($0.id), $0.label(among: options)) },
                    selection: Binding(
                        get: { selectedOption?.id },
                        set: { id in
                            guard let provider, selectedProvider == provider,
                                  registry.availableProviders.contains(provider),
                                  let id, let option = options.first(where: { $0.id == id }) else { return }
                            let effort = selection?.effort.flatMap { option.efforts.contains($0) ? $0 : nil }
                            select(NewThreadModelSelection(provider: provider, modelID: id, effort: effort))
                        }
                    ),
                    maxWidth: 190
                )
                .disabled(options.isEmpty)
                .help(Text(verbatim: modelTitle))
                .accessibilityLabel(Text("Model"))
                .accessibilityValue(Text(verbatim: modelTitle))
            }
            if let selectedOption, !selectedOption.efforts.isEmpty {
                editorRow("Reasoning effort") {
                    GlassPickerButton(
                        options: [(String?.none, "Default")] + selectedOption.efforts.map { (Optional($0), ModelOption.effortTitle($0)) },
                        selection: Binding(
                            get: { selection?.effort.flatMap { selectedOption.efforts.contains($0) ? $0 : nil } },
                            set: { effort in
                                guard let selection else { return }
                                select(NewThreadModelSelection(provider: selection.provider, modelID: selection.modelID, effort: effort))
                            }
                        ),
                        maxWidth: 190
                    )
                    .help(Text(verbatim: effortTitle))
                    .accessibilityLabel(Text("Reasoning effort"))
                    .accessibilityValue(Text(verbatim: effortTitle))
                }
            }
            if providers.isEmpty {
                catalogNote(Chrome.localized(showsAutomaticChoice && automaticTitle == "Last selection" ? "No providers available. You can still use Last selection." : "No providers available."))
            } else if let provider {
                if isLoading {
                    catalogNote(String(format: Chrome.localized(options.isEmpty ? "Loading %@'s models…" : "Refreshing %@'s models…"), provider.displayName))
                } else if let error {
                    catalogNote(
                        options.isEmpty ? error : String(
                            format: Chrome.localized("Could not refresh %@'s models. You can still use the loaded models.\n%@"),
                            provider.displayName, error
                        ),
                        retryProvider: provider
                    )
                } else if options.isEmpty {
                    catalogNote(
                        String(format: Chrome.localized("No models loaded for %@ yet."), provider.displayName),
                        retryProvider: provider
                    )
                }
            }
        }
        .padding(.top, showsAutomaticChoice ? 0 : 6)
        .padding(.bottom, 14)
        .task(id: selectedProvider) {
            guard let provider = selectedProvider, providers.contains(provider), !Task.isCancelled else { return }
            await registry.loadCatalog(provider, force: false)
        }
    }

    private func editorRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(verbatim: Chrome.localized(title))
                .font(.ui(.body))
                .foregroundStyle(Chrome.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        // Leading inset lines the label up with the titles beside the checkmark column.
        .padding(.leading, 36)
        .padding(.trailing, 14)
        .padding(.vertical, 5)
    }

    private func catalogNote(_ message: String, retryProvider: ProviderKind? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: message)
                .font(.ui(.subheadline))
                .foregroundStyle(Chrome.secondaryText)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let provider = retryProvider {
                Button("Retry") {
                    Task {
                        let registry = model.providers
                        guard selectedProvider == provider,
                              registry.availableProviders.contains(provider),
                              !registry.loadingCatalogs.contains(provider) else { return }
                        await registry.loadCatalog(provider, force: true)
                    }
                }
                .chromeGlassButtonStyle()
                .controlSize(.small)
                .disabled(model.providers.loadingCatalogs.contains(provider))
                .accessibilityLabel(Text(verbatim: String(format: Chrome.localized("Retry loading %@'s models"), provider.displayName)))
            }
        }
        .padding(.leading, 36)
        .padding(.trailing, 14)
        .padding(.top, 8)
    }
}

struct NewThreadDefaultPicker: View {
    @Environment(AppModel.self) private var model
    let selection: NewThreadDefault?
    let selectedModelID: String?
    let initialProvider: ProviderKind?
    let automaticTitle: String
    let showsAutomatic: Bool
    let select: (NewThreadDefault?) -> Void

    init(
        selection: NewThreadDefault?,
        selectedModelID: String?,
        initialProvider: ProviderKind?,
        automaticTitle: String = "Last selection",
        showsAutomatic: Bool = true,
        select: @escaping (NewThreadDefault?) -> Void
    ) {
        self.selection = selection
        self.selectedModelID = selectedModelID
        self.initialProvider = initialProvider
        self.automaticTitle = automaticTitle
        self.showsAutomatic = showsAutomatic
        self.select = select
    }

    var body: some View {
        let registry = model.providers
        let pickerPairs = model.hydraPickerPairs
        let selectedPairID = selection?.pairID

        VStack(alignment: .leading, spacing: 0) {
            NewThreadModelPicker(
                selection: selection?.modelSelection,
                selectedModelID: selectedModelID,
                initialProvider: initialProvider,
                automaticTitle: automaticTitle,
                showsAutomaticChoice: showsAutomatic,
                offSelected: selectedPairID != nil
            ) { chosen in
                select(chosen.map(NewThreadDefault.model))
            }
            if !pickerPairs.isEmpty {
                PopoverDivider()
                    .padding(.horizontal, 6)
                PopoverSectionHeader("Preset sub-agents")
                    .padding(.horizontal, 6)
                ForEach(pickerPairs) { pair in
                    PopoverItem(
                        HydraPairSummary.title(pair, registry: registry),
                        detail: pair.customName == nil
                            ? HydraPairSummary.providers(pair)
                            : HydraPairSummary.modelsTitle(pair, registry: registry),
                        leading: AnyView(
                            HydraFusedPairIcon(
                                lead: pair.provider,
                                heads: model.hydraHeadsProvider(of: pair),
                                size: 15,
                                animates: false
                            )
                        ),
                        isChecked: selectedPairID == pair.id,
                        localizesTitle: false
                    ) {
                        select(.pair(pair.id))
                    }
                    .padding(.horizontal, 6)
                }
            }
        }
        .padding(.bottom, pickerPairs.isEmpty ? 0 : 8)
        .frame(width: 360)
    }
}

private struct ProvidersRefreshButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ChromeCapsule {
            ChromeIconButton(
                symbol: "arrow.clockwise",
                isEnabled: !model.providers.isRefreshing,
                help: model.providers.isRefreshing ? "Checking providers…" : "Check providers again"
            ) {
                Task { await model.providers.refreshEverything() }
            }
        }
    }
}

/// Shows provider status plus cached, read-only CLI update checks.
/// The one read it starts on its own is each signed-in account's usage limits, which the registry
/// throttles to once a minute, so the numbers are on screen without a trip through a chat.
private struct ProvidersSettingsPage: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var selection: ProviderKind?

    var body: some View {
        let settings = model.settings
        let enabled = ProviderGroup.allCases.flatMap(\.providers).filter { settings.isEnabled($0) }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = enabled.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
        let selected = selection.flatMap { visible.contains($0) ? $0 : nil }
        VStack(alignment: .leading, spacing: Chrome.pageSectionSpacing) {
            ProviderSelectionSection(settings: settings)
            if !enabled.isEmpty {
                StickySidebarRow(
                    alignment: .providerCardTop,
                    spacing: Chrome.sectionSpacing,
                    sidebarWidth: ProviderListColumn.railWidth
                ) { select in
                    ProviderListColumn(providers: visible, selected: selected) { provider in
                        select { selection = provider }
                    }
                } detail: {
                    if let selected {
                        ProviderSettingsSection(provider: selected, alignsCardTop: true)
                            .id(selected)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !visible.isEmpty {
                        LazyVStack(alignment: .leading, spacing: Chrome.unitSpacing) {
                            ForEach(visible) { provider in
                                ProviderSettingsSection(provider: provider, alignsCardTop: provider == visible.first)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            await model.providers.checkCLIUpdates(freshness: ProviderRegistry.cliCheckFreshnessOnOpen)
        }
        .onChange(of: settings.checksCLIUpdates) { _, _ in
            for provider in ProviderKind.allCases {
                model.providers.cliMonitoringChanged(provider)
            }
        }
    }
}

private enum ProviderListStatus {
    case ready, attention, notInstalled

    var title: String {
        switch self {
        case .ready: "Ready"
        case .attention: "Needs attention"
        case .notInstalled: "Not installed"
        }
    }

    var color: Color {
        switch self {
        case .ready: Chrome.success
        case .attention: Chrome.warning
        case .notInstalled: Chrome.secondaryText.opacity(0.5)
        }
    }
}

private extension VerticalAlignment {
    /// The top of each column's first card, so the provider list and its detail start level.
    enum ProviderCardTop: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.top] }
    }

    static let providerCardTop = VerticalAlignment(ProviderCardTop.self)
}

private struct ProviderListColumn: View {
    static let railWidth: CGFloat = SettingsIconRail.railWidth

    @Environment(AppModel.self) private var model
    let providers: [ProviderKind]
    let selected: ProviderKind?
    let select: (ProviderKind?) -> Void

    private var groupedProviders: [(group: ProviderGroup, providers: [ProviderKind])] {
        ProviderGroup.allCases.compactMap { group in
            let matched = group.providers.filter { providers.contains($0) }
            return matched.isEmpty ? nil : (group, matched)
        }
    }

    var body: some View {
        let allRow = SettingsIconRailRow(
            id: "all",
            title: "All providers",
            titleIsVerbatim: false,
            isSelected: selected == nil,
            action: { select(nil) }
        ) {
            SidebarSymbol("square.grid.2x2")
                .foregroundStyle(Chrome.primaryText.opacity(selected == nil ? 1 : 0.92))
        }
        let sections = [SettingsIconRailSection(id: "all", rows: [allRow])]
            + groupedProviders.map { entry in
                SettingsIconRailSection(
                    id: entry.group.id,
                    title: Chrome.localized(entry.group.title),
                    rows: entry.providers.map(row)
                )
            }
        SettingsIconRail(
            sections: sections,
            emptyTitle: providers.isEmpty ? Chrome.localized("No matching providers") : nil
        )
        .alignmentGuide(.providerCardTop) { $0[.top] }
    }

    private func row(_ provider: ProviderKind) -> SettingsIconRailRow {
        let status = visibleStatus(provider)
        let dot = status.map {
            SettingsIconRailRow.StatusDot(color: $0.color, accessibilityLabel: Chrome.localized($0.title))
        }
        return SettingsIconRailRow(
            id: provider.id,
            title: provider.displayName,
            titleIsVerbatim: true,
            statusDot: dot,
            accessoryWidth: 14,
            isSelected: selected == provider,
            action: { select(provider) }
        ) {
            ProviderIcon(provider: provider, size: Chrome.symbolSize)
        } accessory: {
            if let status {
                Circle()
                    .fill(status.color)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel(Text(verbatim: Chrome.localized(status.title)))
            }
        }
    }

    private func visibleStatus(_ provider: ProviderKind) -> ProviderListStatus? {
        guard !model.providers.status(provider).isChecking else { return nil }
        return listStatus(provider)
    }

    private func listStatus(_ provider: ProviderKind) -> ProviderListStatus {
        let status = model.providers.status(provider)
        guard status.isInstalled else { return .notInstalled }
        if !provider.isAPIKeyBased && status.auth == .signedOut { return .attention }
        switch model.providers.cliUpdates[provider]?.phase {
        case .available, .failed: return .attention
        default: return .ready
        }
    }
}

private struct ProviderCardTopAlignment: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.alignmentGuide(.providerCardTop) { $0[.top] }
        } else {
            content
        }
    }
}

private struct ProviderSettingsSection: View {
    @Environment(AppModel.self) private var model
    let provider: ProviderKind
    var alignsCardTop = false

    @State private var binaryPath = ""
    @State private var apiKey = ""
    @State private var showsAPIKey = false
    @State private var keyCheck: Task<Void, Never>?
    @State private var signInTask: Task<Void, Never>?
    @State private var signInError: String?

    private var apiKeyDetail: String {
        let settings = model.settings
        if let error = settings.apiKeyStoreErrors[provider] {
            return String(format: Chrome.localized("Couldn't save to your Keychain (%@). The key works until you quit Tivano; enter it again to retry."), error)
        }
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           case .environment(let name) = settings.apiKeySource(for: provider) {
            return String(format: Chrome.localized("Using %@ from your shell environment."), name)
        }
        return provider == .zai
            ? String(format: Chrome.localized("Use a GLM Coding Plan key; Standard API keys will not work here. Stored in your Keychain. Get one at %@."), provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
            : provider.isAPIKeyBased
            ? String(format: Chrome.localized("Stored in your Keychain. Get one at %@."), provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
            : String(format: Chrome.localized("Instead of “%@”: a Studio key from %@, stored in your Keychain and handed to the CLI."), provider.loginCommand, provider.apiKeySource ?? Chrome.localized("the provider dashboard"))
    }

    private static let regionOptions = ZaiRegion.allCases.map { ($0, $0.title) }

    var body: some View {
        let settings = model.settings
        let registry = model.providers
        let status = registry.status(provider)
        let isSignedIn: Bool = {
            if case .signedIn = status.auth { return true }
            return false
        }()
        let showsUsage = settings.showsProviderUsage
            && (PlanLimitsReader.exposesLimits(provider) || CreditsReader.exposesCredits(provider))
            && status.isInstalled && status.auth != .signedOut
        VStack(alignment: .leading, spacing: Chrome.pageSectionHeaderSpacing) {
            Group {
                let showsSignIn = !status.isChecking && !isSignedIn && !provider.loginCommand.isEmpty
                let updateState: ProviderUpdateViewState? = provider.isAPIKeyBased ? nil : {
                    let update = registry.cliUpdates[provider]
                    let phase: ProviderUpdateViewState.Phase
                    switch update?.phase {
                    case .checking: phase = .checking
                    case .current: phase = .current
                    case nil: phase = settings.monitorsUpdates(provider) ? .checking : .current
                    case .available: phase = .available
                    case .waiting: phase = .waiting
                    case .updating: phase = .updating
                    case .updated: phase = .updated
                    case .failed: phase = .failed
                    }
                    return ProviderUpdateViewState(
                        phase: phase,
                        installed: update?.installed ?? status.version,
                        latest: update?.latest,
                        command: update?.channel?.command,
                        error: update?.error,
                        updateFailed: update?.updateFailed ?? false,
                        monitoringEnabled: registry.monitorsCLIUpdates(provider),
                        customBinaryPath: !settings.binaryPath(for: provider).isEmpty,
                        channelKnown: update?.channel != nil
                    )
                }()
                ChromeCard {
                    HStack(spacing: 12) {
                        ProviderIcon(provider: provider, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: provider.displayName)
                                .font(.ui(.title3, weight: .semibold))
                                .foregroundStyle(Chrome.primaryText)
                                .accessibilityAddTraits(.isHeader)
                            if !provider.routeSummary.isEmpty {
                                Text(verbatim: provider.routeSummary)
                                    .font(.ui(.subheadline))
                                    .foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    ChromeRowDivider()
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: Chrome.localized(status.isChecking ? "Checking…" : status.summary))
                                .font(.ui(size: 13))
                            if status.isInstalled, let updateState {
                                ProviderUpdateSubtitle(state: updateState)
                            } else if provider.isAPIKeyBased, status.apiKeyConfigured, let host = provider.apiHost {
                                Text(verbatim: String(format: Chrome.localized("Native API · %@"), host))
                                    .font(.ui(.subheadline))
                                    .foregroundStyle(Chrome.secondaryText)
                            }
                        }
                        Spacer()
                        if status.isInstalled, let updateState {
                            ProviderUpdateAction(
                                state: updateState,
                                onCheck: { Task { await registry.checkCLIUpdate(provider, force: true) } },
                                onUpdate: { Task { await registry.updateCLI(provider) } }
                            )
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, Chrome.rowControlTrailingPadding)
                    .padding(.vertical, 11)
                    if showsUsage {
                        ChromeRowDivider()
                        VStack(alignment: .leading, spacing: 14) {
                            if PlanLimitsReader.exposesLimits(provider) {
                                PlanLimitsView(provider: provider)
                            }
                            if CreditsReader.exposesCredits(provider) {
                                CreditsView(provider: provider)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    if provider == .zai {
                        ChromeRowDivider()
                        ChromeRow(title: "Region", detail: "Where your key was issued. Global uses api.z.ai, China uses open.bigmodel.cn.") {
                            GlassPickerButton(options: Self.regionOptions, selection: Binding(
                                get: { settings.zaiRegion },
                                set: { settings.zaiRegion = $0 }
                            ))
                        }
                    }
                    if provider == .dsh || provider == .minimaxCode, let error = status.catalogError {
                        ChromeRowDivider()
                        ChromeRow(title: "Models", detail: error) {
                            EmptyView()
                        }
                    }
                    if provider == .minimaxCode {
                        ChromeRowDivider()
                        ChromeRow(title: "Authentication", detail: "Tivano uses the authentication route already selected in mcode. Token Plan uses your existing mcode sign-in; API-key users keep their configured key. Local checks and model lists do not verify server authentication.") {
                            Link(destination: URL(string: "https://agent.minimax.io/docs/cli/configuration")!) {
                                Text("Setup guide").frame(height: Chrome.rowButtonLabelHeight)
                            }
                            .chromeGlassButtonStyle()
                        }
                        ChromeRowDivider()
                        ChromeRow(title: "CLI updates", detail: "Update MiniMax Code with its official installer or the documented npm command.") {
                            Link(destination: provider.installURL) {
                                Text("Setup guide").frame(height: Chrome.rowButtonLabelHeight)
                            }
                            .chromeGlassButtonStyle()
                        }
                        ChromeRowDivider()
                        ChromeRow(title: "Attachments and usage", detail: "MiniMax Code currently uses text input in Tivano. Image attachments, plan balances and token-spend accounting are not enabled.") {
                            EmptyView()
                        }
                    }
                    if provider.acceptsAPIKey {
                        ChromeRowDivider()
                        ChromeRow(
                            title: provider.isAPIKeyBased ? "API key" : "API key (optional)",
                            detail: apiKeyDetail
                        ) {
                            HStack(spacing: 8) {
                                Group {
                                    if showsAPIKey {
                                        TextField("", text: $apiKey, prompt: Text(verbatim: Chrome.localized(provider == .zai ? ZaiRegion.apiKeyPlaceholder : "sk-…")))
                                    } else {
                                        SecureField("", text: $apiKey, prompt: Text(verbatim: Chrome.localized(provider == .zai ? ZaiRegion.apiKeyPlaceholder : "sk-…")))
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                .font(.ui(size: 12, design: .monospaced))
                                .frame(width: 200)
                                Button {
                                    showsAPIKey.toggle()
                                } label: {
                                    Image(systemName: showsAPIKey ? "eye.slash" : "eye")
                                        .font(.ui(size: 12))
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Chrome.secondaryText)
                                .help(Text(verbatim: Chrome.localized(showsAPIKey ? "Hide the API key" : "Show the API key")))
                                .accessibilityLabel(Text(verbatim: Chrome.localized(showsAPIKey ? "Hide the API key" : "Show the API key")))
                            }
                        }
                        if provider.isAPIKeyBased, !status.isInstalled {
                            ChromeRowDivider()
                            ChromeRow(title: "Get a key", detail: provider == .zai
                                ? "Z.ai needs a GLM Coding Plan key. Standard API keys will not work here. Nothing to install."
                                : String(format: Chrome.localized("%@ needs an API key. Nothing to install."), provider.displayName)) {
                                Link(destination: provider.installURL) {
                                    Text(verbatim: String(format: Chrome.localized("Get a %@ key"), provider.displayName))
                                        .frame(height: Chrome.rowButtonLabelHeight)
                                }
                                .chromeGlassButtonStyle()
                            }
                        }
                    }
                    if updateState != nil {
                        if settings.showsProviderBinaryPaths {
                            ChromeRowDivider()
                            ChromeRow(title: "Binary path", detail: status.executable?.path) {
                                TextField("", text: $binaryPath, prompt: Text(provider.executableName))
                                    .textFieldStyle(.roundedBorder)
                                    .font(.ui(size: 12, design: .monospaced))
                                    .frame(width: 200)
                            }
                        }
                        if !status.isInstalled {
                            ChromeRowDivider()
                            let missing = String(format: Chrome.localized("%@ was not found on your PATH."), provider.displayName)
                            let detail = provider == .zcode
                                ? Chrome.localized("ZCode is not installed. Install the ZCode app, then click Check providers again at the top right.")
                                : LoginEnvironment.diagnostic.map { missing + " " + $0 } ?? missing
                            ChromeRow(title: "Install", detail: detail) {
                                Link(destination: provider.installURL) {
                                    Text(verbatim: String(format: Chrome.localized("Get %@"), provider.displayName))
                                        .frame(height: Chrome.rowButtonLabelHeight)
                                }
                                .chromeGlassButtonStyle()
                            }
                        } else if showsSignIn {
                            ChromeRowDivider()
                            let signInDetail = provider == .dsh
                                ? (registry.signingIn == .dsh
                                    ? "Waiting for you to sign in to DeepSeek Harness…"
                                    : signInError ?? (FileManager.default.fileExists(atPath: "/Applications/DeepSeek Harness.app")
                                        ? "Opens DeepSeek Harness to sign in to your DeepSeek account."
                                        : "Opens your browser to sign in to your DeepSeek account."))
                                : signInError ?? "Click Sign in on the right."
                            ChromeRow(title: provider == .minimaxCode ? "Token Plan sign-in" : "Sign in", detail: provider == .minimaxCode
                                ? "Use mcode login for Token Plan, or mcode login --region global for Global accounts. If already signed in, refresh the provider. API-key users do not need this step."
                                : signInDetail) {
                                if provider == .dsh {
                                    HStack(spacing: 8) {
                                        if registry.signingIn == .dsh {
                                            ProgressView().controlSize(.mini)
                                            Button("Cancel") { signInTask?.cancel() }
                                                .disabled(signInTask == nil)
                                        } else {
                                            Button {
                                                signInError = nil
                                                signInTask = Task {
                                                    signInError = await registry.signIn(provider)
                                                    signInTask = nil
                                                }
                                            } label: {
                                                Text(verbatim: Chrome.localized("Sign in")).frame(height: Chrome.rowButtonLabelHeight)
                                            }
                                            .disabled(registry.signingIn != nil)
                                        }
                                    }
                                    .chromeGlassButtonStyle()
                                } else {
                                    Button {
                                        Workspace.openTerminal(running: provider.loginCommand)
                                    } label: {
                                        Text(verbatim: Chrome.localized("Sign in")).frame(height: Chrome.rowButtonLabelHeight)
                                    }
                                    .chromeGlassButtonStyle()
                                }
                            }
                        }
                    }
                    if ProviderAccounts.supportedProviders.contains(provider), status.isInstalled {
                        ChromeRowDivider()
                        ProviderAccountsSection(provider: provider)
                    }
                }
                .modifier(ProviderCardTopAlignment(enabled: alignsCardTop))
            }
        }
        .onDisappear { signInTask?.cancel() }
        .onAppear {
            binaryPath = settings.binaryPath(for: provider)
            if provider.acceptsAPIKey { apiKey = settings.apiKeyInput(for: provider) }
        }
        .onChange(of: showsUsage, initial: true) { _, shows in
            // Fires once when the page opens on a signed-in account and again when a check signs
            // one in. Sections are eager, so scrolling never re-fires it, and the registry hands
            // back what it read within the last minute instead of asking the provider again.
            guard shows else { return }
            registry.refreshPlanLimits(provider)
            registry.refreshCredits(provider)
        }
        .onChange(of: binaryPath) { _, value in
            guard value != settings.binaryPath(for: provider) else { return }
            settings.setBinaryPath(value, for: provider)
        }
        .onChange(of: provider == .zai ? settings.zaiRegion : nil) { _, _ in
            guard provider == .zai else { return }
            Task {
                await registry.refresh(provider)
                await registry.loadCatalog(provider, force: true)
            }
        }
        .onChange(of: settings.isEnabled(provider)) { _, enabled in
            registry.cliMonitoringChanged(provider)
            if provider == .dsh, enabled {
                Task {
                    await registry.refresh(provider)
                    await registry.loadCatalog(provider)
                }
            }
        }
        .onChange(of: settings.binaryPath(for: provider)) { _, _ in
            registry.cliMonitoringChanged(provider)
        }
        .onChange(of: apiKey) { _, value in
            // Only an edit counts: loading the stored key into the field must not save or check it.
            guard provider.acceptsAPIKey, value != settings.apiKeyInput(for: provider) else { return }
            settings.setAPIKeyInput(value, for: provider)
            // The registry observes DeepSeek changes even when this page is closed.
            guard provider != .deepseek else { return }
            keyCheck?.cancel()
            keyCheck = Task {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                await registry.refresh(provider)
                await registry.loadCatalog(provider, force: true)
            }
        }
        .onChange(of: provider.acceptsAPIKey ? settings.apiKeyInput(for: provider) : nil) { _, value in
            guard let value, value != apiKey else { return }
            apiKey = value
        }
    }
}

/// Which archived chats the storage page shows, kept by the settings scroll so it resets
/// when the page changes; its search field and Delete all act on the same rows.
struct ArchiveFilter: Equatable {
    enum ChatType: CaseIterable {
        case all, chats, heads

        var title: String {
            switch self {
            case .all: "All chats"
            case .chats: "Chats"
            case .heads: "Sub-agents"
            }
        }
    }

    enum ProjectScope: Hashable {
        case all, project(UUID), none
    }

    var query = ""
    var chatType: ChatType = .all
    var project: ProjectScope = .all

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isActive: Bool { !trimmedQuery.isEmpty || chatType != .all || project != .all }

    /// The archive's projects, by name, for the project picker and the groups.
    static func projects(in archived: [ChatThread], from all: [Project]) -> [Project] {
        let ids = Set(archived.compactMap(\.projectID))
        return all.filter { ids.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func scope(of thread: ChatThread, known: Set<UUID>) -> ProjectScope {
        thread.projectID.flatMap { known.contains($0) ? .project($0) : nil } ?? .none
    }

    func matchesSearch(_ thread: ChatThread) -> Bool {
        let search = trimmedQuery
        guard !search.isEmpty else { return true }
        if thread.title.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        if let info = thread.hydra {
            if info.persona.name.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
            if info.task.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                return true
            }
        }
        return false
    }

    func apply(to archived: [ChatThread], known: Set<UUID>) -> [ChatThread] {
        archived.filter { thread in
            let matchesType = chatType == .all || (chatType == .heads ? thread.isHydraHead : !thread.isHydraHead)
            let matchesProject = project == .all || project == Self.scope(of: thread, known: known)
            return matchesType && matchesProject && matchesSearch(thread)
        }
    }
}
