import XCTest
@testable import FDECloudOS

final class SameTaskRecoveryReliabilityTests: XCTestCase {
    func testRecoveryIsDeltaOnlyPreservesSignaturesAndEnforcesNoReread() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let taskID = UUID()
        let request = "只读取当前 Legacy 项目，检查项目结构、主要语言、前端框架、后端框架、数据库和重要依赖。回答必须列出实际读取的 manifest 和关键文件。"
        try await persistence.saveTask(
            FDETask(
                id: taskID,
                workspaceID: fixture.workspace.id,
                title: "Inspect Legacy",
                rawInput: request,
                state: .blocked,
                plan: [],
                riskScore: 0,
                failureProbability: 0,
                performanceScore: 0,
                createdAt: Date(),
                updatedAt: Date()
            )
        )
        try await seedPriorEvidence(taskID: taskID, fixture: fixture, persistence: persistence)

        let forbidden = planOutput([
            toolStep("forbidden", "engineering.read_file", ["path=server/package.json"])
        ])
        let repaired = planOutput([
            toolStep("entry", "engineering.read_file", ["path=server/src/index.ts"])
        ])
        let router = StructuredRecoveryRouter(
            outputs: [forbidden, repaired],
            actions: [
                ReadOnlyNextAction(decision: .finalize, finalAnswer: completeChineseReport)
            ]
        )
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired
        )
        let instruction = "继续完成剩余分析。只补充后端入口的直接证据，不要重复读取 package.json、server/package.json 或 server/prisma/schema.prisma。完成后生成简洁的完整中文报告。"

        let recoveredValue = try await kernel.recoverTask(
            taskID: taskID,
            instruction: instruction,
            workspace: fixture.workspace
        )
        let recovered = try XCTUnwrap(recoveredValue)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: taskID)
        let calls = events.filter { $0.type == .toolCalled }

        XCTAssertEqual(recovered.id, taskID)
        XCTAssertEqual(recovered.state, .completed, eventDiagnostic(events))
        XCTAssertEqual(calls.compactMap { $0.payload["target_path"] }, ["server/src/index.ts"])
        XCTAssertFalse(calls.contains {
            [".", "package.json", "server/package.json", "server/prisma/schema.prisma"]
                .contains($0.payload["target_path"] ?? "")
        })
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "PLAN_REPAIR_REQUESTED"
                && $0.payload["blocker_reason"] == PlanReadinessBlocker.explicitNoRereadConstraint.rawValue
        })
        let recovery = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "TASK_RECOVERY_REQUESTED" })
        XCTAssertEqual(recovery.payload["original_task_id"], taskID.uuidString)
        XCTAssertEqual(recovery.payload["recovered_task_id"], taskID.uuidString)
        XCTAssertEqual(recovery.payload["same_task_id_preserved"], "true")
        XCTAssertEqual(recovery.payload["unsatisfied_evidence_requirements"], "backend_startup_entry")
        XCTAssertTrue(recovery.payload["restored_completed_command_signatures"]?.contains("server/package.json") == true)
        XCTAssertEqual(recovery.payload["exact_continuation_instruction"], instruction)
    }

    func testSearchToReadUsesExactCanonicalRelativePath() async throws {
        let fixture = try makeNodeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let initial = planOutput([toolStep("inspect", "engineering.inspect_project")])
        let router = NativeRecoveryRouter(
            initial: initial,
            actions: [
                nextTool("search", "engineering.search_files", ["query=index.ts", "path=server/src"]),
                nextTool("short", "engineering.read_file", ["path=index.ts"]),
                nextTool("canonical", "engineering.read_file", ["path=server/src/index.ts"]),
                ReadOnlyNextAction(
                    decision: .finalize,
                    finalAnswer: "结论：已直接读取后端入口 `server/src/index.ts`，其中导入 Express 并创建应用。限制：仅做只读静态检查，未执行构建或测试。"
                )
            ]
        )
        let (task, events) = try await runTask(
            input: "只读检查 Legacy 项目的后端入口并提供直接证据",
            fixture: fixture,
            router: router
        )

        XCTAssertEqual(task.state, .completed, eventDiagnostic(events))
        let search = try XCTUnwrap(events.first {
            $0.type == .stepExecuted && $0.payload["command"] == "engineering.search_files"
        })
        XCTAssertTrue(search.payload["stdout"]?.contains("server/src/index.ts:0: file path match") == true)
        XCTAssertTrue(search.payload["discovered_paths"]?.contains("server/src/index.ts") == true)
        XCTAssertFalse(events.contains { $0.type == .toolCalled && $0.payload["target_path"] == "index.ts" })
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "NEXT_ACTION_REPAIR_REQUESTED"
                && $0.payload["rejection_reason"] == PlanReadinessBlocker.canonicalSearchPathRequired.rawValue
        })
        XCTAssertTrue(events.contains {
            $0.type == .toolCalled && $0.payload["target_path"] == "server/src/index.ts"
        })
        XCTAssertFalse(events.contains {
            $0.type == .toolCalled && $0.payload["target_path"] == "server/package.json"
        })
    }

    func testMissingStartupCandidateDoesNotSubstituteApplicationAssembly() async throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(fixture.legacy.appendingPathComponent("package.json"), #"{"dependencies":{"react":"19"}}"#)
        try write(fixture.legacy.appendingPathComponent("server/package.json"), #"{"scripts":{"dev":"tsx watch src/missing.ts"},"dependencies":{"express":"5"}}"#)
        try write(fixture.legacy.appendingPathComponent("server/src/app.ts"), "import express from 'express';\nexport const app = express();\n")
        let router = NativeRecoveryRouter(
            initial: planOutput([toolStep("inspect", "engineering.inspect_project")]),
            actions: [
                nextTool("manifest", "engineering.read_file", ["path=server/package.json"]),
                nextTool("missing", "engineering.read_file", ["path=server/src/missing.ts"]),
                ReadOnlyNextAction(
                    decision: .finalize,
                    finalAnswer: "结论：通过 `server/package.json` 确认 Express 后端，并读取 `server/src/app.ts`，确认它导入 Express 并创建后端应用。限制：仅做只读静态检查，未执行构建或测试。"
                )
            ]
        )
        let (task, events) = try await runTask(
            input: "只读检查 Legacy 项目的后端入口",
            fixture: fixture,
            router: router
        )

        XCTAssertEqual(task.state, .waiting, eventDiagnostic(events))
        XCTAssertEqual(events.filter { $0.type == .toolCalled }.compactMap { $0.payload["target_path"] }, [
            ".", "server/package.json", "server/src/missing.ts", "package.json"
        ])
        let recovery = try XCTUnwrap(events.first { $0.payload["lifecycle_event"] == "RECOVERABLE_CANDIDATE_FAILURE" })
        XCTAssertEqual(recovery.payload["failed_relative_path"], "server/src/missing.ts")
        XCTAssertEqual(recovery.payload["alternative_relative_path"], "package.json")
        XCTAssertEqual(events.filter {
            $0.type == .toolCalled && $0.payload["target_path"] == "server/src/app.ts"
        }.count, 0)
        XCTAssertTrue(events.contains {
            $0.payload["unsatisfied_evidence_requirements"]?.contains("backend_startup_entry") == true
        })
    }

    func testReadFailureWithPriorEvidenceProducesCanonicalChinesePartialAndNoActiveCards() async throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        try write(
            fixture.legacy.appendingPathComponent("package.json"),
            #"{"main":"server/src/Missing.ts","dependencies":{"react":"19"}}"#
        )
        try write(
            fixture.legacy.appendingPathComponent("src/App.tsx"),
            "import React from 'react';\nexport const App = () => <main />;\n"
        )
        let router = NativeRecoveryRouter(
            initial: planOutput([toolStep("inspect", "engineering.inspect_project")]),
            actions: [
                nextTool("feature", "engineering.read_file", ["path=src/App.tsx"]),
                nextTool("manifest", "engineering.read_file", ["path=package.json"]),
                nextTool("missing", "engineering.read_file", ["path=server/src/Missing.ts"])
            ]
        )
        let (task, events) = try await runTask(
            input: "只读检查 Legacy 项目的后端入口 Missing.ts",
            fixture: fixture,
            router: router
        )

        XCTAssertEqual(task.state, .waiting)
        let fallback = try XCTUnwrap(events.first {
            $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_FALLBACK"
                && $0.payload["provider_stage"] == "recoverable_tool_failure"
        }, eventDiagnostic(events))
        XCTAssertEqual(fallback.payload["grounded_answer"], "true")
        XCTAssertEqual(fallback.payload["user_visible_message"], fallback.payload["final_answer"])
        XCTAssertTrue(fallback.payload["user_visible_message"]?.contains("已保留之前确认") == true)
        let partial = try XCTUnwrap(events.last {
            $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
        })
        XCTAssertTrue(partial.payload["user_visible_message"]?.contains("server/src/Missing.ts") == true)
        XCTAssertEqual(partial.payload["response_language"], "zh")
        assertNoActiveWorkCards(events: events, fixture: fixture, expectedTerminal: .partial)
    }

    func testNoEvidenceReadFailureProducesStableFailedAndNoActiveCards() async throws {
        let fixture = try makeEmptyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let router = StructuredRecoveryRouter(outputs: [
            planOutput([toolStep("missing", "engineering.read_file", ["path=Missing.swift"])])
        ])
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired
        )

        let task = try await kernel.submitTask(
            input: "只读读取 Legacy 项目的 Missing.swift",
            workspace: fixture.workspace
        )
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .blocked)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains {
            $0.payload["lifecycle_event"] == "PLAN_REPAIR_REQUESTED"
                && $0.payload["blocker_reason"] == PlanReadinessBlocker.canonicalSearchPathRequired.rawValue
        })
        XCTAssertFalse(events.contains { $0.payload["lifecycle_event"] == "INSPECTION_FAILED" })
        assertNoActiveWorkCards(events: events, fixture: fixture, expectedTerminal: .blocked)
    }

    private func runTask(
        input: String,
        fixture: Fixture,
        router: NativeRecoveryRouter
    ) async throws -> (FDETask, [ExecutionEvent]) {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: router,
            toolExecutor: WorkspaceEngineeringToolExecutor(),
            completionPolicy: .evidenceRequired
        )
        let task = try await kernel.submitTask(input: input, workspace: fixture.workspace)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        return (task, events)
    }

    private func seedPriorEvidence(
        taskID: UUID,
        fixture: Fixture,
        persistence: InMemoryPersistenceStore
    ) async throws {
        let seeded: [(String, String, String)] = [
            ("engineering.inspect_project", ".", "Top files:\npackage.json\nserver/package.json\nserver/prisma/schema.prisma\nserver/src/app.ts\n\nTop directories:\nserver/src\n\nSymbols:\n"),
            ("engineering.read_file", "package.json", #"{"dependencies":{"react":"19","vite":"7"}}"#),
            ("engineering.read_file", "server/package.json", #"{"scripts":{"dev":"tsx watch src/index.ts"},"dependencies":{"express":"5","@prisma/client":"6"}}"#),
            ("engineering.read_file", "server/prisma/schema.prisma", "datasource db {\n provider = \"postgresql\"\n}\ngenerator client {\n provider = \"prisma-client-js\"\n}")
        ]
        for (index, item) in seeded.enumerated() {
            let arguments = item.0 == "engineering.inspect_project"
                ? "workspace=legacy path=."
                : "workspace=legacy path=\(item.1)"
            let argumentSignature = arguments.split(separator: " ").map(String.init).sorted().joined(separator: ",")
            let signature = "\(item.0)|legacy|\(item.1)|\(argumentSignature)"
            let event = ExecutionEvent(
                id: UUID(),
                parentEventID: nil,
                workspaceID: fixture.workspace.id,
                taskID: taskID,
                type: .stepExecuted,
                sequence: Int64(index + 1),
                timestamp: Date().addingTimeInterval(Double(index)),
                summary: "Seeded successful evidence",
                payload: [
                    "command": item.0,
                    "tool_call_id": "seed.\(index)",
                    "workspace_identity": "legacy",
                    "target_path": item.1,
                    "arguments": arguments,
                    "stdout": item.2,
                    "completed_command_signature": signature,
                    "success": "true",
                    "exit_code": "0"
                ]
            )
            try await persistence.appendEvent(event)
        }
    }

    private func assertNoActiveWorkCards(
        events: [ExecutionEvent],
        fixture: Fixture,
        expectedTerminal: AgentWorkUnitStatus
    ) {
        let conversation = AgentConversation.started(
            sessionID: UUID(),
            workspaceID: fixture.workspace.id,
            userRequest: "只读检查",
            createdAt: Date()
        )
        let cards = AgentConversationWorkUnitAdapter.workStatusCards(conversation: conversation, events: events)
        XCTAssertTrue(cards.contains { $0.status == expectedTerminal })
        XCTAssertFalse(cards.contains {
            $0.status == .active || $0.status == .planned || $0.status == .waitingApproval
        })
    }

    private func eventDiagnostic(_ events: [ExecutionEvent]) -> String {
        events.suffix(20).map { event in
            [
                event.payload["lifecycle_event"] ?? event.type.rawValue,
                event.payload["state"] ?? "",
                event.payload["rejection_reason"] ?? event.payload["blocker_reason"] ?? "",
                event.payload["unsatisfied_evidence_requirements"] ?? "",
                event.payload["exact_rejection"] ?? event.payload["detail"] ?? ""
            ].filter { !$0.isEmpty }.joined(separator: " :: ")
        }.joined(separator: "\n")
    }

    private func toolStep(
        _ id: String,
        _ command: String,
        _ arguments: [String] = []
    ) -> (PlanStep, ToolCall) {
        let callID = "tool.\(id)"
        return (
            PlanStep(
                id: "step.\(id)",
                title: id,
                intent: "Execute \(command).",
                kind: .tool,
                toolCallID: callID,
                requiresApproval: false
            ),
            ToolCall(
                id: callID,
                type: .api,
                command: command,
                arguments: arguments,
                workingDirectory: nil,
                requiresApproval: false
            )
        )
    }

    private func planOutput(_ values: [(PlanStep, ToolCall)]) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: values.map(\.0),
            actions: [],
            toolCalls: values.map(\.1),
            risks: [],
            confidence: 0.9
        )
    }

    private func finalOutput(_ answer: String) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "final",
                    title: "Grounded report",
                    intent: answer,
                    kind: .finalization,
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [],
            risks: [],
            confidence: 0.9
        )
    }

    private func nextTool(_ id: String, _ command: String, _ arguments: [String]) -> ReadOnlyNextAction {
        ReadOnlyNextAction(
            decision: .tool,
            toolCalls: [
                ToolCall(
                    id: id,
                    type: .api,
                    command: command,
                    arguments: arguments,
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            reasoningSummary: "Gather one remaining direct evidence item."
        )
    }

    private func makeNodeFixture() throws -> Fixture {
        let fixture = try makeEmptyFixture()
        try write(fixture.legacy.appendingPathComponent("package.json"), #"{"dependencies":{"react":"19","vite":"7"}}"#)
        try write(fixture.legacy.appendingPathComponent("server/package.json"), #"{"scripts":{"dev":"tsx watch src/index.ts"},"dependencies":{"express":"5","@prisma/client":"6"}}"#)
        try write(fixture.legacy.appendingPathComponent("server/src/index.ts"), "import express from 'express';\nconst app = express();\napp.listen(3000);\n")
        try write(fixture.legacy.appendingPathComponent("server/src/app.ts"), "import express from 'express';\nexport const app = express();\n")
        try write(fixture.legacy.appendingPathComponent("server/prisma/schema.prisma"), "datasource db {\n provider = \"postgresql\"\n}\n")
        return fixture
    }

    private func makeEmptyFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDESameTaskRecovery-\(UUID().uuidString)", isDirectory: true)
        let legacy = container.appendingPathComponent("Legacy", isDirectory: true)
        let agent = container.appendingPathComponent("Agent", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let workspace = Workspace(
            id: UUID(),
            name: "Recovery fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacy.path,
            localAgentProjectRoot: agent.path
        )
        return Fixture(container: container, legacy: legacy, agent: agent, workspace: workspace)
    }

    private func write(_ url: URL, _ value: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private struct Fixture {
        var container: URL
        var legacy: URL
        var agent: URL
        var workspace: Workspace
    }

    private var completeChineseReport: String {
        """
        ## 结论
        已确认该 Legacy 项目前端使用 React + Vite，后端使用 Express，ORM 为 Prisma，数据库为 PostgreSQL；后端入口为 `server/src/index.ts`。
        ## 已确认的技术栈
        React、Vite、Express、Prisma、PostgreSQL 均来自已保存的直接证据。
        ## 项目结构
        根目录包含前端、`server` 后端和 Prisma schema。
        ## 数据库
        Prisma 连接 PostgreSQL。
        ## 重要依赖
        react、vite、express、@prisma/client。
        ## 实际读取的文件
        `package.json`、`server/package.json`、`server/prisma/schema.prisma`、`server/src/index.ts`。
        ## 推断与限制
        仅进行了只读静态检查，未执行构建或测试。
        ## 下一步
        当前请求已经完成，无需重复读取上述文件。
        """
    }
}

private actor StructuredRecoveryRouter: ModelRouting {
    private var outputs: [StructuredAgentOutput]
    private var actions: [ReadOnlyNextAction]

    init(outputs: [StructuredAgentOutput], actions: [ReadOnlyNextAction] = []) {
        self.outputs = outputs
        self.actions = actions
    }

    func generatePlan(for input: String, context: ExecutionContext) throws -> StructuredAgentOutput {
        try next()
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) throws -> StructuredAgentOutput {
        try next()
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) throws -> ReadOnlyNextAction {
        guard !actions.isEmpty else {
            throw ModelRoutingError.providerOutputInvalid("Native recovery action exhausted.")
        }
        return actions.removeFirst()
    }

    private func next() throws -> StructuredAgentOutput {
        guard !outputs.isEmpty else {
            throw ModelRoutingError.providerUnavailable("Structured recovery output exhausted.")
        }
        return outputs.removeFirst()
    }
}

private actor NativeRecoveryRouter: ModelRouting {
    private let initial: StructuredAgentOutput
    private var actions: [ReadOnlyNextAction]
    private var returnedPlan = false

    init(initial: StructuredAgentOutput, actions: [ReadOnlyNextAction]) {
        self.initial = initial
        self.actions = actions
    }

    func generatePlan(for input: String, context: ExecutionContext) throws -> StructuredAgentOutput {
        guard !returnedPlan else {
            throw ModelRoutingError.providerOutputInvalid("Initial plan requested more than once.")
        }
        returnedPlan = true
        return initial
    }

    func generateReadOnlyNextAction(prompt: CompiledPrompt, context: ExecutionContext) throws -> ReadOnlyNextAction {
        guard !actions.isEmpty else {
            throw ModelRoutingError.providerOutputInvalid("Native recovery action exhausted.")
        }
        return actions.removeFirst()
    }
}
