import Foundation

/// ACP form elicitation, including Kimi Code's multi-question / multi-select schema.
/// Source: Kimi Code CLI's acp-server/question.ts and the ACP elicitation contract.
struct ACPQuestionForm {
    let questions: [QuestionRequest.Question]
    let required: Set<String>
    private let wireValues: [String: [String: String]]

    init?(_ params: JSONValue, usesOptionTitles: Bool = false) {
        guard params["mode"]?.string == nil || params["mode"]?.string == "form",
              let schema = params["requestedSchema"], schema["type"]?.string == "object",
              let properties = schema["properties"]?.object, !properties.isEmpty else { return nil }
        required = Set((schema["required"]?.array ?? []).compactMap(\.string))
        guard required.isSubset(of: Set(properties.keys)) else { return nil }
        var parsed: [QuestionRequest.Question] = []
        var mappings: [String: [String: String]] = [:]
        for key in properties.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            guard let field = properties[key], let type = field["type"]?.string,
                  type == "string" || type == "array" else { return nil }
            let multiple = type == "array"
            let choicesSchema = multiple ? field["items"] ?? .null : field
            let variants = choicesSchema["oneOf"]?.array ?? choicesSchema["anyOf"]?.array
            let choices: [QuestionRequest.Choice]
            if let variants {
                let mapped = variants.compactMap { option -> QuestionRequest.Choice? in
                    guard let value = option["const"]?.string else { return nil }
                    let label = usesOptionTitles ? (option["title"]?.string ?? value) : value
                    if usesOptionTitles {
                        guard mappings[key]?[label] == nil else { return nil }
                        mappings[key, default: [:]][label] = value
                    }
                    return .init(label: label, detail: option["description"]?.string)
                }
                guard mapped.count == variants.count else { return nil }
                choices = mapped
            } else {
                let values = choicesSchema["enum"]?.array ?? []
                guard values.allSatisfy({ $0.string != nil }) else { return nil }
                let labels = choicesSchema["enumNames"]?.array ?? []
                choices = values.enumerated().map { index, value in
                    .init(label: value.string!, detail: index < labels.count ? labels[index].string : nil)
                }
            }
            guard !multiple || !choices.isEmpty else { return nil }
            let title = field["title"]?.string ?? key
            let detail = field["description"]?.string ?? params["message"]?.string ?? title
            parsed.append(.init(
                id: key, header: title, prompt: detail, choices: choices,
                allowsMultiple: multiple, allowsOther: choices.isEmpty,
                isSecret: field["format"]?.string == "password"
            ))
        }
        questions = parsed
        wireValues = mappings
    }

    func response(answers: [String: [String]]) -> JSONValue? {
        var content: [String: JSONValue] = [:]
        for question in questions {
            let values = answers[question.id] ?? []
            if values.isEmpty {
                guard !required.contains(question.id) else { return nil }
                continue
            }
            guard question.allowsMultiple || values.count == 1,
                  question.allowsOther || values.allSatisfy({ value in question.choices.contains { $0.label == value } }) else { return nil }
            // MiniMax's schema titles are for people; `const` IDs go back on the wire.
            let encoded = values.map { wireValues[question.id]?[$0] ?? $0 }
            content[question.id] = question.allowsMultiple ? .array(encoded.map(JSONValue.string)) : .string(encoded[0])
        }
        return ["action": "accept", "content": .object(content)]
    }
}
