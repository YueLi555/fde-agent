import CryptoKit
import Foundation

/// Phase 3B.5 records a human disposition of an advisory recommendation set.
/// It is deliberately separate from ApprovalRequest and cannot grant execution
/// authority, even when the reviewer acknowledges the assessment for planning.
enum AssessmentHumanReviewStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case awaitingReview = "AWAITING_REVIEW"
    case acknowledgedForPlanning = "ACKNOWLEDGED_FOR_PLANNING"
    case changesRequested = "CHANGES_REQUESTED"
    case rejected = "REJECTED"
}

enum AssessmentHumanReviewDisposition: String, Codable, CaseIterable, Hashable, Sendable {
    case acknowledgeForPlanning = "ACKNOWLEDGE_FOR_PLANNING"
    case requestChanges = "REQUEST_CHANGES"
    case rejectRecommendations = "REJECT_RECOMMENDATIONS"
}

enum AssessmentHumanReviewAuthority: String, Codable, CaseIterable, Hashable, Sendable {
    case advisoryReviewOnly = "ADVISORY_REVIEW_ONLY"
}

struct AssessmentHumanReviewDecision: Codable, Hashable, Sendable, Identifiable {
    var decisionID: String
    var reviewID: String
    var sourceReportID: String
    var recommendationSetID: String
    var sourceDigests: AssessmentHumanReviewSourceDigests
    var binding: AssessmentReportBinding
    var submissionBinding: AssessmentHumanReviewSubmissionBinding
    var disposition: AssessmentHumanReviewDisposition
    var reviewerID: String
    var reviewerNote: String?
    var reviewedRecommendationIDs: [String]
    var sourceClaimIDs: [String]
    var decidedAt: Date
    var authority: AssessmentHumanReviewAuthority
    var executionAuthorized: Bool

    var id: String { decisionID }

    // A Phase 3B.5 disposition is evidence for future planning only. These
    // explicit false capabilities make the authority boundary reviewable and
    // prevent callers from treating acknowledgement as an approval token.
    var approvalRequestCreated: Bool { false }
    var candidatePatchAuthorized: Bool { false }
    var evalAuthorized: Bool { false }
    var executionAdmissionGranted: Bool { false }
    var validationAuthorized: Bool { false }
    var mutationAuthorized: Bool { false }
    var shellAuthorized: Bool { false }
    var gitAuthorized: Bool { false }
    var deploymentAuthorized: Bool { false }
    var productionAccessAuthorized: Bool { false }
}

struct AssessmentHumanReviewSourceDigests: Codable, Hashable, Sendable {
    var reportSHA256: String
    var recommendationSetSHA256: String
}

/// Exact authority-free binding captured when the user submits an assessment
/// disposition. Mission and current application-session identity are retained
/// for audit and replay, but never become runtime authority.
struct AssessmentHumanReviewSubmissionBinding: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var missionID: UUID
    var taskID: UUID
    var agentSessionID: UUID
    var sourceReportID: String
    var sourceReportSHA256: String
    var recommendationSetID: String
    var recommendationSetSHA256: String
    var reviewID: String
    var authenticatedLocalSessionID: UUID
    var workspaceSessionID: UUID
    var appSessionID: UUID
}

struct AssessmentHumanReviewRecord: Codable, Hashable, Sendable, Identifiable {
    static let schemaVersion = "3B.5"

    var schemaVersion: String
    var reviewID: String
    var sourceReportID: String
    var recommendationSetID: String
    var sourceDigests: AssessmentHumanReviewSourceDigests
    var binding: AssessmentReportBinding
    var missionID: UUID
    var sourceDecision: AssessmentRecommendationDecision
    var recommendationIDs: [String]
    var sourceClaimIDs: [String]
    var status: AssessmentHumanReviewStatus
    var decision: AssessmentHumanReviewDecision?
    var openedAt: Date
    var updatedAt: Date
    var authority: AssessmentHumanReviewAuthority
    var executionAuthorized: Bool

    var id: String { reviewID }
    var isPending: Bool { status == .awaitingReview && decision == nil }
    var isFinalized: Bool { !isPending }

    /// Acknowledging an advisory assessment is never an execution approval.
    var approvalGranted: Bool { false }
    var reviewState: AssessmentHumanReviewStatus { status }
    var reviewDecision: AssessmentHumanReviewDecision? { decision }
    var executionApprovalGranted: Bool { false }
    var approvalRequestCreated: Bool { false }
    var candidatePatchAuthorized: Bool { false }
    var evalAuthorized: Bool { false }
    var executionAdmissionGranted: Bool { false }
    var validationAuthorized: Bool { false }
    var mutationAuthorized: Bool { false }
    var shellAuthorized: Bool { false }
    var gitAuthorized: Bool { false }
    var deploymentAuthorized: Bool { false }
    var productionAccessAuthorized: Bool { false }
}

/// Exact caller authority for the single Phase 3B.5 disposition. This binds
/// review to the immutable report/recommendation pair and its Agent session.
struct AssessmentHumanReviewContext: Codable, Hashable, Sendable {
    var submissionBinding: AssessmentHumanReviewSubmissionBinding
    var reviewerID: String

    init(
        submissionBinding: AssessmentHumanReviewSubmissionBinding,
        reviewerID: String
    ) {
        self.submissionBinding = submissionBinding
        self.reviewerID = reviewerID
    }

    init(
        record: AssessmentHumanReviewRecord,
        missionID: UUID,
        authenticatedLocalSessionID: UUID,
        workspaceSessionID: UUID,
        appSessionID: UUID
    ) {
        self.init(
            submissionBinding: AssessmentHumanReviewSubmissionBinding(
                workspaceID: record.binding.workspaceID,
                missionID: missionID,
                taskID: record.binding.taskID,
                agentSessionID: record.binding.sessionID,
                sourceReportID: record.sourceReportID,
                sourceReportSHA256: record.sourceDigests.reportSHA256,
                recommendationSetID: record.recommendationSetID,
                recommendationSetSHA256: record.sourceDigests.recommendationSetSHA256,
                reviewID: record.reviewID,
                authenticatedLocalSessionID: authenticatedLocalSessionID,
                workspaceSessionID: workspaceSessionID,
                appSessionID: appSessionID
            ),
            reviewerID: authenticatedLocalSessionID.uuidString
        )
    }
}

struct AssessmentHumanReviewBundle: Hashable, Sendable, Identifiable {
    var report: FDEAIIntegrationAssessmentReport
    var recommendationSet: AssessmentRecommendationSet
    var review: AssessmentHumanReviewRecord

    var id: String { review.reviewID }
}

struct AssessmentHumanReviewEligibility: Equatable, Sendable {
    var isAvailable: Bool
    var unavailableReason: String?

    static let available = AssessmentHumanReviewEligibility(
        isAvailable: true,
        unavailableReason: nil
    )

    static func unavailable(_ reason: String) -> AssessmentHumanReviewEligibility {
        AssessmentHumanReviewEligibility(isAvailable: false, unavailableReason: reason)
    }
}

enum AssessmentHumanReviewValidationFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case unsupportedSchema = "UNSUPPORTED_SCHEMA"
    case invalidSourceReport = "INVALID_SOURCE_REPORT"
    case invalidRecommendationSet = "INVALID_RECOMMENDATION_SET"
    case sourceIdentityMismatch = "SOURCE_IDENTITY_MISMATCH"
    case bindingMismatch = "BINDING_MISMATCH"
    case invalidAuthority = "INVALID_AUTHORITY"
    case reviewIdentityMismatch = "REVIEW_IDENTITY_MISMATCH"
    case recommendationScopeMismatch = "RECOMMENDATION_SCOPE_MISMATCH"
    case invalidReviewState = "INVALID_REVIEW_STATE"
    case decisionIdentityMismatch = "DECISION_IDENTITY_MISMATCH"
}

struct AssessmentHumanReviewValidationFailure: Codable, Hashable, Sendable, Identifiable {
    var code: AssessmentHumanReviewValidationFailureCode
    var detail: String

    var id: String { "\(code.rawValue):\(detail)" }
}

enum AssessmentHumanReviewFailure: LocalizedError, Equatable {
    case invalidSourceArtifact
    case bindingMismatch
    case reviewNotPending
    case reviewerIdentityRequired
    case reviewerNoteRequired
    case invalidReviewRecord
    case missingPersistencePayload
    case persistenceDigestMismatch
    case persistenceIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSourceArtifact:
            return "The assessment report or recommendation set failed its evidence and identity contract."
        case .bindingMismatch:
            return "The review action is not bound to the exact workspace, Mission, task, Agent session, source artifacts, and current app session."
        case .reviewNotPending:
            return "This exact assessment recommendation set already has a final human disposition."
        case .reviewerIdentityRequired:
            return "An authenticated reviewer identity is required."
        case .reviewerNoteRequired:
            return "A reviewer note is required when changes are requested."
        case .invalidReviewRecord:
            return "The assessment human-review record failed validation."
        case .missingPersistencePayload:
            return "The persisted assessment human-review payload is incomplete."
        case .persistenceDigestMismatch:
            return "The persisted assessment human-review digest does not match its encoded content."
        case .persistenceIdentityMismatch:
            return "The persisted assessment human-review identity does not match its content."
        }
    }
}

enum AssessmentHumanReviewWorkflow {
    static func prepare(
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet
    ) throws -> AssessmentHumanReviewRecord {
        guard let composition = report.composition,
              AssessmentRecommendationEngine.validate(recommendationSet, against: report).isEmpty else {
            throw AssessmentHumanReviewFailure.invalidSourceArtifact
        }
        let sourceDigests = try sourceDigests(
            report: report,
            recommendationSet: recommendationSet
        )
        let recommendationIDs = recommendationSet.recommendations.map(\.recommendationID)
        let sourceClaimIDs = recommendationSet.sourceClaimIDs
        let reviewID = stableReviewID(
            sourceReportID: composition.reportID,
            recommendationSetID: recommendationSet.recommendationSetID,
            sourceDigests: sourceDigests,
            binding: composition.binding,
            missionID: composition.binding.taskID,
            sourceDecision: recommendationSet.decision,
            recommendationIDs: recommendationIDs,
            sourceClaimIDs: sourceClaimIDs,
            openedAt: recommendationSet.generatedAt
        )
        let record = AssessmentHumanReviewRecord(
            schemaVersion: AssessmentHumanReviewRecord.schemaVersion,
            reviewID: reviewID,
            sourceReportID: composition.reportID,
            recommendationSetID: recommendationSet.recommendationSetID,
            sourceDigests: sourceDigests,
            binding: composition.binding,
            missionID: composition.binding.taskID,
            sourceDecision: recommendationSet.decision,
            recommendationIDs: recommendationIDs,
            sourceClaimIDs: sourceClaimIDs,
            status: .awaitingReview,
            decision: nil,
            openedAt: recommendationSet.generatedAt,
            updatedAt: recommendationSet.generatedAt,
            authority: .advisoryReviewOnly,
            executionAuthorized: false
        )
        guard validate(record, against: recommendationSet, report: report).isEmpty else {
            throw AssessmentHumanReviewFailure.invalidReviewRecord
        }
        return record
    }

    static func open(
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet
    ) throws -> AssessmentHumanReviewRecord {
        try prepare(report: report, recommendationSet: recommendationSet)
    }

    static func begin(
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet
    ) throws -> AssessmentHumanReviewRecord {
        try prepare(report: report, recommendationSet: recommendationSet)
    }

    static func record(
        _ record: AssessmentHumanReviewRecord,
        disposition: AssessmentHumanReviewDisposition,
        note: String? = nil,
        context: AssessmentHumanReviewContext,
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet,
        now: Date = Date()
    ) throws -> AssessmentHumanReviewRecord {
        guard validate(record, against: recommendationSet, report: report).isEmpty else {
            throw AssessmentHumanReviewFailure.invalidReviewRecord
        }
        guard record.isPending else {
            throw AssessmentHumanReviewFailure.reviewNotPending
        }
        guard submissionBindingIsExact(context.submissionBinding, for: record),
              context.reviewerID == context.submissionBinding.authenticatedLocalSessionID.uuidString else {
            throw AssessmentHumanReviewFailure.bindingMismatch
        }
        let reviewerID = context.reviewerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reviewerID.isEmpty else {
            throw AssessmentHumanReviewFailure.reviewerIdentityRequired
        }
        let reviewerNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if disposition == .requestChanges, reviewerNote?.isEmpty != false {
            throw AssessmentHumanReviewFailure.reviewerNoteRequired
        }
        guard now >= record.openedAt else {
            throw AssessmentHumanReviewFailure.invalidReviewRecord
        }

        let decisionID = stableDecisionID(
            reviewID: record.reviewID,
            sourceReportID: record.sourceReportID,
            recommendationSetID: record.recommendationSetID,
            sourceDigests: record.sourceDigests,
            binding: record.binding,
            submissionBinding: context.submissionBinding,
            disposition: disposition,
            reviewerID: reviewerID,
            reviewerNote: reviewerNote?.isEmpty == false ? reviewerNote : nil,
            reviewedRecommendationIDs: record.recommendationIDs,
            sourceClaimIDs: record.sourceClaimIDs,
            decidedAt: now
        )
        let decision = AssessmentHumanReviewDecision(
            decisionID: decisionID,
            reviewID: record.reviewID,
            sourceReportID: record.sourceReportID,
            recommendationSetID: record.recommendationSetID,
            sourceDigests: record.sourceDigests,
            binding: record.binding,
            submissionBinding: context.submissionBinding,
            disposition: disposition,
            reviewerID: reviewerID,
            reviewerNote: reviewerNote?.isEmpty == false ? reviewerNote : nil,
            reviewedRecommendationIDs: record.recommendationIDs,
            sourceClaimIDs: record.sourceClaimIDs,
            decidedAt: now,
            authority: .advisoryReviewOnly,
            executionAuthorized: false
        )
        var updated = record
        updated.status = status(for: disposition)
        updated.decision = decision
        updated.updatedAt = now
        updated.authority = .advisoryReviewOnly
        updated.executionAuthorized = false
        guard validate(updated, against: recommendationSet, report: report).isEmpty else {
            throw AssessmentHumanReviewFailure.invalidReviewRecord
        }
        return updated
    }

    static func review(
        _ record: AssessmentHumanReviewRecord,
        disposition: AssessmentHumanReviewDisposition,
        note: String? = nil,
        context: AssessmentHumanReviewContext,
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet,
        now: Date = Date()
    ) throws -> AssessmentHumanReviewRecord {
        try self.record(
            record,
            disposition: disposition,
            note: note,
            context: context,
            report: report,
            recommendationSet: recommendationSet,
            now: now
        )
    }

    static func acknowledgeForPlanning(
        _ record: AssessmentHumanReviewRecord,
        note: String? = nil,
        context: AssessmentHumanReviewContext,
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet,
        now: Date = Date()
    ) throws -> AssessmentHumanReviewRecord {
        try self.record(
            record,
            disposition: .acknowledgeForPlanning,
            note: note,
            context: context,
            report: report,
            recommendationSet: recommendationSet,
            now: now
        )
    }

    static func requestChanges(
        _ record: AssessmentHumanReviewRecord,
        instructions: String,
        context: AssessmentHumanReviewContext,
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet,
        now: Date = Date()
    ) throws -> AssessmentHumanReviewRecord {
        try self.record(
            record,
            disposition: .requestChanges,
            note: instructions,
            context: context,
            report: report,
            recommendationSet: recommendationSet,
            now: now
        )
    }

    static func reject(
        _ record: AssessmentHumanReviewRecord,
        note: String? = nil,
        context: AssessmentHumanReviewContext,
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet,
        now: Date = Date()
    ) throws -> AssessmentHumanReviewRecord {
        try self.record(
            record,
            disposition: .rejectRecommendations,
            note: note,
            context: context,
            report: report,
            recommendationSet: recommendationSet,
            now: now
        )
    }

    static func validate(
        _ record: AssessmentHumanReviewRecord,
        against recommendationSet: AssessmentRecommendationSet,
        report: FDEAIIntegrationAssessmentReport
    ) -> [AssessmentHumanReviewValidationFailure] {
        guard let composition = report.composition else {
            return [failure(.invalidSourceReport, "Phase 3B.5 requires a Phase 3B.3B report composition.")]
        }
        var failures = validateIntegrity(record)
        if !AssessmentRecommendationEngine.validate(recommendationSet, against: report).isEmpty {
            failures.append(failure(
                .invalidRecommendationSet,
                "The Phase 3B.4 recommendation set does not validate against the source report."
            ))
        }
        if record.sourceReportID != composition.reportID
            || record.recommendationSetID != recommendationSet.recommendationSetID {
            failures.append(failure(
                .sourceIdentityMismatch,
                "The review must identify the exact source report and recommendation set."
            ))
        }
        if record.binding != composition.binding || record.binding != recommendationSet.binding {
            failures.append(failure(
                .bindingMismatch,
                "The review workspace/task/session binding differs from its source artifacts."
            ))
        }
        if record.missionID != composition.binding.taskID {
            failures.append(failure(
                .bindingMismatch,
                "The assessment review Mission must match the source assessment task."
            ))
        }
        do {
            if record.sourceDigests != (try sourceDigests(
                report: report,
                recommendationSet: recommendationSet
            )) {
                failures.append(failure(
                    .sourceIdentityMismatch,
                    "The review must retain the exact report and recommendation artifact digests."
                ))
            }
        } catch {
            failures.append(failure(
                .invalidSourceReport,
                "The source artifact digest could not be reconstructed."
            ))
        }
        if record.sourceDecision != recommendationSet.decision
            || record.recommendationIDs != recommendationSet.recommendations.map(\.recommendationID)
            || record.sourceClaimIDs != recommendationSet.sourceClaimIDs {
            failures.append(failure(
                .recommendationScopeMismatch,
                "The review scope must cover the complete immutable recommendation set and claim lineage."
            ))
        }
        if record.openedAt != recommendationSet.generatedAt {
            failures.append(failure(
                .sourceIdentityMismatch,
                "The review opening time must derive from the immutable recommendation artifact."
            ))
        }
        return unique(failures)
    }

    static func validateIntegrity(
        _ record: AssessmentHumanReviewRecord
    ) -> [AssessmentHumanReviewValidationFailure] {
        var failures: [AssessmentHumanReviewValidationFailure] = []
        if record.schemaVersion != AssessmentHumanReviewRecord.schemaVersion {
            failures.append(failure(.unsupportedSchema, "Only the Phase 3B.5 review schema is accepted."))
        }
        if record.authority != .advisoryReviewOnly || record.executionAuthorized || record.approvalGranted {
            failures.append(failure(
                .invalidAuthority,
                "A human assessment review is advisory-only and can never authorize execution."
            ))
        }
        if !isSHA256(record.sourceDigests.reportSHA256)
            || !isSHA256(record.sourceDigests.recommendationSetSHA256) {
            failures.append(failure(
                .sourceIdentityMismatch,
                "The review requires exact SHA-256 digests for both source artifacts."
            ))
        }
        if record.missionID != record.binding.taskID {
            failures.append(failure(
                .bindingMismatch,
                "The review Mission and assessment task binding must be exact."
            ))
        }
        if record.recommendationIDs.isEmpty
            || record.sourceClaimIDs.isEmpty
            || Set(record.recommendationIDs).count != record.recommendationIDs.count
            || Set(record.sourceClaimIDs).count != record.sourceClaimIDs.count {
            failures.append(failure(
                .recommendationScopeMismatch,
                "The review must retain a non-empty, unique recommendation and source-claim scope."
            ))
        }
        if record.reviewID != reconstructReviewID(record) {
            failures.append(failure(
                .reviewIdentityMismatch,
                "The review identifier does not match its immutable source scope."
            ))
        }
        if record.updatedAt < record.openedAt {
            failures.append(failure(.invalidReviewState, "Review chronology is invalid."))
        }

        switch (record.status, record.decision) {
        case (.awaitingReview, .none):
            if record.updatedAt != record.openedAt {
                failures.append(failure(
                    .invalidReviewState,
                    "An awaiting review cannot contain an unrecorded update."
                ))
            }
        case (.acknowledgedForPlanning, .some(let decision)):
            failures.append(contentsOf: validate(decision, expected: .acknowledgeForPlanning, record: record))
        case (.changesRequested, .some(let decision)):
            failures.append(contentsOf: validate(decision, expected: .requestChanges, record: record))
            if decision.reviewerNote?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                failures.append(failure(
                    .invalidReviewState,
                    "A change request must preserve non-empty reviewer instructions."
                ))
            }
        case (.rejected, .some(let decision)):
            failures.append(contentsOf: validate(decision, expected: .rejectRecommendations, record: record))
        default:
            failures.append(failure(
                .invalidReviewState,
                "The review status and single final decision do not agree."
            ))
        }
        return unique(failures)
    }

    static func reconstructReviewID(_ record: AssessmentHumanReviewRecord) -> String {
        stableReviewID(
            sourceReportID: record.sourceReportID,
            recommendationSetID: record.recommendationSetID,
            sourceDigests: record.sourceDigests,
            binding: record.binding,
            missionID: record.missionID,
            sourceDecision: record.sourceDecision,
            recommendationIDs: record.recommendationIDs,
            sourceClaimIDs: record.sourceClaimIDs,
            openedAt: record.openedAt
        )
    }

    static func reconstructDecisionID(_ decision: AssessmentHumanReviewDecision) -> String {
        stableDecisionID(
            reviewID: decision.reviewID,
            sourceReportID: decision.sourceReportID,
            recommendationSetID: decision.recommendationSetID,
            sourceDigests: decision.sourceDigests,
            binding: decision.binding,
            submissionBinding: decision.submissionBinding,
            disposition: decision.disposition,
            reviewerID: decision.reviewerID,
            reviewerNote: decision.reviewerNote,
            reviewedRecommendationIDs: decision.reviewedRecommendationIDs,
            sourceClaimIDs: decision.sourceClaimIDs,
            decidedAt: decision.decidedAt
        )
    }

    static func eligibility(
        for bundle: AssessmentHumanReviewBundle,
        submissionBinding: AssessmentHumanReviewSubmissionBinding
    ) -> AssessmentHumanReviewEligibility {
        guard validate(
            bundle.review,
            against: bundle.recommendationSet,
            report: bundle.report
        ).isEmpty else {
            return .unavailable("The review artifact or evidence lineage failed validation.")
        }
        guard submissionBindingIsExact(submissionBinding, for: bundle.review) else {
            return .unavailable("This review is not bound to the exact workspace, Mission, task, Agent session, source digests, and current app session.")
        }
        guard bundle.review.isPending else {
            return .unavailable("This exact recommendation set already has a final human disposition.")
        }
        return .available
    }

    private static func validate(
        _ decision: AssessmentHumanReviewDecision,
        expected disposition: AssessmentHumanReviewDisposition,
        record: AssessmentHumanReviewRecord
    ) -> [AssessmentHumanReviewValidationFailure] {
        var failures: [AssessmentHumanReviewValidationFailure] = []
        if decision.disposition != disposition
            || decision.reviewID != record.reviewID
            || decision.sourceReportID != record.sourceReportID
            || decision.recommendationSetID != record.recommendationSetID
            || decision.sourceDigests != record.sourceDigests
            || decision.binding != record.binding
            || !submissionBindingIsExact(decision.submissionBinding, for: record)
            || decision.reviewerID != decision.submissionBinding.authenticatedLocalSessionID.uuidString
            || decision.reviewedRecommendationIDs != record.recommendationIDs
            || decision.sourceClaimIDs != record.sourceClaimIDs
            || decision.decidedAt != record.updatedAt {
            failures.append(failure(
                .invalidReviewState,
                "The final decision does not match the exact review scope and state."
            ))
        }
        if decision.reviewerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || decision.authority != .advisoryReviewOnly
            || decision.executionAuthorized {
            failures.append(failure(
                .invalidAuthority,
                "A review decision requires a reviewer identity and remains non-executable."
            ))
        }
        if decision.decisionID != reconstructDecisionID(decision) {
            failures.append(failure(
                .decisionIdentityMismatch,
                "The decision identifier does not match its canonical review content."
            ))
        }
        return failures
    }

    private static func status(
        for disposition: AssessmentHumanReviewDisposition
    ) -> AssessmentHumanReviewStatus {
        switch disposition {
        case .acknowledgeForPlanning: return .acknowledgedForPlanning
        case .requestChanges: return .changesRequested
        case .rejectRecommendations: return .rejected
        }
    }

    private struct ReviewIdentityMaterial: Codable {
        var schemaVersion: String
        var sourceReportID: String
        var recommendationSetID: String
        var sourceDigests: AssessmentHumanReviewSourceDigests
        var binding: AssessmentReportBinding
        var missionID: UUID
        var sourceDecision: AssessmentRecommendationDecision
        var recommendationIDs: [String]
        var sourceClaimIDs: [String]
        var openedAt: Date
        var authority: AssessmentHumanReviewAuthority
        var executionAuthorized: Bool
    }

    private static func stableReviewID(
        sourceReportID: String,
        recommendationSetID: String,
        sourceDigests: AssessmentHumanReviewSourceDigests,
        binding: AssessmentReportBinding,
        missionID: UUID,
        sourceDecision: AssessmentRecommendationDecision,
        recommendationIDs: [String],
        sourceClaimIDs: [String],
        openedAt: Date
    ) -> String {
        let material = ReviewIdentityMaterial(
            schemaVersion: AssessmentHumanReviewRecord.schemaVersion,
            sourceReportID: sourceReportID,
            recommendationSetID: recommendationSetID,
            sourceDigests: sourceDigests,
            binding: binding,
            missionID: missionID,
            sourceDecision: sourceDecision,
            recommendationIDs: recommendationIDs,
            sourceClaimIDs: sourceClaimIDs,
            openedAt: openedAt,
            authority: .advisoryReviewOnly,
            executionAuthorized: false
        )
        return "assessment-human-review-\(sha256(encoded(material)))"
    }

    private struct DecisionIdentityMaterial: Codable {
        var schemaVersion: String
        var reviewID: String
        var sourceReportID: String
        var recommendationSetID: String
        var sourceDigests: AssessmentHumanReviewSourceDigests
        var binding: AssessmentReportBinding
        var submissionBinding: AssessmentHumanReviewSubmissionBinding
        var disposition: AssessmentHumanReviewDisposition
        var reviewerID: String
        var reviewerNote: String?
        var reviewedRecommendationIDs: [String]
        var sourceClaimIDs: [String]
        var decidedAt: Date
        var authority: AssessmentHumanReviewAuthority
        var executionAuthorized: Bool
    }

    private static func stableDecisionID(
        reviewID: String,
        sourceReportID: String,
        recommendationSetID: String,
        sourceDigests: AssessmentHumanReviewSourceDigests,
        binding: AssessmentReportBinding,
        submissionBinding: AssessmentHumanReviewSubmissionBinding,
        disposition: AssessmentHumanReviewDisposition,
        reviewerID: String,
        reviewerNote: String?,
        reviewedRecommendationIDs: [String],
        sourceClaimIDs: [String],
        decidedAt: Date
    ) -> String {
        let material = DecisionIdentityMaterial(
            schemaVersion: AssessmentHumanReviewRecord.schemaVersion,
            reviewID: reviewID,
            sourceReportID: sourceReportID,
            recommendationSetID: recommendationSetID,
            sourceDigests: sourceDigests,
            binding: binding,
            submissionBinding: submissionBinding,
            disposition: disposition,
            reviewerID: reviewerID,
            reviewerNote: reviewerNote,
            reviewedRecommendationIDs: reviewedRecommendationIDs,
            sourceClaimIDs: sourceClaimIDs,
            decidedAt: decidedAt,
            authority: .advisoryReviewOnly,
            executionAuthorized: false
        )
        return "assessment-human-decision-\(sha256(encoded(material)))"
    }

    private static func sourceDigests(
        report: FDEAIIntegrationAssessmentReport,
        recommendationSet: AssessmentRecommendationSet
    ) throws -> AssessmentHumanReviewSourceDigests {
        let reportPayload = try report.persistenceEventPayload()
        let recommendationPayload = try recommendationSet.persistenceEventPayload()
        guard let reportSHA256 = reportPayload["assessment_report_sha256"],
              let recommendationSetSHA256 = recommendationPayload["assessment_recommendation_sha256"],
              isSHA256(reportSHA256),
              isSHA256(recommendationSetSHA256) else {
            throw AssessmentHumanReviewFailure.invalidSourceArtifact
        }
        return AssessmentHumanReviewSourceDigests(
            reportSHA256: reportSHA256,
            recommendationSetSHA256: recommendationSetSHA256
        )
    }

    private static func submissionBindingIsExact(
        _ submission: AssessmentHumanReviewSubmissionBinding,
        for record: AssessmentHumanReviewRecord
    ) -> Bool {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return submission.workspaceID == record.binding.workspaceID
            && submission.missionID == record.missionID
            && submission.taskID == record.binding.taskID
            && submission.agentSessionID == record.binding.sessionID
            && submission.sourceReportID == record.sourceReportID
            && submission.sourceReportSHA256 == record.sourceDigests.reportSHA256
            && submission.recommendationSetID == record.recommendationSetID
            && submission.recommendationSetSHA256 == record.sourceDigests.recommendationSetSHA256
            && submission.reviewID == record.reviewID
            && submission.authenticatedLocalSessionID != zero
            && submission.workspaceSessionID != zero
            && submission.appSessionID != zero
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return (try? encoder.encode(value)) ?? Data()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(
        _ code: AssessmentHumanReviewValidationFailureCode,
        _ detail: String
    ) -> AssessmentHumanReviewValidationFailure {
        AssessmentHumanReviewValidationFailure(code: code, detail: detail)
    }

    private static func unique(
        _ values: [AssessmentHumanReviewValidationFailure]
    ) -> [AssessmentHumanReviewValidationFailure] {
        values.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }
}

enum AssessmentHumanReviewProjectionFailure: String, Codable, CaseIterable, Hashable, Sendable {
    case invalidSourceReport = "INVALID_SOURCE_REPORT"
    case invalidRecommendationSet = "INVALID_RECOMMENDATION_SET"
    case duplicateSourceReport = "DUPLICATE_SOURCE_REPORT"
    case duplicateRecommendationSet = "DUPLICATE_RECOMMENDATION_SET"
    case missingSourceReport = "MISSING_SOURCE_REPORT"
    case invalidReviewRecord = "INVALID_REVIEW_RECORD"
    case duplicateReviewRecord = "DUPLICATE_REVIEW_RECORD"
}

struct AssessmentHumanReviewProjection: Hashable, Sendable {
    var bundles: [AssessmentHumanReviewBundle]
    var failures: [AssessmentHumanReviewProjectionFailure]
}

enum AssessmentHumanReviewProjector {
    static func project(events: [ExecutionEvent]) -> AssessmentHumanReviewProjection {
        let ordered = events.sorted {
            if $0.sequence == $1.sequence { return $0.id.uuidString < $1.id.uuidString }
            return $0.sequence < $1.sequence
        }
        var reportsByID: [String: FDEAIIntegrationAssessmentReport] = [:]
        var recommendationsByID: [String: AssessmentRecommendationSet] = [:]
        var reviewsBySetID: [String: [AssessmentHumanReviewRecord]] = [:]
        var invalidReviewSetIDs: Set<String> = []
        var sourceLedgerIsCorrupt = false
        var reviewLedgerIsCorrupt = false
        var failures: [AssessmentHumanReviewProjectionFailure] = []

        for event in ordered {
            switch event.payload["lifecycle_event"] {
            case "AI_ASSESSMENT_REPORT_COMPOSED":
                do {
                    let report = try FDEAIIntegrationAssessmentReport.reload(from: event)
                    if let reportID = report.composition?.reportID {
                        guard reportsByID[reportID] == nil else {
                            sourceLedgerIsCorrupt = true
                            failures.append(.duplicateSourceReport)
                            continue
                        }
                        reportsByID[reportID] = report
                    }
                } catch {
                    sourceLedgerIsCorrupt = true
                    failures.append(.invalidSourceReport)
                }
            case "AI_ASSESSMENT_RECOMMENDATIONS_GENERATED":
                do {
                    let recommendationSet = try AssessmentRecommendationSet.reload(from: event)
                    guard recommendationsByID[recommendationSet.recommendationSetID] == nil else {
                        sourceLedgerIsCorrupt = true
                        failures.append(.duplicateRecommendationSet)
                        continue
                    }
                    recommendationsByID[recommendationSet.recommendationSetID] = recommendationSet
                } catch {
                    sourceLedgerIsCorrupt = true
                    failures.append(.invalidRecommendationSet)
                }
            case "AI_ASSESSMENT_HUMAN_REVIEW_OPENED", "AI_ASSESSMENT_HUMAN_REVIEW_RECORDED":
                do {
                    let review = try AssessmentHumanReviewRecord.reload(from: event)
                    reviewsBySetID[review.recommendationSetID, default: []].append(review)
                } catch {
                    reviewLedgerIsCorrupt = true
                    if let recommendationSetID = event.payload["assessment_human_review_recommendation_set_id"] {
                        invalidReviewSetIDs.insert(recommendationSetID)
                    }
                    failures.append(.invalidReviewRecord)
                }
            default:
                continue
            }
        }

        var bundles: [AssessmentHumanReviewBundle] = []
        for recommendationSet in recommendationsByID.values {
            guard !sourceLedgerIsCorrupt, !reviewLedgerIsCorrupt else { continue }
            guard let report = reportsByID[recommendationSet.sourceReportID] else {
                failures.append(.missingSourceReport)
                continue
            }
            guard !invalidReviewSetIDs.contains(recommendationSet.recommendationSetID) else {
                continue
            }
            let persistedReviews = reviewsBySetID[recommendationSet.recommendationSetID] ?? []
            let persistedReview: AssessmentHumanReviewRecord?
            switch persistedReviews.count {
            case 0:
                persistedReview = nil
            case 1:
                persistedReview = persistedReviews[0]
            case 2:
                let opened = persistedReviews[0]
                let finalized = persistedReviews[1]
                guard opened.isPending,
                      finalized.isFinalized,
                      opened.reviewID == finalized.reviewID,
                      opened.sourceReportID == finalized.sourceReportID,
                      opened.recommendationSetID == finalized.recommendationSetID,
                      opened.sourceDigests == finalized.sourceDigests,
                      opened.binding == finalized.binding,
                      opened.missionID == finalized.missionID,
                      opened.sourceDecision == finalized.sourceDecision,
                      opened.recommendationIDs == finalized.recommendationIDs,
                      opened.sourceClaimIDs == finalized.sourceClaimIDs,
                      opened.openedAt == finalized.openedAt else {
                    failures.append(.duplicateReviewRecord)
                    continue
                }
                persistedReview = finalized
            default:
                failures.append(.duplicateReviewRecord)
                continue
            }
            do {
                let review = try persistedReview
                    ?? AssessmentHumanReviewWorkflow.prepare(
                        report: report,
                        recommendationSet: recommendationSet
                    )
                guard AssessmentHumanReviewWorkflow.validate(
                    review,
                    against: recommendationSet,
                    report: report
                ).isEmpty else {
                    failures.append(.invalidReviewRecord)
                    continue
                }
                bundles.append(AssessmentHumanReviewBundle(
                    report: report,
                    recommendationSet: recommendationSet,
                    review: review
                ))
            } catch {
                failures.append(.invalidReviewRecord)
            }
        }
        bundles.sort {
            if $0.review.openedAt == $1.review.openedAt { return $0.review.reviewID < $1.review.reviewID }
            return $0.review.openedAt < $1.review.openedAt
        }
        return AssessmentHumanReviewProjection(
            bundles: bundles,
            failures: failures.reduce(into: []) { result, value in
                if !result.contains(value) { result.append(value) }
            }
        )
    }
}

extension AssessmentHumanReviewRecord {
    func markdown() -> String {
        var lines = [
            "# Assessment Human Review",
            "",
            "- Review: `\(reviewID)`",
            "- Report: `\(sourceReportID)`",
            "- Recommendation set: `\(recommendationSetID)`",
            "- Status: **\(status.rawValue)**",
            "- Source decision: **\(sourceDecision.rawValue)**",
            "- Authority: `\(authority.rawValue)`",
            "- Execution authorized: **NO**",
            "",
            "Acknowledging this assessment accepts it as advice for future planning only. No execution, code change, validation, mutation, shell, Git, deployment, production access, or ApprovalRequest is authorized."
        ]
        if let decision {
            lines += [
                "",
                "## Decision",
                "",
                "- Disposition: **\(decision.disposition.rawValue)**",
                "- Reviewer: `\(decision.reviewerID)`",
                "- Decision ID: `\(decision.decisionID)`"
            ]
            if let note = decision.reviewerNote {
                lines.append("- Note: \(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    func persistenceEventPayload() throws -> [String: String] {
        guard AssessmentHumanReviewWorkflow.validateIntegrity(self).isEmpty else {
            throw AssessmentHumanReviewFailure.invalidReviewRecord
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(self)
        guard let json = String(data: data, encoding: .utf8) else {
            throw AssessmentHumanReviewFailure.missingPersistencePayload
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let submission = decision?.submissionBinding
        return [
            "lifecycle_event": isPending
                ? "AI_ASSESSMENT_HUMAN_REVIEW_OPENED"
                : "AI_ASSESSMENT_HUMAN_REVIEW_RECORDED",
            "assessment_human_review_schema": schemaVersion,
            "assessment_human_review_id": reviewID,
            "assessment_human_review_source_report_id": sourceReportID,
            "assessment_human_review_source_report_sha256": sourceDigests.reportSHA256,
            "assessment_human_review_recommendation_set_id": recommendationSetID,
            "assessment_human_review_recommendation_set_sha256": sourceDigests.recommendationSetSHA256,
            "assessment_human_review_status": status.rawValue,
            "assessment_human_review_disposition": decision?.disposition.rawValue ?? "",
            "assessment_human_review_json": json,
            "assessment_human_review_sha256": digest,
            "assessment_human_review_authority": authority.rawValue,
            "assessment_human_review_execution_authorized": "false",
            "assessment_human_review_approval_request_created": "false",
            "assessment_human_review_approval_queue_authority_created": "false",
            "assessment_human_review_candidate_patch_authorized": "false",
            "assessment_human_review_eval_authorized": "false",
            "assessment_human_review_execution_admission_granted": "false",
            "assessment_human_review_validation_authorized": "false",
            "assessment_human_review_mutation_authorized": "false",
            "assessment_human_review_shell_authorized": "false",
            "assessment_human_review_git_authorized": "false",
            "assessment_human_review_deployment_authorized": "false",
            "assessment_human_review_production_access_authorized": "false",
            "assessment_human_review_workspace_id": binding.workspaceID.uuidString,
            "assessment_human_review_mission_id": missionID.uuidString,
            "assessment_human_review_task_id": binding.taskID.uuidString,
            "assessment_human_review_agent_session_id": binding.sessionID.uuidString,
            "assessment_human_review_reviewer_id": decision?.reviewerID ?? "",
            "assessment_human_review_authenticated_local_session_id": submission?.authenticatedLocalSessionID.uuidString ?? "",
            "assessment_human_review_workspace_session_id": submission?.workspaceSessionID.uuidString ?? "",
            "assessment_human_review_app_session_id": submission?.appSessionID.uuidString ?? ""
        ]
    }

    static func reload(from event: ExecutionEvent) throws -> AssessmentHumanReviewRecord {
        let value = try reload(from: event.payload)
        guard value.binding.workspaceID == event.workspaceID,
              value.binding.taskID == event.taskID else {
            throw AssessmentHumanReviewFailure.bindingMismatch
        }
        return value
    }

    static func reload(from payload: [String: String]) throws -> AssessmentHumanReviewRecord {
        guard [
            "AI_ASSESSMENT_HUMAN_REVIEW_OPENED",
            "AI_ASSESSMENT_HUMAN_REVIEW_RECORDED"
        ].contains(payload["lifecycle_event"] ?? ""),
        let reviewID = payload["assessment_human_review_id"],
        let json = payload["assessment_human_review_json"],
        let expectedDigest = payload["assessment_human_review_sha256"],
        let data = json.data(using: .utf8) else {
            throw AssessmentHumanReviewFailure.missingPersistencePayload
        }
        let actualDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == expectedDigest else {
            throw AssessmentHumanReviewFailure.persistenceDigestMismatch
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let value = try decoder.decode(AssessmentHumanReviewRecord.self, from: data)
        let expectedLifecycle = value.isPending
            ? "AI_ASSESSMENT_HUMAN_REVIEW_OPENED"
            : "AI_ASSESSMENT_HUMAN_REVIEW_RECORDED"
        guard payload["lifecycle_event"] == expectedLifecycle,
              value.reviewID == reviewID,
              value.schemaVersion == AssessmentHumanReviewRecord.schemaVersion,
              value.schemaVersion == payload["assessment_human_review_schema"],
              value.sourceReportID == payload["assessment_human_review_source_report_id"],
              value.sourceDigests.reportSHA256 == payload["assessment_human_review_source_report_sha256"],
              value.recommendationSetID == payload["assessment_human_review_recommendation_set_id"],
              value.sourceDigests.recommendationSetSHA256 == payload["assessment_human_review_recommendation_set_sha256"],
              value.status.rawValue == payload["assessment_human_review_status"],
              value.decision?.disposition.rawValue ?? "" == payload["assessment_human_review_disposition"],
              value.authority == .advisoryReviewOnly,
              value.authority.rawValue == payload["assessment_human_review_authority"],
              !value.executionAuthorized,
              payload["assessment_human_review_execution_authorized"] == "false",
              payload["assessment_human_review_approval_request_created"] == "false",
              payload["assessment_human_review_approval_queue_authority_created"] == "false",
              payload["assessment_human_review_candidate_patch_authorized"] == "false",
              payload["assessment_human_review_eval_authorized"] == "false",
              payload["assessment_human_review_execution_admission_granted"] == "false",
              payload["assessment_human_review_validation_authorized"] == "false",
              payload["assessment_human_review_mutation_authorized"] == "false",
              payload["assessment_human_review_shell_authorized"] == "false",
              payload["assessment_human_review_git_authorized"] == "false",
              payload["assessment_human_review_deployment_authorized"] == "false",
              payload["assessment_human_review_production_access_authorized"] == "false",
              value.reviewID == AssessmentHumanReviewWorkflow.reconstructReviewID(value),
              AssessmentHumanReviewWorkflow.validateIntegrity(value).isEmpty else {
            throw AssessmentHumanReviewFailure.persistenceIdentityMismatch
        }
        guard value.binding.workspaceID.uuidString == payload["assessment_human_review_workspace_id"],
              value.missionID.uuidString == payload["assessment_human_review_mission_id"],
              value.binding.taskID.uuidString == payload["assessment_human_review_task_id"],
              value.binding.sessionID.uuidString == payload["assessment_human_review_agent_session_id"],
              value.decision?.reviewerID ?? "" == payload["assessment_human_review_reviewer_id"],
              value.decision?.submissionBinding.authenticatedLocalSessionID.uuidString ?? "" == payload["assessment_human_review_authenticated_local_session_id"],
              value.decision?.submissionBinding.workspaceSessionID.uuidString ?? "" == payload["assessment_human_review_workspace_session_id"],
              value.decision?.submissionBinding.appSessionID.uuidString ?? "" == payload["assessment_human_review_app_session_id"] else {
            throw AssessmentHumanReviewFailure.bindingMismatch
        }
        return value
    }
}

// Compatibility names used by callers that refer to the Phase 3B.5 artifact
// without the longer human-review qualifier. These aliases carry no authority.
typealias AssessmentReviewStatus = AssessmentHumanReviewStatus
typealias AssessmentReviewDisposition = AssessmentHumanReviewDisposition
typealias AssessmentReviewDecision = AssessmentHumanReviewDecision
typealias AssessmentReviewRecord = AssessmentHumanReviewRecord
typealias AssessmentReviewContext = AssessmentHumanReviewContext
typealias AssessmentReviewBundle = AssessmentHumanReviewBundle
typealias AssessmentReviewWorkflow = AssessmentHumanReviewWorkflow
typealias AssessmentReviewPersistenceError = AssessmentHumanReviewFailure
