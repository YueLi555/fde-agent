import Foundation

/// Builds product-facing missions by exact authority lineage. Assets are never
/// selected independently: every child must join through its authoritative
/// parent chain before it can appear in an actionable Current Run.
enum MissionPresentationProjector {
    static func project(
        session: AgentSession,
        activity: AgentConversationActivity?,
        candidatePatches: [CandidatePatchActivitySnapshot],
        generatedTestPlans: [GeneratedTestActivitySnapshot],
        generatedTestArtifacts: [GeneratedTestArtifact],
        approvals: [ApprovalRequest],
        cleanupStates: [MissionCleanupState] = []
    ) -> MissionPresentationState {
        let selectedTaskID = session.runtimeTaskID ?? session.sessionID
        let baseMissionID = exactMissionRunID(
            for: selectedTaskID,
            workspaceID: session.workspaceID,
            candidatePatches: candidatePatches,
            generatedTestPlans: generatedTestPlans,
            generatedTestArtifacts: generatedTestArtifacts
        ) ?? selectedTaskID
        var aggregates: [UUID: MissionAggregate] = [
            baseMissionID: MissionAggregate(
                missionID: baseMissionID,
                workspaceID: session.workspaceID,
                isSelectedSessionMission: true
            )
        ]

        for (index, patch) in candidatePatches.enumerated() {
            guard let missionID = patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) else {
                aggregates[baseMissionID]?.unscopedAuthority.append("Candidate Patch")
                continue
            }
            var aggregate = aggregates[missionID] ?? MissionAggregate(
                missionID: missionID,
                workspaceID: session.workspaceID,
                isSelectedSessionMission: missionID == baseMissionID
            )
            aggregate.patches.append(IndexedPatch(value: patch, order: index))
            aggregate.orderHint = max(aggregate.orderHint, index)
            aggregates[missionID] = aggregate
        }

        for (index, plan) in generatedTestPlans.enumerated() {
            guard let missionID = plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) else {
                aggregates[baseMissionID]?.unscopedAuthority.append("Generated Test Plan")
                continue
            }
            var aggregate = aggregates[missionID] ?? MissionAggregate(
                missionID: missionID,
                workspaceID: session.workspaceID,
                isSelectedSessionMission: missionID == baseMissionID
            )
            aggregate.plans.append(IndexedPlan(value: plan, order: index))
            aggregate.orderHint = max(aggregate.orderHint, candidatePatches.count + index)
            aggregates[missionID] = aggregate
        }

        for (index, artifact) in generatedTestArtifacts.enumerated() {
            let binding = artifact.sourceBinding.generatedTestSourceBinding
            let missionID = binding.sourceCandidatePatchTaskID
            var aggregate = aggregates[missionID] ?? MissionAggregate(
                missionID: missionID,
                workspaceID: session.workspaceID,
                isSelectedSessionMission: missionID == baseMissionID
            )
            aggregate.artifacts.append(IndexedArtifact(value: artifact, order: index))
            aggregate.latestDate = max(aggregate.latestDate, artifact.updatedAt)
            aggregate.orderHint = max(
                aggregate.orderHint,
                candidatePatches.count + generatedTestPlans.count + index
            )
            aggregates[missionID] = aggregate
        }

        for approval in approvals where approval.targetKind == .candidatePatchPlan {
            guard let missionID = approval.taskID else {
                aggregates[baseMissionID]?.unscopedAuthority.append("Candidate Patch review")
                continue
            }
            var aggregate = aggregates[missionID] ?? MissionAggregate(
                missionID: missionID,
                workspaceID: session.workspaceID,
                isSelectedSessionMission: missionID == baseMissionID
            )
            aggregate.approvals.append(approval)
            aggregate.latestDate = max(aggregate.latestDate, approval.decidedAt ?? approval.requestedAt)
            aggregates[missionID] = aggregate
        }

        for cleanup in cleanupStates {
            var aggregate = aggregates[cleanup.missionID] ?? MissionAggregate(
                missionID: cleanup.missionID,
                workspaceID: session.workspaceID,
                isSelectedSessionMission: cleanup.missionID == baseMissionID
            )
            aggregate.cleanups.append(cleanup)
            aggregate.latestDate = max(aggregate.latestDate, cleanup.updatedAt)
            aggregates[cleanup.missionID] = aggregate
        }

        let activityTaskID = activity?.metadata.taskID
        let activityMissionID = activityTaskID.flatMap {
            exactMissionRunID(
                for: $0,
                workspaceID: session.workspaceID,
                candidatePatches: candidatePatches,
                generatedTestPlans: generatedTestPlans,
                generatedTestArtifacts: generatedTestArtifacts
            )
        } ?? (activityTaskID == selectedTaskID ? baseMissionID : activityTaskID) ?? baseMissionID
        if var aggregate = aggregates[activityMissionID] {
            aggregate.activity = activity
            aggregates[activityMissionID] = aggregate
        }

        let taskOrder = orderedMissionTaskRanks(
            session: session,
            baseMissionID: baseMissionID,
            candidatePatches: candidatePatches,
            generatedTestPlans: generatedTestPlans,
            generatedTestArtifacts: generatedTestArtifacts
        )
        let resolved = aggregates.values.map {
            resolve(
                aggregate: $0,
                session: session,
                taskRank: taskOrder[$0.missionID] ?? -1
            )
        }
        let authoritativeNonterminal = resolved.filter {
            $0.summary.lineageState == .exact && !$0.summary.isTerminal
        }
        let authoritativeCompleted = resolved.filter {
            $0.summary.lineageState == .exact && $0.summary.isTerminal
        }
        let selectionPool: [ResolvedMission]
        if !authoritativeNonterminal.isEmpty {
            selectionPool = authoritativeNonterminal
        } else if !authoritativeCompleted.isEmpty {
            selectionPool = authoritativeCompleted
        } else {
            selectionPool = resolved
        }
        let selectedMissionPool = selectionPool.filter { $0.summary.missionID == baseMissionID }
        let currentResolved = (selectedMissionPool.isEmpty ? selectionPool : selectedMissionPool)
            .max(by: isOlder)
            ?? resolve(
                aggregate: MissionAggregate(
                    missionID: baseMissionID,
                    workspaceID: session.workspaceID,
                    isSelectedSessionMission: true
                ),
                session: session,
                taskRank: taskOrder[baseMissionID] ?? 0
            )

        let previousRuns = resolved
            .filter { $0.summary.missionID != currentResolved.summary.missionID }
            .sorted { isOlder($1, $0) }
            .map(historyEntry)

        return MissionPresentationState(
            current: currentResolved.summary,
            previousRuns: previousRuns,
            previousRunsExpandedByDefault: false
        )
    }
}

private extension MissionPresentationProjector {
    struct IndexedPatch {
        var value: CandidatePatchActivitySnapshot
        var order: Int
    }

    struct IndexedPlan {
        var value: GeneratedTestActivitySnapshot
        var order: Int
    }

    struct IndexedArtifact {
        var value: GeneratedTestArtifact
        var order: Int
    }

    struct MissionAggregate {
        var missionID: UUID
        var workspaceID: UUID
        var isSelectedSessionMission: Bool
        var patches: [IndexedPatch] = []
        var plans: [IndexedPlan] = []
        var artifacts: [IndexedArtifact] = []
        var approvals: [ApprovalRequest] = []
        var cleanups: [MissionCleanupState] = []
        var activity: AgentConversationActivity?
        var unscopedAuthority: [String] = []
        var latestDate: Date = .distantPast
        var orderHint: Int = -1
    }

    struct ResolvedMission {
        var summary: MissionSummary
        var timeline: [MissionHistoryEvent]
        var latestDate: Date
        var orderHint: Int
        var taskRank: Int
    }

    struct LineageResolution {
        var state: MissionLineageState
        var reason: String?
        var patch: CandidatePatchActivitySnapshot?
        var plan: GeneratedTestActivitySnapshot?
        var artifact: GeneratedTestArtifact?
        var approval: ApprovalRequest?
        var cleanup: MissionCleanupState?
        var identity: MissionRunIdentity
    }

    static func orderedMissionTaskRanks(
        session: AgentSession,
        baseMissionID: UUID,
        candidatePatches: [CandidatePatchActivitySnapshot],
        generatedTestPlans: [GeneratedTestActivitySnapshot],
        generatedTestArtifacts: [GeneratedTestArtifact]
    ) -> [UUID: Int] {
        let taskIDs = (session.workspaceContext.missionTaskIDs ?? [])
            + [session.runtimeTaskID].compactMap { $0 }
        var ordered: [UUID] = []
        for taskID in taskIDs {
            let missionID = exactMissionRunID(
                for: taskID,
                workspaceID: session.workspaceID,
                candidatePatches: candidatePatches,
                generatedTestPlans: generatedTestPlans,
                generatedTestArtifacts: generatedTestArtifacts
            ) ?? taskID
            if !ordered.contains(missionID) { ordered.append(missionID) }
        }
        ordered.removeAll { $0 == baseMissionID }
        ordered.append(baseMissionID)
        return Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, $0.offset) })
    }

    /// Resolves a runtime task to its exact Candidate Patch mission root. A
    /// child task is never promoted by title, timestamp, workspace, or
    /// capability: it must have one complete Plan/Artifact parent chain.
    static func exactMissionRunID(
        for taskID: UUID,
        workspaceID: UUID,
        candidatePatches: [CandidatePatchActivitySnapshot],
        generatedTestPlans: [GeneratedTestActivitySnapshot],
        generatedTestArtifacts: [GeneratedTestArtifact]
    ) -> UUID? {
        let directPatchMissions = Set(candidatePatches.compactMap { patch -> UUID? in
            guard patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == taskID else {
                return nil
            }
            return taskID
        })

        var childMissionIDs = Set<UUID>()
        for plan in generatedTestPlans
        where plan.planningTaskID.flatMap(UUID.init(uuidString:)) == taskID {
            guard let missionID = plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)),
                  plan.workspaceID.flatMap(UUID.init(uuidString:)) == workspaceID,
                  candidatePatches.contains(where: {
                      planMatchesPatch(plan, patch: $0, missionID: missionID)
                  }) else {
                continue
            }
            childMissionIDs.insert(missionID)
        }

        for artifact in generatedTestArtifacts {
            let binding = artifact.sourceBinding.generatedTestSourceBinding
            guard binding.generatedTestPlanningTaskID == taskID,
                  binding.workspaceID == workspaceID,
                  candidatePatches.contains(where: {
                      artifactMatchesPatch(artifact, patch: $0, missionID: binding.sourceCandidatePatchTaskID)
                  }),
                  generatedTestPlans.contains(where: {
                      artifactMatchesPlan(artifact, plan: $0)
                  }) else {
                continue
            }
            childMissionIDs.insert(binding.sourceCandidatePatchTaskID)
        }

        let exactMissionIDs = directPatchMissions.union(childMissionIDs)
        guard exactMissionIDs.count == 1 else { return nil }
        return exactMissionIDs.first
    }

    static func resolve(
        aggregate: MissionAggregate,
        session: AgentSession,
        taskRank: Int
    ) -> ResolvedMission {
        let lineage = resolveLineage(aggregate: aggregate, session: session)
        let state = resolveState(
            session: session,
            activity: aggregate.activity,
            lineage: lineage
        )
        let title = missionTitle(
            session: session,
            missionID: aggregate.missionID,
            patch: lineage.patch,
            plan: lineage.plan,
            artifact: lineage.artifact
        )
        var exactDetails = exactDetails(identity: lineage.identity)
        if lineage.plan != nil {
            exactDetails.append(MissionExactDetail(
                label: "Internal phase",
                value: "Phase 2D.2A Generated Test Plan"
            ))
        } else if lineage.patch != nil {
            exactDetails.append(MissionExactDetail(
                label: "Internal phase",
                value: "Phase 2D.1 Candidate Patch"
            ))
        }
        let summary = MissionSummary(
            missionID: aggregate.missionID,
            title: title,
            goal: aggregate.isSelectedSessionMission
                ? session.userGoal
                : "Preserved mission outcome and exact authority lineage.",
            legacyRoot: lineage.identity.canonicalLegacyRoot,
            stage: state.stage,
            phase: state.phase,
            result: state.result,
            safetySummary: safetySummary(
                patch: lineage.patch,
                plan: lineage.plan,
                artifact: lineage.artifact,
                lineageState: lineage.state
            ),
            primaryAction: lineage.state == .exact ? state.primaryAction : nil,
            progress: progress(stage: state.stage, phase: state.phase),
            candidatePatch: lineage.patch,
            generatedTestPlan: lineage.plan,
            generatedTestArtifact: lineage.artifact,
            candidatePatchApproval: lineage.approval,
            cleanup: lineage.cleanup,
            lineage: lineage.identity,
            lineageState: lineage.state,
            lineageFailureReason: lineage.reason,
            undoEligible: undoEligible(lineage),
            exactDetails: exactDetails
        )
        return ResolvedMission(
            summary: summary,
            timeline: timeline(for: aggregate),
            latestDate: aggregate.latestDate,
            orderHint: aggregate.orderHint,
            taskRank: taskRank
        )
    }

    static func resolveLineage(
        aggregate: MissionAggregate,
        session: AgentSession
    ) -> LineageResolution {
        var contradictions: [String] = []
        var incomplete: [String] = []
        if !aggregate.unscopedAuthority.isEmpty {
            incomplete.append(
                "Authority without an exact source mission task: "
                    + aggregate.unscopedAuthority.sorted().joined(separator: ", ")
            )
        }

        let patches = aggregate.patches.map(\.value)
        validateSingleValue(patches.map(\.patchID), label: "Candidate Patch ID", into: &contradictions)
        validateSingleValue(patches.map(\.sandboxID), label: "Sandbox ID", into: &contradictions)
        validateSingleValue(patches.map(\.sourceSnapshotID), label: "source snapshot", into: &contradictions)
        validateSingleValue(patches.map(\.canonicalLegacyRoot), label: "canonical Legacy root", into: &contradictions)
        validateSingleValue(patches.map(\.assessmentID), label: "assessment", into: &contradictions)
        validateSingleValue(patches.map(\.capabilityID), label: "capability", into: &contradictions)

        let plansByRevision = Dictionary(grouping: patches) { $0.planRevision ?? Int.min }
        for (revision, values) in plansByRevision where revision != Int.min {
            let planIDs = Set(values.compactMap(\.planID).map(normalized))
            if planIDs.count > 1 {
                contradictions.append("Candidate Patch plan revision \(revision) has conflicting Plan IDs")
            }
        }

        for patch in patches {
            guard let binding = patch.generatedTestSourceBinding else { continue }
            if binding.workspaceID != aggregate.workspaceID {
                contradictions.append("Candidate Patch workspace does not match the mission workspace")
            }
            if !patchMatchesCandidateBinding(patch, binding: binding) {
                contradictions.append("Candidate Patch snapshot contradicts its durable source binding")
            }
        }

        let selectedPatch = aggregate.patches.max { lhs, rhs in
            let leftRevision = lhs.value.planRevision ?? 0
            let rightRevision = rhs.value.planRevision ?? 0
            if leftRevision != rightRevision { return leftRevision < rightRevision }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return patchKey(lhs.value) < patchKey(rhs.value)
        }?.value

        let plans = aggregate.plans.map(\.value)
        var plansMatchingAnyPatch: [GeneratedTestActivitySnapshot] = []
        for plan in plans {
            if let workspaceID = plan.workspaceID.flatMap(UUID.init(uuidString:)),
               workspaceID != aggregate.workspaceID {
                contradictions.append("Generated Test Plan workspace does not match the mission workspace")
            }
            guard hasExactGeneratedPlanIdentity(plan) else {
                incomplete.append("Generated Test Plan exact identity is incomplete")
                continue
            }
            guard !patches.isEmpty else {
                incomplete.append("Generated Test Plan has no authoritative parent Candidate Patch")
                continue
            }
            let matches = patches.filter { planMatchesPatch(plan, patch: $0, missionID: aggregate.missionID) }
            if matches.isEmpty {
                if generatedPlanConflictsWithPatchAuthority(plan, patches: patches) {
                    contradictions.append("Generated Test Plan contradicts Candidate Patch authority")
                } else {
                    incomplete.append("Generated Test Plan parent Candidate Patch revision is unavailable")
                }
            } else {
                plansMatchingAnyPatch.append(plan)
            }
        }

        let selectedPatchPlans = selectedPatch.map { selected in
            plansMatchingAnyPatch.filter {
                planMatchesPatch($0, patch: selected, missionID: aggregate.missionID)
            }
        } ?? []
        let selectedPlan = selectedPatchPlans.max { lhs, rhs in
            let leftRevision = lhs.generatedTestPlanRevision ?? 0
            let rightRevision = rhs.generatedTestPlanRevision ?? 0
            if leftRevision != rightRevision { return leftRevision < rightRevision }
            return generatedPlanKey(lhs) < generatedPlanKey(rhs)
        }

        let artifacts = aggregate.artifacts.map(\.value)
        var artifactsMatchingAnyChain: [GeneratedTestArtifact] = []
        for artifact in artifacts {
            let binding = artifact.sourceBinding.generatedTestSourceBinding
            if binding.workspaceID != aggregate.workspaceID {
                contradictions.append("Generated Test Artifact workspace does not match the mission workspace")
                continue
            }
            let matchingPatches = patches.filter {
                artifactMatchesPatch(artifact, patch: $0, missionID: aggregate.missionID)
            }
            if matchingPatches.isEmpty {
                if artifactConflictsWithPatchAuthority(artifact, patches: patches) {
                    contradictions.append("Generated Test Artifact contradicts Candidate Patch authority")
                } else {
                    incomplete.append("Generated Test Artifact parent Candidate Patch is unavailable")
                }
                continue
            }
            let matchingPlans = plans.filter { artifactMatchesPlan(artifact, plan: $0) }
            if matchingPlans.isEmpty {
                if plans.isEmpty {
                    incomplete.append("Generated Test Artifact parent Plan is unavailable")
                } else {
                    contradictions.append("Generated Test Artifact contradicts Generated Test Plan authority")
                }
                continue
            }
            artifactsMatchingAnyChain.append(artifact)
        }

        let selectedArtifact: GeneratedTestArtifact? = if let selectedPatch, let selectedPlan {
            artifactsMatchingAnyChain
                .filter {
                    artifactMatchesPatch($0, patch: selectedPatch, missionID: aggregate.missionID)
                        && artifactMatchesPlan($0, plan: selectedPlan)
                }
                .max { lhs, rhs in
                    if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
                    return lhs.artifactID.uuidString < rhs.artifactID.uuidString
                }
        } else {
            nil
        }

        if selectedPatch != nil, !plans.isEmpty, selectedPatchPlans.isEmpty {
            // Plans may correctly belong to an older Candidate Patch revision.
            // They remain timeline evidence and are not attached to the frontier.
        }
        if selectedPlan != nil,
           !artifacts.isEmpty,
           selectedArtifact == nil,
           artifactsMatchingAnyChain.contains(where: { artifactMatchesPlan($0, plan: selectedPlan!) }) {
            contradictions.append("Generated Test Artifact does not match the selected Candidate Patch revision")
        }

        let cleanup = aggregate.cleanups.max { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.missionID.uuidString < rhs.missionID.uuidString
        }
        if aggregate.cleanups.contains(where: { $0.workspaceID != aggregate.workspaceID }) {
            contradictions.append("Cleanup workspace does not match the mission workspace")
        }
        if let cleanup, let selectedPatch, !cleanupMatchesPatch(cleanup, patch: selectedPatch) {
            contradictions.append("Cleanup authority contradicts the selected Candidate Patch")
        }

        let approval = exactPendingApproval(
            aggregate.approvals,
            workspaceID: aggregate.workspaceID,
            patch: selectedPatch
        )
        if aggregate.approvals.contains(where: { $0.workspaceID != aggregate.workspaceID }) {
            contradictions.append("Candidate Patch review workspace does not match the mission workspace")
        }

        if let selectedPatch {
            let needsAppliedAuthority = selectedPatch.projectionState == .patchReady
                || selectedPatch.projectionState == .reverted
                || selectedPatch.projectionState == .sandboxDestroyed
                || selectedPatch.status == .reviewReady
                || selectedPatch.status == .applied
                || selectedPatch.status == .reverted
            if needsAppliedAuthority && !hasCompleteAppliedPatchIdentity(selectedPatch) {
                incomplete.append("Candidate Patch applied authority is incomplete")
            }
        }

        let state: MissionLineageState
        let reason: String?
        if !contradictions.isEmpty {
            state = .contradictory
            reason = Array(Set(contradictions)).sorted().joined(separator: ". ")
        } else if !incomplete.isEmpty {
            state = .incomplete
            reason = Array(Set(incomplete)).sorted().joined(separator: ". ")
        } else {
            state = .exact
            reason = nil
        }

        let identity = missionIdentity(
            aggregate: aggregate,
            session: session,
            patch: selectedPatch,
            plan: selectedPlan,
            artifact: selectedArtifact
        )
        return LineageResolution(
            state: state,
            reason: reason,
            patch: selectedPatch,
            plan: selectedPlan,
            artifact: selectedArtifact,
            approval: approval,
            cleanup: cleanup,
            identity: identity
        )
    }

    static func resolveState(
        session: AgentSession,
        activity: AgentConversationActivity?,
        lineage: LineageResolution
    ) -> (
        stage: MissionProgressStage,
        phase: MissionPresentationPhase,
        result: String,
        primaryAction: MissionPrimaryAction?
    ) {
        if lineage.state == .contradictory {
            return (
                .assess,
                .failed,
                "Conflicting mission authority was isolated. No review, generation, or cleanup action is available.",
                nil
            )
        }
        if lineage.state == .incomplete {
            return (
                .assess,
                .failed,
                "Exact mission authority could not be restored. This run is read-only and failed closed.",
                nil
            )
        }
        if let cleanup = lineage.cleanup {
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
        if activity?.kind == .blocked || activity?.kind == .candidatePatchBlocked
            || activity?.kind == .generatedTestPlanningBlocked
            || session.interactionState == .blocked {
            return (.assess, .blocked, activity?.metadata.blockerReason ?? "This run needs attention before it can continue.", .resolveBlocker)
        }
        if let artifact = lineage.artifact, let revision = artifact.currentRevision {
            switch artifact.reviewState(for: revision.revision) {
            case .awaitingReview:
                return (.reviewTests, .awaitingTestReview, "Generated test files are ready for review.", .reviewProposedTests)
            case .approved:
                return (.ready, .ready, "Approved review artifacts are ready for a future phase.", nil)
            case .rejected:
                return (.reviewTests, .failed, "The proposed test files were rejected. No files were written or executed.", nil)
            case .changeRequested:
                return (.reviewTests, .preparingTestReview, "Changes were requested for the proposed test files.", nil)
            }
        }
        if let plan = lineage.plan {
            switch plan.status {
            case .testPlanReviewReady:
                return (
                    .reviewTests,
                    .preparingTestReview,
                    "Proposed tests are ready for review.",
                    .reviewProposedTests
                )
            case .clarificationRequired:
                return (.reviewTests, .blocked, "More information is needed before proposed tests can be reviewed.", .resolveBlocker)
            case .blocked, .failed, .rejected:
                return (.reviewTests, .blocked, MissionStatusLanguage.humanReadable(plan.status.rawValue), .resolveBlocker)
            default:
                return (.reviewTests, .preparingTestReview, "Preparing proposed tests for review.", nil)
            }
        }
        if lineage.approval != nil {
            return (.reviewChange, .awaitingChangeReview, "A proposed change is ready for your review.", .reviewProposedChange)
        }
        if let patch = lineage.patch {
            if patch.projectionState == .sandboxDestroyed {
                return (.ready, .cleanedUp, "The temporary workspace was cleaned up.", nil)
            }
            if patch.projectionState == .reverted || patch.status == .reverted {
                return (.ready, .cleanedUp, "The proposed change was reverted safely.", nil)
            }
            if patch.status == .rejected {
                return (.reviewChange, .failed, "The proposed change was rejected.", nil)
            }
            if patch.projectionState == .patchReady || patch.status == .reviewReady || patch.status == .applied {
                return (.reviewChange, .applyingInSandbox, "The proposed change is isolated in the Safe Sandbox.", .continueToTestReview)
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
        return (
            .assess,
            .assessing,
            running ? "Assessing the selected Legacy." : "Ready to assess the selected Legacy.",
            running ? .continueAssessment : .assessSystem
        )
    }

    static func missionIdentity(
        aggregate: MissionAggregate,
        session: AgentSession,
        patch: CandidatePatchActivitySnapshot?,
        plan: GeneratedTestActivitySnapshot?,
        artifact: GeneratedTestArtifact?
    ) -> MissionRunIdentity {
        let artifactBinding = artifact?.sourceBinding.generatedTestSourceBinding
        let artifactRevision = artifact?.currentRevision
        let canonicalRoot = patch?.canonicalLegacyRoot
            ?? plan?.canonicalLegacyRoot
            ?? artifactBinding?.canonicalLegacyRoot
            ?? (aggregate.isSelectedSessionMission ? session.workspaceContext.localProjectRoot : nil)
        let sourceSnapshot = patch?.sourceSnapshotID ?? artifactBinding?.sourceSnapshotID
        let assessment = patch?.assessmentID ?? plan?.assessmentID ?? artifactBinding?.validatedAssessmentID
        let fields = [
            "workspace=\(aggregate.workspaceID.uuidString.lowercased())",
            "mission=\(aggregate.missionID.uuidString.lowercased())",
            "legacy=\(canonicalRoot ?? "-")",
            "snapshot=\(sourceSnapshot ?? "-")",
            "assessment=\(assessment ?? "-")",
            "patch=\(patch?.patchID ?? artifactBinding?.patchID.rawValue ?? "-")",
            "patch-plan=\(patch?.planID ?? artifactBinding?.candidatePatchPlanID.uuidString.lowercased() ?? "-")",
            "patch-revision=\(patch?.planRevision.map(String.init) ?? artifactBinding.map { String($0.candidatePatchPlanRevision) } ?? "-")",
            "patch-manifest=\(patch?.manifestID ?? artifactBinding?.candidatePatchManifestID ?? "-")",
            "patch-sha=\(patch?.candidatePatchArtifactSHA256 ?? artifactBinding?.candidatePatchArtifactSHA256 ?? "-")",
            "sandbox=\(patch?.sandboxID ?? artifactBinding?.sandboxID.rawValue ?? "-")",
            "test-task=\(plan?.planningTaskID ?? artifactBinding?.generatedTestPlanningTaskID.uuidString.lowercased() ?? "-")",
            "test-plan=\(plan?.generatedTestPlanID ?? artifact?.sourceBinding.generatedTestPlanID.uuidString.lowercased() ?? "-")",
            "test-plan-revision=\(plan?.generatedTestPlanRevision.map(String.init) ?? artifact.map { String($0.sourceBinding.generatedTestPlanRevision) } ?? "-")",
            "test-plan-sha=\(plan?.generatedTestPlanSHA256 ?? artifact?.sourceBinding.generatedTestPlanSHA256 ?? "-")",
            "artifact=\(artifact?.artifactID.uuidString.lowercased() ?? "-")",
            "artifact-revision=\(artifactRevision.map { String($0.revision) } ?? "-")",
            "artifact-sha=\(artifactRevision?.digest.sha256 ?? "-")"
        ]
        return MissionRunIdentity(
            missionRunID: aggregate.missionID,
            workspaceID: aggregate.workspaceID,
            sourceCandidatePatchTaskID: aggregate.missionID,
            lineageKey: fields.joined(separator: "|"),
            canonicalLegacyRoot: canonicalRoot,
            sourceSnapshotID: sourceSnapshot,
            assessmentID: assessment,
            candidatePatchID: patch?.patchID ?? artifactBinding?.patchID.rawValue,
            candidatePatchPlanID: patch?.planID ?? artifactBinding?.candidatePatchPlanID.uuidString.lowercased(),
            candidatePatchPlanRevision: patch?.planRevision ?? artifactBinding?.candidatePatchPlanRevision,
            sandboxID: patch?.sandboxID ?? artifactBinding?.sandboxID.rawValue,
            generatedTestPlanningTaskID: plan?.planningTaskID ?? artifactBinding?.generatedTestPlanningTaskID.uuidString.lowercased(),
            generatedTestPlanID: plan?.generatedTestPlanID ?? artifact?.sourceBinding.generatedTestPlanID.uuidString.lowercased(),
            generatedTestPlanRevision: plan?.generatedTestPlanRevision ?? artifact?.sourceBinding.generatedTestPlanRevision,
            generatedTestPlanSHA256: plan?.generatedTestPlanSHA256 ?? artifact?.sourceBinding.generatedTestPlanSHA256,
            generatedTestArtifactID: artifact?.artifactID.uuidString.lowercased(),
            generatedTestArtifactRevision: artifactRevision?.revision,
            generatedTestArtifactSHA256: artifactRevision?.digest.sha256,
            candidatePatchManifestID: patch?.manifestID ?? artifactBinding?.candidatePatchManifestID,
            candidatePatchArtifactSHA256: patch?.candidatePatchArtifactSHA256 ?? artifactBinding?.candidatePatchArtifactSHA256,
            validationTestPlanSHA256: patch?.validationTestPlanSHA256 ?? artifactBinding?.validationTestPlanSHA256,
            unifiedDiffSHA256: patch?.unifiedDiffSHA256 ?? artifactBinding?.unifiedDiffSHA256
        )
    }

    static func undoEligible(_ lineage: LineageResolution) -> Bool {
        guard lineage.state == .exact,
              lineage.cleanup?.freezesMissionActions != true else {
            return false
        }
        guard let patch = lineage.patch else { return true }
        let needsAppliedAuthority = patch.projectionState == .patchReady
            || patch.projectionState == .reverted
            || patch.projectionState == .sandboxDestroyed
            || patch.status == .reviewReady
            || patch.status == .applied
            || patch.status == .reverted
        guard patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == lineage.identity.missionRunID,
              patch.patchID != nil,
              patch.planID.flatMap(UUID.init(uuidString:)) != nil,
              (patch.planRevision ?? 0) > 0,
              patch.sourceSnapshotID != nil,
              patch.canonicalLegacyRoot != nil,
              patch.assessmentID != nil else {
            return false
        }
        if needsAppliedAuthority {
            return patch.sandboxID.flatMap(SandboxID.init(rawValue:)) != nil
                && patch.candidatePatchArtifactSHA256?.count == 64
                && patch.manifestID != nil
        }
        return true
    }

    static func isOlder(_ lhs: ResolvedMission, _ rhs: ResolvedMission) -> Bool {
        if lhs.taskRank != rhs.taskRank { return lhs.taskRank < rhs.taskRank }
        if lhs.latestDate != rhs.latestDate { return lhs.latestDate < rhs.latestDate }
        if lhs.orderHint != rhs.orderHint { return lhs.orderHint < rhs.orderHint }
        return lhs.summary.missionID.uuidString < rhs.summary.missionID.uuidString
    }

    static func historyEntry(_ mission: ResolvedMission) -> MissionHistoryEntry {
        let summary = mission.summary
        return MissionHistoryEntry(
            historyID: "mission-run:\(summary.missionID.uuidString.lowercased())",
            missionID: summary.missionID,
            title: summary.title,
            completedAt: mission.latestDate == .distantPast ? nil : mission.latestDate,
            finalOutcome: historicalOutcome(summary),
            patchLifecycle: summary.candidatePatch.map {
                MissionStatusLanguage.humanReadable(
                    $0.projectionState?.rawValue ?? $0.status?.rawValue.uppercased() ?? "UNKNOWN"
                )
            } ?? "Not created",
            artifactReviewOutcome: artifactReviewOutcome(summary.generatedTestArtifact),
            cleanupOutcome: cleanupOutcome(summary.cleanup, patch: summary.candidatePatch),
            timeline: mission.timeline,
            exactDetails: summary.exactDetails
        )
    }

    static func historicalOutcome(_ summary: MissionSummary) -> String {
        if summary.lineageState != .exact { return "Failed safely" }
        let artifactOutcome = artifactReviewOutcome(summary.generatedTestArtifact)
        if summary.cleanup?.phase == .cleanedUp
            || summary.candidatePatch?.projectionState == .sandboxDestroyed {
            return artifactOutcome == "Approved"
                ? "Approved, temporary workspace cleaned up"
                : "Temporary workspace cleaned up"
        }
        if artifactOutcome != "Not available" { return artifactOutcome }
        if summary.candidatePatch?.status == .rejected { return "Rejected" }
        if let plan = summary.generatedTestPlan {
            return MissionStatusLanguage.humanReadable(plan.status.rawValue)
        }
        if let patch = summary.candidatePatch {
            return MissionStatusLanguage.humanReadable(
                patch.projectionState?.rawValue ?? patch.status?.rawValue.uppercased() ?? "UNKNOWN"
            )
        }
        return summary.result
    }

    static func timeline(for aggregate: MissionAggregate) -> [MissionHistoryEvent] {
        var events: [String: MissionHistoryEvent] = [:]
        func add(_ event: MissionHistoryEvent) { events[event.id] = event }

        for indexed in aggregate.patches {
            let patch = indexed.value
            let lifecycle = patch.lifecycleEvents ?? patch.projectionState.map { [$0] } ?? []
            if lifecycle.isEmpty {
                let state = patch.status?.rawValue.uppercased() ?? "UNKNOWN"
                add(MissionHistoryEvent(
                    eventID: "patch:\(patchKey(patch)):\(state)",
                    title: "Candidate Patch",
                    outcome: MissionStatusLanguage.humanReadable(state),
                    occurredAt: nil,
                    exactDetails: patchTimelineDetails(patch)
                ))
            } else {
                for state in lifecycle {
                    add(MissionHistoryEvent(
                        eventID: "patch:\(patchKey(patch)):\(state.rawValue)",
                        title: "Candidate Patch",
                        outcome: MissionStatusLanguage.humanReadable(state.rawValue),
                        occurredAt: nil,
                        exactDetails: patchTimelineDetails(patch)
                    ))
                }
            }
        }
        for indexed in aggregate.plans {
            let plan = indexed.value
            add(MissionHistoryEvent(
                eventID: "test-plan:\(generatedPlanKey(plan)):\(plan.status.rawValue)",
                title: "Generated Test Plan",
                outcome: MissionStatusLanguage.humanReadable(plan.status.rawValue),
                occurredAt: nil,
                exactDetails: planTimelineDetails(plan)
            ))
        }
        for indexed in aggregate.artifacts {
            let artifact = indexed.value
            for revision in artifact.revisions.sorted(by: { $0.revision < $1.revision }) {
                let review = artifact.reviewState(for: revision.revision)
                add(MissionHistoryEvent(
                    eventID: "artifact:\(artifact.artifactID.uuidString.lowercased()):\(revision.revision):\(review.rawValue)",
                    title: "Generated Test Artifact revision \(revision.revision)",
                    outcome: MissionStatusLanguage.humanReadable(review.rawValue),
                    occurredAt: revision.createdAt,
                    exactDetails: [
                        MissionExactDetail(label: "Artifact ID", value: artifact.artifactID.uuidString.lowercased()),
                        MissionExactDetail(label: "Artifact revision", value: String(revision.revision)),
                        MissionExactDetail(label: "Artifact SHA-256", value: revision.digest.sha256)
                    ]
                ))
            }
        }
        for cleanup in aggregate.cleanups {
            add(MissionHistoryEvent(
                eventID: "cleanup:\(cleanup.missionID.uuidString.lowercased()):\(cleanup.phase.rawValue)",
                title: "Undo and cleanup",
                outcome: MissionStatusLanguage.humanReadable(cleanup.phase.rawValue),
                occurredAt: cleanup.updatedAt,
                exactDetails: [
                    MissionExactDetail(label: "Mission ID", value: cleanup.missionID.uuidString.lowercased()),
                    MissionExactDetail(label: "Cleanup phase", value: cleanup.phase.rawValue)
                ]
            ))
        }
        return events.values.sorted { lhs, rhs in
            switch (lhs.occurredAt, rhs.occurredAt) {
            case let (left?, right?) where left != right: return left < right
            case (nil, .some): return true
            case (.some, nil): return false
            default: return lhs.id < rhs.id
            }
        }
    }

    static func progress(
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

    static func safetySummary(
        patch: CandidatePatchActivitySnapshot?,
        plan: GeneratedTestActivitySnapshot?,
        artifact: GeneratedTestArtifact?,
        lineageState: MissionLineageState
    ) -> String {
        if lineageState != .exact {
            return "Fail-closed read-only view · No review, generation, Undo, or cleanup authority"
        }
        if let artifact, let revision = artifact.currentRevision {
            return "\(revision.scenarioBindings.count) scenarios · \(revision.virtualFiles.count) virtual \(revision.virtualFiles.count == 1 ? "file" : "files") · No test files were written, compiled, or executed."
        }
        if plan?.status == .testPlanReviewReady {
            return "No test files were written, compiled, or executed."
        }
        if let patch {
            return "Safe Sandbox only · Original Legacy \(patch.sourceIntegrity == .unchanged ? "unchanged" : "not modified by this view") · Build and Tests unavailable"
        }
        return "Read-only assessment · No Build, Tests, Shell, Git, or deployment"
    }

    static func missionTitle(
        session: AgentSession,
        missionID: UUID,
        patch: CandidatePatchActivitySnapshot?,
        plan: GeneratedTestActivitySnapshot?,
        artifact: GeneratedTestArtifact?
    ) -> String {
        if let label = patch?.capabilityDisplayLabel
            ?? patch?.capabilityID
            ?? artifact?.sourceBinding.generatedTestSourceBinding.capabilityDisplayLabel
            ?? plan?.capabilityID,
           !label.isEmpty {
            return plainTitle(label)
        }
        if missionID == session.runtimeTaskID,
           let taskTitle = session.workspaceContext.runtimeTaskTitle,
           !taskTitle.isEmpty {
            return taskTitle
        }
        let firstLine = session.userGoal.split(whereSeparator: \.isNewline).first.map(String.init) ?? session.userGoal
        return firstLine.count > 72 ? String(firstLine.prefix(69)) + "…" : firstLine
    }

    static func plainTitle(_ raw: String) -> String {
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

    static func exactDetails(identity: MissionRunIdentity) -> [MissionExactDetail] {
        var details = [
            MissionExactDetail(label: "Mission Run ID", value: identity.missionRunID.uuidString.lowercased()),
            MissionExactDetail(label: "Workspace ID", value: identity.workspaceID.uuidString.lowercased()),
            MissionExactDetail(label: "Candidate Patch source task", value: identity.sourceCandidatePatchTaskID.uuidString.lowercased()),
            MissionExactDetail(label: "Mission lineage key", value: identity.lineageKey)
        ]
        func add(_ label: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            details.append(MissionExactDetail(label: label, value: value))
        }
        add("Canonical Legacy root", identity.canonicalLegacyRoot)
        add("Source snapshot ID", identity.sourceSnapshotID)
        add("Assessment ID", identity.assessmentID)
        add("Candidate Patch ID", identity.candidatePatchID)
        add("Candidate Patch plan ID", identity.candidatePatchPlanID)
        add("Candidate Patch plan revision", identity.candidatePatchPlanRevision.map(String.init))
        add("Candidate Patch manifest ID", identity.candidatePatchManifestID)
        add("Candidate Patch artifact SHA-256", identity.candidatePatchArtifactSHA256)
        add("Sandbox ID", identity.sandboxID)
        add("Validation Test Plan SHA-256", identity.validationTestPlanSHA256)
        add("Unified Diff SHA-256", identity.unifiedDiffSHA256)
        add("Generated Test planning task", identity.generatedTestPlanningTaskID)
        add("Generated Test Plan ID", identity.generatedTestPlanID)
        add("Generated Test Plan revision", identity.generatedTestPlanRevision.map(String.init))
        add("Generated Test Plan SHA-256", identity.generatedTestPlanSHA256)
        add("Generated Test Artifact ID", identity.generatedTestArtifactID)
        add("Generated Test Artifact revision", identity.generatedTestArtifactRevision.map(String.init))
        add("Generated Test Artifact SHA-256", identity.generatedTestArtifactSHA256)
        return details
    }

    static func patchTimelineDetails(_ patch: CandidatePatchActivitySnapshot) -> [MissionExactDetail] {
        [
            patch.patchID.map { MissionExactDetail(label: "Candidate Patch ID", value: $0) },
            patch.planID.map { MissionExactDetail(label: "Candidate Patch plan ID", value: $0) },
            patch.planRevision.map { MissionExactDetail(label: "Candidate Patch plan revision", value: String($0)) },
            patch.sandboxID.map { MissionExactDetail(label: "Sandbox ID", value: $0) }
        ].compactMap { $0 }
    }

    static func planTimelineDetails(_ plan: GeneratedTestActivitySnapshot) -> [MissionExactDetail] {
        [
            plan.generatedTestPlanID.map { MissionExactDetail(label: "Generated Test Plan ID", value: $0) },
            plan.generatedTestPlanRevision.map { MissionExactDetail(label: "Generated Test Plan revision", value: String($0)) },
            plan.generatedTestPlanSHA256.map { MissionExactDetail(label: "Generated Test Plan SHA-256", value: $0) }
        ].compactMap { $0 }
    }

    static func artifactReviewOutcome(_ artifact: GeneratedTestArtifact?) -> String {
        guard let artifact, let revision = artifact.currentRevision else { return "Not available" }
        return MissionStatusLanguage.humanReadable(artifact.reviewState(for: revision.revision).rawValue)
    }

    static func cleanupOutcome(
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

    static func validateSingleValue(
        _ values: [String?],
        label: String,
        into contradictions: inout [String]
    ) {
        let exact = Set(values.compactMap { $0?.nonEmpty }.map(normalized))
        if exact.count > 1 { contradictions.append("Conflicting \(label)") }
    }

    static func normalized(_ value: String) -> String { value.lowercased() }

    static func patchKey(_ patch: CandidatePatchActivitySnapshot) -> String {
        [
            patch.planRevision.map(String.init) ?? "0",
            patch.planID ?? "-",
            patch.patchID ?? "-",
            patch.sandboxID ?? "-"
        ].joined(separator: ":").lowercased()
    }

    static func generatedPlanKey(_ plan: GeneratedTestActivitySnapshot) -> String {
        [
            plan.generatedTestPlanRevision.map(String.init) ?? "0",
            plan.generatedTestPlanID ?? "-",
            plan.generatedTestPlanSHA256 ?? "-"
        ].joined(separator: ":").lowercased()
    }

    static func hasExactGeneratedPlanIdentity(_ plan: GeneratedTestActivitySnapshot) -> Bool {
        plan.generatedTestPlanID.flatMap(UUID.init(uuidString:)) != nil
            && (plan.generatedTestPlanRevision ?? 0) > 0
            && plan.generatedTestPlanSHA256?.count == 64
            && plan.generatedTestSourceBindingSHA256?.count == 64
            && plan.planningTaskID.flatMap(UUID.init(uuidString:)) != nil
            && plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) != nil
            && plan.patchID.flatMap(CandidatePatchID.init(rawValue:)) != nil
            && plan.candidatePatchArtifactSHA256?.count == 64
            && plan.sandboxID.flatMap(SandboxID.init(rawValue:)) != nil
            && plan.sourceSnapshotID != nil
            && plan.assessmentID != nil
            && plan.workspaceID.flatMap(UUID.init(uuidString:)) != nil
            && plan.candidatePatchPlanID.flatMap(UUID.init(uuidString:)) != nil
            && (plan.candidatePatchPlanRevision ?? 0) > 0
            && plan.candidatePatchManifestID != nil
            && plan.canonicalLegacyRoot != nil
            && plan.capabilityID != nil
            && plan.validationTestPlanSHA256?.count == 64
            && plan.unifiedDiffSHA256?.count == 64
    }

    static func hasCompleteAppliedPatchIdentity(_ patch: CandidatePatchActivitySnapshot) -> Bool {
        patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) != nil
            && patch.patchID.flatMap(CandidatePatchID.init(rawValue:)) != nil
            && patch.planID.flatMap(UUID.init(uuidString:)) != nil
            && (patch.planRevision ?? 0) > 0
            && patch.manifestID != nil
            && patch.candidatePatchArtifactSHA256?.count == 64
            && patch.sandboxID.flatMap(SandboxID.init(rawValue:)) != nil
            && patch.sourceSnapshotID != nil
            && patch.canonicalLegacyRoot != nil
            && patch.assessmentID != nil
    }

    static func patchMatchesCandidateBinding(
        _ patch: CandidatePatchActivitySnapshot,
        binding: CandidatePatchGeneratedTestSourceBinding
    ) -> Bool {
        patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == binding.sourceCandidatePatchTaskID
            && patch.patchID == binding.patchID.rawValue
            && patch.planID.flatMap(UUID.init(uuidString:)) == binding.candidatePatchPlanID
            && patch.planRevision == binding.candidatePatchPlanRevision
            && patch.manifestID == binding.candidatePatchManifestID
            && patch.candidatePatchArtifactSHA256 == binding.candidatePatchArtifactSHA256
            && patch.sandboxID == binding.sandboxID.rawValue
            && patch.sourceSnapshotID == binding.sourceSnapshotID
            && patch.canonicalLegacyRoot == binding.canonicalLegacyRoot
            && patch.capabilityID == binding.normalizedCapabilityID
            && patch.assessmentID == binding.validatedAssessmentID
            && patch.validationTestPlanSHA256 == binding.validationTestPlanSHA256
            && patch.unifiedDiffSHA256 == binding.unifiedDiffSHA256
    }

    static func planMatchesPatch(
        _ plan: GeneratedTestActivitySnapshot,
        patch: CandidatePatchActivitySnapshot,
        missionID: UUID
    ) -> Bool {
        guard hasExactGeneratedPlanIdentity(plan),
              patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == missionID,
              plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == missionID else {
            return false
        }
        return plan.patchID == patch.patchID
            && plan.candidatePatchArtifactSHA256 == patch.candidatePatchArtifactSHA256
            && plan.sandboxID == patch.sandboxID
            && plan.sourceSnapshotID == patch.sourceSnapshotID
            && plan.assessmentID == patch.assessmentID
            && plan.capabilityID == patch.capabilityID
            && plan.candidatePatchPlanID.flatMap(UUID.init(uuidString:))
                == patch.planID.flatMap(UUID.init(uuidString:))
            && plan.candidatePatchPlanRevision == patch.planRevision
            && plan.candidatePatchManifestID == patch.manifestID
            && plan.canonicalLegacyRoot == patch.canonicalLegacyRoot
            && plan.validationTestPlanSHA256 == patch.validationTestPlanSHA256
            && plan.unifiedDiffSHA256 == patch.unifiedDiffSHA256
            && (patch.generatedTestSourceBinding != nil || hasCompleteAppliedPatchIdentity(patch))
    }

    static func generatedPlanConflictsWithPatchAuthority(
        _ plan: GeneratedTestActivitySnapshot,
        patches: [CandidatePatchActivitySnapshot]
    ) -> Bool {
        let patchIDs = Set(patches.compactMap(\.patchID))
        let sandboxes = Set(patches.compactMap(\.sandboxID))
        let snapshots = Set(patches.compactMap(\.sourceSnapshotID))
        let assessments = Set(patches.compactMap(\.assessmentID))
        return plan.patchID.map { !patchIDs.contains($0) } == true
            || plan.sandboxID.map { !sandboxes.contains($0) } == true
            || plan.sourceSnapshotID.map { !snapshots.contains($0) } == true
            || plan.assessmentID.map { !assessments.contains($0) } == true
            || plan.canonicalLegacyRoot.map {
                !Set(patches.compactMap(\.canonicalLegacyRoot)).contains($0)
            } == true
    }

    static func artifactMatchesPatch(
        _ artifact: GeneratedTestArtifact,
        patch: CandidatePatchActivitySnapshot,
        missionID: UUID
    ) -> Bool {
        let binding = artifact.sourceBinding.generatedTestSourceBinding
        return binding.sourceCandidatePatchTaskID == missionID
            && patch.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == missionID
            && patch.patchID == binding.patchID.rawValue
            && patch.planID.flatMap(UUID.init(uuidString:)) == binding.candidatePatchPlanID
            && patch.planRevision == binding.candidatePatchPlanRevision
            && patch.manifestID == binding.candidatePatchManifestID
            && patch.candidatePatchArtifactSHA256 == binding.candidatePatchArtifactSHA256
            && patch.sandboxID == binding.sandboxID.rawValue
            && patch.sourceSnapshotID == binding.sourceSnapshotID
            && patch.canonicalLegacyRoot == binding.canonicalLegacyRoot
            && patch.capabilityID == binding.normalizedCapabilityID
            && patch.assessmentID == binding.validatedAssessmentID
            && patch.validationTestPlanSHA256 == binding.validationTestPlanSHA256
            && patch.unifiedDiffSHA256 == binding.unifiedDiffSHA256
    }

    static func artifactConflictsWithPatchAuthority(
        _ artifact: GeneratedTestArtifact,
        patches: [CandidatePatchActivitySnapshot]
    ) -> Bool {
        guard !patches.isEmpty else { return false }
        let binding = artifact.sourceBinding.generatedTestSourceBinding
        return !Set(patches.compactMap(\.patchID)).contains(binding.patchID.rawValue)
            || !Set(patches.compactMap(\.sandboxID)).contains(binding.sandboxID.rawValue)
            || !Set(patches.compactMap(\.sourceSnapshotID)).contains(binding.sourceSnapshotID)
            || !Set(patches.compactMap(\.canonicalLegacyRoot)).contains(binding.canonicalLegacyRoot)
            || !Set(patches.compactMap(\.assessmentID)).contains(binding.validatedAssessmentID)
    }

    static func artifactMatchesPlan(
        _ artifact: GeneratedTestArtifact,
        plan: GeneratedTestActivitySnapshot
    ) -> Bool {
        let binding = artifact.sourceBinding.generatedTestSourceBinding
        return plan.generatedTestPlanID.flatMap(UUID.init(uuidString:)) == artifact.sourceBinding.generatedTestPlanID
            && plan.generatedTestPlanRevision == artifact.sourceBinding.generatedTestPlanRevision
            && plan.generatedTestPlanSHA256 == artifact.sourceBinding.generatedTestPlanSHA256
            && plan.generatedTestSourceBindingSHA256 == binding.digest
            && plan.planningTaskID.flatMap(UUID.init(uuidString:)) == binding.generatedTestPlanningTaskID
            && plan.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)) == binding.sourceCandidatePatchTaskID
            && plan.patchID == binding.patchID.rawValue
            && plan.candidatePatchArtifactSHA256 == binding.candidatePatchArtifactSHA256
            && plan.sandboxID == binding.sandboxID.rawValue
            && plan.sourceSnapshotID == binding.sourceSnapshotID
            && plan.capabilityID == binding.normalizedCapabilityID
            && plan.assessmentID == binding.validatedAssessmentID
    }

    static func cleanupMatchesPatch(
        _ cleanup: MissionCleanupState,
        patch: CandidatePatchActivitySnapshot
    ) -> Bool {
        cleanup.patchID == nil || (
            cleanup.patchID == patch.patchID
                && cleanup.patchPlanID == patch.planID
                && cleanup.patchRevision == patch.planRevision
                && cleanup.sandboxID == patch.sandboxID
                && cleanup.canonicalLegacyRoot == patch.canonicalLegacyRoot
                && (cleanup.sourceSnapshotID == nil || cleanup.sourceSnapshotID == patch.sourceSnapshotID)
                && (cleanup.candidatePatchManifestID == nil || cleanup.candidatePatchManifestID == patch.manifestID)
                && (cleanup.candidatePatchArtifactSHA256 == nil || cleanup.candidatePatchArtifactSHA256 == patch.candidatePatchArtifactSHA256)
                && (cleanup.assessmentID == nil || cleanup.assessmentID == patch.assessmentID)
        )
    }

    static func exactPendingApproval(
        _ approvals: [ApprovalRequest],
        workspaceID: UUID,
        patch: CandidatePatchActivitySnapshot?
    ) -> ApprovalRequest? {
        approvals
            .filter { approval in
                guard approval.workspaceID == workspaceID,
                      approval.state == .pending,
                      approval.targetKind == .candidatePatchPlan else {
                    return false
                }
                guard let patch else {
                    return approval.metadata["plan_id"].flatMap(UUID.init(uuidString:)) != nil
                        && approval.metadata["plan_revision"].flatMap(Int.init).map { $0 > 0 } == true
                }
                return approval.metadata["plan_id"].flatMap(UUID.init(uuidString:))
                        == patch.planID.flatMap(UUID.init(uuidString:))
                    && approval.metadata["plan_revision"].flatMap(Int.init) == patch.planRevision
            }
            .sorted { lhs, rhs in
                if lhs.requestedAt != rhs.requestedAt { return lhs.requestedAt > rhs.requestedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .first
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
