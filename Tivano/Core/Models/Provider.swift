import Foundation

enum ProviderGroup: String, CaseIterable, Identifiable, Sendable {
    case agentCLI
    case tivanoCode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agentCLI: "Agent CLIs"
        case .tivanoCode: "Tivano Code"
        }
    }

    var providers: [ProviderKind] { ProviderKind.alphabetical.filter { $0.group == self } }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case cursor
    case opencode
    case grok
    case deepseek
    case meta
    case zai
    case devin
    case antigravity
    case copilot
    case commandcode
    case pi
    case kimi
    case omp
    case dsh
    case minimaxCode

    /// A raw value read from storage; the retired `opencodeGo` means `opencode`.
    init?(storedValue raw: String) {
        self.init(rawValue: raw == "opencodeGo" ? "opencode" : raw)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let provider = Self(storedValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown provider: \(raw)")
        }
        self = provider
    }

    /// The order used by every provider list shown to the user.
    static let alphabetical: [ProviderKind] = allCases.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .grok: "Grok"
        case .deepseek: "DeepSeek"
        case .meta: "Meta"
        case .zai: "Z.ai"
        case .devin: "Devin"
        case .antigravity: "Antigravity"
        case .copilot: "Copilot"
        case .commandcode: "Command Code"
        case .pi: "Pi"
        case .omp: "omp"
        case .kimi: "Kimi Code"
        case .dsh: "DeepSeek Harness"
        case .minimaxCode: "MiniMax Code"
        }
    }

    /// English name of the program that runs the tool loop.
    var agentName: String {
        switch self {
        case .codex: "Codex CLI"
        case .claude: "Claude Code"
        case .cursor: "Cursor CLI"
        case .opencode: "OpenCode CLI"
        case .grok: "Grok Build"
        case .deepseek: "Tivano Code"
        case .meta: "Tivano Code"
        case .zai: "Tivano Code"
        case .devin: "Devin CLI"
        case .antigravity: "Antigravity CLI"
        case .copilot: "Copilot CLI"
        case .commandcode: "Command Code CLI"
        case .pi: "Pi CLI"
        case .omp: "omp CLI"
        case .kimi: "Kimi Code CLI"
        case .dsh: "dsh CLI"
        case .minimaxCode: "MiniMax Code CLI"
        }
    }

    /// Grouped by where the tool loop runs: an agent CLI the user installs, or Tivano Code.
    var group: ProviderGroup {
        switch self {
        case .deepseek, .meta, .zai: .tivanoCode
        case .codex, .claude, .cursor, .opencode, .grok, .devin, .antigravity, .copilot, .commandcode, .pi, .kimi, .omp, .dsh, .minimaxCode: .agentCLI
        }
    }

    /// English key for what the user signs in with or pays for, in the vendor's wording.
    var accountLabel: String {
        switch self {
        case .codex: "ChatGPT plan or API key"
        case .claude: "Claude plan or API key"
        case .cursor: "Cursor account"
        case .opencode: "Set up in OpenCode"
        case .grok: "Grok plan or API key"
        case .deepseek: "API key"
        case .meta: "API key"
        case .zai: "GLM Coding Plan"
        case .devin: "Devin account"
        case .antigravity: "Google account or API key"
        case .copilot: "Copilot plan or API key"
        case .commandcode: "Subscription or credits"
        case .pi: "Set up in Pi"
        case .omp: "Set up in omp"
        case .kimi: "Kimi membership or API key"
        case .dsh: "API key"
        case .minimaxCode: "Token Plan or API key"
        }
    }

    /// Agent name and localized account label for display.
    var routeSummary: String { agentName + " · " + AppText.localized(accountLabel) }

    var executableName: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .cursor: "cursor-agent"
        case .opencode: "opencode"
        case .grok: "grok"
        case .deepseek: ""
        case .meta: ""
        case .zai: ""
        case .devin: "devin"
        case .antigravity: "agy"
        case .copilot: "copilot"
        case .commandcode: "cmd"
        case .pi: "pi"
        case .omp: "omp"
        case .kimi: "kimi"
        case .dsh: "dsh"
        case .minimaxCode: "mcode"
        }
    }

    var iconName: String { self == .dsh ? "provider-deepseek" : "provider-\(rawValue)" }

    var loginCommand: String {
        switch self {
        case .codex: "codex login"
        case .claude: "claude auth login"
        case .cursor: "cursor-agent login"
        case .opencode: "opencode auth login"
        case .grok: "grok login"
        case .deepseek: "DEEPSEEK_API_KEY=sk-..."
        case .meta: "MODEL_API_KEY=..."
        case .zai: "ZAI_API_KEY=..."
        case .devin: "devin auth login"
        case .antigravity: "agy"
        case .copilot: "copilot login"
        case .commandcode: "cmd login"
        case .pi: "pi"
        case .omp: "omp login"
        case .kimi: "kimi login"
        case .dsh: ""
        case .minimaxCode: "mcode login"
        }
    }

    var installURL: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        case .claude: URL(string: "https://claude.com/product/claude-code")!
        case .cursor: URL(string: "https://cursor.com/cli")!
        case .opencode: URL(string: "https://opencode.ai")!
        case .grok: URL(string: "https://x.ai/cli")!
        case .deepseek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .meta: URL(string: "https://dev.meta.ai/")!
        case .zai: ZaiRegion.current.keyPageURL
        case .devin: URL(string: "https://cli.devin.ai")!
        case .antigravity: URL(string: "https://antigravity.google/docs/cli/overview")!
        case .copilot: URL(string: "https://github.com/github/copilot-cli")!
        case .commandcode: URL(string: "https://commandcode.ai/docs/quickstart")!
        case .pi: URL(string: "https://pi.dev/docs/latest")!
        case .omp: URL(string: "https://omp.sh")!
        case .kimi: URL(string: "https://www.kimi.com/code/docs/en/kimi-code-cli/")!
        case .dsh: URL(string: "https://www.deepseek.com/en/harness/")!
        case .minimaxCode: URL(string: "https://agent.minimax.io/docs/cli/quick-start")!
        }
    }

    /// API-key providers talk to their cloud API directly instead of a local CLI.
    var isAPIKeyBased: Bool { self == .deepseek || self == .meta || self == .zai }

    /// Driven over the Agent Client Protocol by `ACPSession`.
    var usesACP: Bool { self == .cursor || self == .opencode || self == .grok || self == .devin || self == .kimi || self == .dsh || self == .minimaxCode }

    /// Providers with an API key field in Settings: the API-key providers, which need one,
    /// and Command Code, whose CLI takes a Studio key through `COMMAND_CODE_API_KEY` as an
    /// alternative to `cmd login`.
    var acceptsAPIKey: Bool { isAPIKeyBased || self == .commandcode }

    /// Host shown in Settings for API-key providers, e.g. "api.meta.ai/v1".
    var apiHost: String? {
        switch self {
        case .deepseek: "api.deepseek.com"
        case .meta: "api.meta.ai/v1"
        case .zai: ZaiRegion.current.apiHost
        default: nil
        }
    }

    /// Where the dashboard key lives, for the Settings detail line.
    var apiKeySource: String? {
        switch self {
        case .deepseek: "platform.deepseek.com"
        case .meta: "dev.meta.ai"
        case .zai: ZaiRegion.current.apiKeySource
        case .commandcode: "commandcode.ai/studio"
        default: nil
        }
    }

    /// Env var fallback read when no key is stored in Settings.
    var apiKeyEnvVar: String? {
        switch self {
        case .deepseek: "DEEPSEEK_API_KEY"
        case .meta: "MODEL_API_KEY"
        case .zai: "ZAI_API_KEY"
        case .commandcode: "COMMAND_CODE_API_KEY"
        default: nil
        }
    }

    /// Whether the provider can drop later turns from its own conversation.
    var supportsRewind: Bool { self == .codex || self == .claude || self == .copilot || self == .omp }

    /// Whether the app runs the provider's `/compact` itself. The sessions that speak the
    /// provider's own command are handled locally; for every other provider the command
    /// goes to the tool, which knows what to do with it.
    var supportsCompact: Bool {
        switch self {
        case .codex, .claude, .copilot, .deepseek, .meta, .zai, .pi, .omp: true
        default: false
        }
    }

    /// Headless stream-json only carries text: the TUI pastes images, but a
    /// streaming session rejects non-text blocks, so image attachments stay off.
    var supportsImages: Bool { self != .grok && self != .antigravity && self != .dsh && self != .minimaxCode }

    func supports(_ mode: RuntimeMode) -> Bool {
        switch self {
        case .omp: mode != .auto
        case .dsh: mode == .autoAcceptEdits || mode == .fullAccess
        default: true
        }
    }

    func supported(_ mode: RuntimeMode) -> RuntimeMode { supports(mode) ? mode : .autoAcceptEdits }
}

enum RuntimeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case supervised
    case autoAcceptEdits
    case auto
    case fullAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .supervised: "Supervised"
        case .autoAcceptEdits: "Auto-accept edits"
        case .auto: "Auto"
        case .fullAccess: "Full access"
        }
    }

    var summary: String {
        switch self {
        case .supervised: "Asks before commands and file changes"
        case .autoAcceptEdits: "Edits files freely, asks before other actions"
        case .auto: "The provider's reviewer approves routine actions"
        case .fullAccess: "Runs commands and edits without asking"
        }
    }

    var symbol: String {
        switch self {
        case .supervised: "hand.raised"
        case .autoAcceptEdits: "pencil.line"
        case .auto: "wand.and.sparkles"
        case .fullAccess: "key"
        }
    }
}

enum InteractionMode: String, Codable, Sendable {
    case build
    case plan
}

enum WorkspaceMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case worktree

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local: "Local"
        case .worktree: "New worktree"
        }
    }
}

struct ModelOption: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var detail: String?
    var efforts: [String]
    var defaultEffort: String?
    var isDefault: Bool
    /// The service tier that makes this model fast, when its provider offers one.
    var fastTier: String?
    /// The provider's own ids behind this one row, when the provider lists every effort
    /// and Fast variant as a model of its own (Devin, Grok's Fast). Empty for a row that
    /// is the provider's model as is. See `ModelFamilies`.
    var variants: [ModelVariant]

    init(
        id: String,
        name: String,
        detail: String? = nil,
        efforts: [String] = [],
        defaultEffort: String? = nil,
        isDefault: Bool = false,
        fastTier: String? = nil,
        variants: [ModelVariant] = []
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.isDefault = isDefault
        self.fastTier = fastTier
        self.variants = variants
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        efforts = try container.decodeIfPresent([String].self, forKey: .efforts) ?? []
        defaultEffort = try container.decodeIfPresent(String.self, forKey: .defaultEffort)
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        fastTier = try container.decodeIfPresent(String.self, forKey: .fastTier)
        variants = try container.decodeIfPresent([ModelVariant].self, forKey: .variants) ?? []
    }

    var supportsFast: Bool { fastTier != nil }

    /// The id the provider takes for this row run at an effort and speed: the row's own
    /// id, or for a row of variants the one that matches. A missing combination (no Fast
    /// for that effort, say) falls back to the nearest effort at the speed asked for, then
    /// to the other speed, so the provider is never sent an id it did not list.
    func providerID(effort: String?, fastMode: Bool) -> String {
        guard !variants.isEmpty else { return id }
        let sameSpeed = variants.filter { $0.isFast == fastMode }
        let pool = sameSpeed.isEmpty ? variants : sameSpeed
        guard let wanted = effort ?? defaultEffort else { return pool[0].id }
        if let exact = pool.first(where: { $0.effort == wanted }) { return exact.id }
        guard let rank = Self.effortRank(wanted) else { return pool[0].id }
        let nearest = pool.min { lhs, rhs in
            abs((lhs.effort.flatMap(Self.effortRank) ?? rank) - rank) < abs((rhs.effort.flatMap(Self.effortRank) ?? rank) - rank)
        }
        return (nearest ?? pool[0]).id
    }

    /// The variant behind a provider id this row stands for, when it is one of its variants.
    func variant(_ providerID: String) -> ModelVariant? {
        variants.first { $0.id == providerID }
    }

    /// The name as the picker shows it, such as "5.6 Terra" for "GPT-5.6-Terra".
    var shortName: String {
        var trimmed = name
        if trimmed.lowercased().hasPrefix("gpt-") { trimmed = String(trimmed.dropFirst(4)) }
        return trimmed.replacingOccurrences(of: "-", with: " ")
    }

    /// The name at its shortest, for the composer chip, where the provider's icon already
    /// says whose model it is: "Opus" for "Opus (1M context)", "3.8 Flash" for "Gemini 3.8
    /// Flash", "V4.1 Flash" as is. Parentheticals and dashed or dotted descriptions go, then
    /// the vendor's own name when it leads. The picker keeps `shortName` and `detail`.
    var chipName: String {
        var text = shortName
        for separator in [" (", " · ", " — ", " – ", " - ", ": "] {
            if let range = text.range(of: separator) { text = String(text[..<range.lowerBound]) }
        }
        let lowered = text.lowercased()
        for vendor in ["claude ", "gpt ", "gemini ", "deepseek ", "openai ", "anthropic ", "google ", "meta ", "muse ", "glm "] {
            if lowered.hasPrefix(vendor), text.count > vendor.count {
                text = String(text.dropFirst(vendor.count))
                break
            }
        }
        let cleaned = text.trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? shortName : cleaned
    }

    /// Where an effort sits on the scale, low to high; nil for a level the scale does not know.
    static func effortRank(_ effort: String) -> Int? {
        [
            "none": 0, "minimal": 1, "low": 2, "medium": 3, "high": 4,
            "xhigh": 5, "extra-high": 5, "extra_high": 5, "extra high": 5, "max": 6, "ultra": 6,
        ][effort.lowercased()]
    }

    /// The scale low to high, whatever order the agent lists it in: Grok's ACP advertises
    /// its levels from extra high down to low, and the slider (see `EffortSlider`) reads
    /// the list left to right as low to high, so its knob sat at Low for the highest. A
    /// level the ranks do not know keeps its place among its neighbours.
    static func orderedEfforts(_ values: [String]) -> [String] {
        let ranked = values.enumerated().map { (offset: $0.offset, value: $0.element, rank: effortRank($0.element)) }
        guard ranked.count(where: { $0.rank != nil }) > 1 else { return values }
        return ranked.sorted { lhs, rhs in
            switch (lhs.rank, rhs.rank) {
            case (let l?, let r?) where l != r: return l < r
            default: return lhs.offset < rhs.offset
            }
        }.map(\.value)
    }

    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "xhigh", "extra-high": "Extra High"
        case "": "Default"
        default: effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

extension Array where Element == ModelOption {
    /// A-Z by the name the picker shows, numbers in natural order. Each name is built once:
    /// `shortName` allocates, and a sort of six hundred rows would otherwise build it thousands of times.
    func sortedByName() -> [ModelOption] {
        map { (name: $0.shortName, option: $0) }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return order == .orderedSame ? lhs.option.id < rhs.option.id : order == .orderedAscending
            }
            .map(\.option)
    }
}

/// One of the provider's own ids behind a row of variants: the effort and speed it runs at.
struct ModelVariant: Codable, Hashable, Sendable {
    var id: String
    /// Nil when the variants differ in speed alone and the effort is a setting of its own (Grok).
    var effort: String?
    var isFast: Bool
}

struct SlashCommand: Hashable, Identifiable, Sendable {
    var name: String
    var detail: String
    var isBuiltIn: Bool = false
    var skillPath: String?

    var id: String { name }

    static func name(in text: String) -> String? {
        guard text.first == "/" || text.first == "$" else { return nil }
        return text.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    static func suggestions(_ commands: [Self], matching query: String, recent: [String]) -> [Self] {
        let needle = query.lowercased()
        let ranks = Dictionary(recent.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        var seen = Set<String>()
        // Lowercased once per command, not once per comparison of the sort.
        var matched: [(command: Self, name: String, prefixed: Bool, rank: Int)] = []
        matched.reserveCapacity(commands.count)
        for command in commands where seen.insert(command.name).inserted {
            let name = command.name.lowercased()
            guard needle.isEmpty || name.contains(needle) else { continue }
            matched.append((command, name, name.hasPrefix(needle), ranks[command.name] ?? Int.max))
        }
        matched.sort { lhs, rhs in
            if lhs.prefixed != rhs.prefixed { return lhs.prefixed }
            return lhs.rank == rhs.rank ? lhs.name < rhs.name : lhs.rank < rhs.rank
        }
        return matched.map(\.command)
    }

    func codexInput(for text: String) -> [JSONValue] {
        guard let skillPath, Self.name(in: text) == name else {
            return [["type": "text", "text": .string(text)]]
        }
        return [
            ["type": "text", "text": .string("$" + text.dropFirst())],
            ["type": "skill", "name": .string(name), "path": .string(skillPath)],
        ]
    }

    static func claudeCommands(_ entries: [JSONValue]) -> [Self] {
        entries.compactMap { entry in
            guard let name = entry["name"]?.string ?? entry.string else { return nil }
            return Self(name: name, detail: entry["description"]?.string ?? "Claude Code command")
        }
    }

    static func codexSkills(_ result: JSONValue) -> [Self] {
        (result["data"]?.array ?? []).flatMap { entry in
            (entry["skills"]?.array ?? []).compactMap { skill in
                guard skill["enabled"]?.bool != false,
                      let name = skill["name"]?.string, let path = skill["path"]?.string else { return nil }
                return Self(name: name, detail: skill["interface"]?["shortDescription"]?.string ?? skill["description"]?.string ?? "", skillPath: path)
            }
        }
    }
}
