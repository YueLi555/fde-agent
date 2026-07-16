import Foundation

struct UncertaintyEngine: Sendable {
    func assess(output: StructuredAgentOutput, events: [ExecutionEvent]) -> RealityAssessment {
        let severityScore = output.risks.reduce(0.0) { total, risk in
            switch risk.severity {
            case .low: return total + 8
            case .medium: return total + 18
            case .high: return total + 32
            case .critical: return total + 48
            }
        }
        let failureEvents = Double(events.filter { $0.type == .toolFailed }.count)
        let approvalEvents = Double(events.filter { $0.type == .humanApprovalRequested }.count)
        let risk = min(100, severityScore + failureEvents * 20 + approvalEvents * 12 + (1 - output.confidence) * 25)
        let probability = min(0.95, risk / 125)
        let mitigations = output.risks.map(\.mitigation)

        return RealityAssessment(
            realityRiskScore: risk,
            failureProbability: probability,
            mitigations: Array(Set(mitigations)).sorted()
        )
    }
}

struct OutcomeTracker: Sendable {
    func score(workspaceID: UUID, taskID: UUID, task: FDETask, events: [ExecutionEvent]) -> OutcomeMetrics {
        let toolCalls = max(1, events.filter { $0.type == .toolCalled }.count)
        let failures = events.filter { $0.type == .toolFailed }.count
        let approvals = events.filter { $0.type == .humanApprovalRequested }.count
        let completed = task.state == .completed

        let successRate = completed ? 1.0 : 0.0
        let retryRate = min(1.0, Double(failures) / Double(toolCalls))
        let rollbackRate = 0.0
        let interventionRate = min(1.0, Double(approvals) / Double(toolCalls))
        let integrationSuccess = failures == 0 ? 1.0 : max(0.2, 1.0 - Double(failures) / Double(toolCalls))
        let fdeScore = max(
            0,
            min(
                100,
                successRate * 42
                    + integrationSuccess * 28
                    + (1 - retryRate) * 15
                    + (1 - interventionRate) * 10
                    + (1 - task.failureProbability) * 5
            )
        )

        return OutcomeMetrics(
            id: UUID(),
            workspaceID: workspaceID,
            taskID: taskID,
            taskSuccessRate: successRate,
            retryRate: retryRate,
            rollbackRate: rollbackRate,
            humanInterventionRate: interventionRate,
            integrationSuccessScore: integrationSuccess,
            fdePerformanceScore: fdeScore,
            createdAt: Date()
        )
    }
}
