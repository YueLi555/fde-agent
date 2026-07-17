import Foundation

enum CandidatePatchActivityPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case understandingRequestedChange = "Understanding requested change"
    case loadingGroundedAssessment = "Loading grounded assessment"
    case validatingPlanningPreconditions = "Validating planning preconditions"
    case preparingCandidatePatchPlan = "Preparing Candidate Patch plan"
    case waitingForHumanApproval = "Waiting for human approval"
    case checkingSandboxReadiness = "Creating or validating Safe Sandbox"
    case verifyingApprovedScope = "Verifying approved scope"
    case applyingChangeInIsolatedSandbox = "Applying change in isolated Sandbox"
    case verifyingFileHashes = "Verifying file hashes"
    case buildingUnifiedDiff = "Building unified diff"
    case confirmingOriginalLegacyUnchanged = "Confirming original Legacy unchanged"
    case preparingHumanReview = "Preparing human review"
    case candidatePatchReady = "Candidate Patch ready"
    case candidatePatchBlocked = "Candidate Patch blocked"
    case locatingAppliedPatch = "Locating exact applied Candidate Patch"
    case validatingRevertBinding = "Validating Patch Sandbox and manifest binding"
    case verifyingCurrentPostimages = "Verifying current Sandbox postimages"
    case revertConfirmationRequired = "Candidate Patch Revert confirmation required"
    case revertingCandidatePatch = "Reverting Candidate Patch"
    case verifyingRestoredHashes = "Verifying restored hashes"
    case candidatePatchReverted = "Candidate Patch reverted"
    case sandboxDestructionConfirmationRequired = "Sandbox destruction confirmation required"
    case sandboxDestroyed = "Sandbox destroyed"

    static let generationPhases: [CandidatePatchActivityPhase] = [
        .understandingRequestedChange,
        .loadingGroundedAssessment,
        .validatingPlanningPreconditions,
        .preparingCandidatePatchPlan,
        .waitingForHumanApproval,
        .checkingSandboxReadiness,
        .verifyingApprovedScope,
        .applyingChangeInIsolatedSandbox,
        .verifyingFileHashes,
        .buildingUnifiedDiff,
        .confirmingOriginalLegacyUnchanged,
        .preparingHumanReview,
        .candidatePatchReady,
        .candidatePatchBlocked
    ]

    static let revertPhases: [CandidatePatchActivityPhase] = [
        .locatingAppliedPatch,
        .validatingRevertBinding,
        .verifyingCurrentPostimages,
        .confirmingOriginalLegacyUnchanged,
        .revertConfirmationRequired,
        .revertingCandidatePatch,
        .verifyingRestoredHashes,
        .candidatePatchReverted,
        .candidatePatchBlocked
    ]
}

struct CandidatePatchActivitySnapshot: Codable, Hashable, Sendable {
    var patchID: String?
    var sandboxID: String?
    var status: CandidatePatchStatus?
    var filesPlanned: Int
    var filesChanged: Int
    var additions: Int
    var deletions: Int
    var risk: CandidatePatchRisk?
    var evidenceCount: Int
    var sourceIntegrity: SourceIntegrityState?
    var approvalState: CandidatePatchApprovalDecision?
    var projectionState: CandidatePatchProjectionState?

    static let empty = CandidatePatchActivitySnapshot(
        patchID: nil,
        sandboxID: nil,
        status: nil,
        filesPlanned: 0,
        filesChanged: 0,
        additions: 0,
        deletions: 0,
        risk: nil,
        evidenceCount: 0,
        sourceIntegrity: nil,
        approvalState: nil,
        projectionState: nil
    )

    init(manifest: CandidatePatchManifest) {
        patchID = manifest.patchID.rawValue
        sandboxID = manifest.sandboxID.rawValue
        status = manifest.status
        filesPlanned = manifest.plan.operations.count
        filesChanged = manifest.operations.filter { $0.resultingSHA256 != nil }.count
        additions = manifest.additions
        deletions = manifest.deletions
        risk = manifest.plan.risk
        evidenceCount = manifest.plan.supportingEvidence.count
        sourceIntegrity = manifest.sourceIntegrity
        approvalState = manifest.plan.approvalRecord?.decision
        if manifest.sandboxDestroyedAt != nil {
            projectionState = .sandboxDestroyed
        } else if manifest.status == .reverted {
            projectionState = .reverted
        } else if manifest.status == .reviewReady || manifest.status == .applied {
            projectionState = .patchReady
        } else {
            projectionState = nil
        }
    }

    init(plan: CandidatePatchPlan) {
        patchID = plan.patchID.rawValue
        sandboxID = nil
        status = plan.status
        filesPlanned = plan.operations.count
        filesChanged = 0
        additions = 0
        deletions = 0
        risk = plan.risk
        evidenceCount = plan.supportingEvidence.count
        sourceIntegrity = .unchanged
        approvalState = plan.approvalRecord?.decision
        projectionState = plan.status == .reviewReady || plan.status == .applied ? .patchReady : nil
    }

    init(
        patchID: String?,
        sandboxID: String?,
        status: CandidatePatchStatus?,
        filesPlanned: Int,
        filesChanged: Int,
        additions: Int,
        deletions: Int,
        risk: CandidatePatchRisk?,
        evidenceCount: Int,
        sourceIntegrity: SourceIntegrityState?,
        approvalState: CandidatePatchApprovalDecision?,
        projectionState: CandidatePatchProjectionState? = nil
    ) {
        self.patchID = patchID
        self.sandboxID = sandboxID
        self.status = status
        self.filesPlanned = filesPlanned
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
        self.risk = risk
        self.evidenceCount = evidenceCount
        self.sourceIntegrity = sourceIntegrity
        self.approvalState = approvalState
        self.projectionState = projectionState
    }

    var eventPayload: [String: String] {
        [
            "candidate_patch_id": patchID ?? "",
            "candidate_patch_sandbox_id": sandboxID ?? "",
            "candidate_patch_status": status?.rawValue ?? "",
            "candidate_patch_files_planned": String(filesPlanned),
            "candidate_patch_files_changed": String(filesChanged),
            "candidate_patch_additions": String(additions),
            "candidate_patch_deletions": String(deletions),
            "candidate_patch_risk": risk?.rawValue ?? "",
            "candidate_patch_evidence_count": String(evidenceCount),
            "candidate_patch_source_integrity": sourceIntegrity?.rawValue ?? "",
            "candidate_patch_approval_state": approvalState?.rawValue ?? "",
            "candidate_patch_projection_state": projectionState?.rawValue ?? ""
        ]
    }

    init?(eventPayload: [String: String]) {
        let patchID = eventPayload["candidate_patch_id"]?.nilIfEmpty
        let sandboxID = eventPayload["candidate_patch_sandbox_id"]?.nilIfEmpty
        guard patchID != nil || sandboxID != nil else { return nil }
        self.patchID = patchID
        self.sandboxID = sandboxID
        status = eventPayload["candidate_patch_status"].flatMap(CandidatePatchStatus.init(rawValue:))
        filesPlanned = eventPayload["candidate_patch_files_planned"].flatMap(Int.init) ?? 0
        filesChanged = eventPayload["candidate_patch_files_changed"].flatMap(Int.init) ?? 0
        additions = eventPayload["candidate_patch_additions"].flatMap(Int.init) ?? 0
        deletions = eventPayload["candidate_patch_deletions"].flatMap(Int.init) ?? 0
        risk = eventPayload["candidate_patch_risk"].flatMap(CandidatePatchRisk.init(rawValue:))
        evidenceCount = eventPayload["candidate_patch_evidence_count"].flatMap(Int.init) ?? 0
        sourceIntegrity = eventPayload["candidate_patch_source_integrity"].flatMap(SourceIntegrityState.init(rawValue:))
        approvalState = eventPayload["candidate_patch_approval_state"].flatMap(CandidatePatchApprovalDecision.init(rawValue:))
        projectionState = eventPayload["candidate_patch_projection_state"].flatMap(CandidatePatchProjectionState.init(rawValue:))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
