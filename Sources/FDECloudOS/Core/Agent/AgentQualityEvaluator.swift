import Foundation

struct AgentQualityEvaluation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var planningAccuracy: Double
    var executionEfficiency: Double
    var recoverySuccess: Double
    var unnecessaryActionCount: Int
    var humanInterventionQuality: Double
    var policyViolations: Int
    var outcomeAchievement: Double
    var overallScore: Double
    var summary: String
    var createdAt: Date
}

struct MissionReflection: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var qualityEvaluationID: UUID?
    var whatWorked: [String]
    var whatFailed: [String]
    var improvementSuggestions: [String]
    var reusableKnowledge: [String]
    var createdAt: Date
}

struct MissionLearningUpdate: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var succeeded: Bool
    var solutionPatterns: [String]
    var environmentPatterns: [String]
    var riskPatterns: [String]
    var failureSignatures: [String]
    var preventionRules: [String]
    var taskExecutionMemory: TaskExecutionMemory
    var enterpriseMemoryEntries: [MemoryEntry]
    var createdAt: Date
}

struct AgentBenchmarkSummary: Codable, Hashable, Sendable {
    var missionCount: Int
    var successRate: Double
    var recoveryRate: Double
    var approvalEfficiency: Double
    var averageQualityScore: Double
    var commonFailurePatterns: [String]

    static let empty = AgentBenchmarkSummary(
        missionCount: 0,
        successRate: 0,
        recoveryRate: 0,
        approvalEfficiency: 0,
        averageQualityScore: 0,
        commonFailurePatterns: []
    )
}

struct AgentQualityEvaluator: Sendable {
    func evaluate(
        replay: MissionReplay,
        outcome: OutcomeRecord? = nil,
        events: [ExecutionEvent] = [],
        task: FDETask? = nil,
        createdAt: Date = Date()
    ) -> AgentQualityEvaluation {
        let orderedEvents = ordered(events)
        let outcomeAchievement = outcomeAchievement(replay: replay, outcome: outcome, task: task)
        let unnecessaryActions = unnecessaryActionCount(events: orderedEvents)
        let policyViolations = policyViolationCount(replay: replay, events: orderedEvents)
        let planningAccuracy = planningAccuracy(
            replay: replay,
            events: orderedEvents,
            task: task,
            outcomeAchievement: outcomeAchievement
        )
        let executionEfficiency = executionEfficiency(
            events: orderedEvents,
            outcomeAchievement: outcomeAchievement,
            unnecessaryActionCount: unnecessaryActions
        )
        let recoverySuccess = recoverySuccess(events: orderedEvents, replay: replay)
        let humanInterventionQuality = humanInterventionQuality(
            replay: replay,
            events: orderedEvents,
            outcomeAchievement: outcomeAchievement
        )
        let policyCompliance = max(0, 1 - Double(policyViolations) * 0.35)
        let weightedScore = planningAccuracy * 0.18
            + executionEfficiency * 0.18
            + recoverySuccess * 0.14
            + humanInterventionQuality * 0.12
            + policyCompliance * 0.12
            + outcomeAchievement * 0.26
        let penalty = min(0.25, Double(unnecessaryActions) * 0.03)
        let overallScore = clamp01(weightedScore - penalty) * 100

        return AgentQualityEvaluation(
            id: UUID(),
            workspaceID: replay.workspaceID,
            taskID: replay.taskID,
            planningAccuracy: planningAccuracy,
            executionEfficiency: executionEfficiency,
            recoverySuccess: recoverySuccess,
            unnecessaryActionCount: unnecessaryActions,
            humanInterventionQuality: humanInterventionQuality,
            policyViolations: policyViolations,
            outcomeAchievement: outcomeAchievement,
            overallScore: overallScore,
            summary: qualitySummary(score: overallScore, outcomeAchievement: outcomeAchievement, policyViolations: policyViolations),
            createdAt: createdAt
        )
    }

    func reflect(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        evidence: [OutcomeEvidence] = [],
        errors: [String] = [],
        humanDecisions: [String] = [],
        evaluation: AgentQualityEvaluation? = nil,
        createdAt: Date = Date()
    ) -> MissionReflection {
        let worked = whatWorked(
            replay: replay,
            outcome: outcome,
            evidence: evidence,
            humanDecisions: humanDecisions,
            evaluation: evaluation
        )
        let failed = whatFailed(
            replay: replay,
            outcome: outcome,
            errors: errors,
            evaluation: evaluation
        )
        let suggestions = improvementSuggestions(
            replay: replay,
            outcome: outcome,
            evaluation: evaluation,
            errors: errors
        )
        let knowledge = reusableKnowledge(
            replay: replay,
            outcome: outcome,
            evidence: evidence,
            evaluation: evaluation
        )

        return MissionReflection(
            id: UUID(),
            workspaceID: replay.workspaceID,
            taskID: replay.taskID,
            qualityEvaluationID: evaluation?.id,
            whatWorked: worked,
            whatFailed: failed,
            improvementSuggestions: suggestions,
            reusableKnowledge: knowledge,
            createdAt: createdAt
        )
    }

    func benchmark(
        tasks: [FDETask],
        events: [ExecutionEvent],
        approvals: [ApprovalRequest],
        memories: [TaskExecutionMemory]
    ) -> AgentBenchmarkSummary {
        let taskIDs = Set(tasks.map(\.id) + memories.map(\.taskID) + events.compactMap(\.taskID))
        let missionCount = taskIDs.count
        guard missionCount > 0 else { return .empty }

        let completedTaskIDs = Set(tasks.filter { $0.state == .completed }.map(\.id))
            .union(memories.filter { $0.state == .completed }.map(\.taskID))
        let successRate = Double(completedTaskIDs.count) / Double(missionCount)

        let recoveryEvents = events.filter { $0.type == .recoveryAttempted }
        let recoveryTaskIDs = Set(recoveryEvents.compactMap(\.taskID))
        let recoveredTaskIDs = Set(
            recoveryTaskIDs.filter { taskID in
                completedTaskIDs.contains(taskID)
                    || events.contains { $0.taskID == taskID && $0.type == .taskCompleted }
            }
        )
        let recoveryRate = recoveryEvents.isEmpty
            ? 1
            : Double(recoveredTaskIDs.count) / Double(max(recoveryTaskIDs.count, 1))

        let decidedApprovals = approvals.filter { $0.state != .pending }
        let approvalEfficiency = decidedApprovals.isEmpty
            ? 1
            : Double(decidedApprovals.filter { $0.state == .approved }.count) / Double(decidedApprovals.count)

        let qualityScores = memories.map(\.performanceScore).filter { $0 > 0 }
            + tasks.map(\.performanceScore).filter { $0 > 0 }
        let averageQualityScore = qualityScores.isEmpty
            ? successRate * 100
            : qualityScores.reduce(0, +) / Double(qualityScores.count)

        return AgentBenchmarkSummary(
            missionCount: missionCount,
            successRate: clamp01(successRate),
            recoveryRate: clamp01(recoveryRate),
            approvalEfficiency: clamp01(approvalEfficiency),
            averageQualityScore: min(100, max(0, averageQualityScore)),
            commonFailurePatterns: commonFailurePatterns(memories: memories, events: events)
        )
    }

    private func planningAccuracy(
        replay: MissionReplay,
        events: [ExecutionEvent],
        task: FDETask?,
        outcomeAchievement: Double
    ) -> Double {
        let plannedStepIDs = Set(task?.plan.map(\.id) ?? [])
        let executedStepIDs = Set(replay.actions.compactMap(\.stepID))
        let failedStepIDs = Set(events.filter { $0.type == .toolFailed || $0.type == .connectorFailed }.compactMap { $0.payload["step_id"] })
        let plannedCount = max(plannedStepIDs.count, executedStepIDs.count)

        guard plannedCount > 0 else {
            return replay.agentDecisions.isEmpty ? max(0.35, outcomeAchievement * 0.7) : max(0.55, outcomeAchievement * 0.85)
        }

        let coveredSteps = plannedStepIDs.isEmpty
            ? executedStepIDs.count
            : plannedStepIDs.intersection(executedStepIDs).count
        let coverage = Double(coveredSteps) / Double(plannedCount)
        let failurePenalty = min(0.35, Double(failedStepIDs.count) / Double(max(plannedCount, 1)) * 0.35)
        return clamp01(coverage - failurePenalty + outcomeAchievement * 0.12)
    }

    private func executionEfficiency(
        events: [ExecutionEvent],
        outcomeAchievement: Double,
        unnecessaryActionCount: Int
    ) -> Double {
        let callCount = events.filter { [.toolCalled, .connectorCalled, .connectorExecuted].contains($0.type) }.count
        let successCount = events.filter { [.stepExecuted, .connectorExecuted, .workerTaskCompleted].contains($0.type) }.count
        let failureCount = events.filter { [.toolFailed, .connectorFailed, .nodeExecutionFailed, .workerTaskFailed].contains($0.type) }.count
        let retryCount = events.filter { event in
            event.payload["retry"] == "true" || Int(event.payload["attempt"] ?? "1").map { $0 > 1 } == true
        }.count

        guard callCount > 0 else {
            return outcomeAchievement > 0 ? 0.82 : 0.45
        }

        let successRatio = Double(successCount) / Double(max(callCount, 1))
        let failurePenalty = min(0.35, Double(failureCount) / Double(max(callCount, 1)) * 0.35)
        let retryPenalty = min(0.18, Double(retryCount) / Double(max(callCount, 1)) * 0.18)
        let duplicatePenalty = min(0.18, Double(unnecessaryActionCount) * 0.06)
        return clamp01(successRatio - failurePenalty - retryPenalty - duplicatePenalty + outcomeAchievement * 0.12)
    }

    private func recoverySuccess(events: [ExecutionEvent], replay: MissionReplay) -> Double {
        let recoveryEvents = events.filter { $0.type == .recoveryAttempted }
        guard !recoveryEvents.isEmpty else { return 1 }

        let successfulRecoveries = recoveryEvents.filter { recoveryEvent in
            events.contains { event in
                event.sequence > recoveryEvent.sequence
                    && event.taskID == recoveryEvent.taskID
                    && [.stepExecuted, .taskCompleted, .workerTaskCompleted].contains(event.type)
            } || replay.outcome?.completed == true
        }
        return clamp01(Double(successfulRecoveries.count) / Double(recoveryEvents.count))
    }

    private func humanInterventionQuality(
        replay: MissionReplay,
        events: [ExecutionEvent],
        outcomeAchievement: Double
    ) -> Double {
        let replayApprovals = replay.approvals
        let eventApprovalCount = events.filter { $0.type == .humanApprovalRequested }.count
        let totalApprovalCount = max(replayApprovals.count, eventApprovalCount)
        guard totalApprovalCount > 0 else { return 1 }

        let approvedCount = replayApprovals.filter { $0.state == .approved }.count
            + events.filter { [.humanApproved, .userApprovalGranted].contains($0.type) }.count
        let rejectedCount = replayApprovals.filter { $0.state == .rejected || $0.state == .expired }.count
            + events.filter { [.humanRejected, .userApprovalRejected].contains($0.type) }.count
        let resolvedCount = max(approvedCount + rejectedCount, totalApprovalCount)
        let approvalRatio = Double(approvedCount) / Double(max(resolvedCount, 1))
        let rejectionPenalty = min(0.35, Double(rejectedCount) / Double(max(resolvedCount, 1)) * 0.35)
        return clamp01(approvalRatio - rejectionPenalty + outcomeAchievement * 0.2)
    }

    private func policyViolationCount(replay: MissionReplay, events: [ExecutionEvent]) -> Int {
        let deniedEvents = events.filter { event in
            event.type == .authorizationDenied
                || event.payload["policy_decision"] == PolicyDecisionStatus.denied.rawValue
        }
        let deniedActions = replay.actions.filter { $0.policyDecision == .denied }
        return Set(deniedEvents.map(\.id) + deniedActions.map(\.id)).count
    }

    private func unnecessaryActionCount(events: [ExecutionEvent]) -> Int {
        var seenSuccessfulCommands = Set<String>()
        var duplicates = 0
        for event in events where [.toolCalled, .connectorCalled, .connectorExecuted].contains(event.type) {
            let command = event.payload["command"]?.qualityClean ?? ""
            guard !command.isEmpty else { continue }
            let key = "\(event.payload["step_id"] ?? "")|\(command)"
            let isRetry = event.payload["retry"] == "true" || Int(event.payload["attempt"] ?? "1").map { $0 > 1 } == true
            if seenSuccessfulCommands.contains(key), !isRetry {
                duplicates += 1
            }
            if !isRetry {
                seenSuccessfulCommands.insert(key)
            }
        }

        let noEffectFailures = events.filter { event in
            [.toolFailed, .connectorFailed].contains(event.type)
                && !events.contains { later in
                    later.sequence > event.sequence
                        && later.taskID == event.taskID
                        && [.recoveryAttempted, .stepExecuted, .taskCompleted].contains(later.type)
                }
        }.count
        return duplicates + noEffectFailures
    }

    private func outcomeAchievement(replay: MissionReplay, outcome: OutcomeRecord?, task: FDETask?) -> Double {
        if outcome?.finalState == .complete || replay.outcome?.completed == true || task?.state == .completed {
            return 1
        }
        if task?.state == .failed {
            return 0
        }
        if outcome != nil || replay.outcome != nil {
            return 0.35
        }
        return 0
    }

    private func qualitySummary(score: Double, outcomeAchievement: Double, policyViolations: Int) -> String {
        if policyViolations > 0 {
            return "Mission quality constrained by governance violations."
        }
        if outcomeAchievement >= 1, score >= 85 {
            return "Mission completed with strong planning, execution, and governance quality."
        }
        if outcomeAchievement >= 1 {
            return "Mission completed with improvement opportunities in execution quality."
        }
        return "Mission did not fully achieve the requested outcome."
    }

    private func whatWorked(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        evidence: [OutcomeEvidence],
        humanDecisions: [String],
        evaluation: AgentQualityEvaluation?
    ) -> [String] {
        var values: [String] = []
        if outcome?.finalState == .complete || replay.outcome?.completed == true {
            values.append(outcome?.achievedOutcome ?? replay.outcome?.summary ?? "Mission reached a completed outcome.")
        }
        if evaluation?.policyViolations == 0 {
            values.append("Governance checks completed without policy violations.")
        }
        if evaluation?.recoverySuccess ?? 1 >= 1, replay.actions.contains(where: { $0.eventType == .toolFailed }) {
            values.append("Recovery handling restored progress after a failed action.")
        }
        values += humanDecisions.prefix(3).map { "Human decision captured: \(safe($0, fallback: "decision"))" }
        values += evidence.filter { $0.kind == .completion || $0.kind == .execution }.prefix(3).map(\.detail)
        return unique(values).ifEmpty(["Runtime captured enough evidence to evaluate mission quality."])
    }

    private func whatFailed(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        errors: [String],
        evaluation: AgentQualityEvaluation?
    ) -> [String] {
        var values = errors.map { safe($0, fallback: "Execution error") }
        values += outcome?.evidence.filter { $0.kind == .failure }.map(\.detail) ?? []
        values += replay.evidence
            .filter { [.toolFailed, .connectorFailed, .authorizationDenied, .humanRejected, .userApprovalRejected].contains($0.sourceEventType) }
            .map(\.detail)
        if let evaluation, evaluation.policyViolations > 0 {
            values.append("\(evaluation.policyViolations) policy violation\(evaluation.policyViolations == 1 ? "" : "s") blocked or invalidated execution.")
        }
        if let evaluation, evaluation.unnecessaryActionCount > 0 {
            values.append("\(evaluation.unnecessaryActionCount) unnecessary action\(evaluation.unnecessaryActionCount == 1 ? "" : "s") reduced execution efficiency.")
        }
        values += replay.auditGaps
        return unique(values).ifEmpty(["No blocking failure was identified in the captured replay."])
    }

    private func improvementSuggestions(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        evaluation: AgentQualityEvaluation?,
        errors: [String]
    ) -> [String] {
        var values = outcome?.followUpRecommendations ?? []
        if let evaluation {
            if evaluation.planningAccuracy < 0.75 {
                values.append("Tighten planning so each planned step maps to an executed, observable action.")
            }
            if evaluation.executionEfficiency < 0.75 {
                values.append("Reduce duplicate, failed, or retry-heavy actions before execution.")
            }
            if evaluation.humanInterventionQuality < 0.75 {
                values.append("Provide clearer approval context so human decisions are faster and more decisive.")
            }
            if evaluation.policyViolations > 0 {
                values.append("Run risk and policy evaluation before scheduling production or destructive actions.")
            }
        }
        if !errors.isEmpty {
            values.append("Convert recurring errors into prevention rules before retrying similar missions.")
        }
        if !replay.isAuditComplete {
            values.append("Fill replay audit gaps before using this mission as trusted training memory.")
        }
        return unique(values).ifEmpty(["Keep the current operating pattern for similar low-risk missions."])
    }

    private func reusableKnowledge(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        evidence: [OutcomeEvidence],
        evaluation: AgentQualityEvaluation?
    ) -> [String] {
        var values = outcome?.lessonsLearned ?? []
        values += evidence.filter { $0.kind == .environment }.map(\.detail)
        values += replay.actions.compactMap { action in
            guard let command = action.command?.qualityClean, !command.isEmpty else { return nil }
            return "Action pattern: \(command)"
        }
        if let evaluation, evaluation.overallScore >= 80 {
            values.append("Quality score \(Int(evaluation.overallScore)) indicates this mission can seed future task planning.")
        }
        return unique(values).prefixArray(8).ifEmpty(["Use the mission replay and outcome record as the reusable context source."])
    }

    private func commonFailurePatterns(memories: [TaskExecutionMemory], events: [ExecutionEvent]) -> [String] {
        let memoryPatterns = memories.flatMap(\.failureSignatures)
        let eventPatterns = events
            .filter { [.toolFailed, .connectorFailed, .authorizationDenied, .humanRejected, .userApprovalRejected].contains($0.type) }
            .map { event in
                [
                    event.payload["command"],
                    event.payload["risk_reasons"],
                    event.payload["policy_reasons"],
                    event.summary
                ]
                .compactMap(\.self)
                .first ?? event.type.rawValue
            }
        return top(values: memoryPatterns + eventPatterns, limit: 4)
    }

    private func top(values: [String], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for value in values {
            let clean = safe(value, fallback: "").qualityClean
            guard !clean.isEmpty else { continue }
            counts[clean, default: 0] += 1
        }
        return counts
            .sorted {
                if $0.value == $1.value {
                    return $0.key < $1.key
                }
                return $0.value > $1.value
            }
            .prefix(limit)
            .map(\.key)
    }

    private func ordered(_ events: [ExecutionEvent]) -> [ExecutionEvent] {
        events.sorted {
            if $0.sequence == $1.sequence {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.sequence < $1.sequence
        }
    }

    private func safe(_ value: String, fallback: String) -> String {
        AgentPresentationSanitizer.safeContent(value, fallback: fallback)
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

struct AgentMemoryImprovementPipeline: Sendable {
    func update(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        evaluation: AgentQualityEvaluation,
        reflection: MissionReflection,
        task: FDETask? = nil,
        events: [ExecutionEvent] = [],
        createdAt: Date = Date()
    ) -> MissionLearningUpdate {
        let succeeded = outcome?.finalState == .complete || replay.outcome?.completed == true || task?.state == .completed
        let taskText = task?.rawInput.qualityClean ?? replay.userObjective.qualityClean
        let taskFingerprint = TaskFingerprint.make(from: taskText)
        let taskType = TaskTypeClassifier.classify(taskText)
        let toolCommands = unique(
            replay.actions.compactMap(\.command)
                + events.compactMap { $0.payload["command"] }
        )
        let failedCommands = unique(
            events
                .filter { [.toolFailed, .connectorFailed, .authorizationDenied].contains($0.type) }
                .compactMap { $0.payload["command"] }
        )
        let failureSignatures = succeeded
            ? []
            : failureSignatures(replay: replay, outcome: outcome, events: events, taskType: taskType)
        let solutionPatterns = succeeded ? solutionPatterns(replay: replay, outcome: outcome, reflection: reflection) : []
        let environmentPatterns = succeeded ? environmentPatterns(replay: replay, outcome: outcome) : []
        let riskPatterns = succeeded ? riskPatterns(replay: replay, events: events) : []
        let preventionRules = succeeded ? [] : preventionRules(reflection: reflection, failureSignatures: failureSignatures)
        let memory = TaskExecutionMemory(
            id: UUID(),
            workspaceID: replay.workspaceID,
            taskID: replay.taskID,
            taskFingerprint: taskFingerprint,
            taskType: taskType,
            state: task?.state ?? (succeeded ? .completed : .failed),
            planStepCount: task?.plan.count ?? Set(replay.actions.compactMap(\.stepID)).count,
            toolCommands: toolCommands,
            failedCommands: failedCommands,
            failureSignatures: unique(failureSignatures + preventionRules),
            riskScore: task?.riskScore ?? riskScore(replay: replay, events: events),
            performanceScore: evaluation.overallScore,
            createdAt: createdAt
        )
        let entries = enterpriseEntries(
            workspaceID: replay.workspaceID,
            taskID: replay.taskID,
            taskFingerprint: taskFingerprint,
            succeeded: succeeded,
            solutionPatterns: solutionPatterns,
            environmentPatterns: environmentPatterns,
            riskPatterns: riskPatterns,
            failureSignatures: failureSignatures,
            preventionRules: preventionRules,
            confidence: max(0.35, min(1, evaluation.overallScore / 100)),
            createdAt: createdAt
        )

        return MissionLearningUpdate(
            id: UUID(),
            workspaceID: replay.workspaceID,
            taskID: replay.taskID,
            succeeded: succeeded,
            solutionPatterns: solutionPatterns,
            environmentPatterns: environmentPatterns,
            riskPatterns: riskPatterns,
            failureSignatures: failureSignatures,
            preventionRules: preventionRules,
            taskExecutionMemory: memory,
            enterpriseMemoryEntries: entries,
            createdAt: createdAt
        )
    }

    func store(
        _ update: MissionLearningUpdate,
        persistence: any PersistenceStore,
        enterpriseMemoryStore: (any EnterpriseMemoryStoring)? = nil,
        saveTaskExecutionMemory: Bool = true
    ) async throws {
        if saveTaskExecutionMemory {
            try await persistence.saveTaskExecutionMemory(update.taskExecutionMemory)
        }
        if let enterpriseMemoryStore {
            for entry in update.enterpriseMemoryEntries {
                try await enterpriseMemoryStore.save(entry)
            }
        }
    }

    func reflectionFeedback(_ reflection: MissionReflection) -> FeedbackInsight {
        let detail = [
            section("What worked", reflection.whatWorked),
            section("What failed", reflection.whatFailed),
            section("Improvements", reflection.improvementSuggestions),
            section("Reusable knowledge", reflection.reusableKnowledge)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")

        return FeedbackInsight(
            id: UUID(),
            workspaceID: reflection.workspaceID,
            taskID: reflection.taskID,
            kind: .verificationReport,
            title: "Mission Reflection",
            detail: detail,
            createdAt: reflection.createdAt
        )
    }

    private func solutionPatterns(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        reflection: MissionReflection
    ) -> [String] {
        unique(
            [outcome?.achievedOutcome, replay.outcome?.summary].compactMap(\.self)
                + reflection.whatWorked
                + replay.actions.compactMap { action in
                    action.command.map { "Use \($0) for \(action.summary)" }
                }
        ).prefixArray(8)
    }

    private func environmentPatterns(replay: MissionReplay, outcome: OutcomeRecord?) -> [String] {
        unique(
            (outcome?.evidence.filter { $0.kind == .environment }.map(\.detail) ?? [])
                + replay.evidence
                .filter { $0.sourceEventType == .contextCompiled || $0.sourceEventType == .routingDecisionMade }
                .map(\.detail)
        ).prefixArray(8)
    }

    private func riskPatterns(replay: MissionReplay, events: [ExecutionEvent]) -> [String] {
        let approvalPatterns = replay.approvals.map {
            "\($0.riskLevel.rawValue.uppercased()) approval for \($0.action): \($0.resource)"
        }
        let eventPatterns = events.compactMap { event in
            (event.payload["risk_reasons"] ?? event.payload["risk_assessment_reasons"]).map {
                "\((event.payload["risk_level"] ?? event.payload["risk_assessment_level"] ?? "risk").uppercased()): \($0)"
            }
        }
        return unique(approvalPatterns + eventPatterns).prefixArray(8)
    }

    private func failureSignatures(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        events: [ExecutionEvent],
        taskType: String
    ) -> [String] {
        let eventSignatures = events
            .filter { [.toolFailed, .connectorFailed, .authorizationDenied, .humanRejected, .userApprovalRejected].contains($0.type) }
            .map { event in
                let command = event.payload["command"] ?? event.payload["resource"] ?? "unknown"
                let cause = TaskMemoryIndexer.failureCause(from: event).rawValue
                return "\(taskType)|\(cause)|\(command)|\(event.summary)"
            }
        let replayFailures = replay.evidence
            .filter { [.toolFailed, .connectorFailed, .authorizationDenied, .humanRejected, .userApprovalRejected].contains($0.sourceEventType) }
            .map { "\(taskType)|\( $0.sourceEventType.rawValue)|\($0.detail)" }
        let outcomeFailures = outcome?.evidence.filter { $0.kind == .failure }.map { "\(taskType)|OUTCOME|\($0.detail)" } ?? []
        return unique(eventSignatures + replayFailures + outcomeFailures + replay.auditGaps).prefixArray(10)
    }

    private func preventionRules(reflection: MissionReflection, failureSignatures: [String]) -> [String] {
        var values = reflection.improvementSuggestions
        values += failureSignatures.prefix(4).map { "Prevent recurrence of \($0)" }
        return unique(values).prefixArray(8)
    }

    private func enterpriseEntries(
        workspaceID: UUID,
        taskID: UUID,
        taskFingerprint: String,
        succeeded: Bool,
        solutionPatterns: [String],
        environmentPatterns: [String],
        riskPatterns: [String],
        failureSignatures: [String],
        preventionRules: [String],
        confidence: Double,
        createdAt: Date
    ) -> [MemoryEntry] {
        var entries: [MemoryEntry] = []
        entries += memoryEntries(
            workspaceID: workspaceID,
            taskID: taskID,
            taskFingerprint: taskFingerprint,
            type: .solutionMemory,
            title: "Solution pattern",
            values: solutionPatterns,
            tags: ["quality", "solution_pattern"],
            confidence: confidence,
            createdAt: createdAt
        )
        entries += memoryEntries(
            workspaceID: workspaceID,
            taskID: taskID,
            taskFingerprint: taskFingerprint,
            type: .systemMemory,
            title: "Environment pattern",
            values: environmentPatterns,
            tags: ["quality", "environment_pattern"],
            confidence: confidence,
            createdAt: createdAt
        )
        entries += memoryEntries(
            workspaceID: workspaceID,
            taskID: taskID,
            taskFingerprint: taskFingerprint,
            type: .executionMemory,
            title: "Risk pattern",
            values: riskPatterns,
            tags: ["quality", "risk_pattern"],
            confidence: confidence,
            createdAt: createdAt
        )
        entries += memoryEntries(
            workspaceID: workspaceID,
            taskID: taskID,
            taskFingerprint: taskFingerprint,
            type: .failureMemory,
            title: succeeded ? "Resolved failure pattern" : "Failure signature",
            values: failureSignatures,
            tags: ["quality", "failure_signature"],
            confidence: confidence,
            createdAt: createdAt
        )
        entries += memoryEntries(
            workspaceID: workspaceID,
            taskID: taskID,
            taskFingerprint: taskFingerprint,
            type: .executionMemory,
            title: "Prevention rule",
            values: preventionRules,
            tags: ["quality", "prevention_rule"],
            confidence: confidence,
            createdAt: createdAt
        )
        return entries
    }

    private func memoryEntries(
        workspaceID: UUID,
        taskID: UUID,
        taskFingerprint: String,
        type: EnterpriseMemoryType,
        title: String,
        values: [String],
        tags: [String],
        confidence: Double,
        createdAt: Date
    ) -> [MemoryEntry] {
        values.map { value in
            MemoryEntry(
                workspaceID: workspaceID,
                type: type,
                title: title,
                summary: value.qualityClean,
                detail: value.qualityClean,
                tags: tags,
                relatedTaskFingerprint: taskFingerprint,
                sourceTaskID: taskID,
                confidence: confidence,
                createdAt: createdAt,
                updatedAt: createdAt
            )
        }
    }

    private func riskScore(replay: MissionReplay, events: [ExecutionEvent]) -> Double {
        let replayRisk = replay.actions.compactMap(\.riskLevel).map(\.governanceRank).max() ?? 0
        let eventRisk = events.compactMap {
            ($0.payload["risk_level"] ?? $0.payload["risk_assessment_level"]).flatMap(RiskSeverity.init(rawValue:))
        }
        .map(\.governanceRank)
        .max() ?? 0
        return Double(max(replayRisk, eventRisk)) / 3 * 100
    }

    private func section(_ title: String, _ values: [String]) -> String {
        guard !values.isEmpty else { return "" }
        return "\(title):\n" + values.map { "- \($0.qualityClean)" }.joined(separator: "\n")
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
        let clean = AgentPresentationSanitizer.safeContent(value, fallback: "").qualityClean
        guard !clean.isEmpty, !seen.contains(clean) else { continue }
        seen.insert(clean)
        result.append(clean)
    }
    return result
}

private func clamp01(_ value: Double) -> Double {
    min(1, max(0, value))
}

private extension String {
    var qualityClean: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Array where Element == String {
    func ifEmpty(_ fallback: [String]) -> [String] {
        isEmpty ? fallback : self
    }

    func prefixArray(_ maxLength: Int) -> [String] {
        Array(prefix(maxLength))
    }
}
