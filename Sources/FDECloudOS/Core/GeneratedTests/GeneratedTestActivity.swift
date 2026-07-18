import Foundation

enum GeneratedTestActivityPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case validatingExactPatchBinding = "Validating exact Candidate Patch binding"
    case verifyingCandidatePatchArtifact = "Verifying Candidate Patch artifact digest"
    case loadingStructuredValidationPlan = "Loading structured validation-test plan"
    case resolvingTestEnvironment = "Resolving grounded test framework and location"
    case clarificationRequired = "Generated Test Plan clarification required"
    case preparingReadOnlyPlan = "Preparing read-only Generated Test Plan"
    case testPlanReviewReady = "Generated Test Plan review ready"
    case generatedTestPlanningBlocked = "Generated Test planning blocked"
}

struct GeneratedTestActivitySnapshot: Codable, Hashable, Sendable {
    var generatedTestPlanID: String?
    var generatedTestPlanRevision: Int?
    var generatedTestPlanSHA256: String?
    var generatedTestSourceBindingSHA256: String?
    var planningTaskID: String?
    var sourceCandidatePatchTaskID: String?
    var patchID: String?
    var candidatePatchArtifactSHA256: String?
    var sandboxID: String?
    var sourceSnapshotID: String?
    var capabilityID: String?
    var assessmentID: String?
    var validationPlanItemCount: Int
    var framework: String?
    var testLocation: String?
    var scenarioCount: Int
    var proposedTestPaths: [String]
    var status: GeneratedTestLifecycleStatus
    var remainingUnknowns: [String]
    var workspaceID: String? = nil
    var candidatePatchPlanID: String? = nil
    var candidatePatchPlanRevision: Int? = nil
    var candidatePatchManifestID: String? = nil
    var canonicalLegacyRoot: String? = nil
    var validationTestPlanSHA256: String? = nil
    var unifiedDiffSHA256: String? = nil

    init(
        planningTaskID: String?,
        sourceCandidatePatchTaskID: String?,
        patchID: String?,
        candidatePatchArtifactSHA256: String?,
        sandboxID: String?,
        sourceSnapshotID: String?,
        capabilityID: String?,
        assessmentID: String?,
        validationPlanItemCount: Int,
        framework: String?,
        testLocation: String?,
        scenarioCount: Int,
        proposedTestPaths: [String],
        status: GeneratedTestLifecycleStatus,
        remainingUnknowns: [String],
        generatedTestPlanID: String? = nil,
        generatedTestPlanRevision: Int? = nil,
        generatedTestPlanSHA256: String? = nil,
        generatedTestSourceBindingSHA256: String? = nil,
        workspaceID: String? = nil,
        candidatePatchPlanID: String? = nil,
        candidatePatchPlanRevision: Int? = nil,
        candidatePatchManifestID: String? = nil,
        canonicalLegacyRoot: String? = nil,
        validationTestPlanSHA256: String? = nil,
        unifiedDiffSHA256: String? = nil
    ) {
        self.generatedTestPlanID = generatedTestPlanID
        self.generatedTestPlanRevision = generatedTestPlanRevision
        self.generatedTestPlanSHA256 = generatedTestPlanSHA256
        self.generatedTestSourceBindingSHA256 = generatedTestSourceBindingSHA256
        self.planningTaskID = planningTaskID
        self.sourceCandidatePatchTaskID = sourceCandidatePatchTaskID
        self.patchID = patchID
        self.candidatePatchArtifactSHA256 = candidatePatchArtifactSHA256
        self.sandboxID = sandboxID
        self.sourceSnapshotID = sourceSnapshotID
        self.capabilityID = capabilityID
        self.assessmentID = assessmentID
        self.validationPlanItemCount = validationPlanItemCount
        self.framework = framework
        self.testLocation = testLocation
        self.scenarioCount = scenarioCount
        self.proposedTestPaths = proposedTestPaths
        self.status = status
        self.remainingUnknowns = remainingUnknowns
        self.workspaceID = workspaceID
        self.candidatePatchPlanID = candidatePatchPlanID
        self.candidatePatchPlanRevision = candidatePatchPlanRevision
        self.candidatePatchManifestID = candidatePatchManifestID
        self.canonicalLegacyRoot = canonicalLegacyRoot
        self.validationTestPlanSHA256 = validationTestPlanSHA256
        self.unifiedDiffSHA256 = unifiedDiffSHA256
    }

    static let empty = GeneratedTestActivitySnapshot(
        planningTaskID: nil,
        sourceCandidatePatchTaskID: nil,
        patchID: nil,
        candidatePatchArtifactSHA256: nil,
        sandboxID: nil,
        sourceSnapshotID: nil,
        capabilityID: nil,
        assessmentID: nil,
        validationPlanItemCount: 0,
        framework: nil,
        testLocation: nil,
        scenarioCount: 0,
        proposedTestPaths: [],
        status: .patchReady,
        remainingUnknowns: []
    )

    init(plan: GeneratedTestPlan) {
        generatedTestPlanID = plan.planID.uuidString.lowercased()
        generatedTestPlanRevision = plan.revision
        generatedTestPlanSHA256 = plan.planSHA256
        generatedTestSourceBindingSHA256 = plan.sourceBinding.digest
        planningTaskID = plan.sourceBinding.generatedTestPlanningTaskID.uuidString
        sourceCandidatePatchTaskID = plan.sourceBinding.sourceCandidatePatchTaskID.uuidString
        patchID = plan.sourceBinding.patchID.rawValue
        candidatePatchArtifactSHA256 = plan.sourceBinding.candidatePatchArtifactSHA256
        sandboxID = plan.sourceBinding.sandboxID.rawValue
        sourceSnapshotID = plan.sourceBinding.sourceSnapshotID
        capabilityID = plan.sourceBinding.normalizedCapabilityID
        assessmentID = plan.sourceBinding.validatedAssessmentID
        workspaceID = plan.sourceBinding.workspaceID.uuidString.lowercased()
        candidatePatchPlanID = plan.sourceBinding.candidatePatchPlanID.uuidString.lowercased()
        candidatePatchPlanRevision = plan.sourceBinding.candidatePatchPlanRevision
        candidatePatchManifestID = plan.sourceBinding.candidatePatchManifestID
        canonicalLegacyRoot = plan.sourceBinding.canonicalLegacyRoot
        validationTestPlanSHA256 = plan.sourceBinding.validationTestPlanSHA256
        unifiedDiffSHA256 = plan.sourceBinding.unifiedDiffSHA256
        validationPlanItemCount = plan.relatedValidationPlanItemIDs.count
        framework = plan.expectedFramework?.displayName
        testLocation = plan.confirmedTestLocation
        scenarioCount = plan.proposedScenarios.count
        proposedTestPaths = plan.proposedRelativeTestPaths
        status = plan.status
        remainingUnknowns = plan.remainingUnknowns
    }

    var eventPayload: [String: String] {
        [
            "generated_test_plan_id": generatedTestPlanID ?? "",
            "generated_test_plan_revision": generatedTestPlanRevision.map(String.init) ?? "",
            "generated_test_plan_sha256": generatedTestPlanSHA256 ?? "",
            "generated_test_source_binding_sha256": generatedTestSourceBindingSHA256 ?? "",
            "generated_test_planning_task_id": planningTaskID ?? "",
            "generated_test_source_candidate_patch_task_id": sourceCandidatePatchTaskID ?? "",
            "generated_test_patch_id": patchID ?? "",
            "generated_test_candidate_patch_artifact_sha256": candidatePatchArtifactSHA256 ?? "",
            "generated_test_sandbox_id": sandboxID ?? "",
            "generated_test_source_snapshot_id": sourceSnapshotID ?? "",
            "generated_test_capability_id": capabilityID ?? "",
            "generated_test_assessment_id": assessmentID ?? "",
            "generated_test_workspace_id": workspaceID ?? "",
            "generated_test_candidate_patch_plan_id": candidatePatchPlanID ?? "",
            "generated_test_candidate_patch_plan_revision": candidatePatchPlanRevision.map(String.init) ?? "",
            "generated_test_candidate_patch_manifest_id": candidatePatchManifestID ?? "",
            "generated_test_canonical_legacy_root": canonicalLegacyRoot ?? "",
            "generated_test_validation_test_plan_sha256": validationTestPlanSHA256 ?? "",
            "generated_test_unified_diff_sha256": unifiedDiffSHA256 ?? "",
            "generated_test_validation_plan_item_count": String(validationPlanItemCount),
            "generated_test_framework": framework ?? "UNKNOWN",
            "generated_test_location": testLocation ?? "UNKNOWN",
            "generated_test_scenario_count": String(scenarioCount),
            "generated_test_proposed_paths": proposedTestPaths.joined(separator: " | "),
            "generated_test_lifecycle_status": status.rawValue,
            "generated_test_remaining_unknowns": remainingUnknowns.joined(separator: " | ")
        ]
    }

    init?(eventPayload: [String: String]) {
        guard let rawStatus = eventPayload["generated_test_lifecycle_status"],
              let status = GeneratedTestLifecycleStatus(rawValue: rawStatus) else {
            return nil
        }
        self.status = status
        generatedTestPlanID = eventPayload["generated_test_plan_id"]?.nonEmpty
        generatedTestPlanRevision = eventPayload["generated_test_plan_revision"].flatMap(Int.init)
        generatedTestPlanSHA256 = eventPayload["generated_test_plan_sha256"]?.nonEmpty
        generatedTestSourceBindingSHA256 = eventPayload["generated_test_source_binding_sha256"]?.nonEmpty
        planningTaskID = eventPayload["generated_test_planning_task_id"]?.nonEmpty
        sourceCandidatePatchTaskID = eventPayload["generated_test_source_candidate_patch_task_id"]?.nonEmpty
        patchID = eventPayload["generated_test_patch_id"]?.nonEmpty
        candidatePatchArtifactSHA256 = eventPayload["generated_test_candidate_patch_artifact_sha256"]?.nonEmpty
        sandboxID = eventPayload["generated_test_sandbox_id"]?.nonEmpty
        sourceSnapshotID = eventPayload["generated_test_source_snapshot_id"]?.nonEmpty
        capabilityID = eventPayload["generated_test_capability_id"]?.nonEmpty
        assessmentID = eventPayload["generated_test_assessment_id"]?.nonEmpty
        workspaceID = eventPayload["generated_test_workspace_id"]?.nonEmpty
        candidatePatchPlanID = eventPayload["generated_test_candidate_patch_plan_id"]?.nonEmpty
        candidatePatchPlanRevision = eventPayload["generated_test_candidate_patch_plan_revision"].flatMap(Int.init)
        candidatePatchManifestID = eventPayload["generated_test_candidate_patch_manifest_id"]?.nonEmpty
        canonicalLegacyRoot = eventPayload["generated_test_canonical_legacy_root"]?.nonEmpty
        validationTestPlanSHA256 = eventPayload["generated_test_validation_test_plan_sha256"]?.nonEmpty
        unifiedDiffSHA256 = eventPayload["generated_test_unified_diff_sha256"]?.nonEmpty
        validationPlanItemCount = eventPayload["generated_test_validation_plan_item_count"].flatMap(Int.init) ?? 0
        framework = eventPayload["generated_test_framework"].flatMap { $0 == "UNKNOWN" ? nil : $0 }
        testLocation = eventPayload["generated_test_location"].flatMap { $0 == "UNKNOWN" ? nil : $0 }
        scenarioCount = eventPayload["generated_test_scenario_count"].flatMap(Int.init) ?? 0
        proposedTestPaths = eventPayload["generated_test_proposed_paths"]?
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
        remainingUnknowns = eventPayload["generated_test_remaining_unknowns"]?
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []
    }
}

struct GeneratedTestPlanGenerationEligibility: Equatable, Sendable {
    var isAvailable: Bool
    var unavailableReason: String?

    static let available = GeneratedTestPlanGenerationEligibility(
        isAvailable: true,
        unavailableReason: nil
    )

    static func unavailable(_ reason: String) -> GeneratedTestPlanGenerationEligibility {
        GeneratedTestPlanGenerationEligibility(isAvailable: false, unavailableReason: reason)
    }
}

extension GeneratedTestActivitySnapshot {
    var exactPlanProjectionKey: String? {
        guard let planID = generatedTestPlanID.flatMap(UUID.init(uuidString:)),
              let revision = generatedTestPlanRevision,
              revision > 0,
              let digest = generatedTestPlanSHA256,
              digest.count == 64 else {
            return nil
        }
        return "generated-test-plan:\(planID.uuidString.lowercased()):\(revision):\(digest.lowercased())"
    }

    var stableProjectionKey: String {
        exactPlanProjectionKey
            ?? planningTaskID.flatMap(UUID.init(uuidString:)).map {
                "generated-test-planning-task:\($0.uuidString.lowercased())"
            }
            ?? [sourceCandidatePatchTaskID, patchID]
                .compactMap { $0 }
                .joined(separator: ":")
    }

    func generationEligibility(
        persistedPlan: GeneratedTestPlan?,
        workspaceID: UUID,
        authenticatedLocalSessionID: UUID,
        appSessionID: UUID,
        hasExistingArtifact: Bool,
        isInFlight: Bool
    ) -> GeneratedTestPlanGenerationEligibility {
        guard status == .testPlanReviewReady else {
            return .unavailable("This Generated Test Plan is not ready for Artifact generation.")
        }
        guard let persistedPlan,
              exactGenerationContext(
                for: persistedPlan,
                workspaceID: workspaceID,
                authenticatedLocalSessionID: authenticatedLocalSessionID,
                appSessionID: appSessionID
              ) != nil else {
            if let persistedPlan,
               persistedPlan.sourceBinding.appSessionID != appSessionID {
                return .unavailable("This historical Generated Test Plan belongs to a previous app session and is read-only.")
            }
            return .unavailable("The exact persisted authority for this Generated Test Plan is unavailable or stale.")
        }
        guard !hasExistingArtifact else {
            return .unavailable("This exact Generated Test Plan already has an auditable Generated Test Artifact.")
        }
        guard !isInFlight else {
            return .unavailable("Artifact generation for this exact Generated Test Plan is already in progress.")
        }
        return .available
    }

    func exactGenerationContext(
        for plan: GeneratedTestPlan,
        workspaceID: UUID,
        authenticatedLocalSessionID: UUID,
        appSessionID: UUID
    ) -> GeneratedTestArtifactGenerationContext? {
        guard let planningTaskID = planningTaskID.flatMap(UUID.init(uuidString:)),
              let planID = generatedTestPlanID.flatMap(UUID.init(uuidString:)),
              let planRevision = generatedTestPlanRevision,
              let planSHA256 = generatedTestPlanSHA256,
              let sourceBindingSHA256 = generatedTestSourceBindingSHA256,
              let sourceCandidatePatchTaskID = sourceCandidatePatchTaskID.flatMap(UUID.init(uuidString:)),
              let candidatePatchID = patchID.flatMap(CandidatePatchID.init(rawValue:)),
              let sandboxID = sandboxID.flatMap(SandboxID.init(rawValue:)),
              plan.sourceBinding.workspaceID == workspaceID,
              plan.sourceBinding.generatedTestPlanningTaskID == planningTaskID,
              plan.planID == planID,
              plan.revision == planRevision,
              plan.planSHA256 == planSHA256,
              GeneratedTestPlanDigest.compute(plan) == planSHA256,
              plan.sourceBinding.digest == sourceBindingSHA256,
              plan.sourceBinding.sourceCandidatePatchTaskID == sourceCandidatePatchTaskID,
              plan.sourceBinding.patchID == candidatePatchID,
              plan.sourceBinding.candidatePatchArtifactSHA256 == candidatePatchArtifactSHA256,
              plan.sourceBinding.sandboxID == sandboxID,
              plan.sourceBinding.sourceSnapshotID == sourceSnapshotID,
              plan.sourceBinding.authenticatedLocalSessionID == authenticatedLocalSessionID,
              plan.sourceBinding.appSessionID == appSessionID else {
            return nil
        }
        return GeneratedTestArtifactGenerationContext(
            workspaceID: workspaceID,
            generatedTestPlanningTaskID: planningTaskID,
            generatedTestPlanID: planID,
            generatedTestPlanRevision: planRevision,
            generatedTestPlanSHA256: planSHA256,
            generatedTestSourceBindingSHA256: sourceBindingSHA256,
            sourceCandidatePatchTaskID: sourceCandidatePatchTaskID,
            candidatePatchID: candidatePatchID,
            candidatePatchPlanID: plan.sourceBinding.candidatePatchPlanID,
            candidatePatchPlanRevision: plan.sourceBinding.candidatePatchPlanRevision,
            candidatePatchArtifactSHA256: plan.sourceBinding.candidatePatchArtifactSHA256,
            sandboxID: sandboxID,
            sourceSnapshotID: plan.sourceBinding.sourceSnapshotID,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            appSessionID: appSessionID
        )
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
