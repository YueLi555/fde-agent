import XCTest
@testable import FDECloudOS

final class ControlledEvalExecutionTests: XCTestCase {
    func testExactApprovedPhase3APairIsRequiredAndStaleRevisionFailsClosed() throws {
        let artifacts = try planningArtifacts()
        let dataset = try service.makeFixtureDataset(for: artifacts.evalPlan)
        let policy = try service.makeDefaultPolicy(for: artifacts.evalPlan, datasetID: dataset.datasetID)
        XCTAssertThrowsError(try service.prepare(
            report: artifacts.report,
            evalPlan: artifacts.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .exactApprovedPhase3APairRequired)
        }

        var stale = artifacts
        let reportRevision = try XCTUnwrap(stale.report.currentRevision)
        stale.report = try ProductionReadinessPlanningService().reviewReport(
            stale.report,
            decision: .requestChanges,
            instructions: "Create a newer exact revision.",
            context: reviewContext(
                artifactID: stale.report.reportID,
                revision: reportRevision.revision,
                digest: reportRevision.digest.sha256
            )
        )
        stale.evalPlan = try approvePlan(stale.evalPlan)
        XCTAssertThrowsError(try service.prepare(
            report: stale.report,
            evalPlan: stale.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        ))
    }

    func testExactAuthorityBindsPolicyDatasetProviderAndAllMissionParents() throws {
        let fixture = try preparedFixture()
        let authority = fixture.run.request.authority
        XCTAssertEqual(authority.missionRunID, missionID)
        XCTAssertEqual(authority.workspaceID, workspaceID)
        XCTAssertEqual(authority.readinessSourceBinding.sourceCandidatePatchTaskID, missionID)
        XCTAssertEqual(authority.readinessSourceBinding.generatedTestPlanID, generatedPlanID)
        XCTAssertEqual(authority.readinessSourceBinding.generatedTestArtifactID, generatedArtifactID)
        XCTAssertEqual(authority.productionReadinessReportSHA256, fixture.pair.report.currentRevision?.digest.sha256)
        XCTAssertEqual(authority.aiEvalPlanSHA256, fixture.pair.evalPlan.currentRevision?.digest.sha256)
        XCTAssertEqual(authority.executionPolicySHA256, fixture.run.request.policy.policySHA256)
        XCTAssertEqual(authority.datasetManifestSHA256, fixture.run.request.dataset.manifestSHA256)
        XCTAssertEqual(authority.workspaceSessionID, workspaceSessionID)
        XCTAssertTrue(authority.isSelfValidating)
    }

    func testDigestAppSessionAndWorkspaceSessionMismatchesFailClosed() throws {
        var fixture = try preparedFixture()
        fixture.run.request.dataset.cases[0].input = "drift"
        XCTAssertThrowsError(try ControlledEvalArtifactValidator.validate(fixture.run)) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .digestMismatch)
        }

        let exact = try preparedFixture()
        var badApp = context
        badApp.appSessionID = UUID()
        XCTAssertThrowsError(try service.approveExecution(exact.run, context: badApp)) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .sessionMismatch)
        }
        var badWorkspaceSession = context
        badWorkspaceSession.workspaceSessionID = UUID()
        XCTAssertThrowsError(try service.approveExecution(exact.run, context: badWorkspaceSession)) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .sessionMismatch)
        }
    }

    func testScenarioMetricAndProviderOutsideApprovalAreRejected() throws {
        let pair = try approvedPair()
        var dataset = try service.makeFixtureDataset(for: pair.evalPlan)
        var policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        XCTAssertThrowsError(try service.prepare(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context,
            requestedScenarioIDs: ["scenario.not-approved"]
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .scenarioNotApproved)
        }

        policy.metricAllowlist.append("metric.not-approved")
        policy.policySHA256 = ControlledEvalDigest.policySHA256(policy)
        XCTAssertThrowsError(try service.prepare(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .metricNotApproved)
        }

        policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        var fixture = try service.prepare(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        )
        fixture = try service.approveExecution(fixture, context: context)
        XCTAssertThrowsError(try service.beginExecution(
            fixture,
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: context,
            provider: WrongFixtureProvider()
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .providerMismatch)
        }

        let spoofedBegun = try service.beginExecution(
            fixture,
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: context,
            provider: SpoofedFixtureProvider()
        )
        XCTAssertThrowsError(try service.completeExecution(
            spoofedBegun,
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: context,
            provider: SpoofedFixtureProvider()
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .providerMismatch)
        }

        dataset.cases[0].scenarioID = "scenario.not-approved"
        dataset.cases[0].caseSHA256 = ControlledEvalDigest.datasetCaseSHA256(dataset.cases[0])
        dataset.manifestSHA256 = ControlledEvalDigest.datasetManifestSHA256(dataset)
        XCTAssertThrowsError(try service.prepare(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .datasetDrift)
        }
    }

    func testDatasetCaseRuntimeTokenAndCostLimitsAreEnforced() throws {
        let pair = try approvedPair()
        let dataset = try service.makeFixtureDataset(for: pair.evalPlan)
        var policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)

        policy.maximumCases = dataset.caseCount - 1
        policy.policySHA256 = ControlledEvalDigest.policySHA256(policy)
        assertPrepareThrows(.datasetLimitExceeded, pair: pair, dataset: dataset, policy: policy)

        policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        policy.maximumRuntimeDurationMilliseconds = 1
        policy.policySHA256 = ControlledEvalDigest.policySHA256(policy)
        assertPrepareThrows(.runtimeLimitExceeded, pair: pair, dataset: dataset, policy: policy)

        policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        policy.maximumTokenEstimate = 1
        policy.policySHA256 = ControlledEvalDigest.policySHA256(policy)
        assertPrepareThrows(.tokenLimitExceeded, pair: pair, dataset: dataset, policy: policy)

        var costly = dataset
        costly.cases[0].estimatedCost = 0.01
        costly.cases[0].caseSHA256 = ControlledEvalDigest.datasetCaseSHA256(costly.cases[0])
        costly.manifestSHA256 = ControlledEvalDigest.datasetManifestSHA256(costly)
        policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: costly.datasetID)
        assertPrepareThrows(.costLimitExceeded, pair: pair, dataset: costly, policy: policy)
    }

    func testAllMandatoryGatesPassingProducesPassAndZeroExternalAuthority() throws {
        let fixture = try preparedFixture(thresholdsDefined: true)
        let approved = try service.approveExecution(fixture.run, context: context)
        let result = try service.execute(
            approved,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: context,
            now: now
        )
        XCTAssertEqual(result.run.currentState, .resultsAwaitingReview)
        XCTAssertEqual(result.run.overallResult, .pass)
        XCTAssertTrue(result.run.currentRevision?.metricResults.allSatisfy { $0.outcome == .pass } == true)
        XCTAssertGreaterThan(result.safetyCounters.deterministicFixtureExecutions, 0)
        XCTAssertTrue(result.safetyCounters.hasZeroExternalAuthority)
        XCTAssertFalse(result.run.productionApprovalGranted)
        XCTAssertFalse(result.run.deploymentAuthorized)
        XCTAssertFalse(result.run.phase3BAvailable)
    }

    func testMandatoryGateFailureProducesFailAndCriticalFailureStopsRemainingWork() throws {
        let pair = try approvedPair(thresholdsDefined: true)
        var dataset = try service.makeFixtureDataset(for: pair.evalPlan)
        let firstScenario = dataset.cases.map(\.scenarioID).sorted().first!
        let caseIndex = dataset.cases.firstIndex { $0.scenarioID == firstScenario }!
        let failingMetric = dataset.cases[caseIndex].metricValues.keys.sorted().first!
        dataset.cases[caseIndex].metricValues[failingMetric] = failingMetric.contains("violation") ? 1 : 0
        dataset.cases[caseIndex].isCriticalFailure = true
        dataset.cases[caseIndex].caseSHA256 = ControlledEvalDigest.datasetCaseSHA256(dataset.cases[caseIndex])
        dataset.manifestSHA256 = ControlledEvalDigest.datasetManifestSHA256(dataset)
        let policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        var run = try service.prepare(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        )
        run = try service.approveExecution(run, context: context)
        let result = try service.execute(run, report: pair.report, evalPlan: pair.evalPlan, context: context, now: now)
        XCTAssertEqual(result.run.overallResult, .fail)
        XCTAssertFalse(result.run.currentRevision?.unexecutedScenarioIDs.isEmpty ?? true)
        XCTAssertTrue(result.run.currentRevision?.failures.contains { $0.isCritical } == true)
    }

    func testMissingEvidenceIsInconclusiveNeverPass() throws {
        let pair = try approvedPair(thresholdsDefined: true)
        var dataset = try service.makeFixtureDataset(for: pair.evalPlan)
        dataset.cases[0].evidenceReferences = []
        dataset.cases[0].caseSHA256 = ControlledEvalDigest.datasetCaseSHA256(dataset.cases[0])
        dataset.manifestSHA256 = ControlledEvalDigest.datasetManifestSHA256(dataset)
        let policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        var run = try service.prepare(report: pair.report, evalPlan: pair.evalPlan, dataset: dataset, policy: policy, context: context)
        run = try service.approveExecution(run, context: context)
        let result = try service.execute(run, report: pair.report, evalPlan: pair.evalPlan, context: context, now: now)
        XCTAssertEqual(result.run.overallResult, .inconclusive)
        XCTAssertTrue(result.run.currentRevision?.failures.contains { $0.kind == .missingEvidence } == true)
        XCTAssertFalse(result.run.currentRevision?.scenarioExecutions.flatMap(\.results).filter { $0.evidenceReferences.isEmpty }.contains { $0.outcome == .pass } == true)
    }

    func testRetryIsImmutableAndResultReviewIsSingleUseRevisionBound() throws {
        var fixture = try preparedFixture(thresholdsDefined: true, maximumAttempts: 2)
        fixture.run = try service.approveExecution(fixture.run, context: context)
        var completed = try service.execute(
            fixture.run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: context,
            now: now
        ).run
        let completedRevisions = completed.revisions
        let proposal = try service.makeResultReviewProposal(
            completed,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: context
        )
        let authorization = try service.authorizeResultReview(
            proposal: proposal,
            context: context,
            now: now
        )
        let reviewed = try service.reviewResultsAuthorized(
            completed,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            proposal: proposal,
            authorization: authorization,
            decision: .requestChanges,
            instructions: "Repeat the exact deterministic attempt for review.",
            context: context,
            now: later
        )
        completed = reviewed.run
        XCTAssertEqual(Array(completed.revisions.prefix(completedRevisions.count)), completedRevisions)
        XCTAssertEqual(completed.revisions, completedRevisions)
        XCTAssertTrue(reviewed.consumedAuthorization.isConsumed)
        XCTAssertThrowsError(try service.reviewResultsAuthorized(
            completed,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            proposal: proposal,
            authorization: reviewed.consumedAuthorization,
            decision: .approveResults,
            context: context
        ))

        let retried = try service.retry(completed, context: context, now: later)
        XCTAssertEqual(retried.currentRevision?.attempt, 2)
        XCTAssertEqual(retried.currentState, .awaitingExecutionApproval)
        XCTAssertEqual(Array(retried.revisions.prefix(completed.revisions.count)), completed.revisions)
    }

    func testPersistenceRestoresCompletedExactlyAndInterruptedFailClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try preparedFixture(thresholdsDefined: true)
        var run = try service.approveExecution(fixture.run, context: context, now: now)
        run = try service.execute(run, report: fixture.pair.report, evalPlan: fixture.pair.evalPlan, context: context, now: now).run
        let store = ControlledEvalRunStore(storageRoot: root)
        try store.save(run)
        let completedRestored = try XCTUnwrap(store.restoreAll(workspaceID: workspaceID).runs.first)
        XCTAssertEqual(completedRestored.request, run.request)
        XCTAssertEqual(completedRestored.revisions.map(\.digest), run.revisions.map(\.digest))
        XCTAssertEqual(completedRestored.revisions.map(\.state), run.revisions.map(\.state))
        XCTAssertEqual(
            completedRestored.currentRevision?.scenarioExecutions.flatMap(\.results),
            run.currentRevision?.scenarioExecutions.flatMap(\.results)
        )
        XCTAssertEqual(completedRestored.currentRevision?.metricResults, run.currentRevision?.metricResults)
        XCTAssertEqual(completedRestored.currentRevision?.failures, run.currentRevision?.failures)
        XCTAssertEqual(completedRestored.currentRevision?.evidence, run.currentRevision?.evidence)
        XCTAssertEqual(completedRestored.reviewDecisions, run.reviewDecisions)
        XCTAssertEqual(completedRestored.activityEvents, run.activityEvents)
        XCTAssertEqual(completedRestored.createdAt, run.createdAt)
        XCTAssertEqual(completedRestored.updatedAt, run.updatedAt)

        let interruptedRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: interruptedRoot) }
        let interruptedStore = ControlledEvalRunStore(storageRoot: interruptedRoot)
        var interrupted = try service.approveExecution(fixture.run, context: context)
        interrupted = try service.beginExecution(
            interrupted,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: context,
            now: now
        )
        try interruptedStore.save(interrupted)
        let restored = try interruptedStore.restoreAll(workspaceID: workspaceID, now: later)
        XCTAssertEqual(restored.runs.first?.currentState, .stoppedFailClosed)
        XCTAssertEqual(restored.runs.first?.overallResult, .inconclusive)
        XCTAssertEqual(restored.restorationFailures.first?.kind, .interruptedExecution)
    }

    func testTamperedPersistenceAndRewrittenResultsFailClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try preparedFixture(thresholdsDefined: true)
        let store = ControlledEvalRunStore(storageRoot: root)
        try store.save(fixture.run)
        var rewritten = fixture.run
        rewritten.revisions[0].unexecutedScenarioIDs.removeLast()
        rewritten.revisions[0].digest = ControlledEvalDigest.runRevisionDigest(
            rewritten.revisions[0],
            requestSHA256: rewritten.request.requestSHA256
        )
        XCTAssertThrowsError(try store.save(rewritten)) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .revisionImmutable)
        }

        let url = evalRunURL(root: root, runID: fixture.run.runID)
        var tampered = fixture.run
        tampered.request.dataset.cases[0].input = "tampered persisted bytes"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(tampered).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load(
            workspaceID: workspaceID,
            missionRunID: missionID,
            runID: fixture.run.runID
        ))
    }

    func testMissingPersistedRunAndTamperedAuditRecordsFailClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try preparedFixture()
        let store = ControlledEvalRunStore(storageRoot: root)
        try store.save(fixture.run)

        var tampered = fixture.run
        tampered.activityEvents[0].summary = "rewritten audit summary"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(tampered).write(
            to: evalRunURL(root: root, runID: fixture.run.runID),
            options: [.atomic]
        )
        XCTAssertThrowsError(try store.restoreAll(workspaceID: workspaceID))

        try FileManager.default.removeItem(at: root)
        try store.save(fixture.run)
        try FileManager.default.removeItem(at: evalRunURL(root: root, runID: fixture.run.runID))
        XCTAssertThrowsError(try store.restoreAll(workspaceID: workspaceID)) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .artifactPersistenceInvalid)
        }
    }

    func testCancellationPreservesPriorAuditAndPreventsExecution() throws {
        let fixture = try preparedFixture()
        let approved = try service.approveExecution(fixture.run, context: context)
        XCTAssertThrowsError(try service.approveExecution(approved, context: context)) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .duplicateAction)
        }
        let cancelled = try service.cancel(approved, context: context, now: later)
        XCTAssertEqual(cancelled.currentState, .cancelled)
        XCTAssertEqual(Array(cancelled.revisions.prefix(approved.revisions.count)), approved.revisions)
        XCTAssertEqual(Array(cancelled.reviewDecisions.prefix(approved.reviewDecisions.count)), approved.reviewDecisions)
        XCTAssertThrowsError(try service.beginExecution(
            cancelled,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: context
        ))
    }

    func testPriorSessionPairUsesSharedReauthorizationEligibilityAndNeverNormalPreparation() throws {
        let pair = try approvedPair()
        var restartedContext = context
        restartedContext.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-00000000000F")!

        let eligibility = ControlledEvalExecutionEligibilityEvaluator.evaluate(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext,
            authorizations: [],
            now: now
        )
        XCTAssertEqual(eligibility.state, .reauthorizationReview)
        XCTAssertTrue(eligibility.proposal?.requiresReauthorization == true)
        XCTAssertEqual(eligibility.proposal?.originatingArtifactAppSessionID, appSessionID)
        XCTAssertEqual(eligibility.proposal?.currentActionAppSessionID, restartedContext.appSessionID)

        let dataset = try service.makeFixtureDataset(for: pair.evalPlan)
        let policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        XCTAssertThrowsError(try service.prepare(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: restartedContext
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .sessionMismatch)
        }
    }

    func testTamperedPairAndTamperedAuthorizationExposeOnlyBlockerEligibility() throws {
        let pair = try approvedPair()
        var restartedContext = context
        restartedContext.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-00000000000F")!
        var tamperedPair = pair
        tamperedPair.evalPlan.revisions[0].digest.sha256 = hash("tampered-plan")
        let tamperedPairEligibility = ControlledEvalExecutionEligibilityEvaluator.evaluate(
            report: tamperedPair.report,
            evalPlan: tamperedPair.evalPlan,
            context: restartedContext,
            authorizations: [],
            now: now
        )
        XCTAssertEqual(tamperedPairEligibility.state, .blocker)
        XCTAssertNil(tamperedPairEligibility.proposal)

        let proposal = try service.makeExecutionProposal(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext
        )
        var authorization = try service.authorizeExecution(
            proposal: proposal,
            context: restartedContext,
            now: now
        )
        authorization.confirmationID = UUID()
        let tamperedAuthorizationEligibility = ControlledEvalExecutionEligibilityEvaluator.evaluate(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext,
            authorizations: [authorization],
            now: now
        )
        XCTAssertEqual(tamperedAuthorizationEligibility.state, .blocker)
        XCTAssertNil(tamperedAuthorizationEligibility.authorization)
    }

    func testReauthorizationPreservesProvenanceAndBindsExactCurrentAuthorityAndLineage() throws {
        let pair = try approvedPair()
        var restartedContext = context
        restartedContext.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-00000000000F")!
        let originalReportSource = pair.report.sourceBinding
        let originalPlanSource = pair.evalPlan.sourceBinding
        let proposal = try service.makeExecutionProposal(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext
        )
        let confirmationID = UUID(uuidString: "31000000-0000-0000-0000-000000000010")!
        let authorization = try service.authorizeExecution(
            proposal: proposal,
            context: restartedContext,
            confirmationID: confirmationID,
            now: now
        )

        XCTAssertEqual(pair.report.sourceBinding, originalReportSource)
        XCTAssertEqual(pair.evalPlan.sourceBinding, originalPlanSource)
        XCTAssertEqual(authorization.authority.readinessSourceBinding.appSessionID, appSessionID)
        XCTAssertEqual(authorization.authority.appSessionID, restartedContext.appSessionID)
        XCTAssertEqual(authorization.authority.authenticatedLocalSessionID, authenticatedSessionID)
        XCTAssertEqual(authorization.authority.workspaceSessionID, workspaceSessionID)
        XCTAssertEqual(authorization.authority.productionReadinessReportID, reportID)
        XCTAssertEqual(authorization.authority.productionReadinessReportRevision, pair.report.currentRevision?.revision)
        XCTAssertEqual(authorization.authority.productionReadinessReportSHA256, pair.report.currentRevision?.digest.sha256)
        XCTAssertEqual(authorization.authority.aiEvalPlanID, evalPlanID)
        XCTAssertEqual(authorization.authority.aiEvalPlanRevision, pair.evalPlan.currentRevision?.revision)
        XCTAssertEqual(authorization.authority.aiEvalPlanSHA256, pair.evalPlan.currentRevision?.digest.sha256)
        XCTAssertEqual(authorization.authority.readinessSourceBinding.sourceCandidatePatchTaskID, missionID)
        XCTAssertEqual(authorization.authority.readinessSourceBinding.candidatePatchPlanID, patchPlanID)
        XCTAssertEqual(authorization.authority.readinessSourceBinding.generatedTestPlanningTaskID, planningTaskID)
        XCTAssertEqual(authorization.authority.readinessSourceBinding.generatedTestPlanID, generatedPlanID)
        XCTAssertEqual(authorization.authority.readinessSourceBinding.generatedTestArtifactID, generatedArtifactID)
        XCTAssertEqual(authorization.executionPolicySHA256, proposal.policy.policySHA256)
        XCTAssertEqual(authorization.datasetManifestSHA256, proposal.dataset.manifestSHA256)
        XCTAssertEqual(authorization.confirmationID, confirmationID)
        XCTAssertFalse(authorization.isConsumed)
        XCTAssertTrue(authorization.isSelfValidating)
    }

    func testAuthorizationCreatesNoRunUntilFinalConfirmationThenIsSingleUseAndZeroAuthority() throws {
        let pair = try approvedPair(thresholdsDefined: true)
        var restartedContext = context
        restartedContext.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-00000000000F")!
        let proposal = try service.makeExecutionProposal(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext
        )
        let authorization = try service.authorizeExecution(
            proposal: proposal,
            context: restartedContext,
            now: now
        )
        let afterAuthorization = ControlledEvalExecutionEligibilityEvaluator.evaluate(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext,
            authorizations: [authorization],
            now: now
        )
        XCTAssertEqual(afterAuthorization.state, .finalExecutionReview)

        let final = try service.prepareAuthorized(
            report: pair.report,
            evalPlan: pair.evalPlan,
            proposal: proposal,
            authorization: authorization,
            context: restartedContext,
            runID: UUID(uuidString: "31000000-0000-0000-0000-000000000011")!,
            now: later
        )
        XCTAssertEqual(final.run.currentState, .awaitingExecutionApproval)
        XCTAssertEqual(final.run.request.executionAuthorizationID, authorization.authorizationID)
        XCTAssertTrue(final.consumedAuthorization.isConsumed)
        XCTAssertThrowsError(try service.prepareAuthorized(
            report: pair.report,
            evalPlan: pair.evalPlan,
            proposal: proposal,
            authorization: final.consumedAuthorization,
            context: restartedContext,
            now: later
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .executionAuthorizationStale)
        }

        var approved = try service.approveExecution(final.run, context: restartedContext, now: later)
        approved = try service.beginExecution(
            approved,
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext,
            now: later
        )
        let result = try service.completeExecution(
            approved,
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext,
            now: later
        )
        XCTAssertEqual(result.run.currentState, .resultsAwaitingReview)
        XCTAssertTrue(result.safetyCounters.hasZeroExternalAuthority)
        XCTAssertFalse(result.run.phase3BAvailable)
        XCTAssertFalse(result.run.deploymentAuthorized)

        let afterRestart = ControlledEvalExecutionEligibilityEvaluator.evaluate(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext,
            authorizations: [],
            now: later
        )
        XCTAssertEqual(afterRestart.state, .reauthorizationReview)
    }

    func testExpiredAuthorizationFailsClosedBeforeRunCreation() throws {
        let pair = try approvedPair()
        var restartedContext = context
        restartedContext.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-00000000000F")!
        let proposal = try service.makeExecutionProposal(
            report: pair.report,
            evalPlan: pair.evalPlan,
            context: restartedContext
        )
        let authorization = try service.authorizeExecution(
            proposal: proposal,
            context: restartedContext,
            now: now,
            validityDuration: 1
        )
        XCTAssertThrowsError(try service.prepareAuthorized(
            report: pair.report,
            evalPlan: pair.evalPlan,
            proposal: proposal,
            authorization: authorization,
            context: restartedContext,
            now: now.addingTimeInterval(2)
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .executionAuthorizationStale)
        }
    }

    func testPriorSessionAwaitingResultUsesSharedReauthorizationThenCurrentAuthority() throws {
        let fixture = try completedFixture()
        let run = fixture.run
        let resultRevision = try XCTUnwrap(run.currentRevision)
        var restarted = context
        restarted.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-000000000021")!

        let priorEligibility = ControlledEvalResultReviewEligibilityEvaluator.evaluate(
            run: run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: restarted,
            authorizations: [],
            now: later
        )
        XCTAssertEqual(priorEligibility.state, .reauthorizationReview)
        XCTAssertNotEqual(priorEligibility.state, .currentAuthorizationReview)
        let proposal = try XCTUnwrap(priorEligibility.proposal)
        XCTAssertTrue(proposal.requiresReauthorization)
        XCTAssertEqual(proposal.runID, run.runID)
        XCTAssertEqual(proposal.resultRevision, resultRevision.revision)
        XCTAssertEqual(proposal.resultSHA256, resultRevision.digest.sha256)
        XCTAssertEqual(proposal.executionAuthorizationID, run.request.executionAuthorizationID)
        XCTAssertEqual(proposal.executionAuthority.readinessSourceBinding, fixture.pair.report.sourceBinding)

        let executionCount = resultRevision.scenarioExecutions.flatMap(\.results).count
        let authorization = try service.authorizeResultReview(
            proposal: proposal,
            context: restarted,
            confirmationID: UUID(uuidString: "31000000-0000-0000-0000-000000000022")!,
            now: later
        )
        XCTAssertEqual(run.currentRevision, resultRevision)
        XCTAssertEqual(run.currentRevision?.scenarioExecutions.flatMap(\.results).count, executionCount)
        XCTAssertEqual(authorization.currentSessionAuthority.appSessionID, restarted.appSessionID)
        XCTAssertEqual(authorization.currentSessionAuthority.authenticatedLocalSessionID, authenticatedSessionID)
        XCTAssertEqual(authorization.currentSessionAuthority.workspaceSessionID, workspaceSessionID)
        XCTAssertEqual(authorization.productionReadinessReportSHA256, fixture.pair.report.currentRevision?.digest.sha256)
        XCTAssertEqual(authorization.aiEvalPlanSHA256, fixture.pair.evalPlan.currentRevision?.digest.sha256)
        XCTAssertEqual(authorization.readinessSourceBinding, fixture.pair.report.sourceBinding)
        XCTAssertFalse(authorization.isConsumed)

        let currentEligibility = ControlledEvalResultReviewEligibilityEvaluator.evaluate(
            run: run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: restarted,
            authorizations: [authorization],
            now: later
        )
        XCTAssertEqual(currentEligibility.state, .finalDecisionReview)
        XCTAssertEqual(currentEligibility, ControlledEvalResultReviewEligibilityEvaluator.evaluate(
            run: run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: restarted,
            authorizations: [authorization],
            now: later
        ))
    }

    func testResultReviewReauthorizationRejectsTamperingInterruptionWrongBindingAndStaleAuthority() throws {
        let fixture = try completedFixture()
        var restarted = context
        restarted.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-000000000023")!

        var tampered = fixture.run
        tampered.revisions[tampered.revisions.count - 1].metricResults[0].observedValue = 999
        XCTAssertEqual(ControlledEvalResultReviewEligibilityEvaluator.evaluate(
            run: tampered,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: restarted,
            authorizations: []
        ).state, .blocker)

        let interruptedFixture = try preparedFixture(runID: UUID(uuidString: "31000000-0000-0000-0000-000000000028")!)
        var interrupted = try service.approveExecution(interruptedFixture.run, context: context)
        interrupted = try service.beginExecution(
            interrupted,
            report: interruptedFixture.pair.report,
            evalPlan: interruptedFixture.pair.evalPlan,
            context: context,
            now: now
        )
        interrupted = try service.failClosedInterruptedRestoration(interrupted, now: later)
        XCTAssertEqual(ControlledEvalResultReviewEligibilityEvaluator.evaluate(
            run: interrupted,
            report: interruptedFixture.pair.report,
            evalPlan: interruptedFixture.pair.evalPlan,
            context: restarted,
            authorizations: []
        ).state, .blocker)

        let proposal = try service.makeResultReviewProposal(
            fixture.run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: restarted
        )
        var wrong = try service.authorizeResultReview(
            proposal: proposal,
            context: restarted,
            now: later
        )
        wrong.resultSHA256 = hash("wrong-result")
        wrong.authorizationSHA256 = ControlledEvalDigest.resultReviewAuthorizationSHA256(wrong)
        XCTAssertThrowsError(try service.validateResultReviewAuthorization(
            wrong,
            proposal: proposal,
            context: restarted,
            now: later
        )) {
            XCTAssertEqual($0 as? ControlledEvalFailure, .authorityMismatch)
        }

        let stale = try service.authorizeResultReview(
            proposal: proposal,
            context: restarted,
            now: later,
            validityDuration: 1
        )
        XCTAssertEqual(ControlledEvalResultReviewEligibilityEvaluator.evaluate(
            run: fixture.run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: restarted,
            authorizations: [stale],
            now: later.addingTimeInterval(2)
        ).state, .blocker)
    }

    func testApproveInconclusiveResultIsImmutableSingleUseAndRestoresReadOnly() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try completedFixture()
        XCTAssertEqual(fixture.run.overallResult, .inconclusive)
        let originalRevision = try XCTUnwrap(fixture.run.currentRevision)
        var restarted = context
        restarted.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-000000000024")!
        let proposal = try service.makeResultReviewProposal(
            fixture.run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: restarted
        )
        let authorization = try service.authorizeResultReview(
            proposal: proposal,
            context: restarted,
            now: later
        )
        let reviewed = try service.reviewResultsAuthorized(
            fixture.run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            proposal: proposal,
            authorization: authorization,
            decision: .approveResults,
            context: restarted,
            now: later
        )
        XCTAssertEqual(reviewed.run.currentState, .resultsApproved)
        XCTAssertEqual(reviewed.run.overallResult, .inconclusive)
        XCTAssertEqual(reviewed.run.currentRevision, originalRevision)
        XCTAssertEqual(reviewed.run.revisions.count, fixture.run.revisions.count)
        XCTAssertEqual(reviewed.run.reviewDecisions.filter { $0.stage == .results }.count, 1)
        let decision = try XCTUnwrap(reviewed.run.reviewDecision(stage: .results, attempt: originalRevision.attempt))
        XCTAssertEqual(decision.resultReviewAuthorizationID, authorization.authorizationID)
        XCTAssertEqual(decision.resultReviewConfirmationID, authorization.confirmationID)
        XCTAssertEqual(decision.runRevision, originalRevision.revision)
        XCTAssertEqual(decision.runSHA256, originalRevision.digest.sha256)
        XCTAssertEqual(decision.executionPolicySHA256, fixture.run.request.policy.policySHA256)
        XCTAssertEqual(decision.datasetManifestSHA256, fixture.run.request.dataset.manifestSHA256)
        XCTAssertTrue(decision.approvalScope.contains("INCONCLUSIVE remains INCONCLUSIVE"))
        XCTAssertTrue(decision.approvalScope.contains("not production approval"))
        XCTAssertTrue(decision.approvalScope.contains("deployment authorization"))
        XCTAssertTrue(decision.approvalScope.contains("customer acceptance"))
        XCTAssertTrue(decision.approvalScope.contains("Phase 3B"))
        XCTAssertTrue(reviewed.consumedAuthorization.isConsumed)
        XCTAssertTrue(reviewed.safetyCounters.hasZeroExternalAuthority)
        XCTAssertThrowsError(try service.reviewResultsAuthorized(
            reviewed.run,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            proposal: proposal,
            authorization: reviewed.consumedAuthorization,
            decision: .rejectResults,
            context: restarted,
            now: later
        ))

        let store = ControlledEvalRunStore(storageRoot: root)
        try store.save(fixture.run)
        let persistedAwaiting = try store.load(
            workspaceID: workspaceID,
            missionRunID: missionID,
            runID: fixture.run.runID
        )
        XCTAssertEqual(persistedAwaiting.request.requestSHA256, fixture.run.request.requestSHA256)
        XCTAssertEqual(persistedAwaiting.revisions.map(\.digest), fixture.run.revisions.map(\.digest))
        XCTAssertEqual(persistedAwaiting.reviewDecisions.map(\.decisionSHA256), fixture.run.reviewDecisions.map(\.decisionSHA256))
        XCTAssertTrue(ControlledEvalArtifactValidator.isAppendOnly(
            existing: persistedAwaiting,
            proposed: reviewed.run
        ))
        try store.save(reviewed.run)
        let restoredRuns = try store.loadAll(workspaceID: workspaceID)
        let restored = try XCTUnwrap(restoredRuns.first)
        XCTAssertEqual(restoredRuns.count, 1)
        XCTAssertEqual(restored.runID, fixture.run.runID)
        XCTAssertEqual(restored.currentRevision?.revision, originalRevision.revision)
        XCTAssertEqual(restored.currentRevision?.digest, originalRevision.digest)
        XCTAssertEqual(restored.currentRevision?.overallResult, originalRevision.overallResult)
        XCTAssertEqual(restored.currentRevision?.metricResults, originalRevision.metricResults)
        XCTAssertEqual(restored.currentRevision?.failures, originalRevision.failures)
        XCTAssertEqual(restored.currentRevision?.evidence, originalRevision.evidence)
        XCTAssertEqual(restored.reviewDecisions, reviewed.run.reviewDecisions)
        var secondRestart = restarted
        secondRestart.appSessionID = UUID(uuidString: "31000000-0000-0000-0000-000000000025")!
        XCTAssertEqual(ControlledEvalResultReviewEligibilityEvaluator.evaluate(
            run: restored,
            report: fixture.pair.report,
            evalPlan: fixture.pair.evalPlan,
            context: secondRestart,
            authorizations: []
        ).state, .finalizedReadOnly)
        XCTAssertFalse(restored.productionApprovalGranted)
        XCTAssertFalse(restored.deploymentAuthorized)
        XCTAssertFalse(restored.phase3BAvailable)
    }

    func testRequestChangesAndRejectPreserveOriginalResultArtifact() throws {
        for (index, decision) in [EvalRunReviewDecisionKind.requestChanges, .rejectResults].enumerated() {
            let runID = UUID(uuidString: index == 0
                ? "31000000-0000-0000-0000-000000000026"
                : "31000000-0000-0000-0000-000000000027")!
            let prepared = try preparedFixture(runID: runID)
            var run = try service.approveExecution(prepared.run, context: context)
            run = try service.execute(
                run,
                report: prepared.pair.report,
                evalPlan: prepared.pair.evalPlan,
                context: context,
                now: now
            ).run
            let immutableRevision = try XCTUnwrap(run.currentRevision)
            let proposal = try service.makeResultReviewProposal(
                run,
                report: prepared.pair.report,
                evalPlan: prepared.pair.evalPlan,
                context: context
            )
            let authorization = try service.authorizeResultReview(
                proposal: proposal,
                context: context,
                now: now
            )
            let reviewed = try service.reviewResultsAuthorized(
                run,
                report: prepared.pair.report,
                evalPlan: prepared.pair.evalPlan,
                proposal: proposal,
                authorization: authorization,
                decision: decision,
                instructions: decision == .requestChanges ? "Keep the exact result and prepare a later attempt." : nil,
                context: context,
                now: later
            )
            XCTAssertEqual(reviewed.run.currentRevision, immutableRevision)
            XCTAssertEqual(reviewed.run.overallResult, immutableRevision.overallResult)
            XCTAssertEqual(reviewed.run.currentState, decision == .requestChanges ? .resultsChangeRequested : .resultsRejected)
        }
    }

    func testUIContractsExposeOneControlledCTAAndNativeResultsWorkspace() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let missionSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FDECloudOS/UI/Components/MissionPresentationView.swift"),
            encoding: .utf8
        )
        let reviewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FDECloudOS/UI/Components/ControlledEvalReviewView.swift"),
            encoding: .utf8
        )
        let appStoreSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FDECloudOS/App/AppStore.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(MissionControlledEvalAction.reviewControlledEvalExecution.label, "Review controlled eval execution")
        XCTAssertEqual(MissionControlledEvalAction.reauthorizeControlledEvalExecution.label, "Reauthorize controlled eval execution")
        XCTAssertEqual(MissionControlledEvalAction.viewControlledEvalBlocker.label, "View blocker")
        XCTAssertEqual(MissionControlledEvalAction.reviewEvalResults.label, "Review eval results")
        XCTAssertEqual(MissionControlledEvalAction.authorizeEvalResultReview.label, "Authorize eval result review")
        XCTAssertEqual(MissionControlledEvalAction.reauthorizeEvalResultReview.label, "Reauthorize eval result review")
        XCTAssertEqual(MissionControlledEvalAction.viewEvalResults.label, "View eval results")
        XCTAssertTrue(missionSource.contains("mission.current.controlledEval.primaryAction"))
        XCTAssertTrue(missionSource.contains("mission.current.evalResults.primaryAction"))
        for section in ["SCENARIOS AND CASES", "Selected input", "Deterministic output", "Expected behavior", "Actual behavior", "Metrics", "Failures", "Evidence", "Exact Binding", "Revision History"] {
            XCTAssertTrue(reviewSource.contains(section), section)
        }
        XCTAssertTrue(reviewSource.contains("Phase 3B: unavailable"))
        XCTAssertTrue(reviewSource.contains("Production deployment: unavailable"))
        XCTAssertTrue(appStoreSource.contains("controlledEvalRunsInFlight.insert(run.runID)"))
        XCTAssertTrue(appStoreSource.contains("defer { controlledEvalRunsInFlight.remove(run.runID) }"))
        XCTAssertTrue(appStoreSource.contains("current.controlledEvalEligibility == eligibility"))
        XCTAssertTrue(appStoreSource.contains("func confirmAuthorizedControlledEvalExecution"))
        XCTAssertTrue(reviewSource.contains("Does not create or execute an Eval Run"))
        XCTAssertTrue(reviewSource.contains("Final execution confirmation is still required"))
        XCTAssertTrue(reviewSource.contains("Executes zero scenarios"))
        XCTAssertTrue(appStoreSource.contains("current.controlledEvalResultReviewEligibility == eligibility"))
        XCTAssertTrue(appStoreSource.contains("func prepareControlledEvalResultReview"))
        let undoCancellation = try XCTUnwrap(appStoreSource.range(of: "try cancelControlledEvalRunsForUndo(request)"))
        let cleanupStart = try XCTUnwrap(appStoreSource.range(of: "MissionCleanupStore(storageRoot: environment.sandboxLifecycle.storageRoot).save(starting)"))
        XCTAssertLessThan(undoCancellation.lowerBound, cleanupStart.lowerBound)
    }

    private let workspaceID = UUID(uuidString: "31000000-0000-0000-0000-000000000001")!
    private let missionID = UUID(uuidString: "31000000-0000-0000-0000-000000000002")!
    private let patchPlanID = UUID(uuidString: "31000000-0000-0000-0000-000000000003")!
    private let planningTaskID = UUID(uuidString: "31000000-0000-0000-0000-000000000004")!
    private let generatedPlanID = UUID(uuidString: "31000000-0000-0000-0000-000000000005")!
    private let generatedArtifactID = UUID(uuidString: "31000000-0000-0000-0000-000000000006")!
    private let authenticatedSessionID = UUID(uuidString: "31000000-0000-0000-0000-000000000007")!
    private let appSessionID = UUID(uuidString: "31000000-0000-0000-0000-000000000008")!
    private let workspaceSessionID = UUID(uuidString: "31000000-0000-0000-0000-000000000009")!
    private let reportID = UUID(uuidString: "31000000-0000-0000-0000-00000000000A")!
    private let evalPlanID = UUID(uuidString: "31000000-0000-0000-0000-00000000000B")!
    private let now = Date(timeIntervalSince1970: 1_760_000_000)
    private let later = Date(timeIntervalSince1970: 1_760_000_100)
    private let service = ControlledEvalExecutionService()

    private var context: ControlledEvalExecutionContext {
        ControlledEvalExecutionContext(
            missionRunID: missionID,
            workspaceID: workspaceID,
            authenticatedLocalSessionID: authenticatedSessionID,
            workspaceSessionID: workspaceSessionID,
            appSessionID: appSessionID
        )
    }

    private func preparedFixture(
        thresholdsDefined: Bool = false,
        maximumAttempts: Int = 1,
        runID: UUID = UUID(uuidString: "31000000-0000-0000-0000-00000000000C")!
    ) throws -> (pair: ProductionReadinessArtifacts, run: EvalRun) {
        let pair = try approvedPair(thresholdsDefined: thresholdsDefined)
        let dataset = try service.makeFixtureDataset(for: pair.evalPlan)
        var policy = try service.makeDefaultPolicy(for: pair.evalPlan, datasetID: dataset.datasetID)
        policy.maximumAttemptsPerCase = maximumAttempts
        policy.policySHA256 = ControlledEvalDigest.policySHA256(policy)
        let proposal = try service.makeExecutionProposal(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        )
        let authorization = try service.authorizeExecution(
            proposal: proposal,
            context: context,
            now: now
        )
        let run = try service.prepareAuthorized(
            report: pair.report,
            evalPlan: pair.evalPlan,
            proposal: proposal,
            authorization: authorization,
            context: context,
            runID: runID,
            now: now
        ).run
        return (pair, run)
    }

    private func completedFixture() throws -> (pair: ProductionReadinessArtifacts, run: EvalRun) {
        let prepared = try preparedFixture()
        var run = try service.approveExecution(prepared.run, context: context, now: now)
        run = try service.execute(
            run,
            report: prepared.pair.report,
            evalPlan: prepared.pair.evalPlan,
            context: context,
            now: now
        ).run
        return (prepared.pair, run)
    }

    private func approvedPair(thresholdsDefined: Bool = false) throws -> ProductionReadinessArtifacts {
        var artifacts = try planningArtifacts()
        if thresholdsDefined {
            for index in artifacts.evalPlan.revisions[0].metrics.indices {
                let metricID = artifacts.evalPlan.revisions[0].metrics[index].metricID
                let threshold: String
                if metricID.contains("violation") || metricID.contains("leakage")
                    || metricID.contains("hallucination") || metricID.contains("cost")
                    || metricID.contains("regression") {
                    threshold = "<= 0"
                } else if metricID.contains("latency") {
                    threshold = "<= 10"
                } else if metricID.contains("token") {
                    threshold = "<= 100"
                } else {
                    threshold = ">= 100%"
                }
                artifacts.evalPlan.revisions[0].metrics[index].proposedThreshold = threshold
            }
            artifacts.evalPlan.revisions[0].digest = .compute(
                artifacts.evalPlan.revisions[0],
                sourceBinding: artifacts.evalPlan.sourceBinding
            )
        }
        artifacts.report = try approveReport(artifacts.report)
        artifacts.evalPlan = try approvePlan(artifacts.evalPlan)
        return artifacts
    }

    private func planningArtifacts() throws -> ProductionReadinessArtifacts {
        try ProductionReadinessPlanningService().generate(
            sourceBinding: sourceBinding(),
            reportID: reportID,
            evalPlanID: evalPlanID,
            now: now
        )
    }

    private func approveReport(_ report: ProductionReadinessReport) throws -> ProductionReadinessReport {
        let revision = try XCTUnwrap(report.currentRevision)
        return try ProductionReadinessPlanningService().reviewReport(
            report,
            decision: .approvePlan,
            context: reviewContext(
                artifactID: report.reportID,
                revision: revision.revision,
                digest: revision.digest.sha256
            ),
            now: now
        )
    }

    private func approvePlan(_ plan: AIEvalPlan) throws -> AIEvalPlan {
        let revision = try XCTUnwrap(plan.currentRevision)
        return try ProductionReadinessPlanningService().reviewEvalPlan(
            plan,
            decision: .approvePlan,
            context: reviewContext(
                artifactID: plan.planID,
                revision: revision.revision,
                digest: revision.digest.sha256
            ),
            now: now
        )
    }

    private func reviewContext(
        artifactID: UUID,
        revision: Int,
        digest: String
    ) -> ProductionReadinessReviewContext {
        ProductionReadinessReviewContext(
            missionRunID: missionID,
            workspaceID: workspaceID,
            artifactID: artifactID,
            revision: revision,
            artifactSHA256: digest,
            authenticatedLocalSessionID: authenticatedSessionID,
            appSessionID: appSessionID
        )
    }

    private func sourceBinding() -> ProductionReadinessSourceBinding {
        var binding = ProductionReadinessSourceBinding(
            missionRunID: missionID,
            workspaceID: workspaceID,
            canonicalLegacyRoot: "/fixtures/ControlledEvalLegacy",
            sourceSnapshotID: hash("snapshot"),
            assessmentID: "assessment-controlled-eval",
            assessmentSHA256: hash("assessment"),
            sourceCandidatePatchTaskID: missionID,
            candidatePatchID: CandidatePatchID(rawValue: "31000000-0000-0000-0000-00000000000d")!,
            candidatePatchPlanID: patchPlanID,
            candidatePatchPlanRevision: 2,
            candidatePatchManifestID: "candidate-patch-manifest:controlled-eval",
            candidatePatchArtifactSHA256: hash("patch-artifact"),
            candidatePatchApprovalProvenanceSHA256: hash("patch-approval"),
            candidatePatchReviewOutcome: CandidatePatchApprovalDecision.approve.rawValue,
            sandboxID: SandboxID(rawValue: "31000000-0000-0000-0000-00000000000e")!,
            sandboxLifecycle: CandidatePatchStatus.reviewReady.rawValue,
            generatedTestPlanningTaskID: planningTaskID,
            generatedTestPlanID: generatedPlanID,
            generatedTestPlanRevision: 3,
            generatedTestPlanSHA256: hash("generated-plan"),
            generatedTestArtifactID: generatedArtifactID,
            generatedTestArtifactRevision: 4,
            generatedTestArtifactSHA256: hash("generated-artifact"),
            generatedTestArtifactReviewOutcome: GeneratedTestReviewDecisionKind.approve.rawValue,
            cleanupStatus: nil,
            normalizedCapabilityID: "controlled_read_only_lookup",
            capabilityDisplayLabel: "Controlled read-only lookup",
            authenticatedLocalSessionID: authenticatedSessionID,
            appSessionID: appSessionID,
            sourceBindingSHA256: ""
        )
        binding.sourceBindingSHA256 = binding.canonicalDigest
        return binding
    }

    private func assertPrepareThrows(
        _ expected: ControlledEvalFailure,
        pair: ProductionReadinessArtifacts,
        dataset: EvalDatasetManifest,
        policy: ControlledEvalExecutionPolicy,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try service.prepare(
            report: pair.report,
            evalPlan: pair.evalPlan,
            dataset: dataset,
            policy: policy,
            context: context
        ), file: file, line: line) {
            XCTAssertEqual($0 as? ControlledEvalFailure, expected, file: file, line: line)
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("controlled-eval-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func evalRunURL(root: URL, runID: UUID) -> URL {
        root
            .appendingPathComponent(".controlled-eval-runs")
            .appendingPathComponent(workspaceID.uuidString.lowercased())
            .appendingPathComponent(missionID.uuidString.lowercased())
            .appendingPathComponent(runID.uuidString.lowercased())
            .appendingPathComponent("eval-run.json")
    }

    private func hash(_ value: String) -> String {
        CandidatePatchArtifactAuthority.sha256(Data(value.utf8))
    }
}

private struct WrongFixtureProvider: ControlledEvalProviding {
    let identity = ControlledEvalProviderIdentity(
        evaluatorID: "wrong-provider",
        evaluatorVersion: "9.9.9",
        modelVersion: "wrong-model",
        mode: .deterministicFixture
    )

    func evaluate(_ datasetCase: EvalDatasetCase) throws -> ControlledEvalProviderOutput {
        throw ControlledEvalFailure.providerMismatch
    }
}

private struct SpoofedFixtureProvider: ControlledEvalProviding {
    let identity = DeterministicFixtureEvalProvider().identity

    func evaluate(_ datasetCase: EvalDatasetCase) throws -> ControlledEvalProviderOutput {
        ControlledEvalProviderOutput(
            deterministicOutput: "unapproved-output",
            actualBehavior: datasetCase.actualBehavior,
            metricValues: datasetCase.metricValues,
            evidenceReferences: datasetCase.evidenceReferences,
            tokenEstimate: datasetCase.tokenEstimate,
            estimatedCost: datasetCase.estimatedCost,
            durationMilliseconds: datasetCase.simulatedDurationMilliseconds
        )
    }
}
