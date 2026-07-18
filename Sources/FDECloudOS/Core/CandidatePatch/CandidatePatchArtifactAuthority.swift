import CryptoKit
import Foundation

enum CandidatePatchArtifactAuthority {
    static func artifactSHA256(for manifest: CandidatePatchManifest) throws -> String {
        guard let binding = manifest.appliedBinding,
              let approval = manifest.plan.approvalRecord,
              approval.decision == .approve,
              let provenance = approval.provenance,
              let unifiedDiff = manifest.unifiedDiff else {
            throw CandidatePatchError.blocked(.candidatePatchArtifactDigestMissing)
        }

        let operations = manifest.operations.sorted {
            if $0.relativeCanonicalSandboxPath == $1.relativeCanonicalSandboxPath {
                return $0.operationID < $1.operationID
            }
            return $0.relativeCanonicalSandboxPath < $1.relativeCanonicalSandboxPath
        }
        guard operations.allSatisfy({ $0.resultingSHA256 != nil }) else {
            throw CandidatePatchError.blocked(.candidatePatchPostimageMismatch)
        }

        var fields: [(String, String)] = [
            ("workspace_id", binding.workspaceID.uuidString.lowercased()),
            ("source_candidate_patch_task_id", binding.taskID.uuidString.lowercased()),
            ("patch_id", manifest.patchID.rawValue),
            ("candidate_plan_id", manifest.plan.planID.uuidString.lowercased()),
            ("candidate_plan_revision", String(manifest.plan.revision)),
            ("manifest_format_version", String(manifest.formatVersion)),
            ("sandbox_id", manifest.sandboxID.rawValue),
            ("source_snapshot_id", manifest.sourceSnapshotID),
            ("canonical_legacy_root", manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot),
            ("normalized_requested_capability_id", manifest.plan.requestedCapabilityID),
            ("validated_assessment_id", manifest.plan.assessmentID),
            ("assessment_compatibility_decision", manifest.plan.compatibilityDecision.rawValue),
            ("approval_request_id", approval.approvalRequestID.uuidString.lowercased()),
            ("approval_provenance_sha256", approvalProvenanceSHA256(provenance)),
            ("validation_test_plan_sha256", manifest.validationTestPlanSHA256 ?? "<missing>"),
            ("unified_diff", unifiedDiff),
            ("unified_diff_sha256", sha256(Data(unifiedDiff.utf8)))
        ]

        for (index, operation) in operations.enumerated() {
            let prefix = "operation_\(index)"
            fields.append(("\(prefix)_id", operation.operationID))
            fields.append(("\(prefix)_relative_path", operation.relativeCanonicalSandboxPath))
            fields.append(("\(prefix)_type", operation.operationType.rawValue))
            fields.append(("\(prefix)_preimage_sha256", operation.expectedPreimageSHA256 ?? "<none>"))
            fields.append(("\(prefix)_postimage_sha256", operation.resultingSHA256 ?? "<none>"))
        }

        for (index, path) in changedPaths(in: manifest).enumerated() {
            fields.append(("changed_path_\(index)", path))
        }
        for (index, path) in createdPaths(in: manifest).enumerated() {
            fields.append(("created_path_\(index)", path))
        }
        return digest(fields)
    }

    static func approvalProvenanceSHA256(_ provenance: CandidatePatchApprovalProvenance) -> String {
        digest([
            ("source", provenance.source.rawValue),
            ("workspace_id", provenance.workspaceID.uuidString.lowercased()),
            ("task_id", provenance.taskID.uuidString.lowercased()),
            ("plan_id", provenance.planID.uuidString.lowercased()),
            ("plan_revision", String(provenance.planRevision)),
            ("approval_request_id", provenance.approvalRequestID.uuidString.lowercased()),
            ("assessment_id", provenance.assessmentID),
            ("source_snapshot_id", provenance.sourceSnapshotID),
            ("canonical_legacy_root", provenance.canonicalLegacyRoot),
            ("authenticated_user_session_id", provenance.authenticatedUserSessionID.uuidString.lowercased()),
            ("app_session_id", provenance.appSessionID.uuidString.lowercased()),
            ("confirmation_step_id", provenance.confirmationStepID.uuidString.lowercased())
        ])
    }

    static func validationTestPlanSHA256(_ plan: CandidatePatchValidationTestPlan) -> String {
        var fields: [(String, String)] = [
            ("assessment_id", plan.assessmentID),
            ("execution_authorized", plan.executionAuthorized ? "true" : "false")
        ]
        for (index, item) in plan.items.sorted(by: { $0.validationItemID < $1.validationItemID }).enumerated() {
            let prefix = "item_\(index)"
            fields.append(("\(prefix)_id", item.validationItemID))
            fields.append(("\(prefix)_title", item.title))
            fields.append(("\(prefix)_purpose", item.purpose))
            fields.append(("\(prefix)_expected_behavior", item.expectedBehavior))
            fields.append(("\(prefix)_test_level", item.suggestedTestLevel.rawValue))
            fields.append(("\(prefix)_runtime_status", item.runtimeVerificationStatus.rawValue))
            fields.append(("\(prefix)_required", item.required ? "true" : "false"))
            appendSorted(item.relatedRequirementIDs, name: "\(prefix)_requirement", to: &fields)
            appendSorted(item.relatedBlockerIDs, name: "\(prefix)_blocker", to: &fields)
            appendSorted(item.relatedEvidenceClaimIDs, name: "\(prefix)_evidence_claim", to: &fields)
        }
        return digest(fields)
    }

    static func unifiedDiffSHA256(_ diff: String) -> String {
        sha256(Data(diff.utf8))
    }

    static func changedPaths(in manifest: CandidatePatchManifest) -> [String] {
        manifest.operations
            .filter { $0.operationType == .replaceTextFile }
            .map(\.relativeCanonicalSandboxPath)
            .sorted()
    }

    static func createdPaths(in manifest: CandidatePatchManifest) -> [String] {
        manifest.operations
            .filter { $0.operationType == .createTextFile }
            .map(\.relativeCanonicalSandboxPath)
            .sorted()
    }

    static func digest(_ fields: [(String, String)]) -> String {
        var data = Data()
        for (name, value) in fields {
            appendLengthPrefixed(name, to: &data)
            appendLengthPrefixed(value, to: &data)
        }
        return sha256(data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendSorted(
        _ values: [String],
        name: String,
        to fields: inout [(String, String)]
    ) {
        for (index, value) in values.sorted().enumerated() {
            fields.append(("\(name)_\(index)", value))
        }
    }

    private static func appendLengthPrefixed(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        data.append(Data(String(bytes.count).utf8))
        data.append(0x3a)
        data.append(bytes)
        data.append(0x1f)
    }
}
