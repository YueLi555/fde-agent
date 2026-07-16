import Foundation

enum AgentCollaborationValidationIssue: String, Codable, CaseIterable, Identifiable, Sendable {
    case missingClaim = "missing_claim"
    case missingEvidence = "missing_evidence"
    case confidenceOutOfRange = "confidence_out_of_range"
    case missingRecommendation = "missing_recommendation"

    var id: String { rawValue }
}

struct AgentProposal: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sender: AgentRoleID
    var claim: String
    var evidence: [EvidenceRecord]
    var confidence: Double
    var recommendation: String
    var createdAt: Date

    init(
        id: UUID = UUID(),
        sender: AgentRoleID,
        claim: String,
        evidence: [EvidenceRecord],
        confidence: Double,
        recommendation: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sender = sender
        self.claim = AgentPresentationSanitizer.safeContent(claim, fallback: "")
        self.evidence = evidence
        self.confidence = confidence
        self.recommendation = AgentPresentationSanitizer.safeContent(recommendation, fallback: "")
        self.createdAt = createdAt
    }

    var isEvidenceGrounded: Bool {
        !evidence.isEmpty
    }
}

struct AgentReview: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var reviewer: AgentRoleID
    var proposalID: UUID
    var agreement: Bool
    var disagreement: [String]
    var risk: RiskSeverity
    var confidence: Double
    var createdAt: Date

    init(
        id: UUID = UUID(),
        reviewer: AgentRoleID,
        proposalID: UUID,
        agreement: Bool,
        disagreement: [String] = [],
        risk: RiskSeverity,
        confidence: Double = 0.8,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.reviewer = reviewer
        self.proposalID = proposalID
        self.agreement = agreement
        self.disagreement = disagreement.map { AgentPresentationSanitizer.safeContent($0, fallback: "Disagreement recorded.") }
        self.risk = risk
        self.confidence = min(max(confidence, 0), 1)
        self.createdAt = createdAt
    }

    var hasDisagreement: Bool {
        !agreement || !disagreement.isEmpty
    }
}

struct AgentCollaborationValidation: Codable, Hashable, Sendable {
    var isValid: Bool
    var issues: [AgentCollaborationValidationIssue]
}

struct AgentCollaborationProtocol: Sendable {
    func validate(_ proposal: AgentProposal) -> AgentCollaborationValidation {
        var issues: [AgentCollaborationValidationIssue] = []
        if proposal.claim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingClaim)
        }
        if proposal.evidence.isEmpty {
            issues.append(.missingEvidence)
        }
        if proposal.confidence < 0 || proposal.confidence > 1 {
            issues.append(.confidenceOutOfRange)
        }
        if proposal.recommendation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.missingRecommendation)
        }
        return AgentCollaborationValidation(isValid: issues.isEmpty, issues: issues)
    }

    func review(
        proposal: AgentProposal,
        reviewer: AgentRoleID,
        agreement: Bool,
        disagreement: [String] = [],
        risk: RiskSeverity,
        confidence: Double = 0.8
    ) -> AgentReview {
        AgentReview(
            reviewer: reviewer,
            proposalID: proposal.id,
            agreement: agreement,
            disagreement: disagreement,
            risk: risk,
            confidence: confidence
        )
    }

    func proposal(
        sender: AgentRoleID,
        claim: String,
        evidence: [EvidenceRecord],
        confidence: Double,
        recommendation: String
    ) -> AgentProposal {
        AgentProposal(
            sender: sender,
            claim: claim,
            evidence: evidence,
            confidence: confidence,
            recommendation: recommendation
        )
    }
}
