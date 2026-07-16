import Foundation

struct TaskMemoryIndexer: Sendable {
    func memory(for task: FDETask, events: [ExecutionEvent]) -> TaskExecutionMemory {
        let toolCommands = events
            .filter { $0.type == .toolCalled || $0.type == .stepExecuted }
            .compactMap { $0.payload["command"] }
            .filter { !$0.isEmpty }
        let failedCommands = events
            .filter { $0.type == .toolFailed }
            .compactMap { $0.payload["command"] }
            .filter { !$0.isEmpty }
        let failureSignatures = events
            .filter { $0.type == .toolFailed }
            .map { event in
                let command = event.payload["command"] ?? "unknown"
                let toolCallID = event.payload["tool_call_id"] ?? "unknown"
                let cause = Self.failureCause(from: event).rawValue
                return "\(TaskTypeClassifier.classify(task.rawInput))|\(cause)|\(command)|\(toolCallID)"
            }

        return TaskExecutionMemory(
            id: UUID(),
            workspaceID: task.workspaceID,
            taskID: task.id,
            taskFingerprint: TaskFingerprint.make(from: task.rawInput),
            taskType: TaskTypeClassifier.classify(task.rawInput),
            state: task.state,
            planStepCount: task.plan.count,
            toolCommands: Array(Set(toolCommands)).sorted(),
            failedCommands: Array(Set(failedCommands)).sorted(),
            failureSignatures: Array(Set(failureSignatures)).sorted(),
            riskScore: task.riskScore,
            performanceScore: task.performanceScore,
            createdAt: task.updatedAt
        )
    }

    static func failureCause(from event: ExecutionEvent) -> FailureClusterCause {
        let summary = event.summary.lowercased()
        let command = event.payload["command"]?.lowercased() ?? ""

        if summary.contains("permission") || summary.contains("not permitted") {
            return .permission
        }
        if command.contains("curl") || command.contains("api") || summary.contains("http") {
            return .api
        }
        if summary.contains("approval") {
            return .approval
        }
        if !command.isEmpty {
            return .toolExecution
        }
        return .unknown
    }
}
