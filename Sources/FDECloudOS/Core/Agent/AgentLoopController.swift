import Foundation

struct AgentTaskUpdate: Codable, Hashable, Sendable {
    var title: String?
    var state: TaskState?
    var plan: [PlanStep]?
}

struct AgentDecision: Codable, Hashable, Sendable {
    var nextState: MissionState
    var actionType: AgentRuntimeAction
    var taskUpdate: AgentTaskUpdate?
    var toolRequest: ToolCall?
    var reasoningSummary: String
    var confidence: Double
    var requiresHumanApproval: Bool
    var completionSignal: Bool

    var auditPayload: [String: String] {
        [
            "agent_decision_next_state": nextState.rawValue,
            "agent_decision_action_type": actionType.rawValue,
            "agent_decision_summary": AgentPresentationSanitizer.safeContent(
                reasoningSummary,
                fallback: "Agent selected next runtime action."
            ),
            "agent_decision_confidence": String(confidence),
            "agent_decision_requires_human_approval": requiresHumanApproval ? "true" : "false",
            "agent_decision_completion_signal": completionSignal ? "true" : "false",
            "agent_decision_tool_request_id": toolRequest?.id ?? "",
            "agent_decision_tool_request_command": toolRequest?.command ?? "",
            "agent_decision_task_state": taskUpdate?.state?.rawValue ?? ""
        ]
    }
}

struct AgentRelevantMemory: Codable, Hashable, Sendable {
    var previousSimilarMissions: [String]
    var previousFailures: [String]
    var successfulSolutions: [String]
    var customerEnvironmentKnowledge: [String] = []

    static let empty = AgentRelevantMemory(
        previousSimilarMissions: [],
        previousFailures: [],
        successfulSolutions: [],
        customerEnvironmentKnowledge: []
    )
}

struct AgentMemoryRequest: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var taskID: UUID
    var missionInput: String
    var missionState: MissionState
    var taskFingerprint: String
    var previousObservations: [String]
}

struct AgentMissionOutcome: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var taskID: UUID
    var finalState: MissionState
    var completionSignal: Bool
    var failurePatterns: [String]
    var successfulActions: [String]
    var customerEnvironmentKnowledge: [String]
    var outcomeRecord: OutcomeRecord
    var confidence: Double
    var summary: String
    var completedAt: Date
}

protocol AgentMemoryProvider: Sendable {
    func retrieveRelevantMemory(_ request: AgentMemoryRequest) async -> AgentRelevantMemory
    func storeMissionOutcome(_ outcome: AgentMissionOutcome) async
}

struct NoOpAgentMemoryProvider: AgentMemoryProvider {
    func retrieveRelevantMemory(_ request: AgentMemoryRequest) async -> AgentRelevantMemory {
        .empty
    }

    func storeMissionOutcome(_ outcome: AgentMissionOutcome) async {}
}

actor InMemoryAgentMemoryProvider: AgentMemoryProvider {
    private var outcomes: [AgentMissionOutcome] = []

    func retrieveRelevantMemory(_ request: AgentMemoryRequest) async -> AgentRelevantMemory {
        let workspaceOutcomes = outcomes
            .filter { $0.workspaceID == request.workspaceID }
            .suffix(12)

        return AgentRelevantMemory(
            previousSimilarMissions: workspaceOutcomes.map { $0.outcomeRecord.objective },
            previousFailures: workspaceOutcomes.flatMap(\.failurePatterns).suffixArray(12),
            successfulSolutions: workspaceOutcomes.flatMap(\.successfulActions).suffixArray(12),
            customerEnvironmentKnowledge: workspaceOutcomes.flatMap(\.customerEnvironmentKnowledge).suffixArray(12)
        )
    }

    func storeMissionOutcome(_ outcome: AgentMissionOutcome) async {
        outcomes.append(outcome)
    }

    func storedOutcomes() -> [AgentMissionOutcome] {
        outcomes
    }
}

struct AgentLoopSnapshot: Codable, Hashable, Sendable {
    var runtimeState: RuntimeStateSnapshot
    var worldModel: SystemWorldModel
    var previousObservations: [ToolObservation]
    var activePlan: [PlanStep]
    var activeToolCalls: [ToolCall]
    var policyConstraints: [String]
    var memory: AgentRelevantMemory

    var auditPayload: [String: String] {
        var payload = runtimeState.auditPayload
        payload["agent_loop_active_plan_count"] = String(activePlan.count)
        payload["agent_loop_active_tool_count"] = String(activeToolCalls.count)
        payload["agent_loop_previous_observation_count"] = String(previousObservations.count)
        payload["agent_loop_policy_constraint_count"] = String(policyConstraints.count)
        payload["agent_loop_memory_previous_mission_count"] = String(memory.previousSimilarMissions.count)
        payload["agent_loop_memory_failure_count"] = String(memory.previousFailures.count)
        payload["agent_loop_memory_solution_count"] = String(memory.successfulSolutions.count)
        payload["agent_loop_memory_environment_knowledge_count"] = String(memory.customerEnvironmentKnowledge.count)
        return payload
    }
}

enum AgentLoopStopReason: String, Codable, Hashable, Sendable {
    case complete = "COMPLETE"
    case waitingHuman = "WAITING_HUMAN"
    case missingCriticalInformation = "MISSING_CRITICAL_INFORMATION"
    case policyViolation = "POLICY_VIOLATION"
    case failed = "FAILED"
    case maxIterationsReached = "MAX_ITERATIONS_REACHED"
}

struct AgentLoopResult: Sendable {
    var task: FDETask
    var finalSnapshot: RuntimeStateSnapshot
    var decisions: [AgentDecision]
    var events: [ExecutionEvent]
    var iterations: Int
    var stopReason: AgentLoopStopReason
    var outcomeRecord: OutcomeRecord?
}

struct AgentLoopConfiguration: Sendable {
    var maxLoopIterations: Int
    var minimumDecisionConfidence: Double

    init(
        maxLoopIterations: Int = 20,
        minimumDecisionConfidence: Double = 0.2
    ) {
        self.maxLoopIterations = max(1, maxLoopIterations)
        self.minimumDecisionConfidence = minimumDecisionConfidence
    }
}

private struct MissionCompletionEvidenceValidation: Sendable {
    var successfulObservationCount: Int
    var successfulToolResultCount: Int
    var executedStepCount: Int
    var latestObservationSucceeded: Bool

    var isValid: Bool {
        successfulObservationCount > 0
            && successfulToolResultCount > 0
            && executedStepCount > 0
            && latestObservationSucceeded
    }

    var missingEvidence: [String] {
        var missing: [String] = []
        if successfulObservationCount == 0 {
            missing.append("successful_tool_observation")
        }
        if successfulToolResultCount == 0 {
            missing.append("successful_tool_result_event")
        }
        if executedStepCount == 0 {
            missing.append("executed_plan_step")
        }
        if !latestObservationSucceeded {
            missing.append("resolved_latest_tool_error")
        }
        return missing
    }

    var auditPayload: [String: String] {
        [
            "completion_gate_passed": isValid ? "true" : "false",
            "completion_evidence_successful_observations": String(successfulObservationCount),
            "completion_evidence_successful_tool_results": String(successfulToolResultCount),
            "completion_evidence_executed_steps": String(executedStepCount),
            "completion_evidence_latest_observation_succeeded": latestObservationSucceeded ? "true" : "false",
            "completion_evidence_missing": missingEvidence.joined(separator: " | ")
        ]
    }
}

actor AgentLoopController {
    private let persistence: any PersistenceStore
    private let eventStream: any EventStream
    private let contextCompiler: InstructionContextCompiler
    private let modelRouter: any ModelRouting
    private let validator: any StructuredOutputValidating
    private let promptOrchestrator: PromptOrchestrator
    private let toolExecutor: any ToolExecuting
    private let approvalQueue: ApprovalQueue
    private let riskAssessmentEngine: RiskAssessmentEngine
    private let policyEngine: PolicyEngine
    private let agentQualityEvaluator: AgentQualityEvaluator
    private let memoryImprovementPipeline: AgentMemoryImprovementPipeline
    private let enterpriseMemoryStore: (any EnterpriseMemoryStoring)?
    private let missionStateMachine: MissionStateMachine
    private let workflowStateMachine: WorkflowStateMachine
    private let systemUnderstandingLayer: SystemUnderstandingLayer
    private let observationLoop: ObservationLoop
    private let systemDiscoveryEngine: SystemDiscoveryEngine
    private let memoryProvider: any AgentMemoryProvider
    private let configuration: AgentLoopConfiguration

    private var sequence: Int64 = 0
    private var sequenceInitialized = false
    private var lastEventIDByTask: [UUID: UUID] = [:]
    private var lastEventIDByWorkspace: [UUID: UUID] = [:]
    private var recordedEvents: [ExecutionEvent] = []

    init(
        persistence: any PersistenceStore,
        eventStream: (any EventStream)? = nil,
        contextCompiler: InstructionContextCompiler = InstructionContextCompiler(),
        modelRouter: any ModelRouting,
        validator: any StructuredOutputValidating = StructuredOutputValidator(),
        promptOrchestrator: PromptOrchestrator = PromptOrchestrator(),
        toolExecutor: any ToolExecuting = LocalToolExecutor(),
        approvalQueue: ApprovalQueue? = nil,
        riskAssessmentEngine: RiskAssessmentEngine = RiskAssessmentEngine(),
        policyEngine: PolicyEngine = PolicyEngine(),
        agentQualityEvaluator: AgentQualityEvaluator = AgentQualityEvaluator(),
        memoryImprovementPipeline: AgentMemoryImprovementPipeline = AgentMemoryImprovementPipeline(),
        enterpriseMemoryStore: (any EnterpriseMemoryStoring)? = nil,
        missionStateMachine: MissionStateMachine = MissionStateMachine(),
        workflowStateMachine: WorkflowStateMachine = WorkflowStateMachine(),
        systemUnderstandingLayer: SystemUnderstandingLayer = SystemUnderstandingLayer(),
        observationLoop: ObservationLoop = ObservationLoop(),
        systemDiscoveryEngine: SystemDiscoveryEngine = SystemDiscoveryEngine(),
        memoryProvider: any AgentMemoryProvider = NoOpAgentMemoryProvider(),
        configuration: AgentLoopConfiguration = AgentLoopConfiguration()
    ) {
        self.persistence = persistence
        self.eventStream = eventStream ?? InMemoryEventStream(eventBus: RuntimeEventBus())
        self.contextCompiler = contextCompiler
        self.modelRouter = modelRouter
        self.validator = validator
        self.promptOrchestrator = promptOrchestrator
        self.toolExecutor = toolExecutor
        self.approvalQueue = approvalQueue ?? ApprovalQueue(persistence: persistence)
        self.riskAssessmentEngine = riskAssessmentEngine
        self.policyEngine = policyEngine
        self.agentQualityEvaluator = agentQualityEvaluator
        self.memoryImprovementPipeline = memoryImprovementPipeline
        self.enterpriseMemoryStore = enterpriseMemoryStore
        self.missionStateMachine = missionStateMachine
        self.workflowStateMachine = workflowStateMachine
        self.systemUnderstandingLayer = systemUnderstandingLayer
        self.observationLoop = observationLoop
        self.systemDiscoveryEngine = systemDiscoveryEngine
        self.memoryProvider = memoryProvider
        self.configuration = configuration
    }

    func runMission(input: String, workspace: Workspace) async throws -> AgentLoopResult {
        recordedEvents = []
        let safeInput = AgentPresentationSanitizer.safeContent(input, fallback: "Autonomous mission")
        var task = FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: makeTitle(from: safeInput),
            rawInput: safeInput,
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await persistence.saveTask(task)

        var missionState = try transition(from: MissionState.idle, to: .understand)
        var toolState = ToolExecutionState.idle
        var activePlan: [PlanStep] = []
        var activeToolCalls: [ToolCall] = []
        var previousObservations: [ToolObservation] = []
        var executedStepIDs: Set<String> = []
        var decisions: [AgentDecision] = []
        var lastConfidence = 0.0
        var worldModel: SystemWorldModel?

        try await recordLoopEvent(
            type: .taskCreated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Autonomous mission created",
            stage: .understanding,
            missionState: missionState,
            taskState: task.state,
            toolState: toolState,
            iteration: 0,
            payload: [
                "state": task.state.rawValue,
                "agent_loop_controller": "true",
                "agent_loop_stop_reason": ""
            ]
        )

        for iteration in 1...configuration.maxLoopIterations {
            let context = try await buildExecutionContext(
                workspace: workspace,
                input: safeInput,
                task: task
            )
            if worldModel == nil {
                let recentTasks = try await persistence.loadTasks(workspaceID: workspace.id)
                let workspaceEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
                let policyDeltas = try await persistence.loadPolicyDeltas(workspaceID: workspace.id)
                worldModel = systemUnderstandingLayer.initialModel(
                    workspace: workspace,
                    context: context,
                    recentTasks: recentTasks,
                    workspaceEvents: workspaceEvents,
                    policyDeltas: policyDeltas,
                    systemFailureProfile: try await persistence.loadLatestSystemFailureProfile(workspaceID: workspace.id),
                    globalExecutionPolicy: try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)
                )
                let environment = await systemDiscoveryEngine.discover(workspace: workspace)
                try await persistence.saveGraph(
                    nodes: environment.environmentGraphNodes,
                    edges: environment.environmentGraphEdges
                )
                if let currentWorldModel = worldModel {
                    worldModel = systemUnderstandingLayer.applying(environment, to: currentWorldModel)
                }
                try await recordLoopEvent(
                    type: .contextCompiled,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Autonomous world model compiled",
                    stage: .understanding,
                    missionState: missionState,
                    taskState: task.state,
                    toolState: toolState,
                    iteration: iteration,
                    payload: (worldModel?.auditPayload ?? [:])
                        .merging(environment.auditPayload) { current, _ in current }
                )
            }

            let memory = await memoryProvider.retrieveRelevantMemory(
                AgentMemoryRequest(
                    workspaceID: workspace.id,
                    taskID: task.id,
                    missionInput: safeInput,
                    missionState: missionState,
                    taskFingerprint: context.taskFingerprint,
                    previousObservations: previousObservations.map(\.summary)
                )
            )
            let snapshot = readCurrentSnapshot(
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                worldModel: worldModel ?? fallbackWorldModel(workspace: workspace, context: context),
                previousObservations: previousObservations,
                activePlan: activePlan,
                activeToolCalls: activeToolCalls,
                context: context,
                memory: memory
            )

            try await recordLoopEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Agent loop entered \(loopStage(for: missionState).rawValue)",
                stage: loopStage(for: missionState),
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: snapshot.auditPayload
            )

            let prompt = promptOrchestrator.compile(
                state: missionState,
                input: safeInput,
                context: context,
                worldModel: snapshot.worldModel,
                memory: memory
            )
            let output = try await modelRouter.generateDecision(prompt: prompt, context: context)
            try validator.validate(output)

            let decision = makeDecision(
                output: output,
                snapshot: snapshot,
                currentState: missionState,
                executedStepIDs: executedStepIDs
            )
            decisions.append(decision)
            lastConfidence = decision.confidence

            try await recordLoopEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Agent decided: \(decision.reasoningSummary)",
                stage: .decision,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: decision.auditPayload
                    .merging(snapshot.auditPayload) { current, _ in current }
            )

            var currentWorldModel = worldModel ?? fallbackWorldModel(workspace: workspace, context: context)
            let actionResult = try await act(
                decision: decision,
                output: output,
                workspace: workspace,
                task: &task,
                missionState: &missionState,
                toolState: &toolState,
                worldModel: &currentWorldModel,
                activePlan: &activePlan,
                activeToolCalls: &activeToolCalls,
                previousObservations: &previousObservations,
                executedStepIDs: &executedStepIDs,
                iteration: iteration,
                context: context
            )
            worldModel = currentWorldModel

            if let stopReason = actionResult {
                let outcomeRecord = await recordOutcomeIfTerminal(
                    stopReason: stopReason,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    objective: safeInput,
                    finalState: missionState,
                    completionSignal: stopReason == .complete,
                    observations: previousObservations,
                    activeToolCalls: activeToolCalls,
                    confidence: lastConfidence,
                    events: recordedEvents,
                    worldModel: currentWorldModel,
                    task: task
                )
                return AgentLoopResult(
                    task: task,
                    finalSnapshot: RuntimeStateSnapshot(
                        missionState: missionState,
                        taskState: task.state,
                        toolState: toolState
                    ),
                    decisions: decisions,
                    events: recordedEvents,
                    iterations: iteration,
                    stopReason: stopReason,
                    outcomeRecord: outcomeRecord
                )
            }
        }

        try await recordLoopEvent(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Agent loop stopped at maximum iteration limit",
            stage: .decision,
            missionState: missionState,
            taskState: task.state,
            toolState: toolState,
            iteration: configuration.maxLoopIterations,
            payload: [
                "agent_loop_stop_reason": AgentLoopStopReason.maxIterationsReached.rawValue,
                "max_loop_iterations": String(configuration.maxLoopIterations)
            ]
        )

        let maxIterationOutcome = await storeMissionOutcome(
            workspaceID: workspace.id,
            taskID: task.id,
            objective: safeInput,
            finalState: missionState,
            completionSignal: false,
            observations: previousObservations,
            activeToolCalls: activeToolCalls,
            confidence: lastConfidence,
            events: recordedEvents,
            worldModel: worldModel ?? fallbackOutcomeWorldModel(workspace: workspace),
            task: task
        )

        return AgentLoopResult(
            task: task,
            finalSnapshot: RuntimeStateSnapshot(
                missionState: missionState,
                taskState: task.state,
                toolState: toolState
            ),
            decisions: decisions,
            events: recordedEvents,
            iterations: configuration.maxLoopIterations,
            stopReason: .maxIterationsReached,
            outcomeRecord: maxIterationOutcome
        )
    }

    private func buildExecutionContext(
        workspace: Workspace,
        input: String,
        task: FDETask
    ) async throws -> ExecutionContext {
        let recentTasks = try await persistence.loadTasks(workspaceID: workspace.id)
        let graph = try await persistence.loadGraph(workspaceID: workspace.id)
        let workspaceEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
        let policyDeltas = try await persistence.loadPolicyDeltas(workspaceID: workspace.id)
        let systemFailureProfile = try await persistence.loadLatestSystemFailureProfile(workspaceID: workspace.id)
        let globalExecutionPolicy = try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)
        return await contextCompiler.compile(
            workspace: workspace,
            taskInput: input,
            recentTasks: recentTasks.filter { $0.id != task.id },
            graph: graph,
            policyDeltas: policyDeltas,
            workspaceEvents: workspaceEvents,
            failureEvents: workspaceEvents.filter { $0.type == .toolFailed || $0.type == .connectorFailed },
            systemFailureProfile: systemFailureProfile,
            globalExecutionPolicy: globalExecutionPolicy
        )
    }

    private func readCurrentSnapshot(
        missionState: MissionState,
        taskState: TaskState,
        toolState: ToolExecutionState,
        worldModel: SystemWorldModel,
        previousObservations: [ToolObservation],
        activePlan: [PlanStep],
        activeToolCalls: [ToolCall],
        context: ExecutionContext,
        memory: AgentRelevantMemory
    ) -> AgentLoopSnapshot {
        AgentLoopSnapshot(
            runtimeState: RuntimeStateSnapshot(
                missionState: missionState,
                taskState: taskState,
                toolState: toolState
            ),
            worldModel: worldModel,
            previousObservations: previousObservations,
            activePlan: activePlan,
            activeToolCalls: activeToolCalls,
            policyConstraints: policyConstraints(from: context),
            memory: memory
        )
    }

    private func makeDecision(
        output: StructuredAgentOutput,
        snapshot: AgentLoopSnapshot,
        currentState: MissionState,
        executedStepIDs: Set<String>
    ) -> AgentDecision {
        let proposedTool = nextExecutableTool(
            plan: output.plan,
            toolCalls: output.toolCalls,
            executedStepIDs: executedStepIDs
        )
        let requiresApproval = proposedTool?.requiresApproval == true
            || output.plan.contains(where: \.requiresApproval)
            || output.risks.contains { $0.severity == .high }
        let lowConfidence = output.confidence < configuration.minimumDecisionConfidence
        let summary = decisionSummary(output: output, state: currentState)
        if lowConfidence && currentState != .complete && currentState != .failed {
            return AgentDecision(
                nextState: .waitingHuman,
                actionType: .askClarification,
                taskUpdate: AgentTaskUpdate(title: nil, state: .waiting, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: "Critical mission information is missing.",
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        }

        switch currentState {
        case .idle:
            return AgentDecision(
                nextState: .understand,
                actionType: .continueMission,
                taskUpdate: AgentTaskUpdate(title: nil, state: .created, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: summary,
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .understand:
            return AgentDecision(
                nextState: .plan,
                actionType: .submitTask,
                taskUpdate: AgentTaskUpdate(title: nil, state: .planned, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: summary,
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .plan:
            if requiresApproval {
                return approvalDecision(
                    output: output,
                    tool: proposedTool,
                    summary: summary
                )
            }
            return AgentDecision(
                nextState: .ready,
                actionType: .continueMission,
                taskUpdate: AgentTaskUpdate(title: nil, state: .planned, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: proposedTool == nil
                    ? "Plan is ready but contains no executable tool step; remain READY without claiming completion."
                    : summary,
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .ready:
            guard proposedTool != nil else {
                return AgentDecision(
                    nextState: .ready,
                    actionType: .continueMission,
                    taskUpdate: AgentTaskUpdate(title: nil, state: .planned, plan: output.plan),
                    toolRequest: nil,
                    reasoningSummary: "No executable tool step is ready; the mission remains planned and cannot complete.",
                    confidence: output.confidence,
                    requiresHumanApproval: false,
                    completionSignal: false
                )
            }
            if requiresApproval {
                return approvalDecision(
                    output: output,
                    tool: proposedTool,
                    summary: summary
                )
            }
            return AgentDecision(
                nextState: .execute,
                actionType: .continueMission,
                taskUpdate: AgentTaskUpdate(title: nil, state: .running, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: summary,
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .execute:
            guard let proposedTool else {
                return AgentDecision(
                    nextState: .failed,
                    actionType: .stopTask,
                    taskUpdate: AgentTaskUpdate(title: nil, state: .failed, plan: output.plan),
                    toolRequest: nil,
                    reasoningSummary: "Execution produced no tool request, so the executable mission failed instead of synthesizing completion evidence.",
                    confidence: output.confidence,
                    requiresHumanApproval: false,
                    completionSignal: false
                )
            }
            if requiresApproval {
                return approvalDecision(
                    output: output,
                    tool: proposedTool,
                    summary: summary
                )
            }
            return AgentDecision(
                nextState: .observe,
                actionType: .executeTool,
                taskUpdate: AgentTaskUpdate(title: nil, state: .running, plan: output.plan),
                toolRequest: proposedTool,
                reasoningSummary: summary,
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .observe:
            if snapshot.previousObservations.last?.outcome == .failed {
                return AgentDecision(
                    nextState: .adapt,
                    actionType: .replan,
                    taskUpdate: AgentTaskUpdate(title: nil, state: .running, plan: output.plan),
                    toolRequest: proposedTool,
                    reasoningSummary: summary,
                    confidence: output.confidence,
                    requiresHumanApproval: false,
                    completionSignal: false
                )
            }
            if let latestObservation = snapshot.previousObservations.last,
               latestObservation.outcome == .succeeded,
               proposedTool == nil {
                return AgentDecision(
                    nextState: .verifying,
                    actionType: .continueMission,
                    taskUpdate: AgentTaskUpdate(title: nil, state: .running, plan: output.plan),
                    toolRequest: nil,
                    reasoningSummary: "Successful tool output is available for evidence verification.",
                    confidence: output.confidence,
                    requiresHumanApproval: false,
                    completionSignal: false
                )
            }
            if proposedTool == nil {
                return AgentDecision(
                    nextState: .failed,
                    actionType: .stopTask,
                    taskUpdate: AgentTaskUpdate(title: nil, state: .failed, plan: output.plan),
                    toolRequest: nil,
                    reasoningSummary: "Observation contained no successful tool result to verify.",
                    confidence: output.confidence,
                    requiresHumanApproval: false,
                    completionSignal: false
                )
            }
            return AgentDecision(
                nextState: .execute,
                actionType: .continueMission,
                taskUpdate: AgentTaskUpdate(title: nil, state: .running, plan: output.plan),
                toolRequest: proposedTool,
                reasoningSummary: summary,
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .verifying:
            let evidence = completionEvidenceValidation(
                observations: snapshot.previousObservations,
                executedStepIDs: executedStepIDs
            )
            if evidence.isValid, proposedTool == nil {
                return completionDecision(output: output, summary: summary)
            }
            if let proposedTool {
                if requiresApproval {
                    return approvalDecision(
                        output: output,
                        tool: proposedTool,
                        summary: summary
                    )
                }
                return AgentDecision(
                    nextState: .execute,
                    actionType: .continueMission,
                    taskUpdate: AgentTaskUpdate(title: nil, state: .running, plan: output.plan),
                    toolRequest: proposedTool,
                    reasoningSummary: evidence.isValid
                        ? "Verification identified another required tool step; continue execution before completion."
                        : "Verification is missing \(evidence.missingEvidence.joined(separator: ", ")); continue real execution.",
                    confidence: output.confidence,
                    requiresHumanApproval: false,
                    completionSignal: false
                )
            }
            return AgentDecision(
                nextState: .failed,
                actionType: .stopTask,
                taskUpdate: AgentTaskUpdate(title: nil, state: .failed, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: "Verification failed because required execution evidence is missing: \(evidence.missingEvidence.joined(separator: ", ")).",
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .adapt:
            if proposedTool == nil {
                return AgentDecision(
                    nextState: .failed,
                    actionType: .stopTask,
                    taskUpdate: AgentTaskUpdate(title: nil, state: .failed, plan: output.plan),
                    toolRequest: nil,
                    reasoningSummary: "Recovery produced no executable tool step, so the unresolved tool failure remains FAILED.",
                    confidence: output.confidence,
                    requiresHumanApproval: false,
                    completionSignal: false
                )
            }
            return AgentDecision(
                nextState: .execute,
                actionType: .continueMission,
                taskUpdate: AgentTaskUpdate(title: nil, state: .running, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: summary,
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .waitingHuman:
            return AgentDecision(
                nextState: .waitingHuman,
                actionType: .acknowledgeInstruction,
                taskUpdate: AgentTaskUpdate(title: nil, state: .waiting, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: "Mission is waiting for human input.",
                confidence: output.confidence,
                requiresHumanApproval: true,
                completionSignal: false
            )
        case .blocked:
            return AgentDecision(
                nextState: .waitingHuman,
                actionType: .askClarification,
                taskUpdate: AgentTaskUpdate(title: nil, state: .waiting, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: "Mission remains blocked and needs human input before it can resume.",
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .failed:
            return AgentDecision(
                nextState: .failed,
                actionType: .stopTask,
                taskUpdate: AgentTaskUpdate(title: nil, state: .failed, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: "Mission is failed and cannot be marked complete.",
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        case .complete:
            return AgentDecision(
                nextState: .complete,
                actionType: .acknowledgeInstruction,
                taskUpdate: AgentTaskUpdate(title: nil, state: .completed, plan: output.plan),
                toolRequest: nil,
                reasoningSummary: "Mission is already complete.",
                confidence: output.confidence,
                requiresHumanApproval: false,
                completionSignal: false
            )
        }
    }

    private func act(
        decision: AgentDecision,
        output: StructuredAgentOutput,
        workspace: Workspace,
        task: inout FDETask,
        missionState: inout MissionState,
        toolState: inout ToolExecutionState,
        worldModel: inout SystemWorldModel,
        activePlan: inout [PlanStep],
        activeToolCalls: inout [ToolCall],
        previousObservations: inout [ToolObservation],
        executedStepIDs: inout Set<String>,
        iteration: Int,
        context: ExecutionContext
    ) async throws -> AgentLoopStopReason? {
        if !output.plan.isEmpty {
            if activePlan.isEmpty || !output.toolCalls.isEmpty {
                activePlan = output.plan
            }
            for toolCall in output.toolCalls where !activeToolCalls.contains(where: { $0.id == toolCall.id }) {
                activeToolCalls.append(toolCall)
            }
        }

        if let plan = decision.taskUpdate?.plan,
           task.plan.isEmpty
            || !output.toolCalls.isEmpty
            || [.understand, .plan, .ready].contains(missionState) {
            task.plan = plan
        }
        if let nextTaskState = decision.taskUpdate?.state, nextTaskState != .completed {
            updateTaskState(&task, to: nextTaskState)
            try await persistence.saveTask(task)
        }

        if decision.actionType == .askClarification {
            missionState = try transition(from: missionState, to: .waitingHuman)
            updateTaskState(&task, to: .waiting)
            try await persistence.saveTask(task)
            try await recordLoopEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Agent paused for missing critical information",
                stage: .decision,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: [
                    "agent_loop_stop_reason": AgentLoopStopReason.missingCriticalInformation.rawValue
                ].merging(decision.auditPayload) { current, _ in current }
            )
            return .missingCriticalInformation
        }

        if decision.completionSignal || decision.nextState == .complete {
            let evidence = completionEvidenceValidation(
                observations: previousObservations,
                executedStepIDs: executedStepIDs
            )
            guard missionState == .verifying, evidence.isValid else {
                let rejectedState = missionState
                missionState = try transition(from: missionState, to: .failed)
                toolState = .failed
                updateTaskState(&task, to: .failed)
                try await persistence.saveTask(task)
                try await recordLoopEvent(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Completion rejected because verified execution evidence is missing",
                    stage: .decision,
                    missionState: missionState,
                    taskState: task.state,
                    toolState: toolState,
                    iteration: iteration,
                    payload: [
                        "agent_loop_stop_reason": AgentLoopStopReason.failed.rawValue,
                        "completion_gate_required_state": MissionState.verifying.rawValue,
                        "completion_gate_observed_state": rejectedState.rawValue
                    ].merging(evidence.auditPayload) { current, _ in current }
                        .merging(decision.auditPayload) { current, _ in current }
                )
                return .failed
            }
            missionState = try transition(from: missionState, to: .complete)
            toolState = .succeeded
            updateTaskState(&task, to: .completed)
            task.performanceScore = max(task.performanceScore, decision.confidence * 100)
            try await persistence.saveTask(task)
            try await recordLoopEvent(
                type: .taskCompleted,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Autonomous mission completed",
                stage: .completion,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: [
                    "agent_loop_stop_reason": AgentLoopStopReason.complete.rawValue
                ].merging(evidence.auditPayload) { current, _ in current }
                    .merging(decision.auditPayload) { current, _ in current }
            )
            return .complete
        }

        if decision.nextState == .failed {
            missionState = try transition(from: missionState, to: .failed)
            toolState = .failed
            updateTaskState(&task, to: .failed)
            try await persistence.saveTask(task)
            try await recordLoopEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: decision.reasoningSummary,
                stage: .decision,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: [
                    "agent_loop_stop_reason": AgentLoopStopReason.failed.rawValue,
                    "completion_gate_passed": "false"
                ].merging(decision.auditPayload) { current, _ in current }
            )
            return .failed
        }

        if decision.requiresHumanApproval || decision.actionType == .requestHumanApproval {
            if let toolRequest = decision.toolRequest {
                let review = governanceReview(
                    toolCall: toolRequest,
                    output: output,
                    workspace: workspace,
                    context: context,
                    worldModel: worldModel
                )
                if review.policyEvaluation.status == .denied {
                    try await recordGovernanceDenied(
                        review: review,
                        decision: decision,
                        workspace: workspace,
                        task: &task,
                        missionState: &missionState,
                        toolState: &toolState,
                        iteration: iteration
                    )
                    return .policyViolation
                }
            }

            missionState = try transition(from: missionState, to: .waitingHuman)
            toolState = .pendingApproval
            updateTaskState(&task, to: .pendingApproval)
            try await persistence.saveTask(task)
            let review = decision.toolRequest.map {
                governanceReview(
                    toolCall: $0,
                    output: output,
                    workspace: workspace,
                    context: context,
                    worldModel: worldModel
                )
            }
            try await enqueueApproval(
                decision: decision,
                workspace: workspace,
                task: task,
                iteration: iteration,
                riskAssessment: review?.riskAssessment,
                policyEvaluation: review?.policyEvaluation
            )
            return .waitingHuman
        }

        if decision.actionType == .executeTool, let toolRequest = decision.toolRequest {
            let review = governanceReview(
                toolCall: toolRequest,
                output: output,
                workspace: workspace,
                context: context,
                worldModel: worldModel
            )

            switch review.policyEvaluation.status {
            case .approvalRequired:
                missionState = try transition(from: missionState, to: .waitingHuman)
                toolState = .pendingApproval
                updateTaskState(&task, to: .pendingApproval)
                try await persistence.saveTask(task)
                let approvalDecision = AgentDecision(
                    nextState: .waitingHuman,
                    actionType: .requestHumanApproval,
                    taskUpdate: decision.taskUpdate,
                    toolRequest: toolRequest,
                    reasoningSummary: review.policyEvaluation.summary,
                    confidence: decision.confidence,
                    requiresHumanApproval: true,
                    completionSignal: false
                )
                try await enqueueApproval(
                    decision: approvalDecision,
                    workspace: workspace,
                    task: task,
                    iteration: iteration,
                    riskAssessment: review.riskAssessment,
                    policyEvaluation: review.policyEvaluation
                )
                return .waitingHuman
            case .denied:
                try await recordGovernanceDenied(
                    review: review,
                    decision: decision,
                    workspace: workspace,
                    task: &task,
                    missionState: &missionState,
                    toolState: &toolState,
                    iteration: iteration
                )
                return .policyViolation
            case .allowed:
                break
            }

            try await executeTool(
                toolRequest,
                output: output,
                workspace: workspace,
                task: &task,
                missionState: &missionState,
                toolState: &toolState,
                worldModel: &worldModel,
                previousObservations: &previousObservations,
                executedStepIDs: &executedStepIDs,
                iteration: iteration
            )
            return nil
        }

        if decision.actionType == .replan || decision.nextState == .adapt {
            missionState = try transition(from: missionState, to: decision.nextState)
            try await recordLoopEvent(
                type: .planGenerated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Autonomous plan adapted",
                stage: .adaptation,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: decision.auditPayload
            )
            return nil
        }

        missionState = try transition(from: missionState, to: decision.nextState)
        if missionState == .plan {
            updateTaskState(&task, to: .planned)
            try await persistence.saveTask(task)
            try await recordLoopEvent(
                type: .planGenerated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Autonomous plan prepared",
                stage: .planning,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: decision.auditPayload
            )
        } else {
            try await recordLoopEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Agent loop advanced to \(missionState.rawValue)",
                stage: loopStage(for: missionState),
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: decision.auditPayload
            )
        }
        return nil
    }

    private func executeTool(
        _ toolRequest: ToolCall,
        output: StructuredAgentOutput,
        workspace: Workspace,
        task: inout FDETask,
        missionState: inout MissionState,
        toolState: inout ToolExecutionState,
        worldModel: inout SystemWorldModel,
        previousObservations: inout [ToolObservation],
        executedStepIDs: inout Set<String>,
        iteration: Int
    ) async throws {
        guard let step = output.plan.first(where: { $0.toolCallID == toolRequest.id }) else {
            return
        }

        missionState = try transition(from: missionState, to: .execute)
        toolState = .running
        updateTaskState(&task, to: .running)
        try await persistence.saveTask(task)
        try await recordLoopEvent(
            type: .toolCalled,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "\(toolRequest.type.rawValue): \(toolRequest.command)",
            stage: .execution,
            missionState: missionState,
            taskState: task.state,
            toolState: toolState,
            iteration: iteration,
            payload: [
                "step_id": step.id,
                "tool_call_id": toolRequest.id,
                "command": toolRequest.command,
                "arguments": safeArguments(toolRequest.arguments),
                "working_directory": toolRequest.workingDirectory ?? ""
            ]
        )

        do {
            let result = try await toolExecutor.execute(toolRequest)
            let observation = observationLoop.observeResult(
                step: step,
                toolCall: toolRequest,
                result: result,
                attempt: 1,
                maxAttempts: 1
            )
            previousObservations.append(observation)
            worldModel = systemUnderstandingLayer.applying(observation, to: worldModel)
            toolState = observation.outcome == .succeeded ? .succeeded : .failed
            missionState = try transition(from: missionState, to: .observe)
            if observation.outcome == .succeeded {
                executedStepIDs.insert(step.id)
            }
            try await recordLoopEvent(
                type: .stepExecuted,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: step.title,
                stage: .observation,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: [
                    "step_id": step.id,
                    "tool_call_id": toolRequest.id,
                    "command": toolRequest.command,
                    "exit_code": String(result.exitCode)
                ].merging(observation.auditPayload) { current, _ in current }
                    .merging(worldModel.auditPayload) { current, _ in current }
            )
        } catch {
            let observation = observationLoop.observeFailure(
                step: step,
                toolCall: toolRequest,
                error: error,
                attempt: 1,
                maxAttempts: 1
            )
            previousObservations.append(observation)
            worldModel = systemUnderstandingLayer.applying(observation, to: worldModel)
            toolState = .failed
            missionState = try transition(from: missionState, to: .observe)
            try await recordLoopEvent(
                type: .toolFailed,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "\(toolRequest.id) failed: \(error.localizedDescription)",
                stage: .observation,
                missionState: missionState,
                taskState: task.state,
                toolState: toolState,
                iteration: iteration,
                payload: [
                    "step_id": step.id,
                    "tool_call_id": toolRequest.id,
                    "command": toolRequest.command,
                    "error": error.localizedDescription
                ].merging(observation.auditPayload) { current, _ in current }
                    .merging(worldModel.auditPayload) { current, _ in current }
            )
        }
    }

    private func enqueueApproval(
        decision: AgentDecision,
        workspace: Workspace,
        task: FDETask,
        iteration: Int,
        riskAssessment: RiskAssessment? = nil,
        policyEvaluation: PolicyEvaluation? = nil
    ) async throws {
        let request = ApprovalRequest(
            id: UUID(),
            workspaceID: workspace.id,
            taskID: task.id,
            stepID: decision.taskUpdate?.plan?.first { $0.toolCallID == decision.toolRequest?.id }?.id,
            toolCallID: decision.toolRequest?.id,
            targetKind: decision.toolRequest?.type == .connector ? .connectorOperation : .toolCall,
            action: "execute autonomous tool",
            resource: decision.toolRequest?.command ?? "autonomous mission",
            riskLevel: riskAssessment?.level ?? .high,
            state: .pending,
            requestedByRole: workspace.role,
            decidedByRole: nil,
            decisionReason: nil,
            requestedAt: Date(),
            decidedAt: nil,
            expiresAt: Date().addingTimeInterval(15 * 60),
            metadata: [
                "agent_loop_iteration": String(iteration),
                "agent_decision_summary": decision.reasoningSummary,
                "mission_state": MissionState.waitingHuman.rawValue,
                "task_state": TaskState.pendingApproval.rawValue,
                "tool_state": ToolExecutionState.pendingApproval.rawValue
            ].merging(riskAssessment?.auditPayload ?? [:]) { current, _ in current }
                .merging(policyEvaluation?.auditPayload ?? [:]) { current, _ in current }
        )
        _ = try await approvalQueue.enqueue(request)
        try await recordLoopEvent(
            type: .humanApprovalRequested,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Autonomous loop paused for human approval",
            stage: .decision,
            missionState: .waitingHuman,
            taskState: task.state,
            toolState: .pendingApproval,
            iteration: iteration,
            payload: [
                "approval_request_id": request.id.uuidString,
                "agent_loop_stop_reason": AgentLoopStopReason.waitingHuman.rawValue
            ].merging(decision.auditPayload) { current, _ in current }
                .merging(riskAssessment?.auditPayload ?? [:]) { current, _ in current }
                .merging(policyEvaluation?.auditPayload ?? [:]) { current, _ in current }
        )
    }

    private func governanceReview(
        toolCall: ToolCall,
        output: StructuredAgentOutput,
        workspace: Workspace,
        context: ExecutionContext,
        worldModel: SystemWorldModel
    ) -> AgentToolGovernanceReview {
        let step = output.plan.first { $0.toolCallID == toolCall.id }
            ?? PlanStep(
                id: "policy.\(toolCall.id)",
                title: toolCall.command,
                intent: "Review \(toolCall.command)",
                toolCallID: toolCall.id,
                requiresApproval: toolCall.requiresApproval
            )
        let riskAssessment = riskAssessmentEngine.assess(
            step: step,
            toolCall: toolCall,
            workspace: workspace,
            globalPolicy: context.globalExecutionPolicy,
            systemFailureProfile: context.systemFailureProfile,
            policyDeltas: context.policyDeltas,
            plannerRisks: output.risks
        )
        let permissionDecision = permissionDecision(for: toolCall, workspace: workspace, worldModel: worldModel)
        let policyEvaluation = policyEngine.evaluate(
            PolicyInput(workspace: workspace, toolCall: toolCall, risk: riskAssessment),
            permissionDecision: permissionDecision,
            globallyAvoided: violatesPolicy(toolCall, context: context)
        )
        return AgentToolGovernanceReview(
            step: step,
            riskAssessment: riskAssessment,
            permissionDecision: permissionDecision,
            policyEvaluation: policyEvaluation
        )
    }

    private func recordGovernanceDenied(
        review: AgentToolGovernanceReview,
        decision: AgentDecision,
        workspace: Workspace,
        task: inout FDETask,
        missionState: inout MissionState,
        toolState: inout ToolExecutionState,
        iteration: Int
    ) async throws {
        missionState = try transition(from: missionState, to: .blocked)
        toolState = .failed
        updateTaskState(&task, to: .failed)
        try await persistence.saveTask(task)
        try await recordLoopEvent(
            type: .authorizationDenied,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Policy blocked autonomous tool request",
            stage: .decision,
            missionState: missionState,
            taskState: task.state,
            toolState: toolState,
            iteration: iteration,
            payload: [
                "agent_loop_stop_reason": AgentLoopStopReason.policyViolation.rawValue,
                "step_id": review.step.id,
                "tool_call_id": review.step.toolCallID ?? "",
                "command": review.policyEvaluation.input.action,
                "risk_level": review.riskAssessment.level.rawValue,
                "risk_reasons": review.riskAssessment.reasons.joined(separator: " | "),
                "permission_decision": permissionDecisionSummary(review.permissionDecision),
                "permission_denial": permissionDenialReason(review.permissionDecision),
                "reason": review.policyEvaluation.summary
            ].merging(decision.auditPayload) { current, _ in current }
                .merging(review.riskAssessment.auditPayload) { current, _ in current }
                .merging(review.policyEvaluation.auditPayload) { current, _ in current }
        )
    }

    private func recordOutcomeIfTerminal(
        stopReason: AgentLoopStopReason,
        workspaceID: UUID,
        taskID: UUID,
        objective: String,
        finalState: MissionState,
        completionSignal: Bool,
        observations: [ToolObservation],
        activeToolCalls: [ToolCall],
        confidence: Double,
        events: [ExecutionEvent],
        worldModel: SystemWorldModel,
        task: FDETask
    ) async -> OutcomeRecord? {
        switch stopReason {
        case .complete, .policyViolation, .failed, .maxIterationsReached:
            return await storeMissionOutcome(
                workspaceID: workspaceID,
                taskID: taskID,
                objective: objective,
                finalState: finalState,
                completionSignal: completionSignal,
                observations: observations,
                activeToolCalls: activeToolCalls,
                confidence: confidence,
                events: events,
                worldModel: worldModel,
                task: task
            )
        case .waitingHuman, .missingCriticalInformation:
            return nil
        }
    }

    private func storeMissionOutcome(
        workspaceID: UUID,
        taskID: UUID,
        objective: String,
        finalState: MissionState,
        completionSignal: Bool,
        observations: [ToolObservation],
        activeToolCalls: [ToolCall],
        confidence: Double,
        events: [ExecutionEvent],
        worldModel: SystemWorldModel,
        task: FDETask
    ) async -> OutcomeRecord {
        let outcomeLayer = OutcomeTrackingLayer()
        let outcomeRecord = outcomeLayer.record(
            missionID: taskID,
            objective: objective,
            finalState: finalState,
            events: events,
            observations: observations,
            worldModel: worldModel,
            task: task
        )
        let feedback = outcomeLayer.memoryFeedback(from: outcomeRecord)
        await memoryProvider.storeMissionOutcome(
            AgentMissionOutcome(
                workspaceID: workspaceID,
                taskID: taskID,
                finalState: finalState,
                completionSignal: completionSignal,
                failurePatterns: uniqueOutcomeValues(
                    observations
                        .filter { $0.outcome == .failed }
                        .map(\.summary)
                        + feedback.failurePatterns
                ),
                successfulActions: uniqueOutcomeValues(activeToolCalls.map(\.command) + feedback.successfulSolutions),
                customerEnvironmentKnowledge: feedback.customerEnvironmentKnowledge,
                outcomeRecord: outcomeRecord,
                confidence: confidence,
                summary: outcomeRecord.achievedOutcome,
                completedAt: outcomeRecord.createdAt
            )
        )
        await storeQualityLearning(
            outcomeRecord: outcomeRecord,
            workspaceID: workspaceID,
            taskID: taskID,
            task: task,
            events: events,
            observations: observations
        )
        return outcomeRecord
    }

    private func storeQualityLearning(
        outcomeRecord: OutcomeRecord,
        workspaceID: UUID,
        taskID: UUID,
        task: FDETask,
        events: [ExecutionEvent],
        observations: [ToolObservation]
    ) async {
        let approvals = (try? await persistence.loadApprovalRequests(workspaceID: workspaceID, state: nil))?
            .filter { $0.taskID == taskID } ?? []
        let replay = MissionReplayBuilder().reconstruct(
            task: task,
            events: events,
            approvals: approvals,
            outcome: outcomeRecord
        )
        let evaluation = agentQualityEvaluator.evaluate(
            replay: replay,
            outcome: outcomeRecord,
            events: events,
            task: task
        )
        let errors = uniqueOutcomeValues(
            observations.filter { $0.outcome == .failed }.map(\.summary)
                + events
                .filter { [.toolFailed, .connectorFailed, .authorizationDenied, .humanRejected, .userApprovalRejected].contains($0.type) }
                .map(\.summary)
        )
        let humanDecisions = approvals
            .filter { $0.state != .pending }
            .map { "\($0.state.rawValue): \($0.action) \($0.decisionReason ?? "")" }
        let reflection = agentQualityEvaluator.reflect(
            replay: replay,
            outcome: outcomeRecord,
            evidence: outcomeRecord.evidence,
            errors: errors,
            humanDecisions: humanDecisions,
            evaluation: evaluation
        )
        let update = memoryImprovementPipeline.update(
            replay: replay,
            outcome: outcomeRecord,
            evaluation: evaluation,
            reflection: reflection,
            task: task,
            events: events
        )
        try? await persistence.saveFeedback(memoryImprovementPipeline.reflectionFeedback(reflection))
        try? await memoryImprovementPipeline.store(
            update,
            persistence: persistence,
            enterpriseMemoryStore: enterpriseMemoryStore,
            saveTaskExecutionMemory: true
        )
    }

    private func uniqueOutcomeValues(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let safeValue = AgentPresentationSanitizer.safeContent(value, fallback: "")
            guard !safeValue.isEmpty, !seen.contains(safeValue) else { continue }
            seen.insert(safeValue)
            result.append(safeValue)
        }
        return result
    }

    private func completionEvidenceValidation(
        observations: [ToolObservation],
        executedStepIDs: Set<String>
    ) -> MissionCompletionEvidenceValidation {
        let successfulObservationCount = observations.filter { $0.outcome == .succeeded }.count
        let successfulToolResultCount = recordedEvents.filter { event in
            event.type == .stepExecuted
                && event.payload["tool_call_id"]?.isEmpty == false
                && event.payload["exit_code"] == "0"
        }.count
        return MissionCompletionEvidenceValidation(
            successfulObservationCount: successfulObservationCount,
            successfulToolResultCount: successfulToolResultCount,
            executedStepCount: executedStepIDs.count,
            latestObservationSucceeded: observations.last?.outcome == .succeeded
        )
    }

    private func nextExecutableTool(
        plan: [PlanStep],
        toolCalls: [ToolCall],
        executedStepIDs: Set<String>
    ) -> ToolCall? {
        for step in plan where !executedStepIDs.contains(step.id) {
            guard let toolCallID = step.toolCallID,
                  let tool = toolCalls.first(where: { $0.id == toolCallID }) else {
                continue
            }
            return tool
        }
        return nil
    }

    private func approvalDecision(
        output: StructuredAgentOutput,
        tool: ToolCall?,
        summary: String
    ) -> AgentDecision {
        AgentDecision(
            nextState: .waitingHuman,
            actionType: .requestHumanApproval,
            taskUpdate: AgentTaskUpdate(title: nil, state: .pendingApproval, plan: output.plan),
            toolRequest: tool,
            reasoningSummary: summary,
            confidence: output.confidence,
            requiresHumanApproval: true,
            completionSignal: false
        )
    }

    private func completionDecision(
        output: StructuredAgentOutput,
        summary: String
    ) -> AgentDecision {
        AgentDecision(
            nextState: .complete,
            actionType: .continueMission,
            taskUpdate: AgentTaskUpdate(title: nil, state: nil, plan: output.plan),
            toolRequest: nil,
            reasoningSummary: summary,
            confidence: output.confidence,
            requiresHumanApproval: false,
            completionSignal: true
        )
    }

    private func decisionSummary(output: StructuredAgentOutput, state: MissionState) -> String {
        let candidate = output.actions.first?.title
            ?? output.plan.first?.intent
            ?? output.risks.first?.mitigation
            ?? "Continue autonomous mission from \(state.rawValue)."
        let safe = AgentPresentationSanitizer.safeContent(
            candidate,
            fallback: "Continue autonomous mission from \(state.rawValue)."
        )
        if AgentPresentationSanitizer.containsRestrictedContent(safe) {
            return "Continue autonomous mission from \(state.rawValue)."
        }
        return safe
    }

    private func permissionDecision(
        for toolCall: ToolCall,
        workspace: Workspace,
        worldModel: SystemWorldModel
    ) -> PermissionDecision {
        guard let permissionGraph = worldModel.permissionGraph,
              let target = permissionTarget(for: toolCall, workspace: workspace) else {
            return .allowed
        }
        return permissionGraph.decision(
            for: PermissionCheckRequest(
                user: target.user,
                role: target.role,
                system: target.system,
                action: target.action
            )
        )
    }

    private func permissionDecisionSummary(_ decision: PermissionDecision) -> String {
        switch decision {
        case .allowed:
            return "allowed"
        case .approvalRequired(let reason):
            return "approval_required:\(reason)"
        case .denied(let reason):
            return "denied:\(reason)"
        }
    }

    private func permissionDenialReason(_ decision: PermissionDecision) -> String {
        guard case .denied(let reason) = decision else { return "" }
        return reason
    }

    private func permissionTarget(
        for toolCall: ToolCall,
        workspace: Workspace
    ) -> (user: String, role: String, system: String, action: String)? {
        let command = toolCall.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }

        if toolCall.type == .connector {
            let parts = command
                .lowercased()
                .split(separator: ".")
                .map(String.init)
            let connectorParts = parts.first == "connector" ? Array(parts.dropFirst()) : parts
            guard let system = connectorParts.first else {
                return nil
            }
            let action = connectorParts.dropFirst().joined(separator: ".")
            return (
                user: "\(system)-service-account",
                role: "connector_service",
                system: system,
                action: action.isEmpty ? command : action
            )
        }

        if command.hasPrefix("/") {
            return (
                user: "workspace:\(workspace.id.uuidString)",
                role: workspace.role.rawValue,
                system: "local_shell",
                action: (command as NSString).lastPathComponent
            )
        }

        let parts = command
            .lowercased()
            .split(separator: ".")
            .map(String.init)
        guard let system = parts.first else {
            return nil
        }
        let action = parts.dropFirst().joined(separator: ".")
        return (
            user: "workspace:\(workspace.id.uuidString)",
            role: workspace.role.rawValue,
            system: system,
            action: action.isEmpty ? command : action
        )
    }

    private func violatesPolicy(_ toolCall: ToolCall, context: ExecutionContext) -> Bool {
        let avoided = Set(
            context.policyDeltas.compactMap(\.avoidToolCommand)
                + (context.globalExecutionPolicy?.avoidedToolCommands ?? [])
                + (context.contextBundle?.policySummary.avoidedTools ?? [])
        )
        return avoided.contains(toolCall.command)
    }

    private func policyConstraints(from context: ExecutionContext) -> [String] {
        var constraints = context.policyRules
        constraints += context.policyDeltas.map(\.summary)
        if let globalPolicy = context.globalExecutionPolicy {
            constraints.append(globalPolicy.summary)
        }
        constraints += context.contextBundle?.policySummary.avoidedTools.map { "avoid:\($0)" } ?? []
        return constraints
    }

    private func transition(from current: MissionState, to next: MissionState) throws -> MissionState {
        try missionStateMachine.transition(from: current, to: next)
    }

    private func updateTaskState(_ task: inout FDETask, to nextState: TaskState) {
        guard task.state != nextState else { return }
        do {
            try workflowStateMachine.transition(&task, to: nextState)
        } catch {
            task.state = nextState
            task.updatedAt = Date()
        }
    }

    private func fallbackWorldModel(workspace: Workspace, context: ExecutionContext) -> SystemWorldModel {
        SystemWorldModel(
            workspaceID: workspace.id,
            customerContext: "\(workspace.displayName) role=\(workspace.role.rawValue)",
            connectedSystems: context.contextBundle?.graphSummary.detectedSystems ?? [],
            permissions: ["role:\(workspace.role.rawValue)"],
            previousFailures: context.failurePatterns.map { "\($0.command):\($0.count)" },
            environmentFacts: ["task_fingerprint:\(context.taskFingerprint)"],
            observations: []
        )
    }

    private func fallbackOutcomeWorldModel(workspace: Workspace) -> SystemWorldModel {
        SystemWorldModel(
            workspaceID: workspace.id,
            customerContext: "\(workspace.displayName) role=\(workspace.role.rawValue)",
            connectedSystems: [],
            permissions: ["role:\(workspace.role.rawValue)"],
            previousFailures: [],
            environmentFacts: ["workspace:\(workspace.displayName)"],
            observations: []
        )
    }

    private func loopStage(for state: MissionState) -> AgentLoopTraceStage {
        switch state {
        case .idle, .understand:
            return .understanding
        case .plan, .ready:
            return .planning
        case .execute:
            return .execution
        case .observe, .verifying:
            return .observation
        case .adapt:
            return .adaptation
        case .waitingHuman, .blocked, .failed:
            return .decision
        case .complete:
            return .completion
        }
    }

    @discardableResult
    private func recordLoopEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        stage: AgentLoopTraceStage,
        missionState: MissionState,
        taskState: TaskState?,
        toolState: ToolExecutionState,
        iteration: Int,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        if !sequenceInitialized {
            sequence = try await persistence.loadMaxEventSequence()
            sequenceInitialized = true
        }

        let nextSequence = sequence + 1
        let parentEventID: UUID? = if let taskID {
            lastEventIDByTask[taskID]
        } else {
            lastEventIDByWorkspace[workspaceID]
        }
        let eventID = UUID()
        var enrichedPayload = payload
        enrichedPayload["event_id"] = eventID.uuidString
        enrichedPayload["parent_event_id"] = parentEventID?.uuidString ?? ""
        enrichedPayload["agent_loop_controller"] = "true"
        enrichedPayload["agent_loop_iteration"] = String(iteration)
        enrichedPayload["agent_loop_stage"] = stage.rawValue
        enrichedPayload = RuntimeStateSnapshot(
            missionState: missionState,
            taskState: taskState,
            toolState: toolState
        ).auditPayload.merging(enrichedPayload) { _, next in next }

        let event = ExecutionEvent(
            id: eventID,
            parentEventID: parentEventID,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: nextSequence,
            timestamp: Date(),
            summary: AgentPresentationSanitizer.safeContent(summary, fallback: type.rawValue),
            payload: enrichedPayload,
            metadata: EventMetadata(
                workspaceID: workspaceID,
                correlationID: taskID?.uuidString ?? workspaceID.uuidString
            )
        )
        try await persistence.appendEvent(event)
        sequence = nextSequence
        if let taskID {
            lastEventIDByTask[taskID] = event.id
        }
        lastEventIDByWorkspace[workspaceID] = event.id
        eventStream.persist(event)
        eventStream.publish(event)
        recordedEvents.append(event)
        return event
    }

    private func safeArguments(_ arguments: [String]) -> String {
        let joined = arguments.joined(separator: " ")
        let safe = AgentPresentationSanitizer.safeContent(joined, fallback: "")
        guard !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return ""
        }
        return safe
    }

    private func makeTitle(from input: String) -> String {
        let collapsed = input
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if collapsed.count <= 72 {
            return collapsed
        }
        return String(collapsed.prefix(69)) + "..."
    }
}

enum AgentLoopTraceStage: String, Codable, Hashable, Sendable {
    case understanding = "UNDERSTANDING"
    case planning = "PLANNING"
    case decision = "DECISION"
    case execution = "EXECUTION"
    case observation = "OBSERVATION"
    case adaptation = "ADAPTATION"
    case completion = "COMPLETION"
}

private struct AgentToolGovernanceReview: Sendable {
    var step: PlanStep
    var riskAssessment: RiskAssessment
    var permissionDecision: PermissionDecision
    var policyEvaluation: PolicyEvaluation
}

private extension Array {
    func suffixArray(_ maxCount: Int) -> [Element] {
        Array(suffix(maxCount))
    }
}
