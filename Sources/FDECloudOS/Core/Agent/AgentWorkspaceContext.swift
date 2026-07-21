import CryptoKit
import Foundation

struct AgentWorkspaceContext: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var workspaceName: String
    var localProjectRoot: String?
    var localAgentProjectRoot: String?
    var runtimeTaskID: UUID?
    var runtimeTaskTitle: String?
    var missionTaskIDs: [UUID]?
    var latestEventSequence: Int64?
    var activeTurnID: UUID?
    var activeUserMessageID: UUID?
    var turnIDByRuntimeTaskID: [UUID: UUID]?
    var userMessageIDByRuntimeTaskID: [UUID: UUID]?

    init(
        workspaceID: UUID,
        workspaceName: String,
        localProjectRoot: String? = nil,
        localAgentProjectRoot: String? = nil,
        runtimeTaskID: UUID? = nil,
        runtimeTaskTitle: String? = nil,
        missionTaskIDs: [UUID]? = nil,
        latestEventSequence: Int64? = nil,
        activeTurnID: UUID? = nil,
        activeUserMessageID: UUID? = nil,
        turnIDByRuntimeTaskID: [UUID: UUID]? = nil,
        userMessageIDByRuntimeTaskID: [UUID: UUID]? = nil
    ) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.localProjectRoot = localProjectRoot
        self.localAgentProjectRoot = localAgentProjectRoot
        self.runtimeTaskID = runtimeTaskID
        self.runtimeTaskTitle = runtimeTaskTitle
        self.missionTaskIDs = missionTaskIDs
        self.latestEventSequence = latestEventSequence
        self.activeTurnID = activeTurnID
        self.activeUserMessageID = activeUserMessageID
        self.turnIDByRuntimeTaskID = turnIDByRuntimeTaskID
        self.userMessageIDByRuntimeTaskID = userMessageIDByRuntimeTaskID
    }

    init(workspace: Workspace) {
        self.init(
            workspaceID: workspace.id,
            workspaceName: workspace.displayName,
            localProjectRoot: workspace.localProjectRoot,
            localAgentProjectRoot: workspace.localAgentProjectRoot
        )
    }

    mutating func linkRuntimeTask(
        _ task: FDETask,
        turnID: UUID? = nil,
        userMessageID: UUID? = nil
    ) {
        var missionIDs = missionTaskIDs ?? []
        if let runtimeTaskID, !missionIDs.contains(runtimeTaskID) {
            missionIDs.append(runtimeTaskID)
        }
        if !missionIDs.contains(task.id) {
            missionIDs.append(task.id)
        }
        missionTaskIDs = missionIDs
        runtimeTaskID = task.id
        runtimeTaskTitle = task.title
        bindRuntimeTask(task.id, turnID: turnID, userMessageID: userMessageID)
    }

    mutating func bindRuntimeTask(
        _ taskID: UUID,
        turnID: UUID?,
        userMessageID: UUID?
    ) {
        if let turnID {
            var bindings = turnIDByRuntimeTaskID ?? [:]
            bindings[taskID] = turnID
            turnIDByRuntimeTaskID = bindings
        }
        if let userMessageID {
            var bindings = userMessageIDByRuntimeTaskID ?? [:]
            bindings[taskID] = userMessageID
            userMessageIDByRuntimeTaskID = bindings
        }
    }

    func interactionIdentity(taskID: UUID?) -> (turnID: UUID?, userMessageID: UUID?) {
        guard let taskID else { return (activeTurnID, activeUserMessageID) }
        return (
            turnIDByRuntimeTaskID?[taskID] ?? activeTurnID,
            userMessageIDByRuntimeTaskID?[taskID] ?? activeUserMessageID
        )
    }

    mutating func refreshSelectedWorkspace(_ workspace: Workspace) {
        workspaceID = workspace.id
        workspaceName = workspace.displayName
        localProjectRoot = workspace.localProjectRoot
        localAgentProjectRoot = workspace.localAgentProjectRoot
    }
}

enum AgentEvidenceKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case systemGraph = "system_graph"
    case logs
    case reports
    case artifacts
    case runtimeEvent = "runtime_event"
    case approval

    var id: String { rawValue }
}

struct AgentEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var kind: AgentEvidenceKind
    var title: String
    var detail: String
    var sourceEventID: UUID?
    var createdAt: Date

    init(
        id: String,
        kind: AgentEvidenceKind,
        title: String,
        detail: String,
        sourceEventID: UUID? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.sourceEventID = sourceEventID
        self.createdAt = createdAt
    }

    init(event: ExecutionEvent) {
        self.init(
            id: "event-\(event.id.uuidString)",
            kind: Self.kind(for: event.type),
            title: event.type.rawValue,
            detail: AgentPresentationSanitizer.safeContent(event.summary, fallback: event.type.rawValue),
            sourceEventID: event.id,
            createdAt: event.timestamp
        )
    }

    static func isGroundingEvidence(_ event: ExecutionEvent) -> Bool {
        switch event.type {
        case .stepExecuted,
             .connectorExecuted,
             .toolFailed,
             .connectorFailed,
             .nodeExecutionCompleted,
             .nodeExecutionFailed,
             .executionResponseReceived,
             .workerTaskCompleted,
             .workerTaskFailed:
            return true
        case .feedbackGenerated:
            return event.payload["detail"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        default:
            return false
        }
    }

    private static func kind(for eventType: EventType) -> AgentEvidenceKind {
        switch eventType {
        case .contextCompiled,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned:
            return .systemGraph
        case .feedbackGenerated:
            return .reports
        case .taskCompleted,
             .policyUpdated:
            return .artifacts
        case .humanApprovalRequested,
             .humanApproved,
             .humanRejected,
             .userApprovalGranted,
             .userApprovalRejected:
            return .approval
        default:
            return .runtimeEvent
        }
    }
}

enum AgentArtifactType: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case report = "REPORT"
    case codePatch = "CODE_PATCH"
    case configChange = "CONFIG_CHANGE"
    case apiMapping = "API_MAPPING"
    case incidentReport = "INCIDENT_REPORT"
    case customerSummary = "CUSTOMER_SUMMARY"

    var id: String { rawValue }
}

enum AgentArtifactApprovalStatus: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case notRequired = "NOT_REQUIRED"
    case pending = "PENDING"
    case approved = "APPROVED"
    case rejected = "REJECTED"

    var id: String { rawValue }
}

enum AgentArtifactAuthorityClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case authoritativeAssessment = "AUTHORITATIVE_ASSESSMENT"
    case legacyInvalidAssessment = "LEGACY_INVALID_ASSESSMENT"
    case notAssessment = "NOT_ASSESSMENT"
}

struct AssessmentArtifactProvenance: Codable, Hashable, Sendable {
    var sessionID: UUID
    var workspaceID: UUID
    var turnID: UUID
    var requestID: UUID
    var executableIntentClassification: FDEExecutionIntentClassification
    var runtimeTaskID: UUID
    var missionID: UUID
    var evidenceLineageEventIDs: [UUID]
    var artifactDigest: String
}

struct AgentArtifact: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var type: AgentArtifactType
    var title: String
    var description: String
    var detail: String
    var createdEventID: UUID?
    var relatedTaskID: UUID?
    var sourceEventID: UUID?
    var approvalStatus: AgentArtifactApprovalStatus
    var createdAt: Date
    var assessmentProvenance: AssessmentArtifactProvenance?
    var authorityClassification: AgentArtifactAuthorityClassification?

    var isAssessment: Bool {
        authorityClassification == .authoritativeAssessment
            || authorityClassification == .legacyInvalidAssessment
            || detail.contains("# FDE AI Integration Assessment")
            || detail.contains("# FDE AI 接入评估")
            || title.localizedCaseInsensitiveContains("assessment")
    }

    var hasCurrentAuthority: Bool {
        !isAssessment || authorityClassification == .authoritativeAssessment
    }

    init(
        id: String,
        type: AgentArtifactType = .report,
        title: String,
        description: String? = nil,
        detail: String,
        createdEventID: UUID? = nil,
        relatedTaskID: UUID? = nil,
        sourceEventID: UUID? = nil,
        approvalStatus: AgentArtifactApprovalStatus = .notRequired,
        createdAt: Date = Date(),
        assessmentProvenance: AssessmentArtifactProvenance? = nil,
        authorityClassification: AgentArtifactAuthorityClassification? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.description = description ?? detail
        self.detail = detail
        self.createdEventID = createdEventID ?? sourceEventID
        self.relatedTaskID = relatedTaskID
        self.sourceEventID = sourceEventID
        self.approvalStatus = approvalStatus
        self.createdAt = createdAt
        self.assessmentProvenance = assessmentProvenance
        self.authorityClassification = authorityClassification
    }

    init?(event: ExecutionEvent) {
        let type: AgentArtifactType
        let title: String
        let fallback: String
        let approvalStatus: AgentArtifactApprovalStatus

        switch event.type {
        case .taskCompleted:
            guard event.payload["completion_gate_passed"] != "false" else {
                return nil
            }
            type = .report
            title = Self.isAssessmentEvent(event) ? "FDE Assessment" : "Completion summary"
            fallback = "Task completed"
            approvalStatus = .notRequired
        case .stateUpdated:
            guard event.payload["partial_result_kind"] == "GROUNDED_PARTIAL_RESULT",
                  event.payload["grounded_answer"] == "true" else {
                return nil
            }
            type = .report
            title = Self.isAssessmentEvent(event) ? "FDE Assessment" : "Partial result"
            fallback = "Grounded partial result"
            approvalStatus = .notRequired
        case .feedbackGenerated:
            switch event.payload["kind"] {
            case FeedbackKind.missingIntegration.rawValue:
                type = .apiMapping
            case FeedbackKind.roadmapSuggestion.rawValue:
                type = .customerSummary
            case FeedbackKind.testPlan.rawValue:
                type = .customerSummary
            case FeedbackKind.codePatch.rawValue:
                type = .codePatch
            case FeedbackKind.verificationReport.rawValue:
                type = .report
            default:
                type = .incidentReport
            }
            title = AgentPresentationSanitizer.safeContent(event.summary, fallback: "Execution report")
            fallback = "Execution report generated"
            approvalStatus = .notRequired
        case .policyUpdated:
            type = .configChange
            title = "Policy update"
            fallback = "Policy update recorded"
            approvalStatus = .approved
        case .connectorExecuted,
             .executionResponseReceived,
             .workerTaskCompleted:
            type = .apiMapping
            title = "External system evidence"
            fallback = "External system evidence captured"
            approvalStatus = .notRequired
        case .humanApprovalRequested:
            type = .configChange
            title = "Approval request"
            fallback = "Approval request created"
            approvalStatus = .pending
        case .stepExecuted:
            let command = (event.payload["command"] ?? event.payload["tool_name"] ?? "").lowercased()
            let diff = event.payload["diff"]
                ?? event.payload["patch"]
                ?? (event.payload["diff_nonempty"] == "true" ? event.payload["actual_result"] : nil)
                ?? ((event.payload["stdout"] ?? "").contains("diff_nonempty=true") ? event.payload["stdout"] : nil)
            guard ["edit_file", "write_file", "write_patch", "apply_patch", "file_patch"]
                    .contains(where: command.contains),
                  diff?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return nil
            }
            type = .codePatch
            title = "Code changes"
            fallback = "A non-empty code diff was recorded"
            approvalStatus = .notRequired
        default:
            return nil
        }

        let rawDetail = (event.payload["detail"]
            ?? event.payload["diff"]
            ?? event.payload["patch"]
            ?? event.payload["stdout"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedDetail = rawDetail?.isEmpty == false ? rawDetail ?? event.summary : event.summary
        let detail = AgentPresentationSanitizer.safeMarkdownContent(
            selectedDetail,
            fallback: fallback
        )
        self.init(
            id: "\(type.rawValue.lowercased())-\(event.id.uuidString)",
            type: type,
            title: title,
            description: detail,
            detail: detail,
            createdEventID: event.id,
            relatedTaskID: event.taskID,
            sourceEventID: event.id,
            approvalStatus: approvalStatus,
            createdAt: event.timestamp,
            authorityClassification: Self.isAssessmentEvent(event) ? .legacyInvalidAssessment : .notAssessment
        )
    }

    mutating func bindAssessmentAuthority(
        sessionID: UUID,
        workspaceID: UUID,
        turnID: UUID,
        requestID: UUID,
        intent: FDEExecutionIntentClassification,
        runtimeTaskID: UUID,
        missionID: UUID,
        evidenceEventIDs: [UUID]
    ) {
        guard isAssessment,
              intent == .executableReadOnly,
              !evidenceEventIDs.isEmpty else {
            authorityClassification = isAssessment ? .legacyInvalidAssessment : .notAssessment
            assessmentProvenance = nil
            return
        }
        let lineage = Array(Set(evidenceEventIDs)).sorted { $0.uuidString < $1.uuidString }
        let digest = SHA256.hash(data: Data(detail.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        assessmentProvenance = AssessmentArtifactProvenance(
            sessionID: sessionID,
            workspaceID: workspaceID,
            turnID: turnID,
            requestID: requestID,
            executableIntentClassification: intent,
            runtimeTaskID: runtimeTaskID,
            missionID: missionID,
            evidenceLineageEventIDs: lineage,
            artifactDigest: digest
        )
        authorityClassification = .authoritativeAssessment
    }

    private static func isAssessmentEvent(_ event: ExecutionEvent) -> Bool {
        event.payload["ai_assessment_capability"]?.isEmpty == false
            || event.payload["detail"]?.contains("# FDE AI Integration Assessment") == true
            || event.payload["detail"]?.contains("# FDE AI 接入评估") == true
    }
}
