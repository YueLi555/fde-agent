import XCTest
@testable import FDECloudOS

final class MissionPresentationTests: XCTestCase {
    func testEveryActionableMissionStateHasOnePrimaryActionAndTerminalStateHasNoMutationCTA() {
        let fixture = Fixture()
        let base = fixture.project(session: fixture.session(interaction: .idle))
        XCTAssertEqual(base.current.primaryAction, .assessSystem)

        let running = fixture.project(session: fixture.session(interaction: .working))
        XCTAssertEqual(running.current.primaryAction, .continueAssessment)

        let assessment = fixture.project(
            session: fixture.session(interaction: .completed),
            activity: fixture.activity(
                kind: .completed,
                assessment: AIAssessmentActivitySnapshot(
                    capability: "Order lookup",
                    compatibility: .partial,
                    risk: .medium,
                    blockerCount: 0,
                    evidenceCount: 3
                )
            )
        )
        XCTAssertEqual(assessment.current.primaryAction, .reviewFindings)

        let approval = fixture.project(
            session: fixture.session(interaction: .waitingForApproval),
            approvals: [fixture.approval]
        )
        XCTAssertEqual(approval.current.primaryAction, .reviewProposedChange)

        let patch = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [fixture.patch(revision: 1, state: .patchReady)]
        )
        XCTAssertEqual(patch.current.primaryAction, .continueToTestReview)

        let plan = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [fixture.patch(revision: 1, state: .patchReady)],
            plans: [fixture.plan(status: .testPlanReviewReady)]
        )
        XCTAssertEqual(plan.current.primaryAction, .reviewProposedTests)

        let artifact = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [fixture.patch(revision: 1, state: .patchReady)],
            plans: [fixture.plan(status: .testPlanReviewReady)],
            artifacts: [fixture.artifact(review: .awaitingReview)]
        )
        XCTAssertEqual(artifact.current.primaryAction, .reviewProposedTests)

        let partialCleanup = fixture.project(
            session: fixture.session(interaction: .completed),
            cleanup: [fixture.cleanup(phase: .partialFailure)]
        )
        XCTAssertEqual(partialCleanup.current.primaryAction, .retryCleanup)

        let blocked = fixture.project(
            session: fixture.session(interaction: .blocked),
            activity: fixture.activity(kind: .blocked)
        )
        XCTAssertEqual(blocked.current.primaryAction, .resolveBlocker)

        for state in [base, running, assessment, approval, patch, plan, artifact, partialCleanup, blocked] {
            XCTAssertNotNil(state.current.primaryAction)
        }

        let terminal = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [fixture.patch(revision: 1, state: .patchReady)],
            plans: [fixture.plan(status: .testPlanReviewReady)],
            artifacts: [fixture.artifact(review: .approved)]
        )
        XCTAssertTrue(terminal.current.isTerminal)
        XCTAssertNil(terminal.current.primaryAction)
        XCTAssertEqual(terminal.primaryMutationActionCount, 0)
    }

    func testProgressAndHumanReadableStatusMappingsAreTruthful() {
        let fixture = Fixture()
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [fixture.patch(revision: 1, state: .patchReady)],
            plans: [fixture.plan(status: .testPlanReviewReady)],
            artifacts: [fixture.artifact(review: .awaitingReview)]
        )
        XCTAssertEqual(state.current.stage, .reviewTests)
        XCTAssertEqual(state.current.progress.map(\.status), [.complete, .complete, .needsReview, .pending])
        XCTAssertTrue(state.current.safetySummary.contains("No test files were written, compiled, or executed."))
        XCTAssertEqual(MissionStatusLanguage.humanReadable("TEST_PLAN_REVIEW_READY"), "Proposed tests ready")
        XCTAssertEqual(MissionStatusLanguage.humanReadable("TEST_ARTIFACT_REVIEW_READY"), "Test files ready for review")
        XCTAssertEqual(MissionStatusLanguage.humanReadable("CLARIFICATION_REQUIRED"), "More information needed")
        XCTAssertEqual(MissionStatusLanguage.humanReadable("PATCH_READY"), "Proposed change ready")
        XCTAssertEqual(MissionStatusLanguage.humanReadable("SANDBOX_DESTROYED"), "Temporary workspace cleaned up")
        XCTAssertFalse(state.current.result.lowercased().contains("tests passed"))
    }

    func testCurrentRunIsDeterministicAndOneMissionProducesOneHistoryRow() {
        let fixture = Fixture()
        let currentRevision = fixture.patch(revision: 3, state: .patchReady)
        let olderCurrentRevision = fixture.patch(revision: 2, state: .patchReady)
        let historicalA = fixture.patch(
            missionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            planID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
            revision: 1,
            state: .reverted
        )
        let historicalB = fixture.patch(
            missionID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
            planID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!,
            revision: 2,
            state: .sandboxDestroyed
        )
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [historicalA, currentRevision, historicalB, olderCurrentRevision, historicalA]
        )
        XCTAssertEqual(state.current.candidatePatch?.planRevision, 3)
        XCTAssertFalse(state.previousRunsExpandedByDefault)
        XCTAssertEqual(state.previousRuns.count, 1)
        XCTAssertEqual(Set(state.previousRuns.map(\.id)).count, state.previousRuns.count)
        XCTAssertTrue(state.previousRuns.allSatisfy { !$0.exposesMutationActions })
        XCTAssertEqual(state.previousRuns.first?.missionID, historicalA.sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)))
        XCTAssertTrue(state.previousRuns.first?.timeline.contains { $0.outcome == "Proposed change reverted" } == true)
        XCTAssertTrue(state.previousRuns.first?.timeline.contains { $0.outcome == "Temporary workspace cleaned up" } == true)
    }

    func testGeneratedTestPlanningChildRemainsInCandidatePatchMissionAndPresentsOneReviewCTA() throws {
        let fixture = Fixture()
        let patch = fixture.patch(revision: 1, state: .patchReady)
        let plan = fixture.plan(status: .testPlanReviewReady)
        let childActivity = fixture.activity(
            kind: .generatedTestPlanReviewReady,
            taskID: fixture.planningTaskID
        )
        let state = fixture.project(
            session: fixture.session(
                interaction: .completed,
                runtimeTaskID: fixture.planningTaskID,
                missionTaskIDs: [fixture.missionID, fixture.planningTaskID]
            ),
            activity: childActivity,
            candidates: [patch],
            plans: [plan]
        )

        XCTAssertEqual(state.current.missionID, fixture.missionID)
        XCTAssertEqual(state.current.lineage?.missionRunID, fixture.missionID)
        XCTAssertEqual(state.current.lineage?.sourceCandidatePatchTaskID, fixture.missionID)
        XCTAssertEqual(
            state.current.lineage?.generatedTestPlanningTaskID?.lowercased(),
            fixture.planningTaskID.uuidString.lowercased()
        )
        XCTAssertEqual(state.current.generatedTestPlan?.generatedTestPlanID, plan.generatedTestPlanID)
        XCTAssertEqual(state.current.title, "Customer Support AI Agent — Read Only Order Lookup")
        XCTAssertEqual(state.current.stage, .reviewTests)
        XCTAssertEqual(state.current.phase, .preparingTestReview)
        XCTAssertEqual(state.current.result, "Proposed tests are ready for review.")
        XCTAssertEqual(
            state.current.safetySummary,
            "No test files were written, compiled, or executed."
        )
        XCTAssertEqual(
            state.current.progress.map(\.status),
            [.complete, .complete, .active, .pending]
        )
        XCTAssertEqual(state.current.primaryAction, .reviewProposedTests)
        XCTAssertEqual(state.current.primaryAction?.label, "Review proposed tests")
        XCTAssertNotEqual(state.current.primaryAction, .assessSystem)
        XCTAssertEqual(state.previousRuns.count, 0)
        XCTAssertTrue(state.current.exactDetails.contains {
            $0.label == "Generated Test Plan SHA-256"
                && $0.value == plan.generatedTestPlanSHA256
        })
    }

    func testRestartWithPlanningChildSelectedRestoresSameMissionStageAndHistoryGrouping() {
        let fixture = Fixture()
        let patch = fixture.patch(revision: 1, state: .patchReady)
        let plan = fixture.plan(status: .testPlanReviewReady)
        let restoredSession = fixture.session(
            interaction: .completed,
            runtimeTaskID: fixture.planningTaskID,
            missionTaskIDs: [fixture.missionID, fixture.planningTaskID]
        )

        let first = fixture.project(
            session: restoredSession,
            candidates: [patch],
            plans: [plan]
        )
        let restarted = fixture.project(
            session: restoredSession,
            candidates: [patch],
            plans: [plan]
        )

        XCTAssertEqual(first.current.lineage, restarted.current.lineage)
        XCTAssertEqual(restarted.current.missionID, fixture.missionID)
        XCTAssertEqual(restarted.current.stage, .reviewTests)
        XCTAssertEqual(restarted.current.primaryAction, .reviewProposedTests)
        XCTAssertEqual(restarted.previousRuns.count, 0)
    }

    func testExistingArtifactOpensReviewAndPersistedDecisionRemovesStaleCTA() {
        let fixture = Fixture()
        let patch = fixture.patch(revision: 1, state: .patchReady)
        let plan = fixture.plan(status: .testPlanReviewReady)
        let awaiting = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch],
            plans: [plan],
            artifacts: [fixture.artifact(review: .awaitingReview)]
        )
        XCTAssertEqual(awaiting.current.primaryAction, .reviewProposedTests)

        let decided = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch],
            plans: [plan],
            artifacts: [fixture.artifact(review: .approved)]
        )
        XCTAssertNil(decided.current.primaryAction)
        XCTAssertEqual(decided.current.phase, .ready)
    }

    func testPhase3AArtifactsRemainChildrenOfExactReadyMissionWithOneCTA() throws {
        let fixture = Fixture()
        let patch = fixture.patch(revision: 1, state: .patchReady)
        let plan = fixture.plan(status: .testPlanReviewReady)
        let artifact = fixture.artifact(review: .approved)
        let before = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch],
            plans: [plan],
            artifacts: [artifact]
        )
        XCTAssertEqual(before.current.phase, .ready)
        XCTAssertEqual(before.current.postReadyAction, .reviewProductionReadiness)

        let phase3A = try fixture.phase3Artifacts(for: artifact)
        let restored = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch],
            plans: [plan],
            artifacts: [artifact],
            readinessReports: [phase3A.report],
            evalPlans: [phase3A.evalPlan]
        )
        XCTAssertEqual(restored.current.missionID, fixture.missionID)
        XCTAssertEqual(restored.current.productionReadinessReport?.reportID, phase3A.report.reportID)
        XCTAssertEqual(restored.current.aiEvalPlan?.planID, phase3A.evalPlan.planID)
        XCTAssertEqual(restored.current.postReadyAction, .reviewProductionReadiness)
        XCTAssertEqual(restored.previousRuns.count, 0)
        XCTAssertTrue(restored.current.undoEligible)
        let undo = try XCTUnwrap(MissionUndoRequest(summary: restored.current, workspaceID: fixture.workspaceID))
        XCTAssertEqual(undo.missionID, fixture.missionID)
        XCTAssertEqual(undo.patchID, patch.patchID)
        XCTAssertEqual(undo.sandboxID, patch.sandboxID)
    }

    func testApprovedReadyMissionWithoutPhase3PairExposesExactlyOneProductionReadinessCTA() {
        let fixture = Fixture()
        let artifact = fixture.artifact(review: .approved)
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [fixture.patch(revision: 1, state: .patchReady)],
            plans: [fixture.plan(status: .testPlanReviewReady)],
            artifacts: [artifact],
            readinessReports: [],
            evalPlans: []
        )

        XCTAssertEqual(state.current.phase, .ready)
        XCTAssertEqual(state.current.lineageState, .exact)
        XCTAssertEqual(
            artifact.currentRevision.map { artifact.reviewState(for: $0.revision) },
            .approved
        )
        XCTAssertNil(state.current.productionReadinessReport)
        XCTAssertNil(state.current.aiEvalPlan)
        XCTAssertEqual(
            [state.current.primaryAction?.label, state.current.postReadyAction?.label]
                .compactMap { $0 },
            ["Review production readiness"]
        )
        XCTAssertTrue(state.current.undoEligible)
        XCTAssertEqual(state.previousRuns.count, 0)
    }

    func testPhase3ARestorationFailureSuppressesReviewWithoutChangingExactUndoAuthority() {
        let fixture = Fixture()
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [fixture.patch(revision: 1, state: .patchReady)],
            plans: [fixture.plan(status: .testPlanReviewReady)],
            artifacts: [fixture.artifact(review: .approved)],
            phase3ARestorationFailure: "Persisted artifact digest mismatch"
        )
        XCTAssertEqual(state.current.lineageState, .exact)
        XCTAssertTrue(state.current.undoEligible)
        XCTAssertNil(state.current.postReadyAction)
        XCTAssertNotNil(state.current.phase3APlanningFailureReason)
    }

    func testAdvancedDetailsKeepFullExactValuesOutOfDefaultSummary() throws {
        let fixture = Fixture()
        let patch = fixture.patch(revision: 1, state: .patchReady)
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch]
        )
        let fullPatchID = try XCTUnwrap(patch.patchID)
        XCTAssertTrue(state.current.exactDetails.contains { $0.value == fullPatchID })
        XCTAssertFalse(state.current.title.contains(fullPatchID))
        XCTAssertFalse(state.current.result.contains(fullPatchID))
        XCTAssertFalse(state.current.safetySummary.contains(fullPatchID))
    }

    func testSyntheticLegacyPatchCannotCombineWithTestableLegacyPlanOrArtifact() throws {
        let fixture = Fixture()
        let testableMissionID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let testableCandidatePlanID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let testablePlanningTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let syntheticPatch = fixture.patch(
            canonicalLegacyRoot: "/demo/SyntheticLegacy",
            revision: 1,
            state: .patchReady
        )
        let testablePatch = fixture.patch(
            missionID: testableMissionID,
            planID: testableCandidatePlanID,
            canonicalLegacyRoot: "/demo/TestableLegacy",
            revision: 1,
            state: .patchReady
        )
        let testablePlan = fixture.plan(
            missionID: testableMissionID,
            planningTaskID: testablePlanningTaskID,
            candidatePlanID: testableCandidatePlanID,
            canonicalLegacyRoot: "/demo/TestableLegacy",
            status: .testPlanReviewReady
        )
        let testableArtifact = fixture.artifact(
            missionID: testableMissionID,
            planningTaskID: testablePlanningTaskID,
            candidatePlanID: testableCandidatePlanID,
            canonicalLegacyRoot: "/demo/TestableLegacy",
            review: .approved
        )

        let state = fixture.project(
            session: fixture.session(
                interaction: .completed,
                missionTaskIDs: [testableMissionID, fixture.missionID],
                legacyRoot: "/demo/SyntheticLegacy"
            ),
            candidates: [testablePatch, syntheticPatch],
            plans: [testablePlan],
            artifacts: [testableArtifact]
        )

        XCTAssertEqual(state.current.missionID, fixture.missionID)
        XCTAssertEqual(state.current.legacyRoot, "/demo/SyntheticLegacy")
        XCTAssertEqual(state.current.candidatePatch?.patchID, syntheticPatch.patchID)
        XCTAssertNil(state.current.generatedTestPlan)
        XCTAssertNil(state.current.generatedTestArtifact)
        let history = try XCTUnwrap(state.previousRuns.first { $0.missionID == testableMissionID })
        XCTAssertTrue(history.exactDetails.contains { $0.value == "/demo/TestableLegacy" })
        XCTAssertFalse(history.exactDetails.contains { $0.value == "/demo/SyntheticLegacy" })
    }

    func testDifferingLegacyRootsOrSourceSnapshotsCannotShareMissionRun() {
        let fixture = Fixture()
        let rootConflict = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [
                fixture.patch(canonicalLegacyRoot: "/legacy/A", revision: 1, state: .patchReady),
                fixture.patch(canonicalLegacyRoot: "/legacy/B", revision: 2, state: .patchReady)
            ]
        )
        XCTAssertEqual(rootConflict.current.lineageState, .contradictory)
        XCTAssertNil(rootConflict.current.primaryAction)
        XCTAssertFalse(rootConflict.current.undoEligible)

        let snapshotConflict = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [
                fixture.patch(sourceSnapshotID: String(repeating: "a", count: 64), revision: 1, state: .patchReady),
                fixture.patch(sourceSnapshotID: String(repeating: "b", count: 64), revision: 2, state: .patchReady)
            ]
        )
        XCTAssertEqual(snapshotConflict.current.lineageState, .contradictory)
        XCTAssertNil(snapshotConflict.current.primaryAction)
        XCTAssertFalse(snapshotConflict.current.undoEligible)
    }

    func testDifferingCandidatePatchAuthorityCannotShareMissionRun() {
        let fixture = Fixture()
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [
                fixture.patch(revision: 1, state: .patchReady),
                fixture.patch(
                    patchID: "00000000-0000-0000-0000-000000000081",
                    revision: 2,
                    state: .patchReady
                )
            ]
        )
        XCTAssertEqual(state.current.lineageState, .contradictory)
        XCTAssertNil(state.current.primaryAction)
        XCTAssertFalse(state.current.undoEligible)
    }

    func testPlanAndArtifactMustMatchExactParentPatchLineage() {
        let fixture = Fixture()
        let unrelatedCandidatePlanID = UUID(uuidString: "00000000-0000-0000-0000-000000000109")!
        let patch = fixture.patch(revision: 1, state: .patchReady)
        let mismatchedPlan = fixture.plan(
            candidatePlanID: unrelatedCandidatePlanID,
            status: .testPlanReviewReady
        )
        let mismatchedArtifact = fixture.artifact(
            candidatePlanID: unrelatedCandidatePlanID,
            canonicalLegacyRoot: "/different/Legacy",
            review: .awaitingReview
        )
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch],
            plans: [mismatchedPlan],
            artifacts: [mismatchedArtifact]
        )
        XCTAssertNotEqual(state.current.lineageState, .exact)
        XCTAssertNil(state.current.generatedTestPlan)
        XCTAssertNil(state.current.generatedTestArtifact)
        XCTAssertNil(state.current.primaryAction)
        XCTAssertFalse(state.current.undoEligible)
    }

    func testLatestExactCompletedMissionWinsOverIncompleteFallback() {
        let fixture = Fixture()
        let exactMissionID = UUID(uuidString: "00000000-0000-0000-0000-00000000010A")!
        let exactCandidatePlanID = UUID(uuidString: "00000000-0000-0000-0000-00000000010B")!
        let exactPlanningTaskID = UUID(uuidString: "00000000-0000-0000-0000-00000000010C")!
        let exactPatch = fixture.patch(
            missionID: exactMissionID,
            planID: exactCandidatePlanID,
            revision: 1,
            state: .patchReady
        )
        let exactPlan = fixture.plan(
            missionID: exactMissionID,
            planningTaskID: exactPlanningTaskID,
            candidatePlanID: exactCandidatePlanID,
            status: .testPlanReviewReady
        )
        let exactArtifact = fixture.artifact(
            missionID: exactMissionID,
            planningTaskID: exactPlanningTaskID,
            candidatePlanID: exactCandidatePlanID,
            review: .approved
        )
        let state = fixture.project(
            session: fixture.session(
                interaction: .completed,
                missionTaskIDs: [exactMissionID, fixture.missionID]
            ),
            candidates: [exactPatch],
            plans: [fixture.plan(status: .testPlanReviewReady), exactPlan],
            artifacts: [exactArtifact]
        )
        XCTAssertEqual(state.current.missionID, exactMissionID)
        XCTAssertEqual(state.current.lineageState, .exact)
        XCTAssertEqual(state.current.generatedTestArtifact?.artifactID, exactArtifact.artifactID)
        XCTAssertTrue(state.current.isTerminal)
    }

    func testExactPlanAndArtifactParentChainRemainsActionable() {
        let fixture = Fixture()
        let patch = fixture.patch(revision: 1, state: .patchReady)
        let plan = fixture.plan(status: .testPlanReviewReady)
        let artifact = fixture.artifact(review: .awaitingReview)
        let state = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch],
            plans: [plan],
            artifacts: [artifact]
        )
        XCTAssertEqual(state.current.lineageState, .exact)
        XCTAssertEqual(state.current.generatedTestPlan?.generatedTestPlanID, plan.generatedTestPlanID)
        XCTAssertEqual(state.current.generatedTestArtifact?.artifactID, artifact.artifactID)
        XCTAssertEqual(state.current.primaryAction, .reviewProposedTests)
        XCTAssertTrue(state.current.undoEligible)
    }

    func testUndoIsUnavailableForIncompleteAuthorityAndBindsExactSelectedRun() throws {
        let fixture = Fixture()
        let incomplete = fixture.project(
            session: fixture.session(interaction: .completed),
            plans: [fixture.plan(status: .testPlanReviewReady)]
        )
        XCTAssertEqual(incomplete.current.lineageState, .incomplete)
        XCTAssertFalse(incomplete.current.undoEligible)
        XCTAssertNil(MissionUndoRequest(summary: incomplete.current, workspaceID: fixture.workspaceID))

        let patch = fixture.patch(revision: 1, state: .patchReady)
        let exact = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: [patch]
        )
        let request = try XCTUnwrap(
            MissionUndoRequest(summary: exact.current, workspaceID: fixture.workspaceID)
        )
        XCTAssertEqual(request.missionID, exact.current.missionID)
        XCTAssertEqual(request.patchID, patch.patchID)
        XCTAssertEqual(request.patchPlanID, patch.planID)
        XCTAssertEqual(request.patchRevision, patch.planRevision)
        XCTAssertEqual(request.sandboxID, patch.sandboxID)
        XCTAssertEqual(request.sourceSnapshotID, patch.sourceSnapshotID)
        XCTAssertEqual(request.candidatePatchManifestID, patch.manifestID)
        XCTAssertEqual(request.candidatePatchArtifactSHA256, patch.candidatePatchArtifactSHA256)
        XCTAssertEqual(request.assessmentID, patch.assessmentID)
        XCTAssertEqual(request.lineageKey, exact.current.lineage?.lineageKey)
    }

    func testMultipleRealMissionsRemainDistinctAndHistoricalRunsAreReadOnly() {
        let fixture = Fixture()
        let historicalA = UUID(uuidString: "00000000-0000-0000-0000-000000000111")!
        let historicalB = UUID(uuidString: "00000000-0000-0000-0000-000000000112")!
        let state = fixture.project(
            session: fixture.session(
                interaction: .completed,
                missionTaskIDs: [historicalA, historicalB, fixture.missionID]
            ),
            candidates: [
                fixture.patch(missionID: historicalA, revision: 1, state: .sandboxDestroyed),
                fixture.patch(missionID: historicalB, revision: 1, state: .reverted),
                fixture.patch(revision: 1, state: .patchReady)
            ]
        )
        XCTAssertEqual(state.previousRuns.count, 2)
        XCTAssertEqual(Set(state.previousRuns.compactMap(\.missionID)), [historicalA, historicalB])
        XCTAssertTrue(state.previousRuns.allSatisfy { !$0.exposesMutationActions })
    }

    func testCollapsedDefaultsAndRestartPreserveIdentityWithoutExpansion() {
        let fixture = Fixture()
        let inputs = [fixture.patch(revision: 1, state: .patchReady)]
        let first = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: inputs
        )
        let restored = fixture.project(
            session: fixture.session(interaction: .completed),
            candidates: inputs
        )
        XCTAssertEqual(first.current.lineage, restored.current.lineage)
        for state in [first, restored] {
            XCTAssertFalse(state.previousRunsExpandedByDefault)
            XCTAssertFalse(state.advancedDetailsExpandedByDefault)
            XCTAssertFalse(state.completedActivityExpandedByDefault)
        }
    }

    func testHistoryTimelinePreservesLifecycleEventsAndAdvancedDetailsKeepExactIDs() throws {
        let fixture = Fixture()
        let historicalMission = UUID(uuidString: "00000000-0000-0000-0000-000000000121")!
        let historicalPatch = fixture.patch(
            missionID: historicalMission,
            revision: 1,
            state: .sandboxDestroyed,
            lifecycleEvents: [.patchReady, .reverted, .sandboxDestroyed]
        )
        let state = fixture.project(
            session: fixture.session(
                interaction: .completed,
                missionTaskIDs: [historicalMission, fixture.missionID]
            ),
            candidates: [historicalPatch, fixture.patch(revision: 1, state: .patchReady)]
        )
        let history = try XCTUnwrap(state.previousRuns.first)
        XCTAssertEqual(history.timeline.map(\.outcome), [
            "Proposed change ready",
            "Proposed change reverted",
            "Temporary workspace cleaned up"
        ])
        XCTAssertTrue(history.exactDetails.contains { $0.value == historicalPatch.patchID })
        XCTAssertTrue(history.exactDetails.contains { $0.value == historicalPatch.planID })
        XCTAssertTrue(history.exactDetails.contains { $0.value == historicalPatch.sandboxID })
    }

    func testUndoWithoutPatchCompletesAndRestoresFromDurableStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lifecycle = SandboxLifecycleService(storageRoot: root)
        let request = MissionUndoRequest(
            missionID: UUID(),
            workspaceID: UUID(),
            patchID: nil,
            patchPlanID: nil,
            patchRevision: nil,
            sandboxID: nil,
            canonicalLegacyRoot: nil,
            patchRequiresRevert: false,
            patchAlreadyReverted: false,
            sandboxAlreadyDestroyed: false
        )

        let result = MissionCleanupOrchestrator(lifecycle: lifecycle).execute(request)
        XCTAssertEqual(result.phase, .cleanedUp)
        XCTAssertTrue(result.pendingReviewActionsCancelled)
        XCTAssertTrue(result.candidatePatchReverted)
        XCTAssertTrue(result.legacyVerifiedUnchanged)
        XCTAssertTrue(result.sandboxDestroyed)

        let restored = try XCTUnwrap(
            MissionCleanupStore(storageRoot: root).load(missionID: request.missionID)
        )
        XCTAssertEqual(restored.missionID, result.missionID)
        XCTAssertEqual(restored.phase, result.phase)
        XCTAssertEqual(restored.completedAt?.timeIntervalSince1970.rounded(.down), result.completedAt?.timeIntervalSince1970.rounded(.down))
        XCTAssertEqual(
            MissionCleanupOrchestrator(lifecycle: lifecycle).execute(request),
            restored
        )
    }

    func testUndoFailsClosedOnMissingExactPatchAndPersistsPartialProgress() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mission-cleanup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = MissionUndoRequest(
            missionID: UUID(),
            workspaceID: UUID(),
            patchID: CandidatePatchID().rawValue,
            patchPlanID: UUID().uuidString,
            patchRevision: 1,
            sandboxID: SandboxID().rawValue,
            canonicalLegacyRoot: "/exact/legacy",
            patchRequiresRevert: true,
            patchAlreadyReverted: false,
            sandboxAlreadyDestroyed: false
        )
        let result = MissionCleanupOrchestrator(
            lifecycle: SandboxLifecycleService(storageRoot: root)
        ).execute(request)
        XCTAssertEqual(result.phase, .partialFailure)
        XCTAssertTrue(result.pendingReviewActionsCancelled)
        XCTAssertFalse(result.candidatePatchReverted)
        XCTAssertFalse(result.sandboxDestroyed)
        XCTAssertNotNil(result.failureReason)
        let restored = try XCTUnwrap(
            MissionCleanupStore(storageRoot: root).load(missionID: request.missionID)
        )
        XCTAssertEqual(restored.missionID, result.missionID)
        XCTAssertEqual(restored.phase, result.phase)
        XCTAssertEqual(restored.failureReason, result.failureReason)
    }

    func testUnifiedReviewFileWorkspaceAndAccessibilityContractsArePresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let reviewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FDECloudOS/UI/Components/MissionPresentationView.swift"),
            encoding: .utf8
        )
        let fileSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FDECloudOS/UI/Components/GeneratedTestArtifactView.swift"),
            encoding: .utf8
        )
        for identifier in [
            "mission.current.card", "mission.current.stage", "mission.current.primaryAction",
            "mission.current.more", "mission.current.undo", "mission.current.cleanup.retry",
            "mission.history.toggle", "mission.history.list", "mission.history.item",
            "mission.review.open", "mission.review.choice.approve",
            "mission.review.choice.requestChanges", "mission.review.choice.reject",
            "mission.review.instructions", "mission.review.continue"
        ] {
            XCTAssertTrue(reviewSource.contains(identifier), identifier)
        }
        for identifier in [
            "mission.fileWorkspace", "mission.fileList", "mission.fileRow", "mission.fileContent",
            "mission.fileInspector.scenarios", "mission.fileInspector.evidence",
            "mission.fileInspector.details"
        ] {
            XCTAssertTrue(fileSource.contains(identifier), identifier)
        }
        XCTAssertTrue(reviewSource.contains("choice == .requestChanges"))
        XCTAssertTrue(reviewSource.contains("Approval does not create or execute test files. Phase 2D.3 is unavailable."))
        XCTAssertTrue(fileSource.contains("ScrollView([.horizontal, .vertical])"))
        XCTAssertTrue(fileSource.contains("onMoveCommand"))
        XCTAssertTrue(fileSource.contains("onExitCommand"))
        XCTAssertTrue(fileSource.contains("NOT_WRITTEN") || fileSource.contains("writtenStatus"))
    }
}

private struct Fixture {
    let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let missionID = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    let planID = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
    let planningTaskID = UUID(uuidString: "00000000-0000-0000-0000-000000000040")!
    let generatedTestPlanID = UUID(uuidString: "00000000-0000-0000-0000-000000000045")!
    let localSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
    let appSessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000060")!

    func session(
        interaction: AgentInteractionState,
        runtimeTaskID: UUID? = nil,
        missionTaskIDs: [UUID]? = nil,
        legacyRoot: String = "/exact/legacy"
    ) -> AgentSession {
        let selectedMissionID = runtimeTaskID ?? missionID
        return AgentSession(
            sessionID: UUID(uuidString: "00000000-0000-0000-0000-000000000070")!,
            workspaceID: workspaceID,
            userGoal: "Add safe customer support order lookup",
            currentState: interaction == .blocked ? .blocked : .completed,
            interactionState: interaction,
            workspaceContext: AgentWorkspaceContext(
                workspaceID: workspaceID,
                workspaceName: "Legacy",
                localProjectRoot: legacyRoot,
                runtimeTaskID: selectedMissionID,
                runtimeTaskTitle: "Customer Support Order Lookup",
                missionTaskIDs: missionTaskIDs ?? [selectedMissionID, planningTaskID]
            )
        )
    }

    var approval: ApprovalRequest {
        ApprovalRequest(
            id: UUID(),
            workspaceID: workspaceID,
            taskID: missionID,
            stepID: "candidate-patch-plan-revision-1",
            toolCallID: nil,
            targetKind: .candidatePatchPlan,
            action: "Approve Candidate Patch plan",
            resource: "Exact proposed change",
            riskLevel: .medium,
            state: .pending,
            requestedByRole: .fde,
            decidedByRole: nil,
            decisionReason: nil,
            requestedAt: Date(),
            decidedAt: nil,
            expiresAt: nil,
            metadata: [
                "plan_id": planID.uuidString.lowercased(),
                "plan_revision": "1",
                "files_planned": "1"
            ]
        )
    }

    func activity(
        kind: AgentConversationActivityKind,
        assessment: AIAssessmentActivitySnapshot? = nil,
        taskID: UUID? = nil
    ) -> AgentConversationActivity {
        AgentConversationActivity(
            requestID: UUID(),
            startedAt: Date(),
            scope: .engineeringTask,
            kind: kind,
            metadata: AgentConversationActivityMetadata(
                dialogID: UUID(),
                taskID: taskID ?? missionID,
                aiAssessment: assessment
            )
        )
    }

    func patch(
        missionID: UUID? = nil,
        planID: UUID? = nil,
        patchID: String = "00000000-0000-0000-0000-000000000080",
        sandboxID: String = "00000000-0000-0000-0000-000000000090",
        sourceSnapshotID: String = String(repeating: "b", count: 64),
        canonicalLegacyRoot: String = "/exact/legacy",
        assessmentID: String = "assessment-exact",
        candidatePatchArtifactSHA256: String = String(repeating: "a", count: 64),
        revision: Int,
        state: CandidatePatchProjectionState,
        lifecycleEvents: [CandidatePatchProjectionState]? = nil
    ) -> CandidatePatchActivitySnapshot {
        CandidatePatchActivitySnapshot(
            patchID: patchID,
            sandboxID: sandboxID,
            sourceCandidatePatchTaskID: (missionID ?? self.missionID).uuidString,
            planID: (planID ?? self.planID).uuidString.lowercased(),
            planRevision: revision,
            manifestID: "candidate-patch-manifest:exact",
            candidatePatchArtifactSHA256: candidatePatchArtifactSHA256,
            sourceSnapshotID: sourceSnapshotID,
            canonicalLegacyRoot: canonicalLegacyRoot,
            capabilityID: "customer_support_order_lookup",
            capabilityDisplayLabel: "Customer Support AI Agent — Read-only Order Lookup",
            assessmentID: assessmentID,
            validationTestPlanSHA256: String(repeating: "c", count: 64),
            unifiedDiffSHA256: String(repeating: "d", count: 64),
            status: state == .reverted || state == .sandboxDestroyed ? .reverted : .reviewReady,
            filesPlanned: 1,
            filesChanged: 1,
            additions: 4,
            deletions: 0,
            risk: .medium,
            evidenceCount: 2,
            sourceIntegrity: .unchanged,
            approvalState: .approve,
            projectionState: state,
            lifecycleEvents: lifecycleEvents
        )
    }

    func plan(
        missionID: UUID? = nil,
        planningTaskID: UUID? = nil,
        candidatePlanID: UUID? = nil,
        candidatePlanRevision: Int = 1,
        patchID: String = "00000000-0000-0000-0000-000000000080",
        sandboxID: String = "00000000-0000-0000-0000-000000000090",
        sourceSnapshotID: String = String(repeating: "b", count: 64),
        canonicalLegacyRoot: String = "/exact/legacy",
        assessmentID: String = "assessment-exact",
        candidatePatchArtifactSHA256: String = String(repeating: "a", count: 64),
        generatedTestPlanID: UUID? = nil,
        status: GeneratedTestLifecycleStatus
    ) -> GeneratedTestActivitySnapshot {
        let source = generatedSourceBinding(
            missionID: missionID,
            planningTaskID: planningTaskID,
            candidatePlanID: candidatePlanID,
            candidatePlanRevision: candidatePlanRevision,
            patchID: patchID,
            sandboxID: sandboxID,
            sourceSnapshotID: sourceSnapshotID,
            canonicalLegacyRoot: canonicalLegacyRoot,
            assessmentID: assessmentID,
            candidatePatchArtifactSHA256: candidatePatchArtifactSHA256
        )
        return GeneratedTestActivitySnapshot(
            planningTaskID: source.generatedTestPlanningTaskID.uuidString,
            sourceCandidatePatchTaskID: source.sourceCandidatePatchTaskID.uuidString,
            patchID: patchID,
            candidatePatchArtifactSHA256: candidatePatchArtifactSHA256,
            sandboxID: sandboxID,
            sourceSnapshotID: sourceSnapshotID,
            capabilityID: "customer_support_order_lookup",
            assessmentID: assessmentID,
            validationPlanItemCount: 1,
            framework: "Vitest",
            testLocation: "tests",
            scenarioCount: 1,
            proposedTestPaths: ["tests/order-lookup.test.ts"],
            status: status,
            remainingUnknowns: [],
            generatedTestPlanID: (generatedTestPlanID ?? self.generatedTestPlanID).uuidString,
            generatedTestPlanRevision: 1,
            generatedTestPlanSHA256: String(repeating: "e", count: 64),
            generatedTestSourceBindingSHA256: source.digest,
            workspaceID: workspaceID.uuidString,
            candidatePatchPlanID: source.candidatePatchPlanID.uuidString,
            candidatePatchPlanRevision: source.candidatePatchPlanRevision,
            candidatePatchManifestID: source.candidatePatchManifestID,
            canonicalLegacyRoot: source.canonicalLegacyRoot,
            validationTestPlanSHA256: source.validationTestPlanSHA256,
            unifiedDiffSHA256: source.unifiedDiffSHA256
        )
    }

    func generatedSourceBinding(
        missionID: UUID? = nil,
        planningTaskID: UUID? = nil,
        candidatePlanID: UUID? = nil,
        candidatePlanRevision: Int = 1,
        patchID: String = "00000000-0000-0000-0000-000000000080",
        sandboxID: String = "00000000-0000-0000-0000-000000000090",
        sourceSnapshotID: String = String(repeating: "b", count: 64),
        canonicalLegacyRoot: String = "/exact/legacy",
        assessmentID: String = "assessment-exact",
        candidatePatchArtifactSHA256: String = String(repeating: "a", count: 64)
    ) -> GeneratedTestSourceBinding {
        GeneratedTestSourceBinding(
            workspaceID: workspaceID,
            generatedTestPlanningTaskID: planningTaskID ?? self.planningTaskID,
            sourceCandidatePatchTaskID: missionID ?? self.missionID,
            patchID: CandidatePatchID(rawValue: patchID)!,
            candidatePatchPlanID: candidatePlanID ?? planID,
            candidatePatchPlanRevision: candidatePlanRevision,
            candidatePatchManifestID: "candidate-patch-manifest:exact",
            candidatePatchArtifactSHA256: candidatePatchArtifactSHA256,
            candidatePatchApprovalProvenanceSHA256: String(repeating: "1", count: 64),
            sandboxID: SandboxID(rawValue: sandboxID)!,
            sourceSnapshotID: sourceSnapshotID,
            canonicalLegacyRoot: canonicalLegacyRoot,
            normalizedCapabilityID: "customer_support_order_lookup",
            capabilityDisplayLabel: "Customer Support AI Agent — Read-only Order Lookup",
            validatedAssessmentID: assessmentID,
            validationTestPlanSHA256: String(repeating: "c", count: 64),
            unifiedDiffSHA256: String(repeating: "d", count: 64),
            changedRelativePaths: ["src/order.ts"],
            createdRelativePaths: [],
            candidatePatchPostimages: [],
            authenticatedLocalSessionID: localSessionID,
            appSessionID: appSessionID
        )
    }

    func artifact(
        missionID: UUID? = nil,
        planningTaskID: UUID? = nil,
        candidatePlanID: UUID? = nil,
        candidatePlanRevision: Int = 1,
        patchID: String = "00000000-0000-0000-0000-000000000080",
        sandboxID: String = "00000000-0000-0000-0000-000000000090",
        sourceSnapshotID: String = String(repeating: "b", count: 64),
        canonicalLegacyRoot: String = "/exact/legacy",
        assessmentID: String = "assessment-exact",
        candidatePatchArtifactSHA256: String = String(repeating: "a", count: 64),
        generatedTestPlanID: UUID? = nil,
        review: GeneratedTestArtifactReviewState,
        updatedAt: Date = Date()
    ) -> GeneratedTestArtifact {
        let source = generatedSourceBinding(
            missionID: missionID,
            planningTaskID: planningTaskID,
            candidatePlanID: candidatePlanID,
            candidatePlanRevision: candidatePlanRevision,
            patchID: patchID,
            sandboxID: sandboxID,
            sourceSnapshotID: sourceSnapshotID,
            canonicalLegacyRoot: canonicalLegacyRoot,
            assessmentID: assessmentID,
            candidatePatchArtifactSHA256: candidatePatchArtifactSHA256
        )
        let artifactID = UUID()
        let revision = GeneratedTestArtifactRevision(
            artifactID: artifactID,
            revision: 1,
            lifecycleStatus: .testArtifactReviewReady,
            reviewState: .awaitingReview,
            reviewSessionID: UUID(),
            framework: GeneratedTestFrameworkIdentity(
                frameworkID: "vitest",
                displayName: "Vitest",
                language: "typescript"
            ),
            groundedTestLocation: "tests",
            risk: .medium,
            virtualFiles: [],
            scenarioBindings: [],
            evidenceBindings: [],
            validationPlanItemIDs: ["validation-1"],
            generationProvenance: ["virtual only"],
            reviewInstructionSHA256: nil,
            digest: GeneratedTestArtifactDigest(
                algorithm: "SHA-256",
                canonicalSerializationVersion: 1,
                sha256: String(repeating: "2", count: 64)
            ),
            createdAt: Date()
        )
        let decision: [GeneratedTestReviewDecision]
        switch review {
        case .awaitingReview:
            decision = []
        case .approved, .rejected, .changeRequested:
            let kind: GeneratedTestReviewDecisionKind = switch review {
            case .approved: .approve
            case .rejected: .reject
            case .changeRequested: .requestChanges
            case .awaitingReview: .approve
            }
            decision = [GeneratedTestReviewDecision(
                decisionID: UUID(),
                artifactID: artifactID,
                artifactRevision: 1,
                artifactSHA256: revision.digest.sha256,
                reviewSessionID: revision.reviewSessionID,
                decision: kind,
                reviewerInstructions: nil,
                authenticatedLocalSessionID: localSessionID,
                appSessionID: appSessionID,
                decidedAt: Date()
            )]
        }
        return GeneratedTestArtifact(
            artifactID: artifactID,
            sourceBinding: GeneratedTestArtifactSourceBinding(
                generatedTestPlanID: generatedTestPlanID ?? self.generatedTestPlanID,
                generatedTestPlanRevision: 1,
                generatedTestPlanSHA256: String(repeating: "e", count: 64),
                generatedTestSourceBinding: source,
                approvedPostimages: []
            ),
            revisions: [revision],
            reviewDecisions: decision,
            createdAt: Date(),
            updatedAt: updatedAt
        )
    }

    func phase3Artifacts(for artifact: GeneratedTestArtifact) throws -> ProductionReadinessArtifacts {
        let source = artifact.sourceBinding.generatedTestSourceBinding
        let revision = try XCTUnwrap(artifact.currentRevision)
        var binding = ProductionReadinessSourceBinding(
            missionRunID: source.sourceCandidatePatchTaskID,
            workspaceID: source.workspaceID,
            canonicalLegacyRoot: source.canonicalLegacyRoot,
            sourceSnapshotID: source.sourceSnapshotID,
            assessmentID: source.validatedAssessmentID,
            assessmentSHA256: String(repeating: "3", count: 64),
            sourceCandidatePatchTaskID: source.sourceCandidatePatchTaskID,
            candidatePatchID: source.patchID,
            candidatePatchPlanID: source.candidatePatchPlanID,
            candidatePatchPlanRevision: source.candidatePatchPlanRevision,
            candidatePatchManifestID: source.candidatePatchManifestID,
            candidatePatchArtifactSHA256: source.candidatePatchArtifactSHA256,
            candidatePatchApprovalProvenanceSHA256: source.candidatePatchApprovalProvenanceSHA256,
            candidatePatchReviewOutcome: CandidatePatchApprovalDecision.approve.rawValue,
            sandboxID: source.sandboxID,
            sandboxLifecycle: CandidatePatchStatus.reviewReady.rawValue,
            generatedTestPlanningTaskID: source.generatedTestPlanningTaskID,
            generatedTestPlanID: artifact.sourceBinding.generatedTestPlanID,
            generatedTestPlanRevision: artifact.sourceBinding.generatedTestPlanRevision,
            generatedTestPlanSHA256: artifact.sourceBinding.generatedTestPlanSHA256,
            generatedTestArtifactID: artifact.artifactID,
            generatedTestArtifactRevision: revision.revision,
            generatedTestArtifactSHA256: revision.digest.sha256,
            generatedTestArtifactReviewOutcome: GeneratedTestReviewDecisionKind.approve.rawValue,
            cleanupStatus: nil,
            normalizedCapabilityID: source.normalizedCapabilityID,
            capabilityDisplayLabel: source.capabilityDisplayLabel ?? source.normalizedCapabilityID,
            authenticatedLocalSessionID: source.authenticatedLocalSessionID,
            appSessionID: source.appSessionID,
            sourceBindingSHA256: ""
        )
        binding.sourceBindingSHA256 = binding.canonicalDigest
        return try ProductionReadinessPlanningService().generate(sourceBinding: binding)
    }

    func cleanup(phase: MissionCleanupPhase) -> MissionCleanupState {
        MissionCleanupState(
            missionID: missionID,
            workspaceID: workspaceID,
            phase: phase,
            patchID: nil,
            patchPlanID: nil,
            patchRevision: nil,
            sandboxID: nil,
            canonicalLegacyRoot: "/exact/legacy",
            pendingReviewActionsCancelled: true,
            candidatePatchReverted: true,
            legacyVerifiedUnchanged: true,
            sandboxDestroyed: false,
            failureReason: "Sandbox destruction failed",
            startedAt: Date(),
            updatedAt: Date(),
            completedAt: nil
        )
    }

    func project(
        session: AgentSession,
        activity: AgentConversationActivity? = nil,
        candidates: [CandidatePatchActivitySnapshot] = [],
        plans: [GeneratedTestActivitySnapshot] = [],
        artifacts: [GeneratedTestArtifact] = [],
        approvals: [ApprovalRequest] = [],
        cleanup: [MissionCleanupState] = [],
        readinessReports: [ProductionReadinessReport] = [],
        evalPlans: [AIEvalPlan] = [],
        phase3ARestorationFailure: String? = nil
    ) -> MissionPresentationState {
        MissionPresentationProjector.project(
            session: session,
            activity: activity,
            candidatePatches: candidates,
            generatedTestPlans: plans,
            generatedTestArtifacts: artifacts,
            approvals: approvals,
            cleanupStates: cleanup,
            productionReadinessReports: readinessReports,
            aiEvalPlans: evalPlans,
            phase3ARestorationFailure: phase3ARestorationFailure
        )
    }
}
