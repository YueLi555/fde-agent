import XCTest
@testable import FDECloudOS

final class Phase3B2BEvidenceInspectionLoopTests: XCTestCase {
    func testApprovedPlanStartsBoundedInspection() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await events(for: created.task.id, in: fixture)
        let started = try XCTUnwrap(events.first {
            $0.payload["phase"] == "3B.2B"
                && $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.executionStarted.rawValue
        })

        XCTAssertEqual(started.payload["read_only"], "true")
        XCTAssertEqual(started.payload["mutation_allowed"], "false")
        XCTAssertNotNil(started.payload["bounded_inspection_step_limit"])
        XCTAssertNotNil(started.payload["bounded_tool_limit"])
        XCTAssertNotNil(started.payload["bounded_file_limit"])
        XCTAssertEqual(result.task.state, .waiting)
    }

    func testMultipleReadOnlyStepsExecuteWithDeterministicSelection() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let calls = await fixture.executor.recordedCalls()

        XCTAssertEqual(
            calls.map(\.command),
            [
                "engineering.inspect_project",
                "engineering.read_file",
                "engineering.read_file"
            ]
        )
        XCTAssertEqual(calls.map { argument("path", in: $0) }, [".", "package.json", "src/App.swift"])
        XCTAssertEqual(result.executedSteps.count, 3)
        XCTAssertEqual(result.stopReason, .coverageSufficient)
        XCTAssertTrue(result.coverage.isSufficient)
    }

    func testOnlyEstablishedReadOnlySchemasAreSelected() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )

        XCTAssertTrue(result.executedToolCalls.allSatisfy { call in
            call.type == .api
                && ReadOnlyInspectionPolicy.allowedTools.contains(call.command)
                && ReadOnlyToolSchemas.all[call.command] != nil
        })
        XCTAssertTrue(result.executedToolCalls.allSatisfy { !$0.requiresApproval })
    }

    func testEvidenceComesOnlyFromSuccessfulToolResultsAndObservations() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await events(for: created.task.id, in: fixture)
        let toolResultIDs = Set(events.filter {
            $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.toolResult.rawValue
                && $0.payload["success"] == "true"
        }.map(\.id))
        let prohibitedEvidenceIDs = Set(events.filter { event in
            event.type == .planGenerated
                || event.type == .humanApproved
                || event.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.toolCalled.rawValue
        }.map(\.id))
        let supportingIDs = Set(result.evidenceLedger.requirements.flatMap(\.supportingSuccessfulEventIDs))

        XCTAssertFalse(result.evidence.isEmpty)
        XCTAssertTrue(result.observations.allSatisfy { $0.outcome == .succeeded })
        XCTAssertTrue(result.evidence.allSatisfy { toolResultIDs.contains($0.toolResultEventID) })
        XCTAssertTrue(supportingIDs.isSubset(of: toolResultIDs))
        XCTAssertTrue(supportingIDs.isDisjoint(with: prohibitedEvidenceIDs))
        XCTAssertTrue(events.filter {
            $0.payload["lifecycle_event"] != ExecutionPlanLifecycleEvent.observationCreated.rawValue
        }.allSatisfy { $0.payload["evidence_created"] != "true" })
    }

    func testMissingEvidenceRemainsUnknown() async throws {
        let fixture = try await makeFixture(plan: .rootOnly)
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let staticSource = try XCTUnwrap(result.coverage.requirements.first {
            $0.id == ReadOnlyEvidenceRequirementKind.staticSourceEvidence.rawValue
        })

        XCTAssertEqual(staticSource.status, .unknown)
        XCTAssertTrue(result.coverage.unknown.contains { $0.id == staticSource.id })
        XCTAssertEqual(result.stopReason, .evidenceUnavailable)
        XCTAssertTrue(result.isPartial)
    }

    func testSuccessfulBoundedAbsenceObservationProducesMissing() throws {
        let requirements = try XCTUnwrap(ReadOnlyEvidenceRequirements(
            planRequirementIDs: [ReadOnlyEvidenceRequirementKind.databaseSchemaOrConfig.rawValue]
        ))
        let evidence = ReadOnlyInspectionEvidence(
            toolCallID: "database-search",
            toolName: "engineering.search_files",
            workspaceID: UUID(),
            workspaceIdentity: "legacy",
            targetPath: ".",
            output: "No files found",
            toolCalledEventID: UUID(),
            toolResultEventID: UUID(),
            extractedFacts: ReadOnlySafeFactExtractor.extract(
                toolName: "engineering.search_files",
                targetPath: ".",
                output: "No files found"
            ),
            query: "database schema"
        )

        let coverage = InspectionEvidenceCoverage.derive(
            requirements: requirements,
            evidence: [evidence]
        )

        XCTAssertEqual(coverage.requirements.first?.status, .missing)
        XCTAssertTrue(coverage.isSufficient)
    }

    func testToolFailureCreatesNoEvidence() async throws {
        let fixture = try await makeFixture(failingCommands: Set(ReadOnlyInspectionPolicy.allowedTools))
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await events(for: created.task.id, in: fixture)

        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertTrue(result.evidenceLedger.paths.isEmpty)
        XCTAssertTrue(result.coverage.requirements.allSatisfy { $0.status == .unknown })
        XCTAssertTrue(result.evidenceLedger.requirements.allSatisfy {
            $0.supportingSuccessfulEventIDs.isEmpty
        })
        XCTAssertTrue(events.filter {
            $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.observationCreated.rawValue
        }.allSatisfy { $0.payload["evidence_created"] == "false" })
    }

    func testBudgetExhaustionStopsSafelyInPartialWaitingState() async throws {
        var limits = ReadOnlyInspectionLimits.conservative
        limits.maximumInspectionSteps = 2
        limits.maximumToolCalls = 8
        let fixture = try await makeFixture(limits: limits)
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let calls = await fixture.executor.recordedCalls()
        let events = try await events(for: created.task.id, in: fixture)
        let finalObservation = try XCTUnwrap(events.last {
            $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.observationCreated.rawValue
        })

        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(result.stopReason, .maximumInspectionStepsReached)
        XCTAssertEqual(result.task.state, .waiting)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(finalObservation.payload["budget_exhausted"], "true")
        XCTAssertEqual(finalObservation.payload["waiting_partial"], "true")
        XCTAssertEqual(finalObservation.payload["inspection_continues"], "false")
    }

    func testDeadlineCancelsPendingInspectionAndStopsSafely() async throws {
        var limits = ReadOnlyInspectionLimits.conservative
        limits.budgetOverride = ReadOnlyMissionBudget(
            kind: .projectInspection,
            softLimit: 0.02,
            hardLimit: 0.05,
            providerCallReserve: 0.01,
            finalizationReserve: 0.01
        )
        let fixture = try await makeFixture(
            limits: limits,
            delayNanoseconds: 200_000_000
        )
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await events(for: created.task.id, in: fixture)
        let finalObservation = try XCTUnwrap(events.last {
            $0.payload["lifecycle_event"] == ExecutionPlanLifecycleEvent.observationCreated.rawValue
        })

        XCTAssertEqual(result.stopReason, .deadlineReached)
        XCTAssertEqual(result.task.state, .waiting)
        XCTAssertTrue(result.evidence.isEmpty)
        XCTAssertEqual(finalObservation.payload["deadline_reached_during_tool"], "true")
        XCTAssertEqual(finalObservation.payload["budget_exhausted"], "true")
    }

    func testNoMutationCapabilityAppears() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await events(for: created.task.id, in: fixture)

        XCTAssertFalse(result.plan.constraints.mutationAllowed)
        XCTAssertFalse(result.plan.constraints.executionEnabled)
        XCTAssertFalse(result.plan.constraints.networkAllowed)
        XCTAssertFalse(result.plan.constraints.credentialAccessAllowed)
        XCTAssertFalse(result.plan.constraints.productionAccessAllowed)
        XCTAssertFalse(result.plan.constraints.deploymentAllowed)
        XCTAssertTrue(events.allSatisfy { $0.payload["mutation_allowed"] != "true" })
        XCTAssertTrue(result.executedToolCalls.allSatisfy {
            ReadOnlyInspectionPolicy.allowedTools.contains($0.command)
        })
    }

    func testNoShellGitBuildTestOrDeployEventsAppear() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)

        _ = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await events(for: created.task.id, in: fixture)
        let forbidden = ["shell", "git", "build", "test", "deploy"]

        XCTAssertFalse(events.contains { event in
            let command = event.payload["command"]?.lowercased() ?? ""
            let lifecycle = event.payload["lifecycle_event"]?.lowercased() ?? ""
            return forbidden.contains { command.contains($0) || lifecycle.contains($0) }
        })
    }

    func testAssessmentIsNotGenerated() async throws {
        let fixture = try await makeFixture()
        let created = try await createApprovedPlan(in: fixture)

        let result = try await fixture.kernel.executeApprovedExecutionPlanInspectionLoop(
            approvalRequestID: created.approval.id,
            workspace: fixture.workspace
        )
        let events = try await events(for: created.task.id, in: fixture)

        XCTAssertEqual(result.task.state, .waiting)
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        XCTAssertFalse(events.contains { $0.payload["assessment_generated"] == "true" })
        XCTAssertFalse(events.contains { event in
            event.summary.localizedCaseInsensitiveContains("assessment prepared")
                || event.payload.keys.contains { $0.localizedCaseInsensitiveContains("assessment_id") }
        })
    }

    private struct Fixture {
        var persistence: InMemoryPersistenceStore
        var workspace: Workspace
        var executor: Phase3B2BRecordingExecutor
        var kernel: RuntimeKernel
        var origin: OriginBinding
    }

    private struct CreatedPlan {
        var task: FDETask
        var approval: ApprovalRequest
    }

    private func makeFixture(
        plan: Phase3B2BPlanRouter.Plan = .evidenceLoop,
        failingCommands: Set<String> = [],
        limits: ReadOnlyInspectionLimits = .conservative,
        delayNanoseconds: UInt64 = 0
    ) async throws -> Fixture {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: UUID(),
            name: "Phase 3B.2B",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: FileManager.default.temporaryDirectory.path
        )
        try await persistence.saveWorkspace(workspace)
        let executor = Phase3B2BRecordingExecutor(
            failingCommands: failingCommands,
            delayNanoseconds: delayNanoseconds
        )
        return Fixture(
            persistence: persistence,
            workspace: workspace,
            executor: executor,
            kernel: RuntimeKernel(
                persistence: persistence,
                eventBus: RuntimeEventBus(),
                modelRouter: Phase3B2BPlanRouter(plan: plan),
                toolExecutor: executor,
                readOnlyInspectionLimits: limits
            ),
            origin: OriginBinding(sessionID: UUID(), turnID: UUID(), requestMessageID: UUID())
        )
    }

    private func createApprovedPlan(in fixture: Fixture) async throws -> CreatedPlan {
        let task = try await fixture.kernel.submitTask(
            input: "Assess this legacy application for an AI agent integration.",
            workspace: fixture.workspace,
            origin: fixture.origin
        )
        let pending = try await fixture.persistence.loadApprovalRequests(
            workspaceID: fixture.workspace.id,
            state: .pending
        )
        let request = try XCTUnwrap(pending.first { $0.taskID == task.id })
        let approved = try await fixture.kernel.approveApprovalRequest(
            request.id,
            workspace: fixture.workspace,
            reason: "Approve bounded read-only evidence collection.",
            origin: fixture.origin
        )
        return CreatedPlan(task: task, approval: approved)
    }

    private func events(for taskID: UUID, in fixture: Fixture) async throws -> [ExecutionEvent] {
        try await fixture.persistence.loadEvents(
            workspaceID: fixture.workspace.id,
            taskID: taskID
        )
    }

    private func argument(_ key: String, in call: ToolCall) -> String? {
        call.arguments.first { $0.hasPrefix("\(key)=") }.map {
            String($0.dropFirst(key.count + 1))
        }
    }
}

private struct Phase3B2BPlanRouter: ModelRouting {
    enum Plan {
        case evidenceLoop
        case rootOnly
    }

    var plan: Plan

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        let calls: [ToolCall]
        switch plan {
        case .evidenceLoop:
            // Deliberately not ordered by desired execution. The runtime must
            // select project inventory before content confirmation.
            calls = [
                call(id: "search", command: "engineering.search_files", arguments: ["workspace=legacy", "query=architecture", "path=."]),
                call(id: "manifest", command: "engineering.read_file", arguments: ["workspace=legacy", "path=package.json"]),
                call(id: "inspect", command: "engineering.inspect_project", arguments: ["workspace=legacy", "path=."]),
                call(id: "source", command: "engineering.read_file", arguments: ["workspace=legacy", "path=src/App.swift"])
            ]
        case .rootOnly:
            calls = [
                call(id: "inspect", command: "engineering.inspect_project", arguments: ["workspace=legacy", "path=."])
            ]
        }
        return StructuredAgentOutput(
            plan: calls.map { call in
                PlanStep(
                    id: "step-\(call.id)",
                    title: "Collect \(call.command) evidence",
                    intent: "Collect one bounded successful observation.",
                    toolCallID: call.id,
                    requiresApproval: false
                )
            } + [
                PlanStep(
                    id: "assessment-pending",
                    title: "Assessment remains pending",
                    intent: "Do not create an assessment in Phase 3B.2B.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: calls,
            risks: [
                RiskSignal(
                    id: "bounded-static-inspection",
                    title: "Evidence remains static and bounded",
                    severity: .low,
                    mitigation: "Stop on coverage, budget, deadline, or unavailable evidence."
                )
            ],
            confidence: 0.9
        )
    }

    private func call(id: String, command: String, arguments: [String]) -> ToolCall {
        ToolCall(
            id: id,
            type: .api,
            command: command,
            arguments: arguments,
            workingDirectory: nil,
            requiresApproval: false
        )
    }
}

private actor Phase3B2BRecordingExecutor: ToolExecuting {
    private let failingCommands: Set<String>
    private let delayNanoseconds: UInt64
    private var calls: [ToolCall] = []

    init(failingCommands: Set<String>, delayNanoseconds: UInt64) {
        self.failingCommands = failingCommands
        self.delayNanoseconds = delayNanoseconds
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        calls.append(call)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if failingCommands.contains(call.command) {
            return ToolExecutionResult(
                callID: call.id,
                exitCode: 1,
                standardOutput: "",
                standardError: "bounded read-only fixture failure",
                duration: 0.001
            )
        }
        let path = call.arguments.first { $0.hasPrefix("path=") }.map {
            String($0.dropFirst("path=".count))
        }
        let output: String
        switch (call.command, path) {
        case ("engineering.inspect_project", _):
            output = "Files: 2\nSource files: 1\npackage.json\nsrc/App.swift"
        case ("engineering.read_file", "package.json"):
            output = #"{"name":"fixture","scripts":{"build":"swift build"},"dependencies":{"express":"1.0.0"}}"#
        case ("engineering.read_file", "src/App.swift"):
            output = "import Foundation\nstruct App { func run() {} }"
        case ("engineering.search_files", _):
            output = "No files found"
        default:
            output = "read-only fixture output"
        }
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: output,
            standardError: "",
            duration: 0.001
        )
    }

    func recordedCalls() -> [ToolCall] {
        calls
    }
}
