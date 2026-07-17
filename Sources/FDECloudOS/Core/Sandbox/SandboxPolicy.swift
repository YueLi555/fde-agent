import Foundation

enum SandboxMissionAuthorization: String, Codable, Hashable, Sendable {
    case conversation
    case readOnlyInspection
    case sandboxFoundation
    case futureApprovedSandboxMutation
}

enum SandboxWritableOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case candidatePatch
    case candidatePatchReadText = "candidate_patch_read_text"
    case candidatePatchCreateText = "candidate_patch_create_text"
    case candidatePatchReplaceText = "candidate_patch_replace_text"
    case candidatePatchRevert = "candidate_patch_revert"
    case generatedTest
    case productFileMutation
}

enum SandboxPolicyDenial: String, Codable, Hashable, Sendable {
    case missionNotAuthorized = "mission_not_authorized"
    case sandboxMissing = "sandbox_missing"
    case sandboxNotReady = "sandbox_not_ready"
    case sourceChanged = "source_changed"
    case targetRejected = "target_rejected"
    case operationUnavailable = "operation_unavailable"
    case humanApprovalMissing = "human_approval_missing"
}

struct SandboxWritablePolicyRequest: Hashable, Sendable {
    var mission: SandboxMissionAuthorization
    var sandboxID: SandboxID?
    var relativeTargetPath: String
    var operation: SandboxWritableOperation
    var requiresHumanApproval: Bool
    var humanApprovalSatisfied: Bool
}

struct SandboxPolicyDecision: Hashable, Sendable {
    var allowed: Bool
    var denials: [SandboxPolicyDenial]
    var resolvedTarget: URL?
}

struct SandboxRuntimePolicy: Sendable {
    let lifecycle: SandboxLifecycleService

    /// Phase 2D.0 intentionally exposes no writable product operation.
    static let phase2D0Allowlist: Set<SandboxWritableOperation> = []
    static let phase2D1Allowlist: Set<SandboxWritableOperation> = [
        .candidatePatchReadText,
        .candidatePatchCreateText,
        .candidatePatchReplaceText,
        .candidatePatchRevert
    ]

    func authorize(_ request: SandboxWritablePolicyRequest) -> SandboxPolicyDecision {
        authorize(request, allowlist: Self.phase2D0Allowlist)
    }

    func authorizePhase2D1(_ request: SandboxWritablePolicyRequest) -> SandboxPolicyDecision {
        authorize(request, allowlist: Self.phase2D1Allowlist)
    }

    private func authorize(
        _ request: SandboxWritablePolicyRequest,
        allowlist: Set<SandboxWritableOperation>
    ) -> SandboxPolicyDecision {
        var denials: [SandboxPolicyDenial] = []
        var resolvedTarget: URL?
        if request.mission != .futureApprovedSandboxMutation {
            denials.append(.missionNotAuthorized)
        }
        if !allowlist.contains(request.operation) {
            denials.append(.operationUnavailable)
        }
        if request.requiresHumanApproval && !request.humanApprovalSatisfied {
            denials.append(.humanApprovalMissing)
        }

        if let sandboxID = request.sandboxID {
            do {
                let inspection = try lifecycle.inspectSandbox(sandboxID)
                if inspection.manifest.status != .ready {
                    denials.append(.sandboxNotReady)
                }
                let sourceCheck = try lifecycle.checkSourceIntegrity(sandboxID)
                if !sourceCheck.isUnchanged {
                    denials.append(.sourceChanged)
                }
                do {
                    resolvedTarget = try SandboxPathResolver(storageRoot: lifecycle.storageRoot).resolve(
                        sandboxID: sandboxID,
                        relativePath: request.relativeTargetPath
                    )
                } catch {
                    denials.append(.targetRejected)
                }
            } catch {
                denials.append(.sandboxMissing)
            }
        } else {
            denials.append(.sandboxMissing)
        }

        let uniqueDenials = Array(Set(denials)).sorted { $0.rawValue < $1.rawValue }
        return SandboxPolicyDecision(
            allowed: uniqueDenials.isEmpty,
            denials: uniqueDenials,
            resolvedTarget: uniqueDenials.isEmpty ? resolvedTarget : nil
        )
    }
}
