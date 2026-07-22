import CryptoKit
import Foundation

/// The Phase 3B.3B verdict authority. `UNKNOWN` is intentionally separate from
/// the legacy Phase 2E three-state verdict so existing consumers and UI remain
/// source-compatible.
enum AssessmentExecutiveVerdict: String, Codable, CaseIterable, Hashable, Sendable {
    case yes = "YES"
    case partial = "PARTIAL"
    case no = "NO"
    case unknown = "UNKNOWN"

    init(_ legacyVerdict: AgentIntegrationVerdict) {
        switch legacyVerdict {
        case .yes: self = .yes
        case .partial: self = .partial
        case .no: self = .no
        }
    }

    var legacyVerdict: AgentIntegrationVerdict {
        switch self {
        case .yes: return .yes
        case .partial: return .partial
        case .no, .unknown: return .no
        }
    }
}

enum AssessmentReportClaimSection: String, Codable, CaseIterable, Hashable, Sendable {
    case executiveSummary = "EXECUTIVE_SUMMARY"
    case observedLegacyArchitecture = "OBSERVED_LEGACY_ARCHITECTURE"
    case candidateIntegrationSeam = "CANDIDATE_INTEGRATION_SEAM"
    case capabilityCompatibility = "CAPABILITY_COMPATIBILITY"
    case securityAndAuthorization = "SECURITY_AND_AUTHORIZATION"
    case risk = "RISK"
    case blocker = "BLOCKER"
    case unknown = "UNKNOWN"
    case recommendation = "RECOMMENDATION"

    fileprivate var rank: Int {
        Self.allCases.firstIndex(of: self) ?? Self.allCases.count
    }
}

enum AssessmentReportClaimDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case supported = "SUPPORTED"
    case partial = "PARTIAL"
    case incompatible = "INCOMPATIBLE"
    case blocked = "BLOCKED"
    case unknown = "UNKNOWN"
    case advisory = "ADVISORY"
}

enum AssessmentReportRiskDomain: String, Codable, CaseIterable, Hashable, Sendable {
    case dataAccess = "DATA_ACCESS"
    case permission = "PERMISSION"
    case modification = "MODIFICATION"
    case general = "GENERAL"
}

/// A caller-supplied placement for an already-created AssessmentClaim. It does
/// not create a conclusion: the claim statement and all facts remain immutable.
struct AssessmentReportClaimPlacement: Codable, Hashable, Sendable, Identifiable {
    var claim: AssessmentClaim
    var section: AssessmentReportClaimSection
    var disposition: AssessmentReportClaimDisposition
    var required: Bool
    var capability: LegacyArchitectureCapability?
    var riskLevel: AssessmentRiskLevel?
    var riskDomain: AssessmentReportRiskDomain?
    var blockerCategory: IntegrationBlockerCategory?
    var title: String?
    var integrationPath: [String]
    var architectureComponents: [String]

    var id: String {
        "\(claim.claimID):\(section.rawValue):\(capability?.rawValue ?? "none")"
    }

    init(
        claim: AssessmentClaim,
        section: AssessmentReportClaimSection,
        disposition: AssessmentReportClaimDisposition,
        required: Bool = false,
        capability: LegacyArchitectureCapability? = nil,
        riskLevel: AssessmentRiskLevel? = nil,
        riskDomain: AssessmentReportRiskDomain? = nil,
        blockerCategory: IntegrationBlockerCategory? = nil,
        title: String? = nil,
        integrationPath: [String] = [],
        architectureComponents: [String] = []
    ) {
        self.claim = claim
        self.section = section
        self.disposition = disposition
        self.required = required
        self.capability = capability
        self.riskLevel = riskLevel
        self.riskDomain = riskDomain
        self.blockerCategory = blockerCategory
        self.title = title
        self.integrationPath = integrationPath
        self.architectureComponents = architectureComponents
    }
}

struct AssessmentReportSectionEntry: Codable, Hashable, Sendable, Identifiable {
    var claimID: String
    var section: AssessmentReportClaimSection
    var disposition: AssessmentReportClaimDisposition
    var required: Bool
    var capability: LegacyArchitectureCapability?
    var riskLevel: AssessmentRiskLevel?
    var riskDomain: AssessmentReportRiskDomain?
    var blockerCategory: IntegrationBlockerCategory?
    var title: String?
    var integrationPath: [String]
    var architectureComponents: [String]

    var id: String {
        "\(claimID):\(section.rawValue):\(capability?.rawValue ?? "none")"
    }
}

struct AssessmentReportSections: Codable, Hashable, Sendable {
    var executiveSummary: [AssessmentReportSectionEntry]
    var observedLegacyArchitecture: [AssessmentReportSectionEntry]
    var candidateIntegrationSeams: [AssessmentReportSectionEntry]
    var capabilityCompatibilityMatrix: [AssessmentReportSectionEntry]
    var securityAndAuthorizationFindings: [AssessmentReportSectionEntry]
    var risks: [AssessmentReportSectionEntry]
    var blockers: [AssessmentReportSectionEntry]
    var unknowns: [AssessmentReportSectionEntry]
    var recommendations: [AssessmentReportSectionEntry]

    fileprivate init(entries: [AssessmentReportSectionEntry]) {
        executiveSummary = entries.filter { $0.section == .executiveSummary }
        observedLegacyArchitecture = entries.filter { $0.section == .observedLegacyArchitecture }
        candidateIntegrationSeams = entries.filter { $0.section == .candidateIntegrationSeam }
        capabilityCompatibilityMatrix = entries.filter { $0.section == .capabilityCompatibility }
        securityAndAuthorizationFindings = entries.filter { $0.section == .securityAndAuthorization }
        risks = entries.filter { $0.section == .risk }
        blockers = entries.filter { $0.section == .blocker }
        unknowns = entries.filter { $0.section == .unknown }
        recommendations = entries.filter { $0.section == .recommendation }
    }

    var allEntries: [AssessmentReportSectionEntry] {
        executiveSummary
            + observedLegacyArchitecture
            + candidateIntegrationSeams
            + capabilityCompatibilityMatrix
            + securityAndAuthorizationFindings
            + risks
            + blockers
            + unknowns
            + recommendations
    }
}

struct AssessmentReportBinding: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var taskID: UUID
    var sessionID: UUID
}

struct AssessmentReportExecutionProvenance: Codable, Hashable, Sendable {
    var executionEventIDs: [UUID]
    var sourceToolResultEventIDs: [UUID]
    var sourceToolCallIDs: [String]
    var evidenceLedgerSHA256: String
    var latestEventSequence: Int64
    var latestEventTimestamp: Date
}

struct AssessmentReportScope: Codable, Hashable, Sendable {
    var description: String
    var workspaceIdentities: [String]
    var relativePaths: [String]
    var requiredCapabilityIDs: [String]
    var includedClaimIDs: [String]
}

enum AssessmentReportClaimStatus: String, Codable, Hashable, Sendable {
    case validated = "VALIDATED"
}

struct AssessmentReportEvidenceAppendixEntry: Codable, Hashable, Sendable, Identifiable {
    var claim: AssessmentClaim
    var status: AssessmentReportClaimStatus
    var bindings: [AssessmentClaimEvidenceBinding]
    var sourceExecutionEventIDs: [UUID]
    var workspaceSnapshotIdentifiers: [String]

    var id: String { claim.claimID }
    var claimID: String { claim.claimID }
    var statement: String { claim.statement }
    var confidence: AssessmentClaimConfidence { claim.confidence }
    var evidenceReferences: [AssessmentEvidenceReference] { claim.evidence }
}

/// Optional prose from a language model. Proposed structured fields are audit
/// inputs only and are never applied to the report.
struct AssessmentReportExplanationDraft: Codable, Hashable, Sendable {
    var narrative: String
    var sourceClaimIDs: [String]
    var proposedVerdict: AssessmentExecutiveVerdict?
    var proposedConfidence: AssessmentClaimConfidence?
    var proposedClaims: [AssessmentClaim]
    var proposedRiskClaimIDs: [String]
    var unknownClaimIDsToOmit: [String]

    init(
        narrative: String,
        sourceClaimIDs: [String],
        proposedVerdict: AssessmentExecutiveVerdict? = nil,
        proposedConfidence: AssessmentClaimConfidence? = nil,
        proposedClaims: [AssessmentClaim] = [],
        proposedRiskClaimIDs: [String] = [],
        unknownClaimIDsToOmit: [String] = []
    ) {
        self.narrative = narrative
        self.sourceClaimIDs = sourceClaimIDs
        self.proposedVerdict = proposedVerdict
        self.proposedConfidence = proposedConfidence
        self.proposedClaims = proposedClaims
        self.proposedRiskClaimIDs = proposedRiskClaimIDs
        self.unknownClaimIDsToOmit = unknownClaimIDsToOmit
    }
}

struct AssessmentReportExplanation: Codable, Hashable, Sendable {
    var narrative: String
    var sourceClaimIDs: [String]
    var nonAuthoritative: Bool
}

enum AssessmentReportValidationFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case claimValidationFailed = "CLAIM_VALIDATION_FAILED"
    case conflictingClaimID = "CONFLICTING_CLAIM_ID"
    case missingExecutionEvent = "MISSING_EXECUTION_EVENT"
    case ambiguousExecutionEvent = "AMBIGUOUS_EXECUTION_EVENT"
    case executionEventWorkspaceMismatch = "EXECUTION_EVENT_WORKSPACE_MISMATCH"
    case executionEventTaskMismatch = "EXECUTION_EVENT_TASK_MISMATCH"
    case executionEventNotSuccessfulToolResult = "EXECUTION_EVENT_NOT_SUCCESSFUL_TOOL_RESULT"
    case evidenceWorkspaceMismatch = "EVIDENCE_WORKSPACE_MISMATCH"
    case invalidPlacement = "INVALID_PLACEMENT"
    case duplicateCompatibilityCapability = "DUPLICATE_COMPATIBILITY_CAPABILITY"
    case explanationAuthorityViolation = "EXPLANATION_AUTHORITY_VIOLATION"
    case explanationUnsupportedClaim = "EXPLANATION_UNSUPPORTED_CLAIM"
    case noValidatedClaim = "NO_VALIDATED_CLAIM"
}

struct AssessmentReportValidationFailure: Codable, Hashable, Sendable, Identifiable {
    var code: AssessmentReportValidationFailureCode
    var claimID: String?
    var claimValidationFailure: AssessmentClaimValidationFailure?
    var detail: String

    var id: String {
        "\(code.rawValue):\(claimID ?? "report"):\(claimValidationFailure?.rawValue ?? "none")"
    }
}

struct AssessmentReportComposition: Codable, Hashable, Sendable {
    static let schemaVersion = "3B.3B"

    var schemaVersion: String
    var reportID: String
    var binding: AssessmentReportBinding
    var executionProvenance: AssessmentReportExecutionProvenance
    var executiveVerdict: AssessmentExecutiveVerdict
    var confidence: AssessmentClaimConfidence
    var scope: AssessmentReportScope
    var sections: AssessmentReportSections
    var evidenceAppendix: [AssessmentReportEvidenceAppendixEntry]
    var validationFailures: [AssessmentReportValidationFailure]
    var excludedClaimIDs: [String]
    var explanation: AssessmentReportExplanation?
    var composedAt: Date
}

struct AssessmentReportCompositionContext: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var taskID: UUID
    var sessionID: UUID
    var requestedCapability: AgentCapabilityProfile
    var responseLanguage: ReadOnlyResponseLanguage
    var scopeDescription: String

    init(
        workspaceID: UUID,
        taskID: UUID,
        sessionID: UUID,
        requestedCapability: AgentCapabilityProfile,
        responseLanguage: ReadOnlyResponseLanguage = .english,
        scopeDescription: String
    ) {
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.sessionID = sessionID
        self.requestedCapability = requestedCapability
        self.responseLanguage = responseLanguage
        self.scopeDescription = scopeDescription
    }
}

struct AssessmentReportCompositionResult: Hashable, Sendable {
    var report: FDEAIIntegrationAssessmentReport?
    var executiveVerdict: AssessmentExecutiveVerdict
    var confidence: AssessmentClaimConfidence
    var validationFailures: [AssessmentReportValidationFailure]
    var excludedClaimIDs: [String]
}

enum AssessmentReportComposer {
    static func compose(
        context: AssessmentReportCompositionContext,
        claims placements: [AssessmentReportClaimPlacement],
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger,
        evidence: [ReadOnlyInspectionEvidence],
        executionEvents: [ExecutionEvent],
        explanation: AssessmentReportExplanationDraft? = nil
    ) -> AssessmentReportCompositionResult {
        var failures: [AssessmentReportValidationFailure] = []
        var excludedClaimIDs: Set<String> = []

        let groupedPlacements = Dictionary(grouping: placements, by: { $0.claim.claimID })
        var claimsByID: [String: AssessmentClaim] = [:]
        for claimID in groupedPlacements.keys.sorted() {
            let values = groupedPlacements[claimID] ?? []
            let distinctClaims = Set(values.map(\.claim))
            guard distinctClaims.count == 1, let claim = distinctClaims.first else {
                excludedClaimIDs.insert(claimID)
                failures.append(failure(.conflictingClaimID, claimID: claimID))
                continue
            }
            claimsByID[claimID] = claim
        }

        var bindingsByClaimID: [String: [AssessmentClaimEvidenceBinding]] = [:]
        for claimID in claimsByID.keys.sorted() {
            guard let claim = claimsByID[claimID] else { continue }
            let validation = AssessmentClaimValidator.validate(
                claim,
                evidenceLedger: evidenceLedger,
                evidence: evidence
            )
            guard validation.accepted else {
                excludedClaimIDs.insert(claimID)
                for issue in validation.issues {
                    failures.append(
                        AssessmentReportValidationFailure(
                            code: .claimValidationFailed,
                            claimID: claimID,
                            claimValidationFailure: issue.failure,
                            detail: "The claim did not pass the Phase 3B.3A evidence-grounding contract."
                        )
                    )
                }
                continue
            }
            bindingsByClaimID[claimID] = validation.bindings.filter { $0.claimID == claimID }
        }

        let eventsByID = Dictionary(grouping: executionEvents, by: \.id)
        for claimID in bindingsByClaimID.keys.sorted() {
            guard let bindings = bindingsByClaimID[claimID] else { continue }
            var lineageFailure: AssessmentReportValidationFailure?
            for binding in bindings {
                let matches = eventsByID[binding.toolResultEventID] ?? []
                if matches.isEmpty {
                    lineageFailure = failure(.missingExecutionEvent, claimID: claimID)
                    break
                }
                if matches.count != 1 {
                    lineageFailure = failure(.ambiguousExecutionEvent, claimID: claimID)
                    break
                }
                guard let event = matches.first else { continue }
                if binding.workspaceID != context.workspaceID {
                    lineageFailure = failure(.evidenceWorkspaceMismatch, claimID: claimID)
                    break
                }
                if event.workspaceID != context.workspaceID {
                    lineageFailure = failure(.executionEventWorkspaceMismatch, claimID: claimID)
                    break
                }
                if event.taskID != context.taskID {
                    lineageFailure = failure(.executionEventTaskMismatch, claimID: claimID)
                    break
                }
                if event.type != .stepExecuted
                    || event.payload["lifecycle_event"] != ExecutionPlanLifecycleEvent.toolResult.rawValue
                    || event.payload["tool_call_id"] != binding.toolCallID
                    || event.payload["success"] != "true"
                    || event.payload["evidence_eligible"] != "true" {
                    lineageFailure = failure(.executionEventNotSuccessfulToolResult, claimID: claimID)
                    break
                }
            }
            if let lineageFailure {
                failures.append(lineageFailure)
                excludedClaimIDs.insert(claimID)
                bindingsByClaimID.removeValue(forKey: claimID)
            }
        }

        var acceptedEntries: [AssessmentReportSectionEntry] = []
        var acceptedCompatibilityCapabilities: Set<LegacyArchitectureCapability> = []
        for placement in placements.sorted(by: placementOrder) {
            let claimID = placement.claim.claimID
            guard !excludedClaimIDs.contains(claimID), bindingsByClaimID[claimID] != nil else { continue }
            guard placementIsValid(placement, context: context) else {
                failures.append(failure(.invalidPlacement, claimID: claimID))
                continue
            }
            if placement.section == .capabilityCompatibility,
               let capability = placement.capability,
               !acceptedCompatibilityCapabilities.insert(capability).inserted {
                failures.append(failure(.duplicateCompatibilityCapability, claimID: claimID))
                continue
            }
            acceptedEntries.append(sectionEntry(from: placement, context: context))
        }

        let includedClaimIDs = Set(acceptedEntries.map(\.claimID))
        for claimID in bindingsByClaimID.keys where !includedClaimIDs.contains(claimID) {
            excludedClaimIDs.insert(claimID)
            failures.append(failure(.invalidPlacement, claimID: claimID))
        }
        acceptedEntries.removeAll { excludedClaimIDs.contains($0.claimID) }

        let acceptedClaims = claimsByID
            .filter { includedClaimIDs.contains($0.key) && !excludedClaimIDs.contains($0.key) }
        guard !acceptedClaims.isEmpty else {
            failures.append(failure(.noValidatedClaim, claimID: nil))
            let sortedFailures = uniqueFailures(failures)
            return AssessmentReportCompositionResult(
                report: nil,
                executiveVerdict: .unknown,
                confidence: .unknown,
                validationFailures: sortedFailures,
                excludedClaimIDs: excludedClaimIDs.sorted()
            )
        }

        acceptedEntries.sort(by: entryOrder)
        let sections = AssessmentReportSections(entries: acceptedEntries)
        let verdict = deriveVerdict(
            entries: acceptedEntries,
            requestedCapability: context.requestedCapability
        )
        let reportConfidence = deriveConfidence(claims: Array(acceptedClaims.values))
        let appendix = makeAppendix(
            claims: acceptedClaims,
            bindingsByClaimID: bindingsByClaimID
        )
        let binding = AssessmentReportBinding(
            workspaceID: context.workspaceID,
            taskID: context.taskID,
            sessionID: context.sessionID
        )
        let provenance = makeProvenance(
            context: context,
            appendix: appendix,
            executionEvents: executionEvents,
            evidenceLedger: evidenceLedger
        )
        let scope = AssessmentReportScope(
            description: context.scopeDescription,
            workspaceIdentities: unique(appendix.flatMap { $0.bindings.map(\.workspaceIdentity) }),
            relativePaths: unique(appendix.flatMap { $0.bindings.map(\.relativePath) }),
            requiredCapabilityIDs: context.requestedCapability.requiredCapabilities
                .filter(\.required)
                .map { $0.capability.rawValue }
                .sorted(),
            includedClaimIDs: acceptedClaims.keys.sorted()
        )

        let explanationResult = validateExplanation(
            explanation,
            includedClaims: acceptedClaims
        )
        failures.append(contentsOf: explanationResult.failures)
        excludedClaimIDs.formUnion(explanationResult.excludedClaimIDs)
        let sortedFailures = uniqueFailures(failures)
        let composedAt = provenance.latestEventTimestamp
        let reportID = stableReportID(
            binding: binding,
            provenance: provenance,
            verdict: verdict,
            confidence: reportConfidence,
            scope: scope,
            sections: sections,
            appendix: appendix,
            failures: sortedFailures,
            excludedClaimIDs: excludedClaimIDs.sorted(),
            composedAt: composedAt
        )
        let composition = AssessmentReportComposition(
            schemaVersion: AssessmentReportComposition.schemaVersion,
            reportID: reportID,
            binding: binding,
            executionProvenance: provenance,
            executiveVerdict: verdict,
            confidence: reportConfidence,
            scope: scope,
            sections: sections,
            evidenceAppendix: appendix,
            validationFailures: sortedFailures,
            excludedClaimIDs: excludedClaimIDs.sorted(),
            explanation: explanationResult.explanation,
            composedAt: composedAt
        )
        let report = makeExistingAssessmentReport(
            context: context,
            composition: composition,
            claimsByID: acceptedClaims
        )
        return AssessmentReportCompositionResult(
            report: report,
            executiveVerdict: verdict,
            confidence: reportConfidence,
            validationFailures: sortedFailures,
            excludedClaimIDs: excludedClaimIDs.sorted()
        )
    }

    static func compose(
        context: AssessmentReportCompositionContext,
        placements: [AssessmentReportClaimPlacement],
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger,
        evidence: [ReadOnlyInspectionEvidence],
        executionEvents: [ExecutionEvent],
        explanation: AssessmentReportExplanationDraft? = nil
    ) -> AssessmentReportCompositionResult {
        compose(
            context: context,
            claims: placements,
            evidenceLedger: evidenceLedger,
            evidence: evidence,
            executionEvents: executionEvents,
            explanation: explanation
        )
    }

    private static func placementIsValid(
        _ placement: AssessmentReportClaimPlacement,
        context: AssessmentReportCompositionContext
    ) -> Bool {
        switch placement.section {
        case .capabilityCompatibility:
            guard let capability = placement.capability else { return false }
            return context.requestedCapability.requiredCapabilities.contains {
                $0.capability == capability
            }
        case .blocker:
            return placement.capability != nil
                && placement.blockerCategory != nil
                && placement.riskLevel != nil
        case .risk, .securityAndAuthorization:
            return placement.riskLevel != nil
        case .executiveSummary, .observedLegacyArchitecture, .candidateIntegrationSeam,
             .unknown, .recommendation:
            return true
        }
    }

    private static func sectionEntry(
        from placement: AssessmentReportClaimPlacement,
        context: AssessmentReportCompositionContext
    ) -> AssessmentReportSectionEntry {
        let requiredByProfile = placement.capability.flatMap { capability in
            context.requestedCapability.requiredCapabilities.first {
                $0.capability == capability
            }?.required
        } ?? false
        return AssessmentReportSectionEntry(
            claimID: placement.claim.claimID,
            section: placement.section,
            disposition: placement.disposition,
            required: placement.required || requiredByProfile,
            capability: placement.capability,
            riskLevel: placement.riskLevel,
            riskDomain: placement.riskDomain,
            blockerCategory: placement.blockerCategory,
            title: placement.title,
            integrationPath: placement.integrationPath,
            architectureComponents: placement.architectureComponents
        )
    }

    private static func deriveVerdict(
        entries: [AssessmentReportSectionEntry],
        requestedCapability: AgentCapabilityProfile
    ) -> AssessmentExecutiveVerdict {
        let requiredCapabilities = Set(
            requestedCapability.requiredCapabilities.filter(\.required).map(\.capability)
        )
        let requiredCompatibility = entries.filter {
            $0.section == .capabilityCompatibility
                && $0.capability.map(requiredCapabilities.contains) == true
        }
        let additionalRequired = entries.filter {
            $0.required
                && ($0.section != .capabilityCompatibility
                    || $0.capability.map(requiredCapabilities.contains) != true)
        }
        let required = requiredCompatibility + additionalRequired
        let provenBlocker = entries.contains {
            $0.section == .blocker
                && ($0.disposition == .blocked || $0.disposition == .incompatible)
        }
        if provenBlocker || required.contains(where: {
            $0.disposition == .blocked || $0.disposition == .incompatible
        }) {
            return .no
        }
        let missingRequiredCapabilityCount = requiredCapabilities.count
            - Set(requiredCompatibility.compactMap(\.capability)).count
        guard !required.isEmpty || missingRequiredCapabilityCount > 0 else { return .unknown }
        let supportedCount = required.filter { $0.disposition == .supported }.count
        if supportedCount == required.count && missingRequiredCapabilityCount == 0 { return .yes }
        if supportedCount > 0 { return .partial }
        return .unknown
    }

    private static func deriveConfidence(
        claims: [AssessmentClaim]
    ) -> AssessmentClaimConfidence {
        claims.map(\.confidence).min(by: { confidenceRank($0) < confidenceRank($1) }) ?? .unknown
    }

    private static func makeAppendix(
        claims: [String: AssessmentClaim],
        bindingsByClaimID: [String: [AssessmentClaimEvidenceBinding]]
    ) -> [AssessmentReportEvidenceAppendixEntry] {
        claims.keys.sorted().compactMap { claimID in
            guard let claim = claims[claimID],
                  let bindings = bindingsByClaimID[claimID],
                  !bindings.isEmpty else { return nil }
            let sortedBindings = bindings.sorted {
                if $0.evidenceReferenceID != $1.evidenceReferenceID {
                    return $0.evidenceReferenceID < $1.evidenceReferenceID
                }
                return $0.toolResultEventID.uuidString < $1.toolResultEventID.uuidString
            }
            return AssessmentReportEvidenceAppendixEntry(
                claim: claim,
                status: .validated,
                bindings: sortedBindings,
                sourceExecutionEventIDs: unique(sortedBindings.map(\.toolResultEventID)),
                workspaceSnapshotIdentifiers: unique(
                    claim.evidence.compactMap(\.workspaceSnapshotIdentifier)
                )
            )
        }
    }

    private static func makeProvenance(
        context: AssessmentReportCompositionContext,
        appendix: [AssessmentReportEvidenceAppendixEntry],
        executionEvents: [ExecutionEvent],
        evidenceLedger: ReadOnlyFinalizationEvidenceLedger
    ) -> AssessmentReportExecutionProvenance {
        let sourceIDs = Set(appendix.flatMap(\.sourceExecutionEventIDs))
        let contextEvents = executionEvents.filter {
            $0.workspaceID == context.workspaceID && $0.taskID == context.taskID
        }
        let eventsByID = contextEvents.reduce(into: [UUID: ExecutionEvent]()) { values, event in
            if values[event.id] == nil { values[event.id] = event }
        }
        var lineageIDs = sourceIDs
        var frontier = Array(sourceIDs)
        while let eventID = frontier.popLast() {
            if let parentID = eventsByID[eventID]?.parentEventID,
               lineageIDs.insert(parentID).inserted {
                frontier.append(parentID)
            }
        }
        let lineage = contextEvents
            .filter { lineageIDs.contains($0.id) }
            .sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                return $0.id.uuidString < $1.id.uuidString
            }
        let latest = lineage.max {
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        return AssessmentReportExecutionProvenance(
            executionEventIDs: lineage.map(\.id),
            sourceToolResultEventIDs: sourceIDs.sorted { $0.uuidString < $1.uuidString },
            sourceToolCallIDs: unique(appendix.flatMap { $0.bindings.map(\.toolCallID) }),
            evidenceLedgerSHA256: sha256(encoded(evidenceLedger)),
            latestEventSequence: latest?.sequence ?? 0,
            latestEventTimestamp: latest?.timestamp ?? Date(timeIntervalSince1970: 0)
        )
    }

    private static func validateExplanation(
        _ draft: AssessmentReportExplanationDraft?,
        includedClaims: [String: AssessmentClaim]
    ) -> (
        explanation: AssessmentReportExplanation?,
        failures: [AssessmentReportValidationFailure],
        excludedClaimIDs: Set<String>
    ) {
        guard let draft else { return (nil, [], []) }
        var failures: [AssessmentReportValidationFailure] = []
        var excluded: Set<String> = []
        let includedClaimIDs = Set(includedClaims.keys)
        if draft.proposedVerdict != nil
            || draft.proposedConfidence != nil
            || !draft.proposedRiskClaimIDs.isEmpty
            || !draft.unknownClaimIDsToOmit.isEmpty {
            failures.append(failure(.explanationAuthorityViolation, claimID: nil))
        }
        if !draft.proposedClaims.isEmpty {
            failures.append(failure(.explanationUnsupportedClaim, claimID: nil))
            excluded.formUnion(draft.proposedClaims.map(\.claimID))
        }
        let sourceIDs = Set(draft.sourceClaimIDs)
        if sourceIDs.isEmpty || !sourceIDs.isSubset(of: includedClaimIDs) {
            failures.append(failure(.explanationUnsupportedClaim, claimID: nil))
        }
        let narrative = draft.narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        if !narrative.isEmpty,
           sourceIDs.isSubset(of: includedClaimIDs),
           !narrativeIsGrounded(
               narrative,
               sourceClaimIDs: sourceIDs,
               includedClaims: includedClaims
           ) {
            failures.append(failure(.explanationUnsupportedClaim, claimID: nil))
        }
        guard failures.isEmpty else { return (nil, failures, excluded) }
        guard !narrative.isEmpty else { return (nil, [], []) }
        return (
            AssessmentReportExplanation(
                narrative: narrative,
                sourceClaimIDs: sourceIDs.sorted(),
                nonAuthoritative: true
            ),
            [],
            []
        )
    }

    private static func narrativeIsGrounded(
        _ narrative: String,
        sourceClaimIDs: Set<String>,
        includedClaims: [String: AssessmentClaim]
    ) -> Bool {
        let allowedFragments = sourceClaimIDs.sorted().flatMap { claimID -> [String] in
            guard let claim = includedClaims[claimID] else { return [] }
            return [claim.statement]
                + claim.unknowns
                + claim.evidence.flatMap { [$0.fact, $0.safeEvidenceSummary] }
        }
        var remainder = narrative.lowercased()
        for fragment in allowedFragments.sorted(by: { $0.count > $1.count }) {
            remainder = remainder.replacingOccurrences(of: fragment.lowercased(), with: " ")
        }
        let neutralTokens: Set<String> = [
            "summary", "validated", "fact", "facts", "evidence", "grounded",
            "explanation", "and", "also", "however", "therefore", "the", "a",
            "an", "this", "these", "report", "claim", "claims", "in"
        ]
        let tokens = remainder
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return tokens.allSatisfy(neutralTokens.contains)
    }

    private static func makeExistingAssessmentReport(
        context: AssessmentReportCompositionContext,
        composition: AssessmentReportComposition,
        claimsByID: [String: AssessmentClaim]
    ) -> FDEAIIntegrationAssessmentReport {
        let entries = composition.sections.allEntries
        func claim(_ entry: AssessmentReportSectionEntry) -> AssessmentClaim {
            // Every section entry is constructed from an accepted claim.
            claimsByID[entry.claimID]!
        }
        let summaryEntry = composition.sections.executiveSummary.first ?? entries[0]
        let summaryClaim = claim(summaryEntry)
        let architectureClaims = composition.sections.observedLegacyArchitecture.map(claim)
        let requirementsByCapability = Dictionary(
            uniqueKeysWithValues: context.requestedCapability.requiredCapabilities.map {
                ($0.capability, $0)
            }
        )
        let compatibilityEntries = composition.sections.capabilityCompatibilityMatrix.compactMap { entry -> CompatibilityMatrixEntry? in
            guard let capability = entry.capability,
                  let requirement = requirementsByCapability[capability] else { return nil }
            let status: AgentCompatibilityStatus
            switch entry.disposition {
            case .supported: status = .supported
            case .blocked, .incompatible: status = .blocked
            case .partial, .unknown, .advisory: status = .unknown
            }
            return CompatibilityMatrixEntry(
                requirement: requirement,
                status: status,
                claim: claim(entry)
            )
        }
        let opportunities = composition.sections.candidateIntegrationSeams.map { entry in
            let sourceClaim = claim(entry)
            return IntegrationOpportunity(
                feature: entry.title ?? sourceClaim.statement,
                possibleIntegration: entry.integrationPath,
                confidence: sourceClaim.confidence,
                evidence: sourceClaim.evidence,
                claim: sourceClaim
            )
        }
        let securityEntries = composition.sections.securityAndAuthorizationFindings
        let allRiskEntries = securityEntries + composition.sections.risks
        let dataRisk = maximumRisk(
            allRiskEntries.filter { $0.riskDomain == .dataAccess }.compactMap(\.riskLevel)
        )
        let permissionRisk = maximumRisk(
            allRiskEntries.filter { $0.riskDomain == .permission }.compactMap(\.riskLevel)
        )
        let modificationRisk = maximumRisk(
            allRiskEntries.filter { $0.riskDomain == .modification }.compactMap(\.riskLevel)
        )
        let blockers = composition.sections.blockers.compactMap { entry -> IntegrationBlocker? in
            guard let category = entry.blockerCategory,
                  let capability = entry.capability,
                  let risk = entry.riskLevel else { return nil }
            let sourceClaim = claim(entry)
            return IntegrationBlocker(
                category: category,
                requirement: capability,
                severity: risk,
                reason: sourceClaim.statement,
                claim: sourceClaim
            )
        }
        let recommendationEntry = composition.sections.recommendations.first ?? summaryEntry
        let recommendationClaim = claim(recommendationEntry)
        let unknowns = unique(
            composition.sections.unknowns.map { claim($0).statement }
                + claimsByID.keys.sorted().flatMap { claimsByID[$0]?.unknowns ?? [] }
        )
        return FDEAIIntegrationAssessmentReport(
            assessmentLayerID: AIIntegrationAssessmentLayer.id,
            responseLanguage: context.responseLanguage,
            executiveSummary: summaryClaim,
            legacySystemUnderstanding: architectureClaims,
            requestedAICapability: context.requestedCapability,
            compatibilityMatrix: CompatibilityMatrix(
                capability: context.requestedCapability,
                entries: compatibilityEntries,
                verdict: composition.executiveVerdict.legacyVerdict
            ),
            integrationOpportunities: opportunities,
            securityAssessment: AgentSecurityAssessment(
                dataAccessRisk: dataRisk,
                permissionRisk: permissionRisk,
                modificationRisk: modificationRisk,
                humanApprovalRequired: blockers.contains { $0.severity == .high }
                    || allRiskEntries.contains { $0.riskLevel == .high },
                claims: securityEntries.map(claim)
            ),
            integrationBlockers: IntegrationBlockerReport(blockers: blockers),
            recommendedArchitecture: RecommendedAgentArchitecture(
                components: recommendationEntry.architectureComponents,
                dataFlow: recommendationEntry.integrationPath,
                claim: recommendationClaim
            ),
            integrationPlan: AgentIntegrationPlan(
                capability: context.requestedCapability,
                steps: []
            ),
            validationTestPlan: IntegrationValidationPlan(
                tests: [],
                executionAuthorized: false
            ),
            expectedAgentWorkflows: [],
            expectedOperationalOutcomes: [],
            agentBlackBoxAssessment: AgentBlackBoxAssessment(
                legacySideBlockers: [],
                agentSideBlackBoxes: []
            ),
            evidenceRecords: unique(composition.evidenceAppendix.flatMap { $0.claim.evidence }),
            unknownsAndNextInvestigationSteps: unknowns,
            composition: composition
        )
    }

    private static func maximumRisk(_ risks: [AssessmentRiskLevel]) -> AssessmentRiskLevel {
        risks.max(by: { riskRank($0) < riskRank($1) }) ?? .low
    }

    private static func failure(
        _ code: AssessmentReportValidationFailureCode,
        claimID: String?
    ) -> AssessmentReportValidationFailure {
        AssessmentReportValidationFailure(
            code: code,
            claimID: claimID,
            claimValidationFailure: nil,
            detail: failureDetail(code)
        )
    }

    private static func failureDetail(_ code: AssessmentReportValidationFailureCode) -> String {
        switch code {
        case .claimValidationFailed:
            return "The claim did not pass evidence-grounding validation."
        case .conflictingClaimID:
            return "One claim identifier resolved to conflicting immutable claim values."
        case .missingExecutionEvent:
            return "A bound source execution event was not supplied to the composer."
        case .ambiguousExecutionEvent:
            return "A bound source execution event identifier was not unique."
        case .executionEventWorkspaceMismatch:
            return "A source event belongs to a different workspace."
        case .executionEventTaskMismatch:
            return "A source event belongs to a different task."
        case .executionEventNotSuccessfulToolResult:
            return "A source event is not an evidence-eligible successful TOOL_RESULT."
        case .evidenceWorkspaceMismatch:
            return "Bound evidence belongs to a different workspace."
        case .invalidPlacement:
            return "The claim placement lacks required deterministic classification metadata."
        case .duplicateCompatibilityCapability:
            return "A capability may have only one compatibility conclusion."
        case .explanationAuthorityViolation:
            return "Optional prose attempted to modify structured report authority."
        case .explanationUnsupportedClaim:
            return "Optional prose referenced or proposed a claim outside the validated appendix."
        case .noValidatedClaim:
            return "No evidence-grounded claim remained eligible for report composition."
        }
    }

    private static func uniqueFailures(
        _ values: [AssessmentReportValidationFailure]
    ) -> [AssessmentReportValidationFailure] {
        var seen: Set<String> = []
        return values
            .sorted {
                if $0.code.rawValue != $1.code.rawValue { return $0.code.rawValue < $1.code.rawValue }
                if ($0.claimID ?? "") != ($1.claimID ?? "") { return ($0.claimID ?? "") < ($1.claimID ?? "") }
                return ($0.claimValidationFailure?.rawValue ?? "") < ($1.claimValidationFailure?.rawValue ?? "")
            }
            .filter { seen.insert($0.id).inserted }
    }

    private static func placementOrder(
        _ lhs: AssessmentReportClaimPlacement,
        _ rhs: AssessmentReportClaimPlacement
    ) -> Bool {
        if lhs.section.rank != rhs.section.rank { return lhs.section.rank < rhs.section.rank }
        if lhs.claim.claimID != rhs.claim.claimID { return lhs.claim.claimID < rhs.claim.claimID }
        return (lhs.capability?.rawValue ?? "") < (rhs.capability?.rawValue ?? "")
    }

    private static func entryOrder(
        _ lhs: AssessmentReportSectionEntry,
        _ rhs: AssessmentReportSectionEntry
    ) -> Bool {
        if lhs.section.rank != rhs.section.rank { return lhs.section.rank < rhs.section.rank }
        if lhs.claimID != rhs.claimID { return lhs.claimID < rhs.claimID }
        return (lhs.capability?.rawValue ?? "") < (rhs.capability?.rawValue ?? "")
    }

    private static func confidenceRank(_ value: AssessmentClaimConfidence) -> Int {
        switch value {
        case .unknown: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    private static func riskRank(_ value: AssessmentRiskLevel) -> Int {
        switch value {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen: Set<T> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct ReportIdentityMaterial: Codable {
        var schemaVersion: String
        var binding: AssessmentReportBinding
        var provenance: AssessmentReportExecutionProvenance
        var verdict: AssessmentExecutiveVerdict
        var confidence: AssessmentClaimConfidence
        var scope: AssessmentReportScope
        var sections: AssessmentReportSections
        var appendix: [AssessmentReportEvidenceAppendixEntry]
        var failures: [AssessmentReportValidationFailure]
        var excludedClaimIDs: [String]
        var composedAt: Date
    }

    private static func stableReportID(
        binding: AssessmentReportBinding,
        provenance: AssessmentReportExecutionProvenance,
        verdict: AssessmentExecutiveVerdict,
        confidence: AssessmentClaimConfidence,
        scope: AssessmentReportScope,
        sections: AssessmentReportSections,
        appendix: [AssessmentReportEvidenceAppendixEntry],
        failures: [AssessmentReportValidationFailure],
        excludedClaimIDs: [String],
        composedAt: Date
    ) -> String {
        let material = ReportIdentityMaterial(
            schemaVersion: AssessmentReportComposition.schemaVersion,
            binding: binding,
            provenance: provenance,
            verdict: verdict,
            confidence: confidence,
            scope: scope,
            sections: sections,
            appendix: appendix,
            failures: failures,
            excludedClaimIDs: excludedClaimIDs,
            composedAt: composedAt
        )
        return "assessment-report-\(sha256(encoded(material)))"
    }

    static func reconstructReportID(
        _ composition: AssessmentReportComposition
    ) -> String {
        stableReportID(
            binding: composition.binding,
            provenance: composition.executionProvenance,
            verdict: composition.executiveVerdict,
            confidence: composition.confidence,
            scope: composition.scope,
            sections: composition.sections,
            appendix: composition.evidenceAppendix,
            failures: composition.validationFailures,
            excludedClaimIDs: composition.excludedClaimIDs,
            composedAt: composition.composedAt
        )
    }
}

extension FDEAIIntegrationAssessmentReport {
    func phase3B3BMarkdown(language: ReadOnlyResponseLanguage) -> String {
        guard let composition else { return "" }
        let claimsByID = Dictionary(
            uniqueKeysWithValues: composition.evidenceAppendix.map { ($0.claimID, $0.claim) }
        )
        func statement(_ entry: AssessmentReportSectionEntry) -> String {
            claimsByID[entry.claimID]?.statement ?? ""
        }
        func section(
            _ heading: String,
            _ entries: [AssessmentReportSectionEntry]
        ) -> [String] {
            var lines = ["## \(heading)", ""]
            if entries.isEmpty {
                lines.append(language == .chinese ? "_无经验证声明。_" : "_No validated claims._")
            } else {
                for entry in entries {
                    var suffix = " [\(entry.disposition.rawValue)]"
                    if let capability = entry.capability {
                        suffix += " (`\(capability.rawValue)`)"
                    }
                    if let risk = entry.riskLevel {
                        suffix += " — \(risk.rawValue)"
                    }
                    lines.append("- \(statement(entry))\(suffix) — `\(entry.claimID)`")
                }
            }
            lines.append("")
            return lines
        }

        let title = language == .chinese
            ? "# FDE AI 集成评估报告"
            : "# FDE AI Integration Assessment Report"
        var lines: [String] = [
            title,
            "",
            "- Report ID: `\(composition.reportID)`",
            "- Schema: `\(composition.schemaVersion)`",
            "- Workspace: `\(composition.binding.workspaceID.uuidString)`",
            "- Task: `\(composition.binding.taskID.uuidString)`",
            "- Session: `\(composition.binding.sessionID.uuidString)`",
            "- Verdict: **\(composition.executiveVerdict.rawValue)**",
            "- Confidence: **\(composition.confidence.rawValue)**",
            "- Scope: \(composition.scope.description)",
            "- Source execution events: \(composition.executionProvenance.executionEventIDs.map { "`\($0.uuidString)`" }.joined(separator: ", "))",
            "- Evidence ledger SHA-256: `\(composition.executionProvenance.evidenceLedgerSHA256)`",
            ""
        ]
        if let explanation = composition.explanation {
            lines += [
                language == .chinese ? "## 非权威说明" : "## Non-authoritative Explanation",
                "",
                explanation.narrative,
                "",
                language == .chinese
                    ? "来源声明：\(explanation.sourceClaimIDs.map { "`\($0)`" }.joined(separator: ", "))"
                    : "Source claims: \(explanation.sourceClaimIDs.map { "`\($0)`" }.joined(separator: ", "))",
                ""
            ]
        }
        lines += section(language == .chinese ? "执行结论" : "Executive Verdict Claims", composition.sections.executiveSummary)
        lines += section(language == .chinese ? "观察到的 Legacy 架构" : "Observed Legacy Architecture", composition.sections.observedLegacyArchitecture)
        lines += section(language == .chinese ? "候选集成接缝" : "Candidate Integration Seams", composition.sections.candidateIntegrationSeams)
        lines += section(language == .chinese ? "能力兼容性矩阵" : "Capability Compatibility Matrix", composition.sections.capabilityCompatibilityMatrix)
        lines += section(language == .chinese ? "安全与授权发现" : "Security and Authorization Findings", composition.sections.securityAndAuthorizationFindings)
        lines += section(language == .chinese ? "风险" : "Risks", composition.sections.risks)
        lines += section(language == .chinese ? "阻塞项" : "Blockers", composition.sections.blockers)
        lines += section(language == .chinese ? "未知项" : "Unknowns", composition.sections.unknowns)
        lines += section(language == .chinese ? "建议" : "Recommendations", composition.sections.recommendations)
        lines += [language == .chinese ? "## 证据附录" : "## Evidence Appendix", ""]
        for entry in composition.evidenceAppendix {
            lines += [
                "### `\(entry.claimID)`",
                "",
                "- Statement: \(entry.statement)",
                "- Status: **\(entry.status.rawValue)**",
                "- Confidence: **\(entry.confidence.rawValue)**",
                "- Source execution events: \(entry.sourceExecutionEventIDs.map { "`\($0.uuidString)`" }.joined(separator: ", "))",
                "- Workspace snapshots: \(entry.workspaceSnapshotIdentifiers.map { "`\($0)`" }.joined(separator: ", "))",
                "- Evidence references:"
            ]
            for reference in entry.evidenceReferences {
                lines.append("  - `\(reference.id)` — \(reference.safeEvidenceSummary)")
            }
            lines.append("")
        }
        if !composition.validationFailures.isEmpty {
            lines += [language == .chinese ? "## 验证失败" : "## Validation Failures", ""]
            lines.append(contentsOf: composition.validationFailures.map {
                "- `\($0.code.rawValue)`\($0.claimID.map { " — `\($0)`" } ?? "")"
            })
        }
        return lines.joined(separator: "\n")
    }
}

enum AssessmentReportPersistenceError: LocalizedError, Equatable {
    case missingComposition
    case missingPayload
    case digestMismatch
    case identityMismatch
    case bindingMismatch

    var errorDescription: String? {
        switch self {
        case .missingComposition: return "The assessment does not contain Phase 3B.3B composition metadata."
        case .missingPayload: return "The persisted assessment report payload is incomplete."
        case .digestMismatch: return "The persisted assessment report digest does not match its encoded content."
        case .identityMismatch: return "The persisted assessment report identity does not match its content."
        case .bindingMismatch: return "The persisted assessment report event binding does not match the report."
        }
    }
}

extension FDEAIIntegrationAssessmentReport {
    func persistenceEventPayload() throws -> [String: String] {
        guard let composition else { throw AssessmentReportPersistenceError.missingComposition }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let json = String(data: data, encoding: .utf8) else {
            throw AssessmentReportPersistenceError.missingPayload
        }
        return [
            "lifecycle_event": "AI_ASSESSMENT_REPORT_COMPOSED",
            "assessment_report_schema": composition.schemaVersion,
            "assessment_report_id": composition.reportID,
            "assessment_report_json": json,
            "assessment_report_sha256": digest,
            "assessment_report_verdict": composition.executiveVerdict.rawValue,
            "assessment_report_confidence": composition.confidence.rawValue,
            "assessment_report_workspace_id": composition.binding.workspaceID.uuidString,
            "assessment_report_task_id": composition.binding.taskID.uuidString,
            "assessment_report_session_id": composition.binding.sessionID.uuidString
        ]
    }

    static func reload(from event: ExecutionEvent) throws -> FDEAIIntegrationAssessmentReport {
        let report = try reload(from: event.payload)
        guard let binding = report.composition?.binding,
              event.workspaceID == binding.workspaceID,
              event.taskID == binding.taskID else {
            throw AssessmentReportPersistenceError.bindingMismatch
        }
        return report
    }

    static func reload(from payload: [String: String]) throws -> FDEAIIntegrationAssessmentReport {
        guard payload["lifecycle_event"] == "AI_ASSESSMENT_REPORT_COMPOSED",
              let reportID = payload["assessment_report_id"],
              let json = payload["assessment_report_json"],
              let expectedDigest = payload["assessment_report_sha256"],
              let data = json.data(using: .utf8) else {
            throw AssessmentReportPersistenceError.missingPayload
        }
        let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == expectedDigest else {
            throw AssessmentReportPersistenceError.digestMismatch
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let report = try decoder.decode(FDEAIIntegrationAssessmentReport.self, from: data)
        guard let composition = report.composition else {
            throw AssessmentReportPersistenceError.missingComposition
        }
        guard composition.reportID == reportID,
              composition.reportID == AssessmentReportComposer.reconstructReportID(composition),
              composition.schemaVersion == payload["assessment_report_schema"],
              composition.executiveVerdict.rawValue == payload["assessment_report_verdict"],
              composition.confidence.rawValue == payload["assessment_report_confidence"] else {
            throw AssessmentReportPersistenceError.identityMismatch
        }
        guard composition.binding.workspaceID.uuidString == payload["assessment_report_workspace_id"],
              composition.binding.taskID.uuidString == payload["assessment_report_task_id"],
              composition.binding.sessionID.uuidString == payload["assessment_report_session_id"] else {
            throw AssessmentReportPersistenceError.bindingMismatch
        }
        return report
    }
}
