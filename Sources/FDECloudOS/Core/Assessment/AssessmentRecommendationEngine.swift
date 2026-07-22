import CryptoKit
import Foundation

/// The Phase 3B.4 decision is an advisory handoff derived from a validated
/// Phase 3B.3B report. It is deliberately not an execution-plan state.
enum AssessmentRecommendationDecision: String, Codable, CaseIterable, Hashable, Sendable {
    case proceedToValidation = "PROCEED_TO_VALIDATION"
    case conditionallyProceed = "CONDITIONALLY_PROCEED"
    case doNotProceed = "DO_NOT_PROCEED"
    case investigate = "INVESTIGATE"
}

enum AssessmentRecommendationCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case decisionGate = "DECISION_GATE"
    case blockerRemediation = "BLOCKER_REMEDIATION"
    case securityControl = "SECURITY_CONTROL"
    case evidenceInvestigation = "EVIDENCE_INVESTIGATION"
    case integrationDesign = "INTEGRATION_DESIGN"
    case validation = "VALIDATION"
}

enum AssessmentRecommendationPriority: String, Codable, CaseIterable, Hashable, Sendable {
    case critical = "CRITICAL"
    case high = "HIGH"
    case medium = "MEDIUM"
    case low = "LOW"
}

enum AssessmentRecommendationAuthority: String, Codable, CaseIterable, Hashable, Sendable {
    case advisoryOnly = "ADVISORY_ONLY"
}

struct AssessmentRecommendation: Codable, Hashable, Sendable, Identifiable {
    var recommendationID: String
    var category: AssessmentRecommendationCategory
    var priority: AssessmentRecommendationPriority
    var title: String
    var action: String
    var rationale: String
    var sourceClaimIDs: [String]
    var sourceSections: [AssessmentReportClaimSection]
    var targetCapabilityIDs: [String]
    var conditions: [String]
    var validationCriteria: [String]
    var requiresHumanApproval: Bool
    var authority: AssessmentRecommendationAuthority
    var executionAuthorized: Bool

    var id: String { recommendationID }
}

struct AssessmentRecommendationSet: Codable, Hashable, Sendable, Identifiable {
    static let schemaVersion = "3B.4"

    var schemaVersion: String
    var recommendationSetID: String
    var sourceReportID: String
    var binding: AssessmentReportBinding
    var sourceVerdict: AssessmentExecutiveVerdict
    var sourceConfidence: AssessmentClaimConfidence
    var decision: AssessmentRecommendationDecision
    var recommendations: [AssessmentRecommendation]
    var sourceClaimIDs: [String]
    var generatedAt: Date
    var authority: AssessmentRecommendationAuthority
    var executionAuthorized: Bool

    var id: String { recommendationSetID }
}

/// Compatibility names for callers that present the recommendation artifact as
/// a plan or package. Neither alias grants execution authority.
typealias AssessmentRecommendationPlan = AssessmentRecommendationSet
typealias AssessmentRecommendationPackage = AssessmentRecommendationSet

enum AssessmentRecommendationValidationFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case missingComposition = "MISSING_COMPOSITION"
    case unsupportedReportSchema = "UNSUPPORTED_REPORT_SCHEMA"
    case sourceReportIdentityMismatch = "SOURCE_REPORT_IDENTITY_MISMATCH"
    case duplicateAppendixClaim = "DUPLICATE_APPENDIX_CLAIM"
    case invalidAppendixBinding = "INVALID_APPENDIX_BINDING"
    case danglingSectionClaim = "DANGLING_SECTION_CLAIM"
    case scopeClaimMismatch = "SCOPE_CLAIM_MISMATCH"
    case scopeEvidenceMismatch = "SCOPE_EVIDENCE_MISMATCH"
    case invalidRecommendationAuthority = "INVALID_RECOMMENDATION_AUTHORITY"
    case recommendationIdentityMismatch = "RECOMMENDATION_IDENTITY_MISMATCH"
    case recommendationSetIdentityMismatch = "RECOMMENDATION_SET_IDENTITY_MISMATCH"
    case unsupportedRecommendationClaim = "UNSUPPORTED_RECOMMENDATION_CLAIM"
    case emptyRecommendationSet = "EMPTY_RECOMMENDATION_SET"
}

struct AssessmentRecommendationValidationFailure: Codable, Hashable, Sendable, Identifiable {
    var code: AssessmentRecommendationValidationFailureCode
    var claimID: String?
    var recommendationID: String?
    var detail: String

    var id: String {
        "\(code.rawValue):\(claimID ?? "claim"):\(recommendationID ?? "recommendation")"
    }
}

struct AssessmentRecommendationResult: Hashable, Sendable {
    var recommendationSet: AssessmentRecommendationSet?
    var decision: AssessmentRecommendationDecision
    var validationFailures: [AssessmentRecommendationValidationFailure]

    var accepted: Bool { recommendationSet != nil && validationFailures.isEmpty }
}

enum AssessmentRecommendationEngine {
    static func generate(
        from report: FDEAIIntegrationAssessmentReport
    ) -> AssessmentRecommendationResult {
        let inputFailures = validateSource(report)
        guard inputFailures.isEmpty, let composition = report.composition else {
            return AssessmentRecommendationResult(
                recommendationSet: nil,
                decision: .investigate,
                validationFailures: inputFailures
            )
        }

        let recommendationSet = deriveRecommendationSet(from: composition)
        let outputFailures = validate(
            recommendationSet,
            against: report
        )
        guard outputFailures.isEmpty else {
            return AssessmentRecommendationResult(
                recommendationSet: nil,
                decision: .investigate,
                validationFailures: outputFailures
            )
        }
        return AssessmentRecommendationResult(
            recommendationSet: recommendationSet,
            decision: recommendationSet.decision,
            validationFailures: []
        )
    }

    static func generate(
        report: FDEAIIntegrationAssessmentReport
    ) -> AssessmentRecommendationResult {
        generate(from: report)
    }

    static func recommend(
        from report: FDEAIIntegrationAssessmentReport
    ) -> AssessmentRecommendationResult {
        generate(from: report)
    }

    static func recommendations(
        for report: FDEAIIntegrationAssessmentReport
    ) -> AssessmentRecommendationResult {
        generate(from: report)
    }

    static func validate(
        _ recommendationSet: AssessmentRecommendationSet,
        against report: FDEAIIntegrationAssessmentReport
    ) -> [AssessmentRecommendationValidationFailure] {
        let sourceFailures = validateSource(report)
        guard sourceFailures.isEmpty, let composition = report.composition else {
            return uniqueFailures(sourceFailures)
        }
        var failures: [AssessmentRecommendationValidationFailure] = []

        failures.append(contentsOf: validateIntegrity(recommendationSet))
        if recommendationSet.schemaVersion != AssessmentRecommendationSet.schemaVersion
            || recommendationSet.authority != .advisoryOnly
            || recommendationSet.executionAuthorized
            || recommendationSet.sourceReportID != composition.reportID
            || recommendationSet.binding != composition.binding
            || recommendationSet.sourceVerdict != composition.executiveVerdict
            || recommendationSet.sourceConfidence != composition.confidence
            || recommendationSet.generatedAt != composition.composedAt
            || recommendationSet.decision != decision(for: composition.executiveVerdict) {
            failures.append(failure(
                .invalidRecommendationAuthority,
                detail: "The recommendation artifact must preserve its source binding and remain advisory-only."
            ))
        }
        let validatedClaimIDs = Set(composition.evidenceAppendix.map(\.claimID))
        let recommendationSourceIDs = Set(recommendationSet.recommendations.flatMap(\.sourceClaimIDs))
        if !recommendationSourceIDs.isSubset(of: validatedClaimIDs)
            || Set(recommendationSet.sourceClaimIDs) != recommendationSourceIDs {
            failures.append(failure(
                .unsupportedRecommendationClaim,
                detail: "Every recommendation source must resolve to the validated Phase 3B.3B evidence appendix."
            ))
        }

        if recommendationSet != deriveRecommendationSet(from: composition) {
            failures.append(failure(
                .recommendationSetIdentityMismatch,
                detail: "The recommendation artifact differs from the deterministic Phase 3B.4 derivation for its source report."
            ))
        }
        return uniqueFailures(failures)
    }

    static func validateIntegrity(
        _ recommendationSet: AssessmentRecommendationSet
    ) -> [AssessmentRecommendationValidationFailure] {
        var failures: [AssessmentRecommendationValidationFailure] = []
        let recommendationSourceIDs = Set(recommendationSet.recommendations.flatMap(\.sourceClaimIDs))
        if recommendationSet.schemaVersion != AssessmentRecommendationSet.schemaVersion
            || recommendationSet.authority != .advisoryOnly
            || recommendationSet.executionAuthorized {
            failures.append(failure(
                .invalidRecommendationAuthority,
                detail: "The recommendation artifact must use the Phase 3B.4 schema and remain advisory-only."
            ))
        }
        if recommendationSet.recommendations.isEmpty {
            failures.append(failure(
                .emptyRecommendationSet,
                detail: "A Phase 3B.4 artifact must contain at least one grounded advisory recommendation."
            ))
        }
        if Set(recommendationSet.sourceClaimIDs) != recommendationSourceIDs {
            failures.append(failure(
                .unsupportedRecommendationClaim,
                detail: "The recommendation-set source claims must exactly summarize its recommendation lineage."
            ))
        }

        var recommendationIDs: Set<String> = []
        for recommendation in recommendationSet.recommendations {
            if recommendation.authority != .advisoryOnly
                || recommendation.executionAuthorized
                || recommendation.sourceClaimIDs.isEmpty {
                failures.append(failure(
                    .invalidRecommendationAuthority,
                    recommendationID: recommendation.recommendationID,
                    detail: "Every recommendation must be evidence-linked, advisory-only, and non-executable."
                ))
            }
            let expectedID = stableRecommendationID(
                category: recommendation.category,
                priority: recommendation.priority,
                title: recommendation.title,
                action: recommendation.action,
                rationale: recommendation.rationale,
                sourceClaimIDs: recommendation.sourceClaimIDs,
                sourceSections: recommendation.sourceSections,
                targetCapabilityIDs: recommendation.targetCapabilityIDs,
                conditions: recommendation.conditions,
                validationCriteria: recommendation.validationCriteria,
                requiresHumanApproval: recommendation.requiresHumanApproval
            )
            if recommendation.recommendationID != expectedID
                || !recommendationIDs.insert(recommendation.recommendationID).inserted {
                failures.append(failure(
                    .recommendationIdentityMismatch,
                    recommendationID: recommendation.recommendationID,
                    detail: "A recommendation identifier must be unique and reconstruct from canonical advisory content."
                ))
            }
        }

        if recommendationSet.recommendationSetID != reconstructRecommendationSetID(recommendationSet) {
            failures.append(failure(
                .recommendationSetIdentityMismatch,
                detail: "The recommendation-set identifier does not match its canonical content."
            ))
        }
        return uniqueFailures(failures)
    }

    static func reconstructRecommendationSetID(
        _ recommendationSet: AssessmentRecommendationSet
    ) -> String {
        stableSetID(
            sourceReportID: recommendationSet.sourceReportID,
            binding: recommendationSet.binding,
            sourceVerdict: recommendationSet.sourceVerdict,
            sourceConfidence: recommendationSet.sourceConfidence,
            decision: recommendationSet.decision,
            recommendations: recommendationSet.recommendations,
            sourceClaimIDs: recommendationSet.sourceClaimIDs,
            generatedAt: recommendationSet.generatedAt,
            authority: recommendationSet.authority,
            executionAuthorized: recommendationSet.executionAuthorized
        )
    }

    private static func validateSource(
        _ report: FDEAIIntegrationAssessmentReport
    ) -> [AssessmentRecommendationValidationFailure] {
        guard let composition = report.composition else {
            return [failure(
                .missingComposition,
                detail: "Phase 3B.4 requires a Phase 3B.3B evidence-grounded report composition."
            )]
        }
        var failures: [AssessmentRecommendationValidationFailure] = []
        if composition.schemaVersion != AssessmentReportComposition.schemaVersion {
            failures.append(failure(
                .unsupportedReportSchema,
                detail: "Only the current Phase 3B.3B report schema can authorize recommendation derivation."
            ))
        }
        if composition.reportID != AssessmentReportComposer.reconstructReportID(composition) {
            failures.append(failure(
                .sourceReportIdentityMismatch,
                detail: "The source report identity does not match its canonical composition."
            ))
        }

        let groupedAppendix = Dictionary(grouping: composition.evidenceAppendix, by: \.claimID)
        let duplicateClaims = groupedAppendix.filter { $0.value.count != 1 }.keys.sorted()
        failures.append(contentsOf: duplicateClaims.map { claimID in
            failure(
                .duplicateAppendixClaim,
                claimID: claimID,
                detail: "Each validated claim must appear exactly once in the evidence appendix."
            )
        })
        let appendixClaimIDs = Set(groupedAppendix.keys)
        for appendix in composition.evidenceAppendix {
            let bindingEventIDs = Set(appendix.bindings.map(\.toolResultEventID))
            let invalid = appendix.status != .validated
                || appendix.bindings.isEmpty
                || appendix.bindings.contains {
                    $0.claimID != appendix.claimID
                        || $0.workspaceID != composition.binding.workspaceID
                }
                || Set(appendix.sourceExecutionEventIDs) != bindingEventIDs
                || !bindingEventIDs.isSubset(of: Set(composition.executionProvenance.sourceToolResultEventIDs))
            if invalid {
                failures.append(failure(
                    .invalidAppendixBinding,
                    claimID: appendix.claimID,
                    detail: "The evidence appendix claim is not bound to its recorded workspace and source TOOL_RESULT lineage."
                ))
            }
        }

        for entry in composition.sections.allEntries where !appendixClaimIDs.contains(entry.claimID) {
            failures.append(failure(
                .danglingSectionClaim,
                claimID: entry.claimID,
                detail: "Every report section entry must resolve to one validated appendix claim."
            ))
        }
        if Set(composition.scope.includedClaimIDs) != appendixClaimIDs {
            failures.append(failure(
                .scopeClaimMismatch,
                detail: "The report scope and evidence appendix do not identify the same validated claims."
            ))
        }
        let boundWorkspaceIdentities = Set(
            composition.evidenceAppendix.flatMap { $0.bindings.map(\.workspaceIdentity) }
        )
        let boundPaths = Set(
            composition.evidenceAppendix.flatMap { $0.bindings.map(\.relativePath) }
        )
        if Set(composition.scope.workspaceIdentities) != boundWorkspaceIdentities
            || Set(composition.scope.relativePaths) != boundPaths {
            failures.append(failure(
                .scopeEvidenceMismatch,
                detail: "The report scope must exactly match the workspace/path evidence bindings."
            ))
        }
        return uniqueFailures(failures)
    }

    private static func decision(
        for verdict: AssessmentExecutiveVerdict
    ) -> AssessmentRecommendationDecision {
        switch verdict {
        case .yes: return .proceedToValidation
        case .partial: return .conditionallyProceed
        case .no: return .doNotProceed
        case .unknown: return .investigate
        }
    }

    private static func deriveRecommendationSet(
        from composition: AssessmentReportComposition
    ) -> AssessmentRecommendationSet {
        let claimsByID = Dictionary(
            uniqueKeysWithValues: composition.evidenceAppendix.map { ($0.claimID, $0.claim) }
        )
        let decision = decision(for: composition.executiveVerdict)
        var recommendations: [AssessmentRecommendation] = []
        recommendations.append(
            decisionRecommendation(
                decision: decision,
                composition: composition,
                claimsByID: claimsByID
            )
        )
        recommendations.append(contentsOf: blockerRecommendations(
            composition: composition,
            claimsByID: claimsByID
        ))
        recommendations.append(contentsOf: securityRecommendations(
            composition: composition,
            claimsByID: claimsByID
        ))
        recommendations.append(contentsOf: investigationRecommendations(
            composition: composition,
            claimsByID: claimsByID
        ))
        recommendations.append(contentsOf: designRecommendations(
            composition: composition,
            claimsByID: claimsByID
        ))
        recommendations.append(
            validationRecommendation(
                composition: composition,
                claimsByID: claimsByID
            )
        )
        recommendations = uniqueRecommendations(recommendations).sorted(by: recommendationOrder)
        let sourceClaimIDs = unique(recommendations.flatMap(\.sourceClaimIDs)).sorted()
        let setID = stableSetID(
            sourceReportID: composition.reportID,
            binding: composition.binding,
            sourceVerdict: composition.executiveVerdict,
            sourceConfidence: composition.confidence,
            decision: decision,
            recommendations: recommendations,
            sourceClaimIDs: sourceClaimIDs,
            generatedAt: composition.composedAt,
            authority: .advisoryOnly,
            executionAuthorized: false
        )
        return AssessmentRecommendationSet(
            schemaVersion: AssessmentRecommendationSet.schemaVersion,
            recommendationSetID: setID,
            sourceReportID: composition.reportID,
            binding: composition.binding,
            sourceVerdict: composition.executiveVerdict,
            sourceConfidence: composition.confidence,
            decision: decision,
            recommendations: recommendations,
            sourceClaimIDs: sourceClaimIDs,
            generatedAt: composition.composedAt,
            authority: .advisoryOnly,
            executionAuthorized: false
        )
    }

    private static func decisionRecommendation(
        decision: AssessmentRecommendationDecision,
        composition: AssessmentReportComposition,
        claimsByID: [String: AssessmentClaim]
    ) -> AssessmentRecommendation {
        let preferredEntries = composition.sections.executiveSummary
            + composition.sections.capabilityCompatibilityMatrix
            + composition.sections.blockers
            + composition.sections.unknowns
        let sourceClaimIDs = sourceClaimIDs(
            entries: preferredEntries,
            fallback: composition.scope.includedClaimIDs
        )
        let sourceSections = unique(preferredEntries.map(\.section)).sorted(by: sectionOrder)
        let title: String
        let action: String
        let rationale: String
        let priority: AssessmentRecommendationPriority
        let conditions: [String]
        switch decision {
        case .proceedToValidation:
            title = "Proceed to bounded validation"
            action = "Proceed only to bounded, non-production validation of the evidence-supported integration scope."
            rationale = "The evidence-grounded report verdict is YES; build, test, runtime, deployment, and production behavior remain outside that verdict."
            priority = .medium
            conditions = [
                "Keep implementation and production rollout outside this advisory handoff.",
                "Preserve the report's workspace, task, session, and evidence lineage during validation planning."
            ]
        case .conditionallyProceed:
            title = "Proceed only with the supported subset"
            action = "Advance only the evidence-supported subset after every required condition is satisfied; do not treat unresolved capabilities as supported."
            rationale = "The evidence-grounded report verdict is PARTIAL."
            priority = .high
            conditions = [
                "Resolve or explicitly bound every blocker and material unknown before expanding scope.",
                "Recompose the assessment when new evidence changes compatibility."
            ]
        case .doNotProceed:
            title = "Hold integration handoff"
            action = "Do not proceed with integration until every evidence-backed blocker is remediated and the assessment is recomposed."
            rationale = "The evidence-grounded report verdict is NO."
            priority = .critical
            conditions = [
                "Do not bypass blocked requirements through direct data access or model-only policy decisions.",
                "Require new bounded evidence before changing this decision."
            ]
        case .investigate:
            title = "Collect missing decision evidence"
            action = "Do not proceed; collect bounded evidence for unresolved required capabilities and recompose the assessment."
            rationale = "The evidence-grounded report verdict is UNKNOWN."
            priority = .high
            conditions = [
                "Keep every unresolved capability in an explicit UNKNOWN state.",
                "Do not infer feasibility from missing evidence."
            ]
        }
        let validationCriteria = unique(sourceClaimIDs.flatMap { claimsByID[$0]?.unknowns ?? [] })
            + ["A new evidence-grounded report records the result of any follow-up investigation or validation."]
        return makeRecommendation(
            category: .decisionGate,
            priority: priority,
            title: title,
            action: action,
            rationale: rationale,
            sourceClaimIDs: sourceClaimIDs,
            sourceSections: sourceSections,
            targetCapabilityIDs: composition.scope.requiredCapabilityIDs,
            conditions: conditions,
            validationCriteria: unique(validationCriteria),
            requiresHumanApproval: decision != .investigate
        )
    }

    private static func blockerRecommendations(
        composition: AssessmentReportComposition,
        claimsByID: [String: AssessmentClaim]
    ) -> [AssessmentRecommendation] {
        let entries = composition.sections.blockers
            + composition.sections.capabilityCompatibilityMatrix.filter {
                $0.disposition == .blocked || $0.disposition == .incompatible
            }
        let grouped = Dictionary(grouping: entries) { entry in
            "\(entry.claimID):\(entry.capability?.rawValue ?? "general")"
        }
        return grouped.keys.sorted().compactMap { key in
            guard let values = grouped[key], let first = values.first,
                  let claim = claimsByID[first.claimID] else { return nil }
            let risk = values.compactMap(\.riskLevel).max(by: { riskRank($0) < riskRank($1) }) ?? .high
            let capabilityID = first.capability?.rawValue
            let capabilityName = first.capability?.displayName ?? "integration prerequisite"
            return makeRecommendation(
                category: .blockerRemediation,
                priority: priority(for: risk, blocker: true),
                title: "Resolve \(capabilityName) blocker",
                action: "Resolve the evidence-backed \(capabilityName) blocker before integration handoff, then collect new evidence and recompose the assessment.",
                rationale: claim.statement,
                sourceClaimIDs: [claim.claimID],
                sourceSections: unique(values.map(\.section)).sorted(by: sectionOrder),
                targetCapabilityIDs: capabilityID.map { [$0] } ?? [],
                conditions: claim.unknowns,
                validationCriteria: [
                    "The capability is reassessed from new bounded evidence and is no longer BLOCKED or INCOMPATIBLE."
                ],
                requiresHumanApproval: true
            )
        }
    }

    private static func securityRecommendations(
        composition: AssessmentReportComposition,
        claimsByID: [String: AssessmentClaim]
    ) -> [AssessmentRecommendation] {
        let entries = composition.sections.securityAndAuthorizationFindings
            + composition.sections.risks
        return entries.compactMap { entry in
            guard let risk = entry.riskLevel,
                  risk != .low,
                  let claim = claimsByID[entry.claimID] else { return nil }
            let domain = entry.riskDomain?.rawValue.replacingOccurrences(of: "_", with: " ").lowercased()
                ?? "integration"
            return makeRecommendation(
                category: .securityControl,
                priority: priority(for: risk, blocker: false),
                title: "Mitigate \(domain) risk",
                action: "Document and review a deterministic mitigation for the \(domain) risk before advancing the affected scope."
                    + (risk == .high ? " Require explicit human approval before implementation handoff." : ""),
                rationale: claim.statement,
                sourceClaimIDs: [claim.claimID],
                sourceSections: [entry.section],
                targetCapabilityIDs: entry.capability.map { [$0.rawValue] } ?? [],
                conditions: claim.unknowns,
                validationCriteria: [
                    "The mitigation is tied to a deterministic control and a bounded validation criterion outside the model."
                ],
                requiresHumanApproval: risk == .high
            )
        }
    }

    private static func investigationRecommendations(
        composition: AssessmentReportComposition,
        claimsByID: [String: AssessmentClaim]
    ) -> [AssessmentRecommendation] {
        let unresolvedEntries = composition.sections.unknowns
            + composition.sections.capabilityCompatibilityMatrix.filter {
                $0.disposition == .unknown || $0.disposition == .partial
            }
        var values: [AssessmentRecommendation] = []
        let grouped = Dictionary(grouping: unresolvedEntries) { entry in
            "\(entry.claimID):\(entry.capability?.rawValue ?? "general")"
        }
        for key in grouped.keys.sorted() {
            guard let entries = grouped[key], let first = entries.first,
                  let claim = claimsByID[first.claimID] else { continue }
            let target = first.capability?.displayName ?? first.title ?? "the unresolved finding"
            values.append(makeRecommendation(
                category: .evidenceInvestigation,
                priority: first.required ? .high : .medium,
                title: "Investigate \(target)",
                action: "Collect bounded read-only evidence for \(target), preserve TOOL_RESULT lineage, and recompose the assessment without inferring from absence.",
                rationale: claim.statement,
                sourceClaimIDs: [claim.claimID],
                sourceSections: unique(entries.map(\.section)).sorted(by: sectionOrder),
                targetCapabilityIDs: first.capability.map { [$0.rawValue] } ?? [],
                conditions: claim.unknowns,
                validationCriteria: [
                    "The follow-up produces a validated claim or preserves an explicit UNKNOWN conclusion."
                ],
                requiresHumanApproval: false
            ))
        }

        let representedCapabilities = Set(
            composition.sections.capabilityCompatibilityMatrix.compactMap { $0.capability?.rawValue }
        )
        let missingCapabilities = Set(composition.scope.requiredCapabilityIDs)
            .subtracting(representedCapabilities)
            .sorted()
        let fallbackClaimIDs = sourceClaimIDs(
            entries: composition.sections.executiveSummary
                + composition.sections.capabilityCompatibilityMatrix,
            fallback: composition.scope.includedClaimIDs
        )
        for capabilityID in missingCapabilities {
            values.append(makeRecommendation(
                category: .evidenceInvestigation,
                priority: .high,
                title: "Assess missing required capability \(capabilityID)",
                action: "Collect bounded read-only evidence for the required \(capabilityID) capability and recompose the compatibility matrix.",
                rationale: "The required capability is in report scope but has no validated compatibility entry.",
                sourceClaimIDs: fallbackClaimIDs,
                sourceSections: [.executiveSummary, .capabilityCompatibility],
                targetCapabilityIDs: [capabilityID],
                conditions: ["Do not infer support from the missing compatibility entry."],
                validationCriteria: ["A recomposed report includes one validated compatibility conclusion for the capability."],
                requiresHumanApproval: false
            ))
        }
        return values
    }

    private static func designRecommendations(
        composition: AssessmentReportComposition,
        claimsByID: [String: AssessmentClaim]
    ) -> [AssessmentRecommendation] {
        let explicit = composition.sections.recommendations
        let entries = explicit.isEmpty
            ? composition.sections.candidateIntegrationSeams
            : explicit
        return entries.compactMap { entry in
            guard let claim = claimsByID[entry.claimID] else { return nil }
            let path = entry.integrationPath
            let action: String
            if path.isEmpty {
                action = "Review the evidence-grounded design recommendation before any implementation handoff."
            } else {
                action = "Review the proposed mediated integration path: \(path.joined(separator: " -> "))."
            }
            return makeRecommendation(
                category: .integrationDesign,
                priority: .medium,
                title: entry.title ?? "Review the proposed integration design",
                action: action,
                rationale: claim.statement,
                sourceClaimIDs: [claim.claimID],
                sourceSections: [entry.section],
                targetCapabilityIDs: entry.capability.map { [$0.rawValue] } ?? [],
                conditions: claim.unknowns,
                validationCriteria: [
                    "Architecture and security owners approve the design as a proposal; approval does not authorize execution."
                ],
                requiresHumanApproval: true
            )
        }
    }

    private static func validationRecommendation(
        composition: AssessmentReportComposition,
        claimsByID: [String: AssessmentClaim]
    ) -> AssessmentRecommendation {
        let sourceEntries = composition.sections.capabilityCompatibilityMatrix
            + composition.sections.securityAndAuthorizationFindings
            + composition.sections.risks
        let sourceClaimIDs = sourceClaimIDs(
            entries: sourceEntries,
            fallback: composition.scope.includedClaimIDs
        )
        let unknowns = unique(sourceClaimIDs.flatMap { claimsByID[$0]?.unknowns ?? [] })
        return makeRecommendation(
            category: .validation,
            priority: composition.executiveVerdict == .yes ? .high : .medium,
            title: "Define bounded validation before implementation",
            action: "Create a reviewable non-production validation plan for the recommended scope; this recommendation does not execute tests, modify code, deploy, or grant runtime authority.",
            rationale: "All source claims preserve static-only verification status.",
            sourceClaimIDs: sourceClaimIDs,
            sourceSections: unique(sourceEntries.map(\.section)).sorted(by: sectionOrder),
            targetCapabilityIDs: composition.scope.requiredCapabilityIDs,
            conditions: unknowns,
            validationCriteria: [
                "The plan covers permission, data-contract, failure, rollback, authentication, audit, and approval controls as applicable.",
                "Any later execution requires its own existing admission, policy, approval, and authority checks."
            ],
            requiresHumanApproval: true
        )
    }

    private static func makeRecommendation(
        category: AssessmentRecommendationCategory,
        priority: AssessmentRecommendationPriority,
        title: String,
        action: String,
        rationale: String,
        sourceClaimIDs: [String],
        sourceSections: [AssessmentReportClaimSection],
        targetCapabilityIDs: [String],
        conditions: [String],
        validationCriteria: [String],
        requiresHumanApproval: Bool
    ) -> AssessmentRecommendation {
        let canonicalClaimIDs = unique(sourceClaimIDs).sorted()
        let canonicalSections = unique(sourceSections).sorted(by: sectionOrder)
        let canonicalCapabilities = unique(targetCapabilityIDs).sorted()
        let canonicalConditions = unique(conditions)
        let canonicalCriteria = unique(validationCriteria)
        let recommendationID = stableRecommendationID(
            category: category,
            priority: priority,
            title: title,
            action: action,
            rationale: rationale,
            sourceClaimIDs: canonicalClaimIDs,
            sourceSections: canonicalSections,
            targetCapabilityIDs: canonicalCapabilities,
            conditions: canonicalConditions,
            validationCriteria: canonicalCriteria,
            requiresHumanApproval: requiresHumanApproval
        )
        return AssessmentRecommendation(
            recommendationID: recommendationID,
            category: category,
            priority: priority,
            title: title,
            action: action,
            rationale: rationale,
            sourceClaimIDs: canonicalClaimIDs,
            sourceSections: canonicalSections,
            targetCapabilityIDs: canonicalCapabilities,
            conditions: canonicalConditions,
            validationCriteria: canonicalCriteria,
            requiresHumanApproval: requiresHumanApproval,
            authority: .advisoryOnly,
            executionAuthorized: false
        )
    }

    private struct RecommendationIdentityMaterial: Codable {
        var schemaVersion: String
        var category: AssessmentRecommendationCategory
        var priority: AssessmentRecommendationPriority
        var title: String
        var action: String
        var rationale: String
        var sourceClaimIDs: [String]
        var sourceSections: [AssessmentReportClaimSection]
        var targetCapabilityIDs: [String]
        var conditions: [String]
        var validationCriteria: [String]
        var requiresHumanApproval: Bool
        var authority: AssessmentRecommendationAuthority
        var executionAuthorized: Bool
    }

    private static func stableRecommendationID(
        category: AssessmentRecommendationCategory,
        priority: AssessmentRecommendationPriority,
        title: String,
        action: String,
        rationale: String,
        sourceClaimIDs: [String],
        sourceSections: [AssessmentReportClaimSection],
        targetCapabilityIDs: [String],
        conditions: [String],
        validationCriteria: [String],
        requiresHumanApproval: Bool
    ) -> String {
        let material = RecommendationIdentityMaterial(
            schemaVersion: AssessmentRecommendationSet.schemaVersion,
            category: category,
            priority: priority,
            title: title,
            action: action,
            rationale: rationale,
            sourceClaimIDs: sourceClaimIDs,
            sourceSections: sourceSections,
            targetCapabilityIDs: targetCapabilityIDs,
            conditions: conditions,
            validationCriteria: validationCriteria,
            requiresHumanApproval: requiresHumanApproval,
            authority: .advisoryOnly,
            executionAuthorized: false
        )
        return "assessment-recommendation-\(sha256(encoded(material)))"
    }

    private struct RecommendationSetIdentityMaterial: Codable {
        var schemaVersion: String
        var sourceReportID: String
        var binding: AssessmentReportBinding
        var sourceVerdict: AssessmentExecutiveVerdict
        var sourceConfidence: AssessmentClaimConfidence
        var decision: AssessmentRecommendationDecision
        var recommendations: [AssessmentRecommendation]
        var sourceClaimIDs: [String]
        var generatedAt: Date
        var authority: AssessmentRecommendationAuthority
        var executionAuthorized: Bool
    }

    private static func stableSetID(
        sourceReportID: String,
        binding: AssessmentReportBinding,
        sourceVerdict: AssessmentExecutiveVerdict,
        sourceConfidence: AssessmentClaimConfidence,
        decision: AssessmentRecommendationDecision,
        recommendations: [AssessmentRecommendation],
        sourceClaimIDs: [String],
        generatedAt: Date,
        authority: AssessmentRecommendationAuthority,
        executionAuthorized: Bool
    ) -> String {
        let material = RecommendationSetIdentityMaterial(
            schemaVersion: AssessmentRecommendationSet.schemaVersion,
            sourceReportID: sourceReportID,
            binding: binding,
            sourceVerdict: sourceVerdict,
            sourceConfidence: sourceConfidence,
            decision: decision,
            recommendations: recommendations,
            sourceClaimIDs: sourceClaimIDs,
            generatedAt: generatedAt,
            authority: authority,
            executionAuthorized: executionAuthorized
        )
        return "assessment-recommendation-set-\(sha256(encoded(material)))"
    }

    private static func sourceClaimIDs(
        entries: [AssessmentReportSectionEntry],
        fallback: [String]
    ) -> [String] {
        let values = unique(entries.map(\.claimID)).sorted()
        return values.isEmpty ? unique(fallback).sorted() : values
    }

    private static func recommendationOrder(
        _ lhs: AssessmentRecommendation,
        _ rhs: AssessmentRecommendation
    ) -> Bool {
        if priorityRank(lhs.priority) != priorityRank(rhs.priority) {
            return priorityRank(lhs.priority) < priorityRank(rhs.priority)
        }
        if categoryRank(lhs.category) != categoryRank(rhs.category) {
            return categoryRank(lhs.category) < categoryRank(rhs.category)
        }
        return lhs.recommendationID < rhs.recommendationID
    }

    private static func sectionOrder(
        _ lhs: AssessmentReportClaimSection,
        _ rhs: AssessmentReportClaimSection
    ) -> Bool {
        let allCases = AssessmentReportClaimSection.allCases
        return (allCases.firstIndex(of: lhs) ?? allCases.count)
            < (allCases.firstIndex(of: rhs) ?? allCases.count)
    }

    private static func priority(
        for risk: AssessmentRiskLevel,
        blocker: Bool
    ) -> AssessmentRecommendationPriority {
        switch (risk, blocker) {
        case (.high, true): return .critical
        case (.high, false), (.medium, true): return .high
        case (.medium, false), (.low, true): return .medium
        case (.low, false): return .low
        }
    }

    private static func priorityRank(_ value: AssessmentRecommendationPriority) -> Int {
        switch value {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }

    private static func categoryRank(_ value: AssessmentRecommendationCategory) -> Int {
        AssessmentRecommendationCategory.allCases.firstIndex(of: value)
            ?? AssessmentRecommendationCategory.allCases.count
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

    private static func uniqueRecommendations(
        _ values: [AssessmentRecommendation]
    ) -> [AssessmentRecommendation] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.recommendationID).inserted }
    }

    private static func failure(
        _ code: AssessmentRecommendationValidationFailureCode,
        claimID: String? = nil,
        recommendationID: String? = nil,
        detail: String
    ) -> AssessmentRecommendationValidationFailure {
        AssessmentRecommendationValidationFailure(
            code: code,
            claimID: claimID,
            recommendationID: recommendationID,
            detail: detail
        )
    }

    private static func uniqueFailures(
        _ values: [AssessmentRecommendationValidationFailure]
    ) -> [AssessmentRecommendationValidationFailure] {
        var seen: Set<String> = []
        return values.sorted {
            if $0.code.rawValue != $1.code.rawValue { return $0.code.rawValue < $1.code.rawValue }
            if ($0.claimID ?? "") != ($1.claimID ?? "") { return ($0.claimID ?? "") < ($1.claimID ?? "") }
            return ($0.recommendationID ?? "") < ($1.recommendationID ?? "")
        }.filter { seen.insert($0.id).inserted }
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
}

extension FDEAIIntegrationAssessmentReport {
    func phase3B4Recommendations() -> AssessmentRecommendationResult {
        AssessmentRecommendationEngine.generate(from: self)
    }
}

enum AssessmentRecommendationPersistenceError: LocalizedError, Equatable {
    case missingPayload
    case digestMismatch
    case identityMismatch
    case bindingMismatch

    var errorDescription: String? {
        switch self {
        case .missingPayload: return "The persisted Phase 3B.4 recommendation payload is incomplete."
        case .digestMismatch: return "The persisted recommendation digest does not match its encoded content."
        case .identityMismatch: return "The persisted recommendation identity does not match its content."
        case .bindingMismatch: return "The persisted recommendation event binding does not match the source assessment."
        }
    }
}

extension AssessmentRecommendationSet {
    func markdown(language: ReadOnlyResponseLanguage = .english) -> String {
        let title = language == .chinese
            ? "# Phase 3B.4 评估建议"
            : "# Phase 3B.4 Assessment Recommendations"
        var lines = [
            title,
            "",
            "- Recommendation set: `\(recommendationSetID)`",
            "- Source report: `\(sourceReportID)`",
            "- Decision: **\(decision.rawValue)**",
            "- Authority: **\(authority.rawValue)**",
            "- Execution authorized: **NO**",
            ""
        ]
        for recommendation in recommendations {
            lines += [
                "## \(recommendation.title)",
                "",
                "- Priority: **\(recommendation.priority.rawValue)**",
                "- Category: `\(recommendation.category.rawValue)`",
                "- Action: \(recommendation.action)",
                "- Rationale: \(recommendation.rationale)",
                "- Source claims: \(recommendation.sourceClaimIDs.map { "`\($0)`" }.joined(separator: ", "))",
                "- Human approval required: \(recommendation.requiresHumanApproval ? "YES" : "NO")",
                ""
            ]
        }
        return lines.joined(separator: "\n")
    }

    func persistenceEventPayload() throws -> [String: String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AssessmentRecommendationPersistenceError.missingPayload
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return [
            "lifecycle_event": "AI_ASSESSMENT_RECOMMENDATIONS_GENERATED",
            "assessment_recommendation_schema": schemaVersion,
            "assessment_recommendation_set_id": recommendationSetID,
            "assessment_recommendation_source_report_id": sourceReportID,
            "assessment_recommendation_json": json,
            "assessment_recommendation_sha256": digest,
            "assessment_recommendation_decision": decision.rawValue,
            "assessment_recommendation_authority": authority.rawValue,
            "assessment_recommendation_execution_authorized": String(executionAuthorized),
            "assessment_recommendation_workspace_id": binding.workspaceID.uuidString,
            "assessment_recommendation_task_id": binding.taskID.uuidString,
            "assessment_recommendation_session_id": binding.sessionID.uuidString
        ]
    }

    static func reload(from event: ExecutionEvent) throws -> AssessmentRecommendationSet {
        let value = try reload(from: event.payload)
        guard value.binding.workspaceID == event.workspaceID,
              value.binding.taskID == event.taskID else {
            throw AssessmentRecommendationPersistenceError.bindingMismatch
        }
        return value
    }

    static func reload(from payload: [String: String]) throws -> AssessmentRecommendationSet {
        guard payload["lifecycle_event"] == "AI_ASSESSMENT_RECOMMENDATIONS_GENERATED",
              let setID = payload["assessment_recommendation_set_id"],
              let json = payload["assessment_recommendation_json"],
              let expectedDigest = payload["assessment_recommendation_sha256"],
              let data = json.data(using: .utf8) else {
            throw AssessmentRecommendationPersistenceError.missingPayload
        }
        let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard expectedDigest == actualDigest else {
            throw AssessmentRecommendationPersistenceError.digestMismatch
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(AssessmentRecommendationSet.self, from: data)
        guard value.schemaVersion == AssessmentRecommendationSet.schemaVersion,
              value.recommendationSetID == setID,
              value.recommendationSetID == AssessmentRecommendationEngine.reconstructRecommendationSetID(value),
              AssessmentRecommendationEngine.validateIntegrity(value).isEmpty,
              value.sourceReportID == payload["assessment_recommendation_source_report_id"],
              value.decision.rawValue == payload["assessment_recommendation_decision"],
              value.authority == .advisoryOnly,
              value.authority.rawValue == payload["assessment_recommendation_authority"],
              !value.executionAuthorized,
              payload["assessment_recommendation_execution_authorized"] == "false" else {
            throw AssessmentRecommendationPersistenceError.identityMismatch
        }
        guard value.binding.workspaceID.uuidString == payload["assessment_recommendation_workspace_id"],
              value.binding.taskID.uuidString == payload["assessment_recommendation_task_id"],
              value.binding.sessionID.uuidString == payload["assessment_recommendation_session_id"] else {
            throw AssessmentRecommendationPersistenceError.bindingMismatch
        }
        return value
    }
}
