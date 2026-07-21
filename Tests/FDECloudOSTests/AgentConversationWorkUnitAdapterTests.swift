import XCTest
@testable import FDECloudOS

final class AgentConversationWorkUnitAdapterTests: XCTestCase {
    func testRuntimeEventMessagesRemainInConversationAndWorkStatusMetadata() {
        let workspaceID = UUID()
        let taskID = UUID()
        let createdAt = Date(timeIntervalSince1970: 0)
        let toolCalled = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "step_id": "inspect",
                "tool_call_id": "tool.inspect",
                "command": "/bin/pwd"
            ]
        )
        let stepExecuted = makeEvent(
            .stepExecuted,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Inspect workspace",
            payload: [
                "step_id": "inspect",
                "tool_call_id": "tool.inspect",
                "command": "/bin/pwd",
                "exit_code": "0"
            ]
        )
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Audit workspace",
            createdAt: createdAt
        )
        conversation.append(
            AgentMessage(
                timestamp: createdAt.addingTimeInterval(0.5),
                type: .actionUpdate,
                content: "I've started a runtime execution for this mission."
            )
        )
        conversation.append(AgentResponseComposer.message(for: toolCalled))
        conversation.append(AgentResponseComposer.message(for: stepExecuted))

        let items = AgentConversationWorkUnitAdapter.displayItems(
            conversation: conversation,
            events: [stepExecuted, toolCalled]
        )
        let messageCount = items.filter(\.isMessage).count
        let streamingResponses = items.compactMap(\.streamingResponse)
        let workUnitCards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: [stepExecuted, toolCalled]
        )

        XCTAssertEqual(messageCount, 1)
        XCTAssertEqual(streamingResponses.count, 3)
        XCTAssertEqual(streamingResponses.last?.chunks.count, 1)
        XCTAssertEqual(streamingResponses.last?.markdown, "Confirmed the current workspace path and recorded it as evidence.")
        XCTAssertEqual(workUnitCards.count, 1)
        XCTAssertEqual(workUnitCards.first?.completedSteps, ["Inspect workspace"])
        XCTAssertEqual(workUnitCards.first?.toolsUsed, ["/bin/pwd"])
        XCTAssertEqual(workUnitCards.first?.rawEvents.map(\.eventType), [.toolCalled, .stepExecuted])
    }

    func testReadOnlyToolChipUsesSafeLabelAndCanonicalRelativePath() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "step_id": "read-backend-manifest",
                "tool_call_id": "tool.read-backend-manifest",
                "command": "engineering.read_file",
                "arguments": "workspace=legacy path=server/package.json",
                "normalized_relative_path": "server/package.json",
                "target_path": "server/package.json"
            ]
        )
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Inspect backend manifest",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let card = try XCTUnwrap(
            AgentConversationWorkUnitAdapter.workStatusCards(
                conversation: conversation,
                events: [event]
            ).first
        )

        XCTAssertEqual(card.toolsUsed, ["Read file · server/package.json"])
        XCTAssertFalse(card.toolsUsed[0].contains("engineering..."))
        XCTAssertFalse(card.toolsUsed[0].contains("workspace="))
    }

    func testWorkUnitNarrationUsesReplacedAgentMessageContent() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "step_id": "inspect",
                "tool_call_id": "tool.inspect",
                "command": "/bin/pwd"
            ]
        )
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Audit workspace",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        conversation.append(
            AgentMessage(
                timestamp: event.timestamp,
                sender: .agent,
                type: .actionUpdate,
                content: "LLM narration after replacement",
                relatedEventID: event.id
            )
        )

        let responses = AgentConversationWorkUnitAdapter.displayItems(
            conversation: conversation,
            events: [event]
        )
        .compactMap(\.streamingResponse)
        let card = try XCTUnwrap(
            AgentConversationWorkUnitAdapter.workStatusCards(
                conversation: conversation,
                events: [event]
            )
            .first
        )

        XCTAssertEqual(responses.map(\.markdown), ["LLM narration after replacement"])
        XCTAssertEqual(card.narration, "Inspecting the selected scope and preparing an evidence-grounded assessment.")
    }

    func testStreamingResponseUpdatesFromIncrementalMessageChunks() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "step_id": "inspect",
                "command": "/bin/pwd"
            ]
        )
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Audit workspace",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let message = AgentMessage(
            timestamp: event.timestamp,
            sender: .agent,
            type: .actionUpdate,
            content: "",
            relatedEventID: event.id
        )
        conversation.append(message)

        XCTAssertTrue(conversation.appendMessageChunk(messageID: message.id, chunk: "Completed checks:\n"))
        XCTAssertTrue(conversation.appendMessageChunk(messageID: message.id, chunk: "- Current directory"))

        let responses = AgentConversationWorkUnitAdapter.displayItems(
            conversation: conversation,
            events: [event]
        )
        .compactMap(\.streamingResponse)
        let card = try XCTUnwrap(
            AgentConversationWorkUnitAdapter.workStatusCards(
                conversation: conversation,
                events: [event]
            ).first
        )

        XCTAssertEqual(responses.map(\.markdown), ["Completed checks:\n- Current directory"])
        XCTAssertEqual(card.narration, "Inspecting the selected scope and preparing an evidence-grounded assessment.")
    }

    func testRuntimeStreamingResponseKeepsSameNarrationFromDistinctEvents() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let firstCheck = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "step_id": "inspect-a",
                "command": "/bin/pwd"
            ]
        )
        let repeatedCheck = makeEvent(
            .toolCalled,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "step_id": "inspect-b",
                "command": "/bin/pwd"
            ]
        )
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Audit workspace",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        conversation.append(AgentResponseComposer.message(for: firstCheck))
        conversation.append(AgentResponseComposer.message(for: repeatedCheck))

        let responses = AgentConversationWorkUnitAdapter.displayItems(
            conversation: conversation,
            events: [firstCheck, repeatedCheck]
        )
        .compactMap(\.streamingResponse)
        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: [firstCheck, repeatedCheck]
        )

        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(Set(responses.map(\.markdown)).count, 1)
        XCTAssertNotEqual(responses[0].id, responses[1].id)
        XCTAssertEqual(cards.count, 1)
    }

    func testStableEventIDDeduplicatesMainStreamAndWorkStatus() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            payload: [
                "step_id": "inspect",
                "tool_call_id": "tool.inspect",
                "command": "/bin/pwd"
            ]
        )
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Audit workspace",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        conversation.append(AgentResponseComposer.message(for: event))
        conversation.append(
            AgentMessage(
                timestamp: event.timestamp.addingTimeInterval(0.1),
                sender: .agent,
                type: .actionUpdate,
                content: "Checking the current workspace path.",
                relatedEventID: event.id
            )
        )

        let responses = AgentConversationWorkUnitAdapter.displayItems(
            conversation: conversation,
            events: [event, event]
        )
        .compactMap(\.streamingResponse)
        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: [event, event]
        )

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.markdown, "Checking the current workspace path.")
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.rawEvents.map(\.id), [event.id])
    }

    func testLiveWorkTraceStillReceivesEveryRuntimeEvent() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(
                .toolCalled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: ["step_id": "inspect", "command": "/bin/pwd"]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Inspect workspace",
                payload: ["step_id": "inspect", "command": "/bin/pwd"]
            )
        ]
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Audit workspace",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        conversation.append(contentsOf: AgentResponseComposer.messages(for: events))

        let liveTrace = LiveExecutionMapper.snapshot(task: nil, events: events)

        XCTAssertEqual(
            AgentConversationWorkUnitAdapter.workStatusCards(
                conversation: conversation,
                events: events
            )
            .count,
            1
        )
        XCTAssertEqual(liveTrace.timeline.count, events.count)
    }

    func testCompletedTaskDoesNotCloseUnmatchedActiveOrWaitingWorkUnits() throws {
        let workspaceID = UUID()
        let completedTaskID = UUID()
        let activeTaskID = UUID()
        let activeTool = makeEvent(
            .toolCalled,
            sequence: 3,
            workspaceID: workspaceID,
            taskID: activeTaskID,
            payload: [
                "step_id": "still-running",
                "tool_call_id": "tool.still-running",
                "command": "/usr/bin/head"
            ]
        )
        let waitingApproval = makeEvent(
            .humanApprovalRequested,
            sequence: 4,
            workspaceID: workspaceID,
            taskID: activeTaskID,
            payload: [
                "approval_request_id": UUID().uuidString,
                "step_id": "awaiting-approval",
                "tool_call_id": "tool.awaiting-approval",
                "command": "engineering.write_patch"
            ]
        )
        let events = [
            makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: completedTaskID),
            makeEvent(.planGenerated, sequence: 2, workspaceID: workspaceID, taskID: completedTaskID),
            activeTool,
            waitingApproval,
            makeEvent(
                .taskCompleted,
                sequence: 5,
                workspaceID: workspaceID,
                taskID: completedTaskID,
                payload: [
                    "completion_gate_passed": "true",
                    "completion_evidence": "successful command execution recorded"
                ]
            )
        ]
        var conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Run two independent missions",
            createdAt: Date(timeIntervalSince1970: 0)
        )
        conversation.append(contentsOf: AgentResponseComposer.messages(for: events))

        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: events
        )
        XCTAssertFalse(cards.isEmpty)
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.status, .completed)
        XCTAssertTrue(cards.first?.rawEvents.contains { $0.eventType == .taskCompleted } == true)
        XCTAssertFalse(cards.first?.rawEvents.contains { $0.id == activeTool.id || $0.id == waitingApproval.id } == true)
    }

    func testSyntheticLifecycleEventsDoNotCountAsExecutionEvidence() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(
                .contextCompiled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Workspace context compiled",
                payload: ["command": "workspace_context_compiled"]
            ),
            makeEvent(
                .planGenerated,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Plan generated",
                payload: ["command": "plan_generated"]
            ),
            makeEvent(
                .stateUpdated,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Execution started",
                payload: [
                    "state": TaskState.running.rawValue,
                    "command": "execution_started"
                ]
            ),
            makeEvent(
                .taskCompleted,
                sequence: 4,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Result event created",
                payload: ["command": "result_event_created"]
            )
        ]
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Plan the change",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: events
        )

        XCTAssertTrue(cards.flatMap(\.toolsUsed).isEmpty)
        XCTAssertTrue(cards.flatMap(\.completedSteps).isEmpty)
        XCTAssertTrue(cards.allSatisfy { $0.evidenceSummary == nil })
    }

    func testWorkStatusMetricsComeOnlyFromRealToolResults() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(
                .contextCompiled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: ["command": "workspace_context_compiled"]
            ),
            makeEvent(
                .planGenerated,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: ["command": "plan_generated"]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Read AgentConversationView.swift",
                payload: [
                    "step_id": "read-file",
                    "tool_call_id": "tool.read-file",
                    "command": "engineering.read_file",
                    "target_path": "Sources/FDECloudOS/UI/Components/AgentConversationView.swift",
                    "evidence_kind": "file_read_result",
                    "success": "true",
                    "exit_code": "0"
                ]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 4,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Changed title text",
                payload: [
                    "step_id": "edit-title",
                    "tool_call_id": "tool.edit-title",
                    "command": "engineering.edit_file",
                    "target_path": "Sources/FDECloudOS/UI/Components/AgentConversationView.swift",
                    "evidence_kind": "file_patch",
                    "diff": "- Old title\n+ New title",
                    "success": "true",
                    "exit_code": "0"
                ]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 5,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "swift build passed",
                payload: [
                    "step_id": "swift-build",
                    "tool_call_id": "tool.swift-build",
                    "command": "/usr/bin/swift",
                    "arguments": "build",
                    "evidence_kind": "build_result",
                    "success": "true",
                    "exit_code": "0"
                ]
            ),
            makeEvent(
                .taskCompleted,
                sequence: 6,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "completion_gate_passed": "true",
                    "completion_evidence": "file read, non-empty diff, and swift build result"
                ]
            )
        ]
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "修改标题文字，然后运行 swift build。",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: events
        )
        let tools = Set(cards.flatMap(\.toolsUsed))
        let completedSteps = cards.flatMap(\.completedSteps)
        let evidenceCards = cards.filter { $0.evidenceSummary != nil }

        XCTAssertEqual(tools, [
            "Read file · Sources/FDECloudOS/UI/Components/AgentConversationView.swift",
            "engineering.edit_file",
            "/usr/bin/swift build"
        ])
        XCTAssertEqual(completedSteps.count, 3)
        XCTAssertEqual(evidenceCards.count, 1)
        XCTAssertEqual(
            evidenceCards.first?.rawEvents.filter { $0.eventType == .stepExecuted }.count,
            3
        )
    }

    func testRepairableWorkspaceAndPlannerFailuresProjectBlockedWorkStatus() {
        let workspaceID = UUID()
        let taskID = UUID()
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Inspect Legacy read-only",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        for blocker in [
            PlanReadinessBlocker.workspaceScopeMismatch.rawValue,
            PlanReadinessBlocker.plannerTimeout.rawValue
        ] {
            let events = [
                makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID),
                makeEvent(
                    .stateUpdated,
                    sequence: 2,
                    workspaceID: workspaceID,
                    taskID: taskID,
                    payload: [
                        "state": TaskState.blocked.rawValue,
                        "mission_state": MissionState.blocked.rawValue,
                        "blocker_reason": blocker
                    ]
                )
            ]

            let cards = AgentConversationWorkUnitAdapter.workStatusCards(
                conversation: conversation,
                events: events
            )
            let blocked = cards.first { $0.status == .blocked }
            XCTAssertNotNil(blocked, "Expected BLOCKED Work Status for \(blocker)")
            XCTAssertEqual(blocked?.narration, "The bounded run stopped before it could complete.")
            XCTAssertFalse(cards.contains { $0.status == .failed })
        }
    }

    func testPlannedFailedAndWaitingMissionsDoNotAppearFullyDone() {
        let workspaceID = UUID()
        let taskID = UUID()
        let planOnlyEvents = [
            makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.contextCompiled, sequence: 2, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.planGenerated, sequence: 3, workspaceID: workspaceID, taskID: taskID)
        ]
        let failedEvents = planOnlyEvents + [
            makeEvent(
                .toolFailed,
                sequence: 4,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: ["step_id": "build", "command": "/usr/bin/swift", "arguments": "build"]
            )
        ]
        let waitingEvents = planOnlyEvents + [
            makeEvent(
                .humanApprovalRequested,
                sequence: 4,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: ["approval_request_id": UUID().uuidString]
            )
        ]
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Prepare work",
            createdAt: Date(timeIntervalSince1970: 0)
        )

        let plannedCards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: planOnlyEvents
        )
        let failedCards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: failedEvents
        )
        let waitingCards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: waitingEvents
        )

        XCTAssertNotEqual(plannedCards.last?.status, .completed)
        XCTAssertEqual(failedCards.last?.status, .failed)
        XCTAssertEqual(waitingCards.last?.status, .waitingApproval)
        XCTAssertFalse([plannedCards, failedCards, waitingCards].contains { cards in
            cards.contains { $0.kind == .result && $0.status == .completed }
        })
    }

    func testWorkspaceAuditMissionRendersFewerConversationCardsAndKeepsLiveTraceEvents() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "FDE Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: AdapterRecordingToolExecutor()
        )

        let task = try await kernel.submitTask(input: "Audit the local workspace", workspace: workspace)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        var session = AgentSession(workspace: workspace, userGoal: "Audit the local workspace")
        session.syncRuntimeTask(task)
        for event in events {
            session.apply(event: event)
        }

        let displayItems = AgentConversationWorkUnitAdapter.displayItems(
            conversation: session.conversation,
            events: events
        )
        let runtimeMessageCount = session.conversation.messages.filter { $0.relatedEventID != nil }.count
        let streamingResponseCount = displayItems.compactMap(\.streamingResponse).count
        let workUnitCardCount = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: session.conversation,
            events: events
        )
        .count
        let liveTrace = LiveExecutionMapper.snapshot(task: task, events: events)

        XCTAssertEqual(task.state, .completed)
        XCTAssertFalse(events.isEmpty)
        XCTAssertEqual(streamingResponseCount, runtimeMessageCount)
        XCTAssertEqual(workUnitCardCount, 1)
        XCTAssertEqual(runtimeMessageCount, 1)
        XCTAssertEqual(liveTrace.timeline.count, events.count)
    }

    func testArchitectureMissionKeepsInspectionTargetsInWorkStatusOnly() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "FDE Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: AdapterRecordingToolExecutor()
        )

        let input = "帮我看看这个项目架构有什么问题，并给出改进建议"
        let task = try await kernel.submitTask(input: input, workspace: workspace)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        var session = AgentSession(workspace: workspace, userGoal: input)
        session.syncRuntimeTask(task)
        for event in events {
            session.apply(event: event)
        }

        let responses = AgentConversationWorkUnitAdapter.displayItems(
            conversation: session.conversation,
            events: events
        )
        .compactMap(\.streamingResponse)
        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: session.conversation,
            events: events
        )

        XCTAssertTrue(responses.allSatisfy { $0.id != "stream-runtime-\(session.conversation.id.uuidString)" })
        XCTAssertFalse(cards.isEmpty)
        XCTAssertTrue(cards.flatMap(\.rawEvents).contains { $0.eventType == .toolCalled })
    }

    func testPendingClarificationSessionDoesNotRenderPreviousTaskWorkStatus() throws {
        let workspaceID = UUID()
        let oldTaskID = UUID()
        let currentSession = AgentSession(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userGoal: "帮我",
            interactionState: .waitingForUser
        )
        let currentClarificationEvent = makeEvent(
            .stateUpdated,
            sequence: 3,
            workspaceID: workspaceID,
            taskID: nil,
            summary: "Agent paused for user input",
            payload: [
                "session_id": currentSession.sessionID.uuidString,
                "interaction_state": AgentInteractionState.waitingForUser.rawValue
            ]
        )
        let previousTaskEvent = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: oldTaskID,
            payload: [
                "step_id": "old-inspect",
                "command": "/bin/ls"
            ]
        )
        let unrelatedSessionEvent = makeEvent(
            .stateUpdated,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: nil,
            payload: ["session_id": UUID().uuidString]
        )

        let scopedEvents = AgentSessionEventScope.events(
            from: [previousTaskEvent, unrelatedSessionEvent, currentClarificationEvent],
            for: currentSession
        )
        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: currentSession.conversation,
            events: scopedEvents
        )

        XCTAssertEqual(scopedEvents, [currentClarificationEvent])
        XCTAssertTrue(cards.isEmpty)
        XCTAssertFalse(
            AgentNarrationEngine.feed(task: nil, events: scopedEvents)
                .completedActions
                .contains { $0.detail?.contains("/bin/ls") == true }
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
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: summary ?? type.rawValue,
            payload: payload
        )
    }
}

private extension AgentConversationDisplayItem {
    var isMessage: Bool {
        if case .message = content {
            return true
        }
        return false
    }

    var streamingResponse: AgentConversationStreamingResponse? {
        if case let .streamingResponse(response) = content {
            return response
        }
        return nil
    }
}

private actor AdapterRecordingToolExecutor: ToolExecuting {
    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "ok \(call.command)",
            standardError: "",
            duration: 0.001
        )
    }
}
