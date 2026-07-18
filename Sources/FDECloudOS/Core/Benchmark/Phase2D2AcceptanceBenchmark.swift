import Foundation

enum Phase2D2AcceptanceCaseID: String, Codable, CaseIterable, Hashable, Sendable {
    case stableArtifactDigest = "2d2a.01_stable_artifact_digest"
    case authorityFieldChangesDigest = "2d2a.02_authority_field_changes_digest"
    case unifiedDiffChangesDigest = "2d2a.03_unified_diff_changes_digest"
    case imageHashChangesDigest = "2d2a.04_image_hash_changes_digest"
    case missingDigestFailsClosed = "2d2a.05_missing_digest_fails_closed"
    case validationPlanPersists = "2d2a.06_validation_plan_persists"
    case validationPlanMismatchFailsClosed = "2d2a.07_validation_plan_mismatch_fails_closed"
    case exactPatchBindingSucceeds = "2d2a.08_exact_patch_binding_succeeds"
    case wrongPatchFailsClosed = "2d2a.09_wrong_patch_fails_closed"
    case wrongSandboxFailsClosed = "2d2a.10_wrong_sandbox_fails_closed"
    case wrongSnapshotFailsClosed = "2d2a.11_wrong_snapshot_fails_closed"
    case wrongCapabilityAssessmentFailsClosed = "2d2a.12_wrong_capability_assessment_fails_closed"
    case latestPatchDoesNotGuess = "2d2a.13_latest_patch_does_not_guess"
    case scenariosLinkDiffHunks = "2d2a.14_scenarios_link_diff_hunks"
    case scenariosLinkValidationOrBlocker = "2d2a.15_scenarios_link_validation_or_blocker"
    case frameworkRequiresEvidence = "2d2a.16_framework_requires_evidence"
    case languageDoesNotEstablishFramework = "2d2a.17_language_does_not_establish_framework"
    case unknownFrameworkClarifies = "2d2a.18_unknown_framework_clarifies"
    case conflictingFrameworkClarifies = "2d2a.19_conflicting_framework_clarifies"
    case unknownLocationClarifies = "2d2a.20_unknown_location_clarifies"
    case syntheticLegacyClarifies = "2d2a.21_synthetic_legacy_clarifies"
    case clarificationHasNoApproval = "2d2a.22_clarification_has_no_approval"
    case planningHasNoSandboxWrites = "2d2a.23_planning_has_no_sandbox_writes"
    case planningHasNoGeneratedFiles = "2d2a.24_planning_has_no_generated_files"
    case structuredWritesDisabled = "2d2a.25_structured_writes_disabled"
    case buildTestUnavailable = "2d2a.26_build_test_unavailable"
    case dangerousOperationsUnavailable = "2d2a.27_dangerous_operations_unavailable"
    case accurateUnverifiedClaims = "2d2a.28_accurate_unverified_claims"
    case candidatePatchProjectionPreserved = "2d2a.29_candidate_patch_projection_preserved"
    case planSurvivesRestart = "2d2a.30_plan_survives_restart"
    case candidatePatchRegression = "2d2a.31_candidate_patch_regression"
    case revertDestructionRegression = "2d2a.32_revert_destruction_regression"
    case phase2D3Unavailable = "2d2a.33_phase_2d_3_unavailable"
}

enum Phase2D2AcceptanceEvaluationKind: String, Codable, Hashable, Sendable {
    case deterministicContract
    case disposableFilesystemFixture
    case syntheticLegacyReadOnlyFlow
    case phase2D1Regression
}

struct Phase2D2AcceptanceBenchmarkCase: Codable, Hashable, Sendable, Identifiable {
    var caseID: Phase2D2AcceptanceCaseID
    var title: String
    var evaluationKind: Phase2D2AcceptanceEvaluationKind
    var expectedInvariant: String
    var testMethod: String

    var id: String { caseID.rawValue }
}

struct Phase2D2AcceptanceBenchmark: Sendable {
    func runAll() -> [Phase2D2AcceptanceBenchmarkCase] {
        Phase2D2AcceptanceCaseID.allCases.map { caseID in
            Phase2D2AcceptanceBenchmarkCase(
                caseID: caseID,
                title: caseID.rawValue
                    .split(separator: "_", omittingEmptySubsequences: true)
                    .dropFirst()
                    .joined(separator: " ")
                    .capitalized,
                evaluationKind: evaluationKind(caseID),
                expectedInvariant: invariant(caseID),
                testMethod: testMethod(caseID)
            )
        }
    }

    private func evaluationKind(
        _ caseID: Phase2D2AcceptanceCaseID
    ) -> Phase2D2AcceptanceEvaluationKind {
        switch caseID {
        case .syntheticLegacyClarifies:
            return .syntheticLegacyReadOnlyFlow
        case .candidatePatchRegression, .revertDestructionRegression:
            return .phase2D1Regression
        case .stableArtifactDigest, .authorityFieldChangesDigest, .unifiedDiffChangesDigest,
             .imageHashChangesDigest, .validationPlanPersists, .validationPlanMismatchFailsClosed,
             .exactPatchBindingSucceeds, .wrongPatchFailsClosed, .wrongSandboxFailsClosed,
             .wrongSnapshotFailsClosed, .wrongCapabilityAssessmentFailsClosed,
             .scenariosLinkDiffHunks, .scenariosLinkValidationOrBlocker,
             .frameworkRequiresEvidence, .languageDoesNotEstablishFramework,
             .unknownFrameworkClarifies, .conflictingFrameworkClarifies,
             .unknownLocationClarifies, .planningHasNoSandboxWrites,
             .planningHasNoGeneratedFiles, .planSurvivesRestart:
            return .disposableFilesystemFixture
        default:
            return .deterministicContract
        }
    }

    private func invariant(_ caseID: Phase2D2AcceptanceCaseID) -> String {
        switch caseID {
        case .stableArtifactDigest, .authorityFieldChangesDigest, .unifiedDiffChangesDigest,
             .imageHashChangesDigest, .missingDigestFailsClosed:
            return "Candidate Patch authority is content-addressed, recomputed, and fails closed."
        case .validationPlanPersists, .validationPlanMismatchFailsClosed:
            return "The exact structured assessment validation plan remains digest-bound through planning."
        case .latestPatchDoesNotGuess, .exactPatchBindingSucceeds, .wrongPatchFailsClosed,
             .wrongSandboxFailsClosed, .wrongSnapshotFailsClosed,
             .wrongCapabilityAssessmentFailsClosed:
            return "Only an explicit exact visible Candidate Patch binding can authorize planning."
        case .frameworkRequiresEvidence, .languageDoesNotEstablishFramework,
             .unknownFrameworkClarifies, .conflictingFrameworkClarifies,
             .unknownLocationClarifies, .syntheticLegacyClarifies:
            return "Framework and location resolution uses bounded concrete Sandbox evidence or clarifies."
        case .structuredWritesDisabled, .buildTestUnavailable, .dangerousOperationsUnavailable,
             .planningHasNoSandboxWrites, .planningHasNoGeneratedFiles,
             .clarificationHasNoApproval, .phase2D3Unavailable:
            return "Phase 2D.2A persists plan metadata only and exposes no write or execution authority."
        case .candidatePatchRegression, .revertDestructionRegression:
            return "Released Phase 2D.1 Candidate Patch and Revert behavior remains green."
        default:
            return "The Generated Test Plan is grounded, reviewable, persistent, and truthfully unverified."
        }
    }

    private func testMethod(_ caseID: Phase2D2AcceptanceCaseID) -> String {
        switch caseID {
        case .candidatePatchRegression:
            return "CandidatePatchGenerationTests"
        case .revertDestructionRegression:
            return "CandidatePatchRevertTests"
        case .syntheticLegacyClarifies:
            return "testSyntheticLegacyReturnsClarificationRequiredWithoutWrites"
        default:
            return "GeneratedTestPlanningTests"
        }
    }
}
