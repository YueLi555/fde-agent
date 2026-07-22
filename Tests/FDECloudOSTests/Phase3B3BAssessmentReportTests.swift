import XCTest
@testable import FDECloudOS

final class Phase3B3BAssessmentReportTests: XCTestCase {
    func testReportRoundTripAndCompositionAreDeterministic() throws {
        let fixture = try fixture()
        let placements = partialPlacements(fixture)

        let first = AssessmentReportComposer.compose(
            context: fixture.context,
            claims: placements,
            evidenceLedger: fixture.ledger,
            evidence: fixture.evidence,
            executionEvents: fixture.events
        )
        let second = AssessmentReportComposer.compose(
            context: fixture.context,
            claims: Array(placements.reversed()),
            evidenceLedger: fixture.ledger,
            evidence: Array(fixture.evidence.reversed()),
            executionEvents: Array(fixture.events.reversed())
        )
        let report = try XCTUnwrap(first.report)
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(FDEAIIntegrationAssessmentReport.self, from: encoded)

        XCTAssertEqual(first, second)
        XCTAssertEqual(decoded, report)
        XCTAssertEqual(report.executiveVerdict, .partial)
        XCTAssertEqual(report.confidence, .medium)
        XCTAssertTrue(report.reportID.hasPrefix("assessment-report-"))
    }

    func testInvalidAndMissingEvidenceClaimsAreRejectedWithoutBecomingConclusions() throws {
        var fixture = try fixture(singleRequiredCapability: .apiServiceLayer)
        let unsupportedStatement = "An unsupported architecture conclusion exists."
        let invalid = AssessmentClaim(
            claimID: "claim-invalid-no-evidence",
            statement: unsupportedStatement,
            evidence: [],
            confidence: .low,
            unknowns: ["No evidence was collected."]
        )
        let placements = [
            compatibilityPlacement(
                fixture.directClaim,
                capability: .apiServiceLayer,
                disposition: .supported
            ),
            AssessmentReportClaimPlacement(
                claim: invalid,
                section: .observedLegacyArchitecture,
                disposition: .supported
            )
        ]

        let result = compose(fixture, placements: placements)
        let report = try XCTUnwrap(result.report)

        XCTAssertTrue(result.excludedClaimIDs.contains(invalid.claimID))
        XCTAssertTrue(result.validationFailures.contains {
            $0.claimID == invalid.claimID && $0.claimValidationFailure == .missingEvidence
        })
        XCTAssertFalse(report.materialClaims.contains { $0.claimID == invalid.claimID })
        XCTAssertFalse(report.evidenceAppendix.contains { $0.claimID == invalid.claimID })
        XCTAssertFalse(report.markdown().contains(unsupportedStatement))

        fixture.events.removeAll { $0.id == fixture.directEvidence.toolResultEventID }
        let missingLineage = compose(
            fixture,
            placements: [compatibilityPlacement(
                fixture.directClaim,
                capability: .apiServiceLayer,
                disposition: .supported
            )]
        )
        XCTAssertNil(missingLineage.report)
        XCTAssertEqual(missingLineage.executiveVerdict, .unknown)
        XCTAssertTrue(missingLineage.validationFailures.contains {
            $0.code == .missingExecutionEvent
        })
    }

    func testVerdictAndConfidenceAreDerivedOnlyFromValidatedClaims() throws {
        let yesFixture = try fixture(singleRequiredCapability: .apiServiceLayer)
        let yes = compose(
            yesFixture,
            placements: [compatibilityPlacement(
                yesFixture.directClaim,
                capability: .apiServiceLayer,
                disposition: .supported
            )]
        )
        XCTAssertEqual(yes.executiveVerdict, .yes)
        XCTAssertEqual(yes.confidence, .high)

        let mixedFixture = try fixture()
        let partial = compose(mixedFixture, placements: partialPlacements(mixedFixture))
        XCTAssertEqual(partial.executiveVerdict, .partial)
        XCTAssertEqual(partial.confidence, .medium)

        let no = compose(
            mixedFixture,
            placements: [
                compatibilityPlacement(
                    mixedFixture.directClaim,
                    capability: .apiServiceLayer,
                    disposition: .supported
                ),
                AssessmentReportClaimPlacement(
                    claim: mixedFixture.searchClaim,
                    section: .blocker,
                    disposition: .blocked,
                    capability: .authenticationBoundary,
                    riskLevel: .high,
                    blockerCategory: .security
                )
            ]
        )
        XCTAssertEqual(no.executiveVerdict, .no)
        XCTAssertEqual(no.confidence, .medium)

        let unknown = compose(
            mixedFixture,
            placements: [compatibilityPlacement(
                mixedFixture.searchClaim,
                capability: .authenticationBoundary,
                disposition: .unknown
            )]
        )
        XCTAssertEqual(unknown.executiveVerdict, .unknown)
        XCTAssertEqual(unknown.confidence, .medium)
        XCTAssertNil(unknown.report?.activitySnapshot.compatibility)
    }

    func testLanguageModelExplanationCannotModifyAuthorityOrAddUnsupportedClaim() throws {
        let fixture = try fixture(singleRequiredCapability: .apiServiceLayer)
        let placement = compatibilityPlacement(
            fixture.directClaim,
            capability: .apiServiceLayer,
            disposition: .supported
        )
        let proposedStatement = "The model invented an additional integration risk."
        let proposedClaim = AssessmentClaim(
            claimID: "claim-model-invention",
            statement: proposedStatement,
            evidence: [],
            confidence: .high,
            unknowns: []
        )
        let draft = AssessmentReportExplanationDraft(
            narrative: "A readable summary that attempts to change authority.",
            sourceClaimIDs: [fixture.directClaim.claimID],
            proposedVerdict: .no,
            proposedConfidence: .unknown,
            proposedClaims: [proposedClaim],
            proposedRiskClaimIDs: [proposedClaim.claimID],
            unknownClaimIDsToOmit: [fixture.directClaim.claimID]
        )

        let result = compose(fixture, placements: [placement], explanation: draft)
        let report = try XCTUnwrap(result.report)

        XCTAssertEqual(report.executiveVerdict, .yes)
        XCTAssertEqual(report.confidence, .high)
        XCTAssertNil(report.composition?.explanation)
        XCTAssertTrue(result.validationFailures.contains { $0.code == .explanationAuthorityViolation })
        XCTAssertTrue(result.validationFailures.contains { $0.code == .explanationUnsupportedClaim })
        XCTAssertFalse(report.materialClaims.contains { $0.claimID == proposedClaim.claimID })
        XCTAssertFalse(report.markdown().contains(proposedStatement))
    }

    func testCleanLanguageModelExplanationCanOnlySummarizeValidatedFacts() throws {
        let fixture = try fixture(singleRequiredCapability: .apiServiceLayer)
        let draft = AssessmentReportExplanationDraft(
            narrative: "Validated fact: \(fixture.directClaim.statement)",
            sourceClaimIDs: [fixture.directClaim.claimID]
        )
        let result = compose(
            fixture,
            placements: [compatibilityPlacement(
                fixture.directClaim,
                capability: .apiServiceLayer,
                disposition: .supported
            )],
            explanation: draft
        )
        let report = try XCTUnwrap(result.report)

        XCTAssertEqual(report.composition?.explanation?.nonAuthoritative, true)
        XCTAssertEqual(
            report.composition?.explanation?.sourceClaimIDs,
            [fixture.directClaim.claimID]
        )
        XCTAssertTrue(report.markdown().contains("Non-authoritative Explanation"))

        let inventedNarrative = AssessmentReportExplanationDraft(
            narrative: "The Legacy system has an invented production gateway.",
            sourceClaimIDs: [fixture.directClaim.claimID]
        )
        let rejected = compose(
            fixture,
            placements: [compatibilityPlacement(
                fixture.directClaim,
                capability: .apiServiceLayer,
                disposition: .supported
            )],
            explanation: inventedNarrative
        )
        XCTAssertNil(rejected.report?.composition?.explanation)
        XCTAssertFalse(rejected.report?.markdown().contains("invented production gateway") == true)
        XCTAssertTrue(rejected.validationFailures.contains {
            $0.code == .explanationUnsupportedClaim
        })
    }

    func testEvidenceAppendixIsCompleteAndPreservesEventLineage() throws {
        let fixture = try fixture()
        let report = try XCTUnwrap(
            compose(fixture, placements: partialPlacements(fixture)).report
        )
        let direct = try XCTUnwrap(
            report.evidenceAppendix.first { $0.claimID == fixture.directClaim.claimID }
        )
        let search = try XCTUnwrap(
            report.evidenceAppendix.first { $0.claimID == fixture.searchClaim.claimID }
        )

        XCTAssertEqual(report.evidenceAppendix.count, 2)
        XCTAssertEqual(direct.status, .validated)
        XCTAssertEqual(direct.statement, fixture.directClaim.statement)
        XCTAssertEqual(direct.confidence, .high)
        XCTAssertEqual(direct.evidenceReferences, fixture.directClaim.evidence)
        XCTAssertEqual(direct.sourceExecutionEventIDs, [fixture.directEvidence.toolResultEventID])
        XCTAssertEqual(
            direct.workspaceSnapshotIdentifiers,
            ["workspace-\(fixture.context.workspaceID.uuidString.lowercased())"]
        )
        XCTAssertEqual(search.bindings.first?.toolCallID, fixture.searchEvidence.toolCallID)
        XCTAssertEqual(search.bindings.first?.toolResultEventID, fixture.searchEvidence.toolResultEventID)
        XCTAssertEqual(
            Set(report.executionProvenance?.sourceToolResultEventIDs ?? []),
            Set([fixture.directEvidence.toolResultEventID, fixture.searchEvidence.toolResultEventID])
        )
        XCTAssertEqual(
            report.executionProvenance?.executionEventIDs,
            fixture.events.sorted(by: { $0.sequence < $1.sequence }).map(\.id)
        )
    }

    func testReportReloadUsesExistingExecutionEventPersistence() async throws {
        let fixture = try fixture(singleRequiredCapability: .apiServiceLayer)
        let report = try XCTUnwrap(
            compose(
                fixture,
                placements: [compatibilityPlacement(
                    fixture.directClaim,
                    capability: .apiServiceLayer,
                    disposition: .supported
                )]
            ).report
        )
        let event = ExecutionEvent(
            id: uuid("00000000-0000-0000-0000-000000000090"),
            parentEventID: fixture.directEvidence.toolResultEventID,
            workspaceID: fixture.context.workspaceID,
            taskID: fixture.context.taskID,
            type: .stateUpdated,
            sequence: 90,
            timestamp: Date(timeIntervalSince1970: 1_700_000_090),
            summary: "Phase 3B.3B assessment report composed.",
            payload: try report.persistenceEventPayload()
        )
        let store = InMemoryPersistenceStore()
        try await store.initialize()
        try await store.appendEvent(event)
        let loadedEvents = try await store.loadEvents(
            workspaceID: fixture.context.workspaceID,
            taskID: fixture.context.taskID
        )
        let reloaded = try FDEAIIntegrationAssessmentReport.reload(
            from: XCTUnwrap(loadedEvents.first)
        )

        XCTAssertEqual(reloaded, report)
        XCTAssertEqual(reloaded.reportID, report.reportID)

        var tamperedPayload = event.payload
        tamperedPayload["assessment_report_json"]?.append(" ")
        XCTAssertThrowsError(
            try FDEAIIntegrationAssessmentReport.reload(from: tamperedPayload)
        ) { error in
            XCTAssertEqual(error as? AssessmentReportPersistenceError, .digestMismatch)
        }

        var authorityTamper = report
        authorityTamper.composition?.executiveVerdict = .no
        XCTAssertThrowsError(
            try FDEAIIntegrationAssessmentReport.reload(
                from: authorityTamper.persistenceEventPayload()
            )
        ) { error in
            XCTAssertEqual(error as? AssessmentReportPersistenceError, .identityMismatch)
        }
    }

    private struct Fixture {
        var context: AssessmentReportCompositionContext
        var directEvidence: ReadOnlyInspectionEvidence
        var searchEvidence: ReadOnlyInspectionEvidence
        var evidence: [ReadOnlyInspectionEvidence]
        var ledger: ReadOnlyFinalizationEvidenceLedger
        var events: [ExecutionEvent]
        var directClaim: AssessmentClaim
        var searchClaim: AssessmentClaim
    }

    private func fixture(
        singleRequiredCapability: LegacyArchitectureCapability? = nil
    ) throws -> Fixture {
        let workspaceID = uuid("00000000-0000-0000-0000-000000000001")
        let taskID = uuid("00000000-0000-0000-0000-000000000002")
        let sessionID = uuid("00000000-0000-0000-0000-000000000003")
        let readCalledID = uuid("00000000-0000-0000-0000-000000000010")
        let readResultID = uuid("00000000-0000-0000-0000-000000000011")
        let searchCalledID = uuid("00000000-0000-0000-0000-000000000020")
        let searchResultID = uuid("00000000-0000-0000-0000-000000000021")
        let directOutput = #"{"name":"legacy","dependencies":{"express":"1.0.0"}}"#
        let directEvidence = ReadOnlyInspectionEvidence(
            toolCallID: "read-manifest",
            toolName: "engineering.read_file",
            workspaceID: workspaceID,
            workspaceIdentity: "legacy",
            targetPath: "package.json",
            output: directOutput,
            toolCalledEventID: readCalledID,
            toolResultEventID: readResultID
        )
        let searchEvidence = ReadOnlyInspectionEvidence(
            toolCallID: "search-auth",
            toolName: "engineering.search_files",
            workspaceID: workspaceID,
            workspaceIdentity: "legacy",
            targetPath: ".",
            output: "No files found",
            toolCalledEventID: searchCalledID,
            toolResultEventID: searchResultID,
            query: "authentication"
        )
        let evidence = [directEvidence, searchEvidence]
        let requirements = try XCTUnwrap(
            ReadOnlyEvidenceRequirements(
                planRequirementIDs: [
                    ReadOnlyEvidenceRequirementKind.projectManifest.rawValue,
                    ReadOnlyEvidenceRequirementKind.assessmentAuthentication.rawValue
                ]
            )
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: evidence
        )
        let snapshot = "workspace-\(workspaceID.uuidString.lowercased())"
        let directReference = AssessmentEvidenceReference(
            source: .extractedConfiguration,
            workspaceIdentity: "legacy",
            path: "package.json",
            fact: "The inspected manifest declares the express dependency.",
            claimLevel: .configurationConfirmed,
            observationStatus: .directlyRead,
            sourceComponent: "package.json",
            safeEvidenceSummary: "package.json declares manifest name legacy and dependency express.",
            lineRange: "1-1",
            workspaceSnapshotIdentifier: snapshot,
            relatedToolEventID: readResultID
        )
        let searchReference = AssessmentEvidenceReference(
            source: .staticSearch,
            workspaceIdentity: "legacy",
            path: ".",
            fact: "The bounded authentication search returned no matches.",
            claimLevel: .discovered,
            observationStatus: .discovered,
            sourceComponent: "workspace-root",
            safeEvidenceSummary: "A bounded static search returned no authentication file matches.",
            workspaceSnapshotIdentifier: snapshot,
            relatedToolEventID: searchResultID
        )
        let directClaim = AssessmentClaim(
            claimID: "claim-manifest-service-seam",
            statement: "The directly inspected package.json declares the express dependency.",
            evidence: [directReference],
            confidence: .high,
            unknowns: ["Build, test, and runtime behavior remain unverified."]
        )
        let searchClaim = AssessmentClaim(
            claimID: "claim-auth-search-unknown",
            statement: "The bounded authentication search returned no matches in the inspected scope.",
            evidence: [searchReference],
            confidence: .medium,
            unknowns: ["Authentication files outside the inspected scope remain unknown."]
        )
        let requiredCapabilities: [LegacyArchitectureCapability]
        if let singleRequiredCapability {
            requiredCapabilities = [singleRequiredCapability]
        } else {
            requiredCapabilities = [.apiServiceLayer, .authenticationBoundary]
        }
        let profile = AgentCapabilityProfile(
            kind: .unspecified,
            requiredCapabilities: requiredCapabilities.map {
                AgentCapabilityRequirement(
                    capability: $0,
                    required: true,
                    critical: true,
                    rationale: "Required by the test assessment scope."
                )
            },
            proposesWriteAccess: false
        )
        let context = AssessmentReportCompositionContext(
            workspaceID: workspaceID,
            taskID: taskID,
            sessionID: sessionID,
            requestedCapability: profile,
            scopeDescription: "Validated read-only Legacy workspace evidence."
        )
        let events = [
            toolCalledEvent(
                id: readCalledID,
                workspaceID: workspaceID,
                taskID: taskID,
                sequence: 1,
                toolCallID: directEvidence.toolCallID
            ),
            toolResultEvent(
                id: readResultID,
                parentID: readCalledID,
                workspaceID: workspaceID,
                taskID: taskID,
                sequence: 2,
                toolCallID: directEvidence.toolCallID
            ),
            toolCalledEvent(
                id: searchCalledID,
                workspaceID: workspaceID,
                taskID: taskID,
                sequence: 3,
                toolCallID: searchEvidence.toolCallID
            ),
            toolResultEvent(
                id: searchResultID,
                parentID: searchCalledID,
                workspaceID: workspaceID,
                taskID: taskID,
                sequence: 4,
                toolCallID: searchEvidence.toolCallID
            )
        ]
        return Fixture(
            context: context,
            directEvidence: directEvidence,
            searchEvidence: searchEvidence,
            evidence: evidence,
            ledger: ledger,
            events: events,
            directClaim: directClaim,
            searchClaim: searchClaim
        )
    }

    private func partialPlacements(
        _ fixture: Fixture
    ) -> [AssessmentReportClaimPlacement] {
        [
            AssessmentReportClaimPlacement(
                claim: fixture.directClaim,
                section: .executiveSummary,
                disposition: .supported
            ),
            AssessmentReportClaimPlacement(
                claim: fixture.directClaim,
                section: .observedLegacyArchitecture,
                disposition: .supported
            ),
            AssessmentReportClaimPlacement(
                claim: fixture.directClaim,
                section: .candidateIntegrationSeam,
                disposition: .advisory,
                title: "Express service boundary",
                integrationPath: ["Agent", "Permission-aware adapter", "Legacy service"],
                architectureComponents: ["Permission-aware adapter"]
            ),
            compatibilityPlacement(
                fixture.directClaim,
                capability: .apiServiceLayer,
                disposition: .supported
            ),
            compatibilityPlacement(
                fixture.searchClaim,
                capability: .authenticationBoundary,
                disposition: .unknown
            ),
            AssessmentReportClaimPlacement(
                claim: fixture.searchClaim,
                section: .securityAndAuthorization,
                disposition: .unknown,
                riskLevel: .medium,
                riskDomain: .permission
            ),
            AssessmentReportClaimPlacement(
                claim: fixture.searchClaim,
                section: .unknown,
                disposition: .unknown
            ),
            AssessmentReportClaimPlacement(
                claim: fixture.directClaim,
                section: .recommendation,
                disposition: .advisory,
                integrationPath: ["Agent", "Permission-aware adapter", "Legacy service"],
                architectureComponents: ["Permission-aware adapter"]
            )
        ]
    }

    private func compatibilityPlacement(
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

    private func compose(
        _ fixture: Fixture,
        placements: [AssessmentReportClaimPlacement],
        explanation: AssessmentReportExplanationDraft? = nil
    ) -> AssessmentReportCompositionResult {
        AssessmentReportComposer.compose(
            context: fixture.context,
            claims: placements,
            evidenceLedger: fixture.ledger,
            evidence: fixture.evidence,
            executionEvents: fixture.events,
            explanation: explanation
        )
    }

    private func toolCalledEvent(
        id: UUID,
        workspaceID: UUID,
        taskID: UUID,
        sequence: Int64,
        toolCallID: String
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: id,
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: .toolCalled,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
            summary: "Read-only tool called.",
            payload: [
                "lifecycle_event": ExecutionPlanLifecycleEvent.toolCalled.rawValue,
                "tool_call_id": toolCallID
            ]
        )
    }

    private func toolResultEvent(
        id: UUID,
        parentID: UUID,
        workspaceID: UUID,
        taskID: UUID,
        sequence: Int64,
        toolCallID: String
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: id,
            parentEventID: parentID,
            workspaceID: workspaceID,
            taskID: taskID,
            type: .stepExecuted,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(sequence)),
            summary: "Read-only tool result recorded.",
            payload: [
                "lifecycle_event": ExecutionPlanLifecycleEvent.toolResult.rawValue,
                "tool_call_id": toolCallID,
                "success": "true",
                "evidence_eligible": "true"
            ]
        )
    }

    private func uuid(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
