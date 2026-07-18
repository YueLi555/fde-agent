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
        remainingUnknowns: [String]
    ) {
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
        planningTaskID = plan.sourceBinding.generatedTestPlanningTaskID.uuidString
        sourceCandidatePatchTaskID = plan.sourceBinding.sourceCandidatePatchTaskID.uuidString
        patchID = plan.sourceBinding.patchID.rawValue
        candidatePatchArtifactSHA256 = plan.sourceBinding.candidatePatchArtifactSHA256
        sandboxID = plan.sourceBinding.sandboxID.rawValue
        sourceSnapshotID = plan.sourceBinding.sourceSnapshotID
        capabilityID = plan.sourceBinding.normalizedCapabilityID
        assessmentID = plan.sourceBinding.validatedAssessmentID
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
            "generated_test_planning_task_id": planningTaskID ?? "",
            "generated_test_source_candidate_patch_task_id": sourceCandidatePatchTaskID ?? "",
            "generated_test_patch_id": patchID ?? "",
            "generated_test_candidate_patch_artifact_sha256": candidatePatchArtifactSHA256 ?? "",
            "generated_test_sandbox_id": sandboxID ?? "",
            "generated_test_source_snapshot_id": sourceSnapshotID ?? "",
            "generated_test_capability_id": capabilityID ?? "",
            "generated_test_assessment_id": assessmentID ?? "",
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
        planningTaskID = eventPayload["generated_test_planning_task_id"]?.nonEmpty
        sourceCandidatePatchTaskID = eventPayload["generated_test_source_candidate_patch_task_id"]?.nonEmpty
        patchID = eventPayload["generated_test_patch_id"]?.nonEmpty
        candidatePatchArtifactSHA256 = eventPayload["generated_test_candidate_patch_artifact_sha256"]?.nonEmpty
        sandboxID = eventPayload["generated_test_sandbox_id"]?.nonEmpty
        sourceSnapshotID = eventPayload["generated_test_source_snapshot_id"]?.nonEmpty
        capabilityID = eventPayload["generated_test_capability_id"]?.nonEmpty
        assessmentID = eventPayload["generated_test_assessment_id"]?.nonEmpty
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

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
