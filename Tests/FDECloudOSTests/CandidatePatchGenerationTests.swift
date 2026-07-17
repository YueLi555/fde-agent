import CryptoKit
import XCTest
@testable import FDECloudOS

final class CandidatePatchGenerationTests: XCTestCase {
    func testChineseAndEnglishRequestsRouteToDedicatedCandidatePatchMission() {
        let inputs = [
            "为当前 Legacy 生成候选修改",
            "在安全 Sandbox 中实现建议方案",
            "根据接入评估生成 Candidate Patch",
            "generate a candidate patch in the Safe Sandbox",
            "implement the proposed integration in an isolated sandbox"
        ]
        for input in inputs {
            let intent = MissionIntentParser().parse(input)
            XCTAssertEqual(intent.intentType, .candidatePatchGeneration, input)
            XCTAssertEqual(MissionExecutionSemantic(intent: intent), .candidatePatchGeneration, input)
            XCTAssertTrue(intent.constraints.contains(.requiresApproval), input)
            XCTAssertTrue(intent.constraints.contains(.allowFileEdits), input)
            XCTAssertFalse(intent.constraints.contains(.runVerification), input)
            XCTAssertTrue(intent.expectedOutputs.contains(.candidatePatchReview), input)
            XCTAssertEqual(
                AgentMissionClassifier().conversationMode(
                    for: input,
                    intent: intent,
                    hasActiveRuntimeTask: false
                ),
                .executableEngineeringTask,
                input
            )
        }
    }

    func testPhase2D1RuntimePolicyExposesOnlyStructuredCandidateTextOperations() {
        XCTAssertTrue(SandboxRuntimePolicy.phase2D0Allowlist.isEmpty)
        XCTAssertEqual(SandboxRuntimePolicy.phase2D1Allowlist, [
            .candidatePatchReadText,
            .candidatePatchCreateText,
            .candidatePatchReplaceText,
            .candidatePatchRevert
        ])
        XCTAssertFalse(SandboxRuntimePolicy.phase2D1Allowlist.contains(.candidatePatch))
        XCTAssertFalse(SandboxRuntimePolicy.phase2D1Allowlist.contains(.generatedTest))
        XCTAssertFalse(SandboxRuntimePolicy.phase2D1Allowlist.contains(.productFileMutation))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("shell execution"))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("Git operations"))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("build or test execution"))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("deployment"))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("credential access"))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("production access"))
        let benchmark = Phase2D1AcceptanceBenchmark().runAll()
        XCTAssertEqual(benchmark.count, 35)
        XCTAssertEqual(Set(benchmark.map(\.caseID)), Set(Phase2D1AcceptanceCaseID.allCases))
        XCTAssertTrue(benchmark.allSatisfy { !$0.expectedInvariant.isEmpty && !$0.testMethod.isEmpty })
    }

    func testLegacyAgentNonReadyStaleAndMissingAssessmentPreconditionsFailClosed() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)

        assertFailure(.workspaceNotSelected) {
            var request = try fixture.modifyRequest()
            request.selectedLegacyRoot = nil
            _ = try service.preparePlan(request)
        }
        assertFailure(.agentWorkspaceRejected) {
            var request = try fixture.modifyRequest()
            request.selectedLegacyRoot = fixture.agent
            request.trustedLegacyRoot = fixture.agent
            _ = try service.preparePlan(request)
        }
        assertFailure(.assessmentMissing) {
            var request = try fixture.modifyRequest()
            request.assessment = nil
            _ = try service.preparePlan(request)
        }
        assertFailure(.assessmentEvidenceMissing) {
            var request = try fixture.modifyRequest()
            request.assessment?.evidence[0].evidenceReferences = []
            _ = try service.preparePlan(request)
        }

        var nonReady = try makeFixture(createReadySandbox: false)
        defer { nonReady.cleanup() }
        let nonReadyPlan = try CandidatePatchService(lifecycle: nonReady.lifecycle)
            .preparePlan(try nonReady.modifyRequest())
        XCTAssertEqual(nonReadyPlan.status, .awaitingApproval)

        try Data("export const drift = true\n".utf8)
            .write(to: fixture.legacy.appendingPathComponent("src/drift.ts"))
        assertFailure(.assessmentStale) {
            _ = try service.preparePlan(try fixture.modifyRequest())
        }
    }

    func testNoSandboxWorkspaceMutationBeforeApprovalAndRejectProducesZeroChanges() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let sandboxBefore = try fixture.sandboxWorkspaceSnapshot()
        let legacyBefore = try fixture.legacyIntegrity()
        let plan = try service.preparePlan(try fixture.modifyRequest())

        XCTAssertEqual(plan.status, .awaitingApproval)
        XCTAssertEqual(try fixture.sandboxWorkspaceSnapshot().snapshotID, sandboxBefore.snapshotID)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        assertFailure(.humanApprovalMissing) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }

        let rejected = try service.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .reject,
            decidedBy: "reviewer",
            rationale: "Do not apply this plan."
        )
        XCTAssertEqual(rejected.status, .rejected)
        XCTAssertEqual(try fixture.sandboxWorkspaceSnapshot().snapshotID, sandboxBefore.snapshotID)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
    }

    func testValidatedRemediableNoGeneratesPlanWithoutAnySandboxAndKeepsDiffAbsent() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let sandboxDirectory = fixture.lifecycle.storageRoot
            .appendingPathComponent(fixture.sandboxID.rawValue, isDirectory: true)
        try FileManager.default.removeItem(at: sandboxDirectory)
        let legacyBefore = try fixture.legacyIntegrity()
        var request = try fixture.modifyRequest()
        request.assessment?.compatibilityDecision = .no
        request.assessment?.blockers = [
            "record_level_authorization:Record Level Authorization is blocked.",
            "sensitive_response_field_controls:Sensitive Response Field Controls is blocked."
        ]
        request.proposedOperations[0].blockersAddressed = request.assessment?.blockers ?? []

        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try service.preparePlan(request)
        let manifest = try service.loadManifest(sandboxID: fixture.sandboxID, patchID: plan.patchID)

        XCTAssertEqual(plan.status, .awaitingApproval)
        XCTAssertEqual(plan.compatibilityDecision, .no)
        XCTAssertEqual(plan.blockersAddressed, request.assessment?.blockers.sorted())
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandboxDirectory.path))
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        XCTAssertNil(manifest.unifiedDiff)
        XCTAssertTrue(plan.markdown.contains("Record Level Authorization"))
        XCTAssertTrue(plan.markdown.contains("Sensitive Response Field Controls"))
        XCTAssertTrue(plan.markdown.contains("No patch bytes or Unified Diff exist"))
    }

    func testUngroundedOrUnboundedNoAndAssessmentMismatchesRemainIneligible() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)

        assertFailure(.assessmentVerdictNotEligible) {
            var request = try fixture.modifyRequest()
            request.assessment?.compatibilityDecision = .no
            request.assessment?.blockers = []
            _ = try service.preparePlan(request)
        }
        assertFailure(.assessmentEvidenceMissing) {
            var request = try fixture.modifyRequest()
            request.assessment?.compatibilityDecision = .no
            request.assessment?.blockers = ["record_level_authorization:blocked"]
            request.assessment?.evidence[0].evidenceReferences = []
            _ = try service.preparePlan(request)
        }
        assertFailure(.assessmentCapabilityMismatch) {
            var request = try fixture.modifyRequest()
            request.requestedCapabilityID = "different_capability"
            _ = try service.preparePlan(request)
        }
        assertFailure(.assessmentStale) {
            var request = try fixture.modifyRequest()
            request.assessment?.sourceSnapshotID = "stale-snapshot"
            _ = try service.preparePlan(request)
        }
    }

    func testNativePlanningDefersSandboxReadinessUntilApprovalThenCreatesReservedSandbox() async throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        var request = try fixture.modifyRequest()
        request.sandboxID = SandboxID()
        let reservedSandbox = fixture.lifecycle.storageRoot
            .appendingPathComponent(request.sandboxID.rawValue, isDirectory: true)
        let legacyBefore = try fixture.legacyIntegrity()
        let workspace = Workspace(
            id: UUID(),
            name: "DeferredSandboxCandidatePatch",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle,
            candidatePatchPlanProvider: StaticCandidatePatchPlanRequestProvider(request: request),
            allowsCandidatePatchTestApproval: true
        )

        let task = try await kernel.runCandidatePatchGeneration(
            input: "Generate only the Candidate Patch plan and wait for approval.",
            workspace: workspace
        )
        XCTAssertEqual(task.state, .pendingApproval)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        let planningEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertFalse(planningEvents.contains {
            $0.payload["candidate_patch_activity_phase"] == CandidatePatchActivityPhase.checkingSandboxReadiness.rawValue
        })
        let awaiting = try XCTUnwrap(planningEvents.last { $0.type == .humanApprovalRequested })
        for key in [
            "legacy_writes", "sandbox_writes", "patch_files_created", "build_test_executions",
            "shell_calls", "git_operations", "deployment_operations"
        ] {
            XCTAssertEqual(awaiting.payload[key], "0", key)
        }
        XCTAssertEqual(awaiting.payload["unified_diff_exists"], "false")
        XCTAssertEqual(awaiting.payload["sandbox_readiness_checked"], "false")

        let pendingApprovals = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: .pending
        )
        let approval = try XCTUnwrap(pendingApprovals.first)
        _ = try await kernel.approveCandidatePatchForTest(
            approval.id,
            workspace: workspace,
            reason: "Approve the exact plan for isolated Sandbox application."
        )
        let inspection = try fixture.lifecycle.inspectSandbox(request.sandboxID)
        XCTAssertEqual(inspection.manifest.status, .ready)
        XCTAssertEqual(inspection.manifest.integrity.status, .passed)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        let completedEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertTrue(completedEvents.contains {
            $0.payload["candidate_patch_activity_phase"] == CandidatePatchActivityPhase.checkingSandboxReadiness.rawValue
        })
    }

    func testPostApprovalSandboxValidationFailureFailsClosedAndPreservesApprovalEvidence() async throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        var request = try fixture.modifyRequest()
        request.sandboxID = SandboxID()
        _ = try fixture.lifecycle.prepareSandbox(
            sourceRoot: fixture.legacy,
            approvedLegacyRoot: fixture.legacy,
            sandboxID: request.sandboxID
        )
        let reservedWorkspace = try Self.workspaceURL(
            lifecycle: fixture.lifecycle,
            sandboxID: request.sandboxID
        )
        try Data("must fail validation\n".utf8).write(
            to: reservedWorkspace.appendingPathComponent(".env")
        )
        let sandboxBeforePlanning = try SourceSnapshotBuilder().build(root: reservedWorkspace)
        let legacyBefore = try fixture.legacyIntegrity()
        let workspace = Workspace(
            id: UUID(),
            name: "FailClosedSandboxPreflight",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle,
            candidatePatchPlanProvider: StaticCandidatePatchPlanRequestProvider(request: request),
            allowsCandidatePatchTestApproval: true
        )
        let task = try await kernel.runCandidatePatchGeneration(
            input: "Generate only the Candidate Patch plan and wait for approval.",
            workspace: workspace
        )
        XCTAssertEqual(task.state, .pendingApproval)
        XCTAssertEqual(try SourceSnapshotBuilder().build(root: reservedWorkspace).snapshotID, sandboxBeforePlanning.snapshotID)
        let pendingApprovals = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: .pending
        )
        let approval = try XCTUnwrap(pendingApprovals.first)

        await assertAsyncFailure {
            _ = try await kernel.approveCandidatePatchForTest(
                approval.id,
                workspace: workspace,
                reason: "Approve exact plan; Sandbox validation must still fail closed."
            )
        }

        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        let preservedApproval = try await persistence.loadApprovalRequest(id: approval.id)
        XCTAssertEqual(preservedApproval?.state, .approved)
        let tasks = try await persistence.loadTasks(workspaceID: workspace.id)
        let failedTask = try XCTUnwrap(tasks.first { $0.id == task.id })
        XCTAssertEqual(failedTask.state, .failed)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertEqual(
            events.last { $0.summary == "Approved Candidate Patch failed closed" }?.payload["failure_category"],
            CandidatePatchFailureCode.sandboxNotReady.rawValue
        )
    }

    func testRequestChangesRequiresRevisedPlanAndFreshApproval() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let first = try service.preparePlan(try fixture.modifyRequest())
        let changeDecision = try service.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: first.patchID,
            decision: .requestChanges,
            decidedBy: "reviewer",
            rationale: "Use a narrower comment.",
            requestedChanges: ["Use a narrower comment."]
        )
        XCTAssertEqual(changeDecision.status, .planning)
        assertFailure(.humanApprovalMissing) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: first.patchID)
        }

        var revisionRequest = try fixture.modifyRequest()
        revisionRequest.patchID = first.patchID
        revisionRequest.proposedOperations[0].proposedContent = "export const orders = ['a', 'b'] // read-only candidate\n"
        let revised = try service.preparePlan(revisionRequest)
        XCTAssertEqual(revised.revision, 2)
        XCTAssertEqual(revised.status, .awaitingApproval)
        XCTAssertNil(revised.approvalRecord)
        assertFailure(.humanApprovalMissing) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: first.patchID)
        }
    }

    func testApprovedCreateAndModifyApplyOnlyInsideSandboxAndDiffUsesRelativeActualContent() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let legacyBefore = try fixture.legacyIntegrity()
        var request = try fixture.modifyRequest()
        request.proposedOperations.append(CandidatePatchProposedOperation(
            relativePath: "src/orderReadAdapter.ts",
            operationType: .createTextFile,
            proposedContent: "export const readOrder = (id: string) => ({ id })\n",
            purpose: "Add the assessment-backed read-only adapter boundary.",
            evidenceClaimIDs: [fixture.claimID],
            risk: .low,
            impact: "Adds a proposed read-only adapter without changing production Legacy."
        ))
        let plan = try service.preparePlan(request)
        _ = try service.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "reviewer",
            rationale: "Approved for isolated review."
        )
        let result = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)

        XCTAssertTrue(result.complete)
        XCTAssertEqual(result.manifest.status, .reviewReady)
        XCTAssertEqual(result.appliedOperations.count, 2)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        XCTAssertEqual(
            try String(contentsOf: fixture.legacy.appendingPathComponent("src/orders.ts"), encoding: .utf8),
            fixture.originalOrders
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.legacy.appendingPathComponent("src/orderReadAdapter.ts").path
        ))
        let diff = try XCTUnwrap(result.manifest.unifiedDiff)
        XCTAssertTrue(diff.contains("--- a/src/orders.ts"))
        XCTAssertTrue(diff.contains("+++ b/src/orders.ts"))
        XCTAssertTrue(diff.contains("--- /dev/null"))
        XCTAssertTrue(diff.contains("+++ b/src/orderReadAdapter.ts"))
        XCTAssertTrue(diff.contains("+export const readOrder"))
        XCTAssertFalse(diff.contains(fixture.container.path))
        XCTAssertFalse(diff.contains(fixture.legacy.path))
        let review = try service.reviewSummary(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        XCTAssertFalse(review.buildOrTestExecuted)
        XCTAssertFalse(review.gitOrDeploymentActionOccurred)
        XCTAssertTrue(review.markdown.contains("Build, test, runtime, and deployment behavior remain unverified."))
    }

    func testAbsoluteTraversalMetadataCredentialAndGeneratedTestPathsAreRejected() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let cases: [(String, CandidatePatchFailureCode)] = [
            ("/tmp/escape.ts", .absolutePathRejected),
            ("../escape.ts", .traversalRejected),
            ("src/../escape.ts", .traversalRejected),
            (".fde-sandbox-metadata/patch.ts", .sandboxMetadataPathRejected),
            ("sandbox-manifest.json", .sandboxMetadataPathRejected),
            (".git/config", .sandboxMetadataPathRejected),
            (".env", .sensitivePathRejected),
            ("config/credentials.json", .sensitivePathRejected),
            ("Tests/GeneratedTests.swift", .generatedTestUnavailable),
            ("src/orders.test.ts", .generatedTestUnavailable)
        ]
        for (path, expected) in cases {
            assertFailure(expected, file: #filePath, line: #line) {
                var request = try fixture.createRequest(path: path)
                request.approvedScope = ["."]
                _ = try service.preparePlan(request)
            }
        }
    }

    func testScopeSymlinkHardLinkAndBinaryTargetsFailClosed() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        assertFailure(.scopeNotApproved) {
            var request = try fixture.createRequest(path: "docs/adapter.ts")
            request.approvedScope = ["src"]
            _ = try service.preparePlan(request)
        }

        let workspace = try fixture.workspaceURL()
        let outside = fixture.container.appendingPathComponent("outside.ts")
        try Data("outside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("src/link.ts"),
            withDestinationURL: outside
        )
        assertFailure(.targetMissing) {
            let request = try fixture.modifyRequest(path: "src/link.ts", expectedHash: "irrelevant")
            _ = try service.preparePlan(request)
        }

        let hard = workspace.appendingPathComponent("src/hard.ts")
        try FileManager.default.linkItem(
            at: workspace.appendingPathComponent("src/orders.ts"),
            to: hard
        )
        assertFailure(.targetMissing) {
            let request = try fixture.modifyRequest(path: "src/hard.ts", expectedHash: fixture.ordersHash)
            _ = try service.preparePlan(request)
        }

        let binary = workspace.appendingPathComponent("src/blob.bin")
        try Data([0xff, 0x00, 0x01]).write(to: binary)
        assertFailure(.targetMissing) {
            let request = try fixture.modifyRequest(path: "src/blob.bin", expectedHash: "irrelevant")
            _ = try service.preparePlan(request)
        }
    }

    func testDescriptorAnchoredCreateRejectsParentSymlinkRaceAndPreservesOutsideLegacyAndAudit() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let workspace = try fixture.workspaceURL()
        let outsideDirectory = fixture.container.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let sentinel = outsideDirectory.appendingPathComponent("sentinel.ts")
        let sentinelContent = "outside sentinel remains unchanged\n"
        try Data(sentinelContent.utf8).write(to: sentinel)
        let legacyBefore = try fixture.legacyIntegrity()

        var request = try fixture.createRequest(path: "src/race-create.ts")
        request.approvedScope = ["src"]
        let planningService = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try planningService.preparePlan(request)
        _ = try planningService.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "security-test",
            rationale: "Exercise descriptor anchoring."
        )

        let originalParent = workspace.appendingPathComponent("src", isDirectory: true)
        let displacedParent = workspace.appendingPathComponent("src-displaced", isDirectory: true)
        let service = CandidatePatchService(
            lifecycle: fixture.lifecycle,
            mutationInterlock: { point, path in
                guard point == .beforeMutation, path == "src/race-create.ts" else { return }
                try FileManager.default.moveItem(at: originalParent, to: displacedParent)
                try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: outsideDirectory)
            }
        )
        assertFailure(.pathContainmentFailed) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), sentinelContent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsideDirectory.appendingPathComponent("race-create.ts").path))
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        let failed = try service.loadManifest(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        XCTAssertTrue(failed.auditEvents.contains { $0.type == .operationFailed })
        XCTAssertTrue(failed.auditEvents.contains { $0.type == .approvalRecorded })
    }

    func testDescriptorAnchoredReplaceRejectsParentSymlinkRaceWithoutTouchingOutside() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let workspace = try fixture.workspaceURL()
        let outsideDirectory = fixture.container.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideOrders = outsideDirectory.appendingPathComponent("orders.ts")
        let outsideContent = "outside order data\n"
        try Data(outsideContent.utf8).write(to: outsideOrders)
        let legacyBefore = try fixture.legacyIntegrity()
        let planningService = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try planningService.preparePlan(try fixture.modifyRequest())
        _ = try planningService.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "security-test",
            rationale: "Exercise descriptor anchoring."
        )

        let originalParent = workspace.appendingPathComponent("src", isDirectory: true)
        let displacedParent = workspace.appendingPathComponent("src-displaced", isDirectory: true)
        let service = CandidatePatchService(
            lifecycle: fixture.lifecycle,
            mutationInterlock: { point, path in
                guard point == .beforeMutation, path == "src/orders.ts" else { return }
                try FileManager.default.moveItem(at: originalParent, to: displacedParent)
                try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: outsideDirectory)
            }
        )
        assertFailure(.pathContainmentFailed) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }

        XCTAssertEqual(try String(contentsOf: outsideOrders, encoding: .utf8), outsideContent)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        XCTAssertEqual(
            try String(contentsOf: displacedParent.appendingPathComponent("orders.ts"), encoding: .utf8),
            fixture.originalOrders
        )
    }

    func testDescriptorAnchoredNestedTraversalRejectsDirectoryInodeReplacement() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let workspace = try fixture.workspaceURL()
        let nested = workspace.appendingPathComponent("src/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let planningService = CandidatePatchService(lifecycle: fixture.lifecycle)
        var request = try fixture.createRequest(path: "src/nested/adapter.ts")
        request.approvedScope = ["src/nested"]
        let plan = try planningService.preparePlan(request)
        _ = try planningService.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "security-test",
            rationale: "Exercise nested descriptor traversal."
        )

        let displaced = workspace.appendingPathComponent("src/nested-displaced", isDirectory: true)
        let service = CandidatePatchService(
            lifecycle: fixture.lifecycle,
            mutationInterlock: { point, path in
                guard point == .beforeMutation, path == "src/nested/adapter.ts" else { return }
                try FileManager.default.moveItem(at: nested, to: displaced)
                try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            }
        )
        assertFailure(.pathContainmentFailed) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nested.appendingPathComponent("adapter.ts").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: displaced.appendingPathComponent("adapter.ts").path))
    }

    func testDescriptorAnchoredAtomicReplaceRejectsFinalComponentSymlinkRace() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let workspace = try fixture.workspaceURL()
        let target = workspace.appendingPathComponent("src/orders.ts")
        let outside = fixture.container.appendingPathComponent("outside-orders.ts")
        let outsideContent = "outside final-component sentinel\n"
        try Data(outsideContent.utf8).write(to: outside)
        let planningService = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try planningService.preparePlan(try fixture.modifyRequest())
        _ = try planningService.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "security-test",
            rationale: "Exercise final-component race handling."
        )

        let service = CandidatePatchService(
            lifecycle: fixture.lifecycle,
            mutationInterlock: { point, path in
                guard point == .beforeAtomicRename, path == "src/orders.ts" else { return }
                try FileManager.default.removeItem(at: target)
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
            }
        )
        assertFailure(.pathContainmentFailed) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), outsideContent)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: target.path),
            outside.path
        )
    }

    func testDescriptorAnchoredRevertRejectsParentSymlinkRaceAndPreservesAppliedAudit() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let workspace = try fixture.workspaceURL()
        let outsideDirectory = fixture.container.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideOrders = outsideDirectory.appendingPathComponent("orders.ts")
        let outsideContent = "outside revert sentinel\n"
        try Data(outsideContent.utf8).write(to: outsideOrders)
        let legacyBefore = try fixture.legacyIntegrity()
        let planningService = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try planningService.preparePlan(try fixture.modifyRequest())
        _ = try planningService.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "security-test",
            rationale: "Apply before exercising revert anchoring."
        )
        _ = try planningService.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)

        let originalParent = workspace.appendingPathComponent("src", isDirectory: true)
        let displacedParent = workspace.appendingPathComponent("src-displaced", isDirectory: true)
        let service = CandidatePatchService(
            lifecycle: fixture.lifecycle,
            mutationInterlock: { point, path in
                guard point == .beforeMutation, path == "src/orders.ts" else { return }
                try FileManager.default.moveItem(at: originalParent, to: displacedParent)
                try FileManager.default.createSymbolicLink(at: originalParent, withDestinationURL: outsideDirectory)
            }
        )
        assertFailure(.pathContainmentFailed) {
            _ = try service.revert(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }

        XCTAssertEqual(try String(contentsOf: outsideOrders, encoding: .utf8), outsideContent)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        let failed = try service.loadManifest(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        XCTAssertTrue(failed.auditEvents.contains { $0.type == .operationApplied })
        XCTAssertTrue(failed.auditEvents.contains { $0.type == .reviewPrepared })
    }

    func testPreimageMismatchAndUnexpectedConcurrentSandboxChangeMarkPatchStaleWithoutBlindOverwrite() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try service.preparePlan(try fixture.modifyRequest())
        _ = try service.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "reviewer",
            rationale: "Approved."
        )
        let target = try fixture.workspaceURL().appendingPathComponent("src/orders.ts")
        try Data("unexpected concurrent content\n".utf8).write(to: target)
        assertFailure(.sandboxPreimageChanged) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }
        let manifest = try service.loadManifest(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        XCTAssertEqual(manifest.status, .stale)
        XCTAssertNil(manifest.unifiedDiff)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unexpected concurrent content\n")
    }

    func testSourceDriftStopsApprovedPatchAndOriginalIsNeverRepaired() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try service.preparePlan(try fixture.modifyRequest())
        _ = try service.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "reviewer",
            rationale: "Approved."
        )
        let legacyOrders = fixture.legacy.appendingPathComponent("src/orders.ts")
        try Data("source drift remains user-owned\n".utf8).write(to: legacyOrders)
        assertFailure(.sourceDrift) {
            _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        }
        XCTAssertEqual(try String(contentsOf: legacyOrders, encoding: .utf8), "source drift remains user-owned\n")
        XCTAssertEqual(
            try service.loadManifest(sandboxID: fixture.sandboxID, patchID: plan.patchID).status,
            .stale
        )
    }

    func testManifestRecordsEvidenceHashesApprovalImpactRiskAndAudit() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let plan = try service.preparePlan(try fixture.modifyRequest())
        XCTAssertEqual(plan.operations[0].expectedPreimageSHA256, fixture.ordersHash)
        XCTAssertEqual(plan.operations[0].evidenceClaimIDs, [fixture.claimID])
        XCTAssertFalse(plan.operations[0].purpose.isEmpty)
        XCTAssertFalse(plan.operations[0].impact.isEmpty)
        XCTAssertEqual(plan.operations[0].risk, .medium)
        XCTAssertNil(plan.operations[0].approvalRecord)
        _ = try service.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "reviewer",
            rationale: "Approved."
        )
        _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        let manifest = try service.loadManifest(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        XCTAssertNotNil(manifest.operations[0].resultingSHA256)
        XCTAssertEqual(manifest.operations[0].approvalRecord?.decision, .approve)
        XCTAssertTrue(manifest.auditEvents.contains { $0.type == .operationApplied })
        XCTAssertTrue(manifest.auditEvents.contains { $0.type == .diffGenerated })
        XCTAssertTrue(manifest.auditEvents.contains { $0.type == .reviewPrepared })
        XCTAssertTrue(manifest.auditEvents.allSatisfy { !$0.safeDetail.contains(fixture.legacy.path) })
    }

    func testRevertRestoresModifiedFilesRemovesOnlyPatchCreatedFilesAndPreservesAuditAndLegacy() throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        let legacyBefore = try fixture.legacyIntegrity()
        var request = try fixture.modifyRequest()
        request.proposedOperations.append(try fixture.createOperation(path: "src/orderReadAdapter.ts"))
        let plan = try service.preparePlan(request)
        _ = try service.recordDecision(
            sandboxID: fixture.sandboxID,
            patchID: plan.patchID,
            decision: .approve,
            decidedBy: "reviewer",
            rationale: "Approved."
        )
        _ = try service.apply(sandboxID: fixture.sandboxID, patchID: plan.patchID)
        let workspace = try fixture.workspaceURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/orderReadAdapter.ts").path))
        let reverted = try service.revert(sandboxID: fixture.sandboxID, patchID: plan.patchID)

        XCTAssertEqual(reverted.status, .reverted)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent("src/orders.ts"), encoding: .utf8),
            fixture.originalOrders
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("src/orderReadAdapter.ts").path))
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        XCTAssertTrue(reverted.auditEvents.contains { $0.type == .operationReverted })
        XCTAssertNotNil(reverted.unifiedDiff)
    }

    func testActivitySnapshotIsRecoverableAndLivePhaseReducesBeforeFinalization() {
        let patchID = CandidatePatchID()
        let sandboxID = SandboxID()
        let snapshot = CandidatePatchActivitySnapshot(
            patchID: patchID.rawValue,
            sandboxID: sandboxID.rawValue,
            status: .awaitingApproval,
            filesPlanned: 2,
            filesChanged: 0,
            additions: 0,
            deletions: 0,
            risk: .medium,
            evidenceCount: 3,
            sourceIntegrity: .unchanged,
            approvalState: nil
        )
        let event = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: UUID(),
            taskID: UUID(),
            type: .stateUpdated,
            sequence: 1,
            timestamp: Date(),
            summary: CandidatePatchActivityPhase.waitingForHumanApproval.rawValue,
            payload: snapshot.eventPayload.merging([
                "candidate_patch_activity_phase": CandidatePatchActivityPhase.waitingForHumanApproval.rawValue,
                "runtime_owned_activity": "true",
                "state": TaskState.pendingApproval.rawValue
            ]) { current, _ in current }
        )
        let activity = AgentConversationActivityReducer.reduce(
            .local(requestID: UUID(), dialogID: UUID(), scope: .engineeringTask),
            event: event
        )
        XCTAssertEqual(activity.kind, .waitingCandidatePatchApproval)
        XCTAssertEqual(activity.label, "Waiting for human approval…")
        XCTAssertEqual(activity.metadata.candidatePatch?.patchID, patchID.rawValue)
        XCTAssertEqual(activity.metadata.candidatePatch?.sandboxID, sandboxID.rawValue)
        XCTAssertEqual(activity.metadata.candidatePatch?.filesPlanned, 2)
    }

    func testNativeRuntimeRouteWaitsForApprovalThenProducesManifestBackedReviewWithoutTools() async throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let request = try fixture.modifyRequest()
        let workspace = Workspace(
            id: UUID(),
            name: "CandidatePatchRuntime",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle,
            candidatePatchPlanProvider: StaticCandidatePatchPlanRequestProvider(request: request),
            allowsCandidatePatchTestApproval: true
        )
        let input = "generate a candidate patch in the Safe Sandbox"
        var session = AgentSession(workspace: workspace, userGoal: input)
        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: workspace,
            session: &session,
            runtime: kernel
        )
        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.state, .pendingApproval)
        let beforeApproval = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertFalse(beforeApproval.contains { $0.type == .toolCalled })
        XCTAssertTrue(beforeApproval.contains {
            $0.type == .humanApprovalRequested
                && $0.payload["workspace_mutation_count"] == "0"
                && $0.payload["candidate_patch_id"] != nil
                && $0.payload["candidate_patch_sandbox_id"] == ""
        })
        XCTAssertEqual(
            try String(contentsOf: try fixture.workspaceURL().appendingPathComponent("src/orders.ts"), encoding: .utf8),
            fixture.originalOrders
        )

        let pendingApprovals = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: .pending
        )
        let approval = try XCTUnwrap(pendingApprovals.first)
        XCTAssertEqual(approval.targetKind, .candidatePatchPlan)
        XCTAssertEqual(approval.metadata["sandbox_id"], fixture.sandboxID.rawValue)
        XCTAssertNotNil(approval.metadata["sandbox_root"])
        let renderedPlan = try XCTUnwrap(approval.metadata["candidate_patch_plan_summary"])
        XCTAssertTrue(renderedPlan.contains(approval.id.uuidString))
        XCTAssertTrue(renderedPlan.contains(try XCTUnwrap(approval.metadata["plan_id"])))
        XCTAssertTrue(renderedPlan.contains("No patch bytes or Unified Diff exist"))
        _ = try await kernel.approveCandidatePatchForTest(
            approval.id,
            workspace: workspace,
            reason: "Approved for isolated Candidate Patch review."
        )

        let loadedTasks = try await persistence.loadTasks(workspaceID: workspace.id)
        let completedTask = try XCTUnwrap(loadedTasks.first { $0.id == task.id })
        XCTAssertEqual(completedTask.state, .completed)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        let phases = events.compactMap {
            $0.payload["candidate_patch_activity_phase"].flatMap(CandidatePatchActivityPhase.init(rawValue:))
        }
        XCTAssertTrue(phases.contains(.waitingForHumanApproval))
        XCTAssertTrue(phases.contains(.applyingChangeInIsolatedSandbox))
        XCTAssertTrue(phases.contains(.candidatePatchReady))
        let completed = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        XCTAssertEqual(completed.payload["manifest_backed"], "true")
        XCTAssertEqual(completed.payload["source_integrity"], SourceIntegrityState.unchanged.rawValue)
        XCTAssertEqual(completed.payload["build_or_test_executed"], "false")
        XCTAssertEqual(completed.payload["git_or_deployment_action_occurred"], "false")
        XCTAssertEqual(completed.payload["generated_tests_available"], "false")
        XCTAssertTrue(completed.payload["detail"]?.contains("Candidate Patch Review") == true)
    }

    func testNativeRequestChangesSupersedesOldApprovalCreatesFreshVersionAndReplaysWithoutWrites() async throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        let request = try fixture.modifyRequest()
        let workspace = Workspace(
            id: UUID(),
            name: "CandidatePatchRequestChanges",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle,
            candidatePatchPlanProvider: StaticCandidatePatchPlanRequestProvider(request: request),
            allowsCandidatePatchTestApproval: true
        )
        let sandboxBefore = try fixture.sandboxWorkspaceSnapshot()
        let legacyBefore = try fixture.legacyIntegrity()
        var session = AgentSession(
            workspace: workspace,
            userGoal: "generate a candidate patch in the Safe Sandbox"
        )
        let result = try await AgentRuntimeCoordinator().startMission(
            input: session.userGoal,
            workspace: workspace,
            session: &session,
            runtime: kernel
        )
        let task = try XCTUnwrap(result.task)
        let initialPending = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: .pending
        )
        let originalApproval = try XCTUnwrap(initialPending.first)
        let originalPlanID = try XCTUnwrap(originalApproval.metadata["plan_id"])

        await assertAsyncFailure {
            _ = try await kernel.requestChangesApprovalRequest(
                originalApproval.id,
                workspace: workspace,
                revisionInstructions: "change it"
            )
        }
        let stillPending = try await persistence.loadApprovalRequest(id: originalApproval.id)
        XCTAssertEqual(stillPending?.state, .pending)

        let revision = "Keep the adapter read-only and narrow the explanatory purpose to the authorization boundary."
        let freshApproval = try await kernel.requestChangesApprovalRequest(
            originalApproval.id,
            workspace: workspace,
            revisionInstructions: revision
        )
        let loadedSuperseded = try await persistence.loadApprovalRequest(id: originalApproval.id)
        let superseded = try XCTUnwrap(loadedSuperseded)
        XCTAssertEqual(superseded.state, .superseded)
        XCTAssertEqual(
            superseded.metadata["candidate_patch_decision"],
            CandidatePatchApprovalDecision.requestChanges.rawValue
        )
        XCTAssertEqual(superseded.metadata["revision_instructions"], revision)
        XCTAssertNotEqual(freshApproval.id, originalApproval.id)
        XCTAssertEqual(freshApproval.state, .pending)
        XCTAssertEqual(freshApproval.metadata["original_approval_request_id"], originalApproval.id.uuidString)
        XCTAssertEqual(freshApproval.metadata["superseded_plan_id"], originalPlanID)
        XCTAssertNotEqual(freshApproval.metadata["revised_plan_id"], originalPlanID)
        XCTAssertEqual(freshApproval.metadata["fresh_approval_request_id"], freshApproval.id.uuidString)
        XCTAssertEqual(freshApproval.metadata["plan_revision"], "2")
        let revisedSummary = try XCTUnwrap(freshApproval.metadata["candidate_patch_plan_summary"])
        XCTAssertTrue(revisedSummary.contains(freshApproval.id.uuidString))
        XCTAssertTrue(revisedSummary.contains(try XCTUnwrap(freshApproval.metadata["revised_plan_id"])))

        let patchID = try XCTUnwrap(
            freshApproval.metadata["candidate_patch_id"].flatMap(CandidatePatchID.init(rawValue:))
        )
        let manifest = try CandidatePatchService(lifecycle: fixture.lifecycle).loadManifest(
            sandboxID: fixture.sandboxID,
            patchID: patchID
        )
        XCTAssertEqual(manifest.plan.revision, 2)
        XCTAssertEqual(manifest.plan.status, .awaitingApproval)
        XCTAssertNil(manifest.plan.approvalRecord)
        let history = try XCTUnwrap(manifest.revisionHistory.last)
        XCTAssertEqual(history.originalApprovalRequestID, originalApproval.id)
        XCTAssertEqual(history.decision, .requestChanges)
        XCTAssertEqual(history.revisionInstructions, [revision])
        XCTAssertEqual(history.supersededPlanID.uuidString, originalPlanID)
        XCTAssertEqual(history.revisedPlanID, manifest.plan.planID)
        XCTAssertEqual(history.freshApprovalRequestID, freshApproval.id)
        XCTAssertEqual(try fixture.sandboxWorkspaceSnapshot().snapshotID, sandboxBefore.snapshotID)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
        let revisedTasks = try await persistence.loadTasks(workspaceID: workspace.id)
        XCTAssertEqual(revisedTasks.first { $0.id == task.id }?.state, .pendingApproval)

        await assertAsyncFailure {
            _ = try await kernel.approveCandidatePatchForTest(
                originalApproval.id,
                workspace: workspace,
                reason: "The superseded approval must not authorize revision 2."
            )
        }
        XCTAssertEqual(try fixture.sandboxWorkspaceSnapshot().snapshotID, sandboxBefore.snapshotID)

        let replayBus = RuntimeEventBus()
        let replayKernel = RuntimeKernel(
            persistence: persistence,
            eventBus: replayBus,
            eventStream: InMemoryEventStream(eventBus: replayBus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle,
            candidatePatchPlanProvider: StaticCandidatePatchPlanRequestProvider(request: request),
            allowsCandidatePatchTestApproval: true
        )
        let replayPending = try await replayKernel.pendingApprovals(workspaceID: workspace.id)
        XCTAssertEqual(replayPending.map(\.id), [freshApproval.id])
        _ = try await replayKernel.approveCandidatePatchForTest(
            freshApproval.id,
            workspace: workspace,
            reason: "Approve only the revised plan."
        )
        XCTAssertNotEqual(try fixture.sandboxWorkspaceSnapshot().snapshotID, sandboxBefore.snapshotID)
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
    }

    func testCandidatePatchApprovalRequiresSingleUseSecondStepAndPersistsSanitizedProvenance() async throws {
        var fixture = try makeFixture(createReadySandbox: true)
        defer { fixture.cleanup() }
        var request = try fixture.modifyRequest()
        request.sandboxID = SandboxID()
        let reservedSandbox = fixture.lifecycle.storageRoot
            .appendingPathComponent(request.sandboxID.rawValue, isDirectory: true)
        let workspace = Workspace(
            id: UUID(),
            name: "ApprovalIntegrity",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let userSessionID = UUID()
        try await persistence.saveSessionMetadata(SessionMetadata(
            userSession: UserSession(
                id: userSessionID,
                subject: "local-test-user",
                provider: "test-local-session",
                state: .signedIn,
                issuedAt: Date(),
                expiresAt: nil,
                updatedAt: Date()
            ),
            workspaceSession: WorkspaceSession(
                id: UUID(),
                userSessionID: userSessionID,
                workspaceID: workspace.id,
                orgID: workspace.orgID,
                role: workspace.role,
                state: .signedIn,
                startedAt: Date(),
                updatedAt: Date()
            )
        ))
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle,
            candidatePatchPlanProvider: StaticCandidatePatchPlanRequestProvider(request: request)
        )
        let legacyBefore = try fixture.legacyIntegrity()
        let task = try await kernel.runCandidatePatchGeneration(
            input: "Generate the Candidate Patch plan and require two explicit approval steps.",
            workspace: workspace
        )
        let initialPending = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: .pending
        )
        let approval = try XCTUnwrap(initialPending.first)
        let appSessionID = UUID()
        let context = CandidatePatchApprovalUIContext(
            currentWorkspaceID: workspace.id,
            currentTaskID: task.id,
            visiblePendingApprovalRequestIDs: [approval.id],
            authenticatedUserSessionID: userSessionID,
            appSessionID: appSessionID
        )

        await assertAsyncFailure {
            _ = try await kernel.approveApprovalRequest(
                approval.id,
                workspace: workspace,
                reason: "A one-step API call must be rejected."
            )
        }
        var persistedApproval = try await persistence.loadApprovalRequest(id: approval.id)
        XCTAssertEqual(persistedApproval?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))

        let opened = try await kernel.beginCandidatePatchApprovalConfirmation(
            approval.id,
            workspace: workspace,
            context: context,
            source: .accessibilityUI
        )
        persistedApproval = try await persistence.loadApprovalRequest(id: approval.id)
        XCTAssertEqual(persistedApproval?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))
        var events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertEqual(events.filter { $0.type == .humanApproved }.count, 0)
        XCTAssertEqual(
            events.last { $0.payload["lifecycle_event"] == "CANDIDATE_PATCH_APPROVAL_CONFIRMATION_OPENED" }?
                .payload["approval_emitted"],
            "false"
        )

        await kernel.cancelCandidatePatchApprovalConfirmation(opened.confirmationStepID)
        await assertAsyncFailure {
            _ = try await kernel.confirmCandidatePatchApproval(
                opened,
                workspace: workspace,
                context: context,
                source: .accessibilityUI,
                reason: "A canceled confirmation must not approve."
            )
        }
        persistedApproval = try await persistence.loadApprovalRequest(id: approval.id)
        XCTAssertEqual(persistedApproval?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))

        let backgroundChallenge = try await kernel.beginCandidatePatchApprovalConfirmation(
            approval.id,
            workspace: workspace,
            context: context,
            source: .accessibilityUI
        )
        var backgroundContext = context
        backgroundContext.currentTaskID = UUID()
        await assertAsyncFailure {
            _ = try await kernel.confirmCandidatePatchApproval(
                backgroundChallenge,
                workspace: workspace,
                context: backgroundContext,
                source: .accessibilityUI,
                reason: "A background task must not authorize the current task."
            )
        }
        persistedApproval = try await persistence.loadApprovalRequest(id: approval.id)
        XCTAssertEqual(persistedApproval?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))

        let staleChallenge = try await kernel.beginCandidatePatchApprovalConfirmation(
            approval.id,
            workspace: workspace,
            context: context,
            source: .accessibilityUI
        )
        var stalePlanConfirmation = staleChallenge
        stalePlanConfirmation.planID = UUID()
        await assertAsyncFailure {
            _ = try await kernel.confirmCandidatePatchApproval(
                stalePlanConfirmation,
                workspace: workspace,
                context: context,
                source: .accessibilityUI,
                reason: "A stale plan binding must not approve."
            )
        }
        persistedApproval = try await persistence.loadApprovalRequest(id: approval.id)
        XCTAssertEqual(persistedApproval?.state, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))

        let eventsBeforeRestart = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let replayBus = RuntimeEventBus()
        let restartedKernel = RuntimeKernel(
            persistence: persistence,
            eventBus: replayBus,
            eventStream: InMemoryEventStream(eventBus: replayBus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle,
            candidatePatchPlanProvider: StaticCandidatePatchPlanRequestProvider(request: request)
        )
        let restartedPending = try await restartedKernel.pendingApprovals(workspaceID: workspace.id)
        XCTAssertEqual(restartedPending.map(\.id), [approval.id])
        await assertAsyncFailure {
            _ = try await restartedKernel.beginCandidatePatchApprovalConfirmation(
                approval.id,
                workspace: workspace,
                context: context,
                source: .replay
            )
        }
        let eventsAfterRejectedReplay = try await persistence.loadEvents(
            workspaceID: workspace.id,
            taskID: task.id
        )
        XCTAssertEqual(eventsAfterRejectedReplay.count, eventsBeforeRestart.count)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))

        let confirmedChallenge = try await restartedKernel.beginCandidatePatchApprovalConfirmation(
            approval.id,
            workspace: workspace,
            context: context,
            source: .accessibilityUI
        )
        _ = try await restartedKernel.confirmCandidatePatchApproval(
            confirmedChallenge,
            workspace: workspace,
            context: context,
            source: .accessibilityUI,
            reason: "Second explicit confirmation for the exact visible pending request."
        )
        let loadedApproved = try await persistence.loadApprovalRequest(id: approval.id)
        let approved = try XCTUnwrap(loadedApproved)
        XCTAssertEqual(approved.state, .approved)
        XCTAssertEqual(approved.metadata["approval_source"], CandidatePatchApprovalSource.accessibilityUI.rawValue)
        XCTAssertEqual(approved.metadata["task_id"], task.id.uuidString)
        XCTAssertEqual(approved.metadata["plan_id"], confirmedChallenge.planID.uuidString)
        XCTAssertEqual(approved.metadata["plan_revision"], String(confirmedChallenge.planRevision))
        XCTAssertEqual(approved.metadata["approval_request_id"], approval.id.uuidString)
        XCTAssertEqual(approved.metadata["confirmation_step_id"], confirmedChallenge.confirmationStepID.uuidString)
        XCTAssertEqual(approved.metadata["app_session_id"], appSessionID.uuidString)
        XCTAssertNil(approved.metadata["raw_automation_script"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedSandbox.path))
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)

        events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let approvalEvent = try XCTUnwrap(events.last { $0.type == .humanApproved })
        XCTAssertEqual(approvalEvent.payload["approval_source"], CandidatePatchApprovalSource.accessibilityUI.rawValue)
        XCTAssertEqual(
            approvalEvent.payload["controller_path"],
            "CandidatePatchApprovalConfirmationView.confirm -> AppStore.confirmCandidatePatchApproval -> RuntimeKernel.confirmCandidatePatchApproval"
        )
        XCTAssertEqual(events.filter { $0.type == .humanApproved }.count, 1)

        let patchID = try XCTUnwrap(
            approval.metadata["candidate_patch_id"].flatMap(CandidatePatchID.init(rawValue:))
        )
        let service = CandidatePatchService(lifecycle: fixture.lifecycle)
        var manifest = try service.loadManifest(sandboxID: request.sandboxID, patchID: patchID)
        XCTAssertEqual(manifest.plan.approvalRecord?.provenance?.confirmationStepID, confirmedChallenge.confirmationStepID)
        XCTAssertTrue(manifest.auditEvents.contains { $0.type == .approvalConfirmationOpened })
        XCTAssertTrue(manifest.auditEvents.contains {
            $0.type == .approvalRecorded && $0.approvalProvenance?.source == .accessibilityUI
        })
        manifest = try service.revertAndDestroySandbox(
            sandboxID: request.sandboxID,
            patchID: patchID
        )
        XCTAssertEqual(manifest.status, .reverted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservedSandbox.path))
        let preservedAudit = try service.loadManifest(sandboxID: request.sandboxID, patchID: patchID)
        XCTAssertEqual(preservedAudit.status, .reverted)
        XCTAssertTrue(preservedAudit.auditEvents.contains { $0.type == .approvalRecorded })
        XCTAssertTrue(preservedAudit.auditEvents.contains { $0.type == .operationApplied })
        XCTAssertTrue(preservedAudit.auditEvents.contains { $0.type == .operationReverted })
        XCTAssertTrue(preservedAudit.auditEvents.contains { $0.type == .sourceIntegrityChecked })
        XCTAssertTrue(preservedAudit.auditEvents.contains { $0.type == .sandboxDestroyed })
        XCTAssertEqual(try fixture.legacyIntegrity(), legacyBefore)
    }

    func testSyntheticLegacyNativeCandidateReviewFlowAndRevert() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let legacy = repositoryRoot.appendingPathComponent("demo/SyntheticLegacy", isDirectory: true)
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDECandidatePatchSynthetic-\(UUID().uuidString)", isDirectory: true)
        let storage = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let original = try CandidatePatchLegacyIntegrityMonitor().capture(root: legacy)
        let lifecycle = SandboxLifecycleService(storageRoot: storage)
        let inspection = try lifecycle.createSandbox(sourceRoot: legacy, approvedLegacyRoot: legacy)
        let record = try XCTUnwrap(
            inspection.sourceManifest.files.first { $0.relativeCanonicalPath == "src/orders.ts" }
        )
        let claimID = "claim-synthetic-orders-read-boundary"
        let assessment = CandidatePatchAssessmentContext(
            assessmentID: "phase-2c-synthetic",
            generatedAt: Date(),
            sourceSnapshotID: inspection.sourceManifest.snapshotID,
            canonicalLegacyRoot: inspection.sourceManifest.canonicalSourceRoot,
            compatibilityDecision: .yes,
            evidence: [Self.groundedEvidence(
                claimID: claimID,
                path: "src/orders.ts",
                snapshotID: inspection.sourceManifest.snapshotID
            )]
        )
        let service = CandidatePatchService(lifecycle: lifecycle)
        let request = CandidatePatchPlanRequest(
            sandboxID: inspection.descriptor.sandboxID,
            selectedLegacyRoot: legacy,
            trustedLegacyRoot: legacy,
            assessment: assessment,
            requestedOutcome: "Add a candidate read-only order query adapter in the Safe Sandbox.",
            proposedOperations: [CandidatePatchProposedOperation(
                relativePath: "src/order-query-adapter.ts",
                operationType: .createTextFile,
                proposedContent: "export const queryOrderReadOnly = (orderId: string) => ({ orderId })\n",
                purpose: "Introduce the proposed read-only adapter boundary.",
                evidenceClaimIDs: [claimID],
                risk: .low,
                impact: "Adds an isolated candidate adapter for review."
            )],
            approvedScope: ["src"],
            expectedBehavior: ["Expose a proposed read-only order lookup boundary."],
            validationRequiredLater: ["Review contract mapping; build and test in a later authorized phase."],
            rollbackApproach: "Remove the Candidate Patch-created adapter through app-managed revert.",
            unknowns: ["Runtime integration is not verified."]
        )
        let plan = try service.preparePlan(request)
        XCTAssertEqual(plan.status, CandidatePatchStatus.awaitingApproval)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try Self.workspaceURL(lifecycle: lifecycle, sandboxID: inspection.descriptor.sandboxID)
                .appendingPathComponent("src/order-query-adapter.ts").path
        ))
        let originalApprovalID = UUID()
        _ = try service.recordApprovalRequest(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: plan.patchID,
            planID: plan.planID,
            approvalRequestID: originalApprovalID
        )
        _ = try service.recordDecision(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: plan.patchID,
            decision: .requestChanges,
            decidedBy: "synthetic-acceptance-reviewer",
            rationale: "Keep the adapter explicitly read-only before approval.",
            requestedChanges: ["Keep the adapter explicitly read-only before approval."],
            approvalRequestID: originalApprovalID
        )
        var revisedRequest = request
        revisedRequest.patchID = plan.patchID
        revisedRequest.requestedOutcome = "Add a revised, explicitly read-only order query adapter in the Safe Sandbox."
        revisedRequest.proposedOperations[0].proposedContent =
            "export const queryOrderReadOnly = (orderId: string) => ({ orderId, mode: 'read-only' })\n"
        let revisedPlan = try service.preparePlan(revisedRequest)
        XCTAssertEqual(revisedPlan.revision, 2)
        XCTAssertNotEqual(revisedPlan.planID, plan.planID)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try Self.workspaceURL(lifecycle: lifecycle, sandboxID: inspection.descriptor.sandboxID)
                .appendingPathComponent("src/order-query-adapter.ts").path
        ))
        XCTAssertEqual(CandidatePatchLegacyIntegrityMonitor().verify(original), .unchanged)

        let freshApprovalID = UUID()
        _ = try service.recordApprovalRequest(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: revisedPlan.patchID,
            planID: revisedPlan.planID,
            approvalRequestID: freshApprovalID
        )
        XCTAssertThrowsError(try service.recordDecision(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: revisedPlan.patchID,
            decision: .approve,
            decidedBy: "synthetic-acceptance-reviewer",
            rationale: "The superseded approval must not authorize revision 2.",
            approvalRequestID: originalApprovalID
        ))
        XCTAssertThrowsError(try service.apply(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: revisedPlan.patchID
        ))
        _ = try service.recordDecision(
            sandboxID: inspection.descriptor.sandboxID,
            patchID: revisedPlan.patchID,
            decision: .approve,
            decidedBy: "synthetic-acceptance-reviewer",
            rationale: "Approved revised plan for isolated review only.",
            approvalRequestID: freshApprovalID
        )
        let applied = try service.apply(sandboxID: inspection.descriptor.sandboxID, patchID: plan.patchID)
        XCTAssertTrue(applied.complete)
        XCTAssertTrue(applied.manifest.unifiedDiff?.contains("+++ b/src/order-query-adapter.ts") == true)
        XCTAssertEqual(CandidatePatchLegacyIntegrityMonitor().verify(original), .unchanged)
        let review = try service.reviewSummary(sandboxID: inspection.descriptor.sandboxID, patchID: plan.patchID)
        XCTAssertFalse(review.buildOrTestExecuted)
        XCTAssertFalse(review.gitOrDeploymentActionOccurred)
        _ = try service.revert(sandboxID: inspection.descriptor.sandboxID, patchID: plan.patchID)
        XCTAssertEqual(CandidatePatchLegacyIntegrityMonitor().verify(original), .unchanged)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try Self.workspaceURL(lifecycle: lifecycle, sandboxID: inspection.descriptor.sandboxID)
                .appendingPathComponent("src/order-query-adapter.ts").path
        ))
        XCTAssertEqual(record.sha256, try XCTUnwrap(inspection.sourceManifest.files.first { $0.relativeCanonicalPath == "src/orders.ts" }).sha256)
    }
}

private extension CandidatePatchGenerationTests {
    struct Fixture {
        var container: URL
        var legacy: URL
        var agent: URL
        var lifecycle: SandboxLifecycleService
        var sandboxID: SandboxID
        var sourceSnapshotID: String
        var ordersHash: String
        var originalOrders: String
        var claimID: String

        mutating func cleanup() {
            try? FileManager.default.removeItem(at: container)
        }

        func assessment() -> CandidatePatchAssessmentContext {
            CandidatePatchAssessmentContext(
                assessmentID: "phase-2c-fixture",
                generatedAt: Date(),
                sourceSnapshotID: sourceSnapshotID,
                canonicalLegacyRoot: legacy.standardizedFileURL.path,
                compatibilityDecision: .yes,
                evidence: [CandidatePatchGenerationTests.groundedEvidence(
                    claimID: claimID,
                    path: "src/orders.ts",
                    snapshotID: sourceSnapshotID
                )]
            )
        }

        func modifyRequest(
            path: String = "src/orders.ts",
            expectedHash: String? = nil
        ) throws -> CandidatePatchPlanRequest {
            CandidatePatchPlanRequest(
                sandboxID: sandboxID,
                selectedLegacyRoot: legacy,
                trustedLegacyRoot: legacy,
                agentWorkspaceRoots: [agent],
                assessment: assessment(),
                requestedOutcome: "Add an assessment-backed read-only order candidate change.",
                proposedOperations: [CandidatePatchProposedOperation(
                    relativePath: path,
                    operationType: .replaceTextFile,
                    proposedContent: "export const orders = ['a', 'b'] // candidate read-only boundary\n",
                    expectedPreimageSHA256: expectedHash ?? ordersHash,
                    purpose: "Clarify the proposed read-only order integration boundary.",
                    evidenceClaimIDs: [claimID],
                    risk: .medium,
                    impact: "Changes only the isolated Sandbox candidate source."
                )],
                approvedScope: ["src"],
                expectedBehavior: ["Expose a reviewable read-only boundary proposal."],
                validationRequiredLater: ["Build and test only in a later separately authorized phase."],
                rollbackApproach: "Restore the approved Sandbox preimage.",
                unknowns: ["Runtime behavior remains unverified."]
            )
        }

        func createRequest(path: String) throws -> CandidatePatchPlanRequest {
            var request = try modifyRequest()
            request.proposedOperations = [try createOperation(path: path)]
            return request
        }

        func createOperation(path: String) throws -> CandidatePatchProposedOperation {
            CandidatePatchProposedOperation(
                relativePath: path,
                operationType: .createTextFile,
                proposedContent: "export const candidateAdapter = true\n",
                purpose: "Create the proposed read-only adapter.",
                evidenceClaimIDs: [claimID],
                risk: .low,
                impact: "Adds one review-only Sandbox text file."
            )
        }

        func workspaceURL() throws -> URL {
            try CandidatePatchGenerationTests.workspaceURL(lifecycle: lifecycle, sandboxID: sandboxID)
        }

        func sandboxWorkspaceSnapshot() throws -> SourceSnapshotManifest {
            try SourceSnapshotBuilder().build(root: workspaceURL())
        }

        func legacyIntegrity() throws -> String {
            try CandidatePatchLegacyIntegrityMonitor().capture(root: legacy).fingerprint
        }
    }

    func makeFixture(createReadySandbox: Bool) throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDECandidatePatch-\(UUID().uuidString)", isDirectory: true)
        let legacy = container.appendingPathComponent("Legacy", isDirectory: true)
        let agent = container.appendingPathComponent("Agent", isDirectory: true)
        let storage = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        let originalOrders = "export const orders = ['a']\n"
        try Data(originalOrders.utf8).write(to: legacy.appendingPathComponent("src/orders.ts"))
        try Data("legacy fixture\n".utf8).write(to: legacy.appendingPathComponent("README.md"))
        try Data("agent fixture\n".utf8).write(to: agent.appendingPathComponent("Agent.txt"))
        let lifecycle = SandboxLifecycleService(storageRoot: storage, agentWorkspaceRoots: [agent])
        let inspection = createReadySandbox
            ? try lifecycle.createSandbox(sourceRoot: legacy, approvedLegacyRoot: legacy)
            : try lifecycle.prepareSandbox(sourceRoot: legacy, approvedLegacyRoot: legacy)
        let orders = try XCTUnwrap(
            inspection.sourceManifest.files.first { $0.relativeCanonicalPath == "src/orders.ts" }
        )
        return Fixture(
            container: container,
            legacy: legacy,
            agent: agent,
            lifecycle: lifecycle,
            sandboxID: inspection.descriptor.sandboxID,
            sourceSnapshotID: inspection.sourceManifest.snapshotID,
            ordersHash: orders.sha256,
            originalOrders: originalOrders,
            claimID: "claim-orders-read-boundary"
        )
    }

    static func groundedEvidence(
        claimID: String,
        path: String,
        snapshotID: String
    ) -> CandidatePatchEvidence {
        CandidatePatchEvidence(
            claimID: claimID,
            statement: "The inspected Legacy order module is the grounded integration boundary.",
            evidenceReferences: [AssessmentEvidenceReference(
                source: .inspectedFile,
                path: path,
                fact: "The order module was directly read during Phase 2C.",
                claimLevel: .sourceBehaviorConfirmed,
                observationStatus: .directlyRead,
                sourceComponent: "src",
                safeEvidenceSummary: "The order module exposes the inspected read boundary.",
                workspaceSnapshotIdentifier: snapshotID
            )],
            confidence: .high,
            material: true
        )
    }

    static func workspaceURL(lifecycle: SandboxLifecycleService, sandboxID: SandboxID) throws -> URL {
        try SandboxPathResolver(storageRoot: lifecycle.storageRoot)
            .resolve(sandboxID: sandboxID, relativePath: ".")
    }

    func assertFailure(
        _ expected: CandidatePatchFailureCode,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual((error as? CandidatePatchError)?.code, expected, file: file, line: line)
        }
    }

    func assertAsyncFailure(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected asynchronous operation to throw.", file: file, line: line)
        } catch {
            // Expected failure.
        }
    }
}
