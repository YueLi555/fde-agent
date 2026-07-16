import XCTest
@testable import FDECloudOS

final class Phase2CAcceptanceBenchmarkTests: XCTestCase {
    func testAllTwentyDeterministicAcceptanceCasesPassAndExposeStableOutput() throws {
        let benchmark = Phase2CAcceptanceBenchmark()
        let first = benchmark.runAll()
        let second = benchmark.runAll()

        XCTAssertEqual(first.count, 20)
        XCTAssertEqual(first.map(\.caseID), Phase2CAcceptanceCaseID.allCases)
        XCTAssertTrue(first.allSatisfy(\.passed), first.filter { !$0.passed }.map(\.caseID.rawValue).joined(separator: ", "))
        XCTAssertTrue(first.allSatisfy { !$0.requestedCapability.isEmpty })
        XCTAssertTrue(first.allSatisfy { !$0.compatibilityItems.isEmpty })
        XCTAssertTrue(first.allSatisfy { !$0.agentSideBlackBoxes.isEmpty })
        XCTAssertTrue(first.allSatisfy { !$0.proposedOperationalWorkflow.isEmpty })
        XCTAssertTrue(first.allSatisfy { !$0.validationPlan.tests.isEmpty })
        XCTAssertTrue(first.allSatisfy { !$0.terminalState.isEmpty && !$0.passFailReason.isEmpty })

        let firstJSON = try JSONCoding.encode(first)
        let secondJSON = try JSONCoding.encode(second)
        XCTAssertEqual(firstJSON, secondJSON)
    }

    func testBenchmarkPreservesUnknownConflictScopeAndSensitiveFileContracts() throws {
        let results = Dictionary(
            uniqueKeysWithValues: Phase2CAcceptanceBenchmark().runAll().map { ($0.caseID, $0) }
        )
        let missing = try XCTUnwrap(results[.missingEvidenceUnknown])
        XCTAssertTrue(missing.compatibilityItems.allSatisfy { $0.status == .unknown })

        let conflict = try XCTUnwrap(results[.conflictingEvidence])
        XCTAssertEqual(
            conflict.compatibilityItems.first { $0.capability == LegacyArchitectureCapability.apiServiceLayer.rawValue }?.status,
            .unknown
        )

        let scope = try XCTUnwrap(results[.legacyOnlyScopeIsolation])
        XCTAssertFalse(scope.evidenceRecords.contains { $0.path.lowercased().contains("agent") })

        let sensitive = try XCTUnwrap(results[.sensitiveFileExclusion])
        XCTAssertFalse(sensitive.evidenceRecords.contains { ReadOnlySensitivePathPolicy.isSensitive($0.path) })
    }

    func testWorkflowBlackBoxAndProvenanceContractsAreMachineReadable() throws {
        let result = try XCTUnwrap(
            Phase2CAcceptanceBenchmark().runAll().first { $0.caseID == .fullySupportedReadOnlyCustomerSupport }
        )
        let workflow = try XCTUnwrap(result.proposedOperationalWorkflow.first)

        XCTAssertEqual(workflow.verificationStatus, .proposedNotRuntimeVerified)
        XCTAssertFalse(workflow.trigger.isEmpty)
        XCTAssertFalse(workflow.agentDecisionBoundary.isEmpty)
        XCTAssertFalse(workflow.legacyIntegrationCall.isEmpty)
        XCTAssertFalse(workflow.dataReadOrProposedAction.isEmpty)
        XCTAssertFalse(workflow.permissionCheck.isEmpty)
        XCTAssertFalse(workflow.humanApprovalPoint.isEmpty)
        XCTAssertFalse(workflow.expectedOutput.isEmpty)
        XCTAssertFalse(workflow.failureBehavior.isEmpty)
        XCTAssertFalse(workflow.fallbackBehavior.isEmpty)
        XCTAssertTrue(workflow.prohibitedActions.contains("refund"))
        XCTAssertEqual(result.agentSideBlackBoxes.count, AgentUncertaintyCategory.allCases.count)
        XCTAssertTrue(result.agentSideBlackBoxes.allSatisfy {
            $0.evidenceOrInherentReason.contains("not inspected Legacy evidence")
        })
        XCTAssertTrue(result.evidenceRecords.allSatisfy {
            !$0.path.isEmpty
                && !$0.sourceComponent.isEmpty
                && !$0.safeEvidenceSummary.isEmpty
                && $0.claimLevel != nil
        })
    }

    func testProductManifestLanguageDoesNotImplyProductionImpact() {
        let assessment = RiskAssessmentEngine().assess(
            step: PlanStep(
                id: "manifest",
                title: "Inspect package manifest",
                intent: "Identify package boundaries, products, dependencies, and executable targets.",
                toolCallID: "manifest-read",
                requiresApproval: false
            ),
            toolCall: ToolCall(
                id: "manifest-read",
                type: .shell,
                command: "/bin/ls",
                arguments: ["-la", "Package.swift"],
                workingDirectory: nil,
                requiresApproval: false
            ),
            workspace: Workspace(id: UUID(), name: "Acceptance", role: .fde, createdAt: Date()),
            plannerRisks: [
                RiskSignal(
                    id: "risk.partial-context",
                    title: "Input may omit production constraints",
                    severity: .medium,
                    mitigation: "Preserve evidence without assuming a live environment."
                )
            ]
        )

        XCTAssertEqual(assessment.input.productionImpact, .none)
        XCTAssertEqual(assessment.level, .medium)
        XCTAssertFalse(assessment.requiresApproval)
    }
}
