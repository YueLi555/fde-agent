import Foundation

enum AgentState: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case idle
    case understanding
    case planning
    case executing
    case waitingApproval
    case recovering
    case blocked
    case completed
    case failed

    var id: String { rawValue }

    static func state(for event: ExecutionEvent) -> AgentState? {
        switch event.type {
        case .taskCreated:
            return .understanding
        case .contextCompiled:
            return .understanding
        case .planGenerated:
            return .planning
        case .toolCalled,
             .connectorCalled,
             .connectorDryRun,
             .connectorExecuted,
             .stepExecuted,
             .humanApproved,
             .nodeExecutionStarted,
             .nodeExecutionCompleted,
             .executionDispatched,
             .executionReceived,
             .executionResponseReceived,
             .workerTaskReceived,
             .workerTaskCompleted:
            return .executing
        case .stateUpdated:
            switch event.payload["state"].flatMap(TaskState.init(rawValue:))
                ?? event.payload["task_state"].flatMap(TaskState.init(rawValue:)) {
            case .blocked:
                return .blocked
            case .failed:
                return .failed
            case .completed:
                return .completed
            case .pendingApproval, .waiting:
                return .waitingApproval
            default:
                return .executing
            }
        case .humanApprovalRequested:
            return .waitingApproval
        case .toolFailed,
             .connectorFailed,
             .recoveryAttempted,
             .nodeExecutionFailed,
             .workerTaskFailed:
            return .recovering
        case .taskCompleted,
             .feedbackGenerated,
             .policyUpdated:
            return .completed
        case .humanRejected,
             .authorizationDenied,
             .userApprovalRejected:
            return .failed
        case .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned,
             .workerRegistered,
             .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted:
            return nil
        }
    }
}

enum AgentInteractionState: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case draft = "DRAFT"
    case idle = "IDLE"
    case responding = "RESPONDING"
    case understanding = "UNDERSTANDING"
    case planning = "PLANNING"
    case working = "WORKING"
    case running = "RUNNING"
    case waitingForUser = "WAITING_FOR_USER"
    case waitingForApproval = "WAITING_FOR_APPROVAL"
    case verifying = "VERIFYING"
    case blocked = "BLOCKED"
    case blockedProvider = "BLOCKED_PROVIDER"
    case blockedPermission = "BLOCKED_PERMISSION"
    case completed = "COMPLETED"
    case failed = "FAILED"

    var id: String { rawValue }

    static func state(for event: ExecutionEvent) -> AgentInteractionState? {
        if let explicitState = event.payload["interaction_state"]
            .flatMap(AgentInteractionState.init(rawValue:)) {
            return explicitState
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
             .nodeExecutionStarted,
             .executionDispatched,
             .executionReceived,
             .workerTaskReceived:
            return .running
        case .stateUpdated:
            switch event.payload["state"].flatMap(TaskState.init(rawValue:))
                ?? event.payload["task_state"].flatMap(TaskState.init(rawValue:)) {
            case .blocked:
                return .blocked
            case .failed:
                return .failed
            case .completed:
                return .completed
            case .pendingApproval, .waiting:
                return .waitingForApproval
            default:
                return .running
            }
        case .stepExecuted,
             .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            return .verifying
        case .humanApprovalRequested:
            return .waitingForApproval
        case .toolFailed,
             .connectorFailed,
             .recoveryAttempted,
             .nodeExecutionFailed,
             .workerTaskFailed:
            return .running
        case .taskCompleted,
             .feedbackGenerated,
             .policyUpdated:
            return .completed
        case .authorizationDenied:
            return .blockedPermission
        case .humanRejected,
             .userApprovalRejected:
            return .failed
        case .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .workerRegistered,
             .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted:
            return nil
        }
    }
}
