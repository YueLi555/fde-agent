import XCTest
@testable import FDECloudOS

final class RealitySimulationTests: XCTestCase {
    func testScenarioEngineCreatesEnterpriseUncertaintyScenarios() {
        let scenarios = ScenarioEngine.defaultScenarios()
        let kinds = Set(scenarios.map(\.kind))

        XCTAssertEqual(scenarios.count, 5)
        XCTAssertEqual(
            kinds,
            [
                .brokenIntegration,
                .expiredCredentials,
                .missingAPIAccess,
                .conflictingCustomerRequirements,
                .deploymentFailure
            ]
        )
        XCTAssertTrue(scenarios.allSatisfy { $0.realityContext.hasUncertainty })
        XCTAssertTrue(
            scenarios
                .first { $0.kind == .conflictingCustomerRequirements }?
                .realityContext
                .requiresClarification == true
        )
        XCTAssertTrue(
            scenarios
                .first { $0.kind == .missingAPIAccess }?
                .realityContext
                .requiresHumanApproval == true
        )
    }

    func testBrokenIntegrationScenarioRecoversProducesOutcomeAndLearns() async throws {
        let scenario = try XCTUnwrap(ScenarioEngine().scenario(kind: .brokenIntegration))
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let memory = InMemoryAgentMemoryProvider()
        let failingTool = shellTool(
            id: "tool.salesforce.sync-check",
            command: "/bin/echo",
            arguments: ["sync-check"]
        )
        let recoveryTool = shellTool(
            id: "tool.integration.recovery-check",
            command: "/bin/echo",
            arguments: ["recovery-check"]
        )
        let router = RealitySequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(id: "plan-failure", tool: failingTool, agent: .planner),
            toolOutput(id: "ready-failure", tool: failingTool, agent: .executor),
            toolOutput(id: "execute-failure", tool: failingTool, agent: .executor),
            toolOutput(id: "observe-recovery", tool: recoveryTool, agent: .recovery),
            toolOutput(id: "adapt-recovery", tool: recoveryTool, agent: .recovery),
            toolOutput(id: "execute-recovery", tool: recoveryTool, agent: .executor),
            noToolOutput(id: "verify-recovery", agent: .policy),
            noToolOutput(id: "complete", agent: .policy)
        ])
        let executor = RealityScriptedToolExecutor(outcomes: [
            .failure("Salesforce connector returned HTTP 500."),
            .success("Recovery validation succeeded.")
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            memoryProvider: memory,
            configuration: AgentLoopConfiguration(maxLoopIterations: 10)
        )

        let result = try await controller.runMission(input: scenario.missionObjective, workspace: workspace)
        let storedOutcomes = await memory.storedOutcomes()
        let evaluation = AgentRealityEvaluator().evaluate(
            scenario: scenario,
            result: result,
            memoryOutcomes: storedOutcomes
        )

        XCTAssertEqual(result.stopReason, .complete)
        XCTAssertTrue(evaluation.completedMission)
        XCTAssertTrue(evaluation.recovered)
        XCTAssertTrue(evaluation.producedOutcome)
        XCTAssertTrue(evaluation.learned)
        XCTAssertTrue(evaluation.missionTransitionsValid)
        XCTAssertEqual(evaluation.unnecessaryActionCount, 0)
        XCTAssertTrue(evaluation.failures.isEmpty)
        XCTAssertTrue(result.events.contains { $0.type == .toolFailed })
        XCTAssertTrue(result.events.contains { $0.payload["mission_state"] == MissionState.adapt.rawValue })
    }

    func testMissingAPIAccessRequestsApprovalAndAvoidsUnsafeAction() async throws {
        let scenario = try XCTUnwrap(ScenarioEngine().scenario(kind: .missingAPIAccess))
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let unsafeTool = shellTool(
            id: "tool.api.write-production",
            command: "/bin/echo",
            arguments: ["write-production"],
            requiresApproval: true
        )
        let router = RealitySequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(
                id: "approval-required",
                tool: unsafeTool,
                agent: .planner,
                riskSeverity: .high
            )
        ])
        let executor = RealityScriptedToolExecutor(outcomes: [.success("should not run")])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            configuration: AgentLoopConfiguration(maxLoopIterations: 5)
        )

        let result = try await controller.runMission(input: scenario.missionObjective, workspace: workspace)
        let executedCommands = await executor.executedCommands()
        let pendingApprovals = try await persistence.loadApprovalRequests(workspaceID: workspace.id, state: .pending)
        let evaluation = AgentRealityEvaluator().evaluate(scenario: scenario, result: result)

        XCTAssertEqual(result.stopReason, .waitingHuman)
        XCTAssertTrue(executedCommands.isEmpty)
        XCTAssertEqual(pendingApprovals.count, 1)
        XCTAssertTrue(evaluation.avoidedUnsafeAction)
        XCTAssertEqual(evaluation.humanInterventionQuality, 1.0)
        XCTAssertTrue(evaluation.failures.isEmpty)
        XCTAssertFalse(evaluation.producedOutcome)
    }

    func testConflictingRequirementsAskCorrectQuestionBeforeExecution() async throws {
        let scenario = try XCTUnwrap(ScenarioEngine().scenario(kind: .conflictingCustomerRequirements))
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let router = RealitySequencedDecisionRouter(outputs: [
            noToolOutput(id: "uncertain", agent: .systemUnderstanding, confidence: 0.05)
        ])
        let executor = RealityScriptedToolExecutor(outcomes: [.success("should not run")])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            configuration: AgentLoopConfiguration(maxLoopIterations: 3)
        )

        let result = try await controller.runMission(input: scenario.missionObjective, workspace: workspace)
        let executedCommands = await executor.executedCommands()
        let evaluation = AgentRealityEvaluator().evaluate(scenario: scenario, result: result)

        XCTAssertEqual(result.stopReason, .missingCriticalInformation)
        XCTAssertTrue(executedCommands.isEmpty)
        XCTAssertTrue(evaluation.askedCorrectQuestions)
        XCTAssertTrue(evaluation.avoidedUnsafeAction)
        XCTAssertEqual(evaluation.humanInterventionQuality, 1.0)
        XCTAssertTrue(evaluation.failures.isEmpty)
        XCTAssertFalse(evaluation.producedOutcome)
    }

    func testBenchmarkReportComputesEnterpriseUncertaintyMetrics() async throws {
        let engine = ScenarioEngine()
        let broken = try XCTUnwrap(engine.scenario(kind: .brokenIntegration))
        let missingAccess = try XCTUnwrap(engine.scenario(kind: .missingAPIAccess))
        let conflicting = try XCTUnwrap(engine.scenario(kind: .conflictingCustomerRequirements))
        let brokenRun = try await runBrokenIntegrationScenario(broken)
        let missingAccessRun = try await runMissingAPIAccessScenario(missingAccess)
        let conflictingRun = try await runConflictingRequirementsScenario(conflicting)

        let report = RealityBenchmarkRunner().report(for: [
            brokenRun,
            missingAccessRun,
            conflictingRun
        ])

        XCTAssertEqual(report.scenarioCount, 3)
        XCTAssertEqual(report.completionRate, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.recoveryRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(report.unnecessaryActionRate, 0.0, accuracy: 0.0001)
        XCTAssertEqual(report.humanInterventionQuality, 1.0, accuracy: 0.0001)
        XCTAssertTrue(report.evaluations.allSatisfy(\.missionTransitionsValid))
    }

    private func runBrokenIntegrationScenario(_ scenario: FDEScenario) async throws -> RealityScenarioRun {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let memory = InMemoryAgentMemoryProvider()
        let failingTool = shellTool(
            id: "tool.salesforce.sync-check",
            command: "/bin/echo",
            arguments: ["sync-check"]
        )
        let recoveryTool = shellTool(
            id: "tool.integration.recovery-check",
            command: "/bin/echo",
            arguments: ["recovery-check"]
        )
        let router = RealitySequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(id: "plan-failure", tool: failingTool, agent: .planner),
            toolOutput(id: "ready-failure", tool: failingTool, agent: .executor),
            toolOutput(id: "execute-failure", tool: failingTool, agent: .executor),
            toolOutput(id: "observe-recovery", tool: recoveryTool, agent: .recovery),
            toolOutput(id: "adapt-recovery", tool: recoveryTool, agent: .recovery),
            toolOutput(id: "execute-recovery", tool: recoveryTool, agent: .executor),
            noToolOutput(id: "verify-recovery", agent: .policy),
            noToolOutput(id: "complete", agent: .policy)
        ])
        let executor = RealityScriptedToolExecutor(outcomes: [
            .failure("Salesforce connector returned HTTP 500."),
            .success("Recovery validation succeeded.")
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            memoryProvider: memory,
            configuration: AgentLoopConfiguration(maxLoopIterations: 10)
        )
        let result = try await controller.runMission(input: scenario.missionObjective, workspace: workspace)
        return RealityScenarioRun(
            scenario: scenario,
            result: result,
            memoryOutcomes: await memory.storedOutcomes()
        )
    }

    private func runMissingAPIAccessScenario(_ scenario: FDEScenario) async throws -> RealityScenarioRun {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let unsafeTool = shellTool(
            id: "tool.api.write-production",
            command: "/bin/echo",
            arguments: ["write-production"],
            requiresApproval: true
        )
        let router = RealitySequencedDecisionRouter(outputs: [
            noToolOutput(id: "understand", agent: .systemUnderstanding),
            toolOutput(id: "approval-required", tool: unsafeTool, agent: .planner, riskSeverity: .high)
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            configuration: AgentLoopConfiguration(maxLoopIterations: 5)
        )
        let result = try await controller.runMission(input: scenario.missionObjective, workspace: workspace)
        return RealityScenarioRun(scenario: scenario, result: result)
    }

    private func runConflictingRequirementsScenario(_ scenario: FDEScenario) async throws -> RealityScenarioRun {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let router = RealitySequencedDecisionRouter(outputs: [
            noToolOutput(id: "uncertain", agent: .systemUnderstanding, confidence: 0.05)
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            configuration: AgentLoopConfiguration(maxLoopIterations: 3)
        )
        let result = try await controller.runMission(input: scenario.missionObjective, workspace: workspace)
        return RealityScenarioRun(scenario: scenario, result: result)
    }

    private func makeController(
        persistence: any PersistenceStore,
        router: any ModelRouting,
        toolExecutor: any ToolExecuting = RealityScriptedToolExecutor(outcomes: []),
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
                    title: "Evaluate \(id)",
                    intent: "Advance the mission only with available runtime evidence.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(
                    id: "action.\(id)",
                    title: "Validate the next mission state",
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
                    title: "Validate \(tool.id) before continuing",
                    agent: agent,
                    stepID: "step.\(id)"
                )
            ],
            toolCalls: [tool],
            risks: [
                RiskSignal(
                    id: "risk.\(id)",
                    title: "Scenario runtime risk",
                    severity: riskSeverity,
                    mitigation: "Use existing controller safety gates before execution."
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

private actor RealitySequencedDecisionRouter: ModelRouting {
    private var outputs: [StructuredAgentOutput]
    private var index = 0

    init(outputs: [StructuredAgentOutput]) {
        self.outputs = outputs
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try nextOutput()
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try nextOutput()
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

private enum RealityScriptedToolOutcome: Sendable {
    case success(String)
    case failure(String)
}

private actor RealityScriptedToolExecutor: ToolExecuting {
    private var outcomes: [RealityScriptedToolOutcome]
    private var index = 0
    private var commands: [String] = []

    init(outcomes: [RealityScriptedToolOutcome]) {
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
