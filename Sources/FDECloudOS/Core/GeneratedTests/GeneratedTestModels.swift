import Foundation

enum GeneratedTestLifecycleStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case patchReady = "PATCH_READY"
    case resolvingTestEnvironment = "RESOLVING_TEST_ENVIRONMENT"
    case clarificationRequired = "CLARIFICATION_REQUIRED"
    case preparingTestGenerationPlan = "PREPARING_TEST_GENERATION_PLAN"
    case testPlanReviewReady = "TEST_PLAN_REVIEW_READY"
    case testPlanApprovalRequired = "TEST_PLAN_APPROVAL_REQUIRED"
    case loadingExactPatch = "LOADING_EXACT_PATCH"
    case validatingTestPlan = "VALIDATING_TEST_PLAN"
    case discoveringTestConventions = "DISCOVERING_TEST_CONVENTIONS"
    case generatingTestScenarios = "GENERATING_TEST_SCENARIOS"
    case generatingVirtualTestFiles = "GENERATING_VIRTUAL_TEST_FILES"
    case bindingEvidence = "BINDING_EVIDENCE"
    case verifyingArtifactDigest = "VERIFYING_ARTIFACT_DIGEST"
    case testArtifactReviewReady = "TEST_ARTIFACT_REVIEW_READY"
    case artifactChangeRequested = "ARTIFACT_CHANGE_REQUESTED"
    case artifactRejected = "ARTIFACT_REJECTED"
    case artifactApproved = "ARTIFACT_APPROVED"
    case rejected = "REJECTED"
    case blocked = "BLOCKED"
    case failed = "FAILED"
}

enum GeneratedTestEnvironmentResolutionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case frameworkConfirmed = "framework_confirmed"
    case frameworkConflict = "framework_conflict"
    case frameworkUnknown = "framework_unknown"
    case testLocationConfirmed = "test_location_confirmed"
    case testLocationConflict = "test_location_conflict"
    case testLocationUnknown = "test_location_unknown"
}

enum GeneratedTestEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case projectManifest
    case testScript
    case dependency
    case frameworkConfiguration
    case existingTest
    case testImport
    case testTarget
    case affectedSource
    case validationReference
}

enum GeneratedTestStructuredOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case readBoundSandboxManifest = "generated_test_read_bound_sandbox_manifest"
    case readBoundCandidatePatchSource = "generated_test_read_bound_candidate_patch_source"
    case readGroundedTestConfiguration = "generated_test_read_grounded_test_configuration"
    case createTestText = "generated_test_create_test_text"
    case replaceTestText = "generated_test_replace_test_text"
    case revertGeneratedTestText = "generated_test_revert_test_text"
    case createDirectory = "generated_test_create_directory"
    case modifyDependencies = "generated_test_modify_dependencies"
    case executeBuildOrTest = "generated_test_execute_build_or_test"
    case executeShellGitPackageManagerDeployment = "generated_test_execute_shell_git_package_manager_deployment"
}

enum GeneratedTestPlanningPolicy {
    static let phase2D2AReadAllowlist: Set<GeneratedTestStructuredOperation> = [
        .readBoundSandboxManifest,
        .readBoundCandidatePatchSource,
        .readGroundedTestConfiguration
    ]
    static let phase2D2AWriteAllowlist: Set<GeneratedTestStructuredOperation> = []

    static func permits(_ operation: GeneratedTestStructuredOperation) -> Bool {
        phase2D2AReadAllowlist.contains(operation)
    }
}

struct GeneratedTestCandidatePostimage: Codable, Hashable, Sendable {
    var relativePath: String
    var sha256: String
}

struct CandidatePatchGeneratedTestSourceBinding: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var sourceCandidatePatchTaskID: UUID
    var patchID: CandidatePatchID
    var candidatePatchPlanID: UUID
    var candidatePatchPlanRevision: Int
    var candidatePatchManifestID: String
    var candidatePatchArtifactSHA256: String
    var candidatePatchApprovalProvenanceSHA256: String
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var canonicalLegacyRoot: String
    var normalizedCapabilityID: String
    var capabilityDisplayLabel: String
    var validatedAssessmentID: String
    var validationTestPlanSHA256: String
    var unifiedDiffSHA256: String
    var changedRelativePaths: [String]
    var createdRelativePaths: [String]
    var candidatePatchPostimages: [GeneratedTestCandidatePostimage]
    var authenticatedLocalSessionID: UUID

    init?(manifest: CandidatePatchManifest) {
        guard let appliedBinding = manifest.appliedBinding,
              appliedBinding.patchID == manifest.patchID,
              appliedBinding.planID == manifest.plan.planID,
              appliedBinding.planRevision == manifest.plan.revision,
              appliedBinding.sandboxID == manifest.sandboxID,
              appliedBinding.manifestID == manifest.stableManifestID,
              appliedBinding.sourceSnapshotID == manifest.sourceSnapshotID,
              appliedBinding.canonicalLegacyRoot == manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
              let artifactSHA256 = manifest.candidatePatchArtifactSHA256,
              appliedBinding.candidatePatchArtifactSHA256 == artifactSHA256,
              let provenance = manifest.plan.approvalRecord?.provenance,
              let validationTestPlanSHA256 = manifest.validationTestPlanSHA256,
              let unifiedDiff = manifest.unifiedDiff else {
            return nil
        }
        workspaceID = appliedBinding.workspaceID
        sourceCandidatePatchTaskID = appliedBinding.taskID
        patchID = manifest.patchID
        candidatePatchPlanID = manifest.plan.planID
        candidatePatchPlanRevision = manifest.plan.revision
        candidatePatchManifestID = manifest.stableManifestID
        candidatePatchArtifactSHA256 = artifactSHA256
        candidatePatchApprovalProvenanceSHA256 = CandidatePatchArtifactAuthority
            .approvalProvenanceSHA256(provenance)
        sandboxID = manifest.sandboxID
        sourceSnapshotID = manifest.sourceSnapshotID
        canonicalLegacyRoot = manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot
        normalizedCapabilityID = manifest.plan.requestedCapabilityID
        capabilityDisplayLabel = manifest.plan.assessmentContext?.requestedCapabilityDisplayLabel
            ?? manifest.plan.requestedCapabilityID
        validatedAssessmentID = manifest.plan.assessmentID
        self.validationTestPlanSHA256 = validationTestPlanSHA256
        unifiedDiffSHA256 = CandidatePatchArtifactAuthority.unifiedDiffSHA256(unifiedDiff)
        changedRelativePaths = CandidatePatchArtifactAuthority.changedPaths(in: manifest)
        createdRelativePaths = CandidatePatchArtifactAuthority.createdPaths(in: manifest)
        candidatePatchPostimages = manifest.operations.compactMap { operation in
            operation.resultingSHA256.map {
                GeneratedTestCandidatePostimage(
                    relativePath: operation.relativeCanonicalSandboxPath,
                    sha256: $0
                )
            }
        }.sorted(by: { $0.relativePath < $1.relativePath })
        authenticatedLocalSessionID = appliedBinding.authenticatedLocalSessionID
    }

    var digest: String {
        var fields: [(String, String)] = [
            ("workspace_id", workspaceID.uuidString.lowercased()),
            ("source_candidate_patch_task_id", sourceCandidatePatchTaskID.uuidString.lowercased()),
            ("patch_id", patchID.rawValue),
            ("candidate_patch_plan_id", candidatePatchPlanID.uuidString.lowercased()),
            ("candidate_patch_plan_revision", String(candidatePatchPlanRevision)),
            ("candidate_patch_manifest_id", candidatePatchManifestID),
            ("candidate_patch_artifact_sha256", candidatePatchArtifactSHA256),
            ("candidate_patch_approval_provenance_sha256", candidatePatchApprovalProvenanceSHA256),
            ("sandbox_id", sandboxID.rawValue),
            ("source_snapshot_id", sourceSnapshotID),
            ("canonical_legacy_root", canonicalLegacyRoot),
            ("normalized_capability_id", normalizedCapabilityID),
            ("capability_display_label", capabilityDisplayLabel),
            ("validated_assessment_id", validatedAssessmentID),
            ("validation_test_plan_sha256", validationTestPlanSHA256),
            ("unified_diff_sha256", unifiedDiffSHA256),
            ("authenticated_local_session_id", authenticatedLocalSessionID.uuidString.lowercased())
        ]
        for (index, path) in changedRelativePaths.sorted().enumerated() {
            fields.append(("changed_path_\(index)", path))
        }
        for (index, path) in createdRelativePaths.sorted().enumerated() {
            fields.append(("created_path_\(index)", path))
        }
        for (index, postimage) in candidatePatchPostimages
            .sorted(by: { $0.relativePath < $1.relativePath })
            .enumerated() {
            fields.append(("postimage_\(index)_path", postimage.relativePath))
            fields.append(("postimage_\(index)_sha256", postimage.sha256))
        }
        return CandidatePatchArtifactAuthority.digest(fields)
    }
}

struct GeneratedTestSourceBinding: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var generatedTestPlanningTaskID: UUID
    var sourceCandidatePatchTaskID: UUID
    var patchID: CandidatePatchID
    var candidatePatchPlanID: UUID
    var candidatePatchPlanRevision: Int
    var candidatePatchManifestID: String
    var candidatePatchArtifactSHA256: String
    var candidatePatchApprovalProvenanceSHA256: String
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var canonicalLegacyRoot: String
    var normalizedCapabilityID: String
    var capabilityDisplayLabel: String?
    var validatedAssessmentID: String
    var validationTestPlanSHA256: String
    var unifiedDiffSHA256: String
    var changedRelativePaths: [String]
    var createdRelativePaths: [String]
    var candidatePatchPostimages: [GeneratedTestCandidatePostimage]
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID

    var digest: String {
        var fields: [(String, String)] = [
            ("workspace_id", workspaceID.uuidString.lowercased()),
            ("generated_test_planning_task_id", generatedTestPlanningTaskID.uuidString.lowercased()),
            ("source_candidate_patch_task_id", sourceCandidatePatchTaskID.uuidString.lowercased()),
            ("patch_id", patchID.rawValue),
            ("candidate_patch_plan_id", candidatePatchPlanID.uuidString.lowercased()),
            ("candidate_patch_plan_revision", String(candidatePatchPlanRevision)),
            ("candidate_patch_manifest_id", candidatePatchManifestID),
            ("candidate_patch_artifact_sha256", candidatePatchArtifactSHA256),
            ("candidate_patch_approval_provenance_sha256", candidatePatchApprovalProvenanceSHA256),
            ("sandbox_id", sandboxID.rawValue),
            ("source_snapshot_id", sourceSnapshotID),
            ("canonical_legacy_root", canonicalLegacyRoot),
            ("normalized_capability_id", normalizedCapabilityID),
            ("capability_display_label", capabilityDisplayLabel ?? normalizedCapabilityID),
            ("validated_assessment_id", validatedAssessmentID),
            ("validation_test_plan_sha256", validationTestPlanSHA256),
            ("unified_diff_sha256", unifiedDiffSHA256),
            ("authenticated_local_session_id", authenticatedLocalSessionID.uuidString.lowercased()),
            ("app_session_id", appSessionID.uuidString.lowercased())
        ]
        for (index, path) in changedRelativePaths.sorted().enumerated() {
            fields.append(("changed_path_\(index)", path))
        }
        for (index, path) in createdRelativePaths.sorted().enumerated() {
            fields.append(("created_path_\(index)", path))
        }
        for (index, postimage) in candidatePatchPostimages.sorted(by: { $0.relativePath < $1.relativePath }).enumerated() {
            fields.append(("postimage_\(index)_path", postimage.relativePath))
            fields.append(("postimage_\(index)_sha256", postimage.sha256))
        }
        return CandidatePatchArtifactAuthority.digest(fields)
    }
}

struct GeneratedTestPlanningContext: Hashable, Sendable {
    var sourceBinding: CandidatePatchGeneratedTestSourceBinding
    var appSessionID: UUID

    var sourceCandidatePatchTaskID: UUID { sourceBinding.sourceCandidatePatchTaskID }
    var patchID: CandidatePatchID { sourceBinding.patchID }
    var sandboxID: SandboxID { sourceBinding.sandboxID }
    var authenticatedLocalSessionID: UUID { sourceBinding.authenticatedLocalSessionID }
}

struct GeneratedTestEvidence: Codable, Hashable, Sendable, Identifiable {
    var evidenceID: String
    var kind: GeneratedTestEvidenceKind
    var relativePath: String
    var sha256: String
    var safeFact: String

    var id: String { evidenceID }
}

struct GeneratedTestFrameworkIdentity: Codable, Hashable, Sendable {
    var frameworkID: String
    var displayName: String
    var language: String
}

struct GeneratedTestEnvironmentResolution: Codable, Hashable, Sendable {
    var frameworkStatus: GeneratedTestEnvironmentResolutionStatus
    var locationStatus: GeneratedTestEnvironmentResolutionStatus
    var framework: GeneratedTestFrameworkIdentity?
    var testLocation: String?
    var evidence: [GeneratedTestEvidence]
    var remainingUnknowns: [String]
    var clarificationQuestions: [String]

    var isConfirmed: Bool {
        frameworkStatus == .frameworkConfirmed
            && locationStatus == .testLocationConfirmed
            && framework != nil
            && testLocation != nil
    }
}

struct GeneratedTestDiffHunk: Codable, Hashable, Sendable, Identifiable {
    var hunkID: String
    var relativePath: String
    var header: String
    var addedLines: [String]
    var removedLines: [String]

    var id: String { hunkID }
}

struct GeneratedTestAffectedSymbol: Codable, Hashable, Sendable, Identifiable {
    var symbolID: String
    var name: String
    var relativePath: String
    var declarationKind: String

    var id: String { symbolID }
}

struct GeneratedTestScenario: Codable, Hashable, Sendable, Identifiable {
    var scenarioID: String
    var title: String
    var behaviorUnderTest: String
    var sourceDiffHunkIDs: [String]
    var affectedSymbolReferences: [String]
    var validationPlanItemIDs: [String]
    var relatedAssessmentBlockerIDs: [String]
    var evidenceClaimIDs: [String]
    var expectedTestLevel: CandidatePatchSuggestedTestLevel
    var proposedTestRelativePath: String
    var remainingUnknowns: [String]

    var id: String { scenarioID }
}

struct GeneratedTestPlan: Codable, Hashable, Sendable, Identifiable {
    var planID: UUID
    var revision: Int
    var status: GeneratedTestLifecycleStatus
    var sourceBinding: GeneratedTestSourceBinding
    var expectedFramework: GeneratedTestFrameworkIdentity?
    var frameworkEvidence: [GeneratedTestEvidence]
    var testLocationEvidence: [GeneratedTestEvidence]
    var confirmedTestLocation: String?
    var proposedRelativeTestPaths: [String]
    var proposedScenarios: [GeneratedTestScenario]
    var diffHunks: [GeneratedTestDiffHunk]
    var affectedSymbols: [GeneratedTestAffectedSymbol]
    var relatedValidationPlanItemIDs: [String]
    var relatedAssessmentBlockerIDs: [String]
    var relatedEvidenceClaimIDs: [String]
    var prohibitedOperations: [String]
    var remainingUnknowns: [String]
    var clarificationQuestions: [String]
    var planSHA256: String
    var createdAt: Date

    var id: UUID { planID }

    var reviewReady: Bool { status == .testPlanReviewReady }

    var markdown: String {
        let framework = expectedFramework?.displayName ?? "UNKNOWN"
        let location = confirmedTestLocation ?? "UNKNOWN"
        let scenarioLines = proposedScenarios.map {
            "- \($0.title) — `\($0.proposedTestRelativePath)`; validation: \($0.validationPlanItemIDs.joined(separator: ", "))"
        }
        let questions = clarificationQuestions.map { "- \($0)" }
        var lines = [
            "# Generated Test Plan",
            "",
            "- Status: \(status.rawValue)",
            "- Bound Patch: `\(sourceBinding.patchID.rawValue)`",
            "- Candidate Patch artifact: `\(String(sourceBinding.candidatePatchArtifactSHA256.prefix(12)))…`",
            "- Safe Sandbox: `\(sourceBinding.sandboxID.rawValue)`",
            "- Source snapshot: `\(sourceBinding.sourceSnapshotID)`",
            "- Capability: `\(sourceBinding.normalizedCapabilityID)`",
            "- Assessment: `\(sourceBinding.validatedAssessmentID)`",
            "- Validation-plan items: \(relatedValidationPlanItemIDs.count)",
            "- Framework: \(framework)",
            "- Test location: \(location)",
            "",
            "## Proposed scenarios"
        ]
        lines.append(contentsOf: scenarioLines.isEmpty
            ? ["- None until framework and test location are grounded."]
            : scenarioLines)
        lines.append(contentsOf: [
            "",
            "## Clarification"
        ])
        lines.append(contentsOf: questions.isEmpty ? ["- None."] : questions)
        lines.append(contentsOf: [
            "",
            "No test files were created.",
            "Test syntax was not verified.",
            "Build was not executed.",
            "Tests were not executed.",
            "Behavioral correctness was not verified.",
            "Phase 2D.3 remains unavailable."
        ])
        return lines.joined(separator: "\n")
    }
}

enum GeneratedTestPlanningOutcome: String, Codable, Hashable, Sendable {
    case testPlanReviewReady = "TEST_PLAN_REVIEW_READY"
    case clarificationRequired = "CLARIFICATION_REQUIRED"
}

struct GeneratedTestPlanningResult: Codable, Hashable, Sendable {
    var outcome: GeneratedTestPlanningOutcome
    var plan: GeneratedTestPlan
}

enum GeneratedTestFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case explicitSourceBindingRequired = "generated_test_explicit_source_binding_required"
    case sourceBindingMismatch = "generated_test_source_binding_mismatch"
    case validationTestPlanMissing = "validation_test_plan_missing"
    case validationTestPlanMismatch = "validation_test_plan_mismatch"
    case candidatePatchArtifactDigestMissing = "candidate_patch_artifact_digest_missing"
    case candidatePatchArtifactDigestMismatch = "candidate_patch_artifact_digest_mismatch"
    case candidatePatchDiffMismatch = "candidate_patch_diff_mismatch"
    case candidatePatchPostimageMismatch = "candidate_patch_postimage_mismatch"
    case sandboxReadRejected = "generated_test_sandbox_read_rejected"
    case frameworkUnknown = "generated_test_framework_unknown"
    case frameworkConflict = "generated_test_framework_conflict"
    case testLocationUnknown = "generated_test_location_unknown"
    case testLocationConflict = "generated_test_location_conflict"
    case ungroundedScenario = "generated_test_scenario_ungrounded"
    case writeOperationUnavailable = "generated_test_write_operation_unavailable"
    case phase2D3Unavailable = "phase_2d_3_unavailable"
    case planPersistenceInvalid = "generated_test_plan_persistence_invalid"
    case exactPlanBindingRequired = "generated_test_exact_plan_binding_required"
    case generatedTestPlanMismatch = "generated_test_plan_mismatch"
    case generatedTestPlanDigestMismatch = "generated_test_plan_digest_mismatch"
    case generatedTestPlanNotReviewReady = "generated_test_plan_not_review_ready"
    case virtualFilePathInvalid = "generated_test_virtual_file_path_invalid"
    case unsupportedImport = "generated_test_unsupported_import"
    case ungroundedHelperOrAPI = "generated_test_ungrounded_helper_or_api"
    case generationEvidenceMissing = "generated_test_generation_evidence_missing"
    case artifactDigestMismatch = "generated_test_artifact_digest_mismatch"
    case artifactPersistenceInvalid = "generated_test_artifact_persistence_invalid"
    case artifactReviewBindingMismatch = "generated_test_artifact_review_binding_mismatch"
    case artifactReviewStateInvalid = "generated_test_artifact_review_state_invalid"
    case artifactApprovalConfirmationRequired = "generated_test_artifact_approval_confirmation_required"
    case artifactApprovalConfirmationInvalid = "generated_test_artifact_approval_confirmation_invalid"
}

enum GeneratedTestError: Error, Equatable, Sendable {
    case blocked(GeneratedTestFailureCode)

    var code: GeneratedTestFailureCode {
        switch self { case .blocked(let code): code }
    }
}

extension GeneratedTestError: LocalizedError {
    var errorDescription: String? {
        switch code {
        case .artifactReviewStateInvalid:
            return "This exact Generated Test Artifact revision is no longer awaiting review. Its persisted review decision was preserved."
        case .artifactReviewBindingMismatch:
            return "This Generated Test Artifact review action is stale or does not match the exact persisted revision and review session."
        case .artifactApprovalConfirmationInvalid:
            return "The Generated Test Artifact approval confirmation is stale or does not match the exact persisted review action."
        case .generatedTestPlanMismatch:
            return "The selected Generated Test Plan no longer matches its exact persisted Plan, Candidate Patch, workspace, or session authority."
        default:
            return code.rawValue
        }
    }
}
