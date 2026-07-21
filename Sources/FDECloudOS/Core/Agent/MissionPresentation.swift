import Foundation

enum MissionProgressStage: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case assess = "ASSESS"
    case reviewChange = "REVIEW_CHANGE"
    case reviewTests = "REVIEW_TESTS"
    case ready = "READY"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .assess: return "Assess system"
        case .reviewChange: return "Review proposed change"
        case .reviewTests: return "Review proposed tests"
        case .ready: return "Ready"
        }
    }
}

enum MissionProgressStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case active
    case complete
    case blocked
    case needsReview = "needs_review"
}

struct MissionProgressItem: Codable, Hashable, Sendable, Identifiable {
    var stage: MissionProgressStage
    var status: MissionProgressStatus

    var id: MissionProgressStage { stage }
}

enum MissionPrimaryAction: String, Codable, CaseIterable, Hashable, Sendable {
    case assessSystem
    case continueAssessment
    case reviewFindings
    case reviewProposedChange
    case continueToTestReview
    case reviewProposedTests
    case retryCleanup
    case resolveBlocker

    var label: String {
        switch self {
        case .assessSystem: return "Assess system"
        case .continueAssessment: return "Continue assessment"
        case .reviewFindings: return "Review findings"
        case .reviewProposedChange: return "Review proposed change"
        case .continueToTestReview: return "Continue to test review"
        case .reviewProposedTests: return "Review proposed tests"
        case .retryCleanup: return "Retry cleanup"
        case .resolveBlocker: return "Resolve blocker"
        }
    }

    var isMutation: Bool {
        switch self {
        case .assessSystem, .continueAssessment, .continueToTestReview, .retryCleanup:
            return true
        case .reviewFindings, .reviewProposedChange, .reviewProposedTests, .resolveBlocker:
            return false
        }
    }
}

enum MissionPostReadyAction: String, Codable, CaseIterable, Hashable, Sendable {
    case reviewProductionReadiness

    var label: String {
        switch self {
        case .reviewProductionReadiness: "Review production readiness"
        }
    }
}

enum MissionControlledEvalAction: String, Codable, CaseIterable, Hashable, Sendable {
    case reviewControlledEvalExecution
    case reauthorizeControlledEvalExecution
    case viewControlledEvalBlocker
    case reviewEvalResults
    case authorizeEvalResultReview
    case reauthorizeEvalResultReview
    case viewEvalResults

    var label: String {
        switch self {
        case .reviewControlledEvalExecution: "Review controlled eval execution"
        case .reauthorizeControlledEvalExecution: "Reauthorize controlled eval execution"
        case .viewControlledEvalBlocker: "View blocker"
        case .reviewEvalResults: "Review eval results"
        case .authorizeEvalResultReview: "Authorize eval result review"
        case .reauthorizeEvalResultReview: "Reauthorize eval result review"
        case .viewEvalResults: "View eval results"
        }
    }
}

typealias MissionGeneratedTestReviewAction = (
    _ summary: MissionSummary,
    _ completion: @escaping (GeneratedTestArtifact?) -> Void
) -> Void

enum MissionPresentationPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case assessing = "ASSESSING"
    case preparingChange = "PREPARING_CHANGE"
    case applyingInSandbox = "APPLYING_IN_SANDBOX"
    case preparingTestReview = "PREPARING_TEST_REVIEW"
    case awaitingChangeReview = "AWAITING_CHANGE_REVIEW"
    case awaitingTestReview = "AWAITING_TEST_REVIEW"
    case ready = "READY"
    case cleaningUp = "CLEANING_UP"
    case cleanupPartialFailure = "CLEANUP_PARTIAL_FAILURE"
    case cleanedUp = "CLEANED_UP"
    case blocked = "BLOCKED"
    case failed = "FAILED"
}

enum MissionCleanupPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case freezingActions = "FREEZING_ACTIONS"
    case cancellingReviews = "CANCELLING_REVIEWS"
    case revertingPatch = "REVERTING_PATCH"
    case verifyingLegacy = "VERIFYING_LEGACY_UNCHANGED"
    case destroyingSandbox = "DESTROYING_SANDBOX"
    case partialFailure = "PARTIAL_FAILURE"
    case cleanedUp = "CLEANED_UP"
}

struct MissionCleanupState: Codable, Hashable, Sendable, Identifiable {
    var missionID: UUID
    var workspaceID: UUID
    var phase: MissionCleanupPhase
    var patchID: String?
    var patchPlanID: String?
    var patchRevision: Int?
    var sandboxID: String?
    var canonicalLegacyRoot: String?
    var sourceSnapshotID: String? = nil
    var candidatePatchManifestID: String? = nil
    var candidatePatchArtifactSHA256: String? = nil
    var assessmentID: String? = nil
    var lineageKey: String? = nil
    var pendingReviewActionsCancelled: Bool
    var candidatePatchReverted: Bool
    var legacyVerifiedUnchanged: Bool
    var sandboxDestroyed: Bool
    var failureReason: String?
    var startedAt: Date
    var updatedAt: Date
    var completedAt: Date?

    var id: UUID { missionID }
    var freezesMissionActions: Bool { phase != .cleanedUp }
    var needsRetry: Bool { phase == .partialFailure }

    static func starting(
        missionID: UUID,
        workspaceID: UUID,
        patch: CandidatePatchActivitySnapshot?,
        lineage: MissionRunIdentity? = nil,
        now: Date = Date()
    ) -> MissionCleanupState {
        MissionCleanupState(
            missionID: missionID,
            workspaceID: workspaceID,
            phase: .freezingActions,
            patchID: patch?.patchID,
            patchPlanID: patch?.planID,
            patchRevision: patch?.planRevision,
            sandboxID: patch?.sandboxID,
            canonicalLegacyRoot: patch?.canonicalLegacyRoot,
            sourceSnapshotID: patch?.sourceSnapshotID,
            candidatePatchManifestID: patch?.manifestID,
            candidatePatchArtifactSHA256: patch?.candidatePatchArtifactSHA256,
            assessmentID: patch?.assessmentID,
            lineageKey: lineage?.lineageKey,
            pendingReviewActionsCancelled: false,
            candidatePatchReverted: patch?.projectionState == .reverted
                || patch?.projectionState == .sandboxDestroyed
                || patch?.status == .reverted,
            legacyVerifiedUnchanged: false,
            sandboxDestroyed: patch?.projectionState == .sandboxDestroyed,
            failureReason: nil,
            startedAt: now,
            updatedAt: now,
            completedAt: nil
        )
    }
}

struct MissionExactDetail: Codable, Hashable, Sendable, Identifiable {
    var label: String
    var value: String

    var id: String { "\(label):\(value)" }
}

enum MissionLineageState: String, Codable, Hashable, Sendable {
    case exact = "EXACT"
    case incomplete = "INCOMPLETE"
    case contradictory = "CONTRADICTORY"
}

struct MissionRunIdentity: Codable, Hashable, Sendable, Identifiable {
    var missionRunID: UUID
    var workspaceID: UUID
    var sourceCandidatePatchTaskID: UUID
    var lineageKey: String
    var canonicalLegacyRoot: String?
    var sourceSnapshotID: String?
    var assessmentID: String?
    var candidatePatchID: String?
    var candidatePatchPlanID: String?
    var candidatePatchPlanRevision: Int?
    var sandboxID: String?
    var generatedTestPlanningTaskID: String?
    var generatedTestPlanID: String?
    var generatedTestPlanRevision: Int?
    var generatedTestPlanSHA256: String?
    var generatedTestArtifactID: String?
    var generatedTestArtifactRevision: Int?
    var generatedTestArtifactSHA256: String?
    var candidatePatchManifestID: String? = nil
    var candidatePatchArtifactSHA256: String? = nil
    var validationTestPlanSHA256: String? = nil
    var unifiedDiffSHA256: String? = nil

    var id: UUID { missionRunID }
}

struct MissionHistoryEvent: Hashable, Sendable, Identifiable {
    var eventID: String
    var title: String
    var outcome: String
    var occurredAt: Date?
    var exactDetails: [MissionExactDetail]

    var id: String { eventID }
}

struct MissionSummary: Hashable, Sendable, Identifiable {
    var missionID: UUID
    var title: String
    var goal: String
    var legacyRoot: String?
    var stage: MissionProgressStage
    var phase: MissionPresentationPhase
    var result: String
    var safetySummary: String
    var primaryAction: MissionPrimaryAction?
    var progress: [MissionProgressItem]
    var candidatePatch: CandidatePatchActivitySnapshot?
    var generatedTestPlan: GeneratedTestActivitySnapshot?
    var generatedTestArtifact: GeneratedTestArtifact?
    var candidatePatchApproval: ApprovalRequest?
    var cleanup: MissionCleanupState?
    var lineage: MissionRunIdentity? = nil
    var lineageState: MissionLineageState = .incomplete
    var lineageFailureReason: String? = nil
    var undoEligible: Bool = false
    var productionReadinessReport: ProductionReadinessReport? = nil
    var aiEvalPlan: AIEvalPlan? = nil
    var postReadyAction: MissionPostReadyAction? = nil
    var phase3APlanningFailureReason: String? = nil
    var evalRun: EvalRun? = nil
    var controlledEvalAction: MissionControlledEvalAction? = nil
    var controlledEvalEligibility: ControlledEvalExecutionEligibility? = nil
    var controlledEvalResultReviewEligibility: ControlledEvalResultReviewEligibility? = nil
    var controlledEvalRestorationFailureReason: String? = nil
    var exactDetails: [MissionExactDetail]

    var id: UUID { missionID }
    var isTerminal: Bool {
        phase == .ready || phase == .cleanedUp || phase == .failed
    }
}

struct MissionHistoryEntry: Hashable, Sendable, Identifiable {
    var historyID: String
    var missionID: UUID?
    var title: String
    var completedAt: Date?
    var finalOutcome: String
    var patchLifecycle: String
    var artifactReviewOutcome: String
    var cleanupOutcome: String
    var timeline: [MissionHistoryEvent] = []
    var exactDetails: [MissionExactDetail]

    var id: String { historyID }
    var exposesMutationActions: Bool { false }
}

struct MissionPresentationState: Hashable, Sendable {
    var current: MissionSummary
    var previousRuns: [MissionHistoryEntry]
    var previousRunsExpandedByDefault: Bool
    var advancedDetailsExpandedByDefault: Bool = false
    var completedActivityExpandedByDefault: Bool = false

    var primaryMutationActionCount: Int {
        current.primaryAction?.isMutation == true ? 1 : 0
    }
}

enum MissionStatusLanguage {
    static func humanReadable(_ internalValue: String) -> String {
        switch internalValue {
        case GeneratedTestLifecycleStatus.testPlanReviewReady.rawValue:
            return "Proposed tests ready"
        case GeneratedTestLifecycleStatus.testArtifactReviewReady.rawValue:
            return "Test files ready for review"
        case GeneratedTestLifecycleStatus.clarificationRequired.rawValue:
            return "More information needed"
        case CandidatePatchProjectionState.patchReady.rawValue:
            return "Proposed change ready"
        case CandidatePatchProjectionState.sandboxDestroyed.rawValue:
            return "Temporary workspace cleaned up"
        case CandidatePatchProjectionState.reverted.rawValue:
            return "Proposed change reverted"
        case GeneratedTestArtifactReviewState.approved.rawValue:
            return "Approved"
        case GeneratedTestArtifactReviewState.rejected.rawValue:
            return "Rejected"
        case GeneratedTestArtifactReviewState.changeRequested.rawValue:
            return "Changes requested"
        default:
            return internalValue
                .replacingOccurrences(of: "_", with: " ")
                .lowercased()
                .localizedCapitalized
        }
    }
}

// Retained only as a source-compatible reference while persisted Phase 2D.2C
// records are restored. Active presentation uses the exact-lineage projector
// in MissionLineagePresentation.swift.
private enum LegacyMissionPresentationProjector {
    static func project(
        session: AgentSession,
        activity: AgentConversationActivity?,
        candidatePatches: [CandidatePatchActivitySnapshot],
        generatedTestPlans: [GeneratedTestActivitySnapshot],
        generatedTestArtifacts: [GeneratedTestArtifact],
        approvals: [ApprovalRequest],
        cleanupStates: [MissionCleanupState] = []
    ) -> MissionPresentationState {
        let missionTaskIDs = Set((session.workspaceContext.missionTaskIDs ?? []) + [session.runtimeTaskID].compactMap { $0 })
        let currentCandidates = candidatePatches.filter { patch in
            patch.sourceCandidatePatchTaskID
                .flatMap(UUID.init(uuidString:))
                .map(missionTaskIDs.contains) == true
        }
        let currentPlans = generatedTestPlans.filter { plan in
            [plan.planningTaskID, plan.sourceCandidatePatchTaskID]
                .compactMap { $0?.flatMap(UUID.init(uuidString:)) }
                .contains(where: missionTaskIDs.contains)
        }
        let currentArtifacts = generatedTestArtifacts.filter { artifact in
            let binding = artifact.sourceBinding.generatedTestSourceBinding
            return missionTaskIDs.contains(binding.sourceCandidatePatchTaskID)
                || missionTaskIDs.contains(binding.generatedTestPlanningTaskID)
        }
        let patch = currentCandidates.max { lhs, rhs in
            let leftRevision = lhs.planRevision ?? 0
            let rightRevision = rhs.planRevision ?? 0
            if leftRevision == rightRevision { return historyKey(lhs) < historyKey(rhs) }
            return leftRevision < rightRevision
        }
        let plan = currentPlans.max { lhs, rhs in
            let leftRevision = lhs.generatedTestPlanRevision ?? 0
            let rightRevision = rhs.generatedTestPlanRevision ?? 0
            if leftRevision == rightRevision { return generatedPlanHistoryKey(lhs) < generatedPlanHistoryKey(rhs) }
            return leftRevision < rightRevision
        }
        let artifact = currentArtifacts.max { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt {
                return lhs.artifactID.uuidString < rhs.artifactID.uuidString
            }
            return lhs.updatedAt < rhs.updatedAt
        }
        let missionID = patch?.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:))
            ?? artifact?.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID
            ?? plan?.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:))
            ?? session.runtimeTaskID
            ?? session.sessionID
        let cleanup = cleanupStates.first { $0.missionID == missionID }
        let approval = approvals
            .filter { approval in
                approval.state == .pending
                    && approval.targetKind == .candidatePatchPlan
                    && approval.taskID.map(missionTaskIDs.contains) == true
            }
            .sorted { lhs, rhs in
                if lhs.requestedAt == rhs.requestedAt { return lhs.id.uuidString < rhs.id.uuidString }
                return lhs.requestedAt < rhs.requestedAt
            }
            .first

        let current = summary(
            missionID: missionID,
            session: session,
            activity: activity,
            patch: patch,
            plan: plan,
            artifact: artifact,
            approval: approval,
            cleanup: cleanup
        )
        let currentKeys = Set([
            patch.map(historyKey),
            plan.map { generatedPlanHistoryKey($0) },
            artifact.map { generatedArtifactHistoryKey($0) }
        ].compactMap { $0 })
        let history = history(
            candidates: candidatePatches,
            plans: generatedTestPlans,
            artifacts: generatedTestArtifacts,
            cleanupStates: cleanupStates,
            excluding: currentKeys
        )
        return MissionPresentationState(
            current: current,
            previousRuns: history,
            previousRunsExpandedByDefault: false
        )
    }

    private static func summary(
        missionID: UUID,
        session: AgentSession,
        activity: AgentConversationActivity?,
        patch: CandidatePatchActivitySnapshot?,
        plan: GeneratedTestActivitySnapshot?,
        artifact: GeneratedTestArtifact?,
        approval: ApprovalRequest?,
        cleanup: MissionCleanupState?
    ) -> MissionSummary {
        let resolved = resolveState(
            session: session,
            activity: activity,
            patch: patch,
            plan: plan,
            artifact: artifact,
            approval: approval,
            cleanup: cleanup
        )
        return MissionSummary(
            missionID: missionID,
            title: missionTitle(session: session, patch: patch),
            goal: session.userGoal,
            legacyRoot: patch?.canonicalLegacyRoot ?? session.workspaceContext.localProjectRoot,
            stage: resolved.stage,
            phase: resolved.phase,
            result: resolved.result,
            safetySummary: safetySummary(patch: patch, artifact: artifact),
            primaryAction: resolved.primaryAction,
            progress: progress(stage: resolved.stage, phase: resolved.phase),
            candidatePatch: patch,
            generatedTestPlan: plan,
            generatedTestArtifact: artifact,
            candidatePatchApproval: approval,
            cleanup: cleanup,
            exactDetails: exactDetails(
                missionID: missionID,
                patch: patch,
                plan: plan,
                artifact: artifact
            )
        )
    }

    private static func resolveState(
        session: AgentSession,
        activity: AgentConversationActivity?,
        patch: CandidatePatchActivitySnapshot?,
        plan: GeneratedTestActivitySnapshot?,
        artifact: GeneratedTestArtifact?,
        approval: ApprovalRequest?,
        cleanup: MissionCleanupState?
    ) -> (stage: MissionProgressStage, phase: MissionPresentationPhase, result: String, primaryAction: MissionPrimaryAction?) {
        if let cleanup {
            switch cleanup.phase {
            case .cleanedUp:
                return (.ready, .cleanedUp, "This run was undone and its temporary workspace was cleaned up.", nil)
            case .partialFailure:
                return (.ready, .cleanupPartialFailure, "Cleanup partially completed. The remaining exact step can be retried safely.", .retryCleanup)
            default:
                return (.ready, .cleaningUp, "Undoing this run through the exact revert and cleanup workflow.", nil)
            }
        }
        if activity?.kind == .failed || session.interactionState == .failed {
            return (.assess, .failed, activity?.metadata.blockerReason ?? "This run failed safely.", nil)
        }
        if activity?.kind == .partial {
            return (
                .assess,
                .assessing,
                "A grounded partial assessment is ready. More information is needed to complete the recommendation.",
                .continueAssessment
            )
        }
        if activity?.kind == .blocked || activity?.kind == .candidatePatchBlocked
            || activity?.kind == .generatedTestPlanningBlocked || session.interactionState == .blocked {
            return (.assess, .blocked, activity?.metadata.blockerReason ?? "This run needs attention before it can continue.", .resolveBlocker)
        }
        if let artifact, let revision = artifact.currentRevision {
            switch artifact.reviewState(for: revision.revision) {
            case .awaitingReview:
                return (
                    .reviewTests,
                    .awaitingTestReview,
                    "Generated test files are ready for review.",
                    .reviewProposedTests
                )
            case .approved:
                return (.ready, .ready, "Approved review artifacts are ready for a future phase.", nil)
            case .rejected:
                return (.reviewTests, .failed, "The proposed test files were rejected. No files were written or executed.", nil)
            case .changeRequested:
                return (.reviewTests, .preparingTestReview, "Changes were requested for the proposed test files.", nil)
            }
        }
        if let plan {
            switch plan.status {
            case .testPlanReviewReady:
                return (.reviewTests, .preparingTestReview, "The proposed test scenarios are ready to become reviewable virtual files.", .continueToTestReview)
            case .clarificationRequired:
                return (.reviewTests, .blocked, "More information is needed before proposed tests can be reviewed.", .resolveBlocker)
            case .blocked, .failed, .rejected:
                return (.reviewTests, .blocked, MissionStatusLanguage.humanReadable(plan.status.rawValue), .resolveBlocker)
            default:
                return (.reviewTests, .preparingTestReview, "Preparing proposed tests for review.", nil)
            }
        }
        if approval != nil {
            return (.reviewChange, .awaitingChangeReview, "A proposed change is ready for your review.", .reviewProposedChange)
        }
        if let patch {
            if patch.projectionState == .patchReady || patch.status == .reviewReady || patch.status == .applied {
                return (.reviewChange, .applyingInSandbox, "The proposed change is isolated in the Safe Sandbox.", .continueToTestReview)
            }
            if patch.status == .rejected {
                return (.reviewChange, .failed, "The proposed change was rejected.", nil)
            }
            return (.reviewChange, .preparingChange, "Preparing the proposed change for review.", nil)
        }
        if let assessment = activity?.metadata.aiAssessment {
            return (
                .assess,
                .assessing,
                assessment.blockerCount == 0 ? "Assessment findings are ready." : "Assessment found items that need attention.",
                .reviewFindings
            )
        }
        let running = activity?.kind.isAnimated == true
            || session.interactionState == .understanding
            || session.interactionState == .planning
            || session.interactionState == .working
            || session.interactionState == .running
        return (
            .assess,
            .assessing,
            running ? "Assessing the selected Legacy." : "Ready to assess the selected Legacy.",
            running ? .continueAssessment : .assessSystem
        )
    }

    private static func progress(
        stage activeStage: MissionProgressStage,
        phase: MissionPresentationPhase
    ) -> [MissionProgressItem] {
        let stages = MissionProgressStage.allCases
        let activeIndex = stages.firstIndex(of: activeStage) ?? 0
        return stages.enumerated().map { index, stage in
            let status: MissionProgressStatus
            if phase == .blocked || phase == .failed || phase == .cleanupPartialFailure, stage == activeStage {
                status = .blocked
            } else if index < activeIndex {
                status = .complete
            } else if index > activeIndex {
                status = .pending
            } else if phase == .awaitingChangeReview || phase == .awaitingTestReview {
                status = .needsReview
            } else if phase == .ready || phase == .cleanedUp {
                status = .complete
            } else {
                status = .active
            }
            return MissionProgressItem(stage: stage, status: status)
        }
    }

    private static func history(
        candidates: [CandidatePatchActivitySnapshot],
        plans: [GeneratedTestActivitySnapshot],
        artifacts: [GeneratedTestArtifact],
        cleanupStates: [MissionCleanupState],
        excluding currentKeys: Set<String>
    ) -> [MissionHistoryEntry] {
        let cleanupByMission = Dictionary(uniqueKeysWithValues: cleanupStates.map { ($0.missionID, $0) })
        var entries: [MissionHistoryEntry] = []
        var seen = Set<String>()

        for patch in candidates.reversed() {
            let key = historyKey(patch)
            guard !currentKeys.contains(key), seen.insert(key).inserted else { continue }
            let missionID = patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:))
            let artifact = artifacts
                .filter {
                    $0.sourceBinding.generatedTestSourceBinding.candidatePatchPlanID.uuidString == patch.planID
                        && $0.sourceBinding.generatedTestSourceBinding.candidatePatchPlanRevision == patch.planRevision
                }
                .max(by: { $0.updatedAt < $1.updatedAt })
            let cleanup = missionID.flatMap { cleanupByMission[$0] }
            entries.append(MissionHistoryEntry(
                historyID: key,
                missionID: missionID,
                title: plainTitle(patch.capabilityDisplayLabel ?? patch.capabilityID ?? "Previous mission"),
                completedAt: artifact?.updatedAt ?? cleanup?.completedAt,
                finalOutcome: historicalOutcome(patch: patch, artifact: artifact),
                patchLifecycle: MissionStatusLanguage.humanReadable(
                    patch.projectionState?.rawValue ?? patch.status?.rawValue.uppercased() ?? "UNKNOWN"
                ),
                artifactReviewOutcome: artifactReviewOutcome(artifact),
                cleanupOutcome: cleanupOutcome(cleanup, patch: patch),
                exactDetails: exactDetails(
                    missionID: missionID,
                    patch: patch,
                    plan: nil,
                    artifact: artifact
                )
            ))
        }

        for plan in plans.reversed() {
            let key = generatedPlanHistoryKey(plan)
            guard !currentKeys.contains(key), seen.insert(key).inserted else { continue }
            let missionID = plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:))
            entries.append(MissionHistoryEntry(
                historyID: key,
                missionID: missionID,
                title: plainTitle(plan.capabilityID ?? "Generated tests"),
                completedAt: nil,
                finalOutcome: MissionStatusLanguage.humanReadable(plan.status.rawValue),
                patchLifecycle: "Preserved",
                artifactReviewOutcome: "Not reviewed",
                cleanupOutcome: missionID.flatMap { cleanupByMission[$0] }.map { cleanupOutcome($0, patch: nil) } ?? "Not requested",
                exactDetails: exactDetails(missionID: missionID, patch: nil, plan: plan, artifact: nil)
            ))
        }

        for artifact in artifacts.reversed() {
            let key = generatedArtifactHistoryKey(artifact)
            guard !currentKeys.contains(key), seen.insert(key).inserted else { continue }
            let binding = artifact.sourceBinding.generatedTestSourceBinding
            entries.append(MissionHistoryEntry(
                historyID: key,
                missionID: binding.sourceCandidatePatchTaskID,
                title: plainTitle(binding.capabilityDisplayLabel ?? binding.normalizedCapabilityID),
                completedAt: artifact.updatedAt,
                finalOutcome: artifactReviewOutcome(artifact),
                patchLifecycle: "Proposed change preserved",
                artifactReviewOutcome: artifactReviewOutcome(artifact),
                cleanupOutcome: cleanupByMission[binding.sourceCandidatePatchTaskID]
                    .map { cleanupOutcome($0, patch: nil) } ?? "Not requested",
                exactDetails: exactDetails(
                    missionID: binding.sourceCandidatePatchTaskID,
                    patch: nil,
                    plan: nil,
                    artifact: artifact
                )
            ))
        }
        return entries
    }

    private static func historyKey(_ patch: CandidatePatchActivitySnapshot) -> String {
        [
            "candidate-patch-plan",
            patch.planID ?? "unknown-plan",
            patch.planRevision.map(String.init) ?? "unknown-revision",
            patch.patchID ?? "unknown-patch",
            patch.sandboxID ?? "unknown-sandbox"
        ].joined(separator: ":")
    }

    private static func generatedPlanHistoryKey(_ plan: GeneratedTestActivitySnapshot) -> String {
        "generated-test-plan:\(plan.generatedTestPlanID ?? plan.planningTaskID ?? plan.stableProjectionKey):\(plan.generatedTestPlanRevision ?? 0)"
    }

    private static func generatedArtifactHistoryKey(_ artifact: GeneratedTestArtifact) -> String {
        "generated-test-artifact:\(artifact.artifactID.uuidString.lowercased()):\(artifact.currentRevision?.revision ?? 0)"
    }

    private static func missionTitle(
        session: AgentSession,
        patch: CandidatePatchActivitySnapshot?
    ) -> String {
        if let label = patch?.capabilityDisplayLabel ?? patch?.capabilityID, !label.isEmpty {
            return plainTitle(label)
        }
        if let taskTitle = session.workspaceContext.runtimeTaskTitle, !taskTitle.isEmpty {
            return taskTitle
        }
        let firstLine = session.userGoal.split(whereSeparator: \.isNewline).first.map(String.init) ?? session.userGoal
        return firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
    }

    private static func plainTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                let value = String(word)
                return value == value.uppercased() && value.count <= 4
                    ? value
                    : value.prefix(1).uppercased() + value.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func safetySummary(
        patch: CandidatePatchActivitySnapshot?,
        artifact: GeneratedTestArtifact?
    ) -> String {
        if let artifact, let revision = artifact.currentRevision {
            return "\(revision.scenarioBindings.count) scenarios · \(revision.virtualFiles.count) virtual \(revision.virtualFiles.count == 1 ? "file" : "files") · No files written or executed"
        }
        if let patch {
            return "Safe Sandbox only · Original Legacy \(patch.sourceIntegrity == .unchanged ? "unchanged" : "not modified by this view") · Build and Tests unavailable"
        }
        return "Read-only assessment · No Build, Tests, Shell, Git, or deployment"
    }

    private static func exactDetails(
        missionID: UUID?,
        patch: CandidatePatchActivitySnapshot?,
        plan: GeneratedTestActivitySnapshot?,
        artifact: GeneratedTestArtifact?
    ) -> [MissionExactDetail] {
        var values: [MissionExactDetail] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            values.append(MissionExactDetail(label: label, value: value))
        }
        add("Mission ID", missionID?.uuidString.lowercased())
        add("Candidate Patch ID", patch?.patchID ?? artifact?.sourceBinding.generatedTestSourceBinding.patchID.rawValue)
        add("Candidate Patch plan ID", patch?.planID ?? artifact?.sourceBinding.generatedTestSourceBinding.candidatePatchPlanID.uuidString.lowercased())
        add("Candidate Patch plan revision", patch?.planRevision.map(String.init) ?? artifact.map { String($0.sourceBinding.generatedTestSourceBinding.candidatePatchPlanRevision) })
        add("Candidate Patch artifact SHA-256", patch?.candidatePatchArtifactSHA256 ?? artifact?.sourceBinding.generatedTestSourceBinding.candidatePatchArtifactSHA256)
        add("Sandbox ID", patch?.sandboxID ?? artifact?.sourceBinding.generatedTestSourceBinding.sandboxID.rawValue)
        add("Source snapshot ID", patch?.sourceSnapshotID ?? artifact?.sourceBinding.generatedTestSourceBinding.sourceSnapshotID)
        add("Canonical Legacy root", patch?.canonicalLegacyRoot ?? artifact?.sourceBinding.generatedTestSourceBinding.canonicalLegacyRoot)
        add("Assessment ID", patch?.assessmentID ?? plan?.assessmentID ?? artifact?.sourceBinding.generatedTestSourceBinding.validatedAssessmentID)
        add("Generated Test Plan ID", plan?.generatedTestPlanID ?? artifact?.sourceBinding.generatedTestPlanID.uuidString.lowercased())
        add("Generated Test Plan revision", plan?.generatedTestPlanRevision.map(String.init) ?? artifact.map { String($0.sourceBinding.generatedTestPlanRevision) })
        add("Generated Test Plan SHA-256", plan?.generatedTestPlanSHA256 ?? artifact?.sourceBinding.generatedTestPlanSHA256)
        add("Generated Test Artifact ID", artifact?.artifactID.uuidString.lowercased())
        add("Generated Test Artifact revision", artifact?.currentRevision.map { String($0.revision) })
        add("Generated Test Artifact SHA-256", artifact?.currentRevision?.digest.sha256)
        return values
    }

    private static func historicalOutcome(
        patch: CandidatePatchActivitySnapshot,
        artifact: GeneratedTestArtifact?
    ) -> String {
        if let artifact { return artifactReviewOutcome(artifact) }
        return MissionStatusLanguage.humanReadable(
            patch.projectionState?.rawValue ?? patch.status?.rawValue.uppercased() ?? "UNKNOWN"
        )
    }

    private static func artifactReviewOutcome(_ artifact: GeneratedTestArtifact?) -> String {
        guard let artifact, let revision = artifact.currentRevision else { return "Not available" }
        return MissionStatusLanguage.humanReadable(artifact.reviewState(for: revision.revision).rawValue)
    }

    private static func cleanupOutcome(
        _ cleanup: MissionCleanupState?,
        patch: CandidatePatchActivitySnapshot?
    ) -> String {
        if cleanup?.phase == .cleanedUp || patch?.projectionState == .sandboxDestroyed {
            return "Cleaned up"
        }
        if cleanup?.phase == .partialFailure { return "Cleanup incomplete" }
        if cleanup != nil { return "Cleanup in progress" }
        return "Not requested"
    }
}
