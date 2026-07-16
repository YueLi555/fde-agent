import XCTest
@testable import FDECloudOS

final class AgentMissionRuntimeTests: XCTestCase {
    func testPromptOrchestratorDefinesInstructionForEveryMissionState() {
        let context = promptContext(input: "Audit runtime state behavior")
        let orchestrator = PromptOrchestrator()

        for state in MissionState.allCases {
            let prompt = orchestrator.compile(
                state: state,
                input: "Audit runtime state behavior",
                context: context
            )

            XCTAssertEqual(prompt.missionState, state)
            XCTAssertTrue(prompt.systemInstruction.contains(state.rawValue))
            XCTAssertTrue(prompt.userPrompt.contains(#""current_mission_state":"\#(state.rawValue)""#))
            XCTAssertFalse(prompt.allowedActions.isEmpty)
            XCTAssertFalse(prompt.outputContract.schemaJSON.isEmpty)
        }
    }

    func testPromptOrchestratorUnderstandStateGeneratesUnderstandingPrompt() {
        let prompt = PromptOrchestrator().compile(
            state: .understand,
            input: "Audit runtime state behavior",
            context: promptContext(input: "Audit runtime state behavior")
        )

        XCTAssertTrue(prompt.systemInstruction.contains("System Understanding Agent"))
        XCTAssertTrue(prompt.systemInstruction.contains("UNDERSTAND"))
        XCTAssertFalse(prompt.toolAccess.enabled)
        XCTAssertTrue(prompt.allowedActions.contains(.askClarification))
        XCTAssertTrue(prompt.forbiddenActions.contains(.executeTool))
        XCTAssertTrue(prompt.outputContract.requiredTopLevelKeys.contains("tool_calls"))
    }

    func testPromptOrchestratorPlanStateGeneratesPlanningPrompt() {
        let prompt = PromptOrchestrator().compile(
            state: .plan,
            input: "Audit runtime state behavior",
            context: promptContext(input: "Audit runtime state behavior")
        )

        XCTAssertTrue(prompt.systemInstruction.contains("Planner Agent"))
        XCTAssertTrue(prompt.systemInstruction.contains("PLAN"))
        XCTAssertFalse(prompt.toolAccess.enabled)
        XCTAssertTrue(prompt.allowedActions.contains(.submitTask))
        XCTAssertTrue(prompt.forbiddenActions.contains(.executeTool))
        XCTAssertTrue(prompt.userPrompt.contains(#""schemaName":"StructuredAgentOutput""#))
    }

    func testPromptOrchestratorExecuteStateEnablesTools() {
        let prompt = PromptOrchestrator().compile(
            state: .execute,
            input: "Audit runtime state behavior",
            context: promptContext(input: "Audit runtime state behavior")
        )

        XCTAssertTrue(prompt.systemInstruction.contains("Executor Agent"))
        XCTAssertTrue(prompt.toolAccess.enabled)
        XCTAssertTrue(prompt.allowedActions.contains(.executeTool))
        XCTAssertEqual(prompt.toolAccess.allowedToolTypes, [.api])
        XCTAssertTrue(prompt.toolAccess.availableTools.contains("engineering.inspect_project"))
        XCTAssertFalse(prompt.toolAccess.availableTools.contains("/bin/pwd"))
        XCTAssertFalse(prompt.forbiddenActions.contains(.executeTool))
    }

    func testPromptOrchestratorObserveStateAnalyzesResults() {
        let workspace = Workspace.default()
        let worldModel = SystemWorldModel(
            workspaceID: workspace.id,
            customerContext: "Runtime test workspace",
            connectedSystems: ["local_shell:swift"],
            permissions: ["role:FDE"],
            previousFailures: ["swift test failed"],
            environmentFacts: ["tests_available:true"],
            observations: ["exit_code:1", "stderr_available:true"]
        )

        let prompt = PromptOrchestrator().compile(
            state: .observe,
            input: "Audit runtime state behavior",
            context: promptContext(workspace: workspace, input: "Audit runtime state behavior"),
            worldModel: worldModel
        )

        XCTAssertTrue(prompt.systemInstruction.contains("Observation Agent"))
        XCTAssertTrue(prompt.systemInstruction.contains("Analyze the actual bounded tool result"))
        XCTAssertFalse(prompt.toolAccess.enabled)
        XCTAssertTrue(prompt.allowedActions.contains(.replan))
        XCTAssertTrue(prompt.forbiddenActions.contains(.executeTool))
        XCTAssertTrue(prompt.worldModelJSON.contains("exit_code:1"))
        XCTAssertTrue(prompt.userPrompt.contains("stderr_available:true"))
    }

    func testMissionStateMachineAllowsAutonomousLoopPath() throws {
        let stateMachine = MissionStateMachine()
        var state = MissionState.understand

        state = try stateMachine.transition(from: state, to: .plan)
        state = try stateMachine.transition(from: state, to: .ready)
        state = try stateMachine.transition(from: state, to: .execute)
        state = try stateMachine.transition(from: state, to: .observe)
        state = try stateMachine.transition(from: state, to: .adapt)
        state = try stateMachine.transition(from: state, to: .execute)
        state = try stateMachine.transition(from: state, to: .observe)
        state = try stateMachine.transition(from: state, to: .verifying)
        state = try stateMachine.transition(from: state, to: .complete)

        XCTAssertEqual(state, .complete)
    }

    func testMissionStateMachineRejectsSkippingPlan() {
        let stateMachine = MissionStateMachine()

        XCTAssertThrowsError(try stateMachine.transition(from: .understand, to: .execute)) { error in
            XCTAssertEqual(error as? MissionStateError, .invalidTransition(.understand, .execute))
        }
    }

    func testDecisionEnginePausesVagueMissionBeforeActing() {
        let intent = MissionIntentParser().parse("hi")
        let decision = AgentDecisionEngine().decideNewMission(
            intent: intent,
            isCapabilityQuestion: false,
            needsClarification: intent.shouldAskClarification
        )

        XCTAssertFalse(decision.shouldAct)
        XCTAssertEqual(decision.nextAction, .askClarification)
        XCTAssertFalse(decision.requiresHumanApproval)
        XCTAssertEqual(decision.state.missionState, .waitingHuman)
        XCTAssertNil(decision.state.taskState)
        XCTAssertEqual(decision.state.toolState, .idle)
    }

    func testDecisionEngineSubmitsConcreteMutatingMissionWithApprovalRequirement() {
        let intent = MissionIntentParser().parse("Implement missing Agent Runtime loop and add tests")
        let decision = AgentDecisionEngine().decideNewMission(
            intent: intent,
            isCapabilityQuestion: false,
            needsClarification: intent.shouldAskClarification
        )

        XCTAssertTrue(decision.shouldAct)
        XCTAssertEqual(decision.nextAction, .submitTask)
        XCTAssertTrue(decision.requiresHumanApproval)
        XCTAssertEqual(decision.state.missionState, .plan)
        XCTAssertNil(decision.state.taskState)
        XCTAssertEqual(decision.state.toolState, .idle)
    }

    func testDecisionEngineSeparatesToolApprovalStateFromTaskState() {
        let step = PlanStep(
            id: "step.edit",
            title: "Edit file",
            intent: "Mutate workspace",
            toolCallID: "tool.edit",
            requiresApproval: true
        )
        let tool = ToolCall(
            id: "tool.edit",
            type: .shell,
            command: "/bin/rm",
            arguments: ["file.txt"],
            workingDirectory: nil,
            requiresApproval: true
        )
        let risk = RiskClassification(
            level: .high,
            reasons: ["Shell command can modify system or workspace state."],
            requiresApproval: true
        )

        let decision = AgentDecisionEngine().decideToolExecution(
            step: step,
            toolCall: tool,
            risk: risk
        )

        XCTAssertFalse(decision.shouldAct)
        XCTAssertEqual(decision.nextAction, .requestHumanApproval)
        XCTAssertTrue(decision.requiresHumanApproval)
        XCTAssertEqual(decision.state.missionState, .waitingHuman)
        XCTAssertEqual(decision.state.taskState, .pendingApproval)
        XCTAssertEqual(decision.state.toolState, .pendingApproval)
    }

    func testSystemUnderstandingLayerBuildsWorldModelFromWorkspaceAndHistory() {
        let workspace = Workspace(
            id: UUID(),
            name: "Customer Workspace",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: "/tmp/customer-app"
        )
        let failure = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspace.id,
            taskID: UUID(),
            type: .toolFailed,
            sequence: 1,
            timestamp: Date(),
            summary: "GitHub connector failed",
            payload: ["command": "github.create_issue"]
        )
        let context = ExecutionContext(
            workspace: workspace,
            policyRules: [],
            graphSummary: "empty",
            recentTaskTitles: [],
            taskFingerprint: "test",
            policyDeltas: [],
            failurePatterns: [],
            systemFailureProfile: nil,
            globalExecutionPolicy: nil
        )

        let model = SystemUnderstandingLayer().initialModel(
            workspace: workspace,
            context: context,
            recentTasks: [],
            workspaceEvents: [failure],
            policyDeltas: [],
            systemFailureProfile: nil,
            globalExecutionPolicy: nil
        )

        XCTAssertTrue(model.customerContext.contains("Customer Workspace"))
        XCTAssertTrue(model.connectedSystems.contains("connector:github"))
        XCTAssertTrue(model.permissions.contains("allows:\(Permission.executeTool.rawValue)"))
        XCTAssertTrue(model.previousFailures.contains("tool_failed:github.create_issue"))
        XCTAssertTrue(model.environmentFacts.contains("project_root:/tmp/customer-app"))
    }

    func testObservationLoopUpdatesWorldModelAndDecidesReplanOnFailure() {
        let workspace = Workspace.default()
        let model = SystemWorldModel(
            workspaceID: workspace.id,
            customerContext: "Test customer",
            connectedSystems: [],
            permissions: [],
            previousFailures: [],
            environmentFacts: [],
            observations: []
        )
        let step = PlanStep(
            id: "step.connector",
            title: "Create ticket",
            intent: "Create ticket",
            toolCallID: "tool.github",
            requiresApproval: false
        )
        let call = ToolCall(
            id: "tool.github",
            type: .connector,
            command: "github.create_issue",
            arguments: [],
            workingDirectory: nil,
            requiresApproval: false
        )

        let observation = ObservationLoop().observeFailure(
            step: step,
            toolCall: call,
            error: ToolExecutionError.processFailed("simulated failure"),
            attempt: 1,
            maxAttempts: 1
        )
        let updated = SystemUnderstandingLayer().applying(observation, to: model)

        XCTAssertEqual(observation.outcome, .failed)
        XCTAssertEqual(observation.nextAction, .replan)
        XCTAssertTrue(updated.connectedSystems.contains("connector:github"))
        XCTAssertTrue(updated.previousFailures.contains { $0.contains("simulated failure") })
        XCTAssertTrue(updated.observations.contains(observation.summary))
    }

    func testReplanningEngineCreatesHypothesisModifiedStepAndRecoveryCall() {
        let workspace = Workspace.default()
        let model = SystemWorldModel(
            workspaceID: workspace.id,
            customerContext: "Test customer",
            connectedSystems: ["local_shell:ls"],
            permissions: ["allows:executeTool"],
            previousFailures: ["tool_failed:/bin/ls"],
            environmentFacts: [],
            observations: []
        )
        let step = PlanStep(
            id: "step.inspect",
            title: "Inspect workspace",
            intent: "List files",
            toolCallID: "tool.list",
            requiresApproval: false
        )
        let call = ToolCall(
            id: "tool.list",
            type: .shell,
            command: "/bin/ls",
            arguments: ["."],
            workingDirectory: nil,
            requiresApproval: false
        )

        let replan = ReplanningEngine().replan(
            failedStep: step,
            failedCall: call,
            error: ToolExecutionError.processFailed("simulated failure"),
            worldModel: model,
            recoveryAgent: RecoveryAgent()
        )

        XCTAssertEqual(replan.modifiedStep.id, "replan.step.inspect")
        XCTAssertEqual(replan.modifiedStep.toolCallID, "recovery.tool.list")
        XCTAssertEqual(replan.recoveryCall.command, "/bin/echo")
        XCTAssertTrue(replan.hypothesis.contains("/bin/ls"))
    }

    private func promptContext(
        workspace: Workspace = Workspace.default(),
        input: String
    ) -> ExecutionContext {
        ExecutionContext(
            workspace: workspace,
            policyRules: [
                "Use structured JSON only for agent outputs.",
                "Prefer read-only local inspection tools until a human approves mutation."
            ],
            graphSummary: "runtime graph available",
            recentTaskTitles: ["Previous runtime audit"],
            taskFingerprint: TaskFingerprint.make(from: input),
            policyDeltas: [],
            failurePatterns: [],
            systemFailureProfile: nil,
            globalExecutionPolicy: nil
        )
    }
}
