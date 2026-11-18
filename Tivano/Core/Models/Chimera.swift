import Foundation

struct ChimeraPick: Codable, Hashable, Sendable {
    var provider: ProviderKind
    var model: String?
    var effort: String?
    var briefLabel: String { [model, provider.displayName].compactMap { $0 }.joined(separator: " on ") }
}

enum ChimeraBuiltin: String, Codable, CaseIterable, Sendable {
    case scout, builder, reviewer, designer, researcher, writer

    /// English catalog key; the UI localizes it.
    var title: String {
        switch self {
        case .scout: "Scout"
        case .builder: "Builder"
        case .reviewer: "Reviewer"
        case .designer: "Designer"
        case .researcher: "Researcher"
        case .writer: "Writer"
        }
    }

    /// English catalog key; sent to the lead in English and shown in the UI when not overridden.
    var defaultPrompt: String {
        switch self {
        case .scout: "You explore the codebase fast. Read only, edit nothing. Return the relevant files, entry points and a short summary."
        case .builder: "You implement a clearly specified feature or fix. Keep the change narrow and follow the project's existing patterns."
        case .reviewer: "You review changes before merge. Read only, edit nothing. List real bugs by severity with file and line."
        case .designer: "You build and polish UI and interactions. Reuse the project's existing components and styles."
        case .researcher: "You research libraries and APIs from source code and official docs. Read only. Answer with sources."
        case .writer: "You polish copy, summarize and organize reasoning. Keep it clear and concise."
        }
    }
}

struct ChimeraPreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var name: String = ""
    var specialty: String
    var pick: ChimeraPick?
    var builtin: ChimeraBuiltin?
    var enabled: Bool = true

    init(name: String = "", specialty: String, pick: ChimeraPick?, builtin: ChimeraBuiltin? = nil, enabled: Bool = true) {
        id = UUID()
        self.name = name
        self.specialty = specialty
        self.pick = pick
        self.builtin = builtin
        self.enabled = enabled
    }

    init(builtin: ChimeraBuiltin) {
        id = UUID()
        name = ""
        specialty = ""
        pick = nil
        self.builtin = builtin
        enabled = true
    }

    var effectivePrompt: String { specialty.trimmed.nilIfEmpty ?? builtin?.defaultPrompt ?? "" }
    var isUsable: Bool { enabled && !effectivePrompt.trimmed.isEmpty }
    var briefName: String { name.trimmed.nilIfEmpty ?? builtin?.title ?? "" }

    private enum CodingKeys: String, CodingKey { case id, name, specialty, role, pick, builtin, enabled }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        specialty = try container.decodeIfPresent(String.self, forKey: .specialty)
            ?? container.decodeIfPresent(String.self, forKey: .role)
            ?? ""
        pick = try container.decodeIfPresent(ChimeraPick.self, forKey: .pick)
        builtin = try container.decodeIfPresent(ChimeraBuiltin.self, forKey: .builtin)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(specialty, forKey: .specialty)
        try container.encodeIfPresent(pick, forKey: .pick)
        try container.encodeIfPresent(builtin, forKey: .builtin)
        try container.encode(enabled, forKey: .enabled)
    }
}

struct ChimeraCastingRow: Identifiable, Hashable, Sendable {
    var id: UUID
    var role: String
    var task: String
    var prefill: ChimeraPick?
}

struct ChimeraCasting: Hashable, Sendable {
    var batchID: UUID
    var rows: [ChimeraCastingRow]
}

enum ChimeraPrompts {
    static func roleKey(_ role: String) -> String { role.trimmed.lowercased() }

    static func identityLine(number: Int, preset: ChimeraPreset) -> String? {
        guard preset.isUsable else { return nil }
        let name = preset.briefName.nilIfEmpty ?? "Unnamed"
        let prompt = preset.effectivePrompt
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmed
            .prefix(240)
        let model = preset.pick?.briefLabel ?? "your own model"
        return "\(number). \(name): \(prompt), \(model)"
    }

    static func policy(_ launch: HydraLaunch) -> String {
        var hydra = launch
        hydra.isChimera = false
        let presets = launch.chimeraPresets.isEmpty ? "" : "\nThe user's sub-agent identities (number. name: what it does, model):\n" + launch.chimeraPresets.joined(separator: "\n")
        let suggestions = " Give every entry a short role title. When one of the user's identities fits that role, add \"identity\": <its number> and use the identity's name as the role title; combine different identities across roles as the job needs. Omit identity when none fits; that role runs on your own model. Never name models elsewhere."
        let dispatch = launch.chimeraAutoDispatch
            ? "\nHeads go out at once without the user's confirmation, so pick identities carefully."
            : "\nThe user confirms or changes each role's model in a casting card before heads start."
        return HydraPrompts.v2Policy(hydra)
            .replacingOccurrences(of: "[Hydra 2]", with: "[Chimera]")
            .replacingOccurrences(of: "```hydra", with: "```chimera")
            .replacingOccurrences(of: "[{\"task\":", with: "[{\"role\": \"short clear job title\", \"task\":")
            + "\nEvery new entry needs a short clear job title in \"role\"; never include model or profile fields. A continue entry keeps the head's earlier model." + suggestions + dispatch + presets
            + "\nThis Chimera policy replaces any Hydra delegation rules given earlier in this conversation."
    }
}
