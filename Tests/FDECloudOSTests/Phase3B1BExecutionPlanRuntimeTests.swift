import XCTest
@testable import FDECloudOS

final class Phase3B1BExecutionPlanRuntimeTests: XCTestCase {
    func testSQLitePersistsExactlyOneImmutablePlanRevisionAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase3B1B-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let workspace = Workspace(
            id: UUID(),
            name: "Phase 3B.1B SQLite",
            role: .fde,
            createdAt: Date()
        )
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: Phase3B1BPlanRouter(),
            toolExecutor: Phase3B1BRecordingExecutor()
        )

        let task = try await kernel.submitTask(
            input: "Assess this legacy application for an AI agent integration.",
            workspace: workspace,
            origin: makeOrigin()
        )
        let reopened = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await reopened.initialize()
        let plans = try await reopened.loadExecutionPlans(workspaceID: workspace.id, taskID: task.id)

        XCTAssertEqual(plans.count, 1)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.revision.number, 1)
        XCTAssertNoThrow(try plan.validate())
        do {
            try await reopened.saveExecutionPlan(plan)
            XCTFail("SQLite must not replace an immutable plan revision.")
        } catch PersistenceError.executionPlanRevisionAlreadyExists(let planID, let revision) {
            XCTAssertEqual(planID, plan.id)
            XCTAssertEqual(revision, 1)
        }
    }

    func testPlanGenerationPersistsExactlyOneImmutableRevisionAndExactApprovalBinding() async throws {
        let fixture = try await makeFixture()
        let origin = OriginBinding(
            sessionID: UUID(),
            turnID: UUID(),
            requestMessageID: UUID()
        )

        let task = try await fixture.kernel.submitTask(
            input: "Assess this legacy application for an AI agent integration.",
            workspace: fixture.workspace,
            origin: origin
        )

        let plans = try await fixture.persistence.loadExecutionPlans(
            workspaceID: fixture.workspace.id,
            taskID: task.id
        )
        let approvals = try await fixture.persistence.loadApprovalRequests(
            workspaceID: fixture.workspace.id,
            state: .pending
        )
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: task.id
        )

        XCTAssertEqual(task.state, .planned)
        XCTAssertEqual(plans.count, 1)
        let plan = try XCTUnwrap(plans.first)
        XCTAssertEqual(plan.revision.number, 1)
        XCTAssertNil(plan.revision.parentDigest)
        XCTAssertEqual(plan.origin, origin)
        XCTAssertEqual(try PlanDigest.compute(plan), plan.digest)
        XCTAssertNoThrow(try plan.validate())

        XCTAssertEqual(approvals.count, 1)
        let approval = try XCTUnwrap(approvals.first)
        XCTAssertEqual(approval.targetKind, .executionPlan)
        XCTAssertEqual(ExecutionPlanApprovalBinding(metadata: approval.metadata), ExecutionPlanApprovalBinding(plan: plan))

        XCTAssertEqual(events.filter { $0.type == .planGenerated }.count, 1)
        XCTAssertTrue(events.contains {
            $0.type == .planGenerated
                && $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.generated.rawValue
                && $0.payload["plan_digest"] == plan.digest.sha256
        })
        XCTAssertTrue(events.contains {
            $0.type == .stateUpdated
                && $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.validated.rawValue
                && $0.payload["digest_verified"] == "true"
        })
        XCTAssertTrue(events.contains {
            $0.type == .humanApprovalRequested
                && $0.payload["approval_request_id"] == approval.id.uuidString
        })
        XCTAssertFalse(events.contains { $0.type == .contextCompiled })
        XCTAssertFalse(events.contains { $0.type == .toolCalled || $0.type == .stepExecuted })
        XCTAssertFalse(events.contains { $0.payload["state"] == TaskState.running.rawValue })
        let invocationCount = await fixture.executor.invocationCount()
        XCTAssertEqual(invocationCount, 0)

        do {
            try await fixture.persistence.saveExecutionPlan(plan)
            XCTFail("An immutable plan revision must not be overwritten.")
        } catch PersistenceError.executionPlanRevisionAlreadyExists(let planID, let revision) {
            XCTAssertEqual(planID, plan.id)
            XCTAssertEqual(revision, 1)
        }
    }

    func testModifiedPlanAndModifiedApprovalDigestFailValidation() async throws {
        let fixture = try await makeFixture()
        let task = try await fixture.kernel.submitTask(
            input: "Assess this legacy application for an AI agent integration.",
            workspace: fixture.workspace,
            origin: makeOrigin()
        )
        let plans = try await fixture.persistence.loadExecutionPlans(
            workspaceID: fixture.workspace.id,
            taskID: task.id
        )
        let plan = try XCTUnwrap(plans.first)

        var modifiedPlan = plan
        modifiedPlan.summary += " changed"
        XCTAssertThrowsError(try modifiedPlan.validate()) { error in
            XCTAssertEqual(error as? ExecutionPlanValidationError, .digestMismatch)
        }

        let pendingApprovals = try await fixture.persistence.loadApprovalRequests(
            workspaceID: fixture.workspace.id,
            state: .pending
        )
        var approval = try XCTUnwrap(pendingApprovals.first)
        approval.metadata["plan_digest"] = String(repeating: "0", count: 64)
        try await fixture.persistence.saveApprovalRequest(approval)

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                approval.id,
                workspace: fixture.workspace,
                reason: "Approve the altered binding."
            )
            XCTFail("Approval must fail when the bound digest changes.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .bindingMismatch)
        }
        let invocationCount = await fixture.executor.invocationCount()
        XCTAssertEqual(invocationCount, 0)
    }

    func testApprovalRecordsOnlyAndLeavesPlanPlannedWithoutExecutorOrToolEvents() async throws {
        let fixture = try await makeFixture()
        let task = try await fixture.kernel.submitTask(
            input: "Assess this legacy application for an AI agent integration.",
            workspace: fixture.workspace,
            origin: makeOrigin()
        )
        let plans = try await fixture.persistence.loadExecutionPlans(
            workspaceID: fixture.workspace.id,
            taskID: task.id
        )
        let plan = try XCTUnwrap(plans.first)
        let pendingApprovals = try await fixture.persistence.loadApprovalRequests(
            workspaceID: fixture.workspace.id,
            state: .pending
        )
        let request = try XCTUnwrap(pendingApprovals.first)

        let approved = try await fixture.kernel.approveApprovalRequest(
            request.id,
            workspace: fixture.workspace,
            reason: "Plan reviewed."
        )
        let storedTasks = try await fixture.persistence.loadTasks(workspaceID: fixture.workspace.id)
        let storedTask = try XCTUnwrap(storedTasks.first { $0.id == task.id })
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: task.id
        )

        XCTAssertEqual(approved.state, .approved)
        XCTAssertEqual(ExecutionPlanApprovalBinding(metadata: approved.metadata), ExecutionPlanApprovalBinding(plan: plan))
        XCTAssertEqual(approved.metadata["approval_recorded_only"], "true")
        XCTAssertEqual(approved.metadata["runtime_resumed"], "false")
        XCTAssertEqual(storedTask.state, .planned)
        let invocationCount = await fixture.executor.invocationCount()
        XCTAssertEqual(invocationCount, 0)
        XCTAssertFalse(events.contains { $0.type == .toolCalled || $0.type == .stepExecuted })
        XCTAssertFalse(events.contains { $0.payload["state"] == TaskState.running.rawValue })
        XCTAssertTrue(events.contains {
            $0.type == .humanApproved
                && $0.payload["approval_request_id"] == request.id.uuidString
                && $0.payload["execution_started"] == "false"
        })
    }

    private func makeFixture() async throws -> (
        persistence: InMemoryPersistenceStore,
        workspace: Workspace,
        executor: Phase3B1BRecordingExecutor,
        kernel: RuntimeKernel
    ) {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: UUID(),
            name: "Phase 3B.1B",
            role: .fde,
            createdAt: Date()
        )
        try await persistence.saveWorkspace(workspace)
        let executor = Phase3B1BRecordingExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: Phase3B1BPlanRouter(),
            toolExecutor: executor
        )
        return (persistence, workspace, executor, kernel)
    }

    private func makeOrigin() -> OriginBinding {
        OriginBinding(
            sessionID: UUID(),
            turnID: UUID(),
            requestMessageID: UUID()
        )
    }
}

private struct Phase3B1BPlanRouter: ModelRouting {
    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "inspect-project",
                    title: "Inspect the legacy project",
                    intent: "Collect bounded read-only project structure in a later approved execution phase.",
                    toolCallID: "inspect-project-call",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "assessment",
                    title: "Assess AI integration boundaries",
                    intent: "Reason about integration seams after evidence is available.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [
                ToolCall(
                    id: "inspect-project-call",
                    type: .api,
                    command: "engineering.inspect_project",
                    arguments: ["workspace=legacy", "path=."],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [
                RiskSignal(
                    id: "incomplete-context",
                    title: "Workspace evidence has not been collected",
                    severity: .low,
                    mitigation: "Keep conclusions pending until a later controlled execution phase records evidence."
                )
            ],
            confidence: 0.8
        )
    }
}

private actor Phase3B1BRecordingExecutor: ToolExecuting {
    private var count = 0

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        count += 1
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "unexpected",
            standardError: "",
            duration: 0
        )
    }

    func invocationCount() -> Int {
        count
    }
}
