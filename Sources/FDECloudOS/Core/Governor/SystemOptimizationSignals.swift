import Foundation

struct SystemOptimizationSignalEngine: Sendable {
    func objective(for policy: GlobalExecutionPolicy?) -> GlobalPerformanceObjective {
        guard let policy else {
            return GlobalPerformanceObjective(
                goal: .maximizePerformance,
                targetEfficiencyScore: 75,
                maximumFailureRate: 0.25,
                minimumLearningGradient: 0
            )
        }

        let failureRate = currentFailureRate(from: policy.learningEffectCurve)
        let gradient = learningGradient(from: policy.learningEffectCurve).value
        let goal: GlobalOptimizationGoal

        if failureRate > 0.2 {
            goal = .minimizeFailureRate
        } else if gradient < 0 {
            goal = .stabilizeLearning
        } else {
            goal = .maximizePerformance
        }

        return GlobalPerformanceObjective(
            goal: goal,
            targetEfficiencyScore: goal == .minimizeFailureRate ? 82 : 78,
            maximumFailureRate: goal == .minimizeFailureRate ? 0.12 : 0.2,
            minimumLearningGradient: goal == .stabilizeLearning ? 1.0 : 0.0
        )
    }

    func learningGradient(from curve: [LearningEffectPoint]) -> LearningCurveGradient {
        guard curve.count >= 2, let first = curve.first, let last = curve.last else {
            return LearningCurveGradient(value: 0, trend: .flat, sampleCount: curve.count)
        }

        let denominator = Double(max(1, last.executionIndex - first.executionIndex))
        let value = (last.movingAveragePerformance - first.movingAveragePerformance) / denominator
        let trend: LearningTrend
        if value > 0.25 {
            trend = .improving
        } else if value < -0.25 {
            trend = .regressing
        } else {
            trend = .flat
        }

        return LearningCurveGradient(value: value, trend: trend, sampleCount: curve.count)
    }

    func efficiencyScore(policy: GlobalExecutionPolicy?, plannerOutput: StructuredAgentOutput) -> SystemEfficiencyScore {
        let curve = policy?.learningEffectCurve ?? []
        let averagePerformance = curve.isEmpty
            ? plannerOutput.confidence * 100
            : curve.reduce(0) { $0 + $1.performanceScore } / Double(curve.count)
        let failureRate = currentFailureRate(from: curve)
        let compliance = globalPolicyCompliance(policy: policy, plannerOutput: plannerOutput)
        let score = max(
            0,
            min(
                100,
                averagePerformance * 0.45
                    + (1 - failureRate) * 35
                    + compliance * 20
            )
        )

        return SystemEfficiencyScore(
            score: score,
            averagePerformance: averagePerformance,
            failureRate: failureRate,
            globalPolicyCompliance: compliance
        )
    }

    private func currentFailureRate(from curve: [LearningEffectPoint]) -> Double {
        guard !curve.isEmpty else {
            return 0
        }
        let failures = curve.reduce(0) { $0 + $1.failureCount }
        return min(1, Double(failures) / Double(curve.count))
    }

    private func globalPolicyCompliance(policy: GlobalExecutionPolicy?, plannerOutput: StructuredAgentOutput) -> Double {
        guard let policy, !policy.avoidedToolCommands.isEmpty else {
            return 1
        }
        let plannedCommands = Set(plannerOutput.toolCalls.map(\.command))
        let violations = policy.avoidedToolCommands.filter { plannedCommands.contains($0) }.count
        return max(0, 1 - Double(violations) / Double(policy.avoidedToolCommands.count))
    }
}
