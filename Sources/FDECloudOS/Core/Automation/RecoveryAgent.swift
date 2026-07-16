import Foundation

struct RecoveryAgent: Sendable {
    func recoveryCall(for failedCall: ToolCall, error: Error) -> ToolCall {
        ToolCall(
            id: "recovery.\(failedCall.id)",
            type: .shell,
            command: "/bin/echo",
            arguments: ["Recovery captured failure for \(failedCall.id): \(error.localizedDescription)"],
            workingDirectory: nil,
            requiresApproval: false
        )
    }
}
