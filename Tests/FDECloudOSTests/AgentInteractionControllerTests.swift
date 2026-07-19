import XCTest
@testable import FDECloudOS

final class AgentInteractionControllerTests: XCTestCase {
    func testAgentAsksQuestionUserRespondsAndAgentResumes() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Debug customer integration")
        let controller = AgentInteractionController()

        let questionID = controller.askQuestion(
            "I need one decision before continuing.",
            options: [
                AgentMessageOption(id: "use_existing_oauth", title: "Use existing OAuth credential"),
                AgentMessageOption(id: "create_connector", title: "Create new connector"),
                AgentMessageOption(id: "analyze_without_auth", title: "Analyze without authentication")
            ],
            session: &session
        )

        XCTAssertEqual(session.interactionState, .waitingForUser)
        XCTAssertEqual(session.conversation.messages.last?.type, .question)
        XCTAssertEqual(session.conversation.messages.last?.options.count, 3)

        let event = controller.selectDecision(
            optionID: "use_existing_oauth",
            messageID: questionID,
            session: &session
        )

        XCTAssertEqual(event.type, .userDecisionSelected)
        XCTAssertEqual(event.payload["option_id"], "use_existing_oauth")
        XCTAssertEqual(session.interactionState, .understanding)
        XCTAssertEqual(
            session.conversation.messages.first(where: { $0.id == questionID })?.selectedOptionID,
            "use_existing_oauth"
        )
        XCTAssertTrue(session.conversation.messages.contains { $0.content == "Continuing with your selected approach" })
    }

    func testUserReplyResumesWaitingAgent() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        let controller = AgentInteractionController()
        _ = controller.askQuestion(
            "Which system should I inspect first?",
            options: [AgentMessageOption(id: "billing", title: "Billing Sync")],
            session: &session
        )

        let event = controller.receiveUserReply("Check Billing Sync first", session: &session)

        XCTAssertEqual(event.type, .userMessageReceived)
        XCTAssertEqual(session.interactionState, .understanding)
        XCTAssertEqual(session.conversation.messages.last?.sender, .user)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
    }

    func testApprovalRequestFlowUpdatesInteractionState() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        let approvalID = UUID()
        let taskID = UUID()
        let controller = AgentInteractionController()
        session.setInteractionState(.working)
        session.workspaceContext.runtimeTaskID = taskID

        session.apply(
            event: makeEvent(
                .humanApprovalRequested,
                sequence: 1,
                workspaceID: session.workspaceID,
                taskID: taskID,
                payload: ["approval_request_id": approvalID.uuidString]
            )
        )

        XCTAssertEqual(session.interactionState, .waitingForApproval)
        XCTAssertEqual(session.conversation.messages.last?.type, .approvalRequest)

        let event = controller.approvalGranted(session: &session, approvalID: approvalID)

        XCTAssertEqual(event.type, .userApprovalGranted)
        XCTAssertEqual(event.payload["approval_request_id"], approvalID.uuidString)
        XCTAssertEqual(session.interactionState, .working)
    }

    func testConversationPersistencePreservesInteractionStateAndOptions() throws {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Debug customer integration")
        let controller = AgentInteractionController()
        _ = controller.requestDecision(
            "Need your decision.",
            options: [
                AgentMessageOption(id: "a", title: "Option A"),
                AgentMessageOption(id: "b", title: "Option B")
            ],
            session: &session
        )

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AgentSession.self, from: data)

        XCTAssertEqual(decoded.interactionState, .waitingForUser)
        XCTAssertEqual(decoded.conversation.messages.last?.type, .decisionRequest)
        XCTAssertEqual(decoded.conversation.messages.last?.options.map(\.title), ["Option A", "Option B"])
    }

    func testMissionContinuationKeepsPreviousContext() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        session.workspaceContext.latestEventSequence = 12
        session.evidence.append(
            AgentEvidence(
                id: "event-1",
                kind: .runtimeEvent,
                title: "Previous execution",
                detail: "Prior evidence"
            )
        )
        let controller = AgentInteractionController()

        let event = controller.continueMission(session: &session)

        XCTAssertEqual(event.type, .userMessageReceived)
        XCTAssertEqual(event.payload["continuation"], "true")
        XCTAssertEqual(session.workspaceContext.latestEventSequence, 12)
        XCTAssertEqual(session.evidence.count, 1)
        XCTAssertTrue(session.conversation.messages.contains { $0.content == "Continuing from the previous mission context" })
    }

    func testArtifactGenerationFromRuntimeEvents() {
        var session = AgentSession(workspace: Workspace.default(), userGoal: "Investigate API")
        let taskID = UUID()
        session.workspaceContext.runtimeTaskID = taskID

        session.apply(
            event: makeEvent(
                .taskCompleted,
                sequence: 1,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Task completed with risk 12 and FDE score 98"
            )
        )
        session.apply(
            event: makeEvent(
                .policyUpdated,
                sequence: 2,
                workspaceID: session.workspaceID,
                taskID: taskID,
                summary: "Retry policy updated"
            )
        )

        XCTAssertTrue(session.artifacts.contains { $0.type == .report && $0.relatedTaskID == taskID })
        XCTAssertTrue(session.artifacts.contains { $0.type == .configChange && $0.approvalStatus == .approved })
        XCTAssertTrue(session.conversation.messages.contains { $0.type == .result })
        XCTAssertTrue(session.conversation.messages.contains { $0.type == .decision && $0.content.contains("planning lesson") })
    }

    func testReplayCompatibilityIncludesUserInteractionEventsInOrder() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(.taskCompleted, sequence: 4, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.userMessageReceived, sequence: 2, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.userDecisionSelected, sequence: 3, workspaceID: workspaceID, taskID: taskID)
        ]

        let conversation = AgentResponseComposer.replayConversation(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Debug customer integration",
            events: events,
            createdAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(conversation.messages.map(\.content), [
            "Debug customer integration",
            "I'll take a quick look at the workspace first, then turn that into a plan.",
            "User added an instruction",
            "User selected a path forward",
            "Finished successfully."
        ])
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
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: summary ?? type.rawValue,
            payload: payload
        )
    }
}
