import Foundation

enum MissionState: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case idle = "IDLE"
    case understand = "UNDERSTAND"
    case plan = "PLAN"
    case ready = "READY"
    case execute = "EXECUTE"
    case observe = "OBSERVE"
    case verifying = "VERIFYING"
    case adapt = "ADAPT"
    case waitingHuman = "WAITING_HUMAN"
    case blocked = "BLOCKED"
    case failed = "FAILED"
    case complete = "COMPLETE"

    var id: String { rawValue }
}

enum MissionStateError: LocalizedError, Equatable {
    case invalidTransition(MissionState, MissionState)

    var errorDescription: String? {
        switch self {
        case .invalidTransition(let from, let to):
            return "Invalid mission transition from \(from.rawValue) to \(to.rawValue)."
        }
    }
}

struct MissionStateMachine: Sendable {
    func transition(from current: MissionState, to next: MissionState) throws -> MissionState {
        guard isAllowed(from: current, to: next) else {
            throw MissionStateError.invalidTransition(current, next)
        }
        return next
    }

    func allowedNextStates(from current: MissionState) -> [MissionState] {
        MissionState.allCases.filter { isAllowed(from: current, to: $0) }
    }

    func transitionGraph() -> [MissionState: [MissionState]] {
        Dictionary(uniqueKeysWithValues: MissionState.allCases.map { state in
            (state, allowedNextStates(from: state))
        })
    }

    private func isAllowed(from current: MissionState, to next: MissionState) -> Bool {
        switch (current, next) {
        case (.idle, .understand),
             (.understand, .plan),
             (.understand, .waitingHuman),
             (.understand, .failed),
             (.plan, .ready),
             (.plan, .waitingHuman),
             (.plan, .blocked),
             (.plan, .failed),
             (.ready, .plan),
             (.ready, .execute),
             (.ready, .waitingHuman),
             (.ready, .blocked),
             (.ready, .failed),
             (.execute, .observe),
             (.execute, .waitingHuman),
             (.execute, .blocked),
             (.execute, .failed),
             (.observe, .adapt),
             (.observe, .execute),
             (.observe, .verifying),
             (.observe, .waitingHuman),
             (.observe, .blocked),
             (.observe, .failed),
             (.adapt, .plan),
             (.adapt, .ready),
             (.adapt, .execute),
             (.adapt, .waitingHuman),
             (.adapt, .blocked),
             (.adapt, .failed),
             (.verifying, .execute),
             (.verifying, .adapt),
             (.verifying, .waitingHuman),
             (.verifying, .blocked),
             (.verifying, .failed),
             (.verifying, .complete),
             (.waitingHuman, .plan),
             (.waitingHuman, .ready),
             (.waitingHuman, .execute),
             (.waitingHuman, .adapt),
             (.waitingHuman, .blocked),
             (.waitingHuman, .failed),
             (.blocked, .plan),
             (.blocked, .ready),
             (.blocked, .execute),
             (.blocked, .adapt),
             (.blocked, .waitingHuman),
             (.blocked, .failed),
             (_, _) where current == next:
            return true
        default:
            return false
        }
    }
}

enum ToolExecutionState: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case idle = "IDLE"
    case pendingApproval = "PENDING_APPROVAL"
    case authorized = "AUTHORIZED"
    case running = "RUNNING"
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"
    case skipped = "SKIPPED"

    var id: String { rawValue }
}

struct RuntimeStateSnapshot: Codable, Hashable, Sendable {
    var missionState: MissionState
    var taskState: TaskState?
    var toolState: ToolExecutionState

    init(
        missionState: MissionState,
        taskState: TaskState? = nil,
        toolState: ToolExecutionState = .idle
    ) {
        self.missionState = missionState
        self.taskState = taskState
        self.toolState = toolState
    }

    var auditPayload: [String: String] {
        [
            "mission_state": missionState.rawValue,
            "task_state": taskState?.rawValue ?? "",
            "tool_state": toolState.rawValue
        ]
    }
}

enum AgentRuntimeAction: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case answerCapability = "ANSWER_CAPABILITY"
    case askClarification = "ASK_CLARIFICATION"
    case submitTask = "SUBMIT_TASK"
    case executeTool = "EXECUTE_TOOL"
    case continueMission = "CONTINUE_MISSION"
    case replan = "REPLAN"
    case requestHumanApproval = "REQUEST_HUMAN_APPROVAL"
    case requestPause = "REQUEST_PAUSE"
    case resumeTask = "RESUME_TASK"
    case changeApproach = "CHANGE_APPROACH"
    case stopTask = "STOP_TASK"
    case acknowledgeInstruction = "ACKNOWLEDGE_INSTRUCTION"

    var id: String { rawValue }
}

struct AgentRuntimeDecision: Codable, Hashable, Sendable {
    var shouldAct: Bool
    var nextAction: AgentRuntimeAction
    var requiresHumanApproval: Bool
    var reason: String
    var state: RuntimeStateSnapshot

    var auditPayload: [String: String] {
        var payload = state.auditPayload
        payload["decision_should_act"] = shouldAct ? "true" : "false"
        payload["decision_next_action"] = nextAction.rawValue
        payload["decision_requires_human_approval"] = requiresHumanApproval ? "true" : "false"
        payload["decision_reason"] = reason
        return payload
    }
}

struct AgentDecisionEngine: Sendable {
    private let stateMachine: MissionStateMachine

    init(stateMachine: MissionStateMachine = MissionStateMachine()) {
        self.stateMachine = stateMachine
    }

    func decideNewMission(
        intent: MissionIntent,
        isCapabilityQuestion: Bool,
        needsClarification: Bool
    ) -> AgentRuntimeDecision {
        if isCapabilityQuestion {
            return AgentRuntimeDecision(
                shouldAct: false,
                nextAction: .answerCapability,
                requiresHumanApproval: false,
                reason: "User asked for capabilities instead of a concrete mission.",
                state: RuntimeStateSnapshot(missionState: transition(from: .understand, to: .waitingHuman))
            )
        }

        if needsClarification {
            return AgentRuntimeDecision(
                shouldAct: false,
                nextAction: .askClarification,
                requiresHumanApproval: false,
                reason: intent.missingInformation.isEmpty
                    ? "Mission is not concrete enough to execute autonomously."
                    : "Mission is missing \(intent.missingInformation.joined(separator: ", ")).",
                state: RuntimeStateSnapshot(missionState: transition(from: .understand, to: .waitingHuman))
            )
        }

        return AgentRuntimeDecision(
            shouldAct: true,
            nextAction: .submitTask,
            requiresHumanApproval: missionRequiresHumanApproval(intent),
            reason: "Mission is concrete enough to plan and execute.",
            state: RuntimeStateSnapshot(missionState: transition(from: .understand, to: .plan))
        )
    }

    func decideDirectChat(intent: MissionIntent) -> AgentRuntimeDecision {
        AgentRuntimeDecision(
            shouldAct: false,
            nextAction: .acknowledgeInstruction,
            requiresHumanApproval: false,
            reason: "User message can be answered in chat without starting workspace execution.",
            state: RuntimeStateSnapshot(missionState: transition(from: .understand, to: .waitingHuman))
        )
    }

    func decideMissionReply(
        reply: String,
        intent: MissionIntent,
        hasRuntimeTask: Bool,
        wasWaitingForRuntime: Bool,
        isCapabilityQuestion: Bool,
        needsClarification: Bool
    ) -> AgentRuntimeDecision {
        if !hasRuntimeTask {
            return decideNewMission(
                intent: intent,
                isCapabilityQuestion: isCapabilityQuestion,
                needsClarification: needsClarification
            )
        }

        if shouldStopMission(reply) {
            return AgentRuntimeDecision(
                shouldAct: true,
                nextAction: .stopTask,
                requiresHumanApproval: false,
                reason: "User requested mission cancellation.",
                state: RuntimeStateSnapshot(
                    missionState: transition(from: .waitingHuman, to: .failed),
                    taskState: .failed,
                    toolState: .skipped
                )
            )
        }

        if shouldChangeApproach(reply) {
            return AgentRuntimeDecision(
                shouldAct: true,
                nextAction: .changeApproach,
                requiresHumanApproval: false,
                reason: "User supplied an adaptation instruction for the active mission.",
                state: RuntimeStateSnapshot(missionState: transition(from: .observe, to: .adapt), taskState: .running)
            )
        }

        if wasWaitingForRuntime {
            return AgentRuntimeDecision(
                shouldAct: true,
                nextAction: .resumeTask,
                requiresHumanApproval: false,
                reason: "Runtime is waiting at a checkpoint and can resume with user input.",
                state: RuntimeStateSnapshot(missionState: transition(from: .waitingHuman, to: .execute), taskState: .running)
            )
        }

        if shouldPauseMission(reply) {
            return AgentRuntimeDecision(
                shouldAct: true,
                nextAction: .requestPause,
                requiresHumanApproval: false,
                reason: "User requested a pause at the next safe checkpoint.",
                state: RuntimeStateSnapshot(missionState: transition(from: .execute, to: .waitingHuman), taskState: .waiting)
            )
        }

        return AgentRuntimeDecision(
            shouldAct: false,
            nextAction: .acknowledgeInstruction,
            requiresHumanApproval: false,
            reason: "Instruction was recorded for the active mission context.",
            state: RuntimeStateSnapshot(missionState: transition(from: .execute, to: .observe), taskState: .running)
        )
    }

    func decideToolExecution(
        step: PlanStep,
        toolCall: ToolCall,
        risk: RiskClassification
    ) -> AgentRuntimeDecision {
        if risk.requiresApproval {
            return AgentRuntimeDecision(
                shouldAct: false,
                nextAction: .requestHumanApproval,
                requiresHumanApproval: true,
                reason: risk.reasons.joined(separator: " | "),
                state: RuntimeStateSnapshot(
                    missionState: transition(from: .execute, to: .waitingHuman),
                    taskState: .pendingApproval,
                    toolState: .pendingApproval
                )
            )
        }

        return AgentRuntimeDecision(
            shouldAct: true,
            nextAction: .executeTool,
            requiresHumanApproval: step.requiresApproval || toolCall.requiresApproval,
            reason: "Tool risk accepted for autonomous execution.",
            state: RuntimeStateSnapshot(
                missionState: transition(from: .ready, to: .execute),
                taskState: .running,
                toolState: .authorized
            )
        )
    }

    func shouldChangeApproach(_ reply: String) -> Bool {
        let normalized = reply.lowercased()
        return normalized.contains("change approach")
            || normalized.contains("ignore this connector")
            || normalized.contains("ignore connector")
            || normalized.contains("use another strategy")
            || normalized.contains("换个方式")
            || normalized.contains("改变策略")
            || normalized.contains("跳过")
    }

    func shouldPauseMission(_ reply: String) -> Bool {
        let normalized = reply.lowercased()
        return normalized == "pause"
            || normalized.contains("wait")
            || normalized.contains("hold on")
            || normalized.contains("先停")
            || normalized.contains("暂停")
    }

    func shouldStopMission(_ reply: String) -> Bool {
        let normalized = reply.lowercased()
        return normalized == "stop"
            || normalized == "cancel"
            || normalized.contains("停止任务")
            || normalized.contains("取消任务")
    }

    private func missionRequiresHumanApproval(_ intent: MissionIntent) -> Bool {
        intent.constraints.contains(.requiresApproval)
            || intent.intentType == .modifyCode
            || intent.intentType == .createFeature
            || intent.intentType == .refactorCode
    }

    private func transition(from current: MissionState, to next: MissionState) -> MissionState {
        (try? stateMachine.transition(from: current, to: next)) ?? current
    }
}

enum AgentWorkTraceStage: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case understanding = "understanding"
    case planning = "planning"
    case execution = "execution"
    case observation = "observation"
    case adaptation = "adaptation"
    case completion = "completion"

    var id: String { rawValue }
}

struct AgentWorkTrace: Codable, Hashable, Sendable {
    var stage: AgentWorkTraceStage
    var summary: String
    var detail: String

    var auditPayload: [String: String] {
        [
            "agent_work_trace": "true",
            "agent_work_trace_stage": stage.rawValue,
            "agent_work_trace_summary": AgentPresentationSanitizer.safeContent(summary, fallback: stage.rawValue),
            "agent_work_trace_detail": AgentPresentationSanitizer.safeContent(detail, fallback: "")
        ]
    }
}

struct SystemWorldModel: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var customerContext: String
    var connectedSystems: [String]
    var permissions: [String]
    var previousFailures: [String]
    var environmentFacts: [String]
    var observations: [String]
    var evidence: [String] = []
    var permissionGraph: PermissionGraph? = nil

    var auditPayload: [String: String] {
        [
            "world_model_customer_context": AgentPresentationSanitizer.safeContent(customerContext, fallback: ""),
            "world_model_connected_systems": connectedSystems.prefix(8).joined(separator: " | "),
            "world_model_permissions": permissions.prefix(8).joined(separator: " | "),
            "world_model_previous_failures": previousFailures.prefix(8).joined(separator: " | "),
            "world_model_environment_facts": environmentFacts.prefix(8).joined(separator: " | "),
            "world_model_observations": observations.suffix(6).joined(separator: " | "),
            "world_model_evidence": evidence.suffix(8).joined(separator: " | ")
        ]
    }
}

struct SystemUnderstandingLayer: Sendable {
    func initialModel(
        workspace: Workspace,
        context: ExecutionContext,
        recentTasks: [FDETask],
        workspaceEvents: [ExecutionEvent],
        policyDeltas: [ExecutionPolicyDelta],
        systemFailureProfile: SystemFailureProfile?,
        globalExecutionPolicy: GlobalExecutionPolicy?
    ) -> SystemWorldModel {
        let connectedSystems = unique(
            systems(from: context.contextBundle)
                + systems(from: workspaceEvents)
                + policyDeltas.compactMap(\.replacementToolCommand)
        )
        let previousFailures = unique(
            workspaceEvents
                .filter { [.toolFailed, .connectorFailed, .authorizationDenied].contains($0.type) }
                .map { failureSummary($0) }
                + (systemFailureProfile?.clusters.map { cluster in
                    "\(cluster.toolCommand ?? "unknown command"): \(cluster.frequency) prior failures"
                } ?? [])
        )
        let environmentFacts = unique(
            facts(from: workspace, context: context)
                + recentTasks.prefix(5).map { "recent_task:\($0.title)" }
                + (globalExecutionPolicy.map { ["global_policy:\($0.summary)"] } ?? [])
        )

        return SystemWorldModel(
            workspaceID: workspace.id,
            customerContext: "\(workspace.displayName) role=\(workspace.role.rawValue) org=\(workspace.orgID.uuidString)",
            connectedSystems: connectedSystems,
            permissions: permissions(for: workspace),
            previousFailures: previousFailures,
            environmentFacts: environmentFacts,
            observations: []
        )
    }

    func applying(_ observation: ToolObservation, to model: SystemWorldModel) -> SystemWorldModel {
        var updated = model
        updated.observations = unique(updated.observations + [observation.summary]).suffixArray(20)

        if observation.outcome == .failed {
            updated.previousFailures = unique(updated.previousFailures + [observation.summary]).suffixArray(20)
        }

        if let connectedSystem = observation.connectedSystem {
            updated.connectedSystems = unique(updated.connectedSystems + [connectedSystem]).suffixArray(20)
        }

        updated.environmentFacts = unique(updated.environmentFacts + observation.environmentFacts).suffixArray(30)
        return updated
    }

    func applying(_ environment: SystemEnvironmentModel, to model: SystemWorldModel) -> SystemWorldModel {
        var updated = model
        updated.connectedSystems = unique(updated.connectedSystems + environment.worldModelSystemLabels).suffixArray(30)
        updated.permissions = unique(updated.permissions + environment.permissionGraph.summaryFacts).suffixArray(60)
        updated.environmentFacts = unique(
            updated.environmentFacts
                + environment.facts
                + environment.risks.map { "risk:\($0.systemID):\($0.severity.rawValue):\($0.title)" }
        ).suffixArray(80)
        updated.observations = unique(
            updated.observations + [
                "environment_discovered:\(environment.connectedSystems.count)_systems",
                "environment_risks:\(environment.risks.count)"
            ]
        ).suffixArray(20)
        updated.evidence = unique(updated.evidence + environment.worldModelEvidence).suffixArray(80)
        updated.permissionGraph = (updated.permissionGraph ?? PermissionGraph()).merged(with: environment.permissionGraph)
        return updated
    }

    private func permissions(for workspace: Workspace) -> [String] {
        let authorization = AuthorizationService()
        var permissions = ["role:\(workspace.role.rawValue)"]
        for permission in Permission.allCases where authorization.hasPermission(permission, in: workspace) {
            permissions.append("allows:\(permission.rawValue)")
        }
        if workspace.hasLocalProjectScope {
            permissions.append("local_project_scope")
        }
        if workspace.hasAgentProjectScope {
            permissions.append("agent_project_scope")
        }
        return permissions
    }

    private func systems(from bundle: ContextBundle?) -> [String] {
        guard let bundle else { return [] }
        return unique(
            bundle.codebases.map { "codebase:\($0.role)" }
                + bundle.graphSummary.detectedSystems.map { "graph:\($0)" }
                + bundle.workspace.packageIndicators.map { "package:\($0)" }
                + bundle.codebases.flatMap { $0.packageIndicators.map { "package:\($0)" } }
        )
    }

    private func systems(from events: [ExecutionEvent]) -> [String] {
        unique(events.compactMap { event in
            if let command = event.payload["command"] ?? event.payload["failed_command"] {
                return connectedSystem(from: command)
            }
            return nil
        })
    }

    private func facts(from workspace: Workspace, context: ExecutionContext) -> [String] {
        var facts = [
            "workspace_namespace:\(workspace.eventNamespace)",
            "execution_scope:\(workspace.executionScope.rawValue)",
            "distribution_policy:\(workspace.distributionPolicy.rawValue)"
        ]
        let scope = context.missionWorkspaceScope ?? .legacyAndAgentComparison
        if scope.codebaseRoles.contains("legacy_software"), let root = workspace.localProjectRoot {
            facts.append("project_root:\(root)")
        }
        if scope.codebaseRoles.contains("ai_agent"), let root = workspace.localAgentProjectRoot {
            facts.append("agent_project_root:\(root)")
        }
        if let systemState = context.contextBundle?.systemState {
            facts.append("cwd:\(systemState.currentWorkingDirectory)")
            facts.append("persistence:\(systemState.persistenceStatus)")
        }
        return facts
    }

    private func failureSummary(_ event: ExecutionEvent) -> String {
        let command = event.payload["command"] ?? event.payload["failed_command"] ?? "unknown"
        return "\(event.type.rawValue.lowercased()):\(command)"
    }
}

enum ToolObservationOutcome: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case succeeded = "SUCCEEDED"
    case failed = "FAILED"

    var id: String { rawValue }
}

struct ToolObservation: Codable, Hashable, Sendable {
    var outcome: ToolObservationOutcome
    var summary: String
    var signals: [String]
    var environmentFacts: [String]
    var connectedSystem: String?
    var nextAction: AgentRuntimeAction

    var auditPayload: [String: String] {
        [
            "observation_outcome": outcome.rawValue,
            "observation_summary": AgentPresentationSanitizer.safeContent(summary, fallback: outcome.rawValue),
            "observation_signals": AgentPresentationSanitizer.safeContent(signals.prefix(8).joined(separator: " | "), fallback: ""),
            "observation_next_action": nextAction.rawValue,
            "observation_environment_facts": AgentPresentationSanitizer.safeContent(environmentFacts.prefix(8).joined(separator: " | "), fallback: ""),
            "observation_connected_system": AgentPresentationSanitizer.safeContent(connectedSystem ?? "", fallback: "")
        ]
    }
}

struct ObservationLoop: Sendable {
    func observeResult(
        step: PlanStep,
        toolCall: ToolCall,
        result: ToolExecutionResult,
        attempt: Int,
        maxAttempts: Int
    ) -> ToolObservation {
        let outcome: ToolObservationOutcome = result.exitCode == 0 ? .succeeded : .failed
        let nextAction: AgentRuntimeAction = outcome == .succeeded ? .continueMission : .replan
        let signals = [
            "step:\(step.id)",
            "tool:\(toolCall.id)",
            "command:\(toolCall.command)",
            "exit_code:\(result.exitCode)",
            "attempt:\(attempt)/\(maxAttempts)"
        ]
        let facts = result.standardOutput.isEmpty
            ? []
            : ["stdout_available:true", "stdout_bytes:\(result.standardOutput.utf8.count)"]

        return ToolObservation(
            outcome: outcome,
            summary: outcome == .succeeded
                ? "Observed successful result from \(step.title) using \(toolCall.command)."
                : "Observed non-zero result from \(step.title) using \(toolCall.command).",
            signals: signals,
            environmentFacts: facts,
            connectedSystem: connectedSystem(from: toolCall.command),
            nextAction: nextAction
        )
    }

    func observeFailure(
        step: PlanStep,
        toolCall: ToolCall,
        error: Error,
        attempt: Int,
        maxAttempts: Int
    ) -> ToolObservation {
        ToolObservation(
            outcome: .failed,
            summary: "Observed failure in \(step.title) using \(toolCall.command): \(error.localizedDescription)",
            signals: [
                "step:\(step.id)",
                "tool:\(toolCall.id)",
                "command:\(toolCall.command)",
                "attempt:\(attempt)/\(maxAttempts)",
                "error:\(error.localizedDescription)"
            ],
            environmentFacts: ["failure_captured:true"],
            connectedSystem: connectedSystem(from: toolCall.command),
            nextAction: attempt < maxAttempts ? .executeTool : .replan
        )
    }
}

struct ReplanningDecision: Codable, Hashable, Sendable {
    var hypothesis: String
    var modifiedStep: PlanStep
    var recoveryCall: ToolCall

    var auditPayload: [String: String] {
        [
            "replan_hypothesis": AgentPresentationSanitizer.safeContent(hypothesis, fallback: "Tool failure requires adapted plan."),
            "replan_modified_step_id": modifiedStep.id,
            "replan_recovery_tool_call_id": recoveryCall.id,
            "replan_recovery_command": recoveryCall.command
        ]
    }
}

struct ReplanningEngine: Sendable {
    func replan(
        failedStep: PlanStep,
        failedCall: ToolCall,
        error: Error,
        worldModel: SystemWorldModel,
        recoveryAgent: RecoveryAgent
    ) -> ReplanningDecision {
        let recoveryCall = recoveryAgent.recoveryCall(for: failedCall, error: error)
        let hypothesis = "The action \(failedCall.command) failed in \(worldModel.customerContext); use a local recovery tool and continue with captured evidence."
        let modifiedStep = PlanStep(
            id: "replan.\(failedStep.id)",
            title: "Adapt after \(failedStep.title)",
            intent: "Recover from failed tool call \(failedCall.id) and preserve mission progress.",
            toolCallID: recoveryCall.id,
            requiresApproval: recoveryCall.requiresApproval,
            retryBudget: 0
        )

        return ReplanningDecision(
            hypothesis: hypothesis,
            modifiedStep: modifiedStep,
            recoveryCall: recoveryCall
        )
    }
}

private func connectedSystem(from command: String) -> String? {
    if command.contains(".") {
        return "connector:\(command.split(separator: ".").first.map(String.init) ?? command)"
    }
    if command.hasPrefix("/") {
        return "local_shell:\((command as NSString).lastPathComponent)"
    }
    return command.isEmpty ? nil : "tool:\(command)"
}

private func unique(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values {
        let safeValue = AgentPresentationSanitizer.safeContent(value, fallback: "")
        guard !safeValue.isEmpty, !seen.contains(safeValue) else { continue }
        seen.insert(safeValue)
        result.append(safeValue)
    }
    return result
}

private extension Array {
    func suffixArray(_ maxCount: Int) -> [Element] {
        Array(suffix(maxCount))
    }
}
