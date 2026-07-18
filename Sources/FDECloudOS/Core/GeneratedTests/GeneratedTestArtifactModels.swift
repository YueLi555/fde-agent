import Foundation

enum GeneratedTestVirtualFileOperation: String, Codable, CaseIterable, Hashable, Sendable {
    case create
    case modify
}

enum GeneratedTestArtifactReviewState: String, Codable, CaseIterable, Hashable, Sendable {
    case awaitingReview = "AWAITING_REVIEW"
    case changeRequested = "CHANGE_REQUESTED"
    case rejected = "REJECTED"
    case approved = "APPROVED"
}

enum GeneratedTestReviewDecisionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case requestChanges = "REQUEST_CHANGES"
    case reject = "REJECT_ARTIFACT"
    case approve = "APPROVE_TEST_ARTIFACT"
}

struct GeneratedTestArtifactDigest: Codable, Hashable, Sendable {
    var algorithm: String
    var canonicalSerializationVersion: Int
    var sha256: String

    static let empty = GeneratedTestArtifactDigest(
        algorithm: "SHA-256",
        canonicalSerializationVersion: 1,
        sha256: ""
    )
}

struct GeneratedTestArtifactSourceBinding: Codable, Hashable, Sendable {
    var generatedTestPlanID: UUID
    var generatedTestPlanRevision: Int
    var generatedTestPlanSHA256: String
    var generatedTestSourceBinding: GeneratedTestSourceBinding
    var approvedPostimages: [GeneratedTestCandidatePostimage]

    var digest: String {
        var fields: [(String, String)] = [
            ("generated_test_plan_id", generatedTestPlanID.uuidString.lowercased()),
            ("generated_test_plan_revision", String(generatedTestPlanRevision)),
            ("generated_test_plan_sha256", generatedTestPlanSHA256),
            ("generated_test_source_binding", generatedTestSourceBinding.digest)
        ]
        for (index, postimage) in approvedPostimages.sorted(by: { $0.relativePath < $1.relativePath }).enumerated() {
            fields.append(("approved_postimage_\(index)_path", postimage.relativePath))
            fields.append(("approved_postimage_\(index)_sha256", postimage.sha256))
        }
        return CandidatePatchArtifactAuthority.digest(fields)
    }
}

struct GeneratedTestScenarioBinding: Codable, Hashable, Sendable, Identifiable {
    var scenarioID: String
    var title: String
    var behaviorUnderTest: String
    var virtualFileIDs: [String]
    var validationPlanItemIDs: [String]
    var blockerClaimIDs: [String]
    var evidenceClaimIDs: [String]
    var evidencePaths: [String]

    var id: String { scenarioID }
}

struct GeneratedTestEvidenceBinding: Codable, Hashable, Sendable, Identifiable {
    var bindingID: String
    var evidenceID: String
    var kind: GeneratedTestEvidenceKind
    var relativePath: String
    var sourceSHA256: String
    var safeClaim: String
    var supportsScenarioIDs: [String]
    var supportsVirtualFileIDs: [String]

    var id: String { bindingID }
}

struct GeneratedTestVirtualFile: Codable, Hashable, Sendable, Identifiable {
    var stableID: String
    var proposedRelativePath: String
    var operation: GeneratedTestVirtualFileOperation
    var language: String
    var framework: GeneratedTestFrameworkIdentity
    var sourceBytes: Data
    var sourceSHA256: String
    var lineCount: Int
    var scenarioIDs: [String]
    var validationPlanItemIDs: [String]
    var blockerClaimIDs: [String]
    var evidenceClaimIDs: [String]
    var evidencePaths: [String]
    var candidatePatchBindingSHA256: String
    var generationProvenance: [String]
    var writtenStatus: String
    var compiledStatus: String
    var executedStatus: String
    var behaviorVerificationStatus: String

    var id: String { stableID }
    var sourceText: String { String(decoding: sourceBytes, as: UTF8.self) }

    static let notWritten = "NOT_WRITTEN"
    static let notCompiled = "NOT_COMPILED"
    static let notExecuted = "NOT_EXECUTED"
    static let behaviorNotVerified = "BEHAVIOR_NOT_VERIFIED"
}

struct GeneratedTestArtifactRevision: Codable, Hashable, Sendable, Identifiable {
    var artifactID: UUID
    var revision: Int
    var lifecycleStatus: GeneratedTestLifecycleStatus
    var reviewState: GeneratedTestArtifactReviewState
    var reviewSessionID: UUID? = nil
    var framework: GeneratedTestFrameworkIdentity
    var groundedTestLocation: String
    var risk: CandidatePatchRisk
    var virtualFiles: [GeneratedTestVirtualFile]
    var scenarioBindings: [GeneratedTestScenarioBinding]
    var evidenceBindings: [GeneratedTestEvidenceBinding]
    var validationPlanItemIDs: [String]
    var generationProvenance: [String]
    var reviewInstructionSHA256: String?
    var digest: GeneratedTestArtifactDigest
    var createdAt: Date

    var id: String { "\(artifactID.uuidString.lowercased()):\(revision)" }
    var sourceByteCount: Int { virtualFiles.reduce(0) { $0 + $1.sourceBytes.count } }
}

struct GeneratedTestReviewDecision: Codable, Hashable, Sendable, Identifiable {
    var decisionID: UUID
    var artifactID: UUID
    var artifactRevision: Int
    var artifactSHA256: String
    var reviewSessionID: UUID? = nil
    var decision: GeneratedTestReviewDecisionKind
    var reviewerInstructions: String?
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
    var decidedAt: Date

    var id: UUID { decisionID }
}

struct GeneratedTestArtifact: Codable, Hashable, Sendable, Identifiable {
    var artifactID: UUID
    var sourceBinding: GeneratedTestArtifactSourceBinding
    var revisions: [GeneratedTestArtifactRevision]
    var reviewDecisions: [GeneratedTestReviewDecision]
    var createdAt: Date
    var updatedAt: Date

    var id: UUID { artifactID }
    var currentRevision: GeneratedTestArtifactRevision? { revisions.max(by: { $0.revision < $1.revision }) }
    var phase2D3Available: Bool { false }

    func revision(_ number: Int) -> GeneratedTestArtifactRevision? {
        revisions.first { $0.revision == number }
    }
}

struct GeneratedTestArtifactGenerationContext: Hashable, Sendable {
    var workspaceID: UUID
    var generatedTestPlanningTaskID: UUID
    var generatedTestPlanID: UUID
    var generatedTestPlanRevision: Int
    var generatedTestPlanSHA256: String
    var generatedTestSourceBindingSHA256: String
    var sourceCandidatePatchTaskID: UUID
    var candidatePatchID: CandidatePatchID
    var candidatePatchPlanID: UUID
    var candidatePatchPlanRevision: Int
    var candidatePatchArtifactSHA256: String
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
}

struct GeneratedTestArtifactGenerationRequest: Sendable {
    var context: GeneratedTestArtifactGenerationContext
}

enum GeneratedTestArtifactGenerationOutcome: String, Codable, Hashable, Sendable {
    case testArtifactReviewReady = "TEST_ARTIFACT_REVIEW_READY"
    case clarificationRequired = "CLARIFICATION_REQUIRED"
}

struct GeneratedTestArtifactGenerationResult: Codable, Hashable, Sendable {
    var outcome: GeneratedTestArtifactGenerationOutcome
    var artifact: GeneratedTestArtifact?
    var missingEvidence: [String]
}

struct GeneratedTestArtifactReviewContext: Hashable, Sendable {
    var workspaceID: UUID
    var generatedTestPlanningTaskID: UUID
    var generatedTestPlanID: UUID
    var generatedTestPlanRevision: Int
    var generatedTestPlanSHA256: String
    var sourceCandidatePatchTaskID: UUID
    var candidatePatchID: CandidatePatchID
    var candidatePatchPlanID: UUID
    var candidatePatchPlanRevision: Int
    var candidatePatchArtifactSHA256: String
    var sandboxID: SandboxID
    var artifactID: UUID
    var artifactRevision: Int
    var artifactSHA256: String
    var reviewSessionID: UUID
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
}

struct GeneratedTestArtifactReviewEligibility: Equatable, Sendable {
    var isAvailable: Bool
    var unavailableReason: String?

    static let available = GeneratedTestArtifactReviewEligibility(
        isAvailable: true,
        unavailableReason: nil
    )

    static func unavailable(_ reason: String) -> GeneratedTestArtifactReviewEligibility {
        GeneratedTestArtifactReviewEligibility(isAvailable: false, unavailableReason: reason)
    }
}

struct GeneratedTestArtifactApprovalConfirmation: Identifiable, Hashable, Sendable {
    var confirmationID: UUID
    var context: GeneratedTestArtifactReviewContext
    var issuedAt: Date

    var id: UUID { confirmationID }
}

struct GeneratedTestArtifactSafetyCounters: Codable, Hashable, Sendable {
    var legacyWrites = 0
    var sandboxWrites = 0
    var candidatePatchMutations = 0
    var realGeneratedTestFiles = 0
    var generatedBytesWrittenToFileSystem = 0
    var syntaxChecks = 0
    var buildExecutions = 0
    var testExecutions = 0
    var shellOperations = 0
    var gitOperations = 0
    var packageManagerOperations = 0
    var deploymentOperations = 0
    var credentialAccesses = 0
    var productionAccesses = 0
    var artifactMetadataSourceBytes = 0
}
