import XCTest
@testable import FDECloudOS

final class ConversationRuntimeContractTests: XCTestCase {
    func testFiveTurnsPersistAndRenderFiveAgentRepliesInExactTurnOrder() async throws {
        let workspace = Workspace.default()
        let prompts = ["嗯", "你好", "你是谁？你能做什么", "具体一点", "具体一点说你是做什么的"]
        let replies = (1...5).map { "这是第 \($0) 个独立回答：我是 FDE Agent，会在对话中保留每一轮消息，并在明确授权后处理工程任务。" }
        let provider = ContractSequencedProvider(replies: replies)
        let runtime = ContractRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: provider)
        let firstMessageID = UUID()
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(
            with: prompts[0],
            messageID: firstMessageID,
            turnID: firstMessageID,
            timestamp: Date(timeIntervalSince1970: 1)
        )

        _ = try await coordinator.startMission(
            input: prompts[0],
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageID: firstMessageID
        )
        for prompt in prompts.dropFirst() {
            _ = try await coordinator.resumeMission(
                reply: prompt,
                workspace: workspace,
                session: &session,
                runtime: runtime
            )
        }

        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .user }.count, 5)
        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 5)
        XCTAssertEqual(session.conversation.messages.enumerated().map { index, message in
            index.isMultiple(of: 2) ? message.sender == .user : message.sender == .agent
        }, Array(repeating: true, count: 10))
        let persistedReplies = session.conversation.messages
            .filter { $0.sender == .agent }
            .map(\.content)
        XCTAssertEqual(persistedReplies.count, 5)
        XCTAssertEqual(persistedReplies.first, replies.first)
        XCTAssertEqual(persistedReplies.last, replies.last)
        XCTAssertTrue(persistedReplies.allSatisfy { !$0.isEmpty })

        let rendered = AgentConversationWorkUnitAdapter.conciseDisplayItems(
            from: AgentConversationWorkUnitAdapter.displayItems(
                conversation: session.conversation,
                events: []
            ),
            hasMissionAssets: false
        )
        XCTAssertEqual(rendered.count, 10)
        XCTAssertEqual(rendered.filter(\.isAgentResponse).count, 5)
    }

    func testRepeatedIdenticalPromptsAndRepliesRemainDistinctStableTurns() {
        let workspace = Workspace.default()
        var session = AgentSession.newConversation(in: workspace)
        for index in 0..<5 {
            let messageID = UUID()
            session.appendUserMessage(
                "same prompt",
                messageID: messageID,
                turnID: messageID,
                timestamp: Date(timeIntervalSince1970: TimeInterval(index * 2))
            )
            session.appendInteractionMessage(AgentMessage(
                timestamp: Date(timeIntervalSince1970: TimeInterval(index * 2 + 1)),
                sender: .agent,
                type: .text,
                content: "same reply"
            ))
        }

        let users = session.conversation.messages.filter { $0.sender == .user }
        let agents = session.conversation.messages.filter { $0.sender == .agent }
        XCTAssertEqual(Set(users.map(\.id)).count, 5)
        XCTAssertEqual(Set(agents.map(\.id)).count, 5)
        XCTAssertEqual(Set(users.compactMap(\.turnID)).count, 5)
        XCTAssertEqual(agents.map(\.inReplyToMessageID), users.map { Optional($0.id) })
    }

    func testAsyncCompletionUpdatesOnlyOriginatingTurnAndKeepsAlternatingOrder() throws {
        let workspace = Workspace.default()
        let firstID = UUID()
        let secondID = UUID()
        var origin = AgentSession.newConversation(in: workspace)
        origin.beginConversation(with: "first", messageID: firstID, turnID: firstID)
        let captured = origin
        var completion = captured
        completion.appendInteractionMessage(AgentMessage(
            sender: .agent,
            type: .text,
            content: "first reply"
        ))
        var current = origin
        current.appendUserMessage("second", messageID: secondID, turnID: secondID)
        var sessions = [current]

        XCTAssertTrue(AgentSessionAsyncBinding.commit(
            originatingSession: captured,
            updatedSession: completion,
            into: &sessions
        ))

        let messages = try XCTUnwrap(sessions.first).conversation.messages
        XCTAssertEqual(messages.map(\.content), ["first", "first reply", "second"])
        XCTAssertEqual(messages[1].turnID, firstID)
        XCTAssertEqual(messages[1].inReplyToMessageID, firstID)
        XCTAssertNil(messages.last(where: { $0.turnID == secondID && $0.sender == .agent }))
    }

    func testSwitchingAndCodableRelaunchPreserveCompleteTranscript() throws {
        let workspace = Workspace.default()
        var first = AgentSession.newConversation(in: workspace)
        for index in 0..<5 {
            let id = UUID()
            first.appendUserMessage("prompt \(index)", messageID: id, turnID: id)
            first.appendInteractionMessage(AgentMessage(sender: .agent, type: .text, content: "reply \(index)"))
        }
        let second = AgentSession.newConversation(in: workspace)
        let switched = [second, first].first { $0.sessionID == first.sessionID }
        XCTAssertEqual(switched?.conversation.messages.count, 10)

        let data = try JSONEncoder().encode(first)
        let restored = try JSONDecoder().decode(AgentSession.self, from: data)
        XCTAssertEqual(restored.conversation.messages, first.conversation.messages)
        XCTAssertEqual(
            AgentConversationWorkUnitAdapter.displayItems(
                conversation: restored.conversation,
                events: []
            ).count,
            10
        )
    }

    func testClarificationCommandsWaitWithoutRuntimeMissionArtifactsOrAuthority() async throws {
        let cases: [(String, ConversationRuntimePreflightReason, String)] = [
            ("Assess an AI integration", .missingAssessmentTarget, "module, API, workflow, or subsystem"),
            ("Propose an isolated patch", .missingPatchScope, "behavior should change"),
            ("Inspect a customer system", .missingInspectionTarget, "customer system, root, repository")
        ]

        for (input, reason, expectedQuestion) in cases {
            let workspace = Workspace.default()
            let runtime = ContractRuntime()
            let provider = ContractSequencedProvider(replies: ["provider must not be called"])
            let coordinator = AgentRuntimeCoordinator(chatProvider: provider)
            let messageID = UUID()
            var session = AgentSession.newConversation(in: workspace)
            session.beginConversation(with: input, messageID: messageID, turnID: messageID)

            let result = try await coordinator.startMission(
                input: input,
                workspace: workspace,
                session: &session,
                runtime: runtime,
                userMessageID: messageID
            )

            XCTAssertEqual(ConversationRuntimePreflight.evaluate(input)?.reason, reason)
            XCTAssertTrue(result.waitingForUser, input)
            XCTAssertNil(result.task, input)
            XCTAssertEqual(session.interactionState, .waitingForUser, input)
            XCTAssertTrue(session.conversation.messages.last?.content.contains(expectedQuestion) == true, input)
            XCTAssertNil(session.runtimeTaskID, input)
            XCTAssertTrue(session.artifacts.isEmpty, input)
            XCTAssertTrue(session.evidence.isEmpty, input)
            let submittedInputs = await runtime.submittedInputs()
            let providerRequests = await provider.requestCount()
            XCTAssertTrue(submittedInputs.isEmpty, input)
            XCTAssertEqual(providerRequests, 0, input)
        }
    }

    func testProductionReadinessReviewWithoutExactArtifactIsLocallyGated() async throws {
        let workspace = Workspace.default()
        let input = "Review production readiness"
        let runtime = ContractRuntime()
        let provider = ContractSequencedProvider(replies: ["provider must not be called"])
        let messageID = UUID()
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(with: input, messageID: messageID, turnID: messageID)

        let result = try await AgentRuntimeCoordinator(chatProvider: provider).startMission(
            input: input,
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageID: messageID,
            preflightContext: .empty
        )

        XCTAssertTrue(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .waitingForUser)
        XCTAssertTrue(session.conversation.messages.last?.content.contains("exact Production Readiness Report") == true)
        let submittedInputs = await runtime.submittedInputs()
        let providerRequests = await provider.requestCount()
        XCTAssertTrue(submittedInputs.isEmpty)
        XCTAssertEqual(providerRequests, 0)
    }

    func testProviderFailurePersistsOneReplyPerTurnAndUsesBlockedProvider() async throws {
        let workspace = Workspace.default()
        let runtime = ContractRuntime()
        let firstID = UUID()
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(with: "hello", messageID: firstID, turnID: firstID)
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        _ = try await coordinator.startMission(
            input: "hello",
            workspace: workspace,
            session: &session,
            runtime: runtime,
            userMessageID: firstID
        )
        _ = try await coordinator.resumeMission(
            reply: "hello",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertEqual(session.interactionState, .blockedProvider)
        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 2)
        XCTAssertEqual(
            session.conversation.messages.filter { $0.sender == .agent }.map(\.content),
            Array(repeating: "Unable to reach the configured AI provider.", count: 2)
        )
        XCTAssertTrue(session.artifacts.isEmpty)
        XCTAssertNil(session.runtimeTaskID)
    }

    func testEmptyDraftRetentionIsFailClosedAndPromotesOnFirstMessage() {
        let workspace = Workspace.default()
        let first = AgentSession.newConversation(in: workspace)
        let second = AgentSession.newConversation(in: workspace)
        let sessions = [first, second]

        XCTAssertEqual(
            AgentConversationSessionRetention.reusableEmptyDraft(
                in: sessions,
                workspaceID: workspace.id,
                selectedSessionID: first.sessionID,
                drafts: [:]
            )?.sessionID,
            first.sessionID
        )
        XCTAssertTrue(
            AgentConversationSessionRetention.removingSafelyDisposableEmptySessions(
                from: sessions,
                drafts: [:]
            ).isEmpty
        )

        var promoted = first
        let messageID = UUID()
        promoted.beginConversation(with: "Hello", messageID: messageID, turnID: messageID)
        let retained = AgentConversationSessionRetention.removingSafelyDisposableEmptySessions(
            from: [first, promoted],
            drafts: [:]
        )
        XCTAssertEqual(retained.map(\.sessionID), [promoted.sessionID])
        XCTAssertEqual(retained.first?.conversation.messages.count, 1)
    }

    func testCleanupNeverRemovesSessionsWithAnyDurableSignal() {
        let workspace = Workspace.default()
        let base = AgentSession.newConversation(in: workspace)
        var withMessage = base
        withMessage.appendUserMessage("Hello")
        var withTask = base
        withTask.workspaceContext.runtimeTaskID = UUID()
        var withMission = base
        withMission.workspaceContext.missionTaskIDs = [UUID()]
        var withArtifact = base
        withArtifact.addArtifact(AgentArtifact(id: "artifact", title: "Report", detail: "real"))
        var withEvidence = base
        withEvidence.evidence = [AgentEvidence(id: "evidence", kind: .reports, title: "Evidence", detail: "real")]
        var withEvent = base
        withEvent.workspaceContext.latestEventSequence = 1
        var withTurnBinding = base
        withTurnBinding.workspaceContext.activeTurnID = UUID()

        for session in [withMessage, withTask, withMission, withArtifact, withEvidence, withEvent, withTurnBinding] {
            XCTAssertFalse(AgentConversationSessionRetention.isSafelyDisposableEmptySession(session))
        }
        XCTAssertFalse(AgentConversationSessionRetention.isSafelyDisposableEmptySession(
            base,
            draftText: "unsent draft"
        ))
        XCTAssertFalse(AgentConversationSessionRetention.isSafelyDisposableEmptySession(
            base,
            hasActivityOrAuditEvents: true
        ))
        XCTAssertFalse(AgentConversationSessionRetention.isSafelyDisposableEmptySession(
            base,
            hasHumanActionsOrApprovals: true
        ))
    }
}

private extension AgentConversationDisplayItem {
    var isAgentResponse: Bool {
        switch content {
        case let .message(message): return message.sender == .agent
        case .streamingResponse: return true
        }
    }
}

private actor ContractRuntime: AgentRuntimeExecuting {
    private var inputs: [String] = []
    private var events: [ExecutionEvent] = []

    func submitTask(input: String, workspace: Workspace) async throws -> FDETask {
        inputs.append(input)
        return FDETask(
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
        let event = ExecutionEvent(
            id: UUID(),
            parentEventID: events.last?.id,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: Int64(events.count + 1),
            timestamp: Date(timeIntervalSince1970: TimeInterval(events.count + 1)),
            summary: summary,
            payload: payload
        )
        events.append(event)
        return event
    }

    func submittedInputs() -> [String] { inputs }
}

private actor ContractSequencedProvider: AgentChatProviding {
    nonisolated let kind: ModelProviderKind = .openAI
    nonisolated let isAvailable = true
    nonisolated let disabledReason: String? = nil
    nonisolated let modelIdentifier: String? = "contract-provider"
    private let replies: [String]
    private var requests: [AgentChatRequest] = []

    init(replies: [String]) {
        self.replies = replies
    }

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        requests.append(request)
        let index = min(requests.count - 1, replies.count - 1)
        return AgentChatResponse(
            content: replies[index],
            confidence: 0.95,
            provider: .openAI
        )
    }

    func requestCount() -> Int { requests.count }
}
