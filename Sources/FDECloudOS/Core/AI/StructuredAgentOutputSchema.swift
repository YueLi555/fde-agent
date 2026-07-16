import Foundation

enum ReadOnlyNextActionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case tool
    case finalize
    case clarify
    case block
}

struct ReadOnlyNextActionAudit: Hashable, Sendable {
    var sourceContract: String
    var safeModelOutputJSON: String
    var decodedStepIDs: [String]
    var decodedStepKinds: [String]
    var decodedStepToolCallIDs: [String]
    var decodedToolCallIDs: [String]
    var returnedCompletePlan: Bool
    var normalizationNotes: [String]
    var unexpectedFields: [String]
}

struct ReadOnlyNextAction: Hashable, Sendable {
    var decision: ReadOnlyNextActionKind?
    var rawDecision: String
    var toolCalls: [ToolCall]
    var finalAnswer: String?
    var clarification: String?
    var blockerReason: String?
    var reasoningSummary: String?
    var audit: ReadOnlyNextActionAudit

    init(
        decision: ReadOnlyNextActionKind?,
        rawDecision: String? = nil,
        toolCalls: [ToolCall] = [],
        finalAnswer: String? = nil,
        clarification: String? = nil,
        blockerReason: String? = nil,
        reasoningSummary: String? = nil,
        audit: ReadOnlyNextActionAudit = ReadOnlyNextActionAudit(
            sourceContract: "native",
            safeModelOutputJSON: "{}",
            decodedStepIDs: [],
            decodedStepKinds: [],
            decodedStepToolCallIDs: [],
            decodedToolCallIDs: [],
            returnedCompletePlan: false,
            normalizationNotes: [],
            unexpectedFields: []
        )
    ) {
        self.decision = decision
        self.rawDecision = rawDecision ?? decision?.rawValue ?? ""
        self.toolCalls = toolCalls
        self.finalAnswer = finalAnswer
        self.clarification = clarification
        self.blockerReason = blockerReason
        self.reasoningSummary = reasoningSummary
        self.audit = audit
    }

    init(legacyOutput output: StructuredAgentOutput) {
        let toolSteps = output.plan.filter { $0.kind == .tool }
        let reasoningSteps = output.plan.filter { $0.kind == .reasoning }
        let finalizations = output.plan.filter { $0.kind == .finalization }
        let clarifications = output.plan.filter { $0.kind == .clarification }
        let blockers = output.plan.filter { $0.kind == .blocker }
        var notes: [String] = []
        var selectedCalls: [ToolCall] = []
        var selectedDecision: ReadOnlyNextActionKind?
        var finalAnswer: String?
        var clarification: String?
        var blockerReason: String?

        if !toolSteps.isEmpty {
            selectedDecision = .tool
            let referencedIDs = toolSteps.compactMap(\.toolCallID)
            selectedCalls = referencedIDs.compactMap { id in
                let matches = output.toolCalls.filter { $0.id == id }
                return matches.count == 1 ? matches[0] : nil
            }
            if selectedCalls.isEmpty {
                selectedCalls = output.toolCalls
            }
            let ignoredIDs = output.toolCalls.map(\.id).filter { !selectedCalls.map(\.id).contains($0) }
            if !ignoredIDs.isEmpty {
                notes.append("Ignored tool calls referenced only by non-tool metadata: \(ignoredIDs.joined(separator: ", ")).")
            }
            let substantiveFinalizations = finalizations.filter { Self.looksLikeCompletedAnswer($0.intent) }
            if let answer = substantiveFinalizations.first?.intent {
                finalAnswer = answer
            } else if !finalizations.isEmpty {
                notes.append("Treated a finalization title/directive without a completed answer as metadata.")
            }
            let referencedByMetadata = (reasoningSteps + finalizations).compactMap(\.toolCallID)
            if !referencedByMetadata.isEmpty {
                notes.append("Removed non-executable toolCallID metadata: \(referencedByMetadata.joined(separator: ", ")).")
            }
        } else {
            let terminalKinds = (finalizations.isEmpty ? 0 : 1)
                + (clarifications.isEmpty ? 0 : 1)
                + (blockers.isEmpty ? 0 : 1)
            if terminalKinds == 1, let step = finalizations.first {
                selectedDecision = .finalize
                finalAnswer = step.intent
            } else if terminalKinds == 1, let step = clarifications.first {
                selectedDecision = .clarify
                clarification = step.intent
            } else if terminalKinds == 1, let step = blockers.first {
                selectedDecision = .block
                blockerReason = step.intent
            }
            selectedCalls = output.toolCalls
        }

        let hasIncompatibleTerminal = !toolSteps.isEmpty && (
            finalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || !clarifications.isEmpty
                || !blockers.isEmpty
        )
        let returnedCompletePlan = toolSteps.count > 1
            || hasIncompatibleTerminal
            || (toolSteps.isEmpty && ((finalizations.isEmpty ? 0 : 1) + (clarifications.isEmpty ? 0 : 1) + (blockers.isEmpty ? 0 : 1) > 1))
        let safeJSON = ReadOnlyNextActionSchema.redactedJSONText((try? JSONCoding.encode(output)) ?? "{}")
        self.init(
            decision: selectedDecision,
            toolCalls: selectedCalls,
            finalAnswer: finalAnswer,
            clarification: clarification,
            blockerReason: blockerReason,
            reasoningSummary: reasoningSteps.map(\.intent).filter { !$0.isEmpty }.joined(separator: " | ").nilIfEmpty,
            audit: ReadOnlyNextActionAudit(
                sourceContract: "legacy_structured_agent_output",
                safeModelOutputJSON: safeJSON,
                decodedStepIDs: output.plan.map(\.id),
                decodedStepKinds: output.plan.map { $0.kind.rawValue },
                decodedStepToolCallIDs: output.plan.map { $0.toolCallID ?? "null" },
                decodedToolCallIDs: output.toolCalls.map(\.id),
                returnedCompletePlan: returnedCompletePlan,
                normalizationNotes: notes,
                unexpectedFields: []
            )
        )
    }

    private static func looksLikeCompletedAnswer(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()
        let directivePrefixes = [
            "summarize", "prepare", "provide", "return", "write", "create", "generate",
            "总结", "汇总", "生成", "提供", "撰写"
        ]
        if trimmed.count < 180, directivePrefixes.contains(where: { lower.hasPrefix($0) }) {
            return false
        }
        return trimmed.count >= 80 || trimmed.contains("\n")
    }
}

enum ReadOnlyNextActionSchema {
    private static let keys: Set<String> = [
        "decision", "tool_call", "tool_calls", "final_answer", "clarification", "blocker_reason", "reasoning_summary"
    ]

    static func openAIResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "name": "read_only_next_action",
            "description": "Exactly one observation-stage read-only next action or terminal decision.",
            "strict": true,
            "schema": jsonSchema()
        ]
    }

    static func jsonSchema() -> [String: Any] {
        let toolCall: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": ["id", "type", "command", "arguments", "workingDirectory", "requiresApproval"],
            "properties": [
                "id": ["type": "string"],
                "type": ["type": "string", "enum": [ToolType.api.rawValue]],
                "command": ["type": "string", "enum": ReadOnlyInspectionPolicy.orderedAllowedTools],
                "arguments": ["type": "array", "items": ["type": "string"]],
                "workingDirectory": ["type": ["string", "null"]],
                "requiresApproval": ["type": "boolean"]
            ]
        ]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["decision", "tool_call", "final_answer", "clarification", "blocker_reason", "reasoning_summary"],
            "properties": [
                "decision": ["type": "string", "enum": ReadOnlyNextActionKind.allCases.map(\.rawValue)],
                "tool_call": ["anyOf": [toolCall, ["type": "null"]]],
                "final_answer": ["type": ["string", "null"]],
                "clarification": ["type": ["string", "null"]],
                "blocker_reason": ["type": ["string", "null"]],
                "reasoning_summary": ["type": ["string", "null"]]
            ]
        ]
    }

    static func decodeJSONText(_ json: String) throws -> ReadOnlyNextAction {
        guard let data = json.data(using: .utf8) else {
            throw StructuredOutputSchemaError.malformedJSON("Invalid UTF-8 payload.")
        }
        let rawObject = try JSONSerialization.jsonObject(with: data)
        guard let object = rawObject as? [String: Any] else {
            throw StructuredOutputSchemaError.expectedObject("$")
        }
        if object["decision"] == nil, object["plan"] != nil {
            try StructuredAgentOutputSchema.validateJSONObject(object)
            return ReadOnlyNextAction(legacyOutput: try JSONCoding.decode(StructuredAgentOutput.self, from: json))
        }

        let rawDecision = object["decision"] as? String ?? ""
        var calls: [ToolCall] = []
        var notes: [String] = []
        if let singular = object["tool_call"], !(singular is NSNull) {
            calls.append(try decode(ToolCall.self, from: singular))
        }
        if let plural = object["tool_calls"] as? [Any] {
            calls.append(contentsOf: try plural.map { try decode(ToolCall.self, from: $0) })
            if plural.count == 1, object["tool_call"] == nil || object["tool_call"] is NSNull {
                notes.append("Normalized plural tool_calls wrapper containing one call to singular tool_call.")
            }
        }
        return ReadOnlyNextAction(
            decision: ReadOnlyNextActionKind(rawValue: rawDecision),
            rawDecision: rawDecision,
            toolCalls: calls,
            finalAnswer: nullableString(object["final_answer"]),
            clarification: nullableString(object["clarification"]),
            blockerReason: nullableString(object["blocker_reason"]),
            reasoningSummary: nullableString(object["reasoning_summary"]),
            audit: ReadOnlyNextActionAudit(
                sourceContract: "read_only_next_action",
                safeModelOutputJSON: redactedJSONText(json),
                decodedStepIDs: [],
                decodedStepKinds: [],
                decodedStepToolCallIDs: [],
                decodedToolCallIDs: calls.map(\.id),
                returnedCompletePlan: object["plan"] != nil,
                normalizationNotes: notes,
                unexpectedFields: Set(object.keys).subtracting(keys).sorted()
            )
        )
    }

    static func redactedJSONText(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let redacted = try? JSONSerialization.data(withJSONObject: redact(object), options: [.sortedKeys]) else {
            return "{}"
        }
        return String(String(data: redacted, encoding: .utf8)?.prefix(20_000) ?? "{}")
    }

    private static func nullableString(_ value: Any?) -> String? {
        guard !(value is NSNull) else { return nil }
        return value as? String
    }

    private static func decode<T: Decodable>(_ type: T.Type, from object: Any) throws -> T {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw StructuredOutputSchemaError.invalidType(path: "$.tool_call", expected: "an object")
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return try JSONDecoder().decode(type, from: data)
    }

    private static func redact(_ value: Any, key: String? = nil) -> Any {
        if let object = value as? [String: Any] {
            var result: [String: Any] = [:]
            for (childKey, childValue) in object {
                result[childKey] = redact(childValue, key: childKey)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map { redact($0, key: key) }
        }
        guard let string = value as? String else { return value }
        if key == "workingDirectory", !string.isEmpty {
            return "<working-directory-redacted>"
        }
        let parts = string.split(separator: "=", maxSplits: 1).map(String.init)
        if string.hasPrefix("/") || (parts.count == 2 && parts[1].hasPrefix("/")) {
            return parts.count == 2 ? "\(parts[0])=<absolute-path-redacted>" : "<absolute-path-redacted>"
        }
        return AgentPresentationSanitizer.safeContent(string, fallback: "<invalid>")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum StructuredOutputSchemaError: LocalizedError, Equatable {
    case expectedObject(String)
    case missingRequiredKey(String)
    case unexpectedKey(String)
    case invalidType(path: String, expected: String)
    case invalidEnumValue(path: String, value: String)
    case malformedJSON(String)

    var errorDescription: String? {
        switch self {
        case .expectedObject(let path):
            return "Planner output JSON schema validation failed: expected object at \(path)."
        case .missingRequiredKey(let key):
            return "Planner output JSON schema validation failed: missing required key \(key)."
        case .unexpectedKey(let key):
            return "Planner output JSON schema validation failed: unexpected key \(key)."
        case .invalidType(let path, let expected):
            return "Planner output JSON schema validation failed: \(path) must be \(expected)."
        case .invalidEnumValue(let path, let value):
            return "Planner output JSON schema validation failed: \(path) has unsupported value \(value)."
        case .malformedJSON(let detail):
            return "Planner output JSON schema validation failed: \(detail)"
        }
    }
}

enum StructuredAgentOutputSchema {
    static func openAIResponseFormat() -> [String: Any] {
        [
            "type": "json_schema",
            "name": "structured_agent_output",
            "description": "A schema-valid FDE Cloud OS execution plan.",
            "strict": true,
            "schema": jsonSchema()
        ]
    }

    static func jsonSchema() -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "required": ["plan", "actions", "tool_calls", "risks", "confidence"],
            "properties": [
                "plan": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "title", "intent", "kind", "toolCallID", "requiresApproval", "retryBudget"],
                        "properties": [
                            "id": ["type": "string"],
                            "title": ["type": "string"],
                            "intent": ["type": "string"],
                            "kind": [
                                "type": "string",
                                "enum": PlanStepKind.allCases.map(\.rawValue)
                            ],
                            "toolCallID": ["type": ["string", "null"]],
                            "requiresApproval": ["type": "boolean"],
                            "retryBudget": ["type": "integer"]
                        ]
                    ]
                ],
                "actions": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "title", "agent", "stepID"],
                        "properties": [
                            "id": ["type": "string"],
                            "title": ["type": "string"],
                            "agent": [
                                "type": "string",
                                "enum": AgentKind.allCases.map(\.rawValue)
                            ],
                            "stepID": ["type": ["string", "null"]]
                        ]
                    ]
                ],
                "tool_calls": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "type", "command", "arguments", "workingDirectory", "requiresApproval"],
                        "properties": [
                            "id": ["type": "string"],
                            "type": [
                                "type": "string",
                                "enum": ToolType.allCases.map(\.rawValue)
                            ],
                            "command": ["type": "string"],
                            "arguments": [
                                "type": "array",
                                "items": ["type": "string"]
                            ],
                            "workingDirectory": ["type": ["string", "null"]],
                            "requiresApproval": ["type": "boolean"]
                        ]
                    ]
                ],
                "risks": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["id", "title", "severity", "mitigation"],
                        "properties": [
                            "id": ["type": "string"],
                            "title": ["type": "string"],
                            "severity": [
                                "type": "string",
                                "enum": RiskSeverity.allCases.map(\.rawValue)
                            ],
                            "mitigation": ["type": "string"]
                        ]
                    ]
                ],
                "confidence": ["type": "number"]
            ]
        ]
    }

    static func validateJSONText(_ json: String) throws {
        guard let data = json.data(using: .utf8) else {
            throw StructuredOutputSchemaError.malformedJSON("Invalid UTF-8 payload.")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw StructuredOutputSchemaError.malformedJSON(error.localizedDescription)
        }

        try validateJSONObject(object)
    }

    static func validateJSONObject(_ object: Any) throws {
        let root = try requireObject(
            object,
            path: "$",
            requiredKeys: ["plan", "actions", "tool_calls", "risks", "confidence"]
        )
        try validateArray(root["plan"], path: "$.plan", itemValidator: validatePlanStep)
        try validateArray(root["actions"], path: "$.actions", itemValidator: validateAction)
        try validateArray(root["tool_calls"], path: "$.tool_calls", itemValidator: validateToolCall)
        try validateArray(root["risks"], path: "$.risks", itemValidator: validateRisk)
        try validateNumber(root["confidence"], path: "$.confidence")
    }

    private static func validatePlanStep(_ value: Any, path: String) throws {
        let object = try requireObject(
            value,
            path: path,
            requiredKeys: ["id", "title", "intent", "kind", "toolCallID", "requiresApproval", "retryBudget"]
        )
        try validateString(object["id"], path: "\(path).id")
        try validateString(object["title"], path: "\(path).title")
        try validateString(object["intent"], path: "\(path).intent")
        try validateEnum(object["kind"], path: "\(path).kind", allowed: Set(PlanStepKind.allCases.map(\.rawValue)))
        try validateNullableString(object["toolCallID"], path: "\(path).toolCallID")
        try validateBool(object["requiresApproval"], path: "\(path).requiresApproval")
        try validateInteger(object["retryBudget"], path: "\(path).retryBudget")
    }

    private static func validateAction(_ value: Any, path: String) throws {
        let object = try requireObject(
            value,
            path: path,
            requiredKeys: ["id", "title", "agent", "stepID"]
        )
        try validateString(object["id"], path: "\(path).id")
        try validateString(object["title"], path: "\(path).title")
        try validateEnum(object["agent"], path: "\(path).agent", allowed: Set(AgentKind.allCases.map(\.rawValue)))
        try validateNullableString(object["stepID"], path: "\(path).stepID")
    }

    private static func validateToolCall(_ value: Any, path: String) throws {
        let object = try requireObject(
            value,
            path: path,
            requiredKeys: ["id", "type", "command", "arguments", "workingDirectory", "requiresApproval"]
        )
        try validateString(object["id"], path: "\(path).id")
        try validateEnum(object["type"], path: "\(path).type", allowed: Set(ToolType.allCases.map(\.rawValue)))
        try validateString(object["command"], path: "\(path).command")
        try validateToolArguments(object["arguments"], path: "\(path).arguments", allowWrapper: true)
        try validateNullableString(object["workingDirectory"], path: "\(path).workingDirectory")
        try validateBool(object["requiresApproval"], path: "\(path).requiresApproval")
    }

    private static func validateRisk(_ value: Any, path: String) throws {
        let object = try requireObject(
            value,
            path: path,
            requiredKeys: ["id", "title", "severity", "mitigation"]
        )
        try validateString(object["id"], path: "\(path).id")
        try validateString(object["title"], path: "\(path).title")
        try validateEnum(object["severity"], path: "\(path).severity", allowed: Set(RiskSeverity.allCases.map(\.rawValue)))
        try validateString(object["mitigation"], path: "\(path).mitigation")
    }

    private static func requireObject(_ value: Any?, path: String, requiredKeys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any] else {
            throw StructuredOutputSchemaError.expectedObject(path)
        }

        let keys = Set(object.keys)
        for key in requiredKeys.sorted() where !keys.contains(key) {
            throw StructuredOutputSchemaError.missingRequiredKey("\(path).\(key)")
        }

        for key in keys.subtracting(requiredKeys).sorted() {
            throw StructuredOutputSchemaError.unexpectedKey("\(path).\(key)")
        }

        return object
    }

    private static func validateArray(
        _ value: Any?,
        path: String,
        itemValidator: (Any, String) throws -> Void
    ) throws {
        guard let array = value as? [Any] else {
            throw StructuredOutputSchemaError.invalidType(path: path, expected: "an array")
        }

        for (index, item) in array.enumerated() {
            try itemValidator(item, "\(path)[\(index)]")
        }
    }

    private static func validateStringArray(_ value: Any?, path: String) throws {
        try validateArray(value, path: path) { item, itemPath in
            try validateString(item, path: itemPath)
        }
    }

    private static let toolArgumentKeys: Set<String> = [
        "workspace", "target", "codebase",
        "path", "relative_path", "directory", "dir", "file",
        "query", "q", "pattern", "search_term",
        "extensions", "ext", "file_extensions",
        "workingDirectory", "working_directory"
    ]

    private static func validateToolArguments(_ value: Any?, path: String, allowWrapper: Bool) throws {
        if value is [Any] {
            try validateStringArray(value, path: path)
            return
        }
        guard let object = value as? [String: Any] else {
            throw StructuredOutputSchemaError.invalidType(path: path, expected: "a string array or tool-argument object")
        }
        let allowed = toolArgumentKeys.union(allowWrapper ? ["arguments"] : [])
        for key in object.keys.sorted() {
            guard allowed.contains(key) else {
                throw StructuredOutputSchemaError.unexpectedKey("\(path).\(key)")
            }
            if key == "arguments" {
                try validateToolArguments(object[key], path: "\(path).arguments", allowWrapper: false)
            } else {
                try validateString(object[key], path: "\(path).\(key)")
            }
        }
    }

    private static func validateString(_ value: Any?, path: String) throws {
        guard value is String else {
            throw StructuredOutputSchemaError.invalidType(path: path, expected: "a string")
        }
    }

    private static func validateNullableString(_ value: Any?, path: String) throws {
        if value is NSNull {
            return
        }
        try validateString(value, path: path)
    }

    private static func validateEnum(_ value: Any?, path: String, allowed: Set<String>) throws {
        guard let string = value as? String else {
            throw StructuredOutputSchemaError.invalidType(path: path, expected: "a string enum")
        }
        guard allowed.contains(string) else {
            throw StructuredOutputSchemaError.invalidEnumValue(path: path, value: string)
        }
    }

    private static func validateBool(_ value: Any?, path: String) throws {
        guard let value, value is Bool || isJSONBool(value) else {
            throw StructuredOutputSchemaError.invalidType(path: path, expected: "a boolean")
        }
    }

    private static func validateInteger(_ value: Any?, path: String) throws {
        guard let number = value as? NSNumber,
              !isJSONBool(number),
              number.doubleValue.rounded() == number.doubleValue else {
            throw StructuredOutputSchemaError.invalidType(path: path, expected: "an integer")
        }
    }

    private static func validateNumber(_ value: Any?, path: String) throws {
        guard let number = value as? NSNumber,
              !isJSONBool(number),
              number.doubleValue.isFinite else {
            throw StructuredOutputSchemaError.invalidType(path: path, expected: "a number")
        }
    }

    private static func isJSONBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else {
            return false
        }
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
    }
}
