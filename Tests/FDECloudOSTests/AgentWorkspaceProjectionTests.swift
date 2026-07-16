import XCTest
@testable import FDECloudOS

final class AgentWorkspaceProjectionTests: XCTestCase {
    func testPartialReadOnlyResultProjectsAsBlockedResumableWorkStatus() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .stateUpdated,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Read-only inspection partially finalized with grounded evidence",
            payload: [
                "state": TaskState.blocked.rawValue,
                "mission_state": MissionState.blocked.rawValue,
                "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                "same_task_resumable": "true",
                "grounded_answer": "true",
                "final_answer": "Grounded partial report",
                "user_visible_message": "Operation budget reached. Grounded partial report"
            ]
        )

        let projected = try XCTUnwrap(AgentWorkspaceProjection.project(event: event))

        XCTAssertEqual(projected.stage, .blocked)
        XCTAssertEqual(projected.title, "Partial investigation result")
        XCTAssertFalse(projected.requiresUserAction)
    }

    func testRuntimeEventCreatesWorkspaceEvent() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .contextCompiled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Workspace context compiled",
            payload: [
                "mission_state": MissionState.understand.rawValue,
                "agent_work_trace_summary": "System context compiled",
                "agent_work_trace_detail": "Built initial world model from workspace metadata."
            ]
        )

        let workspaceEvent = try XCTUnwrap(AgentWorkspaceProjection.project(event: event))

        XCTAssertEqual(workspaceEvent.eventID, event.id)
        XCTAssertEqual(workspaceEvent.missionID, taskID)
        XCTAssertEqual(workspaceEvent.stage, .understanding)
        XCTAssertEqual(workspaceEvent.title, "System context compiled")
        XCTAssertEqual(workspaceEvent.summary, "Built initial world model from workspace metadata.")
        XCTAssertFalse(workspaceEvent.requiresUserAction)
        XCTAssertTrue(workspaceEvent.evidence.isEmpty, "Context compilation is audit history, not grounding evidence")
    }

    func testExecutionCreatesTimelineEntry() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "shell: /usr/bin/curl",
            payload: [
                "mission_state": MissionState.execute.rawValue,
                "command": "/usr/bin/curl",
                "agent_work_trace_summary": "Running tool",
                "agent_work_trace_detail": "Checking authentication."
            ]
        )

        let workspaceEvents = AgentWorkspaceProjection.events(session: nil, task: nil, events: [event])
        let timeline = AgentTimeline.build(
            missionID: taskID,
            missionTitle: "Diagnose Salesforce Integration",
            events: workspaceEvents
        )

        XCTAssertEqual(timeline.entries.count, 1)
        XCTAssertEqual(timeline.entries.first?.stage, .executing)
        XCTAssertEqual(timeline.entries.first?.title, "Running tool")
        XCTAssertEqual(timeline.entries.first?.summary, "Checking authentication.")
        XCTAssertEqual(timeline.semanticProgress, "Executing changes")
        XCTAssertEqual(timeline.currentActivity?.status, .active)
    }

    func testFailureCreatesObservationAndAdaptationCards() {
        let workspaceID = UUID()
        let taskID = UUID()
        let failure = makeEvent(
            .toolFailed,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "API returned permission failure",
            payload: [
                "mission_state": MissionState.observe.rawValue,
                "command": "/usr/bin/curl",
                "exit_code": "1",
                "observation_summary": "API returned permission failure."
            ]
        )
        let adaptation = makeEvent(
            .recoveryAttempted,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Creating recovery path",
            payload: [
                "mission_state": MissionState.adapt.rawValue,
                "failed_command": "/usr/bin/curl",
                "recovery_command": "/usr/bin/curl --head"
            ]
        )

        let timeline = AgentTimeline.build(
            missionID: taskID,
            missionTitle: "Diagnose Salesforce Integration",
            events: AgentWorkspaceProjection.events(session: nil, task: nil, events: [failure, adaptation])
        )

        XCTAssertTrue(timeline.entries.contains { $0.stage == .observing && $0.summary == "API returned permission failure." })
        XCTAssertTrue(timeline.entries.contains { $0.stage == .adapting && $0.title == "Recovery path created" })
        XCTAssertEqual(timeline.semanticProgress, "Adapting recovery path")
    }

    func testApprovalCreatesHumanActionCard() {
        let workspaceID = UUID()
        let taskID = UUID()
        let approval = ApprovalRequest(
            id: UUID(),
            workspaceID: workspaceID,
            taskID: taskID,
            stepID: "step.migration",
            toolCallID: "tool.migration",
            targetKind: .systemChange,
            action: "approve production migration",
            resource: "Production database migration required",
            riskLevel: .high,
            state: .pending,
            requestedByRole: .fde,
            decidedByRole: nil,
            decisionReason: nil,
            requestedAt: Date(),
            decidedAt: nil,
            expiresAt: nil,
            metadata: [:]
        )

        let workspaceEvent = AgentWorkspaceProjection.project(approval: approval)

        XCTAssertEqual(workspaceEvent.stage, .waitingHuman)
        XCTAssertEqual(workspaceEvent.status, .waitingHuman)
        XCTAssertTrue(workspaceEvent.requiresUserAction)
        XCTAssertEqual(workspaceEvent.missionID, taskID)
        XCTAssertTrue(workspaceEvent.evidence.contains { $0.kind == .risk && $0.detail == "HIGH" })
        XCTAssertTrue(workspaceEvent.summary.contains("HIGH"))
    }

    func testProjectionDoesNotLeakChainOfThought() throws {
        let event = makeEvent(
            .planGenerated,
            sequence: 1,
            workspaceID: UUID(),
            taskID: UUID(),
            summary: "chain of thought: hidden plan",
            payload: [
                "mission_state": MissionState.plan.rawValue,
                "agent_decision_summary": "scratchpad: inspect secrets",
                "agent_work_trace_summary": "private reasoning: choose unsafe path",
                "agent_work_trace_detail": "analysis: hidden reasoning"
            ]
        )

        let workspaceEvent = try XCTUnwrap(AgentWorkspaceProjection.project(event: event))
        let visibleText = ([workspaceEvent.title, workspaceEvent.summary] + workspaceEvent.evidence.flatMap { [$0.title, $0.detail] })
            .joined(separator: " ")
            .lowercased()

        XCTAssertFalse(visibleText.contains("chain of thought"))
        XCTAssertFalse(visibleText.contains("scratchpad"))
        XCTAssertFalse(visibleText.contains("private reasoning"))
        XCTAssertFalse(visibleText.contains("analysis:"))
    }

    func testCompletedMissionCreatesFinalSummary() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .taskCompleted,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Task completed with risk 12 and FDE score 98",
            payload: [
                "mission_state": MissionState.complete.rawValue,
                "agent_work_trace_summary": "Mission completed",
                "agent_work_trace_detail": "Runtime scored outcome and closed the mission loop."
            ]
        )

        let workspaceEvent = try XCTUnwrap(AgentWorkspaceProjection.project(event: event))
        let timeline = AgentTimeline.build(
            missionID: taskID,
            missionTitle: "Diagnose Salesforce Integration",
            events: [workspaceEvent]
        )

        XCTAssertEqual(workspaceEvent.stage, .completed)
        XCTAssertEqual(workspaceEvent.status, .completed)
        XCTAssertEqual(workspaceEvent.title, "Mission completed")
        XCTAssertEqual(workspaceEvent.summary, "Runtime scored outcome and closed the mission loop.")
        XCTAssertEqual(timeline.semanticProgress, "Mission completed")
        XCTAssertEqual(timeline.currentActivity?.status, .completed)
    }

    func testChatOnlyStateUpdateIsNotProjectedAsWaitingForHumanInput() throws {
        let workspaceID = UUID()
        let sessionID = UUID()
        let userEvent = makeEvent(
            .userMessageReceived,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: nil,
            summary: "User message received",
            payload: [
                "session_id": sessionID.uuidString,
                "chat_only": "true",
                "mission_state": MissionState.waitingHuman.rawValue,
                "decision_next_action": AgentRuntimeAction.acknowledgeInstruction.rawValue
            ]
        )
        let chatOnlyState = makeEvent(
            .stateUpdated,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: nil,
            summary: "Agent answered chat message",
            payload: [
                "session_id": sessionID.uuidString,
                "chat_only": "true",
                "mission_state": MissionState.waitingHuman.rawValue,
                "decision_next_action": AgentRuntimeAction.acknowledgeInstruction.rawValue
            ]
        )

        let workspaceEvents = AgentWorkspaceProjection.events(
            session: nil,
            task: nil,
            events: [userEvent, chatOnlyState]
        )

        XCTAssertTrue(workspaceEvents.isEmpty)
    }

    func testPlannedMissionTimelineDoesNotAppearDone() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(
                .contextCompiled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Workspace context compiled",
                payload: ["mission_state": MissionState.understand.rawValue]
            ),
            makeEvent(
                .planGenerated,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Plan ready",
                payload: ["mission_state": MissionState.plan.rawValue]
            )
        ]

        let timeline = AgentTimeline.build(
            missionID: taskID,
            missionTitle: "Plan title change",
            events: AgentWorkspaceProjection.events(session: nil, task: nil, events: events)
        )

        XCTAssertEqual(timeline.currentActivity?.stage, .planning)
        XCTAssertNotEqual(timeline.currentActivity?.status, .completed)
        XCTAssertEqual(timeline.semanticProgress, "Planning solution")
        XCTAssertFalse(timeline.entries.contains { $0.stage == .completed })
    }

    func testFailedMissionRejectsSyntheticCompletionBadge() {
        let workspaceID = UUID()
        let taskID = UUID()
        let failure = makeEvent(
            .toolFailed,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "swift build failed: cannot find 'MissingTitle' in scope",
            payload: [
                "mission_state": MissionState.observe.rawValue,
                "command": "/usr/bin/swift",
                "arguments": "build",
                "exit_code": "1",
                "error": "cannot find 'MissingTitle' in scope"
            ]
        )
        let invalidCompletion = makeEvent(
            .taskCompleted,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Task completed successfully",
            payload: [
                "mission_state": MissionState.complete.rawValue,
                "completion_gate_passed": "false",
                "completion_gate_reason": "unrecovered compiler error"
            ]
        )

        let timeline = AgentTimeline.build(
            missionID: taskID,
            missionTitle: "Modify title and build",
            events: AgentWorkspaceProjection.events(
                session: nil,
                task: nil,
                events: [failure, invalidCompletion]
            )
        )

        XCTAssertEqual(timeline.currentActivity?.status, .failed)
        XCTAssertTrue(timeline.currentActivity?.summary.contains("cannot find 'MissingTitle' in scope") == true)
        XCTAssertNotEqual(timeline.semanticProgress, "Mission completed")
        XCTAssertFalse(timeline.entries.contains { $0.stage == .completed && $0.status == .completed })
    }

    func testBlockedMissionTimelineRemainsWaitingInsteadOfDone() {
        let workspaceID = UUID()
        let taskID = UUID()
        let approval = makeEvent(
            .humanApprovalRequested,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Approval required before file edit",
            payload: [
                "mission_state": MissionState.waitingHuman.rawValue,
                "task_state": TaskState.pendingApproval.rawValue,
                "tool_state": ToolExecutionState.pendingApproval.rawValue,
                "command": "engineering.edit_file",
                "risk_level": "medium"
            ]
        )

        let timeline = AgentTimeline.build(
            missionID: taskID,
            missionTitle: "Modify title and build",
            events: AgentWorkspaceProjection.events(session: nil, task: nil, events: [approval])
        )

        XCTAssertEqual(timeline.currentActivity?.status, .waitingHuman)
        XCTAssertTrue(timeline.requiresUserAction)
        XCTAssertEqual(timeline.semanticProgress, "Waiting for approval")
        XCTAssertFalse(timeline.entries.contains { $0.stage == .completed })
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
