import Foundation

enum ProductionReadinessArea: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case identityAndAuthentication = "IDENTITY_AND_AUTHENTICATION"
    case authorizationAndTenantBoundaries = "AUTHORIZATION_AND_TENANT_BOUNDARIES"
    case sensitiveDataHandling = "SENSITIVE_DATA_HANDLING"
    case responseAllowlistsAndDataMinimization = "RESPONSE_ALLOWLISTS_AND_DATA_MINIMIZATION"
    case promptAndInstructionBoundaries = "PROMPT_AND_INSTRUCTION_BOUNDARIES"
    case toolAndActionPermissions = "TOOL_AND_ACTION_PERMISSIONS"
    case humanApprovalAndEscalation = "HUMAN_APPROVAL_AND_ESCALATION"
    case failureHandlingAndGracefulDegradation = "FAILURE_HANDLING_AND_GRACEFUL_DEGRADATION"
    case observabilityAndAuditLogging = "OBSERVABILITY_AND_AUDIT_LOGGING"
    case rateLimitsLatencyAndCostControls = "RATE_LIMITS_LATENCY_AND_COST_CONTROLS"
    case modelVersionConfiguration = "MODEL_VERSION_CONFIGURATION"
    case environmentAndConfigurationSeparation = "ENVIRONMENT_AND_CONFIGURATION_SEPARATION"
    case rollbackAndIncidentResponse = "ROLLBACK_AND_INCIDENT_RESPONSE"
    case operationalOwnership = "OPERATIONAL_OWNERSHIP"
    case securityAndComplianceUnknowns = "SECURITY_AND_COMPLIANCE_UNKNOWNS"
    case deploymentPrerequisites = "DEPLOYMENT_PREREQUISITES"
    case adoptionAndSupportPrerequisites = "ADOPTION_AND_SUPPORT_PREREQUISITES"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .identityAndAuthentication: "Identity and authentication"
        case .authorizationAndTenantBoundaries: "Authorization and tenant boundaries"
        case .sensitiveDataHandling: "Sensitive-data handling"
        case .responseAllowlistsAndDataMinimization: "Response allowlists and data minimization"
        case .promptAndInstructionBoundaries: "Prompt and instruction boundaries"
        case .toolAndActionPermissions: "Tool and action permissions"
        case .humanApprovalAndEscalation: "Human approval and escalation"
        case .failureHandlingAndGracefulDegradation: "Failure handling and graceful degradation"
        case .observabilityAndAuditLogging: "Observability and audit logging"
        case .rateLimitsLatencyAndCostControls: "Rate limits, latency, and cost controls"
        case .modelVersionConfiguration: "Model/version configuration"
        case .environmentAndConfigurationSeparation: "Environment and configuration separation"
        case .rollbackAndIncidentResponse: "Rollback and incident response"
        case .operationalOwnership: "Operational ownership"
        case .securityAndComplianceUnknowns: "Security and compliance unknowns"
        case .deploymentPrerequisites: "Deployment prerequisites"
        case .adoptionAndSupportPrerequisites: "Adoption and support prerequisites"
        }
    }
}

enum ProductionReadinessFindingStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case ready = "READY"
    case partial = "PARTIAL"
    case blocked = "BLOCKED"
    case unknown = "UNKNOWN"
    case notApplicable = "NOT_APPLICABLE"
}

enum ProductionReadinessSeverity: String, Codable, CaseIterable, Hashable, Sendable {
    case informational = "INFORMATIONAL"
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
    case critical = "CRITICAL"
}

enum ProductionReadinessEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case confirmed = "CONFIRMED_EVIDENCE"
    case proposedVerification = "PROPOSED_VERIFICATION"
    case unknown = "UNKNOWN"
    case notExecuted = "NOT_EXECUTED"
}

enum ProductionReadinessVerificationState: String, Codable, CaseIterable, Hashable, Sendable {
    case confirmed = "CONFIRMED"
    case proposedNotExecuted = "PROPOSED_NOT_EXECUTED"
    case unknown = "UNKNOWN"
    case notExecuted = "NOT_EXECUTED"
}

enum ProductionReadinessOverallResult: String, Codable, CaseIterable, Hashable, Sendable {
    case notReady = "NOT_READY"
    case conditionallyReady = "CONDITIONALLY_READY"
    case readyForControlledValidation = "READY_FOR_CONTROLLED_VALIDATION"
    case clarificationRequired = "CLARIFICATION_REQUIRED"
}

enum ProductionReadinessGateStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case evidenceRequired = "EVIDENCE_REQUIRED"
    case blocked = "BLOCKED"
    case readyForFutureVerification = "READY_FOR_FUTURE_VERIFICATION"
    case passed = "PASSED"
}

enum ProductionReadinessGateClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case blocking = "BLOCKING"
    case nonBlocking = "NON_BLOCKING"
}

enum ProductionReadinessReviewDecisionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case approvePlan = "APPROVE_PLAN"
    case requestChanges = "REQUEST_CHANGES"
    case reject = "REJECT"
}

struct ProductionReadinessEvidence: Codable, Hashable, Sendable, Identifiable {
    var evidenceID: String
    var kind: ProductionReadinessEvidenceKind
    var sourceArtifactType: String
    var sourceArtifactID: String
    var sourceArtifactRevision: Int?
    var sourceSHA256: String
    var claim: String
    var limitations: String

    var id: String { evidenceID }
}

struct ProductionReadinessFinding: Codable, Hashable, Sendable, Identifiable {
    var findingID: String
    var area: ProductionReadinessArea
    var status: ProductionReadinessFindingStatus
    var severity: ProductionReadinessSeverity
    var summary: String
    var requirement: String
    var supportingEvidence: [ProductionReadinessEvidence]
    var remainingUnknown: String
    var recommendedNextAction: String
    var proposedReleaseGateID: String
    var confidence: Double
    var verificationState: ProductionReadinessVerificationState

    var id: String { findingID }
}

struct ProductionReadinessSection: Codable, Hashable, Sendable, Identifiable {
    var area: ProductionReadinessArea
    var title: String
    var findingIDs: [String]

    var id: String { area.rawValue }
}

struct ProductionReadinessBlocker: Codable, Hashable, Sendable, Identifiable {
    var blockerID: String
    var findingID: String
    var summary: String
    var requiredAction: String
    var releaseGateID: String

    var id: String { blockerID }
}

struct ProductionReadinessGate: Codable, Hashable, Sendable, Identifiable {
    var gateID: String
    var category: String
    var condition: String
    var currentStatus: ProductionReadinessGateStatus
    var evidenceRequired: [String]
    var ownerPlaceholder: String
    var classification: ProductionReadinessGateClassification
    var futureVerificationMethod: String
    var passedEvidenceIDs: [String]

    var id: String { gateID }
}

struct ProductionReadinessSourceBinding: Codable, Hashable, Sendable {
    var missionRunID: UUID
    var workspaceID: UUID
    var canonicalLegacyRoot: String
    var sourceSnapshotID: String
    var assessmentID: String
    var assessmentSHA256: String
    var sourceCandidatePatchTaskID: UUID
    var candidatePatchID: CandidatePatchID
    var candidatePatchPlanID: UUID
    var candidatePatchPlanRevision: Int
    var candidatePatchManifestID: String
    var candidatePatchArtifactSHA256: String
    var candidatePatchApprovalProvenanceSHA256: String
    var candidatePatchReviewOutcome: String
    var sandboxID: SandboxID
    var sandboxLifecycle: String
    var generatedTestPlanningTaskID: UUID
    var generatedTestPlanID: UUID
    var generatedTestPlanRevision: Int
    var generatedTestPlanSHA256: String
    var generatedTestArtifactID: UUID
    var generatedTestArtifactRevision: Int
    var generatedTestArtifactSHA256: String
    var generatedTestArtifactReviewOutcome: String
    var cleanupStatus: String?
    var normalizedCapabilityID: String
    var capabilityDisplayLabel: String
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
    var sourceBindingSHA256: String

    var canonicalDigest: String {
        CandidatePatchArtifactAuthority.digest([
            ("mission_run_id", missionRunID.uuidString.lowercased()),
            ("workspace_id", workspaceID.uuidString.lowercased()),
            ("canonical_legacy_root", canonicalLegacyRoot),
            ("source_snapshot_id", sourceSnapshotID),
            ("assessment_id", assessmentID),
            ("assessment_sha256", assessmentSHA256),
            ("source_candidate_patch_task_id", sourceCandidatePatchTaskID.uuidString.lowercased()),
            ("candidate_patch_id", candidatePatchID.rawValue),
            ("candidate_patch_plan_id", candidatePatchPlanID.uuidString.lowercased()),
            ("candidate_patch_plan_revision", String(candidatePatchPlanRevision)),
            ("candidate_patch_manifest_id", candidatePatchManifestID),
            ("candidate_patch_artifact_sha256", candidatePatchArtifactSHA256),
            ("candidate_patch_approval_provenance_sha256", candidatePatchApprovalProvenanceSHA256),
            ("candidate_patch_review_outcome", candidatePatchReviewOutcome),
            ("sandbox_id", sandboxID.rawValue),
            ("sandbox_lifecycle", sandboxLifecycle),
            ("generated_test_planning_task_id", generatedTestPlanningTaskID.uuidString.lowercased()),
            ("generated_test_plan_id", generatedTestPlanID.uuidString.lowercased()),
            ("generated_test_plan_revision", String(generatedTestPlanRevision)),
            ("generated_test_plan_sha256", generatedTestPlanSHA256),
            ("generated_test_artifact_id", generatedTestArtifactID.uuidString.lowercased()),
            ("generated_test_artifact_revision", String(generatedTestArtifactRevision)),
            ("generated_test_artifact_sha256", generatedTestArtifactSHA256),
            ("generated_test_artifact_review_outcome", generatedTestArtifactReviewOutcome),
            ("cleanup_status", cleanupStatus ?? "NOT_STARTED"),
            ("normalized_capability_id", normalizedCapabilityID),
            ("capability_display_label", capabilityDisplayLabel),
            ("authenticated_local_session_id", authenticatedLocalSessionID.uuidString.lowercased()),
            ("app_session_id", appSessionID.uuidString.lowercased())
        ])
    }

    var isSelfValidating: Bool { sourceBindingSHA256 == canonicalDigest }
}

struct ProductionReadinessDigest: Codable, Hashable, Sendable {
    var algorithm: String
    var canonicalSerializationVersion: Int
    var sha256: String

    static let empty = ProductionReadinessDigest(
        algorithm: "SHA-256",
        canonicalSerializationVersion: 1,
        sha256: ""
    )
}

struct ProductionReadinessReportRevision: Codable, Hashable, Sendable, Identifiable {
    var reportID: UUID
    var revision: Int
    var overallResult: ProductionReadinessOverallResult
    var sections: [ProductionReadinessSection]
    var findings: [ProductionReadinessFinding]
    var blockers: [ProductionReadinessBlocker]
    var releaseGates: [ProductionReadinessGate]
    var reviewInstructionSHA256: String?
    var digest: ProductionReadinessDigest
    var createdAt: Date

    var id: String { "\(reportID.uuidString.lowercased()):\(revision)" }
    var unknownCount: Int { findings.filter { $0.status == .unknown }.count }
    var requiredActionCount: Int { findings.filter { $0.status != .ready && $0.status != .notApplicable }.count }
}

struct ProductionReadinessReviewDecision: Codable, Hashable, Sendable, Identifiable {
    var decisionID: UUID
    var reportID: UUID
    var reportRevision: Int
    var reportSHA256: String
    var decision: ProductionReadinessReviewDecisionKind
    var reviewerInstructions: String?
    var approvalScope: String
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
    var decidedAt: Date

    var id: UUID { decisionID }
}

struct ProductionReadinessReport: Codable, Hashable, Sendable, Identifiable {
    var reportID: UUID
    var sourceBinding: ProductionReadinessSourceBinding
    var revisions: [ProductionReadinessReportRevision]
    var reviewDecisions: [ProductionReadinessReviewDecision]
    var createdAt: Date
    var updatedAt: Date

    var id: UUID { reportID }
    var currentRevision: ProductionReadinessReportRevision? { revisions.max { $0.revision < $1.revision } }
    var overallResult: ProductionReadinessOverallResult? { currentRevision?.overallResult }
    var productionExecutionAuthorized: Bool { false }
    var deploymentAuthorized: Bool { false }

    func reviewDecision(for revision: Int) -> ProductionReadinessReviewDecision? {
        reviewDecisions.first { $0.reportRevision == revision }
    }
}

enum AIEvalScenarioGroup: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case happyPathTaskCompletion = "HAPPY_PATH_TASK_COMPLETION"
    case recordLevelAuthorization = "RECORD_LEVEL_AUTHORIZATION"
    case crossCustomerAndCrossTenantDenial = "CROSS_CUSTOMER_AND_CROSS_TENANT_DENIAL"
    case sensitiveFieldDisclosure = "SENSITIVE_FIELD_DISCLOSURE"
    case promptInjection = "PROMPT_INJECTION"
    case toolMisuseOrUnauthorizedAction = "TOOL_MISUSE_OR_UNAUTHORIZED_ACTION"
    case hallucinatedRecords = "HALLUCINATED_RECORDS"
    case missingOrAmbiguousData = "MISSING_OR_AMBIGUOUS_DATA"
    case modelRefusalCorrectness = "MODEL_REFUSAL_CORRECTNESS"
    case humanEscalation = "HUMAN_ESCALATION"
    case auditLogCorrectness = "AUDIT_LOG_CORRECTNESS"
    case readOnlyBehavior = "READ_ONLY_BEHAVIOR"
    case latencyExpectations = "LATENCY_EXPECTATIONS"
    case costTokenExpectations = "COST_TOKEN_EXPECTATIONS"
    case failureRecovery = "FAILURE_RECOVERY"
    case modelVersionRegression = "MODEL_VERSION_REGRESSION"
    case adversarialOrMalformedInputs = "ADVERSARIAL_OR_MALFORMED_INPUTS"

    var id: String { rawValue }

    var title: String {
        rawValue.replacingOccurrences(of: "_", with: " ").lowercased().localizedCapitalized
    }
}

enum AIEvalVerificationState: String, Codable, CaseIterable, Hashable, Sendable {
    case plannedNotExecuted = "PLANNED_NOT_EXECUTED"
}

enum AIEvalFailureCategory: String, Codable, CaseIterable, Hashable, Sendable, Identifiable {
    case authorizationFailure = "AUTHORIZATION_FAILURE"
    case tenantBoundaryViolation = "TENANT_BOUNDARY_VIOLATION"
    case sensitiveDataExposure = "SENSITIVE_DATA_EXPOSURE"
    case hallucinatedRecord = "HALLUCINATED_RECORD"
    case invalidToolAction = "INVALID_TOOL_ACTION"
    case promptInjectionSuccess = "PROMPT_INJECTION_SUCCESS"
    case incorrectRefusal = "INCORRECT_REFUSAL"
    case missingHumanEscalation = "MISSING_HUMAN_ESCALATION"
    case auditFailure = "AUDIT_FAILURE"
    case responseSchemaFailure = "RESPONSE_SCHEMA_FAILURE"
    case latencyThresholdExceeded = "LATENCY_THRESHOLD_EXCEEDED"
    case costThresholdExceeded = "COST_THRESHOLD_EXCEEDED"
    case modelRegression = "MODEL_REGRESSION"
    case configurationDrift = "CONFIGURATION_DRIFT"
    case unknownFailure = "UNKNOWN_FAILURE"

    var id: String { rawValue }
}

struct AIEvalSourceBinding: Codable, Hashable, Sendable {
    var readinessSourceBinding: ProductionReadinessSourceBinding
    var sourceBindingSHA256: String

    var canonicalDigest: String {
        CandidatePatchArtifactAuthority.digest([
            ("artifact_type", "AI_EVAL_PLAN"),
            ("readiness_source_binding_sha256", readinessSourceBinding.sourceBindingSHA256)
        ])
    }

    var isSelfValidating: Bool {
        readinessSourceBinding.isSelfValidating && sourceBindingSHA256 == canonicalDigest
    }
}

struct AIEvalScenario: Codable, Hashable, Sendable, Identifiable {
    var scenarioID: String
    var group: AIEvalScenarioGroup
    var title: String
    var businessPurpose: String
    var inputDescription: String
    var preconditions: [String]
    var expectedBehavior: [String]
    var prohibitedBehavior: [String]
    var requiredEvidence: [String]
    var metricBindings: [String]
    var failureCategories: [AIEvalFailureCategory]
    var sourceEvidence: [ProductionReadinessEvidence]
    var verificationState: AIEvalVerificationState

    var id: String { scenarioID }
}

struct AIEvalDatasetRequirement: Codable, Hashable, Sendable, Identifiable {
    var datasetRequirementID: String
    var title: String
    var purpose: String
    var requiredCoverage: [String]
    var sensitiveDataPolicy: String
    var status: String
    var missingEvidence: [String]

    var id: String { datasetRequirementID }
}

struct AIEvalMetric: Codable, Hashable, Sendable, Identifiable {
    var metricID: String
    var name: String
    var definition: String
    var calculationMethod: String
    var proposedThreshold: String
    var requiredDatasetID: String
    var missingEvidence: [String]
    var actualResult: String?

    var id: String { metricID }
}

struct AIEvalReleaseGate: Codable, Hashable, Sendable, Identifiable {
    var gateID: String
    var condition: String
    var metricIDs: [String]
    var proposedThresholds: [String]
    var currentStatus: String
    var requiredEvidence: [String]
    var futureVerificationMethod: String

    var id: String { gateID }
}

struct AIEvalPlanDigest: Codable, Hashable, Sendable {
    var algorithm: String
    var canonicalSerializationVersion: Int
    var sha256: String

    static let empty = AIEvalPlanDigest(
        algorithm: "SHA-256",
        canonicalSerializationVersion: 1,
        sha256: ""
    )
}

struct AIEvalPlanRevision: Codable, Hashable, Sendable, Identifiable {
    var planID: UUID
    var revision: Int
    var scenarios: [AIEvalScenario]
    var datasetRequirements: [AIEvalDatasetRequirement]
    var metrics: [AIEvalMetric]
    var failureTaxonomy: [AIEvalFailureCategory]
    var releaseGates: [AIEvalReleaseGate]
    var reviewInstructionSHA256: String?
    var digest: AIEvalPlanDigest
    var createdAt: Date

    var id: String { "\(planID.uuidString.lowercased()):\(revision)" }
}

struct AIEvalReviewDecision: Codable, Hashable, Sendable, Identifiable {
    var decisionID: UUID
    var planID: UUID
    var planRevision: Int
    var planSHA256: String
    var decision: ProductionReadinessReviewDecisionKind
    var reviewerInstructions: String?
    var approvalScope: String
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
    var decidedAt: Date

    var id: UUID { decisionID }
}

struct AIEvalPlan: Codable, Hashable, Sendable, Identifiable {
    var planID: UUID
    var sourceBinding: AIEvalSourceBinding
    var revisions: [AIEvalPlanRevision]
    var reviewDecisions: [AIEvalReviewDecision]
    var createdAt: Date
    var updatedAt: Date

    var id: UUID { planID }
    var currentRevision: AIEvalPlanRevision? { revisions.max { $0.revision < $1.revision } }
    var evalExecutionAvailable: Bool { false }
    var productionRolloutAvailable: Bool { false }

    func reviewDecision(for revision: Int) -> AIEvalReviewDecision? {
        reviewDecisions.first { $0.planRevision == revision }
    }
}

struct ProductionReadinessSafetyCounters: Codable, Hashable, Sendable {
    var legacyWrites = 0
    var sandboxWrites = 0
    var candidatePatchMutations = 0
    var generatedSourceWrites = 0
    var evalExecutions = 0
    var modelBenchmarkExecutions = 0
    var syntaxChecks = 0
    var buildExecutions = 0
    var testExecutions = 0
    var shellOperations = 0
    var gitOperations = 0
    var packageManagerOperations = 0
    var deploymentOperations = 0
    var credentialAccesses = 0
    var productionAccesses = 0

    var hasZeroExecutionAuthority: Bool {
        self == ProductionReadinessSafetyCounters()
    }
}

struct ProductionReadinessReviewContext: Hashable, Sendable {
    var missionRunID: UUID
    var workspaceID: UUID
    var artifactID: UUID
    var revision: Int
    var artifactSHA256: String
    var authenticatedLocalSessionID: UUID
    var appSessionID: UUID
}

struct ProductionReadinessReviewEligibility: Equatable, Sendable {
    var isAvailable: Bool
    var unavailableReason: String?

    static let available = ProductionReadinessReviewEligibility(isAvailable: true, unavailableReason: nil)

    static func unavailable(_ reason: String) -> ProductionReadinessReviewEligibility {
        ProductionReadinessReviewEligibility(isAvailable: false, unavailableReason: reason)
    }
}

enum ProductionReadinessFailure: String, Error, Codable, Hashable, Sendable {
    case exactSourceBindingRequired = "EXACT_SOURCE_BINDING_REQUIRED"
    case sourceBindingContradiction = "SOURCE_BINDING_CONTRADICTION"
    case parentMissionNotReady = "PARENT_MISSION_NOT_READY"
    case artifactDigestMismatch = "ARTIFACT_DIGEST_MISMATCH"
    case artifactPersistenceInvalid = "ARTIFACT_PERSISTENCE_INVALID"
    case reviewAuthorityUnavailable = "REVIEW_AUTHORITY_UNAVAILABLE"
    case revisionImmutable = "REVISION_IMMUTABLE"
    case invalidClaim = "INVALID_CLAIM"
}
