import AppKit
import Combine
import Foundation

private enum ProjectScopeKind {
    case legacy
    case agent

    var panelTitle: String {
        switch self {
        case .legacy: return "Choose Legacy Project"
        case .agent: return "Choose Agent Project"
        }
    }

    var auditLabel: String {
        switch self {
        case .legacy: return "legacy_project_root"
        case .agent: return "ai_agent_project_root"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var workspaces: [Workspace] = []
    @Published var selectedWorkspaceID: UUID?
    @Published var agentSessions: [AgentSession] = [] {
        didSet { persistWorkspaceUIStateIfNeeded() }
    }
    @Published var selectedAgentSessionID: UUID? {
        didSet {
            guard !isRestoringWorkspaceUIState else { return }
            if let oldValue {
                composerDrafts[oldValue] = commandText
            }
            isSwitchingComposerDraft = true
            commandText = selectedAgentSessionID.flatMap { composerDrafts[$0] } ?? ""
            isSwitchingComposerDraft = false
            composerFocusRequestID = UUID()
            persistWorkspaceUIStateIfNeeded()
        }
    }
    @Published var tasks: [FDETask] = []
    @Published var selectedTaskID: UUID?
    @Published var events: [ExecutionEvent] = []
    @Published var graphNodes: [SystemGraphNode] = []
    @Published var graphEdges: [SystemGraphEdge] = []
    @Published var replayFrames: [ReplayFrame] = []
    @Published var missionReplay: MissionReplay?
    @Published var feedback: [FeedbackInsight] = []
    @Published var latestOutcome: OutcomeMetrics?
    @Published var policyDeltas: [ExecutionPolicyDelta] = []
    @Published var latestGlobalExecutionPolicy: GlobalExecutionPolicy?
    @Published var governorDecisions: [GlobalGovernorDecision] = []
    @Published var pendingApprovals: [ApprovalRequest] = []
    @Published var candidatePatchApprovalConfirmation: CandidatePatchApprovalConfirmation?
    @Published var isConfirmingCandidatePatchApproval = false
    @Published var candidatePatchRevertConfirmation: CandidatePatchRevertConfirmation?
    @Published var isConfirmingCandidatePatchRevert = false
    @Published var candidatePatchDestructionConfirmation: CandidatePatchSandboxDestructionConfirmation?
    @Published var isConfirmingCandidatePatchDestruction = false
    @Published var missionUndoConfirmation: MissionUndoConfirmation?
    @Published var isConfirmingMissionUndo = false
    @Published var agentBenchmarkSummary = AgentBenchmarkSummary.empty
    @Published var agentCapabilityReport = AgentCapabilityReport.empty
    @Published var engineeringActivity = EngineeringActivitySnapshot.empty
    @Published var agentTeamSnapshot = AgentTeamSnapshot.empty
    @Published var teamIntelligence = TeamIntelligenceSnapshot.empty
    @Published var replayValidationStatus = "No task selected"
    @Published var eventChainValidationStatus = "No events loaded"
    @Published var persistenceStatus = "Persistence not initialized"
    @Published var contextCompilerDiagnostics = ContextCompilerDiagnostics.empty
    @Published var modelProviderDiagnostics = ModelProviderDiagnostics(
        activeProvider: "Local",
        fallbackReason: "No routing attempt yet",
        lastValidationResult: "not run",
        lastLatencyMilliseconds: nil,
        liveProviderStates: [],
        updatedAt: Date()
    )
    @Published var connectorStatuses: [ConnectorStatus] = []
    @Published var session: SessionCredential?
    @Published var commandText = "" {
        didSet {
            guard !isRestoringWorkspaceUIState, !isSwitchingComposerDraft else { return }
            if let selectedAgentSessionID {
                composerDrafts[selectedAgentSessionID] = commandText
            }
            persistWorkspaceUIStateIfNeeded()
        }
    }
    @Published var isInspectorPresented = false {
        didSet { persistWorkspaceUIStateIfNeeded() }
    }
    @Published private(set) var composerFocusRequestID = UUID()
    @Published var isRunning = false
    @Published var lastError: String?
    @Published private var conversationActivities: [UUID: AgentConversationActivity] = [:]
    @Published private(set) var conversationAssetProjection = AgentConversationAssetProjection.empty
    @Published private var generatedTestPlanGenerationsInFlight: Set<String> = []
    @Published private var generatedTestArtifactReviewSessionsInFlight: Set<UUID> = []
    @Published private var candidatePatchReviewActionsInFlight: Set<UUID> = []
    @Published private(set) var missionCleanupStates: [MissionCleanupState] = []
    @Published private(set) var productionReadinessReports: [ProductionReadinessReport] = []
    @Published private(set) var aiEvalPlans: [AIEvalPlan] = []
    @Published private(set) var productionReadinessRestoreFailure: String?
    @Published private(set) var controlledEvalRuns: [EvalRun] = []
    @Published private(set) var controlledEvalRestoreFailure: String?
    @Published private(set) var controlledEvalExecutionAuthorizations: [ControlledEvalExecutionAuthorization] = []
    @Published private(set) var controlledEvalResultReviewAuthorizations: [ControlledEvalResultReviewAuthorization] = []
    @Published private(set) var activeWorkspaceSessionID: UUID?
    @Published private var controlledEvalRunsInFlight: Set<UUID> = []
    @Published private var controlledEvalAuthorizationsInFlight: Set<UUID> = []
    @Published private var controlledEvalResultReviewAuthorizationsInFlight: Set<UUID> = []

    private let environment: AppEnvironment
    private let startupIssue: String?
    private let interactionController = AgentInteractionController()
    private let runtimeCoordinator: AgentRuntimeCoordinator
    private let missionClassifier = AgentMissionClassifier()
    private var cancellables = Set<AnyCancellable>()
    private var hasLoaded = false
    private var pendingSubmissionFingerprints: [UUID: Set<UInt64>] = [:]
    private let appSessionID = UUID()
    private let workspaceUIStateStore = AgentWorkspaceUIStateStore()
    private var composerDrafts: [UUID: String] = [:]
    private var isRestoringWorkspaceUIState = false
    private var isSwitchingComposerDraft = false

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return workspaces.first }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedAgentSession: AgentSession? {
        guard let selectedAgentSessionID else { return nil }
        return agentSessions.first { session in
            session.sessionID == selectedAgentSessionID
                && session.workspaceID == selectedWorkspace?.id
        }
    }

    /// Center-workspace authority starts with the selected conversation. A
    /// chat-only session has no Mission scope and therefore cannot project a
    /// task, approval, artifact, or mutation from another conversation.
    var selectedConversationScope: AgentSessionMissionScope? {
        selectedAgentSession.map(AgentSessionMissionScope.init)
    }

    var selectedWorkspaceAgentSessions: [AgentSession] {
        guard let workspaceID = selectedWorkspace?.id else { return [] }
        return agentSessions.filter { $0.workspaceID == workspaceID }
    }

    var selectedConversationStatus: AgentInteractionState? {
        guard let selectedAgentSessionID else { return nil }
        return conversationStatus(for: selectedAgentSessionID)
    }

    func conversationStatus(for sessionID: UUID) -> AgentInteractionState? {
        agentSessions.first { session in
            session.sessionID == sessionID
                && session.workspaceID == selectedWorkspace?.id
        }?.interactionState
    }

    var selectedTask: FDETask? {
        guard selectedAgentSession?.hasCurrentMissionAuthority == true,
              let runtimeTaskID = selectedAgentSession?.runtimeTaskID else { return nil }
        return tasks.first { $0.id == runtimeTaskID }
    }

    var controlledEvalSessionAuthority: ControlledEvalSessionAuthority? {
        guard let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id,
              let workspaceSessionID = activeWorkspaceSessionID else {
            return nil
        }
        return ControlledEvalSessionAuthority(
            workspaceID: workspace.id,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            workspaceSessionID: workspaceSessionID,
            appSessionID: appSessionID
        )
    }

    var selectedTaskPendingApprovals: [ApprovalRequest] {
        guard selectedAgentSession?.hasCurrentMissionAuthority == true,
              let scope = selectedConversationScope,
              scope.hasLinkedMission,
              let interactionState = selectedAgentSession?.interactionState else {
            return []
        }
        return pendingApprovals.filter { approval in
            guard scope.containsMissionTask(approval.taskID) else { return false }
            let task = approval.taskID.flatMap { taskID in
                tasks.first(where: { $0.id == taskID })
            }
            return AgentSessionAuthorityEvaluator.approvalIsEligibleForSubmission(
                approval,
                task: task,
                interactionState: interactionState
            )
        }
    }

    func isApprovalBoundToSelectedConversation(_ approval: ApprovalRequest) -> Bool {
        AgentSessionAuthorityEvaluator.approvalIsBound(
            approval,
            scope: selectedConversationScope,
            visiblePendingApprovalIDs: Set(selectedTaskPendingApprovals.map(\.id))
        )
    }

    func isMissionSummaryBoundToSelectedConversation(_ summary: MissionSummary) -> Bool {
        AgentSessionAuthorityEvaluator.missionIsBound(
            summary,
            current: selectedMissionPresentation?.current,
            scope: selectedConversationScope
        )
    }

    func isCandidatePatchBoundToSelectedConversation(
        _ snapshot: CandidatePatchActivitySnapshot
    ) -> Bool {
        guard let missionID = snapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)),
              selectedConversationScope?.containsMissionTask(missionID) == true else {
            return false
        }
        return selectedConversationAssetProjection.candidatePatches.contains {
            $0.assetID == snapshot.assetID
        }
    }

    func isGeneratedTestPlanBoundToSelectedConversation(
        _ snapshot: GeneratedTestActivitySnapshot
    ) -> Bool {
        guard let missionID = snapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)),
              selectedConversationScope?.containsMissionTask(missionID) == true else {
            return false
        }
        return selectedConversationAssetProjection.generatedTestPlans.contains {
            $0.assetID == snapshot.assetID
        }
    }

    func isGeneratedTestArtifactBoundToSelectedConversation(
        _ artifact: GeneratedTestArtifact
    ) -> Bool {
        let missionID = artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID
        guard selectedConversationScope?.containsMissionTask(missionID) == true else { return false }
        return selectedConversationAssetProjection.generatedTestArtifacts.contains {
            $0.artifactID == artifact.artifactID
        }
    }

    var selectedAgentSessionEvents: [ExecutionEvent] {
        AgentSessionEventScope.events(from: events, for: selectedAgentSession)
    }

    var selectedConversationActivity: AgentConversationActivity? {
        guard let session = selectedAgentSession else { return nil }
        return AgentConversationActivityReducer.activity(
            session: session,
            events: selectedAgentSessionEvents,
            localActivity: conversationActivities[session.sessionID]
        )
    }

    var selectedMissionPresentation: MissionPresentationState? {
        guard let session = selectedAgentSession,
              !session.isEmptyConversation,
              session.hasCurrentMissionAuthority,
              selectedConversationScope?.hasLinkedMission == true else {
            return nil
        }
        return MissionPresentationProjector.project(
            session: session,
            activity: selectedConversationActivity,
            candidatePatches: selectedConversationAssetProjection.candidatePatches,
            generatedTestPlans: selectedConversationAssetProjection.generatedTestPlans,
            generatedTestArtifacts: selectedConversationAssetProjection.generatedTestArtifacts,
            approvals: selectedTaskPendingApprovals,
            cleanupStates: missionCleanupStates,
            productionReadinessReports: productionReadinessReports,
            aiEvalPlans: aiEvalPlans,
            phase3ARestorationFailure: productionReadinessRestoreFailure,
            evalRuns: controlledEvalRuns,
            controlledEvalRestorationFailure: controlledEvalRestoreFailure,
            controlledEvalSessionAuthority: controlledEvalSessionAuthority,
            controlledEvalExecutionAuthorizations: controlledEvalExecutionAuthorizations,
            controlledEvalResultReviewAuthorizations: controlledEvalResultReviewAuthorizations
        )
    }

    var selectedConversationAssetProjection: AgentConversationAssetProjection {
        guard selectedAgentSession?.hasCurrentMissionAuthority == true,
              let scope = selectedConversationScope,
              scope.hasLinkedMission,
              let session = selectedAgentSession,
              let missionRunID = MissionPresentationProjector.selectedMissionRunID(
                  for: session,
                  candidatePatches: conversationAssetProjection.candidatePatches,
                  generatedTestPlans: conversationAssetProjection.generatedTestPlans,
                  generatedTestArtifacts: conversationAssetProjection.generatedTestArtifacts
              ) else {
            return .empty
        }
        return AgentConversationAssetProjection(
            candidatePatches: conversationAssetProjection.candidatePatches.filter {
                $0.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == missionRunID
            },
            generatedTestPlans: conversationAssetProjection.generatedTestPlans.filter { plan in
                plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == missionRunID
                    && scope.containsMissionTask(plan.planningTaskID.flatMap(UUID.init(uuidString:)))
            },
            generatedTestArtifacts: conversationAssetProjection.generatedTestArtifacts.filter { artifact in
                let binding = artifact.sourceBinding.generatedTestSourceBinding
                return binding.sourceCandidatePatchTaskID == missionRunID
                    && scope.containsMissionTask(binding.generatedTestPlanningTaskID)
            }
        )
    }

    var selectedArtifactFileCards: [ArtifactFileCardModel] {
        guard let summary = selectedMissionPresentation?.current else { return [] }
        let manifest: CandidatePatchManifest?
        if let patchID = summary.candidatePatch?.patchID.flatMap(CandidatePatchID.init(rawValue:)),
           let sandboxID = summary.candidatePatch?.sandboxID.flatMap(SandboxID.init(rawValue:)) {
            manifest = try? CandidatePatchManifestStore(
                lifecycle: environment.sandboxLifecycle
            ).load(sandboxID: sandboxID, patchID: patchID)
        } else {
            manifest = nil
        }
        return ArtifactFileCardProjector.cards(
            candidateManifest: manifest,
            generatedTestArtifact: summary.generatedTestArtifact
        )
    }

    var liveExecutionSnapshot: LiveExecutionSnapshot {
        LiveExecutionMapper.snapshot(
            task: selectedTask,
            events: selectedAgentSessionEvents,
            feedback: feedback,
            policyDeltas: policyDeltas,
            graphNodes: graphNodes,
            contextDiagnostics: contextCompilerDiagnostics
        )
    }

    var agentNarrationFeed: AgentNarrationFeed {
        AgentNarrationEngine.feed(task: selectedTask, events: selectedAgentSessionEvents)
    }

    var agentWorkspaceEvents: [AgentWorkspaceEvent] {
        AgentWorkspaceProjection.events(
            session: selectedAgentSession,
            task: selectedTask,
            events: selectedAgentSessionEvents,
            approvals: selectedTaskPendingApprovals
        )
    }

    var agentTimeline: AgentTimeline {
        guard let session = selectedAgentSession else {
            return .empty
        }
        return AgentTimeline.build(
            missionID: session.runtimeTaskID ?? session.sessionID,
            missionTitle: selectedTask?.title ?? session.userGoal,
            events: agentWorkspaceEvents
        )
    }

    var missionReplayTimeline: MissionReplayTimeline {
        MissionReplayTimelineEngine().reconstruct(
            task: selectedTask,
            replay: missionReplay,
            events: selectedAgentSessionEvents,
            approvals: selectedTaskPendingApprovals,
            outcome: selectedOutcomeRecord,
            teamIntelligence: teamIntelligence
        )
    }

    var selectedOutcomeRecord: OutcomeRecord? {
        guard let session = selectedAgentSession,
              let finalState = OutcomeTrackingLayer.inferredFinalState(
                  task: selectedTask,
                  events: selectedAgentSessionEvents
              ),
              finalState == .complete || selectedTask?.state == .failed else {
            return nil
        }

        return OutcomeTrackingLayer().record(
            missionID: selectedTask?.id ?? session.runtimeTaskID ?? session.sessionID,
            objective: session.userGoal,
            finalState: finalState,
            events: selectedAgentSessionEvents,
            task: selectedTask
        )
    }

    var latestGovernorDecision: GlobalGovernorDecision? {
        guard let taskID = selectedAgentSession?.runtimeTaskID else { return nil }
        return governorDecisions.first { $0.taskID == taskID }
    }

    var latestPolicyDelta: ExecutionPolicyDelta? {
        guard let taskID = selectedAgentSession?.runtimeTaskID else { return nil }
        return policyDeltas.first { $0.sourceTaskID == taskID }
    }

    var canViewDiagnostics: Bool {
        guard let workspace = selectedWorkspace else { return false }
        return environment.authorizationService.hasPermission(.viewDiagnostics, in: workspace)
    }

    var canManageConnectors: Bool {
        guard let workspace = selectedWorkspace else { return false }
        return environment.authorizationService.hasPermission(.manageConnectors, in: workspace)
    }

    var selectedWorkspaceHasProjectScope: Bool {
        selectedWorkspace?.hasIntegrationProjectScope == true
    }

    var selectedWorkspaceProjectRoot: String? {
        selectedWorkspace?.localProjectRoot
    }

    var selectedWorkspaceAgentProjectRoot: String? {
        selectedWorkspace?.localAgentProjectRoot
    }

    var canSubmitCommand: Bool {
        !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(environment: AppEnvironment, startupIssue: String?) {
        self.environment = environment
        self.startupIssue = startupIssue
        self.runtimeCoordinator = AgentRuntimeCoordinator(chatProvider: environment.agentChatProvider)
        self.lastError = startupIssue
        self.persistenceStatus = Self.initialPersistenceStatus(for: environment.persistence, startupIssue: startupIssue)

        environment.eventStream.subscribe(EventStreamFilter())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.receive(event)
            }
            .store(in: &cancellables)
    }

    static func makeLive() -> AppStore {
        let (environment, startupIssue) = AppEnvironment.live()
        return AppStore(environment: environment, startupIssue: startupIssue)
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true

        do {
            try await environment.persistence.initialize()
            persistenceStatus = Self.readyPersistenceStatus(for: environment.persistence, startupIssue: startupIssue)
            var storedWorkspaces = try await environment.persistence.loadWorkspaces()
            if storedWorkspaces.isEmpty {
                let workspace = Workspace.default()
                try await environment.persistence.saveWorkspace(workspace)
                storedWorkspaces = [workspace]
            }

            workspaces = storedWorkspaces
            let storedSession = try await environment.persistence.loadSessionMetadata()
            activeWorkspaceSessionID = storedSession?.workspaceSession?.state == .signedIn
                ? storedSession?.workspaceSession?.id
                : nil
            if let storedSession,
               let workspaceID = storedSession.workspaceSession?.workspaceID,
               storedWorkspaces.contains(where: { $0.id == workspaceID }) {
                selectedWorkspaceID = selectedWorkspaceID ?? workspaceID
            } else {
                selectedWorkspaceID = selectedWorkspaceID ?? storedWorkspaces.first?.id
            }
            restoreWorkspaceUIState(
                validWorkspaceIDs: Set(storedWorkspaces.map(\.id)),
                activeWorkspaceID: selectedWorkspaceID
            )
            session = try await environment.sessionRepository.loadCredential()
            connectorStatuses = await environment.connectors.statuses()
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard let workspace = selectedWorkspace else { return }

        do {
            tasks = try await environment.persistence.loadTasks(workspaceID: workspace.id)
            selectedTaskID = selectedAgentSession?.runtimeTaskID
            await refreshSelectedTaskDetails()
            let graph = try await environment.persistence.loadGraph(workspaceID: workspace.id)
            graphNodes = graph.0
            graphEdges = graph.1
            latestOutcome = try await environment.persistence.loadLatestOutcome(workspaceID: workspace.id)
            feedback = try await environment.persistence.loadFeedback(workspaceID: workspace.id)
            policyDeltas = try await environment.persistence.loadPolicyDeltas(workspaceID: workspace.id)
            latestGlobalExecutionPolicy = try await environment.persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)
            governorDecisions = try await environment.persistence.loadGlobalGovernorDecisions(workspaceID: workspace.id)
            let workspaceEvents = try await environment.persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
            let candidatePatchManifests = (try? CandidatePatchManifestStore(
                lifecycle: environment.sandboxLifecycle
            ).loadAll()) ?? []
            let generatedTestArtifacts = (try? GeneratedTestArtifactStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            ).loadAll(workspaceID: workspace.id)) ?? []
            missionCleanupStates = (try? MissionCleanupStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            ).loadAll(workspaceID: workspace.id)) ?? []
            let readinessStore = ProductionReadinessArtifactStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            )
            do {
                let restored = try readinessStore.loadAllPairs(workspaceID: workspace.id)
                productionReadinessReports = restored.reports
                aiEvalPlans = restored.evalPlans
                productionReadinessRestoreFailure = nil
            } catch {
                productionReadinessReports = []
                aiEvalPlans = []
                productionReadinessRestoreFailure = "Phase 3A persistence validation failed: \(error.localizedDescription)"
                lastError = productionReadinessRestoreFailure
            }
            let evalStore = ControlledEvalRunStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            )
            do {
                let restored = try evalStore.restoreAll(workspaceID: workspace.id)
                controlledEvalRuns = restored.runs
                controlledEvalRestoreFailure = nil
                if !restored.restorationFailures.isEmpty {
                    lastError = "An interrupted controlled Eval Run was restored and stopped fail-closed."
                }
            } catch {
                controlledEvalRuns = []
                controlledEvalRestoreFailure = "Phase 3A.1 persistence validation failed: \(error.localizedDescription)"
                lastError = controlledEvalRestoreFailure
            }
            let metadata = try await environment.persistence.loadSessionMetadata()
            activeWorkspaceSessionID = metadata?.workspaceSession?.state == .signedIn
                && metadata?.workspaceSession?.workspaceID == workspace.id
                ? metadata?.workspaceSession?.id
                : nil
            conversationAssetProjection = AgentConversationAssetProjector.project(
                workspaceID: workspace.id,
                events: workspaceEvents,
                candidatePatchManifests: candidatePatchManifests,
                generatedTestArtifacts: generatedTestArtifacts
            )
            restoreCandidatePatchConversationIfNeeded(
                workspace: workspace,
                workspaceEvents: workspaceEvents
            )
            let allApprovals = try await environment.persistence.loadApprovalRequests(workspaceID: workspace.id, state: nil)
            let executionMemory = try await environment.persistence.loadTaskExecutionMemory(workspaceID: workspace.id)
            pendingApprovals = allApprovals.filter { $0.state == .pending }
            agentBenchmarkSummary = AgentQualityEvaluator().benchmark(
                tasks: tasks,
                events: workspaceEvents,
                approvals: allApprovals,
                memories: executionMemory
            )
            agentCapabilityReport = AgentBenchmarkRunner().report(
                task: selectedTask,
                replay: missionReplay,
                outcome: selectedOutcomeRecord,
                events: workspaceEvents,
                approvals: allApprovals
            )
            engineeringActivity = await Self.loadEngineeringActivity(
                rootPath: workspace.localAgentProjectRoot ?? workspace.localProjectRoot
            )
            agentTeamSnapshot = Self.buildAgentTeamSnapshot(
                workspace: workspace,
                task: selectedTask,
                session: selectedAgentSession,
                events: workspaceEvents,
                executionMemory: executionMemory,
                outcome: selectedOutcomeRecord
            )
            teamIntelligence = Self.buildTeamIntelligenceSnapshot(
                workspace: workspace,
                task: selectedTask,
                session: selectedAgentSession,
                events: workspaceEvents,
                executionMemory: executionMemory,
                outcome: selectedOutcomeRecord
            )
            modelProviderDiagnostics = await environment.modelDiagnostics.snapshot()
            contextCompilerDiagnostics = await environment.contextDiagnostics.snapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func selectWorkspace(_ workspaceID: UUID?) {
        cancelMissionUndoConfirmation()
        cancelCandidatePatchApprovalConfirmation()
        cancelCandidatePatchRevertConfirmation()
        cancelCandidatePatchDestructionConfirmation()
        let previousWorkspaceID = selectedWorkspaceID
        selectedWorkspaceID = workspaceID
        selectedAgentSessionID = agentSessions.first { $0.workspaceID == workspaceID }?.sessionID
        selectedTaskID = nil
        let workspace = selectedWorkspace
        if let workspace {
            refreshAgentSessionWorkspaceContexts(for: workspace)
        }
        Task {
            if let workspace {
                do {
                    session = try await environment.sessionRepository.switchWorkspace(to: workspace)
                    try await environment.runtime.recordAuditEvent(
                        type: .workspaceSwitched,
                        workspaceID: workspace.id,
                        summary: "Active workspace switched",
                        payload: [
                            "previous_workspace_id": previousWorkspaceID?.uuidString ?? "",
                            "workspace_id": workspace.id.uuidString,
                            "org_id": workspace.orgID.uuidString,
                            "role": workspace.role.rawValue,
                            "local_data_namespace": workspace.localDataNamespace,
                            "policy_namespace": workspace.policyNamespace,
                            "memory_namespace": workspace.memoryNamespace,
                            "event_namespace": workspace.eventNamespace,
                            "local_project_root": workspace.localProjectRoot ?? "",
                            "local_agent_project_root": workspace.localAgentProjectRoot ?? ""
                        ]
                    )
                } catch {
                    lastError = error.localizedDescription
                }
            }
            await refresh()
        }
    }

    func selectTask(_ taskID: UUID?) {
        cancelMissionUndoConfirmation()
        cancelCandidatePatchApprovalConfirmation()
        cancelCandidatePatchRevertConfirmation()
        cancelCandidatePatchDestructionConfirmation()
        guard let taskID,
              let session = agentSessions.first(where: {
                  $0.runtimeTaskID == taskID && $0.workspaceID == selectedWorkspace?.id
              }) else {
            selectedTaskID = nil
            Task { await refreshSelectedTaskDetails() }
            return
        }
        selectedAgentSessionID = session.sessionID
        selectedTaskID = taskID
        Task { await refreshSelectedTaskDetails() }
    }

    func selectAgentSession(_ sessionID: UUID?) {
        cancelMissionUndoConfirmation()
        cancelCandidatePatchApprovalConfirmation()
        cancelCandidatePatchRevertConfirmation()
        cancelCandidatePatchDestructionConfirmation()
        selectedAgentSessionID = sessionID
        selectedTaskID = agentSessions.first { $0.sessionID == sessionID }?.runtimeTaskID
        Task { await refreshSelectedTaskDetails() }
    }

    func createNewChat() {
        guard let workspace = selectedWorkspace else { return }
        cancelMissionUndoConfirmation()
        cancelCandidatePatchApprovalConfirmation()
        cancelCandidatePatchRevertConfirmation()
        cancelCandidatePatchDestructionConfirmation()

        if let reusable = AgentConversationSessionRetention.reusableEmptyDraft(
            in: agentSessions,
            workspaceID: workspace.id,
            selectedSessionID: selectedAgentSessionID,
            drafts: composerDrafts
        ) {
            agentSessions.removeAll {
                $0.workspaceID == workspace.id
                    && $0.sessionID != reusable.sessionID
                    && AgentConversationSessionRetention.isSafelyDisposableEmptySession(
                        $0,
                        draftText: composerDrafts[$0.sessionID] ?? ""
                    )
            }
            composerDrafts = composerDrafts.filter { id, _ in
                agentSessions.contains(where: { $0.sessionID == id })
            }
            selectedAgentSessionID = reusable.sessionID
        } else {
            let newSession = AgentSession.newConversation(in: workspace)
            agentSessions.insert(newSession, at: 0)
            selectedAgentSessionID = newSession.sessionID
        }
        selectedTaskID = nil
        lastError = nil
        composerFocusRequestID = UUID()
        persistWorkspaceUIStateIfNeeded()
    }

    func requestComposerFocus() {
        guard selectedWorkspaceHasProjectScope else { return }
        composerFocusRequestID = UUID()
    }

    func submitCommand() {
        guard let workspace = selectedWorkspace else { return }
        let input = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        let preflightContext = selectedRuntimePreflightContext
        let requiresClarification = ConversationRuntimePreflight.evaluate(
            input,
            context: preflightContext
        ) != nil
        guard requiresClarification || hasRequiredProjectScope(for: input, workspace: workspace) else {
            lastError = missingProjectScopeMessage(for: input)
            return
        }

        if let selectedAgentSessionID, shouldRouteToSelectedSession(input) {
            let fingerprint = submissionFingerprint(input)
            guard !isPendingSubmission(fingerprint, sessionID: selectedAgentSessionID) else {
                commandText = ""
                return
            }
            guard let index = agentSessions.firstIndex(where: { $0.sessionID == selectedAgentSessionID }) else {
                return
            }
            if agentSessions[index].isEmptyConversation {
                let requestID = UUID()
                agentSessions[index].beginConversation(
                    with: input,
                    messageID: requestID,
                    turnID: requestID
                )
                let scope = activityScope(for: input, session: agentSessions[index])
                commandText = ""
                lastError = nil
                beginSubmission(
                    requestID: requestID,
                    session: agentSessions[index],
                    input: input,
                    scope: scope,
                    inputFingerprint: fingerprint,
                    reactivatesCurrentTask: false
                )
                composerFocusRequestID = UUID()
                let originatingSession = agentSessions[index]
                Task {
                    defer {
                        endSubmission(fingerprint, sessionID: selectedAgentSessionID)
                        composerFocusRequestID = UUID()
                    }
                    do {
                        var session = originatingSession
                        let result = try await runtimeCoordinator.startMission(
                            input: input,
                            workspace: workspace,
                            session: &session,
                            runtime: environment.runtime,
                            userMessageID: requestID,
                            preflightContext: preflightContext
                        )
                        guard AgentSessionAsyncBinding.commit(
                            originatingSession: originatingSession,
                            updatedSession: session,
                            into: &agentSessions
                        ) else { return }
                        if let task = result.task {
                            linkRuntimeTask(task, to: selectedAgentSessionID)
                            if self.selectedAgentSessionID == selectedAgentSessionID {
                                self.selectedTaskID = task.id
                            }
                        }
                        finishActivity(for: selectedAgentSessionID, requestID: requestID, result: result)
                        await refresh()
                    } catch {
                        failAgentSession(selectedAgentSessionID, with: error)
                        failActivity(
                            for: selectedAgentSessionID,
                            requestID: requestID,
                            scope: scope,
                            error: error
                        )
                        lastError = error.localizedDescription
                    }
                }
                return
            }
            let requestID = UUID()
            let scope = activityScope(for: input, session: agentSessions[index])
            agentSessions[index].appendUserMessage(
                input,
                messageID: requestID,
                turnID: requestID
            )
            commandText = ""
            lastError = nil
            beginSubmission(
                requestID: requestID,
                session: agentSessions[index],
                input: input,
                scope: scope,
                inputFingerprint: fingerprint,
                reactivatesCurrentTask: reactivatesCurrentTask(input, session: agentSessions[index])
            )
            handleUserReply(
                input,
                in: selectedAgentSessionID,
                continuation: isContinuationCommand(input),
                requestID: requestID,
                inputFingerprint: fingerprint
            )
            composerFocusRequestID = UUID()
            return
        }

        let requestID = UUID()
        let agentSessionID = createAgentSession(
            goal: input,
            workspace: workspace,
            requestID: requestID
        )
        let fingerprint = submissionFingerprint(input)
        let scope = agentSessions.first(where: { $0.sessionID == agentSessionID })
            .map { activityScope(for: input, session: $0) }
            ?? .normalChat
        commandText = ""
        lastError = nil
        if let session = agentSessions.first(where: { $0.sessionID == agentSessionID }) {
            beginSubmission(
                requestID: requestID,
                session: session,
                input: input,
                scope: scope,
                inputFingerprint: fingerprint,
                reactivatesCurrentTask: false
            )
        }
        composerFocusRequestID = UUID()
        guard let originatingSession = agentSessions.first(where: {
            $0.sessionID == agentSessionID
        }) else { return }

        Task {
            defer { endSubmission(fingerprint, sessionID: agentSessionID) }
            do {
                var session = originatingSession
                let result = try await runtimeCoordinator.startMission(
                    input: input,
                    workspace: workspace,
                    session: &session,
                    runtime: environment.runtime,
                    userMessageID: requestID,
                    preflightContext: preflightContext
                )
                guard AgentSessionAsyncBinding.commit(
                    originatingSession: originatingSession,
                    updatedSession: session,
                    into: &agentSessions
                ) else { return }
                if let task = result.task {
                    linkRuntimeTask(task, to: agentSessionID)
                    if self.selectedAgentSessionID == agentSessionID {
                        self.selectedTaskID = task.id
                    }
                }
                finishActivity(for: agentSessionID, requestID: requestID, result: result)
                await refresh()
            } catch {
                failAgentSession(agentSessionID, with: error)
                failActivity(for: agentSessionID, requestID: requestID, scope: scope, error: error)
                lastError = error.localizedDescription
            }
        }
    }

    func chooseProjectDirectory() {
        chooseProjectDirectory(for: .legacy)
    }

    func chooseAgentProjectDirectory() {
        chooseProjectDirectory(for: .agent)
    }

    private func chooseProjectDirectory(for scope: ProjectScopeKind) {
        let panel = NSOpenPanel()
        panel.title = scope.panelTitle
        panel.prompt = "Choose"
        panel.message = "FDE will read and work inside the selected Legacy and Agent folders."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        setSelectedProjectRoot(url, scope: scope)
    }

    func setSelectedProjectRoot(_ projectURL: URL) {
        setSelectedProjectRoot(projectURL, scope: .legacy)
    }

    func setSelectedAgentProjectRoot(_ projectURL: URL) {
        setSelectedProjectRoot(projectURL, scope: .agent)
    }

    private func setSelectedProjectRoot(_ projectURL: URL, scope: ProjectScopeKind) {
        Task {
            await persistSelectedProjectRoot(projectURL, scope: scope)
        }
    }

    func approve(_ approval: ApprovalRequest) {
        guard isApprovalBoundToSelectedConversation(approval),
              let originatingSessionID = selectedAgentSessionID else {
            lastError = "This approval is not bound to the selected conversation and Mission."
            return
        }
        if let missionID = approval.taskID,
           missionCleanupState(for: missionID)?.freezesMissionActions == true {
            lastError = "This exact mission is locked while Undo this run is being completed."
            return
        }
        if approval.targetKind == .candidatePatchPlan {
            guard candidatePatchReviewEligibility(approval) else {
                lastError = "This exact Candidate Patch review action is unavailable or already in progress."
                return
            }
            openCandidatePatchApprovalConfirmation(
                approval,
                source: candidatePatchApprovalInvocationSource()
            )
            return
        }
        guard let workspace = selectedWorkspace else { return }
        Task {
            do {
                _ = try await environment.runtime.approveApprovalRequest(
                    approval.id,
                    workspace: workspace,
                    reason: "Approved from Agent Workspace"
                )
                if let event = applyApprovalGranted(approval.id, to: originatingSessionID) {
                    try await recordInteractionEvent(event, workspace: workspace, taskID: approval.taskID)
                }
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func candidatePatchReviewEligibility(_ approval: ApprovalRequest) -> Bool {
        guard approval.targetKind == .candidatePatchPlan,
              approval.state == .pending,
              isApprovalBoundToSelectedConversation(approval),
              selectedTaskPendingApprovals.contains(where: { $0.id == approval.id }),
              !candidatePatchReviewActionsInFlight.contains(approval.id),
              candidatePatchApprovalConfirmation == nil,
              let missionID = approval.taskID,
              missionCleanupState(for: missionID)?.freezesMissionActions != true else {
            return false
        }
        return true
    }

    func confirmCandidatePatchApproval(_ confirmation: CandidatePatchApprovalConfirmation) {
        guard confirmation == candidatePatchApprovalConfirmation,
              let workspace = selectedWorkspace,
              let originatingSessionID = selectedAgentSessionID,
              let context = candidatePatchApprovalUIContext(for: confirmation.approvalRequestID) else {
            lastError = "The Candidate Patch approval is no longer the visible pending request."
            cancelCandidatePatchApprovalConfirmation()
            return
        }
        let source = candidatePatchApprovalInvocationSource()
        candidatePatchReviewActionsInFlight.insert(confirmation.approvalRequestID)
        isConfirmingCandidatePatchApproval = true
        Task {
            defer {
                isConfirmingCandidatePatchApproval = false
                candidatePatchReviewActionsInFlight.remove(confirmation.approvalRequestID)
            }
            do {
                _ = try await environment.runtime.confirmCandidatePatchApproval(
                    confirmation,
                    workspace: workspace,
                    context: context,
                    source: source,
                    reason: "Confirmed from Candidate Patch approval sheet"
                )
                candidatePatchApprovalConfirmation = nil
                if let event = applyApprovalGranted(
                    confirmation.approvalRequestID,
                    to: originatingSessionID
                ) {
                    try await recordInteractionEvent(event, workspace: workspace, taskID: confirmation.taskID)
                }
                await refresh()
            } catch {
                candidatePatchApprovalConfirmation = nil
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func cancelCandidatePatchApprovalConfirmation() {
        guard let confirmation = candidatePatchApprovalConfirmation else { return }
        candidatePatchApprovalConfirmation = nil
        isConfirmingCandidatePatchApproval = false
        Task {
            await environment.runtime.cancelCandidatePatchApprovalConfirmation(
                confirmation.confirmationStepID
            )
        }
    }

    func openCandidatePatchRevertConfirmation(_ snapshot: CandidatePatchActivitySnapshot) {
        guard isCandidatePatchBoundToSelectedConversation(snapshot),
              let originatingSessionID = selectedAgentSessionID,
              let missionID = snapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) else {
            lastError = "The Candidate Patch Revert target is not bound to the selected conversation and Mission."
            return
        }
        if missionCleanupState(for: missionID)?.freezesMissionActions == true {
            lastError = "This exact mission is locked while Undo this run is being completed."
            return
        }
        guard candidatePatchRevertConfirmation == nil,
              let workspace = selectedWorkspace,
              let patchID = snapshot.patchID.flatMap(CandidatePatchID.init(rawValue:)),
              let sandboxID = snapshot.sandboxID.flatMap(SandboxID.init(rawValue:)),
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id else {
            lastError = "The exact Candidate Patch Revert target is not available in the authenticated workspace."
            return
        }
        let source = candidatePatchApprovalInvocationSource()
        Task {
            do {
                let requestingTask: FDETask
                if let selectedTask,
                   selectedTask.title == "Phase 2D.1 Candidate Patch Revert",
                   selectedTask.state == .pendingApproval {
                    requestingTask = selectedTask
                } else {
                    requestingTask = try await environment.runtime.runCandidatePatchRevert(
                        input: "revert exact Candidate Patch \(patchID.rawValue) in Sandbox \(sandboxID.rawValue)",
                        workspace: workspace
                    )
                }
                if let index = agentSessions.firstIndex(where: { $0.sessionID == originatingSessionID }) {
                    agentSessions[index].linkMissionChildTask(
                        requestingTask,
                        missionRunID: missionID
                    )
                }
                let context = CandidatePatchRevertUIContext(
                    currentWorkspaceID: workspace.id,
                    currentTaskID: requestingTask.id,
                    visiblePatchID: patchID,
                    visibleSandboxID: sandboxID,
                    authenticatedLocalSessionID: authenticatedLocalSessionID,
                    appSessionID: appSessionID
                )
                let confirmation = try await environment.runtime
                    .beginCandidatePatchRevertConfirmation(
                        patchID: patchID,
                        sandboxID: sandboxID,
                        workspace: workspace,
                        context: context,
                        source: source
                    )
                guard selectedAgentSessionID == originatingSessionID,
                      isCandidatePatchBoundToSelectedConversation(snapshot) else {
                    await environment.runtime.cancelCandidatePatchRevertConfirmation(
                        confirmation.confirmationStepID
                    )
                    return
                }
                candidatePatchRevertConfirmation = confirmation
                await refresh()
            } catch {
                candidatePatchRevertConfirmation = nil
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func prepareGeneratedTestPlan(_ snapshot: CandidatePatchActivitySnapshot) {
        guard isCandidatePatchBoundToSelectedConversation(snapshot),
              let missionID = snapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)),
              let originatingSessionID = selectedAgentSessionID else {
            lastError = "The Candidate Patch is not bound to the selected conversation and Mission."
            return
        }
        if missionCleanupState(for: missionID)?.freezesMissionActions == true {
            lastError = "This exact mission is locked while Undo this run is being completed."
            return
        }
        guard let workspace = selectedWorkspace,
              let sourceBinding = snapshot.exactGeneratedTestSourceBinding,
              sourceBinding.workspaceID == workspace.id,
              let authenticatedLocalSessionID = session?.id,
              authenticatedLocalSessionID == sourceBinding.authenticatedLocalSessionID,
              session?.workspaceID == workspace.id else {
            lastError = snapshot.generatedTestActionUnavailableReason
                ?? "The exact persisted PATCH_READY Candidate Patch binding is not available in the authenticated workspace."
            return
        }
        let context = GeneratedTestPlanningContext(
            sourceBinding: sourceBinding,
            appSessionID: appSessionID
        )
        Task {
            do {
                let task = try await environment.runtime.runGeneratedTestPlanning(
                    input: "prepare a Generated Test Plan for this exact visible Candidate Patch without writing files",
                    workspace: workspace,
                    context: context
                )
                if let index = agentSessions.firstIndex(where: { $0.sessionID == originatingSessionID }) {
                    agentSessions[index].linkMissionChildTask(
                        task,
                        missionRunID: sourceBinding.sourceCandidatePatchTaskID
                    )
                }
                if selectedAgentSessionID == originatingSessionID {
                    selectedTaskID = sourceBinding.sourceCandidatePatchTaskID
                }
                await refresh()
            } catch {
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func generatedTestPlanGenerationEligibility(
        _ snapshot: GeneratedTestActivitySnapshot
    ) -> GeneratedTestPlanGenerationEligibility {
        guard isGeneratedTestPlanBoundToSelectedConversation(snapshot) else {
            return .unavailable("This Generated Test Plan is not bound to the selected conversation and Mission.")
        }
        if let missionID = snapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)),
           missionCleanupState(for: missionID)?.freezesMissionActions == true {
            return .unavailable("This exact mission is locked while Undo this run is being completed.")
        }
        guard let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id,
              let planningTaskID = snapshot.planningTaskID.flatMap(UUID.init(uuidString:)) else {
            return .unavailable("The exact authenticated Generated Test Plan authority is unavailable.")
        }
        let plan = try? GeneratedTestPlanStore(storageRoot: environment.sandboxLifecycle.storageRoot).load(
            workspaceID: workspace.id,
            planningTaskID: planningTaskID
        )
        let hasExistingArtifact = plan.map { exactPlan in
            conversationAssetProjection.generatedTestArtifacts.contains {
                $0.sourceBinding.generatedTestPlanID == exactPlan.planID
                    && $0.sourceBinding.generatedTestPlanRevision == exactPlan.revision
                    && $0.sourceBinding.generatedTestPlanSHA256 == exactPlan.planSHA256
                    && $0.sourceBinding.generatedTestSourceBinding == exactPlan.sourceBinding
            }
        } ?? false
        let authorityAppSessionID = plan.flatMap {
            exactMissionContinuationAppSessionID(for: snapshot, persistedPlan: $0)
        } ?? appSessionID
        return snapshot.generationEligibility(
            persistedPlan: plan,
            workspaceID: workspace.id,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            appSessionID: authorityAppSessionID,
            hasExistingArtifact: hasExistingArtifact,
            isInFlight: generatedTestPlanGenerationsInFlight.contains(snapshot.assetID)
        )
    }

    func generateTestArtifact(_ snapshot: GeneratedTestActivitySnapshot) {
        let eligibility = generatedTestPlanGenerationEligibility(snapshot)
        guard eligibility.isAvailable,
              let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              let planningTaskID = snapshot.planningTaskID.flatMap(UUID.init(uuidString:)),
              let plan = try? GeneratedTestPlanStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
              ).load(workspaceID: workspace.id, planningTaskID: planningTaskID),
              let context = snapshot.exactGenerationContext(
                for: plan,
                workspaceID: workspace.id,
                authenticatedLocalSessionID: authenticatedLocalSessionID,
                appSessionID: plan.sourceBinding.appSessionID
              ) else {
            lastError = eligibility.unavailableReason
                ?? "The exact persisted Generated Test Plan binding is unavailable."
            return
        }
        let actionID = snapshot.assetID
        generatedTestPlanGenerationsInFlight.insert(actionID)
        Task {
            defer { generatedTestPlanGenerationsInFlight.remove(actionID) }
            do {
                let result = try GeneratedTestArtifactService(lifecycle: environment.sandboxLifecycle).generate(
                    GeneratedTestArtifactGenerationRequest(context: context)
                )
                if result.outcome == .clarificationRequired {
                    lastError = "CLARIFICATION_REQUIRED: " + result.missingEvidence.joined(separator: " · ")
                }
                await refresh()
            } catch {
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    /// Executes the single product-facing test-review action. The summary must
    /// still be the exact Current Run. An existing awaiting-review Artifact is
    /// returned directly; otherwise exactly one Artifact is generated from the
    /// bound persisted Plan and returned for the unified review workspace.
    func reviewProposedTests(
        _ summary: MissionSummary,
        completion: @escaping (GeneratedTestArtifact?) -> Void
    ) {
        guard let current = exactCurrentMissionSummary(),
              summary.missionID == current.missionID,
              summary.lineageState == .exact,
              current.lineageState == .exact,
              summary.lineage?.lineageKey == current.lineage?.lineageKey,
              current.primaryAction == .reviewProposedTests else {
            lastError = "Review proposed tests could not bind to the exact current Mission Run."
            completion(nil)
            return
        }

        if let artifact = current.generatedTestArtifact,
           let revision = artifact.currentRevision {
            guard artifact.reviewState(for: revision.revision) == .awaitingReview,
                  generatedTestArtifactReviewEligibility(artifact).isAvailable else {
                lastError = "This exact Generated Test Artifact already has a persisted decision or is no longer reviewable."
                completion(nil)
                return
            }
            completion(artifact)
            return
        }

        guard let planSnapshot = current.generatedTestPlan,
              planSnapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == current.missionID else {
            lastError = "The exact Generated Test Plan is not attached to this Mission Run."
            completion(nil)
            return
        }
        generateTestArtifactForReview(
            planSnapshot,
            missionRunID: current.missionID,
            completion: completion
        )
    }

    private func generateTestArtifactForReview(
        _ snapshot: GeneratedTestActivitySnapshot,
        missionRunID: UUID,
        completion: @escaping (GeneratedTestArtifact?) -> Void
    ) {
        let eligibility = generatedTestPlanGenerationEligibility(snapshot)
        guard eligibility.isAvailable,
              let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              let planningTaskID = snapshot.planningTaskID.flatMap(UUID.init(uuidString:)),
              let plan = try? GeneratedTestPlanStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
              ).load(workspaceID: workspace.id, planningTaskID: planningTaskID),
              plan.sourceBinding.sourceCandidatePatchTaskID == missionRunID,
              let context = snapshot.exactGenerationContext(
                for: plan,
                workspaceID: workspace.id,
                authenticatedLocalSessionID: authenticatedLocalSessionID,
                appSessionID: plan.sourceBinding.appSessionID
              ) else {
            lastError = eligibility.unavailableReason
                ?? "The exact persisted Generated Test Plan binding is unavailable."
            completion(nil)
            return
        }

        let actionID = snapshot.assetID
        generatedTestPlanGenerationsInFlight.insert(actionID)
        Task {
            defer { generatedTestPlanGenerationsInFlight.remove(actionID) }
            do {
                let result = try GeneratedTestArtifactService(lifecycle: environment.sandboxLifecycle).generate(
                    GeneratedTestArtifactGenerationRequest(context: context)
                )
                guard result.outcome == .testArtifactReviewReady,
                      let artifact = result.artifact,
                      artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID == missionRunID,
                      artifact.sourceBinding.generatedTestPlanID == context.generatedTestPlanID,
                      artifact.sourceBinding.generatedTestPlanRevision == context.generatedTestPlanRevision,
                      artifact.sourceBinding.generatedTestPlanSHA256 == context.generatedTestPlanSHA256 else {
                    lastError = "CLARIFICATION_REQUIRED: " + result.missingEvidence.joined(separator: " · ")
                    await refresh()
                    completion(nil)
                    return
                }
                await refresh()
                completion(artifact)
            } catch {
                lastError = error.localizedDescription
                await refresh()
                completion(nil)
            }
        }
    }

    func requestGeneratedTestArtifactChanges(_ artifact: GeneratedTestArtifact, instructions: String) {
        reviewGeneratedTestArtifact(artifact) { service, context in
            _ = try service.requestChanges(context, instructions: instructions)
        }
    }

    func rejectGeneratedTestArtifact(_ artifact: GeneratedTestArtifact) {
        reviewGeneratedTestArtifact(artifact) { service, context in
            _ = try service.reject(context)
        }
    }

    func approveGeneratedTestArtifact(_ artifact: GeneratedTestArtifact) {
        reviewGeneratedTestArtifact(artifact) { service, context in
            let confirmation = try service.beginApprovalConfirmation(context)
            _ = try service.confirmApproval(confirmation, context: context)
        }
    }

    func generatedTestArtifactReviewEligibility(
        _ artifact: GeneratedTestArtifact
    ) -> GeneratedTestArtifactReviewEligibility {
        guard isGeneratedTestArtifactBoundToSelectedConversation(artifact) else {
            return .unavailable("This Generated Test Artifact is not bound to the selected conversation and Mission.")
        }
        let missionID = artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID
        if missionCleanupState(for: missionID)?.freezesMissionActions == true {
            return .unavailable("This exact mission is locked while Undo this run is being completed.")
        }
        guard let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id,
              artifact.sourceBinding.generatedTestSourceBinding.workspaceID == workspace.id else {
            return .unavailable("An authenticated local session is required to review this artifact.")
        }
        let eligibility = artifact.reviewEligibility(
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            appSessionID: exactMissionReviewAppSessionID(for: artifact) ?? appSessionID
        )
        guard eligibility.isAvailable,
              let reviewSessionID = artifact.currentRevision?.reviewSessionID else {
            return eligibility
        }
        guard !generatedTestArtifactReviewSessionsInFlight.contains(reviewSessionID) else {
            return .unavailable("This exact Generated Test Artifact review action is already in progress.")
        }
        return .available
    }

    func openMissionUndoConfirmation(_ summary: MissionSummary) {
        guard missionUndoConfirmation == nil,
              let workspace = selectedWorkspace,
              let scope = selectedConversationScope,
              scope.containsMissionTask(summary.missionID),
              summary.cleanup?.phase != .cleanedUp,
              summary.cleanup?.freezesMissionActions != true else {
            lastError = "Undo this run is unavailable because this exact mission is already being cleaned up."
            return
        }
        guard let exactCurrent = selectedMissionPresentation?.current else {
            lastError = "Undo this run could not bind to the selected conversation."
            return
        }
        guard summary.undoEligible,
              summary.lineageState == .exact,
              summary.missionID == exactCurrent.missionID,
              summary.lineage?.lineageKey == exactCurrent.lineage?.lineageKey,
              summary.legacyRoot == nil || summary.legacyRoot == workspace.localProjectRoot,
              let request = MissionUndoRequest(summary: summary, workspaceID: workspace.id) else {
            lastError = "Undo this run could not bind to the exact current mission and Legacy."
            return
        }
        missionUndoConfirmation = MissionUndoConfirmation(
            confirmationID: UUID(),
            request: request,
            issuedAt: Date()
        )
    }

    func confirmMissionUndo(_ confirmation: MissionUndoConfirmation) {
        guard confirmation == missionUndoConfirmation,
              let workspace = selectedWorkspace,
              confirmation.request.workspaceID == workspace.id,
              let current = exactCurrentMissionSummary(),
              current.missionID == confirmation.request.missionID,
              current.lineage?.lineageKey == confirmation.request.lineageKey,
              !isConfirmingMissionUndo else {
            lastError = "The Undo this run confirmation is no longer current."
            cancelMissionUndoConfirmation()
            return
        }
        let request = confirmation.request
        let starting = MissionCleanupState.starting(
            missionID: request.missionID,
            workspaceID: request.workspaceID,
            patch: selectedMissionPatch(for: request),
            lineage: MissionRunIdentity(
                missionRunID: request.missionID,
                workspaceID: request.workspaceID,
                sourceCandidatePatchTaskID: request.missionID,
                lineageKey: request.lineageKey ?? "",
                canonicalLegacyRoot: request.canonicalLegacyRoot,
                sourceSnapshotID: request.sourceSnapshotID,
                assessmentID: request.assessmentID,
                candidatePatchID: request.patchID,
                candidatePatchPlanID: request.patchPlanID,
                candidatePatchPlanRevision: request.patchRevision,
                sandboxID: request.sandboxID,
                generatedTestPlanningTaskID: nil,
                generatedTestPlanID: nil,
                generatedTestPlanRevision: nil,
                generatedTestPlanSHA256: nil,
                generatedTestArtifactID: nil,
                generatedTestArtifactRevision: nil,
                generatedTestArtifactSHA256: nil
            )
        )
        do {
            try cancelControlledEvalRunsForUndo(request)
            try MissionCleanupStore(storageRoot: environment.sandboxLifecycle.storageRoot).save(starting)
            replaceMissionCleanupState(starting)
        } catch {
            lastError = error.localizedDescription
            return
        }

        missionUndoConfirmation = nil
        isConfirmingMissionUndo = true
        cancelCandidatePatchApprovalConfirmation()
        cancelCandidatePatchRevertConfirmation()
        cancelCandidatePatchDestructionConfirmation()
        let lifecycle = environment.sandboxLifecycle
        Task {
            let result = await Task.detached {
                MissionCleanupOrchestrator(lifecycle: lifecycle).execute(request)
            }.value
            replaceMissionCleanupState(result)
            isConfirmingMissionUndo = false
            if result.phase == .partialFailure {
                lastError = result.failureReason ?? "Cleanup partially completed."
            }
            await refresh()
        }
    }

    func retryMissionCleanup(_ summary: MissionSummary) {
        guard isMissionSummaryBoundToSelectedConversation(summary),
              let workspace = selectedWorkspace,
              let cleanup = missionCleanupState(for: summary.missionID),
              cleanup.phase == .partialFailure,
              !isConfirmingMissionUndo else {
            lastError = "There is no incomplete exact cleanup step available to retry."
            return
        }
        guard let request = MissionUndoRequest(summary: summary, workspaceID: workspace.id) else {
            lastError = "The incomplete cleanup no longer matches an exact Mission Run."
            return
        }
        isConfirmingMissionUndo = true
        let lifecycle = environment.sandboxLifecycle
        Task {
            let result = await Task.detached {
                MissionCleanupOrchestrator(lifecycle: lifecycle).execute(request)
            }.value
            replaceMissionCleanupState(result)
            isConfirmingMissionUndo = false
            if result.phase == .partialFailure {
                lastError = result.failureReason ?? "Cleanup remains incomplete."
            }
            await refresh()
        }
    }

    func cancelMissionUndoConfirmation() {
        missionUndoConfirmation = nil
    }

    private func missionCleanupState(for missionID: UUID) -> MissionCleanupState? {
        missionCleanupStates.first { $0.missionID == missionID }
    }

    private func exactCurrentMissionSummary() -> MissionSummary? {
        selectedMissionPresentation?.current
    }

    func reviewProductionReadiness(_ summary: MissionSummary) {
        guard isMissionSummaryBoundToSelectedConversation(summary),
              summary.postReadyAction == .reviewProductionReadiness,
              productionReadinessRestoreFailure == nil,
              summary.phase == .ready,
              summary.lineageState == .exact,
              summary.cleanup?.freezesMissionActions != true,
              let workspace = selectedWorkspace,
              workspace.id == summary.lineage?.workspaceID,
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id,
              let patchID = summary.lineage?.candidatePatchID.flatMap(CandidatePatchID.init(rawValue:)),
              let sandboxID = summary.lineage?.sandboxID.flatMap(SandboxID.init(rawValue:)),
              let planningTaskID = summary.lineage?.generatedTestPlanningTaskID.flatMap(UUID.init(uuidString:)),
              let artifact = summary.generatedTestArtifact,
              artifact.sourceBinding.generatedTestSourceBinding.authenticatedLocalSessionID == authenticatedLocalSessionID,
              artifact.sourceBinding.generatedTestSourceBinding.appSessionID == appSessionID else {
            lastError = "The exact current-app-session authority for this Ready mission is unavailable."
            return
        }
        do {
            let manifest = try CandidatePatchManifestStore(
                lifecycle: environment.sandboxLifecycle
            ).load(sandboxID: sandboxID, patchID: patchID)
            let generatedPlan = try GeneratedTestPlanStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            ).load(workspaceID: workspace.id, planningTaskID: planningTaskID)
            let service = ProductionReadinessPlanningService()
            let binding = try service.makeSourceBinding(
                missionRunID: summary.missionID,
                manifest: manifest,
                generatedTestPlan: generatedPlan,
                generatedTestArtifact: artifact,
                cleanupStatus: summary.cleanup?.phase.rawValue
            )
            let artifacts = try service.generate(sourceBinding: binding)
            guard artifacts.safetyCounters.hasZeroExecutionAuthority else {
                throw ProductionReadinessFailure.invalidClaim
            }
            let store = ProductionReadinessArtifactStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            )
            try store.save(artifacts)
            Task { await refresh() }
        } catch {
            lastError = error.localizedDescription
            Task { await refresh() }
        }
    }

    func productionReadinessReviewEligibility(
        _ report: ProductionReadinessReport
    ) -> ProductionReadinessReviewEligibility {
        guard let current = exactCurrentMissionSummary(),
              productionReadinessRestoreFailure == nil,
              current.lineageState == .exact,
              current.missionID == report.sourceBinding.missionRunID,
              current.productionReadinessReport?.reportID == report.reportID,
              current.aiEvalPlan != nil,
              current.cleanup?.freezesMissionActions != true,
              selectedWorkspace?.id == report.sourceBinding.workspaceID,
              session?.id == report.sourceBinding.authenticatedLocalSessionID,
              appSessionID == report.sourceBinding.appSessionID,
              let revision = report.currentRevision,
              report.reviewDecision(for: revision.revision) == nil else {
            return .unavailable("This report is historical, already decided, or lacks exact current-session review authority.")
        }
        return .available
    }

    func aiEvalPlanReviewEligibility(
        _ plan: AIEvalPlan
    ) -> ProductionReadinessReviewEligibility {
        let binding = plan.sourceBinding.readinessSourceBinding
        guard let current = exactCurrentMissionSummary(),
              productionReadinessRestoreFailure == nil,
              current.lineageState == .exact,
              current.missionID == binding.missionRunID,
              current.aiEvalPlan?.planID == plan.planID,
              current.productionReadinessReport != nil,
              current.cleanup?.freezesMissionActions != true,
              selectedWorkspace?.id == binding.workspaceID,
              session?.id == binding.authenticatedLocalSessionID,
              appSessionID == binding.appSessionID,
              let revision = plan.currentRevision,
              plan.reviewDecision(for: revision.revision) == nil else {
            return .unavailable("This Eval Plan is historical, already decided, or lacks exact current-session review authority.")
        }
        return .available
    }

    func reviewReadinessReport(
        _ report: ProductionReadinessReport,
        decision: ProductionReadinessReviewDecisionKind,
        instructions: String?
    ) {
        let eligibility = productionReadinessReviewEligibility(report)
        guard eligibility.isAvailable, let revision = report.currentRevision else {
            lastError = eligibility.unavailableReason
            return
        }
        let binding = report.sourceBinding
        let context = ProductionReadinessReviewContext(
            missionRunID: binding.missionRunID,
            workspaceID: binding.workspaceID,
            artifactID: report.reportID,
            revision: revision.revision,
            artifactSHA256: revision.digest.sha256,
            authenticatedLocalSessionID: binding.authenticatedLocalSessionID,
            appSessionID: binding.appSessionID
        )
        do {
            let updated = try ProductionReadinessPlanningService().reviewReport(
                report,
                decision: decision,
                instructions: instructions,
                context: context
            )
            try ProductionReadinessArtifactStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            ).save(updated)
            Task { await refresh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reviewAIEvalPlan(
        _ plan: AIEvalPlan,
        decision: ProductionReadinessReviewDecisionKind,
        instructions: String?
    ) {
        let eligibility = aiEvalPlanReviewEligibility(plan)
        guard eligibility.isAvailable, let revision = plan.currentRevision else {
            lastError = eligibility.unavailableReason
            return
        }
        let binding = plan.sourceBinding.readinessSourceBinding
        let context = ProductionReadinessReviewContext(
            missionRunID: binding.missionRunID,
            workspaceID: binding.workspaceID,
            artifactID: plan.planID,
            revision: revision.revision,
            artifactSHA256: revision.digest.sha256,
            authenticatedLocalSessionID: binding.authenticatedLocalSessionID,
            appSessionID: binding.appSessionID
        )
        do {
            let updated = try ProductionReadinessPlanningService().reviewEvalPlan(
                plan,
                decision: decision,
                instructions: instructions,
                context: context
            )
            try ProductionReadinessArtifactStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            ).save(updated)
            Task { await refresh() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func prepareControlledEvalExecution(_ summary: MissionSummary) {
        guard summary.controlledEvalAction == .reviewControlledEvalExecution
                || summary.controlledEvalAction == .reauthorizeControlledEvalExecution,
              summary.evalRun == nil,
              controlledEvalRestoreFailure == nil,
              summary.lineageState == .exact,
              summary.cleanup?.freezesMissionActions != true,
              let eligibility = summary.controlledEvalEligibility,
              eligibility.state == .currentAuthorizationReview
                || eligibility.state == .reauthorizationReview,
              let proposal = eligibility.proposal,
              let current = exactCurrentMissionSummary(),
              current.missionID == summary.missionID,
              current.controlledEvalEligibility == eligibility,
              let context = controlledEvalContext(missionRunID: summary.missionID) else {
            lastError = "The exact controlled Eval authorization review is no longer current."
            return
        }
        do {
            let authorization = try ControlledEvalExecutionService().authorizeExecution(
                proposal: proposal,
                context: context
            )
            replaceControlledEvalExecutionAuthorization(authorization)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func confirmAuthorizedControlledEvalExecution(_ summary: MissionSummary) {
        guard summary.controlledEvalAction == .reviewControlledEvalExecution,
              summary.evalRun == nil,
              controlledEvalRestoreFailure == nil,
              summary.lineageState == .exact,
              summary.cleanup?.freezesMissionActions != true,
              let eligibility = summary.controlledEvalEligibility,
              eligibility.state == .finalExecutionReview,
              let proposal = eligibility.proposal,
              let authorization = eligibility.authorization,
              !controlledEvalAuthorizationsInFlight.contains(authorization.authorizationID),
              let current = exactCurrentMissionSummary(),
              current.missionID == summary.missionID,
              current.controlledEvalEligibility == eligibility,
              let report = current.productionReadinessReport,
              let plan = current.aiEvalPlan,
              let context = controlledEvalContext(missionRunID: summary.missionID) else {
            lastError = "The exact single-use execution authorization is stale, consumed, or unavailable."
            return
        }
        controlledEvalAuthorizationsInFlight.insert(authorization.authorizationID)
        defer { controlledEvalAuthorizationsInFlight.remove(authorization.authorizationID) }
        let store = ControlledEvalRunStore(storageRoot: environment.sandboxLifecycle.storageRoot)
        do {
            let service = ControlledEvalExecutionService()
            let prepared = try service.prepareAuthorized(
                report: report,
                evalPlan: plan,
                proposal: proposal,
                authorization: authorization,
                context: context
            )
            // Consume before persistence or execution. Any subsequent activation
            // fails closed even if persistence cannot complete.
            replaceControlledEvalExecutionAuthorization(prepared.consumedAuthorization)
            try store.save(prepared.run)
            replaceControlledEvalRun(prepared.run)

            let approved = try service.approveExecution(prepared.run, context: context)
            try store.save(approved)
            replaceControlledEvalRun(approved)

            let begun = try service.beginExecution(
                approved,
                report: report,
                evalPlan: plan,
                context: context
            )
            try store.save(begun)
            replaceControlledEvalRun(begun)

            let result = try service.completeExecution(
                begun,
                report: report,
                evalPlan: plan,
                context: context
            )
            guard result.safetyCounters.hasZeroExternalAuthority else {
                throw ControlledEvalFailure.policyViolation
            }
            try store.save(result.run)
            replaceControlledEvalRun(result.run)
        } catch {
            lastError = error.localizedDescription
            Task { await refresh() }
        }
    }

    func controlledEvalExecutionReviewEligibility(
        _ run: EvalRun
    ) -> ProductionReadinessReviewEligibility {
        guard let current = exactCurrentMissionSummary(),
              controlledEvalRestoreFailure == nil,
              current.lineageState == .exact,
              current.evalRun?.runID == run.runID,
              current.cleanup?.freezesMissionActions != true,
              run.currentState == .awaitingExecutionApproval,
              !controlledEvalRunsInFlight.contains(run.runID),
              let context = controlledEvalContext(missionRunID: current.missionID),
              context.workspaceID == run.request.authority.workspaceID,
              context.authenticatedLocalSessionID == run.request.authority.authenticatedLocalSessionID,
              context.workspaceSessionID == run.request.authority.workspaceSessionID,
              context.appSessionID == run.request.authority.appSessionID else {
            return .unavailable("This Eval Run is historical, in flight, already decided, or lacks exact current-session execution authority.")
        }
        return .available
    }

    func confirmControlledEvalExecution(_ run: EvalRun) {
        let eligibility = controlledEvalExecutionReviewEligibility(run)
        guard eligibility.isAvailable,
              let context = controlledEvalContext(missionRunID: run.request.authority.missionRunID),
              let report = productionReadinessReports.first(where: {
                  $0.reportID == run.request.authority.productionReadinessReportID
              }),
              let plan = aiEvalPlans.first(where: {
                  $0.planID == run.request.authority.aiEvalPlanID
              }) else {
            lastError = eligibility.unavailableReason
            return
        }
        controlledEvalRunsInFlight.insert(run.runID)
        defer { controlledEvalRunsInFlight.remove(run.runID) }
        let store = ControlledEvalRunStore(storageRoot: environment.sandboxLifecycle.storageRoot)
        do {
            let service = ControlledEvalExecutionService()
            let approved = try service.approveExecution(run, context: context)
            try store.save(approved)
            replaceControlledEvalRun(approved)

            // Persist EXECUTING before evaluating. A process interruption can
            // therefore only restore as STOPPED_FAIL_CLOSED, never completed.
            let begun = try service.beginExecution(
                approved,
                report: report,
                evalPlan: plan,
                context: context
            )
            try store.save(begun)
            replaceControlledEvalRun(begun)

            let result = try service.completeExecution(
                begun,
                report: report,
                evalPlan: plan,
                context: context
            )
            guard result.safetyCounters.hasZeroExternalAuthority else {
                throw ControlledEvalFailure.policyViolation
            }
            try store.save(result.run)
            replaceControlledEvalRun(result.run)
        } catch {
            lastError = error.localizedDescription
            Task { await refresh() }
        }
    }

    func evalResultsReviewEligibility(
        _ run: EvalRun
    ) -> ProductionReadinessReviewEligibility {
        guard let current = exactCurrentMissionSummary(),
              controlledEvalRestoreFailure == nil,
              current.lineageState == .exact,
              current.evalRun?.runID == run.runID,
              current.cleanup?.freezesMissionActions != true,
              current.controlledEvalResultReviewEligibility?.state == .finalDecisionReview,
              let authorization = current.controlledEvalResultReviewEligibility?.authorization,
              !controlledEvalResultReviewAuthorizationsInFlight.contains(authorization.authorizationID) else {
            return .unavailable("These results are finalized, blocked, or lack exact current-session result-review authority.")
        }
        return .available
    }

    func prepareControlledEvalResultReview(_ summary: MissionSummary) {
        guard summary.controlledEvalAction == .authorizeEvalResultReview
                || summary.controlledEvalAction == .reauthorizeEvalResultReview,
              controlledEvalRestoreFailure == nil,
              summary.lineageState == .exact,
              summary.cleanup?.freezesMissionActions != true,
              let eligibility = summary.controlledEvalResultReviewEligibility,
              eligibility.state == .currentAuthorizationReview
                || eligibility.state == .reauthorizationReview,
              let proposal = eligibility.proposal,
              let current = exactCurrentMissionSummary(),
              current.missionID == summary.missionID,
              current.controlledEvalResultReviewEligibility == eligibility,
              let context = controlledEvalContext(missionRunID: summary.missionID) else {
            lastError = "The exact Eval Result authorization review is no longer current."
            return
        }
        do {
            let authorization = try ControlledEvalExecutionService().authorizeResultReview(
                proposal: proposal,
                context: context
            )
            replaceControlledEvalResultReviewAuthorization(authorization)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func reviewEvalResults(
        _ run: EvalRun,
        decision: EvalRunReviewDecisionKind,
        instructions: String?
    ) {
        guard let current = exactCurrentMissionSummary(),
              current.evalRun?.runID == run.runID,
              let eligibility = current.controlledEvalResultReviewEligibility,
              eligibility.state == .finalDecisionReview,
              let proposal = eligibility.proposal,
              let authorization = eligibility.authorization,
              !controlledEvalResultReviewAuthorizationsInFlight.contains(authorization.authorizationID),
              let exactRun = current.evalRun,
              let report = current.productionReadinessReport,
              let plan = current.aiEvalPlan,
              let context = controlledEvalContext(missionRunID: current.missionID) else {
            lastError = "The exact single-use Eval Result review authorization is stale, consumed, or unavailable."
            return
        }
        controlledEvalResultReviewAuthorizationsInFlight.insert(authorization.authorizationID)
        defer { controlledEvalResultReviewAuthorizationsInFlight.remove(authorization.authorizationID) }
        do {
            let reviewed = try ControlledEvalExecutionService().reviewResultsAuthorized(
                exactRun,
                report: report,
                evalPlan: plan,
                proposal: proposal,
                authorization: authorization,
                decision: decision,
                instructions: instructions,
                context: context
            )
            // Consume before persistence so a failed save cannot make the same
            // current-session authorization reusable.
            replaceControlledEvalResultReviewAuthorization(reviewed.consumedAuthorization)
            guard reviewed.safetyCounters.hasZeroExternalAuthority else {
                throw ControlledEvalFailure.policyViolation
            }
            try ControlledEvalRunStore(
                storageRoot: environment.sandboxLifecycle.storageRoot
            ).save(reviewed.run)
            replaceControlledEvalRun(reviewed.run)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func controlledEvalContext(missionRunID: UUID) -> ControlledEvalExecutionContext? {
        guard let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id,
              let workspaceSessionID = activeWorkspaceSessionID else {
            return nil
        }
        return ControlledEvalExecutionContext(
            missionRunID: missionRunID,
            workspaceID: workspace.id,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            workspaceSessionID: workspaceSessionID,
            appSessionID: appSessionID
        )
    }

    private func replaceControlledEvalRun(_ run: EvalRun) {
        controlledEvalRuns.removeAll { $0.runID == run.runID }
        controlledEvalRuns.append(run)
        controlledEvalRuns.sort {
            if $0.updatedAt == $1.updatedAt { return $0.runID.uuidString < $1.runID.uuidString }
            return $0.updatedAt < $1.updatedAt
        }
    }

    private func replaceControlledEvalExecutionAuthorization(
        _ authorization: ControlledEvalExecutionAuthorization
    ) {
        controlledEvalExecutionAuthorizations.removeAll {
            $0.authorizationID == authorization.authorizationID
                || ($0.authority.missionRunID == authorization.authority.missionRunID
                    && $0.authority.workspaceID == authorization.authority.workspaceID)
        }
        controlledEvalExecutionAuthorizations.append(authorization)
    }

    private func replaceControlledEvalResultReviewAuthorization(
        _ authorization: ControlledEvalResultReviewAuthorization
    ) {
        controlledEvalResultReviewAuthorizations.removeAll {
            $0.authorizationID == authorization.authorizationID
                || ($0.workspaceID == authorization.workspaceID
                    && $0.missionRunID == authorization.missionRunID
                    && $0.runID == authorization.runID)
        }
        controlledEvalResultReviewAuthorizations.append(authorization)
    }

    private func cancelControlledEvalRunsForUndo(_ request: MissionUndoRequest) throws {
        let eligible = controlledEvalRuns.filter {
            $0.request.authority.missionRunID == request.missionID
                && ($0.currentState == .awaitingExecutionApproval || $0.currentState?.isExecutionActive == true)
        }
        guard !eligible.isEmpty else { return }
        guard let context = controlledEvalContext(missionRunID: request.missionID) else {
            throw ControlledEvalFailure.sessionMismatch
        }
        let service = ControlledEvalExecutionService()
        let store = ControlledEvalRunStore(storageRoot: environment.sandboxLifecycle.storageRoot)
        for run in eligible {
            let authority = run.request.authority
            guard authority.workspaceID == request.workspaceID,
                  authority.canonicalLegacyRoot == request.canonicalLegacyRoot,
                  authority.sourceSnapshotID == request.sourceSnapshotID,
                  authority.readinessSourceBinding.candidatePatchManifestID == request.candidatePatchManifestID,
                  authority.readinessSourceBinding.candidatePatchArtifactSHA256 == request.candidatePatchArtifactSHA256 else {
                throw ControlledEvalFailure.authorityMismatch
            }
            let cancelled = try service.cancel(run, context: context)
            try store.save(cancelled)
            replaceControlledEvalRun(cancelled)
        }
    }

    private func exactMissionContinuationAppSessionID(
        for snapshot: GeneratedTestActivitySnapshot,
        persistedPlan: GeneratedTestPlan
    ) -> UUID? {
        guard let current = exactCurrentMissionSummary(),
              current.lineageState == .exact,
              current.primaryAction == .reviewProposedTests,
              current.generatedTestArtifact == nil,
              current.generatedTestPlan?.assetID == snapshot.assetID,
              snapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == current.missionID,
              persistedPlan.sourceBinding.sourceCandidatePatchTaskID == current.missionID,
              current.lineage?.generatedTestPlanID
                == persistedPlan.planID.uuidString.lowercased(),
              current.lineage?.generatedTestPlanRevision == persistedPlan.revision,
              current.lineage?.generatedTestPlanSHA256 == persistedPlan.planSHA256 else {
            return nil
        }
        // Continue with the app-session authority sealed into the exact Plan;
        // the current authenticated local session and Mission Run must still
        // match before this persisted authority can be reused after restart.
        return persistedPlan.sourceBinding.appSessionID
    }

    private func exactMissionReviewAppSessionID(
        for artifact: GeneratedTestArtifact
    ) -> UUID? {
        guard let current = exactCurrentMissionSummary(),
              current.lineageState == .exact,
              current.primaryAction == .reviewProposedTests,
              current.generatedTestArtifact?.artifactID == artifact.artifactID,
              artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID
                == current.missionID,
              current.lineage?.generatedTestArtifactID
                == artifact.artifactID.uuidString.lowercased() else {
            return nil
        }
        return artifact.sourceBinding.generatedTestSourceBinding.appSessionID
    }

    private func replaceMissionCleanupState(_ state: MissionCleanupState) {
        missionCleanupStates.removeAll { $0.missionID == state.missionID }
        missionCleanupStates.append(state)
        missionCleanupStates.sort { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.missionID.uuidString < rhs.missionID.uuidString }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func selectedMissionPatch(for request: MissionUndoRequest) -> CandidatePatchActivitySnapshot? {
        conversationAssetProjection.candidatePatches.first { patch in
            patch.sourceCandidatePatchTaskID == request.missionID.uuidString
                && patch.patchID == request.patchID
                && patch.planID == request.patchPlanID
                && patch.planRevision == request.patchRevision
                && patch.sandboxID == request.sandboxID
                && patch.canonicalLegacyRoot == request.canonicalLegacyRoot
                && patch.sourceSnapshotID == request.sourceSnapshotID
                && patch.manifestID == request.candidatePatchManifestID
                && patch.candidatePatchArtifactSHA256 == request.candidatePatchArtifactSHA256
                && patch.assessmentID == request.assessmentID
        }
    }

    private func reviewGeneratedTestArtifact(
        _ artifact: GeneratedTestArtifact,
        operation: @escaping @Sendable (GeneratedTestArtifactService, GeneratedTestArtifactReviewContext) throws -> Void
    ) {
        let eligibility = generatedTestArtifactReviewEligibility(artifact)
        guard let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id,
              let revision = artifact.currentRevision,
              let reviewSessionID = revision.reviewSessionID,
              eligibility.isAvailable,
              artifact.sourceBinding.generatedTestSourceBinding.workspaceID == workspace.id else {
            lastError = eligibility.unavailableReason
                ?? "The exact Generated Test Artifact review binding is unavailable."
            return
        }
        generatedTestArtifactReviewSessionsInFlight.insert(reviewSessionID)
        let sourceBinding = artifact.sourceBinding.generatedTestSourceBinding
        let authorityAppSessionID = exactMissionReviewAppSessionID(for: artifact) ?? appSessionID
        let context = GeneratedTestArtifactReviewContext(
            workspaceID: workspace.id,
            generatedTestPlanningTaskID: sourceBinding.generatedTestPlanningTaskID,
            generatedTestPlanID: artifact.sourceBinding.generatedTestPlanID,
            generatedTestPlanRevision: artifact.sourceBinding.generatedTestPlanRevision,
            generatedTestPlanSHA256: artifact.sourceBinding.generatedTestPlanSHA256,
            sourceCandidatePatchTaskID: sourceBinding.sourceCandidatePatchTaskID,
            candidatePatchID: sourceBinding.patchID,
            candidatePatchPlanID: sourceBinding.candidatePatchPlanID,
            candidatePatchPlanRevision: sourceBinding.candidatePatchPlanRevision,
            candidatePatchArtifactSHA256: sourceBinding.candidatePatchArtifactSHA256,
            sandboxID: sourceBinding.sandboxID,
            artifactID: artifact.artifactID,
            artifactRevision: revision.revision,
            artifactSHA256: revision.digest.sha256,
            reviewSessionID: reviewSessionID,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            appSessionID: authorityAppSessionID
        )
        Task {
            defer { generatedTestArtifactReviewSessionsInFlight.remove(reviewSessionID) }
            do {
                try operation(GeneratedTestArtifactService(lifecycle: environment.sandboxLifecycle), context)
                await refresh()
            } catch {
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func confirmCandidatePatchRevert(_ confirmation: CandidatePatchRevertConfirmation) {
        guard confirmation == candidatePatchRevertConfirmation,
              let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              candidatePatchBindingIsCurrent(
                  patchID: confirmation.binding.patchID,
                  sandboxID: confirmation.binding.sandboxID
              ) else {
            lastError = "The Candidate Patch Revert confirmation is no longer current."
            cancelCandidatePatchRevertConfirmation()
            return
        }
        let context = CandidatePatchRevertUIContext(
            currentWorkspaceID: workspace.id,
            currentTaskID: confirmation.requestingTaskID,
            visiblePatchID: confirmation.binding.patchID,
            visibleSandboxID: confirmation.binding.sandboxID,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            appSessionID: appSessionID
        )
        let source = candidatePatchApprovalInvocationSource()
        isConfirmingCandidatePatchRevert = true
        Task {
            defer { isConfirmingCandidatePatchRevert = false }
            do {
                _ = try await environment.runtime.confirmCandidatePatchRevert(
                    confirmation,
                    workspace: workspace,
                    context: context,
                    source: source
                )
                candidatePatchRevertConfirmation = nil
                await refresh()
            } catch {
                candidatePatchRevertConfirmation = nil
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func cancelCandidatePatchRevertConfirmation() {
        guard let confirmation = candidatePatchRevertConfirmation else { return }
        candidatePatchRevertConfirmation = nil
        isConfirmingCandidatePatchRevert = false
        Task {
            await environment.runtime.cancelCandidatePatchRevertConfirmation(
                confirmation.confirmationStepID
            )
            await refresh()
        }
    }

    func openCandidatePatchDestructionConfirmation(_ snapshot: CandidatePatchActivitySnapshot) {
        guard isCandidatePatchBoundToSelectedConversation(snapshot),
              let missionID = snapshot.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)),
              let originatingSessionID = selectedAgentSessionID else {
            lastError = "The Candidate Patch Sandbox is not bound to the selected conversation and Mission."
            return
        }
        if missionCleanupState(for: missionID)?.freezesMissionActions == true {
            lastError = "This exact mission is locked while Undo this run is being completed."
            return
        }
        guard candidatePatchDestructionConfirmation == nil,
              let workspace = selectedWorkspace,
              let taskID = selectedAgentSession?.runtimeTaskID,
              let patchID = snapshot.patchID.flatMap(CandidatePatchID.init(rawValue:)),
              let sandboxID = snapshot.sandboxID.flatMap(SandboxID.init(rawValue:)),
              let authenticatedLocalSessionID = session?.id,
              session?.workspaceID == workspace.id else {
            lastError = "The reverted Candidate Patch Sandbox is not available for separate destruction."
            return
        }
        let context = CandidatePatchRevertUIContext(
            currentWorkspaceID: workspace.id,
            currentTaskID: taskID,
            visiblePatchID: patchID,
            visibleSandboxID: sandboxID,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            appSessionID: appSessionID
        )
        let source = candidatePatchApprovalInvocationSource()
        Task {
            do {
                let confirmation = try await environment.runtime
                    .beginCandidatePatchSandboxDestructionConfirmation(
                        patchID: patchID,
                        sandboxID: sandboxID,
                        workspace: workspace,
                        context: context,
                        source: source
                    )
                guard selectedAgentSessionID == originatingSessionID,
                      isCandidatePatchBoundToSelectedConversation(snapshot) else {
                    await environment.runtime.cancelCandidatePatchSandboxDestructionConfirmation(
                        confirmation.confirmationStepID
                    )
                    return
                }
                candidatePatchDestructionConfirmation = confirmation
                await refresh()
            } catch {
                candidatePatchDestructionConfirmation = nil
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func confirmCandidatePatchDestruction(
        _ confirmation: CandidatePatchSandboxDestructionConfirmation
    ) {
        guard confirmation == candidatePatchDestructionConfirmation,
              let workspace = selectedWorkspace,
              let authenticatedLocalSessionID = session?.id,
              candidatePatchBindingIsCurrent(
                  patchID: confirmation.binding.patchID,
                  sandboxID: confirmation.binding.sandboxID
              ) else {
            lastError = "The Sandbox destruction confirmation is no longer current."
            cancelCandidatePatchDestructionConfirmation()
            return
        }
        let context = CandidatePatchRevertUIContext(
            currentWorkspaceID: workspace.id,
            currentTaskID: confirmation.requestingTaskID,
            visiblePatchID: confirmation.binding.patchID,
            visibleSandboxID: confirmation.binding.sandboxID,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            appSessionID: appSessionID
        )
        let source = candidatePatchApprovalInvocationSource()
        isConfirmingCandidatePatchDestruction = true
        Task {
            defer { isConfirmingCandidatePatchDestruction = false }
            do {
                _ = try await environment.runtime.confirmCandidatePatchSandboxDestruction(
                    confirmation,
                    workspace: workspace,
                    context: context,
                    source: source
                )
                candidatePatchDestructionConfirmation = nil
                await refresh()
            } catch {
                candidatePatchDestructionConfirmation = nil
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func cancelCandidatePatchDestructionConfirmation() {
        guard let confirmation = candidatePatchDestructionConfirmation else { return }
        candidatePatchDestructionConfirmation = nil
        isConfirmingCandidatePatchDestruction = false
        Task {
            await environment.runtime.cancelCandidatePatchSandboxDestructionConfirmation(
                confirmation.confirmationStepID
            )
            await refresh()
        }
    }

    private func openCandidatePatchApprovalConfirmation(
        _ approval: ApprovalRequest,
        source: CandidatePatchApprovalSource
    ) {
        guard candidatePatchApprovalConfirmation == nil,
              let workspace = selectedWorkspace,
              let originatingSessionID = selectedAgentSessionID,
              let context = candidatePatchApprovalUIContext(for: approval.id) else {
            lastError = "The Candidate Patch approval is not the current visible pending request."
            return
        }
        Task {
            do {
                let confirmation = try await environment.runtime
                    .beginCandidatePatchApprovalConfirmation(
                        approval.id,
                        workspace: workspace,
                        context: context,
                        source: source
                    )
                guard selectedAgentSessionID == originatingSessionID,
                      isApprovalBoundToSelectedConversation(approval) else {
                    await environment.runtime.cancelCandidatePatchApprovalConfirmation(
                        confirmation.confirmationStepID
                    )
                    return
                }
                candidatePatchApprovalConfirmation = confirmation
            } catch {
                candidatePatchApprovalConfirmation = nil
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    private func candidatePatchApprovalUIContext(
        for approvalRequestID: UUID
    ) -> CandidatePatchApprovalUIContext? {
        guard let workspaceID = selectedWorkspace?.id,
              let taskID = selectedAgentSession?.runtimeTaskID,
              let scope = selectedConversationScope,
              scope.containsMissionTask(taskID),
              let authenticatedUserSessionID = session?.id,
              session?.workspaceID == workspaceID,
              selectedTaskPendingApprovals.contains(where: {
                  $0.id == approvalRequestID && $0.targetKind == .candidatePatchPlan
              }) else {
            return nil
        }
        return CandidatePatchApprovalUIContext(
            currentWorkspaceID: workspaceID,
            currentTaskID: taskID,
            visiblePendingApprovalRequestIDs: selectedTaskPendingApprovals.map(\.id),
            authenticatedUserSessionID: authenticatedUserSessionID,
            appSessionID: appSessionID
        )
    }

    private func candidatePatchApprovalInvocationSource() -> CandidatePatchApprovalSource {
        guard let event = NSApp.currentEvent else { return .accessibilityUI }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp:
            return .nativeUI
        default:
            return .accessibilityUI
        }
    }

    private func candidatePatchBindingIsCurrent(
        patchID: CandidatePatchID,
        sandboxID: SandboxID
    ) -> Bool {
        guard let current = exactCurrentMissionSummary(),
              isMissionSummaryBoundToSelectedConversation(current),
              current.candidatePatch?.patchID == patchID.rawValue,
              current.candidatePatch?.sandboxID == sandboxID.rawValue else {
            return false
        }
        return true
    }

    func reject(_ approval: ApprovalRequest) {
        guard isApprovalBoundToSelectedConversation(approval),
              let originatingSessionID = selectedAgentSessionID else {
            lastError = "This approval is not bound to the selected conversation and Mission."
            return
        }
        if let missionID = approval.taskID,
           missionCleanupState(for: missionID)?.freezesMissionActions == true {
            lastError = "This exact mission is locked while Undo this run is being completed."
            return
        }
        guard let workspace = selectedWorkspace,
              approval.targetKind != .candidatePatchPlan || candidatePatchReviewEligibility(approval) else {
            lastError = "This exact Candidate Patch review action is unavailable or already in progress."
            return
        }
        if approval.targetKind == .candidatePatchPlan {
            candidatePatchReviewActionsInFlight.insert(approval.id)
        }
        Task {
            defer { candidatePatchReviewActionsInFlight.remove(approval.id) }
            do {
                _ = try await environment.runtime.rejectApprovalRequest(
                    approval.id,
                    workspace: workspace,
                    reason: "Rejected from Agent Workspace"
                )
                if let event = applyApprovalRejected(approval.id, to: originatingSessionID) {
                    try await recordInteractionEvent(event, workspace: workspace, taskID: approval.taskID)
                }
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func modify(_ approval: ApprovalRequest) {
        let action = AgentPresentationSanitizer.safeContent(approval.action, fallback: "approval")
        let resource = AgentPresentationSanitizer.safeContent(approval.resource, fallback: "protected action")
        commandText = "Change approach for \(action) on \(resource): "
    }

    func requestCandidatePatchChanges(_ approval: ApprovalRequest, revisionInstructions: String) {
        guard isApprovalBoundToSelectedConversation(approval) else {
            lastError = "This approval is not bound to the selected conversation and Mission."
            return
        }
        if let missionID = approval.taskID,
           missionCleanupState(for: missionID)?.freezesMissionActions == true {
            lastError = "This exact mission is locked while Undo this run is being completed."
            return
        }
        guard let workspace = selectedWorkspace,
              candidatePatchReviewEligibility(approval) else {
            lastError = "This exact Candidate Patch review action is unavailable or already in progress."
            return
        }
        candidatePatchReviewActionsInFlight.insert(approval.id)
        Task {
            defer { candidatePatchReviewActionsInFlight.remove(approval.id) }
            do {
                _ = try await environment.runtime.requestChangesApprovalRequest(
                    approval.id,
                    workspace: workspace,
                    revisionInstructions: revisionInstructions
                )
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func createStubSession() {
        guard let workspace = selectedWorkspace else { return }
        Task {
            do {
                let credential = try await environment.sessionRepository.startLocalSession(
                    subject: NSUserName(),
                    provider: "Local Session",
                    workspace: workspace
                )
                session = credential
                try await environment.runtime.recordAuditEvent(
                    type: .sessionStarted,
                    workspaceID: workspace.id,
                    summary: "Local session started",
                    payload: [
                        "session_id": credential.id.uuidString,
                        "workspace_id": workspace.id.uuidString,
                        "org_id": workspace.orgID.uuidString,
                        "role": workspace.role.rawValue,
                        "provider": credential.provider
                    ]
                )
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func clearSession() {
        let workspaceID = selectedWorkspaceID ?? session?.workspaceID
        Task {
            do {
                try await environment.sessionRepository.endSession()
                if let workspaceID {
                    try await environment.runtime.recordAuditEvent(
                        type: .sessionEnded,
                        workspaceID: workspaceID,
                        summary: "Local session ended",
                        payload: ["workspace_id": workspaceID.uuidString]
                    )
                }
                session = nil
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func persistSelectedProjectRoot(_ projectURL: URL, scope: ProjectScopeKind) async {
        let standardizedURL = projectURL.standardizedFileURL
        let projectRoot = standardizedURL.path
        let projectName = Self.projectName(for: standardizedURL)
        let previousWorkspaceID = selectedWorkspaceID

        do {
            var workspace: Workspace
            var workspaceIndex: Int?

            if scope == .legacy,
               let existingIndex = workspaces.firstIndex(where: { $0.localProjectRoot == projectRoot }) {
                workspaceIndex = existingIndex
                workspace = workspaces[existingIndex]
            } else if let selectedWorkspaceID,
                      let selectedIndex = workspaces.firstIndex(where: { $0.id == selectedWorkspaceID }) {
                workspaceIndex = selectedIndex
                workspace = workspaces[selectedIndex]
            } else {
                workspace = Workspace(id: UUID(), name: projectName, role: .fde, createdAt: Date())
                workspaces.append(workspace)
                workspaceIndex = workspaces.indices.last
            }

            switch scope {
            case .legacy:
                workspace.name = projectName
                workspace.displayName = projectName
                workspace.localProjectRoot = projectRoot
            case .agent:
                workspace.localAgentProjectRoot = projectRoot
                if workspace.localProjectRoot == nil {
                    workspace.name = "FDE Integration"
                    workspace.displayName = "FDE Integration"
                }
            }

            if let workspaceIndex {
                workspaces[workspaceIndex] = workspace
            }

            try await environment.persistence.saveWorkspace(workspace)
            selectedWorkspaceID = workspace.id
            refreshAgentSessionWorkspaceContexts(for: workspace)
            selectedAgentSessionID = agentSessions.first { $0.workspaceID == workspace.id }?.sessionID
            selectedTaskID = nil
            session = try await environment.sessionRepository.switchWorkspace(to: workspace)
            try await environment.runtime.recordAuditEvent(
                type: .workspaceSwitched,
                workspaceID: workspace.id,
                summary: "Project root selected",
                payload: [
                    "previous_workspace_id": previousWorkspaceID?.uuidString ?? "",
                    "workspace_id": workspace.id.uuidString,
                    "workspace_name": workspace.name,
                    "local_project_root": workspace.localProjectRoot ?? "",
                    "local_agent_project_root": workspace.localAgentProjectRoot ?? "",
                    "selected_scope": scope.auditLabel,
                    "selected_scope_root": projectRoot,
                    "access_scope": "selected_legacy_and_ai_agent_projects_only"
                ]
            )
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func receive(_ event: ExecutionEvent) {
        guard event.workspaceID == selectedWorkspaceID else { return }
        applyAgentEvent(event)
        scheduleAgentNarrationEnrichment(for: event)
        if shouldAppendLiveEvent(event) {
            appendLiveEvent(event)
        }
        Task { await refresh() }
    }

    private func shouldAppendLiveEvent(_ event: ExecutionEvent) -> Bool {
        guard let selectedAgentSession else { return false }
        return AgentSessionEventScope.belongsToSession(event, session: selectedAgentSession)
    }

    private func appendLiveEvent(_ event: ExecutionEvent) {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.append(event)
        events.sort { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
        eventChainValidationStatus = Self.eventChainStatus(for: events)
    }

    private func refreshSelectedTaskDetails() async {
        guard let workspace = selectedWorkspace else { return }

        do {
            // Conversation projection filters this workspace event ledger by
            // exact Agent Session and Mission lineage. Loading the ledger here
            // also preserves session-tagged chat events and exact child-task
            // events that an exact root-task query would omit.
            events = try await environment.persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
            if let selectedTaskID {
                do {
                    replayFrames = try await environment.runtime.replay(taskID: selectedTaskID, workspaceID: workspace.id)
                    missionReplay = try await environment.runtime.missionReplay(taskID: selectedTaskID, workspaceID: workspace.id)
                    replayValidationStatus = "Valid replay: \(replayFrames.count) frame(s)"
                } catch {
                    replayFrames = []
                    missionReplay = nil
                    replayValidationStatus = "Replay invalid: \(error.localizedDescription)"
                    lastError = error.localizedDescription
                }
            } else {
                replayFrames = []
                missionReplay = nil
                replayValidationStatus = "No task selected"
            }
            eventChainValidationStatus = Self.eventChainStatus(for: events)
            syncSelectedAgentSessionFromLoadedTaskAndEvents()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func initialPersistenceStatus(for persistence: any PersistenceStore, startupIssue: String?) -> String {
        if let startupIssue {
            return "In-memory fallback pending initialization: \(startupIssue)"
        }
        return "\(persistenceName(for: persistence)) pending initialization"
    }

    private static func readyPersistenceStatus(for persistence: any PersistenceStore, startupIssue: String?) -> String {
        if let startupIssue {
            return "In-memory fallback initialized: \(startupIssue)"
        }
        return "\(persistenceName(for: persistence)) initialized"
    }

    private static func persistenceName(for persistence: any PersistenceStore) -> String {
        let typeName = String(describing: type(of: persistence))
        return typeName.contains("SQLite") ? "SQLite persistence" : typeName
    }

    private static func projectName(for url: URL) -> String {
        let lastPathComponent = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return lastPathComponent.isEmpty ? url.path : lastPathComponent
    }

    private static func eventChainStatus(for events: [ExecutionEvent]) -> String {
        guard !events.isEmpty else {
            return "No events loaded"
        }

        do {
            try ReplayEngine().validate(events: events)
            return "Valid causal chain: \(events.count) event(s)"
        } catch {
            return "Event chain invalid: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func createAgentSession(
        goal: String,
        workspace: Workspace,
        requestID: UUID
    ) -> UUID {
        var session = AgentSession.newConversation(in: workspace)
        session.beginConversation(
            with: goal,
            messageID: requestID,
            turnID: requestID
        )
        agentSessions.insert(session, at: 0)
        selectedAgentSessionID = session.sessionID
        selectedTaskID = nil
        events = []
        replayFrames = []
        missionReplay = nil
        replayValidationStatus = "No runtime task linked"
        eventChainValidationStatus = "Agent session created"
        return session.sessionID
    }

    private func restoreWorkspaceUIState(
        validWorkspaceIDs: Set<UUID>,
        activeWorkspaceID: UUID?
    ) {
        let state = workspaceUIStateStore.load()
        var restoredSessionIDs = Set<UUID>()
        let uniqueSessions = state.sessions.filter {
            validWorkspaceIDs.contains($0.workspaceID)
                && restoredSessionIDs.insert($0.sessionID).inserted
        }
        let validSessions = AgentConversationSessionRetention
            .removingSafelyDisposableEmptySessions(
                from: uniqueSessions,
                drafts: state.drafts
            )
        let validSessionIDs = Set(validSessions.map(\.sessionID))
        let activeSessionIDs = Set(validSessions.filter {
            activeWorkspaceID == nil || $0.workspaceID == activeWorkspaceID
        }.map(\.sessionID))

        isRestoringWorkspaceUIState = true
        agentSessions = validSessions
        composerDrafts = state.drafts.filter { validSessionIDs.contains($0.key) }
        selectedAgentSessionID = state.selectedSessionID.flatMap {
            activeSessionIDs.contains($0) ? $0 : nil
        }
        isInspectorPresented = state.isInspectorPresented
        commandText = selectedAgentSessionID.flatMap { composerDrafts[$0] } ?? ""
        isRestoringWorkspaceUIState = false
    }

    private func persistWorkspaceUIStateIfNeeded() {
        guard !isRestoringWorkspaceUIState else { return }
        let durableSessions = AgentConversationSessionRetention
            .removingSafelyDisposableEmptySessions(
                from: agentSessions,
                drafts: composerDrafts
            )
        let durableSessionIDs = Set(durableSessions.map(\.sessionID))
        workspaceUIStateStore.save(AgentWorkspacePersistedUIState(
            sessions: durableSessions,
            selectedSessionID: selectedAgentSessionID.flatMap {
                durableSessionIDs.contains($0) ? $0 : nil
            },
            drafts: composerDrafts.filter { durableSessionIDs.contains($0.key) },
            isInspectorPresented: isInspectorPresented
        ))
    }

    private func refreshAgentSessionWorkspaceContexts(for workspace: Workspace) {
        for index in agentSessions.indices where agentSessions[index].workspaceID == workspace.id {
            agentSessions[index].refreshSelectedWorkspace(workspace)
        }
    }

    private func restoreCandidatePatchConversationIfNeeded(
        workspace: Workspace,
        workspaceEvents: [ExecutionEvent]
    ) {
        guard !conversationAssetProjection.candidatePatches.isEmpty,
              !agentSessions.contains(where: { $0.workspaceID == workspace.id }) else {
            return
        }

        let sourceTaskIDs = Set(
            conversationAssetProjection.candidatePatches
                .compactMap(\.sourceCandidatePatchTaskID)
                .compactMap(UUID.init(uuidString:))
        )
        let restorableTasks = tasks
            .filter { sourceTaskIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.createdAt > rhs.createdAt
            }

        for task in restorableTasks {
            var workspaceContext = AgentWorkspaceContext(workspace: workspace)
            var missionTaskIDs = [task.id]
            for plan in conversationAssetProjection.generatedTestPlans
            where plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == task.id {
                if let planningTaskID = plan.planningTaskID.flatMap(UUID.init(uuidString:)),
                   !missionTaskIDs.contains(planningTaskID) {
                    missionTaskIDs.append(planningTaskID)
                }
            }
            for artifact in conversationAssetProjection.generatedTestArtifacts
            where artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID == task.id {
                let planningTaskID = artifact.sourceBinding.generatedTestSourceBinding.generatedTestPlanningTaskID
                if !missionTaskIDs.contains(planningTaskID) { missionTaskIDs.append(planningTaskID) }
            }
            workspaceContext.missionTaskIDs = missionTaskIDs
            workspaceContext.linkRuntimeTask(task)
            let taskEvents = workspaceEvents.filter { event in
                event.payload["session_id"] == task.id.uuidString
                    || event.taskID.map(missionTaskIDs.contains) == true
                    || event.exactParentMissionRunID.map(missionTaskIDs.contains) == true
            }
            let conversation = AgentResponseComposer.replayConversation(
                sessionID: task.id,
                workspaceID: workspace.id,
                userRequest: task.rawInput,
                events: taskEvents,
                createdAt: task.createdAt
            )
            agentSessions.append(AgentSession(
                sessionID: task.id,
                workspaceID: workspace.id,
                userGoal: task.rawInput,
                createdAt: task.createdAt,
                currentState: .completed,
                interactionState: .completed,
                currentPlan: task.plan,
                conversation: conversation,
                workspaceContext: workspaceContext
            ))
        }
        // Restored workspace history is not current-conversation authority.
        // The user must select an exact restored conversation before its
        // Mission, artifacts, or Human Action can project.
        selectedAgentSessionID = nil
        selectedTaskID = nil
    }

    private func linkRuntimeTask(_ task: FDETask, to sessionID: UUID) {
        guard let index = agentSessions.firstIndex(where: { session in
            session.sessionID == sessionID && session.workspaceID == task.workspaceID
        }) else { return }

        agentSessions[index].syncRuntimeTask(task)
    }

    private func failAgentSession(_ sessionID: UUID, with error: Error) {
        guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        agentSessions[index].fail(with: error)
    }

    func selectDecision(messageID: UUID, optionID: String) {
        guard let workspace = selectedWorkspace,
              let sessionID = selectedAgentSessionID,
              let event = applyDecisionSelection(messageID: messageID, optionID: optionID, to: sessionID),
              let originatingSession = agentSessions.first(where: { $0.sessionID == sessionID }) else {
            return
        }
        let decision = event.payload["decision"] ?? optionID
        let taskID = originatingSession.runtimeTaskID
        Task {
            do {
                try await recordInteractionEvent(event, workspace: workspace, taskID: taskID)
                if originatingSession.runtimeTaskID == nil {
                    var session = originatingSession
                    let result = try await runtimeCoordinator.resumeMissionFromSelectedDecision(
                        decision: decision,
                        workspace: workspace,
                        session: &session,
                        runtime: environment.runtime
                    )
                    guard AgentSessionAsyncBinding.commit(
                        originatingSession: originatingSession,
                        updatedSession: session,
                        into: &agentSessions
                    ) else { return }
                    if let task = result.task {
                        linkRuntimeTask(task, to: sessionID)
                        if selectedAgentSessionID == sessionID {
                            selectedTaskID = task.id
                        }
                    }
                }
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func approveCurrentPlan() {
        guard let workspace = selectedWorkspace,
              let sessionID = selectedAgentSessionID,
              let event = applyPlanApproval(to: sessionID),
              let originatingSession = agentSessions.first(where: { $0.sessionID == sessionID }) else {
            return
        }
        let taskID = originatingSession.runtimeTaskID
        Task {
            do {
                try await recordInteractionEvent(event, workspace: workspace, taskID: taskID)
                if shouldStartApprovedImplementation(for: originatingSession) {
                    var session = originatingSession
                    let result = try await runtimeCoordinator.startApprovedImplementation(
                        workspace: workspace,
                        session: &session,
                        runtime: environment.runtime
                    )
                    guard AgentSessionAsyncBinding.commit(
                        originatingSession: originatingSession,
                        updatedSession: session,
                        into: &agentSessions
                    ) else { return }
                    if let task = result.task {
                        linkRuntimeTask(task, to: sessionID)
                        if selectedAgentSessionID == sessionID {
                            selectedTaskID = task.id
                        }
                    }
                }
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func modifyCurrentPlan() {
        guard let workspace = selectedWorkspace,
              let sessionID = selectedAgentSessionID,
              let event = applyPlanModificationRequest(to: sessionID),
              let taskID = agentSessions.first(where: { $0.sessionID == sessionID })?.runtimeTaskID else {
            return
        }
        Task {
            do {
                try await recordInteractionEvent(event, workspace: workspace, taskID: taskID)
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private func handleUserReply(
        _ content: String,
        in sessionID: UUID,
        continuation: Bool,
        requestID: UUID,
        inputFingerprint: UInt64
    ) {
        guard let workspace = selectedWorkspace,
              let originatingSession = agentSessions.first(where: {
                  $0.sessionID == sessionID && $0.workspaceID == workspace.id
              }) else {
            return
        }
        let preflightContext = runtimePreflightContext(for: originatingSession)
        Task {
            defer { endSubmission(inputFingerprint, sessionID: sessionID) }
            do {
                var session = originatingSession
                let result = try await runtimeCoordinator.resumeMission(
                    reply: content,
                    workspace: workspace,
                    session: &session,
                    runtime: environment.runtime,
                    continuation: continuation,
                    userMessageAlreadyAppended: true,
                    userMessageID: requestID,
                    preflightContext: preflightContext
                )
                guard AgentSessionAsyncBinding.commit(
                    originatingSession: originatingSession,
                    updatedSession: session,
                    into: &agentSessions
                ) else { return }
                if let task = result.task {
                    linkRuntimeTask(task, to: sessionID)
                    if self.selectedAgentSessionID == sessionID {
                        self.selectedTaskID = task.id
                    }
                }
                finishActivity(for: sessionID, requestID: requestID, result: result)
                await refresh()
            } catch {
                let scope = conversationActivities[sessionID]?.scope ?? .engineeringTask
                failActivity(for: sessionID, requestID: requestID, scope: scope, error: error)
                lastError = error.localizedDescription
            }
        }
    }

    private func applyDecisionSelection(messageID: UUID, optionID: String, to sessionID: UUID) -> AgentInteractionRuntimeEvent? {
        guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return interactionController.selectDecision(
            optionID: optionID,
            messageID: messageID,
            session: &agentSessions[index]
        )
    }

    private func applyPlanApproval(to sessionID: UUID) -> AgentInteractionRuntimeEvent? {
        guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return interactionController.approvePlan(session: &agentSessions[index])
    }

    private func applyPlanModificationRequest(to sessionID: UUID) -> AgentInteractionRuntimeEvent? {
        guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return interactionController.requestPlanModification(session: &agentSessions[index])
    }

    private func shouldStartApprovedImplementation(for session: AgentSession) -> Bool {
        guard session.currentState == .completed,
              session.planApprovalStatus == .approved else {
            return false
        }
        let artifactTitles = Set(session.artifacts.map(\.title))
        return artifactTitles.contains("Integration assessment")
            && artifactTitles.contains("Implementation plan")
            && !artifactTitles.contains("Code patch")
    }

    private func applyApprovalGranted(
        _ approvalID: UUID,
        to sessionID: UUID
    ) -> AgentInteractionRuntimeEvent? {
        guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return interactionController.approvalGranted(session: &agentSessions[index], approvalID: approvalID)
    }

    private func applyApprovalRejected(
        _ approvalID: UUID,
        to sessionID: UUID
    ) -> AgentInteractionRuntimeEvent? {
        guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return interactionController.approvalRejected(session: &agentSessions[index], approvalID: approvalID)
    }

    private func recordInteractionEvent(
        _ event: AgentInteractionRuntimeEvent,
        workspace: Workspace,
        taskID: UUID?
    ) async throws {
        _ = try await environment.runtime.recordAuditEvent(
            type: event.type,
            workspaceID: workspace.id,
            taskID: taskID,
            summary: event.summary,
            payload: event.payload
        )
    }

    private func shouldContinueSelectedSession(_ input: String) -> Bool {
        guard selectedAgentSessionID != nil else { return false }
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isContinuationCommand(normalized)
            || normalized.contains("why did you choose")
            || normalized.contains("change approach")
            || normalized.contains("ignore this connector")
            || normalized.contains("use another strategy")
    }

    private func shouldRouteToSelectedSession(_ input: String) -> Bool {
        selectedAgentSession != nil
    }

    private func activityScope(
        for input: String,
        session: AgentSession
    ) -> AgentConversationActivityScope {
        if reactivatesCurrentTask(input, session: session) {
            return .engineeringTask
        }
        let intent = missionClassifier.intent(for: input)
        let mode = missionClassifier.conversationMode(
            for: input,
            intent: intent,
            hasActiveRuntimeTask: false
        )
        if mode == .executableEngineeringTask {
            return .engineeringTask
        }
        if mode == .workspaceReadOnlyInvestigation,
           missionClassifier.requiresReadOnlyRuntime(input, intent: intent) {
            return .engineeringTask
        }
        return .normalChat
    }

    private func reactivatesCurrentTask(_ input: String, session: AgentSession) -> Bool {
        guard session.runtimeTaskID != nil else { return false }
        let intent = missionClassifier.intent(for: input)
        let mode = missionClassifier.conversationMode(
            for: input,
            intent: intent,
            hasActiveRuntimeTask: true
        )
        if missionClassifier.isMissionControlInstruction(input, intent: intent)
            || missionClassifier.isActiveMissionReference(input)
            || missionClassifier.isPriorWorkQuestion(input) {
            return true
        }
        let wasWaiting = session.interactionState == .waitingForUser
            || session.interactionState == .waitingForApproval
        if missionClassifier.isLikelyActiveMissionClarification(
            input,
            session: session,
            wasWaitingForRuntime: wasWaiting,
            selectedMode: mode
        ) {
            return true
        }
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "好了吗", "现在怎么样", "做到哪了", "为什么停了", "为什么阻塞",
            "status", "how is it going", "where are we", "why did it stop"
        ].contains { normalized.contains($0) }
    }

    private func beginSubmission(
        requestID: UUID,
        session: AgentSession,
        input: String,
        scope: AgentConversationActivityScope,
        inputFingerprint: UInt64,
        reactivatesCurrentTask: Bool
    ) {
        if let index = agentSessions.firstIndex(where: {
            $0.sessionID == session.sessionID && $0.workspaceID == session.workspaceID
        }) {
            agentSessions[index].setInteractionState(
                scope == .normalChat ? .responding : .running
            )
        }
        var activity = AgentConversationActivity.local(
            requestID: requestID,
            dialogID: session.sessionID,
            scope: scope
        )
        if scope == .engineeringTask, reactivatesCurrentTask {
            activity.metadata.taskID = session.runtimeTaskID
        }
        let intent = missionClassifier.intent(for: input)
        if intent.intentType == .aiAgentCompatibilityAssessment {
            activity.metadata.aiAssessment = .pending(for: AgentCapabilityProfile.detect(from: input))
        }
        conversationActivities[session.sessionID] = activity
        pendingSubmissionFingerprints[session.sessionID, default: []].insert(inputFingerprint)
        isRunning = pendingSubmissionFingerprints.values.contains { !$0.isEmpty }
    }

    private func finishActivity(
        for sessionID: UUID,
        requestID: UUID,
        result: AgentRuntimeCoordinatorResult
    ) {
        guard var activity = conversationActivities[sessionID],
              activity.requestID == requestID else {
            return
        }

        if let lifecycle = result.normalChatLifecycle {
            switch lifecycle {
            case .failed:
                activity.kind = .failed
                activity.labelOverride = AgentConversationActivity.providerUnavailableLabel
                activity.metadata.blockerReason = "the AI provider could not be reached"
            case .completed, .idle:
                activity.kind = .completed
                activity.labelOverride = nil
            case .thinking:
                activity.kind = .thinking
            }
            conversationActivities[sessionID] = activity
            return
        }

        if let task = result.task {
            activity.metadata.taskID = task.id
            switch task.state {
            case .completed, .replayed:
                activity.kind = .completed
            case .failed:
                activity.kind = .failed
                activity.metadata.blockerReason = "the task could not be completed"
            case .blocked:
                let partialEvent = events.last { event in
                    event.taskID == task.id
                        && event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
                }
                activity.kind = partialEvent == nil ? .blocked : .partial
                activity.metadata.unsatisfiedRequirementCount = partialEvent.flatMap {
                    $0.payload["evidence_requirements_unsatisfied_count"].flatMap(Int.init)
                }
                activity.metadata.blockerReason = AgentConversationActivityCopy.blockerReason(
                    partialEvent?.payload["blocker_reason"]
                        ?? events.last(where: { $0.taskID == task.id })?.payload["blocker_reason"]
                )
            case .waiting:
                let partialEvent = events.last { event in
                    event.taskID == task.id
                        && event.payload["partial_result_kind"] == "GROUNDED_PARTIAL_RESULT"
                }
                if let partialEvent {
                    activity.kind = .partial
                    activity.metadata.unsatisfiedRequirementCount = partialEvent.payload["evidence_requirements_unsatisfied_count"].flatMap(Int.init)
                    activity.metadata.blockerReason = AgentConversationActivityCopy.blockerReason(
                        partialEvent.payload["blocker_reason"]
                    )
                }
            case .created, .planned, .running, .pendingApproval:
                break
            }
        } else if activity.metadata.taskID == nil {
            activity.kind = .completed
        }
        conversationActivities[sessionID] = activity
    }

    private func failActivity(
        for sessionID: UUID,
        requestID: UUID,
        scope: AgentConversationActivityScope,
        error: Error
    ) {
        guard var activity = conversationActivities[sessionID],
              activity.requestID == requestID else {
            return
        }
        activity.kind = .failed
        if let persistenceError = error as? PersistenceError,
           let category = Self.eventStoreFailureCategory(for: persistenceError) {
            activity.labelOverride = "Event store failure · \(category)"
            activity.metadata.blockerReason = category
        } else if scope == .normalChat {
            activity.labelOverride = "Unable to reach the configured AI provider."
            activity.metadata.blockerReason = "the AI provider could not be reached"
        } else {
            activity.metadata.blockerReason = AgentConversationActivityCopy.blockerReason(
                error.localizedDescription,
                failure: true
            )
        }
        conversationActivities[sessionID] = activity
    }

    static func eventStoreFailureCategory(for error: PersistenceError) -> String? {
        error.eventStoreFailureCategory?.rawValue
    }

    private func endSubmission(_ fingerprint: UInt64, sessionID: UUID) {
        pendingSubmissionFingerprints[sessionID]?.remove(fingerprint)
        if pendingSubmissionFingerprints[sessionID]?.isEmpty == true {
            pendingSubmissionFingerprints.removeValue(forKey: sessionID)
        }
        isRunning = pendingSubmissionFingerprints.values.contains { !$0.isEmpty }
    }

    private func isPendingSubmission(_ fingerprint: UInt64, sessionID: UUID) -> Bool {
        pendingSubmissionFingerprints[sessionID]?.contains(fingerprint) == true
    }

    private func submissionFingerprint(_ input: String) -> UInt64 {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return normalized.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private var selectedRuntimePreflightContext: AgentRuntimePreflightContext {
        guard let session = selectedAgentSession else { return .empty }
        return runtimePreflightContext(for: session)
    }

    private func runtimePreflightContext(
        for session: AgentSession
    ) -> AgentRuntimePreflightContext {
        guard session.sessionID == selectedAgentSessionID,
              let summary = selectedMissionPresentation?.current,
              summary.missionID == session.runtimeTaskID,
              let report = summary.productionReadinessReport,
              report.sourceBinding.workspaceID == session.workspaceID,
              report.sourceBinding.missionRunID == summary.missionID,
              (try? ProductionReadinessArtifactValidator.validate(report)) != nil else {
            return .empty
        }
        return AgentRuntimePreflightContext(
            hasExactProductionReadinessReport: true
        )
    }

    private func hasRequiredProjectScope(for input: String, workspace: Workspace) -> Bool {
        let intent = missionClassifier.intent(for: input)
        if intent.intentType == .safeSandboxAcceptance {
            // The dedicated runtime returns workspace_not_selected when Legacy is absent.
            return true
        }
        let mode = missionClassifier.conversationMode(
            for: input,
            intent: intent,
            hasActiveRuntimeTask: selectedAgentSession?.runtimeTaskID != nil
        )
        switch mode {
        case .workspaceReadOnlyInvestigation:
            switch ReadOnlyMissionTarget(request: input) {
            case .legacy:
                return workspace.localProjectRootURL != nil
            case .agent:
                return workspace.localAgentProjectRootURL != nil
            case .comparison:
                return workspace.hasIntegrationProjectScope
            }
        case .executableEngineeringTask:
            return workspace.hasIntegrationProjectScope
        default:
            return true
        }
    }

    private func missingProjectScopeMessage(for input: String) -> String {
        let intent = missionClassifier.intent(for: input)
        if intent.intentType == .safeSandboxAcceptance {
            return SafeSandboxAcceptanceFailureCategory.workspaceNotSelected.rawValue
        }
        if missionClassifier.conversationMode(
            for: input,
            intent: intent,
            hasActiveRuntimeTask: selectedAgentSession?.runtimeTaskID != nil
        ) == .executableEngineeringTask {
            return "Choose both the Legacy and Agent projects before starting FDE."
        }
        switch ReadOnlyMissionTarget(request: input) {
        case .legacy:
            return "Choose the Legacy project before starting this read-only inspection."
        case .agent:
            return "Choose the Agent project before starting this read-only inspection."
        case .comparison:
            return "Choose both the Legacy and Agent projects before starting a comparison."
        }
    }

    private var selectedAgentSessionNeedsInput: Bool {
        selectedAgentSession?.interactionState == .waitingForUser
            || selectedAgentSession?.interactionState == .waitingForApproval
    }

    private func isContinuationCommand(_ input: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "continue previous task"
    }

    private func applyAgentEvent(_ event: ExecutionEvent) {
        guard let index = agentSessionIndex(for: event) else { return }
        let beforeCount = agentSessions[index].conversation.messages.count
        agentSessions[index].apply(event: event)
        let afterCount = agentSessions[index].conversation.messages.count
        LLMNarrationDebugLog.write(
            "appstore_deterministic_event_applied event_id=\(event.id.uuidString) event_type=\(event.type.rawValue) message_delta=\(afterCount - beforeCount)"
        )
    }

    private func scheduleAgentNarrationEnrichment(for event: ExecutionEvent) {
        let shouldPresent = AgentResponseComposer.shouldPresentInConversation(event)
        let usesLiveNarration = environment.agentResponseComposer.usesLiveNarration
        LLMNarrationDebugLog.write(
            "appstore_enrichment_check event_id=\(event.id.uuidString) event_type=\(event.type.rawValue) should_present=\(shouldPresent) uses_live_narration=\(usesLiveNarration)"
        )
        guard shouldPresent else {
            LLMNarrationDebugLog.write("appstore_enrichment_skipped event_id=\(event.id.uuidString) reason=event_not_presented")
            return
        }
        guard usesLiveNarration else {
            LLMNarrationDebugLog.write("appstore_enrichment_skipped event_id=\(event.id.uuidString) reason=live_narration_disabled")
            return
        }

        Task {
            await enrichAgentNarration(for: event)
        }
    }

    private func enrichAgentNarration(for event: ExecutionEvent) async {
        guard let index = agentSessionIndex(for: event) else {
            LLMNarrationDebugLog.write("appstore_enrichment_failed event_id=\(event.id.uuidString) reason=no_agent_session")
            return
        }
        let originatingSessionID = agentSessions[index].sessionID
        let history = agentSessions[index].conversation.messages
        LLMNarrationDebugLog.write("appstore_enrichment_started event_id=\(event.id.uuidString) event_type=\(event.type.rawValue)")
        let message = await environment.agentResponseComposer.liveMessage(
            for: event,
            history: history
        )
        guard let targetIndex = agentSessions.firstIndex(where: {
            $0.sessionID == originatingSessionID
                && AgentSessionEventScope.belongsToSession(event, session: $0)
        }) else {
            LLMNarrationDebugLog.write("appstore_enrichment_failed event_id=\(event.id.uuidString) reason=originating_agent_session_unavailable")
            return
        }
        var updatedSession = agentSessions[targetIndex]
        let replaced = updatedSession.replaceMessage(relatedEventID: event.id, with: message)
        if replaced {
            agentSessions[targetIndex] = updatedSession
        }
        LLMNarrationDebugLog.write(
            "ui_message_replaced event_id=\(event.id.uuidString) replaced=\(replaced) message_type=\(message.type.rawValue)"
        )
    }

    private func agentSessionIndex(for event: ExecutionEvent) -> Int? {
        if let sessionID = event.payload["session_id"].flatMap(UUID.init(uuidString:)),
           let exactSessionIndex = agentSessions.firstIndex(where: {
               $0.sessionID == sessionID && $0.workspaceID == event.workspaceID
           }) {
            return exactSessionIndex
        }

        if let taskID = event.taskID,
           let linkedIndex = agentSessions.firstIndex(where: {
               $0.runtimeTaskID == taskID && $0.workspaceID == event.workspaceID
           }) {
            return linkedIndex
        }

        if let parentMissionRunID = event.exactParentMissionRunID,
           let parentIndex = agentSessions.firstIndex(where: {
               $0.runtimeTaskID == parentMissionRunID && $0.workspaceID == event.workspaceID
           }) {
            return parentIndex
        }

        if let taskID = event.taskID,
           let childIndex = agentSessions.firstIndex(where: {
               $0.workspaceID == event.workspaceID
                   && $0.workspaceContext.missionTaskIDs?.contains(taskID) == true
           }) {
            return childIndex
        }

        // A task-created event contains no originating Agent Session ID. It
        // cannot safely be attached by current selection, timestamp, or
        // recency; start/resume completion links the exact returned task.
        return nil
    }

    private func syncSelectedAgentSessionFromLoadedTaskAndEvents() {
        guard let selectedTaskID,
              let task = tasks.first(where: { $0.id == selectedTaskID }) else { return }

        guard let targetIndex = agentSessions.firstIndex(where: {
            $0.runtimeTaskID == task.id && $0.workspaceID == task.workspaceID
        }) else { return }

        agentSessions[targetIndex].syncRuntimeTask(task)
        for event in AgentSessionEventScope.events(
            from: events,
            for: agentSessions[targetIndex]
        ) {
            agentSessions[targetIndex].apply(event: event)
        }
    }

    nonisolated private static func loadEngineeringActivity(rootPath: String?) async -> EngineeringActivitySnapshot {
        guard let rootPath = rootPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rootPath.isEmpty else {
            return .empty
        }

        return await Task.detached(priority: .utility) {
            do {
                let model = try CodebaseIntelligence(maxFiles: 300).discover(rootPath: rootPath)
                return EngineeringActivityProjector().snapshot(codebase: model)
            } catch {
                return EngineeringActivitySnapshot(
                    filesInspected: [],
                    changesProposed: [],
                    testsRunning: false,
                    validationResults: ["Engineering scan unavailable: \(error.localizedDescription)"],
                    evidenceRecords: [
                        EvidenceRecord(
                            action: "engineering.activity.scan",
                            source: "AppStore",
                            result: error.localizedDescription,
                            validation: .warning
                        )
                    ],
                    currentStage: nil,
                    riskLevel: .low
                )
            }
        }.value
    }

    private static func buildAgentTeamSnapshot(
        workspace: Workspace,
        task: FDETask?,
        session: AgentSession?,
        events: [ExecutionEvent],
        executionMemory: [TaskExecutionMemory],
        outcome: OutcomeRecord?
    ) -> AgentTeamSnapshot {
        guard let objective = task?.rawInput ?? session?.userGoal else {
            return .empty
        }
        let riskLevel = Self.riskLevel(for: task)
        let mission = AgentMissionBrief(
            workspaceID: workspace.id,
            objective: objective,
            system: workspace.displayName,
            environment: workspace.localAgentProjectRoot ?? workspace.localProjectRoot ?? "workspace",
            riskLevel: riskLevel
        )
        let context = SharedMissionContext(
            workspaceID: workspace.id,
            evidence: events.suffix(12).map { event in
                EvidenceRecord(
                    action: "agent_team.context:\(event.type.rawValue)",
                    source: "EventStream",
                    result: event.summary,
                    validation: .valid
                )
            },
            memory: AgentRelevantMemory(
                previousSimilarMissions: executionMemory.suffix(6).map(\.taskType),
                previousFailures: Array(executionMemory.flatMap(\.failureSignatures).suffix(8)),
                successfulSolutions: executionMemory
                    .filter { $0.state == .completed }
                    .flatMap(\.toolCommands)
                    .suffix(8)
                    .map { $0 },
                customerEnvironmentKnowledge: [
                    workspace.localProjectRoot,
                    workspace.localAgentProjectRoot
                ].compactMap { $0 }
            ),
            outcome: outcome,
            events: Array(events.suffix(12))
        )
        let engine = AgentDelegationEngine()
        let plan = engine.createDelegationPlan(
            mission: mission,
            context: context,
            requireHumanApproval: riskLevel.governanceRank >= RiskSeverity.high.governanceRank,
            approvedByHumanLead: false
        )
        return engine.teamSnapshot(plan: plan)
    }

    private static func buildTeamIntelligenceSnapshot(
        workspace: Workspace,
        task: FDETask?,
        session: AgentSession?,
        events: [ExecutionEvent],
        executionMemory: [TaskExecutionMemory],
        outcome: OutcomeRecord?
    ) -> TeamIntelligenceSnapshot {
        guard let objective = task?.rawInput ?? session?.userGoal else {
            return .empty
        }
        let riskLevel = Self.riskLevel(for: task)
        let environment = workspace.localAgentProjectRoot ?? workspace.localProjectRoot ?? workspace.displayName
        let mission = AgentMissionBrief(
            workspaceID: workspace.id,
            objective: objective,
            system: workspace.displayName,
            environment: environment,
            riskLevel: riskLevel
        )
        let context = SharedMissionContext(
            workspaceID: workspace.id,
            evidence: events.suffix(12).map { event in
                EvidenceRecord(
                    action: "team_intelligence.context:\(event.type.rawValue)",
                    source: "EventStream",
                    result: event.summary,
                    validation: .valid
                )
            },
            memory: AgentRelevantMemory(
                previousSimilarMissions: executionMemory.suffix(6).map(\.taskType),
                previousFailures: Array(executionMemory.flatMap(\.failureSignatures).suffix(8)),
                successfulSolutions: executionMemory
                    .filter { $0.state == .completed }
                    .flatMap(\.toolCommands)
                    .suffix(8)
                    .map { $0 },
                customerEnvironmentKnowledge: [
                    workspace.localProjectRoot,
                    workspace.localAgentProjectRoot
                ].compactMap { $0 }
            ),
            outcome: outcome,
            events: Array(events.suffix(12))
        )
        let requiredSkills = AgentDelegationEngine().analyzeRequiredExpertise(mission: mission, context: context)
        let planner = AgentTeamPlanner()
        let plan = planner.plan(
            input: AgentTeamPlanningInput(
                missionID: mission.id,
                objective: objective,
                complexity: missionComplexity(task: task, events: events, riskLevel: riskLevel),
                requiredSkills: requiredSkills,
                riskLevel: riskLevel,
                environment: environment,
                reputationMemory: reputationMemory(from: executionMemory, domain: environment)
            )
        )
        let proposal = AgentProposal(
            sender: .fdeLeadAgent,
            claim: "Adaptive team selected \(plan.selectedAgents.map(\.roleID.displayName).joined(separator: ", ")).",
            evidence: Array(context.evidence.prefix(4)),
            confidence: plan.confidence,
            recommendation: plan.requiresHumanLeadReview
                ? "Human FDE lead should inspect the adaptive team plan before execution."
                : "Proceed with the adaptive team plan."
        )
        let resolution = AgentConflictResolver().resolve(proposals: [proposal], reviews: [])
        return planner.snapshot(plan: plan, resolution: resolution)
    }

    private static func riskLevel(for task: FDETask?) -> RiskSeverity {
        guard let task else { return .medium }
        if task.riskScore >= 0.85 { return .critical }
        if task.riskScore >= 0.65 { return .high }
        if task.riskScore >= 0.35 { return .medium }
        return .low
    }

    private static func missionComplexity(
        task: FDETask?,
        events: [ExecutionEvent],
        riskLevel: RiskSeverity
    ) -> MissionComplexity {
        if riskLevel == .critical { return .critical }
        let planCount = task?.plan.count ?? 0
        if riskLevel == .high || planCount >= 6 || events.count >= 30 { return .complex }
        if planCount >= 3 || events.count >= 10 { return .moderate }
        return .simple
    }

    private static func reputationMemory(
        from executionMemory: [TaskExecutionMemory],
        domain: String
    ) -> AgentReputationMemory {
        executionMemory.suffix(20).reduce(.empty) { partial, memory in
            let confidence = memory.performanceScore > 1 ? memory.performanceScore / 100 : memory.performanceScore
            let success = memory.state == .completed
            let roleIDs = inferredReputationRoles(from: memory)
            return roleIDs.reduce(partial) { roleMemory, roleID in
                roleMemory.updating(
                    roleID: roleID,
                    domain: domain,
                    successful: success,
                    confidence: confidence
                )
            }
        }
    }

    private static func inferredReputationRoles(from memory: TaskExecutionMemory) -> [AgentRoleID] {
        let text = (
            [memory.taskType]
                + memory.toolCommands
                + memory.failedCommands
                + memory.failureSignatures
        )
        .joined(separator: " ")
        .lowercased()
        var roles: [AgentRoleID] = [.fdeLeadAgent]
        if !memory.toolCommands.isEmpty || text.contains("code") || text.contains("test") {
            roles.append(.codeInvestigationAgent)
        }
        if text.contains("permission") || text.contains("approval") || text.contains("auth") || text.contains("policy") {
            roles.append(.securityAgent)
        }
        if text.contains("deploy") || text.contains("cloud") || text.contains("prod") || text.contains("infra") {
            roles.append(.infrastructureAgent)
        }
        if text.contains("data") || text.contains("database") || text.contains("schema") {
            roles.append(.dataAgent)
        }
        if memory.state == .completed {
            roles.append(.documentationAgent)
        }
        return Array(Set(roles)).sorted { $0.rawValue < $1.rawValue }
    }
}
