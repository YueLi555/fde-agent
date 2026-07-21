import XCTest
@testable import FDECloudOS

final class Phase3B2AReadOnlyAdmissionTests: XCTestCase {
    func testApprovedPlanStartsOneInspectionAndStopsWithoutAssessment() async throws {
        let injectedEvent = ToolExecutionEvent(
            type: .stateUpdated,
            summary: "PATCH",
            payload: ["lifecycle_event": "PATCH"]
        )
        let fixture = try await makeFixture(emittedEvents: [injectedEvent])
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let calls = await fixture.executor.recordedCalls()
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: created.task.id
        )
        let phaseEvents = events.filter { $0.payload["phase"] == "3B.2A" }

        XCTAssertEqual(result.task.state, .waiting)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.command, "engineering.inspect_project")
        XCTAssertEqual(
            phaseEvents.compactMap { $0.payload["lifecycle_event"] },
            [
                ExecutionPlanLifecycleEvent.executionStarted.rawValue,
                ExecutionPlanLifecycleEvent.toolCalled.rawValue,
                ExecutionPlanLifecycleEvent.toolResult.rawValue,
                ExecutionPlanLifecycleEvent.observationCreated.rawValue
            ]
        )
        XCTAssertEqual(
            phaseEvents.first?.payload["state"],
            TaskState.running.rawValue
        )
        XCTAssertEqual(
            phaseEvents.last?.payload["state"],
            TaskState.waiting.rawValue
        )
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        XCTAssertFalse(events.contains { $0.payload["assessment_generated"] == "true" })
        XCTAssertFalse(events.contains { event in
            ["PATCH", "WRITE", "DEPLOY", "RELEASE"].contains(event.payload["lifecycle_event"])
        })
        XCTAssertFalse(events.contains { event in
            let command = event.payload["command"]?.lowercased() ?? ""
            return command.contains("shell")
                || command.contains("git")
                || command.contains("build")
                || command.contains("test")
                || command.contains("deploy")
        })
        XCTAssertEqual(
            phaseEvents.first(where: {
                $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.toolResult.rawValue
            })?.payload["executor_emitted_events_ignored"],
            "1"
        )

        do {
            _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: created.approval.id,
                workspace: fixture.workspace
            )
            XCTFail("A bounded Phase 3B.2A admission must not execute twice.")
        } catch {
            XCTAssertEqual(error as? Phase3B2AReadOnlyAdmissionError, .alreadyAdmitted)
        }
        let callsAfterRepeat = await fixture.executor.recordedCalls()
        XCTAssertEqual(callsAfterRepeat.count, 1)
    }

    func testExecutorReceivesEachEstablishedReadOnlyToolAndNothingElse() async throws {
        for command in ReadOnlyInspectionPolicy.orderedAllowedTools {
            let fixture = try await makeFixture(command: command)
            let created = try await createApprovedPlan(in: fixture)

            let result = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: created.approval.id,
                workspace: fixture.workspace
            )
            let calls = await fixture.executor.recordedCalls()

            XCTAssertEqual(calls.count, 1, command)
            XCTAssertEqual(calls.first?.command, command)
            XCTAssertEqual(result.executedToolCall.command, command)
            XCTAssertTrue(calls.allSatisfy {
                $0.type == .api && ReadOnlyInspectionPolicy.allowedTools.contains($0.command)
            })
        }
    }

    func testForbiddenMutationShellGitBuildTestDeployAndCredentialToolsFailClosed() async throws {
        let forbiddenCommands = [
            "engineering.write_file",
            "shell.exec",
            "git.commit",
            "engineering.build_project",
            "engineering.run_tests",
            "deployment.release",
            "credentials.read"
        ]

        for command in forbiddenCommands {
            let fixture = try await makeSQLiteFixture(label: command.replacingOccurrences(of: ".", with: "-"))
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let created = try await createApprovedPlan(
                persistence: fixture.persistence,
                workspace: fixture.workspace,
                kernel: fixture.kernel,
                origin: fixture.origin
            )
            var forbiddenPlan = created.plan
            forbiddenPlan.toolCalls[0].command = command
            forbiddenPlan.digest = try PlanDigest.compute(forbiddenPlan)
            try overwritePersistedPlan(forbiddenPlan, databaseURL: fixture.databaseURL)
            var forgedApproval = created.approval
            forgedApproval.metadata.merge(ExecutionPlanApprovalBinding(plan: forbiddenPlan).metadata) {
                _, new in new
            }
            try await fixture.persistence.saveApprovalRequest(forgedApproval)

            do {
                _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                    approvalRequestID: forgedApproval.id,
                    workspace: fixture.workspace
                )
                XCTFail("Forbidden command \(command) must fail admission.")
            } catch {
                XCTAssertEqual(
                    error as? ExecutionPlanValidationError,
                    .toolNotAllowed(command),
                    command
                )
            }

            let calls = await fixture.executor.recordedCalls()
            let events = try await fixture.persistence.loadEvents(
                workspaceID: fixture.workspace.id,
                taskID: created.task.id
            )
            XCTAssertEqual(calls.count, 0, command)
            XCTAssertFalse(events.contains {
                $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.executionStarted.rawValue
            }, command)
        }
    }

    func testEvidenceLedgerIsDerivedOnlyFromSuccessfulToolResult() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)
        let result = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: created.task.id
        )
        let toolCalled = try XCTUnwrap(events.first {
            $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.toolCalled.rawValue
        })
        let toolResult = try XCTUnwrap(events.first {
            $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.toolResult.rawValue
        })
        let planGenerated = try XCTUnwrap(events.first { $0.type == .planGenerated })
        let humanApproved = try XCTUnwrap(events.first { $0.type == .humanApproved })
        let supportingEventIDs = result.evidenceLedger.requirements
            .flatMap(\.supportingSuccessfulEventIDs)

        XCTAssertEqual(result.evidence.count, 1)
        XCTAssertEqual(result.evidence.first?.toolResultEventID, toolResult.id)
        XCTAssertTrue(supportingEventIDs.contains(toolResult.id))
        XCTAssertFalse(supportingEventIDs.contains(toolCalled.id))
        XCTAssertFalse(supportingEventIDs.contains(planGenerated.id))
        XCTAssertFalse(supportingEventIDs.contains(humanApproved.id))
        XCTAssertEqual(toolCalled.payload["evidence_created"], "false")
        XCTAssertEqual(
            events.first(where: {
                $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.observationCreated.rawValue
            })?.payload["evidence_created"],
            "true"
        )
    }

    func testFailedToolResultCreatesNoEvidenceLedgerEntry() async throws {
        let fixture = try await makeFixture(exitCode: 1)
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: created.task.id
        )

        XCTAssertEqual(result.toolResult.exitCode, 1)
        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertTrue(result.evidenceLedger.paths.isEmpty)
        XCTAssertTrue(result.evidenceLedger.requirements.allSatisfy {
            $0.supportingSuccessfulEventIDs.isEmpty
        })
        XCTAssertEqual(
            events.first(where: {
                $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.observationCreated.rawValue
            })?.payload["evidence_created"],
            "false"
        )
    }

    func testApprovalDigestMismatchFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)
        var mismatched = created.approval
        mismatched.metadata["plan_digest"] = String(repeating: "0", count: 64)
        try await fixture.persistence.saveApprovalRequest(mismatched)

        do {
            _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: mismatched.id,
                workspace: fixture.workspace
            )
            XCTFail("A mismatched approval digest must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .bindingMismatch)
        }
        try await assertAdmissionDidNotStart(fixture: fixture, taskID: created.task.id)
    }

    func testTaskMismatchFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)
        let otherTaskID = UUID()
        var mismatched = created.approval
        mismatched.taskID = otherTaskID
        mismatched.metadata["task_id"] = otherTaskID.uuidString
        try await fixture.persistence.saveApprovalRequest(mismatched)

        do {
            _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: mismatched.id,
                workspace: fixture.workspace
            )
            XCTFail("Cross-task admission must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .bindingMismatch)
        }
        try await assertAdmissionDidNotStart(fixture: fixture, taskID: created.task.id)
    }

    func testExpiredApprovedRequestFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)
        var expired = created.approval
        expired.expiresAt = Date(timeIntervalSinceNow: -60)
        try await fixture.persistence.saveApprovalRequest(expired)

        do {
            _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: expired.id,
                workspace: fixture.workspace
            )
            XCTFail("An expired approval must fail closed.")
        } catch {
            XCTAssertEqual(error as? Phase3B2AReadOnlyAdmissionError, .approvalExpired)
        }
        try await assertAdmissionDidNotStart(fixture: fixture, taskID: created.task.id)
    }

    func testWorkspaceMismatchFailsClosed() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)
        let otherWorkspace = Workspace(
            id: UUID(),
            name: "Other Phase 3B.2A workspace",
            role: .fde,
            createdAt: Date()
        )
        try await fixture.persistence.saveWorkspace(otherWorkspace)

        do {
            _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: created.approval.id,
                workspace: otherWorkspace
            )
            XCTFail("Cross-workspace admission must fail closed.")
        } catch {
            XCTAssertEqual(error as? ExecutionPlanApprovalError, .bindingMismatch)
        }
        try await assertAdmissionDidNotStart(fixture: fixture, taskID: created.task.id)
    }

    func testOnlyLatestApprovedRevisionCanEnterAdmission() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)
        let revision2 = try makeRevision2(from: created.plan)
        let revision2Request = try await fixture.kernel.reviseExecutionPlan(
            revision2,
            workspace: fixture.workspace
        )
        _ = try await fixture.kernel.approveApprovalRequest(
            revision2Request.id,
            workspace: fixture.workspace,
            reason: "Approve latest revision.",
            origin: fixture.origin
        )

        do {
            _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: created.approval.id,
                workspace: fixture.workspace
            )
            XCTFail("A stale approved revision must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? ExecutionPlanApprovalError,
                .staleRevision(expected: 2, actual: 1)
            )
        }
        try await assertAdmissionDidNotStart(fixture: fixture, taskID: created.task.id)
    }

    func testMissingApprovalFailsBeforeAnyExecution() async throws {
        let fixture = try await makeFixture()
        let missingID = UUID()

        do {
            _ = try await fixture.kernel.executeApprovedExecutionPlanReadOnlyStep(
                approvalRequestID: missingID,
                workspace: fixture.workspace
            )
            XCTFail("A missing approval must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? Phase3B2AReadOnlyAdmissionError,
                .approvalNotFound(missingID)
            )
        }
        let calls = await fixture.executor.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    private struct Fixture {
        var persistence: InMemoryPersistenceStore
        var workspace: Workspace
        var executor: Phase3B2ARecordingExecutor
        var kernel: RuntimeKernel
        var origin: OriginBinding
    }

    private struct SQLiteFixture {
        var directory: URL
        var databaseURL: URL
        var persistence: SQLitePersistenceStore
        var workspace: Workspace
        var executor: Phase3B2ARecordingExecutor
        var kernel: RuntimeKernel
        var origin: OriginBinding
    }

    private struct CreatedPlan {
        var task: FDETask
        var plan: ExecutionPlan
        var approval: ApprovalRequest
    }

    private func makeFixture(
        command: String = "engineering.inspect_project",
        exitCode: Int32 = 0,
        emittedEvents: [ToolExecutionEvent] = []
    ) async throws -> Fixture {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = makeWorkspace(name: "Phase 3B.2A")
        try await persistence.saveWorkspace(workspace)
        let executor = Phase3B2ARecordingExecutor(
            exitCode: exitCode,
            emittedEvents: emittedEvents
        )
        return Fixture(
            persistence: persistence,
            workspace: workspace,
            executor: executor,
            kernel: RuntimeKernel(
                persistence: persistence,
                eventBus: RuntimeEventBus(),
                modelRouter: Phase3B2APlanRouter(command: command),
                toolExecutor: executor
            ),
            origin: makeOrigin()
        )
    }

    private func makeSQLiteFixture(label: String) async throws -> SQLiteFixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase3B2A-\(label)-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("runtime.sqlite")
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        let workspace = makeWorkspace(name: "Phase 3B.2A SQLite")
        try await persistence.saveWorkspace(workspace)
        let executor = Phase3B2ARecordingExecutor()
        return SQLiteFixture(
            directory: directory,
            databaseURL: databaseURL,
            persistence: persistence,
            workspace: workspace,
            executor: executor,
            kernel: RuntimeKernel(
                persistence: persistence,
                eventBus: RuntimeEventBus(),
                modelRouter: Phase3B2APlanRouter(command: "engineering.inspect_project"),
                toolExecutor: executor
            ),
            origin: makeOrigin()
        )
    }

    private func createApprovedPlan(in fixture: Fixture) async throws -> CreatedPlan {
        try await createApprovedPlan(
            persistence: fixture.persistence,
            workspace: fixture.workspace,
            kernel: fixture.kernel,
            origin: fixture.origin
        )
    }

    private func createApprovedPlan(
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
        let pending = try await persistence.loadApprovalRequests(
            workspaceID: workspace.id,
            state: .pending
        )
        let plan = try XCTUnwrap(plans.first)
        let request = try XCTUnwrap(pending.first { $0.taskID == task.id })
        let approved = try await kernel.approveApprovalRequest(
            request.id,
            workspace: workspace,
            reason: "Approve exact read-only plan.",
            origin: origin
        )
        return CreatedPlan(task: task, plan: plan, approval: approved)
    }

    private func assertAdmissionDidNotStart(fixture: Fixture, taskID: UUID) async throws {
        let calls = await fixture.executor.recordedCalls()
        let tasks = try await fixture.persistence.loadTasks(workspaceID: fixture.workspace.id)
        let events = try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: taskID
        )
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(tasks.first(where: { $0.id == taskID })?.state, .planned)
        XCTAssertFalse(events.contains {
            $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.executionStarted.rawValue
        })
        XCTAssertFalse(events.contains { $0.type == .toolCalled || $0.type == .stepExecuted })
    }

    private func overwritePersistedPlan(
        _ plan: ExecutionPlan,
        databaseURL: URL
    ) throws {
        let connection = try SQLiteConnection(path: databaseURL.path)
        try connection.execute(
            "UPDATE execution_plans SET digest = ?, plan_json = ? WHERE plan_id = ? AND revision = ?;",
            parameters: [
                .text(plan.digest.sha256),
                .text(try JSONCoding.encode(plan)),
                .text(plan.id.uuidString),
                .int(Int64(plan.revision.number))
            ]
        )
    }

    private func makeRevision2(from plan: ExecutionPlan) throws -> ExecutionPlan {
        var steps = plan.steps
        steps[0].title += " after review"
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

    private func makeWorkspace(name: String) -> Workspace {
        Workspace(
            id: UUID(),
            name: name,
            role: .fde,
            createdAt: Date(),
            localProjectRoot: FileManager.default.temporaryDirectory.path
        )
    }

    private func makeOrigin() -> OriginBinding {
        OriginBinding(sessionID: UUID(), turnID: UUID(), requestMessageID: UUID())
    }
}

private struct Phase3B2APlanRouter: ModelRouting {
    var command: String

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        let callID = "phase3b2a-read-only-call"
        return StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "phase3b2a-read-only-step",
                    title: "Perform one bounded read-only inspection",
                    intent: "Collect one successful observation for the approved plan.",
                    toolCallID: callID,
                    requiresApproval: false
                ),
                PlanStep(
                    id: "future-assessment",
                    title: "Assessment remains pending",
                    intent: "Do not generate an assessment during Phase 3B.2A.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [
                ToolCall(
                    id: callID,
                    type: .api,
                    command: command,
                    arguments: arguments(for: command),
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [
                RiskSignal(
                    id: "bounded-static-observation",
                    title: "Only one static observation is collected",
                    severity: .low,
                    mitigation: "Stop before assessment or additional execution."
                )
            ],
            confidence: 0.8
        )
    }

    private func arguments(for command: String) -> [String] {
        switch command {
        case "engineering.search_files":
            return ["workspace=legacy", "query=package.json", "path=."]
        case "engineering.search_code":
            return ["workspace=legacy", "query=App", "path=."]
        case "engineering.read_file":
            return ["workspace=legacy", "path=package.json"]
        default:
            return ["workspace=legacy", "path=."]
        }
    }
}

private actor Phase3B2ARecordingExecutor: ToolExecuting {
    private let exitCode: Int32
    private let emittedEvents: [ToolExecutionEvent]
    private var calls: [ToolCall] = []

    init(exitCode: Int32 = 0, emittedEvents: [ToolExecutionEvent] = []) {
        self.exitCode = exitCode
        self.emittedEvents = emittedEvents
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        calls.append(call)
        return ToolExecutionResult(
            callID: call.id,
            exitCode: exitCode,
            standardOutput: exitCode == 0
                ? "Files: 2\nSource files: 1\npackage.json\nsrc/App.swift"
                : "",
            standardError: exitCode == 0 ? "" : "bounded read-only inspection failed",
            duration: 0.001,
            emittedEvents: emittedEvents
        )
    }

    func recordedCalls() -> [ToolCall] {
        calls
    }
}
