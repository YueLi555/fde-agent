import Foundation

enum OutcomeEvidenceKind: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case completion = "COMPLETION"
    case execution = "EXECUTION"
    case observation = "OBSERVATION"
    case failure = "FAILURE"
    case artifact = "ARTIFACT"
    case approval = "APPROVAL"
    case environment = "ENVIRONMENT"

    var id: String { rawValue }
}

struct OutcomeEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var kind: OutcomeEvidenceKind
    var title: String
    var detail: String
    var sourceEventID: UUID?
}

struct OutcomeMetric: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var value: String
    var unit: String?
    var sourceEventID: UUID?
}

struct OutcomeMemoryFeedback: Codable, Hashable, Sendable {
    var successfulSolutions: [String]
    var failurePatterns: [String]
    var customerEnvironmentKnowledge: [String]

    static let empty = OutcomeMemoryFeedback(
        successfulSolutions: [],
        failurePatterns: [],
        customerEnvironmentKnowledge: []
    )
}

struct OutcomeRecord: Identifiable, Codable, Hashable, Sendable {
    let missionID: UUID
    var objective: String
    var expectedOutcome: String
    var achievedOutcome: String
    var successCriteria: [String]
    var finalState: MissionState
    var evidence: [OutcomeEvidence]
    var impactSummary: String
    var businessImpact: [String]
    var metricsBefore: [OutcomeMetric]
    var metricsAfter: [OutcomeMetric]
    var lessonsLearned: [String]
    var followUpRecommendations: [String]
    var createdAt: Date

    var id: UUID { missionID }
}

struct OutcomeTrackingLayer: Sendable {
    func record(
        missionID: UUID,
        objective: String,
        expectedOutcome: String? = nil,
        finalState: MissionState,
        events: [ExecutionEvent],
        observations: [ToolObservation] = [],
        worldModel: SystemWorldModel? = nil,
        task: FDETask? = nil,
        createdAt: Date = Date()
    ) -> OutcomeRecord {
        let orderedEvents = events.sortedByOutcomeOrder()
        let safeObjective = safe(objective, fallback: task?.title ?? "Autonomous mission")
        let evidence = outcomeEvidence(
            events: orderedEvents,
            observations: observations,
            worldModel: worldModel
        )
        let metricsBefore = metrics(from: orderedEvents, phase: .before)
        let metricsAfter = metrics(from: orderedEvents, phase: .after)
        let explicitExpectedOutcome = firstPayloadValue(orderedEvents, keys: ["expected_outcome", "outcome_expected"])
        let explicitSuccessCriteria = firstPayloadValue(orderedEvents, keys: ["success_criteria"])
        let explicitImpact = firstPayloadValue(orderedEvents, keys: ["impact_summary", "business_impact", "customer_impact"])
        let explicitFollowUps = firstPayloadValue(orderedEvents, keys: ["follow_up_recommendations", "follow_ups"])
        let explicitLessons = firstPayloadValue(orderedEvents, keys: ["lessons_learned", "lesson_learned"])
        let failureReason = failureReason(events: orderedEvents, observations: observations)

        return OutcomeRecord(
            missionID: missionID,
            objective: safeObjective,
            expectedOutcome: expectedOutcome
                .flatMap { safeOptional($0) }
                ?? explicitExpectedOutcome
                ?? "Mission objective: \(safeObjective)",
            achievedOutcome: achievedOutcome(
                finalState: finalState,
                events: orderedEvents,
                observations: observations,
                failureReason: failureReason
            ),
            successCriteria: splitList(explicitSuccessCriteria).ifEmpty([
                "Complete the stated mission objective",
                "Attach runtime evidence for the result"
            ]),
            finalState: finalState,
            evidence: evidence,
            impactSummary: explicitImpact ?? impactSummary(
                finalState: finalState,
                evidence: evidence,
                metricsBefore: metricsBefore,
                metricsAfter: metricsAfter,
                failureReason: failureReason
            ),
            businessImpact: splitList(firstPayloadValue(orderedEvents, keys: ["business_impact_items", "impact_items"])),
            metricsBefore: metricsBefore,
            metricsAfter: metricsAfter,
            lessonsLearned: splitList(explicitLessons).ifEmpty(
                lessonsLearned(observations: observations, worldModel: worldModel, finalState: finalState)
            ),
            followUpRecommendations: splitList(explicitFollowUps).ifEmpty(
                followUpRecommendations(finalState: finalState, failureReason: failureReason)
            ),
            createdAt: createdAt
        )
    }

    func memoryFeedback(from record: OutcomeRecord) -> OutcomeMemoryFeedback {
        let environmentKnowledge = record.evidence
            .filter { $0.kind == .environment }
            .map(\.detail)
            + record.lessonsLearned

        if record.finalState == .complete {
            return OutcomeMemoryFeedback(
                successfulSolutions: uniqueOutcomeValues(
                    [record.achievedOutcome] + record.evidence
                        .filter { $0.kind == .execution || $0.kind == .completion || $0.kind == .artifact }
                        .map(\.detail)
                ),
                failurePatterns: record.evidence
                    .filter { $0.kind == .failure }
                    .map(\.detail),
                customerEnvironmentKnowledge: uniqueOutcomeValues(environmentKnowledge)
            )
        }

        return OutcomeMemoryFeedback(
            successfulSolutions: [],
            failurePatterns: uniqueOutcomeValues(
                [record.achievedOutcome] + record.evidence
                    .filter { $0.kind == .failure || $0.kind == .observation }
                    .map(\.detail)
            ),
            customerEnvironmentKnowledge: uniqueOutcomeValues(environmentKnowledge)
        )
    }

    static func inferredFinalState(task: FDETask?, events: [ExecutionEvent]) -> MissionState? {
        if task?.state == .completed || events.contains(where: { $0.type == .taskCompleted }) {
            return .complete
        }
        if task?.state == .failed
            || events.contains(where: { [.authorizationDenied, .humanRejected, .userApprovalRejected].contains($0.type) }) {
            return .adapt
        }
        return events
            .sortedByOutcomeOrder()
            .last?
            .payload["mission_state"]
            .flatMap(MissionState.init(rawValue:))
    }

    private enum MetricPhase {
        case before
        case after

        var prefixes: [String] {
            switch self {
            case .before:
                return ["metric_before_", "metrics_before_", "business_metric_before_"]
            case .after:
                return ["metric_after_", "metrics_after_", "business_metric_after_"]
            }
        }
    }

    private func outcomeEvidence(
        events: [ExecutionEvent],
        observations: [ToolObservation],
        worldModel: SystemWorldModel?
    ) -> [OutcomeEvidence] {
        var evidence = events.compactMap(eventEvidence)
        evidence += observations.enumerated().map { index, observation in
            OutcomeEvidence(
                id: "observation-\(index)",
                kind: observation.outcome == .failed ? .failure : .observation,
                title: observation.outcome == .failed ? "Failed observation" : "Observation",
                detail: safe(observation.summary, fallback: observation.outcome.rawValue),
                sourceEventID: nil
            )
        }

        if let worldModel {
            let facts = (worldModel.connectedSystems + worldModel.environmentFacts + worldModel.observations + worldModel.evidence)
                .prefix(8)
                .map { safe($0, fallback: "Environment fact") }
            evidence += facts.enumerated().map { index, fact in
                OutcomeEvidence(
                    id: "environment-\(index)",
                    kind: .environment,
                    title: "Environment knowledge",
                    detail: fact,
                    sourceEventID: nil
                )
            }
        }

        return uniqueEvidence(evidence)
    }

    private func eventEvidence(_ event: ExecutionEvent) -> OutcomeEvidence? {
        let kind: OutcomeEvidenceKind
        let title: String
        let fallback: String

        switch event.type {
        case .taskCompleted:
            kind = .completion
            title = "Completion"
            fallback = "Mission completed"
        case .stepExecuted,
             .toolCalled,
             .connectorExecuted,
             .executionResponseReceived,
             .workerTaskCompleted:
            kind = .execution
            title = "Execution"
            fallback = "Execution evidence captured"
        case .toolFailed,
             .connectorFailed,
             .authorizationDenied,
             .nodeExecutionFailed,
             .workerTaskFailed:
            kind = .failure
            title = "Failure"
            fallback = "Failure evidence captured"
        case .feedbackGenerated,
             .policyUpdated:
            kind = .artifact
            title = "Artifact"
            fallback = "Artifact generated"
        case .humanApprovalRequested,
             .humanApproved,
             .humanRejected,
             .userApprovalGranted,
             .userApprovalRejected:
            kind = .approval
            title = "Approval"
            fallback = "Approval evidence captured"
        case .contextCompiled,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned:
            kind = .environment
            title = "Environment"
            fallback = "Environment evidence captured"
        default:
            return nil
        }

        return OutcomeEvidence(
            id: "event-\(event.id.uuidString)",
            kind: kind,
            title: title,
            detail: evidenceDetail(event: event, fallback: fallback),
            sourceEventID: event.id
        )
    }

    private func evidenceDetail(event: ExecutionEvent, fallback: String) -> String {
        let detail = event.payload["detail"]
            ?? event.payload["observation_summary"]
            ?? event.payload["agent_decision_summary"]
            ?? event.payload["agent_work_trace_detail"]
            ?? event.summary
        return safe(detail, fallback: fallback)
    }

    private func metrics(from events: [ExecutionEvent], phase: MetricPhase) -> [OutcomeMetric] {
        var metrics: [OutcomeMetric] = []
        for event in events {
            for (key, value) in event.payload {
                guard let prefix = phase.prefixes.first(where: { key.hasPrefix($0) }) else { continue }
                let name = key.dropFirst(prefix.count)
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, let parsed = parseMetricValue(value) else { continue }
                metrics.append(
                    OutcomeMetric(
                        id: "\(phase)-\(event.id.uuidString)-\(key)",
                        name: safe(name, fallback: "Metric"),
                        value: parsed.value,
                        unit: parsed.unit,
                        sourceEventID: event.id
                    )
                )
            }
        }
        return metrics
    }

    private func parseMetricValue(_ rawValue: String) -> (value: String, unit: String?)? {
        let safeValue = safe(rawValue, fallback: "")
        guard !safeValue.isEmpty else { return nil }
        let separators = CharacterSet(charactersIn: " ")
        let parts = safeValue.components(separatedBy: separators).filter { !$0.isEmpty }
        guard let value = parts.first else { return nil }
        let unit = parts.dropFirst().joined(separator: " ")
        return (value: value, unit: unit.isEmpty ? nil : unit)
    }

    private func achievedOutcome(
        finalState: MissionState,
        events: [ExecutionEvent],
        observations: [ToolObservation],
        failureReason: String?
    ) -> String {
        if finalState == .complete {
            let completion = events.last(where: { $0.type == .taskCompleted })
                .map { evidenceDetail(event: $0, fallback: "Mission completed") }
            let observation = observations.last(where: { $0.outcome == .succeeded })?.summary
            return completion ?? observation.map { safe($0, fallback: "Mission completed") } ?? "Mission completed."
        }

        if let failureReason {
            return "Mission stopped in \(finalState.rawValue): \(failureReason)"
        }
        return "Mission stopped in \(finalState.rawValue)."
    }

    private func impactSummary(
        finalState: MissionState,
        evidence: [OutcomeEvidence],
        metricsBefore: [OutcomeMetric],
        metricsAfter: [OutcomeMetric],
        failureReason: String?
    ) -> String {
        if !metricsBefore.isEmpty || !metricsAfter.isEmpty {
            return "Business metrics were captured from runtime evidence."
        }
        if finalState == .complete {
            return "Mission completed with \(evidence.count) evidence item\(evidence.count == 1 ? "" : "s"). No explicit business metrics were recorded."
        }
        if let failureReason {
            return "Mission did not complete: \(failureReason). No explicit business metrics were recorded."
        }
        return "No explicit business metrics were recorded."
    }

    private func failureReason(events: [ExecutionEvent], observations: [ToolObservation]) -> String? {
        if let failedObservation = observations.last(where: { $0.outcome == .failed }) {
            return safe(failedObservation.summary, fallback: "Execution failed")
        }
        let failedEventTypes: Set<EventType> = [
            .toolFailed,
            .connectorFailed,
            .authorizationDenied,
            .humanRejected,
            .userApprovalRejected,
            .nodeExecutionFailed,
            .workerTaskFailed
        ]
        if let event = events.last(where: { failedEventTypes.contains($0.type) }) {
            return evidenceDetail(event: event, fallback: "Execution failed")
        }
        if let stopReason = events.reversed().compactMap({ $0.payload["agent_loop_stop_reason"] }).first {
            return safe(stopReason, fallback: "Mission stopped")
        }
        return nil
    }

    private func lessonsLearned(
        observations: [ToolObservation],
        worldModel: SystemWorldModel?,
        finalState: MissionState
    ) -> [String] {
        let observationLessons = observations
            .suffix(4)
            .map { safe($0.summary, fallback: $0.outcome.rawValue) }
        let worldLessons = (worldModel?.connectedSystems ?? [])
            .prefix(4)
            .map { "Connected system: \(safe($0, fallback: "system"))" }
        let stateLesson = finalState == .complete
            ? "Successful outcome can be reused as prior solution context."
            : "Failure outcome should be reused as a pattern to avoid or recover from."
        return uniqueOutcomeValues(observationLessons + worldLessons + [stateLesson])
    }

    private func followUpRecommendations(finalState: MissionState, failureReason: String?) -> [String] {
        if finalState == .complete {
            return [
                "Review outcome evidence with the customer.",
                "Capture reusable solution notes in FDE memory."
            ]
        }
        if let failureReason {
            return [
                "Review failure reason: \(failureReason)",
                "Update the plan before retrying the mission."
            ]
        }
        return ["Review runtime evidence before continuing."]
    }

    private func firstPayloadValue(_ events: [ExecutionEvent], keys: [String]) -> String? {
        for event in events.reversed() {
            for key in keys {
                if let value = safeOptional(event.payload[key]) {
                    return value
                }
            }
        }
        return nil
    }

    private func splitList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .components(separatedBy: CharacterSet(charactersIn: "|\n,"))
            .map { safe($0, fallback: "") }
            .filter { !$0.isEmpty }
    }

    private func safeOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let safeValue = safe(value, fallback: "")
        return safeValue.isEmpty ? nil : safeValue
    }

    private func safe(_ value: String, fallback: String) -> String {
        let sanitized = AgentPresentationSanitizer.safeContent(value, fallback: fallback)
        guard !AgentPresentationSanitizer.containsRestrictedContent(sanitized) else {
            return fallback
        }
        return sanitized
    }

    private func uniqueEvidence(_ evidence: [OutcomeEvidence]) -> [OutcomeEvidence] {
        var seen = Set<String>()
        var result: [OutcomeEvidence] = []
        for item in evidence {
            let key = "\(item.kind.rawValue)|\(item.detail)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private func uniqueOutcomeValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let safeValue = safe(value, fallback: "")
            guard !safeValue.isEmpty, !seen.contains(safeValue) else { continue }
            seen.insert(safeValue)
            result.append(safeValue)
        }
        return result
    }
}

private extension Array where Element == String {
    func ifEmpty(_ fallback: [String]) -> [String] {
        isEmpty ? fallback : self
    }
}

private extension Array where Element == ExecutionEvent {
    func sortedByOutcomeOrder() -> [ExecutionEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
