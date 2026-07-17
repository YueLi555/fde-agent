import XCTest
@testable import FDECloudOS

final class CandidatePatchRevertTests: XCTestCase {
    func testPrimaryActionExtractionExcludesNegatedConditionalAndFutureDestructionMentions() {
        let parser = MissionIntentParser()
        let observed = """
        请仅对以下已应用的 Candidate Patch 启动专用
        CANDIDATE_PATCH_REVERT 流程。
        只进入 REVERT_CONFIRMATION_REQUIRED。
        Sandbox 销毁必须在 Revert 成功后作为独立操作进行。
        """
        let revertPrompts = [
            observed,
            "请回滚这个 Candidate Patch。Sandbox 销毁必须在 Revert 成功后进行。",
            "请回滚这个 Candidate Patch。不要销毁 Sandbox。",
            "请回滚这个 Candidate Patch。Revert 后再单独销毁。",
            "revert this Candidate Patch; do not destroy the Sandbox",
            "revert this Candidate Patch; destroy only after Revert succeeds",
            "start the CANDIDATE_PATCH_REVERT flow for this Candidate Patch"
        ]
        for input in revertPrompts {
            XCTAssertEqual(parser.parse(input).intentType, .candidatePatchRevert, input)
        }

        for input in [
            "Sandbox 销毁必须在 Revert 成功后进行",
            "不要销毁 Sandbox",
            "do not destroy the Sandbox",
            "Sandbox destruction is not authorized yet",
            "destruction must remain a separate action"
        ] {
            XCTAssertNotEqual(parser.parse(input).intentType, .candidatePatchSandboxDestroy, input)
        }

        for input in [
            "请销毁这个已经回滚的 Sandbox",
            "delete the following Safe Sandbox",
            "start Sandbox destruction confirmation now",
            "Revert this Candidate Patch and destroy the Sandbox now"
        ] {
            XCTAssertEqual(parser.parse(input).intentType, .candidatePatchSandboxDestroy, input)
        }
    }

    func testObservedPrimaryRevertPromptCreatesOneRevertTaskAndNoDestructionPlanOrSandbox() async throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let applied = try fixture.applyPatch(sandboxID: fixture.firstSandboxID)
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: fixture.workspaceID,
            name: "Primary Revert Action Fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        try await persistence.saveWorkspace(workspace)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle
        )
        let sandboxCountBefore = try FileManager.default.contentsOfDirectory(
            at: fixture.lifecycle.storageRoot,
            includingPropertiesForKeys: nil
        ).count
        let prompt = """
        请仅对以下已应用的 Candidate Patch 启动专用 CANDIDATE_PATCH_REVERT 流程。
        Patch: \(applied.binding.patchID.rawValue)
        Plan: \(applied.binding.planID.uuidString), revision \(applied.binding.planRevision)
        Sandbox: \(applied.binding.sandboxID.rawValue)
        只进入 REVERT_CONFIRMATION_REQUIRED。
        Sandbox 销毁必须在 Revert 成功后作为独立操作进行。
        """
        var session = AgentSession(workspace: workspace, userGoal: prompt)
        let result = try await AgentRuntimeCoordinator().startMission(
            input: prompt,
            workspace: workspace,
            session: &session,
            runtime: kernel
        )
        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.title, "Phase 2D.1 Candidate Patch Revert")
        XCTAssertEqual(task.state, .pendingApproval)
        XCTAssertEqual(result.recordedEvents.first?.payload["selected_route"], AgentRequestRoute.candidatePatchRevert.rawValue)
        XCTAssertEqual(result.recordedEvents.first?.payload["intent_type"], MissionIntentType.candidatePatchRevert.rawValue)

        let tasks = try await persistence.loadTasks(workspaceID: workspace.id)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Phase 2D.1 Candidate Patch Revert")
        XCTAssertFalse(tasks.contains { $0.title == "Candidate Patch Sandbox Destruction" })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: fixture.lifecycle.storageRoot,
                includingPropertiesForKeys: nil
            ).count,
            sandboxCountBefore
        )
        let approvals = try await persistence.loadApprovalRequests(workspaceID: workspace.id, state: nil)
        XCTAssertTrue(approvals.isEmpty)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertTrue(events.allSatisfy { $0.payload["patch_plan_created"] != "true" })
        XCTAssertTrue(events.allSatisfy { $0.payload["sandbox_created"] != "true" })
        XCTAssertFalse(events.contains { $0.summary.contains("destruction task created") })
        XCTAssertFalse(SandboxRuntimePolicy.phase2D1Allowlist.contains(.generatedTest))
    }

    func testSandboxDestructionChineseEnglishAndRevertKeywordPrecedenceRouting() {
        let parser = MissionIntentParser()
        for input in [
            "销毁这个已回滚的 Sandbox",
            "删除这个 Safe Sandbox",
            "销毁 Patch 对应的隔离环境",
            "清理已完成 Revert 的 Sandbox",
            "destroy the reverted patch sandbox",
            "delete this Safe Sandbox",
            "remove the isolated sandbox after revert",
            "clean up the reverted patch sandbox",
            "请销毁以下已经完成 Revert 的 Candidate Patch Sandbox"
        ] {
            let intent = parser.parse(input)
            XCTAssertEqual(intent.intentType, .candidatePatchSandboxDestroy, input)
            XCTAssertEqual(MissionExecutionSemantic(intent: intent), .candidatePatchSandboxDestroy, input)
            XCTAssertNotEqual(intent.intentType, .candidatePatchRevert, input)
            XCTAssertNotEqual(intent.intentType, .candidatePatchGeneration, input)
            XCTAssertTrue(
                intent.expectedOutputs.contains(.candidatePatchSandboxDestructionReview),
                input
            )
        }
    }

    func testSandboxDestructionEligibilityExactBindingIsolationAuditAndRestartPersistence() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacyBefore = try fixture.legacyFingerprint()
        let first = try fixture.applyPatch(sandboxID: fixture.firstSandboxID)
        let second = try fixture.applyPatch(sandboxID: fixture.secondSandboxID)
        let firstWorkspace = try fixture.workspaceURL(first.binding.sandboxID)
        let secondWorkspace = try fixture.workspaceURL(second.binding.sandboxID)
        let secondBefore = try SourceSnapshotBuilder().build(root: secondWorkspace).snapshotID

        assertFailure(.sandboxDestructionUnavailable) {
            _ = try fixture.service.locateSandboxDestructionTarget(
                workspaceID: fixture.workspaceID,
                request: "destroy Candidate Patch \(first.binding.patchID.rawValue) Sandbox \(first.binding.sandboxID.rawValue)"
            )
        }
        let pendingSandbox = try fixture.lifecycle.createSandbox(
            sourceRoot: fixture.legacy,
            approvedLegacyRoot: fixture.legacy
        ).descriptor.sandboxID
        let pending = try fixture.preparePatch(sandboxID: pendingSandbox)
        assertFailure(.sandboxDestructionUnavailable) {
            _ = try fixture.service.locateSandboxDestructionTarget(
                workspaceID: fixture.workspaceID,
                request: "destroy Candidate Patch \(pending.patchID.rawValue) Sandbox \(pendingSandbox.rawValue)"
            )
        }
        var wrongSandboxBinding = first.binding
        wrongSandboxBinding.sandboxID = second.binding.sandboxID
        assertFailure(.revertBindingMismatch) {
            _ = try fixture.service.prepareSandboxDestruction(binding: wrongSandboxBinding)
        }

        let reverted = try fixture.service.revert(binding: first.binding)
        let target = try fixture.service.locateSandboxDestructionTarget(
            workspaceID: fixture.workspaceID,
            request: "destroy Candidate Patch \(first.binding.patchID.rawValue) Sandbox \(first.binding.sandboxID.rawValue)"
        )
        XCTAssertEqual(target.binding, first.binding)
        _ = try fixture.service.prepareSandboxDestruction(binding: target.binding)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstWorkspace.path))
        XCTAssertEqual(try fixture.legacyFingerprint(), legacyBefore)

        let destroyed = try fixture.service.destroyRevertedSandbox(binding: target.binding)
        XCTAssertEqual(destroyed.status, .reverted)
        XCTAssertNotNil(destroyed.sandboxDestroyedAt)
        XCTAssertGreaterThan(destroyed.auditEvents.count, reverted.auditEvents.count)
        XCTAssertTrue(destroyed.auditEvents.contains { $0.type == .approvalRecorded })
        XCTAssertTrue(destroyed.auditEvents.contains { $0.type == .revertCompleted })
        XCTAssertTrue(destroyed.auditEvents.contains { $0.type == .sandboxDestroyed })
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstWorkspace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondWorkspace.path))
        XCTAssertEqual(try SourceSnapshotBuilder().build(root: secondWorkspace).snapshotID, secondBefore)
        XCTAssertEqual(try fixture.legacyFingerprint(), legacyBefore)

        let restartedService = CandidatePatchService(lifecycle: fixture.lifecycle)
        let reloaded = try restartedService.loadManifest(
            sandboxID: first.binding.sandboxID,
            patchID: first.binding.patchID
        )
        XCTAssertNotNil(reloaded.sandboxDestroyedAt)
        XCTAssertTrue(reloaded.auditEvents.contains { $0.type == .sandboxDestroyed })
        XCTAssertEqual(
            try restartedService.loadManifest(
                sandboxID: second.binding.sandboxID,
                patchID: second.binding.patchID
            ).status,
            .reviewReady
        )
    }

    func testSandboxDestructionNativeRouteReusesTaskAndRequiresExplicitConfirmation() async throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacyBefore = try fixture.legacyFingerprint()
        let first = try fixture.applyPatch(sandboxID: fixture.firstSandboxID)
        let firstWorkspace = try fixture.workspaceURL(first.binding.sandboxID)
        let secondWorkspace = try fixture.workspaceURL(fixture.secondSandboxID)
        _ = try fixture.service.revert(binding: first.binding)
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: fixture.workspaceID,
            name: "Candidate Patch Destruction Fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        try await persistence.saveWorkspace(workspace)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle
        )
        var session = AgentSession(
            workspace: workspace,
            userGoal: "destroy the reverted patch sandbox"
        )
        let prompt = "destroy the reverted Candidate Patch \(first.binding.patchID.rawValue) Sandbox \(first.binding.sandboxID.rawValue) after Revert"
        let result = try await AgentRuntimeCoordinator().startMission(
            input: prompt,
            workspace: workspace,
            session: &session,
            runtime: kernel
        )
        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.title, "Candidate Patch Sandbox Destruction")
        XCTAssertEqual(task.state, .pendingApproval)
        XCTAssertEqual(result.recordedEvents.first?.payload["selected_route"], AgentRequestRoute.candidatePatchSandboxDestroy.rawValue)
        XCTAssertEqual(result.recordedEvents.first?.payload["intent_type"], MissionIntentType.candidatePatchSandboxDestroy.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstWorkspace.path))
        let tasksBeforeConfirmation = try await persistence.loadTasks(workspaceID: workspace.id)

        let context = CandidatePatchRevertUIContext(
            currentWorkspaceID: workspace.id,
            currentTaskID: task.id,
            visiblePatchID: first.binding.patchID,
            visibleSandboxID: first.binding.sandboxID,
            authenticatedLocalSessionID: fixture.authenticatedSessionID,
            appSessionID: UUID()
        )
        let confirmation = try await kernel.beginCandidatePatchSandboxDestructionConfirmation(
            patchID: first.binding.patchID,
            sandboxID: first.binding.sandboxID,
            workspace: workspace,
            context: context,
            source: .testFixture
        )
        XCTAssertEqual(confirmation.requestingTaskID, task.id)
        let tasksAfterConfirmation = try await persistence.loadTasks(workspaceID: workspace.id)
        XCTAssertEqual(tasksAfterConfirmation.count, tasksBeforeConfirmation.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstWorkspace.path))

        let destroyed = try await kernel.confirmCandidatePatchSandboxDestruction(
            confirmation,
            workspace: workspace,
            context: context,
            source: .testFixture
        )
        XCTAssertNotNil(destroyed.sandboxDestroyedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstWorkspace.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondWorkspace.path))
        XCTAssertEqual(try fixture.legacyFingerprint(), legacyBefore)
        let applicationApprovals = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: nil
        )
        XCTAssertTrue(applicationApprovals.isEmpty)

        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        XCTAssertFalse(events.contains { $0.summary == "Candidate Patch Revert task created" })
        XCTAssertTrue(events.allSatisfy { $0.payload["revert_task_created"] != "true" })
        XCTAssertTrue(events.allSatisfy { $0.payload["patch_plan_created"] != "true" })
        XCTAssertTrue(events.allSatisfy { $0.payload["sandbox_created"] != "true" })
        let completed = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        XCTAssertEqual(completed.payload["completion_contract"], RuntimeCompletionContractKind.candidatePatchSandboxDestroy.rawValue)
        XCTAssertEqual(completed.payload["candidate_patch_projection_state"], CandidatePatchProjectionState.sandboxDestroyed.rawValue)
        XCTAssertEqual(completed.payload["build_or_test_executed"], "false")
        XCTAssertEqual(completed.payload["shell_execution_enabled"], "false")
        XCTAssertEqual(completed.payload["git_or_deployment_action_occurred"], "false")
        XCTAssertFalse(SandboxRuntimePolicy.phase2D1Allowlist.contains(.generatedTest))
    }

    func testChineseEnglishAndPrecedenceRouteOnlyToCandidatePatchRevert() {
        let parser = MissionIntentParser()
        for input in [
            "请回滚刚刚应用的 Candidate Patch",
            "回滚刚才应用的候选修改",
            "revert the Candidate Patch that was just applied",
            "undo the applied candidate patch"
        ] {
            let intent = parser.parse(input)
            XCTAssertEqual(intent.intentType, .candidatePatchRevert, input)
            XCTAssertEqual(MissionExecutionSemantic(intent: intent), .candidatePatchRevert, input)
            XCTAssertNotEqual(intent.intentType, .candidatePatchGeneration, input)
            XCTAssertTrue(intent.expectedOutputs.contains(.candidatePatchRevertReview), input)
        }
    }

    func testExactBindingAmbiguityPendingAndDoubleRevertFailClosed() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = try fixture.applyPatch(sandboxID: fixture.firstSandboxID)
        let second = try fixture.applyPatch(sandboxID: fixture.secondSandboxID)
        let service = fixture.service

        assertFailure(.revertSelectionAmbiguous) {
            _ = try service.locateRevertTarget(
                workspaceID: fixture.workspaceID,
                request: "请回滚刚刚应用的 Candidate Patch"
            )
        }
        let exact = try service.locateRevertTarget(
            workspaceID: fixture.workspaceID,
            request: "revert exact Candidate Patch \(first.binding.patchID.rawValue) in Sandbox \(first.binding.sandboxID.rawValue)"
        )
        XCTAssertEqual(exact.binding, first.binding)
        XCTAssertNotEqual(exact.binding.patchID, second.binding.patchID)
        var wrongBinding = exact.binding
        wrongBinding.planRevision += 1
        assertFailure(.revertBindingMismatch) { _ = try service.prepareRevert(binding: wrongBinding) }

        let pendingSandbox = try fixture.lifecycle.createSandbox(
            sourceRoot: fixture.legacy,
            approvedLegacyRoot: fixture.legacy
        ).descriptor.sandboxID
        let pending = try fixture.preparePatch(sandboxID: pendingSandbox)
        assertFailure(.revertUnavailable) {
            _ = try service.locateRevertTarget(
                workspaceID: fixture.workspaceID,
                request: "revert exact Candidate Patch \(pending.patchID.rawValue)"
            )
        }

        _ = try service.revert(binding: first.binding)
        assertFailure(.revertBindingMismatch) { _ = try service.revert(binding: first.binding) }
    }

    func testPostimagePreflightAndExactRevertRestoreOnlySelectedSandbox() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let legacyBefore = try fixture.legacyFingerprint()
        let first = try fixture.applyPatch(sandboxID: fixture.firstSandboxID)
        let second = try fixture.applyPatch(sandboxID: fixture.secondSandboxID)
        let firstWorkspace = try fixture.workspaceURL(first.binding.sandboxID)
        let secondWorkspace = try fixture.workspaceURL(second.binding.sandboxID)
        let secondBefore = try SourceSnapshotBuilder().build(root: secondWorkspace).snapshotID
        let changedOrders = firstWorkspace.appendingPathComponent("src/orders.ts")

        try Data("tampered postimage\n".utf8).write(to: changedOrders)
        assertFailure(.currentPatchImageChanged) {
            _ = try fixture.service.prepareRevert(binding: first.binding)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: firstWorkspace.appendingPathComponent("src/candidate-adapter.ts").path
        ))
        try Data(Fixture.replacementOrders.utf8).write(to: changedOrders)

        let beforeAuditCount = first.manifest.auditEvents.count
        let reverted = try fixture.service.revert(binding: first.binding)
        XCTAssertEqual(reverted.status, .reverted)
        XCTAssertEqual(try String(contentsOf: changedOrders, encoding: .utf8), Fixture.originalOrders)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: firstWorkspace.appendingPathComponent("src/candidate-adapter.ts").path
        ))
        XCTAssertEqual(try SourceSnapshotBuilder().build(root: secondWorkspace).snapshotID, secondBefore)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: secondWorkspace.appendingPathComponent("src/candidate-adapter.ts").path
        ))
        XCTAssertEqual(try fixture.legacyFingerprint(), legacyBefore)
        XCTAssertGreaterThan(reverted.auditEvents.count, beforeAuditCount)
        XCTAssertTrue(reverted.auditEvents.contains { $0.type == .revertCompleted })
        XCTAssertTrue(reverted.auditEvents.contains { $0.type == .operationReverted })
        XCTAssertNil(reverted.sandboxDestroyedAt)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstWorkspace.path))
        XCTAssertEqual(second.manifest.status, .reviewReady)
    }

    func testRuntimeRequiresExplicitConfirmationAndCreatesNoPlanApprovalOrSandbox() async throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let applied = try fixture.applyPatch(sandboxID: fixture.firstSandboxID)
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: fixture.workspaceID,
            name: "Candidate Patch Revert Fixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: fixture.legacy.path,
            localAgentProjectRoot: fixture.agent.path
        )
        try await persistence.saveWorkspace(workspace)
        let bus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: bus,
            eventStream: InMemoryEventStream(eventBus: bus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: fixture.lifecycle
        )
        let sandboxCountBefore = try FileManager.default.contentsOfDirectory(
            at: fixture.lifecycle.storageRoot,
            includingPropertiesForKeys: nil
        ).count
        let task = try await kernel.runCandidatePatchRevert(
            input: "revert exact Candidate Patch \(applied.binding.patchID.rawValue) in Sandbox \(applied.binding.sandboxID.rawValue)",
            workspace: workspace
        )
        XCTAssertEqual(task.state, .pendingApproval)
        XCTAssertEqual(
            try fixture.service.loadManifest(
                sandboxID: applied.binding.sandboxID,
                patchID: applied.binding.patchID
            ).status,
            .reviewReady
        )
        let applicationApprovals = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: nil
        )
        XCTAssertTrue(applicationApprovals.isEmpty)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: fixture.lifecycle.storageRoot,
                includingPropertiesForKeys: nil
            ).count,
            sandboxCountBefore
        )

        let appSessionID = UUID()
        let context = CandidatePatchRevertUIContext(
            currentWorkspaceID: workspace.id,
            currentTaskID: task.id,
            visiblePatchID: applied.binding.patchID,
            visibleSandboxID: applied.binding.sandboxID,
            authenticatedLocalSessionID: fixture.authenticatedSessionID,
            appSessionID: appSessionID
        )
        let confirmation = try await kernel.beginCandidatePatchRevertConfirmation(
            patchID: applied.binding.patchID,
            sandboxID: applied.binding.sandboxID,
            workspace: workspace,
            context: context,
            source: .testFixture
        )
        XCTAssertEqual(
            try fixture.service.loadManifest(
                sandboxID: applied.binding.sandboxID,
                patchID: applied.binding.patchID
            ).status,
            .reviewReady
        )
        let reverted = try await kernel.confirmCandidatePatchRevert(
            confirmation,
            workspace: workspace,
            context: context,
            source: .testFixture
        )
        XCTAssertEqual(reverted.status, .reverted)
        XCTAssertNil(reverted.sandboxDestroyedAt)

        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let completed = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        XCTAssertEqual(completed.payload["build_or_test_executed"], "false")
        XCTAssertEqual(completed.payload["shell_execution_enabled"], "false")
        XCTAssertEqual(completed.payload["git_or_deployment_action_occurred"], "false")
        XCTAssertEqual(completed.payload["credential_or_production_action_occurred"], "false")
        XCTAssertEqual(completed.payload["sandbox_destroyed"], "false")
        XCTAssertTrue(events.allSatisfy { $0.payload["patch_plan_created"] != "true" })
        XCTAssertTrue(events.allSatisfy { $0.payload["patch_application_approval_created"] != "true" })
        XCTAssertTrue(events.allSatisfy { $0.payload["sandbox_created"] != "true" })
    }

    func testDestructionIsSeparateAccessibilityIsPassiveAndPhase2D2Unavailable() throws {
        var fixture = try Fixture()
        defer { fixture.cleanup() }
        let applied = try fixture.applyPatch(sandboxID: fixture.firstSandboxID)
        _ = try fixture.service.revert(binding: applied.binding)
        let workspaceURL = try fixture.workspaceURL(applied.binding.sandboxID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))

        let source = try String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/FDECloudOS/UI/Components/AgentConversationView.swift"),
            encoding: .utf8
        ) + String(
            contentsOf: Self.repositoryRoot
                .appendingPathComponent("Sources/FDECloudOS/UI/Components/AgentWorkspaceView.swift"),
            encoding: .utf8
        )
        for identifier in [
            "candidatePatch.revert.openConfirmation",
            "candidatePatch.revert.confirm",
            "candidatePatch.revert.cancel",
            "candidatePatch.destroySandbox.openConfirmation",
            "candidatePatch.destroySandbox.confirm",
            "candidatePatch.destroySandbox.cancel"
        ] {
            XCTAssertTrue(source.contains(identifier), identifier)
        }
        XCTAssertTrue(source.contains("Sandbox destruction is permanent."))
        XCTAssertTrue(source.contains("no other Patch or Sandbox is affected"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceURL.path))
        XCTAssertFalse(SandboxRuntimePolicy.phase2D1Allowlist.contains(.generatedTest))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("build or test execution"))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("credential access"))
        XCTAssertTrue(CandidatePatchService.prohibitedActions.contains("production access"))

        let destroyed = try fixture.service.destroyRevertedSandbox(binding: applied.binding)
        XCTAssertNotNil(destroyed.sandboxDestroyedAt)
        XCTAssertTrue(destroyed.auditEvents.contains { $0.type == .sandboxDestroyed })
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceURL.path))
    }
}

private extension CandidatePatchRevertTests {
    struct AppliedPatch {
        var binding: CandidatePatchAppliedBinding
        var manifest: CandidatePatchManifest
    }

    struct Fixture {
        static let originalOrders = "export const orders = ['a']\n"
        static let replacementOrders = "export const orders = ['a', 'b'] // candidate\n"

        var container: URL
        var legacy: URL
        var agent: URL
        var lifecycle: SandboxLifecycleService
        var firstSandboxID: SandboxID
        var secondSandboxID: SandboxID
        var workspaceID = UUID()
        var authenticatedSessionID = UUID()
        var claimID = "claim-orders-boundary"

        init() throws {
            container = FileManager.default.temporaryDirectory
                .appendingPathComponent("FDECandidatePatchRevert-\(UUID().uuidString)", isDirectory: true)
            legacy = container.appendingPathComponent("Legacy", isDirectory: true)
            agent = container.appendingPathComponent("Agent", isDirectory: true)
            let storage = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
            try FileManager.default.createDirectory(
                at: legacy.appendingPathComponent("src", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
            try Data(Self.originalOrders.utf8).write(
                to: legacy.appendingPathComponent("src/orders.ts")
            )
            try Data("legacy fixture\n".utf8).write(to: legacy.appendingPathComponent("README.md"))
            lifecycle = SandboxLifecycleService(storageRoot: storage, agentWorkspaceRoots: [agent])
            firstSandboxID = try lifecycle.createSandbox(
                sourceRoot: legacy,
                approvedLegacyRoot: legacy
            ).descriptor.sandboxID
            secondSandboxID = try lifecycle.createSandbox(
                sourceRoot: legacy,
                approvedLegacyRoot: legacy
            ).descriptor.sandboxID
        }

        var service: CandidatePatchService { CandidatePatchService(lifecycle: lifecycle) }

        mutating func cleanup() { try? FileManager.default.removeItem(at: container) }

        func workspaceURL(_ sandboxID: SandboxID) throws -> URL {
            try SandboxPathResolver(storageRoot: lifecycle.storageRoot)
                .resolve(sandboxID: sandboxID, relativePath: ".")
        }

        func legacyFingerprint() throws -> String {
            try CandidatePatchLegacyIntegrityMonitor().capture(root: legacy).fingerprint
        }

        func preparePatch(sandboxID: SandboxID) throws -> CandidatePatchPlan {
            let inspection = try lifecycle.inspectSandbox(sandboxID)
            let orders = try XCTUnwrap(
                inspection.sourceManifest.files.first { $0.relativeCanonicalPath == "src/orders.ts" }
            )
            let evidence = CandidatePatchEvidence(
                claimID: claimID,
                statement: "The inspected order module is the grounded integration boundary.",
                evidenceReferences: [AssessmentEvidenceReference(
                    source: .inspectedFile,
                    path: "src/orders.ts",
                    fact: "The order module was directly inspected.",
                    claimLevel: .sourceBehaviorConfirmed,
                    observationStatus: .directlyRead,
                    sourceComponent: "src",
                    safeEvidenceSummary: "The module exposes the order boundary.",
                    workspaceSnapshotIdentifier: inspection.sourceManifest.snapshotID
                )],
                confidence: .high,
                material: true
            )
            let assessment = CandidatePatchAssessmentContext(
                assessmentID: "phase-2c-revert-fixture",
                generatedAt: Date(),
                sourceSnapshotID: inspection.sourceManifest.snapshotID,
                canonicalLegacyRoot: inspection.sourceManifest.canonicalSourceRoot,
                compatibilityDecision: .yes,
                evidence: [evidence]
            )
            return try service.preparePlan(CandidatePatchPlanRequest(
                sandboxID: sandboxID,
                selectedLegacyRoot: legacy,
                trustedLegacyRoot: legacy,
                agentWorkspaceRoots: [agent],
                assessment: assessment,
                requestedOutcome: "Create a reversible isolated candidate change.",
                proposedOperations: [
                    CandidatePatchProposedOperation(
                        relativePath: "src/orders.ts",
                        operationType: .replaceTextFile,
                        proposedContent: Self.replacementOrders,
                        expectedPreimageSHA256: orders.sha256,
                        purpose: "Modify the isolated order boundary.",
                        evidenceClaimIDs: [claimID],
                        risk: .medium,
                        impact: "Changes only the selected Sandbox."
                    ),
                    CandidatePatchProposedOperation(
                        relativePath: "src/candidate-adapter.ts",
                        operationType: .createTextFile,
                        proposedContent: "export const candidateAdapter = true\n",
                        purpose: "Add an isolated adapter candidate.",
                        evidenceClaimIDs: [claimID],
                        risk: .low,
                        impact: "Adds one file only in the selected Sandbox."
                    )
                ],
                approvedScope: ["src"],
                expectedBehavior: ["Expose a review-only candidate."],
                validationRequiredLater: ["Build and test remain unavailable."],
                rollbackApproach: "Restore preimages and remove only Patch-created files.",
                unknowns: ["Runtime behavior is unverified."]
            ))
        }

        func applyPatch(sandboxID: SandboxID) throws -> AppliedPatch {
            let plan = try preparePatch(sandboxID: sandboxID)
            let approvalID = UUID()
            _ = try service.recordApprovalRequest(
                sandboxID: sandboxID,
                patchID: plan.patchID,
                planID: plan.planID,
                approvalRequestID: approvalID
            )
            let taskID = UUID()
            let provenance = CandidatePatchApprovalProvenance(
                source: .testFixture,
                workspaceID: workspaceID,
                taskID: taskID,
                planID: plan.planID,
                planRevision: plan.revision,
                approvalRequestID: approvalID,
                assessmentID: "phase-2c-revert-fixture",
                sourceSnapshotID: plan.sourceSnapshotID,
                canonicalLegacyRoot: plan.legacyIntegrityBaseline.canonicalLegacyRoot,
                authenticatedUserSessionID: authenticatedSessionID,
                appSessionID: UUID(),
                confirmationStepID: UUID(),
                timestamp: Date(),
                controllerPath: "CandidatePatchRevertTests.fixture",
                uiAction: "testFixture.approve"
            )
            _ = try service.recordDecision(
                sandboxID: sandboxID,
                patchID: plan.patchID,
                decision: .approve,
                decidedBy: "fixture-reviewer",
                rationale: "Approve isolated fixture Patch.",
                approvalRequestID: approvalID,
                approvalProvenance: provenance
            )
            let result = try service.apply(sandboxID: sandboxID, patchID: plan.patchID)
            return AppliedPatch(
                binding: try service.appliedBinding(sandboxID: sandboxID, patchID: plan.patchID),
                manifest: result.manifest
            )
        }
    }

    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
}
