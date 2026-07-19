import Foundation

enum EvalRunState: String, Codable, CaseIterable, Hashable, Sendable {
    case awaitingExecutionApproval = "AWAITING_EXECUTION_APPROVAL"
    case executionApproved = "EXECUTION_APPROVED"
    case validatingAuthority = "VALIDATING_AUTHORITY"
    case validatingDataset = "VALIDATING_DATASET"
    case executing = "EXECUTING"
    case stoppedFailClosed = "STOPPED_FAIL_CLOSED"
    case executionCompleted = "EXECUTION_COMPLETED"
    case resultsAwaitingReview = "RESULTS_AWAITING_REVIEW"
    case resultsApproved = "RESULTS_APPROVED"
    case resultsRejected = "RESULTS_REJECTED"
    case resultsChangeRequested = "RESULTS_CHANGE_REQUESTED"
    case cancelled = "CANCELLED"

    var isExecutionActive: Bool {
        switch self {
        case .executionApproved, .validatingAuthority, .validatingDataset, .executing:
            true
        default:
            false
        }
    }

    var isImmutableTerminal: Bool {
        switch self {
        case .stoppedFailClosed, .resultsApproved, .resultsRejected, .cancelled:
            true
        default:
            false
        }
    }

    var displayName: String {
        switch self {
        case .awaitingExecutionApproval: "Awaiting execution approval"
        case .executionApproved: "Execution approved"
        case .validatingAuthority: "Validating exact authority"
        case .validatingDataset: "Validating approved dataset"
        case .executing: "Executing approved fixture scenarios"
        case .stoppedFailClosed: "Stopped fail-closed"
        case .executionCompleted: "Execution completed"
        case .resultsAwaitingReview: "Results awaiting review"
        case .resultsApproved: "Results approved"
        case .resultsRejected: "Results rejected"
        case .resultsChangeRequested: "Results changes requested"
        case .cancelled: "Cancelled"
        }
    }
}

enum EvalOverallResult: String, Codable, CaseIterable, Hashable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case inconclusive = "INCONCLUSIVE"
    case notExecuted = "NOT_EXECUTED"
}

enum EvalMetricOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case inconclusive = "INCONCLUSIVE"
    case notExecuted = "NOT_EXECUTED"
}

enum EvalScenarioOutcome: String, Codable, CaseIterable, Hashable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case inconclusive = "INCONCLUSIVE"
    case notExecuted = "NOT_EXECUTED"
    case cancelled = "CANCELLED"
}

enum EvalDatasetSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case appManaged = "APP_MANAGED"
    case repositoryFixture = "REPOSITORY_FIXTURE"
}

enum EvalFailureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case authorityMismatch = "AUTHORITY_MISMATCH"
    case approvalMissing = "APPROVAL_MISSING"
    case revisionMismatch = "REVISION_MISMATCH"
    case digestMismatch = "DIGEST_MISMATCH"
    case sessionMismatch = "SESSION_MISMATCH"
    case scenarioNotApproved = "SCENARIO_NOT_APPROVED"
    case metricNotApproved = "METRIC_NOT_APPROVED"
    case datasetDrift = "DATASET_DRIFT"
    case datasetLimitExceeded = "DATASET_LIMIT_EXCEEDED"
    case providerMismatch = "PROVIDER_MISMATCH"
    case policyViolation = "POLICY_VIOLATION"
    case runtimeLimitExceeded = "RUNTIME_LIMIT_EXCEEDED"
    case tokenLimitExceeded = "TOKEN_LIMIT_EXCEEDED"
    case costLimitExceeded = "COST_LIMIT_EXCEEDED"
    case criticalGateFailure = "CRITICAL_GATE_FAILURE"
    case missingEvidence = "MISSING_EVIDENCE"
    case cancelled = "CANCELLED"
    case interrupted = "INTERRUPTED"
    case persistenceInvalid = "PERSISTENCE_INVALID"
}

enum EvalRunReviewStage: String, Codable, CaseIterable, Hashable, Sendable {
    case execution = "EXECUTION"
    case results = "RESULTS"
}

enum EvalRunReviewDecisionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case approveExecution = "APPROVE_EXECUTION"
    case approveResults = "APPROVE_RESULTS"
    case requestChanges = "REQUEST_CHANGES"
    case rejectResults = "REJECT_RESULTS"
}

enum EvalRunRestorationFailureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case interruptedExecution = "INTERRUPTED_EXECUTION"
    case tamperedArtifact = "TAMPERED_ARTIFACT"
    case missingArtifact = "MISSING_ARTIFACT"
    case contradictoryState = "CONTRADICTORY_STATE"
}

struct ControlledEvalExecutionPolicy: Codable, Hashable, Sendable, Identifiable {
    var policyID: UUID
    var revision: Int
    var scenarioAllowlist: [String]
    var metricAllowlist: [String]
    var datasetAllowlist: [String]
    var evaluatorID: String
    var evaluatorVersion: String
    var modelVersion: String
    var maximumCases: Int
    var maximumAttemptsPerCase: Int
    var maximumRuntimeDurationMilliseconds: Int
    var maximumTokenEstimate: Int
    var maximumEstimatedCost: Double
    var allowedTools: [String]
    var networkAccessAllowed: Bool
    var productionAccessAllowed: Bool
    var credentialAccessAllowed: Bool
    var stopOnCriticalFailure: Bool
    var policySHA256: String

    var id: UUID { policyID }
    var isSelfValidating: Bool {
        !policySHA256.isEmpty && policySHA256 == ControlledEvalDigest.policySHA256(self)
    }
}

struct EvalDatasetCase: Codable, Hashable, Sendable, Identifiable {
    var caseID: String
    var scenarioID: String
    var input: String
    var expectedBehavior: [String]
    var deterministicOutput: String
    var actualBehavior: String
    var metricValues: [String: Double]
    var evidenceReferences: [String]
    var tokenEstimate: Int
    var estimatedCost: Double
    var simulatedDurationMilliseconds: Int
    var isCriticalFailure: Bool
    var caseSHA256: String

    var id: String { caseID }
    var isSelfValidating: Bool {
        !caseSHA256.isEmpty && caseSHA256 == ControlledEvalDigest.datasetCaseSHA256(self)
    }
}

struct EvalDatasetManifest: Codable, Hashable, Sendable, Identifiable {
    var datasetID: String
    var revision: Int
    var sourceKind: EvalDatasetSourceKind
    var fixturePath: String?
    var approvedDatasetRequirementIDs: [String]
    var approvedScenarioIDs: [String]
    var cases: [EvalDatasetCase]
    var readOnly: Bool
    var deterministic: Bool
    var containsProductionData: Bool
    var containsCustomerSecrets: Bool
    var manifestSHA256: String

    var id: String { datasetID }
    var caseCount: Int { cases.count }
    var isSelfValidating: Bool {
        !manifestSHA256.isEmpty
            && manifestSHA256 == ControlledEvalDigest.datasetManifestSHA256(self)
            && cases.allSatisfy(\.isSelfValidating)
    }
}

struct ControlledEvalAuthorityBinding: Codable, Hashable, Sendable {
    var readinessSourceBinding: ProductionReadinessSourceBinding
    var productionReadinessReportID: UUID
    var productionReadinessReportRevision: Int
    var productionReadinessReportSHA256: String
    var productionReadinessReviewDecisionID: UUID
    var productionReadinessReviewDecisionSHA256: String
    var aiEvalPlanID: UUID
    var aiEvalPlanRevision: Int
    var aiEvalPlanSHA256: String
    var aiEvalPlanReviewDecisionID: UUID
    var aiEvalPlanReviewDecisionSHA256: String
    var capabilityID: String
    var authenticatedLocalSessionID: UUID
    var workspaceSessionID: UUID
    var appSessionID: UUID
    var executionPolicySHA256: String
    var datasetManifestSHA256: String
    var evaluatorID: String
    var evaluatorVersion: String
    var modelVersion: String
    var authoritySHA256: String

    var missionRunID: UUID { readinessSourceBinding.missionRunID }
    var workspaceID: UUID { readinessSourceBinding.workspaceID }
    var canonicalLegacyRoot: String { readinessSourceBinding.canonicalLegacyRoot }
    var sourceSnapshotID: String { readinessSourceBinding.sourceSnapshotID }
    var assessmentID: String { readinessSourceBinding.assessmentID }
    var assessmentSHA256: String { readinessSourceBinding.assessmentSHA256 }
    var candidatePatchID: CandidatePatchID { readinessSourceBinding.candidatePatchID }
    var sandboxID: SandboxID { readinessSourceBinding.sandboxID }
    var isSelfValidating: Bool {
        readinessSourceBinding.isSelfValidating
            && !authoritySHA256.isEmpty
            && authoritySHA256 == ControlledEvalDigest.authoritySHA256(self)
    }
}

struct ControlledEvalExecutionRequest: Codable, Hashable, Sendable, Identifiable {
    var requestID: UUID
    var runID: UUID
    var executionAuthorizationID: UUID? = nil
    var authority: ControlledEvalAuthorityBinding
    var requestedScenarioIDs: [String]
    var requestedMetricIDs: [String]
    var policy: ControlledEvalExecutionPolicy
    var dataset: EvalDatasetManifest
    var estimatedTokenCount: Int
    var estimatedCost: Double
    var requestedAt: Date
    var requestSHA256: String

    var id: UUID { requestID }
    var isSelfValidating: Bool {
        !requestSHA256.isEmpty
            && requestSHA256 == ControlledEvalDigest.executionRequestSHA256(self)
            && authority.isSelfValidating
            && policy.isSelfValidating
            && dataset.isSelfValidating
    }
}

struct ControlledEvalExecutionProposal: Codable, Hashable, Sendable, Identifiable {
    var proposalID: UUID
    var authorizationChallengeID: UUID
    var authority: ControlledEvalAuthorityBinding
    var requestedScenarioIDs: [String]
    var requestedMetricIDs: [String]
    var policy: ControlledEvalExecutionPolicy
    var dataset: EvalDatasetManifest
    var estimatedTokenCount: Int
    var estimatedCost: Double
    var proposalSHA256: String

    var id: UUID { proposalID }
    var originatingArtifactAppSessionID: UUID { authority.readinessSourceBinding.appSessionID }
    var currentActionAppSessionID: UUID { authority.appSessionID }
    var requiresReauthorization: Bool {
        originatingArtifactAppSessionID != currentActionAppSessionID
    }
    var isSelfValidating: Bool {
        !proposalSHA256.isEmpty
            && proposalSHA256 == ControlledEvalDigest.executionProposalSHA256(self)
            && authority.isSelfValidating
            && policy.isSelfValidating
            && dataset.isSelfValidating
            && authority.executionPolicySHA256 == policy.policySHA256
            && authority.datasetManifestSHA256 == dataset.manifestSHA256
            && authority.evaluatorID == policy.evaluatorID
            && authority.evaluatorVersion == policy.evaluatorVersion
            && authority.modelVersion == policy.modelVersion
    }
}

struct ControlledEvalExecutionAuthorization: Codable, Hashable, Sendable, Identifiable {
    var authorizationID: UUID
    var authorizationChallengeID: UUID
    var confirmationID: UUID
    var proposalSHA256: String
    var authority: ControlledEvalAuthorityBinding
    var requestedScenarioIDs: [String]
    var requestedMetricIDs: [String]
    var executionPolicySHA256: String
    var datasetManifestSHA256: String
    var evaluatorID: String
    var evaluatorVersion: String
    var modelVersion: String
    var createdAt: Date
    var expiresAt: Date
    var consumedAt: Date?
    var authorizationSHA256: String

    var id: UUID { authorizationID }
    var isConsumed: Bool { consumedAt != nil }
    var isSelfValidating: Bool {
        !authorizationSHA256.isEmpty
            && authorizationSHA256 == ControlledEvalDigest.executionAuthorizationSHA256(self)
            && authority.isSelfValidating
            && executionPolicySHA256 == authority.executionPolicySHA256
            && datasetManifestSHA256 == authority.datasetManifestSHA256
            && evaluatorID == authority.evaluatorID
            && evaluatorVersion == authority.evaluatorVersion
            && modelVersion == authority.modelVersion
    }

    func isAvailable(at date: Date) -> Bool {
        isSelfValidating && !isConsumed && date <= expiresAt
    }
}

struct ControlledEvalResultReviewProposal: Codable, Hashable, Sendable, Identifiable {
    var proposalID: UUID
    var reviewChallengeID: UUID
    var executionAuthorizationID: UUID
    var executionAuthority: ControlledEvalAuthorityBinding
    var currentSessionAuthority: ControlledEvalSessionAuthority
    var runID: UUID
    var runRequestSHA256: String
    var resultRevision: Int
    var resultSHA256: String
    var attempt: Int
    var overallResult: EvalOverallResult
    var executionPolicySHA256: String
    var datasetManifestSHA256: String
    var evaluatorID: String
    var evaluatorVersion: String
    var modelVersion: String
    var proposalSHA256: String

    var id: UUID { proposalID }
    var requiresReauthorization: Bool {
        executionAuthority.appSessionID != currentSessionAuthority.appSessionID
    }
    var isSelfValidating: Bool {
        !proposalSHA256.isEmpty
            && proposalSHA256 == ControlledEvalDigest.resultReviewProposalSHA256(self)
            && executionAuthority.isSelfValidating
            && resultRevision > 0
            && !resultSHA256.isEmpty
            && executionPolicySHA256 == executionAuthority.executionPolicySHA256
            && datasetManifestSHA256 == executionAuthority.datasetManifestSHA256
            && evaluatorID == executionAuthority.evaluatorID
            && evaluatorVersion == executionAuthority.evaluatorVersion
            && modelVersion == executionAuthority.modelVersion
            && currentSessionAuthority.workspaceID == executionAuthority.workspaceID
    }
}

struct ControlledEvalResultReviewAuthorization: Codable, Hashable, Sendable, Identifiable {
    var authorizationID: UUID
    var reviewChallengeID: UUID
    var confirmationID: UUID
    var proposalSHA256: String
    var currentSessionAuthority: ControlledEvalSessionAuthority
    var workspaceID: UUID
    var missionRunID: UUID
    var runID: UUID
    var runRequestSHA256: String
    var resultRevision: Int
    var resultSHA256: String
    var attempt: Int
    var overallResult: EvalOverallResult
    var executionAuthorizationID: UUID
    var executionPolicySHA256: String
    var datasetManifestSHA256: String
    var evaluatorID: String
    var evaluatorVersion: String
    var modelVersion: String
    var productionReadinessReportID: UUID
    var productionReadinessReportRevision: Int
    var productionReadinessReportSHA256: String
    var aiEvalPlanID: UUID
    var aiEvalPlanRevision: Int
    var aiEvalPlanSHA256: String
    var readinessSourceBinding: ProductionReadinessSourceBinding
    var createdAt: Date
    var expiresAt: Date
    var consumedAt: Date?
    var authorizationSHA256: String

    var id: UUID { authorizationID }
    var isConsumed: Bool { consumedAt != nil }
    var isSelfValidating: Bool {
        !authorizationSHA256.isEmpty
            && authorizationSHA256 == ControlledEvalDigest.resultReviewAuthorizationSHA256(self)
            && readinessSourceBinding.isSelfValidating
            && workspaceID == currentSessionAuthority.workspaceID
            && workspaceID == readinessSourceBinding.workspaceID
            && missionRunID == readinessSourceBinding.missionRunID
            && resultRevision > 0
            && !resultSHA256.isEmpty
    }

    func isAvailable(at date: Date) -> Bool {
        isSelfValidating && !isConsumed && date <= expiresAt
    }
}

enum ControlledEvalResultReviewEligibilityState: String, Codable, Hashable, Sendable {
    case currentAuthorizationReview = "CURRENT_AUTHORIZATION_REVIEW"
    case reauthorizationReview = "REAUTHORIZATION_REVIEW"
    case finalDecisionReview = "FINAL_DECISION_REVIEW"
    case finalizedReadOnly = "FINALIZED_READ_ONLY"
    case blocker = "BLOCKER"
}

struct ControlledEvalResultReviewEligibility: Codable, Hashable, Sendable {
    var state: ControlledEvalResultReviewEligibilityState
    var proposal: ControlledEvalResultReviewProposal?
    var authorization: ControlledEvalResultReviewAuthorization?
    var blockerReason: String?

    static func currentAuthorizationReview(
        _ proposal: ControlledEvalResultReviewProposal
    ) -> ControlledEvalResultReviewEligibility {
        .init(state: .currentAuthorizationReview, proposal: proposal, authorization: nil, blockerReason: nil)
    }

    static func reauthorizationReview(
        _ proposal: ControlledEvalResultReviewProposal
    ) -> ControlledEvalResultReviewEligibility {
        .init(state: .reauthorizationReview, proposal: proposal, authorization: nil, blockerReason: nil)
    }

    static func finalDecisionReview(
        proposal: ControlledEvalResultReviewProposal,
        authorization: ControlledEvalResultReviewAuthorization
    ) -> ControlledEvalResultReviewEligibility {
        .init(state: .finalDecisionReview, proposal: proposal, authorization: authorization, blockerReason: nil)
    }

    static func finalizedReadOnly() -> ControlledEvalResultReviewEligibility {
        .init(state: .finalizedReadOnly, proposal: nil, authorization: nil, blockerReason: nil)
    }

    static func blocker(_ reason: String) -> ControlledEvalResultReviewEligibility {
        .init(state: .blocker, proposal: nil, authorization: nil, blockerReason: reason)
    }
}

enum ControlledEvalExecutionEligibilityState: String, Codable, Hashable, Sendable {
    case currentAuthorizationReview = "CURRENT_AUTHORIZATION_REVIEW"
    case reauthorizationReview = "REAUTHORIZATION_REVIEW"
    case finalExecutionReview = "FINAL_EXECUTION_REVIEW"
    case blocker = "BLOCKER"
}

struct ControlledEvalExecutionEligibility: Codable, Hashable, Sendable {
    var state: ControlledEvalExecutionEligibilityState
    var proposal: ControlledEvalExecutionProposal?
    var authorization: ControlledEvalExecutionAuthorization?
    var blockerReason: String?

    static func currentAuthorizationReview(
        _ proposal: ControlledEvalExecutionProposal
    ) -> ControlledEvalExecutionEligibility {
        ControlledEvalExecutionEligibility(
            state: .currentAuthorizationReview,
            proposal: proposal,
            authorization: nil,
            blockerReason: nil
        )
    }

    static func reauthorizationReview(
        _ proposal: ControlledEvalExecutionProposal
    ) -> ControlledEvalExecutionEligibility {
        ControlledEvalExecutionEligibility(
            state: .reauthorizationReview,
            proposal: proposal,
            authorization: nil,
            blockerReason: nil
        )
    }

    static func finalExecutionReview(
        proposal: ControlledEvalExecutionProposal,
        authorization: ControlledEvalExecutionAuthorization
    ) -> ControlledEvalExecutionEligibility {
        ControlledEvalExecutionEligibility(
            state: .finalExecutionReview,
            proposal: proposal,
            authorization: authorization,
            blockerReason: nil
        )
    }

    static func blocker(_ reason: String) -> ControlledEvalExecutionEligibility {
        ControlledEvalExecutionEligibility(
            state: .blocker,
            proposal: nil,
            authorization: nil,
            blockerReason: reason
        )
    }
}

struct EvalMetricObservation: Codable, Hashable, Sendable, Identifiable {
    var observationID: String
    var metricID: String
    var scenarioID: String
    var caseID: String
    var numeratorContribution: Double?
    var denominatorContribution: Double?
    var observedValue: Double?
    var evidenceReferences: [String]
    var evaluatorVersion: String
    var deterministicSHA256: String

    var id: String { observationID }
}

struct EvalMetricResult: Codable, Hashable, Sendable, Identifiable {
    var metricID: String
    var scenarioID: String
    var numerator: Double?
    var denominator: Double?
    var observedValue: Double?
    var proposedThreshold: String
    var outcome: EvalMetricOutcome
    var evidenceReferences: [String]
    var evaluatorVersion: String
    var deterministicSHA256: String

    var id: String { "\(scenarioID):\(metricID)" }
}

struct EvalFailureRecord: Codable, Hashable, Sendable, Identifiable {
    var failureID: UUID
    var kind: EvalFailureKind
    var scenarioID: String?
    var caseID: String?
    var metricID: String?
    var summary: String
    var isCritical: Bool
    var evidenceReferences: [String]
    var recordedAt: Date

    var id: UUID { failureID }
}

struct EvalExecutionEvidence: Codable, Hashable, Sendable, Identifiable {
    var evidenceID: String
    var scenarioID: String
    var caseID: String
    var sourceKind: String
    var sourceSHA256: String
    var summary: String
    var limitations: String

    var id: String { evidenceID }
}

struct EvalScenarioResult: Codable, Hashable, Sendable, Identifiable {
    var scenarioID: String
    var caseID: String
    var expectedBehavior: [String]
    var actualBehavior: String?
    var deterministicOutput: String?
    var outcome: EvalScenarioOutcome
    var metricObservations: [EvalMetricObservation]
    var evidenceReferences: [String]
    var failureIDs: [UUID]
    var evaluatorID: String
    var evaluatorVersion: String
    var deterministicSHA256: String

    var id: String { "\(scenarioID):\(caseID)" }
}

struct EvalScenarioExecution: Codable, Hashable, Sendable, Identifiable {
    var executionID: UUID
    var scenarioID: String
    var attempt: Int
    var startedAt: Date?
    var endedAt: Date?
    var durationMilliseconds: Int?
    var results: [EvalScenarioResult]
    var outcome: EvalScenarioOutcome
    var unexecutedCaseIDs: [String]

    var id: UUID { executionID }
}

struct EvalRunDigest: Codable, Hashable, Sendable {
    var algorithm: String
    var canonicalSerializationVersion: Int
    var sha256: String

    static let empty = EvalRunDigest(
        algorithm: "SHA-256",
        canonicalSerializationVersion: 1,
        sha256: ""
    )
}

struct EvalRunRevision: Codable, Hashable, Sendable, Identifiable {
    var runID: UUID
    var revision: Int
    var attempt: Int
    var state: EvalRunState
    var overallResult: EvalOverallResult
    var scenarioExecutions: [EvalScenarioExecution]
    var metricResults: [EvalMetricResult]
    var failures: [EvalFailureRecord]
    var evidence: [EvalExecutionEvidence]
    var startedAt: Date?
    var endedAt: Date?
    var durationMilliseconds: Int?
    var tokenEstimate: Int
    var estimatedCost: Double
    var unexecutedScenarioIDs: [String]
    var digest: EvalRunDigest
    var createdAt: Date

    var id: String { "\(runID.uuidString.lowercased()):\(revision)" }
}

struct EvalRunReviewDecision: Codable, Hashable, Sendable, Identifiable {
    var decisionID: UUID
    var runID: UUID
    var runRevision: Int
    var runSHA256: String
    var attempt: Int
    var stage: EvalRunReviewStage
    var decision: EvalRunReviewDecisionKind
    var reviewerInstructions: String?
    var approvalScope: String
    var authenticatedLocalSessionID: UUID
    var workspaceSessionID: UUID
    var appSessionID: UUID
    var resultReviewAuthorizationID: UUID? = nil
    var resultReviewConfirmationID: UUID? = nil
    var executionPolicySHA256: String? = nil
    var datasetManifestSHA256: String? = nil
    var evaluatorID: String? = nil
    var evaluatorVersion: String? = nil
    var modelVersion: String? = nil
    var decidedAt: Date
    var decisionSHA256: String

    var id: UUID { decisionID }
    var isSelfValidating: Bool {
        !decisionSHA256.isEmpty
            && decisionSHA256 == ControlledEvalDigest.evalReviewDecisionSHA256(self)
    }
}

struct EvalRunActivityEvent: Codable, Hashable, Sendable, Identifiable {
    var eventID: UUID
    var runID: UUID
    var runRevision: Int
    var attempt: Int
    var state: EvalRunState
    var summary: String
    var occurredAt: Date
    var eventSHA256: String

    var id: UUID { eventID }
    var isSelfValidating: Bool {
        !eventSHA256.isEmpty
            && eventSHA256 == ControlledEvalDigest.activityEventSHA256(self)
    }
}

struct EvalRunRestorationFailure: Codable, Hashable, Sendable, Identifiable {
    var failureID: UUID
    var runID: UUID?
    var workspaceID: UUID?
    var missionRunID: UUID?
    var kind: EvalRunRestorationFailureKind
    var summary: String
    var failedClosedAt: Date
    var failureSHA256: String

    var id: UUID { failureID }
    var isSelfValidating: Bool {
        !failureSHA256.isEmpty
            && failureSHA256 == ControlledEvalDigest.restorationFailureSHA256(self)
    }
}

struct EvalRun: Codable, Hashable, Sendable, Identifiable {
    var runID: UUID
    var request: ControlledEvalExecutionRequest
    var revisions: [EvalRunRevision]
    var reviewDecisions: [EvalRunReviewDecision]
    var activityEvents: [EvalRunActivityEvent]
    var restorationFailures: [EvalRunRestorationFailure]
    var createdAt: Date
    var updatedAt: Date

    var id: UUID { runID }
    var currentRevision: EvalRunRevision? { revisions.max { $0.revision < $1.revision } }
    var currentState: EvalRunState? {
        guard let revision = currentRevision else { return nil }
        guard revision.state == .resultsAwaitingReview,
              let decision = reviewDecision(stage: .results, attempt: revision.attempt) else {
            return revision.state
        }
        return switch decision.decision {
        case .approveResults: .resultsApproved
        case .requestChanges: .resultsChangeRequested
        case .rejectResults: .resultsRejected
        case .approveExecution: revision.state
        }
    }
    var overallResult: EvalOverallResult { currentRevision?.overallResult ?? .notExecuted }
    var productionApprovalGranted: Bool { false }
    var deploymentAuthorized: Bool { false }
    var phase3BAvailable: Bool { false }

    func reviewDecision(stage: EvalRunReviewStage, attempt: Int) -> EvalRunReviewDecision? {
        reviewDecisions.first { $0.stage == stage && $0.attempt == attempt }
    }
}

struct ControlledEvalExecutionContext: Codable, Hashable, Sendable {
    var missionRunID: UUID
    var workspaceID: UUID
    var authenticatedLocalSessionID: UUID
    var workspaceSessionID: UUID
    var appSessionID: UUID
}

struct ControlledEvalSessionAuthority: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var authenticatedLocalSessionID: UUID
    var workspaceSessionID: UUID
    var appSessionID: UUID

    func context(missionRunID: UUID) -> ControlledEvalExecutionContext {
        ControlledEvalExecutionContext(
            missionRunID: missionRunID,
            workspaceID: workspaceID,
            authenticatedLocalSessionID: authenticatedLocalSessionID,
            workspaceSessionID: workspaceSessionID,
            appSessionID: appSessionID
        )
    }
}

struct ControlledEvalSafetyCounters: Codable, Hashable, Sendable {
    var deterministicFixtureExecutions = 0
    var legacyWrites = 0
    var sandboxWrites = 0
    var candidatePatchMutations = 0
    var generatedSourceWrites = 0
    var shellOperations = 0
    var gitOperations = 0
    var packageManagerOperations = 0
    var buildOperations = 0
    var testOperations = 0
    var deploymentOperations = 0
    var infrastructureOperations = 0
    var credentialAccesses = 0
    var productionAccesses = 0
    var networkOperations = 0
    var arbitraryToolOperations = 0

    var hasZeroExternalAuthority: Bool {
        legacyWrites == 0
            && sandboxWrites == 0
            && candidatePatchMutations == 0
            && generatedSourceWrites == 0
            && shellOperations == 0
            && gitOperations == 0
            && packageManagerOperations == 0
            && buildOperations == 0
            && testOperations == 0
            && deploymentOperations == 0
            && infrastructureOperations == 0
            && credentialAccesses == 0
            && productionAccesses == 0
            && networkOperations == 0
            && arbitraryToolOperations == 0
    }
}

enum ControlledEvalFailure: String, Error, Codable, Hashable, Sendable {
    case exactApprovedPhase3APairRequired = "EXACT_APPROVED_PHASE_3A_PAIR_REQUIRED"
    case executionApprovalRequired = "EXECUTION_APPROVAL_REQUIRED"
    case authorityMismatch = "AUTHORITY_MISMATCH"
    case revisionMismatch = "REVISION_MISMATCH"
    case digestMismatch = "DIGEST_MISMATCH"
    case sessionMismatch = "SESSION_MISMATCH"
    case executionAuthorizationRequired = "EXECUTION_AUTHORIZATION_REQUIRED"
    case executionAuthorizationStale = "EXECUTION_AUTHORIZATION_STALE"
    case scenarioNotApproved = "SCENARIO_NOT_APPROVED"
    case metricNotApproved = "METRIC_NOT_APPROVED"
    case datasetDrift = "DATASET_DRIFT"
    case datasetLimitExceeded = "DATASET_LIMIT_EXCEEDED"
    case providerMismatch = "PROVIDER_MISMATCH"
    case policyViolation = "POLICY_VIOLATION"
    case runtimeLimitExceeded = "RUNTIME_LIMIT_EXCEEDED"
    case tokenLimitExceeded = "TOKEN_LIMIT_EXCEEDED"
    case costLimitExceeded = "COST_LIMIT_EXCEEDED"
    case duplicateAction = "DUPLICATE_ACTION"
    case invalidStateTransition = "INVALID_STATE_TRANSITION"
    case reviewAuthorityUnavailable = "REVIEW_AUTHORITY_UNAVAILABLE"
    case revisionImmutable = "REVISION_IMMUTABLE"
    case artifactPersistenceInvalid = "ARTIFACT_PERSISTENCE_INVALID"
    case cancelled = "CANCELLED"
}
