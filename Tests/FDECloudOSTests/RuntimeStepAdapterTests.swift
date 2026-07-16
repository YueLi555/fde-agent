import XCTest
@testable import FDECloudOS

final class RuntimeStepAdapterTests: XCTestCase {
    func testRuntimeKernelWaitsAndResumesAtStepCheckpoint() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let stepAdapter = RuntimeStepAdapter()
        await stepAdapter.requestPauseAtNextCheckpoint(reason: "Need user input")
        let executor = StepRecordingToolExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [TwoStepPlanner()]),
            toolExecutor: executor,
            stepAdapter: stepAdapter
        )

        let runningTask = Task {
            try await kernel.submitTask(input: "Run two controlled steps", workspace: workspace)
        }

        let waitingTask = try await waitForTaskState(.waiting, workspaceID: workspace.id, persistence: persistence)
        await kernel.resumeTask(taskID: waitingTask.id, instruction: "continue")

        let completedTask = try await runningTask.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: completedTask.id)
        let commands = await executor.executedCommands()

        XCTAssertEqual(completedTask.state, .completed)
        XCTAssertEqual(commands, ["/bin/pwd", "/bin/echo"])
        XCTAssertTrue(events.contains { $0.type == .stateUpdated && $0.payload["agent_loop_phase"] == "wait" })
        XCTAssertTrue(events.contains { $0.type == .stateUpdated && $0.payload["agent_loop_phase"] == "resume" })
        let waitingEvent = try XCTUnwrap(events.first { $0.type == .stateUpdated && $0.payload["agent_loop_phase"] == "wait" })
        XCTAssertEqual(waitingEvent.payload["mission_state"], MissionState.waitingHuman.rawValue)
        XCTAssertEqual(waitingEvent.payload["task_state"], TaskState.waiting.rawValue)
        XCTAssertEqual(waitingEvent.payload["tool_state"], ToolExecutionState.idle.rawValue)
        let toolEvent = try XCTUnwrap(events.first { $0.type == .toolCalled })
        XCTAssertEqual(toolEvent.payload["mission_state"], MissionState.execute.rawValue)
        XCTAssertEqual(toolEvent.payload["task_state"], TaskState.running.rawValue)
        XCTAssertEqual(toolEvent.payload["tool_state"], ToolExecutionState.running.rawValue)
        let observedEvent = try XCTUnwrap(events.first { $0.type == .stepExecuted })
        XCTAssertEqual(observedEvent.payload["mission_state"], MissionState.observe.rawValue)
        XCTAssertEqual(observedEvent.payload["task_state"], TaskState.running.rawValue)
        XCTAssertEqual(observedEvent.payload["tool_state"], ToolExecutionState.succeeded.rawValue)
        let completionEvent = try XCTUnwrap(events.first { $0.type == .taskCompleted })
        XCTAssertEqual(completionEvent.payload["mission_state"], MissionState.complete.rawValue)
        XCTAssertEqual(completionEvent.payload["task_state"], TaskState.completed.rawValue)
        XCTAssertEqual(completionEvent.payload["tool_state"], ToolExecutionState.idle.rawValue)
        let workTraceStages = Set(events.compactMap { $0.payload["agent_work_trace_stage"] })
        XCTAssertTrue(workTraceStages.contains(AgentWorkTraceStage.understanding.rawValue))
        XCTAssertTrue(workTraceStages.contains(AgentWorkTraceStage.planning.rawValue))
        XCTAssertTrue(workTraceStages.contains(AgentWorkTraceStage.execution.rawValue))
        XCTAssertTrue(workTraceStages.contains(AgentWorkTraceStage.observation.rawValue))
        XCTAssertTrue(workTraceStages.contains(AgentWorkTraceStage.completion.rawValue))
    }

    func testRuntimeKernelCanChangeApproachAndSkipCurrentStep() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let stepAdapter = RuntimeStepAdapter()
        await stepAdapter.requestPauseAtNextCheckpoint(reason: "Need user input")
        let executor = StepRecordingToolExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [TwoStepPlanner()]),
            toolExecutor: executor,
            stepAdapter: stepAdapter
        )

        let runningTask = Task {
            try await kernel.submitTask(input: "Run two controlled steps", workspace: workspace)
        }

        let waitingTask = try await waitForTaskState(.waiting, workspaceID: workspace.id, persistence: persistence)
        await kernel.changeTaskApproach(taskID: waitingTask.id, instruction: "skip this step")

        let completedTask = try await runningTask.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: completedTask.id)
        let commands = await executor.executedCommands()

        XCTAssertEqual(completedTask.state, .completed)
        XCTAssertEqual(commands, ["/bin/echo"])
        XCTAssertTrue(events.contains { $0.type == .userDecisionSelected && $0.payload["decision"] == "change_approach" })
        XCTAssertTrue(events.contains { $0.type == .stateUpdated && $0.payload["skip_reason"] == "skip this step" })
    }

    private func waitForTaskState(
        _ state: TaskState,
        workspaceID: UUID,
        persistence: InMemoryPersistenceStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> FDETask {
        for _ in 0..<100 {
            if let task = try await persistence.loadTasks(workspaceID: workspaceID).first,
               task.state == state {
                return task
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for task state \(state.rawValue)", file: file, line: line)
        throw RuntimeStepAdapterTestError.timeout
    }
}

private enum RuntimeStepAdapterTestError: Error {
    case timeout
}

private struct TwoStepPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.one",
                    title: "Inspect current directory",
                    intent: "Create a checkpoint before inspecting.",
                    toolCallID: "tool.pwd",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "step.two",
                    title: "Emit follow-up marker",
                    intent: "Verify runtime continued after the checkpoint.",
                    toolCallID: "tool.echo",
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [
                ToolCall(
                    id: "tool.pwd",
                    type: .shell,
                    command: "/bin/pwd",
                    arguments: [],
                    workingDirectory: nil,
                    requiresApproval: false
                ),
                ToolCall(
                    id: "tool.echo",
                    type: .shell,
                    command: "/bin/echo",
                    arguments: ["resumed"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [],
            confidence: 0.9
        )
    }
}

private actor StepRecordingToolExecutor: ToolExecuting {
    private var commands: [String] = []

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        commands.append(call.command)
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "ok \(call.command)",
            standardError: "",
            duration: 0.001
        )
    }

    func executedCommands() -> [String] {
        commands
    }
}
