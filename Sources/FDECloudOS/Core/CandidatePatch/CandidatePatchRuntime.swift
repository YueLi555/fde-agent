import Foundation

protocol CandidatePatchPlanRequestProviding: Sendable {
    func planRequest(
        for input: String,
        workspace: Workspace,
        lifecycle: SandboxLifecycleService
    ) async throws -> CandidatePatchPlanRequest
}

struct StaticCandidatePatchPlanRequestProvider: CandidatePatchPlanRequestProviding {
    var request: CandidatePatchPlanRequest

    func planRequest(
        for input: String,
        workspace: Workspace,
        lifecycle: SandboxLifecycleService
    ) async throws -> CandidatePatchPlanRequest {
        request
    }
}

struct PersistedCandidatePatchPlanRequestProvider: CandidatePatchPlanRequestProviding {
    var persistence: any PersistenceStore

    func planRequest(
        for input: String,
        workspace: Workspace,
        lifecycle: SandboxLifecycleService
    ) async throws -> CandidatePatchPlanRequest {
        guard let rootPath = workspace.localProjectRoot?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rootPath.isEmpty else {
            throw CandidatePatchError.blocked(.workspaceNotSelected)
        }
        let root = try SandboxFileSystem.canonicalExistingDirectory(
            URL(fileURLWithPath: rootPath, isDirectory: true)
        )
        let currentSnapshot = try SourceSnapshotBuilder().build(root: root)
        let explicitKind = AIAgentCapabilityKind(request: input)
        let explicitCapabilityID = explicitKind == .unspecified ? nil : explicitKind.rawValue

        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: nil)
            .filter { $0.payload["lifecycle_event"] == "AI_ASSESSMENT_PERSISTED" }
            .sorted { $0.sequence > $1.sequence }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = events.compactMap { event -> CandidatePatchAssessmentContext? in
            guard let json = event.payload["candidate_patch_assessment_context"],
                  let data = json.data(using: .utf8),
                  let context = try? decoder.decode(CandidatePatchAssessmentContext.self, from: data),
                  context.validationStatus == .validated,
                  event.payload["assessment_validation_status"] == context.validationStatus.rawValue,
                  event.payload["assessment_finalization_mode"] == context.finalizationMode.rawValue,
                  event.payload["assessment_id"] == context.assessmentID,
                  event.payload["source_snapshot_id"] == context.sourceSnapshotID,
                  event.payload["canonical_legacy_root"] == context.canonicalLegacyRoot,
                  event.payload["normalized_requested_capability_id"] == context.requestedCapabilityID,
                  event.payload["requested_capability_display_label"] == context.requestedCapabilityDisplayLabel,
                  event.payload["compatibility_decision"] == context.compatibilityDecision.rawValue,
                  event.payload["evidence_claim_ids"] == context.evidenceClaimIDs.joined(separator: " | ") else {
                return nil
            }
            return context
        }
        let currentSourceAssessments = decoded.filter {
            $0.canonicalLegacyRoot == root.path && $0.sourceSnapshotID == currentSnapshot.snapshotID
        }
        if let explicitCapabilityID,
           !currentSourceAssessments.isEmpty,
           !currentSourceAssessments.contains(where: { $0.requestedCapabilityID == explicitCapabilityID }) {
            throw CandidatePatchError.blocked(.assessmentCapabilityMismatch)
        }
        guard let assessment = currentSourceAssessments.first(where: { context in
            explicitCapabilityID == nil || context.requestedCapabilityID == explicitCapabilityID
        }) else {
            if decoded.contains(where: { $0.canonicalLegacyRoot == root.path }) {
                throw CandidatePatchError.blocked(.assessmentStale)
            }
            throw CandidatePatchError.blocked(.assessmentMissing)
        }
        guard assessment.requestedCapabilityID == AIAgentCapabilityKind.customerSupportOrderLookup.rawValue else {
            throw CandidatePatchError.blocked(.operationUnavailable)
        }

        let groundedEvidence = assessment.evidence.filter(\.isGrounded)
        guard !groundedEvidence.isEmpty else {
            throw CandidatePatchError.blocked(.assessmentEvidenceMissing)
        }
        let preferredEvidence = groundedEvidence.filter { evidence in
            evidence.evidenceReferences.contains { reference in
                let path = reference.path.lowercased()
                return path.contains("order") || path.contains("auth") || path.contains("audit")
            }
        }
        let claimIDs = Array((preferredEvidence.isEmpty ? groundedEvidence : preferredEvidence).prefix(6).map(\.claimID))
        return CandidatePatchPlanRequest(
            sandboxID: SandboxID(),
            selectedLegacyRoot: root,
            trustedLegacyRoot: root,
            agentWorkspaceRoots: [],
            assessment: assessment,
            requestedCapabilityID: assessment.requestedCapabilityID,
            requestedOutcome: "Prepare an assessment-backed read-only customer-support order lookup adapter for explicit review.",
            proposedOperations: [
                CandidatePatchProposedOperation(
                    relativePath: "src/fde-customer-support-order-lookup.ts",
                    operationType: .createTextFile,
                    proposedContent: "",
                    implementationRecipe: .customerSupportOrderLookupReadOnlyAdapter,
                    purpose: "Add a fail-closed record-authorization dependency and omit customerID from the Agent-facing response.",
                    evidenceClaimIDs: claimIDs,
                    blockersAddressed: assessment.blockers,
                    risk: assessment.compatibilityDecision == .no ? .high : .medium,
                    impact: "Creates one review-only TypeScript adapter inside the isolated Sandbox; no Legacy source write occurs before approval."
                )
            ],
            approvedScope: ["src"],
            expectedBehavior: [
                "Require a deterministic record-level authorization decision before lookup.",
                "Reuse the existing role-protected read path.",
                "Return only orderID and status to the Agent-facing boundary.",
                "Preserve authentication, permission enforcement, read auditing, and strict read-only behavior."
            ],
            validationRequiredLater: [
                "Generated Tests remain unavailable in Phase 2D.1.",
                "Build, test, and runtime verification require a separately authorized later phase."
            ],
            rollbackApproach: "Use the app-managed Candidate Patch revert operation to remove the created Sandbox file.",
            unknowns: Array(Set(assessment.blockers + assessment.unresolvedRequirements)).sorted()
        )
    }
}

struct CandidatePatchPendingRuntime: Sendable {
    var approvalRequestID: UUID
    var taskID: UUID
    var workspaceID: UUID
    var sandboxID: SandboxID
    var patchID: CandidatePatchID
}

enum CandidatePatchRuntimeError: Error, Equatable, Sendable {
    case runtimeUnavailable
    case approvalMetadataInvalid
    case approvalConfirmationRequired
    case approvalConfirmationInvalid
    case approvalSourceInvalid
    case authenticatedSessionInvalid
}
