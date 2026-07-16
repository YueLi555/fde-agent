import Foundation

enum AgentConflictAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case requestMoreEvidence = "request_more_evidence"
    case askHumanLead = "ask_human_lead"
    case selectHigherConfidence = "select_higher_confidence"

    var id: String { rawValue }
}

struct AgentConflictResolution: Codable, Hashable, Sendable {
    var action: AgentConflictAction
    var selectedProposal: AgentProposal?
    var reasons: [String]
    var missingEvidenceRoles: [AgentRoleID]
    var disagreements: [String]
    var confidence: Double
    var finalDecision: String
    var requiresHumanLead: Bool
}

struct AgentConflictResolver: Sendable {
    var minimumConfidence: Double = 0.65
    var decisiveConfidenceGap: Double = 0.2

    func resolve(proposals: [AgentProposal], reviews: [AgentReview]) -> AgentConflictResolution {
        let protocolValidator = AgentCollaborationProtocol()
        let invalidProposals = proposals.filter { !protocolValidator.validate($0).isValid }
        let missingEvidenceRoles = proposals
            .filter { $0.evidence.isEmpty }
            .map(\.sender)

        if !invalidProposals.isEmpty || !missingEvidenceRoles.isEmpty {
            return AgentConflictResolution(
                action: .requestMoreEvidence,
                selectedProposal: nil,
                reasons: ["One or more proposals are missing required evidence or schema fields."],
                missingEvidenceRoles: uniqueRoles(missingEvidenceRoles),
                disagreements: reviewDisagreements(reviews),
                confidence: 0,
                finalDecision: "Request more evidence before selecting a team decision.",
                requiresHumanLead: false
            )
        }

        guard let highest = proposals.max(by: { $0.confidence < $1.confidence }) else {
            return AgentConflictResolution(
                action: .requestMoreEvidence,
                selectedProposal: nil,
                reasons: ["No proposals were submitted."],
                missingEvidenceRoles: [],
                disagreements: [],
                confidence: 0,
                finalDecision: "Request proposals before selecting a team decision.",
                requiresHumanLead: false
            )
        }

        let disagreements = reviewDisagreements(reviews) + recommendationConflicts(proposals)
        let highestRisk = reviews.map(\.risk).max { $0.governanceRank < $1.governanceRank } ?? .low
        if highest.confidence < minimumConfidence {
            return AgentConflictResolution(
                action: .askHumanLead,
                selectedProposal: highest,
                reasons: ["Highest-confidence proposal is below the minimum confidence threshold."],
                missingEvidenceRoles: [],
                disagreements: disagreements,
                confidence: highest.confidence,
                finalDecision: "Ask the human FDE lead before proceeding with a low-confidence decision.",
                requiresHumanLead: true
            )
        }

        if !disagreements.isEmpty {
            let secondConfidence = proposals
                .filter { $0.id != highest.id }
                .map(\.confidence)
                .max() ?? 0
            let confidenceGap = highest.confidence - secondConfidence
            if confidenceGap >= decisiveConfidenceGap && highestRisk.governanceRank < RiskSeverity.high.governanceRank {
                return AgentConflictResolution(
                    action: .selectHigherConfidence,
                    selectedProposal: highest,
                    reasons: ["Selected the higher-confidence proposal despite disagreement."],
                    missingEvidenceRoles: [],
                    disagreements: disagreements,
                    confidence: highest.confidence,
                    finalDecision: highest.recommendation,
                    requiresHumanLead: false
                )
            }

            return AgentConflictResolution(
                action: .askHumanLead,
                selectedProposal: highest,
                reasons: ["Agent reviews or recommendations conflict."],
                missingEvidenceRoles: [],
                disagreements: disagreements,
                confidence: highest.confidence,
                finalDecision: "Ask the human FDE lead to resolve conflicting recommendations.",
                requiresHumanLead: true
            )
        }

        return AgentConflictResolution(
            action: .selectHigherConfidence,
            selectedProposal: highest,
            reasons: ["Selected the highest-confidence evidence-grounded proposal."],
            missingEvidenceRoles: [],
            disagreements: [],
            confidence: highest.confidence,
            finalDecision: highest.recommendation,
            requiresHumanLead: false
        )
    }

    private func reviewDisagreements(_ reviews: [AgentReview]) -> [String] {
        reviews
            .filter(\.hasDisagreement)
            .map { review in
                let detail = review.disagreement.isEmpty ? "No detail provided." : review.disagreement.joined(separator: " ")
                return "\(review.reviewer.displayName): \(detail)"
            }
    }

    private func recommendationConflicts(_ proposals: [AgentProposal]) -> [String] {
        let blockers = proposals.filter { isBlockingRecommendation($0.recommendation) }
        let proceeding = proposals.filter { isProceedingRecommendation($0.recommendation) }
        var conflicts: [String] = []
        for blocker in blockers {
            for proceed in proceeding where blocker.sender != proceed.sender {
                conflicts.append("\(blocker.sender.displayName) recommends holding while \(proceed.sender.displayName) recommends proceeding.")
            }
        }
        return conflicts
    }

    private func isBlockingRecommendation(_ value: String) -> Bool {
        let text = value.lowercased()
        return containsAny(text, ["do not", "block", "hold", "deny", "unsafe", "stop", "reject"])
    }

    private func isProceedingRecommendation(_ value: String) -> Bool {
        let text = value.lowercased()
        return containsAny(text, ["proceed", "approve", "ship", "deploy", "merge", "execute"])
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func uniqueRoles(_ roles: [AgentRoleID]) -> [AgentRoleID] {
        var seen = Set<AgentRoleID>()
        var result: [AgentRoleID] = []
        for role in roles where !seen.contains(role) {
            seen.insert(role)
            result.append(role)
        }
        return result
    }
}
