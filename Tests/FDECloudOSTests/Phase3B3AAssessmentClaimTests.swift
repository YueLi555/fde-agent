import XCTest
@testable import FDECloudOS

final class Phase3B3AAssessmentClaimTests: XCTestCase {
    func testAssessmentClaimRoundTripsAndBindsToExactSuccessfulEvidence() throws {
        let fixture = try directEvidenceFixture()
        let claim = groundedClaim(reference: fixture.reference)

        let encoded = try JSONEncoder().encode(claim)
        let decoded = try JSONDecoder().decode(AssessmentClaim.self, from: encoded)
        let validation = AssessmentClaimValidator.validate(
            decoded,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )
        let binding = try XCTUnwrap(validation.bindings.first)

        XCTAssertEqual(decoded, claim)
        XCTAssertTrue(validation.accepted, validation.issues.map(\.detail).joined(separator: " | "))
        XCTAssertEqual(validation.bindings.count, 1)
        XCTAssertEqual(binding.claimID, claim.claimID)
        XCTAssertEqual(binding.evidenceReferenceID, fixture.reference.id)
        XCTAssertEqual(binding.toolCallID, fixture.evidence.toolCallID)
        XCTAssertEqual(binding.toolResultEventID, fixture.evidence.toolResultEventID)
        XCTAssertEqual(binding.workspaceID, fixture.evidence.workspaceID)
        XCTAssertEqual(binding.workspaceIdentity, "legacy")
        XCTAssertEqual(binding.relativePath, "package.json")
        XCTAssertEqual(binding.claimLevel, .configurationConfirmed)
        XCTAssertEqual(binding.observationStatus, .directlyRead)
        XCTAssertEqual(binding.sourceOutputSHA256.count, 64)
        XCTAssertTrue(binding.extractedFactKinds.contains("manifest_name"))
        XCTAssertTrue(binding.extractedFactKinds.contains("dependency_names"))
    }

    func testBindingRejectsUnknownEventWorkspaceAndPath() throws {
        let fixture = try directEvidenceFixture()

        var unknownEvent = fixture.reference
        unknownEvent.relatedToolEventID = UUID()
        XCTAssertEqual(
            failures(for: groundedClaim(reference: unknownEvent), fixture: fixture),
            [.toolResultEventNotFound, .highConfidenceRequiresDirectEvidence]
        )

        var wrongWorkspace = fixture.reference
        wrongWorkspace.workspaceIdentity = "agent"
        XCTAssertEqual(
            failures(for: groundedClaim(reference: wrongWorkspace), fixture: fixture),
            [.workspaceBindingMismatch, .highConfidenceRequiresDirectEvidence]
        )

        var missingPath = fixture.reference
        missingPath.path = "Sources/Uninspected.swift"
        XCTAssertEqual(
            failures(for: groundedClaim(reference: missingPath), fixture: fixture),
            [.evidencePathNotInLedger, .highConfidenceRequiresDirectEvidence]
        )
    }

    func testBindingRejectsMaturityAndOptionalProvenanceTampering() throws {
        let fixture = try directEvidenceFixture()

        var escalated = fixture.reference
        escalated.claimLevel = .sourceBehaviorConfirmed
        XCTAssertEqual(
            failures(for: groundedClaim(reference: escalated), fixture: fixture),
            [.unsupportedClaimLevel, .highConfidenceRequiresDirectEvidence]
        )

        var wrongHash = fixture.reference
        wrongHash.fileHash = String(repeating: "0", count: 64)
        XCTAssertEqual(
            failures(for: groundedClaim(reference: wrongHash), fixture: fixture),
            [.fileHashMismatch, .highConfidenceRequiresDirectEvidence]
        )

        var wrongSnapshot = fixture.reference
        wrongSnapshot.workspaceSnapshotIdentifier = "workspace-incorrect"
        XCTAssertEqual(
            failures(for: groundedClaim(reference: wrongSnapshot), fixture: fixture),
            [.workspaceSnapshotMismatch, .highConfidenceRequiresDirectEvidence]
        )

        var wrongLines = fixture.reference
        wrongLines.lineRange = "1-99"
        XCTAssertEqual(
            failures(for: groundedClaim(reference: wrongLines), fixture: fixture),
            [.lineRangeMismatch, .highConfidenceRequiresDirectEvidence]
        )

        var wrongSource = fixture.reference
        wrongSource.source = .evidenceLedger
        XCTAssertEqual(
            failures(for: groundedClaim(reference: wrongSource), fixture: fixture),
            [.evidenceSourceMismatch, .highConfidenceRequiresDirectEvidence]
        )
    }

    func testHighConfidenceCannotBeGroundedOnlyByDiscovery() throws {
        let fixture = try discoveryEvidenceFixture()
        let highConfidence = AssessmentClaim(
            claimID: "claim-auth-search",
            statement: "The bounded authentication search returned no matches in the inspected scope.",
            evidence: [fixture.reference],
            confidence: .high,
            unknowns: ["Files outside the inspected scope remain unknown."]
        )
        let mediumConfidence = AssessmentClaim(
            claimID: "claim-auth-search-medium",
            statement: highConfidence.statement,
            evidence: highConfidence.evidence,
            confidence: .medium,
            unknowns: highConfidence.unknowns
        )

        let highValidation = AssessmentClaimValidator.validate(
            highConfidence,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )
        let mediumValidation = AssessmentClaimValidator.validate(
            mediumConfidence,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )

        XCTAssertEqual(highValidation.bindings.count, 1)
        XCTAssertEqual(highValidation.failures, [.highConfidenceRequiresDirectEvidence])
        XCTAssertFalse(highValidation.accepted)
        XCTAssertTrue(mediumValidation.accepted, mediumValidation.issues.map(\.detail).joined(separator: " | "))
        XCTAssertEqual(mediumValidation.bindings.first?.observationStatus, .discovered)
    }

    func testReferencedButUnreadPathBindsWithoutBecomingDirectEvidence() throws {
        let workspaceID = UUID()
        let eventID = UUID()
        let evidence = ReadOnlyInspectionEvidence(
            toolCallID: "read-entry",
            toolName: "engineering.read_file",
            workspaceID: workspaceID,
            workspaceIdentity: "legacy",
            targetPath: "server/src/index.ts",
            output: "import app from './app';\napp.listen(3000);",
            toolCalledEventID: UUID(),
            toolResultEventID: eventID
        )
        let requirements = try XCTUnwrap(
            ReadOnlyEvidenceRequirements(
                planRequirementIDs: [ReadOnlyEvidenceRequirementKind.backendApplicationAssembly.rawValue]
            )
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: [evidence]
        )
        let reference = AssessmentEvidenceReference(
            source: .inspectedFile,
            workspaceIdentity: "legacy",
            path: "server/src/app.ts",
            fact: "The inspected entry point references server/src/app.ts.",
            claimLevel: .referencedButNotRead,
            observationStatus: .referenced,
            sourceComponent: "server",
            safeEvidenceSummary: "server/src/app.ts is referenced but was not read.",
            relatedToolEventID: eventID
        )
        let claim = AssessmentClaim(
            claimID: "claim-app-referenced",
            statement: "server/src/app.ts is referenced by the inspected entry point but was not read.",
            evidence: [reference],
            confidence: .medium,
            unknowns: ["The application assembly contents remain unknown."]
        )

        let validation = AssessmentClaimValidator.validate(
            claim,
            evidenceLedger: ledger,
            evidence: [evidence]
        )

        XCTAssertTrue(validation.accepted, validation.issues.map(\.detail).joined(separator: " | "))
        XCTAssertEqual(validation.bindings.first?.relativePath, "server/src/app.ts")
        XCTAssertEqual(validation.bindings.first?.claimLevel, .referencedButNotRead)
        XCTAssertEqual(validation.bindings.first?.observationStatus, .referenced)
    }

    func testUserIntentAndEmptyEvidenceCannotGroundAssessmentClaims() throws {
        let fixture = try directEvidenceFixture()
        let intentOnly = AssessmentClaim(
            claimID: "claim-user-intent",
            statement: "The user requested a production-ready service.",
            evidence: [.userIntent("The user requested a production-ready service.")],
            confidence: .medium,
            unknowns: ["No workspace observation supports the requested state."]
        )
        let noEvidence = AssessmentClaim(
            claimID: "claim-no-evidence",
            statement: "An unobserved service boundary exists.",
            evidence: [],
            confidence: .low,
            unknowns: ["No supporting evidence was collected."]
        )

        let intentValidation = AssessmentClaimValidator.validate(
            intentOnly,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )
        let emptyValidation = AssessmentClaimValidator.validate(
            noEvidence,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )

        XCTAssertTrue(intentValidation.failures.contains(.userIntentIsNotObservedEvidence))
        XCTAssertTrue(intentValidation.failures.contains(.unsupportedExecutionAssertion))
        XCTAssertTrue(intentValidation.bindings.isEmpty)
        XCTAssertEqual(emptyValidation.failures, [.missingEvidence])
        XCTAssertTrue(emptyValidation.bindings.isEmpty)
    }

    func testStaticEvidenceCannotClaimExecutionOrVerification() throws {
        let fixture = try directEvidenceFixture()
        let executionClaim = AssessmentClaim(
            claimID: "claim-tests-passed",
            statement: "The inspected application tests passed and it is production-ready.",
            evidence: [fixture.reference],
            confidence: .high,
            unknowns: [],
            verificationStatus: AssessmentVerificationStatus(
                runtime: .runtimeVerified,
                build: .buildPassed,
                test: .testPassed
            )
        )
        let honestStaticClaim = AssessmentClaim(
            claimID: "claim-static-only",
            statement: "The manifest was directly read; build was not executed and runtime was not verified.",
            evidence: [fixture.reference],
            confidence: .high,
            unknowns: ["Runtime behavior remains unverified."]
        )

        let rejected = AssessmentClaimValidator.validate(
            executionClaim,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )
        let accepted = AssessmentClaimValidator.validate(
            honestStaticClaim,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )

        XCTAssertTrue(rejected.failures.contains(.unsupportedExecutionAssertion))
        XCTAssertTrue(rejected.failures.contains(.unsupportedVerificationStatus))
        XCTAssertEqual(rejected.bindings.count, 1, "A valid evidence link must not legitimize an invalid claim.")
        XCTAssertTrue(accepted.accepted, accepted.issues.map(\.detail).joined(separator: " | "))
    }

    func testClaimSetRejectsDuplicateClaimsReferencesAndUnknowns() throws {
        let fixture = try directEvidenceFixture()
        var duplicatedReference = groundedClaim(reference: fixture.reference)
        duplicatedReference.evidence.append(fixture.reference)
        duplicatedReference.unknowns = ["Runtime remains unknown.", "runtime remains unknown."]
        let duplicateClaimID = groundedClaim(reference: fixture.reference)

        let validation = AssessmentClaimValidator.validate(
            [duplicatedReference, duplicateClaimID],
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        )

        XCTAssertTrue(validation.failures.contains(.duplicateClaimID))
        XCTAssertTrue(validation.failures.contains(.duplicateEvidenceReference))
        XCTAssertTrue(validation.failures.contains(.duplicateUnknown))
        XCTAssertEqual(validation.bindings.count, 1, "Repeated citations must not create repeated bindings.")
    }

    func testLedgerAloneCannotSubstituteForTheBoundEvidenceCollection() throws {
        let fixture = try directEvidenceFixture()
        let validation = AssessmentClaimValidator.validate(
            groundedClaim(reference: fixture.reference),
            evidenceLedger: fixture.ledger,
            evidence: []
        )

        XCTAssertTrue(validation.failures.contains(.toolResultEventNotFound))
        XCTAssertTrue(validation.bindings.isEmpty)
        XCTAssertFalse(validation.accepted)
    }

    private struct EvidenceFixture {
        var evidence: ReadOnlyInspectionEvidence
        var ledger: ReadOnlyFinalizationEvidenceLedger
        var reference: AssessmentEvidenceReference
    }

    private func directEvidenceFixture() throws -> EvidenceFixture {
        let workspaceID = UUID()
        let eventID = UUID()
        let output = #"{"name":"fixture","dependencies":{"express":"1.0.0"}}"#
        let evidence = ReadOnlyInspectionEvidence(
            toolCallID: "read-manifest",
            toolName: "engineering.read_file",
            workspaceID: workspaceID,
            workspaceIdentity: "legacy",
            targetPath: "package.json",
            output: output,
            toolCalledEventID: UUID(),
            toolResultEventID: eventID
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
            safeEvidenceSummary: "package.json declares manifest name fixture and dependency express.",
            lineRange: "1-1",
            workspaceSnapshotIdentifier: "workspace-\(workspaceID.uuidString.lowercased())",
            relatedToolEventID: eventID
        )
        return EvidenceFixture(evidence: evidence, ledger: ledger, reference: reference)
    }

    private func discoveryEvidenceFixture() throws -> EvidenceFixture {
        let workspaceID = UUID()
        let eventID = UUID()
        let evidence = ReadOnlyInspectionEvidence(
            toolCallID: "search-auth",
            toolName: "engineering.search_files",
            workspaceID: workspaceID,
            workspaceIdentity: "legacy",
            targetPath: ".",
            output: "No files found",
            toolCalledEventID: UUID(),
            toolResultEventID: eventID,
            query: "authentication"
        )
        let requirements = try XCTUnwrap(
            ReadOnlyEvidenceRequirements(
                planRequirementIDs: [ReadOnlyEvidenceRequirementKind.assessmentAuthentication.rawValue]
            )
        )
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: [evidence]
        )
        let reference = AssessmentEvidenceReference(
            source: .staticSearch,
            workspaceIdentity: "legacy",
            path: ".",
            fact: "The bounded authentication search returned no matches.",
            claimLevel: .discovered,
            observationStatus: .discovered,
            sourceComponent: "workspace-root",
            safeEvidenceSummary: "A bounded static search returned no authentication file matches.",
            workspaceSnapshotIdentifier: "workspace-\(workspaceID.uuidString.lowercased())",
            relatedToolEventID: eventID
        )
        return EvidenceFixture(evidence: evidence, ledger: ledger, reference: reference)
    }

    private func groundedClaim(reference: AssessmentEvidenceReference) -> AssessmentClaim {
        AssessmentClaim(
            claimID: "claim-manifest-express",
            statement: "The directly inspected package.json declares the express dependency.",
            evidence: [reference],
            confidence: .high,
            unknowns: ["Build, test, and runtime behavior remain unverified."]
        )
    }

    private func failures(
        for claim: AssessmentClaim,
        fixture: EvidenceFixture
    ) -> [AssessmentClaimValidationFailure] {
        AssessmentClaimValidator.validate(
            claim,
            evidenceLedger: fixture.ledger,
            evidence: [fixture.evidence]
        ).failures
    }
}
