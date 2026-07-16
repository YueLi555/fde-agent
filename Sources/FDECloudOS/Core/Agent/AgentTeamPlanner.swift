import Foundation

enum MissionComplexity: String, Codable, CaseIterable, Identifiable, Sendable {
    case simple
    case moderate
    case complex
    case critical

    var id: String { rawValue }
}

struct AgentRoleReputation: Identifiable, Codable, Hashable, Sendable {
    var id: AgentRoleID { roleID }
    var roleID: AgentRoleID
    var completedMissions: Int
    var successfulMissions: Int
    var averageConfidence: Double
    var domainExpertise: [String: Double]
    var lastUpdated: Date

    var successRate: Double {
        guard completedMissions > 0 else { return 0.5 }
        return Double(successfulMissions) / Double(completedMissions)
    }

    static func baseline(roleID: AgentRoleID) -> AgentRoleReputation {
        AgentRoleReputation(
            roleID: roleID,
            completedMissions: 0,
            successfulMissions: 0,
            averageConfidence: 0.7,
            domainExpertise: [:],
            lastUpdated: Date.distantPast
        )
    }
}

struct AgentReputationMemory: Codable, Hashable, Sendable {
    var reputations: [AgentRoleID: AgentRoleReputation]

    static let empty = AgentReputationMemory(reputations: [:])

    func reputation(for roleID: AgentRoleID) -> AgentRoleReputation {
        reputations[roleID] ?? .baseline(roleID: roleID)
    }

    func domainScore(for roleID: AgentRoleID, domain: String) -> Double {
        let key = Self.normalizedDomain(domain)
        return reputation(for: roleID).domainExpertise[key] ?? 0.5
    }

    func updating(
        roleID: AgentRoleID,
        domain: String,
        successful: Bool,
        confidence: Double,
        now: Date = Date()
    ) -> AgentReputationMemory {
        var copy = self
        var reputation = copy.reputation(for: roleID)
        let previousCompleted = reputation.completedMissions
        reputation.completedMissions += 1
        if successful {
            reputation.successfulMissions += 1
        }
        let boundedConfidence = min(max(confidence, 0), 1)
        reputation.averageConfidence = (
            reputation.averageConfidence * Double(previousCompleted) + boundedConfidence
        ) / Double(reputation.completedMissions)

        let key = Self.normalizedDomain(domain)
        let previousDomainScore = reputation.domainExpertise[key] ?? 0.5
        let outcomeScore = successful ? boundedConfidence : min(boundedConfidence, 0.35)
        reputation.domainExpertise[key] = (previousDomainScore + outcomeScore) / 2
        reputation.lastUpdated = now
        copy.reputations[roleID] = reputation
        return copy
    }

    func updating(from report: AgentDelegationReport, domain: String, now: Date = Date()) -> AgentReputationMemory {
        report.results.reduce(self) { memory, result in
            memory.updating(
                roleID: result.role,
                domain: domain,
                successful: result.status == .completed && report.status == .completed,
                confidence: result.confidence,
                now: now
            )
        }
    }

    private static func normalizedDomain(_ value: String) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty ? "workspace" : normalized
    }
}

struct AgentTeamPlanningInput: Codable, Hashable, Sendable {
    var missionID: UUID
    var objective: String
    var complexity: MissionComplexity
    var requiredSkills: [AgentExpertise]
    var riskLevel: RiskSeverity
    var environment: String
    var reputationMemory: AgentReputationMemory

    init(
        missionID: UUID = UUID(),
        objective: String,
        complexity: MissionComplexity,
        requiredSkills: [AgentExpertise],
        riskLevel: RiskSeverity,
        environment: String,
        reputationMemory: AgentReputationMemory = .empty
    ) {
        self.missionID = missionID
        self.objective = objective
        self.complexity = complexity
        self.requiredSkills = requiredSkills
        self.riskLevel = riskLevel
        self.environment = environment
        self.reputationMemory = reputationMemory
    }
}

struct PlannedAgentAssignment: Identifiable, Codable, Hashable, Sendable {
    var id: AgentRoleID { roleID }
    var roleID: AgentRoleID
    var responsibility: String
    var selectedBecause: String
    var confidence: Double
    var expectedContribution: String
}

struct AgentTeamPlan: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var missionID: UUID
    var complexity: MissionComplexity
    var riskLevel: RiskSeverity
    var environment: String
    var selectedAgents: [PlannedAgentAssignment]
    var omittedAgents: [AgentRoleID]
    var rationale: [String]
    var confidence: Double
    var requiresHumanLeadReview: Bool

    var roleIDs: [AgentRoleID] {
        selectedAgents.map(\.roleID)
    }
}

struct TeamIntelligenceSnapshot: Codable, Hashable, Sendable {
    var selectedAgents: [PlannedAgentAssignment]
    var selectionReasons: [String]
    var confidence: Double
    var disagreements: [String]
    var finalDecision: String

    static let empty = TeamIntelligenceSnapshot(
        selectedAgents: [],
        selectionReasons: ["No adaptive team plan generated."],
        confidence: 0,
        disagreements: [],
        finalDecision: "No team decision available."
    )
}

struct AgentTeamPlanner: Sendable {
    let roleCatalog: AgentRoleCatalog

    init(roleCatalog: AgentRoleCatalog = AgentRoleCatalog()) {
        self.roleCatalog = roleCatalog
    }

    func plan(input: AgentTeamPlanningInput) -> AgentTeamPlan {
        let roleIDs = selectedRoleIDs(for: input)
        let assignments = roleIDs.map { assignment(for: $0, input: input) }
        let confidence = teamConfidence(assignments)
        let allRoles = Set(AgentRoleID.allCases)
        let omitted = allRoles.subtracting(Set(roleIDs)).sorted { $0.rawValue < $1.rawValue }
        return AgentTeamPlan(
            id: UUID(),
            missionID: input.missionID,
            complexity: input.complexity,
            riskLevel: input.riskLevel,
            environment: input.environment,
            selectedAgents: assignments,
            omittedAgents: omitted,
            rationale: rationale(for: input, selectedRoles: roleIDs),
            confidence: confidence,
            requiresHumanLeadReview: input.riskLevel.governanceRank >= RiskSeverity.high.governanceRank
                || input.complexity == .critical
        )
    }

    func snapshot(plan: AgentTeamPlan, resolution: AgentConflictResolution? = nil) -> TeamIntelligenceSnapshot {
        TeamIntelligenceSnapshot(
            selectedAgents: plan.selectedAgents,
            selectionReasons: plan.rationale,
            confidence: resolution?.confidence ?? plan.confidence,
            disagreements: resolution?.disagreements ?? [],
            finalDecision: resolution?.finalDecision ?? "Use \(plan.selectedAgents.count) selected agent role\(plan.selectedAgents.count == 1 ? "" : "s") for this mission."
        )
    }

    private func selectedRoleIDs(for input: AgentTeamPlanningInput) -> [AgentRoleID] {
        var roles: [AgentRoleID] = [.fdeLeadAgent]
        let requestedRoles = input.requiredSkills
            .filter { $0 != .leadership }
            .map(\.roleID)

        switch input.complexity {
        case .simple:
            if let primary = requestedRoles.first {
                roles.append(primary)
            }
        case .moderate:
            roles.append(contentsOf: requestedRoles.prefix(3))
        case .complex, .critical:
            roles.append(contentsOf: requestedRoles)
            roles.append(.documentationAgent)
        }

        if input.riskLevel.governanceRank >= RiskSeverity.high.governanceRank {
            roles.append(.securityAgent)
        }
        if isProductionLike(input.environment) || input.complexity == .critical {
            roles.append(.infrastructureAgent)
        }
        if input.objective.localizedCaseInsensitiveContains("data")
            || input.objective.localizedCaseInsensitiveContains("database")
            || input.objective.localizedCaseInsensitiveContains("schema") {
            roles.append(.dataAgent)
        }
        if roles.count == 1 {
            roles.append(.documentationAgent)
        }
        return uniqueRoles(roles)
    }

    private func assignment(for roleID: AgentRoleID, input: AgentTeamPlanningInput) -> PlannedAgentAssignment {
        let role = roleCatalog.role(roleID)
        let reputation = input.reputationMemory.reputation(for: roleID)
        let domainScore = input.reputationMemory.domainScore(for: roleID, domain: input.environment)
        let confidence = min(max((reputation.successRate * 0.45) + (reputation.averageConfidence * 0.35) + (domainScore * 0.20), 0.2), 0.98)
        return PlannedAgentAssignment(
            roleID: roleID,
            responsibility: role.responsibility,
            selectedBecause: selectionReason(for: roleID, input: input, reputation: reputation, domainScore: domainScore),
            confidence: confidence,
            expectedContribution: expectedContribution(for: roleID)
        )
    }

    private func rationale(for input: AgentTeamPlanningInput, selectedRoles: [AgentRoleID]) -> [String] {
        var values = [
            "Mission complexity is \(input.complexity.rawValue).",
            "Risk level is \(input.riskLevel.rawValue).",
            "Environment is \(input.environment.isEmpty ? "workspace" : input.environment)."
        ]
        if input.complexity == .simple {
            values.append("Simple missions use the FDE lead plus the smallest required specialist set.")
        } else {
            values.append("Complex missions use specialized roles for each required expertise area.")
        }
        values.append("Selected roles: \(selectedRoles.map(\.displayName).joined(separator: ", ")).")
        return values
    }

    private func selectionReason(
        for roleID: AgentRoleID,
        input: AgentTeamPlanningInput,
        reputation: AgentRoleReputation,
        domainScore: Double
    ) -> String {
        if roleID == .fdeLeadAgent {
            return "Coordinates adaptive team decisions and human lead review."
        }
        if input.requiredSkills.map(\.roleID).contains(roleID) {
            return "Required by mission skill analysis with \(Int((domainScore * 100).rounded()))% domain fit."
        }
        if roleID == .securityAgent && input.riskLevel.governanceRank >= RiskSeverity.high.governanceRank {
            return "Added because elevated risk requires policy and approval review."
        }
        if roleID == .infrastructureAgent && isProductionLike(input.environment) {
            return "Added because the mission targets a production-like environment."
        }
        if roleID == .documentationAgent && input.complexity != .simple {
            return "Added to preserve evidence-grounded customer and runbook updates."
        }
        return "Selected from reputation memory with \(Int((reputation.successRate * 100).rounded()))% success rate."
    }

    private func expectedContribution(for roleID: AgentRoleID) -> String {
        switch roleID {
        case .fdeLeadAgent: return "Final synthesis, escalation, and decision ownership."
        case .codeInvestigationAgent: return "Codebase diagnosis and validation plan."
        case .securityAgent: return "Policy, permission, and approval risk assessment."
        case .infrastructureAgent: return "Runtime, deployment, and production environment analysis."
        case .dataAgent: return "Data sensitivity, schema, and migration impact analysis."
        case .documentationAgent: return "Customer-safe summary and runbook updates."
        }
    }

    private func teamConfidence(_ assignments: [PlannedAgentAssignment]) -> Double {
        guard !assignments.isEmpty else { return 0 }
        return assignments.map(\.confidence).reduce(0, +) / Double(assignments.count)
    }

    private func isProductionLike(_ environment: String) -> Bool {
        let value = environment.lowercased()
        return value.contains("prod") || value.contains("production") || value.contains("live")
    }

    private func uniqueRoles(_ values: [AgentRoleID]) -> [AgentRoleID] {
        var seen = Set<AgentRoleID>()
        var result: [AgentRoleID] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }
}
