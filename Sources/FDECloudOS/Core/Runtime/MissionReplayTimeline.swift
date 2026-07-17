import Foundation

enum MissionReplayStage: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case userGoal = "USER_GOAL"
    case discovery = "DISCOVERY"
    case teamFormation = "TEAM_FORMATION"
    case agentProposals = "AGENT_PROPOSALS"
    case conflicts = "CONFLICTS"
    case decisions = "DECISIONS"
    case approvals = "APPROVALS"
    case executions = "EXECUTIONS"
    case evidence = "EVIDENCE"
    case outcome = "OUTCOME"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .userGoal: return "User Goal"
        case .discovery: return "Discovery"
        case .teamFormation: return "Team Formation"
        case .agentProposals: return "Agent Proposals"
        case .conflicts: return "Conflicts"
        case .decisions: return "Decisions"
        case .approvals: return "Approvals"
        case .executions: return "Executions"
        case .evidence: return "Evidence"
        case .outcome: return "Outcome"
        }
    }
}

struct MissionReplayEventEvidence: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var detail: String
    var source: String
}

struct MissionReplayAgentDecisionVisualization: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var agentName: String
    var selectedBecause: String
    var supportingEvidence: [String]
    var alternatives: [String]
    var confidence: Double?
}

struct MissionReplayTimelineEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sequence: Int64
    var sortOrdinal: Int
    var timestamp: Date?
    var stage: MissionReplayStage
    var title: String
    var summary: String
    var agentName: String?
    var evidence: [MissionReplayEventEvidence]
    var decisionVisualization: MissionReplayAgentDecisionVisualization?
    var sourceEventID: UUID?
}

struct MissionReplayOutcomeStory: Codable, Hashable, Sendable {
    var problem: String
    var investigation: String
    var solution: String
    var evidence: String
    var impact: String
}

struct MissionReplayTimelineFilter: Equatable, Sendable {
    var agentName: String?
    var stage: MissionReplayStage?

    static let all = MissionReplayTimelineFilter(agentName: nil, stage: nil)
}

struct MissionReplayTimeline: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var missionID: UUID
    var title: String
    var events: [MissionReplayTimelineEvent]
    var agentDecisionVisualizations: [MissionReplayAgentDecisionVisualization]
    var outcomeStory: MissionReplayOutcomeStory
    var auditGaps: [String]

    static let empty = MissionReplayTimeline(
        id: UUID(uuidString: "FDE10000-0000-4000-8000-000000000000")!,
        missionID: UUID(uuidString: "FDE10000-0000-4000-8000-000000000001")!,
        title: "No mission selected",
        events: [],
        agentDecisionVisualizations: [],
        outcomeStory: MissionReplayOutcomeStory(
            problem: "No mission selected.",
            investigation: "No runtime evidence is loaded.",
            solution: "Select or run a mission to reconstruct the replay.",
            evidence: "No evidence available.",
            impact: "No outcome available."
        ),
        auditGaps: []
    )

    var agents: [String] {
        uniqueStrings(events.compactMap(\.agentName) + agentDecisionVisualizations.map(\.agentName))
    }

    var stages: [MissionReplayStage] {
        MissionReplayStage.allCases.filter { stage in
            events.contains { $0.stage == stage }
        }
    }

    func events(matching filter: MissionReplayTimelineFilter) -> [MissionReplayTimelineEvent] {
        events.filter { event in
            let matchesAgent = filter.agentName == nil || event.agentName == filter.agentName
            let matchesStage = filter.stage == nil || event.stage == filter.stage
            return matchesAgent && matchesStage
        }
    }
}

struct MissionReplayTimelinePlayback: Sendable {
    private(set) var visibleEvents: [MissionReplayTimelineEvent]
    private(set) var currentIndex: Int

    init(timeline: MissionReplayTimeline, filter: MissionReplayTimelineFilter = .all) {
        self.visibleEvents = timeline.events(matching: filter)
        self.currentIndex = 0
    }

    var currentEvent: MissionReplayTimelineEvent? {
        guard visibleEvents.indices.contains(currentIndex) else { return nil }
        return visibleEvents[currentIndex]
    }

    mutating func apply(filter: MissionReplayTimelineFilter, timeline: MissionReplayTimeline) {
        let previousEventID = currentEvent?.id
        visibleEvents = timeline.events(matching: filter)
        if let previousEventID,
           let retainedIndex = visibleEvents.firstIndex(where: { $0.id == previousEventID }) {
            currentIndex = retainedIndex
        } else {
            currentIndex = 0
        }
    }

    mutating func stepForward() {
        guard !visibleEvents.isEmpty else {
            currentIndex = 0
            return
        }
        currentIndex = min(currentIndex + 1, visibleEvents.count - 1)
    }

    mutating func stepBackward() {
        currentIndex = max(currentIndex - 1, 0)
    }

    mutating func jump(to eventID: UUID) {
        guard let index = visibleEvents.firstIndex(where: { $0.id == eventID }) else { return }
        currentIndex = index
    }
}

struct MissionReplayTimelineEngine: Sendable {
    func reconstruct(
        task: FDETask?,
        replay existingReplay: MissionReplay?,
        events runtimeEvents: [ExecutionEvent],
        approvals: [ApprovalRequest] = [],
        outcome: OutcomeRecord? = nil,
        teamIntelligence: TeamIntelligenceSnapshot = .empty
    ) -> MissionReplayTimeline {
        let orderedEvents = ordered(runtimeEvents)
        let replay = existingReplay ?? MissionReplayBuilder().reconstruct(
            task: task,
            events: orderedEvents,
            approvals: approvals,
            outcome: outcome
        )

        guard !replay.userObjective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !orderedEvents.isEmpty
                || task != nil else {
            return .empty
        }

        let missionID = task?.id ?? replay.taskID
        let title = safe(replay.userObjective, fallback: task?.title ?? "Engineering mission")
        let indexedEvents = Dictionary(uniqueKeysWithValues: orderedEvents.map { ($0.id, $0) })
        let contextEvidence = evidenceDigest(replay: replay, outcome: outcome, events: orderedEvents)
        let decisionVisualizations = agentDecisionVisualizations(
            teamIntelligence: teamIntelligence,
            replay: replay,
            events: orderedEvents,
            contextEvidence: contextEvidence
        )
        var timelineEvents: [MissionReplayTimelineEvent] = []

        timelineEvents.append(userGoalEvent(replay: replay, task: task, events: orderedEvents))
        timelineEvents.append(contentsOf: discoveryEvents(from: orderedEvents))
        timelineEvents.append(contentsOf: teamFormationEvents(
            teamIntelligence: teamIntelligence,
            replay: replay,
            events: orderedEvents,
            decisionVisualizations: decisionVisualizations
        ))
        timelineEvents.append(contentsOf: conflictEvents(teamIntelligence: teamIntelligence, events: orderedEvents))
        timelineEvents.append(contentsOf: decisionEvents(
            replay: replay,
            indexedEvents: indexedEvents,
            decisionVisualizations: decisionVisualizations
        ))
        timelineEvents.append(contentsOf: approvalEvents(replay: replay, events: orderedEvents, approvals: approvals))
        timelineEvents.append(contentsOf: executionEvents(replay: replay, indexedEvents: indexedEvents))
        timelineEvents.append(contentsOf: evidenceEvents(replay: replay, indexedEvents: indexedEvents))
        timelineEvents.append(outcomeEvent(replay: replay, outcome: outcome, events: orderedEvents))

        let sortedEvents = timelineEvents
            .filter { !$0.title.isEmpty && !$0.summary.isEmpty }
            .sortedByReplayTimelineOrder()

        return MissionReplayTimeline(
            id: stableUUID("timeline-\(missionID.uuidString)"),
            missionID: missionID,
            title: title,
            events: sortedEvents,
            agentDecisionVisualizations: decisionVisualizations,
            outcomeStory: outcomeStory(replay: replay, outcome: outcome, events: orderedEvents),
            auditGaps: replay.auditGaps
        )
    }

    private func userGoalEvent(
        replay: MissionReplay,
        task: FDETask?,
        events: [ExecutionEvent]
    ) -> MissionReplayTimelineEvent {
        let firstEvent = events.first
        let sequence = firstEvent.map { safePreviousSequence($0.sequence) } ?? 0
        let summary = safe(
            replay.userObjective,
            fallback: task?.rawInput ?? task?.title ?? firstEvent?.summary ?? "Engineering mission started."
        )
        return MissionReplayTimelineEvent(
            id: stableUUID("goal-\(replay.taskID.uuidString)-\(summary)"),
            sequence: sequence,
            sortOrdinal: MissionReplayStage.userGoal.sortOrdinal,
            timestamp: firstEvent?.timestamp ?? task?.createdAt,
            stage: .userGoal,
            title: "User goal captured",
            summary: summary,
            agentName: nil,
            evidence: [],
            decisionVisualization: nil,
            sourceEventID: firstEvent?.type == .taskCreated ? firstEvent?.id : nil
        )
    }

    private func discoveryEvents(from events: [ExecutionEvent]) -> [MissionReplayTimelineEvent] {
        events.compactMap { event in
            guard [
                .taskCreated,
                .contextCompiled,
                .routingDecisionMade,
                .nodeSelected,
                .executionTargetAssigned
            ].contains(event.type)
                || event.payload["mission_state"] == MissionState.understand.rawValue else {
                return nil
            }

            return MissionReplayTimelineEvent(
                id: stableUUID("discovery-\(event.id.uuidString)"),
                sequence: event.sequence,
                sortOrdinal: MissionReplayStage.discovery.sortOrdinal,
                timestamp: event.timestamp,
                stage: .discovery,
                title: semanticTitle(for: event, fallback: "Discovery"),
                summary: safe(event.payload["agent_work_trace_detail"] ?? event.summary, fallback: "Runtime captured mission context."),
                agentName: agentName(for: event),
                evidence: payloadEvidence(for: event),
                decisionVisualization: nil,
                sourceEventID: event.id
            )
        }
    }

    private func teamFormationEvents(
        teamIntelligence: TeamIntelligenceSnapshot,
        replay: MissionReplay,
        events: [ExecutionEvent],
        decisionVisualizations: [MissionReplayAgentDecisionVisualization]
    ) -> [MissionReplayTimelineEvent] {
        guard !teamIntelligence.selectedAgents.isEmpty else { return [] }

        let anchor = events.first { $0.type == .planGenerated }
            ?? events.first { $0.type == .contextCompiled }
            ?? events.first
        let sequence = anchor.map { $0.sequence } ?? replay.agentDecisions.first?.sequence ?? 1
        let selectedAgents = teamIntelligence.selectedAgents.map(\.roleID.displayName).joined(separator: ", ")
        let formation = MissionReplayTimelineEvent(
            id: stableUUID("team-formation-\(replay.taskID.uuidString)-\(selectedAgents)"),
            sequence: sequence,
            sortOrdinal: MissionReplayStage.teamFormation.sortOrdinal,
            timestamp: anchor?.timestamp,
            stage: .teamFormation,
            title: "Mission team formed",
            summary: safe("Selected \(selectedAgents). \(teamIntelligence.finalDecision)", fallback: "Selected mission team."),
            agentName: AgentRoleID.fdeLeadAgent.displayName,
            evidence: teamIntelligence.selectionReasons.prefix(4).map { reason in
                MissionReplayEventEvidence(
                    id: stableUUID("team-evidence-\(reason)"),
                    title: "Selection reason",
                    detail: safe(reason, fallback: "Evidence-grounded role selection."),
                    source: "Team Intelligence"
                )
            },
            decisionVisualization: decisionVisualizations.first,
            sourceEventID: anchor?.id
        )

        let proposals = teamIntelligence.selectedAgents.map { assignment in
            let visualization = decisionVisualizations.first { $0.agentName == assignment.roleID.displayName }
            return MissionReplayTimelineEvent(
                id: stableUUID("agent-proposal-\(replay.taskID.uuidString)-\(assignment.roleID.rawValue)"),
                sequence: sequence,
                sortOrdinal: MissionReplayStage.agentProposals.sortOrdinal,
                timestamp: anchor?.timestamp,
                stage: .agentProposals,
                title: "\(assignment.roleID.displayName) proposed",
                summary: safe(assignment.expectedContribution, fallback: assignment.responsibility),
                agentName: assignment.roleID.displayName,
                evidence: visualization?.supportingEvidence.prefix(3).map { item in
                    MissionReplayEventEvidence(
                        id: stableUUID("agent-proposal-evidence-\(assignment.roleID.rawValue)-\(item)"),
                        title: "Evidence",
                        detail: item,
                        source: "Team Intelligence"
                    )
                } ?? [],
                decisionVisualization: visualization,
                sourceEventID: anchor?.id
            )
        }

        return [formation] + proposals
    }

    private func conflictEvents(
        teamIntelligence: TeamIntelligenceSnapshot,
        events: [ExecutionEvent]
    ) -> [MissionReplayTimelineEvent] {
        let anchor = events.first { $0.type == .planGenerated } ?? events.first
        let sequence = anchor?.sequence ?? events.first?.sequence ?? 1
        let disagreements = teamIntelligence.disagreements
            .map { safe($0, fallback: "Agent disagreement recorded.") }
            .filter { !$0.isEmpty }
        let eventConflicts = events.flatMap { event in
            splitList(event.payload["conflicts"] ?? event.payload["agent_conflicts"] ?? event.payload["disagreements"])
                .map { (event, $0) }
        }

        var results = disagreements.enumerated().map { index, disagreement in
            MissionReplayTimelineEvent(
                id: stableUUID("conflict-\(index)-\(disagreement)"),
                sequence: sequence,
                sortOrdinal: MissionReplayStage.conflicts.sortOrdinal + index,
                timestamp: anchor?.timestamp,
                stage: .conflicts,
                title: "Conflict surfaced",
                summary: disagreement,
                agentName: AgentRoleID.fdeLeadAgent.displayName,
                evidence: [],
                decisionVisualization: nil,
                sourceEventID: anchor?.id
            )
        }

        results += eventConflicts.enumerated().map { index, value in
            MissionReplayTimelineEvent(
                id: stableUUID("event-conflict-\(value.0.id.uuidString)-\(index)"),
                sequence: value.0.sequence,
                sortOrdinal: MissionReplayStage.conflicts.sortOrdinal + disagreements.count + index,
                timestamp: value.0.timestamp,
                stage: .conflicts,
                title: "Runtime conflict recorded",
                summary: safe(value.1, fallback: "Runtime conflict recorded."),
                agentName: agentName(for: value.0),
                evidence: payloadEvidence(for: value.0),
                decisionVisualization: nil,
                sourceEventID: value.0.id
            )
        }
        return results
    }

    private func decisionEvents(
        replay: MissionReplay,
        indexedEvents: [UUID: ExecutionEvent],
        decisionVisualizations: [MissionReplayAgentDecisionVisualization]
    ) -> [MissionReplayTimelineEvent] {
        replay.agentDecisions.map { decision in
            let source = indexedEvents[decision.id]
            let agent = source.flatMap(agentName(for:)) ?? agentName(for: decision.actionType)
            let visualization = agent.flatMap { agentName in
                decisionVisualizations.first { $0.agentName == agentName }
            }
            return MissionReplayTimelineEvent(
                id: stableUUID("decision-\(decision.id.uuidString)"),
                sequence: decision.sequence,
                sortOrdinal: MissionReplayStage.decisions.sortOrdinal,
                timestamp: source?.timestamp,
                stage: .decisions,
                title: decisionTitle(decision),
                summary: safe(decision.summary, fallback: "Agent selected the next runtime action."),
                agentName: agent,
                evidence: payloadEvidence(for: source),
                decisionVisualization: visualization,
                sourceEventID: source?.id ?? decision.id
            )
        }
    }

    private func approvalEvents(
        replay: MissionReplay,
        events: [ExecutionEvent],
        approvals: [ApprovalRequest]
    ) -> [MissionReplayTimelineEvent] {
        var indexedEventsByRequestID: [UUID: ExecutionEvent] = [:]
        for event in events {
            guard let requestID = event.payload["approval_request_id"].flatMap(UUID.init(uuidString:)) else { continue }
            indexedEventsByRequestID[requestID] = indexedEventsByRequestID[requestID] ?? event
        }
        let indexedApprovals = Dictionary(uniqueKeysWithValues: approvals.map { ($0.id, $0) })

        return replay.approvals.map { approval in
            let source = approval.requestID.flatMap { indexedEventsByRequestID[$0] }
            let request = approval.requestID.flatMap { indexedApprovals[$0] }
            let detail = [
                approval.action,
                approval.resource,
                approval.reason
            ]
            .compactMap { $0 }
            .map { safe($0, fallback: "") }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")

            return MissionReplayTimelineEvent(
                id: stableUUID("approval-\(approval.id.uuidString)"),
                sequence: approval.sequence ?? source?.sequence ?? request.map { Int64($0.requestedAt.timeIntervalSince1970) } ?? Int64.max - 2,
                sortOrdinal: MissionReplayStage.approvals.sortOrdinal,
                timestamp: source?.timestamp ?? request?.requestedAt,
                stage: .approvals,
                title: approvalTitle(approval.state),
                summary: detail.isEmpty ? approvalTitle(approval.state) : detail,
                agentName: AgentKind.policy.rawValue,
                evidence: [
                    MissionReplayEventEvidence(
                        id: stableUUID("approval-risk-\(approval.id.uuidString)"),
                        title: "Risk",
                        detail: approval.riskLevel.rawValue.uppercased(),
                        source: "Governance"
                    )
                ],
                decisionVisualization: nil,
                sourceEventID: source?.id ?? approval.requestID
            )
        }
    }

    private func executionEvents(
        replay: MissionReplay,
        indexedEvents: [UUID: ExecutionEvent]
    ) -> [MissionReplayTimelineEvent] {
        replay.actions.map { action in
            let source = indexedEvents[action.id]
            let detail = action.command ?? action.summary
            return MissionReplayTimelineEvent(
                id: stableUUID("execution-\(action.id.uuidString)"),
                sequence: action.sequence,
                sortOrdinal: MissionReplayStage.executions.sortOrdinal,
                timestamp: source?.timestamp,
                stage: .executions,
                title: executionTitle(action),
                summary: safe(detail, fallback: "Runtime executed an authorized action."),
                agentName: source.flatMap(agentName(for:)) ?? AgentKind.executor.rawValue,
                evidence: payloadEvidence(for: source) + actionEvidence(action),
                decisionVisualization: nil,
                sourceEventID: source?.id ?? action.id
            )
        }
    }

    private func evidenceEvents(
        replay: MissionReplay,
        indexedEvents: [UUID: ExecutionEvent]
    ) -> [MissionReplayTimelineEvent] {
        replay.evidence.map { evidence in
            let source = indexedEvents[evidence.id]
            return MissionReplayTimelineEvent(
                id: stableUUID("evidence-\(evidence.id.uuidString)"),
                sequence: evidence.sequence,
                sortOrdinal: MissionReplayStage.evidence.sortOrdinal,
                timestamp: source?.timestamp,
                stage: .evidence,
                title: safe(evidence.title, fallback: "Evidence captured"),
                summary: safe(evidence.detail, fallback: "Runtime evidence captured."),
                agentName: source.flatMap(agentName(for:)),
                evidence: [
                    MissionReplayEventEvidence(
                        id: stableUUID("evidence-detail-\(evidence.id.uuidString)"),
                        title: safe(evidence.sourceEventType.rawValue, fallback: "Source event"),
                        detail: safe(evidence.detail, fallback: "Evidence detail withheld."),
                        source: "Evidence"
                    )
                ],
                decisionVisualization: nil,
                sourceEventID: source?.id ?? evidence.id
            )
        }
    }

    private func outcomeEvent(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        events: [ExecutionEvent]
    ) -> MissionReplayTimelineEvent {
        let finalEvent = events.last { $0.type == .taskCompleted } ?? events.last
        let sequence = finalEvent.map { safeNextSequence($0.sequence) }
            ?? replay.outcome.map { _ in Int64.max - 1 }
            ?? 1
        let summary = outcome?.achievedOutcome
            ?? replay.outcome?.summary
            ?? finalEvent?.summary
            ?? "Mission outcome not recorded."

        return MissionReplayTimelineEvent(
            id: stableUUID("outcome-\(replay.taskID.uuidString)-\(summary)"),
            sequence: sequence,
            sortOrdinal: MissionReplayStage.outcome.sortOrdinal,
            timestamp: outcome?.createdAt ?? finalEvent?.timestamp,
            stage: .outcome,
            title: replay.outcome?.completed == false ? "Mission outcome recorded" : "Mission solved",
            summary: safe(summary, fallback: "Mission outcome recorded."),
            agentName: AgentKind.policy.rawValue,
            evidence: outcomeEvidenceItems(outcome: outcome, replay: replay).prefixArray(4),
            decisionVisualization: nil,
            sourceEventID: finalEvent?.id
        )
    }

    private func agentDecisionVisualizations(
        teamIntelligence: TeamIntelligenceSnapshot,
        replay: MissionReplay,
        events: [ExecutionEvent],
        contextEvidence: [String]
    ) -> [MissionReplayAgentDecisionVisualization] {
        if !teamIntelligence.selectedAgents.isEmpty {
            let selectedRoleIDs = Set(teamIntelligence.selectedAgents.map(\.roleID))
            let alternatives = AgentRoleID.allCases
                .filter { !selectedRoleIDs.contains($0) }
                .map(\.displayName)

            return teamIntelligence.selectedAgents.map { assignment in
                MissionReplayAgentDecisionVisualization(
                    id: stableUUID("visualization-\(replay.taskID.uuidString)-\(assignment.roleID.rawValue)"),
                    agentName: assignment.roleID.displayName,
                    selectedBecause: safe(assignment.selectedBecause, fallback: assignment.responsibility),
                    supportingEvidence: uniqueStrings(
                        teamIntelligence.selectionReasons
                            + contextEvidence
                            + [assignment.expectedContribution]
                    ).prefixArray(5),
                    alternatives: alternatives.prefixArray(4),
                    confidence: assignment.confidence
                )
            }
        }

        let decisionAgents = uniqueStrings(
            replay.agentDecisions.compactMap { decision in
                agentName(for: decision.actionType)
            }
            + events.compactMap(agentName(for:))
        )

        return decisionAgents.map { agentName in
            MissionReplayAgentDecisionVisualization(
                id: stableUUID("visualization-\(replay.taskID.uuidString)-\(agentName)"),
                agentName: agentName,
                selectedBecause: "Runtime event type matched this agent's operating responsibility.",
                supportingEvidence: contextEvidence.prefixArray(5),
                alternatives: AgentKind.allCases
                    .map(\.rawValue)
                    .filter { $0 != agentName }
                    .prefixArray(4),
                confidence: replay.agentDecisions.first?.confidence
            )
        }
    }

    private func outcomeStory(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        events: [ExecutionEvent]
    ) -> MissionReplayOutcomeStory {
        let objective = safe(replay.userObjective, fallback: outcome?.objective ?? "Engineering mission")
        let discovery = events
            .filter { [.contextCompiled, .routingDecisionMade, .nodeSelected].contains($0.type) }
            .map { safe($0.summary, fallback: "") }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " ")
        let actions = replay.actions
            .map { safe($0.summary, fallback: $0.command ?? "") }
            .filter { !$0.isEmpty }
            .prefix(3)
            .joined(separator: " ")
        let evidence = evidenceDigest(replay: replay, outcome: outcome, events: events)
            .prefix(4)
            .joined(separator: " ")
        let impact = outcome?.impactSummary
            ?? replay.outcome?.summary
            ?? events.last(where: { $0.type == .taskCompleted })?.summary
            ?? "Impact is pending until the mission completes."

        return MissionReplayOutcomeStory(
            problem: objective,
            investigation: safe(discovery, fallback: "FDE reconstructed the runtime event stream and gathered evidence before acting."),
            solution: safe(outcome?.achievedOutcome ?? replay.outcome?.summary ?? actions, fallback: "FDE selected and executed the approved solution path."),
            evidence: safe(evidence, fallback: "Replay evidence is attached to the timeline."),
            impact: safe(impact, fallback: "Mission impact recorded from the outcome layer.")
        )
    }

    private func evidenceDigest(
        replay: MissionReplay,
        outcome: OutcomeRecord?,
        events: [ExecutionEvent]
    ) -> [String] {
        let replayEvidence = replay.evidence.map(\.detail)
        let outcomeEvidence = outcome?.evidence.map { "\($0.title): \($0.detail)" } ?? []
        let eventEvidence = events.flatMap { event in
            [
                event.payload["world_model_evidence"],
                event.payload["environment_evidence"],
                event.payload["risk_reasons"],
                event.payload["policy_reasons"],
                event.payload["agent_work_trace_detail"],
                event.payload["observation_summary"]
            ].compactMap(\.self)
        }
        return uniqueStrings((replayEvidence + outcomeEvidence + eventEvidence).map { safe($0, fallback: "") })
            .filter { !$0.isEmpty }
    }

    private func payloadEvidence(for event: ExecutionEvent?) -> [MissionReplayEventEvidence] {
        guard let event else { return [] }
        let keys = [
            "world_model_evidence",
            "environment_evidence",
            "risk_reasons",
            "policy_reasons",
            "agent_work_trace_detail",
            "observation_summary",
            "command",
            "exit_code"
        ]
        return keys.compactMap { key in
            guard let value = event.payload[key] else { return nil }
            let detail = safe(value, fallback: "")
            guard !detail.isEmpty else { return nil }
            return MissionReplayEventEvidence(
                id: stableUUID("payload-evidence-\(event.id.uuidString)-\(key)-\(detail)"),
                title: evidenceTitle(for: key),
                detail: detail,
                source: event.type.rawValue
            )
        }
    }

    private func actionEvidence(_ action: MissionReplayAction) -> [MissionReplayEventEvidence] {
        var evidence: [MissionReplayEventEvidence] = []
        if let policyDecision = action.policyDecision {
            evidence.append(
                MissionReplayEventEvidence(
                    id: stableUUID("action-policy-\(action.id.uuidString)"),
                    title: "Policy",
                    detail: policyDecision.rawValue,
                    source: "Governance"
                )
            )
        }
        if let riskLevel = action.riskLevel {
            evidence.append(
                MissionReplayEventEvidence(
                    id: stableUUID("action-risk-\(action.id.uuidString)"),
                    title: "Risk",
                    detail: riskLevel.rawValue.uppercased(),
                    source: "Governance"
                )
            )
        }
        return evidence
    }

    private func outcomeEvidenceItems(
        outcome: OutcomeRecord?,
        replay: MissionReplay
    ) -> [MissionReplayEventEvidence] {
        if let outcome, !outcome.evidence.isEmpty {
            return outcome.evidence.map { item in
                MissionReplayEventEvidence(
                    id: stableUUID("outcome-evidence-\(item.id)-\(item.detail)"),
                    title: safe(item.title, fallback: item.kind.rawValue),
                    detail: safe(item.detail, fallback: "Outcome evidence captured."),
                    source: item.kind.rawValue
                )
            }
        }

        return replay.evidence.prefix(4).map { item in
            MissionReplayEventEvidence(
                id: stableUUID("outcome-replay-evidence-\(item.id.uuidString)"),
                title: safe(item.title, fallback: "Evidence"),
                detail: safe(item.detail, fallback: "Evidence detail withheld."),
                source: item.sourceEventType.rawValue
            )
        }
    }

    private func semanticTitle(for event: ExecutionEvent, fallback: String) -> String {
        if let traceSummary = event.payload["agent_work_trace_summary"] {
            return safe(traceSummary, fallback: fallback)
        }
        switch event.type {
        case .taskCreated:
            return "Mission accepted"
        case .contextCompiled:
            return "Environment discovered"
        case .routingDecisionMade:
            return "Execution route selected"
        case .nodeSelected:
            return "Execution node selected"
        case .executionTargetAssigned:
            return "Execution target assigned"
        default:
            return safe(event.summary, fallback: fallback)
        }
    }

    private func decisionTitle(_ decision: MissionReplayDecision) -> String {
        if decision.requiresApproval {
            return "Decision required approval"
        }
        if let action = decision.actionType {
            return "Decision: \(action.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)"
        }
        return "Agent decision recorded"
    }

    private func approvalTitle(_ state: ApprovalState) -> String {
        switch state {
        case .pending: return "Approval requested"
        case .approved: return "Approval granted"
        case .rejected: return "Approval rejected"
        case .superseded: return "Approval superseded"
        case .expired: return "Approval expired"
        }
    }

    private func executionTitle(_ action: MissionReplayAction) -> String {
        switch action.eventType {
        case .toolFailed, .connectorFailed:
            return "Execution failed"
        case .authorizationDenied:
            return "Execution blocked"
        case .policyUpdated:
            return "Policy updated"
        case .connectorDryRun:
            return "Dry run executed"
        default:
            return "Execution performed"
        }
    }

    private func evidenceTitle(for key: String) -> String {
        switch key {
        case "world_model_evidence": return "World model"
        case "environment_evidence": return "Environment"
        case "risk_reasons": return "Risk"
        case "policy_reasons": return "Policy"
        case "agent_work_trace_detail": return "Work trace"
        case "observation_summary": return "Observation"
        case "command": return "Command"
        case "exit_code": return "Exit code"
        default: return key
        }
    }

    private func agentName(for event: ExecutionEvent) -> String? {
        if let role = event.payload["agent_role_id"].flatMap(AgentRoleID.init(rawValue:)) {
            return role.displayName
        }
        if let role = event.payload["selected_agent_role_id"].flatMap(AgentRoleID.init(rawValue:)) {
            return role.displayName
        }
        if let agent = event.payload["agent"].flatMap(AgentKind.init(rawValue:)) {
            return agent.rawValue
        }
        if let agent = event.payload["agent_kind"].flatMap(AgentKind.init(rawValue:)) {
            return agent.rawValue
        }
        return agentKind(for: event.type)?.rawValue
    }

    private func agentName(for action: AgentRuntimeAction?) -> String? {
        guard let action else { return nil }
        switch action {
        case .answerCapability, .askClarification, .submitTask, .continueMission, .resumeTask, .acknowledgeInstruction:
            return AgentKind.planner.rawValue
        case .executeTool:
            return AgentKind.executor.rawValue
        case .replan, .changeApproach, .requestPause, .stopTask:
            return AgentKind.recovery.rawValue
        case .requestHumanApproval:
            return AgentKind.policy.rawValue
        }
    }

    private func agentKind(for eventType: EventType) -> AgentKind? {
        switch eventType {
        case .taskCreated, .contextCompiled:
            return .systemUnderstanding
        case .planGenerated, .routingDecisionMade, .nodeSelected, .executionTargetAssigned:
            return .planner
        case .toolCalled, .toolFailed, .connectorCalled, .connectorDryRun, .connectorExecuted, .connectorFailed, .stepExecuted,
             .taskCompleted, .nodeExecutionStarted, .nodeExecutionCompleted, .nodeExecutionFailed, .executionDispatched,
             .executionReceived, .executionResponseReceived, .workerTaskReceived, .workerTaskCompleted, .workerTaskFailed:
            return .executor
        case .recoveryAttempted:
            return .recovery
        case .humanApprovalRequested, .humanApproved, .humanRejected, .authorizationDenied, .policyUpdated, .feedbackGenerated,
             .userApprovalGranted, .userApprovalRejected:
            return .policy
        case .stateUpdated, .sessionStarted, .sessionEnded, .workspaceSwitched, .roleChanged, .workerRegistered,
             .userMessageReceived, .userDecisionSelected:
            return nil
        }
    }

    private func ordered(_ events: [ExecutionEvent]) -> [ExecutionEvent] {
        events.sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }

    private func safe(_ value: String?, fallback: String) -> String {
        guard let value else { return fallback }
        let safe = AgentPresentationSanitizer.safeMarkdownContent(value, fallback: fallback)
        guard !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return fallback
        }
        return safe
    }

    private func splitList(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .split { character in
                character == "|" || character == "\n" || character == ";"
            }
            .map(String.init)
            .map { safe($0, fallback: "") }
            .filter { !$0.isEmpty }
    }

    private func safePreviousSequence(_ sequence: Int64) -> Int64 {
        sequence == Int64.min ? sequence : sequence - 1
    }

    private func safeNextSequence(_ sequence: Int64) -> Int64 {
        sequence == Int64.max ? sequence : sequence + 1
    }

    private func stableUUID(_ seed: String) -> UUID {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8((hash >> UInt64((index % 8) * 8)) & 0xFF)
            hash = (hash &* 1_099_511_628_211) ^ UInt64(index + seed.count)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension MissionReplayStage {
    var sortOrdinal: Int {
        switch self {
        case .userGoal: return 0
        case .discovery: return 100
        case .teamFormation: return 200
        case .agentProposals: return 300
        case .conflicts: return 400
        case .decisions: return 500
        case .approvals: return 600
        case .executions: return 700
        case .evidence: return 800
        case .outcome: return 900
        }
    }
}

private extension Array where Element == MissionReplayTimelineEvent {
    func sortedByReplayTimelineOrder() -> [MissionReplayTimelineEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                if lhs.sortOrdinal == rhs.sortOrdinal {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.sortOrdinal < rhs.sortOrdinal
            }
            return lhs.sequence < rhs.sequence
        }
    }
}

private func uniqueStrings(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }
        let key = trimmed.lowercased()
        guard !seen.contains(key) else { continue }
        seen.insert(key)
        result.append(trimmed)
    }
    return result
}

private extension Array {
    func prefixArray(_ count: Int) -> [Element] {
        Array(prefix(count))
    }
}
