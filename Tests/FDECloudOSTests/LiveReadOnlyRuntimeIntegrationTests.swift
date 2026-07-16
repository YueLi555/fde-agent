import XCTest
@testable import FDECloudOS

final class LiveReadOnlyRuntimeIntegrationTests: XCTestCase {
    func testShortChineseLegacyRootListingBootstrapsTaskAndUsesRealLegacyOnlyTools() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let input = "只读取当前 Legacy 项目的根目录并列出主要文件，不要修改任何文件。"
        let finalAnswer = """
        工作区根目录的实际条目包括 package.json、src 和 server。
        工程推断：这是一个包含前端与服务端目录的项目。
        限制：本次仅进行了 Legacy 工作区根目录的只读检查，没有修改任何文件。
        """
        let provider = MockOpenAICompatibleInspectionProvider(outputs: [
            inspectionOutput(id: "inspect-root", command: "engineering.inspect_project"),
            inspectionOutput(id: "list-root", command: "engineering.list_directory", arguments: ["path=."]),
            finalizationOutput(finalAnswer)
        ])
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let eventBus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: InMemoryEventStream(eventBus: eventBus),
            modelRouter: ModelRouter(providers: [provider]),
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true
        )
        var session = AgentSession(workspace: fixture.workspace, userGoal: input)

        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: fixture.workspace,
            session: &session,
            runtime: kernel
        )

        let task = try XCTUnwrap(result.task)
        let allEvents = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: nil)
        let routeEvent = try XCTUnwrap(allEvents.first { $0.type == .userMessageReceived })
        XCTAssertEqual(routeEvent.payload["selected_route"], AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
        let taskEvents = allEvents.filter { $0.taskID == task.id }.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(
            task.state,
            .completed,
            taskEvents.map { "\($0.type.rawValue):\($0.payload["blocker_reason"] ?? $0.summary)" }.joined(separator: " | ")
        )
        let taskCreated = try XCTUnwrap(taskEvents.first { $0.type == .taskCreated })
        let firstPlannerOrToolEvent = try XCTUnwrap(taskEvents.first {
            $0.type == .planGenerated || $0.type == .toolCalled
        })
        XCTAssertLessThan(taskCreated.sequence, firstPlannerOrToolEvent.sequence)
        XCTAssertEqual(taskCreated.payload["mission_workspace_scope"], MissionWorkspaceScope.legacyOnly.rawValue)

        let toolCalls = taskEvents.filter { $0.type == .toolCalled }
        XCTAssertEqual(toolCalls.map { $0.payload["command"] ?? "" }, [
            "engineering.inspect_project",
            "engineering.list_directory"
        ])
        XCTAssertEqual(toolCalls.last?.payload["normalized_relative_path"], ".")
        XCTAssertTrue(toolCalls.allSatisfy { $0.payload["workspace_identity"] == "legacy" })
        XCTAssertFalse(toolCalls.contains { $0.payload["working_directory"] == fixture.agent.path })
        let listResult = try XCTUnwrap(taskEvents.last {
            $0.type == .stepExecuted && $0.payload["command"] == "engineering.list_directory"
        })
        XCTAssertTrue(listResult.payload["stdout"]?.contains("vite.config.ts") == true)

        let plannerContexts = await provider.recordedContexts()
        XCTAssertFalse(plannerContexts.isEmpty)
        XCTAssertTrue(plannerContexts.allSatisfy { context in
            guard let bundle = context.contextBundle else { return false }
            return context.missionWorkspaceScope == .legacyOnly
                && bundle.codebases.map(\.role) == ["legacy_software"]
                && bundle.workspace.agentRootPath == nil
                && !bundle.workspace.fileTreeSummary.contains("AgentOnly.swift")
        })
        let completed = try XCTUnwrap(taskEvents.last { $0.type == .taskCompleted })
        let groundedAnswer = try XCTUnwrap(completed.payload["detail"])
        XCTAssertTrue(groundedAnswer.contains("package.json"))
        XCTAssertTrue(groundedAnswer.contains("src"))
        XCTAssertTrue(groundedAnswer.contains("server"))
        XCTAssertFalse(groundedAnswer.contains("AgentOnly.swift"))
    }

    func testCoordinatorRoutesExplicitLegacyOnlyInspectionThroughProductionRuntimeAndConversation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let requestedPaths = [
            "package.json",
            "server/package.json",
            "server/prisma/schema.prisma",
            "server/src/index.ts"
        ]
        let finalAnswer = """
        Inspected workspace: Legacy only.
        Files/manifests read: package.json, server/package.json, server/prisma/schema.prisma, server/src/index.ts.
        Project structure: a Vite/React frontend and an Express backend with Prisma database access.
        Programming languages: TypeScript and TSX. Configuration formats: JSON. Schema languages: Prisma Schema Language.
        Frameworks and important dependencies: React, Vite, Express, Prisma, and PostgreSQL configuration.
        Confirmed facts: these names come from the files listed above.
        Inferences: the frontend and backend are separate application layers in one repository.
        Limitations: read-only static inspection only; no files were changed and no build, test, or profiling command ran.
        """
        var outputs = [inspectionOutput(id: "inspect", command: "engineering.inspect_project")]
        outputs += requestedPaths.enumerated().map { index, path in
            inspectionOutput(id: "read-\(index)", command: "engineering.read_file", arguments: ["path=\(path)"])
        }
        outputs.append(finalizationOutput(finalAnswer))

        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let provider = MockOpenAICompatibleInspectionProvider(outputs: outputs)
        let router = ModelRouter(providers: [provider])
        let eventBus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: InMemoryEventStream(eventBus: eventBus),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true
        )
        let input = "只读取当前 Legacy 项目。请实际检查项目结构、主要语言、前端框架、后端框架、数据库和重要依赖，不要修改任何文件。回答必须列出实际读取过的 manifest 和关键文件；不要分析 Agent 项目。"
        var session = AgentSession(workspace: fixture.workspace, userGoal: input)

        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: fixture.workspace,
            session: &session,
            runtime: kernel
        )

        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.state, .completed)
        XCTAssertFalse(result.waitingForUser)
        let allEvents = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: nil)
        let routeEvent = try XCTUnwrap(allEvents.first { $0.type == .userMessageReceived })
        XCTAssertEqual(routeEvent.payload["selected_route"], AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
        XCTAssertEqual(routeEvent.payload["selected_chat_mode"], FDEConversationMode.workspaceReadOnlyInvestigation.rawValue)
        XCTAssertEqual(routeEvent.payload["mission_semantic"], MissionExecutionSemantic.readOnlyWorkspaceInspection.rawValue)
        XCTAssertEqual(routeEvent.payload["chat_only"], "false")

        let taskEvents = allEvents.filter { $0.taskID == task.id }
        XCTAssertTrue(taskEvents.contains { $0.type == .planGenerated })
        XCTAssertTrue(taskEvents.contains { $0.type == .toolCalled && $0.payload["lifecycle_event"] == "TOOL_CALLED" })
        XCTAssertTrue(taskEvents.contains { $0.type == .stepExecuted && $0.payload["lifecycle_event"] == "TOOL_RESULT" })
        XCTAssertTrue(taskEvents.contains { $0.type == .stateUpdated && $0.payload["lifecycle_event"] == "OBSERVATION_RECORDED" })
        let toolCalls = taskEvents.filter { $0.type == .toolCalled }
        XCTAssertEqual(
            toolCalls.compactMap { $0.payload["target_path"] },
            [".", "package.json", "server/package.json", "server/prisma/schema.prisma"]
        )
        XCTAssertTrue(toolCalls.allSatisfy { $0.payload["workspace_identity"] == "legacy" })
        XCTAssertFalse(toolCalls.contains { $0.payload["working_directory"] == fixture.agent.path })

        session.linkRuntimeTask(task)
        for event in allEvents.sorted(by: { $0.sequence < $1.sequence }) {
            session.apply(event: event)
        }
        let visibleFinal = try XCTUnwrap(session.conversation.messages.last { $0.type == .result })
        for path in requestedPaths {
            XCTAssertTrue(visibleFinal.content.contains(path), "Expected visible final answer to cite \(path)")
        }
        XCTAssertFalse(visibleFinal.content.contains("AgentOnly.swift"))
        XCTAssertFalse(visibleFinal.content.contains("files..."))
        XCTAssertFalse(visibleFinal.content.contains("diff"))
        XCTAssertEqual(try String(contentsOf: fixture.legacy.appendingPathComponent("src/App.tsx"), encoding: .utf8), fixture.appSource)
    }

    func testNegativeAgentScopeIsLegacyOnlyAndComparisonRequiresExplicitLanguage() {
        XCTAssertEqual(
            ReadOnlyMissionTarget(request: "只读取当前 Legacy 项目；不要分析 Agent 项目。"),
            .legacy
        )
        XCTAssertEqual(
            ReadOnlyMissionTarget(request: "Compare both Legacy and Agent projects."),
            .comparison
        )
    }

    func testExactFollowUpAndPerformanceRequestsSelectReadOnlyRuntimeRoute() async throws {
        let workspace = Workspace.default()
        let inputs = [
            "根据刚才读取到的文件，继续检查前端和后端是如何连接的。找出 API 基础地址、主要接口入口、数据库访问层和任务 Worker。仍然不要修改文件。",
            "对当前 Legacy 项目做一次只读的静态性能风险分析。检查前端渲染、网络请求、后端任务、数据库访问和文件处理。不要修改代码，也不要声称已经测量 CPU、内存、延迟或 profiler 数据。"
        ]

        for input in inputs {
            let runtime = RouteRecordingRuntime()
            var session = AgentSession(workspace: workspace, userGoal: input)
            let result = try await AgentRuntimeCoordinator().startMission(
                input: input,
                workspace: workspace,
                session: &session,
                runtime: runtime
            )
            XCTAssertNotNil(result.task)
            let recordedEvents = await runtime.events()
            let userEvent = try XCTUnwrap(recordedEvents.first)
            XCTAssertEqual(userEvent.payload["selected_route"], AgentRequestRoute.workspaceReadOnlyInvestigation.rawValue)
            XCTAssertEqual(userEvent.payload["chat_only"], "false")
            XCTAssertEqual(userEvent.payload["mission_semantic"], MissionExecutionSemantic.readOnlyWorkspaceInspection.rawValue)
        }
    }

    func testGroundedCompletionCannotBeRewrittenByNarrationProvider() async throws {
        let answer = "Files/manifests read: package.json and server/package.json."
        let event = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: UUID(),
            taskID: UUID(),
            type: .taskCompleted,
            sequence: 1,
            timestamp: Date(),
            summary: "Read-only inspection completed with grounded evidence",
            payload: [
                "grounded_answer": "true",
                "completion_contract": RuntimeCompletionContractKind.readOnlyInspection.rawValue,
                "detail": answer
            ]
        )
        let provider = RewritingNarrationProvider()

        let message = await AgentResponseComposer(narrationProvider: provider).liveMessage(for: event)
        let providerCallCount = await provider.callCount()

        XCTAssertEqual(message.content, answer)
        XCTAssertEqual(providerCallCount, 0)
    }

    private struct Fixture {
        var container: URL
        var legacy: URL
        var agent: URL
        var workspace: Workspace
        var appSource: String
    }

    private func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("FDELiveReadOnly-\(UUID().uuidString)", isDirectory: true)
        let legacy = container.appendingPathComponent("Legacy", isDirectory: true)
        let agent = container.appendingPathComponent("Agent", isDirectory: true)
        let appSource = "import React from 'react';\nexport function App() { return <main>Fixture</main>; }\n"
        try write(legacy.appendingPathComponent("package.json"), #"{"dependencies":{"react":"19.0.0"},"devDependencies":{"vite":"7.0.0"}}"#)
        try write(legacy.appendingPathComponent("vite.config.ts"), "import { defineConfig } from 'vite';\nexport default defineConfig({});\n")
        try write(legacy.appendingPathComponent("src/App.tsx"), appSource)
        try write(legacy.appendingPathComponent("server/package.json"), #"{"dependencies":{"express":"5.0.0","@prisma/client":"6.0.0"}}"#)
        try write(legacy.appendingPathComponent("server/src/index.ts"), "import express from 'express';\nconst app = express();\n")
        try write(legacy.appendingPathComponent("server/prisma/schema.prisma"), "datasource db {\n  provider = \"postgresql\"\n  url = env(\"DATABASE_URL\")\n}\n")
        try write(agent.appendingPathComponent("AgentOnly.swift"), "struct AgentOnly {}\n")
        let workspace = Workspace(
            id: UUID(),
            name: "Live path fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacy.path,
            localAgentProjectRoot: agent.path
        )
        return Fixture(container: container, legacy: legacy, agent: agent, workspace: workspace, appSource: appSource)
    }

    private func write(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func inspectionOutput(id: String, command: String, arguments: [String] = []) -> StructuredAgentOutput {
        let callID = "tool.\(id)"
        return StructuredAgentOutput(
            plan: [PlanStep(id: "step.\(id)", title: id, intent: "Read workspace evidence.", kind: .tool, toolCallID: callID, requiresApproval: false)],
            actions: [],
            toolCalls: [ToolCall(id: callID, type: .api, command: command, arguments: arguments, workingDirectory: nil, requiresApproval: false)],
            risks: [],
            confidence: 0.95
        )
    }

    private func finalizationOutput(_ answer: String) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [PlanStep(id: "final", title: "Grounded answer", intent: answer, kind: .finalization, toolCallID: nil, requiresApproval: false)],
            actions: [],
            toolCalls: [],
            risks: [],
            confidence: 0.95
        )
    }
}

private actor MockOpenAICompatibleInspectionProvider: ModelProvider {
    nonisolated let kind: ModelProviderKind = .openAI
    nonisolated let isAvailable = true
    private var outputs: [StructuredAgentOutput]
    private var contexts: [ExecutionContext] = []

    init(outputs: [StructuredAgentOutput]) {
        self.outputs = outputs
    }

    func generatePlan(for input: String, context: ExecutionContext) throws -> StructuredAgentOutput {
        contexts.append(context)
        guard !outputs.isEmpty else {
            throw ModelRoutingError.providerOutputInvalid("Mock OpenAI-compatible output exhausted.")
        }
        return outputs.removeFirst()
    }

    func recordedContexts() -> [ExecutionContext] { contexts }
}

private actor RewritingNarrationProvider: AgentNarrationProviding {
    nonisolated let kind: ModelProviderKind = .openAI
    nonisolated let isAvailable = true
    nonisolated let disabledReason: String? = nil
    private var calls = 0

    func generateNarration(for request: AgentNarrationRequest) -> AgentNarration {
        calls += 1
        return AgentNarration(content: "Rewritten metadata summary", messageType: .result, confidence: 1, provider: .openAI, usedFallback: false)
    }

    func callCount() -> Int { calls }
}

private actor RouteRecordingRuntime: AgentRuntimeExecuting {
    private var recordedEvents: [ExecutionEvent] = []

    func submitTask(input: String, workspace: Workspace) -> FDETask {
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

    func requestStepPause(taskID: UUID, reason: String) {}
    func resumeTask(taskID: UUID, instruction: String?) {}
    func changeTaskApproach(taskID: UUID, instruction: String) {}
    func stopTask(taskID: UUID, reason: String) {}

    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) -> ExecutionEvent {
        let event = ExecutionEvent(
            id: UUID(),
            parentEventID: recordedEvents.last?.id,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: Int64(recordedEvents.count + 1),
            timestamp: Date(),
            summary: summary,
            payload: payload
        )
        recordedEvents.append(event)
        return event
    }

    func events() -> [ExecutionEvent] { recordedEvents }
}
