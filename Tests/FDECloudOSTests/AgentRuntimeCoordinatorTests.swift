import XCTest
@testable import FDECloudOS

final class AgentRuntimeCoordinatorTests: XCTestCase {
    func testGreetingGetsChatReplyBeforeRuntimeStarts() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你好")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "你好，我在。"))

        let result = try await coordinator.startMission(
            input: "你好",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
        XCTAssertEqual(session.conversation.messages.last?.content, "你好，我在。")
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["mission_state"], MissionState.waitingHuman.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["tool_state"], ToolExecutionState.idle.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["decision_next_action"], AgentRuntimeAction.acknowledgeInstruction.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["decision_should_act"], "false")
        XCTAssertEqual(recordedEvents.last?.payload["chat_only"], "true")
    }

    func testVagueMissionStaysInChatBeforeRuntimeStarts() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "帮我")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "可以，先告诉我你想处理什么。"))

        let result = try await coordinator.startMission(
            input: "帮我",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
        XCTAssertEqual(session.conversation.messages.last?.content, "可以，先告诉我你想处理什么。")
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["decision_next_action"], AgentRuntimeAction.acknowledgeInstruction.rawValue)
    }

    func testDirectQuestionGetsChatReplyInsteadOfRuntimeTask() async throws {
        let workspace = Workspace.default()
        let question = "FDE 和 Claude Code 为什么完全不一样？"
        var session = AgentSession(workspace: workspace, userGoal: question)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "这是 chat-first 和 workflow-first 的产品入口差异。"))

        let result = try await coordinator.startMission(
            input: question,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.content, "这是 chat-first 和 workflow-first 的产品入口差异。")
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["chat_only"], "true")
    }

    func testActionableMissionStartsRuntimeFromConversationLoop() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "检查 Salesforce integration")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()

        let result = try await coordinator.startMission(
            input: "检查 Salesforce integration",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNotNil(result.task)
        XCTAssertEqual(session.interactionState, .running)
        let submittedInputs = await runtime.submittedInputs()
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(submittedInputs, ["检查 Salesforce integration"])
        XCTAssertEqual(recordedEvents.first?.payload["intent_type"], MissionIntentType.inspectWorkspace.rawValue)
        XCTAssertNotNil(recordedEvents.first?.payload["intent_confidence"])
        XCTAssertEqual(recordedEvents.last?.payload["mission_state"], MissionState.plan.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["tool_state"], ToolExecutionState.idle.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["decision_next_action"], AgentRuntimeAction.submitTask.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["decision_should_act"], "true")
        XCTAssertFalse(session.conversation.messages.contains {
            $0.content.contains("I have enough to start")
        })
    }

    func testShortAndLongChineseWorkspaceEngineeringPromptsRouteBeforeChatProvider() async throws {
        let inputs = [
            "只读取当前 Legacy 项目的根目录并列出主要文件，不要修改任何文件。",
            "请只读检查当前 Legacy 项目的 package.json 和 manifest，分析使用的 framework、database 与 dependency，验证主要文件并列出依据；不要修改任何文件，也不要包含 Agent 项目的上下文或统计。"
        ]

        for input in inputs {
            let workspace = Workspace.default()
            var session = AgentSession(workspace: workspace, userGoal: input)
            let runtime = FakeAgentRuntime()
            let provider = SequencedRecordingChatProvider(responses: [
                AgentChatResponse(content: "This should not be used.", confidence: 1, provider: .openAI)
            ])

            let result = try await AgentRuntimeCoordinator(chatProvider: provider).startMission(
                input: input,
                workspace: workspace,
                session: &session,
                runtime: runtime
            )

            let submissions = await runtime.submittedInputs()
            let chatRequests = await provider.recordedRequests()
            let events = await runtime.recordedEvents()
            XCTAssertNotNil(result.task, input)
            XCTAssertEqual(submissions, [input], input)
            XCTAssertTrue(chatRequests.isEmpty, input)
            let routeEvent = try XCTUnwrap(events.first, input)
            XCTAssertEqual(
                routeEvent.payload["selected_route"],
                AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue,
                input
            )
            XCTAssertEqual(routeEvent.payload["chat_only"], "false", input)
        }
    }

    func testCapabilityQuestionDoesNotStartRuntime() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你能做什么")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "我可以聊天、检查项目、修改代码和运行验证；只有你明确要求执行时才会进入工作区。"))

        let result = try await coordinator.startMission(
            input: "你能做什么",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
        XCTAssertEqual(session.conversation.messages.last?.content, "我可以聊天、检查项目、修改代码和运行验证；只有你明确要求执行时才会进入工作区。")
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["mission_state"], MissionState.waitingHuman.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["decision_next_action"], AgentRuntimeAction.acknowledgeInstruction.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["decision_should_act"], "false")
    }

    func testCapabilityQuestionWithoutLiveProviderReturnsHonestUnavailableMessage() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你能做什么？")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        let result = try await coordinator.startMission(
            input: "你能做什么？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNil(result.task)
        XCTAssertEqual(result.normalChatLifecycle, .failed)
        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertEqual(session.conversation.messages.last?.content, "Unable to reach the configured AI provider.")
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
    }

    func testStateMachineChatProviderReturnsNaturalIdentityAnswer() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你是谁")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: StateMachineChatProvider())

        let result = try await coordinator.startMission(
            input: "你是谁",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let content = try XCTUnwrap(session.conversation.messages.last?.content)
        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertTrue(content.contains("FDE Agent"))
        XCTAssertTrue(content.contains("工程助手"))
        XCTAssertTrue(content.contains("真实工具和文件证据"))
        XCTAssertFalse(content.contains("配置 OpenAI"))
        XCTAssertFalse(content.contains("RAG/LLM"))
        XCTAssertFalse(content.contains(MissionState.understand.rawValue))
        XCTAssertFalse(content.contains(AgentRuntimeAction.submitTask.rawValue))
        XCTAssertFalse(content.contains(AgentRuntimeAction.executeTool.rawValue))
        XCTAssertFalse(content.contains("你可以直接告诉我要检查、修改或运行什么"))
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["chat_only"], "true")
        XCTAssertEqual(recordedEvents.last?.payload["runtime_mode"], AgentRuntimeMode.fallback.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["used_fallback"], "true")
    }

    func testStateMachineChatProviderKeepsFollowUpCasualChatIdle() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你好")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: StateMachineChatProvider())

        _ = try await coordinator.startMission(
            input: "你好",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )
        let result = try await coordinator.resumeMission(
            reply: "hello",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let content = try XCTUnwrap(session.conversation.messages.last?.content)
        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(content, "Yes, I’m here.")
        XCTAssertFalse(content.contains("workspace execution"))
        XCTAssertFalse(content.contains(AgentInteractionState.working.rawValue))
        XCTAssertFalse(content.contains(MissionState.execute.rawValue))
    }

    func testMissingChatProviderReturnsHonestUnavailableMessage() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你好")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        let result = try await coordinator.startMission(
            input: "你好",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(result.normalChatLifecycle, .failed)
        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertEqual(session.conversation.messages.last?.content, "Unable to reach the configured AI provider.")
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["runtime_mode"], AgentRuntimeMode.fallback.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["used_fallback"], "true")
        XCTAssertEqual(recordedEvents.last?.payload["chat_lifecycle"], NormalChatLifecycle.failed.rawValue)
    }

    func testChatProviderFailureReturnsHonestUnavailableMessage() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你是做什么的？")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(
            chatProvider: FailingAgentChatProvider(errorMessage: "OpenAI authentication failed.")
        )

        let result = try await coordinator.startMission(
            input: "你是做什么的？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(result.normalChatLifecycle, .failed)
        XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertEqual(session.conversation.messages.last?.content, "Unable to reach the configured AI provider.")
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["runtime_mode"], AgentRuntimeMode.fallback.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["model_provider"], "")
    }

    func testAgentAbilityQuestionAboutCodeEditingStaysInChat() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "你会改写代码吗？")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "会，但我只有在你明确给出修改目标时才会进入工作区执行。"))

        let result = try await coordinator.startMission(
            input: "你会改写代码吗？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
        XCTAssertEqual(session.conversation.messages.last?.content, "会，但我只有在你明确给出修改目标时才会进入工作区执行。")
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["chat_only"], "true")
        XCTAssertEqual(recordedEvents.last?.payload["decision_next_action"], AgentRuntimeAction.acknowledgeInstruction.rawValue)
    }

    func testSoftwareTestingAbilityQuestionStaysInChat() async throws {
        let workspace = Workspace.default()
        let question = "你是否会解决软件测试的问题"
        var session = AgentSession(workspace: workspace, userGoal: question)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "会。我可以解释测试失败、检查测试文件，也可以在你明确要求时运行测试或修复失败。"))

        let result = try await coordinator.startMission(
            input: question,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.first?.payload["selected_route"], AgentRequestRoute.conversationalChat.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["chat_only"], "true")
    }

    func testWorkspaceTestFileListingStartsReadOnlyInvestigationTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEWorkspaceQuestion-\(UUID().uuidString)", isDirectory: true)
        let testsDir = root.appendingPathComponent("Tests", isDirectory: true)
        try FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)
        try "import XCTest\nfinal class FeatureTests: XCTestCase {}\n".write(
            to: testsDir.appendingPathComponent("FeatureTests.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Project",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: root.path
        )
        let input = "查看当前项目，告诉我有哪些测试文件。"
        var session = AgentSession(workspace: workspace, userGoal: input)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "unused"))

        let result = try await coordinator.startMission(
            input: input,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNotNil(result.task)
        XCTAssertEqual(session.interactionState, .running)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertEqual(submittedInputs, [input])
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.first?.payload["selected_route"], AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
        XCTAssertEqual(recordedEvents.first?.payload["chat_only"], "false")
    }

    func testReadOnlyFilenameInspectionStartsEngineeringTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEReadOnlyQuestion-\(UUID().uuidString)", isDirectory: true)
        let sourcesDir = root.appendingPathComponent("Sources/FDECloudOS/UI/Components", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        let source = """
        import SwiftUI

        struct AgentConversationView: View {
            let session: AgentSession
            let events: [ExecutionEvent]
            let approvals: [ApprovalRequest]
            let onApprove: (ApprovalRequest) -> Void

            private var displayItems: [AgentConversationDisplayItem] {
                AgentConversationWorkUnitAdapter.displayItems(
                    conversation: session.conversation,
                    events: events
                )
            }

            private var workStatusCards: [AgentConversationWorkUnitCard] {
                AgentConversationWorkUnitAdapter.workStatusCards(
                    conversation: session.conversation,
                    events: events
                )
            }

            var body: some View {
                AgentConversationApprovalView(
                    approvals: approvals,
                    onApprove: onApprove,
                    onReject: { _ in }
                )
            }
        }
        """
        try source.write(
            to: sourcesDir.appendingPathComponent("AgentConversationView.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let input = "检查 AgentConversationView.swift，告诉我它负责什么，不要修改。"
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Project",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: root.path
        )
        var session = AgentSession(workspace: workspace, userGoal: input)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        let result = try await coordinator.startMission(
            input: input,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNotNil(result.task)
        XCTAssertEqual(session.interactionState, .running)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertEqual(submittedInputs, [input])
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.first?.payload["selected_route"], AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
        XCTAssertEqual(recordedEvents.first?.payload["chat_only"], "false")
    }

    func testPriorWorkQuestionWithNoPatchAnswersNoCodeWasModified() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        var session = AgentSession(workspace: workspace, userGoal: "检查项目")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .completed
        session.setInteractionState(.completed)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)
        let previousMessages = session.conversation.messages

        let result = try await coordinator.resumeMission(
            reply: "你刚才修改了哪些代码？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.prefix(previousMessages.count), previousMessages[...])
        XCTAssertTrue(session.conversation.messages.last?.content.contains("刚才没有修改代码") == true)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.first?.payload["selected_route"], AgentRequestRoute.conversationalChat.rawValue)
        XCTAssertTrue(recordedEvents.allSatisfy { $0.payload["chat_only"] == "true" })
    }

    func testPriorWorkQuestionAnswersFromSavedCodePatchArtifact() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "Change the title")
        session.workspaceContext.runtimeTaskID = UUID()
        session.currentState = .completed
        session.setInteractionState(.completed)
        session.addArtifact(
            AgentArtifact(
                id: "patch",
                type: .codePatch,
                title: "Code patch",
                detail: "Modified Sources/App/TitleView.swift: changed the navigation title to Dashboard."
            )
        )
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        let result = try await coordinator.resumeMission(
            reply: "How did you modify the code?",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNil(result.task)
        let answer = try XCTUnwrap(session.conversation.messages.last?.content)
        XCTAssertTrue(answer.contains("Sources/App/TitleView.swift"))
        XCTAssertTrue(answer.contains("navigation title"))
        XCTAssertFalse(answer.contains("no code was modified"))
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
    }

    func testConversationalQuestionDuringActiveMissionDoesNotControlOrCloseMission() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        var session = AgentSession(workspace: workspace, userGoal: "Inspect the project")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .executing
        session.setInteractionState(.working)
        session.appendInteractionMessage(
            AgentMessage(sender: .agent, type: .progressUpdate, content: "Inspection is still running.")
        )
        let previousMessages = session.conversation.messages
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        let result = try await coordinator.resumeMission(
            reply: "你能做什么？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNil(result.task)
        XCTAssertFalse(result.waitingForUser)
        XCTAssertEqual(session.currentState, .executing)
        XCTAssertEqual(session.interactionState, .blockedProvider)
        XCTAssertEqual(session.conversation.messages.prefix(previousMessages.count), previousMessages[...])
        XCTAssertEqual(result.normalChatLifecycle, .failed)
        XCTAssertEqual(session.conversation.messages.suffix(2).first?.sender, .user)
        XCTAssertEqual(session.conversation.messages.suffix(2).first?.content, "你能做什么？")
        XCTAssertEqual(session.conversation.messages.last?.sender, .agent)
        XCTAssertEqual(session.conversation.messages.last?.content, "Unable to reach the configured AI provider.")
        let submittedInputs = await runtime.submittedInputs()
        let controlActions = await runtime.recordedControlActions()
        XCTAssertTrue(submittedInputs.isEmpty)
        XCTAssertTrue(controlActions.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertTrue(recordedEvents.allSatisfy { $0.taskID == nil })
        XCTAssertTrue(recordedEvents.allSatisfy { $0.payload["chat_only"] == "true" })
        XCTAssertTrue(recordedEvents.allSatisfy { $0.payload["active_task_context_included"] == "false" })
    }

    func testExplicitReadOnlyWorkspaceRequestDuringActiveMissionStartsNewTask() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEActiveReadOnly-\(UUID().uuidString)", isDirectory: true)
        let sourcesDir = root.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try """
        import SwiftUI
        struct ActiveMissionView: View {
            var body: some View { Text("Active") }
        }
        """.write(
            to: sourcesDir.appendingPathComponent("ActiveMissionView.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = Workspace(
            id: UUID(),
            name: "Active Workspace",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: root.path
        )
        let taskID = UUID()
        var session = AgentSession(workspace: workspace, userGoal: "Run the active mission")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .executing
        session.setInteractionState(.working)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        let input = "检查 ActiveMissionView.swift，告诉我它负责什么，不要修改。"
        let result = try await coordinator.resumeMission(
            reply: input,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNotNil(result.task)
        XCTAssertNotEqual(result.task?.id, taskID)
        XCTAssertFalse(result.waitingForUser)
        XCTAssertEqual(session.currentState, .executing)
        XCTAssertEqual(session.interactionState, .running)
        let submittedInputs = await runtime.submittedInputs()
        let controlActions = await runtime.recordedControlActions()
        XCTAssertEqual(submittedInputs, [input])
        XCTAssertTrue(controlActions.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertTrue(recordedEvents.allSatisfy { $0.taskID == nil })
        XCTAssertTrue(recordedEvents.allSatisfy { $0.payload["chat_only"] == "false" })
        XCTAssertTrue(recordedEvents.allSatisfy { $0.payload["active_task_context_included"] == "false" })
        XCTAssertEqual(recordedEvents.first?.payload["selected_route"], AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
    }

    func testUnrelatedUIQuestionDoesNotInheritBlockedTaskContextOrEvidence() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        let oldToolCallID = "inspect-old-project"
        let oldCalledEvent = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspace.id,
            taskID: taskID,
            type: .toolCalled,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            summary: "Old project inspection started",
            payload: [
                "tool_call_id": oldToolCallID,
                "command": "engineering.inspect_project",
                "workspace_identity": "legacy",
                "target_path": "."
            ]
        )
        let oldResultEvent = ExecutionEvent(
            id: UUID(),
            parentEventID: oldCalledEvent.id,
            workspaceID: workspace.id,
            taskID: taskID,
            type: .stepExecuted,
            sequence: 2,
            timestamp: Date(timeIntervalSince1970: 2),
            summary: "Old project inspection completed",
            payload: [
                "tool_call_id": oldToolCallID,
                "command": "engineering.inspect_project",
                "workspace_identity": "legacy",
                "target_path": ".",
                "success": "true",
                "exit_code": "0"
            ]
        )
        var session = AgentSession(workspace: workspace, userGoal: "Inspect the legacy project")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .failed
        session.setInteractionState(.failed)
        session.appendInteractionMessage(
            AgentMessage(
                sender: .agent,
                type: .warning,
                content: "The old project analysis is blocked by a provider failure."
            )
        )
        let runtime = FakeAgentRuntime(loadableEvents: [oldCalledEvent, oldResultEvent])
        let provider = SequencedRecordingChatProvider(responses: [
            AgentChatResponse(
                content: "A compact activity timeline should show progress, tool outcomes, and failures in chronological order.",
                confidence: 0.92
            )
        ])
        let coordinator = AgentRuntimeCoordinator(chatProvider: provider)

        let result = try await coordinator.resumeMission(
            reply: "How should a Thinking UI present progress and tool activity?",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNil(result.task)
        let requests = await provider.recordedRequests()
        let request = try XCTUnwrap(requests.last)
        XCTAssertFalse(request.activeTaskContextIncluded)
        XCTAssertFalse(request.hasRuntimeTask)
        XCTAssertEqual(request.interactionState, .idle)
        XCTAssertTrue(request.toolEvidence.isEmpty)
        XCTAssertTrue(request.recentMessages.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertTrue(recordedEvents.allSatisfy { $0.taskID == nil })
        XCTAssertTrue(recordedEvents.allSatisfy { $0.payload["active_task_context_included"] == "false" })
        XCTAssertFalse(session.conversation.messages.last?.content.contains("old project") ?? true)
    }

    func testUserClarificationResumesWaitingMissionAndStartsRuntime() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "帮我")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()

        _ = try await coordinator.startMission(
            input: "帮我",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let result = try await coordinator.resumeMission(
            reply: "检查 Salesforce integration",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNotNil(result.task)
        XCTAssertEqual(session.interactionState, .running)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertEqual(submittedInputs, ["检查 Salesforce integration"])
        XCTAssertFalse(session.conversation.messages.contains {
            $0.content.contains("I have your clarification")
        })
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.payload["selected_route"], AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
    }

    func testCapabilityQuestionWhileWaitingDoesNotStartRuntime() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "帮我")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "我能回答问题，也能在你明确要求时执行工作区任务。"))

        _ = try await coordinator.startMission(
            input: "帮我",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let result = try await coordinator.resumeMission(
            reply: "你能做什么",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
        XCTAssertEqual(session.conversation.messages.last?.content, "我能回答问题，也能在你明确要求时执行工作区任务。")
        XCTAssertFalse(session.conversation.messages.contains {
            $0.content.contains("I have your clarification")
        })
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
    }

    func testComplaintWhileWaitingStaysInChatAndDoesNotStartRuntime() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "修改代码")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "你说得对，我应该先按普通对话理解你的意思。"))

        _ = try await coordinator.startMission(
            input: "修改代码",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let result = try await coordinator.resumeMission(
            reply: "你像个机器人",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        XCTAssertEqual(session.conversation.messages.last?.type, .text)
        XCTAssertEqual(session.conversation.messages.last?.content, "你说得对，我应该先按普通对话理解你的意思。")
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
    }

    func testVagueReplyWhileWaitingStaysInChatInsteadOfStartingRuntime() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "帮我")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator(chatProvider: FakeAgentChatProvider(content: "这还不是一个可执行目标。"))

        _ = try await coordinator.startMission(
            input: "帮我",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let result = try await coordinator.resumeMission(
            reply: "随便看看",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .idle)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.summary, "Agent answered chat message")
    }

    func testSelectedInspectWorkspaceDecisionStartsRuntimeWithoutDuplicatingUserMessage() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "帮我")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()
        let interactionController = AgentInteractionController()

        let questionID = interactionController.askQuestion(
            "你想让我在这个工作区里做什么？",
            options: [
                AgentMessageOption(id: "inspect_workspace", title: "查看工作区"),
                AgentMessageOption(id: "debug_issue", title: "排查问题"),
                AgentMessageOption(id: "modify_code", title: "修改代码")
            ],
            session: &session
        )
        _ = interactionController.selectDecision(
            optionID: "inspect_workspace",
            messageID: questionID,
            session: &session
        )

        let result = try await coordinator.resumeMissionFromSelectedDecision(
            decision: "查看工作区",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNotNil(result.task)
        XCTAssertEqual(session.interactionState, .running)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertEqual(submittedInputs, ["查看工作区"])
        XCTAssertEqual(
            session.conversation.messages.filter { $0.sender == .user && $0.content == "查看工作区" }.count,
            1
        )
    }

    func testSelectedModifyCodeDecisionAsksForConcreteTaskBeforeRuntimeStarts() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "start")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()
        let interactionController = AgentInteractionController()

        let questionID = interactionController.askQuestion(
            "What would you like me to do in this workspace?",
            options: [
                AgentMessageOption(id: "inspect_workspace", title: "Inspect the workspace"),
                AgentMessageOption(id: "debug_issue", title: "Debug an issue"),
                AgentMessageOption(id: "modify_code", title: "Modify code")
            ],
            session: &session
        )
        _ = interactionController.selectDecision(
            optionID: "modify_code",
            messageID: questionID,
            session: &session
        )

        let result = try await coordinator.resumeMissionFromSelectedDecision(
            decision: "Modify code",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertTrue(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .waitingForUser)
        XCTAssertEqual(session.conversation.messages.last?.type, .question)
        XCTAssertTrue(session.conversation.messages.last?.content.contains("What specific code change should I make") ?? false)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
        let recordedEvents = await runtime.recordedEvents()
        XCTAssertEqual(recordedEvents.last?.summary, "Agent requested concrete task details")
    }

    func testSelectedDebugIssueDecisionAsksForConcreteFailureBeforeRuntimeStarts() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "帮我")
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()
        let interactionController = AgentInteractionController()

        let questionID = interactionController.askQuestion(
            "你想让我在这个工作区里做什么？",
            options: [
                AgentMessageOption(id: "inspect_workspace", title: "查看工作区"),
                AgentMessageOption(id: "debug_issue", title: "排查问题"),
                AgentMessageOption(id: "modify_code", title: "修改代码")
            ],
            session: &session
        )
        _ = interactionController.selectDecision(
            optionID: "debug_issue",
            messageID: questionID,
            session: &session
        )

        let result = try await coordinator.resumeMissionFromSelectedDecision(
            decision: "排查问题",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertTrue(result.waitingForUser)
        XCTAssertNil(result.task)
        XCTAssertEqual(session.interactionState, .waitingForUser)
        XCTAssertEqual(session.conversation.messages.last?.type, .question)
        XCTAssertTrue(session.conversation.messages.last?.content.contains("你要我排查哪个具体问题") ?? false)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertTrue(submittedInputs.isEmpty)
    }

    func testFollowUpOnLinkedRuntimeRecordsInstructionWithoutRestartingTask() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        var session = AgentSession(workspace: workspace, userGoal: "Investigate API")
        session.workspaceContext.runtimeTaskID = taskID
        session.setInteractionState(.working)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()

        let result = try await coordinator.resumeMission(
            reply: "Change approach",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNil(result.task)
        let submittedInputs = await runtime.submittedInputs()
        let recordedEvents = await runtime.recordedEvents()
        let controlActions = await runtime.recordedControlActions()
        XCTAssertTrue(submittedInputs.isEmpty)
        XCTAssertEqual(recordedEvents.last?.taskID, taskID)
        XCTAssertEqual(recordedEvents.last?.payload["mission_state"], MissionState.adapt.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["task_state"], TaskState.running.rawValue)
        XCTAssertEqual(recordedEvents.last?.payload["decision_next_action"], AgentRuntimeAction.changeApproach.rawValue)
        XCTAssertEqual(controlActions, ["change:\(taskID.uuidString):Change approach"])
        XCTAssertTrue(session.conversation.messages.contains {
            $0.content.contains("I will apply that change")
        })
    }

    func testPauseAndResumeLinkedRuntimeUseStepController() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        var session = AgentSession(workspace: workspace, userGoal: "Investigate API")
        session.workspaceContext.runtimeTaskID = taskID
        session.setInteractionState(.working)
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()

        let pauseResult = try await coordinator.resumeMission(
            reply: "pause",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertTrue(pauseResult.waitingForUser)
        XCTAssertEqual(session.interactionState, .waitingForUser)

        let resumeResult = try await coordinator.resumeMission(
            reply: "continue",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(resumeResult.waitingForUser)
        XCTAssertEqual(session.interactionState, .working)
        let controlActions = await runtime.recordedControlActions()
        XCTAssertEqual(controlActions, [
            "pause:\(taskID.uuidString):pause",
            "resume:\(taskID.uuidString):continue"
        ])
    }

    func testNormalReplyWhileWaitingForApprovalKeepsApprovalGateVisible() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        var session = AgentSession(workspace: workspace, userGoal: "Investigate API")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .waitingApproval
        session.pauseForApproval()
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()

        let result = try await coordinator.resumeMission(
            reply: "为什么不继续执行",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertTrue(result.waitingForUser)
        XCTAssertEqual(session.interactionState, .waitingForApproval)
        let controlActions = await runtime.recordedControlActions()
        XCTAssertTrue(controlActions.isEmpty)
        XCTAssertTrue(session.conversation.messages.contains {
            $0.sender == .agent
                && $0.type == .question
                && $0.content.contains("审批点")
        })
    }

    func testApprovedImplementationStartsPatchGenerationMission() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "看看这个项目可以接 AI agent 吗")
        session.currentState = .completed
        session.setInteractionState(.completed)
        session.addArtifact(
            AgentArtifact(
                id: "assessment",
                type: .apiMapping,
                title: "Integration assessment",
                detail: "Assessment complete"
            )
        )
        session.addArtifact(
            AgentArtifact(
                id: "implementation-plan",
                type: .customerSummary,
                title: "Implementation plan",
                detail: "Plan ready"
            )
        )
        session.addArtifact(
            AgentArtifact(
                id: "test-plan",
                type: .customerSummary,
                title: "Test plan",
                detail: "Tests ready"
            )
        )
        let runtime = FakeAgentRuntime()
        let coordinator = AgentRuntimeCoordinator()

        let result = try await coordinator.startApprovedImplementation(
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertFalse(result.waitingForUser)
        XCTAssertNotNil(result.task)
        XCTAssertEqual(session.interactionState, .running)
        let submittedInputs = await runtime.submittedInputs()
        XCTAssertEqual(submittedInputs.count, 1)
        XCTAssertTrue(submittedInputs[0].contains("Approved implementation for AI agent integration"))
        XCTAssertTrue(submittedInputs[0].contains("writing tests"))
        XCTAssertTrue(submittedInputs[0].contains("generating adapter/client/service patch"))
    }

    func testChatHistoryKeepsOnlyCanonicalTurnsAndExcludesCurrentDuplicate() async throws {
        let workspace = Workspace.default()
        var session = AgentSession(workspace: workspace, userGoal: "哈哈哈")
        let runtime = FakeAgentRuntime()
        let provider = SequencedRecordingChatProvider(responses: [
            AgentChatResponse(content: "哈哈，我在。", confidence: 0.9),
            AgentChatResponse(content: "我只能猜，可能刚才的内容戳中了你的笑点。", confidence: 0.9)
        ])
        let coordinator = AgentRuntimeCoordinator(chatProvider: provider)

        _ = try await coordinator.startMission(
            input: "哈哈哈",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )
        session.appendInteractionMessage(
            AgentMessage(sender: .agent, type: .progressUpdate, content: "Work Status: Planning")
        )
        session.appendInteractionMessage(
            AgentMessage(sender: .agent, type: .planUpdate, content: "Understanding → Planning")
        )

        _ = try await coordinator.resumeMission(
            reply: "你觉得我刚刚为什么笑？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let requests = await provider.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let history = requests[1].recentMessages
        XCTAssertEqual(history.map(\.sender), [.user, .agent])
        XCTAssertEqual(history.map(\.content), ["哈哈哈", "哈哈，我在。"])
        XCTAssertFalse(history.contains { $0.content.contains("Work Status") || $0.content.contains("Planning") })
        XCTAssertFalse(history.contains { $0.content == "你觉得我刚刚为什么笑？" })
        XCTAssertEqual(requests[1].selectedMode, .casualConversation)
    }

    func testQualityGuardRetriesOnceAndRecordsSafeMetadata() async throws {
        let workspace = Workspace.default()
        let repeated = "我可以检查项目、修改代码、运行测试、构建并部署。"
        var session = AgentSession(workspace: workspace, userGoal: "你能做什么？")
        let runtime = FakeAgentRuntime()
        let provider = SequencedRecordingChatProvider(responses: [
            AgentChatResponse(content: repeated, confidence: 0.9),
            AgentChatResponse(content: repeated, confidence: 0.9),
            AgentChatResponse(content: "状态机定义状态和允许的转换；路由根据当前输入选择合法的下一条路径。", confidence: 0.92)
        ])
        let coordinator = AgentRuntimeCoordinator(chatProvider: provider)

        _ = try await coordinator.startMission(
            input: "你能做什么？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )
        _ = try await coordinator.resumeMission(
            reply: "状态机路由是什么？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        let requests = await provider.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertNil(requests[1].repairInstruction)
        XCTAssertTrue(requests[2].repairInstruction?.contains("rejected") == true)
        XCTAssertEqual(session.conversation.messages.last?.content, "状态机定义状态和允许的转换；路由根据当前输入选择合法的下一条路径。")
        let events = await runtime.recordedEvents()
        XCTAssertEqual(events.last?.payload["selected_chat_mode"], FDEConversationMode.engineeringExplanation.rawValue)
        XCTAssertEqual(events.last?.payload["quality_retry_used"], "true")
        XCTAssertFalse(events.last?.payload["quality_rejection_reason"]?.isEmpty ?? true)
    }

    func testBlockedMissionStatusReportsActualBlockerWithoutStartingAnotherTask() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        let blockedEvent = blockedMissionEvent(
            workspaceID: workspace.id,
            taskID: taskID,
            blocker: PlanReadinessBlocker.workingDirectoryOutsideWorkspace.rawValue
        )
        var session = AgentSession(workspace: workspace, userGoal: "只检查当前 Legacy 项目")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .blocked
        session.setInteractionState(.blocked)
        let runtime = BlockedMissionRuntime(taskID: taskID, persistedEvents: [blockedEvent])
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        let result = try await coordinator.resumeMission(
            reply: "为什么阻塞？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNil(result.task)
        XCTAssertEqual(session.currentState, .blocked)
        XCTAssertEqual(session.interactionState, .blocked)
        let answer = try XCTUnwrap(session.conversation.messages.last?.content)
        XCTAssertTrue(answer.contains("任务已阻止"))
        XCTAssertTrue(answer.contains("工作目录不属于当前选择的 Legacy 项目"))
        XCTAssertTrue(answer.contains("没有读取任何文件"))
        XCTAssertFalse(answer.contains("Failed"))
        XCTAssertFalse(answer.contains("Executing"))
        let submitted = await runtime.submittedInputs()
        let recoveries = await runtime.recoveryInstructions()
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(recoveries.isEmpty)
        let audits = await runtime.recordedEvents()
        XCTAssertEqual(audits.last?.payload["selected_route"], AgentRequestRoute.activeMissionStatusQuery.rawValue)
        XCTAssertEqual(audits.last?.payload["state"], TaskState.blocked.rawValue)
        XCTAssertEqual(audits.last?.payload["successful_read_evidence"], "false")
    }

    func testBlockedMissionClarificationRecoversSameTaskAndCorrectsFalseReadPremise() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        let blockedEvent = blockedMissionEvent(
            workspaceID: workspace.id,
            taskID: taskID,
            blocker: PlanReadinessBlocker.workspaceScopeMismatch.rawValue
        )
        let successfulDirectoryInspection = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspace.id,
            taskID: taskID,
            type: .stepExecuted,
            sequence: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            summary: "Project inventory inspected",
            payload: [
                "command": "engineering.inspect_project",
                "success": "true",
                "exit_code": "0"
            ]
        )
        var session = AgentSession(workspace: workspace, userGoal: "只检查当前 Legacy 项目")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .blocked
        session.setInteractionState(.blocked)
        let runtime = BlockedMissionRuntime(
            taskID: taskID,
            persistedEvents: [successfulDirectoryInspection, blockedEvent]
        )
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)
        let clarification = "根据刚才真正读取到的文件继续检查，只检查 Legacy，不要检查 Agent"

        let result = try await coordinator.resumeMission(
            reply: clarification,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertEqual(result.task?.id, taskID)
        XCTAssertEqual(result.task?.state, .running)
        XCTAssertEqual(session.workspaceContext.runtimeTaskID, taskID)
        XCTAssertEqual(session.currentState, .executing)
        XCTAssertEqual(session.interactionState, .running)
        XCTAssertTrue(session.conversation.messages.contains {
            $0.type == .warning
                && $0.content.contains("刚才没有成功读取任何文件")
                && $0.content.contains("同一个任务")
        })
        let submitted = await runtime.submittedInputs()
        let recoveries = await runtime.recoveryInstructions()
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertEqual(recoveries, [clarification])
    }

    func testPartialDurationMissionReportsUsefulCopyAndCompleteRemainingResumesSameTask() async throws {
        let workspace = Workspace.default()
        let taskID = UUID()
        let partialMessage = "本轮只读调查已达到时间预算。已完成：Legacy workspace、package.json、server；尚未完成：backend manifest、database schema。以下是部分结果，可从当前任务继续。"
        let partialEvent = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspace.id,
            taskID: taskID,
            type: .stateUpdated,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            summary: "Read-only inspection partially finalized with grounded evidence",
            payload: [
                "state": TaskState.blocked.rawValue,
                "mission_state": MissionState.blocked.rawValue,
                "blocker_reason": PlanReadinessBlocker.softDeadlineReached.rawValue,
                "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                "partial_result": "true",
                "user_visible_message": partialMessage,
                "successful_read_evidence": "true",
                "success": "false"
            ]
        )
        var session = AgentSession(workspace: workspace, userGoal: "检查 Legacy 项目依赖和数据库")
        session.workspaceContext.runtimeTaskID = taskID
        session.currentState = .blocked
        session.setInteractionState(.blocked)
        let runtime = BlockedMissionRuntime(taskID: taskID, persistedEvents: [partialEvent])
        let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

        _ = try await coordinator.resumeMission(
            reply: "为什么停了？",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )
        XCTAssertEqual(session.conversation.messages.last?.content, partialMessage)

        let result = try await coordinator.resumeMission(
            reply: "完成剩余分析",
            workspace: workspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertEqual(result.task?.id, taskID)
        let recoveries = await runtime.recoveryInstructions()
        let submissions = await runtime.submittedInputs()
        XCTAssertEqual(recoveries, ["完成剩余分析"])
        XCTAssertTrue(submissions.isEmpty)
    }

    func testPartialMissionContinuationPhrasesRecoverTheSameTask() async throws {
        let phrases = [
            "继续完成剩余分析",
            "继续读取剩余文件",
            "读取 vite.config.ts 后完成报告",
            "完成前端入口和 API 地址检查"
        ]

        for phrase in phrases {
            let workspace = Workspace.default()
            let taskID = UUID()
            let partialEvent = ExecutionEvent(
                id: UUID(),
                parentEventID: nil,
                workspaceID: workspace.id,
                taskID: taskID,
                type: .stateUpdated,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 1),
                summary: "Read-only inspection partially finalized with grounded evidence",
                payload: [
                    "state": TaskState.blocked.rawValue,
                    "mission_state": MissionState.blocked.rawValue,
                    "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                    "same_task_resumable": "true",
                    "successful_read_evidence": "true",
                    "success": "false"
                ]
            )
            var session = AgentSession(workspace: workspace, userGoal: "检查 Legacy 项目")
            session.workspaceContext.runtimeTaskID = taskID
            session.currentState = .blocked
            session.setInteractionState(.blocked)
            let runtime = BlockedMissionRuntime(taskID: taskID, persistedEvents: [partialEvent])
            let coordinator = AgentRuntimeCoordinator(chatProvider: nil)

            let result = try await coordinator.resumeMission(
                reply: phrase,
                workspace: workspace,
                session: &session,
                runtime: runtime
            )

            let recoveries = await runtime.recoveryInstructions()
            let submissions = await runtime.submittedInputs()
            XCTAssertEqual(result.task?.id, taskID, phrase)
            XCTAssertEqual(recoveries, [phrase], phrase)
            XCTAssertTrue(submissions.isEmpty, phrase)
        }
    }

    func testCasualIdentityAndCapabilityQuestionsRemainSingleReplyChatOnly() async throws {
        let messages = [
            "Hello",
            "Who are you?",
            "What can you do?",
            "Hello, who are you? What can you do?",
            "你好",
            "你是谁？",
            "你可以做什么？"
        ]

        for message in messages {
            let workspace = Workspace.default()
            var session = AgentSession(workspace: workspace, userGoal: message)
            let runtime = FakeAgentRuntime()
            let response = message.unicodeScalars.contains(where: { $0.value > 127 })
                ? "我是 FDE。我可以回答问题，也可以在你明确要求时处理所选代码库中的工程任务。"
                : "I am FDE. I can answer questions and, when explicitly asked, work on the selected codebase."
            let coordinator = AgentRuntimeCoordinator(
                chatProvider: FakeAgentChatProvider(content: response)
            )

            let result = try await coordinator.startMission(
                input: message,
                workspace: workspace,
                session: &session,
                runtime: runtime
            )

            XCTAssertNil(result.task, message)
            XCTAssertFalse(result.waitingForUser, message)
            XCTAssertEqual(session.currentState, .idle, message)
            XCTAssertEqual(session.interactionState, .idle, message)
            XCTAssertTrue(session.artifacts.isEmpty, message)
            XCTAssertNil(session.runtimeTaskID, message)
            XCTAssertEqual(session.conversation.messages.filter { $0.sender == .user }.count, 1, message)
            XCTAssertEqual(session.conversation.messages.filter { $0.sender == .agent }.count, 1, message)
            let submittedInputs = await runtime.submittedInputs()
            XCTAssertTrue(submittedInputs.isEmpty, message)
            let events = await runtime.recordedEvents()
            XCTAssertEqual(
                events.first?.payload["selected_route"],
                AgentRequestRoute.conversationalChat.rawValue,
                message
            )
            XCTAssertTrue(events.allSatisfy { $0.taskID == nil }, message)
            XCTAssertTrue(events.allSatisfy { $0.payload["chat_only"] == "true" }, message)
        }
    }

    private func blockedMissionEvent(
        workspaceID: UUID,
        taskID: UUID,
        blocker: String
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: .stateUpdated,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            summary: "Read-only task blocked",
            payload: [
                "state": TaskState.blocked.rawValue,
                "task_state": TaskState.blocked.rawValue,
                "mission_state": MissionState.blocked.rawValue,
                "blocker_reason": blocker,
                "successful_read_evidence": "false",
                "success": "false"
            ]
        )
    }
}

private actor BlockedMissionRuntime: AgentRuntimeExecuting {
    private let taskID: UUID
    private let persistedEvents: [ExecutionEvent]
    private var audits: [ExecutionEvent] = []
    private var submissions: [String] = []
    private var recoveries: [String] = []

    init(taskID: UUID, persistedEvents: [ExecutionEvent]) {
        self.taskID = taskID
        self.persistedEvents = persistedEvents
    }

    func submitTask(input: String, workspace: Workspace) throws -> FDETask {
        submissions.append(input)
        return task(workspaceID: workspace.id, state: .running, input: input)
    }

    func recoverTask(taskID: UUID, instruction: String, workspace: Workspace) throws -> FDETask? {
        guard taskID == self.taskID else { return nil }
        recoveries.append(instruction)
        return task(workspaceID: workspace.id, state: .running, input: instruction)
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
    ) throws -> ExecutionEvent {
        let event = ExecutionEvent(
            id: UUID(),
            parentEventID: audits.last?.id,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: Int64(audits.count + 2),
            timestamp: Date(timeIntervalSince1970: TimeInterval(audits.count + 2)),
            summary: summary,
            payload: payload
        )
        audits.append(event)
        return event
    }

    func loadAuditEvents(workspaceID: UUID, taskID: UUID?) throws -> [ExecutionEvent] {
        persistedEvents.filter {
            $0.workspaceID == workspaceID && (taskID == nil || $0.taskID == taskID)
        }
    }

    func submittedInputs() -> [String] { submissions }
    func recoveryInstructions() -> [String] { recoveries }
    func recordedEvents() -> [ExecutionEvent] { audits }

    private func task(workspaceID: UUID, state: TaskState, input: String) -> FDETask {
        FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Recovered read-only mission",
            rawInput: input,
            state: state,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date()
        )
    }
}

private actor FakeAgentRuntime: AgentRuntimeExecuting {
    private var inputs: [String] = []
    private var events: [ExecutionEvent] = []
    private var controlActions: [String] = []
    private let loadableEvents: [ExecutionEvent]

    init(loadableEvents: [ExecutionEvent] = []) {
        self.loadableEvents = loadableEvents
    }

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

    func requestStepPause(taskID: UUID, reason: String) async {
        controlActions.append("pause:\(taskID.uuidString):\(reason)")
    }

    func resumeTask(taskID: UUID, instruction: String?) async {
        controlActions.append("resume:\(taskID.uuidString):\(instruction ?? "")")
    }

    func changeTaskApproach(taskID: UUID, instruction: String) async {
        controlActions.append("change:\(taskID.uuidString):\(instruction)")
    }

    func stopTask(taskID: UUID, reason: String) async {
        controlActions.append("stop:\(taskID.uuidString):\(reason)")
    }

    func submittedInputs() -> [String] {
        inputs
    }

    func recordedEvents() -> [ExecutionEvent] {
        events
    }

    func recordedControlActions() -> [String] {
        controlActions
    }

    func loadAuditEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent] {
        loadableEvents.filter { event in
            event.workspaceID == workspaceID && (taskID == nil || event.taskID == taskID)
        }
    }
}

private struct FakeAgentChatProvider: AgentChatProviding {
    let kind: ModelProviderKind = .openAI
    let isAvailable = true
    let disabledReason: String? = nil
    let content: String

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        AgentChatResponse(content: content, confidence: 0.9, provider: kind)
    }
}

private struct FailingAgentChatProvider: AgentChatProviding {
    let kind: ModelProviderKind = .openAI
    let isAvailable = true
    let disabledReason: String? = nil
    let errorMessage: String

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        throw ModelRoutingError.providerUnavailable(errorMessage)
    }
}

private actor SequencedRecordingChatProvider: AgentChatProviding {
    nonisolated let kind: ModelProviderKind = .openAI
    nonisolated let isAvailable = true
    nonisolated let disabledReason: String? = nil
    nonisolated let modelIdentifier: String? = "mock-chat-model"
    private let responses: [AgentChatResponse]
    private var requests: [AgentChatRequest] = []

    init(responses: [AgentChatResponse]) {
        self.responses = responses
    }

    func generateChatResponse(for request: AgentChatRequest) async throws -> AgentChatResponse {
        requests.append(request)
        let index = min(requests.count - 1, responses.count - 1)
        return responses[index]
    }

    func recordedRequests() -> [AgentChatRequest] {
        requests
    }
}
