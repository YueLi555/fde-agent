import Foundation

enum AgentWorkspaceStage: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case understanding = "UNDERSTANDING"
    case planning = "PLANNING"
    case ready = "READY"
    case deciding = "DECIDING"
    case executing = "EXECUTING"
    case observing = "OBSERVING"
    case verifying = "VERIFYING"
    case adapting = "ADAPTING"
    case waitingHuman = "WAITING_HUMAN"
    case blocked = "BLOCKED"
    case failed = "FAILED"
    case completed = "COMPLETED"

    var id: String { rawValue }
}

enum AgentWorkspaceEventStatus: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case queued = "QUEUED"
    case active = "ACTIVE"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case waitingHuman = "WAITING_HUMAN"

    var id: String { rawValue }
}

enum AgentWorkspaceEvidenceKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case runtimeEvent = "RUNTIME_EVENT"
    case decision = "DECISION"
    case toolExecution = "TOOL_EXECUTION"
    case observation = "OBSERVATION"
    case adaptation = "ADAPTATION"
    case approval = "APPROVAL"
    case artifact = "ARTIFACT"
    case risk = "RISK"
    case systemContext = "SYSTEM_CONTEXT"

    var id: String { rawValue }
}

struct AgentWorkspaceEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var kind: AgentWorkspaceEvidenceKind
    var title: String
    var detail: String
}

struct AgentWorkspaceEvent: Identifiable, Codable, Hashable, Sendable {
    let eventID: UUID
    var timestamp: Date
    var missionID: UUID
    var stage: AgentWorkspaceStage
    var title: String
    var summary: String
    var status: AgentWorkspaceEventStatus
    var evidence: [AgentWorkspaceEvidence]
    var requiresUserAction: Bool

    var id: UUID { eventID }
}

struct AgentWorkspaceProjection: Sendable {
    static func events(
        session: AgentSession?,
        task: FDETask?,
        events runtimeEvents: [ExecutionEvent],
        approvals: [ApprovalRequest] = [],
        artifacts: [AgentArtifact]? = nil
    ) -> [AgentWorkspaceEvent] {
        let projectedRuntimeEvents = runtimeEvents
            .sortedByWorkspaceProjectionOrder()
            .compactMap { event in
                project(event: event, session: session, task: task)
            }

        let existingEventIDs = Set(projectedRuntimeEvents.map(\.eventID))
        let approvalIDsInRuntimeEvents = Set(
            runtimeEvents.compactMap { event in
                event.payload["approval_request_id"].flatMap(UUID.init(uuidString:))
            }
        )
        let missionID = session?.runtimeTaskID ?? task?.id ?? session?.sessionID
        let projectedApprovals: [AgentWorkspaceEvent] = approvals.compactMap { approval in
            if existingEventIDs.contains(approval.id) || approvalIDsInRuntimeEvents.contains(approval.id) {
                return nil
            }
            return project(approval: approval, missionID: missionID)
        }

        let projectedArtifacts = (artifacts ?? session?.artifacts ?? [])
            .filter { artifact in
                guard let sourceEventID = artifact.sourceEventID else { return true }
                return !existingEventIDs.contains(sourceEventID)
            }
            .compactMap { artifact in
                project(artifact: artifact, missionID: missionID)
            }

        return (projectedRuntimeEvents + projectedApprovals + projectedArtifacts)
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.eventID.uuidString < rhs.eventID.uuidString
                }
                return lhs.timestamp < rhs.timestamp
            }
    }

    static func project(
        event: ExecutionEvent,
        session: AgentSession? = nil,
        task: FDETask? = nil
    ) -> AgentWorkspaceEvent? {
        guard !isChatOnlyEvent(event) else {
            return nil
        }
        guard event.type != .taskCompleted
                || event.payload["completion_gate_passed"] != "false" else {
            return nil
        }
        let stage = stage(for: event)
        let requiresUserAction = requiresUserAction(event)
        let status = status(for: event, stage: stage, requiresUserAction: requiresUserAction)
        let title = title(for: event, stage: stage)
        let summary = summary(for: event, stage: stage)

        return AgentWorkspaceEvent(
            eventID: event.id,
            timestamp: event.timestamp,
            missionID: event.taskID ?? task?.id ?? session?.runtimeTaskID ?? session?.sessionID ?? event.workspaceID,
            stage: stage,
            title: title,
            summary: summary,
            status: status,
            evidence: evidence(for: event, stage: stage),
            requiresUserAction: requiresUserAction
        )
    }

    static func project(approval: ApprovalRequest, missionID: UUID? = nil) -> AgentWorkspaceEvent {
        let safeAction = safe(approval.action, fallback: "Approval required")
        let safeResource = safe(approval.resource, fallback: "Protected resource")
        let isPending = approval.state == .pending
        let title: String
        let status: AgentWorkspaceEventStatus

        switch approval.state {
        case .pending:
            title = "Approval required"
            status = .waitingHuman
        case .approved:
            title = "Approval granted"
            status = .completed
        case .rejected:
            title = "Approval rejected"
            status = .failed
        case .expired:
            title = "Approval expired"
            status = .failed
        }

        return AgentWorkspaceEvent(
            eventID: approval.id,
            timestamp: approval.requestedAt,
            missionID: approval.taskID ?? missionID ?? approval.workspaceID,
            stage: .waitingHuman,
            title: title,
            summary: "\(safeAction) requires \(approval.riskLevel.rawValue.uppercased()) risk approval.",
            status: status,
            evidence: [
                AgentWorkspaceEvidence(
                    id: "approval-\(approval.id.uuidString)-risk",
                    kind: .risk,
                    title: "Risk",
                    detail: approval.riskLevel.rawValue.uppercased()
                ),
                AgentWorkspaceEvidence(
                    id: "approval-\(approval.id.uuidString)-resource",
                    kind: .approval,
                    title: "Resource",
                    detail: safeResource
                )
            ],
            requiresUserAction: isPending
        )
    }

    static func project(artifact: AgentArtifact, missionID: UUID? = nil) -> AgentWorkspaceEvent {
        let eventID = artifact.sourceEventID ?? artifact.createdEventID ?? stableUUID(from: artifact.id)
        let status: AgentWorkspaceEventStatus
        switch artifact.approvalStatus {
        case .pending:
            status = .waitingHuman
        case .rejected:
            status = .failed
        case .approved, .notRequired:
            status = .completed
        }
        return AgentWorkspaceEvent(
            eventID: eventID,
            timestamp: artifact.createdAt,
            missionID: artifact.relatedTaskID ?? missionID ?? eventID,
            stage: artifactStage(for: artifact),
            title: safe(artifact.title, fallback: "Artifact created"),
            summary: safe(artifact.description, fallback: "Artifact captured for this mission."),
            status: status,
            evidence: [
                AgentWorkspaceEvidence(
                    id: "artifact-\(artifact.id)",
                    kind: .artifact,
                    title: artifact.type.rawValue,
                    detail: safe(artifact.detail, fallback: "Artifact detail withheld.")
                )
            ],
            requiresUserAction: artifact.approvalStatus == .pending
        )
    }

    private static func stage(for event: ExecutionEvent) -> AgentWorkspaceStage {
        if event.type == .humanApprovalRequested {
            return .waitingHuman
        }

        if hasDecisionPayload(event) {
            let requiresApproval = event.payload["agent_decision_requires_human_approval"] == "true"
            return requiresApproval ? .waitingHuman : .deciding
        }

        if event.type == .userMessageReceived {
            return .deciding
        }

        if let missionState = event.payload["mission_state"].flatMap(MissionState.init(rawValue:)) {
            return stage(for: missionState)
        }

        if let traceStage = event.payload["agent_work_trace_stage"].flatMap(AgentWorkTraceStage.init(rawValue:)) {
            return stage(for: traceStage)
        }

        switch event.type {
        case .taskCreated, .contextCompiled:
            return .understanding
        case .planGenerated, .routingDecisionMade, .nodeSelected, .executionTargetAssigned:
            return .planning
        case .toolCalled,
             .connectorCalled,
             .connectorDryRun,
             .connectorExecuted,
             .humanApproved,
             .userApprovalGranted,
             .nodeExecutionStarted,
             .executionDispatched,
             .executionReceived,
             .workerTaskReceived:
            return .executing
        case .stepExecuted,
             .toolFailed,
             .connectorFailed,
             .authorizationDenied,
             .nodeExecutionCompleted,
             .nodeExecutionFailed,
             .executionResponseReceived,
             .workerTaskCompleted,
             .workerTaskFailed:
            return .observing
        case .recoveryAttempted,
             .policyUpdated,
             .userDecisionSelected:
            return .adapting
        case .humanApprovalRequested:
            return .waitingHuman
        case .userMessageReceived:
            return .deciding
        case .taskCompleted,
             .feedbackGenerated:
            return .completed
        case .humanRejected,
             .userApprovalRejected:
            return .waitingHuman
        case .stateUpdated:
            return stateUpdatedStage(event)
        case .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .workerRegistered:
            return .understanding
        }
    }

    private static func stateUpdatedStage(_ event: ExecutionEvent) -> AgentWorkspaceStage {
        if let missionState = event.payload["mission_state"].flatMap(MissionState.init(rawValue:)) {
            return stage(for: missionState)
        }
        if event.payload["task_state"] == TaskState.pendingApproval.rawValue
            || event.payload["task_state"] == TaskState.waiting.rawValue {
            return .waitingHuman
        }
        return .executing
    }

    private static func stage(for missionState: MissionState) -> AgentWorkspaceStage {
        switch missionState {
        case .idle, .understand:
            return .understanding
        case .plan:
            return .planning
        case .ready:
            return .ready
        case .execute:
            return .executing
        case .observe:
            return .observing
        case .verifying:
            return .verifying
        case .adapt:
            return .adapting
        case .waitingHuman:
            return .waitingHuman
        case .blocked:
            return .blocked
        case .failed:
            return .failed
        case .complete:
            return .completed
        }
    }

    private static func stage(for traceStage: AgentWorkTraceStage) -> AgentWorkspaceStage {
        switch traceStage {
        case .understanding:
            return .understanding
        case .planning:
            return .planning
        case .execution:
            return .executing
        case .observation:
            return .observing
        case .adaptation:
            return .adapting
        case .completion:
            return .completed
        }
    }

    private static func status(
        for event: ExecutionEvent,
        stage: AgentWorkspaceStage,
        requiresUserAction: Bool
    ) -> AgentWorkspaceEventStatus {
        if requiresUserAction {
            return .waitingHuman
        }

        switch event.type {
        case .toolFailed,
             .connectorFailed,
             .authorizationDenied,
             .humanRejected,
             .nodeExecutionFailed,
             .workerTaskFailed,
             .userApprovalRejected:
            return .failed
        case .taskCompleted,
             .feedbackGenerated,
             .policyUpdated:
            return .completed
        case .stepExecuted,
             .connectorExecuted,
             .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            return .completed
        case .userMessageReceived,
             .userDecisionSelected:
            return .completed
        default:
            return stage == .completed ? .completed : .active
        }
    }

    private static func requiresUserAction(_ event: ExecutionEvent) -> Bool {
        if event.type == .userMessageReceived || isChatOnlyEvent(event) {
            return false
        }
        return event.type == .humanApprovalRequested
            || event.payload["mission_state"] == MissionState.waitingHuman.rawValue
            || event.payload["task_state"] == TaskState.pendingApproval.rawValue
            || event.payload["tool_state"] == ToolExecutionState.pendingApproval.rawValue
            || event.payload["agent_decision_requires_human_approval"] == "true"
    }

    private static func title(for event: ExecutionEvent, stage: AgentWorkspaceStage) -> String {
        if let traceTitle = safePayload(event, "agent_work_trace_summary") {
            return traceTitle
        }
        if hasDecisionPayload(event),
           let action = event.payload["agent_decision_action_type"].flatMap(AgentRuntimeAction.init(rawValue:)) {
            return decisionTitle(for: action)
        }

        switch event.type {
        case .taskCreated:
            return "Mission accepted"
        case .contextCompiled:
            return "Understanding environment"
        case .planGenerated:
            return "Execution strategy created"
        case .toolCalled:
            return "Running tool"
        case .connectorCalled, .connectorDryRun, .connectorExecuted:
            return "Checking connector"
        case .stepExecuted:
            return "Observed result"
        case .toolFailed, .connectorFailed:
            return "Execution issue detected"
        case .authorizationDenied:
            return "Permission issue detected"
        case .recoveryAttempted:
            return "Recovery path created"
        case .humanApprovalRequested:
            return "Waiting for approval"
        case .stateUpdated:
            if event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" {
                return "Partial investigation result"
            }
            return semanticTitle(for: stage)
        case .taskCompleted:
            return "Mission completed"
        case .feedbackGenerated:
            return "Artifact generated"
        case .policyUpdated:
            return "Configuration updated"
        case .humanApproved, .userApprovalGranted:
            return "Approval granted"
        case .humanRejected, .userApprovalRejected:
            return "Approval rejected"
        case .userMessageReceived:
            return "User input received"
        case .userDecisionSelected:
            return "Direction updated"
        case .routingDecisionMade:
            return "Execution route selected"
        case .nodeSelected:
            return "Execution node selected"
        case .executionTargetAssigned:
            return "Execution target assigned"
        case .nodeExecutionStarted, .executionDispatched, .executionReceived, .workerTaskReceived:
            return "Remote execution started"
        case .nodeExecutionCompleted, .executionResponseReceived, .workerTaskCompleted:
            return "Remote execution observed"
        case .nodeExecutionFailed, .workerTaskFailed:
            return "Remote execution issue detected"
        case .sessionStarted, .sessionEnded, .workspaceSwitched, .roleChanged, .workerRegistered:
            return safe(event.summary, fallback: event.type.rawValue)
        }
    }

    private static func summary(for event: ExecutionEvent, stage: AgentWorkspaceStage) -> String {
        if let traceDetail = safePayload(event, "agent_work_trace_detail") {
            return traceDetail
        }
        if let decisionSummary = safePayload(event, "agent_decision_summary") {
            return decisionSummary
        }
        if let observationSummary = safePayload(event, "observation_summary") {
            return observationSummary
        }
        if event.type == .humanApprovalRequested {
            let command = safePayload(event, "command") ?? "protected action"
            let risk = safePayload(event, "risk_level") ?? "high"
            return "Needs approval for \(command). Risk: \(risk.uppercased())."
        }
        if event.type == .toolCalled, let command = safePayload(event, "command") {
            return "Executing \(command)."
        }
        if event.type == .recoveryAttempted {
            let failed = safePayload(event, "failed_command") ?? "failed action"
            let recovery = safePayload(event, "recovery_command") ?? "recovery step"
            return "Adapting after \(failed). Next path: \(recovery)."
        }
        if event.type == .feedbackGenerated, let detail = safePayload(event, "detail") {
            return detail
        }
        return safe(event.summary, fallback: semanticSummary(for: stage))
    }

    private static func evidence(for event: ExecutionEvent, stage: AgentWorkspaceStage) -> [AgentWorkspaceEvidence] {
        guard AgentEvidence.isGroundingEvidence(event)
                || event.type == .authorizationDenied
                || event.type == .humanApproved
                || event.type == .humanRejected
                || event.type == .userApprovalGranted
                || event.type == .userApprovalRejected else {
            return []
        }
        var items: [AgentWorkspaceEvidence] = [
            AgentWorkspaceEvidence(
                id: "event-\(event.id.uuidString)",
                kind: .runtimeEvent,
                title: "Runtime event",
                detail: event.type.rawValue
            )
        ]

        if let decision = safePayload(event, "agent_decision_action_type") {
            items.append(
                AgentWorkspaceEvidence(
                    id: "decision-\(event.id.uuidString)",
                    kind: .decision,
                    title: "Decision",
                    detail: decision
                )
            )
        }
        if let command = safePayload(event, "command") ?? safePayload(event, "failed_command") {
            items.append(
                AgentWorkspaceEvidence(
                    id: "command-\(event.id.uuidString)",
                    kind: .toolExecution,
                    title: "Tool",
                    detail: command
                )
            )
        }
        if let exitCode = safePayload(event, "exit_code") {
            items.append(
                AgentWorkspaceEvidence(
                    id: "exit-\(event.id.uuidString)",
                    kind: .observation,
                    title: "Exit code",
                    detail: exitCode
                )
            )
        }
        if let risk = safePayload(event, "risk_level") {
            items.append(
                AgentWorkspaceEvidence(
                    id: "risk-\(event.id.uuidString)",
                    kind: .risk,
                    title: "Risk",
                    detail: risk.uppercased()
                )
            )
        }
        if let approvalID = safePayload(event, "approval_request_id") {
            items.append(
                AgentWorkspaceEvidence(
                    id: "approval-\(event.id.uuidString)",
                    kind: .approval,
                    title: "Approval",
                    detail: approvalID
                )
            )
        }
        if let connectedSystem = safePayload(event, "observation_connected_system")
            ?? safePayload(event, "world_model_connected_systems") {
            items.append(
                AgentWorkspaceEvidence(
                    id: "system-\(event.id.uuidString)",
                    kind: .systemContext,
                    title: "System",
                    detail: connectedSystem
                )
            )
        }
        if let artifactDetail = artifactDetail(for: event) {
            items.append(
                AgentWorkspaceEvidence(
                    id: "artifact-\(event.id.uuidString)",
                    kind: .artifact,
                    title: "Artifact",
                    detail: artifactDetail
                )
            )
        }
        if stage == .adapting, let recovery = safePayload(event, "recovery_command") {
            items.append(
                AgentWorkspaceEvidence(
                    id: "adaptation-\(event.id.uuidString)",
                    kind: .adaptation,
                    title: "Recovery",
                    detail: recovery
                )
            )
        }

        return items
    }

    private static func artifactDetail(for event: ExecutionEvent) -> String? {
        switch event.type {
        case .taskCompleted:
            return "Completion summary"
        case .feedbackGenerated:
            return safePayload(event, "kind") ?? "Report"
        case .policyUpdated:
            return "Configuration diff"
        default:
            return nil
        }
    }

    private static func artifactStage(for artifact: AgentArtifact) -> AgentWorkspaceStage {
        switch artifact.type {
        case .codePatch, .configChange:
            return artifact.approvalStatus == .pending ? .waitingHuman : .adapting
        case .report, .incidentReport, .customerSummary:
            return .completed
        case .apiMapping:
            return .observing
        }
    }

    private static func decisionTitle(for action: AgentRuntimeAction) -> String {
        switch action {
        case .answerCapability:
            return "Capability answer prepared"
        case .askClarification:
            return "Information needed"
        case .submitTask:
            return "Mission submitted"
        case .executeTool:
            return "Execution approved"
        case .continueMission:
            return "Continuing mission"
        case .replan:
            return "Replanning"
        case .requestHumanApproval:
            return "Human approval needed"
        case .requestPause:
            return "Pause requested"
        case .resumeTask:
            return "Mission resumed"
        case .changeApproach:
            return "Approach changed"
        case .stopTask:
            return "Mission stopped"
        case .acknowledgeInstruction:
            return "Instruction recorded"
        }
    }

    private static func semanticTitle(for stage: AgentWorkspaceStage) -> String {
        switch stage {
        case .understanding:
            return "Understanding environment"
        case .planning:
            return "Planning solution"
        case .ready:
            return "Ready"
        case .deciding:
            return "Choosing next action"
        case .executing:
            return "Executing changes"
        case .observing:
            return "Validating outcome"
        case .verifying:
            return "Verifying"
        case .adapting:
            return "Adapting recovery path"
        case .waitingHuman:
            return "Waiting for human input"
        case .blocked:
            return "Blocked"
        case .failed:
            return "Failed"
        case .completed:
            return "Mission completed"
        }
    }

    private static func semanticSummary(for stage: AgentWorkspaceStage) -> String {
        switch stage {
        case .understanding:
            return "Analyzing customer environment."
        case .planning:
            return "Creating execution strategy."
        case .ready:
            return "The plan is ready for execution."
        case .deciding:
            return "Selecting the next safe action."
        case .executing:
            return "Running authorized work."
        case .observing:
            return "Checking execution results."
        case .verifying:
            return "Validating execution results and evidence."
        case .adapting:
            return "Creating a recovery path."
        case .waitingHuman:
            return "Needs human input before continuing."
        case .blocked:
            return "Execution is blocked and requires attention."
        case .failed:
            return "Execution failed before completion."
        case .completed:
            return "Mission finished."
        }
    }

    private static func hasDecisionPayload(_ event: ExecutionEvent) -> Bool {
        event.payload["agent_decision_action_type"]?.isEmpty == false
            || event.payload["agent_decision_summary"]?.isEmpty == false
    }

    private static func isChatOnlyEvent(_ event: ExecutionEvent) -> Bool {
        event.payload["chat_only"] == "true"
    }

    private static func safePayload(_ event: ExecutionEvent, _ key: String) -> String? {
        guard let value = event.payload[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return safe(value, fallback: fallback(for: key))
    }

    private static func fallback(for key: String) -> String {
        switch key {
        case "command", "failed_command", "recovery_command":
            return "Command withheld"
        case "detail":
            return "Artifact detail withheld"
        case "agent_decision_summary":
            return "Agent selected next runtime action."
        case "agent_work_trace_summary":
            return "Agent activity"
        case "agent_work_trace_detail":
            return "Safe execution summary."
        case "observation_summary":
            return "Observation captured."
        default:
            return "Value withheld"
        }
    }

    private static func safe(_ value: String, fallback: String) -> String {
        let sanitized = AgentPresentationSanitizer.safeContent(value, fallback: fallback)
        guard !AgentPresentationSanitizer.containsRestrictedContent(sanitized) else {
            return fallback
        }
        return sanitized
    }

    private static func stableUUID(from value: String) -> UUID {
        let namespace = UUID(uuidString: "FDE00000-0000-4000-8000-000000000000")!
        let uuid = namespace.uuid
        var bytes = [
            uuid.0, uuid.1, uuid.2, uuid.3,
            uuid.4, uuid.5, uuid.6, uuid.7,
            uuid.8, uuid.9, uuid.10, uuid.11,
            uuid.12, uuid.13, uuid.14, uuid.15
        ]
        for scalar in value.unicodeScalars {
            let next = UInt8(truncatingIfNeeded: scalar.value)
            let index = Int(next) % bytes.count
            bytes[index] = bytes[index] &+ next
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension Array where Element == ExecutionEvent {
    func sortedByWorkspaceProjectionOrder() -> [ExecutionEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
