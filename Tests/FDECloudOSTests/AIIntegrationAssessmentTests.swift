import XCTest
@testable import FDECloudOS

final class AIIntegrationAssessmentTests: XCTestCase {
    func testCustomerSupportAssessmentDetectsDataAPIBoundaryAuthenticationAndRiskReport() throws {
        let request = "Can this system support a customer service AI agent?"
        let evidence = [
            item("root", "engineering.inspect_project", ".", "Repository: Legacy\nFiles: 12\nSource files: 8"),
            item(
                "schema",
                "engineering.read_file",
                "server/prisma/schema.prisma",
                "datasource db { provider = \"postgresql\" }\nmodel Customer { id Int @id }\nmodel Order { id Int @id customerId Int }"
            ),
            item(
                "routes",
                "engineering.read_file",
                "server/src/routes/customer.ts",
                "router.get('/customers/:id/orders', authorize('support'), async (request, response) => { const customer = request.params.id; return response.json({ customer, orders: [] }); });"
            ),
            item(
                "auth",
                "engineering.read_file",
                "server/src/middleware/auth.ts",
                "export function authenticateJWT(session) { return authorize(session.user, session.permissions); }"
            ),
            item(
                "knowledge",
                "engineering.read_file",
                "docs/support-knowledge.md",
                "# Approved customer support knowledge base\nReturns and delivery policies."
            )
        ]
        let ledger = ledger(request: request, evidence: evidence)
        let architecture = LegacyArchitecture(ledger: ledger, evidence: evidence)

        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .profile(for: .customerSupport),
            evidenceLedger: ledger,
            legacyArchitecture: architecture
        )

        XCTAssertEqual(report.requestedAICapability.kind, .customerSupport)
        XCTAssertEqual(status(.customerData, in: report), .supported)
        XCTAssertEqual(status(.orderData, in: report), .supported)
        XCTAssertEqual(status(.apiServiceLayer, in: report), .supported)
        XCTAssertEqual(status(.authenticationBoundary, in: report), .supported)
        XCTAssertEqual(status(.permissionModel, in: report), .supported)
        XCTAssertEqual(report.verdict, .yes)
        XCTAssertEqual(report.securityAssessment.permissionRisk, .low)
        XCTAssertTrue(report.validationTestPlan.tests.allSatisfy(\.generatedOnly))
        XCTAssertFalse(report.validationTestPlan.executionAuthorized)
        XCTAssertTrue(report.markdown().contains("## 10. Unknowns and Next Investigation Steps"))
        XCTAssertEqual(report.activitySnapshot.compatibility, .yes)
        XCTAssertEqual(report.activitySnapshot.blockerCount, 0)
        XCTAssertGreaterThan(report.activitySnapshot.evidenceCount, 0)
        XCTAssertEqual(report.activitySnapshot.missionState, .finalizingGroundedAssessment)
        XCTAssertEqual(report.expectedAgentWorkflows.first?.verificationStatus, .proposedNotRuntimeVerified)
        XCTAssertTrue(report.expectedAgentWorkflows.first?.prohibitedActions.contains("refund") == true)
        XCTAssertEqual(
            report.agentBlackBoxAssessment.agentSideBlackBoxes.count,
            AgentUncertaintyCategory.allCases.count
        )
        XCTAssertTrue(report.agentBlackBoxAssessment.agentSideBlackBoxes.allSatisfy {
            $0.evidenceOrInherentReason.contains("not inspected Legacy evidence")
        })
        let routeEvidence = try XCTUnwrap(report.evidenceRecords.first { $0.path == "server/src/routes/customer.ts" })
        XCTAssertEqual(routeEvidence.observationStatus, .directlyRead)
        XCTAssertEqual(routeEvidence.fileHash?.count, 64)
        XCTAssertNotNil(routeEvidence.lineRange)
        XCTAssertNotNil(routeEvidence.workspaceSnapshotIdentifier)
        XCTAssertNotNil(routeEvidence.relatedToolEventID)
        XCTAssertEqual(
            AIAssessmentActivitySnapshot(eventPayload: report.activitySnapshot.eventPayload),
            report.activitySnapshot
        )
    }

    func testMissingAPILayerBlocksRequiredIntegration() {
        let request = "Analyze whether this legacy system is ready for a data analysis AI agent."
        let evidence = [
            item("root", "engineering.inspect_project", ".", "Repository: Legacy\nFiles: 2"),
            item("schema", "engineering.read_file", "database/schema.sql", "CREATE TABLE metrics (id INTEGER, value REAL);"),
            item("route-search", "engineering.search_code", ".", "Found 0 matches.", query: "route"),
            item("controller-search", "engineering.search_code", ".", "Found 0 matches.", query: "controller"),
            item("endpoint-search", "engineering.search_code", ".", "Found 0 matches.", query: "endpoint")
        ]
        let ledger = ledger(request: request, evidence: evidence)
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .profile(for: .dataAnalysis),
            evidenceLedger: ledger,
            legacyArchitecture: LegacyArchitecture(ledger: ledger, evidence: evidence)
        )

        XCTAssertEqual(status(.apiServiceLayer, in: report), .blocked)
        XCTAssertEqual(report.verdict, .no)
        XCTAssertTrue(report.integrationBlockers.blockers.contains {
            $0.category == .architecture && $0.requirement == .apiServiceLayer
        })
    }

    func testMissingPermissionModelProducesHighSecurityRisk() {
        let request = "Can this project integrate a customer support AI agent?"
        let evidence = [
            item("root", "engineering.inspect_project", ".", "Repository: Legacy\nFiles: 5"),
            item("route", "engineering.read_file", "server/routes/customer.ts", "router.get('/customer/:id/orders', authenticateJWT, handler);"),
            item("auth", "engineering.read_file", "server/middleware/auth.ts", "function authenticateJWT(session) { return session.identity; }"),
            item("schema", "engineering.read_file", "server/schema.prisma", "model Customer { id Int @id }\nmodel Order { id Int @id }"),
            item("docs", "engineering.read_file", "docs/knowledge.md", "Approved knowledge base."),
            item("permission-search", "engineering.search_code", ".", "Found 0 matches.", query: "permission"),
            item("authorize-search", "engineering.search_code", ".", "Found 0 matches.", query: "authorize"),
            item("rbac-search", "engineering.search_code", ".", "Found 0 matches.", query: "rbac")
        ]
        let ledger = ledger(request: request, evidence: evidence)
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .profile(for: .customerSupport),
            evidenceLedger: ledger,
            legacyArchitecture: LegacyArchitecture(ledger: ledger, evidence: evidence)
        )

        XCTAssertEqual(status(.permissionModel, in: report), .blocked)
        XCTAssertEqual(report.securityAssessment.permissionRisk, .high)
        XCTAssertEqual(report.securityAssessment.dataAccessRisk, .high)
        XCTAssertTrue(report.securityAssessment.humanApprovalRequired)
        XCTAssertTrue(report.integrationBlockers.blockers.contains {
            $0.category == .security && $0.requirement == .permissionModel && $0.severity == .high
        })
    }

    func testDatabaseOnlySystemRecommendsServiceLayerBeforeAgent() {
        let request = "Can this database-only legacy system support a data analysis agent?"
        let evidence = [
            item("root", "engineering.inspect_project", ".", "Repository: DatabaseOnly\nFiles: 1"),
            item("schema", "engineering.read_file", "schema.sql", "CREATE TABLE metrics (id INTEGER, value REAL);"),
            item("route-search", "engineering.search_code", ".", "Found 0 matches.", query: "route"),
            item("controller-search", "engineering.search_code", ".", "Found 0 matches.", query: "controller"),
            item("endpoint-search", "engineering.search_code", ".", "Found 0 matches.", query: "endpoint")
        ]
        let ledger = ledger(request: request, evidence: evidence)
        let architecture = LegacyArchitecture(ledger: ledger, evidence: evidence)
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .profile(for: .dataAnalysis),
            evidenceLedger: ledger,
            legacyArchitecture: architecture
        )

        XCTAssertTrue(architecture.isDatabaseOnly)
        XCTAssertTrue(report.integrationOpportunities.contains { $0.feature == "API/service layer prerequisite" })
        XCTAssertTrue(report.integrationPlan.steps[0].purpose.contains("direct database access is prohibited"))
        XCTAssertTrue(report.recommendedArchitecture.claim.statement.contains("never connect the agent directly"))
    }

    func testMissingEvidenceStaysUnknownAndNeverBecomesSupportedOrBlocked() {
        let request = "Can this Legacy system safely connect with a customer support AI Agent?"
        let evidence = [
            item("root", "engineering.inspect_project", ".", "Repository: Legacy\nFiles: 1"),
            item("single-search", "engineering.search_code", ".", "Found 0 matches.", query: "permission")
        ]
        let ledger = ledger(request: request, evidence: evidence)
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .profile(for: .customerSupport),
            evidenceLedger: ledger,
            legacyArchitecture: LegacyArchitecture(ledger: ledger, evidence: evidence)
        )

        XCTAssertEqual(report.verdict, .partial)
        XCTAssertTrue(report.compatibilityMatrix.entries.allSatisfy { $0.status == .unknown })
        XCTAssertTrue(report.compatibilityMatrix.entries.allSatisfy { $0.claim.confidence == .unknown })
        XCTAssertTrue(report.compatibilityMatrix.entries.allSatisfy { $0.claim.evidence.isEmpty })
        XCTAssertTrue(report.integrationBlockers.blockers.isEmpty)
        XCTAssertFalse(report.unknownsAndNextInvestigationSteps.isEmpty)
    }

    func testIntentSelectsAssessmentMissionAndCapabilityProfile() {
        let intent = MissionIntentParser().parse("Find blockers preventing a workflow automation AI agent integration.")

        XCTAssertEqual(intent.intentType, .aiAgentCompatibilityAssessment)
        XCTAssertTrue(intent.constraints.contains(.readOnly))
        XCTAssertFalse(intent.constraints.contains(.allowFileEdits))
        XCTAssertTrue(intent.expectedOutputs.contains(.aiIntegrationAssessmentReport))
        XCTAssertEqual(AgentCapabilityProfile.detect(from: intent.originalText).kind, .workflowAutomation)
        XCTAssertEqual(MissionExecutionSemantic(intent: intent), .readOnlyWorkspaceInspection)
    }

    func testGenericAssessmentDoesNotAssumeCustomerSupportCapability() {
        let profile = AgentCapabilityProfile.detect(from: "Can this legacy application integrate an AI assistant?")

        XCTAssertEqual(profile.kind, .unspecified)
        XCTAssertFalse(profile.proposesWriteAccess)
        XCTAssertEqual(
            Set(profile.requiredCapabilities.map(\.capability)),
            Set([.apiServiceLayer, .authenticationBoundary, .permissionModel, .auditLogging])
        )
    }

    private func status(
        _ capability: LegacyArchitectureCapability,
        in report: FDEAIIntegrationAssessmentReport
    ) -> AgentCompatibilityStatus? {
        report.compatibilityMatrix.entries.first { $0.requirement.capability == capability }?.status
    }

    private func ledger(
        request: String,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> ReadOnlyFinalizationEvidenceLedger {
        ReadOnlyFinalizationEvidenceLedger(
            requirements: ReadOnlyEvidenceRequirements(request: request),
            evidence: evidence
        )
    }

    private func item(
        _ id: String,
        _ tool: String,
        _ path: String,
        _ output: String,
        query: String? = nil
    ) -> ReadOnlyInspectionEvidence {
        ReadOnlyInspectionEvidence(
            toolCallID: id,
            toolName: tool,
            workspaceID: UUID(),
            workspaceIdentity: "legacy",
            targetPath: path,
            output: output,
            toolCalledEventID: UUID(),
            toolResultEventID: UUID(),
            query: query
        )
    }
}
