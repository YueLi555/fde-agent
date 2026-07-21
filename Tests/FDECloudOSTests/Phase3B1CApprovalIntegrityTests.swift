import XCTest
@testable import FDECloudOS

final class Phase3B1CApprovalIntegrityTests: XCTestCase {
    func testExactApprovalSuccessBindsOriginAndRemainsPlanOnly() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)

        let approved = try await fixture.kernel.approveApprovalRequest(
            created.approval.id,
            workspace: fixture.workspace,
            reason: "Reviewed exact immutable plan.",
            origin: fixture.origin
        )

        XCTAssertEqual(approved.state, .approved)
        XCTAssertEqual(
            ExecutionPlanApprovalBinding(metadata: approved.metadata),
            ExecutionPlanApprovalBinding(plan: created.plan)
        )
        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 1
        )
    }

    func testConversationOriginMismatchFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)
        let otherOrigin = OriginBinding(
            sessionID: UUID(),
            turnID: fixture.origin.turnID,
            requestMessageID: fixture.origin.requestMessageID
        )

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                created.approval.id,
                workspace: fixture.workspace,
                reason: "Wrong conversation.",
                origin: otherOrigin
            )
            XCTFail("Cross-conversation approval must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .originMismatch)
        }

        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 0
        )
    }

    func testMissingDigestFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)
        var request = created.approval
        request.metadata.removeValue(forKey: "plan_digest")
        try await fixture.persistence.saveApprovalRequest(request)

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                request.id,
                workspace: fixture.workspace,
                reason: "Digest missing.",
                origin: fixture.origin
            )
            XCTFail("Missing digest must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .invalidBinding)
        }

        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 0
        )
    }

    func testCrossWorkspaceApprovalFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)
        let otherWorkspace = Workspace(
            id: UUID(),
            name: "Other workspace",
            role: .fde,
            createdAt: Date()
        )
        try await fixture.persistence.saveWorkspace(otherWorkspace)

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                created.approval.id,
                workspace: otherWorkspace,
                reason: "Cross-workspace attempt.",
                origin: fixture.origin
            )
            XCTFail("Cross-workspace approval must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .bindingMismatch)
        }

        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 0
        )
    }

    func testCrossTaskApprovalFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)
        let otherTaskID = UUID()
        var request = created.approval
        request.taskID = otherTaskID
        request.metadata["task_id"] = otherTaskID.uuidString
        try await fixture.persistence.saveApprovalRequest(request)

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                request.id,
                workspace: fixture.workspace,
                reason: "Cross-task attempt.",
                origin: fixture.origin
            )
            XCTFail("Cross-task approval must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .bindingMismatch)
        }

        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 0
        )
    }

    func testAuthorityBearingDigestMutationsAllFailApproval() async throws {
        let mutations: [(String, (inout ExecutionPlan) -> Void)] = [
            ("tool_call", { $0.toolCalls[0].command = "engineering.search_code" }),
            ("argument", { plan in
                plan.toolCalls[0].arguments = plan.toolCalls[0].arguments.map {
                    $0.hasPrefix("query=") ? "query=Package.swift" : $0
                }
            }),
            ("path", { plan in
                plan.toolCalls[0].arguments = plan.toolCalls[0].arguments.map {
                    $0.hasPrefix("path=") ? "path=Sources" : $0
                }
            }),
            ("workspace_scope", { $0.workspaceScope = .legacyOnly }),
            ("evidence_requirement", { $0.evidenceRequirementIDs.append("additional-review-evidence") }),
            ("risk", { $0.risks[0].title = "Changed risk authority" }),
            ("summary", { $0.summary += " changed" }),
            ("constraint", { $0.constraints.executionEnabled = true })
        ]

        for (name, mutate) in mutations {
            let sqlite = try await makeSQLiteFixture(label: name)
            defer { try? FileManager.default.removeItem(at: sqlite.directory) }
            let created = try await createPlan(
                persistence: sqlite.persistence,
                workspace: sqlite.workspace,
                kernel: sqlite.kernel,
                origin: sqlite.origin
            )
            var corrupted = created.plan
            mutate(&corrupted)
            XCTAssertNotEqual(try PlanDigest.compute(corrupted), created.plan.digest, name)
            try overwritePersistedPlanJSON(corrupted, databaseURL: sqlite.databaseURL)

            do {
                _ = try await sqlite.kernel.approveApprovalRequest(
                    created.approval.id,
                    workspace: sqlite.workspace,
                    reason: "Attempt approval after \(name) mutation.",
                    origin: sqlite.origin
                )
                XCTFail("\(name) mutation must fail approval.")
            } catch {
                XCTAssertEqual(error as? ExecutionPlanValidationError, .digestMismatch, name)
            }

            try await assertPlanOnlyAuthority(
                persistence: sqlite.persistence,
                workspace: sqlite.workspace,
                taskID: created.task.id,
                executor: sqlite.executor,
                expectedHumanApprovedCount: 0
            )
        }
    }

    func testRevisionSupersedesPendingApprovalAndPreservesImmutableHistory() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)
        let revision2 = try makeRevision2(from: created.plan)

        let revision2Approval = try await fixture.kernel.reviseExecutionPlan(
            revision2,
            workspace: fixture.workspace
        )
        let history = try await fixture.persistence.loadExecutionPlans(
            workspaceID: fixture.workspace.id,
            taskID: created.task.id
        )
        let loadedRevision1Approval = try await fixture.persistence.loadApprovalRequest(
            id: created.approval.id
        )
        let revision1Approval = try XCTUnwrap(loadedRevision1Approval)

        XCTAssertEqual(history.map(\.revision.number), [1, 2])
        XCTAssertEqual(history[0], created.plan)
        XCTAssertEqual(history[1].revision.parentDigest, created.plan.digest)
        XCTAssertEqual(revision1Approval.state, .superseded)
        XCTAssertEqual(revision2Approval.state, .pending)
        XCTAssertEqual(
            ExecutionPlanApprovalBinding(metadata: revision2Approval.metadata),
            ExecutionPlanApprovalBinding(plan: revision2)
        )

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                revision1Approval.id,
                workspace: fixture.workspace,
                reason: "Attempt superseded approval.",
                origin: fixture.origin
            )
            XCTFail("Superseded approval must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? ExecutionPlanApprovalError,
                .approvalNotPending(.superseded)
            )
        }
        do {
            try await fixture.persistence.saveExecutionPlan(created.plan)
            XCTFail("Revision 1 must remain immutable.")
        } catch PersistenceError.executionPlanRevisionAlreadyExists(let planID, let revision) {
            XCTAssertEqual(planID, created.plan.id)
            XCTAssertEqual(revision, 1)
        }

        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 0
        )
    }

    func testStaleRevisionApprovalFailsEvenIfRequestIsMadePendingAgain() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)
        _ = try await fixture.kernel.reviseExecutionPlan(
            makeRevision2(from: created.plan),
            workspace: fixture.workspace
        )
        let loadedStaleApproval = try await fixture.persistence.loadApprovalRequest(
            id: created.approval.id
        )
        var stale = try XCTUnwrap(loadedStaleApproval)
        stale.state = .pending
        stale.decidedAt = nil
        stale.decidedByRole = nil
        stale.decisionReason = nil
        try await fixture.persistence.saveApprovalRequest(stale)

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                stale.id,
                workspace: fixture.workspace,
                reason: "Attempt stale revision approval.",
                origin: fixture.origin
            )
            XCTFail("Stale revision must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? ExecutionPlanApprovalError,
                .staleRevision(expected: 2, actual: 1)
            )
        }

        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 0
        )
    }

    func testExpiredApprovalCannotApproveResumeOrCreateAuthority() async throws {
        let fixture = try await makeFixture()
        let created = try await createPlan(in: fixture)
        var expired = created.approval
        expired.expiresAt = Date(timeIntervalSinceNow: -60)
        try await fixture.persistence.saveApprovalRequest(expired)

        do {
            _ = try await fixture.kernel.approveApprovalRequest(
                expired.id,
                workspace: fixture.workspace,
                reason: "Attempt expired approval.",
                origin: fixture.origin
            )
            XCTFail("Expired approval must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .approvalExpired)
        }
        let loadedStoredApproval = try await fixture.persistence.loadApprovalRequest(id: expired.id)
        let stored = try XCTUnwrap(loadedStoredApproval)
        XCTAssertEqual(stored.state, .expired)

        await fixture.kernel.resumeTask(taskID: created.task.id, instruction: "continue")
        _ = try await fixture.kernel.recoverTask(
            taskID: created.task.id,
            instruction: "retry",
            workspace: fixture.workspace
        )
        try await assertPlanOnlyAuthority(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            taskID: created.task.id,
            executor: fixture.executor,
            expectedHumanApprovedCount: 0
        )
    }

    func testColdRestorationPreservesApprovalAsPlanOnlyAndBlocksRecovery() async throws {
        let sqlite = try await makeSQLiteFixture(label: "cold-approved")
        defer { try? FileManager.default.removeItem(at: sqlite.directory) }
        let created = try await createPlan(
            persistence: sqlite.persistence,
            workspace: sqlite.workspace,
            kernel: sqlite.kernel,
            origin: sqlite.origin
        )
        let revision2 = try makeRevision2(from: created.plan)
        let revision2Approval = try await sqlite.kernel.reviseExecutionPlan(
            revision2,
            workspace: sqlite.workspace
        )
        _ = try await sqlite.kernel.approveApprovalRequest(
            revision2Approval.id,
            workspace: sqlite.workspace,
            reason: "Approve before restart.",
            origin: sqlite.origin
        )

        let restoredPersistence = try SQLitePersistenceStore(databaseURL: sqlite.databaseURL)
        try await restoredPersistence.initialize()
        let restoredExecutor = Phase3B1CRecordingExecutor()
        let restoredKernel = RuntimeKernel(
            persistence: restoredPersistence,
            eventBus: RuntimeEventBus(),
            modelRouter: Phase3B1CPlanRouter(),
            toolExecutor: restoredExecutor
        )
        let restoredPlans = try await restoredPersistence.loadExecutionPlans(
            workspaceID: sqlite.workspace.id,
            taskID: created.task.id
        )
        let loadedRestoredApproval = try await restoredPersistence.loadApprovalRequest(
            id: revision2Approval.id
        )
        let restoredApproval = try XCTUnwrap(loadedRestoredApproval)
        let loadedRevision1Approval = try await restoredPersistence.loadApprovalRequest(
            id: created.approval.id
        )
        let restoredRevision1Approval = try XCTUnwrap(loadedRevision1Approval)

        XCTAssertEqual(restoredPlans.count, 2)
        XCTAssertEqual(restoredPlans.map(\.id), [created.plan.id, revision2.id])
        XCTAssertEqual(restoredPlans.map(\.revision.number), [1, 2])
        XCTAssertEqual(restoredPlans.map(\.digest), [created.plan.digest, revision2.digest])
        XCTAssertEqual(restoredPlans[1].revision.parentDigest, restoredPlans[0].digest)
        for plan in restoredPlans {
            XCTAssertEqual(try PlanDigest.compute(plan), plan.digest)
        }
        XCTAssertEqual(restoredRevision1Approval.state, .superseded)
        XCTAssertEqual(restoredApproval.state, .approved)
        await restoredKernel.resumeTask(taskID: created.task.id, instruction: "continue")
        _ = try await restoredKernel.recoverTask(
            taskID: created.task.id,
            instruction: "retry",
            workspace: sqlite.workspace
        )

        try await assertPlanOnlyAuthority(
            persistence: restoredPersistence,
            workspace: sqlite.workspace,
            taskID: created.task.id,
            executor: restoredExecutor,
            expectedHumanApprovedCount: 1
        )
    }

    func testColdRestorationWithCorruptedPlanDigestFailsClosed() async throws {
        let sqlite = try await makeSQLiteFixture(label: "cold-corrupt")
        defer { try? FileManager.default.removeItem(at: sqlite.directory) }
        let created = try await createPlan(
            persistence: sqlite.persistence,
            workspace: sqlite.workspace,
            kernel: sqlite.kernel,
            origin: sqlite.origin
        )
        var corrupted = created.plan
        corrupted.summary += " corrupted after persistence"
        try overwritePersistedPlanJSON(corrupted, databaseURL: sqlite.databaseURL)

        let restoredPersistence = try SQLitePersistenceStore(databaseURL: sqlite.databaseURL)
        try await restoredPersistence.initialize()
        let restoredExecutor = Phase3B1CRecordingExecutor()
        let restoredKernel = RuntimeKernel(
            persistence: restoredPersistence,
            eventBus: RuntimeEventBus(),
            modelRouter: Phase3B1CPlanRouter(),
            toolExecutor: restoredExecutor
        )

        do {
            _ = try await restoredPersistence.loadExecutionPlans(
                workspaceID: sqlite.workspace.id,
                taskID: created.task.id
            )
            XCTFail("Corrupted persisted digest must fail restoration.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanValidationError, .digestMismatch)
        }
        do {
            _ = try await restoredKernel.approveApprovalRequest(
                created.approval.id,
                workspace: sqlite.workspace,
                reason: "Attempt corrupted restored approval.",
                origin: sqlite.origin
            )
            XCTFail("Corrupted restored plan must not approve.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanValidationError, .digestMismatch)
        }
        await restoredKernel.resumeTask(taskID: created.task.id, instruction: "continue")

        let events = try await restoredPersistence.loadEvents(
            workspaceID: sqlite.workspace.id,
            taskID: created.task.id
        )
        let calls = await restoredExecutor.invocationCount()
        XCTAssertEqual(calls, 0)
        XCTAssertFalse(events.contains { $0.type == .humanApproved })
        XCTAssertFalse(events.contains { isExecutionOrEvidenceEvent($0) })
        XCTAssertFalse(events.contains { $0.payload["state"] == TaskState.running.rawValue })
    }

    private struct Fixture {
        var persistence: InMemoryPersistenceStore
        var workspace: Workspace
        var executor: Phase3B1CRecordingExecutor
        var kernel: RuntimeKernel
        var origin: OriginBinding
    }

    private struct SQLiteFixture {
        var directory: URL
        var databaseURL: URL
        var persistence: SQLitePersistenceStore
        var workspace: Workspace
        var executor: Phase3B1CRecordingExecutor
        var kernel: RuntimeKernel
        var origin: OriginBinding
    }

    private struct CreatedPlan {
        var task: FDETask
        var plan: ExecutionPlan
        var approval: ApprovalRequest
    }

    private func makeFixture() async throws -> Fixture {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = makeWorkspace(name: "Phase 3B.1C")
        try await persistence.saveWorkspace(workspace)
        let executor = Phase3B1CRecordingExecutor()
        return Fixture(
            persistence: persistence,
            workspace: workspace,
            executor: executor,
            kernel: RuntimeKernel(
                persistence: persistence,
                eventBus: RuntimeEventBus(),
                modelRouter: Phase3B1CPlanRouter(),
                toolExecutor: executor
            ),
            origin: makeOrigin()
        )
    }

    private func makeSQLiteFixture(label: String) async throws -> SQLiteFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase3B1C-\(label)-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        let workspace = makeWorkspace(name: "Phase 3B.1C SQLite")
        try await persistence.saveWorkspace(workspace)
        let executor = Phase3B1CRecordingExecutor()
        return SQLiteFixture(
            directory: directory,
            databaseURL: databaseURL,
            persistence: persistence,
            workspace: workspace,
            executor: executor,
            kernel: RuntimeKernel(
                persistence: persistence,
                eventBus: RuntimeEventBus(),
                modelRouter: Phase3B1CPlanRouter(),
                toolExecutor: executor
            ),
            origin: makeOrigin()
        )
    }

    private func createPlan(in fixture: Fixture) async throws -> CreatedPlan {
        try await createPlan(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            kernel: fixture.kernel,
            origin: fixture.origin
        )
    }

    private func createPlan(
        persistence: any PersistenceStore,
        workspace: Workspace,
        kernel: RuntimeKernel,
        origin: OriginBinding
    ) async throws -> CreatedPlan {
        let task = try await kernel.submitTask(
            input: "Assess this legacy application for an AI agent integration.",
            workspace: workspace,
            origin: origin
        )
        let plans = try await persistence.loadExecutionPlans(
            workspaceID: workspace.id,
            taskID: task.id
        )
        let approvals = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: .pending
        )
        return CreatedPlan(
            task: task,
            plan: try XCTUnwrap(plans.first),
            approval: try XCTUnwrap(approvals.first { $0.taskID == task.id })
        )
    }

    private func makeRevision2(from plan: ExecutionPlan) throws -> ExecutionPlan {
        var steps = plan.steps
        steps[0].title += " after requested changes"
        let createdAt = Date()
        return try ExecutionPlan.make(
            id: plan.id,
            taskID: plan.taskID,
            workspaceID: plan.workspaceID,
            origin: plan.origin,
            missionSemantic: plan.missionSemantic,
            workspaceScope: plan.workspaceScope,
            objective: plan.objective,
            summary: plan.summary + " | revised",
            steps: steps,
            toolCalls: plan.toolCalls,
            evidenceRequirementIDs: plan.evidenceRequirementIDs,
            risks: plan.risks,
            constraints: plan.constraints,
            revision: PlanRevision(
                number: 2,
                parentDigest: plan.digest,
                reason: .humanRequestedChanges,
                createdAt: createdAt
            ),
            createdAt: createdAt
        )
    }

    private func overwritePersistedPlanJSON(
        _ plan: ExecutionPlan,
        databaseURL: URL
    ) throws {
        let connection = try SQLiteConnection(path: databaseURL.path)
        try connection.execute(
            "UPDATE execution_plans SET plan_json = ? WHERE plan_id = ? AND revision = ?;",
            parameters: [
                .text(try JSONCoding.encode(plan)),
                .text(plan.id.uuidString),
                .int(Int64(plan.revision.number))
            ]
        )
    }

    private func assertPlanOnlyAuthority(
        persistence: any PersistenceStore,
        workspace: Workspace,
        taskID: UUID,
        executor: Phase3B1CRecordingExecutor,
        expectedHumanApprovedCount: Int
    ) async throws {
        let tasks = try await persistence.loadTasks(workspaceID: workspace.id)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)
        let calls = await executor.invocationCount()
        XCTAssertEqual(tasks.first(where: { $0.id == taskID })?.state, .planned)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(events.filter { $0.type == .humanApproved }.count, expectedHumanApprovedCount)
        XCTAssertFalse(events.contains { isExecutionOrEvidenceEvent($0) })
        XCTAssertFalse(events.contains { $0.payload["state"] == TaskState.running.rawValue })
    }

    private func isExecutionOrEvidenceEvent(_ event: ExecutionEvent) -> Bool {
        event.type == .toolCalled
            || event.type == .stepExecuted
            || event.payload["tool_result"] != nil
            || event.payload["evidence_id"] != nil
            || event.payload["evidence_claim_id"] != nil
            || event.payload["grounded_answer"] == "true"
    }

    private func makeWorkspace(name: String) -> Workspace {
        Workspace(id: UUID(), name: name, role: .fde, createdAt: Date())
    }

    private func makeOrigin() -> OriginBinding {
        OriginBinding(
            sessionID: UUID(),
            turnID: UUID(),
            requestMessageID: UUID()
        )
    }
}

private struct Phase3B1CPlanRouter: ModelRouting {
    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "search-manifest",
                    title: "Locate the legacy manifest",
                    intent: "Plan a bounded future read-only search for integration evidence.",
                    toolCallID: "search-manifest-call",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "assess-boundaries",
                    title: "Assess AI integration boundaries",
                    intent: "Reason only after a future controlled phase records evidence.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [
                ToolCall(
                    id: "search-manifest-call",
                    type: .api,
                    command: "engineering.search_files",
                    arguments: [
                        "workspace=legacy",
                        "query=package.json",
                        "path=."
                    ],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [
                RiskSignal(
                    id: "evidence-not-collected",
                    title: "Workspace evidence has not been collected",
                    severity: .low,
                    mitigation: "Keep assessment conclusions pending until a later controlled execution phase."
                )
            ],
            confidence: 0.82
        )
    }
}

private actor Phase3B1CRecordingExecutor: ToolExecuting {
    private var calls = 0

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        calls += 1
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "unexpected execution",
            standardError: "",
            duration: 0
        )
    }

    func invocationCount() -> Int {
        calls
    }
}
