import Foundation

struct FailurePatternMiner: Sendable {
    func profile(workspaceID: UUID, memories: [TaskExecutionMemory]) -> SystemFailureProfile {
        let failures = memories.flatMap { memory in
            memory.failureSignatures.map { signature in
                FailureSeed(memory: memory, signature: signature)
            }
        }

        let grouped = Dictionary(grouping: failures, by: \.signature)
        let clusters = grouped.map { signature, seeds in
            let sortedSeeds = seeds.sorted { $0.memory.createdAt < $1.memory.createdAt }
            let first = sortedSeeds.first?.memory.createdAt ?? Date()
            let last = sortedSeeds.last?.memory.createdAt ?? first
            let parsed = parse(signature: signature)
            let summaries = sortedSeeds.map { memorySummary($0.memory) }

            return FailureCluster(
                id: signature,
                workspaceID: workspaceID,
                signature: signature,
                taskType: parsed.taskType,
                cause: parsed.cause,
                toolCommand: parsed.command == "unknown" ? nil : parsed.command,
                frequency: seeds.count,
                affectedTaskIDs: Array(Set(seeds.map(\.memory.taskID))).sorted { $0.uuidString < $1.uuidString },
                latestSummary: summaries.last ?? "No failure summary",
                firstSeenAt: first,
                lastSeenAt: last
            )
        }
        .sorted { lhs, rhs in
            if lhs.frequency == rhs.frequency {
                return lhs.signature < rhs.signature
            }
            return lhs.frequency > rhs.frequency
        }

        let taskTypeFailureCounts = Dictionary(grouping: clusters, by: \.taskType)
            .mapValues { clusters in clusters.reduce(0) { $0 + $1.frequency } }

        return SystemFailureProfile(
            id: UUID(),
            workspaceID: workspaceID,
            clusters: clusters,
            recurringSignatures: clusters.filter { $0.frequency >= 2 }.map(\.signature),
            taskTypeFailureCounts: taskTypeFailureCounts,
            generatedAt: Date()
        )
    }

    func insights(workspaceID: UUID, profile: SystemFailureProfile) -> [SystemLevelInsight] {
        var insights: [SystemLevelInsight] = []

        for cluster in profile.clusters {
            let kind: SystemInsightKind = cluster.frequency >= 2 ? .recurringFailure : .toolReliability
            insights.append(
                SystemLevelInsight(
                    id: UUID(),
                    workspaceID: workspaceID,
                    kind: kind,
                    taskType: cluster.taskType,
                    failureSignature: cluster.signature,
                    title: cluster.frequency >= 2
                        ? "Recurring \(cluster.taskType) failure"
                        : "Observed \(cluster.taskType) tool failure",
                    detail: "\(cluster.frequency) failure(s) from \(cluster.toolCommand ?? "unknown tool") caused by \(cluster.cause.rawValue). Latest: \(cluster.latestSummary)",
                    frequency: cluster.frequency,
                    createdAt: Date()
                )
            )
        }

        for (taskType, count) in profile.taskTypeFailureCounts where count > 0 {
            insights.append(
                SystemLevelInsight(
                    id: UUID(),
                    workspaceID: workspaceID,
                    kind: .taskTypeRisk,
                    taskType: taskType,
                    failureSignature: nil,
                    title: "\(taskType) failure concentration",
                    detail: "\(count) failure signal(s) explain why this task type is risky.",
                    frequency: count,
                    createdAt: Date()
                )
            )
        }

        return insights.sorted { lhs, rhs in
            if lhs.frequency == rhs.frequency {
                return lhs.title < rhs.title
            }
            return lhs.frequency > rhs.frequency
        }
    }

    private struct FailureSeed {
        let memory: TaskExecutionMemory
        let signature: String
    }

    private func parse(signature: String) -> (taskType: String, cause: FailureClusterCause, command: String) {
        let parts = signature.split(separator: "|").map(String.init)
        let taskType = parts.indices.contains(0) ? parts[0] : "unknown"
        let cause = parts.indices.contains(1) ? FailureClusterCause(rawValue: parts[1]) ?? .unknown : .unknown
        let command = parts.indices.contains(2) ? parts[2] : "unknown"
        return (taskType, cause, command)
    }

    private func memorySummary(_ memory: TaskExecutionMemory) -> String {
        "\(memory.taskType) task \(memory.taskID.uuidString.prefix(8)) scored \(Int(memory.performanceScore)) with \(memory.failureSignatures.count) failure(s)."
    }
}
