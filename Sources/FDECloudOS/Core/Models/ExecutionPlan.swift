import CryptoKit
import Foundation

struct OriginBinding: Codable, Hashable, Sendable {
    var sessionID: UUID
    var turnID: UUID
    var requestMessageID: UUID
}

struct ExecutionPlanApprovalBinding: Codable, Hashable, Sendable {
    var planID: UUID
    var revision: Int
    var digest: PlanDigest
    var taskID: UUID
    var workspaceID: UUID
    var origin: OriginBinding?

    init(plan: ExecutionPlan) {
        planID = plan.id
        revision = plan.revision.number
        digest = plan.digest
        taskID = plan.taskID
        workspaceID = plan.workspaceID
        origin = plan.origin
    }

    init?(metadata: [String: String]) {
        guard let planID = metadata["plan_id"].flatMap(UUID.init(uuidString:)),
              let revision = metadata["plan_revision"].flatMap(Int.init),
              let algorithm = metadata["plan_digest_algorithm"],
              let serializationVersion = metadata["plan_digest_serialization_version"].flatMap(Int.init),
              let sha256 = metadata["plan_digest"],
              let taskID = metadata["task_id"].flatMap(UUID.init(uuidString:)),
              let workspaceID = metadata["workspace_id"].flatMap(UUID.init(uuidString:)) else {
            return nil
        }
        self.planID = planID
        self.revision = revision
        self.digest = PlanDigest(
            algorithm: algorithm,
            canonicalSerializationVersion: serializationVersion,
            sha256: sha256
        )
        self.taskID = taskID
        self.workspaceID = workspaceID
        let originValues = (
            metadata["origin_session_id"],
            metadata["origin_turn_id"],
            metadata["origin_request_message_id"]
        )
        switch originValues {
        case (nil, nil, nil):
            origin = nil
        case let (sessionID?, turnID?, requestMessageID?):
            guard let sessionID = UUID(uuidString: sessionID),
                  let turnID = UUID(uuidString: turnID),
                  let requestMessageID = UUID(uuidString: requestMessageID) else {
                return nil
            }
            origin = OriginBinding(
                sessionID: sessionID,
                turnID: turnID,
                requestMessageID: requestMessageID
            )
        default:
            return nil
        }
    }

    var metadata: [String: String] {
        var values = [
            "plan_id": planID.uuidString,
            "plan_revision": String(revision),
            "plan_digest_algorithm": digest.algorithm,
            "plan_digest_serialization_version": String(digest.canonicalSerializationVersion),
            "plan_digest": digest.sha256,
            "task_id": taskID.uuidString,
            "workspace_id": workspaceID.uuidString
        ]
        if let origin {
            values["origin_session_id"] = origin.sessionID.uuidString
            values["origin_turn_id"] = origin.turnID.uuidString
            values["origin_request_message_id"] = origin.requestMessageID.uuidString
        }
        return values
    }
}

enum ExecutionPlanLifecycleEvent: String, Codable, Hashable, Sendable {
    case generated = "PLAN_GENERATED"
    case validated = "PLAN_VALIDATED"
}

struct PlanConstraints: Codable, Hashable, Sendable {
    var readOnlyRequired: Bool
    var executionEnabled: Bool
    var allowedToolTypes: [ToolType]
    var allowedTools: [String]
    var mutationAllowed: Bool
    var networkAllowed: Bool
    var credentialAccessAllowed: Bool
    var productionAccessAllowed: Bool
    var deploymentAllowed: Bool

    static var phase3B1AReadOnly: PlanConstraints {
        PlanConstraints(
            readOnlyRequired: true,
            executionEnabled: false,
            allowedToolTypes: [.api],
            allowedTools: ReadOnlyInspectionPolicy.allowedTools.sorted(),
            mutationAllowed: false,
            networkAllowed: false,
            credentialAccessAllowed: false,
            productionAccessAllowed: false,
            deploymentAllowed: false
        )
    }
}

struct PlanDigest: Codable, Hashable, Sendable {
    var algorithm: String
    var canonicalSerializationVersion: Int
    var sha256: String

    static let empty = PlanDigest(
        algorithm: "SHA-256",
        canonicalSerializationVersion: 1,
        sha256: ""
    )

    var isWellFormed: Bool {
        algorithm == "SHA-256"
            && canonicalSerializationVersion == 1
            && sha256.count == 64
            && sha256.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }

    static func compute(_ plan: ExecutionPlan) throws -> PlanDigest {
        let canonical = try ExecutionPlanCanonicalizer.canonical(plan)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(canonical)
        let value = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PlanDigest(
            algorithm: "SHA-256",
            canonicalSerializationVersion: 1,
            sha256: value
        )
    }
}

struct PlanRevision: Codable, Hashable, Sendable {
    enum Reason: String, Codable, CaseIterable, Hashable, Sendable {
        case initial
        case humanRequestedChanges = "human_requested_changes"
        case plannerCorrection = "planner_correction"
        case restoredPlan = "restored_plan"
    }

    var number: Int
    var parentDigest: PlanDigest?
    var reason: Reason
    var createdAt: Date

    static func initial(createdAt: Date = Date()) -> PlanRevision {
        PlanRevision(
            number: 1,
            parentDigest: nil,
            reason: .initial,
            createdAt: createdAt
        )
    }
}

struct ExecutionPlan: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    let id: UUID
    var taskID: UUID
    var workspaceID: UUID
    var origin: OriginBinding
    var missionSemantic: MissionExecutionSemantic
    var workspaceScope: MissionWorkspaceScope
    var objective: String
    var summary: String
    var steps: [PlanStep]
    var toolCalls: [ToolCall]
    var evidenceRequirementIDs: [String]
    var risks: [RiskSignal]
    var constraints: PlanConstraints
    var revision: PlanRevision
    var digest: PlanDigest
    var createdAt: Date

    static func make(
        id: UUID = UUID(),
        taskID: UUID,
        workspaceID: UUID,
        origin: OriginBinding,
        missionSemantic: MissionExecutionSemantic,
        workspaceScope: MissionWorkspaceScope,
        objective: String,
        summary: String,
        steps: [PlanStep],
        toolCalls: [ToolCall],
        evidenceRequirementIDs: [String],
        risks: [RiskSignal],
        constraints: PlanConstraints = .phase3B1AReadOnly,
        revision: PlanRevision = .initial(),
        createdAt: Date = Date()
    ) throws -> ExecutionPlan {
        var plan = ExecutionPlan(
            schemaVersion: currentSchemaVersion,
            id: id,
            taskID: taskID,
            workspaceID: workspaceID,
            origin: origin,
            missionSemantic: missionSemantic,
            workspaceScope: workspaceScope,
            objective: objective,
            summary: summary,
            steps: steps,
            toolCalls: toolCalls,
            evidenceRequirementIDs: evidenceRequirementIDs,
            risks: risks,
            constraints: constraints,
            revision: revision,
            digest: .empty,
            createdAt: createdAt
        )
        plan.digest = try PlanDigest.compute(plan)
        try plan.validate()
        return plan
    }

    var isSelfValidating: Bool {
        (try? validate()) != nil
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ExecutionPlanValidationError.invalidSchemaVersion(schemaVersion)
        }
        guard missionSemantic == .readOnlyWorkspaceInspection else {
            throw ExecutionPlanValidationError.missionSemanticNotReadOnly(missionSemantic)
        }
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutionPlanValidationError.missingObjective
        }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExecutionPlanValidationError.missingSummary
        }

        try validateRevision()
        try validateConstraints()
        try validateStepsAndToolCalls()
        try validateEvidenceRequirements()
        try validateRisks()

        guard digest.isWellFormed else {
            throw ExecutionPlanValidationError.invalidDigest
        }
        guard try PlanDigest.compute(self) == digest else {
            throw ExecutionPlanValidationError.digestMismatch
        }
    }

    private func validateRevision() throws {
        guard revision.number > 0 else {
            throw ExecutionPlanValidationError.invalidRevisionNumber(revision.number)
        }
        if revision.number == 1 {
            guard revision.parentDigest == nil else {
                throw ExecutionPlanValidationError.unexpectedParentDigest
            }
            guard revision.reason == .initial else {
                throw ExecutionPlanValidationError.invalidInitialRevisionReason
            }
        } else {
            guard let parentDigest = revision.parentDigest else {
                throw ExecutionPlanValidationError.missingParentDigest
            }
            guard parentDigest.isWellFormed else {
                throw ExecutionPlanValidationError.invalidParentDigest
            }
            guard revision.reason != .initial else {
                throw ExecutionPlanValidationError.invalidSubsequentRevisionReason
            }
        }
    }

    private func validateConstraints() throws {
        guard constraints.readOnlyRequired,
              !constraints.executionEnabled,
              !constraints.mutationAllowed,
              !constraints.networkAllowed,
              !constraints.credentialAccessAllowed,
              !constraints.productionAccessAllowed,
              !constraints.deploymentAllowed else {
            throw ExecutionPlanValidationError.invalidReadOnlyConstraints
        }
        guard Set(constraints.allowedToolTypes) == [.api],
              constraints.allowedToolTypes.count == 1 else {
            throw ExecutionPlanValidationError.invalidAllowedToolTypes
        }
        guard Set(constraints.allowedTools) == ReadOnlyInspectionPolicy.allowedTools,
              constraints.allowedTools.count == ReadOnlyInspectionPolicy.allowedTools.count else {
            throw ExecutionPlanValidationError.invalidAllowedTools
        }
    }

    private func validateStepsAndToolCalls() throws {
        guard !steps.isEmpty else {
            throw ExecutionPlanValidationError.emptyPlan
        }

        var stepIDs: Set<String> = []
        var toolCallIDs: Set<String> = []
        var referencedToolCallIDs: Set<String> = []

        for call in toolCalls {
            guard !call.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExecutionPlanValidationError.invalidToolCall("Tool-call ID is empty.")
            }
            guard toolCallIDs.insert(call.id).inserted else {
                throw ExecutionPlanValidationError.duplicateToolCallID(call.id)
            }
            try validateToolCall(call)
        }

        for step in steps {
            guard !step.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !step.intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  step.retryBudget >= 0 else {
                throw ExecutionPlanValidationError.invalidStep(step.id)
            }
            guard stepIDs.insert(step.id).inserted else {
                throw ExecutionPlanValidationError.duplicateStepID(step.id)
            }

            switch step.kind {
            case .tool:
                guard let toolCallID = step.toolCallID, toolCallIDs.contains(toolCallID) else {
                    throw ExecutionPlanValidationError.invalidToolCallReference(step.id)
                }
                guard referencedToolCallIDs.insert(toolCallID).inserted else {
                    throw ExecutionPlanValidationError.toolCallReferencedMoreThanOnce(toolCallID)
                }
            case .reasoning, .finalization, .clarification, .blocker:
                guard step.toolCallID == nil else {
                    throw ExecutionPlanValidationError.nonToolStepReferencesTool(step.id)
                }
            }
        }

        if let unreferenced = toolCallIDs.subtracting(referencedToolCallIDs).sorted().first {
            throw ExecutionPlanValidationError.unreferencedToolCall(unreferenced)
        }
    }

    private func validateToolCall(_ call: ToolCall) throws {
        guard call.type == .api, constraints.allowedToolTypes.contains(call.type) else {
            throw ExecutionPlanValidationError.toolTypeNotAllowed(call.type)
        }
        guard constraints.allowedTools.contains(call.command),
              ReadOnlyInspectionPolicy.allowedTools.contains(call.command),
              let schema = ReadOnlyToolSchemas.all[call.command] else {
            throw ExecutionPlanValidationError.toolNotAllowed(call.command)
        }
        guard call.workingDirectory == nil else {
            throw ExecutionPlanValidationError.modelWorkingDirectoryProhibited(call.id)
        }

        let arguments = try ExecutionPlanCanonicalizer.argumentMap(call.arguments)
        let actualKeys = Set(arguments.keys)
        let allowedKeys = Set(schema.allowedArguments).subtracting(["workingDirectory"])
        guard actualKeys.isSubset(of: allowedKeys) else {
            throw ExecutionPlanValidationError.invalidToolArguments(call.id)
        }
        guard Set(schema.requiredModelArguments).isSubset(of: actualKeys) else {
            throw ExecutionPlanValidationError.missingRequiredToolArguments(call.id)
        }
        guard let workspace = arguments["workspace"] else {
            throw ExecutionPlanValidationError.missingWorkspaceBinding(call.id)
        }
        switch workspaceScope {
        case .legacyOnly where workspace != ReadOnlyWorkspaceTarget.legacy.rawValue:
            throw ExecutionPlanValidationError.workspaceScopeMismatch(call.id)
        case .agentOnly where workspace != ReadOnlyWorkspaceTarget.agent.rawValue:
            throw ExecutionPlanValidationError.workspaceScopeMismatch(call.id)
        case .legacyAndAgentComparison where !ReadOnlyWorkspaceTarget.allCases.map(\.rawValue).contains(workspace):
            throw ExecutionPlanValidationError.workspaceScopeMismatch(call.id)
        default:
            break
        }

        if let path = arguments["path"] {
            let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
            let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
            guard !normalized.isEmpty,
                  !normalized.hasPrefix("/"),
                  !normalized.hasPrefix("~"),
                  !components.contains(".."),
                  !ReadOnlySensitivePathPolicy.isSensitive(normalized) else {
                throw ExecutionPlanValidationError.invalidToolPath(call.id)
            }
        }
    }

    private func validateEvidenceRequirements() throws {
        var seen: Set<String> = []
        for requirementID in evidenceRequirementIDs {
            guard !requirementID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExecutionPlanValidationError.invalidEvidenceRequirement
            }
            guard seen.insert(requirementID).inserted else {
                throw ExecutionPlanValidationError.duplicateEvidenceRequirement(requirementID)
            }
        }
    }

    private func validateRisks() throws {
        var seen: Set<String> = []
        for risk in risks {
            guard !risk.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !risk.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !risk.mitigation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExecutionPlanValidationError.invalidRisk(risk.id)
            }
            guard seen.insert(risk.id).inserted else {
                throw ExecutionPlanValidationError.duplicateRiskID(risk.id)
            }
        }
    }
}

enum ExecutionPlanValidationError: LocalizedError, Equatable {
    case invalidSchemaVersion(Int)
    case missionSemanticNotReadOnly(MissionExecutionSemantic)
    case missingObjective
    case missingSummary
    case invalidRevisionNumber(Int)
    case unexpectedParentDigest
    case missingParentDigest
    case invalidParentDigest
    case invalidInitialRevisionReason
    case invalidSubsequentRevisionReason
    case invalidReadOnlyConstraints
    case invalidAllowedToolTypes
    case invalidAllowedTools
    case emptyPlan
    case duplicateStepID(String)
    case invalidStep(String)
    case duplicateToolCallID(String)
    case invalidToolCall(String)
    case invalidToolCallReference(String)
    case toolCallReferencedMoreThanOnce(String)
    case nonToolStepReferencesTool(String)
    case unreferencedToolCall(String)
    case toolTypeNotAllowed(ToolType)
    case toolNotAllowed(String)
    case modelWorkingDirectoryProhibited(String)
    case invalidToolArguments(String)
    case missingRequiredToolArguments(String)
    case missingWorkspaceBinding(String)
    case workspaceScopeMismatch(String)
    case invalidToolPath(String)
    case invalidEvidenceRequirement
    case duplicateEvidenceRequirement(String)
    case invalidRisk(String)
    case duplicateRiskID(String)
    case invalidDigest
    case digestMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSchemaVersion(let version): "Unsupported ExecutionPlan schema version: \(version)."
        case .missionSemanticNotReadOnly(let semantic): "ExecutionPlan semantic is not read-only: \(semantic.rawValue)."
        case .missingObjective: "ExecutionPlan objective is required."
        case .missingSummary: "ExecutionPlan summary is required."
        case .invalidRevisionNumber(let number): "Plan revision must be positive: \(number)."
        case .unexpectedParentDigest: "Initial plan revision cannot have a parent digest."
        case .missingParentDigest: "A subsequent plan revision requires a parent digest."
        case .invalidParentDigest: "Plan revision parent digest is malformed."
        case .invalidInitialRevisionReason: "Revision 1 must use the initial reason."
        case .invalidSubsequentRevisionReason: "A subsequent revision cannot use the initial reason."
        case .invalidReadOnlyConstraints: "Phase 3B.1A constraints must deny execution and all mutation authority."
        case .invalidAllowedToolTypes: "Phase 3B.1A allows only API-backed read-only tools."
        case .invalidAllowedTools: "Phase 3B.1A allowed tools must match the read-only inspection policy."
        case .emptyPlan: "ExecutionPlan requires at least one step."
        case .duplicateStepID(let id): "Duplicate plan-step ID: \(id)."
        case .invalidStep(let id): "Invalid plan step: \(id)."
        case .duplicateToolCallID(let id): "Duplicate tool-call ID: \(id)."
        case .invalidToolCall(let detail): detail
        case .invalidToolCallReference(let id): "Plan step has an invalid tool-call reference: \(id)."
        case .toolCallReferencedMoreThanOnce(let id): "Tool call is referenced more than once: \(id)."
        case .nonToolStepReferencesTool(let id): "Non-tool step references a tool call: \(id)."
        case .unreferencedToolCall(let id): "ExecutionPlan contains an unreferenced tool call: \(id)."
        case .toolTypeNotAllowed(let type): "Tool type is not allowed: \(type.rawValue)."
        case .toolNotAllowed(let command): "Tool is not allowed: \(command)."
        case .modelWorkingDirectoryProhibited(let id): "ExecutionPlan cannot bind a model-supplied working directory: \(id)."
        case .invalidToolArguments(let id): "Tool call contains invalid or duplicate arguments: \(id)."
        case .missingRequiredToolArguments(let id): "Tool call is missing required arguments: \(id)."
        case .missingWorkspaceBinding(let id): "Tool call requires an explicit workspace binding: \(id)."
        case .workspaceScopeMismatch(let id): "Tool-call workspace does not match the plan scope: \(id)."
        case .invalidToolPath(let id): "Tool-call path is unsafe or non-relative: \(id)."
        case .invalidEvidenceRequirement: "Evidence requirement IDs must be non-empty."
        case .duplicateEvidenceRequirement(let id): "Duplicate evidence requirement ID: \(id)."
        case .invalidRisk(let id): "Invalid risk record: \(id)."
        case .duplicateRiskID(let id): "Duplicate risk ID: \(id)."
        case .invalidDigest: "ExecutionPlan digest is malformed."
        case .digestMismatch: "ExecutionPlan digest does not match its canonical content."
        }
    }
}

private enum ExecutionPlanCanonicalizer {
    struct CanonicalPlan: Encodable {
        var canonicalSerializationVersion: Int
        var schemaVersion: Int
        var id: UUID
        var taskID: UUID
        var workspaceID: UUID
        var origin: OriginBinding
        var missionSemantic: MissionExecutionSemantic
        var workspaceScope: MissionWorkspaceScope
        var objective: String
        var summary: String
        var steps: [CanonicalStep]
        var toolCalls: [CanonicalToolCall]
        var evidenceRequirementIDs: [String]
        var risks: [CanonicalRisk]
        var constraints: CanonicalConstraints
        var revision: CanonicalRevision
    }

    struct CanonicalStep: Encodable {
        var id: String
        var title: String
        var intent: String
        var kind: PlanStepKind
        var toolCallID: String?
        var requiresApproval: Bool
        var retryBudget: Int
    }

    struct CanonicalToolCall: Encodable {
        var id: String
        var type: ToolType
        var command: String
        var arguments: [CanonicalArgument]
        var workingDirectory: String?
        var requiresApproval: Bool
    }

    struct CanonicalArgument: Encodable {
        var key: String
        var value: String
    }

    struct CanonicalRisk: Encodable {
        var id: String
        var title: String
        var severity: RiskSeverity
        var mitigation: String
    }

    struct CanonicalConstraints: Encodable {
        var readOnlyRequired: Bool
        var executionEnabled: Bool
        var allowedToolTypes: [ToolType]
        var allowedTools: [String]
        var mutationAllowed: Bool
        var networkAllowed: Bool
        var credentialAccessAllowed: Bool
        var productionAccessAllowed: Bool
        var deploymentAllowed: Bool
    }

    struct CanonicalRevision: Encodable {
        var number: Int
        var parentDigest: PlanDigest?
        var reason: PlanRevision.Reason
    }

    static func canonical(_ plan: ExecutionPlan) throws -> CanonicalPlan {
        CanonicalPlan(
            canonicalSerializationVersion: 1,
            schemaVersion: plan.schemaVersion,
            id: plan.id,
            taskID: plan.taskID,
            workspaceID: plan.workspaceID,
            origin: plan.origin,
            missionSemantic: plan.missionSemantic,
            workspaceScope: plan.workspaceScope,
            objective: plan.objective,
            summary: plan.summary,
            steps: plan.steps.map {
                CanonicalStep(
                    id: $0.id,
                    title: $0.title,
                    intent: $0.intent,
                    kind: $0.kind,
                    toolCallID: $0.toolCallID,
                    requiresApproval: $0.requiresApproval,
                    retryBudget: $0.retryBudget
                )
            },
            toolCalls: try plan.toolCalls.map {
                CanonicalToolCall(
                    id: $0.id,
                    type: $0.type,
                    command: $0.command,
                    arguments: try canonicalArguments($0.arguments),
                    workingDirectory: $0.workingDirectory,
                    requiresApproval: $0.requiresApproval
                )
            }.sorted { $0.id < $1.id },
            evidenceRequirementIDs: plan.evidenceRequirementIDs.sorted(),
            risks: plan.risks.map {
                CanonicalRisk(id: $0.id, title: $0.title, severity: $0.severity, mitigation: $0.mitigation)
            }.sorted { $0.id < $1.id },
            constraints: CanonicalConstraints(
                readOnlyRequired: plan.constraints.readOnlyRequired,
                executionEnabled: plan.constraints.executionEnabled,
                allowedToolTypes: plan.constraints.allowedToolTypes.sorted { $0.rawValue < $1.rawValue },
                allowedTools: plan.constraints.allowedTools.sorted(),
                mutationAllowed: plan.constraints.mutationAllowed,
                networkAllowed: plan.constraints.networkAllowed,
                credentialAccessAllowed: plan.constraints.credentialAccessAllowed,
                productionAccessAllowed: plan.constraints.productionAccessAllowed,
                deploymentAllowed: plan.constraints.deploymentAllowed
            ),
            revision: CanonicalRevision(
                number: plan.revision.number,
                parentDigest: plan.revision.parentDigest,
                reason: plan.revision.reason
            )
        )
    }

    static func argumentMap(_ arguments: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        for argument in arguments {
            let components = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw ExecutionPlanValidationError.invalidToolArguments("arguments")
            }
            let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, values[key] == nil else {
                throw ExecutionPlanValidationError.invalidToolArguments("arguments")
            }
            values[key] = value
        }
        return values
    }

    private static func canonicalArguments(_ arguments: [String]) throws -> [CanonicalArgument] {
        try argumentMap(arguments)
            .map { CanonicalArgument(key: $0.key, value: $0.value) }
            .sorted {
                if $0.key == $1.key { return $0.value < $1.value }
                return $0.key < $1.key
            }
    }
}
