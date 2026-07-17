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

        XCTAssertEqual(report.verdict, .no)
        XCTAssertTrue(report.compatibilityMatrix.entries.allSatisfy { $0.status == .unknown })
        XCTAssertTrue(report.compatibilityMatrix.entries.allSatisfy { $0.claim.confidence == .unknown })
        XCTAssertTrue(report.compatibilityMatrix.entries.allSatisfy { $0.claim.evidence.isEmpty })
        XCTAssertFalse(report.integrationBlockers.blockers.isEmpty)
        XCTAssertFalse(report.unknownsAndNextInvestigationSteps.isEmpty)
    }

    func testChineseCustomerSupportOrderQueryExtractsNormalizedCapability() {
        let request = "请只读评估当前 Legacy 是否能接入客户支持 AI Agent，用于订单查询，不要修改任何文件。"
        let profile = AgentCapabilityProfile.detect(from: request)

        XCTAssertEqual(profile.kind, .customerSupportOrderLookup)
        XCTAssertEqual(profile.normalizedCapabilityID, "customer_support_order_lookup")
        XCTAssertEqual(profile.name, "Customer Support AI Agent — Read-only Order Lookup")
    }

    func testEnglishCustomerSupportOrderLookupExtractsNormalizedCapability() {
        let profile = AgentCapabilityProfile.detect(
            from: "Assess a customer-support AI Agent for read-only order lookup."
        )

        XCTAssertEqual(profile.kind, .customerSupportOrderLookup)
        XCTAssertEqual(profile.normalizedCapabilityID, "customer_support_order_lookup")
    }

    func testExplicitCustomerSupportOrderCapabilityNeverBecomesUnspecified() {
        let explicitRequests = [
            "客服 AI Agent 订单查询能力接入评估",
            "客户服务智能体查询订单状态",
            "customer service support agent order query assessment"
        ]

        for request in explicitRequests {
            XCTAssertNotEqual(AgentCapabilityProfile.detect(from: request).kind, .unspecified, request)
        }
    }

    func testOrderAuthAuditAndBoundedSupportingEvidenceAreInvestigated() throws {
        let request = "请评估客户支持 AI Agent 的订单查询能力。"
        let evidence = syntheticOrderLookupEvidence()
        let ledger = ledger(request: request, evidence: evidence)
        let architecture = LegacyArchitecture(ledger: ledger, evidence: evidence)
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .detect(from: request),
            evidenceLedger: ledger,
            legacyArchitecture: architecture,
            responseLanguage: .chinese
        )

        XCTAssertTrue(Set(architecture.inspectedPaths).isSuperset(of: [
            "src/orders.ts", "src/auth.ts", "src/audit.ts",
            "docs/architecture.md", "config/app.example.json"
        ]))
        XCTAssertEqual(status(.orderData, in: report), .supported)
        XCTAssertEqual(status(.apiServiceLayer, in: report), .supported)
        XCTAssertEqual(status(.authenticationBoundary, in: report), .supported)
        XCTAssertEqual(status(.permissionModel, in: report), .supported)
        XCTAssertEqual(status(.auditLogging, in: report), .supported)
        XCTAssertEqual(status(.readOnlyMutationBoundary, in: report), .supported)
        XCTAssertEqual(status(.recordLevelAuthorization, in: report), .blocked)
        XCTAssertEqual(status(.sensitiveResponseFieldControls, in: report), .blocked)
        XCTAssertTrue(report.evidenceRecords.contains { $0.path == "src/auth.ts" })
        XCTAssertTrue(report.evidenceRecords.contains { $0.path == "src/audit.ts" })
    }

    func testAvailableAssessmentEvidenceMustBeInspectedBeforeRequirementsComplete() {
        let request = "请评估客户支持 AI Agent 的订单查询能力。"
        let partialEvidence = Array(syntheticOrderLookupEvidence().prefix(2))
        let partialLedger = ledger(request: request, evidence: partialEvidence)

        XCTAssertTrue(partialLedger.unsatisfied.contains(.assessmentAuthentication))
        XCTAssertTrue(partialLedger.unsatisfied.contains(.assessmentAuditLogging))
        XCTAssertTrue(partialLedger.unsatisfied.contains(.assessmentArchitectureDocumentation))
        XCTAssertTrue(partialLedger.unsatisfied.contains(.assessmentExampleConfiguration))

        let completeLedger = ledger(request: request, evidence: syntheticOrderLookupEvidence())
        let assessmentRequirements: Set<ReadOnlyEvidenceRequirementKind> = [
            .assessmentOrderReadBoundary, .assessmentAPIServiceBoundary,
            .assessmentAuthentication, .assessmentRecordAuthorization,
            .assessmentPermissionModel, .assessmentAuditLogging,
            .assessmentMutationPaths, .assessmentSensitiveResponseFields,
            .assessmentArchitectureDocumentation, .assessmentExampleConfiguration
        ]
        XCTAssertTrue(assessmentRequirements.isDisjoint(with: Set(completeLedger.unsatisfied)))
    }

    func testPartialRequiresEvidenceBackedSupportedCapability() {
        var report = orderLookupReport(evidence: [])
        report.compatibilityMatrix.verdict = .partial
        report.compatibilityMatrix.entries = report.compatibilityMatrix.entries.map { entry in
            var entry = entry
            entry.status = .unknown
            entry.claim.evidence = []
            return entry
        }

        let validation = AssessmentSemanticConsistencyValidator.validate(report)

        XCTAssertTrue(validation.issues.contains(.partialWithoutSupportedEvidence))
    }

    func testPartialWithoutConcreteIntegrationOpportunityIsRejected() {
        var report = orderLookupReport(evidence: syntheticOrderLookupEvidence())
        report.compatibilityMatrix.verdict = .partial
        report.integrationOpportunities = []

        let validation = AssessmentSemanticConsistencyValidator.validate(report)

        XCTAssertTrue(validation.issues.contains(.partialWithoutIntegrationOpportunity))
    }

    func testUnknownAuthorizationIsAnUnresolvedSafetyBlocker() {
        let evidence = syntheticOrderLookupEvidence().filter { $0.targetPath != "src/auth.ts" }
        let report = orderLookupReport(evidence: evidence)

        XCTAssertEqual(status(.authenticationBoundary, in: report), .unknown)
        XCTAssertTrue(report.integrationBlockers.blockers.contains {
            $0.requirement == .authenticationBoundary && $0.severity == .high
        })
        XCTAssertTrue(report.securityAssessment.humanApprovalRequired)
    }

    func testNoBlockerClaimIsRejectedWhenMaterialRequirementsAreUnknown() {
        var report = orderLookupReport(
            evidence: syntheticOrderLookupEvidence().filter { $0.targetPath != "src/auth.ts" }
        )
        report.integrationBlockers.blockers = []

        let validation = AssessmentSemanticConsistencyValidator.validate(report)

        XCTAssertTrue(validation.issues.contains(.unresolvedAuthorizationWithoutBlocker))
        XCTAssertTrue(validation.issues.contains(.unknownMaterialRequirementWithoutBlocker))
    }

    func testOverallVerdictCitesConcreteEvidenceClaimsAndPaths() {
        let report = orderLookupReport(evidence: syntheticOrderLookupEvidence())
        let rendered = report.markdown()

        XCTAssertFalse(report.executiveSummary.evidence.isEmpty)
        XCTAssertTrue(rendered.contains(report.executiveSummary.claimID))
        XCTAssertTrue(rendered.contains("src/orders.ts"))
        XCTAssertFalse(rendered.contains("Evidence: none confirmed"))
    }

    func testCompatibilityRenderingUsesReadableStructuredCards() {
        let rendered = orderLookupReport(evidence: syntheticOrderLookupEvidence()).markdown()

        XCTAssertTrue(rendered.contains("### 4.1"))
        XCTAssertTrue(rendered.contains("- Requirement:"))
        XCTAssertTrue(rendered.contains("- Status:"))
        XCTAssertTrue(rendered.contains("- Evidence:"))
        XCTAssertTrue(rendered.contains("- Confidence:"))
        XCTAssertTrue(rendered.contains("- Remaining unknown:"))
        XCTAssertFalse(rendered.contains("| Requirement | Status |"))
    }

    func testChineseAssessmentReportRemainsChinesePrimary() {
        let request = "请评估客户支持 AI Agent 的订单查询能力。"
        let evidence = syntheticOrderLookupEvidence()
        let ledger = ledger(request: request, evidence: evidence)
        let report = LegacyAgentCompatibilityAnalyzer().assess(
            capability: .detect(from: request),
            evidenceLedger: ledger,
            legacyArchitecture: LegacyArchitecture(ledger: ledger, evidence: evidence),
            responseLanguage: .chinese
        )
        let rendered = report.markdown()

        XCTAssertTrue(rendered.contains("# FDE AI 接入评估报告"))
        XCTAssertTrue(rendered.contains("## 4. 兼容性矩阵"))
        XCTAssertTrue(rendered.contains("- 剩余未知："))
        XCTAssertTrue(ReadOnlyResponseLanguage.chinese.matches(rendered))
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

    func testAffirmativeChineseAndEnglishAssessmentRequestsRouteCapabilityWithoutLegacyKeywords() {
        let requests = [
            "请评估客户支持 AI Agent 的订单查询能力",
            "评估订单查询是否适合接入客服 Agent",
            "Assess whether a customer-support agent can perform read-only order lookup",
            "只读取当前 Legacy 项目，不要分析 Agent 项目。请评估客户支持 AI Agent 的只读订单查询接入能力，不要修改任何文件。"
        ]

        for request in requests {
            let intent = MissionIntentParser().parse(request)
            XCTAssertEqual(intent.intentType, .aiAgentCompatibilityAssessment, request)
            XCTAssertEqual(
                AgentCapabilityProfile.detect(from: request).kind,
                .customerSupportOrderLookup,
                request
            )
            XCTAssertTrue(intent.constraints.contains(.readOnly), request)
            XCTAssertFalse(intent.constraints.contains(.allowFileEdits), request)
        }
    }

    func testNegativeCandidatePatchReferenceRemainsAssessmentConstraintNotMutationMission() {
        let request = "Assess customer-support read-only order lookup; do not generate a Candidate Patch."
        let intent = MissionIntentParser().parse(request)

        XCTAssertEqual(intent.intentType, .aiAgentCompatibilityAssessment)
        XCTAssertEqual(AgentCapabilityProfile.detect(from: request).kind, .customerSupportOrderLookup)
        XCTAssertFalse(intent.constraints.contains(.allowFileEdits))
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

    private func syntheticOrderLookupEvidence() -> [ReadOnlyInspectionEvidence] {
        [
            item(
                "root", "engineering.inspect_project", ".",
                "src/orders.ts\nsrc/auth.ts\nsrc/audit.ts\ndocs/architecture.md\nconfig/app.example.json"
            ),
            item(
                "orders", "engineering.read_file", "src/orders.ts",
                """
                import { Principal, requireRole } from "./auth";
                export interface OrderSummary { orderID: string; customerID: string; status: "processing" | "shipped"; }
                export function listCustomerOrders(principal: Principal, customerID: string): OrderSummary[] {
                  requireRole(principal, "support");
                  return syntheticOrders.filter((order) => order.customerID === customerID);
                }
                """
            ),
            item(
                "auth", "engineering.read_file", "src/auth.ts",
                """
                export interface Principal { subject: string; roles: ("support" | "auditor")[]; }
                export function authenticate(exampleToken: string | undefined): Principal { if (!exampleToken) throw new Error("authentication required"); return { subject: "user", roles: ["support"] }; }
                export function requireRole(principal: Principal, role: string): void { if (!principal.roles.includes(role)) throw new Error("forbidden"); }
                """
            ),
            item(
                "audit", "engineering.read_file", "src/audit.ts",
                "export interface AuditRecord { actorID: string; action: \"orders.read\"; resourceID: string; outcome: \"allowed\" | \"denied\"; } export function recordAuditEvent(record: AuditRecord): string { return JSON.stringify(record); }"
            ),
            item(
                "architecture", "engineering.read_file", "docs/architecture.md",
                "The service models a read-only order route, a minimal authentication/role boundary, and an audit event. It has no business-action API."
            ),
            item(
                "config", "engineering.read_file", "config/app.example.json",
                #"{"environment":"demo","auditSink":"sink","outboundActionsEnabled": false}"#
            )
        ]
    }

    private func orderLookupReport(
        evidence: [ReadOnlyInspectionEvidence]
    ) -> FDEAIIntegrationAssessmentReport {
        let request = "Assess a customer-support AI Agent for read-only order lookup."
        let ledger = ledger(request: request, evidence: evidence)
        return LegacyAgentCompatibilityAnalyzer().assess(
            capability: .detect(from: request),
            evidenceLedger: ledger,
            legacyArchitecture: LegacyArchitecture(ledger: ledger, evidence: evidence)
        )
    }
}
