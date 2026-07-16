import Foundation

struct FeedbackPolicyEngine: Sendable {
    func policyDeltas(
        for task: FDETask,
        feedback: [FeedbackInsight],
        events: [ExecutionEvent],
        parentEventID: UUID?
    ) -> [ExecutionPolicyDelta] {
        let fingerprint = TaskFingerprint.make(from: task.rawInput)
        let failureEvents = events.filter { $0.type == .toolFailed }

        if failureEvents.isEmpty {
            return [
                ExecutionPolicyDelta(
                    id: UUID(),
                    workspaceID: task.workspaceID,
                    sourceTaskID: task.id,
                    parentEventID: parentEventID,
                    kind: .stabilizeSuccessfulPlan,
                    taskFingerprint: fingerprint,
                    failureSignature: nil,
                    avoidToolCommand: nil,
                    replacementToolCommand: nil,
                    retryBudget: 0,
                    reorderCheckpointBeforeRiskyTool: true,
                    summary: "Task completed without tool failure; next matching plan should preserve a causal checkpoint before risky inspection.",
                    createdAt: Date()
                )
            ]
        }

        let grouped = Dictionary(grouping: failureEvents) { event in
            event.payload["command"] ?? "unknown"
        }

        return grouped.map { command, failures in
            let latest = failures.sorted { $0.sequence < $1.sequence }.last
            let toolCallID = latest?.payload["tool_call_id"] ?? "unknown"
            let replacement = replacementCommand(for: command)
            return ExecutionPolicyDelta(
                id: UUID(),
                workspaceID: task.workspaceID,
                sourceTaskID: task.id,
                parentEventID: parentEventID,
                kind: .avoidFailedTool,
                taskFingerprint: fingerprint,
                failureSignature: "\(command)|\(toolCallID)|count:\(failures.count)",
                avoidToolCommand: command == "unknown" ? nil : command,
                replacementToolCommand: replacement,
                retryBudget: 1,
                reorderCheckpointBeforeRiskyTool: true,
                summary: "Avoid \(command) for matching tasks after \(failures.count) failure(s); use \(replacement ?? "policy-selected replacement") with one retry budget.",
                createdAt: Date()
            )
        }
        .sorted { $0.summary < $1.summary }
    }

    private func replacementCommand(for command: String) -> String? {
        switch command {
        case "api.missing_dependency":
            return "/usr/bin/env"
        case "/bin/ls":
            return "/usr/bin/env"
        case "/usr/bin/env":
            return "/bin/pwd"
        default:
            return "/bin/pwd"
        }
    }
}
