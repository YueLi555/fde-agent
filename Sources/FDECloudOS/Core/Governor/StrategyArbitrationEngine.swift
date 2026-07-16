import Foundation

struct StrategyArbitrationEngine: Sendable {
    private let signalEngine: SystemOptimizationSignalEngine

    init(signalEngine: SystemOptimizationSignalEngine = SystemOptimizationSignalEngine()) {
        self.signalEngine = signalEngine
    }

    func arbitrate(
        plannerOutput: StructuredAgentOutput,
        globalPolicy: GlobalExecutionPolicy?,
        systemFailureProfile: SystemFailureProfile?
    ) -> StrategyArbitrationDecision {
        let objective = signalEngine.objective(for: globalPolicy)
        let gradient = signalEngine.learningGradient(from: globalPolicy?.learningEffectCurve ?? [])
        let efficiency = signalEngine.efficiencyScore(policy: globalPolicy, plannerOutput: plannerOutput)
        let plannedCommands = Set(plannerOutput.toolCalls.map(\.command))
        let avoidedCommands = Set(globalPolicy?.avoidedToolCommands ?? [])
        let policyViolations = plannedCommands.intersection(avoidedCommands)
        let hasRecurringFailures = !(systemFailureProfile?.recurringSignatures.isEmpty ?? true)

        let strategy: GovernorStrategy
        var reasons: [String] = []

        if !policyViolations.isEmpty {
            strategy = .globalPolicyPreferred
            reasons.append("Planner selected globally avoided tools: \(policyViolations.sorted().joined(separator: ", "))")
        } else if objective.goal == .minimizeFailureRate || gradient.trend == .regressing || hasRecurringFailures {
            strategy = .conservativeRecovery
            reasons.append("Global optimization favors failure reduction or learning stabilization.")
        } else {
            strategy = .plannerPreferred
            reasons.append("Planner output satisfies current global policy.")
        }

        return StrategyArbitrationDecision(
            selectedStrategy: strategy,
            objective: objective,
            learningGradient: gradient,
            efficiencyScore: efficiency,
            reasons: reasons
        )
    }
}
