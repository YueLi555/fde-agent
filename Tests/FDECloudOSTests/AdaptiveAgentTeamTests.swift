import XCTest
@testable import FDECloudOS

final class AdaptiveAgentTeamTests: XCTestCase {
    func testDynamicTeamCreationUsesMinimalAgentsForSimpleMission() {
        let input = AgentTeamPlanningInput(
            objective: "Fix a small code formatting issue.",
            complexity: .simple,
            requiredSkills: [.code],
            riskLevel: .low,
            environment: "local"
        )

        let plan = AgentTeamPlanner().plan(input: input)

        XCTAssertEqual(plan.roleIDs, [.fdeLeadAgent, .codeInvestigationAgent])
        XCTAssertFalse(plan.roleIDs.contains(.securityAgent))
        XCTAssertFalse(plan.roleIDs.contains(.infrastructureAgent))
        XCTAssertGreaterThan(plan.confidence, 0.5)
    }

    func testDynamicTeamCreationUsesSpecialistsForComplexProductionMission() {
        let memory = AgentReputationMemory.empty
            .updating(roleID: .securityAgent, domain: "production", successful: true, confidence: 0.95)
            .updating(roleID: .infrastructureAgent, domain: "production", successful: true, confidence: 0.9)
        let input = AgentTeamPlanningInput(
            objective: "Recover production API integration with database schema risk.",
            complexity: .complex,
            requiredSkills: [.code, .data],
            riskLevel: .high,
            environment: "production",
            reputationMemory: memory
        )

        let plan = AgentTeamPlanner().plan(input: input)

        XCTAssertTrue(plan.roleIDs.contains(.fdeLeadAgent))
        XCTAssertTrue(plan.roleIDs.contains(.codeInvestigationAgent))
        XCTAssertTrue(plan.roleIDs.contains(.securityAgent))
        XCTAssertTrue(plan.roleIDs.contains(.infrastructureAgent))
        XCTAssertTrue(plan.roleIDs.contains(.dataAgent))
        XCTAssertTrue(plan.roleIDs.contains(.documentationAgent))
        XCTAssertTrue(plan.requiresHumanLeadReview)
    }

    func testCollaborationMessageValidation() {
        let evidence = makeEvidence()
        let valid = AgentProposal(
            sender: .codeInvestigationAgent,
            claim: "The API client fails after token refresh.",
            evidence: [evidence],
            confidence: 0.82,
            recommendation: "Proceed with bounded token refresh fix."
        )
        let invalid = AgentProposal(
            sender: .securityAgent,
            claim: "",
            evidence: [],
            confidence: 1.2,
            recommendation: ""
        )

        let validator = AgentCollaborationProtocol()

        XCTAssertTrue(validator.validate(valid).isValid)
        let invalidValidation = validator.validate(invalid)
        XCTAssertFalse(invalidValidation.isValid)
        XCTAssertTrue(invalidValidation.issues.contains(.missingClaim))
        XCTAssertTrue(invalidValidation.issues.contains(.missingEvidence))
        XCTAssertTrue(invalidValidation.issues.contains(.confidenceOutOfRange))
        XCTAssertTrue(invalidValidation.issues.contains(.missingRecommendation))
    }

    func testConflictResolverEscalatesConflictingHighRiskRecommendations() {
        let evidence = makeEvidence()
        let securityProposal = AgentProposal(
            sender: .securityAgent,
            claim: "Permission drift is unresolved.",
            evidence: [evidence],
            confidence: 0.86,
            recommendation: "Hold deployment until approval is recorded."
        )
        let infrastructureProposal = AgentProposal(
            sender: .infrastructureAgent,
            claim: "Rollback path is available.",
            evidence: [evidence],
            confidence: 0.8,
            recommendation: "Proceed with deploy after smoke tests."
        )
        let review = AgentReview(
            reviewer: .fdeLeadAgent,
            proposalID: infrastructureProposal.id,
            agreement: false,
            disagreement: ["Security approval is still missing."],
            risk: .high,
            confidence: 0.9
        )

        let resolution = AgentConflictResolver().resolve(
            proposals: [securityProposal, infrastructureProposal],
            reviews: [review]
        )

        XCTAssertEqual(resolution.action, .askHumanLead)
        XCTAssertTrue(resolution.requiresHumanLead)
        XCTAssertFalse(resolution.disagreements.isEmpty)
        XCTAssertTrue(resolution.finalDecision.contains("human FDE lead"))
    }

    func testReputationUpdateTracksRolePerformanceAndDomainExpertise() {
        let updated = AgentReputationMemory.empty
            .updating(roleID: .codeInvestigationAgent, domain: "production", successful: true, confidence: 0.9)
            .updating(roleID: .codeInvestigationAgent, domain: "production", successful: false, confidence: 0.4)

        let reputation = updated.reputation(for: .codeInvestigationAgent)

        XCTAssertEqual(reputation.completedMissions, 2)
        XCTAssertEqual(reputation.successfulMissions, 1)
        XCTAssertEqual(reputation.successRate, 0.5, accuracy: 0.001)
        XCTAssertGreaterThan(updated.domainScore(for: .codeInvestigationAgent, domain: "production"), 0.3)
    }

    private func makeEvidence() -> EvidenceRecord {
        EvidenceRecord(
            action: "adaptive_team.fixture",
            source: "AdaptiveAgentTeamTests",
            result: "Evidence captured for adaptive collaboration.",
            validation: .valid
        )
    }
}
