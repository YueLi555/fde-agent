import Foundation

struct GlobalPolicyCompiler: Sendable {
    func compile(
        workspaceID: UUID,
        localPolicyDeltas: [ExecutionPolicyDelta],
        memories: [TaskExecutionMemory],
        profile: SystemFailureProfile,
        insights: [SystemLevelInsight]
    ) -> GlobalExecutionPolicy {
        let failedToolClusters = profile.clusters
            .filter { $0.cause == .toolExecution }
        let avoidedCommands = Array(Set(
            failedToolClusters.compactMap(\.toolCommand)
                + localPolicyDeltas.compactMap(\.avoidToolCommand)
        )).sorted()

        var preferences: [String: String] = [:]
        for command in avoidedCommands {
            preferences[command] = replacementCommand(for: command)
        }

        let maxFrequency = profile.clusters.map(\.frequency).max() ?? 0
        let defaultRetryBudget = min(3, max(0, maxFrequency))
        let decompositionDepth = min(5, 3 + (profile.clusters.isEmpty ? 0 : 1) + (profile.recurringSignatures.isEmpty ? 0 : 1))
        let learningCurve = learningEffectCurve(workspaceID: workspaceID, memories: memories)
        let sourceInsightIDs = insights.prefix(12).map(\.id)
        let sourceClusterSignatures = profile.clusters.prefix(12).map(\.signature)

        return GlobalExecutionPolicy(
            id: UUID(),
            workspaceID: workspaceID,
            avoidedToolCommands: avoidedCommands,
            toolPreferences: preferences,
            defaultRetryBudget: defaultRetryBudget,
            decompositionDepth: decompositionDepth,
            checkpointBeforeInspection: !profile.clusters.isEmpty,
            sourceInsightIDs: sourceInsightIDs,
            sourceClusterSignatures: sourceClusterSignatures,
            learningEffectCurve: learningCurve,
            summary: summary(avoidedCommands: avoidedCommands, profile: profile, curve: learningCurve),
            createdAt: Date()
        )
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

    private func learningEffectCurve(workspaceID: UUID, memories: [TaskExecutionMemory]) -> [LearningEffectPoint] {
        let ordered = memories.sorted { $0.createdAt < $1.createdAt }
        var totalPerformance = 0.0

        return ordered.enumerated().map { index, memory in
            totalPerformance += memory.performanceScore
            return LearningEffectPoint(
                id: UUID(),
                workspaceID: workspaceID,
                taskID: memory.taskID,
                taskType: memory.taskType,
                executionIndex: index + 1,
                performanceScore: memory.performanceScore,
                failureCount: memory.failureSignatures.count,
                movingAveragePerformance: totalPerformance / Double(index + 1),
                createdAt: memory.createdAt
            )
        }
    }

    private func summary(avoidedCommands: [String], profile: SystemFailureProfile, curve: [LearningEffectPoint]) -> String {
        let commandSummary = avoidedCommands.isEmpty ? "no avoided tools" : "avoid \(avoidedCommands.joined(separator: ", "))"
        let recurring = profile.recurringSignatures.isEmpty ? "no recurring signatures" : "\(profile.recurringSignatures.count) recurring signature(s)"
        let latestAverage = curve.last.map { String(format: "%.1f", $0.movingAveragePerformance) } ?? "n/a"
        return "Global strategy: \(commandSummary); \(recurring); learning average \(latestAverage)."
    }
}
