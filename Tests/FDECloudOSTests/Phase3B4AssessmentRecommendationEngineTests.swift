import XCTest
@testable import FDECloudOS

final class Phase3B4AssessmentRecommendationEngineTests: XCTestCase {
    func testRecommendationSetIsDeterministicGroundedAndAdvisory() throws {
        let report = try makeReport(verdict: .partial)

        let first = AssessmentRecommendationEngine.generate(from: report)
        let second = AssessmentRecommendationEngine.recommend(from: report)
        let recommendationSet = try XCTUnwrap(first.recommendationSet)
        let validatedClaimIDs = Set(report.evidenceAppendix.map(\.claimID))

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.accepted)
        XCTAssertEqual(first.decision, .conditionallyProceed)
        XCTAssertEqual(recommendationSet.schemaVersion, "3B.4")
        XCTAssertEqual(recommendationSet.sourceReportID, report.reportID)
        XCTAssertEqual(recommendationSet.binding, report.workspaceTaskSessionBinding)
        XCTAssertEqual(recommendationSet.authority, .advisoryOnly)
        XCTAssertFalse(recommendationSet.executionAuthorized)
        XCTAssertFalse(recommendationSet.recommendations.isEmpty)
        XCTAssertTrue(recommendationSet.recommendations.allSatisfy {
            $0.authority == .advisoryOnly
                && !$0.executionAuthorized
                && !$0.sourceClaimIDs.isEmpty
                && Set($0.sourceClaimIDs).isSubset(of: validatedClaimIDs)
        })
        XCTAssertTrue(recommendationSet.recommendations.contains { $0.category == .decisionGate })
        XCTAssertTrue(recommendationSet.recommendations.contains { $0.category == .securityControl })
        XCTAssertTrue(recommendationSet.recommendations.contains { $0.category == .evidenceInvestigation })
        XCTAssertTrue(recommendationSet.recommendations.contains { $0.category == .integrationDesign })
        XCTAssertTrue(recommendationSet.recommendations.contains { $0.category == .validation })
        XCTAssertEqual(
            recommendationSet.recommendationSetID,
            AssessmentRecommendationEngine.reconstructRecommendationSetID(recommendationSet)
        )
    }

    func testExecutiveVerdictMapsToFailClosedRecommendationDecision() throws {
        let expectations: [(AssessmentExecutiveVerdict, AssessmentRecommendationDecision)] = [
            (.yes, .proceedToValidation),
            (.partial, .conditionallyProceed),
            (.no, .doNotProceed),
            (.unknown, .investigate)
        ]

        for (verdict, expectedDecision) in expectations {
            let result = AssessmentRecommendationEngine.generate(
                from: try makeReport(verdict: verdict)
            )
            XCTAssertEqual(result.decision, expectedDecision)
            XCTAssertEqual(result.recommendationSet?.decision, expectedDecision)
            XCTAssertFalse(result.recommendationSet?.executionAuthorized ?? true)
        }
    }

    func testBlockersProduceCriticalRemediationBeforeAnyDesignAdvice() throws {
        let report = try makeReport(verdict: .no)
        let recommendationSet = try XCTUnwrap(
            AssessmentRecommendationEngine.generate(from: report).recommendationSet
        )
        let blocker = try XCTUnwrap(
            recommendationSet.recommendations.first { $0.category == .blockerRemediation }
        )
        let design = try XCTUnwrap(
            recommendationSet.recommendations.first { $0.category == .integrationDesign }
        )

        XCTAssertEqual(recommendationSet.decision, .doNotProceed)
        XCTAssertEqual(blocker.priority, .critical)
        XCTAssertTrue(blocker.requiresHumanApproval)
        XCTAssertLessThan(
            try XCTUnwrap(recommendationSet.recommendations.firstIndex(of: blocker)),
            try XCTUnwrap(recommendationSet.recommendations.firstIndex(of: design))
        )
        XCTAssertTrue(
            recommendationSet.recommendations.first?.category == .decisionGate
                || recommendationSet.recommendations.first?.category == .blockerRemediation
        )
    }

    func testTamperedOrDanglingSourceReportFailsClosed() throws {
        let source = try makeReport(verdict: .partial)

        var identityTamper = source
        identityTamper.composition?.executiveVerdict = .yes
        let identityResult = AssessmentRecommendationEngine.generate(from: identityTamper)
        XCTAssertNil(identityResult.recommendationSet)
        XCTAssertEqual(identityResult.decision, .investigate)
        XCTAssertTrue(identityResult.validationFailures.contains {
            $0.code == .sourceReportIdentityMismatch
        })

        var dangling = source
        let danglingEntry = AssessmentReportSectionEntry(
            claimID: "claim-not-in-appendix",
            section: .unknown,
            disposition: .unknown,
            required: false,
            capability: nil,
            riskLevel: nil,
            riskDomain: nil,
            blockerCategory: nil,
            title: nil,
            integrationPath: [],
            architectureComponents: []
        )
        dangling.composition?.sections.unknowns.append(danglingEntry)
        if let composition = dangling.composition {
            dangling.composition?.reportID = AssessmentReportComposer.reconstructReportID(composition)
        }
        let danglingResult = AssessmentRecommendationEngine.generate(from: dangling)
        XCTAssertNil(danglingResult.recommendationSet)
        XCTAssertTrue(danglingResult.validationFailures.contains {
            $0.code == .danglingSectionClaim && $0.claimID == danglingEntry.claimID
        })
    }

    func testRecommendationValidationRejectsAuthorityAndUnsupportedClaimTampering() throws {
        let report = try makeReport(verdict: .yes)
        let source = try XCTUnwrap(
            AssessmentRecommendationEngine.generate(from: report).recommendationSet
        )

        var authorityTamper = source
        authorityTamper.executionAuthorized = true
        XCTAssertTrue(AssessmentRecommendationEngine.validate(authorityTamper, against: report).contains {
            $0.code == .invalidRecommendationAuthority
        })

        var claimTamper = source
        claimTamper.recommendations[0].sourceClaimIDs.append("claim-model-invention")
        claimTamper.sourceClaimIDs.append("claim-model-invention")
        claimTamper.recommendationSetID = AssessmentRecommendationEngine
            .reconstructRecommendationSetID(claimTamper)
        let failures = AssessmentRecommendationEngine.validate(claimTamper, against: report)
        XCTAssertTrue(failures.contains { $0.code == .unsupportedRecommendationClaim })
        XCTAssertTrue(failures.contains { $0.code == .recommendationIdentityMismatch })
    }

    func testRecommendationPersistenceRoundTripPreservesAdvisoryAuthority() throws {
        let report = try makeReport(verdict: .yes)
        let recommendationSet = try XCTUnwrap(
            report.phase3B4Recommendations().recommendationSet
        )
        let payload = try recommendationSet.persistenceEventPayload()
        let decoded = try AssessmentRecommendationSet.reload(from: payload)

        XCTAssertEqual(decoded, recommendationSet)
        XCTAssertEqual(payload["assessment_recommendation_execution_authorized"], "false")

        var tamperedPayload = payload
        tamperedPayload["assessment_recommendation_json"]?.append(" ")
        XCTAssertThrowsError(try AssessmentRecommendationSet.reload(from: tamperedPayload)) { error in
            XCTAssertEqual(error as? AssessmentRecommendationPersistenceError, .digestMismatch)
        }

        let event = ExecutionEvent(
            id: uuid("00000000-0000-0000-0000-000000000099"),
            parentEventID: nil,
            workspaceID: recommendationSet.binding.workspaceID,
            taskID: recommendationSet.binding.taskID,
            type: .stateUpdated,
            sequence: 99,
            timestamp: recommendationSet.generatedAt,
            summary: "Phase 3B.4 recommendations generated.",
            payload: payload
        )
        XCTAssertEqual(try AssessmentRecommendationSet.reload(from: event), recommendationSet)
    }

    func testLegacyAssessmentWithoutCompositionCannotProduceRecommendations() throws {
        var report = try makeReport(verdict: .yes)
        report.composition = nil

        let result = AssessmentRecommendationEngine.generate(from: report)

        XCTAssertNil(result.recommendationSet)
        XCTAssertEqual(result.decision, .investigate)
        XCTAssertEqual(result.validationFailures.map(\.code), [.missingComposition])
    }

    private struct Fixture {
        var context: AssessmentReportCompositionContext
        var evidence: [ReadOnlyInspectionEvidence]
        var ledger: ReadOnlyFinalizationEvidenceLedger
        var events: [ExecutionEvent]
        var claims: Claims
    }

    private struct Claims {
        var summary: AssessmentClaim
        var supported: AssessmentClaim
        var unknown: AssessmentClaim
        var blocker: AssessmentClaim
        var risk: AssessmentClaim
        var recommendation: AssessmentClaim
    }

    private func makeReport(
        verdict: AssessmentExecutiveVerdict
    ) throws -> FDEAIIntegrationAssessmentReport {
        var fixture = try fixture()
        let capabilities: [LegacyArchitectureCapability]
        let placements: [AssessmentReportClaimPlacement]
        switch verdict {
        case .yes:
            capabilities = [.apiServiceLayer]
            placements = commonPlacements(fixture.claims) + [
                compatibility(
                    fixture.claims.supported,
                    capability: .apiServiceLayer,
                    disposition: .supported
                )
            ]
        case .partial:
            capabilities = [.apiServiceLayer, .authenticationBoundary]
            placements = commonPlacements(fixture.claims) + [
                compatibility(
                    fixture.claims.supported,
                    capability: .apiServiceLayer,
                    disposition: .supported
                ),
                compatibility(
                    fixture.claims.unknown,
                    capability: .authenticationBoundary,
                    disposition: .unknown
                ),
                AssessmentReportClaimPlacement(
                    claim: fixture.claims.unknown,
                    section: .unknown,
                    disposition: .unknown,
                    required: true,
                    capability: .authenticationBoundary
                )
            ]
        case .no:
            capabilities = [.apiServiceLayer]
            placements = commonPlacements(fixture.claims) + [
                compatibility(
                    fixture.claims.blocker,
                    capability: .apiServiceLayer,
                    disposition: .blocked
                ),
                AssessmentReportClaimPlacement(
                    claim: fixture.claims.blocker,
                    section: .blocker,
                    disposition: .blocked,
                    required: true,
                    capability: .apiServiceLayer,
                    riskLevel: .high,
                    blockerCategory: .architecture
                )
            ]
        case .unknown:
            capabilities = [.apiServiceLayer]
            placements = commonPlacements(fixture.claims) + [
                compatibility(
                    fixture.claims.unknown,
                    capability: .apiServiceLayer,
                    disposition: .unknown
                ),
                AssessmentReportClaimPlacement(
                    claim: fixture.claims.unknown,
                    section: .unknown,
                    disposition: .unknown,
                    required: true,
                    capability: .apiServiceLayer
                )
            ]
        }
        fixture.context.requestedCapability = AgentCapabilityProfile(
            kind: .unspecified,
            requiredCapabilities: capabilities.map {
                AgentCapabilityRequirement(
                    capability: $0,
                    required: true,
                    critical: true,
                    rationale: "Required for the Phase 3B.4 fixture."
                )
            },
            proposesWriteAccess: false
        )
        let result = AssessmentReportComposer.compose(
            context: fixture.context,
            claims: placements,
            evidenceLedger: fixture.ledger,
            evidence: fixture.evidence,
            executionEvents: fixture.events
        )
        XCTAssertEqual(result.executiveVerdict, verdict)
        return try XCTUnwrap(result.report)
    }

    private func commonPlacements(
        _ claims: Claims
    ) -> [AssessmentReportClaimPlacement] {
        [
            AssessmentReportClaimPlacement(
                claim: claims.summary,
                section: .executiveSummary,
                disposition: .advisory
            ),
            AssessmentReportClaimPlacement(
                claim: claims.risk,
                section: .securityAndAuthorization,
                disposition: .partial,
                riskLevel: .medium,
                riskDomain: .permission
            ),
            AssessmentReportClaimPlacement(
                claim: claims.recommendation,
                section: .recommendation,
                disposition: .advisory,
                title: "Mediated service boundary",
                integrationPath: ["AI Agent", "Permission-aware adapter", "Legacy API"],
                architectureComponents: ["Permission-aware adapter"]
            )
        ]
    }

    private func compatibility(
        _ claim: AssessmentClaim,
        capability: LegacyArchitectureCapability,
        disposition: AssessmentReportClaimDisposition
    ) -> AssessmentReportClaimPlacement {
        AssessmentReportClaimPlacement(
            claim: claim,
            section: .capabilityCompatibility,
            disposition: disposition,
            capability: capability
        )
    }

    private func fixture() throws -> Fixture {
        let workspaceID = uuid("00000000-0000-0000-0000-000000000001")
        let taskID = uuid("00000000-0000-0000-0000-000000000002")
        let sessionID = uuid("00000000-0000-0000-0000-000000000003")
        let calledID = uuid("00000000-0000-0000-0000-000000000010")
        let resultID = uuid("00000000-0000-0000-0000-000000000011")
        let output = #"{"name":"legacy","dependencies":{"express":"1.0.0"}}"#
        let evidence = ReadOnlyInspectionEvidence(
            toolCallID: "read-manifest",
            toolName: "engineering.read_file",
            workspaceID: workspaceID,
            workspaceIdentity: "legacy",
            targetPath: "package.json",
            output: output,
            toolCalledEventID: calledID,
            toolResultEventID: resultID
        )
        let requirements = try XCTUnwrap(
            ReadOnlyEvidenceRequirements(
                planRequirementIDs: [ReadOnlyEvidenceRequirementKind.projectManifest.rawValue]
            )
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: [evidence]
        )
        let reference = AssessmentEvidenceReference(
            source: .extractedConfiguration,
            workspaceIdentity: "legacy",
            path: "package.json",
            fact: "The inspected manifest declares the express dependency.",
            claimLevel: .configurationConfirmed,
            observationStatus: .directlyRead,
            sourceComponent: "package.json",
            safeEvidenceSummary: "package.json declares dependency express.",
            lineRange: "1-1",
            workspaceSnapshotIdentifier: "workspace-\(workspaceID.uuidString.lowercased())",
            relatedToolEventID: resultID
        )
        func claim(_ id: String, _ statement: String, _ unknowns: [String]) -> AssessmentClaim {
            AssessmentClaim(
                claimID: id,
                statement: statement,
                evidence: [reference],
                confidence: .high,
                unknowns: unknowns
            )
        }
        let claims = Claims(
            summary: claim(
                "claim-summary",
                "The inspected manifest provides one bounded static assessment fact.",
                ["Runtime behavior remains unverified."]
            ),
            supported: claim(
                "claim-service-supported",
                "The inspected manifest declares the express service dependency.",
                ["The service was not run."]
            ),
            unknown: claim(
                "claim-auth-unknown",
                "Authentication behavior is not established by the inspected manifest.",
                ["Authentication implementation remains unknown."]
            ),
            blocker: claim(
                "claim-service-blocked",
                "The requested service boundary conflicts with the bounded assessment requirement.",
                ["A remediated boundary has not been inspected."]
            ),
            risk: claim(
                "claim-permission-risk",
                "Permission behavior is not established by the inspected manifest.",
                ["Permission enforcement remains unknown."]
            ),
            recommendation: claim(
                "claim-mediated-design",
                "The inspected service dependency can be considered during mediated boundary design.",
                ["The proposed design is not runtime verified."]
            )
        )
        let context = AssessmentReportCompositionContext(
            workspaceID: workspaceID,
            taskID: taskID,
            sessionID: sessionID,
            requestedCapability: AgentCapabilityProfile.profile(for: .unspecified),
            scopeDescription: "Bounded Phase 3B.4 recommendation fixture."
        )
        let events = [
            ExecutionEvent(
                id: calledID,
                parentEventID: nil,
                workspaceID: workspaceID,
                taskID: taskID,
                type: .toolCalled,
                sequence: 1,
                timestamp: Date(timeIntervalSince1970: 1_700_000_001),
                summary: "Read-only tool called.",
                payload: [
                    "lifecycle_event": ExecutionPlanLifecycleEvent.toolCalled.rawValue,
                    "tool_call_id": evidence.toolCallID
                ]
            ),
            ExecutionEvent(
                id: resultID,
                parentEventID: calledID,
                workspaceID: workspaceID,
                taskID: taskID,
                type: .stepExecuted,
                sequence: 2,
                timestamp: Date(timeIntervalSince1970: 1_700_000_002),
                summary: "Read-only tool result recorded.",
                payload: [
                    "lifecycle_event": ExecutionPlanLifecycleEvent.toolResult.rawValue,
                    "tool_call_id": evidence.toolCallID,
                    "success": "true",
                    "evidence_eligible": "true"
                ]
            )
        ]
        return Fixture(
            context: context,
            evidence: [evidence],
            ledger: ledger,
            events: events,
            claims: claims
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
