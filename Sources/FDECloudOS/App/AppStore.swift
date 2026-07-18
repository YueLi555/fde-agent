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
    @Published var agentSessions: [AgentSession] = []
    @Published var selectedAgentSessionID: UUID?
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
    @Published var commandText = ""
    @Published var isRunning = false
    @Published var lastError: String?
    @Published private var conversationActivities: [UUID: AgentConversationActivity] = [:]
    @Published private(set) var conversationAssetProjection = AgentConversationAssetProjection.empty

    private let environment: AppEnvironment
    private let startupIssue: String?
    private let interactionController = AgentInteractionController()
    private let runtimeCoordinator: AgentRuntimeCoordinator
    private let missionClassifier = AgentMissionClassifier()
    private var cancellables = Set<AnyCancellable>()
    private var hasLoaded = false
    private var pendingSubmissionFingerprints: [UUID: Set<UInt64>] = [:]
    private let appSessionID = UUID()

    var selectedWorkspace: Workspace? {
        guard let selectedWorkspaceID else { return workspaces.first }
        return workspaces.first { $0.id == selectedWorkspaceID }
    }

    var selectedAgentSession: AgentSession? {
        if let selectedAgentSessionID,
           let selectedSession = agentSessions.first(where: { $0.sessionID == selectedAgentSessionID }) {
            return selectedSession
        }
        guard let workspaceID = selectedWorkspace?.id else { return agentSessions.first }
        return agentSessions.first { $0.workspaceID == workspaceID }
    }

    var selectedTask: FDETask? {
        if selectedAgentSession?.runtimeTaskID == nil, selectedAgentSessionID != nil {
            return nil
        }
        guard let selectedTaskID else { return tasks.first }
        return tasks.first { $0.id == selectedTaskID }
    }

    var selectedTaskPendingApprovals: [ApprovalRequest] {
        guard let selectedTaskID else { return [] }
        return pendingApprovals.filter { $0.taskID == selectedTaskID }
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
        if let selectedTaskID,
           let selectedDecision = governorDecisions.first(where: { $0.taskID == selectedTaskID }) {
            return selectedDecision
        }
        return governorDecisions.first
    }

    var latestPolicyDelta: ExecutionPolicyDelta? {
        if let selectedTaskID,
           let selectedDelta = policyDeltas.first(where: { $0.sourceTaskID == selectedTaskID }) {
            return selectedDelta
        }
        return policyDeltas.first
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
            if let storedSession = try await environment.persistence.loadSessionMetadata(),
               let workspaceID = storedSession.workspaceSession?.workspaceID,
               storedWorkspaces.contains(where: { $0.id == workspaceID }) {
                selectedWorkspaceID = selectedWorkspaceID ?? workspaceID
            } else {
                selectedWorkspaceID = selectedWorkspaceID ?? storedWorkspaces.first?.id
            }
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
            if let runtimeTaskID = selectedAgentSession?.runtimeTaskID {
                selectedTaskID = runtimeTaskID
            } else if selectedAgentSessionID != nil {
                selectedTaskID = nil
            } else if selectedTaskID == nil {
                selectedTaskID = tasks.first?.id
            }
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
            conversationAssetProjection = AgentConversationAssetProjector.project(
                workspaceID: workspace.id,
                events: workspaceEvents,
                candidatePatchManifests: candidatePatchManifests
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
        cancelCandidatePatchApprovalConfirmation()
        cancelCandidatePatchRevertConfirmation()
        cancelCandidatePatchDestructionConfirmation()
        selectedTaskID = taskID
        if let taskID,
           let session = agentSessions.first(where: { $0.runtimeTaskID == taskID }) {
            selectedAgentSessionID = session.sessionID
        }
        Task { await refreshSelectedTaskDetails() }
    }

    func selectAgentSession(_ sessionID: UUID?) {
        cancelCandidatePatchApprovalConfirmation()
        cancelCandidatePatchRevertConfirmation()
        cancelCandidatePatchDestructionConfirmation()
        selectedAgentSessionID = sessionID
        selectedTaskID = agentSessions.first { $0.sessionID == sessionID }?.runtimeTaskID
        Task { await refreshSelectedTaskDetails() }
    }

    func submitCommand() {
        guard let workspace = selectedWorkspace else { return }
        let input = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }

        guard hasRequiredProjectScope(for: input, workspace: workspace) else {
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
            let requestID = UUID()
            let scope = activityScope(for: input, session: agentSessions[index])
            agentSessions[index].appendUserMessage(input)
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
            return
        }

        let agentSessionID = createAgentSession(goal: input, workspace: workspace)
        let requestID = UUID()
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

        Task {
            do {
                guard let index = agentSessions.firstIndex(where: { $0.sessionID == agentSessionID }) else { return }
                var session = agentSessions[index]
                let result = try await runtimeCoordinator.startMission(
                    input: input,
                    workspace: workspace,
                    session: &session,
                    runtime: environment.runtime,
                    userMessageID: requestID
                )
                agentSessions[index] = session
                if let task = result.task {
                    selectedTaskID = task.id
                    linkRuntimeTask(task, to: agentSessionID)
                }
                finishActivity(for: agentSessionID, requestID: requestID, result: result)
                await refresh()
            } catch {
                failAgentSession(agentSessionID, with: error)
                failActivity(for: agentSessionID, requestID: requestID, scope: scope, error: error)
                lastError = error.localizedDescription
            }
            endSubmission(fingerprint, sessionID: agentSessionID)
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
        if approval.targetKind == .candidatePatchPlan {
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
                if let event = applyApprovalGranted(approval.id) {
                    try await recordInteractionEvent(event, workspace: workspace, taskID: approval.taskID)
                }
                await refresh()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func confirmCandidatePatchApproval(_ confirmation: CandidatePatchApprovalConfirmation) {
        guard confirmation == candidatePatchApprovalConfirmation,
              let workspace = selectedWorkspace,
              let context = candidatePatchApprovalUIContext(for: confirmation.approvalRequestID) else {
            lastError = "The Candidate Patch approval is no longer the visible pending request."
            cancelCandidatePatchApprovalConfirmation()
            return
        }
        let source = candidatePatchApprovalInvocationSource()
        isConfirmingCandidatePatchApproval = true
        Task {
            defer { isConfirmingCandidatePatchApproval = false }
            do {
                _ = try await environment.runtime.confirmCandidatePatchApproval(
                    confirmation,
                    workspace: workspace,
                    context: context,
                    source: source,
                    reason: "Confirmed from Candidate Patch approval sheet"
                )
                candidatePatchApprovalConfirmation = nil
                if let event = applyApprovalGranted(confirmation.approvalRequestID) {
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
                let context = CandidatePatchRevertUIContext(
                    currentWorkspaceID: workspace.id,
                    currentTaskID: requestingTask.id,
                    visiblePatchID: patchID,
                    visibleSandboxID: sandboxID,
                    authenticatedLocalSessionID: authenticatedLocalSessionID,
                    appSessionID: appSessionID
                )
                candidatePatchRevertConfirmation = try await environment.runtime
                    .beginCandidatePatchRevertConfirmation(
                        patchID: patchID,
                        sandboxID: sandboxID,
                        workspace: workspace,
                        context: context,
                        source: source
                    )
                await refresh()
            } catch {
                candidatePatchRevertConfirmation = nil
                lastError = error.localizedDescription
                await refresh()
            }
        }
    }

    func prepareGeneratedTestPlan(_ snapshot: CandidatePatchActivitySnapshot) {
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
                selectedTaskID = task.id
                if let selectedAgentSessionID {
                    linkRuntimeTask(task, to: selectedAgentSessionID)
                }
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
              let authenticatedLocalSessionID = session?.id else {
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
        guard candidatePatchDestructionConfirmation == nil,
              let workspace = selectedWorkspace,
              let taskID = selectedTaskID,
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
                candidatePatchDestructionConfirmation = try await environment.runtime
                    .beginCandidatePatchSandboxDestructionConfirmation(
                        patchID: patchID,
                        sandboxID: sandboxID,
                        workspace: workspace,
                        context: context,
                        source: source
                    )
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
              let authenticatedLocalSessionID = session?.id else {
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
              let context = candidatePatchApprovalUIContext(for: approval.id) else {
            lastError = "The Candidate Patch approval is not the current visible pending request."
            return
        }
        Task {
            do {
                candidatePatchApprovalConfirmation = try await environment.runtime
                    .beginCandidatePatchApprovalConfirmation(
                        approval.id,
                        workspace: workspace,
                        context: context,
                        source: source
                    )
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
              let taskID = selectedTaskID,
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

    func reject(_ approval: ApprovalRequest) {
        guard let workspace = selectedWorkspace else { return }
        Task {
            do {
                _ = try await environment.runtime.rejectApprovalRequest(
                    approval.id,
                    workspace: workspace,
                    reason: "Rejected from Agent Workspace"
                )
                if let event = applyApprovalRejected(approval.id) {
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
        guard let workspace = selectedWorkspace else { return }
        Task {
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
        if event.type == .taskCreated, let taskID = event.taskID, isRunning || selectedTaskID == nil {
            selectedTaskID = taskID
            events = []
            replayFrames = []
            missionReplay = nil
        }
        if shouldAppendLiveEvent(event) {
            appendLiveEvent(event)
        }
        Task { await refresh() }
    }

    private func shouldAppendLiveEvent(_ event: ExecutionEvent) -> Bool {
        if let selectedTaskID {
            return event.taskID == selectedTaskID
                || event.payload["session_id"] == selectedAgentSessionID?.uuidString
        }

        guard let selectedAgentSession else {
            return event.taskID == nil
        }

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
            events = try await environment.persistence.loadEvents(workspaceID: workspace.id, taskID: selectedTaskID)
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
    private func createAgentSession(goal: String, workspace: Workspace) -> UUID {
        let session = AgentSession(workspace: workspace, userGoal: goal)
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
              !agentSessions.contains(where: { $0.workspaceID == workspace.id }),
              let sourceTaskID = conversationAssetProjection.candidatePatches
                .compactMap(\.sourceCandidatePatchTaskID)
                .compactMap(UUID.init(uuidString:))
                .last,
              let task = tasks.first(where: { $0.id == sourceTaskID }) else {
            return
        }
        let taskEvents = workspaceEvents.filter { $0.taskID == task.id }
        let conversation = AgentResponseComposer.replayConversation(
            sessionID: task.id,
            workspaceID: workspace.id,
            userRequest: task.rawInput,
            events: taskEvents,
            createdAt: task.createdAt
        )
        var workspaceContext = AgentWorkspaceContext(workspace: workspace)
        workspaceContext.missionTaskIDs = conversationAssetProjection.candidatePatches
            .compactMap(\.sourceCandidatePatchTaskID)
            .compactMap(UUID.init(uuidString:))
        workspaceContext.linkRuntimeTask(task)
        let restored = AgentSession(
            sessionID: task.id,
            workspaceID: workspace.id,
            userGoal: task.rawInput,
            createdAt: task.createdAt,
            currentState: .completed,
            interactionState: .completed,
            currentPlan: task.plan,
            conversation: conversation,
            workspaceContext: workspaceContext
        )
        agentSessions.insert(restored, at: 0)
        selectedAgentSessionID = restored.sessionID
        selectedTaskID = task.id
    }

    private func linkRuntimeTask(_ task: FDETask, to sessionID: UUID) {
        guard let index = agentSessions.firstIndex(where: { session in
            session.sessionID == sessionID || session.runtimeTaskID == task.id
        }) else { return }

        agentSessions[index].syncRuntimeTask(task)
        selectedAgentSessionID = agentSessions[index].sessionID
    }

    private func failAgentSession(_ sessionID: UUID, with error: Error) {
        guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        agentSessions[index].fail(with: error)
    }

    func selectDecision(messageID: UUID, optionID: String) {
        guard let workspace = selectedWorkspace,
              let sessionID = selectedAgentSessionID,
              let event = applyDecisionSelection(messageID: messageID, optionID: optionID, to: sessionID) else {
            return
        }
        let decision = event.payload["decision"] ?? optionID
        Task {
            do {
                try await recordInteractionEvent(event, workspace: workspace, taskID: selectedTaskID)
                if let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }),
                   agentSessions[index].runtimeTaskID == nil {
                    var session = agentSessions[index]
                    let result = try await runtimeCoordinator.resumeMissionFromSelectedDecision(
                        decision: decision,
                        workspace: workspace,
                        session: &session,
                        runtime: environment.runtime
                    )
                    agentSessions[index] = session
                    if let task = result.task {
                        selectedTaskID = task.id
                        linkRuntimeTask(task, to: sessionID)
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
              let event = applyPlanApproval(to: sessionID) else {
            return
        }
        Task {
            do {
                try await recordInteractionEvent(event, workspace: workspace, taskID: selectedTaskID)
                if let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }),
                   shouldStartApprovedImplementation(for: agentSessions[index]) {
                    var session = agentSessions[index]
                    let result = try await runtimeCoordinator.startApprovedImplementation(
                        workspace: workspace,
                        session: &session,
                        runtime: environment.runtime
                    )
                    agentSessions[index] = session
                    if let task = result.task {
                        selectedTaskID = task.id
                        linkRuntimeTask(task, to: sessionID)
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
              let event = applyPlanModificationRequest(to: sessionID) else {
            return
        }
        Task {
            do {
                try await recordInteractionEvent(event, workspace: workspace, taskID: selectedTaskID)
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
        guard let workspace = selectedWorkspace else {
            return
        }
        Task {
            do {
                guard let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return }
                var session = agentSessions[index]
                let result = try await runtimeCoordinator.resumeMission(
                    reply: content,
                    workspace: workspace,
                    session: &session,
                    runtime: environment.runtime,
                    continuation: continuation,
                    userMessageAlreadyAppended: true,
                    userMessageID: requestID
                )
                agentSessions[index] = session
                if let task = result.task {
                    selectedTaskID = task.id
                    linkRuntimeTask(task, to: sessionID)
                }
                finishActivity(for: sessionID, requestID: requestID, result: result)
                await refresh()
            } catch {
                let scope = conversationActivities[sessionID]?.scope ?? .engineeringTask
                failActivity(for: sessionID, requestID: requestID, scope: scope, error: error)
                lastError = error.localizedDescription
            }
            endSubmission(inputFingerprint, sessionID: sessionID)
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

    private func applyApprovalGranted(_ approvalID: UUID) -> AgentInteractionRuntimeEvent? {
        guard let sessionID = selectedAgentSessionID,
              let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
        return interactionController.approvalGranted(session: &agentSessions[index], approvalID: approvalID)
    }

    private func applyApprovalRejected(_ approvalID: UUID) -> AgentInteractionRuntimeEvent? {
        guard let sessionID = selectedAgentSessionID,
              let index = agentSessions.firstIndex(where: { $0.sessionID == sessionID }) else { return nil }
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
                activity.labelOverride = "Unable to reach the configured AI provider."
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
            case .created, .planned, .running, .waiting, .pendingApproval:
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

    private func isClosed(_ session: AgentSession) -> Bool {
        session.currentState == .completed
            || session.currentState == .failed
            || session.interactionState == .completed
            || session.interactionState == .failed
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
        selectedAgentSessionID = agentSessions[index].sessionID
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
        LLMNarrationDebugLog.write("appstore_enrichment_started event_id=\(event.id.uuidString) event_type=\(event.type.rawValue)")
        let message = await environment.agentResponseComposer.liveMessage(
            for: event,
            history: agentSessions[index].conversation.messages
        )
        var updatedSession = agentSessions[index]
        let replaced = updatedSession.replaceMessage(relatedEventID: event.id, with: message)
        if replaced {
            agentSessions[index] = updatedSession
        }
        LLMNarrationDebugLog.write(
            "ui_message_replaced event_id=\(event.id.uuidString) replaced=\(replaced) message_type=\(message.type.rawValue)"
        )
    }

    private func agentSessionIndex(for event: ExecutionEvent) -> Int? {
        if let taskID = event.taskID,
           let linkedIndex = agentSessions.firstIndex(where: { $0.runtimeTaskID == taskID }) {
            return linkedIndex
        }

        guard event.type == .taskCreated,
              let selectedAgentSessionID,
              let pendingIndex = agentSessions.firstIndex(where: { session in
                  session.sessionID == selectedAgentSessionID
                      && session.workspaceID == event.workspaceID
                      && (session.runtimeTaskID == nil || isClosed(session))
              }) else {
            return nil
        }

        return pendingIndex
    }

    private func syncSelectedAgentSessionFromLoadedTaskAndEvents() {
        guard let selectedTaskID,
              let task = tasks.first(where: { $0.id == selectedTaskID }) else { return }

        let targetIndex = agentSessions.firstIndex(where: { $0.runtimeTaskID == task.id })
            ?? selectedAgentSessionID.flatMap { sessionID in
                agentSessions.firstIndex { $0.sessionID == sessionID }
            }
        guard let targetIndex else { return }

        agentSessions[targetIndex].syncRuntimeTask(task)
        for event in events {
            agentSessions[targetIndex].apply(event: event)
        }
        selectedAgentSessionID = agentSessions[targetIndex].sessionID
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
