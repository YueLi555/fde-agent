import Foundation

struct GovernorResult: Sendable {
    var output: StructuredAgentOutput
    var decision: GlobalGovernorDecision
}

struct GlobalExecutionGovernor: Sendable {
    private let arbitrationEngine: StrategyArbitrationEngine
    private let preflightLayer: ExecutionPreflightLayer

    init(
        arbitrationEngine: StrategyArbitrationEngine = StrategyArbitrationEngine(),
        preflightLayer: ExecutionPreflightLayer = ExecutionPreflightLayer()
    ) {
        self.arbitrationEngine = arbitrationEngine
        self.preflightLayer = preflightLayer
    }

    func govern(
        taskID: UUID,
        workspaceID: UUID,
        plannerOutput: StructuredAgentOutput,
        globalPolicy: GlobalExecutionPolicy?,
        systemFailureProfile: SystemFailureProfile?
    ) -> GovernorResult {
        let arbitration = arbitrationEngine.arbitrate(
            plannerOutput: plannerOutput,
            globalPolicy: globalPolicy,
            systemFailureProfile: systemFailureProfile
        )
        let governedPlan = preflightLayer.validateAndMutate(
            output: plannerOutput,
            policy: globalPolicy,
            arbitration: arbitration
        )

        let decision = GlobalGovernorDecision(
            id: UUID(),
            workspaceID: workspaceID,
            taskID: taskID,
            selectedStrategy: arbitration.selectedStrategy,
            objective: arbitration.objective,
            learningGradient: arbitration.learningGradient,
            efficiencyScore: arbitration.efficiencyScore,
            overrides: governedPlan.overrides,
            approved: true,
            summary: summary(arbitration: arbitration, overrides: governedPlan.overrides),
            createdAt: Date()
        )

        return GovernorResult(output: governedPlan.output, decision: decision)
    }

    private func summary(arbitration: StrategyArbitrationDecision, overrides: [GovernorOverride]) -> String {
        let overrideText = overrides.isEmpty ? "no overrides" : "\(overrides.count) override(s)"
        return "Governor selected \(arbitration.selectedStrategy.rawValue) with \(overrideText); efficiency \(Int(arbitration.efficiencyScore.score))."
    }
}
