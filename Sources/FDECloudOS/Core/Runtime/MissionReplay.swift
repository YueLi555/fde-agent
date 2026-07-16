import Foundation

struct MissionReplay: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var userObjective: String
    var agentDecisions: [MissionReplayDecision]
    var stateTransitions: [MissionReplayStateTransition]
    var approvals: [MissionReplayApproval]
    var actions: [MissionReplayAction]
    var evidence: [MissionReplayEvidence]
    var outcome: MissionReplayOutcome?
    var eventCount: Int
    var auditGaps: [String]

    var isAuditComplete: Bool {
        auditGaps.isEmpty
    }
}

struct MissionReplayDecision: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sequence: Int64
    var summary: String
    var nextState: MissionState?
    var actionType: AgentRuntimeAction?
    var confidence: Double?
    var requiresApproval: Bool
}

struct MissionReplayStateTransition: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sequence: Int64
    var missionState: MissionState?
    var taskState: TaskState?
    var toolState: ToolExecutionState?
    var eventType: EventType
    var summary: String
}

struct MissionReplayApproval: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var requestID: UUID?
    var sequence: Int64?
    var state: ApprovalState
    var action: String
    var resource: String
    var riskLevel: RiskSeverity
    var requestedByRole: UserRole?
    var decidedByRole: UserRole?
    var reason: String?
}

struct MissionReplayAction: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sequence: Int64
    var eventType: EventType
    var command: String?
    var toolCallID: String?
    var stepID: String?
    var summary: String
    var policyDecision: PolicyDecisionStatus?
    var riskLevel: RiskSeverity?
}

struct MissionReplayEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sequence: Int64
    var title: String
    var detail: String
    var sourceEventType: EventType
}

struct MissionReplayOutcome: Codable, Hashable, Sendable {
    var finalState: MissionState?
    var taskState: TaskState?
    var summary: String
    var completed: Bool
}

struct MissionReplayBuilder: Sendable {
    func reconstruct(
        task: FDETask?,
        objective: String? = nil,
        events: [ExecutionEvent],
        approvals: [ApprovalRequest],
        outcome: OutcomeRecord? = nil
    ) -> MissionReplay {
        let orderedEvents = events.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
        let workspaceID = task?.workspaceID ?? orderedEvents.first?.workspaceID ?? UUID()
        let taskID = task?.id ?? orderedEvents.first?.taskID ?? UUID()
        let userObjective = objective?.nilIfBlank
            ?? task?.rawInput.nilIfBlank
            ?? orderedEvents.first(where: { $0.type == .taskCreated })?.summary
            ?? ""

        let replay = MissionReplay(
            id: taskID,
            workspaceID: workspaceID,
            taskID: taskID,
            userObjective: userObjective,
            agentDecisions: decisions(from: orderedEvents),
            stateTransitions: stateTransitions(from: orderedEvents),
            approvals: approvalModels(from: approvals, events: orderedEvents),
            actions: actions(from: orderedEvents),
            evidence: evidence(from: orderedEvents),
            outcome: outcomeModel(from: outcome, task: task, events: orderedEvents),
            eventCount: orderedEvents.count,
            auditGaps: []
        )

        return replay.withAuditGaps(auditGaps(for: replay, events: orderedEvents))
    }

    private func decisions(from events: [ExecutionEvent]) -> [MissionReplayDecision] {
        events.compactMap { event in
            guard event.payload["agent_decision_summary"] != nil
                || event.payload["decision_next_action"] != nil
                || event.payload["agent_decision_action_type"] != nil else {
                return nil
            }
            return MissionReplayDecision(
                id: event.id,
                sequence: event.sequence,
                summary: event.payload["agent_decision_summary"]
                    ?? event.payload["decision_reason"]
                    ?? event.summary,
                nextState: event.payload["agent_decision_next_state"].flatMap(MissionState.init(rawValue:)),
                actionType: (event.payload["agent_decision_action_type"] ?? event.payload["decision_next_action"])
                    .flatMap(AgentRuntimeAction.init(rawValue:)),
                confidence: event.payload["agent_decision_confidence"].flatMap(Double.init),
                requiresApproval: event.payload["agent_decision_requires_human_approval"] == "true"
                    || event.payload["decision_requires_human_approval"] == "true"
            )
        }
    }

    private func stateTransitions(from events: [ExecutionEvent]) -> [MissionReplayStateTransition] {
        events.compactMap { event in
            let missionState = event.payload["mission_state"].flatMap(MissionState.init(rawValue:))
            let taskState = event.payload["task_state"].flatMap(TaskState.init(rawValue:))
            let toolState = event.payload["tool_state"].flatMap(ToolExecutionState.init(rawValue:))
            guard missionState != nil || taskState != nil || toolState != nil else { return nil }
            return MissionReplayStateTransition(
                id: event.id,
                sequence: event.sequence,
                missionState: missionState,
                taskState: taskState,
                toolState: toolState,
                eventType: event.type,
                summary: event.summary
            )
        }
    }

    private func approvalModels(from approvals: [ApprovalRequest], events: [ExecutionEvent]) -> [MissionReplayApproval] {
        var values = approvals.map { request in
            MissionReplayApproval(
                id: request.id,
                requestID: request.id,
                sequence: events.first { $0.payload["approval_request_id"] == request.id.uuidString }?.sequence,
                state: request.state,
                action: request.action,
                resource: request.resource,
                riskLevel: request.riskLevel,
                requestedByRole: request.requestedByRole,
                decidedByRole: request.decidedByRole,
                reason: request.decisionReason ?? request.metadata["policy_reasons"] ?? request.metadata["risk_reasons"]
            )
        }

        let knownRequestIDs = Set(values.compactMap(\.requestID))
        for event in events where [.humanApprovalRequested, .humanApproved, .humanRejected].contains(event.type) {
            let requestID = event.payload["approval_request_id"].flatMap(UUID.init(uuidString:))
            guard requestID.map({ !knownRequestIDs.contains($0) }) ?? true else { continue }
            values.append(
                MissionReplayApproval(
                    id: event.id,
                    requestID: requestID,
                    sequence: event.sequence,
                    state: approvalState(from: event),
                    action: event.payload["action"] ?? event.payload["decision_next_action"] ?? event.type.rawValue,
                    resource: event.payload["command"] ?? event.payload["resource"] ?? event.summary,
                    riskLevel: event.payload["risk_level"].flatMap(RiskSeverity.init(rawValue:)) ?? .medium,
                    requestedByRole: event.payload["requested_by_role"].flatMap(UserRole.init(rawValue:)),
                    decidedByRole: event.payload["decided_by_role"].flatMap(UserRole.init(rawValue:)),
                    reason: event.payload["decision_reason"] ?? event.payload["risk_reasons"] ?? event.payload["policy_reasons"]
                )
            )
        }
        return values.sorted { ($0.sequence ?? Int64.max) < ($1.sequence ?? Int64.max) }
    }

    private func actions(from events: [ExecutionEvent]) -> [MissionReplayAction] {
        events.compactMap { event in
            guard [
                .toolCalled,
                .stepExecuted,
                .connectorCalled,
                .connectorDryRun,
                .connectorExecuted,
                .connectorFailed,
                .toolFailed,
                .authorizationDenied,
                .policyUpdated
            ].contains(event.type) else {
                return nil
            }
            return MissionReplayAction(
                id: event.id,
                sequence: event.sequence,
                eventType: event.type,
                command: event.payload["command"],
                toolCallID: event.payload["tool_call_id"],
                stepID: event.payload["step_id"],
                summary: event.summary,
                policyDecision: event.payload["policy_decision"].flatMap(PolicyDecisionStatus.init(rawValue:)),
                riskLevel: (event.payload["risk_level"] ?? event.payload["risk_assessment_level"]).flatMap(RiskSeverity.init(rawValue:))
            )
        }
    }

    private func evidence(from events: [ExecutionEvent]) -> [MissionReplayEvidence] {
        events.compactMap { event in
            let details = [
                event.payload["world_model_evidence"],
                event.payload["environment_evidence"],
                event.payload["risk_reasons"],
                event.payload["policy_reasons"],
                event.payload["stdout"],
                event.payload["stderr"]
            ]
            .compactMap(\.self)
            .filter { !$0.isEmpty }

            guard !details.isEmpty || [.contextCompiled, .stepExecuted, .toolFailed, .authorizationDenied, .taskCompleted].contains(event.type) else {
                return nil
            }

            return MissionReplayEvidence(
                id: event.id,
                sequence: event.sequence,
                title: event.type.rawValue,
                detail: details.first ?? event.summary,
                sourceEventType: event.type
            )
        }
    }

    private func outcomeModel(
        from outcome: OutcomeRecord?,
        task: FDETask?,
        events: [ExecutionEvent]
    ) -> MissionReplayOutcome? {
        if let outcome {
            return MissionReplayOutcome(
                finalState: outcome.finalState,
                taskState: task?.state,
                summary: outcome.achievedOutcome,
                completed: outcome.finalState == .complete
            )
        }

        if let completion = events.last(where: { $0.type == .taskCompleted || $0.type == .authorizationDenied }) {
            return MissionReplayOutcome(
                finalState: completion.payload["mission_state"].flatMap(MissionState.init(rawValue:)),
                taskState: completion.payload["task_state"].flatMap(TaskState.init(rawValue:)) ?? task?.state,
                summary: completion.summary,
                completed: completion.type == .taskCompleted
            )
        }

        if let task, [.completed, .failed].contains(task.state) {
            return MissionReplayOutcome(
                finalState: task.state == .completed ? .complete : nil,
                taskState: task.state,
                summary: task.title,
                completed: task.state == .completed
            )
        }

        return nil
    }

    private func approvalState(from event: ExecutionEvent) -> ApprovalState {
        switch event.type {
        case .humanApproved, .userApprovalGranted:
            return .approved
        case .humanRejected, .userApprovalRejected:
            return .rejected
        default:
            return event.payload["approval_state"].flatMap(ApprovalState.init(rawValue:)) ?? .pending
        }
    }

    private func auditGaps(for replay: MissionReplay, events: [ExecutionEvent]) -> [String] {
        var gaps: [String] = []
        if replay.userObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            gaps.append("Missing user objective.")
        }
        if replay.agentDecisions.isEmpty {
            gaps.append("Missing agent decisions.")
        }
        if replay.stateTransitions.isEmpty {
            gaps.append("Missing state transitions.")
        }
        if events.contains(where: { $0.type == .humanApprovalRequested }) && replay.approvals.isEmpty {
            gaps.append("Missing approval records.")
        }
        if replay.actions.isEmpty {
            gaps.append("Missing action records.")
        }
        if replay.evidence.isEmpty {
            gaps.append("Missing evidence.")
        }
        if replay.outcome == nil {
            gaps.append("Missing outcome.")
        }
        return gaps
    }
}

private extension MissionReplay {
    func withAuditGaps(_ gaps: [String]) -> MissionReplay {
        var copy = self
        copy.auditGaps = gaps
        return copy
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
