import Foundation

struct ChimeraPick: Codable, Hashable, Sendable {
    var provider: ProviderKind
    var model: String?
    var effort: String?
    var briefLabel: String { [model, provider.displayName].compactMap { $0 }.joined(separator: " on ") }
}

struct ChimeraPreset: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var specialty: String
    var pick: ChimeraPick
    init(specialty: String, pick: ChimeraPick) {
        id = UUID()
        self.specialty = specialty
        self.pick = pick
    }
    private enum CodingKeys: String, CodingKey { case id, specialty, role, pick }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        specialty = try container.decodeIfPresent(String.self, forKey: .specialty)
            ?? container.decode(String.self, forKey: .role)
        pick = try container.decode(ChimeraPick.self, forKey: .pick)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(specialty, forKey: .specialty)
        try container.encode(pick, forKey: .pick)
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

    static func policy(_ launch: HydraLaunch) -> String {
        var hydra = launch
        hydra.isChimera = false
        let presets = launch.chimeraPresets.isEmpty ? "" : "\nThe user's model presets (number. model on provider: specialty):\n" + launch.chimeraPresets.joined(separator: "\n")
        let suggestions = " Give every entry a short role title. When one of the user's presets fits that role, add \"preset\": <its number> as a suggestion, combining different presets across roles as the job needs. Omit preset when none fits. The user confirms or changes every model in the casting card, so never name models elsewhere."
        return HydraPrompts.v2Policy(hydra)
            .replacingOccurrences(of: "[Hydra 2]", with: "[Chimera]")
            .replacingOccurrences(of: "```hydra", with: "```chimera")
            .replacingOccurrences(of: "[{\"task\":", with: "[{\"role\": \"short clear job title\", \"task\":")
            + "\nThe user casts a provider, model and effort for each role in a casting card before any heads start. Every new entry needs a short clear job title in \"role\"; never include model or profile fields. A continue entry keeps the head's earlier model." + suggestions + presets
            + "\nThis Chimera policy replaces any Hydra delegation rules given earlier in this conversation."
    }
}
