import XCTest
@testable import FDECloudOS

final class AgentConversationTests: XCTestCase {
    func testUserMessageCreatesConversation() {
        let sessionID = UUID()
        let workspaceID = UUID()
        let createdAt = Date(timeIntervalSince1970: 10)

        let conversation = AgentConversation.started(
            sessionID: sessionID,
            workspaceID: workspaceID,
            userRequest: "Fix customer API failure",
            createdAt: createdAt
        )

        XCTAssertEqual(conversation.sessionID, sessionID)
        XCTAssertEqual(conversation.workspaceID, workspaceID)
        XCTAssertEqual(conversation.messages.count, 1)
        XCTAssertEqual(conversation.messages.first?.type, .text)
        XCTAssertEqual(conversation.messages.first?.sender, .user)
        XCTAssertEqual(conversation.messages.first?.content, "Fix customer API failure")
        XCTAssertEqual(conversation.createdAt, createdAt)
        XCTAssertEqual(conversation.updatedAt, createdAt)
    }

    func testRuntimeEventsGenerateAgentMessages() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.planGenerated, sequence: 2, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.toolCalled, sequence: 3, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.connectorCalled, sequence: 4, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.policyUpdated, sequence: 5, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.taskCompleted, sequence: 6, workspaceID: workspaceID, taskID: taskID)
        ]

        let messages = AgentResponseComposer.messages(for: events)

        XCTAssertEqual(messages.map(\.content), [
            "The runtime did not provide a grounded completion report."
        ])
        XCTAssertEqual(messages.map(\.type), [.result])
    }

    func testComposerDeduplicatesRepeatedTraceEventsForConversation() {
        let workspaceID = UUID()
        let taskID = UUID()
        let repeatedPayload = ["command": "/bin/ls", "attempt": "1", "max_attempts": "1"]
        let events = [
            makeEvent(.toolCalled, sequence: 1, workspaceID: workspaceID, taskID: taskID, payload: repeatedPayload),
            makeEvent(.toolCalled, sequence: 2, workspaceID: workspaceID, taskID: taskID, payload: repeatedPayload),
            makeEvent(.executionDispatched, sequence: 3, workspaceID: workspaceID, taskID: taskID)
        ]

        let messages = AgentResponseComposer.messages(for: events)

        XCTAssertTrue(messages.isEmpty)
    }

    func testComposerDoesNotLeakChainOfThoughtStdoutOrSecrets() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(
                .toolCalled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "chain_of_thought: use token=SECRET_VALUE",
                payload: [
                    "command": "/usr/bin/curl --token SECRET_VALUE https://example.com",
                    "stdout": "SECRET_VALUE",
                    "stderr": "chain_of_thought"
                ]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "stdout SECRET_VALUE",
                payload: [
                    "stdout": "SECRET_VALUE",
                    "token": "SECRET_VALUE"
                ]
            )
        ]

        let rendered = AgentResponseComposer.messages(for: events)
            .map(\.content)
            .joined(separator: "\n")

        XCTAssertFalse(rendered.contains("SECRET_VALUE"))
        XCTAssertFalse(rendered.lowercased().contains("chain_of_thought"))
        XCTAssertFalse(rendered.lowercased().contains("stdout"))
        XCTAssertFalse(rendered.lowercased().contains("token="))
        XCTAssertFalse(AgentResponseComposer.containsRestrictedContent(rendered))
    }

    func testEvidenceMessagesAttachRelatedEventAndArtifactIDs() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = makeEvent(.stepExecuted, sequence: 1, workspaceID: workspaceID, taskID: taskID)

        let message = AgentResponseComposer.message(for: event)

        XCTAssertEqual(message.type, .observation)
        XCTAssertEqual(message.relatedEventID, event.id)
        XCTAssertEqual(message.relatedArtifactID, "event-\(event.id.uuidString)")
    }

    func testReplayReproducesConversationOrdering() {
        let workspaceID = UUID()
        let taskID = UUID()
        let sessionID = UUID()
        let createdAt = Date(timeIntervalSince1970: 0)
        let later = makeEvent(.taskCompleted, sequence: 3, workspaceID: workspaceID, taskID: taskID)
        let earlier = makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID)
        let middle = makeEvent(.planGenerated, sequence: 2, workspaceID: workspaceID, taskID: taskID)

        let conversation = AgentResponseComposer.replayConversation(
            sessionID: sessionID,
            workspaceID: workspaceID,
            userRequest: "Fix customer API failure",
            events: [later, earlier, middle],
            createdAt: createdAt
        )

        XCTAssertEqual(conversation.messages.map(\.content), [
            "Fix customer API failure",
            "The runtime did not provide a grounded completion report."
        ])
    }

    func testLiveComposerFallsBackToDeterministicNarrationWhenOpenAIKeyIsMissing() async {
        let configuration = ModelProviderConfiguration(
            preferredProvider: nil,
            openAIAPIKey: nil,
            anthropicAPIKey: nil,
            openAIModel: "test-model",
            claudeModel: "test-claude"
        )
        let composer = AgentResponseComposer.live(configuration: configuration)
        let event = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: UUID(),
            taskID: UUID(),
            payload: ["command": "/bin/pwd"]
        )

        let message = await composer.liveMessage(for: event)

        XCTAssertFalse(composer.usesLiveNarration)
        XCTAssertEqual(message.content, "Checking the current workspace path.")
    }

    func testLiveComposerAutoEnablesOpenAIWhenKeyExists() {
        let configuration = ModelProviderConfiguration(
            preferredProvider: nil,
            openAIAPIKey: "test-key",
            anthropicAPIKey: nil,
            openAIModel: "test-model",
            claudeModel: "test-claude"
        )
        let composer = AgentResponseComposer.live(configuration: configuration)

        XCTAssertTrue(composer.usesLiveNarration)
    }

    func testOpenAINarrationUsesStructuredJSONAndDoesNotSendRawLogsOrSecrets() async throws {
        let client = CapturingNarrationHTTPClient(
            content: #"{"content":"I am checking the workspace state before using the result.","message_type":"ACTION_UPDATE","confidence":0.86}"#
        )
        let provider = OpenAIProvider(apiKey: "test-key", model: "test-model", httpClient: client)
        let composer = AgentResponseComposer(narrationProvider: provider)
        let event = makeEvent(
            .toolCalled,
            sequence: 1,
            workspaceID: UUID(),
            taskID: UUID(),
            summary: "chain_of_thought: use token=SECRET_VALUE",
            payload: [
                "command": "/usr/bin/curl --token SECRET_VALUE https://example.com",
                "stdout": "SECRET_VALUE",
                "stderr": "raw execution log"
            ]
        )

        let message = await composer.liveMessage(for: event)
        let capturedBody = await client.lastRequestBody()
        let requestBody = try XCTUnwrap(capturedBody)

        XCTAssertEqual(message.content, "I am checking the workspace state before using the result.")
        XCTAssertEqual(message.type, .actionUpdate)
        XCTAssertFalse(requestBody.contains("SECRET_VALUE"))
        XCTAssertFalse(requestBody.lowercased().contains("chain_of_thought"))
        XCTAssertFalse(requestBody.lowercased().contains("stdout"))
        XCTAssertFalse(requestBody.lowercased().contains("stderr"))
        XCTAssertFalse(requestBody.lowercased().contains("token=secret"))
    }

    func testOpenAIChatUsesResponsesAPIAndDecodesNaturalAnswer() async throws {
        let client = CapturingNarrationHTTPClient(
            content: #"{"content":"可以，我会先按聊天方式回答；只有你明确要求执行时才进入工作区。","confidence":0.91}"#
        )
        let provider = OpenAIProvider(apiKey: "test-key", model: "test-model", httpClient: client)

        let response = try await provider.generateChatResponse(
            for: AgentChatRequest(
                message: "你能做什么？",
                detectedLanguage: "zh",
                intentType: .answerQuestion,
                workspaceName: "PetFound",
                interactionState: .idle,
                hasRuntimeTask: false,
                selectedMode: .fdeCapabilityExplanation,
                recentMessages: [
                    AgentChatMessageContext(sender: .user, type: .text, content: "你好"),
                    AgentChatMessageContext(sender: .agent, type: .text, content: "你好，我在。")
                ]
            )
        )
        let capturedBody = await client.lastRequestBody()
        let requestBody = try XCTUnwrap(capturedBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(requestBody.utf8)) as? [String: Any]
        )
        let inputMessages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let systemMessage = try XCTUnwrap(inputMessages.first?["content"] as? String)
        let roles = inputMessages.compactMap { $0["role"] as? String }
        let finalUserMessage = try XCTUnwrap(inputMessages.last?["content"] as? String)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])

        XCTAssertEqual(response.content, "可以，我会先按聊天方式回答；只有你明确要求执行时才进入工作区。")
        XCTAssertEqual(response.provider, .openAI)
        XCTAssertTrue(systemMessage.contains("Legacy-to-Agent") || systemMessage.contains("traditional software"))
        XCTAssertTrue(systemMessage.contains("Mode: fdeCapabilityExplanation"))
        XCTAssertEqual(format["type"] as? String, "json_object")
        XCTAssertEqual(roles, ["system", "user", "assistant", "user"])
        XCTAssertEqual(finalUserMessage, "你能做什么？")
        XCTAssertFalse(requestBody.contains(#""runtime_profile""#))
        XCTAssertFalse(requestBody.contains(#""current_mission_state""#))
        XCTAssertFalse(requestBody.contains("```"))
    }

    func testClaudeChatUsesMessagesAPIAndDecodesNaturalAnswer() async throws {
        let client = CapturingNarrationHTTPClient(
            content: #"{"content":"你好，我可以先正常聊天；需要检查项目时会进入工作区任务。","confidence":0.88}"#
        )
        let provider = ClaudeProvider(apiKey: "test-key", model: "test-claude", httpClient: client)

        let response = try await provider.generateChatResponse(
            for: AgentChatRequest(
                message: "你好",
                detectedLanguage: "zh",
                intentType: .unknown,
                workspaceName: "FDE",
                interactionState: .idle,
                hasRuntimeTask: false,
                selectedMode: .casualConversation,
                recentMessages: []
            )
        )
        let capturedBody = await client.lastRequestBody()
        let requestBody = try XCTUnwrap(capturedBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(requestBody.utf8)) as? [String: Any]
        )
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let userMessage = try XCTUnwrap(messages.first?["content"] as? String)

        XCTAssertEqual(response.content, "你好，我可以先正常聊天；需要检查项目时会进入工作区任务。")
        XCTAssertEqual(response.provider, .claude)
        XCTAssertEqual(body["model"] as? String, "test-claude")
        XCTAssertNotNil(body["system"] as? String)
        XCTAssertEqual(userMessage, "你好")
        XCTAssertTrue((body["system"] as? String)?.contains("Mode: casualConversation") == true)
        XCTAssertFalse(requestBody.contains(#""runtime_profile""#))
        XCTAssertFalse(requestBody.contains("```"))
    }

    func testUnsupportedNamedFileInspectionClaimIsRejectedWithoutToolEvidence() {
        let request = AgentChatRequest(
            message: "How should the activity UI work?",
            detectedLanguage: "en",
            intentType: .answerQuestion,
            workspaceName: "FDE",
            interactionState: .idle,
            hasRuntimeTask: false,
            selectedMode: .engineeringExplanation,
            recentMessages: []
        )
        let response = AgentChatResponse(
            content: "I read package.json, webpack.config.js, app.js, and knexfile.js before answering.",
            confidence: 0.9
        )

        let reason = FDEChatQualityGuard().rejectionReason(for: response, request: request)

        XCTAssertTrue(reason?.hasPrefix("unsupported_evidence_claim") == true)
        XCTAssertTrue(reason?.contains("no_matching_tool_call_and_result") == true)
    }

    func testMatchingReadFileToolEvidencePermitsNamedFileClaim() {
        let workspaceID = UUID()
        let taskID = UUID()
        let evidence = AgentToolEvidenceContext(
            toolCallID: "read-package",
            toolName: "engineering.read_file",
            workspaceID: workspaceID,
            taskID: taskID,
            workspaceIdentity: "legacy",
            targetPath: "package.json",
            toolCalledEventID: UUID(),
            toolResultEventID: UUID()
        )
        let request = AgentChatRequest(
            message: "What did you inspect?",
            detectedLanguage: "en",
            intentType: .answerQuestion,
            workspaceName: "FDE",
            interactionState: .completed,
            hasRuntimeTask: true,
            selectedMode: .casualConversation,
            recentMessages: [],
            toolEvidence: [evidence],
            activeTaskContextIncluded: true
        )
        let response = AgentChatResponse(content: "I read package.json in the selected Legacy workspace.", confidence: 0.9)

        XCTAssertNil(FDEChatQualityGuard().rejectionReason(for: response, request: request))
    }

    func testInspectProjectEvidenceDoesNotAuthorizeSpecificReadFileClaim() {
        let evidence = AgentToolEvidenceContext(
            toolCallID: "inspect-root",
            toolName: "engineering.inspect_project",
            workspaceID: UUID(),
            taskID: UUID(),
            workspaceIdentity: "legacy",
            targetPath: ".",
            toolCalledEventID: UUID(),
            toolResultEventID: UUID()
        )
        let reason = AgentEvidenceClaimGuard().rejectionReason(
            for: "I read package.json and found the dependencies there.",
            evidence: [evidence],
            workspaceID: evidence.workspaceID
        )

        XCTAssertEqual(reason, "unsupported_evidence_claim:path=package.json")
    }

    func testEvidenceClaimGuardKeepsMultiCharacterExtensionsIntact() {
        let workspaceID = UUID()
        let evidence = AgentToolEvidenceContext(
            toolCallID: "read-architecture",
            toolName: "engineering.read_file",
            workspaceID: workspaceID,
            taskID: nil,
            workspaceIdentity: "legacy",
            targetPath: "docs/architecture.md",
            toolCalledEventID: UUID(),
            toolResultEventID: UUID()
        )
        let reason = AgentEvidenceClaimGuard().rejectionReason(
            for: "## 实际读取的文件\n\n- 已读取 `docs/architecture.md`。",
            evidence: [evidence],
            workspaceID: workspaceID
        )

        XCTAssertNil(reason)
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

private actor CapturingNarrationHTTPClient: LLMHTTPClient {
    private let content: String
    private var requestBody: String?

    init(content: String) {
        self.content = content
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let responseData = try JSONSerialization.data(withJSONObject: [
            "output_text": content
        ])
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.openai.com/v1/responses")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }

    func lastRequestBody() -> String? {
        requestBody
    }
}
