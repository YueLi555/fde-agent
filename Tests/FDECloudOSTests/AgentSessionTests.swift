import XCTest
@testable import FDECloudOS

final class AgentSessionTests: XCTestCase {
    func testAgentSessionCreationStartsConversation() {
        let workspace = Workspace.default()
        let session = AgentSession(workspace: workspace, userGoal: "Investigate customer API integration failure")

        XCTAssertEqual(session.workspaceID, workspace.id)
        XCTAssertEqual(session.currentState, .understanding)
        XCTAssertEqual(session.conversation.workspaceID, workspace.id)
        XCTAssertEqual(session.conversation.sessionID, session.sessionID)
        XCTAssertEqual(session.messages.first?.type, .text)
        XCTAssertEqual(session.messages.first?.content, "Investigate customer API integration failure")
    }

    func testAgentSessionPreservesUserGoal() {
        let workspace = Workspace.default()
        let goal = "Investigate customer API integration failure"

        let session = AgentSession(workspace: workspace, userGoal: goal)

        XCTAssertEqual(session.userGoal, goal)
        XCTAssertEqual(session.conversation.messages.first?.content, goal)
    }

    func testRuntimeTaskLinksToAgentSession() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Audit workspace")
        let task = makeTask(
            id: UUID(),
            workspaceID: session.workspaceID,
            plan: [
                PlanStep(
                    id: "inspect",
                    title: "Inspect API",
                    intent: "Check integration state",
                    toolCallID: "tool.inspect",
                    requiresApproval: false
                )
            ]
        )

        session.syncRuntimeTask(task)

        XCTAssertEqual(session.runtimeTaskID, task.id)
        XCTAssertEqual(session.workspaceContext.runtimeTaskTitle, task.title)
        XCTAssertEqual(session.currentPlan, task.plan)
    }

    func testEventUpdatesChangeAgentState() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        let taskID = UUID()

        session.apply(event: makeEvent(.taskCreated, sequence: 1, workspaceID: session.workspaceID, taskID: taskID))
        XCTAssertEqual(session.currentState, .understanding)

        session.apply(event: makeEvent(.planGenerated, sequence: 2, workspaceID: session.workspaceID, taskID: taskID))
        XCTAssertEqual(session.currentState, .planning)

        session.apply(
            event: makeEvent(
                .toolCalled,
                sequence: 3,
                workspaceID: session.workspaceID,
                taskID: taskID,
                payload: ["command": "/usr/bin/curl"]
            )
        )
        XCTAssertEqual(session.currentState, .executing)
    }

    func testBlockedStateUpdateDoesNotLeaveSidebarExecuting() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Inspect project")
        let taskID = UUID()
        session.apply(event: makeEvent(.toolCalled, sequence: 1, workspaceID: session.workspaceID, taskID: taskID))
        XCTAssertEqual(session.currentState, .executing)

        session.apply(
            event: makeEvent(
                .stateUpdated,
                sequence: 2,
                workspaceID: session.workspaceID,
                taskID: taskID,
                payload: ["state": TaskState.blocked.rawValue]
            )
        )

        XCTAssertEqual(session.currentState, .blocked)
        XCTAssertEqual(session.interactionState, .blocked)
    }

    func testCompletionEventCreatesSummary() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        let taskID = UUID()
        session.apply(event: makeEvent(.taskCreated, sequence: 1, workspaceID: session.workspaceID, taskID: taskID))
        session.apply(
            event: makeEvent(
                .stepExecuted,
                sequence: 2,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Inspected AgentConversationView.swift",
                payload: [
                    "step_id": "inspect",
                    "command": "engineering.read_file",
                    "target_path": "Sources/FDECloudOS/UI/Components/AgentConversationView.swift",
                    "evidence_kind": "file_read_result",
                    "success": "true",
                    "exit_code": "0"
                ]
            )
        )

        session.apply(
            event: makeEvent(
                .taskCompleted,
                sequence: 3,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Inspected AgentConversationView.swift without modifying files",
                payload: [
                    "completion_gate_passed": "true",
                    "completion_evidence": "file_read_result"
                ]
            )
        )

        XCTAssertEqual(session.currentState, .completed)
        XCTAssertEqual(session.messages.last?.type, .result)
        XCTAssertEqual(session.messages.last?.content, "Inspected AgentConversationView.swift without modifying files")
        XCTAssertEqual(session.artifacts.last?.title, "Completion summary")
        XCTAssertEqual(session.artifacts.last?.detail, "Inspected AgentConversationView.swift without modifying files")
    }

    func testSyntheticCompletionWithoutValidatedEvidenceDoesNotCompleteSession() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Modify the title")
        let taskID = UUID()
        session.apply(event: makeEvent(.taskCreated, sequence: 1, workspaceID: session.workspaceID, taskID: taskID))
        session.apply(event: makeEvent(.contextCompiled, sequence: 2, workspaceID: session.workspaceID, taskID: taskID))
        session.apply(event: makeEvent(.planGenerated, sequence: 3, workspaceID: session.workspaceID, taskID: taskID))

        session.apply(
            event: makeEvent(
                .taskCompleted,
                sequence: 4,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Task completed successfully",
                payload: [
                    "completion_gate_passed": "false",
                    "completion_gate_reason": "no real file, diff, command, or verification evidence"
                ]
            )
        )

        XCTAssertEqual(session.currentState, .planning)
        XCTAssertNotEqual(session.interactionState, .completed)
        XCTAssertFalse(session.messages.contains { $0.type == .result })
        XCTAssertFalse(session.artifacts.contains { $0.title == "Completion summary" })
    }

    func testPostCompletionPolicyEventsKeepInteractionCompleted() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        let taskID = UUID()

        session.apply(
            event: makeEvent(
                .taskCompleted,
                sequence: 1,
                workspaceID: session.workspaceID,
                taskID: taskID,
                payload: [
                    "completion_gate_passed": "true",
                    "completion_evidence": "successful command execution recorded"
                ]
            )
        )
        session.apply(event: makeEvent(.feedbackGenerated, sequence: 2, workspaceID: session.workspaceID, taskID: taskID))
        session.apply(event: makeEvent(.policyUpdated, sequence: 3, workspaceID: session.workspaceID, taskID: taskID))

        XCTAssertEqual(session.currentState, .completed)
        XCTAssertEqual(session.interactionState, .completed)
    }

    func testFeedbackEventCreatesActionableArtifactFromPayloadDetail() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Assess AI agent integration")
        let taskID = UUID()
        let detail = "Verdict: Assessment-only complete.\nProblems to resolve:\n- Identify the legacy extension point."

        session.apply(
            event: makeEvent(
                .feedbackGenerated,
                sequence: 1,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Integration assessment",
                payload: [
                    "kind": FeedbackKind.missingIntegration.rawValue,
                    "detail": detail
                ]
            )
        )

        XCTAssertEqual(session.artifacts.last?.title, "Integration assessment")
        XCTAssertEqual(session.artifacts.last?.type, .apiMapping)
        XCTAssertEqual(session.artifacts.last?.detail, detail)
    }

    func testImplementationFeedbackEventsCreatePatchAndVerificationArtifacts() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Approved AI agent implementation")
        let taskID = UUID()

        session.apply(
            event: makeEvent(
                .feedbackGenerated,
                sequence: 1,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Code patch",
                payload: [
                    "kind": FeedbackKind.codePatch.rawValue,
                    "detail": "Patch scope"
                ]
            )
        )
        session.apply(
            event: makeEvent(
                .feedbackGenerated,
                sequence: 2,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Verification report",
                payload: [
                    "kind": FeedbackKind.verificationReport.rawValue,
                    "detail": "Required verification"
                ]
            )
        )

        XCTAssertTrue(session.artifacts.contains { $0.title == "Code patch" && $0.type == .codePatch })
        XCTAssertTrue(session.artifacts.contains { $0.title == "Verification report" && $0.type == .report })
    }

    func testApprovalEventChangesState() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        let taskID = UUID()
        session.apply(event: makeEvent(.taskCreated, sequence: 1, workspaceID: session.workspaceID, taskID: taskID))

        session.apply(
            event: makeEvent(
                .humanApprovalRequested,
                sequence: 2,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "High-risk approval requested",
                payload: ["command": "/bin/rm", "risk_level": "high"]
            )
        )

        XCTAssertEqual(session.currentState, .waitingApproval)
        XCTAssertEqual(session.messages.last?.type, .approvalRequest)
        XCTAssertEqual(session.messages.last?.content, "I need your approval before continuing. Requested action: `/bin/rm`. Risk: high.")
    }

    func testUserMessageEventRestoresVisibleUserReply() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")

        let event = makeEvent(
            .userMessageReceived,
            sequence: 1,
            workspaceID: session.workspaceID,
            taskID: nil,
            summary: "User message received",
            payload: [
                "session_id": session.sessionID.uuidString,
                "message": "Use a safer approach"
            ]
        )

        session.apply(event: event)

        XCTAssertEqual(session.messages.last?.sender, .user)
        XCTAssertEqual(session.messages.last?.content, "Use a safer approach")
        XCTAssertEqual(session.messages.last?.relatedEventID, event.id)
    }

    func testInitialUserMessageEventDoesNotDuplicateUserGoal() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")

        session.apply(
            event: makeEvent(
                .userMessageReceived,
                sequence: 1,
                workspaceID: session.workspaceID,
                taskID: nil,
                summary: "User mission received",
                payload: [
                    "session_id": session.sessionID.uuidString,
                    "message": "Investigate API"
                ]
            )
        )

        XCTAssertEqual(session.messages.filter { $0.sender == .user && $0.content == "Investigate API" }.count, 1)
    }

    func testApprovalRejectedStopsSessionWithVisibleAgentExplanation() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        session.currentState = .waitingApproval
        session.pauseForApproval()

        _ = AgentInteractionController().approvalRejected(session: &session, approvalID: UUID())

        XCTAssertEqual(session.currentState, .failed)
        XCTAssertEqual(session.interactionState, .failed)
        XCTAssertTrue(session.messages.contains {
            $0.sender == .agent
                && $0.type == .warning
                && $0.content.contains("requested action was rejected")
        })
    }

    func testUserApprovalRejectedEventMarksSessionFailed() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        session.currentState = .waitingApproval

        session.apply(
            event: makeEvent(
                .userApprovalRejected,
                sequence: 1,
                workspaceID: session.workspaceID,
                taskID: nil,
                summary: "User approval rejected",
                payload: ["session_id": session.sessionID.uuidString]
            )
        )

        XCTAssertEqual(session.currentState, .failed)
        XCTAssertEqual(session.interactionState, .failed)
    }

    private func makeTask(
        id: UUID,
        workspaceID: UUID,
        plan: [PlanStep] = []
    ) -> FDETask {
        FDETask(
            id: id,
            workspaceID: workspaceID,
            title: "Investigate API",
            rawInput: "Investigate API",
            state: .created,
            plan: plan,
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func makeEvent(
        _ type: EventType,
        sequence: Int64,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String? = nil,
        payload: [String: String] = [:]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(),
            summary: summary ?? type.rawValue,
            payload: payload
        )
    }
}
