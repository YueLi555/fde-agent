import Foundation

enum NormalChatLifecycle: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case thinking
    case completed
    case failed
}

enum AgentConversationActivityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case idle
    case thinking
    case preparingTask
    case compilingContext
    case planning
    case repairingPlan
    case validatingPlan
    case inspectingProject
    case listingDirectory
    case searchingFiles
    case searchingCode
    case readingFile
    case analyzingEvidence
    case validatingLegacySource
    case confirmingCanonicalLegacyRoot
    case checkingLocalSourceAvailability
    case creatingSourceSnapshot
    case creatingIsolatedSandbox
    case copyingApprovedSourceFiles
    case excludingSensitiveFiles
    case verifyingFileHashes
    case checkingPathContainment
    case confirmingSourceIsolation
    case confirmingOriginalLegacyUnchanged
    case sandboxReady
    case sandboxCreationBlocked
    case destroyingSandbox
    case finalizingSandboxAcceptance
    case preparingCandidatePatch
    case waitingCandidatePatchApproval
    case applyingCandidatePatch
    case buildingUnifiedDiff
    case candidatePatchReady
    case candidatePatchBlocked
    case revertingCandidatePatch
    case candidatePatchReverted
    case sandboxDestroyed
    case preparingFinalAnswer
    case preparingPartialAnswer
    case retryingProvider
    case blocked
    case failed
    case partial
    case completed

    var priority: Int {
        switch self {
        case .failed, .candidatePatchBlocked: return 20
        case .sandboxCreationBlocked: return 19
        case .blocked: return 18
        case .partial: return 17
        case .candidatePatchReady, .candidatePatchReverted, .sandboxDestroyed: return 17
        case .sandboxReady: return 16
        case .completed: return 15
        case .destroyingSandbox, .finalizingSandboxAcceptance, .buildingUnifiedDiff: return 14
        case .preparingFinalAnswer: return 13
        case .preparingPartialAnswer: return 12
        case .retryingProvider: return 11
        case .confirmingSourceIsolation, .checkingPathContainment, .verifyingFileHashes,
             .applyingCandidatePatch, .revertingCandidatePatch: return 10
        case .confirmingOriginalLegacyUnchanged: return 10
        case .excludingSensitiveFiles, .copyingApprovedSourceFiles, .creatingIsolatedSandbox,
             .creatingSourceSnapshot, .checkingLocalSourceAvailability,
             .confirmingCanonicalLegacyRoot, .validatingLegacySource: return 9
        case .analyzingEvidence: return 8
        case .readingFile: return 7
        case .searchingCode: return 6
        case .searchingFiles: return 5
        case .listingDirectory: return 4
        case .inspectingProject, .validatingPlan, .repairingPlan, .planning,
             .preparingCandidatePatch, .waitingCandidatePatchApproval: return 3
        case .compilingContext, .preparingTask: return 2
        case .thinking: return 2
        case .idle: return 1
        }
    }

    var isTerminal: Bool {
        switch self {
        case .blocked, .failed, .partial, .completed, .sandboxReady, .sandboxCreationBlocked,
             .candidatePatchReady, .candidatePatchBlocked, .candidatePatchReverted, .sandboxDestroyed:
            return true
        default:
            return false
        }
    }

    var isVisible: Bool {
        self != .idle && self != .completed
    }

    var isAnimated: Bool {
        isVisible && !isTerminal
    }
}

enum AgentConversationActivityScope: String, Codable, Hashable, Sendable {
    case normalChat
    case engineeringTask
}

struct AgentConversationActivityMetadata: Equatable, Sendable {
    var dialogID: UUID
    var taskID: UUID?
    var latestEventID: UUID?
    var workspaceIdentity: String?
    var relativePath: String?
    var safeToolName: String?
    var evidenceCount: Int
    var satisfiedRequirementCount: Int?
    var unsatisfiedRequirementCount: Int?
    var elapsedMilliseconds: Int?
    var remainingMilliseconds: Int?
    var blockerReason: String?
    var retryAttempt: Int?
    var aiAssessment: AIAssessmentActivitySnapshot?
    var sandbox: SandboxActivitySnapshot?
    var candidatePatch: CandidatePatchActivitySnapshot?

    init(
        dialogID: UUID,
        taskID: UUID? = nil,
        latestEventID: UUID? = nil,
        workspaceIdentity: String? = nil,
        relativePath: String? = nil,
        safeToolName: String? = nil,
        evidenceCount: Int = 0,
        satisfiedRequirementCount: Int? = nil,
        unsatisfiedRequirementCount: Int? = nil,
        elapsedMilliseconds: Int? = nil,
        remainingMilliseconds: Int? = nil,
        blockerReason: String? = nil,
        retryAttempt: Int? = nil,
        aiAssessment: AIAssessmentActivitySnapshot? = nil,
        sandbox: SandboxActivitySnapshot? = nil,
        candidatePatch: CandidatePatchActivitySnapshot? = nil
    ) {
        self.dialogID = dialogID
        self.taskID = taskID
        self.latestEventID = latestEventID
        self.workspaceIdentity = workspaceIdentity
        self.relativePath = relativePath
        self.safeToolName = safeToolName
        self.evidenceCount = evidenceCount
        self.satisfiedRequirementCount = satisfiedRequirementCount
        self.unsatisfiedRequirementCount = unsatisfiedRequirementCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.remainingMilliseconds = remainingMilliseconds
        self.blockerReason = blockerReason
        self.retryAttempt = retryAttempt
        self.aiAssessment = aiAssessment
        self.sandbox = sandbox
        self.candidatePatch = candidatePatch
    }
}

struct AgentConversationActivity: Identifiable, Equatable, Sendable {
    var requestID: UUID
    var startedAt: Date
    var scope: AgentConversationActivityScope
    var kind: AgentConversationActivityKind
    var metadata: AgentConversationActivityMetadata
    var labelOverride: String?

    var id: String {
        [
            metadata.dialogID.uuidString,
            requestID.uuidString,
            metadata.taskID?.uuidString ?? "chat"
        ].joined(separator: ":")
    }

    var label: String {
        labelOverride ?? AgentConversationActivityCopy.label(for: kind, metadata: metadata)
    }

    func shouldAnimate(reduceMotion: Bool) -> Bool {
        kind.isAnimated && !reduceMotion
    }

    static func local(
        requestID: UUID,
        dialogID: UUID,
        scope: AgentConversationActivityScope,
        startedAt: Date = Date()
    ) -> AgentConversationActivity {
        AgentConversationActivity(
            requestID: requestID,
            startedAt: startedAt,
            scope: scope,
            kind: scope == .normalChat ? .thinking : .preparingTask,
            metadata: AgentConversationActivityMetadata(dialogID: dialogID)
        )
    }
}

enum AgentConversationActivityCopy {
    static func label(
        for kind: AgentConversationActivityKind,
        metadata: AgentConversationActivityMetadata
    ) -> String {
        if let assessment = metadata.aiAssessment, !kind.isTerminal, kind != .idle {
            return "\(assessment.missionState.rawValue)…"
        }
        switch kind {
        case .idle, .completed:
            return ""
        case .thinking:
            return "Thinking…"
        case .preparingTask:
            return "Preparing task…"
        case .compilingContext:
            switch metadata.workspaceIdentity?.lowercased() {
            case let value? where value.contains("legacy"):
                return "Inspecting Legacy workspace context…"
            case let value? where value.contains("agent"):
                return "Inspecting Agent workspace context…"
            default:
                return "Compiling workspace context…"
            }
        case .planning:
            return "Planning the investigation…"
        case .repairingPlan:
            return "Repairing the tool plan…"
        case .validatingPlan:
            return "Validating the tool plan…"
        case .inspectingProject:
            switch metadata.workspaceIdentity?.lowercased() {
            case let value? where value.contains("legacy"):
                return "Inspecting Legacy workspace project structure…"
            case let value? where value.contains("agent"):
                return "Inspecting Agent workspace project structure…"
            default:
                return metadata.safeToolName == nil
                    ? "Running a workspace inspection…"
                    : "Inspecting project structure…"
            }
        case .listingDirectory:
            return "Listing project files…"
        case .searchingFiles:
            return "Searching files…"
        case .searchingCode:
            return "Searching source code…"
        case .readingFile:
            if let path = metadata.relativePath {
                return "Reading \(path)…"
            }
            return "Reading a workspace file…"
        case .analyzingEvidence:
            return metadata.evidenceCount > 0
                ? "Analyzing evidence · \(metadata.evidenceCount) findings"
                : "Analyzing evidence…"
        case .validatingLegacySource:
            return "Validating selected Legacy workspace…"
        case .confirmingCanonicalLegacyRoot:
            return "Confirming canonical Legacy root…"
        case .checkingLocalSourceAvailability:
            return "Checking local source availability…"
        case .creatingSourceSnapshot:
            return "Creating source snapshot…"
        case .creatingIsolatedSandbox:
            return "Creating isolated Sandbox…"
        case .copyingApprovedSourceFiles:
            return "Copying approved source files…"
        case .excludingSensitiveFiles:
            return "Excluding sensitive files…"
        case .verifyingFileHashes:
            return "Verifying file hashes…"
        case .checkingPathContainment:
            return "Checking path containment…"
        case .confirmingSourceIsolation:
            return "Confirming source isolation…"
        case .confirmingOriginalLegacyUnchanged:
            return "Confirming original Legacy unchanged…"
        case .sandboxReady:
            return "Sandbox ready"
        case .sandboxCreationBlocked:
            return "Sandbox creation blocked"
        case .destroyingSandbox:
            return "Destroying Sandbox…"
        case .finalizingSandboxAcceptance:
            return "Finalizing Sandbox acceptance…"
        case .preparingCandidatePatch:
            return "Preparing Candidate Patch plan…"
        case .waitingCandidatePatchApproval:
            return "Waiting for human approval"
        case .applyingCandidatePatch:
            return "Applying change in isolated Sandbox…"
        case .buildingUnifiedDiff:
            return "Building unified diff…"
        case .candidatePatchReady:
            return "Candidate Patch ready"
        case .candidatePatchBlocked:
            return "Candidate Patch blocked"
        case .revertingCandidatePatch:
            return "Reverting Candidate Patch…"
        case .candidatePatchReverted:
            return "Candidate Patch reverted"
        case .sandboxDestroyed:
            return "Sandbox destroyed"
        case .preparingFinalAnswer:
            return "Preparing grounded findings…"
        case .preparingPartialAnswer:
            if let count = metadata.unsatisfiedRequirementCount, count > 0 {
                return "Preparing partial findings · \(count) areas remain"
            }
            return "Preparing partial findings…"
        case .retryingProvider:
            return "Connection interrupted · retrying once…"
        case .blocked:
            return "Blocked · \(metadata.blockerReason ?? "the task needs attention")"
        case .failed:
            return "Failed · \(metadata.blockerReason ?? "the task could not be completed")"
        case .partial:
            if let count = metadata.unsatisfiedRequirementCount, count > 0 {
                return "Partial result · \(count) areas remain"
            }
            return "Partial result"
        }
    }

    static func toolActivity(
        command: String?,
        event: ExecutionEvent,
        metadata: inout AgentConversationActivityMetadata
    ) -> AgentConversationActivityKind {
        let safeCommand = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        metadata.safeToolName = safeCommand.flatMap(safeToolName)
        switch safeCommand {
        case "engineering.inspect_project":
            return .inspectingProject
        case "engineering.list_directory":
            return .listingDirectory
        case "engineering.search_files":
            return .searchingFiles
        case "engineering.search_code":
            return .searchingCode
        case "engineering.read_file":
            metadata.relativePath = safeRelativePath(
                event.payload["normalized_relative_path"]
                    ?? event.payload["target_path"]
                    ?? event.payload["path"]
            )
            return .readingFile
        default:
            return .inspectingProject
        }
    }

    static func sandboxActivity(_ phase: SandboxRuntimeActivityPhase) -> AgentConversationActivityKind {
        switch phase {
        case .validatingSelectedLegacyWorkspace, .validatingLegacySource:
            return .validatingLegacySource
        case .confirmingCanonicalLegacyRoot:
            return .confirmingCanonicalLegacyRoot
        case .checkingLocalSourceAvailability:
            return .checkingLocalSourceAvailability
        case .creatingSourceSnapshot:
            return .creatingSourceSnapshot
        case .creatingIsolatedSandbox:
            return .creatingIsolatedSandbox
        case .copyingApprovedFiles, .copyingApprovedSourceFiles:
            return .copyingApprovedSourceFiles
        case .excludingSensitiveFiles:
            return .excludingSensitiveFiles
        case .verifyingSHA256, .verifyingFileHashes:
            return .verifyingFileHashes
        case .verifyingFilesystemIsolation, .checkingPathContainment:
            return .checkingPathContainment
        case .confirmingSourceIsolation:
            return .confirmingSourceIsolation
        case .confirmingOriginalLegacyUnchanged:
            return .confirmingOriginalLegacyUnchanged
        case .sandboxReady:
            return .sandboxReady
        case .sandboxCreationBlocked:
            return .sandboxCreationBlocked
        case .destroyingSandbox:
            return .destroyingSandbox
        case .finalizingSandboxAcceptance:
            return .finalizingSandboxAcceptance
        }
    }

    static func safeRelativePath(_ value: String?) -> String? {
        guard var path = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              path != ".",
              path.count <= 240,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        while path.hasPrefix("./") {
            path.removeFirst(2)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.isEmpty,
              !components.contains(".."),
              !components.contains("."),
              !components.contains(where: isSensitivePathComponent) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    static func blockerReason(_ rawValue: String?, failure: Bool = false) -> String {
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalized.contains("file access denied")
            || normalized.contains("permission denied")
            || normalized == "file_access_denied" {
            return "file access was denied"
        }
        if normalized.contains("provider_transport")
            || normalized.contains("connection_lost")
            || normalized.contains("connection lost")
            || normalized.contains("provider_request_failed") {
            return "the AI connection was interrupted"
        }
        if normalized.contains("provider_unavailable") {
            return "no AI provider is available"
        }
        switch normalized {
        case SafeSandboxAcceptanceFailureCategory.workspaceNotSelected.rawValue:
            return "no Legacy workspace is selected"
        case SafeSandboxAcceptanceFailureCategory.workspaceRootMismatch.rawValue:
            return "the asserted root does not match the selected Legacy workspace"
        case SafeSandboxAcceptanceFailureCategory.sourceFileRequiresExternalHydration.rawValue:
            return "a source file requires external hydration"
        case SafeSandboxAcceptanceFailureCategory.sourceChanged.rawValue:
            return "the Legacy source changed during acceptance"
        case SafeSandboxAcceptanceFailureCategory.sandboxCopyMismatch.rawValue:
            return "the Sandbox copy did not match the source manifest"
        case SafeSandboxAcceptanceFailureCategory.pathContainmentFailed.rawValue:
            return "a Sandbox path failed containment validation"
        case SafeSandboxAcceptanceFailureCategory.insufficientDiskSpace.rawValue:
            return "there is insufficient disk space for the isolated copy"
        case SafeSandboxAcceptanceFailureCategory.sandboxDestructionFailed.rawValue:
            return "the Sandbox could not be destroyed safely"
        case SafeSandboxAcceptanceFailureCategory.agentWorkspaceRejected.rawValue:
            return "the Agent workspace cannot be used as Legacy source"
        case "planner_timeout":
            return "the planning request timed out"
        case "provider_transport_failed", "provider_request_failed", "connection_lost":
            return "the AI connection was interrupted"
        case "planner_provider_unavailable", "provider_unavailable", "chat_provider_unavailable":
            return "no AI provider is available"
        case "workspace_empty":
            return "the selected workspace is empty"
        case "workspace_not_found":
            return "the selected workspace could not be found"
        case "workspace_scope_mismatch":
            return "the requested path is outside the selected workspace"
        case "working_directory_outside_workspace":
            return "the tool plan targeted a directory outside the selected workspace"
        case "no_executable_tool_step":
            return "no valid inspection action was produced"
        case "invalid_next_action":
            return "the next inspection action was invalid"
        case "multiple_next_actions":
            return "the AI returned more than one next action"
        case "next_action_repair_failed", "repair_failed":
            return "the next inspection action could not be repaired"
        case "planner_output_invalid", "provider_output_invalid":
            return "the inspection plan was invalid"
        case "inspection_cancelled", "hard_cancellation", "cancelled":
            return "the task was cancelled before completion"
        default:
            return failure ? "the task could not be completed" : "the task needs attention"
        }
    }

    private static func safeToolName(_ value: String) -> String? {
        let allowed = [
            "engineering.inspect_project",
            "engineering.list_directory",
            "engineering.search_files",
            "engineering.search_code",
            "engineering.read_file"
        ]
        return allowed.contains(value) ? value : nil
    }

    private static func isSensitivePathComponent(_ component: String) -> Bool {
        let value = component.lowercased()
        return value == ".env"
            || value.hasPrefix(".env.")
            || value.contains("secret")
            || value.contains("credential")
            || value.contains("private_key")
            || value.contains("access_token")
    }
}

struct AgentConversationActivityReducer: Sendable {
    static func activity(
        session: AgentSession,
        events: [ExecutionEvent],
        localActivity: AgentConversationActivity?
    ) -> AgentConversationActivity? {
        if let localActivity, localActivity.scope == .normalChat {
            return localActivity
        }

        let taskID: UUID?
        if let localActivity {
            taskID = localActivity.metadata.taskID
                ?? events
                    .filter { $0.timestamp >= localActivity.startedAt }
                    .sorted(by: eventOrder)
                    .reversed()
                    .compactMap(\.taskID)
                    .first
        } else {
            taskID = session.runtimeTaskID ?? events.reversed().compactMap(\.taskID).first
        }
        let taskEvents = deduplicated(events).filter { event in
            guard let taskID else { return event.taskID == nil }
            return event.taskID == taskID
        }
        let scopedEvents = localActivity.map { local in
            taskEvents.filter { $0.timestamp >= local.startedAt }
        } ?? taskEvents
        let requestID = localActivity?.requestID ?? session.sessionID
        let base = localActivity ?? AgentConversationActivity(
            requestID: requestID,
            startedAt: events.first?.timestamp ?? session.createdAt,
            scope: .engineeringTask,
            kind: .idle,
            metadata: AgentConversationActivityMetadata(
                dialogID: session.sessionID,
                taskID: taskID
            )
        )
        var current = base
        current.metadata.taskID = taskID
        for event in scopedEvents.sorted(by: eventOrder) {
            current = reduce(current, event: event, successfulEvidenceCount: evidenceCount(in: scopedEvents, through: event.sequence))
        }

        if let terminal = terminalKind(
            session: session,
            events: scopedEvents,
            includesSessionSnapshot: localActivity == nil
        ),
           terminal.priority > current.kind.priority || !current.kind.isTerminal {
            current.kind = terminal
            current.metadata.blockerReason = terminalReason(for: terminal, events: scopedEvents)
        }
        return current
    }

    static func reduce(
        _ current: AgentConversationActivity,
        event: ExecutionEvent,
        successfulEvidenceCount: Int? = nil
    ) -> AgentConversationActivity {
        guard event.taskID == nil
                || current.metadata.taskID == nil
                || event.taskID == current.metadata.taskID else {
            return current
        }

        var next = current
        next.metadata.taskID = event.taskID ?? next.metadata.taskID
        next.metadata.latestEventID = event.id
        next.metadata.workspaceIdentity = workspaceIdentity(from: event) ?? next.metadata.workspaceIdentity
        next.metadata.evidenceCount = integer(event.payload["evidence_count"])
            ?? successfulEvidenceCount
            ?? next.metadata.evidenceCount
        next.metadata.satisfiedRequirementCount = integer(event.payload["evidence_requirements_satisfied_count"])
            ?? next.metadata.satisfiedRequirementCount
        next.metadata.unsatisfiedRequirementCount = integer(event.payload["evidence_requirements_unsatisfied_count"])
            ?? next.metadata.unsatisfiedRequirementCount
        next.metadata.elapsedMilliseconds = integer(event.payload["elapsed_ms"])
            ?? next.metadata.elapsedMilliseconds
        next.metadata.remainingMilliseconds = integer(event.payload["remaining_ms"])
            ?? next.metadata.remainingMilliseconds
        next.metadata.retryAttempt = integer(event.payload["retry_attempt"])
            ?? integer(event.payload["attempt"])
            ?? next.metadata.retryAttempt
        if let assessment = AIAssessmentActivitySnapshot(eventPayload: event.payload) {
            next.metadata.aiAssessment = assessment
        } else if var assessment = next.metadata.aiAssessment {
            assessment.evidenceCount = next.metadata.evidenceCount
            next.metadata.aiAssessment = assessment
        }
        if let sandbox = SandboxActivitySnapshot(eventPayload: event.payload) {
            next.metadata.sandbox = sandbox
        }
        if let candidatePatch = CandidatePatchActivitySnapshot(eventPayload: event.payload) {
            next.metadata.candidatePatch = candidatePatch
        }
        next.labelOverride = nil

        if event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" {
            next.kind = .partial
            return next
        }
        if isCompleted(event) {
            next.kind = .completed
            return next
        }
        if isFailed(event) {
            next.kind = .failed
            next.metadata.blockerReason = AgentConversationActivityCopy.blockerReason(
                event.payload["blocker_reason"] ?? event.payload["error"],
                failure: true
            )
            return next
        }
        if isBlocked(event) {
            next.kind = .blocked
            next.metadata.blockerReason = AgentConversationActivityCopy.blockerReason(
                event.payload["blocker_reason"] ?? event.payload["provider_diagnostic"]
            )
            return next
        }

        let lifecycle = event.payload["lifecycle_event"] ?? ""
        let providerStage = event.payload["provider_stage"] ?? ""
        if let rawPhase = event.payload["sandbox_activity_phase"],
           let phase = SandboxRuntimeActivityPhase(rawValue: rawPhase) {
            next.kind = AgentConversationActivityCopy.sandboxActivity(phase)
            next.labelOverride = "\(phase.rawValue)…"
            return next
        }
        if let rawPhase = event.payload["candidate_patch_activity_phase"],
           let phase = CandidatePatchActivityPhase(rawValue: rawPhase) {
            next.kind = candidatePatchActivity(phase)
            next.labelOverride = phase.rawValue + (phase == .candidatePatchReady || phase == .candidatePatchBlocked ? "" : "…")
            return next
        }
        if lifecycle == "PROVIDER_RETRY_REQUESTED" || event.payload["retry"] == "true" {
            next.kind = .retryingProvider
            return next
        }
        if lifecycle == "PLAN_REPAIR_REQUESTED" || providerStage == "repair" || providerStage == "readiness_repair" {
            next.kind = .repairingPlan
            return next
        }
        if lifecycle == "PLAN_READINESS_CHECKED" || lifecycle == "PLAN_REPAIRED" {
            next.kind = .validatingPlan
            if event.payload["is_ready"] == "true"
                || event.payload["plan_execution_ready"] == "true"
                || event.payload["readiness"] == "ready" {
                next.labelOverride = "Plan is ready"
            }
            return next
        }
        if providerStage == "planner" || providerStage == "planning" {
            next.kind = .planning
            return next
        }
        if providerStage == "observation_next_action" || providerStage == "observation_next_action_repair" {
            next.kind = .analyzingEvidence
            return next
        }
        if providerStage == "final_grounded_answer" || providerStage == "graceful_finalization" {
            next.kind = isPartialFinalization(event) ? .preparingPartialAnswer : .preparingFinalAnswer
            return next
        }

        switch event.type {
        case .taskCreated:
            next.kind = .preparingTask
        case .contextCompiled:
            next.kind = .compilingContext
        case .planGenerated:
            next.kind = .validatingPlan
        case .toolCalled:
            next.kind = AgentConversationActivityCopy.toolActivity(
                command: event.payload["command"] ?? event.payload["tool_name"],
                event: event,
                metadata: &next.metadata
            )
        case .stepExecuted, .connectorExecuted, .nodeExecutionCompleted,
             .executionResponseReceived, .workerTaskCompleted:
            next.kind = .analyzingEvidence
        case .recoveryAttempted:
            next.kind = .retryingProvider
        case .stateUpdated:
            if lifecycle == "GRACEFUL_FINALIZATION_STARTED"
                || lifecycle == "GRACEFUL_FINALIZATION_FALLBACK"
                || lifecycle == "INSPECTION_COMPLETED" {
                next.kind = isPartialFinalization(event) ? .preparingPartialAnswer : .preparingFinalAnswer
            } else if lifecycle == "OBSERVATION_RECORDED" {
                next.kind = .analyzingEvidence
            }
        default:
            break
        }
        return next
    }

    private static func candidatePatchActivity(
        _ phase: CandidatePatchActivityPhase
    ) -> AgentConversationActivityKind {
        switch phase {
        case .understandingRequestedChange,
             .loadingGroundedAssessment,
             .validatingPlanningPreconditions,
             .checkingSandboxReadiness,
             .preparingCandidatePatchPlan,
             .verifyingApprovedScope:
            return .preparingCandidatePatch
        case .waitingForHumanApproval:
            return .waitingCandidatePatchApproval
        case .applyingChangeInIsolatedSandbox, .verifyingFileHashes,
             .confirmingOriginalLegacyUnchanged, .preparingHumanReview:
            return .applyingCandidatePatch
        case .buildingUnifiedDiff:
            return .buildingUnifiedDiff
        case .candidatePatchReady:
            return .candidatePatchReady
        case .candidatePatchBlocked:
            return .candidatePatchBlocked
        case .revertingCandidatePatch:
            return .revertingCandidatePatch
        case .locatingAppliedPatch, .validatingRevertBinding, .verifyingCurrentPostimages,
             .verifyingRestoredHashes:
            return .verifyingFileHashes
        case .revertConfirmationRequired, .sandboxDestructionConfirmationRequired:
            return .waitingCandidatePatchApproval
        case .candidatePatchReverted:
            return .candidatePatchReverted
        case .sandboxDestroyed:
            return .sandboxDestroyed
        }
    }

    private static func terminalKind(
        session: AgentSession,
        events: [ExecutionEvent],
        includesSessionSnapshot: Bool
    ) -> AgentConversationActivityKind? {
        if includesSessionSnapshot
            && (session.currentState == .failed || session.interactionState == .failed) {
            return .failed
        }
        if includesSessionSnapshot
            && (session.currentState == .completed || session.interactionState == .completed) {
            return .completed
        }
        if let latest = events.sorted(by: eventOrder).reversed().first(where: {
            $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
                || isCompleted($0)
                || isFailed($0)
                || isBlocked($0)
        }) {
            if latest.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" {
                return .partial
            }
            if isFailed(latest) { return .failed }
            if isBlocked(latest) { return .blocked }
            if isCompleted(latest) { return .completed }
        }
        if includesSessionSnapshot
            && (session.currentState == .blocked || session.interactionState == .blocked) {
            return events.contains(where: {
                $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
            }) ? .partial : .blocked
        }
        return nil
    }

    private static func terminalReason(
        for kind: AgentConversationActivityKind,
        events: [ExecutionEvent]
    ) -> String? {
        guard kind == .blocked || kind == .failed else { return nil }
        let event = events.reversed().first { isBlocked($0) || isFailed($0) }
        return AgentConversationActivityCopy.blockerReason(
            event?.payload["blocker_reason"]
                ?? event?.payload["provider_diagnostic"]
                ?? event?.payload["error"],
            failure: kind == .failed
        )
    }

    private static func isCompleted(_ event: ExecutionEvent) -> Bool {
        event.type == .taskCompleted && event.payload["completion_gate_passed"] != "false"
            || event.payload["state"] == TaskState.completed.rawValue
    }

    private static func isFailed(_ event: ExecutionEvent) -> Bool {
        if event.payload["state"] == TaskState.failed.rawValue { return true }
        switch event.type {
        case .toolFailed, .connectorFailed, .nodeExecutionFailed, .workerTaskFailed, .authorizationDenied:
            return true
        default:
            return false
        }
    }

    private static func isBlocked(_ event: ExecutionEvent) -> Bool {
        event.payload["state"] == TaskState.blocked.rawValue
            || event.payload["lifecycle_event"] == "PLAN_BLOCKED"
    }

    private static func isPartialFinalization(_ event: ExecutionEvent) -> Bool {
        event.payload["partial_result"] == "true"
            || event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
            || event.payload["budget_stop_decision"] == ReadOnlyBudgetStopDecision.partialWithCurrentEvidence.rawValue
    }

    private static func workspaceIdentity(from event: ExecutionEvent) -> String? {
        if let identity = event.payload["workspace_identity"], !identity.isEmpty {
            let normalized = identity.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercased = normalized.lowercased()
            if lowercased.contains("legacy") { return "Legacy" }
            if lowercased.contains("agent") { return "Agent" }
            guard !normalized.hasPrefix("/"),
                  !normalized.hasPrefix("~"),
                  !normalized.contains("\\") else {
                return nil
            }
            let safe = AgentPresentationSanitizer.safeContent(normalized, fallback: "")
            return safe.isEmpty ? nil : safe
        }
        let roles = event.payload["codebase_roles"]?.lowercased() ?? ""
        if roles.contains("legacy") && !roles.contains("agent") { return "Legacy" }
        if roles.contains("agent") && !roles.contains("legacy") { return "Agent" }
        return nil
    }

    private static func evidenceCount(in events: [ExecutionEvent], through sequence: Int64) -> Int {
        var callIDs = Set<String>()
        var eventIDs = Set<UUID>()
        for event in events where event.sequence <= sequence {
            guard event.type == .stepExecuted || event.type == .connectorExecuted,
                  event.payload["success"] == "true" || event.payload["exit_code"] == "0" else {
                continue
            }
            if let callID = event.payload["tool_call_id"], !callID.isEmpty {
                callIDs.insert(callID)
            } else {
                eventIDs.insert(event.id)
            }
        }
        return callIDs.count + eventIDs.count
    }

    private static func deduplicated(_ events: [ExecutionEvent]) -> [ExecutionEvent] {
        var seen = Set<UUID>()
        return events.filter { seen.insert($0.id).inserted }
    }

    private static func eventOrder(_ lhs: ExecutionEvent, _ rhs: ExecutionEvent) -> Bool {
        if lhs.sequence == rhs.sequence {
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return lhs.sequence < rhs.sequence
    }

    private static func integer(_ value: String?) -> Int? {
        value.flatMap(Int.init)
    }
}
