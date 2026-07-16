import XCTest
@testable import FDECloudOS

final class AgentLoopControllerTests: XCTestCase {
    func testMissionStartsAgentLoopDecisionGeneratedAndStateChanges() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let router = SequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding)
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            configuration: AgentLoopConfiguration(maxLoopIterations: 1)
        )

        let result = try await controller.runMission(input: "Audit autonomous runtime", workspace: workspace)
        let promptStates = await router.promptStates()

        XCTAssertEqual(result.stopReason, .maxIterationsReached)
        XCTAssertEqual(result.finalSnapshot.missionState, .plan)
        XCTAssertEqual(result.decisions.first?.actionType, .submitTask)
        XCTAssertEqual(promptStates, [.understand])
        XCTAssertTrue(result.events.contains { $0.payload["agent_loop_stage"] == AgentLoopTraceStage.decision.rawValue })
        XCTAssertTrue(result.events.contains { $0.payload["mission_state"] == MissionState.plan.rawValue })
    }

    func testExecutionFailureObservesReplansAndContinues() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let failingTool = shellTool(id: "tool.fail", command: "/bin/echo", arguments: ["fail"])
        let recoveryTool = shellTool(id: "tool.recover", command: "/bin/echo", arguments: ["recover"])
        let router = SequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(id: "plan-fail", tool: failingTool, agent: .planner),
            toolOutput(id: "ready-fail", tool: failingTool, agent: .planner),
            toolOutput(id: "execute-fail", tool: failingTool, agent: .executor),
            toolOutput(id: "observe-replan", tool: recoveryTool, agent: .recovery),
            toolOutput(id: "adapt-recovery", tool: recoveryTool, agent: .recovery),
            toolOutput(id: "execute-recovery", tool: recoveryTool, agent: .executor),
            noToolOutput(id: "observe-verify", agent: .policy),
            noToolOutput(id: "verify-complete", agent: .policy)
        ])
        let executor = ScriptedToolExecutor(outcomes: [
            .failure("Injected execution failure"),
            .success("recovered")
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            configuration: AgentLoopConfiguration(maxLoopIterations: 10)
        )

        let result = try await controller.runMission(input: "Run autonomous recovery", workspace: workspace)
        let commands = await executor.executedCommands()
        let promptStates = await router.promptStates()

        XCTAssertEqual(result.stopReason, .complete)
        XCTAssertEqual(result.finalSnapshot.missionState, .complete)
        XCTAssertEqual(commands, ["/bin/echo", "/bin/echo"])
        XCTAssertTrue(promptStates.contains(.observe))
        XCTAssertTrue(promptStates.contains(.adapt))
        XCTAssertTrue(promptStates.contains(.verifying))
        XCTAssertTrue(result.events.contains { $0.type == .toolFailed })
        XCTAssertTrue(result.events.contains { $0.payload["agent_loop_stage"] == AgentLoopTraceStage.adaptation.rawValue })
        XCTAssertTrue(result.events.contains { $0.type == .stepExecuted && $0.payload["observation_outcome"] == ToolObservationOutcome.succeeded.rawValue })
    }

    func testUnrecoveredToolFailureEndsFailedWithoutCompletion() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let failingTool = shellTool(id: "tool.fail", command: "/bin/echo", arguments: ["fail"])
        let router = SequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(id: "plan", tool: failingTool, agent: .planner),
            toolOutput(id: "ready", tool: failingTool, agent: .planner),
            toolOutput(id: "execute", tool: failingTool, agent: .executor),
            noToolOutput(id: "observe", agent: .recovery),
            noToolOutput(id: "adapt", agent: .recovery)
        ])
        let executor = ScriptedToolExecutor(outcomes: [.failure("Injected execution failure")])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            configuration: AgentLoopConfiguration(maxLoopIterations: 8)
        )

        let result = try await controller.runMission(input: "Run failing command", workspace: workspace)

        XCTAssertEqual(result.stopReason, .failed)
        XCTAssertEqual(result.finalSnapshot.missionState, .failed)
        XCTAssertEqual(result.task.state, .failed)
        XCTAssertTrue(result.events.contains { $0.type == .toolFailed })
        XCTAssertFalse(result.events.contains { $0.type == .taskCompleted })
        XCTAssertFalse(result.decisions.contains(where: \.completionSignal))
    }

    func testHumanApprovalRequiredPausesLoop() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let approvalTool = shellTool(
            id: "tool.approval",
            command: "/bin/echo",
            arguments: ["approval"],
            requiresApproval: true
        )
        let router = SequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(
                id: "plan-approval",
                tool: approvalTool,
                agent: .planner,
                riskSeverity: .high
            )
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            configuration: AgentLoopConfiguration(maxLoopIterations: 5)
        )

        let result = try await controller.runMission(input: "Run approved autonomous action", workspace: workspace)
        let pendingApprovals = try await persistence.loadApprovalRequests(workspaceID: workspace.id, state: .pending)

        XCTAssertEqual(result.stopReason, .waitingHuman)
        XCTAssertEqual(result.finalSnapshot.missionState, .waitingHuman)
        XCTAssertEqual(result.task.state, .pendingApproval)
        XCTAssertEqual(pendingApprovals.count, 1)
        XCTAssertEqual(pendingApprovals.first?.toolCallID, approvalTool.id)
        XCTAssertTrue(result.events.contains { $0.type == .humanApprovalRequested })
    }

    func testMissionCompletionStopsLoopAndStoresOutcome() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let memory = InMemoryAgentMemoryProvider()
        let tool = shellTool(id: "tool.complete", command: "/bin/echo", arguments: ["complete"])
        let router = SequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(id: "plan", tool: tool, agent: .planner),
            toolOutput(id: "ready", tool: tool, agent: .planner),
            toolOutput(id: "execute", tool: tool, agent: .executor),
            noToolOutput(id: "observe", agent: .policy),
            noToolOutput(id: "verify", agent: .policy)
        ])
        let executor = ScriptedToolExecutor(outcomes: [.success("completed")])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            memoryProvider: memory,
            configuration: AgentLoopConfiguration(maxLoopIterations: 8)
        )

        let result = try await controller.runMission(input: "Complete autonomous mission", workspace: workspace)
        let outcomes = await memory.storedOutcomes()

        XCTAssertEqual(result.stopReason, .complete)
        XCTAssertEqual(result.finalSnapshot.missionState, .complete)
        XCTAssertEqual(result.task.state, .completed)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.finalState, .complete)
        XCTAssertEqual(result.outcomeRecord?.finalState, .complete)
        XCTAssertEqual(outcomes.first?.outcomeRecord.missionID, result.task.id)
        XCTAssertFalse(outcomes.first?.successfulActions.isEmpty ?? true)
        XCTAssertFalse(outcomes.first?.customerEnvironmentKnowledge.isEmpty ?? true)
        XCTAssertTrue(result.events.contains { $0.payload["agent_loop_stage"] == AgentLoopTraceStage.completion.rawValue })
        XCTAssertTrue(result.events.contains {
            $0.type == .taskCompleted
                && $0.payload["completion_gate_passed"] == "true"
                && $0.payload["completion_evidence_successful_tool_results"] == "1"
        })
    }

    func testPlanningOnlyOutputRemainsReadyAndNeverCompletes() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let memory = InMemoryAgentMemoryProvider()
        let router = SequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            noToolOutput(id: "plan-only", agent: .planner)
        ])
        let executor = ScriptedToolExecutor(outcomes: [])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            memoryProvider: memory,
            configuration: AgentLoopConfiguration(maxLoopIterations: 5)
        )

        let result = try await controller.runMission(input: "Create a plan only", workspace: workspace)
        let commands = await executor.executedCommands()
        let outcomes = await memory.storedOutcomes()

        XCTAssertEqual(result.stopReason, .maxIterationsReached)
        XCTAssertEqual(result.finalSnapshot.missionState, .ready)
        XCTAssertEqual(result.task.state, .planned)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(result.decisions.contains(where: \.completionSignal))
        XCTAssertFalse(result.events.contains { $0.type == .taskCompleted })
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertFalse(outcomes[0].completionSignal)
    }

    func testMissionStateMachineAllowsCompletionOnlyFromVerifying() throws {
        let stateMachine = MissionStateMachine()

        XCTAssertThrowsError(try stateMachine.transition(from: .understand, to: .complete))
        XCTAssertThrowsError(try stateMachine.transition(from: .execute, to: .complete))
        XCTAssertThrowsError(try stateMachine.transition(from: .observe, to: .complete))
        XCTAssertThrowsError(try stateMachine.transition(from: .adapt, to: .complete))
        XCTAssertThrowsError(try stateMachine.transition(from: .waitingHuman, to: .complete))
        XCTAssertEqual(try stateMachine.transition(from: .verifying, to: .complete), .complete)
    }

    func testMaxLoopIterationsProtectsAgainstInfiniteProgression() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let tool = shellTool(id: "tool.loop", command: "/bin/echo", arguments: ["loop"])
        let router = SequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(id: "plan-loop", tool: tool, agent: .planner),
            toolOutput(id: "execute-loop", tool: tool, agent: .executor)
        ])
        let executor = ScriptedToolExecutor(outcomes: [.success("should not execute before max stop")])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            configuration: AgentLoopConfiguration(maxLoopIterations: 2)
        )

        let result = try await controller.runMission(input: "Loop until protected", workspace: workspace)
        let commands = await executor.executedCommands()

        XCTAssertEqual(result.stopReason, .maxIterationsReached)
        XCTAssertEqual(result.iterations, 2)
        XCTAssertEqual(result.finalSnapshot.missionState, .ready)
        XCTAssertEqual(result.task.state, .planned)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(result.events.contains {
            $0.payload["agent_loop_stop_reason"] == AgentLoopStopReason.maxIterationsReached.rawValue
        })
    }

    private func makeController(
        persistence: any PersistenceStore,
        router: any ModelRouting,
        toolExecutor: any ToolExecuting = ScriptedToolExecutor(outcomes: []),
        memoryProvider: any AgentMemoryProvider = NoOpAgentMemoryProvider(),
        configuration: AgentLoopConfiguration
    ) -> AgentLoopController {
        AgentLoopController(
            persistence: persistence,
            contextCompiler: InstructionContextCompiler(
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                workspaceScanner: LocalWorkspaceScanner(maxEntries: 20, maxSummaryEntries: 10)
            ),
            modelRouter: router,
            toolExecutor: toolExecutor,
            memoryProvider: memoryProvider,
            configuration: configuration
        )
    }

    private func noToolOutput(
        id: String,
        agent: AgentKind,
        confidence: Double = 0.9
    ) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.\(id)",
                    title: "Decide \(id)",
                    intent: "Advance autonomous mission state.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(
                    id: "action.\(id)",
                    title: "Validate autonomous next step",
                    agent: agent,
                    stepID: "step.\(id)"
                )
            ],
            toolCalls: [],
            risks: [],
            confidence: confidence
        )
    }

    private func toolOutput(
        id: String,
        tool: ToolCall,
        agent: AgentKind,
        riskSeverity: RiskSeverity = .low
    ) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.\(id)",
                    title: "Run \(id)",
                    intent: "Use the validated tool request for this mission state.",
                    toolCallID: tool.id,
                    requiresApproval: tool.requiresApproval
                )
            ],
            actions: [
                AgentAction(
                    id: "action.\(id)",
                    title: "Validate \(tool.command) before next transition",
                    agent: agent,
                    stepID: "step.\(id)"
                )
            ],
            toolCalls: [tool],
            risks: [
                RiskSignal(
                    id: "risk.\(id)",
                    title: "Runtime risk",
                    severity: riskSeverity,
                    mitigation: "Use controller safety gates before execution."
                )
            ],
            confidence: 0.88
        )
    }

    private func shellTool(
        id: String,
        command: String,
        arguments: [String],
        requiresApproval: Bool = false
    ) -> ToolCall {
        ToolCall(
            id: id,
            type: .shell,
            command: command,
            arguments: arguments,
            workingDirectory: nil,
            requiresApproval: requiresApproval
        )
    }
}

private actor SequencedDecisionRouter: ModelRouting {
    private var outputs: [StructuredAgentOutput]
    private var index = 0
    private var states: [MissionState] = []

    init(outputs: [StructuredAgentOutput]) {
        self.outputs = outputs
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try nextOutput()
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        states.append(prompt.missionState)
        return try nextOutput()
    }

    func promptStates() -> [MissionState] {
        states
    }

    private func nextOutput() throws -> StructuredAgentOutput {
        guard !outputs.isEmpty else {
            throw ModelRoutingError.providerUnavailable("No scripted output available.")
        }
        let output = outputs[min(index, outputs.count - 1)]
        index += 1
        return output
    }
}

private enum ScriptedToolOutcome: Sendable {
    case success(String)
    case failure(String)
}

private actor ScriptedToolExecutor: ToolExecuting {
    private var outcomes: [ScriptedToolOutcome]
    private var index = 0
    private var commands: [String] = []

    init(outcomes: [ScriptedToolOutcome]) {
        self.outcomes = outcomes
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        commands.append(call.command)
        guard !outcomes.isEmpty else {
            return ToolExecutionResult(
                callID: call.id,
                exitCode: 0,
                standardOutput: "ok",
                standardError: "",
                duration: 0.001
            )
        }
        let outcome = outcomes[min(index, outcomes.count - 1)]
        index += 1
        switch outcome {
        case .success(let output):
            return ToolExecutionResult(
                callID: call.id,
                exitCode: 0,
                standardOutput: output,
                standardError: "",
                duration: 0.001
            )
        case .failure(let message):
            throw ToolExecutionError.processFailed(message)
        }
    }

    func executedCommands() -> [String] {
        commands
    }
}
