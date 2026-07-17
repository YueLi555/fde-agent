import Foundation

enum RuntimeKernelError: LocalizedError, Equatable {
    case emptyInput
    case projectRootRequired

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Task input cannot be empty."
        case .projectRootRequired:
            return "Choose both the legacy software project and the AI agent project before starting FDE."
        }
    }
}

private enum RuntimeStepHandlingResult {
    case runStep
    case skipStep
    case finishTask
}

private enum ReadOnlyMissionDeadlineError: Error, Sendable {
    case hardDeadlineReached(stage: String)
}

enum RuntimeCompletionPolicy: Equatable, Sendable {
    case legacyPermissive
    case evidenceRequired
}

actor RuntimeKernel {
    private let persistence: any PersistenceStore
    private let eventStream: any EventStream
    private let contextCompiler: InstructionContextCompiler
    private let modelRouter: any ModelRouting
    private let validator: any StructuredOutputValidating
    private let toolExecutor: any ToolExecuting
    private let recoveryAgent: RecoveryAgent
    private let graphEngine: SystemGraphEngine
    private let uncertaintyEngine: UncertaintyEngine
    private let outcomeTracker: OutcomeTracker
    private let feedbackEngine: FieldFeedbackEngine
    private let feedbackPolicyEngine: FeedbackPolicyEngine
    private let systemLearningEngine: SystemLearningEngine
    private let globalGovernor: GlobalExecutionGovernor
    private let authorizationService: AuthorizationService
    private let approvalQueue: ApprovalQueue
    private let riskClassifier: RiskClassificationEngine
    private let riskAssessmentEngine: RiskAssessmentEngine
    private let policyEngine: PolicyEngine
    private let decisionEngine: AgentDecisionEngine
    private let agentQualityEvaluator: AgentQualityEvaluator
    private let memoryImprovementPipeline: AgentMemoryImprovementPipeline
    private let enterpriseMemoryStore: (any EnterpriseMemoryStoring)?
    private let systemUnderstandingLayer: SystemUnderstandingLayer
    private let observationLoop: ObservationLoop
    private let replanningEngine: ReplanningEngine
    private let stepAdapter: RuntimeStepAdapter
    private let completionPolicy: RuntimeCompletionPolicy
    private let requiresProjectScope: Bool
    private let readOnlyInspectionLimits: ReadOnlyInspectionLimits
    private let sandboxLifecycle: SandboxLifecycleService?
    private let candidatePatchPlanProvider: (any CandidatePatchPlanRequestProviding)?
    private let allowsCandidatePatchTestApproval: Bool
    private let readOnlyReadinessValidator = ReadOnlyPlanReadinessValidator()
    private let promptOrchestrator = PromptOrchestrator()
    private let stateMachine = WorkflowStateMachine()
    private var lastEventIDByTask: [UUID: UUID] = [:]
    private var lastEventIDByWorkspace: [UUID: UUID] = [:]
    private var pendingCandidatePatches: [UUID: CandidatePatchPendingRuntime] = [:]
    private var candidatePatchApprovalConfirmations: [UUID: CandidatePatchApprovalConfirmation] = [:]
    private var pendingCandidatePatchReverts: [UUID: CandidatePatchRevertTarget] = [:]
    private var candidatePatchRevertConfirmations: [UUID: CandidatePatchRevertConfirmation] = [:]
    private var pendingCandidatePatchDestructions: [UUID: CandidatePatchSandboxDestructionTarget] = [:]
    private var candidatePatchDestructionConfirmations: [UUID: CandidatePatchSandboxDestructionConfirmation] = [:]

    init(
        persistence: any PersistenceStore,
        eventBus: RuntimeEventBus,
        eventStream: (any EventStream)? = nil,
        contextCompiler: InstructionContextCompiler = InstructionContextCompiler(),
        modelRouter: any ModelRouting,
        validator: any StructuredOutputValidating = StructuredOutputValidator(),
        toolExecutor: any ToolExecuting = LocalToolExecutor(),
        recoveryAgent: RecoveryAgent = RecoveryAgent(),
        graphEngine: SystemGraphEngine = SystemGraphEngine(),
        uncertaintyEngine: UncertaintyEngine = UncertaintyEngine(),
        outcomeTracker: OutcomeTracker = OutcomeTracker(),
        feedbackEngine: FieldFeedbackEngine = FieldFeedbackEngine(),
        feedbackPolicyEngine: FeedbackPolicyEngine = FeedbackPolicyEngine(),
        systemLearningEngine: SystemLearningEngine = SystemLearningEngine(),
        globalGovernor: GlobalExecutionGovernor = GlobalExecutionGovernor(),
        authorizationService: AuthorizationService = AuthorizationService(),
        approvalQueue: ApprovalQueue? = nil,
        riskClassifier: RiskClassificationEngine = RiskClassificationEngine(),
        riskAssessmentEngine: RiskAssessmentEngine = RiskAssessmentEngine(),
        policyEngine: PolicyEngine = PolicyEngine(),
        decisionEngine: AgentDecisionEngine = AgentDecisionEngine(),
        agentQualityEvaluator: AgentQualityEvaluator = AgentQualityEvaluator(),
        memoryImprovementPipeline: AgentMemoryImprovementPipeline = AgentMemoryImprovementPipeline(),
        enterpriseMemoryStore: (any EnterpriseMemoryStoring)? = nil,
        systemUnderstandingLayer: SystemUnderstandingLayer = SystemUnderstandingLayer(),
        observationLoop: ObservationLoop = ObservationLoop(),
        replanningEngine: ReplanningEngine = ReplanningEngine(),
        stepAdapter: RuntimeStepAdapter = RuntimeStepAdapter(),
        completionPolicy: RuntimeCompletionPolicy = .legacyPermissive,
        requiresProjectScope: Bool = false,
        readOnlyInspectionLimits: ReadOnlyInspectionLimits = .conservative,
        sandboxLifecycle: SandboxLifecycleService? = nil,
        candidatePatchPlanProvider: (any CandidatePatchPlanRequestProviding)? = nil,
        allowsCandidatePatchTestApproval: Bool = false
    ) {
        self.persistence = persistence
        self.eventStream = eventStream ?? InMemoryEventStream(eventBus: eventBus)
        self.contextCompiler = contextCompiler
        self.modelRouter = modelRouter
        self.validator = validator
        self.toolExecutor = toolExecutor
        self.recoveryAgent = recoveryAgent
        self.graphEngine = graphEngine
        self.uncertaintyEngine = uncertaintyEngine
        self.outcomeTracker = outcomeTracker
        self.feedbackEngine = feedbackEngine
        self.feedbackPolicyEngine = feedbackPolicyEngine
        self.systemLearningEngine = systemLearningEngine
        self.globalGovernor = globalGovernor
        self.authorizationService = authorizationService
        self.approvalQueue = approvalQueue ?? ApprovalQueue(persistence: persistence)
        self.riskClassifier = riskClassifier
        self.riskAssessmentEngine = riskAssessmentEngine
        self.policyEngine = policyEngine
        self.decisionEngine = decisionEngine
        self.agentQualityEvaluator = agentQualityEvaluator
        self.memoryImprovementPipeline = memoryImprovementPipeline
        self.enterpriseMemoryStore = enterpriseMemoryStore
        self.systemUnderstandingLayer = systemUnderstandingLayer
        self.observationLoop = observationLoop
        self.replanningEngine = replanningEngine
        self.stepAdapter = stepAdapter
        self.completionPolicy = completionPolicy
        self.requiresProjectScope = requiresProjectScope
        self.readOnlyInspectionLimits = readOnlyInspectionLimits
        self.sandboxLifecycle = sandboxLifecycle
        self.allowsCandidatePatchTestApproval = allowsCandidatePatchTestApproval
        self.candidatePatchPlanProvider = candidatePatchPlanProvider
            ?? PersistedCandidatePatchPlanRequestProvider(persistence: persistence)
    }

    func runCandidatePatchGeneration(input: String, workspace: Workspace) async throws -> FDETask {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeKernelError.emptyInput }
        var task = FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: "Phase 2D.1 Candidate Patch",
            rawInput: trimmed,
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await record(
            type: .taskCreated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Candidate Patch task created",
            payload: [
                "state": task.state.rawValue,
                "intent_type": MissionIntentType.candidatePatchGeneration.rawValue,
                "mission_semantic": MissionExecutionSemantic.candidatePatchGeneration.rawValue,
                "mission_workspace_scope": MissionWorkspaceScope.legacyOnly.rawValue,
                "generic_tool_execution_enabled": "false",
                "generated_tests_available": "false"
            ].merging(runtimeStatePayload(mission: .understand, task: task.state)) { current, _ in current },
            initialTask: task
        )
        task.plan = CandidatePatchActivityPhase.generationPhases.map { phase in
            PlanStep(
                id: "candidate-patch-\(phase.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: phase.rawValue,
                intent: "Run an app-managed Candidate Patch lifecycle step without shell, Git, build, test, or deployment execution.",
                kind: .reasoning,
                toolCallID: nil,
                requiresApproval: phase == .waitingForHumanApproval
            )
        }
        try stateMachine.transition(&task, to: .planned)
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)

        var snapshot = CandidatePatchActivitySnapshot.empty
        do {
            try await recordCandidatePatchActivity(.understandingRequestedChange, snapshot: snapshot, workspace: workspace, task: task)
            try await recordCandidatePatchActivity(.loadingGroundedAssessment, snapshot: snapshot, workspace: workspace, task: task)
            guard let lifecycle = sandboxLifecycle,
                  let provider = candidatePatchPlanProvider else {
                throw CandidatePatchRuntimeError.runtimeUnavailable
            }
            try await recordCandidatePatchActivity(.validatingPlanningPreconditions, snapshot: snapshot, workspace: workspace, task: task)
            let request = try await provider.planRequest(for: trimmed, workspace: workspace, lifecycle: lifecycle)
            try await recordCandidatePatchActivity(.preparingCandidatePatchPlan, snapshot: snapshot, workspace: workspace, task: task)
            let service = CandidatePatchService(lifecycle: lifecycle)
            let plan = try service.preparePlan(request)
            var manifest = try service.loadManifest(sandboxID: plan.sandboxID, patchID: plan.patchID)
            snapshot = CandidatePatchActivitySnapshot(plan: plan)

            let approvalID = UUID()
            var renderedPlan = plan
            renderedPlan.approvalRequestID = approvalID
            let approval = ApprovalRequest(
                id: approvalID,
                workspaceID: workspace.id,
                taskID: task.id,
                stepID: "candidate-patch-plan-revision-\(plan.revision)",
                toolCallID: nil,
                targetKind: .candidatePatchPlan,
                action: "Approve Candidate Patch plan",
                resource: "Candidate Patch \(plan.patchID.rawValue) with reserved Safe Sandbox \(plan.sandboxID.rawValue)",
                riskLevel: riskSeverity(plan.risk),
                state: .pending,
                requestedByRole: workspace.role,
                decidedByRole: nil,
                decisionReason: nil,
                requestedAt: Date(),
                decidedAt: nil,
                expiresAt: nil,
                metadata: [
                    "workspace_id": workspace.id.uuidString,
                    "task_id": task.id.uuidString,
                    "approval_request_id": approvalID.uuidString,
                    "candidate_patch_id": plan.patchID.rawValue,
                    "sandbox_id": plan.sandboxID.rawValue,
                    "sandbox_root": "",
                    "source_snapshot_id": plan.sourceSnapshotID,
                    "assessment_id": plan.assessmentID,
                    "normalized_requested_capability_id": plan.requestedCapabilityID,
                    "canonical_legacy_root": plan.legacyIntegrityBaseline.canonicalLegacyRoot,
                    "plan_id": plan.planID.uuidString,
                    "plan_revision": String(plan.revision),
                    "files_planned": String(plan.operations.count),
                    "prohibited_actions": plan.prohibitedActions.joined(separator: " | "),
                    "candidate_patch_plan_summary": renderedPlan.markdown
                ]
            )
            manifest = try service.recordApprovalRequest(
                sandboxID: plan.sandboxID,
                patchID: plan.patchID,
                planID: plan.planID,
                approvalRequestID: approval.id
            )
            snapshot = CandidatePatchActivitySnapshot(plan: manifest.plan)
            _ = try await approvalQueue.enqueue(approval)
            pendingCandidatePatches[approval.id] = CandidatePatchPendingRuntime(
                approvalRequestID: approval.id,
                taskID: task.id,
                workspaceID: workspace.id,
                sandboxID: plan.sandboxID,
                patchID: plan.patchID
            )
            try stateMachine.transition(&task, to: .pendingApproval)
            try await persistence.saveTask(task)
            try await record(
                type: .humanApprovalRequested,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Candidate Patch plan requires explicit human approval",
                payload: snapshot.eventPayload.merging([
                    "state": task.state.rawValue,
                    "approval_request_id": approval.id.uuidString,
                    "candidate_patch_activity_phase": CandidatePatchActivityPhase.waitingForHumanApproval.rawValue,
                    "runtime_owned_activity": "true",
                    "manifest_backed": "true",
                    "plan_state_location": "app_managed_outside_legacy_and_sandbox",
                    "detail": manifest.plan.markdown,
                    "actual_result": manifest.plan.markdown,
                    "workspace_mutation_count": "0",
                    "legacy_writes": "0",
                    "sandbox_writes": "0",
                    "patch_files_created": "0",
                    "build_test_executions": "0",
                    "shell_calls": "0",
                    "git_operations": "0",
                    "deployment_operations": "0",
                    "unified_diff_exists": "false",
                    "sandbox_readiness_checked": "false"
                ]) { current, _ in current }
                .merging(runtimeStatePayload(mission: .waitingHuman, task: task.state, tool: .pendingApproval)) { current, _ in current }
            )
            return task
        } catch {
            try stateMachine.transition(&task, to: .failed)
            task.failureProbability = 1
            try await persistence.saveTask(task)
            let code = candidatePatchFailureCode(error)
            try? await recordCandidatePatchActivity(.candidatePatchBlocked, snapshot: snapshot, workspace: workspace, task: task)
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Candidate Patch generation failed closed",
                payload: [
                    "state": task.state.rawValue,
                    "intent_type": MissionIntentType.candidatePatchGeneration.rawValue,
                    "failure_category": code.rawValue,
                    "blocker_reason": code.rawValue,
                    "workspace_mutation_count": "0",
                    "legacy_writes": "0",
                    "sandbox_writes": "0",
                    "patch_files_created": "0",
                    "build_or_test_executed": "false",
                    "shell_calls": "0",
                    "git_operations": "0",
                    "deployment_operations": "0",
                    "git_or_deployment_action_occurred": "false",
                    "generated_tests_available": "false"
                ].merging(runtimeStatePayload(mission: .failed, task: task.state, tool: .failed)) { current, _ in current }
            )
            return task
        }
    }

    func runCandidatePatchRevert(input: String, workspace: Workspace) async throws -> FDETask {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeKernelError.emptyInput }
        var task = FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: "Phase 2D.1 Candidate Patch Revert",
            rawInput: trimmed,
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await record(
            type: .taskCreated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Candidate Patch Revert task created",
            payload: [
                "state": task.state.rawValue,
                "intent_type": MissionIntentType.candidatePatchRevert.rawValue,
                "mission_semantic": MissionExecutionSemantic.candidatePatchRevert.rawValue,
                "generic_tool_execution_enabled": "false",
                "patch_plan_created": "false",
                "patch_application_approval_created": "false",
                "sandbox_created": "false",
                "unified_diff_applied": "false"
            ].merging(runtimeStatePayload(mission: .understand, task: task.state)) { current, _ in current },
            initialTask: task
        )
        task.plan = CandidatePatchActivityPhase.revertPhases.map { phase in
            PlanStep(
                id: "candidate-patch-revert-\(phase.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: phase.rawValue,
                intent: "Run the exact-bound app-managed Candidate Patch Revert lifecycle without Build, Test, Shell, Git, deployment, credential, or Sandbox-creation operations.",
                kind: .reasoning,
                toolCallID: nil,
                requiresApproval: phase == .revertConfirmationRequired
            )
        }
        try stateMachine.transition(&task, to: .planned)
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)

        guard let lifecycle = sandboxLifecycle else {
            try stateMachine.transition(&task, to: .failed)
            try await persistence.saveTask(task)
            return task
        }
        let service = CandidatePatchService(lifecycle: lifecycle)
        do {
            try await recordCandidatePatchRevertActivity(
                .locatingAppliedPatch,
                snapshot: .empty,
                workspace: workspace,
                task: task
            )
            let target = try service.locateRevertTarget(workspaceID: workspace.id, request: trimmed)
            _ = try service.prepareRevert(binding: target.binding)
            var snapshot = CandidatePatchActivitySnapshot(
                manifest: try service.loadManifest(
                    sandboxID: target.binding.sandboxID,
                    patchID: target.binding.patchID
                )
            )
            try await recordCandidatePatchRevertActivity(
                .validatingRevertBinding,
                snapshot: snapshot,
                workspace: workspace,
                task: task
            )
            try await recordCandidatePatchRevertActivity(
                .verifyingCurrentPostimages,
                snapshot: snapshot,
                workspace: workspace,
                task: task
            )
            try await recordCandidatePatchRevertActivity(
                .confirmingOriginalLegacyUnchanged,
                snapshot: snapshot,
                workspace: workspace,
                task: task
            )
            snapshot.projectionState = .revertConfirmationRequired
            pendingCandidatePatchReverts[task.id] = target
            try stateMachine.transition(&task, to: .pendingApproval)
            try await persistence.saveTask(task)
            try await recordCandidatePatchRevertActivity(
                .revertConfirmationRequired,
                snapshot: snapshot,
                workspace: workspace,
                task: task,
                extraPayload: [
                    "manifest_id": target.binding.manifestID,
                    "source_task_id": target.binding.taskID.uuidString,
                    "plan_id": target.binding.planID.uuidString,
                    "plan_revision": String(target.binding.planRevision),
                    "source_snapshot_id": target.binding.sourceSnapshotID,
                    "canonical_legacy_root": target.binding.canonicalLegacyRoot,
                    "files_to_restore": target.filesToRestore.joined(separator: " | "),
                    "files_to_remove": target.filesToRemove.joined(separator: " | "),
                    "explicit_revert_confirmation_required": "true",
                    "patch_plan_created": "false",
                    "patch_application_approval_created": "false",
                    "sandbox_created": "false",
                    "unified_diff_applied": "false"
                ]
            )
            return task
        } catch let error as CandidatePatchError where error.code == .revertSelectionAmbiguous {
            let choices = (try? service.revertTargets(workspaceID: workspace.id)) ?? []
            try stateMachine.transition(&task, to: .blocked)
            try await persistence.saveTask(task)
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Candidate Patch Revert requires exact Patch selection",
                payload: [
                    "state": task.state.rawValue,
                    "intent_type": MissionIntentType.candidatePatchRevert.rawValue,
                    "lifecycle_event": "CANDIDATE_PATCH_REVERT_DISAMBIGUATION_REQUIRED",
                    "candidate_patch_projection_state": CandidatePatchProjectionState.revertConfirmationRequired.rawValue,
                    "candidate_patch_choices": choices.map {
                        "\($0.binding.patchID.rawValue.prefix(8))… / \($0.binding.sandboxID.rawValue.prefix(8))…"
                    }.joined(separator: " | "),
                    "selection_required": "true",
                    "patch_plan_created": "false",
                    "patch_application_approval_created": "false",
                    "sandbox_created": "false",
                    "build_or_test_executed": "false",
                    "shell_execution_enabled": "false",
                    "git_or_deployment_action_occurred": "false"
                ].merging(runtimeStatePayload(mission: .blocked, task: task.state, tool: .failed)) { current, _ in current }
            )
            return task
        } catch {
            try stateMachine.transition(&task, to: .failed)
            task.failureProbability = 1
            try await persistence.saveTask(task)
            let code = candidatePatchFailureCode(error)
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Candidate Patch Revert failed closed",
                payload: [
                    "state": task.state.rawValue,
                    "intent_type": MissionIntentType.candidatePatchRevert.rawValue,
                    "failure_category": code.rawValue,
                    "patch_plan_created": "false",
                    "patch_application_approval_created": "false",
                    "sandbox_created": "false",
                    "build_or_test_executed": "false",
                    "shell_execution_enabled": "false",
                    "git_or_deployment_action_occurred": "false"
                ].merging(runtimeStatePayload(mission: .failed, task: task.state, tool: .failed)) { current, _ in current }
            )
            return task
        }
    }

    func runCandidatePatchSandboxDestroy(input: String, workspace: Workspace) async throws -> FDETask {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeKernelError.emptyInput }
        var task = FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: "Candidate Patch Sandbox Destruction",
            rawInput: trimmed,
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await record(
            type: .taskCreated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Candidate Patch Sandbox destruction task created",
            payload: [
                "state": task.state.rawValue,
                "intent_type": MissionIntentType.candidatePatchSandboxDestroy.rawValue,
                "mission_semantic": MissionExecutionSemantic.candidatePatchSandboxDestroy.rawValue,
                "revert_task_created": "false",
                "patch_plan_created": "false",
                "patch_application_approval_created": "false",
                "sandbox_created": "false"
            ].merging(runtimeStatePayload(mission: .understand, task: task.state)) { current, _ in current },
            initialTask: task
        )
        task.plan = [PlanStep(
            id: "candidate-patch-sandbox-destruction-confirmation",
            title: CandidatePatchActivityPhase.sandboxDestructionConfirmationRequired.rawValue,
            intent: "Validate and destroy only the exact Sandbox bound to an already-reverted Candidate Patch after separate explicit confirmation.",
            kind: .reasoning,
            toolCallID: nil,
            requiresApproval: true
        )]
        try stateMachine.transition(&task, to: .planned)
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)

        guard let lifecycle = sandboxLifecycle else {
            try stateMachine.transition(&task, to: .failed)
            try await persistence.saveTask(task)
            return task
        }
        let service = CandidatePatchService(lifecycle: lifecycle)
        do {
            let target = try service.locateSandboxDestructionTarget(
                workspaceID: workspace.id,
                request: trimmed
            )
            _ = try service.prepareSandboxDestruction(binding: target.binding)
            var snapshot = CandidatePatchActivitySnapshot(manifest: try service.loadManifest(
                sandboxID: target.binding.sandboxID,
                patchID: target.binding.patchID
            ))
            snapshot.projectionState = .sandboxDestructionConfirmationRequired
            pendingCandidatePatchDestructions[task.id] = target
            try stateMachine.transition(&task, to: .pendingApproval)
            try await persistence.saveTask(task)
            try await recordCandidatePatchRevertActivity(
                .sandboxDestructionConfirmationRequired,
                snapshot: snapshot,
                workspace: workspace,
                task: task,
                intentType: .candidatePatchSandboxDestroy,
                extraPayload: [
                    "manifest_id": target.binding.manifestID,
                    "plan_id": target.binding.planID.uuidString,
                    "plan_revision": String(target.binding.planRevision),
                    "source_snapshot_id": target.binding.sourceSnapshotID,
                    "canonical_legacy_root": target.binding.canonicalLegacyRoot,
                    "explicit_destruction_confirmation_required": "true",
                    "revert_task_created": "false",
                    "patch_plan_created": "false",
                    "patch_application_approval_created": "false",
                    "sandbox_created": "false",
                    "build_or_test_executed": "false",
                    "shell_execution_enabled": "false",
                    "git_or_deployment_action_occurred": "false"
                ]
            )
            return task
        } catch {
            try stateMachine.transition(&task, to: .failed)
            task.failureProbability = 1
            try await persistence.saveTask(task)
            let code = candidatePatchFailureCode(error)
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Candidate Patch Sandbox destruction failed closed",
                payload: [
                    "state": task.state.rawValue,
                    "intent_type": MissionIntentType.candidatePatchSandboxDestroy.rawValue,
                    "failure_category": code.rawValue,
                    "revert_task_created": "false",
                    "patch_plan_created": "false",
                    "patch_application_approval_created": "false",
                    "sandbox_created": "false",
                    "build_or_test_executed": "false",
                    "shell_execution_enabled": "false",
                    "git_or_deployment_action_occurred": "false"
                ].merging(runtimeStatePayload(mission: .failed, task: task.state, tool: .failed)) { current, _ in current }
            )
            return task
        }
    }

    private func recordCandidatePatchActivity(
        _ phase: CandidatePatchActivityPhase,
        snapshot: CandidatePatchActivitySnapshot,
        workspace: Workspace,
        task: FDETask
    ) async throws {
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: phase.rawValue,
            payload: snapshot.eventPayload.merging([
                "state": task.state.rawValue,
                "lifecycle_event": "CANDIDATE_PATCH_ACTIVITY",
                "candidate_patch_activity_phase": phase.rawValue,
                "intent_type": MissionIntentType.candidatePatchGeneration.rawValue,
                "workspace_identity": "sandbox",
                "runtime_owned_activity": "true",
                "shell_execution_enabled": "false",
                "git_operations_enabled": "false",
                "build_test_execution_enabled": "false",
                "generated_tests_available": "false"
            ]) { current, _ in current }
            .merging(runtimeStatePayload(mission: .execute, task: task.state, tool: .running)) { current, _ in current }
        )
    }

    private func recordCandidatePatchRevertActivity(
        _ phase: CandidatePatchActivityPhase,
        snapshot: CandidatePatchActivitySnapshot,
        workspace: Workspace,
        task: FDETask,
        intentType: MissionIntentType = .candidatePatchRevert,
        extraPayload: [String: String] = [:]
    ) async throws {
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: phase.rawValue,
            payload: snapshot.eventPayload.merging([
                "state": task.state.rawValue,
                "lifecycle_event": intentType == .candidatePatchSandboxDestroy
                    ? "CANDIDATE_PATCH_SANDBOX_DESTRUCTION_ACTIVITY"
                    : "CANDIDATE_PATCH_REVERT_ACTIVITY",
                "candidate_patch_activity_phase": phase.rawValue,
                "intent_type": intentType.rawValue,
                "workspace_identity": "sandbox",
                "runtime_owned_activity": "true",
                "shell_execution_enabled": "false",
                "git_operations_enabled": "false",
                "build_test_execution_enabled": "false",
                "credential_access_enabled": "false",
                "generated_tests_available": "false"
            ]) { current, _ in current }
            .merging(extraPayload) { current, _ in current }
            .merging(runtimeStatePayload(
                mission: phase == .revertConfirmationRequired
                    || phase == .sandboxDestructionConfirmationRequired ? .waitingHuman : .execute,
                task: task.state,
                tool: phase == .revertConfirmationRequired
                    || phase == .sandboxDestructionConfirmationRequired ? .pendingApproval : .running
            )) { current, _ in current }
        )
    }

    private func persistCandidatePatchAssessmentContext(
        report: FDEAIIntegrationAssessmentReport,
        finalizationMode: CandidatePatchAssessmentFinalizationMode,
        workspace: Workspace,
        task: FDETask
    ) async throws {
        guard let rootPath = workspace.localProjectRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rootPath.isEmpty else {
            throw RuntimeKernelError.projectRootRequired
        }
        let canonicalRoot = try SandboxFileSystem.canonicalExistingDirectory(
            URL(fileURLWithPath: rootPath, isDirectory: true)
        )
        let sourceSnapshot = try SourceSnapshotBuilder().build(root: canonicalRoot)
        let context = CandidatePatchAssessmentContext(
            assessmentID: "assessment-\(task.id.uuidString.lowercased())",
            generatedAt: Date(),
            sourceSnapshotID: sourceSnapshot.snapshotID,
            canonicalLegacyRoot: sourceSnapshot.canonicalSourceRoot,
            report: report,
            finalizationMode: finalizationMode
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(context)
        guard let contextJSON = String(data: encoded, encoding: .utf8) else {
            throw CandidatePatchError.blocked(.assessmentEvidenceMissing)
        }
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Grounded AI integration assessment persisted for Candidate Patch handoff",
            payload: [
                "lifecycle_event": "AI_ASSESSMENT_PERSISTED",
                "assessment_id": context.assessmentID,
                "source_snapshot_id": context.sourceSnapshotID,
                "canonical_legacy_root": context.canonicalLegacyRoot,
                "normalized_requested_capability_id": context.requestedCapabilityID,
                "requested_capability_display_label": context.requestedCapabilityDisplayLabel,
                "compatibility_decision": context.compatibilityDecision.rawValue,
                "evidence_claim_ids": context.evidenceClaimIDs.joined(separator: " | "),
                "supported_capabilities": context.supportedCapabilities.joined(separator: " | "),
                "assessment_blockers": context.blockers.joined(separator: " | "),
                "unresolved_requirements": context.unresolvedRequirements.joined(separator: " | "),
                "evidence_paths": context.evidence
                    .flatMap(\.evidenceReferences)
                    .map(\.path)
                    .reduce(into: [String]()) { values, path in
                        if !values.contains(path) { values.append(path) }
                    }
                    .joined(separator: " | "),
                "assessment_finalization_mode": context.finalizationMode.rawValue,
                "assessment_validation_status": context.validationStatus.rawValue,
                "candidate_patch_assessment_context": contextJSON,
                "workspace_identity": "legacy",
                "workspace_mutation_count": "0"
            ].merging(runtimeStatePayload(mission: .complete, task: task.state)) { current, _ in current }
        )
    }

    private func riskSeverity(_ risk: CandidatePatchRisk) -> RiskSeverity {
        switch risk {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    private func candidatePatchFailureCode(_ error: Error) -> CandidatePatchFailureCode {
        if let error = error as? CandidatePatchError { return error.code }
        if error is CandidatePatchRuntimeError { return .assessmentMissing }
        return .manifestInvalid
    }

    func runSafeSandboxAcceptance(input: String, workspace: Workspace) async throws -> FDETask {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeKernelError.emptyInput }

        var task = FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: "Phase 2D.0 Safe Sandbox acceptance",
            rawInput: trimmed,
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        try await record(
            type: .taskCreated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Safe Sandbox acceptance task created",
            payload: [
                "state": task.state.rawValue,
                "intent_type": MissionIntentType.safeSandboxAcceptance.rawValue,
                "mission_workspace_scope": MissionWorkspaceScope.legacyOnly.rawValue,
                "mission_semantic": MissionExecutionSemantic.safeSandboxAcceptance.rawValue,
                "selected_legacy_root": workspace.localProjectRoot ?? "",
                "trusted_workspace_root": workspace.localProjectRoot ?? "",
                "workspace_identity": "legacy",
                "phase_2d_1_started": "false"
            ].merging(runtimeStatePayload(mission: .understand, task: task.state)) { current, _ in current },
            initialTask: task
        )

        task.plan = SandboxRuntimeActivityPhase.productAcceptancePhases.enumerated().map { index, phase in
            PlanStep(
                id: "sandbox-acceptance-\(index + 1)",
                title: phase.rawValue,
                intent: "Run the Phase 2D.0 lifecycle step from runtime-owned Sandbox components.",
                kind: .reasoning,
                toolCallID: nil,
                requiresApproval: false
            )
        }
        try stateMachine.transition(&task, to: .planned)
        try await persistence.saveTask(task)
        try await record(
            type: .planGenerated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Deterministic Safe Sandbox acceptance lifecycle selected",
            payload: [
                "state": task.state.rawValue,
                "intent_type": MissionIntentType.safeSandboxAcceptance.rawValue,
                "plan_step_count": String(task.plan.count),
                "generic_file_search_enabled": "false",
                "phase_2d_1_started": "false"
            ].merging(runtimeStatePayload(mission: .plan, task: task.state)) { current, _ in current }
        )
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)

        var activeSandboxID: SandboxID?
        var latestSnapshot = SandboxActivitySnapshot.empty
        do {
            guard var lifecycle = sandboxLifecycle else {
                throw SafeSandboxAcceptanceRuntimeError.runtimeUnavailable
            }

            try await recordSandboxActivity(
                .validatingSelectedLegacyWorkspace,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            guard let selectedRoot = workspace.localProjectRootURL else {
                throw SafeSandboxAcceptanceRuntimeError.workspaceNotSelected
            }

            try await recordSandboxActivity(
                .confirmingCanonicalLegacyRoot,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            let canonicalLegacyRoot = try SandboxFileSystem.canonicalExistingDirectory(selectedRoot)
            for assertedRoot in SafeSandboxAcceptanceRequest.assertedAbsoluteRoots(in: trimmed) {
                let canonicalAssertion = try SandboxFileSystem.canonicalPotential(
                    URL(fileURLWithPath: assertedRoot, isDirectory: true)
                )
                guard canonicalAssertion.path == canonicalLegacyRoot.path else {
                    throw SafeSandboxAcceptanceRuntimeError.workspaceRootMismatch
                }
            }

            if let agentRoot = workspace.localAgentProjectRootURL,
               !lifecycle.agentWorkspaceRoots.contains(where: { $0.standardizedFileURL.path == agentRoot.standardizedFileURL.path }) {
                lifecycle.agentWorkspaceRoots.append(agentRoot)
            }

            try await recordSandboxActivity(
                .checkingLocalSourceAvailability,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            _ = try SandboxPreflightValidator(
                storageRoot: lifecycle.storageRoot,
                agentWorkspaceRoots: lifecycle.agentWorkspaceRoots
            ).validate(sourceRoot: canonicalLegacyRoot, approvedLegacyRoot: canonicalLegacyRoot)

            try await recordSandboxActivity(
                .creatingSourceSnapshot,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            try await recordSandboxActivity(
                .creatingIsolatedSandbox,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            try await recordSandboxActivity(
                .copyingApprovedFiles,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            try await recordSandboxActivity(
                .excludingSensitiveFiles,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )

            let prepared = try lifecycle.prepareSandbox(
                sourceRoot: canonicalLegacyRoot,
                approvedLegacyRoot: canonicalLegacyRoot
            )
            activeSandboxID = prepared.descriptor.sandboxID
            latestSnapshot = SandboxActivitySnapshot(inspection: prepared)
            let beforeIntegrity = try lifecycle.checkSourceIntegrity(prepared.descriptor.sandboxID)
            guard beforeIntegrity.isUnchanged else {
                throw SandboxFoundationError.sourceSnapshotChanged
            }

            try await recordSandboxActivity(
                .verifyingSHA256,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            try await recordSandboxActivity(
                .verifyingFilesystemIsolation,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            let ready = try lifecycle.validateSandbox(prepared.descriptor.sandboxID)
            guard ready.manifest.status == .ready else {
                throw SandboxFoundationError.copyVerificationFailed
            }
            latestSnapshot = SandboxActivitySnapshot(inspection: ready)
            try await recordSandboxActivity(
                .sandboxReady,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )

            try await recordSandboxActivity(
                .confirmingOriginalLegacyUnchanged,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            let afterIntegrity = try lifecycle.checkSourceIntegrity(ready.descriptor.sandboxID)
            guard afterIntegrity.isUnchanged else {
                throw SandboxFoundationError.sourceSnapshotChanged
            }

            let sensitiveExcludedCount = ready.sourceManifest.exclusions.filter {
                lifecycle.snapshotBuilder.exclusionPolicy.isSensitive(reason: $0.reason)
            }.count
            let hashValidationPassed = ready.manifest.integrity.status == .passed
                && ready.manifest.integrity.matchingHashCount == ready.manifest.includedFileCount
            let inodeIsolationPassed = ready.manifest.integrity.independentlyStoredFileCount
                == ready.manifest.includedFileCount
            let sensitiveExclusionPassed = ready.manifest.integrity.sensitiveItemsFound == 0

            try await recordSandboxActivity(
                .destroyingSandbox,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            let destroyed: SandboxDescriptor
            do {
                destroyed = try lifecycle.destroySandbox(ready.descriptor.sandboxID)
            } catch {
                throw SafeSandboxAcceptanceRuntimeError.sandboxDestructionFailed
            }
            activeSandboxID = nil
            latestSnapshot.status = destroyed.status

            let report = SafeSandboxAcceptanceReport(
                canonicalLegacyRoot: canonicalLegacyRoot.path,
                sourceAvailability: "local",
                sourceSnapshotID: ready.sourceManifest.snapshotID,
                sandboxID: ready.manifest.sandboxID.rawValue,
                lifecycleStates: [.creating, .validating, .ready, .destroying, .destroyed],
                includedFileCount: ready.manifest.includedFileCount,
                excludedItemCount: ready.manifest.excludedItemCount,
                hashValidationPassed: hashValidationPassed,
                inodeIsolationPassed: inodeIsolationPassed,
                sensitiveExclusionPassed: sensitiveExclusionPassed,
                sensitiveExcludedItemCount: sensitiveExcludedCount,
                originalLegacyBeforeIntegrity: beforeIntegrity.state,
                originalLegacyAfterIntegrity: afterIntegrity.state,
                sandboxDestroyed: destroyed.status == .destroyed,
                phase2D1Started: false
            )
            guard report.hashValidationPassed,
                  report.inodeIsolationPassed,
                  report.sensitiveExclusionPassed,
                  report.originalLegacyBeforeIntegrity == .unchanged,
                  report.originalLegacyAfterIntegrity == .unchanged,
                  report.sandboxDestroyed else {
                throw SandboxFoundationError.copyVerificationFailed
            }

            try await recordSandboxActivity(
                .finalizingSandboxAcceptance,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            try stateMachine.transition(&task, to: .completed)
            try await persistence.saveTask(task)
            try await record(
                type: .taskCompleted,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Phase 2D.0 Safe Sandbox acceptance completed",
                payload: report.eventPayload.merging([
                    "state": task.state.rawValue,
                    "intent_type": MissionIntentType.safeSandboxAcceptance.rawValue,
                    "completion_contract": RuntimeCompletionContractKind.safeSandboxAcceptance.rawValue,
                    "completion_gate_passed": "true",
                    "grounded_answer": "true",
                    "detail": report.markdown,
                    "actual_result": report.markdown,
                    "success": "true",
                    "generic_file_search_invoked": "false"
                ]) { current, _ in current }
                .merging(runtimeStatePayload(mission: .complete, task: task.state)) { current, _ in current }
            )
            return task
        } catch {
            var category = SafeSandboxAcceptanceFailureCategory.sanitized(error: error)
            if let activeSandboxID, var lifecycle = sandboxLifecycle {
                if let agentRoot = workspace.localAgentProjectRootURL {
                    lifecycle.agentWorkspaceRoots.append(agentRoot)
                }
                do {
                    _ = try lifecycle.destroySandbox(activeSandboxID)
                } catch {
                    category = .sandboxDestructionFailed
                }
            }
            try? await recordSandboxActivity(
                .sandboxCreationBlocked,
                snapshot: latestSnapshot,
                workspace: workspace,
                task: task
            )
            try stateMachine.transition(&task, to: .failed)
            task.failureProbability = 1
            try await persistence.saveTask(task)
            let safeFailureMessage = "Safe Sandbox acceptance stopped safely (`\(category.rawValue)`). Phase 2D.1 was not started."
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Safe Sandbox acceptance failed closed",
                payload: [
                    "state": task.state.rawValue,
                    "intent_type": MissionIntentType.safeSandboxAcceptance.rawValue,
                    "failure_category": category.rawValue,
                    "blocker_reason": category.rawValue,
                    "user_visible_message": safeFailureMessage,
                    "generic_file_search_invoked": "false",
                    "phase_2d_1_started": "false",
                    "success": "false"
                ].merging(runtimeStatePayload(mission: .failed, task: task.state, tool: .failed)) { current, _ in current }
            )
            return task
        }
    }

    private func recordSandboxActivity(
        _ phase: SandboxRuntimeActivityPhase,
        snapshot: SandboxActivitySnapshot,
        workspace: Workspace,
        task: FDETask
    ) async throws {
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: phase.rawValue,
            payload: snapshot.eventPayload.merging([
                "state": task.state.rawValue,
                "lifecycle_event": "SAFE_SANDBOX_ACTIVITY",
                "sandbox_activity_phase": phase.rawValue,
                "intent_type": MissionIntentType.safeSandboxAcceptance.rawValue,
                "workspace_identity": "legacy",
                "runtime_owned_activity": "true",
                "generic_file_search_invoked": "false",
                "phase_2d_1_started": "false"
            ]) { current, _ in current }
            .merging(runtimeStatePayload(mission: .execute, task: task.state, tool: .running)) { current, _ in current }
        )
    }

    func submitTask(input: String, workspace: Workspace) async throws -> FDETask {
        let missionStartedAt = Date()
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw RuntimeKernelError.emptyInput
        }
        let missionIntent = MissionIntentParser().parse(trimmed)
        let missionSemantic = MissionExecutionSemantic(intent: missionIntent)
        let missionWorkspaceScope = missionSemantic == .readOnlyWorkspaceInspection
            ? MissionWorkspaceScope(request: trimmed)
            : .legacyAndAgentComparison
        let selectedReadOnlyBudget = readOnlyInspectionLimits.budget(
            for: trimmed,
            workspaceScope: missionWorkspaceScope
        )
        var readOnlyMissionTiming = ReadOnlyMissionTiming(
            startedAt: missionStartedAt,
            budget: selectedReadOnlyBudget,
            operationBudget: readOnlyInspectionLimits.operationBudget(for: selectedReadOnlyBudget.kind)
        )
        let readOnlyEvidenceRequirements = ReadOnlyEvidenceRequirements(request: trimmed)
        if requiresProjectScope, !hasRequiredProjectScope(
            workspace: workspace,
            semantic: missionSemantic,
            request: trimmed
        ) {
            throw RuntimeKernelError.projectRootRequired
        }
        let completionContract = RuntimeCompletionContract(input: trimmed, intent: missionIntent)

        let createDecision = authorizationService.authorize(
            .createTask,
            workspace: workspace,
            action: "create task",
            resource: trimmed
        )
        guard createDecision.allowed else {
            try await recordAuthorizationDenied(createDecision, workspaceID: workspace.id, taskID: nil, extraPayload: [:])
            throw AuthorizationError.denied(createDecision)
        }

        let title = makeTitle(from: trimmed)
        var task = FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: title,
            rawInput: trimmed,
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )

        var taskCreatedPayload: [String: String] = [
            "state": task.state.rawValue,
            "workspace_id": workspace.id.uuidString,
            "org_id": workspace.orgID.uuidString,
            "role": workspace.role.rawValue,
            "intent_type": missionIntent.intentType.rawValue,
            "intent_confidence": String(missionIntent.confidence),
            "intent_language": missionIntent.detectedLanguage,
            "mission_workspace_scope": missionWorkspaceScope.rawValue,
            "event_namespace": workspace.eventNamespace
        ]
        if missionSemantic == .readOnlyWorkspaceInspection {
            taskCreatedPayload.merge(readOnlyMissionTiming.auditPayload()) { current, _ in current }
            taskCreatedPayload.merge(readOnlyEvidenceRequirements.auditPayload(evidence: [])) { current, _ in current }
            taskCreatedPayload["lifecycle_event"] = "MISSION_BUDGET_SELECTED"
            taskCreatedPayload["mission_timer_start"] = "task_submission"
            taskCreatedPayload["planning_counts_toward_budget"] = "true"
            taskCreatedPayload["provider_retries_count_toward_budget"] = "true"
        }
        try await record(
            type: .taskCreated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Task created",
            payload: taskCreatedPayload
                .merging(runtimeStatePayload(mission: .understand, task: task.state)) { current, _ in current }
                .merging(workTracePayload(.understanding, summary: "Mission accepted", detail: "Created runtime task and started system understanding.")) { current, _ in current },
            initialTask: task
        )

        let recentTasks = try await persistence.loadTasks(workspaceID: workspace.id)
        let graph = try await persistence.loadGraph(workspaceID: workspace.id)
        let workspaceEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
        let policyDeltas = try await persistence.loadPolicyDeltas(workspaceID: workspace.id)
        let systemFailureProfile = try await persistence.loadLatestSystemFailureProfile(workspaceID: workspace.id)
        let globalExecutionPolicy = try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)
        let contextCompilationStartedAt = Date()
        let context: ExecutionContext
        do {
            if missionSemantic == .readOnlyWorkspaceInspection {
                context = try await withReadOnlyHardDeadline(
                    deadline: readOnlyMissionTiming.hardDeadline,
                    stage: "context_compilation"
                ) { [contextCompiler] in
                    await contextCompiler.compile(
                        workspace: workspace,
                        taskInput: trimmed,
                        missionWorkspaceScope: missionWorkspaceScope,
                        recentTasks: recentTasks,
                        graph: graph,
                        policyDeltas: policyDeltas,
                        workspaceEvents: workspaceEvents,
                        failureEvents: workspaceEvents.filter { $0.type == .toolFailed },
                        systemFailureProfile: systemFailureProfile,
                        globalExecutionPolicy: globalExecutionPolicy
                    )
                }
            } else {
                context = await contextCompiler.compile(
                    workspace: workspace,
                    taskInput: trimmed,
                    missionWorkspaceScope: missionWorkspaceScope,
                    recentTasks: recentTasks,
                    graph: graph,
                    policyDeltas: policyDeltas,
                    workspaceEvents: workspaceEvents,
                    failureEvents: workspaceEvents.filter { $0.type == .toolFailed },
                    systemFailureProfile: systemFailureProfile,
                    globalExecutionPolicy: globalExecutionPolicy
                )
            }
        } catch {
            readOnlyMissionTiming.contextCompilation += Date().timeIntervalSince(contextCompilationStartedAt)
            return try await blockReadOnlyInspection(
                task: &task,
                workspace: workspace,
                reason: .durationLimitReached,
                detail: "The read-only mission reached its hard duration deadline during context compilation. Pending work was cancelled and no completion is claimed.",
                providerStage: "context_compilation",
                providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                timingPayload: readOnlyMissionTiming.auditPayload(),
                evidenceRequirementsPayload: readOnlyEvidenceRequirements.auditPayload(evidence: [])
            )
        }
        if missionSemantic == .readOnlyWorkspaceInspection {
            readOnlyMissionTiming.contextCompilation += Date().timeIntervalSince(contextCompilationStartedAt)
        }
        var worldModel = systemUnderstandingLayer.initialModel(
            workspace: workspace,
            context: context,
            recentTasks: recentTasks,
            workspaceEvents: workspaceEvents,
            policyDeltas: policyDeltas,
            systemFailureProfile: systemFailureProfile,
            globalExecutionPolicy: globalExecutionPolicy
        )
        try await recordContextCompiled(context, workspace: workspace, taskID: task.id, worldModel: worldModel)

        var output: StructuredAgentOutput
        let planningStartedAt = Date()
        let plannerTaskSnapshot = task
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Planner request pending",
            payload: [
                "state": task.state.rawValue,
                "lifecycle_event": "PROVIDER_REQUEST_PENDING",
                "provider_stage": "planner",
                "provider_request_pending": "true",
                "success": ""
            ].merging(runtimeStatePayload(mission: .plan, task: task.state, tool: .idle)) { current, _ in current }
        )
        do {
            if missionSemantic == .readOnlyWorkspaceInspection {
                output = try await withReadOnlyHardDeadline(
                    deadline: readOnlyMissionTiming.hardDeadline,
                    stage: "planning"
                ) { [self] in
                    try await generatePlannerOutput(
                        input: trimmed,
                        context: context,
                        workspace: workspace,
                        task: plannerTaskSnapshot
                    )
                }
            } else {
                output = try await generatePlannerOutput(
                    input: trimmed,
                    context: context,
                    workspace: workspace,
                    task: task
                )
            }
        } catch {
            if missionSemantic == .readOnlyWorkspaceInspection {
                readOnlyMissionTiming.planning += Date().timeIntervalSince(planningStartedAt)
            }
            if let deadlineError = error as? ReadOnlyMissionDeadlineError,
               case .hardDeadlineReached(let stage) = deadlineError {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .durationLimitReached,
                    detail: "The read-only mission reached its hard duration deadline during \(stage); pending work was cancelled and no completion is claimed.",
                    providerStage: stage,
                    providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                    timingPayload: readOnlyMissionTiming.auditPayload(),
                    evidenceRequirementsPayload: readOnlyEvidenceRequirements.auditPayload(evidence: [])
                )
            }
            let failure = ModelRoutingError.classified(error)
            let providerFailure = error as? ModelProviderFailure
            let plannerTimedOut = isPlannerTimeout(error)
            try stateMachine.transition(&task, to: .blocked)
            try await persistence.saveTask(task)
            var failurePayload: [String: String] = [
                "state": task.state.rawValue,
                "lifecycle_event": "PLANNER_PROVIDER_FAILED",
                "blocker_reason": plannerTimedOut ? PlanReadinessBlocker.plannerTimeout.rawValue : "planner_\(failure.diagnosticReason)",
                "provider_stage": "planner",
                "provider_diagnostic": failure.diagnosticReason,
                "detail": AgentPresentationSanitizer.safeContent(failure.localizedDescription, fallback: failure.diagnosticReason),
                "retry_exhausted": plannerTimedOut ? "true" : "false",
                "retry_later_allowed": "true",
                "response_language": missionIntent.detectedLanguage,
                "successful_read_evidence": "false",
                "success": "false"
            ]
            failurePayload.merge(plannerRequestAudit(input: trimmed, context: context)) { current, _ in current }
            failurePayload.merge(providerFailure?.auditPayload ?? [:]) { current, _ in current }
            if missionSemantic == .readOnlyWorkspaceInspection {
                failurePayload.merge(readOnlyMissionTiming.auditPayload()) { current, _ in current }
                failurePayload.merge(readOnlyEvidenceRequirements.auditPayload(evidence: [])) { current, _ in current }
            }
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: plannerTimedOut ? "Planner request timed out" : "Planner model unavailable: \(failure.diagnosticReason)",
                payload: failurePayload
                    .merging(runtimeStatePayload(mission: .blocked, task: task.state, tool: .skipped)) { current, _ in current }
            )
            return task
        }
        if missionSemantic == .readOnlyWorkspaceInspection {
            readOnlyMissionTiming.planning += Date().timeIntervalSince(planningStartedAt)
        }
        let governorResult = globalGovernor.govern(
            taskID: task.id,
            workspaceID: workspace.id,
            plannerOutput: output,
            globalPolicy: globalExecutionPolicy,
            systemFailureProfile: systemFailureProfile
        )
        output = governorResult.output
        try validator.validate(output)
        try await persistence.saveGlobalGovernorDecision(governorResult.decision)

        task.plan = output.plan
        try stateMachine.transition(&task, to: .planned)
        try await persistence.saveTask(task)
        let workingDirectorySources = output.toolCalls.prefix(20).map { call in
            let source = call.workingDirectory?.isEmpty == false ? "model_supplied" : "runtime_pending"
            return "\(call.id):\(source)"
        }.joined(separator: " | ")
        var planGeneratedPayload: [String: String] = [
            "state": task.state.rawValue,
            "confidence": String(output.confidence),
            "plan_step_count": String(output.plan.count),
            "tool_call_count": String(output.toolCalls.count),
            "plan_step_ids": output.plan.prefix(20).map(\.id).joined(separator: " | "),
            "tool_call_ids": output.toolCalls.prefix(20).map(\.id).joined(separator: " | "),
            "tool_commands": output.toolCalls.prefix(20).map(\.command).joined(separator: " | "),
            "tool_call_arguments": readOnlyPlannerArgumentSummary(output),
            "tool_call_working_directory_sources": workingDirectorySources,
            "governor_decision_id": governorResult.decision.id.uuidString,
            "governor_strategy": governorResult.decision.selectedStrategy.rawValue,
            "governor_overrides": String(governorResult.decision.overrides.count),
            "system_efficiency_score": String(governorResult.decision.efficiencyScore.score),
            "completion_contract": completionContract.kind.rawValue,
            "mission_disposition": completionContract.isPlanOnly ? "PLANNED" : "EXECUTABLE",
            "model_output_json": safeReadOnlyModelOutput(output)
        ]
        planGeneratedPayload.merge(runtimeStatePayload(mission: .plan, task: task.state)) { current, _ in current }
        planGeneratedPayload.merge(
            workTracePayload(
                .planning,
                summary: "Plan generated",
                detail: "Structured plan selected \(output.plan.count) steps and \(output.toolCalls.count) tool calls."
            )
        ) { current, _ in current }
        try await record(
            type: .planGenerated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Structured plan generated",
            payload: planGeneratedPayload
        )

        if completionContract.isPlanOnly {
            return task
        }

        if completionPolicy == .evidenceRequired,
           missionSemantic == .readOnlyWorkspaceInspection {
            return try await runReadOnlyInspection(
                originalOutput: output,
                context: context,
                worldModel: &worldModel,
                workspace: workspace,
                task: &task,
                completionContract: completionContract,
                missionTiming: &readOnlyMissionTiming,
                evidenceRequirements: readOnlyEvidenceRequirements
            )
        }

        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)
        var executionStarted = false

        stepLoop: for (stepIndex, step) in output.plan.enumerated() {
            guard let toolCallID = step.toolCallID,
                  let call = output.toolCalls.first(where: { $0.id == toolCallID }) else {
                continue
            }

            let checkpoint = RuntimeStepCheckpoint(
                workspaceID: workspace.id,
                taskID: task.id,
                stepID: step.id,
                stepIndex: stepIndex,
                stepTitle: step.title,
                toolCallID: call.id,
                command: call.command,
                phase: .beforeStep
            )
            switch await stepAdapter.directive(for: checkpoint) {
            case .continue:
                break
            case .waitForUser(let reason):
                try await pauseTaskForUser(
                    &task,
                    workspace: workspace,
                    step: step,
                    call: call,
                    reason: reason
                )
                let resumeDirective = await stepAdapter.waitForResume(taskID: task.id)
                switch try await handleResumeDirective(
                    resumeDirective,
                    task: &task,
                    workspace: workspace,
                    step: step,
                    call: call
                ) {
                case .runStep:
                    break
                case .skipStep:
                    continue stepLoop
                case .finishTask:
                    return task
                }
            case .changeApproach(let instruction):
                switch try await handleApproachChange(
                    instruction,
                    task: &task,
                    workspace: workspace,
                    step: step,
                    call: call
                ) {
                case .runStep:
                    break
                case .skipStep:
                    continue stepLoop
                case .finishTask:
                    return task
                }
            case .stop(let reason):
                try await stopTaskForUser(
                    &task,
                    workspace: workspace,
                    step: step,
                    call: call,
                    reason: reason
                )
                return task
            }
            let authorizationDecision = authorizationService.authorize(
                .executeTool,
                workspace: workspace,
                action: "execute tool",
                resource: call.command
            )
            guard authorizationDecision.allowed else {
                try await recordAuthorizationDenied(
                    authorizationDecision,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    extraPayload: [
                        "step_id": step.id,
                        "tool_call_id": call.id,
                        "command": call.command,
                        "tool_type": call.type.rawValue
                    ]
                )
                continue
            }
            var executableCall = call
            do {
                executableCall = try scopedToolCall(call, workspace: workspace)
            } catch {
                try await record(
                    type: .toolFailed,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Project scope blocked \(call.id): \(error.localizedDescription)",
                    payload: [
                        "step_id": step.id,
                        "tool_call_id": call.id,
                        "command": call.command,
                        "arguments": safeArguments(call.arguments),
                        "working_directory": call.workingDirectory ?? "",
                        "project_root": workspace.localProjectRoot ?? "",
                        "agent_project_root": workspace.localAgentProjectRoot ?? "",
                        "allowed_project_roots": workspace.localProjectScopeRootURLs.map(\.path).joined(separator: " | "),
                        "error": error.localizedDescription
                    ].merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .failed)) { current, _ in current }
                )
                continue
            }
            let riskAssessment = riskAssessmentEngine.assess(
                step: step,
                toolCall: executableCall,
                workspace: workspace,
                globalPolicy: globalExecutionPolicy,
                systemFailureProfile: systemFailureProfile,
                governorDecision: governorResult.decision,
                policyDeltas: policyDeltas,
                plannerRisks: output.risks
            )
            let policyEvaluation = policyEngine.evaluate(
                PolicyInput(workspace: workspace, toolCall: executableCall, risk: riskAssessment),
                globallyAvoided: isGloballyAvoidedTool(executableCall.command, context: context)
            )

            if policyEvaluation.status == .denied {
                try stateMachine.transition(&task, to: .failed)
                try await persistence.saveTask(task)
                try await record(
                    type: .authorizationDenied,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Policy denied \(step.title)",
                    payload: [
                        "state": task.state.rawValue,
                        "step_id": step.id,
                        "tool_call_id": call.id,
                        "command": call.command,
                        "tool_type": call.type.rawValue,
                        "risk_level": riskAssessment.level.rawValue,
                        "risk_reasons": riskAssessment.reasons.joined(separator: " | "),
                        "reason": policyEvaluation.summary
                    ].merging(riskAssessment.auditPayload) { current, _ in current }
                        .merging(policyEvaluation.auditPayload) { current, _ in current }
                        .merging(runtimeStatePayload(mission: .adapt, task: task.state, tool: .failed)) { current, _ in current }
                        .merging(workTracePayload(.adaptation, summary: "Policy denied action", detail: policyEvaluation.summary)) { current, _ in current }
                )
                return task
            }

            let risk = RiskClassification(
                level: riskAssessment.level,
                reasons: riskAssessment.reasons + policyEvaluation.reasons,
                requiresApproval: policyEvaluation.requiresApproval
            )
            let toolDecision = decisionEngine.decideToolExecution(
                step: step,
                toolCall: executableCall,
                risk: risk
            )

            if policyEvaluation.requiresApproval {
                let approvalRequest = ApprovalRequest(
                    id: UUID(),
                    workspaceID: workspace.id,
                    taskID: task.id,
                    stepID: step.id,
                    toolCallID: call.id,
                    targetKind: call.type == .connector ? .connectorOperation : .toolCall,
                    action: "execute tool",
                    resource: call.command,
                    riskLevel: riskAssessment.level,
                    state: .pending,
                    requestedByRole: workspace.role,
                    decidedByRole: nil,
                    decisionReason: nil,
                    requestedAt: Date(),
                    decidedAt: nil,
                    expiresAt: Date().addingTimeInterval(15 * 60),
                    metadata: [
                        "step_title": step.title,
                        "tool_type": call.type.rawValue,
                        "working_directory": executableCall.workingDirectory ?? "",
                        "risk_reasons": riskAssessment.reasons.joined(separator: " | "),
                        "policy_decision": policyEvaluation.status.rawValue,
                        "policy_reasons": policyEvaluation.summary,
                        "governor_decision_id": governorResult.decision.id.uuidString,
                        "mission_state": toolDecision.state.missionState.rawValue,
                        "task_state": toolDecision.state.taskState?.rawValue ?? "",
                        "tool_state": toolDecision.state.toolState.rawValue
                    ].merging(riskAssessment.auditPayload) { current, _ in current }
                        .merging(policyEvaluation.auditPayload) { current, _ in current }
                )
                _ = try await approvalQueue.enqueue(approvalRequest)
                try stateMachine.transition(&task, to: .pendingApproval)
                try await persistence.saveTask(task)
                try await record(
                    type: .humanApprovalRequested,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "High-risk approval requested for \(step.title)",
                    payload: [
                        "approval_request_id": approvalRequest.id.uuidString,
                        "step_id": step.id,
                        "tool_call_id": call.id,
                        "command": call.command,
                        "risk_level": riskAssessment.level.rawValue,
                        "risk_reasons": riskAssessment.reasons.joined(separator: " | "),
                        "state": task.state.rawValue
                    ].merging(toolDecision.auditPayload) { current, _ in current }
                        .merging(riskAssessment.auditPayload) { current, _ in current }
                        .merging(policyEvaluation.auditPayload) { current, _ in current }
                )

                let decidedRequest = try await approvalQueue.waitForDecision(requestID: approvalRequest.id)
                switch decidedRequest.state {
                case .approved:
                    try stateMachine.transition(&task, to: .running)
                    try await persistence.saveTask(task)
                    try await record(
                        type: .humanApproved,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        summary: "Approval granted for \(step.title)",
                        payload: [
                            "approval_request_id": decidedRequest.id.uuidString,
                            "step_id": step.id,
                            "tool_call_id": call.id,
                            "command": call.command,
                            "decided_by_role": decidedRequest.decidedByRole?.rawValue ?? "",
                            "decision_reason": decidedRequest.decisionReason ?? ""
                        ].merging(runtimeStatePayload(mission: .execute, task: task.state, tool: .authorized)) { current, _ in current }
                    )
                    executableCall.requiresApproval = false
                case .rejected, .superseded, .expired:
                    try stateMachine.transition(&task, to: .failed)
                    try await persistence.saveTask(task)
                    try await record(
                        type: .humanRejected,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        summary: "Approval \(decidedRequest.state.rawValue) for \(step.title)",
                        payload: [
                            "approval_request_id": decidedRequest.id.uuidString,
                            "step_id": step.id,
                            "tool_call_id": call.id,
                            "command": call.command,
                            "approval_state": decidedRequest.state.rawValue,
                            "decided_by_role": decidedRequest.decidedByRole?.rawValue ?? "",
                            "decision_reason": decidedRequest.decisionReason ?? ""
                        ].merging(runtimeStatePayload(mission: .complete, task: task.state, tool: .skipped)) { current, _ in current }
                    )
                    return task
                case .pending:
                    continue
                }
            }

            var didExecute = false
            var lastError: Error?
            let maxAttempts = max(1, step.retryBudget + 1)

            for attempt in 1...maxAttempts {
                if !executionStarted {
                    try await record(
                        type: .stateUpdated,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        summary: "Execution started",
                        payload: ["state": task.state.rawValue]
                            .merging(runtimeStatePayload(mission: .execute, task: task.state, tool: .running)) { current, _ in current }
                            .merging(workTracePayload(.execution, summary: "Execution started", detail: "A validated tool call is ready to run.")) { current, _ in current }
                    )
                    executionStarted = true
                }
                if executableCall.type == .connector {
                    try await record(
                        type: .connectorCalled,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        summary: "\(executableCall.command) connector request prepared",
                        payload: [
                            "step_id": step.id,
                            "tool_call_id": executableCall.id,
                            "command": executableCall.command,
                            "attempt": String(attempt),
                            "network": "disabled"
                        ].merging(runtimeStatePayload(mission: .execute, task: task.state, tool: .running)) { current, _ in current }
                            .merging(workTracePayload(.execution, summary: "Connector request prepared", detail: "Prepared \(executableCall.command) for local execution.")) { current, _ in current }
                    )
                }
                try await record(
                    type: .toolCalled,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: attempt == 1 ? "\(executableCall.type.rawValue): \(executableCall.command)" : "\(executableCall.type.rawValue): \(executableCall.command) retry \(attempt)",
                    payload: [
                        "step_id": step.id,
                        "tool_call_id": executableCall.id,
                        "command": executableCall.command,
                        "arguments": safeArguments(executableCall.arguments),
                        "working_directory": executableCall.workingDirectory ?? "",
                        "attempt": String(attempt),
                        "max_attempts": String(maxAttempts),
                        "retry": attempt == 1 ? "false" : "true",
                        "risk_level": riskAssessment.level.rawValue,
                        "risk_reasons": riskAssessment.reasons.joined(separator: " | ")
                    ].merging(toolDecision.auditPayload) { current, _ in current }
                        .merging(riskAssessment.auditPayload) { current, _ in current }
                        .merging(policyEvaluation.auditPayload) { current, _ in current }
                        .merging(runtimeStatePayload(mission: .execute, task: task.state, tool: .running)) { _, next in next }
                        .merging(workTracePayload(.execution, summary: "Running tool", detail: "Executing \(executableCall.command) for step \(step.id).")) { current, _ in current }
                )
                do {
                    let result = try await toolExecutor.execute(executableCall)
                    let observation = observationLoop.observeResult(
                        step: step,
                        toolCall: executableCall,
                        result: result,
                        attempt: attempt,
                        maxAttempts: maxAttempts
                    )
                    worldModel = systemUnderstandingLayer.applying(observation, to: worldModel)
                    let observedToolState: ToolExecutionState = observation.outcome == .succeeded ? .succeeded : .failed
                    try await recordToolExecutionEvents(
                        result.emittedEvents,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        stepID: step.id,
                        toolCallID: executableCall.id,
                        command: executableCall.command,
                        attempt: attempt
                    )
                    try await record(
                        type: .stepExecuted,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        summary: step.title,
                        payload: [
                            "step_id": step.id,
                            "tool_call_id": executableCall.id,
                            "command": executableCall.command,
                            "arguments": safeArguments(executableCall.arguments),
                            "working_directory": executableCall.workingDirectory ?? "",
                            "attempt": String(attempt),
                            "exit_code": String(result.exitCode),
                            "stdout": String(result.standardOutput.prefix(500)),
                            "stderr": String(result.standardError.prefix(500))
                        ].merging(runtimeStatePayload(mission: .observe, task: task.state, tool: observedToolState)) { current, _ in current }
                            .merging(observation.auditPayload) { current, _ in current }
                            .merging(worldModel.auditPayload) { current, _ in current }
                            .merging(workTracePayload(.observation, summary: "Observed tool result", detail: observation.summary)) { current, _ in current }
                    )
                    if observation.outcome == .succeeded {
                        didExecute = true
                        break
                    }
                    lastError = ToolExecutionError.processFailed("Non-zero exit code \(result.exitCode) from \(executableCall.command)")
                } catch {
                    lastError = error
                    let observation = observationLoop.observeFailure(
                        step: step,
                        toolCall: executableCall,
                        error: error,
                        attempt: attempt,
                        maxAttempts: maxAttempts
                    )
                    worldModel = systemUnderstandingLayer.applying(observation, to: worldModel)
                    if let connectorFailure = error as? ConnectorExecutionFailure {
                        try await recordToolExecutionEvents(
                            connectorFailure.emittedEvents,
                            workspaceID: workspace.id,
                            taskID: task.id,
                            stepID: step.id,
                            toolCallID: executableCall.id,
                            command: executableCall.command,
                            attempt: attempt
                        )
                    }
                    if executableCall.type == .connector {
                        try await record(
                            type: .connectorFailed,
                            workspaceID: workspace.id,
                            taskID: task.id,
                            summary: "\(executableCall.command) connector request failed: \(error.localizedDescription)",
                            payload: [
                                "step_id": step.id,
                                "tool_call_id": executableCall.id,
                                "command": executableCall.command,
                                "arguments": safeArguments(executableCall.arguments),
                                "working_directory": executableCall.workingDirectory ?? "",
                                "attempt": String(attempt),
                                "error": error.localizedDescription,
                                "network": "disabled"
                            ].merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .failed)) { current, _ in current }
                                .merging(observation.auditPayload) { current, _ in current }
                                .merging(worldModel.auditPayload) { current, _ in current }
                                .merging(workTracePayload(.observation, summary: "Observed connector failure", detail: observation.summary)) { current, _ in current }
                        )
                    }
                    try await record(
                        type: .toolFailed,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        summary: "\(call.id) failed on attempt \(attempt): \(error.localizedDescription)",
                        payload: [
                            "step_id": step.id,
                            "tool_call_id": executableCall.id,
                            "command": executableCall.command,
                            "arguments": safeArguments(executableCall.arguments),
                            "working_directory": executableCall.workingDirectory ?? "",
                            "attempt": String(attempt),
                            "max_attempts": String(maxAttempts)
                        ].merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .failed)) { current, _ in current }
                            .merging(observation.auditPayload) { current, _ in current }
                            .merging(worldModel.auditPayload) { current, _ in current }
                            .merging(workTracePayload(.observation, summary: "Observed tool failure", detail: observation.summary)) { current, _ in current }
                    )
                }
            }

            if !didExecute, let lastError {
                let replan = replanningEngine.replan(
                    failedStep: step,
                    failedCall: executableCall,
                    error: lastError,
                    worldModel: worldModel,
                    recoveryAgent: recoveryAgent
                )
                if !task.plan.contains(where: { $0.id == replan.modifiedStep.id }) {
                    task.plan.append(replan.modifiedStep)
                    try await persistence.saveTask(task)
                }
                let recoveryCall = try scopedToolCall(replan.recoveryCall, workspace: workspace)
                try await record(
                    type: .recoveryAttempted,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Recovery agent replacing \(executableCall.id) with \(recoveryCall.id)",
                    payload: [
                        "failed_tool_call_id": executableCall.id,
                        "failed_command": executableCall.command,
                        "recovery_tool_call_id": recoveryCall.id,
                        "recovery_command": recoveryCall.command,
                        "working_directory": recoveryCall.workingDirectory ?? ""
                    ].merging(runtimeStatePayload(mission: .adapt, task: task.state, tool: .failed)) { current, _ in current }
                        .merging(replan.auditPayload) { current, _ in current }
                        .merging(worldModel.auditPayload) { current, _ in current }
                        .merging(workTracePayload(.adaptation, summary: "Replanned after failure", detail: "Created a recovery hypothesis and appended \(replan.modifiedStep.id).")) { current, _ in current }
                )
                let recoveryDecision = authorizationService.authorize(
                    .executeTool,
                    workspace: workspace,
                    action: "execute recovery tool",
                    resource: recoveryCall.command
                )
                guard recoveryDecision.allowed else {
                    try await recordAuthorizationDenied(
                        recoveryDecision,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        extraPayload: [
                            "failed_tool_call_id": executableCall.id,
                            "failed_command": executableCall.command,
                            "recovery_tool_call_id": recoveryCall.id,
                            "recovery_command": recoveryCall.command,
                            "working_directory": recoveryCall.workingDirectory ?? ""
                        ]
                    )
                    continue
                }
                let recoveryResult = try await toolExecutor.execute(recoveryCall)
                let recoveryObservation = observationLoop.observeResult(
                    step: replan.modifiedStep,
                    toolCall: recoveryCall,
                    result: recoveryResult,
                    attempt: 1,
                    maxAttempts: 1
                )
                worldModel = systemUnderstandingLayer.applying(recoveryObservation, to: worldModel)
                try await record(
                    type: .stepExecuted,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Recovery agent captured failure",
                    payload: [
                        "tool_call_id": recoveryCall.id,
                        "command": recoveryCall.command,
                        "working_directory": recoveryCall.workingDirectory ?? "",
                        "exit_code": String(recoveryResult.exitCode),
                        "stdout": recoveryResult.standardOutput
                    ].merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .succeeded)) { current, _ in current }
                        .merging(recoveryObservation.auditPayload) { current, _ in current }
                        .merging(worldModel.auditPayload) { current, _ in current }
                        .merging(workTracePayload(.observation, summary: "Observed recovery result", detail: recoveryObservation.summary)) { current, _ in current }
                )
            }
        }

        let eventsBeforeScoring = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        if completionPolicy == .evidenceRequired {
            let gate = completionContract.evaluate(events: eventsBeforeScoring)
            guard gate.allowed else {
                try stateMachine.transition(&task, to: .failed)
                try await persistence.saveTask(task)
                try await record(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Completion gate blocked completion: \(gate.reason)",
                    payload: [
                        "state": task.state.rawValue,
                        "completion_contract": completionContract.kind.rawValue,
                        "actual_result": gate.report,
                        "success": "false"
                    ].merging(runtimeStatePayload(mission: .adapt, task: task.state, tool: .failed)) { current, _ in current }
                        .merging(gate.auditPayload) { current, _ in current }
                        .merging(worldModel.auditPayload) { current, _ in current }
                        .merging(workTracePayload(.observation, summary: "Completion blocked", detail: gate.report)) { current, _ in current }
                )
                return task
            }

            try stateMachine.transition(&task, to: .completed)
            task.riskScore = 0
            task.failureProbability = 0
            task.performanceScore = 0
            try await persistence.saveTask(task)
            let finalEventsBeforeCompletion = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
            try await record(
                type: .taskCompleted,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Task completed with verified tool evidence",
                payload: [
                    "state": task.state.rawValue,
                    "completion_contract": completionContract.kind.rawValue,
                    "completion_evidence": gate.report,
                    "detail": gate.report,
                    "metrics_status": "not_scored_in_evidence_required_mode",
                    "actual_result": gate.report,
                    "success": "true"
                ].merging(runtimeStatePayload(mission: .complete, task: task.state)) { current, _ in current }
                    .merging(gate.auditPayload) { current, _ in current }
                    .merging(worldModel.auditPayload) { current, _ in current }
                    .merging(workTracePayload(.completion, summary: "Mission completed", detail: gate.report)) { current, _ in current }
            )
            let finalEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
            let snapshot = graphEngine.buildSnapshot(workspace: workspace, task: task, output: output, events: finalEvents.isEmpty ? finalEventsBeforeCompletion : finalEvents)
            try await persistence.saveGraph(nodes: snapshot.nodes, edges: snapshot.edges)
            return task
        }
        let assessment = uncertaintyEngine.assess(output: output, events: eventsBeforeScoring)
        task.riskScore = assessment.realityRiskScore
        task.failureProbability = assessment.failureProbability
        try stateMachine.transition(&task, to: .completed)

        let outcome = outcomeTracker.score(workspaceID: workspace.id, taskID: task.id, task: task, events: eventsBeforeScoring)
        task.performanceScore = outcome.fdePerformanceScore
        try await persistence.saveTask(task)
        try await persistence.saveOutcome(outcome)

        let completionEvent = try await record(
            type: .taskCompleted,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Task completed with legacy metrics risk \(Int(task.riskScore)) and performance \(Int(task.performanceScore))",
            payload: [
                "state": task.state.rawValue,
                "risk_score": String(task.riskScore),
                "failure_probability": String(task.failureProbability),
                "performance_score": String(task.performanceScore)
            ].merging(runtimeStatePayload(mission: .complete, task: task.state)) { current, _ in current }
                .merging(worldModel.auditPayload) { current, _ in current }
                .merging(workTracePayload(.completion, summary: "Mission completed", detail: "Runtime scored outcome and closed the mission loop.")) { current, _ in current }
        )

        let eventsWithCompletion = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let insights = feedbackEngine.insights(for: task, events: eventsWithCompletion, assessment: assessment)
        var policyParentEventID: UUID? = completionEvent.id

        for insight in insights {
            try await persistence.saveFeedback(insight)
            let feedbackEvent = try await record(
                type: .feedbackGenerated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: insight.title,
                payload: [
                    "feedback_id": insight.id.uuidString,
                    "kind": insight.kind.rawValue,
                    "detail": insight.detail
                ].merging(runtimeStatePayload(mission: .complete, task: task.state)) { current, _ in current }
            )
            policyParentEventID = feedbackEvent.id
        }

        let eventsWithFeedback = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let deltas = feedbackPolicyEngine.policyDeltas(
            for: task,
            feedback: insights,
            events: eventsWithFeedback,
            parentEventID: policyParentEventID
        )

        if !deltas.isEmpty {
            let policyDecision = authorizationService.authorize(
                .updatePolicy,
                workspace: workspace,
                action: "update execution policy",
                resource: task.id.uuidString
            )
            if policyDecision.allowed {
                for delta in deltas {
                    let policyRisk = riskClassifier.classifyPolicyUpdate(delta: delta, workspace: workspace)
                    try await persistence.savePolicyDelta(delta)
                    try await record(
                        type: .policyUpdated,
                        workspaceID: workspace.id,
                        taskID: task.id,
                        summary: delta.summary,
                        payload: [
                            "policy_delta_id": delta.id.uuidString,
                            "kind": delta.kind.rawValue,
                            "task_fingerprint": delta.taskFingerprint,
                            "avoid_tool_command": delta.avoidToolCommand ?? "",
                            "replacement_tool_command": delta.replacementToolCommand ?? "",
                            "retry_budget": String(delta.retryBudget),
                            "policy_namespace": workspace.policyNamespace,
                            "risk_level": policyRisk.level.rawValue,
                            "risk_reasons": policyRisk.reasons.joined(separator: " | ")
                        ].merging(runtimeStatePayload(mission: .complete, task: task.state)) { current, _ in current }
                    )
                }
            } else {
                try await recordAuthorizationDenied(
                    policyDecision,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    extraPayload: ["policy_delta_count": String(deltas.count)]
                )
            }
        }

        let finalEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let allPolicyDeltas = try await persistence.loadPolicyDeltas(workspaceID: workspace.id)
        _ = try await systemLearningEngine.learn(
            task: task,
            events: finalEvents,
            localPolicyDeltas: allPolicyDeltas,
            persistence: persistence
        )
        try await recordQualityLearning(
            task: task,
            workspace: workspace,
            events: finalEvents
        )
        let snapshot = graphEngine.buildSnapshot(workspace: workspace, task: task, output: output, events: finalEvents)
        try await persistence.saveGraph(nodes: snapshot.nodes, edges: snapshot.edges)

        return task
    }

    private func recordQualityLearning(
        task: FDETask,
        workspace: Workspace,
        events: [ExecutionEvent]
    ) async throws {
        let finalState = OutcomeTrackingLayer.inferredFinalState(task: task, events: events)
            ?? (task.state == .completed ? .complete : .adapt)
        let outcomeRecord = OutcomeTrackingLayer().record(
            missionID: task.id,
            objective: task.rawInput,
            finalState: finalState,
            events: events,
            task: task
        )
        let approvals = try await persistence.loadApprovalRequests(workspaceID: workspace.id, state: nil)
            .filter { $0.taskID == task.id }
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
        let errors = events
            .filter { [.toolFailed, .connectorFailed, .authorizationDenied, .humanRejected, .userApprovalRejected].contains($0.type) }
            .map(\.summary)
        let humanDecisions = approvals
            .filter { $0.state != .pending }
            .map { approval in
                "\(approval.state.rawValue): \(approval.action) \(approval.decisionReason ?? "")"
            }
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
        let feedback = memoryImprovementPipeline.reflectionFeedback(reflection)
        try await persistence.saveFeedback(feedback)
        try await memoryImprovementPipeline.store(
            update,
            persistence: persistence,
            enterpriseMemoryStore: enterpriseMemoryStore,
            saveTaskExecutionMemory: false
        )
        try await record(
            type: .feedbackGenerated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Agent quality feedback generated",
            payload: [
                "feedback_id": feedback.id.uuidString,
                "kind": feedback.kind.rawValue,
                "quality_score": String(evaluation.overallScore),
                "planning_accuracy": String(evaluation.planningAccuracy),
                "execution_efficiency": String(evaluation.executionEfficiency),
                "recovery_success": String(evaluation.recoverySuccess),
                "human_intervention_quality": String(evaluation.humanInterventionQuality),
                "policy_violations": String(evaluation.policyViolations),
                "outcome_achievement": String(evaluation.outcomeAchievement),
                "detail": feedback.detail
            ].merging(runtimeStatePayload(mission: .complete, task: task.state)) { current, _ in current }
        )
    }

    func replay(taskID: UUID, workspaceID: UUID) async throws -> [ReplayFrame] {
        let events = try await persistence.loadEvents(workspaceID: workspaceID, taskID: taskID)
        _ = eventStream.replay(.task(workspaceID: workspaceID, taskID: taskID))
        let graph = try await persistence.loadGraph(workspaceID: workspaceID)
        return try ReplayEngine().frames(events: events, graph: graph)
    }

    private func generatePlannerOutput(
        input: String,
        context: ExecutionContext,
        workspace: Workspace,
        task: FDETask
    ) async throws -> StructuredAgentOutput {
        do {
            return try await modelRouter.generatePlan(for: input, context: context)
        } catch {
            let firstProviderFailure = error as? ModelProviderFailure
            guard isPlannerTimeout(error), firstProviderFailure?.retryable != false else {
                throw error
            }
            var retryPayload: [String: String] = [
                "lifecycle_event": "PROVIDER_RETRY_REQUESTED",
                "provider_stage": "planner",
                "provider_diagnostic": ModelRoutingError.classified(error).diagnosticReason,
                "retry_attempt": "1",
                "max_retries": "1",
                "success": "false"
            ]
            retryPayload.merge(plannerRequestAudit(input: input, context: context)) { current, _ in current }
            retryPayload.merge(firstProviderFailure?.auditPayload ?? [:]) { current, _ in current }
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Retrying planner after timeout",
                payload: retryPayload
                    .merging(runtimeStatePayload(mission: .plan, task: task.state, tool: .idle)) { current, _ in current }
            )
            do {
                return try await modelRouter.generatePlan(for: input, context: context)
            } catch var secondFailure as ModelProviderFailure {
                secondFailure.attempts = 2
                throw secondFailure
            }
        }
    }

    private func withReadOnlyHardDeadline<Value: Sendable>(
        deadline: Date,
        stage: String,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw ReadOnlyMissionDeadlineError.hardDeadlineReached(stage: stage)
        }
        let nanoseconds = UInt64(max(1, min(remaining * 1_000_000_000, Double(UInt64.max))))
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanoseconds)
                try Task.checkCancellation()
                throw ReadOnlyMissionDeadlineError.hardDeadlineReached(stage: stage)
            }
            do {
                guard let first = try await group.next() else {
                    group.cancelAll()
                    throw ReadOnlyMissionDeadlineError.hardDeadlineReached(stage: stage)
                }
                group.cancelAll()
                return first
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    private func isPlannerTimeout(_ error: Error) -> Bool {
        if let providerFailure = error as? ModelProviderFailure {
            return providerFailure.failurePhase == "timeout"
                || providerFailure.safeErrorType == "timeout"
        }
        let detail = error.localizedDescription.lowercased()
        return detail.contains("timed out") || detail.contains("timeout")
    }

    private func plannerRequestAudit(input: String, context: ExecutionContext) -> [String: String] {
        let bundleBytes = context.contextBundle.flatMap { try? JSONCoding.encode($0).utf8.count } ?? 0
        let prompt = RemoteStructuredOutputParser.compiledPrompt(
            for: .planning,
            input: input,
            context: context
        )
        return [
            "planner_input_bytes": String(input.utf8.count),
            "planner_context_bytes": String(bundleBytes),
            "planner_system_prompt_bytes": String(prompt.systemInstruction.utf8.count),
            "planner_user_prompt_bytes": String(prompt.userPrompt.utf8.count),
            "planner_prompt_bytes": String(prompt.systemInstruction.utf8.count + prompt.userPrompt.utf8.count),
            "planner_codebase_count": String(context.contextBundle?.codebases.count ?? 0),
            "mission_workspace_scope": context.missionWorkspaceScope?.rawValue ?? ""
        ]
    }

    func missionReplay(taskID: UUID, workspaceID: UUID) async throws -> MissionReplay {
        let events = try await persistence.loadEvents(workspaceID: workspaceID, taskID: taskID)
        let task = try await persistence.loadTasks(workspaceID: workspaceID).first { $0.id == taskID }
        let approvals = try await persistence.loadApprovalRequests(workspaceID: workspaceID, state: nil)
            .filter { $0.taskID == taskID }
        return MissionReplayBuilder().reconstruct(task: task, events: events, approvals: approvals)
    }

    func loadAuditEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent] {
        try await persistence.loadEvents(workspaceID: workspaceID, taskID: taskID)
    }

    func recoverTask(
        taskID: UUID,
        instruction: String,
        workspace: Workspace
    ) async throws -> FDETask? {
        let recoveryStartedAt = Date()
        guard var task = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == taskID }),
              task.state == .blocked else {
            return nil
        }
        let originalIntent = MissionIntentParser().parse(task.rawInput)
        guard MissionExecutionSemantic(intent: originalIntent) == .readOnlyWorkspaceInspection else {
            return nil
        }

        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)
        let recoveryAttempt = events.filter {
            $0.type == .recoveryAttempted && $0.payload["recovery_kind"] == "read_only_same_task"
        }.count + 1
        guard recoveryAttempt <= 2 else {
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Read-only recovery attempt limit reached",
                payload: [
                    "state": TaskState.blocked.rawValue,
                    "lifecycle_event": "RECOVERY_BLOCKED",
                    "blocker_reason": "recovery_attempt_limit_reached",
                    "recovery_attempt": String(recoveryAttempt),
                    "max_recovery_attempts": "2",
                    "retry_later_allowed": "false",
                    "success": "false"
                ].merging(runtimeStatePayload(mission: .blocked, task: task.state, tool: .skipped)) { current, _ in current }
            )
            return task
        }

        let originalScope = MissionWorkspaceScope(request: task.rawInput)
        let recoveryScope = explicitMissionWorkspaceScope(in: instruction) ?? originalScope
        guard recoveryScope == originalScope else {
            return nil
        }
        let safeInstruction = AgentPresentationSanitizer.safeContent(
            instruction,
            fallback: "Retry the current read-only mission"
        )
        let baseEffectiveRequest = "\(task.rawInput)\n\nUser clarification for same-task recovery: \(safeInstruction)"
        // A continuation narrows execution; it must not redefine the original
        // material evidence contract merely because it names already-read files.
        let recoveryRequirements = ReadOnlyEvidenceRequirements(request: baseEffectiveRequest)
        let priorEvidence = restoredReadOnlyEvidence(from: events, workspace: workspace)
        let completedSignatures = restoredReadOnlyCommandSignatures(from: events)
        let failedSignatures = restoredReadOnlyFailedCommandSignatures(from: events)
        let successfulReadPaths = Set(
            priorEvidence.filter { $0.toolName == "engineering.read_file" }.map(\.targetPath)
        )
        let discoveredUnreadPaths = Set(
            priorEvidence.flatMap { $0.structuredFacts.discoveredPaths }
        ).subtracting(successfulReadPaths).sorted()
        let explicitNoRereadPaths = readOnlyExplicitNoRereadPaths(
            in: safeInstruction,
            successfullyReadPaths: successfulReadPaths
        )
        let recoveryLedgerPayload = recoveryRequirements.auditPayload(evidence: priorEvidence)
        let remainingRequirements = recoveryRequirements.unsatisfied(by: priorEvidence).map(\.rawValue)
        let satisfiedRequirements = recoveryRequirements.satisfied(by: priorEvidence).map(\.rawValue)
        let effectiveRequest = """
        \(baseEffectiveRequest)

        Same-task continuation state:
        - exact continuation instruction: \(safeInstruction)
        - satisfied evidence requirements: \(satisfiedRequirements.joined(separator: " | "))
        - unsatisfied evidence requirements: \(remainingRequirements.joined(separator: " | "))
        - successfully inspected relative paths: \(successfulReadPaths.sorted().joined(separator: " | "))
        - discovered but unread canonical relative paths: \(discoveredUnreadPaths.joined(separator: " | "))
        - completed command signatures: \(completedSignatures.sorted().joined(separator: " | "))
        - failed command signatures: \(failedSignatures.sorted().joined(separator: " | "))
        - explicit no-reread relative paths: \(explicitNoRereadPaths.sorted().joined(separator: " | "))
        - previous evidence ledger: \(recoveryLedgerPayload["requirement_evidence_ledger"] ?? "[]")
        Completed and failed operations are unavailable by default. Do not repeat completed commands or an explicitly forbidden reread. Plan only the highest-value unsatisfied read-only evidence target.
        """
        let recoveryBudget = readOnlyInspectionLimits.budget(for: effectiveRequest, workspaceScope: originalScope)
        var recoveryTiming = ReadOnlyMissionTiming(
            startedAt: recoveryStartedAt,
            budget: recoveryBudget,
            operationBudget: readOnlyInspectionLimits.operationBudget(for: recoveryBudget.kind)
        )
        let priorBlocker = events.reversed().compactMap { $0.payload["blocker_reason"] }.first ?? "unknown"
        let hasReadEvidence = events.contains {
            $0.type == .stepExecuted
                && $0.payload["success"] == "true"
                && $0.payload["command"] == "engineering.read_file"
        }

        try await record(
            type: .recoveryAttempted,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Retrying the same read-only task",
            payload: [
                "lifecycle_event": "TASK_RECOVERY_REQUESTED",
                "recovery_kind": "read_only_same_task",
                "recovery_attempt": String(recoveryAttempt),
                "max_recovery_attempts": "2",
                "recovery_reason": "user_clarification_or_retry",
                "prior_blocker": priorBlocker,
                "clarification_text": safeInstruction,
                "resumed_stage": "planner",
                "mission_workspace_scope": originalScope.rawValue,
                "prior_evidence_available": hasReadEvidence ? "true" : "false",
                "same_task_id_preserved": "true",
                "original_task_id": task.id.uuidString,
                "recovered_task_id": task.id.uuidString,
                "exact_continuation_instruction": safeInstruction,
                "satisfied_evidence_requirements": satisfiedRequirements.joined(separator: " | "),
                "unsatisfied_evidence_requirements": remainingRequirements.joined(separator: " | "),
                "successful_inspected_paths": successfulReadPaths.sorted().joined(separator: " | "),
                "discovered_only_paths": discoveredUnreadPaths.joined(separator: " | "),
                "restored_completed_command_signatures": completedSignatures.sorted().joined(separator: " | "),
                "restored_failed_command_signatures": failedSignatures.sorted().joined(separator: " | "),
                "explicit_no_reread_paths": explicitNoRereadPaths.sorted().joined(separator: " | "),
                "previous_evidence_ledger": recoveryLedgerPayload["requirement_evidence_ledger"] ?? "[]",
                "success": ""
            ].merging(runtimeStatePayload(mission: .adapt, task: task.state, tool: .idle)) { current, _ in current }
        )

        let recentTasks = try await persistence.loadTasks(workspaceID: workspace.id)
        let graph = try await persistence.loadGraph(workspaceID: workspace.id)
        let workspaceEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
        let policyDeltas = try await persistence.loadPolicyDeltas(workspaceID: workspace.id)
        let systemFailureProfile = try await persistence.loadLatestSystemFailureProfile(workspaceID: workspace.id)
        let globalExecutionPolicy = try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)
        let contextStartedAt = Date()
        let context: ExecutionContext
        do {
            context = try await withReadOnlyHardDeadline(
                deadline: recoveryTiming.hardDeadline,
                stage: "context_compilation"
            ) { [contextCompiler] in
                await contextCompiler.compile(
                    workspace: workspace,
                    taskInput: effectiveRequest,
                    missionWorkspaceScope: originalScope,
                    recentTasks: recentTasks,
                    graph: graph,
                    policyDeltas: policyDeltas,
                    workspaceEvents: workspaceEvents,
                    failureEvents: workspaceEvents.filter { $0.type == .toolFailed },
                    systemFailureProfile: systemFailureProfile,
                    globalExecutionPolicy: globalExecutionPolicy
                )
            }
        } catch {
            recoveryTiming.contextCompilation += Date().timeIntervalSince(contextStartedAt)
            return try await blockReadOnlyInspection(
                task: &task,
                workspace: workspace,
                reason: .durationLimitReached,
                detail: "The resumed read-only mission reached its hard deadline during context compilation. Prior evidence was preserved and no completion is claimed.",
                providerStage: "context_compilation",
                providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                timingPayload: recoveryTiming.auditPayload(),
                evidenceRequirementsPayload: recoveryRequirements.auditPayload(evidence: priorEvidence)
            )
        }
        recoveryTiming.contextCompilation += Date().timeIntervalSince(contextStartedAt)
        var worldModel = systemUnderstandingLayer.initialModel(
            workspace: workspace,
            context: context,
            recentTasks: recentTasks,
            workspaceEvents: workspaceEvents,
            policyDeltas: policyDeltas,
            systemFailureProfile: systemFailureProfile,
            globalExecutionPolicy: globalExecutionPolicy
        )
        try await recordContextCompiled(context, workspace: workspace, taskID: task.id, worldModel: worldModel)

        let output: StructuredAgentOutput
        let planningStartedAt = Date()
        let plannerTaskSnapshot = task
        do {
            output = try await withReadOnlyHardDeadline(
                deadline: recoveryTiming.hardDeadline,
                stage: "planning"
            ) { [self] in
                try await generatePlannerOutput(
                    input: effectiveRequest,
                    context: context,
                    workspace: workspace,
                    task: plannerTaskSnapshot
                )
            }
            try validator.validate(output)
            recoveryTiming.planning += Date().timeIntervalSince(planningStartedAt)
        } catch {
            recoveryTiming.planning += Date().timeIntervalSince(planningStartedAt)
            if let deadlineError = error as? ReadOnlyMissionDeadlineError,
               case .hardDeadlineReached(let stage) = deadlineError {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .durationLimitReached,
                    detail: "The resumed read-only mission reached its hard deadline during \(stage). Prior evidence was preserved and no completion is claimed.",
                    providerStage: stage,
                    providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                    timingPayload: recoveryTiming.auditPayload(),
                    evidenceRequirementsPayload: recoveryRequirements.auditPayload(evidence: priorEvidence)
                )
            }
            let failure = ModelRoutingError.classified(error)
            let providerFailure = error as? ModelProviderFailure
            let plannerTimedOut = isPlannerTimeout(error)
            var payload: [String: String] = [
                "state": task.state.rawValue,
                "lifecycle_event": "PLANNER_PROVIDER_FAILED",
                "blocker_reason": plannerTimedOut ? PlanReadinessBlocker.plannerTimeout.rawValue : "planner_\(failure.diagnosticReason)",
                "provider_stage": "planner",
                "provider_diagnostic": failure.diagnosticReason,
                "detail": AgentPresentationSanitizer.safeContent(failure.localizedDescription, fallback: failure.diagnosticReason),
                "recovery_attempt": String(recoveryAttempt),
                "recovery_outcome": "blocked",
                "retry_later_allowed": "true",
                "response_language": originalIntent.detectedLanguage,
                "successful_read_evidence": hasReadEvidence ? "true" : "false",
                "success": "false"
            ]
            payload.merge(plannerRequestAudit(input: effectiveRequest, context: context)) { current, _ in current }
            payload.merge(providerFailure?.auditPayload ?? [:]) { current, _ in current }
            payload.merge(recoveryTiming.auditPayload()) { current, _ in current }
            payload.merge(recoveryRequirements.auditPayload(evidence: priorEvidence)) { current, _ in current }
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: plannerTimedOut ? "Planner request timed out" : "Planner model unavailable: \(failure.diagnosticReason)",
                payload: payload
                    .merging(runtimeStatePayload(mission: .blocked, task: task.state, tool: .skipped)) { current, _ in current }
            )
            return task
        }

        try stateMachine.transition(&task, to: .planned)
        task.plan = output.plan
        try await persistence.saveTask(task)
        var recoveryPlanPayload: [String: String] = [
            "state": task.state.rawValue,
            "lifecycle_event": "RECOVERY_PLAN_GENERATED",
            "recovery_attempt": String(recoveryAttempt),
            "recovery_outcome": "plan_generated",
            "plan_step_count": String(output.plan.count),
            "tool_call_count": String(output.toolCalls.count),
            "tool_call_ids": output.toolCalls.prefix(20).map(\.id).joined(separator: " | "),
            "tool_commands": output.toolCalls.prefix(20).map(\.command).joined(separator: " | "),
            "tool_call_arguments": readOnlyPlannerArgumentSummary(output),
            "model_output_json": safeReadOnlyModelOutput(output),
            "mission_workspace_scope": originalScope.rawValue,
            "same_task_id_preserved": "true",
            "fresh_duration_budget": "true",
            "fresh_operation_budget": "true",
            "completed_command_signatures_preserved": String(completedSignatures.count),
            "failed_command_signatures_preserved": String(failedSignatures.count),
            "restored_completed_command_signatures": completedSignatures.sorted().joined(separator: " | "),
            "restored_failed_command_signatures": failedSignatures.sorted().joined(separator: " | "),
            "explicit_no_reread_paths": explicitNoRereadPaths.sorted().joined(separator: " | "),
            "successful_inspected_paths": successfulReadPaths.sorted().joined(separator: " | "),
            "discovered_only_paths": discoveredUnreadPaths.joined(separator: " | "),
            "exact_continuation_instruction": safeInstruction,
            "remaining_evidence_requirements": remainingRequirements.joined(separator: " | "),
            "success": "true"
        ]
        recoveryPlanPayload.merge(recoveryTiming.auditPayload()) { current, _ in current }
        recoveryPlanPayload.merge(recoveryRequirements.auditPayload(evidence: priorEvidence)) { current, _ in current }
        recoveryPlanPayload.merge(runtimeStatePayload(mission: .plan, task: task.state, tool: .idle)) { current, _ in current }
        try await record(
            type: .planGenerated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Structured recovery plan generated",
            payload: recoveryPlanPayload
        )

        return try await runReadOnlyInspection(
            originalOutput: output,
            context: context,
            worldModel: &worldModel,
            workspace: workspace,
            task: &task,
            completionContract: RuntimeCompletionContract(input: task.rawInput, intent: originalIntent),
            missionRequest: effectiveRequest,
            missionTiming: &recoveryTiming,
            evidenceRequirements: recoveryRequirements
        )
    }

    func pendingApprovals(workspaceID: UUID) async throws -> [ApprovalRequest] {
        try await approvalQueue.pendingRequests(workspaceID: workspaceID)
    }

    func requestStepPause(taskID: UUID, reason: String) async {
        await stepAdapter.requestPause(taskID: taskID, reason: reason)
    }

    func resumeTask(taskID: UUID, instruction: String? = nil) async {
        await stepAdapter.resume(taskID: taskID, instruction: instruction)
    }

    func changeTaskApproach(taskID: UUID, instruction: String) async {
        await stepAdapter.changeApproach(taskID: taskID, instruction: instruction)
    }

    func stopTask(taskID: UUID, reason: String) async {
        await stepAdapter.stop(taskID: taskID, reason: reason)
    }

    @discardableResult
    func approveApprovalRequest(_ requestID: UUID, workspace: Workspace, reason: String) async throws -> ApprovalRequest {
        let request = try await approvalQueue.load(requestID: requestID)
        if request?.targetKind == .candidatePatchPlan {
            throw CandidatePatchRuntimeError.approvalConfirmationRequired
        }
        let decision = authorizationService.authorize(
            .approveRiskyAction,
            workspace: workspace,
            action: "approve high-risk action",
            resource: requestID.uuidString
        )
        guard decision.allowed else {
            try await recordAuthorizationDenied(
                decision,
                workspaceID: workspace.id,
                taskID: request?.taskID,
                extraPayload: ["approval_request_id": requestID.uuidString]
            )
            throw AuthorizationError.denied(decision)
        }
        let approved = try await approvalQueue.approve(
            requestID: requestID,
            approverRole: workspace.role,
            reason: reason
        )
        return approved
    }

    func beginCandidatePatchApprovalConfirmation(
        _ requestID: UUID,
        workspace: Workspace,
        context: CandidatePatchApprovalUIContext,
        source: CandidatePatchApprovalSource,
        now: Date = Date()
    ) async throws -> CandidatePatchApprovalConfirmation {
        let validated = try await validateCandidatePatchApprovalBinding(
            requestID,
            workspace: workspace,
            context: context,
            source: source
        )
        let confirmation = CandidatePatchApprovalConfirmation(
            confirmationStepID: UUID(),
            approvalRequestID: validated.request.id,
            workspaceID: workspace.id,
            taskID: validated.task.id,
            planID: validated.manifest.plan.planID,
            planRevision: validated.manifest.plan.revision,
            assessmentID: validated.manifest.plan.assessmentID,
            sourceSnapshotID: validated.manifest.plan.sourceSnapshotID,
            canonicalLegacyRoot: validated.manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
            authenticatedUserSessionID: context.authenticatedUserSessionID,
            appSessionID: context.appSessionID,
            openingSource: source,
            affectedRelativePaths: validated.manifest.plan.operations.map(\.relativeCanonicalSandboxPath),
            capability: validated.manifest.plan.requestedCapabilityID,
            issuedAt: now
        )
        let service = CandidatePatchService(lifecycle: validated.lifecycle)
        _ = try service.recordApprovalConfirmationOpened(
            sandboxID: validated.pending.sandboxID,
            patchID: validated.pending.patchID,
            confirmation: confirmation,
            now: now
        )
        candidatePatchApprovalConfirmations[confirmation.confirmationStepID] = confirmation
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: validated.task.id,
            summary: "Candidate Patch approval confirmation opened",
            payload: [
                "lifecycle_event": "CANDIDATE_PATCH_APPROVAL_CONFIRMATION_OPENED",
                "approval_source": source.rawValue,
                "approval_request_id": requestID.uuidString,
                "plan_id": confirmation.planID.uuidString,
                "plan_revision": String(confirmation.planRevision),
                "confirmation_step_id": confirmation.confirmationStepID.uuidString,
                "app_session_id": confirmation.appSessionID.uuidString,
                "controller_path": "AppStore.approve -> RuntimeKernel.beginCandidatePatchApprovalConfirmation",
                "ui_action": "candidatePatch.approve.openConfirmation",
                "approval_emitted": "false",
                "workspace_mutation_count": "0",
                "legacy_writes": "0",
                "sandbox_writes": "0",
                "sandbox_readiness_checked": "false"
            ]
        )
        return confirmation
    }

    func cancelCandidatePatchApprovalConfirmation(_ confirmationStepID: UUID) {
        candidatePatchApprovalConfirmations.removeValue(forKey: confirmationStepID)
    }

    @discardableResult
    func confirmCandidatePatchApproval(
        _ confirmation: CandidatePatchApprovalConfirmation,
        workspace: Workspace,
        context: CandidatePatchApprovalUIContext,
        source: CandidatePatchApprovalSource,
        reason: String,
        now: Date = Date()
    ) async throws -> ApprovalRequest {
        guard let issued = candidatePatchApprovalConfirmations.removeValue(
            forKey: confirmation.confirmationStepID
        ), issued == confirmation else {
            throw CandidatePatchRuntimeError.approvalConfirmationInvalid
        }
        let validated = try await validateCandidatePatchApprovalBinding(
            confirmation.approvalRequestID,
            workspace: workspace,
            context: context,
            source: source
        )
        guard confirmation.workspaceID == workspace.id,
              confirmation.taskID == validated.task.id,
              confirmation.planID == validated.manifest.plan.planID,
              confirmation.planRevision == validated.manifest.plan.revision,
              confirmation.approvalRequestID == validated.request.id,
              confirmation.assessmentID == validated.manifest.plan.assessmentID,
              confirmation.sourceSnapshotID == validated.manifest.plan.sourceSnapshotID,
              confirmation.canonicalLegacyRoot == validated.manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
              confirmation.authenticatedUserSessionID == context.authenticatedUserSessionID,
              confirmation.appSessionID == context.appSessionID else {
            throw CandidatePatchRuntimeError.approvalConfirmationInvalid
        }
        let decision = authorizationService.authorize(
            .approveRiskyAction,
            workspace: workspace,
            action: "confirm Candidate Patch plan approval",
            resource: confirmation.approvalRequestID.uuidString
        )
        guard decision.allowed else {
            try await recordAuthorizationDenied(
                decision,
                workspaceID: workspace.id,
                taskID: validated.task.id,
                extraPayload: ["approval_request_id": confirmation.approvalRequestID.uuidString]
            )
            throw AuthorizationError.denied(decision)
        }
        try await validateApprovedCandidatePatchAssessment(validated.manifest.plan, workspace: workspace)
        let provenance = CandidatePatchApprovalProvenance(
            source: source,
            workspaceID: workspace.id,
            taskID: validated.task.id,
            planID: confirmation.planID,
            planRevision: confirmation.planRevision,
            approvalRequestID: confirmation.approvalRequestID,
            assessmentID: confirmation.assessmentID,
            sourceSnapshotID: confirmation.sourceSnapshotID,
            canonicalLegacyRoot: confirmation.canonicalLegacyRoot,
            authenticatedUserSessionID: confirmation.authenticatedUserSessionID,
            appSessionID: confirmation.appSessionID,
            confirmationStepID: confirmation.confirmationStepID,
            timestamp: now,
            controllerPath: "CandidatePatchApprovalConfirmationView.confirm -> AppStore.confirmCandidatePatchApproval -> RuntimeKernel.confirmCandidatePatchApproval",
            uiAction: "candidatePatch.approve.confirm"
        )
        let approved = try await approvalQueue.approve(
            requestID: confirmation.approvalRequestID,
            approverRole: workspace.role,
            reason: reason,
            metadata: provenance.sanitizedMetadata
        )
        try await record(
            type: .humanApproved,
            workspaceID: workspace.id,
            taskID: validated.task.id,
            summary: "Confirmed Candidate Patch approval recorded",
            payload: provenance.sanitizedMetadata.merging([
                "lifecycle_event": "CANDIDATE_PATCH_APPROVAL_CONFIRMED",
                "approval_confirmation_opened": "true",
                "approval_confirmation_confirmed": "true"
            ]) { current, _ in current }
        )
        try await applyApprovedCandidatePatch(
            approved,
            workspace: workspace,
            reason: reason,
            provenance: provenance
        )
        return approved
    }

    @discardableResult
    func approveCandidatePatchForTest(
        _ requestID: UUID,
        workspace: Workspace,
        reason: String
    ) async throws -> ApprovalRequest {
        guard allowsCandidatePatchTestApproval,
              let request = try await approvalQueue.load(requestID: requestID),
              let taskID = request.taskID else {
            throw CandidatePatchRuntimeError.approvalSourceInvalid
        }
        let context = CandidatePatchApprovalUIContext(
            currentWorkspaceID: workspace.id,
            currentTaskID: taskID,
            visiblePendingApprovalRequestIDs: [requestID],
            authenticatedUserSessionID: UUID(),
            appSessionID: UUID()
        )
        let confirmation = try await beginCandidatePatchApprovalConfirmation(
            requestID,
            workspace: workspace,
            context: context,
            source: .testFixture
        )
        return try await confirmCandidatePatchApproval(
            confirmation,
            workspace: workspace,
            context: context,
            source: .testFixture,
            reason: reason
        )
    }

    func beginCandidatePatchRevertConfirmation(
        patchID: CandidatePatchID,
        sandboxID: SandboxID,
        workspace: Workspace,
        context: CandidatePatchRevertUIContext,
        source: CandidatePatchApprovalSource,
        now: Date = Date()
    ) async throws -> CandidatePatchRevertConfirmation {
        guard source != .replay,
              context.currentWorkspaceID == workspace.id,
              context.visiblePatchID == patchID,
              context.visibleSandboxID == sandboxID,
              let lifecycle = sandboxLifecycle else {
            throw CandidatePatchRuntimeError.approvalSourceInvalid
        }
        let service = CandidatePatchService(lifecycle: lifecycle)
        let target: CandidatePatchRevertTarget
        let requestingTaskID: UUID
        if let pending = pendingCandidatePatchReverts[context.currentTaskID],
           pending.binding.patchID == patchID,
           pending.binding.sandboxID == sandboxID {
            target = pending
            requestingTaskID = context.currentTaskID
        } else {
            target = try service.locateRevertTarget(
                workspaceID: workspace.id,
                request: "revert exact Candidate Patch \(patchID.rawValue) in Sandbox \(sandboxID.rawValue)"
            )
            requestingTaskID = context.currentTaskID
        }
        guard target.binding.authenticatedLocalSessionID == context.authenticatedLocalSessionID else {
            throw CandidatePatchError.blocked(.authenticatedSessionMismatch)
        }
        _ = try service.prepareRevert(binding: target.binding)
        let confirmation = CandidatePatchRevertConfirmation(
            confirmationStepID: UUID(),
            binding: target.binding,
            requestingTaskID: requestingTaskID,
            appSessionID: context.appSessionID,
            openingSource: source,
            filesToRestore: target.filesToRestore,
            filesToRemove: target.filesToRemove,
            issuedAt: now
        )
        _ = try service.recordRevertConfirmationOpened(confirmation, now: now)
        candidatePatchRevertConfirmations[confirmation.confirmationStepID] = confirmation
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: requestingTaskID,
            summary: "Candidate Patch Revert confirmation opened",
            payload: [
                "lifecycle_event": "CANDIDATE_PATCH_REVERT_CONFIRMATION_OPENED",
                "intent_type": MissionIntentType.candidatePatchRevert.rawValue,
                "candidate_patch_id": patchID.rawValue,
                "candidate_patch_sandbox_id": sandboxID.rawValue,
                "candidate_patch_projection_state": CandidatePatchProjectionState.revertConfirmationRequired.rawValue,
                "manifest_id": target.binding.manifestID,
                "plan_id": target.binding.planID.uuidString,
                "plan_revision": String(target.binding.planRevision),
                "confirmation_step_id": confirmation.confirmationStepID.uuidString,
                "ui_action": "candidatePatch.revert.openConfirmation",
                "controller_path": "AgentConversationView.revert -> AppStore.openCandidatePatchRevertConfirmation -> RuntimeKernel.beginCandidatePatchRevertConfirmation",
                "sandbox_writes": "0",
                "legacy_writes": "0",
                "approval_emitted": "false"
            ]
        )
        return confirmation
    }

    func cancelCandidatePatchRevertConfirmation(_ confirmationStepID: UUID) async {
        guard let confirmation = candidatePatchRevertConfirmations.removeValue(forKey: confirmationStepID),
              let lifecycle = sandboxLifecycle else { return }
        try? CandidatePatchService(lifecycle: lifecycle).recordRevertConfirmationCancelled(
            binding: confirmation.binding
        )
        if var task = try? await persistence.loadTasks(workspaceID: confirmation.binding.workspaceID)
            .first(where: { $0.id == confirmation.requestingTaskID }),
           task.state == .pendingApproval {
            try? stateMachine.transition(&task, to: .failed)
            try? await persistence.saveTask(task)
        }
        _ = try? await record(
            type: .stateUpdated,
            workspaceID: confirmation.binding.workspaceID,
            taskID: confirmation.requestingTaskID,
            summary: "Candidate Patch Revert confirmation cancelled",
            payload: [
                "lifecycle_event": "CANDIDATE_PATCH_REVERT_CONFIRMATION_CANCELLED",
                "candidate_patch_id": confirmation.binding.patchID.rawValue,
                "candidate_patch_sandbox_id": confirmation.binding.sandboxID.rawValue,
                "candidate_patch_projection_state": CandidatePatchProjectionState.patchReady.rawValue,
                "sandbox_writes": "0",
                "legacy_writes": "0"
            ]
        )
        pendingCandidatePatchReverts.removeValue(forKey: confirmation.requestingTaskID)
    }

    func confirmCandidatePatchRevert(
        _ confirmation: CandidatePatchRevertConfirmation,
        workspace: Workspace,
        context: CandidatePatchRevertUIContext,
        source: CandidatePatchApprovalSource,
        now: Date = Date()
    ) async throws -> CandidatePatchManifest {
        guard let issued = candidatePatchRevertConfirmations.removeValue(
            forKey: confirmation.confirmationStepID
        ), issued == confirmation,
              source != .replay,
              confirmation.openingSource == source,
              confirmation.binding.workspaceID == workspace.id,
              confirmation.binding.patchID == context.visiblePatchID,
              confirmation.binding.sandboxID == context.visibleSandboxID,
              confirmation.binding.authenticatedLocalSessionID == context.authenticatedLocalSessionID,
              confirmation.appSessionID == context.appSessionID,
              let lifecycle = sandboxLifecycle else {
            throw CandidatePatchRuntimeError.approvalConfirmationInvalid
        }
        let authorization = authorizationService.authorize(
            .approveRiskyAction,
            workspace: workspace,
            action: "confirm exact-bound Candidate Patch Revert",
            resource: confirmation.binding.manifestID
        )
        guard authorization.allowed else {
            throw AuthorizationError.denied(authorization)
        }
        guard var task = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == confirmation.requestingTaskID }),
              task.state == .pendingApproval else {
            throw CandidatePatchRuntimeError.approvalConfirmationInvalid
        }
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)
        let service = CandidatePatchService(lifecycle: lifecycle)
        _ = try service.prepareRevert(binding: confirmation.binding)
        var before = CandidatePatchActivitySnapshot(manifest: try service.loadManifest(
            sandboxID: confirmation.binding.sandboxID,
            patchID: confirmation.binding.patchID
        ))
        before.projectionState = .reverting
        try await recordCandidatePatchRevertActivity(
            .revertingCandidatePatch,
            snapshot: before,
            workspace: workspace,
            task: task,
            extraPayload: [
                "confirmation_step_id": confirmation.confirmationStepID.uuidString,
                "ui_action": "candidatePatch.revert.confirm",
                "controller_path": "CandidatePatchRevertConfirmationView.confirm -> AppStore.confirmCandidatePatchRevert -> RuntimeKernel.confirmCandidatePatchRevert"
            ]
        )
        let manifest = try service.revert(binding: confirmation.binding, now: now)
        var after = CandidatePatchActivitySnapshot(manifest: manifest)
        after.projectionState = .reverted
        try await recordCandidatePatchRevertActivity(
            .verifyingRestoredHashes,
            snapshot: after,
            workspace: workspace,
            task: task
        )
        try await recordCandidatePatchRevertActivity(
            .candidatePatchReverted,
            snapshot: after,
            workspace: workspace,
            task: task
        )
        try stateMachine.transition(&task, to: .completed)
        try await persistence.saveTask(task)
        try await record(
            type: .taskCompleted,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Candidate Patch reverted",
            payload: after.eventPayload.merging([
                "state": task.state.rawValue,
                "intent_type": MissionIntentType.candidatePatchRevert.rawValue,
                "completion_contract": RuntimeCompletionContractKind.candidatePatchRevert.rawValue,
                "manifest_backed": "true",
                "source_integrity": SourceIntegrityState.unchanged.rawValue,
                "sandbox_destroyed": "false",
                "audit_preserved": "true",
                "build_or_test_executed": "false",
                "shell_execution_enabled": "false",
                "git_or_deployment_action_occurred": "false",
                "credential_or_production_action_occurred": "false",
                "success": "true"
            ]) { current, _ in current }
            .merging(runtimeStatePayload(mission: .complete, task: task.state, tool: .succeeded)) { current, _ in current }
        )
        pendingCandidatePatchReverts.removeValue(forKey: task.id)
        return manifest
    }

    func beginCandidatePatchSandboxDestructionConfirmation(
        patchID: CandidatePatchID,
        sandboxID: SandboxID,
        workspace: Workspace,
        context: CandidatePatchRevertUIContext,
        source: CandidatePatchApprovalSource,
        now: Date = Date()
    ) async throws -> CandidatePatchSandboxDestructionConfirmation {
        guard source != .replay,
              context.currentWorkspaceID == workspace.id,
              context.visiblePatchID == patchID,
              context.visibleSandboxID == sandboxID,
              let lifecycle = sandboxLifecycle else {
            throw CandidatePatchRuntimeError.approvalSourceInvalid
        }
        let service = CandidatePatchService(lifecycle: lifecycle)
        let target: CandidatePatchSandboxDestructionTarget
        if let pending = pendingCandidatePatchDestructions[context.currentTaskID],
           pending.binding.patchID == patchID,
           pending.binding.sandboxID == sandboxID {
            target = pending
        } else {
            target = try service.locateSandboxDestructionTarget(
                workspaceID: workspace.id,
                request: "destroy exact reverted Candidate Patch \(patchID.rawValue) Sandbox \(sandboxID.rawValue)"
            )
        }
        let binding = target.binding
        guard binding.workspaceID == workspace.id,
              binding.authenticatedLocalSessionID == context.authenticatedLocalSessionID else {
            throw CandidatePatchError.blocked(.authenticatedSessionMismatch)
        }
        _ = try service.prepareSandboxDestruction(binding: binding)
        let task: FDETask
        if let existing = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == context.currentTaskID }),
           pendingCandidatePatchDestructions[context.currentTaskID] != nil,
           existing.state == .pendingApproval {
            task = existing
        } else {
            var created = FDETask(
                id: UUID(),
                workspaceID: workspace.id,
                title: "Candidate Patch Sandbox Destruction",
                rawInput: "Destroy reverted Sandbox \(sandboxID.rawValue)",
                state: .created,
                plan: [],
                riskScore: 0,
                failureProbability: 0,
                performanceScore: 0,
                createdAt: now,
                updatedAt: now
            )
            try await record(
                type: .taskCreated,
                workspaceID: workspace.id,
                taskID: created.id,
                summary: "Separate Sandbox destruction task created",
                payload: [
                    "intent_type": MissionIntentType.candidatePatchSandboxDestroy.rawValue,
                    "candidate_patch_id": patchID.rawValue,
                    "candidate_patch_sandbox_id": sandboxID.rawValue,
                    "revert_task_created": "false"
                ],
                initialTask: created
            )
            created.plan = [PlanStep(
                id: "sandbox-destruction-confirmation",
                title: CandidatePatchActivityPhase.sandboxDestructionConfirmationRequired.rawValue,
                intent: "Destroy only the already-reverted Sandbox after separate explicit confirmation.",
                kind: .reasoning,
                toolCallID: nil,
                requiresApproval: true
            )]
            try stateMachine.transition(&created, to: .planned)
            try stateMachine.transition(&created, to: .running)
            try stateMachine.transition(&created, to: .pendingApproval)
            try await persistence.saveTask(created)
            pendingCandidatePatchDestructions[created.id] = target
            task = created
        }
        let confirmation = CandidatePatchSandboxDestructionConfirmation(
            confirmationStepID: UUID(),
            binding: binding,
            requestingTaskID: task.id,
            appSessionID: context.appSessionID,
            openingSource: source,
            issuedAt: now
        )
        _ = try service.recordSandboxDestructionConfirmationOpened(confirmation, now: now)
        candidatePatchDestructionConfirmations[confirmation.confirmationStepID] = confirmation
        var snapshot = CandidatePatchActivitySnapshot(manifest: try service.loadManifest(
            sandboxID: sandboxID,
            patchID: patchID
        ))
        snapshot.projectionState = .sandboxDestructionConfirmationRequired
        try await recordCandidatePatchRevertActivity(
            .sandboxDestructionConfirmationRequired,
            snapshot: snapshot,
            workspace: workspace,
            task: task,
            intentType: .candidatePatchSandboxDestroy,
            extraPayload: [
                "ui_action": "candidatePatch.destroySandbox.openConfirmation",
                "confirmation_step_id": confirmation.confirmationStepID.uuidString
            ]
        )
        return confirmation
    }

    func cancelCandidatePatchSandboxDestructionConfirmation(_ confirmationStepID: UUID) async {
        guard let confirmation = candidatePatchDestructionConfirmations.removeValue(
            forKey: confirmationStepID
        ), let lifecycle = sandboxLifecycle else { return }
        try? CandidatePatchService(lifecycle: lifecycle).recordSandboxDestructionConfirmationCancelled(
            binding: confirmation.binding
        )
        if var task = try? await persistence.loadTasks(workspaceID: confirmation.binding.workspaceID)
            .first(where: { $0.id == confirmation.requestingTaskID }),
           task.state == .pendingApproval {
            try? stateMachine.transition(&task, to: .failed)
            try? await persistence.saveTask(task)
        }
        pendingCandidatePatchDestructions.removeValue(forKey: confirmation.requestingTaskID)
    }

    func confirmCandidatePatchSandboxDestruction(
        _ confirmation: CandidatePatchSandboxDestructionConfirmation,
        workspace: Workspace,
        context: CandidatePatchRevertUIContext,
        source: CandidatePatchApprovalSource,
        now: Date = Date()
    ) async throws -> CandidatePatchManifest {
        guard let issued = candidatePatchDestructionConfirmations.removeValue(
            forKey: confirmation.confirmationStepID
        ), issued == confirmation,
              source != .replay,
              confirmation.openingSource == source,
              confirmation.binding.workspaceID == workspace.id,
              confirmation.binding.patchID == context.visiblePatchID,
              confirmation.binding.sandboxID == context.visibleSandboxID,
              confirmation.binding.authenticatedLocalSessionID == context.authenticatedLocalSessionID,
              confirmation.appSessionID == context.appSessionID,
              let lifecycle = sandboxLifecycle else {
            throw CandidatePatchRuntimeError.approvalConfirmationInvalid
        }
        let authorization = authorizationService.authorize(
            .approveRiskyAction,
            workspace: workspace,
            action: "confirm exact-bound reverted Candidate Patch Sandbox destruction",
            resource: confirmation.binding.manifestID
        )
        guard authorization.allowed else {
            throw AuthorizationError.denied(authorization)
        }
        guard var task = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == confirmation.requestingTaskID }),
              task.state == .pendingApproval else {
            throw CandidatePatchRuntimeError.approvalConfirmationInvalid
        }
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)
        let service = CandidatePatchService(lifecycle: lifecycle)
        let manifest = try service.destroyRevertedSandbox(binding: confirmation.binding, now: now)
        var snapshot = CandidatePatchActivitySnapshot(manifest: manifest)
        snapshot.projectionState = .sandboxDestroyed
        try await recordCandidatePatchRevertActivity(
            .sandboxDestroyed,
            snapshot: snapshot,
            workspace: workspace,
            task: task,
            intentType: .candidatePatchSandboxDestroy,
            extraPayload: ["ui_action": "candidatePatch.destroySandbox.confirm"]
        )
        try stateMachine.transition(&task, to: .completed)
        try await persistence.saveTask(task)
        try await record(
            type: .taskCompleted,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Reverted Sandbox destroyed",
            payload: snapshot.eventPayload.merging([
                "state": task.state.rawValue,
                "intent_type": MissionIntentType.candidatePatchSandboxDestroy.rawValue,
                "completion_contract": RuntimeCompletionContractKind.candidatePatchSandboxDestroy.rawValue,
                "manifest_backed": "true",
                "sandbox_destroyed": "true",
                "source_integrity": SourceIntegrityState.unchanged.rawValue,
                "audit_preserved": "true",
                "build_or_test_executed": "false",
                "shell_execution_enabled": "false",
                "git_or_deployment_action_occurred": "false",
                "credential_or_production_action_occurred": "false",
                "success": "true"
            ]) { current, _ in current }
        )
        pendingCandidatePatchDestructions.removeValue(forKey: task.id)
        return manifest
    }

    @discardableResult
    func rejectApprovalRequest(_ requestID: UUID, workspace: Workspace, reason: String) async throws -> ApprovalRequest {
        let request = try await approvalQueue.load(requestID: requestID)
        let decision = authorizationService.authorize(
            .approveRiskyAction,
            workspace: workspace,
            action: "reject high-risk action",
            resource: requestID.uuidString
        )
        guard decision.allowed else {
            try await recordAuthorizationDenied(
                decision,
                workspaceID: workspace.id,
                taskID: request?.taskID,
                extraPayload: ["approval_request_id": requestID.uuidString]
            )
            throw AuthorizationError.denied(decision)
        }
        let rejected = try await approvalQueue.reject(
            requestID: requestID,
            approverRole: workspace.role,
            reason: reason
        )
        if rejected.targetKind == .candidatePatchPlan {
            try await rejectCandidatePatch(rejected, workspace: workspace, reason: reason)
        }
        return rejected
    }

    @discardableResult
    func requestChangesApprovalRequest(
        _ requestID: UUID,
        workspace: Workspace,
        revisionInstructions: String
    ) async throws -> ApprovalRequest {
        let instructions = try normalizedCandidatePatchRevisionInstructions(revisionInstructions)
        guard let request = try await approvalQueue.load(requestID: requestID) else {
            throw ApprovalQueueError.requestNotFound(requestID)
        }
        guard request.targetKind == .candidatePatchPlan,
              request.state == .pending else {
            throw CandidatePatchRuntimeError.approvalMetadataInvalid
        }
        let authorization = authorizationService.authorize(
            .approveRiskyAction,
            workspace: workspace,
            action: "request Candidate Patch plan changes",
            resource: requestID.uuidString
        )
        guard authorization.allowed else {
            try await recordAuthorizationDenied(
                authorization,
                workspaceID: workspace.id,
                taskID: request.taskID,
                extraPayload: ["approval_request_id": requestID.uuidString]
            )
            throw AuthorizationError.denied(authorization)
        }
        guard let lifecycle = sandboxLifecycle,
              let provider = candidatePatchPlanProvider else {
            throw CandidatePatchRuntimeError.runtimeUnavailable
        }
        let pending = try candidatePatchPending(from: request)
        guard var task = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == pending.taskID }) else {
            throw CandidatePatchRuntimeError.approvalMetadataInvalid
        }
        let service = CandidatePatchService(lifecycle: lifecycle)
        let currentManifest = try service.loadManifest(
            sandboxID: pending.sandboxID,
            patchID: pending.patchID
        )
        guard currentManifest.status == .awaitingApproval,
              currentManifest.plan.status == .awaitingApproval,
              currentManifest.plan.approvalRequestID == request.id,
              request.metadata["plan_id"] == currentManifest.plan.planID.uuidString,
              request.metadata["plan_revision"] == String(currentManifest.plan.revision) else {
            throw CandidatePatchError.blocked(.planRevisionMismatch)
        }

        _ = try service.recordDecision(
            sandboxID: pending.sandboxID,
            patchID: pending.patchID,
            decision: .requestChanges,
            decidedBy: workspace.role.rawValue,
            rationale: instructions.joined(separator: " "),
            requestedChanges: instructions,
            approvalRequestID: request.id
        )
        _ = try await approvalQueue.supersede(
            requestID: request.id,
            approverRole: workspace.role,
            reason: instructions.joined(separator: " "),
            metadata: [
                "candidate_patch_decision": CandidatePatchApprovalDecision.requestChanges.rawValue,
                "revision_instructions": instructions.joined(separator: " | "),
                "superseded_plan_id": currentManifest.plan.planID.uuidString
            ]
        )
        pendingCandidatePatches.removeValue(forKey: request.id)
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)

        var revisionRequest = try await provider.planRequest(
            for: "Candidate Patch revision requested: \(instructions.joined(separator: " | "))",
            workspace: workspace,
            lifecycle: lifecycle
        )
        revisionRequest.patchID = pending.patchID
        revisionRequest.sandboxID = pending.sandboxID
        revisionRequest.requestedOutcome += " Requested revision: \(instructions.joined(separator: " "))"
        revisionRequest.proposedOperations = revisionRequest.proposedOperations.map { operation in
            var revised = operation
            revised.purpose += " Revision instruction: \(instructions.joined(separator: " "))"
            return revised
        }
        let revisedPlan = try service.preparePlan(revisionRequest)
        let freshApprovalID = UUID()
        var renderedRevisedPlan = revisedPlan
        renderedRevisedPlan.approvalRequestID = freshApprovalID
        let freshApproval = ApprovalRequest(
            id: freshApprovalID,
            workspaceID: workspace.id,
            taskID: task.id,
            stepID: "candidate-patch-plan-revision-\(revisedPlan.revision)",
            toolCallID: nil,
            targetKind: .candidatePatchPlan,
            action: "Approve revised Candidate Patch plan",
            resource: "Candidate Patch \(revisedPlan.patchID.rawValue) in Safe Sandbox \(revisedPlan.sandboxID.rawValue)",
            riskLevel: riskSeverity(revisedPlan.risk),
            state: .pending,
            requestedByRole: workspace.role,
            decidedByRole: nil,
            decisionReason: nil,
            requestedAt: Date(),
            decidedAt: nil,
            expiresAt: nil,
            metadata: [
                "workspace_id": workspace.id.uuidString,
                "task_id": task.id.uuidString,
                "approval_request_id": freshApprovalID.uuidString,
                "candidate_patch_id": revisedPlan.patchID.rawValue,
                "sandbox_id": revisedPlan.sandboxID.rawValue,
                "source_snapshot_id": revisedPlan.sourceSnapshotID,
                "assessment_id": revisedPlan.assessmentID,
                "normalized_requested_capability_id": revisedPlan.requestedCapabilityID,
                "canonical_legacy_root": revisedPlan.legacyIntegrityBaseline.canonicalLegacyRoot,
                "plan_id": revisedPlan.planID.uuidString,
                "plan_revision": String(revisedPlan.revision),
                "original_approval_request_id": request.id.uuidString,
                "candidate_patch_decision": CandidatePatchApprovalDecision.requestChanges.rawValue,
                "revision_instructions": instructions.joined(separator: " | "),
                "superseded_plan_id": currentManifest.plan.planID.uuidString,
                "revised_plan_id": revisedPlan.planID.uuidString,
                "fresh_approval_request_id": freshApprovalID.uuidString,
                "files_planned": String(revisedPlan.operations.count),
                "prohibited_actions": revisedPlan.prohibitedActions.joined(separator: " | "),
                "candidate_patch_plan_summary": renderedRevisedPlan.markdown
            ]
        )
        let revisedManifest = try service.recordApprovalRequest(
            sandboxID: revisedPlan.sandboxID,
            patchID: revisedPlan.patchID,
            planID: revisedPlan.planID,
            approvalRequestID: freshApproval.id
        )
        _ = try await approvalQueue.enqueue(freshApproval)
        pendingCandidatePatches[freshApproval.id] = CandidatePatchPendingRuntime(
            approvalRequestID: freshApproval.id,
            taskID: task.id,
            workspaceID: workspace.id,
            sandboxID: revisedPlan.sandboxID,
            patchID: revisedPlan.patchID
        )
        try stateMachine.transition(&task, to: .pendingApproval)
        try await persistence.saveTask(task)
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Candidate Patch changes requested and prior approval superseded",
            payload: [
                "state": task.state.rawValue,
                "lifecycle_event": "CANDIDATE_PATCH_REVISION_REQUESTED",
                "original_approval_request_id": request.id.uuidString,
                "candidate_patch_decision": CandidatePatchApprovalDecision.requestChanges.rawValue,
                "revision_instructions": instructions.joined(separator: " | "),
                "superseded_plan_id": currentManifest.plan.planID.uuidString,
                "revised_plan_id": revisedPlan.planID.uuidString,
                "fresh_approval_request_id": freshApproval.id.uuidString,
                "workspace_mutation_count": "0"
            ].merging(CandidatePatchActivitySnapshot(manifest: revisedManifest).eventPayload) { current, _ in current }
        )
        try await record(
            type: .humanApprovalRequested,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Revised Candidate Patch plan requires fresh explicit human approval",
            payload: CandidatePatchActivitySnapshot(plan: revisedManifest.plan).eventPayload.merging([
                "state": task.state.rawValue,
                "approval_request_id": freshApproval.id.uuidString,
                "original_approval_request_id": request.id.uuidString,
                "candidate_patch_activity_phase": CandidatePatchActivityPhase.waitingForHumanApproval.rawValue,
                "runtime_owned_activity": "true",
                "manifest_backed": "true",
                "detail": revisedManifest.plan.markdown,
                "actual_result": revisedManifest.plan.markdown,
                "workspace_mutation_count": "0",
                "legacy_writes": "0",
                "sandbox_writes": "0",
                "patch_files_created": "0",
                "build_test_executions": "0",
                "shell_calls": "0",
                "git_operations": "0",
                "deployment_operations": "0",
                "unified_diff_exists": "false",
                "sandbox_readiness_checked": "false"
            ]) { current, _ in current }
        )
        return freshApproval
    }

    private func validateCandidatePatchApprovalBinding(
        _ requestID: UUID,
        workspace: Workspace,
        context: CandidatePatchApprovalUIContext,
        source: CandidatePatchApprovalSource
    ) async throws -> (
        request: ApprovalRequest,
        pending: CandidatePatchPendingRuntime,
        manifest: CandidatePatchManifest,
        task: FDETask,
        lifecycle: SandboxLifecycleService
    ) {
        guard source != .replay,
              source.isInteractiveUI || (source == .testFixture && allowsCandidatePatchTestApproval),
              context.currentWorkspaceID == workspace.id,
              context.visiblyContains(requestID),
              let lifecycle = sandboxLifecycle,
              let request = try await approvalQueue.load(requestID: requestID),
              request.targetKind == .candidatePatchPlan,
              request.state == .pending,
              request.workspaceID == workspace.id,
              request.taskID == context.currentTaskID else {
            throw CandidatePatchRuntimeError.approvalMetadataInvalid
        }
        if source.isInteractiveUI {
            guard let session = try await persistence.loadSessionMetadata(),
                  session.userSession.id == context.authenticatedUserSessionID,
                  session.userSession.state == .signedIn,
                  session.workspaceSession?.userSessionID == session.userSession.id,
                  session.workspaceSession?.workspaceID == workspace.id,
                  session.workspaceSession?.orgID == workspace.orgID,
                  session.workspaceSession?.role == workspace.role,
                  session.workspaceSession?.state == .signedIn else {
                throw CandidatePatchRuntimeError.authenticatedSessionInvalid
            }
        }
        let databasePending = try await approvalQueue.pendingRequests(workspaceID: workspace.id)
        guard databasePending.contains(where: {
            $0.id == requestID && $0.taskID == context.currentTaskID && $0.targetKind == .candidatePatchPlan
        }),
        let task = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == context.currentTaskID }),
        task.state == .pendingApproval else {
            throw CandidatePatchRuntimeError.approvalMetadataInvalid
        }
        let pending = try candidatePatchPending(from: request)
        let service = CandidatePatchService(lifecycle: lifecycle)
        let manifest = try service.loadManifest(sandboxID: pending.sandboxID, patchID: pending.patchID)
        let canonicalWorkspaceRoot = try workspace.localProjectRoot.map {
            try SandboxFileSystem.canonicalExistingDirectory(
                URL(fileURLWithPath: $0, isDirectory: true)
            ).path
        }
        guard pending.approvalRequestID == request.id,
              pending.workspaceID == workspace.id,
              pending.taskID == task.id,
              manifest.status == .awaitingApproval,
              manifest.plan.status == .awaitingApproval,
              manifest.plan.approvalRecord == nil,
              manifest.plan.approvalRequestID == request.id,
              request.stepID == "candidate-patch-plan-revision-\(manifest.plan.revision)",
              request.metadata["candidate_patch_id"] == manifest.patchID.rawValue,
              request.metadata["sandbox_id"] == manifest.sandboxID.rawValue,
              request.metadata["plan_id"] == manifest.plan.planID.uuidString,
              request.metadata["plan_revision"] == String(manifest.plan.revision),
              request.metadata["assessment_id"] == manifest.plan.assessmentID,
              request.metadata["source_snapshot_id"] == manifest.plan.sourceSnapshotID,
              request.metadata["normalized_requested_capability_id"] == manifest.plan.requestedCapabilityID,
              request.metadata["canonical_legacy_root"] == manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
              canonicalWorkspaceRoot == manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
              manifest.plan.assessmentContext?.validationStatus == .validated,
              manifest.plan.assessmentContext?.assessmentID == manifest.plan.assessmentID,
              manifest.plan.assessmentContext?.sourceSnapshotID == manifest.plan.sourceSnapshotID,
              manifest.plan.assessmentContext?.canonicalLegacyRoot == manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot else {
            throw CandidatePatchError.blocked(.planRevisionMismatch)
        }
        return (request, pending, manifest, task, lifecycle)
    }

    private func applyApprovedCandidatePatch(
        _ approval: ApprovalRequest,
        workspace: Workspace,
        reason: String,
        provenance: CandidatePatchApprovalProvenance
    ) async throws {
        guard let lifecycle = sandboxLifecycle else {
            throw CandidatePatchRuntimeError.runtimeUnavailable
        }
        let pending = try candidatePatchPending(from: approval)
        guard var task = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == pending.taskID }) else {
            throw CandidatePatchRuntimeError.approvalMetadataInvalid
        }
        let service = CandidatePatchService(lifecycle: lifecycle)
        var manifest = try service.loadManifest(sandboxID: pending.sandboxID, patchID: pending.patchID)
        guard manifest.status == .awaitingApproval,
              manifest.plan.status == .awaitingApproval,
              manifest.plan.approvalRequestID == approval.id,
              approval.metadata["candidate_patch_id"] == manifest.patchID.rawValue,
              approval.metadata["sandbox_id"] == manifest.sandboxID.rawValue,
              approval.metadata["plan_id"] == manifest.plan.planID.uuidString,
              approval.metadata["plan_revision"] == String(manifest.plan.revision),
              approval.metadata["assessment_id"] == manifest.plan.assessmentID,
              approval.metadata["source_snapshot_id"] == manifest.plan.sourceSnapshotID,
              approval.metadata["normalized_requested_capability_id"] == manifest.plan.requestedCapabilityID,
              approval.metadata["canonical_legacy_root"] == manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot else {
            throw CandidatePatchError.blocked(.planRevisionMismatch)
        }
        var snapshot = CandidatePatchActivitySnapshot(plan: manifest.plan)
        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)
        try await recordCandidatePatchActivity(.verifyingApprovedScope, snapshot: snapshot, workspace: workspace, task: task)
        do {
            try await validateApprovedCandidatePatchAssessment(manifest.plan, workspace: workspace)
            try await recordCandidatePatchActivity(.checkingSandboxReadiness, snapshot: snapshot, workspace: workspace, task: task)
            _ = try service.preflightApprovedPlan(
                sandboxID: pending.sandboxID,
                patchID: pending.patchID,
                planID: manifest.plan.planID,
                approvalRequestID: approval.id
            )
            manifest = try service.recordDecision(
                sandboxID: pending.sandboxID,
                patchID: pending.patchID,
                decision: .approve,
                decidedBy: workspace.role.rawValue,
                rationale: reason,
                approvalRequestID: approval.id,
                approvalProvenance: provenance
            )
            manifest = try service.materializeApprovedImplementation(
                sandboxID: pending.sandboxID,
                patchID: pending.patchID
            )
            snapshot = CandidatePatchActivitySnapshot(manifest: manifest)
            try await recordCandidatePatchActivity(.applyingChangeInIsolatedSandbox, snapshot: snapshot, workspace: workspace, task: task)
            let result = try service.apply(sandboxID: pending.sandboxID, patchID: pending.patchID)
            manifest = result.manifest
            snapshot = CandidatePatchActivitySnapshot(manifest: manifest)
            try await recordCandidatePatchActivity(.verifyingFileHashes, snapshot: snapshot, workspace: workspace, task: task)
            try await recordCandidatePatchActivity(.buildingUnifiedDiff, snapshot: snapshot, workspace: workspace, task: task)
            try await recordCandidatePatchActivity(.confirmingOriginalLegacyUnchanged, snapshot: snapshot, workspace: workspace, task: task)
            try await recordCandidatePatchActivity(.preparingHumanReview, snapshot: snapshot, workspace: workspace, task: task)
            let review = try service.reviewSummary(sandboxID: pending.sandboxID, patchID: pending.patchID)
            try await recordCandidatePatchActivity(.candidatePatchReady, snapshot: snapshot, workspace: workspace, task: task)
            try stateMachine.transition(&task, to: .completed)
            try await persistence.saveTask(task)
            try await record(
                type: .taskCompleted,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Candidate Patch ready for human review",
                payload: snapshot.eventPayload.merging([
                    "state": task.state.rawValue,
                    "intent_type": MissionIntentType.candidatePatchGeneration.rawValue,
                    "completion_contract": RuntimeCompletionContractKind.candidatePatchGeneration.rawValue,
                    "manifest_backed": "true",
                    "source_integrity": SourceIntegrityState.unchanged.rawValue,
                    "build_or_test_executed": "false",
                    "git_or_deployment_action_occurred": "false",
                    "generated_tests_available": "false",
                    "shell_execution_enabled": "false",
                    "detail": review.markdown,
                    "actual_result": review.markdown,
                    "success": "true"
                ]) { current, _ in current }
                .merging(runtimeStatePayload(mission: .complete, task: task.state, tool: .succeeded)) { current, _ in current }
            )
            pendingCandidatePatches.removeValue(forKey: approval.id)
        } catch {
            let code = candidatePatchFailureCode(error)
            try stateMachine.transition(&task, to: .failed)
            task.failureProbability = 1
            try await persistence.saveTask(task)
            try? await recordCandidatePatchActivity(.candidatePatchBlocked, snapshot: snapshot, workspace: workspace, task: task)
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Approved Candidate Patch failed closed",
                payload: snapshot.eventPayload.merging([
                    "state": task.state.rawValue,
                    "failure_category": code.rawValue,
                    "blocker_reason": code.rawValue,
                    "success": "false",
                    "build_or_test_executed": "false",
                    "git_or_deployment_action_occurred": "false"
                ]) { current, _ in current }
            )
            throw error
        }
    }

    private func rejectCandidatePatch(
        _ approval: ApprovalRequest,
        workspace: Workspace,
        reason: String
    ) async throws {
        guard let lifecycle = sandboxLifecycle else {
            throw CandidatePatchRuntimeError.runtimeUnavailable
        }
        let pending = try candidatePatchPending(from: approval)
        let service = CandidatePatchService(lifecycle: lifecycle)
        let manifest = try service.recordDecision(
            sandboxID: pending.sandboxID,
            patchID: pending.patchID,
            decision: .reject,
            decidedBy: workspace.role.rawValue,
            rationale: reason,
            approvalRequestID: approval.id
        )
        if var task = try await persistence.loadTasks(workspaceID: workspace.id)
            .first(where: { $0.id == pending.taskID }) {
            try stateMachine.transition(&task, to: .failed)
            try await persistence.saveTask(task)
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Candidate Patch plan rejected without Sandbox workspace mutation",
                payload: CandidatePatchActivitySnapshot(manifest: manifest).eventPayload.merging([
                    "state": task.state.rawValue,
                    "candidate_patch_activity_phase": CandidatePatchActivityPhase.candidatePatchBlocked.rawValue,
                    "failure_category": CandidatePatchStatus.rejected.rawValue,
                    "workspace_mutation_count": "0",
                    "build_or_test_executed": "false",
                    "git_or_deployment_action_occurred": "false"
                ]) { current, _ in current }
            )
        }
        pendingCandidatePatches.removeValue(forKey: approval.id)
    }

    private func candidatePatchPending(from approval: ApprovalRequest) throws -> CandidatePatchPendingRuntime {
        if let pending = pendingCandidatePatches[approval.id] { return pending }
        guard let taskID = approval.taskID,
              let rawSandboxID = approval.metadata["sandbox_id"],
              let sandboxID = SandboxID(rawValue: rawSandboxID),
              let rawPatchID = approval.metadata["candidate_patch_id"],
              let patchID = CandidatePatchID(rawValue: rawPatchID) else {
            throw CandidatePatchRuntimeError.approvalMetadataInvalid
        }
        return CandidatePatchPendingRuntime(
            approvalRequestID: approval.id,
            taskID: taskID,
            workspaceID: approval.workspaceID,
            sandboxID: sandboxID,
            patchID: patchID
        )
    }

    private func validateApprovedCandidatePatchAssessment(
        _ plan: CandidatePatchPlan,
        workspace: Workspace
    ) async throws {
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
        let event = events
            .filter({ $0.payload["lifecycle_event"] == "AI_ASSESSMENT_PERSISTED" })
            .sorted(by: { $0.sequence > $1.sequence })
            .first(where: { $0.payload["assessment_id"] == plan.assessmentID })
        let assessment: CandidatePatchAssessmentContext
        if let event {
            guard event.payload["assessment_validation_status"] == CandidatePatchAssessmentValidationStatus.validated.rawValue,
                  event.payload["source_snapshot_id"] == plan.sourceSnapshotID,
                  event.payload["canonical_legacy_root"] == plan.legacyIntegrityBaseline.canonicalLegacyRoot else {
                throw CandidatePatchError.blocked(.assessmentStale)
            }
            guard event.payload["normalized_requested_capability_id"] == plan.requestedCapabilityID else {
                throw CandidatePatchError.blocked(.assessmentCapabilityMismatch)
            }
            guard event.payload["compatibility_decision"] == plan.compatibilityDecision.rawValue,
                  let json = event.payload["candidate_patch_assessment_context"],
                  let data = json.data(using: .utf8) else {
                throw CandidatePatchError.blocked(.assessmentEvidenceMissing)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode(CandidatePatchAssessmentContext.self, from: data) else {
                throw CandidatePatchError.blocked(.assessmentEvidenceMissing)
            }
            assessment = decoded
        } else if let embedded = plan.assessmentContext {
            assessment = embedded
        } else {
            throw CandidatePatchError.blocked(.assessmentMissing)
        }
        guard assessment.validationStatus == .validated,
              assessment.assessmentID == plan.assessmentID,
              assessment.sourceSnapshotID == plan.sourceSnapshotID,
              assessment.canonicalLegacyRoot == plan.legacyIntegrityBaseline.canonicalLegacyRoot,
              assessment.requestedCapabilityID == plan.requestedCapabilityID,
              assessment.compatibilityDecision == plan.compatibilityDecision,
              !assessment.evidence.filter(\.isGrounded).isEmpty else {
            throw CandidatePatchError.blocked(.assessmentEvidenceMissing)
        }
        if assessment.compatibilityDecision == .no {
            guard !assessment.blockers.isEmpty,
                  Set(plan.blockersAddressed).isSubset(of: Set(assessment.blockers)),
                  !plan.blockersAddressed.isEmpty else {
                throw CandidatePatchError.blocked(.assessmentVerdictNotEligible)
            }
        }
    }

    private func normalizedCandidatePatchRevisionInstructions(_ value: String) throws -> [String] {
        let values = value
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let combined = values.joined(separator: " ")
        let ambiguous: Set<String> = [
            "change", "changes", "change it", "revise", "revision", "fix it", "update it",
            "修改", "改一下", "调整", "变更"
        ]
        guard combined.count >= 8,
              !ambiguous.contains(combined.lowercased()) else {
            throw CandidatePatchError.blocked(.invalidApprovalState)
        }
        return values
    }

    @discardableResult
    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID? = nil,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        try await record(type: type, workspaceID: workspaceID, taskID: taskID, summary: summary, payload: payload)
    }

    @discardableResult
    func recordUserSubmissionAuditEvent(
        logicalEventID: UUID,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        try await record(
            type: .userMessageReceived,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: summary,
            payload: payload.merging(["client_message_id": logicalEventID.uuidString]) { current, _ in current },
            eventID: logicalEventID
        )
    }

    private func pauseTaskForUser(
        _ task: inout FDETask,
        workspace: Workspace,
        step: PlanStep,
        call: ToolCall,
        reason: String
    ) async throws {
        if task.state != .waiting {
            try stateMachine.transition(&task, to: .waiting)
            try await persistence.saveTask(task)
        }
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Agent paused before \(step.title)",
            payload: [
                "state": task.state.rawValue,
                "step_id": step.id,
                "tool_call_id": call.id,
                "command": call.command,
                "interaction_state": AgentInteractionState.waitingForUser.rawValue,
                "agent_loop_phase": "wait",
                "reason": AgentPresentationSanitizer.safeContent(reason, fallback: "Waiting for user input")
            ].merging(runtimeStatePayload(mission: .waitingHuman, task: task.state)) { current, _ in current }
        )
    }

    private func handleResumeDirective(
        _ directive: RuntimeStepDirective,
        task: inout FDETask,
        workspace: Workspace,
        step: PlanStep,
        call: ToolCall
    ) async throws -> RuntimeStepHandlingResult {
        switch directive {
        case .continue:
            try await resumeTaskAfterUserWait(&task, workspace: workspace, step: step, call: call)
            return .runStep
        case .waitForUser(let reason):
            try await pauseTaskForUser(&task, workspace: workspace, step: step, call: call, reason: reason)
            let nextDirective = await stepAdapter.waitForResume(taskID: task.id)
            return try await handleResumeDirective(nextDirective, task: &task, workspace: workspace, step: step, call: call)
        case .changeApproach(let instruction):
            try await resumeTaskAfterUserWait(&task, workspace: workspace, step: step, call: call)
            return try await handleApproachChange(instruction, task: &task, workspace: workspace, step: step, call: call)
        case .stop(let reason):
            try await stopTaskForUser(&task, workspace: workspace, step: step, call: call, reason: reason)
            return .finishTask
        }
    }

    private func resumeTaskAfterUserWait(
        _ task: inout FDETask,
        workspace: Workspace,
        step: PlanStep,
        call: ToolCall
    ) async throws {
        if task.state == .waiting {
            try stateMachine.transition(&task, to: .running)
            try await persistence.saveTask(task)
        }
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Agent resumed before \(step.title)",
            payload: [
                "state": task.state.rawValue,
                "step_id": step.id,
                "tool_call_id": call.id,
                "command": call.command,
                "interaction_state": AgentInteractionState.working.rawValue,
                "agent_loop_phase": "resume"
            ].merging(runtimeStatePayload(mission: .execute, task: task.state)) { current, _ in current }
        )
    }

    private func handleApproachChange(
        _ instruction: String,
        task: inout FDETask,
        workspace: Workspace,
        step: PlanStep,
        call: ToolCall
    ) async throws -> RuntimeStepHandlingResult {
        let safeInstruction = AgentPresentationSanitizer.safeContent(instruction, fallback: "Change approach")
        try await record(
            type: .userDecisionSelected,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "User changed approach before \(step.title)",
            payload: [
                "step_id": step.id,
                "tool_call_id": call.id,
                "command": call.command,
                "decision": "change_approach",
                "instruction": safeInstruction,
                "interaction_state": AgentInteractionState.working.rawValue,
                "agent_loop_phase": "decide"
            ].merging(runtimeStatePayload(mission: .adapt, task: task.state)) { current, _ in current }
                .merging(workTracePayload(.adaptation, summary: "Approach changed", detail: "Applied user adaptation instruction at a checkpoint.")) { current, _ in current }
        )

        if shouldSkipStep(for: safeInstruction, call: call) {
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Agent skipped \(step.title) after user changed approach",
                payload: [
                    "state": task.state.rawValue,
                    "step_id": step.id,
                    "tool_call_id": call.id,
                    "command": call.command,
                    "interaction_state": AgentInteractionState.working.rawValue,
                    "agent_loop_phase": "act",
                    "skip_reason": safeInstruction
                ].merging(runtimeStatePayload(mission: .adapt, task: task.state, tool: .skipped)) { current, _ in current }
                    .merging(workTracePayload(.adaptation, summary: "Step skipped", detail: "Skipped current step after adaptation instruction.")) { current, _ in current }
            )
            return .skipStep
        }

        return .runStep
    }

    private func stopTaskForUser(
        _ task: inout FDETask,
        workspace: Workspace,
        step: PlanStep,
        call: ToolCall,
        reason: String
    ) async throws {
        if task.state != .failed {
            try stateMachine.transition(&task, to: .failed)
            try await persistence.saveTask(task)
        }
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Agent stopped before \(step.title)",
            payload: [
                "state": task.state.rawValue,
                "step_id": step.id,
                "tool_call_id": call.id,
                "command": call.command,
                "interaction_state": AgentInteractionState.failed.rawValue,
                "agent_loop_phase": "stop",
                "reason": AgentPresentationSanitizer.safeContent(reason, fallback: "Stopped by user")
            ].merging(runtimeStatePayload(mission: .complete, task: task.state, tool: .skipped)) { current, _ in current }
        )
    }

    private func runReadOnlyInspection(
        originalOutput: StructuredAgentOutput,
        context: ExecutionContext,
        worldModel: inout SystemWorldModel,
        workspace: Workspace,
        task: inout FDETask,
        completionContract: RuntimeCompletionContract,
        missionRequest: String? = nil,
        missionTiming: inout ReadOnlyMissionTiming,
        evidenceRequirements: ReadOnlyEvidenceRequirements
    ) async throws -> FDETask {
        let effectiveRequest = missionRequest ?? task.rawInput
        let readinessStartedAt = Date()
        var output = originalOutput
        let missionTarget = context.missionWorkspaceScope?.readOnlyMissionTarget
            ?? ReadOnlyMissionTarget(request: effectiveRequest)
        let priorEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let restoredEvidence = restoredReadOnlyEvidence(from: priorEvents, workspace: workspace)
        let assessmentProfile = MissionIntentParser().parse(effectiveRequest).intentType == .aiAgentCompatibilityAssessment
            ? AgentCapabilityProfile.detect(from: effectiveRequest)
            : nil
        func emitAssessmentState(
            _ state: AIAssessmentMissionState,
            evidenceCount: Int,
            completedSnapshot: AIAssessmentActivitySnapshot? = nil
        ) async throws {
            guard let assessmentProfile else { return }
            let snapshot = completedSnapshot ?? AIAssessmentActivitySnapshot(
                capability: assessmentProfile.name,
                missionState: state,
                compatibility: nil,
                risk: nil,
                blockerCount: nil,
                evidenceCount: evidenceCount
            )
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: state.rawValue,
                payload: [
                    "lifecycle_event": "AI_ASSESSMENT_ACTIVITY",
                    "state": task.state.rawValue,
                    "evidence_count": String(evidenceCount),
                    "safe_engineering_objective": state.rawValue
                ].merging(snapshot.eventPayload) { current, _ in current }
                    .merging(runtimeStatePayload(mission: .understand, task: task.state)) { current, _ in current }
            )
        }
        try await emitAssessmentState(
            .understandingCapability,
            evidenceCount: restoredEvidence.count
        )
        let restoredCompletedSignatures = restoredReadOnlyCommandSignatures(from: priorEvents)
        let restoredFailedSignatures = restoredReadOnlyFailedCommandSignatures(from: priorEvents)
        let restoredReadPaths = Set(
            restoredEvidence.filter { $0.toolName == "engineering.read_file" }.map(\.targetPath)
        )
        let explicitNoRereadPaths = readOnlyExplicitNoRereadPaths(
            in: effectiveRequest,
            successfullyReadPaths: restoredReadPaths
        )
        var readiness = readOnlyReadinessValidator.validate(output, workspace: workspace, missionTarget: missionTarget)
        readiness = applyingReadOnlyOperationAvailability(
            to: readiness,
            completedSignatures: restoredCompletedSignatures,
            failedSignatures: restoredFailedSignatures,
            explicitNoRereadPaths: explicitNoRereadPaths,
            evidence: restoredEvidence,
            evidenceRequirements: evidenceRequirements
        )
        try await recordReadiness(
            readiness,
            lifecycleEvent: "PLAN_READINESS_CHECKED",
            workspace: workspace,
            task: task,
            iteration: 0,
            modelOutput: output
        )
        if readiness.isReady, !readiness.stepNormalizations.isEmpty {
            output.plan = readiness.normalizedPlan
            task.plan = readiness.normalizedPlan
            try await persistence.saveTask(task)
        }

        if !readiness.isReady {
            guard readiness.repairable else {
                missionTiming.readinessAndRepair += Date().timeIntervalSince(readinessStartedAt)
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: readiness.blockerReason ?? .noExecutableToolStep,
                    detail: readiness.rejectedToolCalls.first?.detail ?? "The read-only plan is not executable.",
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: [])
                )
            }

            let repairInstruction = readOnlyRepairInstruction(
                for: readiness,
                originalRequest: effectiveRequest,
                missionTarget: missionTarget
            )
            try await record(
                type: .planGenerated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Read-only plan repair requested",
                payload: [
                    "lifecycle_event": "PLAN_REPAIR_REQUESTED",
                    "repair_attempt": "1",
                    "repair_instruction": AgentPresentationSanitizer.safeContent(repairInstruction, fallback: "Repair invalid read-only plan."),
                    "original_plan_step_count": String(originalOutput.plan.count),
                    "original_tool_call_count": String(originalOutput.toolCalls.count),
                    "original_plan_step_ids": originalOutput.plan.prefix(20).map(\.id).joined(separator: " | "),
                    "original_tool_call_ids": originalOutput.toolCalls.prefix(20).map(\.id).joined(separator: " | "),
                    "original_tool_commands": originalOutput.toolCalls.prefix(20).map(\.command).joined(separator: " | "),
                    "original_model_output_json": safeReadOnlyModelOutput(originalOutput),
                    "selected_mission_target": missionTarget.rawValue,
                    "allowed_workspace_values": ReadOnlyWorkspaceTarget.allCases.map(\.rawValue).joined(separator: " | ")
                ].merging(readiness.auditPayload) { current, _ in current }
                    .merging(runtimeStatePayload(mission: .plan, task: task.state)) { current, _ in current }
            )

            do {
                let repairPrompt = promptOrchestrator.compile(
                    state: .plan,
                    input: repairInstruction,
                    context: context,
                    worldModel: worldModel
                )
                output = try await withReadOnlyHardDeadline(
                    deadline: missionTiming.hardDeadline,
                    stage: "readiness_repair"
                ) { [modelRouter] in
                    try await modelRouter.generateDecision(prompt: repairPrompt, context: context)
                }
                try validator.validate(output)
                readiness = readOnlyReadinessValidator.validate(output, workspace: workspace, missionTarget: missionTarget)
                readiness = applyingReadOnlyOperationAvailability(
                    to: readiness,
                    completedSignatures: restoredCompletedSignatures,
                    failedSignatures: restoredFailedSignatures,
                    explicitNoRereadPaths: explicitNoRereadPaths,
                    evidence: restoredEvidence,
                    evidenceRequirements: evidenceRequirements
                )
                output.plan = readiness.normalizedPlan
                task.plan = readiness.normalizedPlan
                try await persistence.saveTask(task)
                try await recordReadiness(
                    readiness,
                    lifecycleEvent: "PLAN_REPAIRED",
                    workspace: workspace,
                    task: task,
                    iteration: 1,
                    modelOutput: output
                )
            } catch {
                missionTiming.readinessAndRepair += Date().timeIntervalSince(readinessStartedAt)
                if let deadlineError = error as? ReadOnlyMissionDeadlineError,
                   case .hardDeadlineReached(let stage) = deadlineError {
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: .durationLimitReached,
                        detail: "The read-only mission reached its hard duration deadline during \(stage). The repair request was cancelled and no completion is claimed.",
                        providerStage: stage,
                        providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: [])
                    )
                }
                let failure = ModelRoutingError.classified(error)
                let providerFailure = error as? ModelProviderFailure
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: readOnlyProviderBlocker(
                        failure,
                        providerFailure: providerFailure,
                        unavailableReason: .repairProviderUnavailable
                    ),
                    detail: providerFailure?.localizedDescription
                        ?? "The single bounded plan repair failed (\(failure.diagnosticReason)).",
                    providerStage: "repair",
                    providerDiagnostic: failure.diagnosticReason,
                    providerAuditPayload: providerFailure?.auditPayload ?? [:],
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: [])
                )
            }

            guard readiness.isReady else {
                missionTiming.readinessAndRepair += Date().timeIntervalSince(readinessStartedAt)
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: readiness.blockerReason ?? .repairFailed,
                    detail: readiness.rejectedToolCalls.first?.detail ?? "The repaired plan is still not executable.",
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: [])
                )
            }
        }

        missionTiming.readinessAndRepair += Date().timeIntervalSince(readinessStartedAt)

        try await emitAssessmentState(
            .mappingLegacyArchitecture,
            evidenceCount: restoredEvidence.count
        )

        try stateMachine.transition(&task, to: .running)
        try await persistence.saveTask(task)

        // The initial plan establishes direction, but OBSERVE owns every action
        // after the first validated tool result.
        var evidence = restoredEvidence
        var executedCallIDs = Set(evidence.map(\.toolCallID))
        var executedCommandSignatures = restoredCompletedSignatures.union(restoredFailedSignatures)
        var failedCommandSignatures = restoredFailedSignatures
        let remainingInitialSteps = readiness.executableSteps.filter {
            !executedCallIDs.contains($0.toolCall.id)
                && !executedCommandSignatures.contains(readOnlyCommandSignature($0))
        }
        var queue = Array(remainingInitialSteps.prefix(1))
        var queuedCallIDs = Set(queue.map { $0.toolCall.id })
        var pendingFinalAnswer: String?
        var partialFinalizationRequired = false
        var finalizationResolution: ReadOnlyBudgetStopResolution?
        var decisionIterations = 0
        var toolCallCount = 0
        var fileReadCount = 0
        var alternativeCandidateAttempts = 0

        if queue.isEmpty, !evidence.isEmpty {
            let resolution = readOnlyBudgetStopResolution(
                trigger: .restoredEvidence,
                request: effectiveRequest,
                evidence: evidence,
                requirements: evidenceRequirements
            )
            do {
                pendingFinalAnswer = try await gracefulReadOnlyFinalAnswer(
                    request: effectiveRequest,
                    context: context,
                    worldModel: worldModel,
                    workspace: workspace,
                    task: task,
                    evidence: evidence,
                    requirements: evidenceRequirements,
                    decisionIterations: decisionIterations,
                    toolCallCount: toolCallCount,
                    fileReadCount: fileReadCount,
                    missionTiming: &missionTiming,
                    resolution: resolution
                )
            } catch {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: error is CancellationError ? .inspectionCancelled : .durationLimitReached,
                    detail: "Graceful finalization could not finish before the hard deadline. Accumulated evidence was preserved and no completion is claimed.",
                    providerStage: "final_grounded_answer",
                    providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence),
                    additionalPayload: ["pending_provider_cancelled": "true"]
                )
            }
            finalizationResolution = resolution
            partialFinalizationRequired = resolution.decision == .partialWithCurrentEvidence
        }

        inspectionLoop: while !queue.isEmpty {
            if Task.isCancelled {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .inspectionCancelled,
                    detail: "The read-only inspection was cancelled before the next tool call."
                )
            }
            let operationBudget = missionTiming.operationBudget
            let preToolTrigger: ReadOnlyFinalizationTrigger?
            if let durationTrigger = missionTiming.durationFinalizationTrigger() {
                preToolTrigger = durationTrigger
            } else if toolCallCount >= operationBudget.maximumToolCalls {
                preToolTrigger = .toolCallLimit
            } else if queue.first?.toolCall.command == "engineering.read_file",
                      fileReadCount >= operationBudget.maximumFilesRead {
                preToolTrigger = .fileReadLimit
            } else {
                preToolTrigger = nil
            }
            if let preToolTrigger {
                guard !evidence.isEmpty else {
                    let resolution = ReadOnlyBudgetStopResolution(
                        decision: .hardCancel,
                        trigger: preToolTrigger
                    )
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: preToolTrigger.blockerReason,
                        detail: "The read-only mission reached a bounded stop before any useful workspace evidence was available. No completion is claimed; the same task can be resumed with a fresh bounded budget.",
                        providerStage: "graceful_finalization",
                        providerDiagnostic: preToolTrigger.blockerReason.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence),
                        additionalPayload: resolution.auditPayload
                    )
                }
                let resolution = readOnlyBudgetStopResolution(
                    trigger: preToolTrigger,
                    request: effectiveRequest,
                    evidence: evidence,
                    requirements: evidenceRequirements
                )
                do {
                    pendingFinalAnswer = try await gracefulReadOnlyFinalAnswer(
                        request: effectiveRequest,
                        context: context,
                        worldModel: worldModel,
                        workspace: workspace,
                        task: task,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        decisionIterations: decisionIterations,
                        toolCallCount: toolCallCount,
                        fileReadCount: fileReadCount,
                        missionTiming: &missionTiming,
                        resolution: resolution
                    )
                } catch {
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: error is CancellationError ? .inspectionCancelled : .durationLimitReached,
                        detail: "Graceful finalization could not finish before the hard deadline. Accumulated evidence was preserved and no completion is claimed.",
                        providerStage: "final_grounded_answer",
                        providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence),
                        additionalPayload: ["pending_provider_cancelled": "true"]
                    )
                }
                finalizationResolution = resolution
                partialFinalizationRequired = resolution.decision == .partialWithCurrentEvidence
                break
            }

            let executable = queue.removeFirst()
            guard !executedCallIDs.contains(executable.toolCall.id) else { continue }
            if executable.toolCall.command == "engineering.read_file" {
                fileReadCount += 1
            }
            toolCallCount += 1

            let authorization = authorizationService.authorize(
                .executeTool,
                workspace: workspace,
                action: "execute read-only workspace tool",
                resource: executable.toolCall.command
            )
            guard authorization.allowed else {
                try await recordAuthorizationDenied(
                    authorization,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    extraPayload: readOnlyToolMetadata(executable, iteration: decisionIterations)
                )
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .toolNotAllowed,
                    detail: authorization.reason
                )
            }

            let toolCalledEvent = try await record(
                type: .toolCalled,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Read-only tool: \(executable.toolCall.command)",
                payload: readOnlyToolMetadata(executable, iteration: decisionIterations)
                    .merging([
                        "lifecycle_event": "TOOL_CALLED",
                        "attempt": "1",
                        "max_attempts": "1",
                        "completed_command_signature": readOnlyCommandSignature(executable)
                    ]) { current, _ in current }
                    .merging(runtimeStatePayload(mission: .execute, task: task.state, tool: .running)) { current, _ in current }
            )

            let result: ToolExecutionResult
            let toolExecutionStartedAt = Date()
            do {
                result = try await withReadOnlyHardDeadline(
                    deadline: missionTiming.hardDeadline,
                    stage: "tool_execution"
                ) { [toolExecutor] in
                    try await toolExecutor.execute(executable.toolCall)
                }
            } catch {
                missionTiming.toolExecution += Date().timeIntervalSince(toolExecutionStartedAt)
                if let deadlineError = error as? ReadOnlyMissionDeadlineError,
                   case .hardDeadlineReached(let stage) = deadlineError {
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: .durationLimitReached,
                        detail: "The read-only mission reached its hard duration deadline during \(stage). The pending tool was cancelled, prior evidence was preserved, and no completion is claimed.",
                        providerStage: stage,
                        providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence),
                        additionalPayload: ["pending_tool_cancelled": "true"]
                    )
                }
                if error is CancellationError || Task.isCancelled {
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: .inspectionCancelled,
                        detail: "The read-only inspection was cancelled during tool execution; prior evidence was preserved.",
                        providerStage: "tool_execution",
                        providerDiagnostic: PlanReadinessBlocker.inspectionCancelled.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
                    )
                }
                try await recordReadOnlyToolFailure(
                    executable,
                    error: error.localizedDescription,
                    classification: readOnlyToolFailureClassification(error.localizedDescription),
                    workspace: workspace,
                    task: task,
                    iteration: decisionIterations
                )
                let failureDetail = error.localizedDescription
                let failureClassification = readOnlyToolFailureClassification(failureDetail)
                executedCallIDs.insert(executable.toolCall.id)
                let failedSignature = readOnlyCommandSignature(executable)
                executedCommandSignatures.insert(failedSignature)
                failedCommandSignatures.insert(failedSignature)
                if failureClassification.isRecoverableCandidateFailure,
                   alternativeCandidateAttempts < 1,
                   let alternative = groundedAlternativeReadStep(
                        after: executable,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        workspace: workspace,
                        missionTarget: missionTarget,
                        excludedSignatures: executedCommandSignatures,
                        iteration: decisionIterations
                   ) {
                    alternativeCandidateAttempts += 1
                    queue.insert(alternative, at: 0)
                    queuedCallIDs.insert(alternative.toolCall.id)
                    try await recordReadOnlyCandidateRecovery(
                        failed: executable,
                        alternative: alternative,
                        classification: failureClassification,
                        error: failureDetail,
                        workspace: workspace,
                        task: task,
                        iteration: decisionIterations
                    )
                    continue inspectionLoop
                }
                if executable.toolCall.command == "engineering.read_file", !evidence.isEmpty {
                    let resolution = ReadOnlyBudgetStopResolution(
                        decision: .partialWithCurrentEvidence,
                        trigger: .restoredEvidence
                    )
                    pendingFinalAnswer = groundedReadFailureFallback(
                        request: effectiveRequest,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        failedPath: executable.relativeTargetPath,
                        error: failureDetail
                    )
                    finalizationResolution = resolution
                    partialFinalizationRequired = true
                    try await recordDeterministicAnswerFallback(
                        workspace: workspace,
                        task: task,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        resolution: resolution,
                        diagnostic: failureClassification.rawValue,
                        timing: missionTiming,
                        providerStage: "recoverable_tool_failure",
                        answer: pendingFinalAnswer
                    )
                    break inspectionLoop
                }
                return try await failReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .toolExecutionFailed,
                    detail: failureDetail,
                    classification: failureClassification,
                    timing: missionTiming,
                    requirements: evidenceRequirements,
                    evidence: evidence
                )
            }
            missionTiming.toolExecution += Date().timeIntervalSince(toolExecutionStartedAt)

            guard result.exitCode == 0 else {
                let detail = result.standardError.isEmpty
                    ? "Read-only tool returned exit code \(result.exitCode)."
                    : String(result.standardError.prefix(1_000))
                try await recordReadOnlyToolFailure(
                    executable,
                    error: detail,
                    classification: readOnlyToolFailureClassification(detail),
                    workspace: workspace,
                    task: task,
                    iteration: decisionIterations
                )
                let failureClassification = readOnlyToolFailureClassification(detail)
                executedCallIDs.insert(executable.toolCall.id)
                let failedSignature = readOnlyCommandSignature(executable)
                executedCommandSignatures.insert(failedSignature)
                failedCommandSignatures.insert(failedSignature)
                if failureClassification.isRecoverableCandidateFailure,
                   alternativeCandidateAttempts < 1,
                   let alternative = groundedAlternativeReadStep(
                        after: executable,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        workspace: workspace,
                        missionTarget: missionTarget,
                        excludedSignatures: executedCommandSignatures,
                        iteration: decisionIterations
                   ) {
                    alternativeCandidateAttempts += 1
                    queue.insert(alternative, at: 0)
                    queuedCallIDs.insert(alternative.toolCall.id)
                    try await recordReadOnlyCandidateRecovery(
                        failed: executable,
                        alternative: alternative,
                        classification: failureClassification,
                        error: detail,
                        workspace: workspace,
                        task: task,
                        iteration: decisionIterations
                    )
                    continue inspectionLoop
                }
                if executable.toolCall.command == "engineering.read_file", !evidence.isEmpty {
                    let resolution = ReadOnlyBudgetStopResolution(
                        decision: .partialWithCurrentEvidence,
                        trigger: .restoredEvidence
                    )
                    pendingFinalAnswer = groundedReadFailureFallback(
                        request: effectiveRequest,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        failedPath: executable.relativeTargetPath,
                        error: detail
                    )
                    finalizationResolution = resolution
                    partialFinalizationRequired = true
                    try await recordDeterministicAnswerFallback(
                        workspace: workspace,
                        task: task,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        resolution: resolution,
                        diagnostic: failureClassification.rawValue,
                        timing: missionTiming,
                        providerStage: "recoverable_tool_failure",
                        answer: pendingFinalAnswer
                    )
                    break inspectionLoop
                }
                return try await failReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .toolExecutionFailed,
                    detail: detail,
                    classification: failureClassification,
                    timing: missionTiming,
                    requirements: evidenceRequirements,
                    evidence: evidence
                )
            }

            executedCallIDs.insert(executable.toolCall.id)
            executedCommandSignatures.insert(readOnlyCommandSignature(executable))
            let boundedOutput = String(result.standardOutput.prefix(readOnlyInspectionLimits.maximumObservationCharacters))
            let extractedFacts = ReadOnlySafeFactExtractor.extract(
                toolName: executable.toolCall.command,
                targetPath: executable.relativeTargetPath,
                output: result.standardOutput
            )
            let lowLevelObservation = observationLoop.observeResult(
                step: executable.step,
                toolCall: executable.toolCall,
                result: result,
                attempt: 1,
                maxAttempts: 1
            )
            worldModel = systemUnderstandingLayer.applying(lowLevelObservation, to: worldModel)

            let toolResultEvent = try await record(
                type: .stepExecuted,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Read-only result: \(readOnlyToolPresentationTitle(executable))",
                payload: readOnlyToolMetadata(executable, iteration: decisionIterations)
                    .merging([
                        "lifecycle_event": "TOOL_RESULT",
                        "success": "true",
                        "exit_code": "0",
                        "stdout": String(boundedOutput.prefix(4_000)),
                        "stderr": "",
                        "evidence_count": String(evidence.count + 1),
                        "completed_command_signature": readOnlyCommandSignature(executable)
                    ]) { current, _ in current }
                    .merging(extractedFacts.eventPayload) { current, _ in current }
                    .merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .succeeded)) { current, _ in current }
            )
            evidence.append(
                ReadOnlyInspectionEvidence(
                    toolCallID: executable.toolCall.id,
                    toolName: executable.toolCall.command,
                    workspaceID: workspace.id,
                    workspaceIdentity: executable.workspaceIdentity,
                    targetPath: executable.relativeTargetPath,
                    output: boundedOutput,
                    toolCalledEventID: toolCalledEvent.id,
                    toolResultEventID: toolResultEvent.id,
                    extractedFacts: extractedFacts,
                    query: readOnlyArgumentValue("query", in: executable.toolCall.arguments)
                )
            )

            if isProvenEmptyWorkspace(result.standardOutput) {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .workspaceEmpty,
                    detail: "The selected \(executable.workspaceIdentity) workspace was proven empty by \(executable.toolCall.command)."
                )
            }
            if result.standardOutput.contains("Source files: 0") {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .noSourceFiles,
                    detail: "The selected \(executable.workspaceIdentity) workspace is nonempty, but project inspection found no analyzable source files."
                )
            }

            if let stopTrigger = readOnlyFinalizationTriggerBeforeObservation(
                request: effectiveRequest,
                evidence: evidence,
                requirements: evidenceRequirements,
                decisionIterations: decisionIterations,
                toolCallCount: toolCallCount,
                fileReadCount: fileReadCount,
                missionTiming: missionTiming
            ) {
                let resolution = readOnlyBudgetStopResolution(
                    trigger: stopTrigger,
                    request: effectiveRequest,
                    evidence: evidence,
                    requirements: evidenceRequirements
                )
                do {
                    pendingFinalAnswer = try await gracefulReadOnlyFinalAnswer(
                        request: effectiveRequest,
                        context: context,
                        worldModel: worldModel,
                        workspace: workspace,
                        task: task,
                        evidence: evidence,
                        requirements: evidenceRequirements,
                        decisionIterations: decisionIterations,
                        toolCallCount: toolCallCount,
                        fileReadCount: fileReadCount,
                        missionTiming: &missionTiming,
                        resolution: resolution
                    )
                } catch {
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: error is CancellationError ? .inspectionCancelled : .durationLimitReached,
                        detail: "Graceful finalization could not finish before the hard deadline. Accumulated evidence was preserved and no completion is claimed.",
                        providerStage: "final_grounded_answer",
                        providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence),
                        additionalPayload: ["pending_provider_cancelled": "true"]
                    )
                }
                finalizationResolution = resolution
                partialFinalizationRequired = resolution.decision == .partialWithCurrentEvidence
                break
            }

            decisionIterations += 1
            let canonicalUnreadPaths = groundedReadOnlyCandidates(
                evidence: evidence,
                requirements: evidenceRequirements
            )
            let compactObservation = ReadOnlyInspectionObservation(
                missionGoal: effectiveRequest,
                trustedWorkspaceScope: context.missionWorkspaceScope?.rawValue ?? missionTarget.rawValue,
                toolName: executable.toolCall.command,
                workspaceIdentity: executable.workspaceIdentity,
                targetPath: executable.relativeTargetPath,
                success: true,
                boundedOutput: boundedOutput,
                accumulatedEvidence: evidence.map {
                    "tool=\($0.toolName); workspace=\($0.workspaceIdentity); path=\($0.targetPath); tool_call_id=\($0.toolCallID)"
                },
                structuredFacts: evidence.flatMap { item in
                    item.structuredFacts.safeSummaries.map { "path=\(item.targetPath); \($0)" }
                },
                inspectedFiles: evidence.filter { $0.toolName == "engineering.read_file" }.map(\.targetPath),
                responseLanguage: ReadOnlyResponseLanguage(request: effectiveRequest),
                remainingDecisionIterations: max(0, operationBudget.maximumModelDecisionIterations - decisionIterations),
                remainingToolCalls: max(0, operationBudget.maximumToolCalls - toolCallCount),
                remainingFileReads: max(0, operationBudget.maximumFilesRead - fileReadCount),
                elapsedMilliseconds: Int(missionTiming.elapsed() * 1_000),
                remainingDurationMilliseconds: Int(missionTiming.remainingHard() * 1_000),
                estimatedNextProviderCallMilliseconds: Int(missionTiming.budget.providerCallReserve * 1_000),
                finalizationReserveMilliseconds: Int(missionTiming.budget.finalizationReserve * 1_000),
                finalizationRequired: false,
                satisfiedEvidenceRequirements: evidenceRequirements.satisfied(by: evidence).map(\.rawValue),
                unsatisfiedEvidenceRequirements: evidenceRequirements.unsatisfied(by: evidence).map(\.rawValue),
                canonicalUnreadPaths: canonicalUnreadPaths,
                highestValueCandidateCategories: readOnlyCandidateCategoryPriority(
                    candidates: canonicalUnreadPaths,
                    evidence: evidence,
                    requirements: evidenceRequirements
                ),
                unavailableReadPaths: failedReadOnlyPaths(from: failedCommandSignatures),
                completedCommandSignatures: executedCommandSignatures.subtracting(failedCommandSignatures).sorted(),
                failedCommandSignatures: failedCommandSignatures.sorted()
            )
            var observationPayload: [String: String] = [
                "lifecycle_event": "OBSERVATION_RECORDED",
                "iteration": String(decisionIterations),
                "tool_name": compactObservation.toolName,
                "workspace_identity": compactObservation.workspaceIdentity,
                "trusted_workspace_scope": compactObservation.trustedWorkspaceScope,
                "target_path": compactObservation.targetPath,
                "success": "true",
                "evidence_count": String(evidence.count),
                "observation_input_summary": "latest_tool=\(compactObservation.toolName); workspace=\(compactObservation.workspaceIdentity); path=\(compactObservation.targetPath); evidence=\(evidence.count)",
                "accumulated_evidence": compactObservation.accumulatedEvidence.joined(separator: " | "),
                "files_already_inspected": compactObservation.inspectedFiles.joined(separator: " | "),
                "canonical_discovered_unread_paths": compactObservation.canonicalUnreadPaths.joined(separator: " | "),
                "completed_command_signatures": compactObservation.completedCommandSignatures.joined(separator: " | "),
                "failed_command_signatures": compactObservation.failedCommandSignatures.joined(separator: " | "),
                "explicit_no_reread_paths": explicitNoRereadPaths.sorted().joined(separator: " | "),
                "remaining_model_decisions": String(compactObservation.remainingDecisionIterations),
                "remaining_tool_calls": String(compactObservation.remainingToolCalls),
                "remaining_file_reads": String(compactObservation.remainingFileReads),
                "elapsed_ms": String(compactObservation.elapsedMilliseconds),
                "remaining_ms": String(compactObservation.remainingDurationMilliseconds),
                "estimated_next_provider_call_ms": String(compactObservation.estimatedNextProviderCallMilliseconds),
                "finalization_reserve_ms": String(compactObservation.finalizationReserveMilliseconds),
                "finalization_required": "false",
                "provider_stage": "observation_next_action"
            ]
            observationPayload.merge(missionTiming.auditPayload()) { current, _ in current }
            observationPayload.merge(evidenceRequirements.auditPayload(evidence: evidence)) { current, _ in current }
            observationPayload.merge(runtimeStatePayload(mission: .observe, task: task.state, tool: .succeeded)) { current, _ in current }
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Read-only observation recorded",
                payload: observationPayload
            )

            let initialPrompt = promptOrchestrator.compile(
                state: .observe,
                input: compactObservation.prompt(),
                context: context,
                worldModel: worldModel
            )
            var action: ReadOnlyNextAction?
            var actionValidation: ReadOnlyNextActionValidation
            var acceptedDecisionProviderDuration: TimeInterval = 0
            let observationProviderStartedAt = Date()
            let observationTaskSnapshot = task
            do {
                let proposed = try await withReadOnlyHardDeadline(
                    deadline: missionTiming.hardDeadline,
                    stage: "observation_next_action"
                ) { [self] in
                    try await generateReadOnlyObservationDecision(
                        prompt: initialPrompt,
                        context: context,
                        workspace: workspace,
                        task: observationTaskSnapshot
                    )
                }
                acceptedDecisionProviderDuration = Date().timeIntervalSince(observationProviderStartedAt)
                missionTiming.observationProvider += acceptedDecisionProviderDuration
                action = proposed
                actionValidation = validateReadOnlyNextAction(
                    proposed,
                    workspace: workspace,
                    missionTarget: missionTarget,
                    request: effectiveRequest,
                    evidence: evidence,
                    executedCallIDs: executedCallIDs,
                    executedCommandSignatures: executedCommandSignatures,
                    iteration: decisionIterations,
                    evidenceRequirements: evidenceRequirements,
                    allowPartialFinalization: false
                )
                try await recordReadOnlyNextAction(
                    proposed,
                    validation: actionValidation,
                    attempt: 0,
                    workspace: workspace,
                    task: task,
                    iteration: decisionIterations
                )
            } catch {
                missionTiming.observationProvider += Date().timeIntervalSince(observationProviderStartedAt)
                if let deadlineError = error as? ReadOnlyMissionDeadlineError,
                   case .hardDeadlineReached(let stage) = deadlineError {
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: .durationLimitReached,
                        detail: "The read-only mission reached its hard duration deadline during \(stage). The provider request was cancelled, accumulated evidence was preserved, and no completion is claimed.",
                        providerStage: stage,
                        providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence),
                        additionalPayload: ["pending_provider_cancelled": "true"]
                    )
                }
                let failure = ModelRoutingError.classified(error)
                let providerFailure = error as? ModelProviderFailure
                let repairableOutputFailure = failure.diagnosticReason == "provider_output_invalid"
                    || providerFailure?.failurePhase == "response_decode"
                    || providerFailure?.failurePhase == "response_schema_validation"
                guard repairableOutputFailure else {
                    if !evidence.isEmpty {
                        let resolution = readOnlyBudgetStopResolution(
                            trigger: .restoredEvidence,
                            request: effectiveRequest,
                            evidence: evidence,
                            requirements: evidenceRequirements
                        )
                        pendingFinalAnswer = groundedEvidenceFallback(
                            request: effectiveRequest,
                            evidence: evidence,
                            satisfied: evidenceRequirements.satisfied(by: evidence),
                            unsatisfied: evidenceRequirements.unsatisfied(by: evidence),
                            decision: resolution.decision
                        )
                        finalizationResolution = resolution
                        partialFinalizationRequired = resolution.decision == .partialWithCurrentEvidence
                        try await recordDeterministicAnswerFallback(
                            workspace: workspace,
                            task: task,
                            evidence: evidence,
                            requirements: evidenceRequirements,
                            resolution: resolution,
                            diagnostic: failure.diagnosticReason,
                            timing: missionTiming,
                            providerAuditPayload: providerFailure?.auditPayload ?? [:],
                            providerStage: "final_grounded_answer",
                            answer: pendingFinalAnswer
                        )
                        break inspectionLoop
                    }
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: readOnlyProviderBlocker(
                            failure,
                            providerFailure: providerFailure,
                            unavailableReason: .observationProviderUnavailable
                        ),
                        detail: providerFailure?.localizedDescription
                            ?? "The observation model decision failed (\(failure.diagnosticReason)).",
                        providerStage: "observation_next_action",
                        providerDiagnostic: failure.diagnosticReason,
                        providerAuditPayload: providerFailure?.auditPayload ?? [:],
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
                    )
                }
                actionValidation = .rejected(
                    ReadOnlyNextActionRejection(
                        reason: .invalidNextAction,
                        detail: providerFailure?.localizedDescription ?? error.localizedDescription
                    )
                )
            }

            if let rejection = actionValidation.rejection {
                try await record(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Observation next-action repair requested",
                    payload: [
                        "lifecycle_event": "NEXT_ACTION_REPAIR_REQUESTED",
                        "provider_stage": "observation_next_action_repair",
                        "repair_attempt": "1",
                        "rejection_reason": rejection.reason.rawValue,
                        "exact_rejection": safeReadOnlyRejectionDetail(rejection),
                        "completed_tool_call_id": executable.toolCall.id,
                        "completed_command_signature": readOnlyCommandSignature(executable),
                        "iteration": String(decisionIterations)
                    ].merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .succeeded)) { current, _ in current }
                )
                do {
                    let repaired: ReadOnlyNextAction
                    let repairSource: String
                    if let deterministic = deterministicCanonicalNextActionRepair(
                        action: action,
                        rejection: rejection,
                        missionTarget: missionTarget,
                        evidence: evidence,
                        requirements: evidenceRequirements
                    ) {
                        repaired = deterministic
                        repairSource = "bounded_deterministic_repair"
                    } else {
                        let repairPrompt = promptOrchestrator.compile(
                            state: .observe,
                            input: compactObservation.repairPrompt(rejection: rejection),
                            context: context,
                            worldModel: worldModel
                        )
                        let repairProviderStartedAt = Date()
                        let repairTaskSnapshot = task
                        do {
                            repaired = try await withReadOnlyHardDeadline(
                                deadline: missionTiming.hardDeadline,
                                stage: "observation_next_action_repair"
                            ) { [self] in
                                try await generateReadOnlyObservationDecision(
                                    prompt: repairPrompt,
                                    context: context,
                                    workspace: workspace,
                                    task: repairTaskSnapshot
                                )
                            }
                            acceptedDecisionProviderDuration = Date().timeIntervalSince(repairProviderStartedAt)
                            missionTiming.observationProvider += acceptedDecisionProviderDuration
                        } catch {
                            missionTiming.observationProvider += Date().timeIntervalSince(repairProviderStartedAt)
                            throw error
                        }
                        repairSource = "provider_bounded_repair"
                    }
                    action = repaired
                    actionValidation = validateReadOnlyNextAction(
                        repaired,
                        workspace: workspace,
                        missionTarget: missionTarget,
                        request: effectiveRequest,
                        evidence: evidence,
                        executedCallIDs: executedCallIDs,
                        executedCommandSignatures: executedCommandSignatures,
                        iteration: decisionIterations,
                        evidenceRequirements: evidenceRequirements,
                        allowPartialFinalization: false
                    )
                    try await recordReadOnlyNextAction(
                        repaired,
                        validation: actionValidation,
                        attempt: 1,
                        workspace: workspace,
                        task: task,
                        iteration: decisionIterations,
                        additionalPayload: canonicalPathRepairAuditPayload(
                            validation: actionValidation,
                            evidence: evidence,
                            rejection: rejection,
                            source: repairSource
                        )
                    )
                } catch {
                    if let deadlineError = error as? ReadOnlyMissionDeadlineError,
                       case .hardDeadlineReached(let stage) = deadlineError {
                        return try await blockReadOnlyInspection(
                            task: &task,
                            workspace: workspace,
                            reason: .durationLimitReached,
                            detail: "The read-only mission reached its hard duration deadline during \(stage). The provider repair was cancelled, accumulated evidence was preserved, and no completion is claimed.",
                            providerStage: stage,
                            providerDiagnostic: PlanReadinessBlocker.durationLimitReached.rawValue,
                            timingPayload: missionTiming.auditPayload(),
                            evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence),
                            additionalPayload: ["pending_provider_cancelled": "true"]
                        )
                    }
                    if !evidence.isEmpty,
                       action?.decision == .finalize || rejection.reason == .invalidNextAction {
                        let resolution = readOnlyBudgetStopResolution(
                            trigger: .restoredEvidence,
                            request: effectiveRequest,
                            evidence: evidence,
                            requirements: evidenceRequirements
                        )
                        pendingFinalAnswer = groundedEvidenceFallback(
                            request: effectiveRequest,
                            evidence: evidence,
                            satisfied: evidenceRequirements.satisfied(by: evidence),
                            unsatisfied: evidenceRequirements.unsatisfied(by: evidence),
                            decision: resolution.decision
                        )
                        finalizationResolution = resolution
                        partialFinalizationRequired = resolution.decision == .partialWithCurrentEvidence
                        try await recordDeterministicAnswerFallback(
                            workspace: workspace,
                            task: task,
                            evidence: evidence,
                            requirements: evidenceRequirements,
                            resolution: resolution,
                            diagnostic: ModelRoutingError.classified(error).diagnosticReason,
                            timing: missionTiming,
                            providerAuditPayload: (error as? ModelProviderFailure)?.auditPayload ?? [:],
                            providerStage: "final_grounded_answer",
                            answer: pendingFinalAnswer
                        )
                        break inspectionLoop
                    }
                    let failure = ModelRoutingError.classified(error)
                    let providerFailure = error as? ModelProviderFailure
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: .nextActionRepairFailed,
                        detail: providerFailure?.localizedDescription
                            ?? "The bounded next-action repair failed (\(failure.diagnosticReason)).",
                        providerStage: "observation_next_action_repair",
                        providerDiagnostic: failure.diagnosticReason,
                        providerAuditPayload: providerFailure?.auditPayload ?? [:],
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
                    )
                }
            }

            if action?.decision == .finalize,
               case .rejected(let finalRejection) = actionValidation,
               !evidence.isEmpty {
                let resolution = readOnlyBudgetStopResolution(
                    trigger: .restoredEvidence,
                    request: effectiveRequest,
                    evidence: evidence,
                    requirements: evidenceRequirements
                )
                pendingFinalAnswer = groundedEvidenceFallback(
                    request: effectiveRequest,
                    evidence: evidence,
                    satisfied: evidenceRequirements.satisfied(by: evidence),
                    unsatisfied: evidenceRequirements.unsatisfied(by: evidence),
                    decision: resolution.decision
                )
                finalizationResolution = resolution
                partialFinalizationRequired = resolution.decision == .partialWithCurrentEvidence
                try await recordDeterministicAnswerFallback(
                    workspace: workspace,
                    task: task,
                    evidence: evidence,
                    requirements: evidenceRequirements,
                    resolution: resolution,
                    diagnostic: finalRejection.reason.rawValue,
                    timing: missionTiming,
                    answer: pendingFinalAnswer
                )
                break inspectionLoop
            }

            guard let action, case .accepted(let decision) = actionValidation else {
                let rejection = actionValidation.rejection ?? ReadOnlyNextActionRejection(
                    reason: .invalidNextAction,
                    detail: "The repaired observation decision did not contain one valid next action."
                )
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: rejection.reason,
                    detail: rejection.detail,
                    providerStage: "observation_next_action_repair",
                    providerDiagnostic: PlanReadinessBlocker.nextActionRepairFailed.rawValue,
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
                )
            }

            _ = action
            switch decision {
            case .tool(let next):
                queuedCallIDs.insert(next.toolCall.id)
                queue.append(next)
                if let existing = task.plan.firstIndex(where: { $0.id == next.step.id }) {
                    task.plan[existing] = next.step
                } else {
                    task.plan.append(next.step)
                }
                try await persistence.saveTask(task)
            case .clarification(let question):
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .clarificationRequired,
                    detail: question,
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
                )
            case .blocker(let detail):
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .modelDecisionFailed,
                    detail: detail,
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
                )
            case .finalAnswer(let answer):
                missionTiming.observationProvider = max(
                    0,
                    missionTiming.observationProvider - acceptedDecisionProviderDuration
                )
                missionTiming.finalization += acceptedDecisionProviderDuration
                pendingFinalAnswer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard var finalAnswer = pendingFinalAnswer else {
            return try await blockReadOnlyInspection(
                task: &task,
                workspace: workspace,
                reason: .ungroundedFinalAnswer,
                detail: "The model did not provide a final answer grounded in recorded workspace evidence.",
                providerStage: "final_grounded_answer",
                providerDiagnostic: "provider_output_invalid",
                timingPayload: missionTiming.auditPayload(),
                evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
            )
        }

        var aiAssessmentActivity: AIAssessmentActivitySnapshot?
        var canonicalAssessmentReport: FDEAIIntegrationAssessmentReport?
        var canonicalAssessmentFinalizationMode: CandidatePatchAssessmentFinalizationMode = .normal
        if assessmentProfile != nil,
           !evidence.isEmpty {
            try await emitAssessmentState(.checkingIntegrationCapabilities, evidenceCount: evidence.count)
            try await emitAssessmentState(.inspectingPermissionBoundaries, evidenceCount: evidence.count)
            try await emitAssessmentState(.evaluatingAgentUncertainty, evidenceCount: evidence.count)
            try await emitAssessmentState(.identifyingBlockers, evidenceCount: evidence.count)
            try await emitAssessmentState(.buildingCompatibilityMatrix, evidenceCount: evidence.count)
            let ledger = ReadOnlyFinalizationEvidenceLedger(
                requirements: evidenceRequirements,
                evidence: evidence
            )
            let architecture = LegacyArchitecture(ledger: ledger, evidence: evidence)
            let responseLanguage = ReadOnlyResponseLanguage(request: effectiveRequest)
            var report = LegacyAgentCompatibilityAnalyzer().assess(
                capability: assessmentProfile ?? AgentCapabilityProfile.detect(from: effectiveRequest),
                evidenceLedger: ledger,
                legacyArchitecture: architecture,
                responseLanguage: responseLanguage
            )
            var semanticValidation = AssessmentSemanticConsistencyValidator.validate(report)
            if !semanticValidation.isValid {
                report = AssessmentSemanticConsistencyValidator.repair(report)
                semanticValidation = AssessmentSemanticConsistencyValidator.validate(report)
            }
            guard semanticValidation.isValid else {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .assessmentSemanticInconsistency,
                    detail: "The assessment report remained semantically inconsistent after deterministic repair: \(semanticValidation.issues.map(\.rawValue).joined(separator: ", ")).",
                    providerStage: "final_grounded_answer",
                    providerDiagnostic: ReadOnlyFinalAnswerContractFailure.assessmentSemanticInconsistency.rawValue,
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: ledger.auditPayload
                )
            }
            aiAssessmentActivity = report.activitySnapshot
            try await emitAssessmentState(.designingOperationalWorkflow, evidenceCount: evidence.count)
            try await emitAssessmentState(.preparingValidationPlan, evidenceCount: evidence.count)
            try await emitAssessmentState(
                .finalizingGroundedAssessment,
                evidenceCount: evidence.count,
                completedSnapshot: report.activitySnapshot
            )
            canonicalAssessmentReport = report
            finalAnswer = report.markdown(language: responseLanguage)
            let finalizationEvents = try await persistence.loadEvents(
                workspaceID: workspace.id,
                taskID: task.id
            )
            if finalizationEvents.contains(where: {
                $0.payload["lifecycle_event"] == "GRACEFUL_FINALIZATION_FALLBACK"
            }) {
                canonicalAssessmentFinalizationMode = .fallback
            }
        }

        var finalAnswerValidation = ReadOnlyFinalAnswerContract.validate(
            answer: finalAnswer,
            request: effectiveRequest,
            requirements: evidenceRequirements,
            evidence: evidence,
            requireComplete: !partialFinalizationRequired
        )
        if !isGroundedFinalAnswer(finalAnswer, evidence: evidence, request: effectiveRequest)
            || !finalAnswerValidation.accepted {
            guard !evidence.isEmpty else {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .ungroundedFinalAnswer,
                    detail: "The final report failed grounded requirement validation: \(finalAnswerValidation.safeContractFailures.map(\.rawValue).joined(separator: ", ")).",
                    providerStage: "final_grounded_answer",
                    providerDiagnostic: "provider_output_invalid",
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: finalAnswerValidation.ledger.auditPayload
                )
            }
            if let assessmentReport = canonicalAssessmentReport {
                let fallbackReport = AssessmentSemanticConsistencyValidator.repair(assessmentReport)
                let fallbackSemanticValidation = AssessmentSemanticConsistencyValidator.validate(fallbackReport)
                let fallback = fallbackReport.markdown(language: ReadOnlyResponseLanguage(request: effectiveRequest))
                let fallbackValidation = ReadOnlyFinalAnswerContract.validate(
                    answer: fallback,
                    request: effectiveRequest,
                    requirements: evidenceRequirements,
                    evidence: evidence,
                    requireComplete: !partialFinalizationRequired
                )
                guard fallbackSemanticValidation.isValid,
                      isGroundedFinalAnswer(fallback, evidence: evidence, request: effectiveRequest),
                      fallbackValidation.accepted else {
                    return try await blockReadOnlyInspection(
                        task: &task,
                        workspace: workspace,
                        reason: .assessmentSemanticInconsistency,
                        detail: "Neither the normal assessment nor its deterministic grounded fallback passed canonical validation.",
                        providerStage: "final_grounded_answer_validation",
                        providerDiagnostic: ReadOnlyFinalAnswerContractFailure.assessmentSemanticInconsistency.rawValue,
                        timingPayload: missionTiming.auditPayload(),
                        evidenceRequirementsPayload: fallbackValidation.ledger.auditPayload
                    )
                }
                finalAnswer = fallback
                finalAnswerValidation = fallbackValidation
                canonicalAssessmentReport = fallbackReport
                canonicalAssessmentFinalizationMode = .fallback
                aiAssessmentActivity = fallbackReport.activitySnapshot
                let resolution = finalizationResolution ?? ReadOnlyBudgetStopResolution(
                    decision: partialFinalizationRequired ? .partialWithCurrentEvidence : .completeWithCurrentEvidence,
                    trigger: .restoredEvidence
                )
                finalizationResolution = resolution
                try await recordDeterministicAnswerFallback(
                    workspace: workspace,
                    task: task,
                    evidence: evidence,
                    requirements: evidenceRequirements,
                    resolution: resolution,
                    diagnostic: "assessment_final_output_validation_failed",
                    timing: missionTiming,
                    providerStage: "assessment_final_grounded_answer_validation",
                    answer: fallback
                )
            } else {
            let unsatisfied = evidenceRequirements.unsatisfied(by: evidence)
            let resolution = ReadOnlyBudgetStopResolution(
                decision: unsatisfied.isEmpty ? .completeWithCurrentEvidence : .partialWithCurrentEvidence,
                trigger: .restoredEvidence
            )
            let fallback = groundedEvidenceFallback(
                request: effectiveRequest,
                evidence: evidence,
                satisfied: evidenceRequirements.satisfied(by: evidence),
                unsatisfied: unsatisfied,
                decision: resolution.decision
            )
            let fallbackValidation = ReadOnlyFinalAnswerContract.validate(
                answer: fallback,
                request: effectiveRequest,
                requirements: evidenceRequirements,
                evidence: evidence,
                requireComplete: unsatisfied.isEmpty
            )
            guard isGroundedFinalAnswer(fallback, evidence: evidence, request: effectiveRequest),
                  fallbackValidation.accepted else {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .ungroundedFinalAnswer,
                    detail: "The deterministic grounded fallback failed validation: \(fallbackValidation.safeContractFailures.map(\.rawValue).joined(separator: ", ")).",
                    providerStage: "final_grounded_answer",
                    providerDiagnostic: "deterministic_fallback_invalid",
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: fallbackValidation.ledger.auditPayload
                )
            }
            finalAnswer = fallback
            finalAnswerValidation = fallbackValidation
            finalizationResolution = resolution
            partialFinalizationRequired = !unsatisfied.isEmpty
            try await recordDeterministicAnswerFallback(
                workspace: workspace,
                task: task,
                evidence: evidence,
                requirements: evidenceRequirements,
                resolution: resolution,
                diagnostic: "final_output_validation_failed",
                timing: missionTiming,
                providerStage: "final_grounded_answer_validation",
                answer: fallback
            )
            }
        }

        if let canonicalAssessmentReport {
            let canonicalMarkdown = canonicalAssessmentReport.markdown(
                language: ReadOnlyResponseLanguage(request: effectiveRequest)
            )
            guard canonicalMarkdown == finalAnswer,
                  AssessmentSemanticConsistencyValidator.validate(canonicalAssessmentReport).isValid,
                  finalAnswerValidation.accepted,
                  isGroundedFinalAnswer(finalAnswer, evidence: evidence, request: effectiveRequest) else {
                return try await blockReadOnlyInspection(
                    task: &task,
                    workspace: workspace,
                    reason: .assessmentSemanticInconsistency,
                    detail: "The canonical assessment, visible report, and validation state did not match; no Candidate Patch handoff was persisted.",
                    providerStage: "canonical_assessment_persistence",
                    providerDiagnostic: ReadOnlyFinalAnswerContractFailure.assessmentSemanticInconsistency.rawValue,
                    timingPayload: missionTiming.auditPayload(),
                    evidenceRequirementsPayload: finalAnswerValidation.ledger.auditPayload
                )
            }
        }

        if partialFinalizationRequired {
            let resolution = finalizationResolution ?? ReadOnlyBudgetStopResolution(
                decision: .partialWithCurrentEvidence,
                trigger: .restoredEvidence
            )
            return try await finalizePartialReadOnlyInspection(
                task: &task,
                workspace: workspace,
                request: effectiveRequest,
                answer: finalAnswer,
                evidence: evidence,
                requirements: evidenceRequirements,
                timing: missionTiming,
                resolution: resolution
            )
        }

        // Assessment reports contain fourteen auditable sections and can legitimately
        // exceed the generic inspection event budget. Preserve the complete report
        // within a bounded assessment-specific envelope so the completion artifact
        // does not silently omit provenance or late-section blockers.
        let finalAnswerEventDetail = String(
            finalAnswer.prefix(aiAssessmentActivity == nil ? 12_000 : 64_000)
        )
        var preparedPayload: [String: String] = [
            "lifecycle_event": "INSPECTION_COMPLETED",
            "grounded_answer": "true",
            "final_answer": finalAnswerEventDetail,
            "evidence_count": String(evidence.count),
            "workspace_identity": Array(Set(evidence.map(\.workspaceIdentity))).sorted().joined(separator: " | "),
            "response_language": ReadOnlyResponseLanguage(request: effectiveRequest).rawValue,
            "state": task.state.rawValue
        ]
        preparedPayload.merge(missionTiming.auditPayload()) { current, _ in current }
        preparedPayload.merge(aiAssessmentActivity?.eventPayload ?? [:]) { current, _ in current }
        preparedPayload.merge(finalAnswerValidation.ledger.auditPayload) { current, _ in current }
        preparedPayload.merge(finalizationResolution?.auditPayload ?? [:]) { current, _ in current }
        preparedPayload.merge(runtimeStatePayload(mission: .verifying, task: task.state, tool: .succeeded)) { current, _ in current }
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Grounded read-only inspection answer prepared",
            payload: preparedPayload
        )

        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let gate = completionContract.evaluate(events: events)
        guard gate.allowed else {
            return try await blockReadOnlyInspection(
                task: &task,
                workspace: workspace,
                reason: .ungroundedFinalAnswer,
                detail: gate.reason,
                providerStage: "final_grounded_answer",
                providerDiagnostic: "completion_gate_rejected",
                timingPayload: missionTiming.auditPayload(),
                evidenceRequirementsPayload: evidenceRequirements.auditPayload(evidence: evidence)
            )
        }

        try stateMachine.transition(&task, to: .completed)
        try await persistence.saveTask(task)
        var completionPayload: [String: String] = [
            "state": task.state.rawValue,
            "lifecycle_event": "INSPECTION_COMPLETED",
            "completion_contract": completionContract.kind.rawValue,
            "grounded_answer": "true",
            "completion_evidence": gate.report,
            "detail": finalAnswerEventDetail,
            "actual_result": finalAnswerEventDetail,
            "success": "true",
            "evidence_count": String(evidence.count),
            "response_language": ReadOnlyResponseLanguage(request: effectiveRequest).rawValue
        ]
        completionPayload.merge(missionTiming.auditPayload()) { current, _ in current }
        completionPayload.merge(aiAssessmentActivity?.eventPayload ?? [:]) { current, _ in current }
        completionPayload.merge(finalAnswerValidation.ledger.auditPayload) { current, _ in current }
        completionPayload.merge(finalizationResolution?.auditPayload ?? [:]) { current, _ in current }
        completionPayload.merge(runtimeStatePayload(mission: .complete, task: task.state, tool: .succeeded)) { current, _ in current }
        completionPayload.merge(gate.auditPayload) { current, _ in current }
        try await record(
            type: .taskCompleted,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Read-only inspection completed with grounded evidence",
            payload: completionPayload
        )
        if let canonicalAssessmentReport {
            try await persistCandidatePatchAssessmentContext(
                report: canonicalAssessmentReport,
                finalizationMode: canonicalAssessmentFinalizationMode,
                workspace: workspace,
                task: task
            )
        }
        return task
    }

    private func recordReadiness(
        _ readiness: PlanReadinessResult,
        lifecycleEvent: String,
        workspace: Workspace,
        task: FDETask,
        iteration: Int,
        modelOutput: StructuredAgentOutput
    ) async throws {
        try await record(
            type: .planGenerated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: readiness.isReady ? "Read-only plan is execution-ready" : "Read-only plan is not execution-ready",
            payload: [
                "lifecycle_event": lifecycleEvent,
                "iteration": String(iteration),
                "tool_call_arguments": readOnlyPlannerArgumentSummary(modelOutput),
                "tool_call_working_directory_sources": modelOutput.toolCalls.prefix(20).map {
                    "\($0.id):\(($0.workingDirectory?.isEmpty == false) ? "model_supplied" : "runtime_pending")"
                }.joined(separator: " | "),
                "model_output_json": safeReadOnlyModelOutput(modelOutput)
            ].merging(readiness.auditPayload) { current, _ in current }
                .merging(runtimeStatePayload(mission: readiness.isReady ? .ready : .blocked, task: task.state)) { current, _ in current }
        )
    }

    private func generateReadOnlyObservationDecision(
        prompt: CompiledPrompt,
        context: ExecutionContext,
        workspace: Workspace,
        task: FDETask
    ) async throws -> ReadOnlyNextAction {
        do {
            return try await modelRouter.generateReadOnlyNextAction(prompt: prompt, context: context)
        } catch let firstFailure as ModelProviderFailure where firstFailure.retryable {
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Retrying transient observation provider failure",
                payload: [
                    "lifecycle_event": "PROVIDER_RETRY_REQUESTED",
                    "provider_stage": "observation_next_action",
                    "provider_diagnostic": firstFailure.routingError.diagnosticReason,
                    "retry_attempt": "1",
                    "max_retries": "1",
                    "success": "false"
                ].merging(firstFailure.auditPayload) { current, _ in current }
                    .merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .succeeded)) { current, _ in current }
            )
            do {
                return try await modelRouter.generateReadOnlyNextAction(prompt: prompt, context: context)
            } catch var secondFailure as ModelProviderFailure {
                secondFailure.attempts = 2
                throw secondFailure
            }
        }
    }

    private func recordDeterministicAnswerFallback(
        workspace: Workspace,
        task: FDETask,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements,
        resolution: ReadOnlyBudgetStopResolution,
        diagnostic: String,
        timing: ReadOnlyMissionTiming,
        providerAuditPayload: [String: String] = [:],
        providerStage: String = "final_grounded_answer_repair",
        answer: String? = nil
    ) async throws {
        var payload: [String: String] = [
            "state": task.state.rawValue,
            "lifecycle_event": "GRACEFUL_FINALIZATION_FALLBACK",
            "provider_stage": providerStage,
            "provider_diagnostic": diagnostic,
            "finalization_provider_requested": "true",
            "answer_repair_attempted": providerStage.contains("repair") ? "true" : "false",
            "fallback_grounded_from_recorded_evidence": "true",
            "success": ""
        ]
        if let answer, !answer.isEmpty {
            let bounded = String(answer.prefix(12_000))
            payload["grounded_answer"] = "true"
            payload["final_answer"] = bounded
            payload["detail"] = bounded
            payload["actual_result"] = bounded
            payload["user_visible_message"] = bounded
            payload["response_language"] = ReadOnlyResponseLanguage(request: task.rawInput).rawValue
        }
        payload.merge(providerAuditPayload) { current, _ in current }
        payload.merge(timing.auditPayload()) { current, _ in current }
        payload.merge(requirements.auditPayload(evidence: evidence)) { current, _ in current }
        payload.merge(resolution.auditPayload) { current, _ in current }
        payload.merge(runtimeStatePayload(mission: .verifying, task: task.state, tool: .succeeded)) { current, _ in current }
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Deterministic grounded report used after answer repair",
            payload: payload
        )
    }

    private func gracefulReadOnlyFinalAnswer(
        request: String,
        context: ExecutionContext,
        worldModel: SystemWorldModel,
        workspace: Workspace,
        task: FDETask,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements,
        decisionIterations: Int,
        toolCallCount: Int,
        fileReadCount: Int,
        missionTiming: inout ReadOnlyMissionTiming,
        resolution: ReadOnlyBudgetStopResolution
    ) async throws -> String {
        guard let latest = evidence.last else {
            throw ReadOnlyMissionDeadlineError.hardDeadlineReached(stage: "graceful_finalization_without_evidence")
        }
        let satisfied = requirements.satisfied(by: evidence)
        let unsatisfied = requirements.unsatisfied(by: evidence)
        let operationBudget = missionTiming.operationBudget
        let canonicalUnreadPaths = groundedReadOnlyCandidates(
            evidence: evidence,
            requirements: requirements
        )
        let observation = ReadOnlyInspectionObservation(
            missionGoal: request,
            trustedWorkspaceScope: context.missionWorkspaceScope?.rawValue ?? ReadOnlyMissionTarget(request: request).rawValue,
            toolName: latest.toolName,
            workspaceIdentity: latest.workspaceIdentity,
            targetPath: latest.targetPath,
            success: true,
            boundedOutput: latest.structuredFacts.safeSummaries.isEmpty
                ? "Successful read-only result recorded for \(latest.targetPath)."
                : latest.structuredFacts.safeSummaries.joined(separator: "\n"),
            accumulatedEvidence: evidence.map {
                "tool=\($0.toolName); workspace=\($0.workspaceIdentity); path=\($0.targetPath); tool_call_id=\($0.toolCallID)"
            },
            structuredFacts: evidence.flatMap { item in
                item.structuredFacts.safeSummaries.map { "path=\(item.targetPath); \($0)" }
            },
            inspectedFiles: evidence.filter { $0.toolName == "engineering.read_file" }.map(\.targetPath),
            responseLanguage: ReadOnlyResponseLanguage(request: request),
            remainingDecisionIterations: max(0, operationBudget.maximumModelDecisionIterations - decisionIterations),
            remainingToolCalls: max(0, operationBudget.maximumToolCalls - toolCallCount),
            remainingFileReads: max(0, operationBudget.maximumFilesRead - fileReadCount),
            elapsedMilliseconds: Int(missionTiming.elapsed() * 1_000),
            remainingDurationMilliseconds: Int(missionTiming.remainingHard() * 1_000),
            estimatedNextProviderCallMilliseconds: Int(missionTiming.budget.providerCallReserve * 1_000),
            finalizationReserveMilliseconds: Int(missionTiming.budget.finalizationReserve * 1_000),
            finalizationRequired: true,
            satisfiedEvidenceRequirements: satisfied.map(\.rawValue),
            unsatisfiedEvidenceRequirements: unsatisfied.map(\.rawValue),
            canonicalUnreadPaths: canonicalUnreadPaths,
            highestValueCandidateCategories: readOnlyCandidateCategoryPriority(
                candidates: canonicalUnreadPaths,
                evidence: evidence,
                requirements: requirements
            )
        )
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Read-only graceful finalization started",
            payload: [
                "state": task.state.rawValue,
                "lifecycle_event": "GRACEFUL_FINALIZATION_STARTED",
                "provider_stage": "final_grounded_answer",
                "finalization_required": "true",
                "finalization_terminal_operation": "true",
                "finalization_provider_requested": "true",
                "no_additional_tool_allowed": "true",
                "evidence_count": String(evidence.count),
                "success": ""
            ].merging(missionTiming.auditPayload()) { current, _ in current }
                .merging(requirements.auditPayload(evidence: evidence)) { current, _ in current }
                .merging(resolution.auditPayload) { current, _ in current }
                .merging(runtimeStatePayload(mission: .verifying, task: task.state, tool: .succeeded)) { current, _ in current }
        )

        let prompt = promptOrchestrator.compile(
            state: .observe,
            input: observation.prompt(),
            context: context,
            worldModel: worldModel
        )
        let finalizationStartedAt = Date()
        do {
            let proposed = try await withReadOnlyHardDeadline(
                deadline: missionTiming.hardDeadline,
                stage: "final_grounded_answer"
            ) { [self] in
                try await generateReadOnlyObservationDecision(
                    prompt: prompt,
                    context: context,
                    workspace: workspace,
                    task: task
                )
            }
            missionTiming.finalization += Date().timeIntervalSince(finalizationStartedAt)
            let canonicalAssessmentWillRender = MissionIntentParser().parse(request).intentType
                == .aiAgentCompatibilityAssessment
            if canonicalAssessmentWillRender,
               proposed.decision == .finalize,
               proposed.toolCalls.isEmpty {
                try await record(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Assessment finalization signal accepted for canonical rendering",
                    payload: [
                        "state": task.state.rawValue,
                        "lifecycle_event": "AI_ASSESSMENT_FINALIZATION_SIGNAL_ACCEPTED",
                        "provider_stage": "final_grounded_answer",
                        "canonical_assessment_render_pending": "true",
                        "success": "true"
                    ].merging(runtimeStatePayload(mission: .verifying, task: task.state, tool: .succeeded)) { current, _ in current }
                )
                return proposed.finalAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
                    ? proposed.finalAnswer!.trimmingCharacters(in: .whitespacesAndNewlines)
                    : "Canonical assessment rendering pending."
            }
            let validation = validateReadOnlyNextAction(
                proposed,
                workspace: workspace,
                missionTarget: context.missionWorkspaceScope?.readOnlyMissionTarget ?? ReadOnlyMissionTarget(request: request),
                request: request,
                evidence: evidence,
                executedCallIDs: Set(evidence.map(\.toolCallID)),
                executedCommandSignatures: [],
                iteration: decisionIterations,
                evidenceRequirements: requirements,
                allowPartialFinalization: true
            )
            try await recordReadOnlyNextAction(
                proposed,
                validation: validation,
                attempt: 0,
                workspace: workspace,
                task: task,
                iteration: decisionIterations
            )
            if case .accepted(.finalAnswer(let answer)) = validation,
               unsatisfied.isEmpty || isExplicitPartialAnswer(answer) {
                return answer
            }
            if let rejection = validation.rejection {
                try await record(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: task.id,
                    summary: "Final answer repair requested",
                    payload: [
                        "state": task.state.rawValue,
                        "lifecycle_event": "FINAL_ANSWER_REPAIR_REQUESTED",
                        "provider_stage": "final_grounded_answer_repair",
                        "repair_attempt": "1",
                        "rejection_reason": rejection.reason.rawValue,
                        "safe_contract_failures": ReadOnlyFinalAnswerContractFailure.allCases
                            .filter { rejection.detail.contains($0.rawValue) }
                            .map(\.rawValue)
                            .joined(separator: " | "),
                        "success": "false"
                    ].merging(requirements.auditPayload(evidence: evidence)) { current, _ in current }
                        .merging(resolution.auditPayload) { current, _ in current }
                        .merging(runtimeStatePayload(mission: .verifying, task: task.state, tool: .succeeded)) { current, _ in current }
                )
                let repairPrompt = promptOrchestrator.compile(
                    state: .observe,
                    input: observation.repairPrompt(rejection: rejection),
                    context: context,
                    worldModel: worldModel
                )
                let repaired = try await withReadOnlyHardDeadline(
                    deadline: missionTiming.hardDeadline,
                    stage: "final_grounded_answer_repair"
                ) { [self] in
                    try await generateReadOnlyObservationDecision(
                        prompt: repairPrompt,
                        context: context,
                        workspace: workspace,
                        task: task
                    )
                }
                let repairedValidation = validateReadOnlyNextAction(
                    repaired,
                    workspace: workspace,
                    missionTarget: context.missionWorkspaceScope?.readOnlyMissionTarget ?? ReadOnlyMissionTarget(request: request),
                    request: request,
                    evidence: evidence,
                    executedCallIDs: Set(evidence.map(\.toolCallID)),
                    executedCommandSignatures: [],
                    iteration: decisionIterations,
                    evidenceRequirements: requirements,
                    allowPartialFinalization: true
                )
                try await recordReadOnlyNextAction(
                    repaired,
                    validation: repairedValidation,
                    attempt: 1,
                    workspace: workspace,
                    task: task,
                    iteration: decisionIterations
                )
                if case .accepted(.finalAnswer(let answer)) = repairedValidation,
                   unsatisfied.isEmpty || isExplicitPartialAnswer(answer) {
                    return answer
                }
            }
        } catch {
            missionTiming.finalization += Date().timeIntervalSince(finalizationStartedAt)
            if error is CancellationError, Task.isCancelled {
                throw error
            }
            let failure = ModelRoutingError.classified(error)
            let providerFailure = error as? ModelProviderFailure
            let fallbackAnswer = groundedEvidenceFallback(
                request: request,
                evidence: evidence,
                satisfied: satisfied,
                unsatisfied: unsatisfied,
                decision: resolution.decision
            )
            var fallbackPayload: [String: String] = [
                "state": task.state.rawValue,
                "lifecycle_event": "GRACEFUL_FINALIZATION_FALLBACK",
                "provider_stage": "final_grounded_answer",
                "provider_diagnostic": failure.diagnosticReason,
                "finalization_provider_requested": "true",
                "fallback_grounded_from_recorded_evidence": "true",
                "grounded_answer": "true",
                "final_answer": String(fallbackAnswer.prefix(12_000)),
                "detail": String(fallbackAnswer.prefix(12_000)),
                "actual_result": String(fallbackAnswer.prefix(12_000)),
                "user_visible_message": String(fallbackAnswer.prefix(12_000)),
                "response_language": ReadOnlyResponseLanguage(request: request).rawValue,
                "success": ""
            ]
            fallbackPayload.merge(providerFailure?.auditPayload ?? [:]) { current, _ in current }
            fallbackPayload.merge(missionTiming.auditPayload()) { current, _ in current }
            fallbackPayload.merge(requirements.auditPayload(evidence: evidence)) { current, _ in current }
            fallbackPayload.merge(resolution.auditPayload) { current, _ in current }
            fallbackPayload.merge(runtimeStatePayload(mission: .verifying, task: task.state, tool: .succeeded)) { current, _ in current }
            try await record(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: task.id,
                summary: "Grounded partial-answer fallback used",
                payload: fallbackPayload
            )
            return fallbackAnswer
        }
        let fallbackAnswer = groundedEvidenceFallback(
            request: request,
            evidence: evidence,
            satisfied: satisfied,
            unsatisfied: unsatisfied,
            decision: resolution.decision
        )
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Grounded evidence fallback used after invalid finalization output",
            payload: [
                "state": task.state.rawValue,
                "lifecycle_event": "GRACEFUL_FINALIZATION_FALLBACK",
                "provider_stage": "final_grounded_answer",
                "provider_diagnostic": PlanReadinessBlocker.providerOutputInvalid.rawValue,
                "finalization_provider_requested": "true",
                "fallback_grounded_from_recorded_evidence": "true",
                "grounded_answer": "true",
                "final_answer": String(fallbackAnswer.prefix(12_000)),
                "detail": String(fallbackAnswer.prefix(12_000)),
                "actual_result": String(fallbackAnswer.prefix(12_000)),
                "user_visible_message": String(fallbackAnswer.prefix(12_000)),
                "response_language": ReadOnlyResponseLanguage(request: request).rawValue,
                "success": ""
            ].merging(missionTiming.auditPayload()) { current, _ in current }
                .merging(requirements.auditPayload(evidence: evidence)) { current, _ in current }
                .merging(resolution.auditPayload) { current, _ in current }
                .merging(runtimeStatePayload(mission: .verifying, task: task.state, tool: .succeeded)) { current, _ in current }
        )
        return fallbackAnswer
    }

    private func finalizePartialReadOnlyInspection(
        task: inout FDETask,
        workspace: Workspace,
        request: String,
        answer: String,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements,
        timing: ReadOnlyMissionTiming,
        resolution: ReadOnlyBudgetStopResolution
    ) async throws -> FDETask {
        try stateMachine.transition(&task, to: .blocked)
        try await persistence.saveTask(task)
        let usesChinese = ReadOnlyResponseLanguage(request: request) == .chinese
        let finalLedger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: evidence,
            finalAnswer: answer
        )
        let inspected = evidence.map { item in
            item.targetPath == "." ? "\(item.workspaceIdentity) workspace" : item.targetPath
        }
        let incompleteRequirements = requirements.unsatisfied(by: evidence)
        let incomplete = usesChinese
            ? incompleteRequirements.map(chineseRequirementLabel)
            : incompleteRequirements.map(\.label)
        let stopDescription: String
        switch resolution.trigger {
        case .iterationReserve:
            stopDescription = usesChinese ? "操作迭代预算" : "operation-iteration budget"
        case .toolCallLimit:
            stopDescription = usesChinese ? "工具调用预算" : "tool-call budget"
        case .fileReadLimit:
            stopDescription = usesChinese ? "文件读取预算" : "file-read budget"
        case .softDurationReserve, .hardDurationReserve, .hardDurationReached, .providerAndFinalizationReserve:
            stopDescription = usesChinese ? "时间预算" : "time budget"
        case .evidenceSatisfied, .restoredEvidence:
            stopDescription = usesChinese ? "当前证据边界" : "current evidence boundary"
        }
        let introduction: String
        if usesChinese {
            introduction = "本轮只读调查已达到\(stopDescription)。我已检查：\(inspected.joined(separator: "、"))，并据此生成了部分报告。尚未完成：\(incomplete.joined(separator: "、"))。可以从当前任务继续。"
        } else {
            introduction = "This read-only investigation reached its \(stopDescription). I inspected \(inspected.joined(separator: ", ")) and generated the grounded partial report below. Still incomplete: \(incomplete.joined(separator: ", ")). Continue this same task to finish."
        }
        let userVisibleMessage = "\(introduction)\n\n\(answer)"
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Read-only inspection partially finalized with grounded evidence",
            payload: [
                "state": task.state.rawValue,
                "lifecycle_event": "INSPECTION_PARTIALLY_FINALIZED",
                "blocker_reason": resolution.trigger.blockerReason.rawValue,
                "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                "partial_result": "true",
                "requested_scope_complete": "false",
                "grounded_answer": "true",
                "final_answer": String(answer.prefix(12_000)),
                "detail": String(answer.prefix(12_000)),
                "actual_result": String(answer.prefix(12_000)),
                "evidence_count": String(evidence.count),
                "retry_later_allowed": "true",
                "same_task_resumable": "true",
                "user_visible_message": userVisibleMessage,
                "response_language": usesChinese ? "zh" : "en",
                "successful_read_evidence": evidence.contains { $0.toolName == "engineering.read_file" } ? "true" : "false",
                "success": "false"
            ].merging(timing.auditPayload()) { current, _ in current }
                .merging(finalLedger.auditPayload) { current, _ in current }
                .merging(resolution.auditPayload) { current, _ in current }
                .merging(runtimeStatePayload(mission: .blocked, task: task.state, tool: .succeeded)) { current, _ in current }
        )
        return task
    }

    func groundedEvidenceFallback(
        request: String,
        evidence: [ReadOnlyInspectionEvidence],
        satisfied: [ReadOnlyEvidenceRequirementKind],
        unsatisfied: [ReadOnlyEvidenceRequirementKind],
        decision: ReadOnlyBudgetStopDecision
    ) -> String {
        _ = satisfied
        _ = decision
        let language = ReadOnlyResponseLanguage(request: request)
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: evidence)
        let reads = ledger.successfulReadPaths
        let allFacts = evidence.map(\.structuredFacts)
        let frontend = uniqueStrings(allFacts.flatMap(\.frontendFrameworks))
        let backend = uniqueStrings(allFacts.flatMap(\.backendFrameworks))
        let databases = uniqueStrings(allFacts.flatMap(\.databaseProviders))
        let orms = uniqueStrings(allFacts.flatMap(\.ormNames))
        let languages = uniqueStrings(allFacts.flatMap(\.languages))
        let configurationFormats = uniqueStrings(allFacts.flatMap(\.configurationFormats))
        let schemaLanguages = uniqueStrings(allFacts.flatMap(\.schemaLanguages))
        let structure = uniqueStrings(allFacts.flatMap(\.structureEntries))
        let dependencyEvidence = evidence.filter { !$0.structuredFacts.dependencyFacts.isEmpty }
        let dependencyLines = dependencyEvidence.map { item in
            "`\(item.targetPath)`: \(item.structuredFacts.dependencyFacts.joined(separator: ", "))"
        }
        let frontendPaths = evidence.filter { !$0.structuredFacts.frontendFrameworks.isEmpty }.map(\.targetPath)
        let backendPaths = evidence.filter { !$0.structuredFacts.backendFrameworks.isEmpty }.map(\.targetPath)
        let databasePaths = evidence.filter { !$0.structuredFacts.databaseProviders.isEmpty }.map(\.targetPath)
        let unresolved = ledger.unsatisfied
        let buildConfigurationPresent = allFacts.contains { $0.buildConfigurationPresent }
        let testConfigurationPresent = allFacts.contains { $0.testConfigurationPresent }
        let startupRequirement = ledger.requirements.first {
            $0.requirementID == ReadOnlyEvidenceRequirementKind.backendEntryPoint.rawValue
        }
        let assemblyRequirement = ledger.requirements.first {
            $0.requirementID == ReadOnlyEvidenceRequirementKind.backendApplicationAssembly.rawValue
        }

        if language == .chinese {
            let stackParts = [
                frontend.isEmpty ? nil : "前端 \(frontend.joined(separator: " + "))",
                backend.isEmpty ? nil : "后端 \(backend.joined(separator: " + "))",
                orms.isEmpty ? nil : "ORM \(orms.joined(separator: " + "))",
                databases.isEmpty ? nil : "数据库 \(databases.joined(separator: " + "))"
            ].compactMap { $0 }
            let conclusion = unresolved.isEmpty
                ? "已确认这是一个\(stackParts.isEmpty ? "可进行静态分析的项目" : stackParts.joined(separator: "，"))。以下结论只使用成功读取并已提取的安全事实。"
                : "目前只能形成部分结论：\(stackParts.isEmpty ? "已成功读取部分项目证据" : stackParts.joined(separator: "，"))；仍缺少\(unresolved.map(chineseRequirementLabel).joined(separator: "、"))的直接事实。"
            let technologyRows = [
                frontend.isEmpty ? nil : "| 前端 | \(frontend.joined(separator: " + ")) | \(uniqueStrings(frontendPaths).joined(separator: ", ")) | 已确认 |",
                backend.isEmpty ? nil : "| 后端 | \(backend.joined(separator: " + ")) | \(uniqueStrings(backendPaths).joined(separator: ", ")) | 已确认 |",
                orms.isEmpty ? nil : "| ORM | \(orms.joined(separator: " + ")) | \(uniqueStrings(evidence.filter { !$0.structuredFacts.ormNames.isEmpty }.map(\.targetPath)).joined(separator: ", ")) | 已确认 |",
                databases.isEmpty ? nil : "| 数据库 | \(databases.joined(separator: " + ")) | \(uniqueStrings(databasePaths).joined(separator: ", ")) | 已确认 |"
            ].compactMap { $0 }
            let backendFileEvidence = [
                startupRequirement.map { requirement in
                    let path = requirement.supportingRelativePaths.first.map { "`\($0)`" } ?? "尚未确认"
                    let status = requirement.status == .satisfied ? "已读取确认" : "尚未确认"
                    return "- 启动入口：\(path)，\(status)"
                },
                assemblyRequirement.map { requirement in
                    let path = requirement.supportingRelativePaths.first.map { "`\($0)`" } ?? "尚未确认"
                    let status: String
                    if requirement.status == .satisfied {
                        status = "已读取确认"
                    } else if requirement.evidenceLevel == .referencedButNotRead {
                        status = "被入口引用但未读取"
                    } else {
                        status = "尚未确认"
                    }
                    return "- 应用组装：\(path)，\(status)"
                }
            ].compactMap { $0 }.joined(separator: "\n")
            return """
            ## 结论

            \(conclusion)

            ## 已确认的技术栈

            | 类别 | 结论 | 证据 | 可信度 |
            |---|---|---|---|
            \(technologyRows.isEmpty ? "| 技术栈 | 尚无足够直接事实 | — | 未知 |" : technologyRows.joined(separator: "\n"))

            ## 项目结构

            \(structure.isEmpty ? "- 尚未从成功的根目录检查中提取项目结构。" : groupedReadOnlyStructure(structure, language: .chinese))

            ## 主要语言

            - 编程语言：\(languages.isEmpty ? "尚未确认" : languages.joined(separator: "、"))
            - 配置/数据格式：\(configurationFormats.isEmpty ? "尚未确认" : configurationFormats.joined(separator: "、"))
            - Schema 语言：\(schemaLanguages.isEmpty ? "尚未确认" : schemaLanguages.joined(separator: "、"))

            ## 数据库

            - ORM：\(orms.isEmpty ? "尚未确认" : orms.joined(separator: "、"))
            - 数据库引擎：\(databases.isEmpty ? "尚未确认" : databases.joined(separator: "、"))

            \(backendFileEvidence.isEmpty ? "" : "## 后端文件证据\n\n\(backendFileEvidence)\n")

            ## 重要依赖

            \(dependencyLines.isEmpty ? "- 尚未从成功读取的 manifest 中提取依赖名称。" : dependencyLines.map { "- \($0)" }.joined(separator: "\n"))

            ## 实际读取的文件

            \(reads.isEmpty ? "- 无" : reads.map { "- `\($0)`" }.joined(separator: "\n"))

            ## 推断与限制

            - \(buildConfigurationPresent ? "已确认存在构建脚本和构建配置，但本轮未实际执行构建。" : "本轮未实际执行构建，且未确认存在构建配置。")
            - \(testConfigurationPresent ? "已确认存在测试配置，但本轮未实际执行测试。" : "本轮未实际执行测试。")
            - 服务运行状态：未验证运行状态。
            - 部署状态：未验证部署状态。
            - 未将推断写成已确认事实。未执行性能分析、网络请求或运行时测量。
            - 搜索发现但未成功读取的路径不计入“实际读取的文件”。

            ## 下一步

            - \(unresolved.isEmpty ? "当前请求的实质类别均已有直接事实，不需要重复读取上述文件。" : "可在同一任务继续补充\(unresolved.map(chineseRequirementLabel).joined(separator: "、"))的直接证据；已成功读取的文件不会被当作未读文件。")
            """
        }

        let stackParts = [
            frontend.isEmpty ? nil : "frontend \(frontend.joined(separator: " + "))",
            backend.isEmpty ? nil : "backend \(backend.joined(separator: " + "))",
            orms.isEmpty ? nil : "ORM \(orms.joined(separator: " + "))",
            databases.isEmpty ? nil : "database \(databases.joined(separator: " + "))"
        ].compactMap { $0 }
        let conclusion = unresolved.isEmpty
            ? "Confirmed: \(stackParts.isEmpty ? "the project has directly inspected static evidence" : stackParts.joined(separator: ", ")). Every statement below comes from successful reads and extracted safe facts."
            : "This is a partial result. Confirmed so far: \(stackParts.isEmpty ? "some project evidence was successfully inspected" : stackParts.joined(separator: ", ")). Direct facts are still missing for \(unresolved.map(\.label).joined(separator: ", "))."
        let technologyRows = [
            frontend.isEmpty ? nil : "| Frontend | \(frontend.joined(separator: " + ")) | \(uniqueStrings(frontendPaths).joined(separator: ", ")) | Confirmed |",
            backend.isEmpty ? nil : "| Backend | \(backend.joined(separator: " + ")) | \(uniqueStrings(backendPaths).joined(separator: ", ")) | Confirmed |",
            orms.isEmpty ? nil : "| ORM | \(orms.joined(separator: " + ")) | \(uniqueStrings(evidence.filter { !$0.structuredFacts.ormNames.isEmpty }.map(\.targetPath)).joined(separator: ", ")) | Confirmed |",
            databases.isEmpty ? nil : "| Database | \(databases.joined(separator: " + ")) | \(uniqueStrings(databasePaths).joined(separator: ", ")) | Confirmed |"
        ].compactMap { $0 }
        let backendFileEvidence = [
            startupRequirement.map { requirement in
                let path = requirement.supportingRelativePaths.first.map { "`\($0)`" } ?? "Not confirmed"
                let status = requirement.status == .satisfied ? "content read" : "not confirmed"
                return "- Startup entry: \(path), \(status)"
            },
            assemblyRequirement.map { requirement in
                let path = requirement.supportingRelativePaths.first.map { "`\($0)`" } ?? "Not confirmed"
                let status: String
                if requirement.status == .satisfied {
                    status = "content read"
                } else if requirement.evidenceLevel == .referencedButNotRead {
                    status = "referenced by the entry but not read"
                } else {
                    status = "not confirmed"
                }
                return "- Application assembly: \(path), \(status)"
            }
        ].compactMap { $0 }.joined(separator: "\n")
        return """
        ## Conclusion

        \(conclusion)

        ## Confirmed stack

        | Category | Finding | Evidence | Confidence |
        |---|---|---|---|
        \(technologyRows.isEmpty ? "| Stack | Insufficient direct facts | — | Unknown |" : technologyRows.joined(separator: "\n"))

        ## Project structure

        \(structure.isEmpty ? "- No project structure was extracted from a successful root inspection." : groupedReadOnlyStructure(structure, language: .english))

        ## Primary languages

        - Programming languages: \(languages.isEmpty ? "Not confirmed" : languages.joined(separator: ", "))
        - Configuration/data formats: \(configurationFormats.isEmpty ? "Not confirmed" : configurationFormats.joined(separator: ", "))
        - Schema languages: \(schemaLanguages.isEmpty ? "Not confirmed" : schemaLanguages.joined(separator: ", "))

        ## Database

        - ORM: \(orms.isEmpty ? "Not confirmed" : orms.joined(separator: ", "))
        - Database engine: \(databases.isEmpty ? "Not confirmed" : databases.joined(separator: ", "))

        \(backendFileEvidence.isEmpty ? "" : "## Backend file evidence\n\n\(backendFileEvidence)\n")

        ## Important dependencies

        \(dependencyLines.isEmpty ? "- No dependency names were extracted from a successfully read manifest." : dependencyLines.map { "- \($0)" }.joined(separator: "\n"))

        ## Files actually read

        \(reads.isEmpty ? "- None" : reads.map { "- `\($0)`" }.joined(separator: "\n"))

        ## Inferences and limitations

        - \(buildConfigurationPresent ? "Build scripts and configuration are present, but no build was executed during this inspection." : "No build was executed during this inspection, and build configuration was not confirmed.")
        - \(testConfigurationPresent ? "Test configuration is present, but no test was executed during this inspection." : "No test was executed during this inspection.")
        - Runtime status: not verified.
        - Deployment status: not verified.
        - No inference is presented as confirmed. No profiling, network request, or runtime measurement was performed.
        - A discovered search path is not counted as an inspected file until its read succeeds.

        ## Next step

        - \(unresolved.isEmpty ? "All material categories in the current request have direct facts; no listed file needs to be read again." : "Continue this same task to collect direct evidence for \(unresolved.map(\.label).joined(separator: ", ")); successfully read files remain recorded and will not be treated as unread.")
        """
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    private func groupedReadOnlyStructure(
        _ entries: [String],
        language: ReadOnlyResponseLanguage
    ) -> String {
        let safe = uniqueStrings(entries).filter { path in
            let components = path.lowercased().split(separator: "/").map(String.init)
            return !components.contains("node_modules") && !components.contains(".git")
        }
        var root: [String] = []
        var frontend: [String] = []
        var backend: [String] = []
        var data: [String] = []
        var localRun: [String] = []
        for path in safe.prefix(40) {
            let value = path.lowercased()
            let components = value.split(separator: "/").map(String.init)
            let first = components.first ?? value
            if components.contains("prisma") || components.contains("migrations")
                || components.contains("database") || value.contains("schema.") {
                data.append(path)
            } else if value.contains("docker-compose") || value.hasSuffix("dockerfile")
                || value.contains("compose.yaml") || value.contains("compose.yml") {
                localRun.append(path)
            } else if isBackendPath(path) {
                backend.append(path)
            } else if ["src", "public", "app", "pages"].contains(first)
                || value.contains("vite.config") || value.contains("webpack") || value.contains("next.config") {
                frontend.append(path)
            } else {
                root.append(path)
            }
        }
        let groups: [(String, [String])]
        if language == .chinese {
            groups = [("根目录", root), ("前端", frontend), ("后端", backend), ("数据层", data), ("本地运行", localRun)]
        } else {
            groups = [("Root", root), ("Frontend", frontend), ("Backend", backend), ("Data", data), ("Local run", localRun)]
        }
        return groups.compactMap { label, paths in
            guard !paths.isEmpty else { return nil }
            let separator = language == .chinese ? "、" : ", "
            let punctuation = language == .chinese ? "：" : ": "
            return "- \(label)\(punctuation)\(paths.sorted().map { "`\($0)`" }.joined(separator: separator))"
        }.joined(separator: "\n")
    }

    private func chineseRequirementLabel(_ requirement: ReadOnlyEvidenceRequirementKind) -> String {
        switch requirement {
        case .requestedFile: return "指定文件"
        case .projectRoot: return "项目根目录"
        case .projectStructure: return "项目结构"
        case .staticSourceEvidence: return "静态源码证据"
        case .primaryLanguages: return "主要语言"
        case .projectManifest: return "项目 manifest"
        case .frontendManifestOrConfig: return "前端框架"
        case .frontendConfiguration: return "前端配置"
        case .backendManifest: return "后端框架"
        case .databaseSchemaOrConfig: return "数据库"
        case .backendEntryPoint: return "后端启动入口"
        case .backendApplicationAssembly: return "后端应用组装文件"
        case .importantDependencies: return "重要依赖"
        case .inspectedManifestsAndKeyFiles: return "实际读取的 manifest 和关键文件"
        case .assessmentOrderReadBoundary: return "订单只读数据边界"
        case .assessmentAPIServiceBoundary: return "API/服务边界"
        case .assessmentAuthentication: return "身份认证边界"
        case .assessmentRecordAuthorization: return "记录级授权"
        case .assessmentPermissionModel: return "权限模型"
        case .assessmentAuditLogging: return "审计日志"
        case .assessmentMutationPaths: return "修改路径与只读边界"
        case .assessmentSensitiveResponseFields: return "敏感响应字段"
        case .assessmentArchitectureDocumentation: return "相关架构文档"
        case .assessmentExampleConfiguration: return "相关示例配置"
        }
    }

    private func readOnlyBudgetStopResolution(
        trigger: ReadOnlyFinalizationTrigger,
        request: String,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements
    ) -> ReadOnlyBudgetStopResolution {
        guard !evidence.isEmpty else {
            return ReadOnlyBudgetStopResolution(decision: .hardCancel, trigger: trigger)
        }
        let allMaterialRequirementsSatisfied = requirements.unsatisfied(by: evidence).isEmpty
            && hasSufficientEvidenceToFinalize(request: request, evidence: evidence)
        return ReadOnlyBudgetStopResolution(
            decision: allMaterialRequirementsSatisfied
                ? .completeWithCurrentEvidence
                : .partialWithCurrentEvidence,
            trigger: trigger
        )
    }

    private func readOnlyFinalizationTriggerBeforeObservation(
        request: String,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements,
        decisionIterations: Int,
        toolCallCount: Int,
        fileReadCount: Int,
        missionTiming: ReadOnlyMissionTiming
    ) -> ReadOnlyFinalizationTrigger? {
        if requirements.supportsEvidenceDrivenEarlyFinalization,
           requirements.unsatisfied(by: evidence).isEmpty,
           hasSufficientEvidenceToFinalize(request: request, evidence: evidence) {
            return .evidenceSatisfied
        }
        if let durationTrigger = missionTiming.durationFinalizationTrigger() {
            return durationTrigger
        }
        let operationBudget = missionTiming.operationBudget
        let remainingIterations = operationBudget.maximumModelDecisionIterations - decisionIterations
        if remainingIterations <= 1 {
            return .iterationReserve
        }
        if operationBudget.maximumToolCalls - toolCallCount <= 0 {
            return .toolCallLimit
        }
        if operationBudget.maximumFilesRead - fileReadCount <= 0,
           requirements.hasUnsatisfiedFileRequirement(evidence: evidence) {
            return .fileReadLimit
        }
        return nil
    }

    private func deterministicConfirmedFacts(from evidence: [ReadOnlyInspectionEvidence]) -> [String] {
        var facts: [String] = []
        for item in evidence {
            let target = item.evidenceLabel
            let lines = item.output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if item.toolName == "engineering.inspect_project" {
                let safePrefixes = ["Repository:", "Kind:", "Files:", "Source files:", "Directories:", "Dependencies:"]
                for line in lines where safePrefixes.contains(where: { line.hasPrefix($0) }) {
                    facts.append("\(target): \(line)")
                }
                continue
            }

            if item.toolName == "engineering.list_directory" {
                facts.append("\(target): directory listing returned \(lines.count) entr\(lines.count == 1 ? "y" : "ies").")
                continue
            }

            if item.toolName == "engineering.search_files" || item.toolName == "engineering.search_code" {
                facts.append("\(target): \(item.toolName) returned \(lines.count) recorded match\(lines.count == 1 ? "" : "es").")
                continue
            }

            guard item.toolName == "engineering.read_file" else { continue }
            if let data = item.output.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let name = object["name"] as? String, !name.isEmpty {
                    facts.append("\(target): manifest name is \(name).")
                }
                let dependencies = ((object["dependencies"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys)
                    .sorted()
                let devDependencies = ((object["devDependencies"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys)
                    .sorted()
                let dependencyNames = Array((dependencies + devDependencies).prefix(24))
                if !dependencyNames.isEmpty {
                    facts.append("\(target): recorded dependency keys include \(dependencyNames.joined(separator: ", ")).")
                }
                let scripts = ((object["scripts"] as? [String: Any])?.keys ?? Dictionary<String, Any>().keys).sorted()
                if !scripts.isEmpty {
                    facts.append("\(target): recorded script keys are \(scripts.joined(separator: ", ")).")
                }
            } else if item.targetPath.lowercased().hasSuffix(".prisma") {
                if let provider = lines.first(where: { $0.hasPrefix("provider") && $0.contains("=") }) {
                    facts.append("\(target): recorded datasource \(provider).")
                } else {
                    facts.append("\(target): Prisma schema content was successfully read (\(lines.count) non-empty lines).")
                }
            } else {
                facts.append("\(target): file content was successfully read (\(lines.count) non-empty lines).")
            }
        }

        let extensions = Set(evidence.compactMap { item -> String? in
            guard item.toolName == "engineering.read_file" else { return nil }
            let value = URL(fileURLWithPath: item.targetPath).pathExtension.lowercased()
            return value.isEmpty ? nil : ".\(value)"
        }).sorted()
        if !extensions.isEmpty {
            facts.append("Recorded inspected file extensions: \(extensions.joined(separator: ", ")).")
        }

        var seen: Set<String> = []
        let unique = facts.filter { seen.insert($0).inserted }
        return unique.isEmpty ? ["Successful read-only tool results exist for the listed targets."] : unique
    }

    private func isExplicitPartialAnswer(_ answer: String) -> Bool {
        let normalized = answer.lowercased()
        return ["partial", "incomplete", "not inspected", "uninspected", "limitation", "部分", "未完成", "尚未", "限制"]
            .contains { normalized.contains($0) }
    }

    private func restoredReadOnlyEvidence(
        from events: [ExecutionEvent],
        workspace: Workspace
    ) -> [ReadOnlyInspectionEvidence] {
        var seenCallIDs: Set<String> = []
        return events.compactMap { event in
            guard event.type == .stepExecuted,
                  event.payload["success"] == "true",
                  let command = event.payload["command"],
                  ReadOnlyInspectionPolicy.allowedTools.contains(command),
                  let callID = event.payload["tool_call_id"],
                  seenCallIDs.insert(callID).inserted else {
                return nil
            }
            let calledEventID = events.last(where: {
                $0.type == .toolCalled && $0.payload["tool_call_id"] == callID && $0.sequence < event.sequence
            })?.id ?? event.id
            let recordedFacts = ReadOnlyExtractedFacts(eventPayload: event.payload)
            return ReadOnlyInspectionEvidence(
                toolCallID: callID,
                toolName: command,
                workspaceID: workspace.id,
                workspaceIdentity: event.payload["workspace_identity"] ?? "legacy",
                targetPath: event.payload["target_path"] ?? ".",
                output: event.payload["stdout"] ?? event.payload["actual_result"] ?? "",
                toolCalledEventID: calledEventID,
                toolResultEventID: event.id,
                extractedFacts: recordedFacts.factKinds.isEmpty ? nil : recordedFacts,
                query: event.payload["search_query"]
            )
        }
    }

    private func restoredReadOnlyCommandSignatures(from events: [ExecutionEvent]) -> Set<String> {
        Set(events.compactMap { event in
            guard event.type == .stepExecuted,
                  event.payload["success"] == "true",
                  let command = event.payload["command"],
                  ReadOnlyInspectionPolicy.allowedTools.contains(command) else {
                return nil
            }
            if let signature = event.payload["completed_command_signature"], !signature.isEmpty {
                return signature
            }
            let arguments = (event.payload["arguments"] ?? "")
                .split(separator: " ")
                .map(String.init)
                .sorted()
                .joined(separator: ",")
            return [
                command,
                event.payload["workspace_identity"] ?? "legacy",
                event.payload["target_path"] ?? ".",
                arguments
            ].joined(separator: "|")
        })
    }

    private func restoredReadOnlyFailedCommandSignatures(from events: [ExecutionEvent]) -> Set<String> {
        Set(events.compactMap { event in
            guard event.type == .toolFailed,
                  let command = event.payload["command"],
                  ReadOnlyInspectionPolicy.allowedTools.contains(command) else {
                return nil
            }
            if let signature = event.payload["failed_command_signature"], !signature.isEmpty {
                return signature
            }
            if let callID = event.payload["tool_call_id"],
               let called = events.last(where: {
                   $0.type == .toolCalled
                       && $0.sequence < event.sequence
                       && $0.payload["tool_call_id"] == callID
               }),
               let signature = called.payload["completed_command_signature"],
               !signature.isEmpty {
                return signature
            }
            let arguments = (event.payload["arguments"] ?? "")
                .split(separator: " ")
                .map(String.init)
                .sorted()
                .joined(separator: ",")
            return [
                command,
                event.payload["workspace_identity"] ?? "legacy",
                event.payload["target_path"] ?? ".",
                arguments
            ].joined(separator: "|")
        })
    }

    private func readOnlyExplicitNoRereadPaths(
        in instruction: String,
        successfullyReadPaths: Set<String>
    ) -> Set<String> {
        let normalized = instruction.lowercased()
        let negativeMarkers = [
            "不要重复读取", "不要再次读取", "不要重读", "无需重读", "不得重复读取",
            "do not reread", "don't reread", "do not read again", "must not reread", "no reread"
        ]
        guard negativeMarkers.contains(where: normalized.contains) else { return [] }
        return Set(successfullyReadPaths.filter { normalized.contains($0.lowercased()) })
    }

    private func applyingReadOnlyOperationAvailability(
        to readiness: PlanReadinessResult,
        completedSignatures: Set<String>,
        failedSignatures: Set<String>,
        explicitNoRereadPaths: Set<String>,
        evidence: [ReadOnlyInspectionEvidence],
        evidenceRequirements: ReadOnlyEvidenceRequirements
    ) -> PlanReadinessResult {
        var result = readiness
        guard readiness.isReady else { return result }
        let groundedCandidates = groundedReadOnlyCandidates(
            evidence: evidence,
            requirements: evidenceRequirements
        )
        let preferredCandidates = preferredGroundedReadOnlyCandidates(
            groundedCandidates,
            evidence: evidence,
            requirements: evidenceRequirements
        )
        let nextExecutableID = readiness.executableSteps.first?.toolCall.id
        var unavailable: [RejectedReadOnlyToolCall] = []
        var availableSteps: [ReadOnlyExecutableStep] = []
        for executable in readiness.executableSteps {
            let signature = readOnlyCommandSignature(executable)
            let rejection: RejectedReadOnlyToolCall?
            if executable.toolCall.command == "engineering.read_file",
               explicitNoRereadPaths.contains(executable.relativeTargetPath) {
                rejection = RejectedReadOnlyToolCall(
                    toolCallID: executable.toolCall.id,
                    command: executable.toolCall.command,
                    reason: .explicitNoRereadConstraint,
                    detail: "The user explicitly prohibited rereading \(executable.relativeTargetPath); this action is unavailable.",
                    invalidFields: ["path"],
                    allowedArguments: ReadOnlyToolSchemas.all[executable.toolCall.command]?.allowedArguments ?? [],
                    stepID: executable.step.id,
                    stepKind: executable.step.kind
                )
            } else if completedSignatures.contains(signature) {
                rejection = RejectedReadOnlyToolCall(
                    toolCallID: executable.toolCall.id,
                    command: executable.toolCall.command,
                    reason: .commandAlreadyCompleted,
                    detail: "This normalized read-only operation already completed and is unavailable: \(signature).",
                    invalidFields: ["command", "path"],
                    allowedArguments: ReadOnlyToolSchemas.all[executable.toolCall.command]?.allowedArguments ?? [],
                    stepID: executable.step.id,
                    stepKind: executable.step.kind
                )
            } else if failedSignatures.contains(signature) {
                rejection = RejectedReadOnlyToolCall(
                    toolCallID: executable.toolCall.id,
                    command: executable.toolCall.command,
                    reason: .commandPreviouslyFailed,
                    detail: "This normalized read-only operation already failed and cannot be repeated: \(signature).",
                    invalidFields: ["command", "path"],
                    allowedArguments: ReadOnlyToolSchemas.all[executable.toolCall.command]?.allowedArguments ?? [],
                    stepID: executable.step.id,
                    stepKind: executable.step.kind
                )
            } else if executable.toolCall.command == "engineering.read_file",
                      executable.toolCall.id == nextExecutableID,
                      !groundedCandidates.contains(executable.relativeTargetPath) {
                rejection = RejectedReadOnlyToolCall(
                    toolCallID: executable.toolCall.id,
                    command: executable.toolCall.command,
                    reason: .canonicalSearchPathRequired,
                    detail: groundedReadRejectionDetail(
                        proposedPath: executable.relativeTargetPath,
                        candidates: groundedCandidates
                    ),
                    invalidFields: ["path"],
                    allowedArguments: ReadOnlyToolSchemas.all[executable.toolCall.command]?.allowedArguments ?? [],
                    stepID: executable.step.id,
                    stepKind: executable.step.kind
                )
            } else if executable.toolCall.command == "engineering.read_file",
                      executable.toolCall.id == nextExecutableID,
                      !preferredCandidates.isEmpty,
                      !preferredCandidates.contains(executable.relativeTargetPath) {
                rejection = RejectedReadOnlyToolCall(
                    toolCallID: executable.toolCall.id,
                    command: executable.toolCall.command,
                    reason: .canonicalSearchPathRequired,
                    detail: "A higher-value unsatisfied requirement has grounded canonical candidates that must be read first: \(preferredCandidates.joined(separator: " | ")).",
                    invalidFields: ["path"],
                    allowedArguments: ReadOnlyToolSchemas.all[executable.toolCall.command]?.allowedArguments ?? [],
                    stepID: executable.step.id,
                    stepKind: executable.step.kind
                )
            } else {
                rejection = nil
            }
            if let rejection {
                unavailable.append(rejection)
            } else {
                availableSteps.append(executable)
            }
        }
        guard !unavailable.isEmpty else { return result }
        result.isReady = false
        result.executableSteps = availableSteps
        result.executableStepCount = availableSteps.count
        result.rejectedToolCalls.append(contentsOf: unavailable)
        result.blockerReason = unavailable[0].reason
        result.repairable = true
        return result
    }

    private func groundedReadOnlyCandidates(
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements
    ) -> [String] {
        var scores: [String: Int] = [:]
        let unsatisfied = Set(requirements.unsatisfied(by: evidence))
        let manifestDerivedBackendEntries = Set(
            evidence.flatMap(\.structuredFacts.manifestDerivedPaths).filter {
                isBackendEntryCandidate($0)
            }
        )
        func add(_ rawPath: String, score: Int) {
            guard let path = canonicalSafeReadOnlyPath(rawPath), !rawPath.hasSuffix("/") else { return }
            var value = score
            if unsatisfied.contains(.assessmentOrderReadBoundary), isAssessmentOrderPath(path) { value += 1_000 }
            if unsatisfied.contains(.assessmentAuthentication), isAssessmentAuthPath(path) { value += 950 }
            if unsatisfied.contains(.assessmentAuditLogging), isAssessmentAuditPath(path) { value += 900 }
            if unsatisfied.contains(.assessmentArchitectureDocumentation), isAssessmentArchitecturePath(path) { value += 850 }
            if unsatisfied.contains(.assessmentExampleConfiguration), isAssessmentExampleConfigurationPath(path) { value += 800 }
            if unsatisfied.contains(.projectManifest), isRootManifestPath(path) { value += 500 }
            if unsatisfied.contains(.backendManifest), isBackendManifestPath(path) { value += 450 }
            if unsatisfied.contains(.databaseSchemaOrConfig), isDatabaseEvidencePath(path) { value += 400 }
            if unsatisfied.contains(.backendEntryPoint),
               isBackendEntryCandidate(path) || manifestDerivedBackendEntries.contains(path) {
                value += 350
            }
            if unsatisfied.contains(.backendApplicationAssembly), isBackendApplicationAssemblyCandidate(path) {
                value += 325
            }
            if unsatisfied.contains(.frontendConfiguration), isFrontendConfigPath(path) { value += 300 }
            scores[path] = max(scores[path] ?? Int.min, value)
        }

        for item in evidence {
            if item.toolName == "engineering.search_files" || item.toolName == "engineering.search_code" {
                for path in item.structuredFacts.discoveredPaths {
                    add(path, score: 110)
                }
            }
            if item.toolName == "engineering.inspect_project" {
                for path in item.structuredFacts.structureEntries {
                    add(path, score: 70)
                }
            }
            if item.toolName == "engineering.list_directory" {
                for entry in item.structuredFacts.directoryEntries where entry.entryType == .file {
                    add(entry.canonicalChildRelativePath, score: 90)
                }
            }
            for path in item.structuredFacts.manifestDerivedPaths {
                add(path, score: 140)
            }
            for path in item.structuredFacts.referencedSourcePaths {
                add(path, score: 160)
            }
        }
        let readPaths = Set(evidence.filter { $0.toolName == "engineering.read_file" }.map(\.targetPath))
        return scores.keys
            .filter { !readPaths.contains($0) }
            .sorted {
                let left = scores[$0] ?? 0
                let right = scores[$1] ?? 0
                return left == right ? $0 < $1 : left > right
            }
    }

    private func preferredGroundedReadOnlyCandidates(
        _ candidates: [String],
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements
    ) -> [String] {
        let unsatisfied = Set(requirements.unsatisfied(by: evidence))
        let manifestDerivedBackendEntries = Set(
            evidence.flatMap(\.structuredFacts.manifestDerivedPaths).filter {
                isBackendEntryCandidate($0)
            }
        )
        let categories: [(ReadOnlyEvidenceRequirementKind, (String) -> Bool)] = [
            (.assessmentOrderReadBoundary, isAssessmentOrderPath),
            (.assessmentAuthentication, isAssessmentAuthPath),
            (.assessmentAuditLogging, isAssessmentAuditPath),
            (.assessmentArchitectureDocumentation, isAssessmentArchitecturePath),
            (.assessmentExampleConfiguration, isAssessmentExampleConfigurationPath),
            (.projectManifest, isRootManifestPath),
            (.backendManifest, isBackendManifestPath),
            (.databaseSchemaOrConfig, isDatabaseEvidencePath),
            (.backendEntryPoint, { self.isBackendEntryCandidate($0) || manifestDerivedBackendEntries.contains($0) }),
            (.backendApplicationAssembly, isBackendApplicationAssemblyCandidate),
            (.frontendConfiguration, isFrontendConfigPath)
        ]
        for (requirement, predicate) in categories where unsatisfied.contains(requirement) {
            let matching = candidates.filter(predicate)
            switch requirement {
            case .assessmentOrderReadBoundary, .assessmentAuthentication,
                 .assessmentAuditLogging, .assessmentArchitectureDocumentation,
                 .assessmentExampleConfiguration:
                // Capability requirements are ordered. An unrelated path must
                // not conceal that the next required canonical path is absent.
                return matching
            default:
                // Preserve the established generic/frontend Phase 2C behavior:
                // continue to the next grounded category when this one has no
                // available candidate yet.
                if !matching.isEmpty { return matching }
            }
        }
        return candidates
    }

    private func groundedReadRejectionDetail(proposedPath: String, candidates: [String]) -> String {
        guard !candidates.isEmpty else {
            return "read_file path \(proposedPath) is ungrounded. No canonical file candidate has been established; inspect/list/search the selected workspace before reading a file."
        }
        return "read_file path \(proposedPath) is ungrounded. Use one exact canonical candidate without changing its directory, basename, or extension: \(candidates.joined(separator: " | "))."
    }

    private func deterministicCanonicalNextActionRepair(
        action: ReadOnlyNextAction?,
        rejection: ReadOnlyNextActionRejection,
        missionTarget: ReadOnlyMissionTarget,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements
    ) -> ReadOnlyNextAction? {
        guard missionTarget.unambiguousWorkspace != nil,
              let action,
              action.decision == .tool,
              action.toolCalls.count == 1,
              let originalCall = action.toolCalls.first,
              originalCall.command == "engineering.read_file",
              rejection.reason == .canonicalSearchPathRequired
                || (rejection.reason == .nextActionInvalidTool
                    && rejection.detail.contains("missing required argument path")) else {
            return nil
        }

        let grounded = groundedReadOnlyCandidates(evidence: evidence, requirements: requirements)
        let preferred = preferredGroundedReadOnlyCandidates(
            grounded,
            evidence: evidence,
            requirements: requirements
        )
        let proposed = readOnlyArgumentValue("path", in: originalCall.arguments)
        let matches: [String]
        if let proposed {
            let proposedName = URL(fileURLWithPath: proposed).lastPathComponent.lowercased()
            matches = preferred.filter {
                URL(fileURLWithPath: $0).lastPathComponent.lowercased() == proposedName
            }
        } else {
            matches = preferred.count == 1 ? preferred : []
        }
        guard matches.count == 1, let canonicalPath = matches.first,
              let workspaceIdentity = missionTarget.unambiguousWorkspace?.rawValue else {
            return nil
        }

        var repairedCall = originalCall
        repairedCall.arguments = ["workspace=\(workspaceIdentity)", "path=\(canonicalPath)"]
        repairedCall.workingDirectory = nil
        var repairedAudit = action.audit
        repairedAudit.sourceContract = "runtime_canonical_path_repair"
        repairedAudit.normalizationNotes.append("Repaired once from trusted canonical discovery metadata.")
        return ReadOnlyNextAction(
            decision: .tool,
            toolCalls: [repairedCall],
            reasoningSummary: action.reasoningSummary,
            audit: repairedAudit
        )
    }

    private func canonicalPathRepairAuditPayload(
        validation: ReadOnlyNextActionValidation,
        evidence: [ReadOnlyInspectionEvidence],
        rejection: ReadOnlyNextActionRejection,
        source: String
    ) -> [String: String] {
        guard case .accepted(.tool(let executable)) = validation,
              executable.toolCall.command == "engineering.read_file" else {
            return [:]
        }
        let path = executable.relativeTargetPath
        let sources = evidence.filter { item in
            let facts = item.structuredFacts
            return facts.discoveredPaths.contains(path)
                || facts.structureEntries.contains(path)
                || facts.manifestDerivedPaths.contains(path)
                || facts.referencedSourcePaths.contains(path)
                || facts.directoryEntries.contains { $0.canonicalChildRelativePath == path }
        }
        guard !sources.isEmpty else { return [:] }
        return [
            "canonical_path_repair_count": "1",
            "canonical_path_repair_source": source,
            "canonical_path_provenance": "trusted_discovered_metadata",
            "canonical_path_repaired_to": path,
            "canonical_path_source_event_ids": sources.map(\.toolResultEventID.uuidString).joined(separator: " | "),
            "canonical_path_source_tool_call_ids": sources.map(\.toolCallID).joined(separator: " | "),
            "canonical_path_original_rejection": safeReadOnlyRejectionDetail(rejection)
        ]
    }

    private func safeReadOnlyRejectionDetail(_ rejection: ReadOnlyNextActionRejection) -> String {
        let safe = AgentPresentationSanitizer.safeMarkdownContent(
            rejection.detail,
            fallback: rejection.reason.rawValue
        )
        return String(safe.prefix(2_000))
    }

    private func isManifestPath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return [
            "package.json", "package.swift", "pyproject.toml", "requirements.txt", "pom.xml",
            "build.gradle", "build.gradle.kts", "cargo.toml", "gemfile", "composer.json", "go.mod"
        ].contains(name) || path.lowercased().hasSuffix(".csproj") || path.lowercased().hasSuffix(".podspec")
    }

    private func isRootManifestPath(_ path: String) -> Bool {
        isManifestPath(path) && !path.contains("/")
    }

    private func isBackendManifestPath(_ path: String) -> Bool {
        isManifestPath(path) && isBackendPath(path)
    }

    private func isBackendPath(_ path: String) -> Bool {
        let segments: Set<String> = ["server", "backend", "api", "service", "services"]
        return path.lowercased().split(separator: "/").contains { segments.contains(String($0)) }
    }

    private func isBackendEntryCandidate(_ path: String) -> Bool {
        guard isBackendPath(path), isSourceCandidate(path) else { return false }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        return ["index", "main", "server", "bootstrap", "start"].contains(stem)
    }

    private func isBackendApplicationAssemblyCandidate(_ path: String) -> Bool {
        guard isBackendPath(path), isSourceCandidate(path) else { return false }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        return ["app", "application"].contains(stem)
    }

    private func isDatabaseEvidencePath(_ path: String) -> Bool {
        let value = path.lowercased()
        let name = URL(fileURLWithPath: value).lastPathComponent
        return name == "schema.prisma"
            || value.contains("/prisma/")
            || value.contains("/database/")
            || value.contains("/migrations/")
            || name.contains("schema")
            || name.contains("database")
    }

    private func isFrontendConfigPath(_ path: String) -> Bool {
        let value = path.lowercased()
        return !isBackendPath(value)
            && (value.contains("vite.config") || value.contains("webpack") || value.contains("next.config"))
    }

    private func isAssessmentOrderPath(_ path: String) -> Bool {
        let value = path.lowercased()
        return isSourceCandidate(value)
            && (URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent.contains("order")
                || value.split(separator: "/").contains("orders"))
    }

    private func isAssessmentAuthPath(_ path: String) -> Bool {
        let value = path.lowercased()
        return isSourceCandidate(value)
            && ["auth", "authentication", "authorization", "identity", "session"].contains {
                URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent.contains($0)
            }
    }

    private func isAssessmentAuditPath(_ path: String) -> Bool {
        let value = path.lowercased()
        return isSourceCandidate(value)
            && URL(fileURLWithPath: value).deletingPathExtension().lastPathComponent.contains("audit")
    }

    private func isAssessmentArchitecturePath(_ path: String) -> Bool {
        let value = path.lowercased()
        return value == "docs/architecture.md" || value.hasSuffix("/architecture.md")
    }

    private func isAssessmentExampleConfigurationPath(_ path: String) -> Bool {
        let value = path.lowercased()
        return value == "config/app.example.json" || value.hasSuffix("/app.example.json")
    }

    private func canonicalSafeReadOnlyPath(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\"),
              !ReadOnlySensitivePathPolicy.isSensitive(trimmed) else {
            return nil
        }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return parts.joined(separator: "/")
    }

    private func isSourceCandidate(_ path: String) -> Bool {
        let extensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "swift", "py", "go", "rs", "java", "kt"]
        return extensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func groundedAlternativeReadStep(
        after failed: ReadOnlyExecutableStep,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements,
        workspace: Workspace,
        missionTarget: ReadOnlyMissionTarget,
        excludedSignatures: Set<String>,
        iteration: Int
    ) -> ReadOnlyExecutableStep? {
        let allCandidates = groundedReadOnlyCandidates(evidence: evidence, requirements: requirements)
            .filter { $0 != failed.relativeTargetPath }
        let manifestDerivedBackendEntries = Set(
            evidence.flatMap(\.structuredFacts.manifestDerivedPaths).filter {
                isBackendEntryCandidate($0)
            }
        )
        let failedCategory = readOnlyCandidateCategory(
            failed.relativeTargetPath,
            manifestDerivedBackendEntries: manifestDerivedBackendEntries
        )
        let sameCategory = allCandidates.filter {
            readOnlyCandidateCategory($0, manifestDerivedBackendEntries: manifestDerivedBackendEntries) == failedCategory
        }
        let candidates = sameCategory.isEmpty ? allCandidates : sameCategory
        for (index, path) in candidates.enumerated() {
            let call = ToolCall(
                id: "recovery.alternative.\(iteration).\(index)",
                type: .api,
                command: "engineering.read_file",
                arguments: ["workspace=\(failed.workspaceIdentity)", "path=\(path)"],
                workingDirectory: nil,
                requiresApproval: false
            )
            let step = PlanStep(
                id: "recovery.alternative.step.\(iteration).\(index)",
                title: "Read alternative grounded candidate",
                intent: "Read the next highest-value canonical candidate after a recoverable candidate failure.",
                kind: .tool,
                toolCallID: call.id,
                requiresApproval: false,
                retryBudget: 0
            )
            let output = StructuredAgentOutput(
                plan: [step], actions: [], toolCalls: [call], risks: [], confidence: 1
            )
            let readiness = readOnlyReadinessValidator.validate(
                output,
                workspace: workspace,
                missionTarget: missionTarget
            )
            guard let executable = readiness.executableSteps.first,
                  readiness.isReady,
                  !excludedSignatures.contains(readOnlyCommandSignature(executable)) else {
                continue
            }
            return executable
        }
        return nil
    }

    private func readOnlyCandidateCategory(
        _ path: String,
        manifestDerivedBackendEntries: Set<String> = []
    ) -> String {
        if isAssessmentOrderPath(path) { return "assessment_order_boundary" }
        if isAssessmentAuthPath(path) { return "assessment_authentication" }
        if isAssessmentAuditPath(path) { return "assessment_audit_logging" }
        if isAssessmentArchitecturePath(path) { return "assessment_architecture" }
        if isAssessmentExampleConfigurationPath(path) { return "assessment_example_configuration" }
        if isBackendManifestPath(path) { return "backend_manifest" }
        if isRootManifestPath(path) { return "root_manifest" }
        if isDatabaseEvidencePath(path) { return "database" }
        if isBackendEntryCandidate(path) || manifestDerivedBackendEntries.contains(path) { return "backend_entry" }
        if isBackendApplicationAssemblyCandidate(path) { return "backend_application_assembly" }
        if isFrontendConfigPath(path) { return "frontend_config" }
        if isSourceCandidate(path) { return "source" }
        return "file"
    }

    private func readOnlyCandidateCategoryPriority(
        candidates: [String],
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements
    ) -> [String] {
        let unsatisfied = Set(requirements.unsatisfied(by: evidence))
        let manifestDerivedBackendEntries = Set(
            evidence.flatMap(\.structuredFacts.manifestDerivedPaths).filter {
                isBackendEntryCandidate($0)
            }
        )
        var categories: [String] = []
        func append(_ requirement: ReadOnlyEvidenceRequirementKind, _ label: String, matching: (String) -> Bool) {
            guard unsatisfied.contains(requirement) else { return }
            let paths = candidates.filter(matching)
            categories.append(paths.isEmpty ? "\(label) (discover exact path)" : "\(label): \(paths.joined(separator: " | "))")
        }
        append(.assessmentOrderReadBoundary, "order read/data boundary", matching: isAssessmentOrderPath)
        append(.assessmentAuthentication, "authentication and permission boundary", matching: isAssessmentAuthPath)
        append(.assessmentAuditLogging, "audit logging boundary", matching: isAssessmentAuditPath)
        append(.assessmentArchitectureDocumentation, "architecture documentation", matching: isAssessmentArchitecturePath)
        append(.assessmentExampleConfiguration, "example configuration", matching: isAssessmentExampleConfigurationPath)
        append(.projectManifest, "root manifest", matching: isRootManifestPath)
        append(.backendManifest, "nested backend manifest", matching: isBackendManifestPath)
        append(.databaseSchemaOrConfig, "database schema/config", matching: isDatabaseEvidencePath)
        append(
            .backendEntryPoint,
            "backend startup entry",
            matching: { self.isBackendEntryCandidate($0) || manifestDerivedBackendEntries.contains($0) }
        )
        append(
            .backendApplicationAssembly,
            "backend application assembly",
            matching: isBackendApplicationAssemblyCandidate
        )
        append(.frontendConfiguration, "frontend configuration", matching: isFrontendConfigPath)
        if categories.isEmpty, !candidates.isEmpty {
            categories.append("remaining grounded files: \(candidates.joined(separator: " | "))")
        }
        return categories
    }

    private func failedReadOnlyPaths(from signatures: Set<String>) -> [String] {
        uniqueStrings(signatures.compactMap { signature in
            let parts = signature.split(separator: "|", maxSplits: 3).map(String.init)
            guard parts.count > 2, parts[0] == "engineering.read_file" else { return nil }
            return parts[2]
        })
    }

    private func validateReadOnlyNextAction(
        _ action: ReadOnlyNextAction,
        workspace: Workspace,
        missionTarget: ReadOnlyMissionTarget,
        request: String,
        evidence: [ReadOnlyInspectionEvidence],
        executedCallIDs: Set<String>,
        executedCommandSignatures: Set<String>,
        iteration: Int,
        evidenceRequirements: ReadOnlyEvidenceRequirements,
        allowPartialFinalization: Bool
    ) -> ReadOnlyNextActionValidation {
        func present(_ value: String?) -> Bool {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        func reject(_ reason: PlanReadinessBlocker, _ detail: String) -> ReadOnlyNextActionValidation {
            .rejected(ReadOnlyNextActionRejection(reason: reason, detail: detail))
        }

        if action.audit.returnedCompletePlan || !action.audit.unexpectedFields.isEmpty {
            let fields = action.audit.unexpectedFields.joined(separator: ", ")
            return reject(
                .invalidNextAction,
                fields.isEmpty
                    ? "OBSERVE returned a complete replacement plan instead of one next decision."
                    : "OBSERVE returned unsupported next-action field(s): \(fields)."
            )
        }
        guard let decision = action.decision else {
            return reject(
                .invalidNextAction,
                action.rawDecision.isEmpty
                    ? "Observation decision is missing."
                    : "Unsupported observation decision type: \(action.rawDecision)."
            )
        }

        switch decision {
        case .tool:
            guard !present(action.finalAnswer), !present(action.clarification), !present(action.blockerReason) else {
                return reject(.invalidNextAction, "A tool decision cannot also contain a final answer, clarification, or blocker.")
            }
            guard !action.toolCalls.isEmpty else {
                return reject(.nextActionMissingTool, "decision=tool requires exactly one tool_call.")
            }
            guard action.toolCalls.count == 1 else {
                return reject(.multipleNextActions, "decision=tool returned \(action.toolCalls.count) tool calls; exactly one is allowed.")
            }
            let call = action.toolCalls[0]
            let step = PlanStep(
                id: "observation.\(iteration).\(call.id)",
                title: "Observation next action: \(call.command)",
                intent: action.reasoningSummary ?? "Continue the read-only inspection with one evidence-gathering action.",
                kind: .tool,
                toolCallID: call.id,
                requiresApproval: false,
                retryBudget: 0
            )
            let output = StructuredAgentOutput(
                plan: [step],
                actions: [],
                toolCalls: [call],
                risks: [],
                confidence: 1
            )
            let readiness = readOnlyReadinessValidator.validate(
                output,
                workspace: workspace,
                missionTarget: missionTarget
            )
            guard readiness.isReady, readiness.executableSteps.count == 1, let executable = readiness.executableSteps.first else {
                let detail = readiness.rejectedToolCalls.first?.detail
                    ?? "The requested next tool did not pass read-only scope and argument validation."
                return reject(.nextActionInvalidTool, detail)
            }
            guard !executedCallIDs.contains(executable.toolCall.id) else {
                return reject(.nextActionInvalidTool, "The completed toolCallID \(executable.toolCall.id) cannot be executed again.")
            }
            if executable.toolCall.command == "engineering.read_file" {
                let successfulReadPaths = Set(
                    evidence.filter { $0.toolName == "engineering.read_file" }.map(\.targetPath)
                )
                let forbiddenPaths = readOnlyExplicitNoRereadPaths(
                    in: request,
                    successfullyReadPaths: successfulReadPaths
                )
                guard !forbiddenPaths.contains(executable.relativeTargetPath) else {
                    return reject(
                        .explicitNoRereadConstraint,
                        "The user explicitly prohibited rereading \(executable.relativeTargetPath); this action is unavailable."
                    )
                }
                let groundedCandidates = groundedReadOnlyCandidates(
                    evidence: evidence,
                    requirements: evidenceRequirements
                )
                let preferredCandidates = preferredGroundedReadOnlyCandidates(
                    groundedCandidates,
                    evidence: evidence,
                    requirements: evidenceRequirements
                )
                guard groundedCandidates.contains(executable.relativeTargetPath) else {
                    return reject(
                        .canonicalSearchPathRequired,
                        groundedReadRejectionDetail(
                            proposedPath: executable.relativeTargetPath,
                            candidates: preferredCandidates
                        )
                    )
                }
                if !preferredCandidates.isEmpty,
                   !preferredCandidates.contains(executable.relativeTargetPath) {
                    return reject(
                        .canonicalSearchPathRequired,
                        "Read a grounded candidate for the highest-value unsatisfied requirement first: \(preferredCandidates.joined(separator: " | "))."
                    )
                }
            }
            let signature = readOnlyCommandSignature(executable)
            guard !executedCommandSignatures.contains(signature) else {
                return reject(
                    .nextActionInvalidTool,
                    "The normalized read-only command already completed and cannot be replayed: \(signature)."
                )
            }
            return .accepted(.tool(executable))
        case .finalize:
            guard action.toolCalls.isEmpty else {
                return reject(.multipleNextActions, "decision=finalize must contain zero tool calls.")
            }
            guard present(action.finalAnswer), !present(action.clarification), !present(action.blockerReason) else {
                return reject(.invalidNextAction, "decision=finalize requires only one non-empty final_answer.")
            }
            let answer = action.finalAnswer!.trimmingCharacters(in: .whitespacesAndNewlines)
            let evidenceRequirementsSatisfied = evidenceRequirements.unsatisfied(by: evidence).isEmpty
            guard (allowPartialFinalization || (
                evidenceRequirementsSatisfied
                    && hasSufficientEvidenceToFinalize(request: request, evidence: evidence)
            )), isGroundedFinalAnswer(answer, evidence: evidence, request: request) else {
                return reject(
                    .insufficientEvidenceToFinalize,
                    "The final answer does not yet meet the request-specific workspace evidence threshold; gather another read-only result."
                )
            }
            let answerContract = ReadOnlyFinalAnswerContract.validate(
                answer: answer,
                request: request,
                requirements: evidenceRequirements,
                evidence: evidence,
                requireComplete: evidenceRequirementsSatisfied
            )
            guard answerContract.accepted else {
                return reject(
                    .providerOutputInvalid,
                    "The final answer violates the grounded report contract: \(answerContract.safeContractFailures.map(\.rawValue).joined(separator: ", "))."
                )
            }
            return .accepted(.finalAnswer(answer))
        case .clarify:
            guard action.toolCalls.isEmpty,
                  present(action.clarification),
                  !present(action.finalAnswer),
                  !present(action.blockerReason) else {
                return reject(.invalidNextAction, "decision=clarify requires zero tool calls and only one essential clarification.")
            }
            return .accepted(.clarification(action.clarification!.trimmingCharacters(in: .whitespacesAndNewlines)))
        case .block:
            guard action.toolCalls.isEmpty,
                  present(action.blockerReason),
                  !present(action.finalAnswer),
                  !present(action.clarification) else {
                return reject(.invalidNextAction, "decision=block requires zero tool calls and only one safe blocker_reason.")
            }
            return .accepted(.blocker(action.blockerReason!.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private func recordReadOnlyNextAction(
        _ action: ReadOnlyNextAction,
        validation: ReadOnlyNextActionValidation,
        attempt: Int,
        workspace: Workspace,
        task: FDETask,
        iteration: Int,
        additionalPayload: [String: String] = [:]
    ) async throws {
        let rejection = validation.rejection
        let lifecycleEvent = attempt == 0 ? "NEXT_ACTION_DECODED" : "NEXT_ACTION_REPAIRED"
        let providerStage = attempt == 0 ? "observation_next_action" : "observation_next_action_repair"
        let exactRejection = rejection.map {
            safeReadOnlyRejectionDetail($0)
        } ?? ""
        var payload: [String: String] = [
            "lifecycle_event": lifecycleEvent,
            "provider_stage": providerStage,
            "repair_attempt": String(attempt),
            "iteration": String(iteration),
            "decision": action.rawDecision,
            "decoded_tool_call_count": String(action.toolCalls.count),
            "decoded_tool_call_ids": action.toolCalls.map(\.id).joined(separator: " | "),
            "decoded_tool_commands": action.toolCalls.map(\.command).joined(separator: " | "),
            "decoded_plan_step_count": String(action.audit.decodedStepIDs.count),
            "decoded_plan_step_ids": action.audit.decodedStepIDs.joined(separator: " | "),
            "decoded_plan_step_kinds": action.audit.decodedStepKinds.joined(separator: " | "),
            "decoded_plan_step_tool_call_ids": action.audit.decodedStepToolCallIDs.joined(separator: " | "),
            "final_answer_present": action.finalAnswer?.isEmpty == false ? "true" : "false",
            "clarification_present": action.clarification?.isEmpty == false ? "true" : "false",
            "blocker_reason_present": action.blockerReason?.isEmpty == false ? "true" : "false",
            "reasoning_summary_present": action.reasoningSummary?.isEmpty == false ? "true" : "false",
            "returned_complete_plan": action.audit.returnedCompletePlan ? "true" : "false",
            "source_contract": action.audit.sourceContract,
            "normalization_notes": action.audit.normalizationNotes.joined(separator: " | "),
            "unexpected_fields": action.audit.unexpectedFields.joined(separator: " | "),
            "safe_model_output_json": action.audit.safeModelOutputJSON,
            "next_action_valid": rejection == nil ? "true" : "false",
            "rejection_reason": rejection?.reason.rawValue ?? "",
            "exact_rejection": exactRejection
        ]
        payload.merge(additionalPayload) { current, _ in current }
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: rejection == nil ? "Observation next action accepted" : "Observation next action rejected",
            payload: payload.merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .succeeded)) { current, _ in current }
        )
    }

    private func readOnlyCommandSignature(_ executable: ReadOnlyExecutableStep) -> String {
        [
            executable.toolCall.command,
            executable.workspaceIdentity,
            executable.relativeTargetPath,
            executable.toolCall.arguments.sorted().joined(separator: ",")
        ].joined(separator: "|")
    }

    private func blockReadOnlyInspection(
        task: inout FDETask,
        workspace: Workspace,
        reason: PlanReadinessBlocker,
        detail: String,
        providerStage: String? = nil,
        providerDiagnostic: String? = nil,
        providerAuditPayload: [String: String] = [:],
        timingPayload: [String: String] = [:],
        evidenceRequirementsPayload: [String: String] = [:],
        additionalPayload: [String: String] = [:]
    ) async throws -> FDETask {
        try stateMachine.transition(&task, to: .blocked)
        try await persistence.saveTask(task)
        let priorEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let hasSuccessfulReadEvidence = priorEvents.contains {
            $0.type == .stepExecuted
                && $0.payload["success"] == "true"
                && $0.payload["command"] == "engineering.read_file"
        }
        let responseLanguage = MissionIntentParser().parse(task.rawInput).detectedLanguage
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Read-only inspection blocked: \(reason.rawValue)",
            payload: [
                "state": task.state.rawValue,
                "lifecycle_event": "PLAN_BLOCKED",
                "blocker_reason": reason.rawValue,
                "detail": AgentPresentationSanitizer.safeContent(detail, fallback: reason.rawValue),
                "provider_stage": providerStage ?? "",
                "provider_diagnostic": providerDiagnostic ?? "",
                "response_language": responseLanguage,
                "successful_read_evidence": hasSuccessfulReadEvidence ? "true" : "false",
                "retry_later_allowed": "true",
                "success": "false"
            ].merging(providerAuditPayload) { current, _ in current }
                .merging(timingPayload) { current, _ in current }
                .merging(evidenceRequirementsPayload) { current, _ in current }
                .merging(additionalPayload) { current, _ in current }
                .merging(runtimeStatePayload(mission: .blocked, task: task.state, tool: .skipped)) { current, _ in current }
        )
        return task
    }

    private func readOnlyToolFailureClassification(_ detail: String) -> ReadOnlyToolFailureClassification {
        let normalized = detail.lowercased()
        if normalized.contains("file not found") || normalized.contains("no such file") {
            return .missingPath
        }
        if normalized.contains("outside") && normalized.contains("workspace") {
            return .workspaceScopeViolation
        }
        if normalized.contains("permission denied")
            || normalized.contains("not readable")
            || normalized.contains("operation not permitted") {
            return .permissionSecurityFailure
        }
        if normalized.contains("missing required argument")
            || normalized.contains("invalid argument")
            || normalized.contains("malformed") {
            return .malformedAction
        }
        if normalized.contains("not valid utf-8") || normalized.contains("candidate") {
            return .recoverableCandidateFailure
        }
        return .hardRuntimeFailure
    }

    private func recordReadOnlyCandidateRecovery(
        failed: ReadOnlyExecutableStep,
        alternative: ReadOnlyExecutableStep,
        classification: ReadOnlyToolFailureClassification,
        error: String,
        workspace: Workspace,
        task: FDETask,
        iteration: Int
    ) async throws {
        try await record(
            type: .recoveryAttempted,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Trying one alternative grounded read candidate",
            payload: [
                "lifecycle_event": "RECOVERABLE_CANDIDATE_FAILURE",
                "recovery_kind": "read_only_candidate_alternative",
                "tool_failure_classification": classification.rawValue,
                "failed_tool_call_id": failed.toolCall.id,
                "failed_command_signature": readOnlyCommandSignature(failed),
                "failed_relative_path": failed.relativeTargetPath,
                "recovery_tool_call_id": alternative.toolCall.id,
                "alternative_relative_path": alternative.relativeTargetPath,
                "alternative_command_signature": readOnlyCommandSignature(alternative),
                "error": String(error.prefix(1_000)),
                "iteration": String(iteration),
                "success": ""
            ].merging(runtimeStatePayload(mission: .adapt, task: task.state, tool: .failed)) { current, _ in current }
        )
    }

    private func groundedReadFailureFallback(
        request: String,
        evidence: [ReadOnlyInspectionEvidence],
        requirements: ReadOnlyEvidenceRequirements,
        failedPath: String,
        error: String
    ) -> String {
        let base = groundedEvidenceFallback(
            request: request,
            evidence: evidence,
            satisfied: requirements.satisfied(by: evidence),
            unsatisfied: requirements.unsatisfied(by: evidence),
            decision: .partialWithCurrentEvidence
        )
        if ReadOnlyResponseLanguage(request: request) == .chinese {
            let reason = readOnlyToolFailureClassification(error) == .missingPath
                ? "该候选文件不存在"
                : "读取候选文件失败"
            return "已保留之前确认的全部直接证据。本次读取后端入口候选 `\(failedPath)` 失败（\(reason)），尚未取得入口代码的直接证据，因此任务仍为部分完成。\n\n\(base)"
        }
        return "All previously confirmed direct evidence is preserved. Reading backend-entry candidate `\(failedPath)` failed, so direct entry-code evidence remains incomplete.\n\n\(base)"
    }

    private func failReadOnlyInspection(
        task: inout FDETask,
        workspace: Workspace,
        reason: PlanReadinessBlocker,
        detail: String,
        classification: ReadOnlyToolFailureClassification,
        timing: ReadOnlyMissionTiming,
        requirements: ReadOnlyEvidenceRequirements,
        evidence: [ReadOnlyInspectionEvidence]
    ) async throws -> FDETask {
        try stateMachine.transition(&task, to: .failed)
        try await persistence.saveTask(task)
        let usesChinese = ReadOnlyResponseLanguage(request: task.rawInput) == .chinese
        let userVisible = usesChinese
            ? "任务失败：工作区读取未能产生可用的直接证据。错误分类：\(classification.rawValue)。"
            : "Task failed: workspace access produced no useful direct evidence. Classification: \(classification.rawValue)."
        try await record(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Read-only inspection failed without a useful grounded result",
            payload: [
                "state": task.state.rawValue,
                "lifecycle_event": "INSPECTION_FAILED",
                "blocker_reason": reason.rawValue,
                "tool_failure_classification": classification.rawValue,
                "detail": String(detail.prefix(1_000)),
                "user_visible_message": userVisible,
                "response_language": usesChinese ? "zh" : "en",
                "useful_evidence_available": evidence.isEmpty ? "false" : "true",
                "success": "false"
            ].merging(timing.auditPayload()) { current, _ in current }
                .merging(requirements.auditPayload(evidence: evidence)) { current, _ in current }
                .merging(runtimeStatePayload(mission: .failed, task: task.state, tool: .failed)) { current, _ in current }
        )
        return task
    }

    private func recordReadOnlyToolFailure(
        _ executable: ReadOnlyExecutableStep,
        error: String,
        classification: ReadOnlyToolFailureClassification,
        workspace: Workspace,
        task: FDETask,
        iteration: Int
    ) async throws {
        try await record(
            type: .toolFailed,
            workspaceID: workspace.id,
            taskID: task.id,
            summary: "Read-only tool failed: \(executable.toolCall.command)",
            payload: readOnlyToolMetadata(executable, iteration: iteration)
                .merging([
                    "lifecycle_event": "TOOL_FAILED",
                    "error": String(error.prefix(1_000)),
                    "tool_failure_classification": classification.rawValue,
                    "recoverable_candidate_failure": classification.isRecoverableCandidateFailure ? "true" : "false",
                    "failed_command_signature": readOnlyCommandSignature(executable),
                    "success": "false"
                ]) { current, _ in current }
                .merging(runtimeStatePayload(mission: .observe, task: task.state, tool: .failed)) { current, _ in current }
        )
    }

    private func readOnlyToolMetadata(_ executable: ReadOnlyExecutableStep, iteration: Int) -> [String: String] {
        var metadata = [
            "step_id": executable.step.id,
            "tool_call_id": executable.toolCall.id,
            "command": executable.toolCall.command,
            "arguments": safeArguments(executable.toolCall.arguments),
            "workspace_identity": executable.workspaceIdentity,
            "target_path": executable.relativeTargetPath,
            "model_supplied_arguments": executable.modelSuppliedArguments.joined(separator: " | "),
            "runtime_defaulted_arguments": executable.runtimeDefaultedArguments.joined(separator: " | "),
            "model_workspace_label": executable.authorityAudit.modelWorkspaceLabel,
            "normalized_workspace_identity": executable.authorityAudit.normalizedWorkspaceIdentity,
            "trusted_workspace_root": executable.authorityAudit.trustedRoot,
            "model_working_directory": executable.authorityAudit.rawModelWorkingDirectory,
            "model_path": executable.authorityAudit.modelPath,
            "normalized_relative_path": executable.authorityAudit.normalizedRelativePath,
            "symlink_resolution_changed": executable.authorityAudit.symlinkResolutionChangedPath ? "true" : "false",
            "iteration": String(iteration)
        ]
        if let query = readOnlyArgumentValue("query", in: executable.toolCall.arguments) {
            metadata["search_query"] = AgentPresentationSanitizer.safeContent(query, fallback: "")
        }
        return metadata
    }

    private func readOnlyToolPresentationTitle(_ executable: ReadOnlyExecutableStep) -> String {
        let workspaceLabel = executable.workspaceIdentity.lowercased() == "legacy" ? "Legacy" : "Agent"
        switch executable.toolCall.command {
        case "engineering.inspect_project":
            return "Inspect \(workspaceLabel) workspace project structure"
        case "engineering.list_directory":
            return "List \(workspaceLabel) workspace directory · \(executable.relativeTargetPath)"
        case "engineering.search_files":
            return "Search \(workspaceLabel) workspace files · \(executable.relativeTargetPath)"
        case "engineering.search_code":
            return "Search \(workspaceLabel) workspace source · \(executable.relativeTargetPath)"
        case "engineering.read_file":
            return "Read \(workspaceLabel) workspace file · \(executable.relativeTargetPath)"
        default:
            return "Inspect \(workspaceLabel) workspace"
        }
    }

    private func readOnlyArgumentValue(_ key: String, in arguments: [String]) -> String? {
        for raw in arguments {
            let parts = raw.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2,
               parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key {
                let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }
            if raw.first == "{",
               let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = object[key] as? String,
               !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private func readOnlyRepairInstruction(
        for readiness: PlanReadinessResult,
        originalRequest: String,
        missionTarget: ReadOnlyMissionTarget
    ) -> String {
        let rejected = readiness.rejectedToolCalls.prefix(8).map { rejection in
            let id = rejection.toolCallID.isEmpty ? "unlinked-step" : rejection.toolCallID
            let fields = rejection.invalidFields.isEmpty ? "none" : rejection.invalidFields.joined(separator: ", ")
            let allowed = rejection.allowedArguments.isEmpty ? "see canonical tool schemas" : rejection.allowedArguments.joined(separator: ", ")
            let step = rejection.stepID.map { stepID in
                let kind = rejection.stepKind?.rawValue ?? "unknown"
                let actual = rejection.actualFields.isEmpty ? "not recorded" : rejection.actualFields.joined(separator: ", ")
                let expected = rejection.expectedFields.isEmpty ? "not recorded" : rejection.expectedFields.joined(separator: ", ")
                return "; invalid_step_id=\(stepID); step_kind=\(kind); actual_fields=\(actual); expected_fields=\(expected); original_step=\(rejection.originalStepJSON ?? "not recorded")"
            } ?? ""
            return "- rejected_tool_call_id=\(id); tool=\(rejection.command.isEmpty ? "unresolved" : rejection.command); reason=\(rejection.reason.rawValue); fields=\(fields); detail=\(rejection.detail); allowed_arguments=\(allowed)\(step)"
        }.joined(separator: "\n")
        let exampleSchema = readiness.rejectedToolCalls.first
            .flatMap { ReadOnlyToolSchemas.all[$0.command] }
            ?? ReadOnlyToolSchemas.all["engineering.inspect_project"]!
        let exampleArguments = exampleSchema.exampleArguments.map { "\"\($0)\"" }.joined(separator: ",")
        let correctedStepExample: String
        if let invalidStep = readiness.rejectedToolCalls.first(where: { $0.stepID != nil }),
           let stepID = invalidStep.stepID,
           let kind = invalidStep.stepKind,
           kind != .tool {
            correctedStepExample = "{\"id\":\"\(stepID)\",\"title\":\"Analyze recorded evidence\",\"intent\":\"Analyze only the results already returned by read-only tools.\",\"kind\":\"\(kind.rawValue)\",\"toolCallID\":null,\"requiresApproval\":false,\"retryBudget\":0}"
        } else {
            correctedStepExample = "{\"id\":\"step-1\",\"title\":\"Inspect workspace\",\"intent\":\"Inspect selected project structure.\",\"kind\":\"tool\",\"toolCallID\":\"example-call\",\"requiresApproval\":false,\"retryBudget\":0}"
        }
        return """
        Repair the read-only inspection plan for: \(originalRequest)
        It is not executable because: \(readiness.blockerReason?.rawValue ?? "no_executable_tool_step").
        Selected mission target: \(missionTarget.rawValue).
        Allowed workspace values: legacy, agent. Comparison calls must choose one explicitly.
        Rejections:
        \(rejected)
        workingDirectory is injected by the runtime. Do not guess or emit an absolute local path. Every path must be relative to the selected workspace.
        If the rejected first action was an ungrounded read_file, repair it to inspect_project, list_directory, or search first. Do not invent another filename or extension. For broad assessments, read a grounded root manifest before a grounded nested backend manifest, then requested database schema/config, then a manifest-derived or exactly discovered backend entry.
        Produce at least one `tool` plan step linked to an exact tool_call ID. Allowed tools are \(ReadOnlyInspectionPolicy.orderedAllowedTools.joined(separator: ", ")). Use API tool type and requiresApproval=false. Do not modify files or run commands. Non-tool steps must use an explicit non-tool kind and no toolCallID.
        Corrected invalid-step example: \(correctedStepExample)
        Valid example: {"plan":[{"id":"step-1","title":"Inspect workspace","intent":"Inspect selected project structure.","kind":"tool","toolCallID":"example-call","requiresApproval":false,"retryBudget":0}],"actions":[],"tool_calls":[{"id":"example-call","type":"api","command":"\(exampleSchema.command)","arguments":[\(exampleArguments)],"workingDirectory":null,"requiresApproval":false}],"risks":[],"confidence":0.9}
        """
    }

    private func safeReadOnlyModelOutput(_ output: StructuredAgentOutput) -> String {
        var sanitized = output
        sanitized.toolCalls = output.toolCalls.map { call in
            var safeCall = call
            safeCall.workingDirectory = nil
            safeCall.arguments = call.arguments.map { argument in
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2,
                   parts[1].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                    return "\(parts[0])=<absolute-path-redacted>"
                }
                if argument.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                    return "<absolute-path-redacted>"
                }
                return AgentPresentationSanitizer.safeContent(argument, fallback: "<invalid>")
            }
            return safeCall
        }
        return String(((try? JSONCoding.encode(sanitized)) ?? "{}").prefix(20_000))
    }

    private func readOnlyProviderBlocker(
        _ failure: ModelRoutingError,
        providerFailure: ModelProviderFailure? = nil,
        unavailableReason: PlanReadinessBlocker
    ) -> PlanReadinessBlocker {
        if let providerFailure {
            switch providerFailure.failurePhase {
            case "timeout":
                return .providerTimeout
            case "transport":
                return .providerTransportFailed
            case "http":
                return .providerHTTPFailed
            case "response_decode":
                return .providerResponseDecodeFailed
            case "response_schema_validation":
                return .providerResponseSchemaValidationFailed
            default:
                break
            }
        }
        switch failure {
        case .providerUnavailable:
            return unavailableReason
        case .providerRequestFailed:
            return .providerRequestFailed
        case .providerOutputInvalid:
            return .providerOutputInvalid
        }
    }

    private func isProvenEmptyWorkspace(_ output: String) -> Bool {
        output.contains("Directory is empty:")
            || (output.contains("Files: 0") && output.contains("Directories: 0"))
    }

    private func isGroundedFinalAnswer(
        _ answer: String,
        evidence: [ReadOnlyInspectionEvidence],
        request: String
    ) -> Bool {
        guard !answer.isEmpty, !evidence.isEmpty else { return false }
        let claimEvidence = evidence.map { item in
            AgentToolEvidenceContext(
                toolCallID: item.toolCallID,
                toolName: item.toolName,
                workspaceID: item.workspaceID,
                taskID: nil,
                workspaceIdentity: item.workspaceIdentity,
                targetPath: item.targetPath,
                toolCalledEventID: item.toolCalledEventID,
                toolResultEventID: item.toolResultEventID
            )
        }
        let claimRejection = AgentEvidenceClaimGuard().rejectionReason(
            for: answer,
            evidence: claimEvidence,
            workspaceID: evidence.first?.workspaceID
        )
        guard claimRejection == nil else {
            return false
        }
        let normalized = answer.lowercased()
        switch ReadOnlyMissionTarget(request: request) {
        case .legacy:
            let inventoriesAgent = ["agent workspace", "agent project", "agent 工作区", "agent 项目", "ai agent workspace"]
                .contains { normalized.contains($0) }
            guard !inventoriesAgent else { return false }
        case .agent:
            let inventoriesLegacy = ["legacy workspace", "legacy project", "legacy 工作区", "legacy 项目"]
                .contains { normalized.contains($0) }
            guard !inventoriesLegacy else { return false }
        case .comparison:
            break
        }
        let evidenceTerms = evidence.flatMap { item -> [String] in
            let pathTerms = item.targetPath == "." ? [] : [item.targetPath, URL(fileURLWithPath: item.targetPath).lastPathComponent]
            let outputTerms = item.output
                .split(whereSeparator: { $0.isWhitespace || $0 == ":" })
                .map(String.init)
                .filter { token in
                    token.contains("/") || [".swift", ".ts", ".tsx", ".js", ".py", ".java", ".kt"].contains { token.lowercased().hasSuffix($0) }
                }
                .prefix(30)
            return pathTerms + outputTerms
        }
        let citesEvidence = evidenceTerms.contains { term in
            !term.isEmpty && normalized.contains(term.lowercased())
        } || normalized.contains("workspace") || normalized.contains("工作区")
        guard citesEvidence else { return false }

        let performanceRequest = request.lowercased().contains("performance") || request.contains("性能")
        if performanceRequest {
            let labelsStaticFinding = ["static", "suspected", "possible", "risk", "静态", "疑似", "可能", "风险"]
                .contains { normalized.contains($0) }
            let statesLimit = ["not measured", "not profiled", "limitation", "cannot measure", "未测量", "未分析运行时", "限制", "无法测量"]
                .contains { normalized.contains($0) }
            return labelsStaticFinding && statesLimit
        }
        return true
    }

    private func hasSufficientEvidenceToFinalize(
        request: String,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> Bool {
        guard requestRequiresManifestEvidence(request) else { return !evidence.isEmpty }
        guard evidence.contains(where: {
            $0.toolName == "engineering.inspect_project" || $0.toolName == "engineering.list_directory"
        }) else {
            return false
        }
        let manifestReads = evidence.filter {
            $0.toolName == "engineering.read_file" && isRelevantManifestPath($0.targetPath)
        }
        guard !manifestReads.isEmpty else { return false }
        let combined = manifestReads.map(\.output).joined(separator: "\n").lowercased()
        let frameworkOrDependencyIndicators = [
            "dependencies", "devdependencies", "react", "vite", "express", "prisma", "provider",
            "package", "products", "targets", "requirements", "plugins", "framework"
        ]
        return frameworkOrDependencyIndicators.contains { combined.contains($0) }
    }

    private func requestRequiresManifestEvidence(_ request: String) -> Bool {
        let normalized = request.lowercased()
        return [
            "manifest", "dependency", "dependencies", "framework", "package", "important file", "key file",
            "依赖", "框架", "清单", "关键文件", "重要文件"
        ].contains { normalized.contains($0) }
    }

    private func isRelevantManifestPath(_ path: String) -> Bool {
        let normalized = path.lowercased()
        let name = URL(fileURLWithPath: normalized).lastPathComponent
        let exactNames: Set<String> = [
            "package.json", "package.swift", "pyproject.toml", "requirements.txt", "pom.xml",
            "build.gradle", "build.gradle.kts", "cargo.toml", "gemfile", "composer.json", "go.mod",
            "schema.prisma"
        ]
        return exactNames.contains(name)
            || normalized.hasSuffix(".csproj")
            || normalized.hasSuffix(".podspec")
    }

    private func hasRequiredProjectScope(
        workspace: Workspace,
        semantic: MissionExecutionSemantic,
        request: String
    ) -> Bool {
        guard semantic == .readOnlyWorkspaceInspection else {
            return workspace.hasIntegrationProjectScope
        }
        guard explicitMissionWorkspaceScope(in: request) != nil else {
            return workspace.hasIntegrationProjectScope
        }
        switch ReadOnlyMissionTarget(request: request) {
        case .legacy:
            return workspace.localProjectRootURL != nil
        case .agent:
            return workspace.localAgentProjectRootURL != nil
        case .comparison:
            return workspace.hasIntegrationProjectScope
        }
    }

    private func explicitMissionWorkspaceScope(in request: String) -> MissionWorkspaceScope? {
        let value = request.lowercased()
        let scopeLanguage = [
            "legacy", "agent", "旧项目", "传统项目", "智能体",
            "both workspaces", "both projects", "两个项目", "两者", "它们如何连接"
        ]
        guard scopeLanguage.contains(where: { value.contains($0) }) else { return nil }
        return MissionWorkspaceScope(request: request)
    }

    private func shouldSkipStep(for instruction: String, call: ToolCall) -> Bool {
        let normalized = instruction.lowercased()
        if normalized.contains("ignore this connector") || normalized.contains("ignore connector") {
            return call.type == .connector
        }
        return normalized.contains("skip this step")
            || normalized.contains("skip step")
            || normalized.contains("跳过")
    }

    private func isGloballyAvoidedTool(_ command: String, context: ExecutionContext) -> Bool {
        let avoided = Set(
            context.policyDeltas.compactMap(\.avoidToolCommand)
                + (context.globalExecutionPolicy?.avoidedToolCommands ?? [])
                + (context.contextBundle?.policySummary.avoidedTools ?? [])
        )
        return avoided.contains(command)
    }

    private func runtimeStatePayload(
        mission: MissionState,
        task: TaskState?,
        tool: ToolExecutionState = .idle
    ) -> [String: String] {
        RuntimeStateSnapshot(
            missionState: mission,
            taskState: task,
            toolState: tool
        ).auditPayload
    }

    private func workTracePayload(
        _ stage: AgentWorkTraceStage,
        summary: String,
        detail: String
    ) -> [String: String] {
        AgentWorkTrace(stage: stage, summary: summary, detail: detail).auditPayload
    }

    private func scopedToolCall(_ call: ToolCall, workspace: Workspace) throws -> ToolCall {
        let projectRoots = workspace.localProjectScopeRootURLs
        guard !projectRoots.isEmpty else {
            return call
        }
        let defaultProjectRoot = workspace.localProjectRootURL ?? projectRoots[0]

        var scopedCall = call
        let workingDirectory = resolvedWorkingDirectory(
            call.workingDirectory,
            projectRoot: defaultProjectRoot
        )

        guard projectRoots.contains(where: { Self.isInsideProject(workingDirectory, rootURL: $0) }) else {
            let allowedRoots = projectRoots.map(\.path).joined(separator: ", ")
            throw ToolExecutionError.workingDirectoryOutsideProject(workingDirectory.path, allowedRoots)
        }

        scopedCall.workingDirectory = workingDirectory.path
        return scopedCall
    }

    private func resolvedWorkingDirectory(_ workingDirectory: String?, projectRoot: URL) -> URL {
        guard let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
              !workingDirectory.isEmpty else {
            return projectRoot
        }

        if workingDirectory.hasPrefix("/") {
            return URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
        }

        return projectRoot.appendingPathComponent(workingDirectory, isDirectory: true).standardizedFileURL
    }

    private static func isInsideProject(_ url: URL, rootURL: URL) -> Bool {
        let rootPath = rootURL.standardizedFileURL.path
        let targetPath = url.standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        return targetPath == rootPath || targetPath.hasPrefix(rootPrefix)
    }

    @discardableResult
    private func recordAuthorizationDenied(
        _ decision: AuthorizationDecision,
        workspaceID: UUID,
        taskID: UUID?,
        extraPayload: [String: String]
    ) async throws -> ExecutionEvent {
        var payload = extraPayload
        payload["permission"] = decision.permission.rawValue
        payload["role"] = decision.role.rawValue
        payload["action"] = decision.action
        payload["resource"] = decision.resource ?? ""
        payload["reason"] = decision.reason
        payload = runtimeStatePayload(
            mission: .adapt,
            task: taskID == nil ? nil : .running,
            tool: taskID == nil ? .idle : .failed
        ).merging(payload) { _, next in next }
        return try await record(
            type: .authorizationDenied,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: decision.reason,
            payload: payload
        )
    }

    private func recordToolExecutionEvents(
        _ emittedEvents: [ToolExecutionEvent],
        workspaceID: UUID,
        taskID: UUID,
        stepID: String,
        toolCallID: String,
        command: String,
        attempt: Int
    ) async throws {
        for emittedEvent in emittedEvents {
            var payload = emittedEvent.payload
            payload["step_id"] = stepID
            payload["tool_call_id"] = toolCallID
            payload["command"] = command
            payload["attempt"] = String(attempt)
            try await record(
                type: emittedEvent.type,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: emittedEvent.summary,
                payload: payload
            )
        }
    }

    private func safeArguments(_ arguments: [String]) -> String {
        let joined = arguments.joined(separator: " ")
        let safe = AgentPresentationSanitizer.safeContent(joined, fallback: "")
        guard !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return ""
        }
        return safe
    }

    private func readOnlyPlannerArgumentSummary(_ output: StructuredAgentOutput) -> String {
        output.toolCalls.prefix(12).map { call in
            guard ReadOnlyInspectionPolicy.allowedTools.contains(call.command) else {
                return "\(call.id):[non-read-only arguments omitted]"
            }
            let arguments = call.arguments.prefix(12).map { argument -> String in
                let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, parts[1].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                    return "\(parts[0])=<absolute-path-redacted>"
                }
                if argument.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
                    return "<absolute-path-redacted>"
                }
                return AgentPresentationSanitizer.safeContent(argument, fallback: "<invalid>")
            }
            return "\(call.id):[\(arguments.joined(separator: ", "))]"
        }.joined(separator: " | ")
    }

    private func recordContextCompiled(
        _ context: ExecutionContext,
        workspace: Workspace,
        taskID: UUID,
        worldModel: SystemWorldModel
    ) async throws {
        guard let bundle = context.contextBundle else {
            try await record(
                type: .contextCompiled,
                workspaceID: workspace.id,
                taskID: taskID,
                summary: "Workspace context compiled",
                payload: [
                    "legacy_project_root": context.missionWorkspaceScope?.codebaseRoles.contains("legacy_software") == true ? (workspace.localProjectRoot ?? "") : "",
                    "agent_project_root": context.missionWorkspaceScope?.codebaseRoles.contains("ai_agent") == true ? (workspace.localAgentProjectRoot ?? "") : "",
                    "codebase_count": "0",
                    "codebase_roles": "",
                    "mission_workspace_scope": context.missionWorkspaceScope?.rawValue ?? "",
                    "context_bundle_bytes": "0"
                ].merging(runtimeStatePayload(mission: .understand, task: .created)) { current, _ in current }
                    .merging(worldModel.auditPayload) { current, _ in current }
                    .merging(workTracePayload(.understanding, summary: "System context compiled", detail: "Built initial world model from workspace metadata.")) { current, _ in current }
            )
            return
        }

        try await record(
            type: .contextCompiled,
            workspaceID: workspace.id,
            taskID: taskID,
            summary: "Workspace context compiled",
            payload: [
                "legacy_project_root": bundle.codebases.first(where: { $0.role == "legacy_software" })?.rootPath ?? "",
                "agent_project_root": bundle.codebases.first(where: { $0.role == "ai_agent" })?.rootPath ?? "",
                "codebase_count": String(bundle.codebases.count),
                "codebase_roles": bundle.codebases.map(\.role).joined(separator: " | "),
                "mission_workspace_scope": bundle.missionWorkspaceScope.rawValue,
                "context_bundle_bytes": String((try? JSONCoding.encode(bundle).utf8.count) ?? 0),
                "legacy_source_directories": codebaseValue(bundle.codebases, role: "legacy_software", keyPath: \.sourceDirectories),
                "agent_source_directories": codebaseValue(bundle.codebases, role: "ai_agent", keyPath: \.sourceDirectories),
                "legacy_package_indicators": codebaseValue(bundle.codebases, role: "legacy_software", keyPath: \.packageIndicators),
                "agent_package_indicators": codebaseValue(bundle.codebases, role: "ai_agent", keyPath: \.packageIndicators)
            ].merging(runtimeStatePayload(mission: .understand, task: .created)) { current, _ in current }
                .merging(worldModel.auditPayload) { current, _ in current }
                .merging(workTracePayload(.understanding, summary: "System context compiled", detail: "Built initial world model from workspace, policies, and prior failures.")) { current, _ in current }
        )
    }

    private func codebaseValue(
        _ codebases: [CodebaseContextSummary],
        role: String,
        keyPath: KeyPath<CodebaseContextSummary, [String]>
    ) -> String {
        guard let values = codebases.first(where: { $0.role == role })?[keyPath: keyPath] else {
            return ""
        }
        return values.prefix(8).joined(separator: " | ")
    }

    @discardableResult
    private func record(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String],
        eventID requestedEventID: UUID? = nil,
        initialTask: FDETask? = nil
    ) async throws -> ExecutionEvent {
        let parentEventID: UUID? = if let taskID {
            lastEventIDByTask[taskID]
        } else {
            lastEventIDByWorkspace[workspaceID]
        }
        let eventID = requestedEventID ?? UUID()
        let timestamp = Date()
        var enrichedPayload = payload
        enrichedPayload["event_id"] = eventID.uuidString
        enrichedPayload["parent_event_id"] = parentEventID?.uuidString ?? ""
        enrichedPayload["evidence_event_type"] = type.rawValue
        enrichedPayload["evidence_timestamp"] = ISO8601DateFormatter().string(from: timestamp)
        if enrichedPayload["tool_name"] == nil {
            enrichedPayload["tool_name"] = enrichedPayload["command"] ?? ""
        }
        if enrichedPayload["target_path"] == nil {
            enrichedPayload["target_path"] = enrichedPayload["working_directory"]
                ?? enrichedPayload["project_root"]
                ?? enrichedPayload["resource"]
                ?? ""
        }
        if enrichedPayload["success"] == nil {
            enrichedPayload["success"] = Self.successValue(for: type, payload: enrichedPayload)
        }
        if enrichedPayload["actual_result"] == nil {
            enrichedPayload["actual_result"] = Self.actualResult(for: type, summary: summary, payload: enrichedPayload)
        }
        if enrichedPayload["error"] == nil {
            enrichedPayload["error"] = Self.errorValue(for: type, payload: enrichedPayload)
        }
        let metadata = EventMetadata(
            workspaceID: workspaceID,
            correlationID: taskID?.uuidString ?? workspaceID.uuidString
        )

        let pendingEvent = ExecutionEvent(
            id: eventID,
            parentEventID: parentEventID,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: 0,
            timestamp: timestamp,
            summary: summary,
            payload: enrichedPayload,
            metadata: metadata
        )
        let event = try await persistence.appendEvent(
            pendingEvent,
            mode: .live,
            initialTask: initialTask
        )
        if let taskID {
            lastEventIDByTask[taskID] = event.id
        }
        lastEventIDByWorkspace[workspaceID] = event.id
        eventStream.persist(event)
        eventStream.publish(event)
        return event
    }

    private static func successValue(for type: EventType, payload: [String: String]) -> String {
        if let exitCode = payload["exit_code"] {
            return exitCode == "0" ? "true" : "false"
        }
        switch type {
        case .toolFailed,
             .connectorFailed,
             .authorizationDenied,
             .humanRejected,
             .userApprovalRejected,
             .nodeExecutionFailed,
             .workerTaskFailed:
            return "false"
        case .taskCompleted,
             .stepExecuted,
             .connectorExecuted,
             .humanApproved,
             .userApprovalGranted,
             .contextCompiled,
             .planGenerated:
            return "true"
        default:
            return ""
        }
    }

    private static func actualResult(for type: EventType, summary: String, payload: [String: String]) -> String {
        if let stdout = payload["stdout"], !stdout.isEmpty {
            return String(stdout.prefix(500))
        }
        if let stderr = payload["stderr"], !stderr.isEmpty {
            return String(stderr.prefix(500))
        }
        if let state = payload["state"], !state.isEmpty {
            return "\(type.rawValue) state=\(state): \(summary)"
        }
        return summary
    }

    private static func errorValue(for type: EventType, payload: [String: String]) -> String {
        if let error = payload["error"], !error.isEmpty {
            return error
        }
        switch type {
        case .toolFailed,
             .connectorFailed,
             .authorizationDenied,
             .humanRejected,
             .userApprovalRejected,
             .nodeExecutionFailed,
             .workerTaskFailed:
            return payload["stderr"] ?? payload["reason"] ?? "operation_failed"
        default:
            return ""
        }
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
