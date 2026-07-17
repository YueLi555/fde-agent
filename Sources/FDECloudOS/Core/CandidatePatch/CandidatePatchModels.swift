import Foundation

struct CandidatePatchID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        let normalized = rawValue.lowercased()
        guard normalized == rawValue,
              normalized.count == 36,
              UUID(uuidString: normalized) != nil,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef-").contains($0)
              }) else {
            return nil
        }
        self.rawValue = normalized
    }

    init() {
        rawValue = UUID().uuidString.lowercased()
    }

    var description: String { rawValue }
}

enum CandidatePatchStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planning
    case awaitingApproval
    case approved
    case applying
    case applied
    case reviewReady
    case rejected
    case invalid
    case stale
    case reverted
}

enum CandidatePatchProjectionState: String, Codable, CaseIterable, Hashable, Sendable {
    case patchReady = "PATCH_READY"
    case revertConfirmationRequired = "REVERT_CONFIRMATION_REQUIRED"
    case reverting = "REVERTING"
    case reverted = "REVERTED"
    case sandboxDestructionConfirmationRequired = "SANDBOX_DESTRUCTION_CONFIRMATION_REQUIRED"
    case sandboxDestroyed = "SANDBOX_DESTROYED"
}

enum CandidatePatchOperationType: String, Codable, CaseIterable, Hashable, Sendable {
    case createTextFile = "create_text_file"
    case replaceTextFile = "replace_text_file"
}

enum CandidatePatchImplementationRecipe: String, Codable, CaseIterable, Hashable, Sendable {
    case customerSupportOrderLookupReadOnlyAdapter = "customer_support_order_lookup_read_only_adapter"
}

enum CandidatePatchRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"

    static func maximum(_ risks: [CandidatePatchRisk]) -> CandidatePatchRisk {
        risks.max { rank($0) < rank($1) } ?? .low
    }

    private static func rank(_ risk: CandidatePatchRisk) -> Int {
        switch risk {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

enum CandidatePatchApprovalDecision: String, Codable, CaseIterable, Hashable, Sendable {
    case approve = "APPROVE"
    case reject = "REJECT"
    case requestChanges = "REQUEST_CHANGES"
}

enum CandidatePatchApprovalSource: String, Codable, CaseIterable, Hashable, Sendable {
    case nativeUI = "native_ui"
    case accessibilityUI = "accessibility_ui"
    case testFixture = "test_fixture"
    case replay

    var isInteractiveUI: Bool {
        self == .nativeUI || self == .accessibilityUI
    }
}

enum CandidatePatchApprovalUIOperation: String, CaseIterable, Hashable, Sendable {
    case accessibilityEnumeration
    case windowFocus
    case screenshotCapture
    case scrolling
    case openConfirmation
    case cancelConfirmation
    case confirmApproval

    var emitsRuntimeApproval: Bool { self == .confirmApproval }
}

struct CandidatePatchApprovalUIContext: Hashable, Sendable {
    var currentWorkspaceID: UUID
    var currentTaskID: UUID
    var visiblePendingApprovalRequestIDs: [UUID]
    var authenticatedUserSessionID: UUID
    var appSessionID: UUID

    func visiblyContains(_ approvalRequestID: UUID) -> Bool {
        visiblePendingApprovalRequestIDs.count == 1
            && visiblePendingApprovalRequestIDs.first == approvalRequestID
    }
}

struct CandidatePatchApprovalProvenance: Codable, Hashable, Sendable {
    var source: CandidatePatchApprovalSource
    var workspaceID: UUID
    var taskID: UUID
    var planID: UUID
    var planRevision: Int
    var approvalRequestID: UUID
    var assessmentID: String
    var sourceSnapshotID: String
    var canonicalLegacyRoot: String
    var authenticatedUserSessionID: UUID
    var appSessionID: UUID
    var confirmationStepID: UUID
    var timestamp: Date
    var controllerPath: String
    var uiAction: String

    var sanitizedMetadata: [String: String] {
        [
            "approval_source": source.rawValue,
            "workspace_id": workspaceID.uuidString,
            "task_id": taskID.uuidString,
            "plan_id": planID.uuidString,
            "plan_revision": String(planRevision),
            "approval_request_id": approvalRequestID.uuidString,
            "assessment_id": assessmentID,
            "source_snapshot_id": sourceSnapshotID,
            "canonical_legacy_root": canonicalLegacyRoot,
            "authenticated_user_session_id": authenticatedUserSessionID.uuidString,
            "app_session_id": appSessionID.uuidString,
            "confirmation_step_id": confirmationStepID.uuidString,
            "approval_timestamp": ISO8601DateFormatter().string(from: timestamp),
            "controller_path": controllerPath,
            "ui_action": uiAction
        ]
    }
}

struct CandidatePatchApprovalConfirmation: Identifiable, Hashable, Sendable {
    var confirmationStepID: UUID
    var approvalRequestID: UUID
    var workspaceID: UUID
    var taskID: UUID
    var planID: UUID
    var planRevision: Int
    var assessmentID: String
    var sourceSnapshotID: String
    var canonicalLegacyRoot: String
    var authenticatedUserSessionID: UUID
    var appSessionID: UUID
    var openingSource: CandidatePatchApprovalSource
    var affectedRelativePaths: [String]
    var capability: String
    var issuedAt: Date

    var id: UUID { confirmationStepID }
    var shortPlanID: String { String(planID.uuidString.prefix(8)) }
}

struct CandidatePatchAppliedBinding: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var taskID: UUID
    var patchID: CandidatePatchID
    var planID: UUID
    var planRevision: Int
    var sandboxID: SandboxID
    var manifestID: String
    var sourceSnapshotID: String
    var canonicalLegacyRoot: String
    var authenticatedLocalSessionID: UUID
}

struct CandidatePatchRevertTarget: Hashable, Sendable {
    var binding: CandidatePatchAppliedBinding
    var appliedAt: Date
    var filesToRestore: [String]
    var filesToRemove: [String]
}

struct CandidatePatchRevertUIContext: Hashable, Sendable {
    var currentWorkspaceID: UUID
    var currentTaskID: UUID
    var visiblePatchID: CandidatePatchID
    var visibleSandboxID: SandboxID
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
}

struct CandidatePatchRevertConfirmation: Identifiable, Hashable, Sendable {
    var confirmationStepID: UUID
    var binding: CandidatePatchAppliedBinding
    var requestingTaskID: UUID
    var appSessionID: UUID
    var openingSource: CandidatePatchApprovalSource
    var filesToRestore: [String]
    var filesToRemove: [String]
    var issuedAt: Date

    var id: UUID { confirmationStepID }
}

struct CandidatePatchSandboxDestructionConfirmation: Identifiable, Hashable, Sendable {
    var confirmationStepID: UUID
    var binding: CandidatePatchAppliedBinding
    var requestingTaskID: UUID
    var appSessionID: UUID
    var openingSource: CandidatePatchApprovalSource
    var issuedAt: Date

    var id: UUID { confirmationStepID }
}

struct CandidatePatchSandboxDestructionTarget: Hashable, Sendable {
    var binding: CandidatePatchAppliedBinding
}

struct CandidatePatchApprovalRecord: Codable, Hashable, Sendable {
    var decision: CandidatePatchApprovalDecision
    var approvalRequestID: UUID
    var planID: UUID
    var planRevision: Int
    var decidedAt: Date
    var decidedBy: String
    var rationale: String
    var requestedChanges: [String]
    var provenance: CandidatePatchApprovalProvenance? = nil
}

struct CandidatePatchRevisionRecord: Codable, Hashable, Sendable {
    var originalApprovalRequestID: UUID
    var decision: CandidatePatchApprovalDecision
    var revisionInstructions: [String]
    var supersededPlanID: UUID
    var revisedPlanID: UUID?
    var freshApprovalRequestID: UUID?
    var decidedAt: Date
}

struct CandidatePatchEvidence: Codable, Hashable, Sendable, Identifiable {
    var claimID: String
    var statement: String
    var evidenceReferences: [AssessmentEvidenceReference]
    var confidence: AssessmentClaimConfidence
    var material: Bool

    var id: String { claimID }

    var isGrounded: Bool {
        material
            && !evidenceReferences.isEmpty
            && evidenceReferences.contains { reference in
                reference.source != .userIntent
                    && reference.observationStatus == .directlyRead
                    && reference.claimLevel != nil
            }
    }
}

enum CandidatePatchAssessmentFinalizationMode: String, Codable, Hashable, Sendable {
    case normal
    case fallback
}

enum CandidatePatchAssessmentValidationStatus: String, Codable, Hashable, Sendable {
    case validated
    case invalid
}

struct CandidatePatchAssessmentContext: Codable, Hashable, Sendable {
    var assessmentID: String
    var generatedAt: Date
    var sourceSnapshotID: String
    var canonicalLegacyRoot: String
    var requestedCapabilityID: String
    var requestedCapabilityDisplayLabel: String
    var compatibilityDecision: AgentIntegrationVerdict
    var supportedCapabilities: [String]
    var blockers: [String]
    var unresolvedRequirements: [String]
    var evidence: [CandidatePatchEvidence]
    var finalizationMode: CandidatePatchAssessmentFinalizationMode
    var validationStatus: CandidatePatchAssessmentValidationStatus

    var evidenceClaimIDs: [String] { evidence.map(\.claimID) }

    init(
        assessmentID: String,
        generatedAt: Date,
        sourceSnapshotID: String,
        canonicalLegacyRoot: String,
        requestedCapabilityID: String = AIAgentCapabilityKind.unspecified.rawValue,
        requestedCapabilityDisplayLabel: String = AIAgentCapabilityKind.unspecified.displayName,
        compatibilityDecision: AgentIntegrationVerdict = .no,
        supportedCapabilities: [String] = [],
        blockers: [String] = [],
        unresolvedRequirements: [String] = [],
        evidence: [CandidatePatchEvidence],
        finalizationMode: CandidatePatchAssessmentFinalizationMode = .normal,
        validationStatus: CandidatePatchAssessmentValidationStatus = .validated
    ) {
        self.assessmentID = assessmentID
        self.generatedAt = generatedAt
        self.sourceSnapshotID = sourceSnapshotID
        self.canonicalLegacyRoot = canonicalLegacyRoot
        self.requestedCapabilityID = requestedCapabilityID
        self.requestedCapabilityDisplayLabel = requestedCapabilityDisplayLabel
        self.compatibilityDecision = compatibilityDecision
        self.supportedCapabilities = supportedCapabilities
        self.blockers = blockers
        self.unresolvedRequirements = unresolvedRequirements
        self.evidence = evidence
        self.finalizationMode = finalizationMode
        self.validationStatus = validationStatus
    }

    init(
        assessmentID: String,
        generatedAt: Date,
        sourceSnapshotID: String,
        canonicalLegacyRoot: String,
        report: FDEAIIntegrationAssessmentReport,
        finalizationMode: CandidatePatchAssessmentFinalizationMode
    ) {
        self.init(
            assessmentID: assessmentID,
            generatedAt: generatedAt,
            sourceSnapshotID: sourceSnapshotID,
            canonicalLegacyRoot: canonicalLegacyRoot,
            requestedCapabilityID: report.requestedAICapability.normalizedCapabilityID,
            requestedCapabilityDisplayLabel: report.requestedAICapability.name,
            compatibilityDecision: report.verdict,
            supportedCapabilities: report.compatibilityMatrix.entries
                .filter { $0.status == .supported }
                .map { $0.requirement.capability.rawValue },
            blockers: report.integrationBlockers.blockers.map {
                "\($0.requirement.rawValue):\($0.reason)"
            },
            unresolvedRequirements: report.compatibilityMatrix.entries
                .filter { $0.status == .unknown }
                .map { $0.requirement.capability.rawValue },
            evidence: report.candidatePatchEvidence,
            finalizationMode: finalizationMode,
            validationStatus: .validated
        )
    }
}

struct CandidatePatchProposedOperation: Codable, Hashable, Sendable {
    var relativePath: String
    var operationType: CandidatePatchOperationType
    var proposedContent: String
    var implementationRecipe: CandidatePatchImplementationRecipe?
    var expectedPreimageSHA256: String?
    var purpose: String
    var evidenceClaimIDs: [String]
    var blockersAddressed: [String]
    var risk: CandidatePatchRisk
    var impact: String

    init(
        relativePath: String,
        operationType: CandidatePatchOperationType,
        proposedContent: String,
        implementationRecipe: CandidatePatchImplementationRecipe? = nil,
        expectedPreimageSHA256: String? = nil,
        purpose: String,
        evidenceClaimIDs: [String],
        blockersAddressed: [String] = [],
        risk: CandidatePatchRisk,
        impact: String
    ) {
        self.relativePath = relativePath
        self.operationType = operationType
        self.proposedContent = proposedContent
        self.implementationRecipe = implementationRecipe
        self.expectedPreimageSHA256 = expectedPreimageSHA256
        self.purpose = purpose
        self.evidenceClaimIDs = evidenceClaimIDs
        self.blockersAddressed = blockersAddressed
        self.risk = risk
        self.impact = impact
    }
}

struct CandidatePatchFileMetadata: Codable, Hashable, Sendable {
    var sha256: String
    var size: UInt64
    var permissions: UInt16
    var deviceID: UInt64
    var inode: UInt64
    var linkCount: UInt64
}

enum CandidatePatchRollbackKind: String, Codable, Hashable, Sendable {
    case restorePreimage = "restore_preimage"
    case removeCreatedFile = "remove_created_file"
}

struct CandidatePatchRollbackData: Codable, Hashable, Sendable {
    var kind: CandidatePatchRollbackKind
    var preimage: Data?
    var preimageMetadata: CandidatePatchFileMetadata?
}

struct CandidatePatchOperation: Codable, Hashable, Sendable, Identifiable {
    var operationID: String
    var relativeCanonicalSandboxPath: String
    var operationType: CandidatePatchOperationType
    var expectedPreimageSHA256: String?
    var resultingSHA256: String?
    var proposedContent: String
    var implementationRecipe: CandidatePatchImplementationRecipe?
    var purpose: String
    var evidenceClaimIDs: [String]
    var blockersAddressed: [String]
    var risk: CandidatePatchRisk
    var impact: String
    var rollbackData: CandidatePatchRollbackData
    var approvalRecord: CandidatePatchApprovalRecord?
    var beforeMetadata: CandidatePatchFileMetadata?
    var afterMetadata: CandidatePatchFileMetadata?

    var id: String { operationID }
}

struct CandidatePatchLegacyIntegrityBaseline: Codable, Hashable, Sendable {
    var canonicalLegacyRoot: String
    var rootDeviceID: UInt64
    var rootInode: UInt64
    var fingerprint: String
    var entryCount: Int
    var createdAt: Date
}

struct CandidatePatchPlan: Codable, Hashable, Sendable, Identifiable {
    var patchID: CandidatePatchID
    var planID: UUID
    var revision: Int
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var assessmentID: String
    var assessmentContext: CandidatePatchAssessmentContext? = nil
    var requestedCapabilityID: String = AIAgentCapabilityKind.unspecified.rawValue
    var compatibilityDecision: AgentIntegrationVerdict = .no
    var status: CandidatePatchStatus
    var requestedOutcome: String
    var operations: [CandidatePatchOperation]
    var supportingEvidence: [CandidatePatchEvidence]
    var blockersAddressed: [String] = []
    var expectedBehavior: [String]
    var risk: CandidatePatchRisk
    var prohibitedActions: [String]
    var validationRequiredLater: [String]
    var rollbackApproach: String
    var unknowns: [String]
    var approvedScope: [String]
    var legacyIntegrityBaseline: CandidatePatchLegacyIntegrityBaseline
    var createdAt: Date
    var updatedAt: Date
    var approvalRequestID: UUID?
    var approvalRecord: CandidatePatchApprovalRecord?

    var id: UUID { planID }
    var filesToCreate: [String] {
        operations.filter { $0.operationType == .createTextFile }.map(\.relativeCanonicalSandboxPath)
    }
    var filesToModify: [String] {
        operations.filter { $0.operationType == .replaceTextFile }.map(\.relativeCanonicalSandboxPath)
    }

    var markdown: String {
        let approvalID = approvalRequestID?.uuidString ?? "pending"
        let files = operations.map { operation in
            let intent = operation.operationType == .createTextFile ? "create" : "modify"
            let claims = operation.evidenceClaimIDs.joined(separator: ", ")
            let blockers = operation.blockersAddressed.joined(separator: " | ")
            let recipe = operation.implementationRecipe?.rawValue ?? "approved structured text mutation"
            return "- `\(operation.relativeCanonicalSandboxPath)` — \(intent); purpose: \(operation.purpose); claims: \(claims); blockers: \(blockers); recipe: \(recipe); risk: \(operation.risk.rawValue); expected impact: \(operation.impact)"
        }
        var lines = [
            "# Candidate Patch Plan",
            "",
            "- Plan ID: `\(planID.uuidString)`",
            "- Approval request ID: `\(approvalID)`",
            "- Plan revision: \(revision)",
            "- Capability: `\(requestedCapabilityID)`",
            "- Assessment: `\(assessmentID)` (\(compatibilityDecision.rawValue))",
            "- Source snapshot: `\(sourceSnapshotID)`",
            "- Safe Sandbox: reserved `\(sandboxID.rawValue)`; creation and readiness validation are deferred until approval",
            "",
            "## Proposed file scope"
        ]
        lines.append(contentsOf: files)
        lines.append(contentsOf: [
            "",
            "## Blockers addressed",
        ])
        lines.append(contentsOf: blockersAddressed.map { "- \($0)" })
        lines.append(contentsOf: [
            "",
            "## Expected behavior",
        ])
        lines.append(contentsOf: expectedBehavior.map { "- \($0)" })
        lines.append(contentsOf: [
            "",
            "## Risks and unknowns",
            "- Overall risk: \(risk.rawValue)",
        ])
        lines.append(contentsOf: unknowns.map { "- \($0)" })
        lines.append(contentsOf: [
            "",
            "## Rollback strategy",
            rollbackApproach,
            "",
            "## Validations still required",
        ])
        lines.append(contentsOf: validationRequiredLater.map { "- \($0)" })
        lines.append(contentsOf: [
            "",
            "No patch bytes or Unified Diff exist before explicit approval."
        ])
        return lines.joined(separator: "\n")
    }
}

enum CandidatePatchAuditEventType: String, Codable, Hashable, Sendable {
    case planPrepared = "plan_prepared"
    case approvalRequested = "approval_requested"
    case approvalConfirmationOpened = "approval_confirmation_opened"
    case approvalRecorded = "approval_recorded"
    case revisionRequested = "revision_requested"
    case operationApplied = "operation_applied"
    case operationFailed = "operation_failed"
    case sourceIntegrityChecked = "source_integrity_checked"
    case diffGenerated = "diff_generated"
    case reviewPrepared = "review_prepared"
    case operationReverted = "operation_reverted"
    case revertConfirmationOpened = "revert_confirmation_opened"
    case revertConfirmationCancelled = "revert_confirmation_cancelled"
    case revertStarted = "revert_started"
    case revertCompleted = "revert_completed"
    case sandboxDestructionConfirmationOpened = "sandbox_destruction_confirmation_opened"
    case sandboxDestructionConfirmationCancelled = "sandbox_destruction_confirmation_cancelled"
    case sandboxDestructionStarted = "sandbox_destruction_started"
    case sandboxDestroyed = "sandbox_destroyed"
}

struct CandidatePatchAuditEvent: Codable, Hashable, Sendable, Identifiable {
    var eventID: UUID
    var type: CandidatePatchAuditEventType
    var timestamp: Date
    var operationID: String?
    var relativePath: String?
    var beforeSHA256: String?
    var afterSHA256: String?
    var sourceIntegrity: SourceIntegrityState?
    var safeDetail: String
    var approvalProvenance: CandidatePatchApprovalProvenance? = nil

    var id: UUID { eventID }
}

struct CandidatePatchManifest: Codable, Hashable, Sendable {
    var formatVersion: Int
    var patchID: CandidatePatchID
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var sandboxRoot: String
    var status: CandidatePatchStatus
    var plan: CandidatePatchPlan
    var operations: [CandidatePatchOperation]
    var unifiedDiff: String?
    var additions: Int
    var deletions: Int
    var sourceIntegrity: SourceIntegrityState
    var auditEvents: [CandidatePatchAuditEvent]
    var revisionHistory: [CandidatePatchRevisionRecord]
    var appliedBinding: CandidatePatchAppliedBinding? = nil
    var appliedAt: Date? = nil
    var revertedAt: Date? = nil
    var sandboxDestroyedAt: Date? = nil
    var createdAt: Date
    var updatedAt: Date

    var stableManifestID: String {
        "candidate-patch-manifest:\(sandboxID.rawValue):\(patchID.rawValue)"
    }
}

struct CandidatePatchAppliedOperation: Codable, Hashable, Sendable {
    var operationID: String
    var relativePath: String
    var resultingSHA256: String
}

struct CandidatePatchFailedOperation: Codable, Hashable, Sendable {
    var operationID: String
    var relativePath: String
    var failureCode: CandidatePatchFailureCode
}

struct CandidatePatchApplicationResult: Codable, Hashable, Sendable {
    var manifest: CandidatePatchManifest
    var appliedOperations: [CandidatePatchAppliedOperation]
    var failedOperations: [CandidatePatchFailedOperation]

    var complete: Bool {
        failedOperations.isEmpty
            && appliedOperations.count == manifest.operations.count
            && manifest.status == .reviewReady
    }
}

struct CandidatePatchFileReview: Codable, Hashable, Sendable {
    var relativePath: String
    var operationType: CandidatePatchOperationType
    var purpose: String
    var evidenceClaimIDs: [String]
    var expectedEffect: String
    var risk: CandidatePatchRisk
    var unknowns: [String]
    var rollbackMethod: String
}

struct CandidatePatchReviewSummary: Codable, Hashable, Sendable {
    var patchID: CandidatePatchID
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var requestedOutcome: String
    var assessmentEvidence: [CandidatePatchEvidence]
    var approvedPlan: CandidatePatchPlan
    var files: [CandidatePatchFileReview]
    var unifiedDiff: String
    var additions: Int
    var deletions: Int
    var expectedBehavior: [String]
    var validationStillRequired: [String]
    var unknowns: [String]
    var rollbackInstructions: String
    var originalLegacyIntegrity: SourceIntegrityState
    var buildOrTestExecuted: Bool
    var gitOrDeploymentActionOccurred: Bool

    var markdown: String {
        let evidenceLines = assessmentEvidence.map { "- `\($0.claimID)`: \($0.statement)" }
        let fileLines = files.map { file in
            "- `\(file.relativePath)` — \(file.purpose); effect: \(file.expectedEffect); risk: \(file.risk.rawValue); rollback: \(file.rollbackMethod)"
        }
        let approval = approvedPlan.approvalRecord?.decision.rawValue ?? "missing"
        let behavior = expectedBehavior.joined(separator: " | ")
        let validation = validationStillRequired.joined(separator: " | ")
        let remainingUnknowns = unknowns.joined(separator: " | ")
        return ([
            "# Candidate Patch Review",
            "",
            "1. Requested outcome: \(requestedOutcome)",
            "2. Assessment evidence used:",
        ] + evidenceLines + [
            "3. Approved plan: revision \(approvedPlan.revision), approval \(approval)",
            "4. Sandbox / source snapshot IDs: `\(sandboxID.rawValue)` / `\(sourceSnapshotID)`",
            "5. Files created or modified:",
        ] + fileLines + [
            "6. Unified diff:",
            "```diff",
            unifiedDiff,
            "```",
            "7. Per-file purpose and risk are listed above.",
            "8. Expected behavior: \(behavior)",
            "9. Validation still required: \(validation)",
            "10. Unknowns: \(remainingUnknowns)",
            "11. Rollback/revert: \(rollbackInstructions)",
            "12. Original Legacy integrity: \(originalLegacyIntegrity.rawValue)",
            "13. No build or test was executed.",
            "14. No Git or deployment action occurred.",
            "",
            "Candidate changes were applied in the isolated Sandbox. Build, test, runtime, and deployment behavior remain unverified."
        ]).joined(separator: "\n")
    }
}

struct CandidatePatchPlanRequest: Sendable {
    var patchID: CandidatePatchID?
    var sandboxID: SandboxID
    var selectedLegacyRoot: URL?
    var trustedLegacyRoot: URL
    var agentWorkspaceRoots: [URL]
    var assessment: CandidatePatchAssessmentContext?
    var requestedCapabilityID: String?
    var requestedOutcome: String
    var proposedOperations: [CandidatePatchProposedOperation]
    var approvedScope: [String]
    var expectedBehavior: [String]
    var validationRequiredLater: [String]
    var rollbackApproach: String
    var unknowns: [String]
    var minimumFreeDiskBytes: UInt64

    init(
        patchID: CandidatePatchID? = nil,
        sandboxID: SandboxID,
        selectedLegacyRoot: URL?,
        trustedLegacyRoot: URL,
        agentWorkspaceRoots: [URL] = [],
        assessment: CandidatePatchAssessmentContext?,
        requestedCapabilityID: String? = nil,
        requestedOutcome: String,
        proposedOperations: [CandidatePatchProposedOperation],
        approvedScope: [String],
        expectedBehavior: [String],
        validationRequiredLater: [String],
        rollbackApproach: String,
        unknowns: [String],
        minimumFreeDiskBytes: UInt64 = 1_048_576
    ) {
        self.patchID = patchID
        self.sandboxID = sandboxID
        self.selectedLegacyRoot = selectedLegacyRoot
        self.trustedLegacyRoot = trustedLegacyRoot
        self.agentWorkspaceRoots = agentWorkspaceRoots
        self.assessment = assessment
        self.requestedCapabilityID = requestedCapabilityID
        self.requestedOutcome = requestedOutcome
        self.proposedOperations = proposedOperations
        self.approvedScope = approvedScope
        self.expectedBehavior = expectedBehavior
        self.validationRequiredLater = validationRequiredLater
        self.rollbackApproach = rollbackApproach
        self.unknowns = unknowns
        self.minimumFreeDiskBytes = minimumFreeDiskBytes
    }
}

enum CandidatePatchFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case workspaceNotSelected = "workspace_not_selected"
    case workspaceRootUntrusted = "workspace_root_untrusted"
    case legacyRootMismatch = "legacy_root_mismatch"
    case agentWorkspaceRejected = "agent_workspace_rejected"
    case assessmentMissing = "phase_2c_assessment_missing"
    case assessmentStale = "phase_2c_assessment_stale"
    case assessmentEvidenceMissing = "phase_2c_evidence_missing"
    case assessmentVerdictNotEligible = "assessment_verdict_not_eligible"
    case assessmentCapabilityMismatch = "assessment_capability_mismatch"
    case sourceSnapshotStale = "source_snapshot_stale"
    case sourceDrift = "source_drift"
    case sandboxMissing = "sandbox_missing"
    case sandboxNotReady = "sandbox_not_ready"
    case insufficientDiskSpace = "insufficient_disk_space"
    case emptyPlan = "empty_candidate_patch_plan"
    case operationUnavailable = "operation_unavailable"
    case absolutePathRejected = "absolute_path_rejected"
    case traversalRejected = "path_traversal_rejected"
    case pathContainmentFailed = "path_containment_failed"
    case sandboxMetadataPathRejected = "sandbox_metadata_path_rejected"
    case sensitivePathRejected = "sensitive_path_rejected"
    case generatedTestUnavailable = "phase_2d_2_generated_tests_unavailable"
    case binaryFileRejected = "binary_file_rejected"
    case sensitiveContentRejected = "sensitive_content_rejected"
    case symlinkRejected = "symlink_rejected"
    case hardLinkRejected = "hard_link_rejected"
    case scopeNotApproved = "scope_not_approved"
    case evidenceClaimMissing = "evidence_claim_missing"
    case targetAlreadyExists = "target_already_exists"
    case targetMissing = "target_missing"
    case sandboxPreimageChanged = "sandbox_preimage_changed"
    case humanApprovalMissing = "human_approval_missing"
    case invalidApprovalState = "invalid_approval_state"
    case planRevisionMismatch = "plan_revision_mismatch"
    case patchNotFound = "candidate_patch_not_found"
    case manifestInvalid = "candidate_patch_manifest_invalid"
    case partialApplication = "partial_application"
    case currentPatchImageChanged = "current_patch_image_changed"
    case revertUnavailable = "revert_unavailable"
    case revertSelectionAmbiguous = "revert_selection_ambiguous"
    case revertBindingMissing = "revert_binding_missing"
    case revertBindingMismatch = "revert_binding_mismatch"
    case authenticatedSessionMismatch = "authenticated_session_mismatch"
    case sandboxDestructionUnavailable = "sandbox_destruction_unavailable"
    case sandboxDestructionSelectionAmbiguous = "sandbox_destruction_selection_ambiguous"
}

enum CandidatePatchError: Error, Equatable, Sendable {
    case blocked(CandidatePatchFailureCode)

    var code: CandidatePatchFailureCode {
        switch self {
        case .blocked(let code): code
        }
    }
}

extension CandidatePatchError: LocalizedError {
    var errorDescription: String? { code.rawValue }
}

private extension FDEAIIntegrationAssessmentReport {
    var candidatePatchEvidence: [CandidatePatchEvidence] {
        var claims: [AssessmentClaim] = [executiveSummary]
        claims.append(contentsOf: legacySystemUnderstanding)
        claims.append(contentsOf: compatibilityMatrix.entries.map(\.claim))
        claims.append(contentsOf: integrationOpportunities.map(\.claim))
        claims.append(contentsOf: securityAssessment.claims)
        claims.append(contentsOf: integrationBlockers.blockers.map(\.claim))
        claims.append(recommendedArchitecture.claim)

        var seen = Set<String>()
        return claims.filter { seen.insert($0.claimID).inserted }.map { claim in
            let hasDirectLegacyEvidence = claim.evidence.contains { reference in
                reference.source != .userIntent
                    && reference.observationStatus == .directlyRead
                    && reference.claimLevel != nil
            }
            return CandidatePatchEvidence(
                claimID: claim.claimID,
                statement: claim.statement,
                evidenceReferences: claim.evidence,
                confidence: claim.confidence,
                material: hasDirectLegacyEvidence
            )
        }
    }
}
