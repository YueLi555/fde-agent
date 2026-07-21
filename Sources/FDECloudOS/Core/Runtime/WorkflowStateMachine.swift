import Foundation

enum WorkflowStateError: LocalizedError, Equatable {
    case invalidTransition(TaskState, TaskState)

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "Invalid workflow transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
}

struct WorkflowStateMachine: Sendable {
    func transition(_ task: inout FDETask, to nextState: TaskState) throws {
        guard isAllowed(from: task.state, to: nextState) else {
            throw WorkflowStateError.invalidTransition(task.state, nextState)
        }
        task.state = nextState
        task.updatedAt = Date()
    }

    private func isAllowed(from current: TaskState, to next: TaskState) -> Bool {
        switch (current, next) {
        case (.created, .planned),
             (.created, .blocked),
             (.planned, .running),
             (.planned, .blocked),
             (.running, .waiting),
             (.running, .pendingApproval),
             (.running, .failed),
             (.running, .blocked),
             (.running, .completed),
             (.waiting, .planned),
             (.waiting, .running),
             (.waiting, .failed),
             (.pendingApproval, .running),
             (.pendingApproval, .failed),
             (.blocked, .planned),
             (.blocked, .running),
             (.failed, .running),
             (.completed, .replayed),
             (_, _) where current == next:
            return true
        default:
            return false
        }
    }
}
