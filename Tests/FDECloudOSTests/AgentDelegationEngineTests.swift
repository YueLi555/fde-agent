import XCTest
@testable import FDECloudOS

final class AgentDelegationEngineTests: XCTestCase {
    func testDelegationCreatesSubMissionsForRequiredExpertise() {
        let workspaceID = UUID()
        let mission = AgentMissionBrief(
            workspaceID: workspaceID,
            objective: "Fix broken production enterprise API integration with OAuth permissions, database schema impact, deployment risk, tests, and customer runbook.",
            system: "Enterprise CRM",
            environment: "production",
            riskLevel: .high
        )
        let context = makeContext(workspaceID: workspaceID)

        let plan = AgentDelegationEngine().createDelegationPlan(
            mission: mission,
            context: context,
            requireHumanApproval: true
        )

        XCTAssertTrue(plan.requiredExpertise.contains(.leadership))
        XCTAssertTrue(plan.requiredExpertise.contains(.code))
        XCTAssertTrue(plan.requiredExpertise.contains(.security))
        XCTAssertTrue(plan.requiredExpertise.contains(.infrastructure))
        XCTAssertTrue(plan.requiredExpertise.contains(.data))
        XCTAssertTrue(plan.requiredExpertise.contains(.documentation))
        XCTAssertEqual(plan.humanLeadMode.approvalState, .pending)
        XCTAssertEqual(plan.status, .proposed)
        XCTAssertTrue(plan.subMissions.allSatisfy(\.evidenceRequired))
    }

    func testRolePermissionsAreScoped() {
        let catalog = AgentRoleCatalog()

        XCTAssertTrue(catalog.hasPermission(.approveDelegation, for: .fdeLeadAgent))
        XCTAssertTrue(catalog.hasPermission(.overrideAgentDecision, for: .fdeLeadAgent))
        XCTAssertTrue(catalog.hasPermission(.inspectCode, for: .codeInvestigationAgent))
        XCTAssertFalse(catalog.hasPermission(.editCode, for: .securityAgent))
        XCTAssertFalse(catalog.hasPermission(.approveDelegation, for: .codeInvestigationAgent))
        XCTAssertTrue(catalog.hasPermission(.writeDocumentation, for: .documentationAgent))
    }

    func testAgentCollaborationMessagesCarryTaskEvidenceAndRecommendation() {
        let workspaceID = UUID()
        let mission = AgentMissionBrief(
            workspaceID: workspaceID,
            objective: "Investigate API code failure and security approval risk.",
            riskLevel: .medium
        )
        let context = makeContext(workspaceID: workspaceID)

        let plan = AgentDelegationEngine().createDelegationPlan(
            mission: mission,
            context: context,
            requireHumanApproval: false
        )

        let securityMessage = plan.messages.first { $0.receiver == .securityAgent }
        XCTAssertNotNil(securityMessage)
        XCTAssertEqual(securityMessage?.sender, .fdeLeadAgent)
        XCTAssertEqual(securityMessage?.receiver, .securityAgent)
        XCTAssertFalse(securityMessage?.task.isEmpty ?? true)
        XCTAssertFalse(securityMessage?.evidence.isEmpty ?? true)
        XCTAssertTrue(securityMessage?.recommendation.contains("shared world model") == true)
    }

    func testConflictingRecommendationHandlingRequiresLeadReview() {
        let workspaceID = UUID()
        let context = makeContext(workspaceID: workspaceID)
        let mission = AgentMissionBrief(
            workspaceID: workspaceID,
            objective: "Resolve production deploy incident with security policy risk.",
            environment: "production",
            riskLevel: .high
        )
        let engine = AgentDelegationEngine()
        let plan = engine.approveDelegation(
            engine.createDelegationPlan(mission: mission, context: context, requireHumanApproval: true),
            reason: "Approved specialist review."
        )
        let security = try! XCTUnwrap(plan.subMissions.first { $0.assignedRole == .securityAgent })
        let infrastructure = try! XCTUnwrap(plan.subMissions.first { $0.assignedRole == .infrastructureAgent })

        let report = engine.collectResults(
            plan: plan,
            context: context,
            results: [
                AgentSubMissionResult(
                    subMissionID: security.id,
                    role: .securityAgent,
                    findings: ["Production permission drift is unresolved."],
                    evidence: context.evidence,
                    recommendation: "Do not deploy until policy approval is recorded.",
                    confidence: 0.9
                ),
                AgentSubMissionResult(
                    subMissionID: infrastructure.id,
                    role: .infrastructureAgent,
                    findings: ["Rollback path is available."],
                    evidence: context.evidence,
                    recommendation: "Proceed with deploy after smoke tests.",
                    confidence: 0.7
                )
            ]
        )

        XCTAssertFalse(report.conflicts.isEmpty)
        XCTAssertTrue(report.requiresHumanLeadReview)
        XCTAssertEqual(report.status, .blocked)
        XCTAssertTrue(report.finalRecommendation.contains("Human FDE lead review"))
    }

    func testFinalAggregationCompletesWhenReportsAreGroundedAndAligned() {
        let workspaceID = UUID()
        let context = makeContext(workspaceID: workspaceID)
        let mission = AgentMissionBrief(
            workspaceID: workspaceID,
            objective: "Investigate code integration failure and prepare customer summary.",
            riskLevel: .medium
        )
        let engine = AgentDelegationEngine()
        let plan = engine.createDelegationPlan(
            mission: mission,
            context: context,
            requireHumanApproval: false
        )
        let results = plan.subMissions.map { subMission in
            AgentSubMissionResult(
                subMissionID: subMission.id,
                role: subMission.assignedRole,
                findings: ["\(subMission.assignedRole.displayName) finding is grounded in shared evidence."],
                evidence: context.evidence,
                recommendation: "Proceed with bounded fix and validation.",
                confidence: 0.85
            )
        }

        let report = engine.collectResults(plan: plan, context: context, results: results)
        let snapshot = engine.teamSnapshot(plan: plan, report: report)

        XCTAssertTrue(report.conflicts.isEmpty)
        XCTAssertFalse(report.requiresHumanLeadReview)
        XCTAssertEqual(report.status, .completed)
        XCTAssertFalse(report.finalFindings.isEmpty)
        XCTAssertFalse(report.evidence.isEmpty)
        XCTAssertEqual(snapshot.progress, 1)
        XCTAssertEqual(snapshot.status, .completed)
    }

    private func makeContext(workspaceID: UUID) -> SharedMissionContext {
        let evidence = EvidenceRecord(
            action: "fixture.inspect",
            source: "TestEvidence",
            result: "Verified integration failure and permission graph drift.",
            validation: .valid
        )
        let worldModel = SystemWorldModel(
            workspaceID: workspaceID,
            customerContext: "Enterprise customer",
            connectedSystems: ["CRM", "Billing API"],
            permissions: ["oauth:crm.write", "database:read"],
            previousFailures: ["OAuth token expired"],
            environmentFacts: ["production", "deployment pipeline"],
            observations: ["500 response on CRM sync"],
            evidence: [evidence.summary],
            permissionGraph: nil
        )
        return SharedMissionContext(
            workspaceID: workspaceID,
            worldModel: worldModel,
            evidence: [evidence],
            memory: AgentRelevantMemory(
                previousSimilarMissions: ["CRM sync recovery"],
                previousFailures: ["OAuth token expired"],
                successfulSolutions: ["Refresh token and retry connector sync"],
                customerEnvironmentKnowledge: ["Billing API depends on CRM account IDs"]
            )
        )
    }
}
