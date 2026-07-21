import Foundation
import XCTest
@testable import FDECloudOS

final class AgentConversationActivityTests: XCTestCase {
    func testNormalChatLocalLifecycleShowsOneUnpersistedThinkingActivity() {
        let session = AgentSession(workspaceID: UUID(), userGoal: "Are you there?")
        let activity = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: session.sessionID,
            scope: .normalChat
        )

        let projected = AgentConversationActivityReducer.activity(
            session: session,
            events: [],
            localActivity: activity
        )

        XCTAssertEqual(projected?.kind, .thinking)
        XCTAssertEqual(projected?.label, "Thinking…")
        XCTAssertEqual(session.conversation.messages.count, 1)
        XCTAssertFalse(session.conversation.messages.contains { $0.content == "Thinking…" })
    }

    func testNormalChatProviderFailureReturnsFailedLifecycleWithOneCanonicalReply() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "Are you there?")
        let runtime = ActivityTestRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: DelayedFailingChatProvider())

        let result = try await coordinator.startMission(
            input: "Are you there?",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertEqual(result.normalChatLifecycle, .failed)
        XCTAssertEqual(session.conversation.messages.count, 2)
        XCTAssertEqual(session.conversation.messages.first?.sender, .user)
        XCTAssertEqual(session.conversation.messages.last?.sender, .agent)
        XCTAssertEqual(session.conversation.messages.last?.content, "Unable to reach the configured AI provider.")
        XCTAssertEqual(result.recordedEvents.last?.payload["chat_lifecycle"], NormalChatLifecycle.failed.rawValue)
    }

    func testRestoredProviderFailureKeepsProviderSpecificWorkStatus() {
        var session = AgentSession(workspaceID: UUID(), userGoal: "Are you there?")
        session.currentState = .failed
        session.setInteractionState(.blockedProvider)

        let projected = AgentConversationActivityReducer.activity(
            session: session,
            events: [],
            localActivity: nil
        )

        XCTAssertEqual(projected?.scope, .normalChat)
        XCTAssertEqual(projected?.kind, .failed)
        XCTAssertEqual(projected?.label, AgentConversationActivity.providerUnavailableLabel)
        XCTAssertNil(projected?.metadata.taskID)
    }

    func testNormalChatCompletionKeepsCanonicalAnswerAndHidesThinkingActivity() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "Are you there?")
        let runtime = ActivityTestRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: SuccessfulActivityChatProvider())

        let result = try await coordinator.startMission(
            input: "Are you there?",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )
        var activity = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: session.sessionID,
            scope: .normalChat
        )
        activity.kind = result.normalChatLifecycle == .completed ? .completed : .failed

        XCTAssertEqual(result.normalChatLifecycle, .completed)
        XCTAssertEqual(session.conversation.messages.last?.content, "Yes, I am here.")
        XCTAssertFalse(activity.kind.isVisible)
        XCTAssertFalse(session.conversation.messages.contains { $0.content == "Thinking…" })
    }

    func testPreinsertedUserReplyIsNotDuplicatedWhileProviderIsPending() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "First message")
        session.appendUserMessage("Follow-up")
        let runtime = ActivityTestRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: SuccessfulActivityChatProvider())

        _ = try await coordinator.resumeMission(
            reply: "Follow-up",
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageAlreadyAppended: true
        )

        XCTAssertEqual(session.conversation.messages.filter {
            $0.sender == .user && $0.content == "Follow-up"
        }.count, 1)
    }

    func testEngineeringLifecycleUsesOrderedRealEventsAndOneDerivedState() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let dialogID = UUID()
        var activity = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: dialogID,
            scope: .engineeringTask,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        activity.metadata.taskID = taskID
        let events = [
            event(.taskCreated, 1, workspaceID, taskID),
            event(.contextCompiled, 2, workspaceID, taskID, payload: ["codebase_roles": "legacy_software"]),
            event(.stateUpdated, 3, workspaceID, taskID, payload: [
                "lifecycle_event": "PROVIDER_REQUEST_PENDING",
                "provider_stage": "planner"
            ]),
            event(.planGenerated, 4, workspaceID, taskID, payload: ["lifecycle_event": "PLAN_REPAIR_REQUESTED"]),
            event(.planGenerated, 5, workspaceID, taskID, payload: [
                "lifecycle_event": "PLAN_READINESS_CHECKED",
                "is_ready": "true"
            ]),
            event(.toolCalled, 6, workspaceID, taskID, payload: [
                "command": "engineering.inspect_project",
                "tool_call_id": "inspect"
            ]),
            event(.stepExecuted, 7, workspaceID, taskID, payload: [
                "command": "engineering.inspect_project",
                "tool_call_id": "inspect",
                "success": "true"
            ]),
            event(.toolCalled, 8, workspaceID, taskID, payload: [
                "command": "engineering.read_file",
                "normalized_relative_path": "server/package.json",
                "tool_call_id": "read"
            ]),
            event(.stateUpdated, 9, workspaceID, taskID, payload: [
                "lifecycle_event": "OBSERVATION_RECORDED",
                "provider_stage": "observation_next_action",
                "evidence_count": "1"
            ]),
            event(.stateUpdated, 10, workspaceID, taskID, payload: [
                "lifecycle_event": "GRACEFUL_FINALIZATION_STARTED",
                "provider_stage": "final_grounded_answer",
                "evidence_count": "1"
            ])
        ]
        let expectedKinds: [AgentConversationActivityKind] = [
            .preparingTask, .compilingContext, .planning, .repairingPlan, .validatingPlan,
            .inspectingProject, .analyzingEvidence, .readingFile, .analyzingEvidence, .preparingFinalAnswer
        ]

        for (index, item) in events.enumerated() {
            activity = AgentConversationActivityReducer.reduce(activity, event: item)
            XCTAssertEqual(activity.kind, expectedKinds[index])
        }
        XCTAssertEqual(activity.label, "Preparing grounded findings…")
    }

    func testSafeRelativeReadFileLabelNeverShowsAbsoluteRoot() {
        let workspaceID = UUID()
        let taskID = UUID()
        var activity = engineeringActivity(taskID: taskID)
        let read = event(.toolCalled, 1, workspaceID, taskID, payload: [
            "command": "engineering.read_file",
            "target_path": "server/package.json"
        ])

        activity = AgentConversationActivityReducer.reduce(activity, event: read)

        XCTAssertEqual(activity.label, "Reading server/package.json…")
        let privatePath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("project/server/package.json").path
        XCTAssertFalse(activity.label.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertNil(AgentConversationActivityCopy.safeRelativePath(privatePath))
        XCTAssertNil(AgentConversationActivityCopy.safeRelativePath("server/../secrets.env"))
    }

    func testCentralizedToolLabelsCoverApprovedReadOnlyToolsAndUnknownFallback() {
        let taskID = UUID()
        let workspaceID = UUID()
        let cases: [(String, String)] = [
            ("engineering.inspect_project", "Inspecting project structure…"),
            ("engineering.list_directory", "Listing project files…"),
            ("engineering.search_files", "Searching files…"),
            ("engineering.search_code", "Searching source code…"),
            ("unknown.read_only_tool", "Running a workspace inspection…")
        ]

        for (index, item) in cases.enumerated() {
            let activity = AgentConversationActivityReducer.reduce(
                engineeringActivity(taskID: taskID),
                event: event(.toolCalled, Int64(index + 1), workspaceID, taskID, payload: ["command": item.0])
            )
            XCTAssertEqual(activity.label, item.1)
        }
    }

    func testLegacyInspectActivityNeverClaimsAgentWorkspace() {
        let workspaceID = UUID()
        let taskID = UUID()
        var activity = engineeringActivity(taskID: taskID)
        let inspect = event(.toolCalled, 1, workspaceID, taskID, payload: [
            "command": "engineering.inspect_project",
            "workspace_identity": "legacy",
            "normalized_relative_path": "."
        ])

        activity = AgentConversationActivityReducer.reduce(activity, event: inspect)

        XCTAssertEqual(activity.label, "Inspecting Legacy workspace project structure…")
        XCTAssertFalse(activity.label.contains("Agent workspace"))
    }

    func testObservationPendingShowsEvidenceCount() {
        let taskID = UUID()
        let item = event(.stateUpdated, 1, UUID(), taskID, payload: [
            "lifecycle_event": "OBSERVATION_RECORDED",
            "provider_stage": "observation_next_action",
            "evidence_count": "5"
        ])
        let activity = AgentConversationActivityReducer.reduce(
            engineeringActivity(taskID: taskID),
            event: item
        )

        XCTAssertEqual(activity.kind, .analyzingEvidence)
        XCTAssertEqual(activity.label, "Analyzing evidence · 5 findings")
    }

    func testRetryableProviderEventShowsOneSafeRetry() {
        let taskID = UUID()
        let item = event(.stateUpdated, 1, UUID(), taskID, payload: [
            "lifecycle_event": "PROVIDER_RETRY_REQUESTED",
            "provider_stage": "planner",
            "attempt": "2"
        ])
        let activity = AgentConversationActivityReducer.reduce(
            engineeringActivity(taskID: taskID),
            event: item
        )

        XCTAssertEqual(activity.kind, .retryingProvider)
        XCTAssertEqual(activity.label, "Connection interrupted · retrying once…")
    }

    func testGroundedPartialIsStableAndDominatesEarlierReading() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let session = AgentSession(workspaceID: workspaceID, userGoal: "Inspect")
        let events = [
            event(.toolCalled, 1, workspaceID, taskID, payload: [
                "command": "engineering.read_file",
                "target_path": "package.json"
            ]),
            event(.stateUpdated, 2, workspaceID, taskID, payload: [
                "state": TaskState.blocked.rawValue,
                "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                "evidence_requirements_unsatisfied_count": "2",
                "grounded_answer": "true"
            ])
        ]

        let activity = try XCTUnwrap(
            AgentConversationActivityReducer.activity(session: session, events: events, localActivity: nil)
        )

        XCTAssertEqual(activity.kind, .partial)
        XCTAssertEqual(activity.label, "Partial result · 2 areas remain")
        XCTAssertFalse(activity.kind.isAnimated)
    }

    func testGroundedPartialReportRemainsCanonicalConversationAnswer() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        var session = AgentSession(workspaceID: workspaceID, userGoal: "Inspect")
        session.workspaceContext.runtimeTaskID = taskID
        let partial = event(.stateUpdated, 1, workspaceID, taskID, payload: [
            "state": TaskState.blocked.rawValue,
            "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
            "grounded_answer": "true",
            "final_answer": "Grounded partial report",
            "user_visible_message": "Grounded partial report",
            "evidence_requirements_unsatisfied_count": "2"
        ])
        session.apply(event: partial)

        let responses = AgentConversationWorkUnitAdapter.displayItems(
            conversation: session.conversation,
            events: [partial]
        )
        .compactMap { item -> AgentConversationStreamingResponse? in
            if case let .streamingResponse(response) = item.content {
                return response
            }
            return nil
        }

        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.markdown, "Grounded partial report")
        XCTAssertFalse(responses.first?.markdown.contains("BLOCKED_WITH_PARTIAL_RESULT") == true)
    }

    func testTerminalProjectionMarksHistoricalFinalizationDone() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: workspaceID,
            userRequest: "Inspect"
        )
        let events = [
            event(.stateUpdated, 1, workspaceID, taskID, payload: [
                "state": TaskState.running.rawValue,
                "lifecycle_event": "GRACEFUL_FINALIZATION_STARTED"
            ]),
            event(.stateUpdated, 2, workspaceID, taskID, payload: [
                "state": TaskState.running.rawValue,
                "lifecycle_event": "GRACEFUL_FINALIZATION_FALLBACK"
            ]),
            event(.stateUpdated, 3, workspaceID, taskID, payload: [
                "state": TaskState.blocked.rawValue,
                "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                "grounded_answer": "true"
            ])
        ]

        let cards = AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: conversation,
            events: events
        )

        XCTAssertEqual(cards.last?.status, .partial)
        XCTAssertFalse(cards.dropLast().contains { $0.status == .active })
    }

    func testBlockedAndFailedReplaceEarlierActiveStateWithSafeCopy() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let session = AgentSession(workspaceID: workspaceID, userGoal: "Inspect")
        let reading = event(.toolCalled, 1, workspaceID, taskID, payload: [
            "command": "engineering.read_file",
            "target_path": "package.json"
        ])
        let blocked = event(.stateUpdated, 2, workspaceID, taskID, payload: [
            "state": TaskState.blocked.rawValue,
            "blocker_reason": "planner_timeout"
        ])
        let failed = event(.toolFailed, 3, workspaceID, taskID, payload: [
            "state": TaskState.failed.rawValue,
            "error": "file access denied"
        ])

        let blockedActivity = try XCTUnwrap(
            AgentConversationActivityReducer.activity(
                session: session,
                events: [reading, blocked],
                localActivity: nil
            )
        )
        let failedActivity = try XCTUnwrap(
            AgentConversationActivityReducer.activity(
                session: session,
                events: [reading, blocked, failed],
                localActivity: nil
            )
        )

        XCTAssertEqual(blockedActivity.label, "Blocked · the planning request timed out")
        XCTAssertEqual(failedActivity.label, "Failed · file access was denied")
        XCTAssertFalse(failedActivity.kind.isAnimated)
    }

    func testUnrelatedNormalChatMasksPreviousPartialMissionActivity() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        var session = AgentSession(workspaceID: workspaceID, userGoal: "Inspect")
        session.workspaceContext.runtimeTaskID = taskID
        let partial = event(.stateUpdated, 1, workspaceID, taskID, payload: [
            "state": TaskState.blocked.rawValue,
            "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT"
        ])
        let chat = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: session.sessionID,
            scope: .normalChat
        )

        let activity = try XCTUnwrap(
            AgentConversationActivityReducer.activity(
                session: session,
                events: [partial],
                localActivity: chat
            )
        )

        XCTAssertEqual(activity.kind, .thinking)
        XCTAssertEqual(activity.label, "Thinking…")
    }

    func testSameTaskContinuationDoesNotReplayStalePartialAsCurrentActivity() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        var session = AgentSession(workspaceID: workspaceID, userGoal: "Inspect")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .blocked
        let oldPartial = event(.stateUpdated, 1, workspaceID, taskID, payload: [
            "state": TaskState.blocked.rawValue,
            "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT"
        ])
        var continuation = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: session.sessionID,
            scope: .engineeringTask,
            startedAt: Date(timeIntervalSince1970: 2)
        )
        continuation.metadata.taskID = taskID

        let preparing = try XCTUnwrap(
            AgentConversationActivityReducer.activity(
                session: session,
                events: [oldPartial],
                localActivity: continuation
            )
        )

        XCTAssertEqual(preparing.kind, .preparingTask)
        XCTAssertEqual(preparing.label, "Preparing task…")
    }

    func testReplayAndLiveDuplicateEventUpdatesEvidenceOnce() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let result = event(.stepExecuted, 1, workspaceID, taskID, payload: [
            "success": "true",
            "tool_call_id": "read-package",
            "command": "engineering.read_file"
        ])
        let session = AgentSession(workspaceID: workspaceID, userGoal: "Inspect")

        let activity = try XCTUnwrap(
            AgentConversationActivityReducer.activity(
                session: session,
                events: [result, result],
                localActivity: nil
            )
        )

        XCTAssertEqual(activity.metadata.evidenceCount, 1)
        XCTAssertEqual(activity.kind, .analyzingEvidence)
    }

    func testConversationCleanupKeepsCanonicalAnswerAndAuditHistory() {
        let workspaceID = UUID()
        let taskID = UUID()
        var session = AgentSession(workspaceID: workspaceID, userGoal: "Inspect")
        let events = [
            event(.taskCreated, 1, workspaceID, taskID),
            event(.contextCompiled, 2, workspaceID, taskID),
            event(.planGenerated, 3, workspaceID, taskID),
            event(.toolCalled, 4, workspaceID, taskID, payload: ["command": "engineering.inspect_project"]),
            event(.stepExecuted, 5, workspaceID, taskID, payload: ["success": "true"]),
            event(.taskCompleted, 6, workspaceID, taskID, payload: [
                "state": TaskState.completed.rawValue,
                "grounded_answer": "true",
                "detail": "Canonical grounded report",
                "success": "true"
            ])
        ]
        events.forEach { session.apply(event: $0) }

        let visible = AgentConversationWorkUnitAdapter.displayItems(
            conversation: session.conversation,
            events: events
        )

        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertTrue(session.conversation.messages.last?.content.contains("Canonical grounded report") == true)
        XCTAssertEqual(visible.count, 2)
        XCTAssertFalse(AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: session.conversation,
            events: events
        ).isEmpty)
    }

    func testReducedMotionKeepsTextAndDisablesAnimation() {
        let activity = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: UUID(),
            scope: .normalChat
        )

        XCTAssertEqual(activity.label, "Thinking…")
        XCTAssertTrue(activity.shouldAnimate(reduceMotion: false))
        XCTAssertFalse(activity.shouldAnimate(reduceMotion: true))
    }

    func testApprovedActivityCopyDoesNotExposeReasoningFields() {
        let taskID = UUID()
        let item = event(.toolCalled, 1, UUID(), taskID, payload: [
            "command": "engineering.read_file",
            "target_path": "Sources/App.swift",
            "reasoning": "private reasoning",
            "chain_of_thought": "hidden",
            "authorization": "secret"
        ])
        let activity = AgentConversationActivityReducer.reduce(
            engineeringActivity(taskID: taskID),
            event: item
        )
        let visible = activity.label.lowercased()

        XCTAssertEqual(activity.label, "Reading Sources/App.swift…")
        XCTAssertFalse(visible.contains("reasoning"))
        XCTAssertFalse(visible.contains("hidden"))
        XCTAssertFalse(visible.contains("authorization"))
    }

    func testAIAssessmentMissionStatesUpdateLiveBeforeTaskFinalization() {
        let taskID = UUID()
        let workspaceID = UUID()
        var activity = engineeringActivity(taskID: taskID)
        var labels: [String] = []

        for (index, state) in AIAssessmentMissionState.allCases.enumerated() {
            let snapshot = AIAssessmentActivitySnapshot(
                capability: "Customer Support Agent",
                missionState: state,
                compatibility: nil,
                risk: nil,
                blockerCount: nil,
                evidenceCount: index
            )
            let item = event(
                .stateUpdated,
                Int64(index + 1),
                workspaceID,
                taskID,
                payload: [
                    "lifecycle_event": "AI_ASSESSMENT_ACTIVITY",
                    "state": TaskState.running.rawValue,
                    "evidence_count": String(index)
                ].merging(snapshot.eventPayload) { current, _ in current }
            )

            activity = AgentConversationActivityReducer.reduce(activity, event: item)
            labels.append(activity.label)
            XCTAssertEqual(activity.metadata.aiAssessment?.missionState, state)
            XCTAssertFalse(activity.kind.isTerminal)
        }

        XCTAssertEqual(
            labels,
            AIAssessmentMissionState.allCases.map { "\($0.rawValue)…" }
        )
        XCTAssertEqual(activity.metadata.evidenceCount, AIAssessmentMissionState.allCases.count - 1)
    }

    private func engineeringActivity(taskID: UUID) -> AgentConversationActivity {
        var activity = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: UUID(),
            scope: .engineeringTask,
            startedAt: Date(timeIntervalSince1970: 0)
        )
        activity.metadata.taskID = taskID
        return activity
    }

    private func event(
        _ type: EventType,
        _ sequence: Int64,
        _ workspaceID: UUID,
        _ taskID: UUID?,
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
            summary: type.rawValue,
            payload: payload
        )
    }
}

private struct DelayedFailingChatProvider: AgentChatProviding {
    let kind: ModelProviderKind = .openAI
    let modelIdentifier: String? = "activity-test"
    let isAvailable = true
    let disabledReason: String? = nil

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        try await Task.sleep(nanoseconds: 20_000_000)
        throw ModelRoutingError.providerUnavailable("connection lost")
    }
}

private struct SuccessfulActivityChatProvider: AgentChatProviding {
    let kind: ModelProviderKind = .openAI
    let modelIdentifier: String? = "activity-test"
    let isAvailable = true
    let disabledReason: String? = nil

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        AgentChatResponse(content: "Yes, I am here.", provider: kind)
    }
}

private actor ActivityTestRuntime: AgentRuntimeExecuting {
    private var events: [ExecutionEvent] = []

    func submitTask(input: String, workspace: Workspace) async throws -> FDETask {
        FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: input,
            rawInput: input,
            state: .running,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func requestStepPause(taskID: UUID, reason: String) async {}
    func resumeTask(taskID: UUID, instruction: String?) async {}
    func changeTaskApproach(taskID: UUID, instruction: String) async {}
    func stopTask(taskID: UUID, reason: String) async {}

    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        let item = ExecutionEvent(
            id: UUID(),
            parentEventID: events.last?.id,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: Int64(events.count + 1),
            timestamp: Date(),
            summary: summary,
            payload: payload
        )
        events.append(item)
        return item
    }
}
