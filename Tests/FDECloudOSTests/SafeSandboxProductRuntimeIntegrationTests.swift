import Foundation
import XCTest
@testable import FDECloudOS

final class SafeSandboxProductRuntimeIntegrationTests: XCTestCase {
    func testOneLineChineseRootAssertionStopsAtSentenceBoundary() {
        let input = "请仅对当前 Legacy Workspace 执行 Phase 2D.0 安全沙箱验收。开始前确认当前 Legacy 根目录为 /tmp/fde-public-fixture/legacy。不得使用旧路径，不得修改原始项目，不得开始 Phase 2D.1。"

        XCTAssertEqual(
            SafeSandboxAcceptanceRequest.assertedAbsoluteRoots(in: input),
            ["/tmp/fde-public-fixture/legacy"]
        )
    }

    func testChineseAndEnglishRequestsSelectDedicatedMissionBeforeWorkspaceSearch() {
        let parser = MissionIntentParser()
        let classifier = AgentMissionClassifier()
        let chinese = "请仅对当前 Legacy Workspace 执行 Phase 2D.0 安全沙箱验收。不得修改原始项目。"
        let english = "Create and validate an isolated sandbox for the current Legacy workspace."

        for input in [chinese, english] {
            let intent = parser.parse(input)
            XCTAssertEqual(intent.intentType, .safeSandboxAcceptance)
            XCTAssertEqual(MissionExecutionSemantic(intent: intent), .safeSandboxAcceptance)
            XCTAssertEqual(
                classifier.conversationMode(for: input, intent: intent, hasActiveRuntimeTask: false),
                .executableEngineeringTask
            )
            XCTAssertFalse(classifier.requiresReadOnlyRuntime(input, intent: intent))
            XCTAssertFalse(classifier.isWorkspaceQuestion(input, intent: intent))
            XCTAssertTrue(intent.constraints.contains(.readOnly))
            XCTAssertTrue(intent.constraints.contains(.noNetwork))
            XCTAssertTrue(intent.expectedOutputs.contains(.safeSandboxAcceptanceReport))
        }
    }

    func testSelectedDeveloperRootReplacesStaleDesktopRootAndBypassesGenericSubmit() async throws {
        let workspaceID = UUID()
        let staleWorkspace = Workspace(
            id: workspaceID,
            name: "SyntheticLegacy",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: "/tmp/fde-stale-fixture/legacy"
        )
        let selectedWorkspace = Workspace(
            id: workspaceID,
            name: "SyntheticLegacy",
            role: .fde,
            createdAt: staleWorkspace.createdAt,
            localProjectRoot: "/tmp/fde-public-fixture/legacy"
        )
        let input = """
        请仅对当前 Legacy Workspace 执行 Phase 2D.0 安全沙箱验收。
        开始前确认当前 Legacy 根目录为 /tmp/fde-public-fixture/legacy。
        """
        var session = AgentSession(workspace: staleWorkspace, userGoal: input)
        let runtime = SafeSandboxRouteSpy()

        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: selectedWorkspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertNotNil(result.task)
        XCTAssertEqual(session.workspaceContext.localProjectRoot, "/tmp/fde-public-fixture/legacy")
        let capturedRoots = await runtime.safeSandboxRoots()
        let genericSubmitCount = await runtime.genericSubmitCount()
        let recordedEvents = await runtime.events()
        XCTAssertEqual(capturedRoots, ["/tmp/fde-public-fixture/legacy"])
        XCTAssertEqual(genericSubmitCount, 0)
        let userEvent = try XCTUnwrap(recordedEvents.first { $0.type == .userMessageReceived })
        XCTAssertEqual(userEvent.payload["selected_route"], AgentRequestRoute.safeSandboxAcceptance.rawValue)
        XCTAssertEqual(userEvent.payload["mission_semantic"], MissionExecutionSemantic.safeSandboxAcceptance.rawValue)
    }

    func testConversationResumeRebindsRecoveryContextToNewSelectedRoot() async throws {
        let workspaceID = UUID()
        let oldWorkspace = Workspace(
            id: workspaceID,
            name: "SyntheticLegacy",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: "/tmp/fde-stale-fixture/legacy"
        )
        let newWorkspace = Workspace(
            id: workspaceID,
            name: "SyntheticLegacy",
            role: .fde,
            createdAt: oldWorkspace.createdAt,
            localProjectRoot: "/tmp/fde-public-fixture/legacy"
        )
        var session = AgentSession(workspace: oldWorkspace, userGoal: "Previous conversation")
        let runtime = SafeSandboxRouteSpy()

        _ = try await AgentRuntimeCoordinator().resumeMission(
            reply: "run safe sandbox acceptance for /tmp/fde-public-fixture/legacy",
            workspace: newWorkspace,
            session: &session,
            runtime: runtime
        )

        XCTAssertEqual(session.workspaceContext.localProjectRoot, newWorkspace.localProjectRoot)
        let capturedRoots = await runtime.safeSandboxRoots()
        let genericSubmitCount = await runtime.genericSubmitCount()
        XCTAssertEqual(capturedRoots, [newWorkspace.localProjectRoot!])
        XCTAssertEqual(genericSubmitCount, 0)
    }

    func testRealRuntimeRunsManifestBackedLifecycleAndDestroysSandbox() async throws {
        let fixture = try makePublicDemoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let ordersURL = fixture.legacy.appendingPathComponent("src/orders.ts")
        let ordersBefore = try Data(contentsOf: ordersURL)
        let sourceBefore = try SourceSnapshotBuilder().build(root: fixture.legacy)
        XCTAssertEqual(sourceBefore.includedFileCount, 8)
        XCTAssertEqual(sourceBefore.excludedItemCount, 0)
        let input = """
        请仅对当前 Legacy Workspace 执行 Phase 2D.0 安全沙箱验收。
        开始前确认当前 Legacy 根目录为 \(fixture.legacy.path)。
        不得使用旧路径，不得修改原始项目，不得开始 Phase 2D.1。
        """
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let eventBus = RuntimeEventBus()
        let lifecycle = SandboxLifecycleService(storageRoot: fixture.sandboxes)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: InMemoryEventStream(eventBus: eventBus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: lifecycle
        )
        var session = AgentSession(workspace: fixture.workspace, userGoal: input)

        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: fixture.workspace,
            session: &session,
            runtime: kernel
        )

        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.state, .completed)
        let allEvents = try await persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: nil)
        let taskEvents = allEvents.filter { $0.taskID == task.id }.sorted { $0.sequence < $1.sequence }
        XCTAssertFalse(taskEvents.contains { $0.type == .toolCalled })
        XCTAssertFalse(taskEvents.contains { $0.payload["command"] == "engineering.search_files" })

        let activityEvents = taskEvents.filter { $0.payload["lifecycle_event"] == "SAFE_SANDBOX_ACTIVITY" }
        let productPhases = activityEvents.compactMap {
            $0.payload["sandbox_activity_phase"].flatMap(SandboxRuntimeActivityPhase.init(rawValue:))
        }.filter { SandboxRuntimeActivityPhase.productAcceptancePhases.contains($0) }
        XCTAssertEqual(productPhases, SandboxRuntimeActivityPhase.productAcceptancePhases)
        XCTAssertTrue(activityEvents.allSatisfy { $0.payload["runtime_owned_activity"] == "true" })
        XCTAssertTrue(activityEvents.allSatisfy { $0.payload["state"] == TaskState.running.rawValue })

        let readyEvent = try XCTUnwrap(activityEvents.first {
            $0.payload["sandbox_activity_phase"] == SandboxRuntimeActivityPhase.sandboxReady.rawValue
        })
        let destroyEvent = try XCTUnwrap(activityEvents.first {
            $0.payload["sandbox_activity_phase"] == SandboxRuntimeActivityPhase.destroyingSandbox.rawValue
        })
        XCTAssertLessThan(readyEvent.sequence, destroyEvent.sequence)
        XCTAssertEqual(readyEvent.payload["sandbox_status"], SandboxStatus.ready.rawValue)
        XCTAssertEqual(readyEvent.payload["integrity_status"], SandboxIntegrityStatus.passed.rawValue)
        XCTAssertNotNil(readyEvent.payload["source_snapshot_id"])
        XCTAssertNotNil(readyEvent.payload["sandbox_id"])

        let completed = try XCTUnwrap(taskEvents.last { $0.type == .taskCompleted })
        XCTAssertEqual(
            completed.payload["canonical_legacy_root"],
            try SandboxFileSystem.canonicalExistingDirectory(fixture.legacy).path
        )
        XCTAssertEqual(completed.payload["source_availability"], "local")
        XCTAssertEqual(completed.payload["manifest_backed"], "true")
        XCTAssertEqual(completed.payload["hash_validation_passed"], "true")
        XCTAssertEqual(completed.payload["inode_isolation_passed"], "true")
        XCTAssertEqual(completed.payload["sensitive_exclusion_passed"], "true")
        XCTAssertEqual(completed.payload["original_legacy_before_integrity"], SourceIntegrityState.unchanged.rawValue)
        XCTAssertEqual(completed.payload["original_legacy_after_integrity"], SourceIntegrityState.unchanged.rawValue)
        XCTAssertEqual(completed.payload["sandbox_destroyed"], "true")
        XCTAssertEqual(completed.payload["phase_2d_1_started"], "false")
        XCTAssertEqual(completed.payload["generic_file_search_invoked"], "false")
        XCTAssertFalse(completed.payload["source_snapshot_id", default: ""].isEmpty)
        XCTAssertFalse(completed.payload["sandbox_id", default: ""].isEmpty)
        XCTAssertEqual(Int(completed.payload["included_file_count", default: ""]), sourceBefore.includedFileCount)
        XCTAssertEqual(Int(completed.payload["excluded_item_count", default: ""]), sourceBefore.excludedItemCount)
        XCTAssertTrue(completed.payload["detail", default: ""].contains("Phase 2D.1 started: no"))

        let sourceAfter = try SourceSnapshotBuilder().build(root: fixture.legacy)
        XCTAssertEqual(sourceAfter.snapshotID, sourceBefore.snapshotID)
        XCTAssertTrue(try lifecycle.listActiveSandboxes().isEmpty)
        XCTAssertEqual(try Data(contentsOf: ordersURL), ordersBefore)
    }

    func testMismatchingAbsoluteRootFailsClosedWithoutCreatingOrSearching() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.container) }
        let other = fixture.container.appendingPathComponent("OtherLegacy", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let runtime = try await makeKernel(fixture: fixture)
        var session = AgentSession(workspace: fixture.workspace, userGoal: "sandbox")
        let input = "run safe sandbox acceptance; expected root \(other.path)"
        XCTAssertEqual(SafeSandboxAcceptanceRequest.assertedAbsoluteRoots(in: input), [other.path])

        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: fixture.workspace,
            session: &session,
            runtime: runtime.kernel
        )

        let task = try XCTUnwrap(result.task)
        XCTAssertEqual(task.state, .failed)
        let events = try await runtime.persistence.loadEvents(workspaceID: fixture.workspace.id, taskID: task.id)
        let failure = try XCTUnwrap(events.last { $0.payload["failure_category"] != nil })
        XCTAssertEqual(failure.payload["failure_category"], SafeSandboxAcceptanceFailureCategory.workspaceRootMismatch.rawValue)
        XCTAssertEqual(failure.payload["generic_file_search_invoked"], "false")
        XCTAssertFalse(failure.payload.values.joined(separator: " ").contains(other.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sandboxes.path))
    }

    func testWorkspaceNotSelectedAndAgentWorkspaceSourceReturnSanitizedCategories() async throws {
        let missingFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: missingFixture.container) }
        var noRootWorkspace = missingFixture.workspace
        noRootWorkspace.localProjectRoot = nil
        let missingRuntime = try await makeKernel(fixture: missingFixture)
        var missingSession = AgentSession(workspace: noRootWorkspace, userGoal: "sandbox")
        let missingResult = try await AgentRuntimeCoordinator().startMission(
            input: "run safe sandbox acceptance",
            workspace: noRootWorkspace,
            session: &missingSession,
            runtime: missingRuntime.kernel
        )
        let missingTask = try XCTUnwrap(missingResult.task)
        let missingEvents = try await missingRuntime.persistence.loadEvents(
            workspaceID: noRootWorkspace.id,
            taskID: missingTask.id
        )
        XCTAssertEqual(
            missingEvents.last { $0.payload["failure_category"] != nil }?.payload["failure_category"],
            SafeSandboxAcceptanceFailureCategory.workspaceNotSelected.rawValue
        )

        let agentFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: agentFixture.container) }
        var agentAsLegacy = agentFixture.workspace
        agentAsLegacy.localProjectRoot = agentFixture.agent.path
        agentAsLegacy.localAgentProjectRoot = agentFixture.agent.path
        let agentRuntime = try await makeKernel(fixture: agentFixture)
        var agentSession = AgentSession(workspace: agentAsLegacy, userGoal: "sandbox")
        let agentResult = try await AgentRuntimeCoordinator().startMission(
            input: "create and validate an isolated sandbox",
            workspace: agentAsLegacy,
            session: &agentSession,
            runtime: agentRuntime.kernel
        )
        let agentTask = try XCTUnwrap(agentResult.task)
        let agentEvents = try await agentRuntime.persistence.loadEvents(
            workspaceID: agentAsLegacy.id,
            taskID: agentTask.id
        )
        XCTAssertEqual(
            agentEvents.last { $0.payload["failure_category"] != nil }?.payload["failure_category"],
            SafeSandboxAcceptanceFailureCategory.agentWorkspaceRejected.rawValue
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: agentFixture.sandboxes.path))
    }

    func testSandboxActivityLeavesIdleAndUsesAggregateManifestMetadata() {
        let workspaceID = UUID()
        let taskID = UUID()
        let event = ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: .stateUpdated,
            sequence: 1,
            timestamp: Date(),
            summary: SandboxRuntimeActivityPhase.verifyingSHA256.rawValue,
            payload: SandboxActivitySnapshot(
                sandboxID: SandboxID().rawValue,
                sourceSnapshotID: String(repeating: "a", count: 64),
                status: .validating,
                includedFileCount: 3,
                excludedItemCount: 2,
                integrityStatus: .notValidated,
                sourceUnchanged: true
            ).eventPayload.merging([
                "state": TaskState.running.rawValue,
                "lifecycle_event": "SAFE_SANDBOX_ACTIVITY",
                "sandbox_activity_phase": SandboxRuntimeActivityPhase.verifyingSHA256.rawValue
            ]) { current, _ in current }
        )
        let activity = AgentConversationActivityReducer.reduce(
            AgentConversationActivity.local(
                requestID: UUID(),
                dialogID: UUID(),
                scope: .engineeringTask
            ),
            event: event
        )

        XCTAssertEqual(activity.kind, .verifyingFileHashes)
        XCTAssertEqual(activity.label, "Verifying SHA-256…")
        XCTAssertNotEqual(activity.kind, .idle)
        XCTAssertEqual(activity.metadata.sandbox?.includedFileCount, 3)
        XCTAssertNil(activity.metadata.relativePath)
    }

    func testPublicMissionSurfaceExposesReadOnlyInspectionAssessmentAndDedicatedSandboxWhilePhase2D1RemainsUnavailable() async throws {
        let parser = MissionIntentParser()
        let inspection = parser.parse("review README.md")
        let assessment = parser.parse("Can this system support a customer service AI agent?")
        let sandboxInput = "Create and validate an isolated sandbox for the current Legacy workspace."
        let sandbox = parser.parse(sandboxInput)

        XCTAssertEqual(inspection.intentType, .inspectWorkspace)
        XCTAssertEqual(MissionExecutionSemantic(intent: inspection), .readOnlyWorkspaceInspection)
        XCTAssertEqual(assessment.intentType, .aiAgentCompatibilityAssessment)
        XCTAssertEqual(MissionExecutionSemantic(intent: assessment), .readOnlyWorkspaceInspection)
        XCTAssertEqual(sandbox.intentType, .safeSandboxAcceptance)
        XCTAssertEqual(MissionExecutionSemantic(intent: sandbox), .safeSandboxAcceptance)
        XCTAssertEqual(ReadOnlyInspectionPolicy.allowedTools, [
            "engineering.list_directory",
            "engineering.inspect_project",
            "engineering.search_files",
            "engineering.search_code",
            "engineering.read_file"
        ])

        let workspace = Workspace(
            id: UUID(),
            name: "SyntheticLegacy",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: "/tmp/fde-public-fixture/legacy"
        )
        var session = AgentSession(workspace: workspace, userGoal: sandboxInput)
        let runtime = SafeSandboxRouteSpy()
        let result = try await AgentRuntimeCoordinator().startMission(
            input: sandboxInput,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )
        let safeSandboxRoots = await runtime.safeSandboxRoots()
        let genericSubmitCount = await runtime.genericSubmitCount()
        let recordedEvents = await runtime.events()

        XCTAssertNotNil(result.task)
        XCTAssertEqual(safeSandboxRoots, [workspace.localProjectRoot!])
        XCTAssertEqual(genericSubmitCount, 0)
        XCTAssertEqual(
            recordedEvents.first { $0.type == .userMessageReceived }?.payload["selected_route"],
            AgentRequestRoute.safeSandboxAcceptance.rawValue
        )
        XCTAssertTrue(SandboxRuntimePolicy.phase2D0Allowlist.isEmpty)
        XCTAssertFalse(SandboxRuntimeActivityPhase.productAcceptancePhases.contains { phase in
            phase.rawValue.localizedCaseInsensitiveContains("patch")
                || phase.rawValue.localizedCaseInsensitiveContains("test generation")
        })
    }

    func testLiveWorkspaceProductRuntimeAcceptanceWhenExplicitlyEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FDE_RUN_LIVE_PRODUCT_RUNTIME_ACCEPTANCE"] == "1",
              let rootPath = environment["FDE_LIVE_LEGACY_ROOT"],
              let storagePath = environment["FDE_LIVE_SANDBOX_ROOT"] else {
            throw XCTSkip("Set the explicit live-workspace product-runtime acceptance environment variables to run.")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let storage = URL(fileURLWithPath: storagePath, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let workspace = Workspace(
            id: UUID(),
            name: "LiveLegacyFixture",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: root.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let eventBus = RuntimeEventBus()
        let lifecycle = SandboxLifecycleService(storageRoot: storage)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: InMemoryEventStream(eventBus: eventBus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: lifecycle
        )
        let input = """
        请仅对当前 Legacy Workspace 执行 Phase 2D.0 安全沙箱验收。
        开始前确认当前 Legacy 根目录为 \(root.path)。
        不得使用旧路径，不得修改原始项目，不得开始 Phase 2D.1。
        """
        var session = AgentSession(workspace: workspace, userGoal: input)

        let result = try await AgentRuntimeCoordinator().startMission(
            input: input,
            workspace: workspace,
            session: &session,
            runtime: kernel
        )
        let task = try XCTUnwrap(result.task)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        if task.state != .completed {
            let category = events.last { $0.payload["failure_category"] != nil }?
                .payload["failure_category"] ?? "missing_failure_category"
            XCTFail("Live product runtime acceptance failed closed: \(category)")
            return
        }
        let completed = try XCTUnwrap(events.last { $0.type == .taskCompleted })
        XCTAssertEqual(completed.payload["canonical_legacy_root"], root.path)
        XCTAssertEqual(completed.payload["manifest_backed"], "true")
        XCTAssertEqual(completed.payload["sandbox_destroyed"], "true")
        XCTAssertEqual(completed.payload["phase_2d_1_started"], "false")
        XCTAssertTrue(try lifecycle.listActiveSandboxes().isEmpty)
        print(
            "FDE_LIVE_PRODUCT_RUNTIME_SANDBOX_ACCEPTANCE "
            + "root=\(completed.payload["canonical_legacy_root"] ?? "") "
            + "snapshot_id=\(completed.payload["source_snapshot_id"] ?? "") "
            + "sandbox_id=\(completed.payload["sandbox_id"] ?? "") "
            + "included=\(completed.payload["included_file_count"] ?? "") "
            + "excluded=\(completed.payload["excluded_item_count"] ?? "") "
            + "hashes=\(completed.payload["hash_validation_passed"] ?? "") "
            + "inode_isolation=\(completed.payload["inode_isolation_passed"] ?? "") "
            + "source_before=\(completed.payload["original_legacy_before_integrity"] ?? "") "
            + "source_after=\(completed.payload["original_legacy_after_integrity"] ?? "") "
            + "destroyed=\(completed.payload["sandbox_destroyed"] ?? "") "
            + "phase_2d_1_started=\(completed.payload["phase_2d_1_started"] ?? "")"
        )
    }
}

private extension SafeSandboxProductRuntimeIntegrationTests {
    struct Fixture {
        var container: URL
        var legacy: URL
        var agent: URL
        var sandboxes: URL
        var workspace: Workspace
    }

    struct KernelFixture {
        var persistence: InMemoryPersistenceStore
        var kernel: RuntimeKernel
    }

    func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDESafeSandboxProductRuntime-\(UUID().uuidString)", isDirectory: true)
        let legacy = container.appendingPathComponent("Legacy", isDirectory: true)
        let agent = container.appendingPathComponent("Agent", isDirectory: true)
        let sandboxes = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try Data("print(\"legacy\")\n".utf8).write(to: legacy.appendingPathComponent("Sources/App.swift"))
        try Data("SECRET=excluded\n".utf8).write(to: legacy.appendingPathComponent(".env"))
        try Data("agent\n".utf8).write(to: agent.appendingPathComponent("Agent.swift"))
        let workspace = Workspace(
            id: UUID(),
            name: "SyntheticLegacy",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacy.path,
            localAgentProjectRoot: agent.path
        )
        return Fixture(
            container: container,
            legacy: legacy,
            agent: agent,
            sandboxes: sandboxes,
            workspace: workspace
        )
    }

    func makePublicDemoFixture() throws -> Fixture {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let legacy = repositoryRoot.appendingPathComponent("demo/SyntheticLegacy", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacy.appendingPathComponent("package.json").path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEPublicDemoRuntime-\(UUID().uuidString)", isDirectory: true)
        let agent = container.appendingPathComponent("Agent", isDirectory: true)
        let sandboxes = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try Data("synthetic agent\n".utf8).write(to: agent.appendingPathComponent("Agent.txt"))
        let workspace = Workspace(
            id: UUID(),
            name: "SyntheticLegacy",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacy.path,
            localAgentProjectRoot: agent.path
        )
        return Fixture(
            container: container,
            legacy: legacy,
            agent: agent,
            sandboxes: sandboxes,
            workspace: workspace
        )
    }

    func makeKernel(fixture: Fixture) async throws -> KernelFixture {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(fixture.workspace)
        let eventBus = RuntimeEventBus()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: InMemoryEventStream(eventBus: eventBus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: SandboxLifecycleService(storageRoot: fixture.sandboxes)
        )
        return KernelFixture(persistence: persistence, kernel: kernel)
    }
}

private actor SafeSandboxRouteSpy: AgentRuntimeExecuting {
    private var genericSubmissions = 0
    private var roots: [String] = []
    private var recordedEvents: [ExecutionEvent] = []

    func submitTask(input: String, workspace: Workspace) -> FDETask {
        genericSubmissions += 1
        return task(input: input, workspace: workspace)
    }

    func runSafeSandboxAcceptance(input: String, workspace: Workspace) -> FDETask {
        roots.append(workspace.localProjectRoot ?? "")
        return task(input: input, workspace: workspace)
    }

    func requestStepPause(taskID: UUID, reason: String) {}
    func resumeTask(taskID: UUID, instruction: String?) {}
    func changeTaskApproach(taskID: UUID, instruction: String) {}
    func stopTask(taskID: UUID, reason: String) {}

    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) -> ExecutionEvent {
        let event = ExecutionEvent(
            id: UUID(),
            parentEventID: recordedEvents.last?.id,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: Int64(recordedEvents.count + 1),
            timestamp: Date(),
            summary: summary,
            payload: payload
        )
        recordedEvents.append(event)
        return event
    }

    func genericSubmitCount() -> Int { genericSubmissions }
    func safeSandboxRoots() -> [String] { roots }
    func events() -> [ExecutionEvent] { recordedEvents }

    private func task(input: String, workspace: Workspace) -> FDETask {
        FDETask(
            id: UUID(),
            workspaceID: workspace.id,
            title: "Sandbox acceptance",
            rawInput: input,
            state: .completed,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
    }
}
