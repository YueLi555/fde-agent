import Foundation

struct GovernedPlan: Sendable {
    var output: StructuredAgentOutput
    var overrides: [GovernorOverride]
}

struct ExecutionPreflightLayer: Sendable {
    func validateAndMutate(
        output: StructuredAgentOutput,
        policy: GlobalExecutionPolicy?,
        arbitration: StrategyArbitrationDecision
    ) -> GovernedPlan {
        var governed = output
        var overrides: [GovernorOverride] = []
        guard let policy else {
            return GovernedPlan(output: governed, overrides: overrides)
        }

        for index in governed.toolCalls.indices {
            let call = governed.toolCalls[index]
            guard policy.avoidedToolCommands.contains(call.command) else {
                continue
            }
            let replacement = policy.toolPreferences[call.command] ?? replacementCommand(for: call.command)
            governed.toolCalls[index].type = .shell
            governed.toolCalls[index].command = replacement
            governed.toolCalls[index].arguments = defaultArguments(for: replacement)
            overrides.append(
                GovernorOverride(
                    id: UUID(),
                    kind: .replaceAvoidedTool,
                    targetID: call.id,
                    before: call.command,
                    after: replacement,
                    reason: "GlobalExecutionPolicy forbids planner-selected command."
                )
            )
        }

        for index in governed.plan.indices where governed.plan[index].retryBudget < policy.defaultRetryBudget {
            let before = String(governed.plan[index].retryBudget)
            governed.plan[index].retryBudget = policy.defaultRetryBudget
            overrides.append(
                GovernorOverride(
                    id: UUID(),
                    kind: .raiseRetryBudget,
                    targetID: governed.plan[index].id,
                    before: before,
                    after: String(policy.defaultRetryBudget),
                    reason: "Global objective requires system-wide retry posture."
                )
            )
        }

        if policy.decompositionDepth > governed.plan.count {
            let preflightToolID = "tool.governor.preflight"
            if !governed.toolCalls.contains(where: { $0.id == preflightToolID }) {
                governed.toolCalls.append(
                    ToolCall(
                        id: preflightToolID,
                        type: .shell,
                        command: "/bin/echo",
                        arguments: ["Governor preflight approved: \(policy.summary)"],
                        workingDirectory: nil,
                        requiresApproval: false
                    )
                )
            }
            if !governed.plan.contains(where: { $0.id == "step.governor-preflight" }) {
                governed.plan.insert(
                    PlanStep(
                        id: "step.governor-preflight",
                        title: "Apply global governor constraints",
                        intent: "Enforce system-wide optimization objective before task execution.",
                        toolCallID: preflightToolID,
                        requiresApproval: false,
                        retryBudget: policy.defaultRetryBudget
                    ),
                    at: min(1, governed.plan.count)
                )
                overrides.append(
                    GovernorOverride(
                        id: UUID(),
                        kind: .insertPreflightConstraint,
                        targetID: "step.governor-preflight",
                        before: "missing",
                        after: "inserted",
                        reason: "Execution must be pre-validated by global governor."
                    )
                )
            }
        }

        if policy.checkpointBeforeInspection {
            let beforeOrder = governed.plan.map(\.id).joined(separator: " > ")
            governed.plan = reorderCheckpointBeforeInspection(governed.plan)
            let afterOrder = governed.plan.map(\.id).joined(separator: " > ")
            if beforeOrder != afterOrder {
                overrides.append(
                    GovernorOverride(
                        id: UUID(),
                        kind: .reorderCheckpoint,
                        targetID: "plan",
                        before: beforeOrder,
                        after: afterOrder,
                        reason: "Global policy requires checkpoint before inspection."
                    )
                )
            }
        }

        if arbitration.selectedStrategy == .conservativeRecovery {
            for index in governed.plan.indices where governed.plan[index].retryBudget == 0 {
                governed.plan[index].retryBudget = 1
            }
        }

        return GovernedPlan(output: governed, overrides: overrides)
    }

    private func replacementCommand(for command: String) -> String {
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

    private func defaultArguments(for command: String) -> [String] {
        command == "/bin/ls" ? ["-la", "."] : []
    }

    private func reorderCheckpointBeforeInspection(_ plan: [PlanStep]) -> [PlanStep] {
        guard let checkpointIndex = plan.firstIndex(where: { $0.toolCallID == "tool.execution.checkpoint" }),
              let inspectionIndex = plan.firstIndex(where: { $0.id.contains("inspect") || $0.toolCallID?.contains("workspace") == true }),
              checkpointIndex > inspectionIndex else {
            return plan
        }

        var reordered = plan
        let checkpoint = reordered.remove(at: checkpointIndex)
        let insertionIndex = reordered.firstIndex(where: { $0.id.contains("inspect") || $0.toolCallID?.contains("workspace") == true }) ?? 0
        reordered.insert(checkpoint, at: insertionIndex)
        return reordered
    }
}
