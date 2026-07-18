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
    var sourceCandidatePatchTaskID: String?
    var planID: String?
    var planRevision: Int?
    var manifestID: String?
    var candidatePatchArtifactSHA256: String?
    var sandboxID: String?
    var sourceSnapshotID: String?
    var canonicalLegacyRoot: String?
    var capabilityID: String?
    var capabilityDisplayLabel: String?
    var assessmentID: String?
    var validationTestPlanSHA256: String?
    var unifiedDiffSHA256: String?
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
    var generatedTestSourceBinding: CandidatePatchGeneratedTestSourceBinding?
    var lifecycleEvents: [CandidatePatchProjectionState]? = nil

    static let empty = CandidatePatchActivitySnapshot(
        patchID: nil,
        sandboxID: nil,
        sourceCandidatePatchTaskID: nil,
        planID: nil,
        planRevision: nil,
        manifestID: nil,
        candidatePatchArtifactSHA256: nil,
        sourceSnapshotID: nil,
        canonicalLegacyRoot: nil,
        capabilityID: nil,
        capabilityDisplayLabel: nil,
        assessmentID: nil,
        validationTestPlanSHA256: nil,
        unifiedDiffSHA256: nil,
        status: nil,
        filesPlanned: 0,
        filesChanged: 0,
        additions: 0,
        deletions: 0,
        risk: nil,
        evidenceCount: 0,
        sourceIntegrity: nil,
        approvalState: nil,
        projectionState: nil,
        generatedTestSourceBinding: nil
    )

    init(manifest: CandidatePatchManifest) {
        let sourceBinding = CandidatePatchGeneratedTestSourceBinding(manifest: manifest)
        patchID = manifest.patchID.rawValue
        sourceCandidatePatchTaskID = manifest.appliedBinding?.taskID.uuidString
        planID = manifest.plan.planID.uuidString
        planRevision = manifest.plan.revision
        manifestID = manifest.stableManifestID
        candidatePatchArtifactSHA256 = manifest.candidatePatchArtifactSHA256
        sandboxID = manifest.sandboxID.rawValue
        sourceSnapshotID = manifest.sourceSnapshotID
        canonicalLegacyRoot = manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot
        capabilityID = manifest.plan.requestedCapabilityID
        capabilityDisplayLabel = manifest.plan.assessmentContext?.requestedCapabilityDisplayLabel
            ?? manifest.plan.requestedCapabilityID
        assessmentID = manifest.plan.assessmentID
        validationTestPlanSHA256 = manifest.validationTestPlanSHA256
        unifiedDiffSHA256 = manifest.unifiedDiff.map(CandidatePatchArtifactAuthority.unifiedDiffSHA256)
        status = manifest.status
        filesPlanned = manifest.plan.operations.count
        filesChanged = manifest.operations.filter { $0.resultingSHA256 != nil }.count
        additions = manifest.additions
        deletions = manifest.deletions
        risk = manifest.plan.risk
        evidenceCount = manifest.plan.supportingEvidence.count
        sourceIntegrity = manifest.sourceIntegrity
        approvalState = manifest.plan.approvalRecord?.decision
        generatedTestSourceBinding = sourceBinding
        if manifest.sandboxDestroyedAt != nil {
            projectionState = .sandboxDestroyed
        } else if manifest.status == .reverted {
            projectionState = .reverted
        } else if manifest.status == .reviewReady || manifest.status == .applied {
            projectionState = .patchReady
        } else {
            projectionState = nil
        }
        var lifecycle: [CandidatePatchProjectionState] = []
        if manifest.auditEvents.contains(where: { $0.type == .reviewPrepared })
            || manifest.status == .reviewReady
            || manifest.status == .reverted
            || manifest.sandboxDestroyedAt != nil {
            lifecycle.append(.patchReady)
        }
        if manifest.auditEvents.contains(where: { $0.type == .revertCompleted })
            || manifest.status == .reverted
            || manifest.sandboxDestroyedAt != nil {
            lifecycle.append(.reverted)
        }
        if manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed })
            || manifest.sandboxDestroyedAt != nil {
            lifecycle.append(.sandboxDestroyed)
        }
        lifecycleEvents = lifecycle
    }

    init(plan: CandidatePatchPlan) {
        patchID = plan.patchID.rawValue
        sourceCandidatePatchTaskID = nil
        planID = plan.planID.uuidString
        planRevision = plan.revision
        manifestID = nil
        candidatePatchArtifactSHA256 = nil
        sandboxID = nil
        sourceSnapshotID = plan.sourceSnapshotID
        canonicalLegacyRoot = plan.legacyIntegrityBaseline.canonicalLegacyRoot
        capabilityID = plan.requestedCapabilityID
        capabilityDisplayLabel = plan.assessmentContext?.requestedCapabilityDisplayLabel
            ?? plan.requestedCapabilityID
        assessmentID = plan.assessmentID
        validationTestPlanSHA256 = plan.validationTestPlanSHA256
        unifiedDiffSHA256 = nil
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
        generatedTestSourceBinding = nil
        lifecycleEvents = projectionState.map { [$0] }
    }

    init(
        patchID: String?,
        sandboxID: String?,
        sourceCandidatePatchTaskID: String? = nil,
        planID: String? = nil,
        planRevision: Int? = nil,
        manifestID: String? = nil,
        candidatePatchArtifactSHA256: String? = nil,
        sourceSnapshotID: String? = nil,
        canonicalLegacyRoot: String? = nil,
        capabilityID: String? = nil,
        capabilityDisplayLabel: String? = nil,
        assessmentID: String? = nil,
        validationTestPlanSHA256: String? = nil,
        unifiedDiffSHA256: String? = nil,
        status: CandidatePatchStatus?,
        filesPlanned: Int,
        filesChanged: Int,
        additions: Int,
        deletions: Int,
        risk: CandidatePatchRisk?,
        evidenceCount: Int,
        sourceIntegrity: SourceIntegrityState?,
        approvalState: CandidatePatchApprovalDecision?,
        projectionState: CandidatePatchProjectionState? = nil,
        generatedTestSourceBinding: CandidatePatchGeneratedTestSourceBinding? = nil,
        lifecycleEvents: [CandidatePatchProjectionState]? = nil
    ) {
        self.patchID = patchID
        self.sourceCandidatePatchTaskID = sourceCandidatePatchTaskID
        self.planID = planID
        self.planRevision = planRevision
        self.manifestID = manifestID
        self.candidatePatchArtifactSHA256 = candidatePatchArtifactSHA256
        self.sandboxID = sandboxID
        self.sourceSnapshotID = sourceSnapshotID
        self.canonicalLegacyRoot = canonicalLegacyRoot
        self.capabilityID = capabilityID
        self.capabilityDisplayLabel = capabilityDisplayLabel
        self.assessmentID = assessmentID
        self.validationTestPlanSHA256 = validationTestPlanSHA256
        self.unifiedDiffSHA256 = unifiedDiffSHA256
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
        self.generatedTestSourceBinding = generatedTestSourceBinding
        self.lifecycleEvents = lifecycleEvents ?? projectionState.map { [$0] }
    }

    var eventPayload: [String: String] {
        var payload: [String: String] = [
            "candidate_patch_id": patchID ?? "",
            "candidate_patch_source_task_id": sourceCandidatePatchTaskID ?? "",
            "candidate_patch_plan_id": planID ?? "",
            "candidate_patch_plan_revision": planRevision.map(String.init) ?? "",
            "candidate_patch_manifest_id": manifestID ?? "",
            "candidate_patch_artifact_sha256": candidatePatchArtifactSHA256 ?? "",
            "candidate_patch_sandbox_id": sandboxID ?? "",
            "candidate_patch_source_snapshot_id": sourceSnapshotID ?? "",
            "candidate_patch_canonical_legacy_root": canonicalLegacyRoot ?? "",
            "candidate_patch_capability_id": capabilityID ?? "",
            "candidate_patch_capability_display_label": capabilityDisplayLabel ?? "",
            "candidate_patch_assessment_id": assessmentID ?? "",
            "candidate_patch_validation_test_plan_sha256": validationTestPlanSHA256 ?? "",
            "candidate_patch_unified_diff_sha256": unifiedDiffSHA256 ?? ""
        ]
        payload["candidate_patch_status"] = status?.rawValue ?? ""
        payload["candidate_patch_files_planned"] = String(filesPlanned)
        payload["candidate_patch_files_changed"] = String(filesChanged)
        payload["candidate_patch_additions"] = String(additions)
        payload["candidate_patch_deletions"] = String(deletions)
        payload["candidate_patch_risk"] = risk?.rawValue ?? ""
        payload["candidate_patch_evidence_count"] = String(evidenceCount)
        payload["candidate_patch_source_integrity"] = sourceIntegrity?.rawValue ?? ""
        payload["candidate_patch_approval_state"] = approvalState?.rawValue ?? ""
        payload["candidate_patch_projection_state"] = projectionState?.rawValue ?? ""
        payload["candidate_patch_lifecycle_events"] = (lifecycleEvents ?? []).map(\.rawValue).joined(separator: "|")
        if let generatedTestSourceBinding,
           let data = try? Self.bindingEncoder.encode(generatedTestSourceBinding),
           let json = String(data: data, encoding: .utf8) {
            payload["candidate_patch_generated_test_source_binding"] = json
            payload["candidate_patch_generated_test_source_binding_sha256"] = generatedTestSourceBinding.digest
        }
        return payload
    }

    init?(eventPayload: [String: String]) {
        let patchID = eventPayload["candidate_patch_id"]?.nilIfEmpty
        let sandboxID = eventPayload["candidate_patch_sandbox_id"]?.nilIfEmpty
        guard patchID != nil || sandboxID != nil else { return nil }
        self.patchID = patchID
        sourceCandidatePatchTaskID = eventPayload["candidate_patch_source_task_id"]?.nilIfEmpty
            ?? eventPayload["generated_test_source_candidate_patch_task_id"]?.nilIfEmpty
        planID = eventPayload["candidate_patch_plan_id"]?.nilIfEmpty
        planRevision = eventPayload["candidate_patch_plan_revision"].flatMap(Int.init)
        manifestID = eventPayload["candidate_patch_manifest_id"]?.nilIfEmpty
        candidatePatchArtifactSHA256 = eventPayload["candidate_patch_artifact_sha256"]?.nilIfEmpty
            ?? eventPayload["generated_test_candidate_patch_artifact_sha256"]?.nilIfEmpty
        self.sandboxID = sandboxID
        sourceSnapshotID = eventPayload["candidate_patch_source_snapshot_id"]?.nilIfEmpty
            ?? eventPayload["generated_test_source_snapshot_id"]?.nilIfEmpty
        canonicalLegacyRoot = eventPayload["candidate_patch_canonical_legacy_root"]?.nilIfEmpty
        capabilityID = eventPayload["candidate_patch_capability_id"]?.nilIfEmpty
            ?? eventPayload["generated_test_capability_id"]?.nilIfEmpty
        capabilityDisplayLabel = eventPayload["candidate_patch_capability_display_label"]?.nilIfEmpty
        assessmentID = eventPayload["candidate_patch_assessment_id"]?.nilIfEmpty
            ?? eventPayload["generated_test_assessment_id"]?.nilIfEmpty
        validationTestPlanSHA256 = eventPayload["candidate_patch_validation_test_plan_sha256"]?.nilIfEmpty
        unifiedDiffSHA256 = eventPayload["candidate_patch_unified_diff_sha256"]?.nilIfEmpty
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
        generatedTestSourceBinding = Self.decodeVerifiedBinding(eventPayload)
        lifecycleEvents = eventPayload["candidate_patch_lifecycle_events"]?
            .split(separator: "|")
            .compactMap { CandidatePatchProjectionState(rawValue: String($0)) }
        if lifecycleEvents?.isEmpty != false, let projectionState {
            lifecycleEvents = [projectionState]
        }
    }

    var assetID: String {
        [
            "candidate-patch-plan",
            planID ?? "unknown-plan",
            planRevision.map(String.init) ?? "unknown-revision",
            patchID ?? "unknown-patch",
            sandboxID ?? "unknown-sandbox"
        ].joined(separator: ":")
    }

    var exactGeneratedTestSourceBinding: CandidatePatchGeneratedTestSourceBinding? {
        guard projectionState == .patchReady || status == .reviewReady,
              sourceIntegrity == .unchanged,
              approvalState == .approve,
              let binding = generatedTestSourceBinding,
              patchID == binding.patchID.rawValue,
              sourceCandidatePatchTaskID == binding.sourceCandidatePatchTaskID.uuidString,
              planID == binding.candidatePatchPlanID.uuidString,
              planRevision == binding.candidatePatchPlanRevision,
              manifestID == binding.candidatePatchManifestID,
              candidatePatchArtifactSHA256 == binding.candidatePatchArtifactSHA256,
              sandboxID == binding.sandboxID.rawValue,
              sourceSnapshotID == binding.sourceSnapshotID,
              canonicalLegacyRoot == binding.canonicalLegacyRoot,
              capabilityID == binding.normalizedCapabilityID,
              assessmentID == binding.validatedAssessmentID,
              validationTestPlanSHA256 == binding.validationTestPlanSHA256,
              unifiedDiffSHA256 == binding.unifiedDiffSHA256 else {
            return nil
        }
        return binding
    }

    var generatedTestActionUnavailableReason: String? {
        guard projectionState == .patchReady || status == .reviewReady else {
            return "Generated Test planning is available only for a PATCH_READY Candidate Patch."
        }
        guard exactGeneratedTestSourceBinding != nil else {
            return "The exact persisted Candidate Patch binding could not be restored."
        }
        return nil
    }

    func merged(with newer: CandidatePatchActivitySnapshot) -> CandidatePatchActivitySnapshot {
        CandidatePatchActivitySnapshot(
            patchID: newer.patchID ?? patchID,
            sandboxID: newer.sandboxID ?? sandboxID,
            sourceCandidatePatchTaskID: newer.sourceCandidatePatchTaskID ?? sourceCandidatePatchTaskID,
            planID: newer.planID ?? planID,
            planRevision: newer.planRevision ?? planRevision,
            manifestID: newer.manifestID ?? manifestID,
            candidatePatchArtifactSHA256: newer.candidatePatchArtifactSHA256 ?? candidatePatchArtifactSHA256,
            sourceSnapshotID: newer.sourceSnapshotID ?? sourceSnapshotID,
            canonicalLegacyRoot: newer.canonicalLegacyRoot ?? canonicalLegacyRoot,
            capabilityID: newer.capabilityID ?? capabilityID,
            capabilityDisplayLabel: newer.capabilityDisplayLabel ?? capabilityDisplayLabel,
            assessmentID: newer.assessmentID ?? assessmentID,
            validationTestPlanSHA256: newer.validationTestPlanSHA256 ?? validationTestPlanSHA256,
            unifiedDiffSHA256: newer.unifiedDiffSHA256 ?? unifiedDiffSHA256,
            status: newer.status ?? status,
            filesPlanned: max(filesPlanned, newer.filesPlanned),
            filesChanged: max(filesChanged, newer.filesChanged),
            additions: max(additions, newer.additions),
            deletions: max(deletions, newer.deletions),
            risk: newer.risk ?? risk,
            evidenceCount: max(evidenceCount, newer.evidenceCount),
            sourceIntegrity: newer.sourceIntegrity ?? sourceIntegrity,
            approvalState: newer.approvalState ?? approvalState,
            projectionState: newer.projectionState ?? projectionState,
            generatedTestSourceBinding: newer.generatedTestSourceBinding ?? generatedTestSourceBinding,
            lifecycleEvents: orderedLifecycleEvents(
                (lifecycleEvents ?? []) + (newer.lifecycleEvents ?? [])
            )
        )
    }

    private func orderedLifecycleEvents(
        _ values: [CandidatePatchProjectionState]
    ) -> [CandidatePatchProjectionState] {
        CandidatePatchProjectionState.allCases.filter(values.contains)
    }

    private static let bindingEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func decodeVerifiedBinding(
        _ eventPayload: [String: String]
    ) -> CandidatePatchGeneratedTestSourceBinding? {
        guard let json = eventPayload["candidate_patch_generated_test_source_binding"],
              let expectedDigest = eventPayload["candidate_patch_generated_test_source_binding_sha256"],
              let data = json.data(using: .utf8),
              let binding = try? JSONDecoder().decode(
                  CandidatePatchGeneratedTestSourceBinding.self,
                  from: data
              ),
              binding.digest == expectedDigest else {
            return nil
        }
        return binding
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
