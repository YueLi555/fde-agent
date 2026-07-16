import Foundation

struct EventToWorkUnitAggregator: Sendable {
    func workUnits(from events: [ExecutionEvent]) -> [AgentWorkUnit] {
        Self.workUnits(from: events)
    }

    static func workUnits(from events: [ExecutionEvent]) -> [AgentWorkUnit] {
        var units: [AgentWorkUnit] = []
        var indexesByID: [String: Int] = [:]

        for event in events.sortedByWorkUnitOrder() where !isChatOnlyEvent(event) {
            let mapping = workUnitMapping(for: event)
            let id = unitID(for: event, kind: mapping.kind, groupKey: mapping.groupKey)

            if let index = indexesByID[id] {
                units[index].append(
                    event: event,
                    status: mapping.status,
                    title: mapping.title,
                    detail: mapping.detail,
                    relatedArtifactID: mapping.relatedArtifactID
                )
            } else {
                indexesByID[id] = units.count
                units.append(
                    AgentWorkUnit(
                        id: id,
                        workspaceID: event.workspaceID,
                        taskID: event.taskID,
                        kind: mapping.kind,
                        status: mapping.status,
                        title: mapping.title,
                        detail: mapping.detail,
                        agent: mapping.agent,
                        startedAt: event.timestamp,
                        updatedAt: event.timestamp,
                        eventIDs: [event.id],
                        eventTypes: [event.type],
                        relatedArtifactID: mapping.relatedArtifactID
                    )
                )
            }
        }

        return units
    }

    private struct WorkUnitMapping {
        var kind: AgentWorkUnitKind
        var status: AgentWorkUnitStatus
        var title: String
        var detail: String?
        var agent: AgentKind?
        var groupKey: String
        var relatedArtifactID: String?
    }

    private static func workUnitMapping(for event: ExecutionEvent) -> WorkUnitMapping {
        let classification = classification(for: event)
        return WorkUnitMapping(
            kind: classification.kind,
            status: classification.status,
            title: title(for: event, kind: classification.kind),
            detail: detail(for: event),
            agent: agent(for: event.type),
            groupKey: groupKey(for: event, kind: classification.kind),
            relatedArtifactID: relatedArtifactID(for: event)
        )
    }

    private static func classification(
        for event: ExecutionEvent
    ) -> (kind: AgentWorkUnitKind, status: AgentWorkUnitStatus) {
        if event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" {
            return (.execution, .blocked)
        }
        switch event.type {
        case .taskCreated,
             .contextCompiled:
            return (.understanding, event.type == .contextCompiled ? .completed : .active)
        case .planGenerated,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned:
            return (.planning, .planned)
        case .toolCalled,
             .connectorCalled,
             .connectorDryRun,
             .nodeExecutionStarted,
             .executionDispatched,
             .executionReceived,
             .workerTaskReceived:
            return (.execution, .active)
        case .stepExecuted,
             .connectorExecuted,
             .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            return (.execution, .completed)
        case .toolFailed,
             .connectorFailed,
             .nodeExecutionFailed,
             .workerTaskFailed:
            return (.execution, .failed)
        case .recoveryAttempted:
            return (.recovery, .active)
        case .humanApprovalRequested:
            return (.approval, .waitingApproval)
        case .humanApproved,
             .userApprovalGranted:
            return (.approval, .completed)
        case .humanRejected,
             .userApprovalRejected:
            return (.approval, .failed)
        case .stateUpdated:
            return stateClassification(for: event)
        case .taskCompleted,
             .feedbackGenerated:
            return (.result, .completed)
        case .policyUpdated:
            return (.policy, .completed)
        case .authorizationDenied:
            return (.policy, .failed)
        case .userMessageReceived,
             .userDecisionSelected:
            return (.request, .completed)
        case .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .workerRegistered:
            return (.system, .completed)
        }
    }

    private static func stateClassification(
        for event: ExecutionEvent
    ) -> (kind: AgentWorkUnitKind, status: AgentWorkUnitStatus) {
        if isChatOnlyEvent(event) {
            return (.request, .completed)
        }
        guard let state = event.payload["state"].flatMap(TaskState.init(rawValue:)) else {
            return (.system, .active)
        }

        switch state {
        case .created:
            return (.understanding, .active)
        case .planned:
            return (.planning, .planned)
        case .running:
            return (.execution, .active)
        case .waiting,
             .pendingApproval:
            return (.approval, .waitingApproval)
        case .blocked:
            return (.execution, .blocked)
        case .failed:
            return (.execution, .failed)
        case .completed,
             .replayed:
            return (.result, .completed)
        }
    }

    private static func title(for event: ExecutionEvent, kind: AgentWorkUnitKind) -> String {
        switch kind {
        case .request:
            return "User input"
        case .understanding:
            return event.type == .contextCompiled ? "Workspace context ready" : "Understand request"
        case .planning:
            return "Plan execution"
        case .execution:
            if event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" {
                return "Partial investigation result"
            }
            switch event.type {
            case .toolFailed,
                 .connectorFailed,
                 .nodeExecutionFailed,
                 .workerTaskFailed:
                return "Execution issue"
            case .stepExecuted,
                 .connectorExecuted,
                 .nodeExecutionCompleted,
                 .executionResponseReceived,
                 .workerTaskCompleted:
                return "Execution result"
            default:
                return "Execute step"
            }
        case .approval:
            switch event.type {
            case .humanApproved,
                 .userApprovalGranted:
                return "Approval granted"
            case .humanRejected,
                 .userApprovalRejected:
                return "Approval rejected"
            default:
                return "Approval required"
            }
        case .recovery:
            return "Recover execution"
        case .policy:
            return event.type == .authorizationDenied ? "Policy blocked action" : "Update policy"
        case .result:
            return event.type == .feedbackGenerated ? "Generate report" : "Mission result"
        case .system:
            return "System event"
        }
    }

    private static func detail(for event: ExecutionEvent) -> String? {
        let fallback = event.type.rawValue
        guard event.summary != fallback else { return nil }

        let safe = AgentPresentationSanitizer.safeContent(event.summary, fallback: "")
        guard !safe.isEmpty,
              !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return nil
        }
        return safe
    }

    private static func agent(for eventType: EventType) -> AgentKind? {
        switch eventType {
        case .taskCreated,
             .contextCompiled:
            return .systemUnderstanding
        case .planGenerated,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned:
            return .planner
        case .toolCalled,
             .toolFailed,
             .connectorCalled,
             .connectorDryRun,
             .connectorExecuted,
             .connectorFailed,
             .stepExecuted,
             .taskCompleted,
             .nodeExecutionStarted,
             .nodeExecutionCompleted,
             .nodeExecutionFailed,
             .executionDispatched,
             .executionReceived,
             .executionResponseReceived,
             .workerTaskReceived,
             .workerTaskCompleted,
             .workerTaskFailed:
            return .executor
        case .recoveryAttempted:
            return .recovery
        case .humanApprovalRequested,
             .humanApproved,
             .humanRejected,
             .authorizationDenied,
             .policyUpdated,
             .userApprovalGranted,
             .userApprovalRejected:
            return .policy
        case .feedbackGenerated:
            return .policy
        case .stateUpdated,
             .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .workerRegistered,
             .userMessageReceived,
             .userDecisionSelected:
            return nil
        }
    }

    private static func groupKey(for event: ExecutionEvent, kind: AgentWorkUnitKind) -> String {
        switch kind {
        case .execution:
            return payloadID(event, keys: ["step_id", "tool_call_id", "worker_id", "node_id"])
                ?? "event-\(event.id.uuidString)"
        case .approval:
            return payloadID(event, keys: ["approval_request_id", "step_id", "tool_call_id"])
                ?? "event-\(event.id.uuidString)"
        case .recovery:
            return payloadID(event, keys: ["recovery_tool_call_id", "failed_tool_call_id"])
                ?? "event-\(event.id.uuidString)"
        case .policy:
            return payloadID(event, keys: ["policy_delta_id"])
                ?? kind.rawValue
        case .result:
            if event.type == .feedbackGenerated {
                return payloadID(event, keys: ["feedback_id"]) ?? "event-\(event.id.uuidString)"
            }
            return kind.rawValue
        case .request:
            return payloadID(event, keys: ["message_id", "session_id"]) ?? "event-\(event.id.uuidString)"
        case .understanding,
             .planning,
             .system:
            return kind.rawValue
        }
    }

    private static func payloadID(_ event: ExecutionEvent, keys: [String]) -> String? {
        for key in keys {
            if let value = event.payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return "\(key)=\(value)"
            }
        }
        return nil
    }

    private static func unitID(
        for event: ExecutionEvent,
        kind: AgentWorkUnitKind,
        groupKey: String
    ) -> String {
        [
            "work-unit",
            event.workspaceID.uuidString,
            event.taskID?.uuidString ?? "workspace",
            kind.rawValue,
            groupKey
        ].joined(separator: ":")
    }

    private static func relatedArtifactID(for event: ExecutionEvent) -> String? {
        switch event.type {
        case .taskCompleted:
            return "completion-\(event.id.uuidString)"
        case .feedbackGenerated:
            return event.payload["feedback_id"].map { "feedback-\($0)" } ?? "event-\(event.id.uuidString)"
        case .policyUpdated:
            return event.payload["policy_delta_id"].map { "policy-\($0)" } ?? "event-\(event.id.uuidString)"
        case .humanApprovalRequested,
             .humanApproved,
             .humanRejected,
             .userApprovalGranted,
             .userApprovalRejected:
            return event.payload["approval_request_id"].map { "approval-\($0)" } ?? "event-\(event.id.uuidString)"
        case .contextCompiled,
             .stepExecuted,
             .connectorExecuted,
             .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            return "event-\(event.id.uuidString)"
        default:
            return nil
        }
    }

    private static func isChatOnlyEvent(_ event: ExecutionEvent) -> Bool {
        event.payload["chat_only"] == "true"
    }
}

private extension Array where Element == ExecutionEvent {
    func sortedByWorkUnitOrder() -> [ExecutionEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
