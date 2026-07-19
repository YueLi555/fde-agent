import XCTest
@testable import FDECloudOS

final class ProductionReadinessPlanningTests: XCTestCase {
    func testArtifactsBindToSameExactMissionAndRemainSeparate() throws {
        let artifacts = try fixtureArtifacts()
        XCTAssertEqual(artifacts.report.sourceBinding.missionRunID, missionID)
        XCTAssertEqual(artifacts.evalPlan.sourceBinding.readinessSourceBinding.missionRunID, missionID)
        XCTAssertEqual(artifacts.report.sourceBinding, artifacts.evalPlan.sourceBinding.readinessSourceBinding)
        XCTAssertNotEqual(artifacts.report.reportID, artifacts.evalPlan.planID)
        XCTAssertNotEqual(artifacts.report.currentRevision?.digest.sha256, artifacts.evalPlan.currentRevision?.digest.sha256)
    }

    func testConflictingOrTamperedLineageFailsClosed() throws {
        var binding = sourceBinding()
        binding.generatedTestPlanSHA256 = hash("wrong-plan")
        XCTAssertThrowsError(try ProductionReadinessPlanningService().generate(sourceBinding: binding)) {
            XCTAssertEqual($0 as? ProductionReadinessFailure, .exactSourceBindingRequired)
        }
    }

    func testNoLatestArtifactFallbackCanRepairIncompleteBinding() throws {
        var binding = sourceBinding()
        binding.generatedTestArtifactID = UUID()
        binding.sourceBindingSHA256 = ""
        XCTAssertThrowsError(try ProductionReadinessPlanningService().generate(sourceBinding: binding))
    }

    func testAllReadinessAreasAreRepresentedExactlyOnce() throws {
        let findings = try XCTUnwrap(fixtureArtifacts().report.currentRevision?.findings)
        XCTAssertEqual(ProductionReadinessArea.allCases.count, 17)
        XCTAssertEqual(findings.count, ProductionReadinessArea.allCases.count)
        XCTAssertEqual(Set(findings.map(\.area)), Set(ProductionReadinessArea.allCases))
        XCTAssertEqual(Set(findings.map(\.findingID)).count, findings.count)
    }

    func testUnsupportedClaimsRemainUnknownAndReadyRequiresConfirmedEvidence() throws {
        let findings = try XCTUnwrap(fixtureArtifacts().report.currentRevision?.findings)
        XCTAssertTrue(findings.contains { $0.status == .unknown })
        XCTAssertFalse(findings.contains { $0.status == .ready })
        XCTAssertTrue(findings.filter { $0.status == .unknown }.allSatisfy { $0.verificationState == .unknown })
    }

    func testProposedPatchAndVirtualTestsAreNotRuntimeEvidence() throws {
        let evidence = try XCTUnwrap(fixtureArtifacts().report.currentRevision)
            .findings.flatMap(\.supportingEvidence)
        let patch = try XCTUnwrap(evidence.first { $0.evidenceID == "evidence.candidate-patch" })
        let tests = try XCTUnwrap(evidence.first { $0.evidenceID == "evidence.generated-test-artifact" })
        XCTAssertEqual(patch.kind, .notExecuted)
        XCTAssertEqual(tests.kind, .notExecuted)
        XCTAssertTrue(patch.limitations.contains("not runtime verification"))
        XCTAssertTrue(tests.limitations.contains("not written, compiled, or executed"))
    }

    func testOverallResultIsDeterministicAndBlockersProduceNotReady() throws {
        let first = try fixtureArtifacts().report.currentRevision
        let second = try fixtureArtifacts().report.currentRevision
        XCTAssertEqual(first?.overallResult, .notReady)
        XCTAssertEqual(first?.overallResult, second?.overallResult)
        XCTAssertFalse(first?.blockers.isEmpty ?? true)
    }

    func testMissingEvidenceProducesUnknownFindings() throws {
        let revision = try XCTUnwrap(fixtureArtifacts().report.currentRevision)
        XCTAssertTrue(revision.findings.contains {
            $0.status == .unknown && !$0.remainingUnknown.isEmpty
        })
    }

    func testReleaseGatesPreserveEvidenceAndNoneArePassed() throws {
        let gates = try XCTUnwrap(fixtureArtifacts().report.currentRevision?.releaseGates)
        XCTAssertTrue(gates.allSatisfy { !$0.evidenceRequired.isEmpty })
        XCTAssertTrue(gates.allSatisfy { $0.currentStatus != .passed })
        XCTAssertTrue(gates.allSatisfy { $0.passedEvidenceIDs.isEmpty })
        XCTAssertTrue(gates.contains { $0.gateID == "gate.record-authorization" })
        XCTAssertTrue(gates.contains { $0.gateID == "gate.customer-acceptance" })
    }

    func testAllEvalScenarioGroupsExistWithStableIDsAndPlannedState() throws {
        let first = try XCTUnwrap(fixtureArtifacts().evalPlan.currentRevision?.scenarios)
        let second = try XCTUnwrap(fixtureArtifacts().evalPlan.currentRevision?.scenarios)
        XCTAssertEqual(AIEvalScenarioGroup.allCases.count, 17)
        XCTAssertEqual(Set(first.map(\.group)), Set(AIEvalScenarioGroup.allCases))
        XCTAssertEqual(first.map(\.scenarioID), second.map(\.scenarioID))
        XCTAssertTrue(first.allSatisfy { $0.verificationState == .plannedNotExecuted })
        XCTAssertTrue(first.allSatisfy { !$0.requiredEvidence.isEmpty && !$0.metricBindings.isEmpty })
    }

    func testMetricValuesAreNeverFabricatedAndThresholdsRemainProposals() throws {
        let metrics = try XCTUnwrap(fixtureArtifacts().evalPlan.currentRevision?.metrics)
        XCTAssertEqual(metrics.count, 14)
        XCTAssertTrue(metrics.allSatisfy { $0.actualResult == nil })
        XCTAssertTrue(metrics.allSatisfy { !$0.proposedThreshold.isEmpty })
        XCTAssertTrue(metrics.allSatisfy { $0.missingEvidence.contains("No eval execution occurred") })
        XCTAssertTrue(metrics.contains { $0.metricID == "metric.p95-latency" })
        XCTAssertTrue(metrics.contains { $0.metricID == "metric.regression-delta" })
    }

    func testFailureTaxonomyIsCompleteReusableAndNotFixtureSpecific() throws {
        let taxonomy = try XCTUnwrap(fixtureArtifacts().evalPlan.currentRevision?.failureTaxonomy)
        XCTAssertEqual(taxonomy, AIEvalFailureCategory.allCases)
        XCTAssertTrue(taxonomy.contains(.tenantBoundaryViolation))
        XCTAssertTrue(taxonomy.contains(.configurationDrift))
        XCTAssertFalse(taxonomy.map(\.rawValue).joined().contains("TestableLegacy"))
    }

    func testCanonicalSHA256DigestsAreDeterministic() throws {
        let first = try fixtureArtifacts()
        let second = try fixtureArtifacts()
        XCTAssertEqual(first.report.currentRevision?.digest, second.report.currentRevision?.digest)
        XCTAssertEqual(first.evalPlan.currentRevision?.digest, second.evalPlan.currentRevision?.digest)
        XCTAssertEqual(first.report.currentRevision?.digest.sha256.count, 64)
        XCTAssertEqual(first.evalPlan.currentRevision?.digest.sha256.count, 64)
    }

    func testDefaultArtifactIDsAreDeterministicForExactSourceBinding() throws {
        let service = ProductionReadinessPlanningService()
        let first = try service.generate(sourceBinding: sourceBinding(), now: now)
        let second = try service.generate(sourceBinding: sourceBinding(), now: later)
        XCTAssertEqual(first.report.reportID, second.report.reportID)
        XCTAssertEqual(first.evalPlan.planID, second.evalPlan.planID)
        XCTAssertNotEqual(first.report.reportID, first.evalPlan.planID)
    }

    func testPersistedBytesAreRevalidatedAndTamperingFailsClosed() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try fixtureArtifacts()
        let store = ProductionReadinessArtifactStore(storageRoot: root)
        try store.save(artifacts.report)
        let restored = try store.loadReport(
            workspaceID: workspaceID,
            missionRunID: missionID,
            reportID: reportID
        )
        XCTAssertEqual(restored, artifacts.report)

        var tampered = restored
        tampered.revisions[0].findings[0].summary = "tampered"
        let url = root
            .appendingPathComponent(".production-readiness-artifacts")
            .appendingPathComponent(workspaceID.uuidString.lowercased())
            .appendingPathComponent(missionID.uuidString.lowercased())
            .appendingPathComponent("readiness-reports")
            .appendingPathComponent(reportID.uuidString.lowercased())
            .appendingPathComponent("production-readiness-report.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tampered).write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.loadReport(
            workspaceID: workspaceID,
            missionRunID: missionID,
            reportID: reportID
        ))
    }

    func testRequestChangesCreatesNewImmutableReportRevision() throws {
        let artifacts = try fixtureArtifacts()
        let current = try XCTUnwrap(artifacts.report.currentRevision)
        let updated = try ProductionReadinessPlanningService().reviewReport(
            artifacts.report,
            decision: .requestChanges,
            instructions: "Add an accountable owner to every blocking gate.",
            context: reviewContext(
                artifactID: artifacts.report.reportID,
                revision: current.revision,
                digest: current.digest.sha256
            ),
            now: later
        )
        XCTAssertEqual(updated.revisions.count, 2)
        XCTAssertEqual(updated.revisions[0], artifacts.report.revisions[0])
        XCTAssertEqual(updated.reviewDecisions.first?.decision, .requestChanges)
        XCTAssertNotNil(updated.revisions[1].reviewInstructionSHA256)
    }

    func testRequestChangesCreatesNewImmutableEvalRevision() throws {
        let artifacts = try fixtureArtifacts()
        let current = try XCTUnwrap(artifacts.evalPlan.currentRevision)
        let updated = try ProductionReadinessPlanningService().reviewEvalPlan(
            artifacts.evalPlan,
            decision: .requestChanges,
            instructions: "Add malformed Unicode cases.",
            context: reviewContext(
                artifactID: artifacts.evalPlan.planID,
                revision: current.revision,
                digest: current.digest.sha256
            ),
            now: later
        )
        XCTAssertEqual(updated.revisions.count, 2)
        XCTAssertEqual(updated.revisions[0], artifacts.evalPlan.revisions[0])
        XCTAssertEqual(updated.reviewDecisions.first?.decision, .requestChanges)
    }

    func testRejectPreservesEvidenceAndApproveMeansPlanApprovalOnly() throws {
        let artifacts = try fixtureArtifacts()
        let current = try XCTUnwrap(artifacts.report.currentRevision)
        let rejected = try ProductionReadinessPlanningService().reviewReport(
            artifacts.report,
            decision: .reject,
            context: reviewContext(
                artifactID: artifacts.report.reportID,
                revision: current.revision,
                digest: current.digest.sha256
            ),
            now: later
        )
        XCTAssertEqual(rejected.revisions, artifacts.report.revisions)
        XCTAssertEqual(rejected.reviewDecisions.first?.decision, .reject)

        let approved = try ProductionReadinessPlanningService().reviewReport(
            artifacts.report,
            decision: .approvePlan,
            context: reviewContext(
                artifactID: artifacts.report.reportID,
                revision: current.revision,
                digest: current.digest.sha256
            ),
            now: later
        )
        XCTAssertEqual(approved.reviewDecisions.first?.approvalScope, ProductionReadinessPlanningService.planApprovalScope)
        XCTAssertFalse(approved.productionExecutionAuthorized)
        XCTAssertFalse(approved.deploymentAuthorized)
    }

    func testReviewRequiresExactAuthenticatedAndAppSessionAuthority() throws {
        let artifacts = try fixtureArtifacts()
        let current = try XCTUnwrap(artifacts.report.currentRevision)
        var context = reviewContext(
            artifactID: artifacts.report.reportID,
            revision: current.revision,
            digest: current.digest.sha256
        )
        context.appSessionID = UUID()
        XCTAssertThrowsError(try ProductionReadinessPlanningService().reviewReport(
            artifacts.report,
            decision: .approvePlan,
            context: context
        )) {
            XCTAssertEqual($0 as? ProductionReadinessFailure, .reviewAuthorityUnavailable)
        }
    }

    func testPersistenceRestoresBothExactArtifactsAndAppendOnlyHistory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifacts = try fixtureArtifacts()
        let store = ProductionReadinessArtifactStore(storageRoot: root)
        try store.save(artifacts.report)
        try store.save(artifacts.evalPlan)
        XCTAssertEqual(try store.loadAllReports(workspaceID: workspaceID), [artifacts.report])
        XCTAssertEqual(try store.loadAllEvalPlans(workspaceID: workspaceID), [artifacts.evalPlan])

        var rewritten = artifacts.report
        rewritten.revisions[0].findings[0].summary = "rewrite"
        rewritten.revisions[0].digest = .compute(rewritten.revisions[0], sourceBinding: rewritten.sourceBinding)
        XCTAssertThrowsError(try store.save(rewritten)) {
            XCTAssertEqual($0 as? ProductionReadinessFailure, .revisionImmutable)
        }
    }

    func testOnlyCommittedArtifactPairsRestoreAndInterruptedSaveIsRetryable() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = ProductionReadinessPlanningService()
        let first = try service.generate(sourceBinding: sourceBinding(), now: now)
        let retry = try service.generate(sourceBinding: sourceBinding(), now: later)
        let store = ProductionReadinessArtifactStore(storageRoot: root)

        try store.save(first.report)
        XCTAssertEqual(try store.loadAllPairs(workspaceID: workspaceID).reports, [])
        XCTAssertEqual(try store.loadAllPairs(workspaceID: workspaceID).evalPlans, [])

        try store.save(retry)
        let restored = try store.loadAllPairs(workspaceID: workspaceID)
        XCTAssertEqual(restored.reports.count, 1)
        XCTAssertEqual(restored.evalPlans.count, 1)
        XCTAssertEqual(restored.reports[0].reportID, first.report.reportID)
        XCTAssertEqual(restored.evalPlans[0].planID, retry.evalPlan.planID)
        XCTAssertEqual(
            restored.reports[0].sourceBinding,
            restored.evalPlans[0].sourceBinding.readinessSourceBinding
        )
    }

    func testSafetyCountersProveZeroExecutionAuthority() throws {
        let counters = try fixtureArtifacts().safetyCounters
        XCTAssertTrue(counters.hasZeroExecutionAuthority)
        XCTAssertEqual(counters.legacyWrites, 0)
        XCTAssertEqual(counters.sandboxWrites, 0)
        XCTAssertEqual(counters.candidatePatchMutations, 0)
        XCTAssertEqual(counters.generatedSourceWrites, 0)
        XCTAssertEqual(counters.evalExecutions, 0)
        XCTAssertEqual(counters.modelBenchmarkExecutions, 0)
        XCTAssertEqual(counters.syntaxChecks, 0)
        XCTAssertEqual(counters.buildExecutions, 0)
        XCTAssertEqual(counters.testExecutions, 0)
        XCTAssertEqual(counters.shellOperations, 0)
        XCTAssertEqual(counters.gitOperations, 0)
        XCTAssertEqual(counters.packageManagerOperations, 0)
        XCTAssertEqual(counters.deploymentOperations, 0)
        XCTAssertEqual(counters.credentialAccesses, 0)
        XCTAssertEqual(counters.productionAccesses, 0)
    }

    func testLaterExecutionAndRolloutRemainUnavailable() throws {
        let artifacts = try fixtureArtifacts()
        XCTAssertFalse(artifacts.evalPlan.evalExecutionAvailable)
        XCTAssertFalse(artifacts.evalPlan.productionRolloutAvailable)
        XCTAssertFalse(artifacts.report.productionExecutionAuthorized)
        XCTAssertFalse(artifacts.report.deploymentAuthorized)
    }

    func testUnifiedReviewAndOneCTAContractsArePresent() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let missionSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FDECloudOS/UI/Components/MissionPresentationView.swift"),
            encoding: .utf8
        )
        let reviewSource = try String(
            contentsOf: root.appendingPathComponent("Sources/FDECloudOS/UI/Components/ProductionReadinessReviewView.swift"),
            encoding: .utf8
        )
        XCTAssertEqual(MissionPostReadyAction.allCases, [.reviewProductionReadiness])
        XCTAssertEqual(MissionPostReadyAction.reviewProductionReadiness.label, "Review production readiness")
        XCTAssertTrue(missionSource.contains("mission.current.productionReadiness.primaryAction"))
        XCTAssertFalse(missionSource.contains("Generate readiness report"))
        XCTAssertFalse(missionSource.contains("Generate Eval Plan"))
        XCTAssertFalse(missionSource.contains("Review readiness and eval plan"))
        for section in ["Overview", "Production Readiness", "Release Gates", "Eval Scenarios", "Metrics", "Failure Taxonomy", "Evidence", "Exact Binding", "Revision History"] {
            XCTAssertTrue(reviewSource.contains(section), section)
        }
        XCTAssertTrue(reviewSource.contains("Eval execution is unavailable in Phase 3A.0"))
        XCTAssertTrue(reviewSource.contains("Production rollout remains unavailable"))
    }

    private let workspaceID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    private let missionID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
    private let patchPlanID = UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
    private let planningTaskID = UUID(uuidString: "30000000-0000-0000-0000-000000000004")!
    private let generatedPlanID = UUID(uuidString: "30000000-0000-0000-0000-000000000005")!
    private let generatedArtifactID = UUID(uuidString: "30000000-0000-0000-0000-000000000006")!
    private let authenticatedSessionID = UUID(uuidString: "30000000-0000-0000-0000-000000000007")!
    private let appSessionID = UUID(uuidString: "30000000-0000-0000-0000-000000000008")!
    private let reportID = UUID(uuidString: "30000000-0000-0000-0000-000000000009")!
    private let evalPlanID = UUID(uuidString: "30000000-0000-0000-0000-00000000000A")!
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let later = Date(timeIntervalSince1970: 1_750_000_100)

    private func sourceBinding() -> ProductionReadinessSourceBinding {
        var binding = ProductionReadinessSourceBinding(
            missionRunID: missionID,
            workspaceID: workspaceID,
            canonicalLegacyRoot: "/fixtures/GenericLegacy",
            sourceSnapshotID: hash("snapshot"),
            assessmentID: "assessment-generic",
            assessmentSHA256: hash("assessment"),
            sourceCandidatePatchTaskID: missionID,
            candidatePatchID: CandidatePatchID(rawValue: "30000000-0000-0000-0000-00000000000b")!,
            candidatePatchPlanID: patchPlanID,
            candidatePatchPlanRevision: 2,
            candidatePatchManifestID: "candidate-patch-manifest:exact",
            candidatePatchArtifactSHA256: hash("patch-artifact"),
            candidatePatchApprovalProvenanceSHA256: hash("patch-approval"),
            candidatePatchReviewOutcome: CandidatePatchApprovalDecision.approve.rawValue,
            sandboxID: SandboxID(rawValue: "30000000-0000-0000-0000-00000000000c")!,
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
            normalizedCapabilityID: "generic_read_only_lookup",
            capabilityDisplayLabel: "Generic read-only lookup",
            authenticatedLocalSessionID: authenticatedSessionID,
            appSessionID: appSessionID,
            sourceBindingSHA256: ""
        )
        binding.sourceBindingSHA256 = binding.canonicalDigest
        return binding
    }

    private func fixtureArtifacts() throws -> ProductionReadinessArtifacts {
        try ProductionReadinessPlanningService().generate(
            sourceBinding: sourceBinding(),
            reportID: reportID,
            evalPlanID: evalPlanID,
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

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("phase-3a-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func hash(_ value: String) -> String {
        CandidatePatchArtifactAuthority.sha256(Data(value.utf8))
    }
}
