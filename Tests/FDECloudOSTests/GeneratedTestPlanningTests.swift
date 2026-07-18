import XCTest
@testable import FDECloudOS

final class GeneratedTestPlanningTests: XCTestCase {
    func testCandidatePatchArtifactDigestIsCanonicalAndSensitiveToAuthorityContent() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()

        let first = try CandidatePatchArtifactAuthority.artifactSHA256(for: manifest)
        var presentationOnlyChange = manifest
        presentationOnlyChange.updatedAt = Date(timeIntervalSince1970: 9_999)
        presentationOnlyChange.status = .applied
        XCTAssertEqual(first, try CandidatePatchArtifactAuthority.artifactSHA256(for: presentationOnlyChange))

        var authorityChange = manifest
        authorityChange.plan.compatibilityDecision = .partial
        XCTAssertNotEqual(first, try CandidatePatchArtifactAuthority.artifactSHA256(for: authorityChange))

        var diffChange = manifest
        diffChange.unifiedDiff = (manifest.unifiedDiff ?? "") + "\n+tampered\n"
        XCTAssertNotEqual(first, try CandidatePatchArtifactAuthority.artifactSHA256(for: diffChange))

        var imageChange = manifest
        imageChange.operations[0].resultingSHA256 = String(repeating: "a", count: 64)
        XCTAssertNotEqual(first, try CandidatePatchArtifactAuthority.artifactSHA256(for: imageChange))
        XCTAssertEqual(manifest.candidatePatchArtifactSHA256, first)
        XCTAssertEqual(manifest.appliedBinding?.candidatePatchArtifactSHA256, first)
    }

    func testMissingOrDriftedCandidatePatchAuthorityFailsClosed() throws {
        do {
            let fixture = try makeFixture(environment: .vitest)
            defer { fixture.cleanup() }
            var manifest = try fixture.authorizedManifest()
            let sourceBinding = try XCTUnwrap(
                CandidatePatchGeneratedTestSourceBinding(manifest: manifest)
            )
            manifest.candidatePatchArtifactSHA256 = nil
            manifest.appliedBinding?.candidatePatchArtifactSHA256 = nil
            try CandidatePatchManifestStore(lifecycle: fixture.lifecycle).save(manifest)
            assertGeneratedFailure(.candidatePatchArtifactDigestMissing) {
                _ = try fixture.planGeneratedTests(sourceBinding: sourceBinding)
            }
        }

        do {
            let fixture = try makeFixture(environment: .vitest)
            defer { fixture.cleanup() }
            var manifest = try fixture.authorizedManifest()
            let sourceBinding = try XCTUnwrap(
                CandidatePatchGeneratedTestSourceBinding(manifest: manifest)
            )
            manifest.unifiedDiff = (manifest.unifiedDiff ?? "") + "\n+not-authorized\n"
            try CandidatePatchManifestStore(lifecycle: fixture.lifecycle).save(manifest)
            assertGeneratedFailure(.candidatePatchDiffMismatch) {
                _ = try fixture.planGeneratedTests(sourceBinding: sourceBinding)
            }
        }

        do {
            let fixture = try makeFixture(environment: .vitest)
            defer { fixture.cleanup() }
            let manifest = try fixture.authorizedManifest()
            let workspace = try fixture.workspaceURL()
            try Data("export function listOrders(): string[] { return ['drift'] }\n".utf8)
                .write(to: workspace.appendingPathComponent("src/orders.ts"))
            assertGeneratedFailure(.candidatePatchPostimageMismatch) {
                _ = try fixture.planGeneratedTests()
            }
            XCTAssertNotNil(manifest.candidatePatchArtifactSHA256)
        }
    }

    func testStructuredValidationPlanPersistsAndMismatchFailsClosed() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let plan = try XCTUnwrap(manifest.plan.assessmentContext?.validationTestPlan)
        let sourceBinding = try XCTUnwrap(
            CandidatePatchGeneratedTestSourceBinding(manifest: manifest)
        )
        let digest = CandidatePatchArtifactAuthority.validationTestPlanSHA256(plan)
        XCTAssertEqual(manifest.validationTestPlanSHA256, digest)
        XCTAssertEqual(manifest.plan.validationTestPlanSHA256, digest)
        XCTAssertEqual(plan.items.first?.runtimeVerificationStatus, .notVerified)
        XCTAssertEqual(plan.items.first?.relatedRequirementIDs, ["record_level_authorization"])

        let encoded = try JSONEncoder().encode(manifest.plan.assessmentContext)
        let restored = try JSONDecoder().decode(CandidatePatchAssessmentContext?.self, from: encoded)
        XCTAssertEqual(restored?.validationTestPlan, plan)

        var mismatched = manifest
        mismatched.plan.assessmentContext?.validationTestPlan?.items[0].expectedBehavior = "Different assessment behavior"
        try CandidatePatchManifestStore(lifecycle: fixture.lifecycle).save(mismatched)
        assertGeneratedFailure(.validationTestPlanMismatch) {
            _ = try fixture.planGeneratedTests(sourceBinding: sourceBinding)
        }
    }

    func testExactSourceBindingSucceedsAndWrongBindingsFailClosed() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let result = try fixture.planGeneratedTests()
        XCTAssertEqual(result.outcome, .testPlanReviewReady)
        XCTAssertEqual(result.plan.sourceBinding.workspaceID, fixture.workspaceID)
        XCTAssertEqual(result.plan.sourceBinding.sourceCandidatePatchTaskID, fixture.sourceTaskID)
        XCTAssertEqual(result.plan.sourceBinding.patchID, manifest.patchID)
        XCTAssertEqual(result.plan.sourceBinding.sandboxID, manifest.sandboxID)
        XCTAssertEqual(result.plan.sourceBinding.sourceSnapshotID, manifest.sourceSnapshotID)
        XCTAssertEqual(result.plan.sourceBinding.normalizedCapabilityID, manifest.plan.requestedCapabilityID)
        XCTAssertEqual(result.plan.sourceBinding.validatedAssessmentID, manifest.plan.assessmentID)

        assertGeneratedFailure(.sourceBindingMismatch) {
            _ = try fixture.planGeneratedTests(patchID: CandidatePatchID())
        }
        assertGeneratedFailure(.sourceBindingMismatch) {
            _ = try fixture.planGeneratedTests(sandboxID: SandboxID())
        }
        assertGeneratedFailure(.sourceBindingMismatch) {
            _ = try fixture.planGeneratedTests(sourceTaskID: UUID())
        }
    }

    func testSnapshotCapabilityAndAssessmentTamperingFailsClosed() throws {
        for mutation in 0..<3 {
            let fixture = try makeFixture(environment: .vitest)
            defer { fixture.cleanup() }
            var manifest = try fixture.authorizedManifest()
            let sourceBinding = try XCTUnwrap(
                CandidatePatchGeneratedTestSourceBinding(manifest: manifest)
            )
            switch mutation {
            case 0:
                manifest.sourceSnapshotID = "wrong-snapshot"
                manifest.plan.sourceSnapshotID = "wrong-snapshot"
            case 1:
                manifest.plan.requestedCapabilityID = "wrong-capability"
            default:
                manifest.plan.assessmentID = "wrong-assessment"
            }
            try CandidatePatchManifestStore(lifecycle: fixture.lifecycle).save(manifest)
            XCTAssertThrowsError(try fixture.planGeneratedTests(sourceBinding: sourceBinding))
        }
    }

    func testGroundedFrameworkLocationDiffSymbolsAndValidationScenarios() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        _ = try fixture.authorizedManifest()
        let result = try fixture.planGeneratedTests()
        let plan = result.plan

        XCTAssertEqual(result.outcome, .testPlanReviewReady)
        XCTAssertEqual(plan.expectedFramework?.frameworkID, "vitest")
        XCTAssertEqual(plan.confirmedTestLocation, "tests")
        XCTAssertTrue(plan.frameworkEvidence.contains { $0.relativePath == "package.json" })
        XCTAssertTrue(plan.testLocationEvidence.contains { $0.relativePath == "tests/orders.test.ts" })
        XCTAssertFalse(plan.diffHunks.isEmpty)
        XCTAssertTrue(plan.affectedSymbols.contains { $0.name == "listOrders" })
        XCTAssertFalse(plan.proposedScenarios.isEmpty)
        XCTAssertTrue(plan.proposedScenarios.allSatisfy {
            !$0.sourceDiffHunkIDs.isEmpty
                && !$0.affectedSymbolReferences.isEmpty
                && (!$0.validationPlanItemIDs.isEmpty || !$0.relatedAssessmentBlockerIDs.isEmpty)
                && !$0.proposedTestRelativePath.isEmpty
        })
        XCTAssertFalse(plan.planSHA256.isEmpty)
        XCTAssertEqual(GeneratedTestPlanDigest.compute(plan), plan.planSHA256)
    }

    func testFrameworkAndLocationResolutionNeverInfersFromLanguage() throws {
        let languageOnly = try makeFixture(environment: .languageOnly)
        defer { languageOnly.cleanup() }
        _ = try languageOnly.authorizedManifest()
        let unknown = try languageOnly.planGeneratedTests()
        XCTAssertEqual(unknown.outcome, .clarificationRequired)
        XCTAssertNil(unknown.plan.expectedFramework)
        XCTAssertNil(unknown.plan.confirmedTestLocation)
        XCTAssertTrue(unknown.plan.remainingUnknowns.contains { $0.contains("No manifest dependency") })

        let conflict = try makeFixture(environment: .conflictingFrameworks)
        defer { conflict.cleanup() }
        _ = try conflict.authorizedManifest()
        let conflicted = try conflict.planGeneratedTests()
        XCTAssertEqual(conflicted.outcome, .clarificationRequired)
        XCTAssertNil(conflicted.plan.expectedFramework)
        XCTAssertTrue(conflicted.plan.remainingUnknowns.contains { $0.contains("Conflicting concrete framework") })

        let unknownLocation = try makeFixture(environment: .unknownLocation)
        defer { unknownLocation.cleanup() }
        _ = try unknownLocation.authorizedManifest()
        let noLocation = try unknownLocation.planGeneratedTests()
        XCTAssertEqual(noLocation.outcome, .clarificationRequired)
        XCTAssertEqual(noLocation.plan.expectedFramework?.frameworkID, "vitest")
        XCTAssertNil(noLocation.plan.confirmedTestLocation)
    }

    func testSyntheticLegacyReturnsClarificationRequiredWithoutWrites() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let synthetic = repositoryRoot.appendingPathComponent("demo/SyntheticLegacy", isDirectory: true)
        let fixture = try makeFixture(environment: .languageOnly, legacyOverride: synthetic)
        defer { fixture.cleanup() }
        _ = try fixture.authorizedManifest()
        let before = try SourceSnapshotBuilder().build(root: fixture.workspaceURL()).snapshotID
        let result = try fixture.planGeneratedTests()
        let after = try SourceSnapshotBuilder().build(root: fixture.workspaceURL()).snapshotID

        XCTAssertEqual(result.outcome, .clarificationRequired)
        XCTAssertNil(result.plan.expectedFramework)
        XCTAssertNil(result.plan.confirmedTestLocation)
        XCTAssertEqual(before, after)
        XCTAssertTrue(result.plan.proposedRelativeTestPaths.isEmpty)
        XCTAssertTrue(result.plan.proposedScenarios.isEmpty)
        XCTAssertFalse(result.plan.clarificationQuestions.isEmpty)
    }

    func testPlanningPolicyDisablesEveryWriteAndExecutionOperation() {
        XCTAssertEqual(GeneratedTestPlanningPolicy.phase2D2AReadAllowlist, [
            .readBoundSandboxManifest,
            .readBoundCandidatePatchSource,
            .readGroundedTestConfiguration
        ])
        XCTAssertTrue(GeneratedTestPlanningPolicy.phase2D2AWriteAllowlist.isEmpty)
        for operation in GeneratedTestStructuredOperation.allCases {
            let expected = GeneratedTestPlanningPolicy.phase2D2AReadAllowlist.contains(operation)
            XCTAssertEqual(GeneratedTestPlanningPolicy.permits(operation), expected, operation.rawValue)
        }
        for prohibited in [
            GeneratedTestStructuredOperation.createTestText,
            .replaceTestText, .revertGeneratedTestText, .createDirectory,
            .modifyDependencies, .executeBuildOrTest,
            .executeShellGitPackageManagerDeployment
        ] {
            XCTAssertFalse(GeneratedTestPlanningPolicy.permits(prohibited))
        }
        XCTAssertFalse(SandboxRuntimePolicy.phase2D1Allowlist.contains(.generatedTest))
    }

    func testPlanClaimsAreAccurateProjectionIsSeparateAndPlanSurvivesRestart() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let before = try SourceSnapshotBuilder().build(root: fixture.workspaceURL()).snapshotID
        let result = try fixture.planGeneratedTests()
        let after = try SourceSnapshotBuilder().build(root: fixture.workspaceURL()).snapshotID
        let markdown = result.plan.markdown

        XCTAssertEqual(before, after)
        XCTAssertTrue(markdown.contains("Generated Test Plan"))
        XCTAssertTrue(markdown.contains("No test files were created"))
        XCTAssertTrue(markdown.contains("Test syntax was not verified"))
        XCTAssertTrue(markdown.contains("Build was not executed"))
        XCTAssertTrue(markdown.contains("Tests were not executed"))
        XCTAssertTrue(markdown.contains("Behavioral correctness was not verified"))
        XCTAssertFalse(markdown.lowercased().contains("tests passed"))
        XCTAssertFalse(markdown.lowercased().contains("runtime verified"))
        XCTAssertTrue(result.plan.prohibitedOperations.contains("Phase 2D.3"))

        let restartedStore = GeneratedTestPlanStore(storageRoot: fixture.lifecycle.storageRoot)
        let restored = try restartedStore.load(
            workspaceID: fixture.workspaceID,
            planningTaskID: fixture.planningTaskID
        )
        XCTAssertEqual(restored, result.plan)
        var sameRevisionTamper = restored
        sameRevisionTamper.remainingUnknowns.append("Material change under the same revision.")
        sameRevisionTamper.planSHA256 = GeneratedTestPlanDigest.compute(sameRevisionTamper)
        XCTAssertThrowsError(try restartedStore.save(sameRevisionTamper)) { error in
            XCTAssertEqual((error as? GeneratedTestError)?.code, .planPersistenceInvalid)
        }
        XCTAssertEqual(
            try restartedStore.load(
                workspaceID: fixture.workspaceID,
                planningTaskID: fixture.planningTaskID
            ),
            restored
        )

        let candidateSnapshot = CandidatePatchActivitySnapshot(manifest: manifest)
        let generatedSnapshot = GeneratedTestActivitySnapshot(plan: result.plan)
        let activity = AgentConversationActivity.local(
            requestID: UUID(),
            dialogID: UUID(),
            scope: .engineeringTask
        )
        let payload = candidateSnapshot.eventPayload
            .merging(generatedSnapshot.eventPayload) { current, _ in current }
            .merging(["generated_test_activity_phase": GeneratedTestActivityPhase.testPlanReviewReady.rawValue]) {
                current, _ in current
            }
        let reduced = AgentConversationActivityReducer.reduce(
            activity,
            event: event(workspaceID: fixture.workspaceID, taskID: fixture.planningTaskID, payload: payload)
        )
        XCTAssertNotNil(reduced.metadata.candidatePatch)
        XCTAssertNotNil(reduced.metadata.generatedTest)
        XCTAssertEqual(reduced.kind, .generatedTestPlanReviewReady)
    }

    func testLatestPatchRequestDoesNotGuessAndDedicatedMissionDoesNotCaptureRunTests() async throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: fixture.workspaceID,
            name: "Generated Test no-guess fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path
        )
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            sandboxLifecycle: fixture.lifecycle
        )
        let task = try await kernel.runGeneratedTestPlanning(
            input: "generate tests for the latest patch",
            workspace: workspace
        )
        XCTAssertEqual(task.state, .waiting)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertEqual(events.last?.payload["failure_category"], GeneratedTestFailureCode.explicitSourceBindingRequired.rawValue)
        XCTAssertEqual(events.last?.payload["source_binding_verified"], "false")

        let planRequests = [
            "prepare a generated test plan for this Candidate Patch",
            "analyze which tests should be generated without writing files",
            "基于当前 Patch 和验证计划准备 Generated Test Plan"
        ]
        for request in planRequests {
            XCTAssertEqual(MissionIntentParser().parse(request).intentType, .generatedTestPlan, request)
        }
        for request in ["run tests", "execute tests", "build project", "do these tests pass?"] {
            XCTAssertNotEqual(MissionIntentParser().parse(request).intentType, .generatedTestPlan, request)
        }
        let contract = RuntimeCompletionContract(
            input: planRequests[0],
            intent: MissionIntentParser().parse(planRequests[0])
        )
        XCTAssertEqual(contract.kind, .generatedTestPlan)
    }

    func testRuntimeCompletionCarriesZeroCountersAndAllowsReviewReadyOutcome() async throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: fixture.workspaceID,
            name: "Generated Test exact runtime fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path
        )
        try await persistence.saveWorkspace(workspace)
        try await persistence.saveTask(completedTask(id: fixture.sourceTaskID, workspaceID: fixture.workspaceID))
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            sandboxLifecycle: fixture.lifecycle
        )
        _ = try await kernel.recordAuditEvent(
            type: .taskCompleted,
            workspaceID: fixture.workspaceID,
            taskID: fixture.sourceTaskID,
            summary: "Candidate Patch ready",
            payload: [
                "completion_contract": RuntimeCompletionContractKind.candidatePatchGeneration.rawValue,
                "candidate_patch_id": manifest.patchID.rawValue,
                "candidate_patch_sandbox_id": manifest.sandboxID.rawValue
            ]
        )
        let generatedTask = try await kernel.runGeneratedTestPlanning(
            input: "prepare a generated test plan for this Candidate Patch",
            workspace: workspace,
            context: GeneratedTestPlanningContext(
                sourceBinding: try XCTUnwrap(
                    CandidatePatchGeneratedTestSourceBinding(manifest: manifest)
                ),
                appSessionID: fixture.appSessionID
            )
        )
        XCTAssertEqual(generatedTask.state, .completed)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspaceID, taskID: generatedTask.id)
        let completion = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        for key in [
            "sandbox_write_count", "generated_test_file_count", "generated_test_byte_count",
            "build_execution_count", "test_execution_count", "syntax_check_count", "shell_count",
            "git_count", "package_manager_count", "deployment_count", "candidate_patch_write_count",
            "legacy_write_count"
        ] {
            XCTAssertEqual(completion.payload[key], "0", key)
        }
        XCTAssertEqual(completion.payload["approval_request_created"], "false")
        XCTAssertEqual(completion.payload["phase_2d_3_available"], "false")
        XCTAssertEqual(completion.payload["generated_test_outcome"], GeneratedTestPlanningOutcome.testPlanReviewReady.rawValue)
        let contract = RuntimeCompletionContract(
            input: generatedTask.rawInput,
            intent: MissionIntentParser().parse(generatedTask.rawInput)
        )
        XCTAssertTrue(contract.evaluate(events: events).allowed)
    }

    func testClarificationRuntimeCompletesTruthfullyWithoutApprovalOrExecution() async throws {
        let fixture = try makeFixture(environment: .languageOnly)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: fixture.workspaceID,
            name: "Generated Test clarification runtime fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path
        )
        try await persistence.saveWorkspace(workspace)
        try await persistence.saveTask(completedTask(id: fixture.sourceTaskID, workspaceID: fixture.workspaceID))
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            sandboxLifecycle: fixture.lifecycle
        )
        _ = try await kernel.recordAuditEvent(
            type: .taskCompleted,
            workspaceID: fixture.workspaceID,
            taskID: fixture.sourceTaskID,
            summary: "Candidate Patch ready",
            payload: [
                "completion_contract": RuntimeCompletionContractKind.candidatePatchGeneration.rawValue,
                "candidate_patch_id": manifest.patchID.rawValue,
                "candidate_patch_sandbox_id": manifest.sandboxID.rawValue
            ]
        )
        let generatedTask = try await kernel.runGeneratedTestPlanning(
            input: "prepare a generated test plan for this Candidate Patch",
            workspace: workspace,
            context: GeneratedTestPlanningContext(
                sourceBinding: try XCTUnwrap(
                    CandidatePatchGeneratedTestSourceBinding(manifest: manifest)
                ),
                appSessionID: fixture.appSessionID
            )
        )
        XCTAssertEqual(generatedTask.state, .completed)
        let events = try await persistence.loadEvents(workspaceID: fixture.workspaceID, taskID: generatedTask.id)
        let completion = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        XCTAssertEqual(
            completion.payload["generated_test_outcome"],
            GeneratedTestPlanningOutcome.clarificationRequired.rawValue
        )
        XCTAssertEqual(completion.payload["clarification_required"], "true")
        XCTAssertEqual(completion.payload["bounded_environment_investigation_performed"], "true")
        XCTAssertEqual(completion.payload["approval_request_created"], "false")
        XCTAssertEqual(completion.payload["sandbox_write_count"], "0")
        XCTAssertEqual(completion.payload["generated_test_file_count"], "0")
        XCTAssertEqual(completion.payload["build_execution_count"], "0")
        XCTAssertEqual(completion.payload["test_execution_count"], "0")
        let approvals = try await persistence.loadApprovalRequests(
            workspaceID: fixture.workspaceID,
            state: nil
        )
        XCTAssertTrue(approvals.isEmpty)
        let contract = RuntimeCompletionContract(
            input: generatedTask.rawInput,
            intent: MissionIntentParser().parse(generatedTask.rawInput)
        )
        XCTAssertTrue(contract.evaluate(events: events).allowed)
    }

    func testCompletedCandidatePatchAssetSurvivesCompletionMissionResultAndUnrelatedChat() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let snapshot = CandidatePatchActivitySnapshot(manifest: manifest)
        let ready = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: fixture.workspaceID,
            taskID: fixture.sourceTaskID,
            type: .taskCompleted,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            summary: "Candidate Patch ready",
            payload: snapshot.eventPayload.merging([
                "intent_type": MissionIntentType.candidatePatchGeneration.rawValue,
                "completion_contract": RuntimeCompletionContractKind.candidatePatchGeneration.rawValue,
                "state": TaskState.completed.rawValue
            ]) { current, _ in current }
        )
        let missionResult = ExecutionEvent(
            id: UUID(),
            parentEventID: ready.id,
            workspaceID: fixture.workspaceID,
            taskID: UUID(),
            type: .taskCompleted,
            sequence: 2,
            timestamp: Date(timeIntervalSince1970: 2),
            summary: "Mission result",
            payload: ["state": TaskState.completed.rawValue, "actual_result": "Unrelated result"]
        )
        let unrelatedChat = ExecutionEvent(
            id: UUID(),
            parentEventID: missionResult.id,
            workspaceID: fixture.workspaceID,
            taskID: nil,
            type: .userMessageReceived,
            sequence: 3,
            timestamp: Date(timeIntervalSince1970: 3),
            summary: "Unrelated chat",
            payload: ["chat_only": "true", "message": "hello"]
        )

        let projection = AgentConversationAssetProjector.project(
            workspaceID: fixture.workspaceID,
            events: [ready, missionResult, unrelatedChat]
        )
        let restored = try XCTUnwrap(projection.candidatePatches.first)
        XCTAssertEqual(projection.candidatePatches.count, 1)
        XCTAssertEqual(restored.patchID, manifest.patchID.rawValue)
        XCTAssertEqual(restored.sourceCandidatePatchTaskID, fixture.sourceTaskID.uuidString)
        XCTAssertEqual(restored.planID, manifest.plan.planID.uuidString)
        XCTAssertEqual(restored.planRevision, manifest.plan.revision)
        XCTAssertEqual(restored.sandboxID, manifest.sandboxID.rawValue)
        XCTAssertEqual(restored.assessmentID, manifest.plan.assessmentID)
        XCTAssertEqual(restored.sourceSnapshotID, manifest.sourceSnapshotID)
        XCTAssertNotNil(restored.exactGeneratedTestSourceBinding)
    }

    func testCandidatePatchAssetRestoresFromManifestAndLegacyReplayPayload() async throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        _ = try await persistence.appendEvent(ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: fixture.workspaceID,
            taskID: fixture.sourceTaskID,
            type: .taskCompleted,
            sequence: 1,
            timestamp: Date(timeIntervalSince1970: 1),
            summary: "Candidate Patch ready",
            payload: [
                "intent_type": MissionIntentType.candidatePatchGeneration.rawValue,
                "candidate_patch_id": manifest.patchID.rawValue,
                "candidate_patch_sandbox_id": manifest.sandboxID.rawValue,
                "candidate_patch_status": CandidatePatchStatus.reviewReady.rawValue,
                "candidate_patch_projection_state": CandidatePatchProjectionState.patchReady.rawValue,
                "candidate_patch_source_integrity": SourceIntegrityState.unchanged.rawValue,
                "candidate_patch_approval_state": CandidatePatchApprovalDecision.approve.rawValue
            ]
        ))

        let replayedEvents = try await persistence.loadEvents(
            workspaceID: fixture.workspaceID,
            taskID: nil
        )
        let replayedManifests = try CandidatePatchManifestStore(lifecycle: fixture.lifecycle).loadAll()
        let projection = AgentConversationAssetProjector.project(
            workspaceID: fixture.workspaceID,
            events: replayedEvents,
            candidatePatchManifests: replayedManifests
        )
        let restored = try XCTUnwrap(projection.candidatePatches.first)
        XCTAssertEqual(restored.manifestID, manifest.stableManifestID)
        XCTAssertEqual(restored.candidatePatchArtifactSHA256, manifest.candidatePatchArtifactSHA256)
        XCTAssertEqual(restored.validationTestPlanSHA256, manifest.validationTestPlanSHA256)
        XCTAssertEqual(
            restored.unifiedDiffSHA256,
            manifest.unifiedDiff.map(CandidatePatchArtifactAuthority.unifiedDiffSHA256)
        )
        XCTAssertNotNil(restored.exactGeneratedTestSourceBinding)
    }

    func testGeneratedTestAssetDoesNotOverwriteCandidatePatchAsset() throws {
        let fixture = try makeFixture(environment: .languageOnly)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let candidate = CandidatePatchActivitySnapshot(manifest: manifest)
        let generated = GeneratedTestActivitySnapshot(
            planningTaskID: fixture.planningTaskID.uuidString,
            sourceCandidatePatchTaskID: fixture.sourceTaskID.uuidString,
            patchID: manifest.patchID.rawValue,
            candidatePatchArtifactSHA256: manifest.candidatePatchArtifactSHA256,
            sandboxID: manifest.sandboxID.rawValue,
            sourceSnapshotID: manifest.sourceSnapshotID,
            capabilityID: manifest.plan.requestedCapabilityID,
            assessmentID: manifest.plan.assessmentID,
            validationPlanItemCount: 1,
            framework: nil,
            testLocation: nil,
            scenarioCount: 0,
            proposedTestPaths: [],
            status: .clarificationRequired,
            remainingUnknowns: ["Framework is unknown."]
        )
        let candidateEvent = event(
            workspaceID: fixture.workspaceID,
            taskID: fixture.sourceTaskID,
            payload: candidate.eventPayload
        )
        var generatedEvent = event(
            workspaceID: fixture.workspaceID,
            taskID: fixture.planningTaskID,
            payload: candidate.eventPayload.merging(generated.eventPayload) { current, _ in current }
        )
        generatedEvent.sequence = 2

        let projection = AgentConversationAssetProjector.project(
            workspaceID: fixture.workspaceID,
            events: [candidateEvent, generatedEvent]
        )
        XCTAssertEqual(projection.candidatePatches.map(\.patchID), [manifest.patchID.rawValue])
        XCTAssertEqual(projection.generatedTestPlans.map(\.planningTaskID), [fixture.planningTaskID.uuidString])
        XCTAssertEqual(projection.generatedTestPlans.first?.status, .clarificationRequired)
    }

    func testGeneratedTestPlanProjectionDeduplicatesOneAuthorityAndPreservesDistinctPlans() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        _ = try fixture.authorizedManifest()
        let plan = try fixture.planGeneratedTests().plan
        let first = GeneratedTestActivitySnapshot(plan: plan)
        var duplicateReady = event(
            workspaceID: fixture.workspaceID,
            taskID: fixture.planningTaskID,
            payload: first.eventPayload
        )
        duplicateReady.sequence = 1
        var duplicateCompleted = event(
            workspaceID: fixture.workspaceID,
            taskID: fixture.planningTaskID,
            payload: first.eventPayload
        )
        duplicateCompleted.sequence = 2

        let onePlan = AgentConversationAssetProjector.project(
            workspaceID: fixture.workspaceID,
            events: [duplicateReady, duplicateCompleted]
        )
        XCTAssertEqual(onePlan.generatedTestPlans, [first])
        XCTAssertEqual(onePlan.generatedTestPlans.first?.assetID, first.exactPlanProjectionKey)

        var second = first
        second.generatedTestPlanID = "00000000-0000-0000-0000-0000000002c0"
        second.generatedTestPlanSHA256 = String(repeating: "2", count: 64)
        second.generatedTestSourceBindingSHA256 = String(repeating: "3", count: 64)
        second.planningTaskID = "00000000-0000-0000-0000-0000000002c1"
        var secondEvent = event(
            workspaceID: fixture.workspaceID,
            taskID: UUID(uuidString: second.planningTaskID!)!,
            payload: second.eventPayload
        )
        secondEvent.sequence = 3

        let distinctPlans = AgentConversationAssetProjector.project(
            workspaceID: fixture.workspaceID,
            events: [duplicateReady, duplicateCompleted, secondEvent]
        )
        XCTAssertEqual(distinctPlans.generatedTestPlans.count, 2)
        XCTAssertEqual(distinctPlans.generatedTestPlans[0].generatedTestPlanID, first.generatedTestPlanID)
        XCTAssertEqual(distinctPlans.generatedTestPlans[0].generatedTestPlanRevision, first.generatedTestPlanRevision)
        XCTAssertEqual(distinctPlans.generatedTestPlans[0].generatedTestPlanSHA256, first.generatedTestPlanSHA256)
        XCTAssertEqual(distinctPlans.generatedTestPlans[1].generatedTestPlanID, second.generatedTestPlanID)
        XCTAssertEqual(distinctPlans.generatedTestPlans[1].generatedTestPlanRevision, second.generatedTestPlanRevision)
        XCTAssertEqual(distinctPlans.generatedTestPlans[1].generatedTestPlanSHA256, second.generatedTestPlanSHA256)
        XCTAssertEqual(Set(distinctPlans.generatedTestPlans.map(\.assetID)).count, 2)
        XCTAssertEqual(
            AgentConversationAssetProjector.project(
                workspaceID: fixture.workspaceID,
                events: [duplicateReady, duplicateCompleted, secondEvent]
            ),
            distinctPlans
        )
    }

    func testExactPlanCardEligibilityDisablesRestartedExistingAndInFlightActions() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        _ = try fixture.authorizedManifest()
        let plan = try fixture.planGeneratedTests().plan
        let snapshot = GeneratedTestActivitySnapshot(plan: plan)

        XCTAssertEqual(snapshot.generationEligibility(
            persistedPlan: plan,
            workspaceID: fixture.workspaceID,
            authenticatedLocalSessionID: fixture.userSessionID,
            appSessionID: fixture.appSessionID,
            hasExistingArtifact: false,
            isInFlight: false
        ), .available)
        let context = try XCTUnwrap(snapshot.exactGenerationContext(
            for: plan,
            workspaceID: fixture.workspaceID,
            authenticatedLocalSessionID: fixture.userSessionID,
            appSessionID: fixture.appSessionID
        ))
        XCTAssertEqual(context.generatedTestPlanID, plan.planID)
        XCTAssertEqual(context.generatedTestPlanRevision, plan.revision)
        XCTAssertEqual(context.generatedTestPlanSHA256, plan.planSHA256)
        XCTAssertEqual(context.candidatePatchID, plan.sourceBinding.patchID)
        XCTAssertEqual(context.candidatePatchArtifactSHA256, plan.sourceBinding.candidatePatchArtifactSHA256)

        let restarted = snapshot.generationEligibility(
            persistedPlan: plan,
            workspaceID: fixture.workspaceID,
            authenticatedLocalSessionID: fixture.userSessionID,
            appSessionID: UUID(),
            hasExistingArtifact: false,
            isInFlight: false
        )
        XCTAssertFalse(restarted.isAvailable)
        XCTAssertTrue(restarted.unavailableReason?.contains("previous app session") == true)
        XCTAssertFalse(snapshot.generationEligibility(
            persistedPlan: plan,
            workspaceID: fixture.workspaceID,
            authenticatedLocalSessionID: fixture.userSessionID,
            appSessionID: fixture.appSessionID,
            hasExistingArtifact: true,
            isInFlight: false
        ).isAvailable)
        XCTAssertFalse(snapshot.generationEligibility(
            persistedPlan: plan,
            workspaceID: fixture.workspaceID,
            authenticatedLocalSessionID: fixture.userSessionID,
            appSessionID: fixture.appSessionID,
            hasExistingArtifact: false,
            isInFlight: true
        ).isAvailable)

        var staleDigest = snapshot
        staleDigest.generatedTestPlanSHA256 = String(repeating: "0", count: 64)
        XCTAssertNil(staleDigest.exactGenerationContext(
            for: plan,
            workspaceID: fixture.workspaceID,
            authenticatedLocalSessionID: fixture.userSessionID,
            appSessionID: fixture.appSessionID
        ))
    }

    func testExactActionBindingRejectsMissingTruncatedAndTamperedAuthority() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let snapshot = CandidatePatchActivitySnapshot(manifest: manifest)
        let sourceBinding = try XCTUnwrap(snapshot.exactGeneratedTestSourceBinding)
        let context = GeneratedTestPlanningContext(
            sourceBinding: sourceBinding,
            appSessionID: fixture.appSessionID
        )
        XCTAssertEqual(context.sourceBinding, sourceBinding)
        XCTAssertEqual(context.patchID.rawValue, snapshot.patchID)

        var missing = snapshot
        missing.generatedTestSourceBinding = nil
        XCTAssertNil(missing.exactGeneratedTestSourceBinding)
        XCTAssertEqual(
            missing.generatedTestActionUnavailableReason,
            "The exact persisted Candidate Patch binding could not be restored."
        )

        var truncated = snapshot
        truncated.patchID = snapshot.patchID.map { String($0.prefix(12)) + "…" }
        XCTAssertNil(truncated.exactGeneratedTestSourceBinding)

        var tampered = sourceBinding
        tampered.candidatePatchPlanID = UUID()
        assertGeneratedFailure(.sourceBindingMismatch) {
            _ = try GeneratedTestPlanningService(lifecycle: fixture.lifecycle).preparePlan(
                GeneratedTestPlanningRequest(
                    workspaceID: fixture.workspaceID,
                    planningTaskID: fixture.planningTaskID,
                    sourceContext: GeneratedTestPlanningContext(
                        sourceBinding: tampered,
                        appSessionID: fixture.appSessionID
                    )
                )
            )
        }
    }

    func testMultipleCandidatePatchAssetsRemainExactlyIsolated() throws {
        let fixture = try makeFixture(environment: .vitest)
        defer { fixture.cleanup() }
        let manifest = try fixture.authorizedManifest()
        let first = CandidatePatchActivitySnapshot(manifest: manifest)
        var second = first
        var secondBinding = try XCTUnwrap(first.generatedTestSourceBinding)
        secondBinding.sourceCandidatePatchTaskID = UUID()
        secondBinding.patchID = CandidatePatchID()
        secondBinding.candidatePatchPlanID = UUID()
        secondBinding.candidatePatchManifestID = "candidate-patch-manifest:second"
        secondBinding.sandboxID = SandboxID()
        second.sourceCandidatePatchTaskID = secondBinding.sourceCandidatePatchTaskID.uuidString
        second.patchID = secondBinding.patchID.rawValue
        second.planID = secondBinding.candidatePatchPlanID.uuidString
        second.manifestID = secondBinding.candidatePatchManifestID
        second.sandboxID = secondBinding.sandboxID.rawValue
        second.generatedTestSourceBinding = secondBinding

        let firstEvent = event(
            workspaceID: fixture.workspaceID,
            taskID: fixture.sourceTaskID,
            payload: first.eventPayload
        )
        var secondEvent = event(
            workspaceID: fixture.workspaceID,
            taskID: secondBinding.sourceCandidatePatchTaskID,
            payload: second.eventPayload
        )
        secondEvent.sequence = 2
        let projection = AgentConversationAssetProjector.project(
            workspaceID: fixture.workspaceID,
            events: [firstEvent, secondEvent]
        )

        XCTAssertEqual(projection.candidatePatches.count, 2)
        let bindings = try projection.candidatePatches.map {
            try XCTUnwrap($0.exactGeneratedTestSourceBinding)
        }
        XCTAssertEqual(Set(bindings.map(\.patchID)).count, 2)
        XCTAssertEqual(Set(bindings.map(\.sourceCandidatePatchTaskID)).count, 2)
        XCTAssertEqual(bindings.first { $0.patchID == manifest.patchID }?.sourceCandidatePatchTaskID, fixture.sourceTaskID)
    }

    func testPhase2D2AcceptanceMatrixCoversAllRequiredCases() {
        let cases = Phase2D2AcceptanceBenchmark().runAll()
        XCTAssertEqual(cases.count, 33)
        XCTAssertEqual(Set(cases.map(\.caseID)), Set(Phase2D2AcceptanceCaseID.allCases))
        XCTAssertTrue(cases.allSatisfy { !$0.expectedInvariant.isEmpty && !$0.testMethod.isEmpty })
    }
}

private extension GeneratedTestPlanningTests {
    enum EnvironmentFixture {
        case vitest
        case languageOnly
        case conflictingFrameworks
        case unknownLocation
    }

    struct Fixture {
        var container: URL
        var legacy: URL
        var lifecycle: SandboxLifecycleService
        var sandboxID: SandboxID
        var sourceSnapshotID: String
        var sourceHash: String
        var workspaceID: UUID
        var sourceTaskID: UUID
        var planningTaskID: UUID
        var userSessionID: UUID
        var appSessionID: UUID
        var sourceRelativePath: String
        var sourcePostimage: String

        func cleanup() { try? FileManager.default.removeItem(at: container) }

        func workspaceURL() throws -> URL {
            try SandboxPathResolver(storageRoot: lifecycle.storageRoot)
                .resolve(sandboxID: sandboxID, relativePath: ".")
        }

        func authorizedManifest() throws -> CandidatePatchManifest {
            let claimID = "claim-orders-read-boundary"
            let assessmentID = "phase-2c-generated-test-fixture"
            let validationPlan = CandidatePatchValidationTestPlan(
                assessmentID: assessmentID,
                items: [CandidatePatchValidationTestItem(
                    validationItemID: "validation-order-read-contract",
                    title: "Order read contract",
                    purpose: "Verify the assessment-backed order read behavior.",
                    expectedBehavior: "The changed listOrders symbol returns the grounded order values.",
                    relatedRequirementIDs: ["record_level_authorization"],
                    relatedBlockerIDs: ["blocker-order-read-boundary"],
                    relatedEvidenceClaimIDs: [claimID],
                    suggestedTestLevel: .contract,
                    runtimeVerificationStatus: .notVerified,
                    required: true
                )],
                executionAuthorized: false
            )
            let evidence = CandidatePatchEvidence(
                claimID: claimID,
                statement: "The inspected order module is the grounded Candidate Patch source boundary.",
                evidenceReferences: [AssessmentEvidenceReference(
                    source: .inspectedFile,
                    path: sourceRelativePath,
                    fact: "The order source was directly read during assessment.",
                    claimLevel: .sourceBehaviorConfirmed,
                    observationStatus: .directlyRead,
                    sourceComponent: "src",
                    safeEvidenceSummary: "The order source establishes the read boundary.",
                    workspaceSnapshotIdentifier: sourceSnapshotID
                )],
                confidence: .high,
                material: true
            )
            let context = CandidatePatchAssessmentContext(
                assessmentID: assessmentID,
                generatedAt: Date(timeIntervalSince1970: 1_000),
                sourceSnapshotID: sourceSnapshotID,
                canonicalLegacyRoot: legacy.standardizedFileURL.path,
                requestedCapabilityID: AIAgentCapabilityKind.customerSupportOrderLookup.rawValue,
                requestedCapabilityDisplayLabel: AIAgentCapabilityKind.customerSupportOrderLookup.displayName,
                compatibilityDecision: .yes,
                supportedCapabilities: ["api_service_layer"],
                blockers: ["blocker-order-read-boundary"],
                unresolvedRequirements: [],
                evidence: [evidence],
                validationTestPlan: validationPlan
            )
            let request = CandidatePatchPlanRequest(
                sandboxID: sandboxID,
                selectedLegacyRoot: legacy,
                trustedLegacyRoot: legacy,
                assessment: context,
                requestedCapabilityID: AIAgentCapabilityKind.customerSupportOrderLookup.rawValue,
                requestedOutcome: "Clarify the read-only order boundary in the isolated Sandbox.",
                proposedOperations: [CandidatePatchProposedOperation(
                    relativePath: sourceRelativePath,
                    operationType: .replaceTextFile,
                    proposedContent: sourcePostimage,
                    expectedPreimageSHA256: sourceHash,
                    purpose: "Introduce the assessment-backed listOrders symbol.",
                    evidenceClaimIDs: [claimID],
                    blockersAddressed: ["blocker-order-read-boundary"],
                    risk: .low,
                    impact: "Changes only the isolated Candidate Patch source."
                )],
                approvedScope: ["src"],
                expectedBehavior: ["Expose a reviewable listOrders behavior."],
                validationRequiredLater: ["A later authorized phase may create and execute tests."],
                rollbackApproach: "Restore the recorded preimage.",
                unknowns: ["Runtime behavior is not verified."]
            )
            let service = CandidatePatchService(lifecycle: lifecycle)
            let plan = try service.preparePlan(request)
            let approvalID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
            _ = try service.recordApprovalRequest(
                sandboxID: sandboxID,
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
                sourceSnapshotID: sourceSnapshotID,
                canonicalLegacyRoot: legacy.standardizedFileURL.path,
                authenticatedUserSessionID: userSessionID,
                appSessionID: appSessionID,
                confirmationStepID: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
                timestamp: Date(timeIntervalSince1970: 1_200),
                controllerPath: "GeneratedTestPlanningTests.exactApproval",
                uiAction: "confirm_exact_candidate_patch"
            )
            _ = try service.recordDecision(
                sandboxID: sandboxID,
                patchID: plan.patchID,
                decision: .approve,
                decidedBy: "fixture-reviewer",
                rationale: "Approve exact Candidate Patch fixture.",
                approvalRequestID: approvalID,
                approvalProvenance: provenance,
                now: Date(timeIntervalSince1970: 1_200)
            )
            return try service.apply(
                sandboxID: sandboxID,
                patchID: plan.patchID,
                now: Date(timeIntervalSince1970: 1_300)
            ).manifest
        }

        func planGeneratedTests(
            patchID: CandidatePatchID? = nil,
            sandboxID: SandboxID? = nil,
            sourceTaskID: UUID? = nil,
            sourceBinding persistedSourceBinding: CandidatePatchGeneratedTestSourceBinding? = nil
        ) throws -> GeneratedTestPlanningResult {
            guard let manifest = try CandidatePatchManifestStore(lifecycle: lifecycle).loadAll().first,
                  var sourceBinding = persistedSourceBinding
                    ?? CandidatePatchGeneratedTestSourceBinding(manifest: manifest) else {
                throw GeneratedTestError.blocked(.sourceBindingMismatch)
            }
            sourceBinding.patchID = patchID ?? sourceBinding.patchID
            sourceBinding.sandboxID = sandboxID ?? sourceBinding.sandboxID
            sourceBinding.sourceCandidatePatchTaskID = sourceTaskID ?? sourceBinding.sourceCandidatePatchTaskID
            return try GeneratedTestPlanningService(lifecycle: lifecycle).preparePlan(
                GeneratedTestPlanningRequest(
                    workspaceID: workspaceID,
                    planningTaskID: planningTaskID,
                    sourceContext: GeneratedTestPlanningContext(
                        sourceBinding: sourceBinding,
                        appSessionID: appSessionID
                    )
                ),
                now: Date(timeIntervalSince1970: 1_400)
            )
        }
    }

    func makeFixture(
        environment: EnvironmentFixture,
        legacyOverride: URL? = nil
    ) throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEGeneratedTestPlanning-\(UUID().uuidString)", isDirectory: true)
        let managed = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
        let legacy: URL
        let sourceRelativePath = "src/orders.ts"
        let sourcePostimage = "export function listOrders(): string[] { return ['a', 'b'] }\n"
        if let legacyOverride {
            legacy = legacyOverride
        } else {
            legacy = container.appendingPathComponent("Legacy", isDirectory: true)
            try FileManager.default.createDirectory(
                at: legacy.appendingPathComponent("src", isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("export const orders = ['a']\n".utf8)
                .write(to: legacy.appendingPathComponent(sourceRelativePath))
            switch environment {
            case .vitest:
                try writePackageJSON(to: legacy, dependencies: ["vitest"], testScript: "vitest run")
                try writeTest(to: legacy, text: "import { describe, it, expect } from 'vitest'\n")
            case .conflictingFrameworks:
                try writePackageJSON(to: legacy, dependencies: ["vitest", "jest"], testScript: "vitest run")
                try writeTest(to: legacy, text: "import { describe, it } from 'vitest'\njest.mock('orders')\n")
            case .unknownLocation:
                try writePackageJSON(to: legacy, dependencies: ["vitest"], testScript: "vitest run")
            case .languageOnly:
                break
            }
        }
        let lifecycle = SandboxLifecycleService(storageRoot: managed)
        let inspection = try lifecycle.createSandbox(sourceRoot: legacy, approvedLegacyRoot: legacy)
        let sourceRecord = try XCTUnwrap(
            inspection.sourceManifest.files.first { $0.relativeCanonicalPath == sourceRelativePath }
        )
        return Fixture(
            container: container,
            legacy: legacy,
            lifecycle: lifecycle,
            sandboxID: inspection.descriptor.sandboxID,
            sourceSnapshotID: inspection.sourceManifest.snapshotID,
            sourceHash: sourceRecord.sha256,
            workspaceID: UUID(),
            sourceTaskID: UUID(),
            planningTaskID: UUID(),
            userSessionID: UUID(),
            appSessionID: UUID(),
            sourceRelativePath: sourceRelativePath,
            sourcePostimage: sourcePostimage
        )
    }

    func writePackageJSON(to root: URL, dependencies: [String], testScript: String) throws {
        let dependencyLines = dependencies.sorted().map { "\"\($0)\": \"1.0.0\"" }.joined(separator: ",")
        let text = "{\"scripts\":{\"test\":\"\(testScript)\"},\"devDependencies\":{\(dependencyLines)}}\n"
        try Data(text.utf8).write(to: root.appendingPathComponent("package.json"))
    }

    func writeTest(to root: URL, text: String) throws {
        let tests = root.appendingPathComponent("tests", isDirectory: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: tests.appendingPathComponent("orders.test.ts"))
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

    func completedTask(id: UUID, workspaceID: UUID) -> FDETask {
        FDETask(
            id: id,
            workspaceID: workspaceID,
            title: "Completed Candidate Patch source",
            rawInput: "generate a candidate patch",
            state: .completed,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 1,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    func event(
        workspaceID: UUID,
        taskID: UUID,
        payload: [String: String]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: .stateUpdated,
            sequence: 1,
            timestamp: Date(),
            summary: "Generated Test projection",
            payload: payload
        )
    }
}
