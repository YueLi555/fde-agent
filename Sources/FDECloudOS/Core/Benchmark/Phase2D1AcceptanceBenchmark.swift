import Foundation

enum Phase2D1AcceptanceCaseID: String, Codable, CaseIterable, Hashable, Sendable {
    case chineseRouting = "2d1.01_chinese_routing"
    case englishRouting = "2d1.02_english_routing"
    case originalLegacyTargetRejected = "2d1.03_original_legacy_target_rejected"
    case agentWorkspaceTargetRejected = "2d1.04_agent_workspace_target_rejected"
    case nonReadySandboxRejected = "2d1.05_non_ready_sandbox_rejected"
    case staleSourceSnapshotRejected = "2d1.06_stale_source_snapshot_rejected"
    case missingPhase2CEvidenceRejected = "2d1.07_missing_phase_2c_evidence_rejected"
    case noMutationBeforeApproval = "2d1.08_no_mutation_before_approval"
    case rejectionProducesZeroChanges = "2d1.09_rejection_zero_changes"
    case requestChangesRequiresReapproval = "2d1.10_request_changes_reapproval"
    case approvedCreateSandboxOnly = "2d1.11_approved_create_sandbox_only"
    case approvedModifySandboxOnly = "2d1.12_approved_modify_sandbox_only"
    case absolutePathRejected = "2d1.13_absolute_path_rejected"
    case traversalRejected = "2d1.14_traversal_rejected"
    case symlinkEscapeRejected = "2d1.15_symlink_escape_rejected"
    case sandboxMetadataRejected = "2d1.16_sandbox_metadata_rejected"
    case credentialPathRejected = "2d1.17_credential_path_rejected"
    case binaryModificationRejected = "2d1.18_binary_modification_rejected"
    case deletionRenameRejected = "2d1.19_deletion_rename_rejected"
    case preimageMismatchRejected = "2d1.20_preimage_mismatch_rejected"
    case sourceDriftStopsApplication = "2d1.21_source_drift_stops_application"
    case diffMatchesContent = "2d1.22_diff_matches_content"
    case diffRelativePathsOnly = "2d1.23_diff_relative_paths_only"
    case legacyByteIdentical = "2d1.24_legacy_byte_identical"
    case partialFailureNotComplete = "2d1.25_partial_failure_not_complete"
    case manifestRecordsEvidence = "2d1.26_manifest_records_evidence"
    case revertRestoresSandbox = "2d1.27_revert_restores_sandbox"
    case revertLeavesLegacyUnchanged = "2d1.28_revert_leaves_legacy_unchanged"
    case prohibitedCapabilitiesUnavailable = "2d1.29_prohibited_capabilities_unavailable"
    case generatedTestsUnavailable = "2d1.30_generated_tests_unavailable"
    case liveActivityBeforeFinalization = "2d1.31_live_activity_before_finalization"
    case recoveryRetainsIdentifiers = "2d1.32_recovery_retains_identifiers"
    case sensitiveValuesNotExposed = "2d1.33_sensitive_values_not_exposed"
    case concurrentChangeFailsClosed = "2d1.34_concurrent_change_fails_closed"
    case syntheticReviewFlow = "2d1.35_synthetic_review_flow"
}

enum Phase2D1AcceptanceEvaluationKind: String, Codable, Hashable, Sendable {
    case deterministicContract
    case disposableFilesystemFixture
    case syntheticLegacyProductFlow
}

struct Phase2D1AcceptanceBenchmarkCase: Codable, Hashable, Sendable, Identifiable {
    var caseID: Phase2D1AcceptanceCaseID
    var title: String
    var evaluationKind: Phase2D1AcceptanceEvaluationKind
    var expectedInvariant: String
    var testMethod: String

    var id: String { caseID.rawValue }
}

struct Phase2D1AcceptanceBenchmark: Sendable {
    func runAll() -> [Phase2D1AcceptanceBenchmarkCase] {
        Phase2D1AcceptanceCaseID.allCases.map { caseID in
            Phase2D1AcceptanceBenchmarkCase(
                caseID: caseID,
                title: title(caseID),
                evaluationKind: evaluationKind(caseID),
                expectedInvariant: invariant(caseID),
                testMethod: testMethod(caseID)
            )
        }
    }

    private func evaluationKind(_ caseID: Phase2D1AcceptanceCaseID) -> Phase2D1AcceptanceEvaluationKind {
        switch caseID {
        case .chineseRouting, .englishRouting, .prohibitedCapabilitiesUnavailable,
             .generatedTestsUnavailable, .liveActivityBeforeFinalization, .recoveryRetainsIdentifiers:
            .deterministicContract
        case .syntheticReviewFlow:
            .syntheticLegacyProductFlow
        default:
            .disposableFilesystemFixture
        }
    }

    private func title(_ caseID: Phase2D1AcceptanceCaseID) -> String {
        caseID.rawValue
            .split(separator: "_", omittingEmptySubsequences: true)
            .dropFirst()
            .joined(separator: " ")
            .capitalized
    }

    private func invariant(_ caseID: Phase2D1AcceptanceCaseID) -> String {
        switch caseID {
        case .chineseRouting, .englishRouting:
            "Routes only to CANDIDATE_PATCH_GENERATION."
        case .noMutationBeforeApproval, .rejectionProducesZeroChanges, .requestChangesRequiresReapproval:
            "Sandbox workspace mutation remains approval-gated."
        case .approvedCreateSandboxOnly, .approvedModifySandboxOnly, .legacyByteIdentical,
             .revertLeavesLegacyUnchanged, .sourceDriftStopsApplication:
            "The original Legacy remains unchanged and all writes stay inside the Safe Sandbox."
        case .diffMatchesContent, .diffRelativePathsOnly:
            "Unified diff is deterministic, content-backed, and contains relative paths only."
        case .revertRestoresSandbox:
            "Revert restores preimages and removes only files created by this Candidate Patch."
        case .prohibitedCapabilitiesUnavailable, .generatedTestsUnavailable:
            "Shell, Git, build, test, deployment, credential, production, and Phase 2D.2 capabilities remain unavailable."
        case .syntheticReviewFlow:
            "The native SyntheticLegacy flow plans, waits for approval, applies, reviews, and reverts safely."
        default:
            "The operation fails closed with a sanitized Candidate Patch failure code."
        }
    }

    private func testMethod(_ caseID: Phase2D1AcceptanceCaseID) -> String {
        switch caseID {
        case .chineseRouting, .englishRouting:
            "testChineseAndEnglishRequestsRouteToDedicatedCandidatePatchMission"
        case .noMutationBeforeApproval, .rejectionProducesZeroChanges:
            "testNoSandboxWorkspaceMutationBeforeApprovalAndRejectProducesZeroChanges"
        case .requestChangesRequiresReapproval:
            "testRequestChangesRequiresRevisedPlanAndFreshApproval"
        case .approvedCreateSandboxOnly, .approvedModifySandboxOnly, .diffMatchesContent,
             .diffRelativePathsOnly, .legacyByteIdentical:
            "testApprovedCreateAndModifyApplyOnlyInsideSandboxAndDiffUsesRelativeActualContent"
        case .absolutePathRejected, .traversalRejected, .sandboxMetadataRejected, .credentialPathRejected,
             .deletionRenameRejected, .generatedTestsUnavailable:
            "testAbsoluteTraversalMetadataCredentialAndGeneratedTestPathsAreRejected"
        case .symlinkEscapeRejected, .binaryModificationRejected:
            "testScopeSymlinkHardLinkAndBinaryTargetsFailClosed"
        case .preimageMismatchRejected, .concurrentChangeFailsClosed, .partialFailureNotComplete:
            "testPreimageMismatchAndUnexpectedConcurrentSandboxChangeMarkPatchStaleWithoutBlindOverwrite"
        case .sourceDriftStopsApplication:
            "testSourceDriftStopsApprovedPatchAndOriginalIsNeverRepaired"
        case .manifestRecordsEvidence, .sensitiveValuesNotExposed:
            "testManifestRecordsEvidenceHashesApprovalImpactRiskAndAudit"
        case .revertRestoresSandbox, .revertLeavesLegacyUnchanged:
            "testRevertRestoresModifiedFilesRemovesOnlyPatchCreatedFilesAndPreservesAuditAndLegacy"
        case .prohibitedCapabilitiesUnavailable:
            "testPhase2D1RuntimePolicyExposesOnlyStructuredCandidateTextOperations"
        case .liveActivityBeforeFinalization, .recoveryRetainsIdentifiers:
            "testNativeRuntimeRouteWaitsForApprovalThenProducesManifestBackedReviewWithoutTools"
        case .syntheticReviewFlow:
            "testSyntheticLegacyNativeCandidateReviewFlowAndRevert"
        case .originalLegacyTargetRejected, .agentWorkspaceTargetRejected, .nonReadySandboxRejected,
             .staleSourceSnapshotRejected, .missingPhase2CEvidenceRejected:
            "testLegacyAgentNonReadyStaleAndMissingAssessmentPreconditionsFailClosed"
        }
    }
}
