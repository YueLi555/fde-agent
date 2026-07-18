import XCTest
@testable import FDECloudOS

final class GeneratedTestArtifactTests: XCTestCase {
    func testTestableLegacyGroundsFrameworkLocationAndGeneratesBoundVirtualSource() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let originalBefore = try fixture.originalLegacySnapshot()
        let plan = try fixture.prepareGeneratedTestPlan()
        let sandboxBefore = try fixture.sandboxSnapshot()
        let artifact = try fixture.generateArtifact(from: plan)
        let revision = try XCTUnwrap(artifact.currentRevision)
        let file = try XCTUnwrap(revision.virtualFiles.first)

        XCTAssertEqual(plan.expectedFramework?.frameworkID, "vitest")
        XCTAssertEqual(plan.expectedFramework?.language, "typescript")
        XCTAssertEqual(plan.confirmedTestLocation, "tests")
        XCTAssertTrue(plan.frameworkEvidence.contains {
            $0.relativePath == "package.json" && $0.kind == .testScript
        })
        XCTAssertTrue(plan.frameworkEvidence.contains {
            $0.relativePath == "vitest.config.ts" && $0.kind == .frameworkConfiguration
        })
        XCTAssertTrue(plan.frameworkEvidence.contains {
            $0.relativePath == "tests/orders.test.ts" && $0.kind == .testImport
        })
        XCTAssertTrue(plan.testLocationEvidence.contains {
            $0.relativePath == "tests/orders.test.ts"
        })

        XCTAssertEqual(revision.lifecycleStatus, .testArtifactReviewReady)
        XCTAssertEqual(revision.reviewState, .awaitingReview)
        XCTAssertEqual(revision.virtualFiles.count, 1)
        XCTAssertEqual(file.operation, .create)
        XCTAssertEqual(file.language, "typescript")
        XCTAssertEqual(file.framework.frameworkID, "vitest")
        XCTAssertFalse(file.sourceBytes.isEmpty)
        XCTAssertEqual(CandidatePatchArtifactAuthority.sha256(file.sourceBytes), file.sourceSHA256)
        XCTAssertEqual(
            file.sourceText.split(separator: "\n", omittingEmptySubsequences: false).count,
            file.lineCount
        )
        XCTAssertEqual(file.writtenStatus, GeneratedTestVirtualFile.notWritten)
        XCTAssertEqual(file.compiledStatus, GeneratedTestVirtualFile.notCompiled)
        XCTAssertEqual(file.executedStatus, GeneratedTestVirtualFile.notExecuted)
        XCTAssertEqual(file.behaviorVerificationStatus, GeneratedTestVirtualFile.behaviorNotVerified)
        XCTAssertFalse(file.scenarioIDs.isEmpty)
        XCTAssertFalse(file.validationPlanItemIDs.isEmpty)
        XCTAssertFalse(file.blockerClaimIDs.isEmpty)
        XCTAssertFalse(file.evidenceClaimIDs.isEmpty)
        XCTAssertTrue(file.evidencePaths.contains("src/orderReadAdapter.ts"))
        XCTAssertTrue(revision.evidenceBindings.contains {
            $0.kind == .affectedSource && $0.relativePath == "src/orderReadAdapter.ts"
        })
        XCTAssertTrue(file.generationProvenance.contains {
            $0.contains("exact Candidate Patch postimage")
        })
        XCTAssertNoThrow(try GeneratedTestSourceGroundingValidator.validateVirtualPath(
            file.proposedRelativePath,
            groundedTestLocation: revision.groundedTestLocation
        ))

        let scenarioText = revision.scenarioBindings
            .map { ($0.title + " " + $0.behaviorUnderTest).lowercased() }
            .joined(separator: " ")
        XCTAssertTrue(scenarioText.contains("record-level"))
        XCTAssertTrue(scenarioText.contains("customerid"))
        XCTAssertTrue(scenarioText.contains("allowlist"))
        XCTAssertTrue(scenarioText.contains("read-only"))
        XCTAssertTrue(scenarioText.contains("audit"))
        XCTAssertTrue(revision.scenarioBindings.allSatisfy {
            !$0.virtualFileIDs.isEmpty
                && !$0.validationPlanItemIDs.isEmpty
                && !$0.blockerClaimIDs.isEmpty
                && !$0.evidenceClaimIDs.isEmpty
                && !$0.evidencePaths.isEmpty
        })
        XCTAssertTrue(file.sourceText.contains("expect(() => lookup"))
        XCTAssertTrue(file.sourceText.contains("Object.keys(result ?? {}).sort()"))
        XCTAssertTrue(file.sourceText.contains("customerID"))
        XCTAssertTrue(file.sourceText.contains("const first = lookup"))
        XCTAssertTrue(file.sourceText.contains("toHaveBeenCalledWith"))
        XCTAssertTrue(file.sourceText.contains("Object.keys(candidateModule).sort()"))
        XCTAssertEqual(
            GeneratedTestArtifactDigest.compute(revision, sourceBinding: artifact.sourceBinding),
            revision.digest
        )
        XCTAssertEqual(try fixture.originalLegacySnapshot(), originalBefore)
        XCTAssertEqual(try fixture.sandboxSnapshot(), sandboxBefore)
        XCTAssertFalse(try fixture.virtualFileExists(file))
        XCTAssertFalse(artifact.phase2D3Available)
    }

    func testExactGeneratedTestPlanAndSessionBindingsFailClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.prepareGeneratedTestPlan()
        let service = GeneratedTestArtifactService(lifecycle: fixture.lifecycle)
        let valid = fixture.generationContext(for: plan)

        var contexts: [GeneratedTestArtifactGenerationContext] = []
        var wrongPlan = valid
        wrongPlan.generatedTestPlanID = UUID()
        contexts.append(wrongPlan)
        var wrongRevision = valid
        wrongRevision.generatedTestPlanRevision += 1
        contexts.append(wrongRevision)
        var wrongDigest = valid
        wrongDigest.generatedTestPlanSHA256 = String(repeating: "0", count: 64)
        contexts.append(wrongDigest)
        var wrongSourceBinding = valid
        wrongSourceBinding.generatedTestSourceBindingSHA256 = String(repeating: "1", count: 64)
        contexts.append(wrongSourceBinding)
        var wrongUserSession = valid
        wrongUserSession.authenticatedLocalSessionID = UUID()
        contexts.append(wrongUserSession)
        var wrongAppSession = valid
        wrongAppSession.appSessionID = UUID()
        contexts.append(wrongAppSession)
        var wrongCandidatePatch = valid
        wrongCandidatePatch.candidatePatchID = CandidatePatchID()
        contexts.append(wrongCandidatePatch)
        var wrongCandidatePatchPlan = valid
        wrongCandidatePatchPlan.candidatePatchPlanID = UUID()
        contexts.append(wrongCandidatePatchPlan)
        var wrongSandbox = valid
        wrongSandbox.sandboxID = SandboxID()
        contexts.append(wrongSandbox)
        var wrongSnapshot = valid
        wrongSnapshot.sourceSnapshotID = "stale-source-snapshot"
        contexts.append(wrongSnapshot)

        for context in contexts {
            assertGeneratedFailure(.generatedTestPlanMismatch) {
                _ = try service.generate(.init(context: context))
            }
        }
    }

    func testDistinctPlanActionsRemainExactAndRepeatedGenerationIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let legacyBefore = try fixture.originalLegacySnapshot()
        let sandboxBefore = try fixture.sandboxSnapshot()
        let planA = try fixture.prepareGeneratedTestPlan()
        let planB = try fixture.prepareGeneratedTestPlan(
            planningTaskID: UUID(uuidString: "00000000-0000-0000-0000-0000000002B0")!
        )
        let contextA = fixture.generationContext(for: planA)
        let contextB = fixture.generationContext(for: planB)
        let service = GeneratedTestArtifactService(lifecycle: fixture.lifecycle)

        XCTAssertNotEqual(planA.planID, planB.planID)
        XCTAssertNotEqual(planA.planSHA256, planB.planSHA256)
        XCTAssertNotEqual(
            planA.sourceBinding.generatedTestPlanningTaskID,
            planB.sourceBinding.generatedTestPlanningTaskID
        )
        XCTAssertEqual(contextA.generatedTestPlanID, planA.planID)
        XCTAssertEqual(contextB.generatedTestPlanID, planB.planID)

        let generatedB = try service.generate(.init(context: contextB))
        let artifactB = try XCTUnwrap(generatedB.artifact)
        let generatedA = try service.generate(.init(context: contextA))
        let artifactA = try XCTUnwrap(generatedA.artifact)
        XCTAssertNotEqual(artifactA.artifactID, artifactB.artifactID)
        XCTAssertEqual(artifactA.sourceBinding.generatedTestPlanID, planA.planID)
        XCTAssertEqual(artifactA.sourceBinding.generatedTestPlanSHA256, planA.planSHA256)
        XCTAssertEqual(artifactB.sourceBinding.generatedTestPlanID, planB.planID)
        XCTAssertEqual(artifactB.sourceBinding.generatedTestPlanSHA256, planB.planSHA256)

        let repeatedA = try XCTUnwrap(service.generate(.init(context: contextA)).artifact)
        let repeatedB = try XCTUnwrap(service.generate(.init(context: contextB)).artifact)
        XCTAssertEqual(repeatedA.artifactID, artifactA.artifactID)
        XCTAssertEqual(repeatedA.sourceBinding, artifactA.sourceBinding)
        XCTAssertEqual(repeatedA.revisions.map(\.digest), artifactA.revisions.map(\.digest))
        XCTAssertEqual(repeatedB.artifactID, artifactB.artifactID)
        XCTAssertEqual(repeatedB.sourceBinding, artifactB.sourceBinding)
        XCTAssertEqual(repeatedB.revisions.map(\.digest), artifactB.revisions.map(\.digest))
        XCTAssertEqual(
            try GeneratedTestArtifactStore(storageRoot: fixture.lifecycle.storageRoot)
                .loadAll(workspaceID: fixture.workspaceID).count,
            2
        )

        let rejectedA = try service.reject(fixture.reviewContext(for: artifactA))
        XCTAssertEqual(rejectedA.reviewState(for: 1), .rejected)
        let repeatedRejectedA = try XCTUnwrap(service.generate(.init(context: contextA)).artifact)
        XCTAssertEqual(repeatedRejectedA.artifactID, rejectedA.artifactID)
        XCTAssertEqual(repeatedRejectedA.sourceBinding, rejectedA.sourceBinding)
        XCTAssertEqual(repeatedRejectedA.revisions.map(\.digest), rejectedA.revisions.map(\.digest))
        XCTAssertEqual(repeatedRejectedA.reviewDecisions.map(\.decisionID), rejectedA.reviewDecisions.map(\.decisionID))
        XCTAssertEqual(repeatedRejectedA.reviewState(for: 1), .rejected)
        XCTAssertEqual(try fixture.originalLegacySnapshot(), legacyBefore)
        XCTAssertEqual(try fixture.sandboxSnapshot(), sandboxBefore)
        assertZeroAuthorityCounters(service.safetyCounters(for: repeatedRejectedA), expectsMetadata: true)
        XCTAssertFalse(repeatedRejectedA.phase2D3Available)
    }

    func testCandidatePatchAndSandboxMismatchFailClosed() throws {
        for mutation in 0..<2 {
            let fixture = try makeFixture()
            defer { fixture.cleanup() }
            var plan = try fixture.prepareGeneratedTestPlan()
            if mutation == 0 {
                plan.sourceBinding.patchID = CandidatePatchID()
            } else {
                plan.sourceBinding.sandboxID = SandboxID()
            }
            plan.planSHA256 = GeneratedTestPlanDigest.compute(plan)
            try fixture.overwritePersistedPlan(plan)

            assertGeneratedFailure(.sourceBindingMismatch) {
                _ = try GeneratedTestArtifactService(lifecycle: fixture.lifecycle).generate(
                    .init(context: fixture.generationContext(for: plan))
                )
            }
        }
    }

    func testChangedCandidatePostimageFailsClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.prepareGeneratedTestPlan()
        try Data("export function drifted(): void {}\n".utf8)
            .write(to: try fixture.sandboxURL().appendingPathComponent("src/orderReadAdapter.ts"))

        assertGeneratedFailure(.candidatePatchPostimageMismatch) {
            _ = try GeneratedTestArtifactService(lifecycle: fixture.lifecycle).generate(
                .init(context: fixture.generationContext(for: plan))
            )
        }
    }

    func testArtifactDigestSourceTamperingAndRestartValidationFailClosed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.prepareGeneratedTestPlan()
        let artifact = try fixture.generateArtifact(from: plan)
        let store = GeneratedTestArtifactStore(storageRoot: fixture.lifecycle.storageRoot)
        let restored = try store.load(
            workspaceID: fixture.workspaceID,
            planningTaskID: fixture.planningTaskID,
            artifactID: artifact.artifactID
        )
        XCTAssertEqual(restored, artifact)
        XCTAssertEqual(restored.currentRevision?.virtualFiles.first?.sourceText,
                       artifact.currentRevision?.virtualFiles.first?.sourceText)

        var digestTamper = artifact
        digestTamper.revisions[0].digest.sha256 = String(repeating: "f", count: 64)
        assertGeneratedFailure(.artifactDigestMismatch) {
            try store.save(digestTamper)
        }

        var sourceTamper = artifact
        sourceTamper.revisions[0].virtualFiles[0].sourceBytes = Data("tampered source\n".utf8)
        assertGeneratedFailure(.artifactDigestMismatch) {
            try store.save(sourceTamper)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(sourceTamper).write(to: fixture.artifactURL(artifact), options: [.atomic])
        assertGeneratedFailure(.artifactDigestMismatch) {
            _ = try store.load(
                workspaceID: fixture.workspaceID,
                planningTaskID: fixture.planningTaskID,
                artifactID: artifact.artifactID
            )
        }
    }

    func testVirtualPathAndGeneratedSourceValidationFailClosed() throws {
        XCTAssertNoThrow(try GeneratedTestSourceGroundingValidator.validateVirtualPath(
            "tests/orders.generated.test.ts",
            groundedTestLocation: "tests"
        ))
        for path in ["/tmp/orders.test.ts", "../orders.test.ts", "tests/../orders.test.ts"] {
            assertGeneratedFailure(.virtualFilePathInvalid) {
                try GeneratedTestSourceGroundingValidator.validateVirtualPath(
                    path,
                    groundedTestLocation: "tests"
                )
            }
        }

        let valid = """
        import { describe, expect, it } from "vitest";
        import { listAuthorizedCustomerOrders } from "../src/orderReadAdapter";
        describe("orders", () => { it("exists", () => { expect(listAuthorizedCustomerOrders).toBeDefined(); }); });
        """
        XCTAssertNoThrow(try GeneratedTestSourceGroundingValidator.validateSource(
            valid,
            proposedPath: "tests/orders.generated.test.ts",
            frameworkBindings: ["describe", "expect", "it"],
            groundedSourcePaths: ["src/orderReadAdapter.ts"],
            groundedSymbols: ["listAuthorizedCustomerOrders"]
        ))

        let unsupportedImport = valid.replacingOccurrences(
            of: "../src/orderReadAdapter",
            with: "invented-package"
        )
        assertGeneratedFailure(.unsupportedImport) {
            try GeneratedTestSourceGroundingValidator.validateSource(
                unsupportedImport,
                proposedPath: "tests/orders.generated.test.ts",
                frameworkBindings: ["describe", "expect", "it"],
                groundedSourcePaths: ["src/orderReadAdapter.ts"],
                groundedSymbols: ["listAuthorizedCustomerOrders"]
            )
        }

        assertGeneratedFailure(.ungroundedHelperOrAPI) {
            try GeneratedTestSourceGroundingValidator.validateSource(
                valid + "\nfetch(\"https://example.invalid\");",
                proposedPath: "tests/orders.generated.test.ts",
                frameworkBindings: ["describe", "expect", "it"],
                groundedSourcePaths: ["src/orderReadAdapter.ts"],
                groundedSymbols: ["listAuthorizedCustomerOrders"]
            )
        }
    }

    func testRequestChangesCreatesRevisionTwoAndPreservesRevisionOne() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.prepareGeneratedTestPlan()
        let original = try fixture.generateArtifact(from: plan)
        let firstRevision = try XCTUnwrap(original.currentRevision)
        let service = GeneratedTestArtifactService(lifecycle: fixture.lifecycle)
        let originalContext = fixture.reviewContext(for: original)
        let revised = try service.requestChanges(
            originalContext,
            instructions: "Add an explicit denied-audit assertion.",
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertEqual(revised.revisions.count, 2)
        XCTAssertEqual(revised.revisions[0], firstRevision)
        XCTAssertEqual(revised.currentRevision?.revision, 2)
        XCTAssertNotNil(firstRevision.reviewSessionID)
        XCTAssertNotNil(revised.currentRevision?.reviewSessionID)
        XCTAssertNotEqual(firstRevision.reviewSessionID, revised.currentRevision?.reviewSessionID)
        XCTAssertEqual(revised.reviewState(for: 1), .changeRequested)
        XCTAssertEqual(revised.reviewState(for: 2), .awaitingReview)
        XCTAssertEqual(revised.reviewDecisions.count, 1)
        XCTAssertEqual(revised.reviewDecisions[0].decision, .requestChanges)
        XCTAssertEqual(
            revised.reviewDecisions[0].reviewerInstructions,
            "Add an explicit denied-audit assertion."
        )
        XCTAssertNotNil(revised.currentRevision?.reviewInstructionSHA256)

        assertGeneratedFailure(.artifactReviewStateInvalid) {
            _ = try service.beginApprovalConfirmation(originalContext)
        }
        let restarted = try GeneratedTestArtifactStore(storageRoot: fixture.lifecycle.storageRoot).load(
            workspaceID: fixture.workspaceID,
            planningTaskID: fixture.planningTaskID,
            artifactID: revised.artifactID
        )
        XCTAssertEqual(restarted, revised)
    }

    func testRevisionTwoRejectUsesDistinctExactAuthorityOnceAndRemainsAuditableAfterRestart() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let legacyBefore = try fixture.originalLegacySnapshot()
        let plan = try fixture.prepareGeneratedTestPlan()
        let sandboxBefore = try fixture.sandboxSnapshot()
        let original = try fixture.generateArtifact(from: plan)
        let originalContext = fixture.reviewContext(for: original)
        let revisionOneBefore = try XCTUnwrap(original.revision(1))
        let service = GeneratedTestArtifactService(lifecycle: fixture.lifecycle)

        let revised = try service.requestChanges(
            originalContext,
            instructions: "Keep the exact evidence and separate the response-contract scenarios.",
            now: Date(timeIntervalSince1970: 2_100)
        )
        let revisionOne = try XCTUnwrap(revised.revision(1))
        let revisionTwo = try XCTUnwrap(revised.revision(2))
        let revisionTwoContext = fixture.reviewContext(for: revised)

        XCTAssertEqual(revisionOne, revisionOneBefore)
        XCTAssertEqual(revisionOne.reviewState, .awaitingReview)
        XCTAssertEqual(revised.reviewState(for: 1), .changeRequested)
        XCTAssertEqual(revised.reviewDecisions.first?.decision, .requestChanges)
        XCTAssertEqual(revised.reviewDecisions.first?.reviewSessionID, revisionOne.reviewSessionID)
        XCTAssertEqual(revisionTwo.reviewState, .awaitingReview)
        XCTAssertEqual(revised.reviewState(for: 2), .awaitingReview)
        XCTAssertNotNil(revisionOne.reviewSessionID)
        XCTAssertNotNil(revisionTwo.reviewSessionID)
        XCTAssertNotEqual(revisionOne.reviewSessionID, revisionTwo.reviewSessionID)
        XCTAssertEqual(revisionTwoContext.reviewSessionID, revisionTwo.reviewSessionID)
        XCTAssertEqual(revisionTwoContext.artifactID, revised.artifactID)
        XCTAssertEqual(revisionTwoContext.artifactRevision, 2)
        XCTAssertEqual(revisionTwoContext.artifactSHA256, revisionTwo.digest.sha256)
        XCTAssertEqual(revisionTwoContext.generatedTestPlanID, plan.planID)
        XCTAssertEqual(revisionTwoContext.candidatePatchID, fixture.manifest.patchID)
        XCTAssertEqual(revisionTwoContext.candidatePatchPlanID, fixture.manifest.plan.planID)
        XCTAssertEqual(revisionTwoContext.workspaceID, fixture.workspaceID)
        XCTAssertEqual(revisionTwoContext.authenticatedLocalSessionID, fixture.userSessionID)
        XCTAssertEqual(revisionTwoContext.appSessionID, fixture.appSessionID)
        XCTAssertEqual(
            revised.reviewEligibility(
                authenticatedLocalSessionID: fixture.userSessionID,
                appSessionID: fixture.appSessionID
            ),
            .available
        )

        assertGeneratedFailure(.artifactReviewStateInvalid) {
            _ = try service.reject(originalContext)
        }
        var mismatchedDigest = revisionTwoContext
        mismatchedDigest.artifactSHA256 = String(repeating: "0", count: 64)
        assertGeneratedFailure(.artifactReviewBindingMismatch) {
            _ = try service.reject(mismatchedDigest)
        }
        var staleReviewSession = revisionTwoContext
        staleReviewSession.reviewSessionID = try XCTUnwrap(revisionOne.reviewSessionID)
        assertGeneratedFailure(.artifactReviewBindingMismatch) {
            _ = try service.reject(staleReviewSession)
        }
        var mismatchedCandidatePatch = revisionTwoContext
        mismatchedCandidatePatch.candidatePatchID = CandidatePatchID()
        assertGeneratedFailure(.artifactReviewBindingMismatch) {
            _ = try service.reject(mismatchedCandidatePatch)
        }

        let rejected = try service.reject(
            revisionTwoContext,
            now: Date(timeIntervalSince1970: 2_200)
        )
        XCTAssertEqual(rejected.revisions, revised.revisions)
        XCTAssertEqual(rejected.sourceBinding, revised.sourceBinding)
        XCTAssertEqual(rejected.reviewState(for: 1), .changeRequested)
        XCTAssertEqual(rejected.reviewState(for: 2), .rejected)
        XCTAssertEqual(rejected.reviewDecisions.filter { $0.decision == .reject }.count, 1)
        XCTAssertEqual(rejected.reviewDecisions.last?.artifactRevision, 2)
        XCTAssertEqual(rejected.reviewDecisions.last?.artifactSHA256, revisionTwo.digest.sha256)
        XCTAssertEqual(rejected.reviewDecisions.last?.reviewSessionID, revisionTwo.reviewSessionID)
        XCTAssertFalse(revisionTwo.virtualFiles.isEmpty)
        XCTAssertFalse(revisionTwo.scenarioBindings.isEmpty)
        XCTAssertFalse(revisionTwo.evidenceBindings.isEmpty)
        XCTAssertFalse(revisionTwo.digest.sha256.isEmpty)
        XCTAssertEqual(try fixture.originalLegacySnapshot(), legacyBefore)
        XCTAssertEqual(try fixture.sandboxSnapshot(), sandboxBefore)
        for file in revisionTwo.virtualFiles {
            XCTAssertFalse(try fixture.virtualFileExists(file))
        }
        assertZeroAuthorityCounters(service.safetyCounters(for: rejected), expectsMetadata: true)
        XCTAssertFalse(rejected.phase2D3Available)
        XCTAssertFalse(rejected.reviewEligibility(
            authenticatedLocalSessionID: fixture.userSessionID,
            appSessionID: fixture.appSessionID
        ).isAvailable)

        assertGeneratedFailure(.artifactReviewStateInvalid) {
            _ = try service.reject(revisionTwoContext)
        }
        assertGeneratedFailure(.artifactReviewStateInvalid) {
            _ = try service.requestChanges(revisionTwoContext, instructions: "Conflicting change")
        }
        assertGeneratedFailure(.artifactReviewStateInvalid) {
            _ = try service.beginApprovalConfirmation(revisionTwoContext)
        }

        let restarted = try GeneratedTestArtifactStore(storageRoot: fixture.lifecycle.storageRoot).load(
            workspaceID: fixture.workspaceID,
            planningTaskID: fixture.planningTaskID,
            artifactID: rejected.artifactID
        )
        XCTAssertEqual(restarted, rejected)
        XCTAssertEqual(restarted.reviewState(for: 2), .rejected)
        XCTAssertEqual(restarted.revision(2), revisionTwo)
        XCTAssertFalse(restarted.phase2D3Available)
    }

    func testRejectPreservesAuditableSourceAndPerformsNoSandboxMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.prepareGeneratedTestPlan()
        let artifact = try fixture.generateArtifact(from: plan)
        let sourceBefore = try XCTUnwrap(artifact.currentRevision?.virtualFiles.first?.sourceBytes)
        let sandboxBefore = try fixture.sandboxSnapshot()
        let service = GeneratedTestArtifactService(lifecycle: fixture.lifecycle)
        let rejected = try service.reject(
            fixture.reviewContext(for: artifact),
            now: Date(timeIntervalSince1970: 2_200)
        )

        XCTAssertEqual(rejected.reviewState(for: 1), .rejected)
        XCTAssertEqual(rejected.reviewDecisions.last?.decision, .reject)
        XCTAssertEqual(rejected.currentRevision?.virtualFiles.first?.sourceBytes, sourceBefore)
        XCTAssertEqual(try fixture.sandboxSnapshot(), sandboxBefore)
        XCTAssertFalse(try fixture.virtualFileExists(
            XCTUnwrap(rejected.currentRevision?.virtualFiles.first)
        ))
        assertZeroAuthorityCounters(service.safetyCounters(for: rejected), expectsMetadata: true)
    }

    func testApprovalRequiresExactConfirmationAndPerformsNoExecutionOrMaterialization() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.prepareGeneratedTestPlan()
        let artifact = try fixture.generateArtifact(from: plan)
        let sandboxBefore = try fixture.sandboxSnapshot()
        let service = GeneratedTestArtifactService(lifecycle: fixture.lifecycle)
        let context = fixture.reviewContext(for: artifact)

        var wrongDigest = context
        wrongDigest.artifactSHA256 = String(repeating: "0", count: 64)
        assertGeneratedFailure(.artifactReviewBindingMismatch) {
            _ = try service.beginApprovalConfirmation(wrongDigest)
        }
        var wrongUserSession = context
        wrongUserSession.authenticatedLocalSessionID = UUID()
        assertGeneratedFailure(.artifactReviewBindingMismatch) {
            _ = try service.beginApprovalConfirmation(wrongUserSession)
        }
        var wrongAppSession = context
        wrongAppSession.appSessionID = UUID()
        assertGeneratedFailure(.artifactReviewBindingMismatch) {
            _ = try service.beginApprovalConfirmation(wrongAppSession)
        }

        let confirmation = try service.beginApprovalConfirmation(
            context,
            now: Date(timeIntervalSince1970: 2_300)
        )
        assertGeneratedFailure(.artifactApprovalConfirmationInvalid) {
            _ = try service.confirmApproval(confirmation, context: wrongDigest)
        }
        let approved = try service.confirmApproval(
            confirmation,
            context: context,
            now: Date(timeIntervalSince1970: 2_301)
        )
        XCTAssertEqual(approved.reviewState(for: 1), .approved)
        XCTAssertEqual(approved.reviewDecisions.last?.decision, .approve)
        XCTAssertEqual(approved.reviewDecisions.last?.artifactSHA256, context.artifactSHA256)
        XCTAssertEqual(try fixture.sandboxSnapshot(), sandboxBefore)
        XCTAssertFalse(try fixture.virtualFileExists(
            XCTUnwrap(approved.currentRevision?.virtualFiles.first)
        ))
        assertZeroAuthorityCounters(service.safetyCounters(for: approved), expectsMetadata: true)
        XCTAssertFalse(approved.phase2D3Available)
    }

    func testRestartProjectionKeepsCandidatePlanAndArtifactCardsSeparate() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let plan = try fixture.prepareGeneratedTestPlan()
        let artifact = try fixture.generateArtifact(from: plan)
        let candidate = CandidatePatchActivitySnapshot(manifest: fixture.manifest)
        let generated = GeneratedTestActivitySnapshot(plan: plan)
        let candidateEvent = fixture.event(
            taskID: fixture.sourceTaskID,
            sequence: 1,
            payload: candidate.eventPayload
        )
        let generatedEvent = fixture.event(
            taskID: fixture.planningTaskID,
            sequence: 2,
            payload: generated.eventPayload
        )
        let restartedArtifacts = try GeneratedTestArtifactStore(
            storageRoot: fixture.lifecycle.storageRoot
        ).loadAll(workspaceID: fixture.workspaceID)
        let projection = AgentConversationAssetProjector.project(
            workspaceID: fixture.workspaceID,
            events: [candidateEvent, generatedEvent],
            candidatePatchManifests: [fixture.manifest],
            generatedTestArtifacts: restartedArtifacts
        )

        XCTAssertEqual(projection.candidatePatches.count, 1)
        XCTAssertEqual(projection.generatedTestPlans.count, 1)
        XCTAssertEqual(projection.generatedTestArtifacts, [artifact])
        XCTAssertEqual(
            projection.generatedTestArtifacts.first?.currentRevision?.virtualFiles.first?.sourceText,
            artifact.currentRevision?.virtualFiles.first?.sourceText
        )
    }

    func testArtifactUIKeepsFilesIndependentAndExactDetailsCollapsedAndCopyable() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/UI/Components/GeneratedTestArtifactView.swift"
            ),
            encoding: .utf8
        )
        let conversation = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/UI/Components/AgentConversationView.swift"
            ),
            encoding: .utf8
        )
        let appStore = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/App/AppStore.swift"
            ),
            encoding: .utf8
        )

        for value in [
            "ForEach(revision.virtualFiles)", "selectedFile = file",
            "GeneratedTestVirtualFilePreview", "ScrollView([.horizontal, .vertical])",
            "String(index + 1)", "case content = \"Content\"",
            "case scenarios = \"Scenarios\"", "case evidence = \"Evidence\"",
            "case binding = \"Exact Binding\"", "Copy Path", "Copy Source",
            "DisclosureGroup(\"Exact binding details\")", "Copy full",
            "Request Changes", "Reject Artifact", "Approve Test Artifact",
            "Approve Exact Artifact", "Review session ID", "Phase 2D.3 is unavailable"
        ] {
            XCTAssertTrue(source.contains(value), value)
        }
        for identifier in [
            "generatedTests.artifact.card", "generatedTests.artifact.file.open",
            "generatedTests.artifact.fileList", "generatedTests.artifact.file.preview",
            "generatedTests.artifact.file.content", "generatedTests.artifact.file.scenarios",
            "generatedTests.artifact.file.evidence", "generatedTests.artifact.file.binding",
            "generatedTests.artifact.requestChanges", "generatedTests.artifact.reject",
            "generatedTests.artifact.approve.openConfirmation",
            "generatedTests.artifact.approve.cancel", "generatedTests.artifact.approve.confirm"
        ] {
            XCTAssertTrue(source.contains(identifier), identifier)
        }
        XCTAssertTrue(source.contains("!reviewEligibility.isAvailable"))
        XCTAssertTrue(source.contains("generatedTests.artifact.review.unavailableReason"))
        XCTAssertTrue(conversation.contains("generatedTestArtifactReviewEligibility?(artifact)"))
        XCTAssertTrue(conversation.contains("generatedTestPlanGenerationEligibility?(snapshot)"))
        XCTAssertTrue(conversation.contains("!generationEligibility.isAvailable"))
        XCTAssertTrue(conversation.contains("DisclosureGroup(\"Exact Plan binding\")"))
        XCTAssertTrue(conversation.contains("generatedTests.artifact.generate.unavailableReason"))
        XCTAssertTrue(appStore.contains("generatedTestPlanGenerationsInFlight.insert(actionID)"))
        XCTAssertTrue(appStore.contains("defer { generatedTestPlanGenerationsInFlight.remove(actionID) }"))
        XCTAssertTrue(appStore.contains("generatedTestArtifactReviewSessionsInFlight.insert(reviewSessionID)"))
        XCTAssertTrue(appStore.contains("defer { generatedTestArtifactReviewSessionsInFlight.remove(reviewSessionID) }"))
        let summary = try XCTUnwrap(
            source.components(separatedBy: "private func summaryGrid").last?
                .components(separatedBy: "private func fileList").first
        )
        XCTAssertTrue(summary.contains("short(artifact.sourceBinding"))
        XCTAssertFalse(summary.contains("artifact.artifactID.uuidString"))
        XCTAssertFalse(summary.contains("revision.digest.sha256"))
        let exact = try XCTUnwrap(
            source.components(separatedBy: "private func exactBindingDetails").last?
                .components(separatedBy: "private func generationLifecycle").first
        )
        XCTAssertTrue(exact.contains("artifact.artifactID.uuidString.lowercased()"))
        XCTAssertTrue(exact.contains("revision.digest.sha256"))
        XCTAssertTrue(exact.contains("candidatePatchArtifactSHA256"))
        XCTAssertTrue(source.contains("NSPasteboard.general.setString(value"))
        XCTAssertFalse(source.contains(".accessibilityAction"))
        XCTAssertTrue(conversation.contains("ForEach(generatedTestArtifactAssets)"))
    }
}

private extension GeneratedTestArtifactTests {
    struct Fixture {
        var container: URL
        var legacy: URL
        var lifecycle: SandboxLifecycleService
        var manifest: CandidatePatchManifest
        var workspaceID: UUID
        var sourceTaskID: UUID
        var planningTaskID: UUID
        var userSessionID: UUID
        var appSessionID: UUID

        func cleanup() {
            try? FileManager.default.removeItem(at: container)
        }

        func prepareGeneratedTestPlan(
            planningTaskID exactPlanningTaskID: UUID? = nil
        ) throws -> GeneratedTestPlan {
            let binding = try XCTUnwrap(CandidatePatchGeneratedTestSourceBinding(manifest: manifest))
            return try GeneratedTestPlanningService(lifecycle: lifecycle).preparePlan(
                GeneratedTestPlanningRequest(
                    workspaceID: workspaceID,
                    planningTaskID: exactPlanningTaskID ?? planningTaskID,
                    sourceContext: GeneratedTestPlanningContext(
                        sourceBinding: binding,
                        appSessionID: appSessionID
                    )
                ),
                now: Date(timeIntervalSince1970: 2_000)
            ).plan
        }

        func generationContext(for plan: GeneratedTestPlan) -> GeneratedTestArtifactGenerationContext {
            GeneratedTestArtifactGenerationContext(
                workspaceID: workspaceID,
                generatedTestPlanningTaskID: plan.sourceBinding.generatedTestPlanningTaskID,
                generatedTestPlanID: plan.planID,
                generatedTestPlanRevision: plan.revision,
                generatedTestPlanSHA256: plan.planSHA256,
                generatedTestSourceBindingSHA256: plan.sourceBinding.digest,
                sourceCandidatePatchTaskID: plan.sourceBinding.sourceCandidatePatchTaskID,
                candidatePatchID: plan.sourceBinding.patchID,
                candidatePatchPlanID: plan.sourceBinding.candidatePatchPlanID,
                candidatePatchPlanRevision: plan.sourceBinding.candidatePatchPlanRevision,
                candidatePatchArtifactSHA256: plan.sourceBinding.candidatePatchArtifactSHA256,
                sandboxID: plan.sourceBinding.sandboxID,
                sourceSnapshotID: plan.sourceBinding.sourceSnapshotID,
                authenticatedLocalSessionID: userSessionID,
                appSessionID: appSessionID
            )
        }

        func generateArtifact(from plan: GeneratedTestPlan) throws -> GeneratedTestArtifact {
            let result = try GeneratedTestArtifactService(lifecycle: lifecycle).generate(
                .init(context: generationContext(for: plan)),
                now: Date(timeIntervalSince1970: 2_050)
            )
            XCTAssertEqual(
                result.outcome,
                .testArtifactReviewReady,
                result.missingEvidence.joined(separator: " | ")
            )
            XCTAssertTrue(
                result.missingEvidence.isEmpty,
                result.missingEvidence.joined(separator: " | ")
            )
            return try XCTUnwrap(result.artifact)
        }

        func reviewContext(for artifact: GeneratedTestArtifact) -> GeneratedTestArtifactReviewContext {
            let revision = artifact.currentRevision!
            return GeneratedTestArtifactReviewContext(
                workspaceID: workspaceID,
                generatedTestPlanningTaskID: planningTaskID,
                generatedTestPlanID: artifact.sourceBinding.generatedTestPlanID,
                generatedTestPlanRevision: artifact.sourceBinding.generatedTestPlanRevision,
                generatedTestPlanSHA256: artifact.sourceBinding.generatedTestPlanSHA256,
                sourceCandidatePatchTaskID: artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID,
                candidatePatchID: artifact.sourceBinding.generatedTestSourceBinding.patchID,
                candidatePatchPlanID: artifact.sourceBinding.generatedTestSourceBinding.candidatePatchPlanID,
                candidatePatchPlanRevision: artifact.sourceBinding.generatedTestSourceBinding.candidatePatchPlanRevision,
                candidatePatchArtifactSHA256: artifact.sourceBinding.generatedTestSourceBinding.candidatePatchArtifactSHA256,
                sandboxID: artifact.sourceBinding.generatedTestSourceBinding.sandboxID,
                artifactID: artifact.artifactID,
                artifactRevision: revision.revision,
                artifactSHA256: revision.digest.sha256,
                reviewSessionID: revision.reviewSessionID!,
                authenticatedLocalSessionID: userSessionID,
                appSessionID: appSessionID
            )
        }

        func sandboxURL() throws -> URL {
            try SandboxPathResolver(storageRoot: lifecycle.storageRoot)
                .resolve(sandboxID: manifest.sandboxID, relativePath: ".")
        }

        func sandboxSnapshot() throws -> String {
            try SourceSnapshotBuilder().build(root: sandboxURL()).snapshotID
        }

        func originalLegacySnapshot() throws -> String {
            try SourceSnapshotBuilder().build(root: legacy).snapshotID
        }

        func virtualFileExists(_ file: GeneratedTestVirtualFile) throws -> Bool {
            FileManager.default.fileExists(
                atPath: try sandboxURL().appendingPathComponent(file.proposedRelativePath).path
            )
        }

        func overwritePersistedPlan(_ plan: GeneratedTestPlan) throws {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(plan).write(to: planURL(), options: [.atomic])
        }

        func planURL() -> URL {
            lifecycle.storageRoot
                .appendingPathComponent(".generated-test-plans", isDirectory: true)
                .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(planningTaskID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("generated-test-plan.json")
        }

        func artifactURL(_ artifact: GeneratedTestArtifact) -> URL {
            lifecycle.storageRoot
                .appendingPathComponent(".generated-test-artifacts", isDirectory: true)
                .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(planningTaskID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent(artifact.artifactID.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("generated-test-artifact.json")
        }

        func event(
            taskID: UUID,
            sequence: Int64,
            payload: [String: String]
        ) -> ExecutionEvent {
            ExecutionEvent(
                id: UUID(),
                parentEventID: nil,
                workspaceID: workspaceID,
                taskID: taskID,
                type: .stateUpdated,
                sequence: sequence,
                timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
                summary: "Generated Test Artifact projection",
                payload: payload
            )
        }
    }

    func makeFixture() throws -> Fixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let legacy = repositoryRoot.appendingPathComponent("demo/TestableLegacy", isDirectory: true)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEGeneratedTestArtifact-\(UUID().uuidString)", isDirectory: true)
        let managed = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
        let lifecycle = SandboxLifecycleService(storageRoot: managed)
        let inspection = try lifecycle.createSandbox(sourceRoot: legacy, approvedLegacyRoot: legacy)
        let workspaceID = UUID()
        let sourceTaskID = UUID()
        let planningTaskID = UUID()
        let userSessionID = UUID()
        let appSessionID = UUID()
        let assessmentID = "phase-2d2b-testable-legacy"
        let claimID = "claim-testable-order-boundary"
        let blockerID = "blocker-record-level-order-authorization"
        let validationPlan = CandidatePatchValidationTestPlan(
            assessmentID: assessmentID,
            items: validationItems(claimID: claimID, blockerID: blockerID),
            executionAuthorized: false
        )
        let evidence = CandidatePatchEvidence(
            claimID: claimID,
            statement: "The inspected TestableLegacy order boundary is grounded source evidence.",
            evidenceReferences: [AssessmentEvidenceReference(
                source: .inspectedFile,
                path: "src/orders.ts",
                fact: "The order lookup exposes the existing support-role and record-filter boundary.",
                claimLevel: .sourceBehaviorConfirmed,
                observationStatus: .directlyRead,
                sourceComponent: "src",
                safeEvidenceSummary: "The inspected order source grounds the bounded read behavior.",
                workspaceSnapshotIdentifier: inspection.sourceManifest.snapshotID
            )],
            confidence: .high,
            material: true
        )
        let assessment = CandidatePatchAssessmentContext(
            assessmentID: assessmentID,
            generatedAt: Date(timeIntervalSince1970: 1_000),
            sourceSnapshotID: inspection.sourceManifest.snapshotID,
            canonicalLegacyRoot: legacy.standardizedFileURL.path,
            requestedCapabilityID: AIAgentCapabilityKind.customerSupportOrderLookup.rawValue,
            requestedCapabilityDisplayLabel: AIAgentCapabilityKind.customerSupportOrderLookup.displayName,
            compatibilityDecision: .yes,
            supportedCapabilities: ["api_service_layer", "authentication", "audit_logging"],
            blockers: [blockerID],
            unresolvedRequirements: [],
            evidence: [evidence],
            validationTestPlan: validationPlan
        )
        let request = CandidatePatchPlanRequest(
            sandboxID: inspection.descriptor.sandboxID,
            selectedLegacyRoot: legacy,
            trustedLegacyRoot: legacy,
            assessment: assessment,
            requestedCapabilityID: AIAgentCapabilityKind.customerSupportOrderLookup.rawValue,
            requestedOutcome: "Add a bounded read-only Agent adapter in the isolated Sandbox.",
            proposedOperations: [CandidatePatchProposedOperation(
                relativePath: "src/orderReadAdapter.ts",
                operationType: .createTextFile,
                proposedContent: orderAdapterSource,
                purpose: "Bind order reads to exact record authorization and an allowlisted response.",
                evidenceClaimIDs: [claimID],
                blockersAddressed: [blockerID],
                risk: .low,
                impact: "Adds only the approved read-only adapter inside the Safe Sandbox."
            )],
            approvedScope: ["src"],
            expectedBehavior: ["Authorized reads return only orderID and status."],
            validationRequiredLater: ["Review virtual tests before any future materialization."],
            rollbackApproach: "Remove the exact Patch-created adapter from the Sandbox.",
            unknowns: ["Runtime behavior remains unverified."]
        )
        let service = CandidatePatchService(lifecycle: lifecycle)
        let plan = try service.preparePlan(request)
        let approvalID = UUID()
        _ = try service.recordApprovalRequest(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: plan.patchID,
            planID: plan.planID,
            approvalRequestID: approvalID,
            now: Date(timeIntervalSince1970: 1_100)
        )
        let provenance = CandidatePatchApprovalProvenance(
            source: .nativeUI,
            workspaceID: workspaceID,
            taskID: sourceTaskID,
            planID: plan.planID,
            planRevision: plan.revision,
            approvalRequestID: approvalID,
            assessmentID: assessmentID,
            sourceSnapshotID: inspection.sourceManifest.snapshotID,
            canonicalLegacyRoot: legacy.standardizedFileURL.path,
            authenticatedUserSessionID: userSessionID,
            appSessionID: appSessionID,
            confirmationStepID: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_200),
            controllerPath: "GeneratedTestArtifactTests.exactApproval",
            uiAction: "confirm_exact_candidate_patch"
        )
        _ = try service.recordDecision(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "fixture-reviewer",
            rationale: "Approve the exact TestableLegacy Candidate Patch.",
            approvalRequestID: approvalID,
            approvalProvenance: provenance,
            now: Date(timeIntervalSince1970: 1_200)
        )
        let manifest = try service.apply(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: plan.patchID,
            now: Date(timeIntervalSince1970: 1_300)
        ).manifest
        return Fixture(
            container: container,
            legacy: legacy,
            lifecycle: lifecycle,
            manifest: manifest,
            workspaceID: workspaceID,
            sourceTaskID: sourceTaskID,
            planningTaskID: planningTaskID,
            userSessionID: userSessionID,
            appSessionID: appSessionID
        )
    }

    func validationItems(
        claimID: String,
        blockerID: String
    ) -> [CandidatePatchValidationTestItem] {
        let values: [(String, String, String, CandidatePatchSuggestedTestLevel)] = [
            ("authorized-order", "Authenticated user can access an authorized order", "The authorized order is returned through the allowlisted contract.", .security),
            ("other-customer", "User cannot access another customer's order", "A cross-customer lookup is rejected.", .security),
            ("role-boundary", "Support role alone does not bypass record-level authorization", "The record-level decision remains required.", .security),
            ("allowlist", "customerID and unnecessary sensitive fields are omitted by the response allowlist", "Only orderID and status are returned.", .contract),
            ("read-only", "Order lookup remains read-only", "Repeated reads expose no mutation behavior.", .contract),
            ("audit", "Audit logging receives the approved non-sensitive order-read event", "The approved audit record is emitted without response payload data.", .security),
            ("mutation", "Unauthorized mutation attempts remain rejected", "Only the approved read function is exported.", .security)
        ]
        return values.map { id, title, behavior, level in
            CandidatePatchValidationTestItem(
                validationItemID: "validation-\(id)",
                title: title,
                purpose: "Verify \(title.lowercased()).",
                expectedBehavior: behavior,
                relatedRequirementIDs: [id],
                relatedBlockerIDs: [blockerID],
                relatedEvidenceClaimIDs: [claimID],
                suggestedTestLevel: level,
                runtimeVerificationStatus: .notVerified,
                required: true
            )
        }
    }

    var orderAdapterSource: String {
        """
        import type { Principal } from "./auth";
        import { recordAuditEvent } from "./audit";
        import { listCustomerOrders } from "./orders";

        export interface OrderReadAuthorization {
          canReadCustomerOrders(principal: Principal, customerID: string): boolean;
        }

        export function listAuthorizedCustomerOrders(
          principal: Principal,
          customerID: string,
          authorization: OrderReadAuthorization
        ): Array<{ orderID: string; status: "processing" | "shipped" }> {
          if (!authorization.canReadCustomerOrders(principal, customerID)) {
            throw new Error("forbidden");
          }
          const result = listCustomerOrders(principal, customerID)
            .map(({ orderID, status }) => ({ orderID, status }));
          recordAuditEvent({
            actorID: principal.subject,
            action: "orders.read",
            resourceID: customerID,
            outcome: "allowed"
          });
          return result;
        }
        """ + "\n"
    }

    func assertGeneratedFailure(
        _ expected: GeneratedTestFailureCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? GeneratedTestError)?.code, expected, file: file, line: line)
        }
    }

    func assertZeroAuthorityCounters(
        _ counters: GeneratedTestArtifactSafetyCounters,
        expectsMetadata: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(counters.legacyWrites, 0, file: file, line: line)
        XCTAssertEqual(counters.sandboxWrites, 0, file: file, line: line)
        XCTAssertEqual(counters.candidatePatchMutations, 0, file: file, line: line)
        XCTAssertEqual(counters.realGeneratedTestFiles, 0, file: file, line: line)
        XCTAssertEqual(counters.generatedBytesWrittenToFileSystem, 0, file: file, line: line)
        XCTAssertEqual(counters.syntaxChecks, 0, file: file, line: line)
        XCTAssertEqual(counters.buildExecutions, 0, file: file, line: line)
        XCTAssertEqual(counters.testExecutions, 0, file: file, line: line)
        XCTAssertEqual(counters.shellOperations, 0, file: file, line: line)
        XCTAssertEqual(counters.gitOperations, 0, file: file, line: line)
        XCTAssertEqual(counters.packageManagerOperations, 0, file: file, line: line)
        XCTAssertEqual(counters.deploymentOperations, 0, file: file, line: line)
        XCTAssertEqual(counters.credentialAccesses, 0, file: file, line: line)
        XCTAssertEqual(counters.productionAccesses, 0, file: file, line: line)
        if expectsMetadata {
            XCTAssertGreaterThan(counters.artifactMetadataSourceBytes, 0, file: file, line: line)
        }
    }
}
