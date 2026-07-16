import XCTest
@testable import FDECloudOS

final class MissionReplayTimelineTests: XCTestCase {
    func testReplayReconstructionBuildsMissionStagesAndDecisionVisualizations() {
        let fixture = makeFixture()
        let timeline = MissionReplayTimelineEngine().reconstruct(
            task: fixture.task,
            replay: nil,
            events: fixture.events,
            approvals: [fixture.approval],
            outcome: fixture.outcome,
            teamIntelligence: fixture.team
        )

        let stages = Set(timeline.events.map(\.stage))

        XCTAssertTrue(stages.contains(.userGoal))
        XCTAssertTrue(stages.contains(.discovery))
        XCTAssertTrue(stages.contains(.teamFormation))
        XCTAssertTrue(stages.contains(.agentProposals))
        XCTAssertTrue(stages.contains(.decisions))
        XCTAssertTrue(stages.contains(.approvals))
        XCTAssertTrue(stages.contains(.executions))
        XCTAssertTrue(stages.contains(.evidence))
        XCTAssertTrue(stages.contains(.outcome))
        XCTAssertTrue(timeline.agentDecisionVisualizations.contains { visualization in
            visualization.agentName == AgentRoleID.codeInvestigationAgent.displayName
                && visualization.selectedBecause.contains("code-level failure")
                && visualization.alternatives.contains(AgentRoleID.infrastructureAgent.displayName)
        })
    }

    func testTimelineEventsAreOrderedByReplaySequence() {
        let fixture = makeFixture()
        let shuffledEvents = [fixture.events[3], fixture.events[0], fixture.events[5], fixture.events[1], fixture.events[2], fixture.events[4]]
        let timeline = MissionReplayTimelineEngine().reconstruct(
            task: fixture.task,
            replay: nil,
            events: shuffledEvents,
            approvals: [fixture.approval],
            outcome: fixture.outcome,
            teamIntelligence: .empty
        )

        let ordered = timeline.events
        for pair in zip(ordered, ordered.dropFirst()) {
            XCTAssertTrue(
                pair.0.sequence < pair.1.sequence
                    || (pair.0.sequence == pair.1.sequence && pair.0.sortOrdinal <= pair.1.sortOrdinal),
                "Timeline event \(pair.0.title) should come before \(pair.1.title)"
            )
        }
    }

    func testAgentAndStageFilteringAndPlayback() {
        let fixture = makeFixture()
        let timeline = MissionReplayTimelineEngine().reconstruct(
            task: fixture.task,
            replay: nil,
            events: fixture.events,
            approvals: [fixture.approval],
            outcome: fixture.outcome,
            teamIntelligence: fixture.team
        )

        let agentEvents = timeline.events(matching: MissionReplayTimelineFilter(
            agentName: AgentRoleID.codeInvestigationAgent.displayName,
            stage: nil
        ))
        XCTAssertFalse(agentEvents.isEmpty)
        XCTAssertTrue(agentEvents.allSatisfy { $0.agentName == AgentRoleID.codeInvestigationAgent.displayName })

        let executionEvents = timeline.events(matching: MissionReplayTimelineFilter(agentName: nil, stage: .executions))
        XCTAssertFalse(executionEvents.isEmpty)
        XCTAssertTrue(executionEvents.allSatisfy { $0.stage == .executions })

        var playback = MissionReplayTimelinePlayback(
            timeline: timeline,
            filter: MissionReplayTimelineFilter(agentName: nil, stage: .executions)
        )
        let firstExecutionID = playback.currentEvent?.id
        playback.stepForward()
        playback.stepBackward()
        XCTAssertEqual(playback.currentEvent?.id, firstExecutionID)
        if let target = executionEvents.last {
            playback.jump(to: target.id)
            XCTAssertEqual(playback.currentEvent?.id, target.id)
        }
    }

    func testOutcomeStoryRenderingUsesMissionEvidenceWithoutPrivateReasoning() {
        let fixture = makeFixture(includePrivateReasoningMarkers: true)
        let timeline = MissionReplayTimelineEngine().reconstruct(
            task: fixture.task,
            replay: nil,
            events: fixture.events,
            approvals: [fixture.approval],
            outcome: fixture.outcome,
            teamIntelligence: fixture.team
        )

        XCTAssertEqual(timeline.outcomeStory.problem, fixture.task.rawInput)
        XCTAssertTrue(timeline.outcomeStory.investigation.contains("workspace context"))
        XCTAssertTrue(timeline.outcomeStory.solution.contains("Adapter fixed"))
        XCTAssertTrue(timeline.outcomeStory.evidence.contains("health check passed"))
        XCTAssertTrue(timeline.outcomeStory.impact.contains("Reduced incident risk"))

        let visibleText = (
            timeline.events.flatMap { event in
                [event.title, event.summary]
                    + event.evidence.flatMap { [$0.title, $0.detail] }
                    + [event.decisionVisualization?.selectedBecause ?? ""]
            }
            + [
                timeline.outcomeStory.problem,
                timeline.outcomeStory.investigation,
                timeline.outcomeStory.solution,
                timeline.outcomeStory.evidence,
                timeline.outcomeStory.impact
            ]
        )
        .joined(separator: "\n")
        .lowercased()

        XCTAssertFalse(visibleText.contains("chain_of_thought"))
        XCTAssertFalse(visibleText.contains("chain of thought"))
        XCTAssertFalse(visibleText.contains("analysis:"))
        XCTAssertFalse(visibleText.contains("scratchpad"))
    }

    private func makeFixture(includePrivateReasoningMarkers: Bool = false) -> (
        task: FDETask,
        events: [ExecutionEvent],
        approval: ApprovalRequest,
        outcome: OutcomeRecord,
        team: TeamIntelligenceSnapshot
    ) {
        let workspaceID = UUID()
        let taskID = UUID()
        let approvalID = UUID()
        let task = FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Fix checkout adapter",
            rawInput: "Fix the checkout adapter failure and prove the customer impact.",
            state: .completed,
            plan: [
                PlanStep(
                    id: "inspect",
                    title: "Inspect checkout integration",
                    intent: "Find the adapter failure",
                    toolCallID: "tool.inspect",
                    requiresApproval: false
                )
            ],
            riskScore: 0.72,
            failureProbability: 0.44,
            performanceScore: 0.91,
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 70)
        )
        let privateSummary = includePrivateReasoningMarkers ? "chain_of_thought: hidden adapter notes" : "Use code investigation and security review."
        let events = [
            makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID, summary: task.rawInput),
            makeEvent(
                .contextCompiled,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Compiled workspace context",
                payload: [
                    "mission_state": MissionState.understand.rawValue,
                    "agent_work_trace_detail": "Built workspace context from checkout service files.",
                    "environment_evidence": "checkout service and adapter tests discovered"
                ]
            ),
            makeEvent(
                .planGenerated,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Generated repair plan",
                payload: [
                    "mission_state": MissionState.plan.rawValue,
                    "agent_decision_summary": privateSummary,
                    "agent_decision_next_state": MissionState.execute.rawValue,
                    "agent_decision_action_type": AgentRuntimeAction.executeTool.rawValue,
                    "agent_decision_confidence": "0.91",
                    "agent_decision_requires_human_approval": "true"
                ]
            ),
            makeEvent(
                .humanApprovalRequested,
                sequence: 4,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Approval requested for adapter patch",
                payload: [
                    "approval_request_id": approvalID.uuidString,
                    "command": "/usr/bin/git apply checkout-adapter.patch",
                    "risk_level": RiskSeverity.high.rawValue,
                    "risk_reasons": "Adapter patch changes customer checkout flow."
                ]
            ),
            makeEvent(
                .toolCalled,
                sequence: 5,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Applied checkout adapter patch",
                payload: [
                    "mission_state": MissionState.execute.rawValue,
                    "command": "/usr/bin/git apply checkout-adapter.patch",
                    "policy_decision": PolicyDecisionStatus.allowed.rawValue,
                    "risk_level": RiskSeverity.high.rawValue
                ]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 6,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: includePrivateReasoningMarkers ? "analysis: hidden validation" : "Adapter health check passed",
                payload: [
                    "mission_state": MissionState.observe.rawValue,
                    "exit_code": "0",
                    "observation_summary": "Adapter health check passed and customer checkout recovered.",
                    "world_model_evidence": "health check passed for checkout adapter"
                ]
            ),
            makeEvent(
                .taskCompleted,
                sequence: 7,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Adapter fixed and verified",
                payload: [
                    "mission_state": MissionState.complete.rawValue,
                    "impact_summary": "Reduced incident risk for checkout customers."
                ]
            )
        ]
        let approval = ApprovalRequest(
            id: approvalID,
            workspaceID: workspaceID,
            taskID: taskID,
            stepID: "patch",
            toolCallID: "tool.patch",
            targetKind: .systemChange,
            action: "Apply checkout adapter patch",
            resource: "Customer checkout adapter",
            riskLevel: .high,
            state: .approved,
            requestedByRole: .fde,
            decidedByRole: .admin,
            decisionReason: "Patch scoped to adapter and backed by health check evidence.",
            requestedAt: Date(timeIntervalSince1970: 40),
            decidedAt: Date(timeIntervalSince1970: 45),
            expiresAt: nil,
            metadata: [:]
        )
        let outcome = OutcomeRecord(
            missionID: taskID,
            objective: task.rawInput,
            expectedOutcome: "Recover checkout adapter",
            achievedOutcome: "Adapter fixed and verified with health check passed.",
            successCriteria: ["Checkout adapter recovers", "Evidence attached"],
            finalState: .complete,
            evidence: [
                OutcomeEvidence(
                    id: "health",
                    kind: .completion,
                    title: "Health check",
                    detail: "health check passed for checkout adapter",
                    sourceEventID: events[5].id
                )
            ],
            impactSummary: "Reduced incident risk for checkout customers.",
            businessImpact: ["Checkout customers can complete purchases"],
            metricsBefore: [],
            metricsAfter: [],
            lessonsLearned: [],
            followUpRecommendations: [],
            createdAt: Date(timeIntervalSince1970: 80)
        )
        let team = TeamIntelligenceSnapshot(
            selectedAgents: [
                PlannedAgentAssignment(
                    roleID: .fdeLeadAgent,
                    responsibility: "Coordinate mission",
                    selectedBecause: "Mission required cross-agent coordination.",
                    confidence: 0.87,
                    expectedContribution: "Own the mission decision log."
                ),
                PlannedAgentAssignment(
                    roleID: .codeInvestigationAgent,
                    responsibility: "Inspect code",
                    selectedBecause: "Mission required code-level failure isolation.",
                    confidence: 0.91,
                    expectedContribution: "Find the checkout adapter defect and validation path."
                )
            ],
            selectionReasons: [
                "Runtime evidence showed a checkout adapter failure.",
                "High risk score required review before execution."
            ],
            confidence: 0.9,
            disagreements: [],
            finalDecision: "Use selected agents for the adapter repair mission."
        )
        return (task, events, approval, outcome, team)
    }

    private func makeEvent(
        _ type: EventType,
        sequence: Int64,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String] = [:]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: summary,
            payload: payload
        )
    }
}
