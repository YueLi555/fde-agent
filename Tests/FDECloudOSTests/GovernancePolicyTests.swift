import XCTest
@testable import FDECloudOS

final class GovernancePolicyTests: XCTestCase {
    func testDeniedProductionAction() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Production Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = GovernanceRecordingExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: GovernancePlanner(
                stepTitle: "Deploy production deletion",
                stepIntent: "Deploy production and delete live service",
                tool: ToolCall(
                    id: "tool.production.delete",
                    type: .shell,
                    command: "/bin/echo",
                    arguments: ["deploy", "production", "delete"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ),
            toolExecutor: executor
        )

        let task = try await kernel.submitTask(input: "Deploy production deletion", workspace: workspace)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let commands = await executor.executedCommands()

        XCTAssertEqual(task.state, .failed)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(
            events.contains {
                $0.type == .authorizationDenied
                    && $0.payload["policy_decision"] == PolicyDecisionStatus.denied.rawValue
                    && $0.payload["risk_assessment_level"] == RiskSeverity.critical.rawValue
            }
        )
    }

    func testApprovalRequiredAction() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Approval Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = GovernanceRecordingExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: GovernancePlanner(
                stepTitle: "Update CRM",
                stepIntent: "Update customer CRM account",
                tool: ToolCall(
                    id: "tool.crm.update",
                    type: .api,
                    command: "crm.update_account",
                    arguments: ["customer=acme"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ),
            toolExecutor: executor
        )

        let execution = Task {
            try await kernel.submitTask(input: "Update customer CRM account", workspace: workspace)
        }
        let request = try await waitForPendingApproval(workspaceID: workspace.id, persistence: persistence)
        let commandsBeforeApproval = await executor.executedCommands()

        XCTAssertEqual(request.state, .pending)
        XCTAssertEqual(request.riskLevel, .high)
        XCTAssertEqual(request.metadata["policy_decision"], PolicyDecisionStatus.approvalRequired.rawValue)
        XCTAssertTrue(commandsBeforeApproval.isEmpty)

        _ = try await kernel.approveApprovalRequest(request.id, workspace: workspace, reason: "Approve governed CRM update.")
        let task = try await execution.value
        let commandsAfterApproval = await executor.executedCommands()
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(commandsAfterApproval, ["crm.update_account"])
        XCTAssertTrue(events.contains { $0.type == .humanApprovalRequested && $0.payload["policy_decision"] == PolicyDecisionStatus.approvalRequired.rawValue })
        XCTAssertTrue(events.contains { $0.type == .toolCalled && $0.payload["policy_decision"] == PolicyDecisionStatus.approvalRequired.rawValue })
    }

    func testLowRiskAutoExecution() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Low Risk Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = GovernanceRecordingExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: GovernancePlanner(
                stepTitle: "Echo status",
                stepIntent: "Read local workspace status",
                tool: ToolCall(
                    id: "tool.low.echo",
                    type: .shell,
                    command: "/bin/echo",
                    arguments: ["status"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ),
            toolExecutor: executor
        )

        let task = try await kernel.submitTask(input: "Echo local status", workspace: workspace)
        let approvals = try await persistence.loadApprovalRequests(workspaceID: workspace.id, state: nil)
        let commands = await executor.executedCommands()
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(approvals.isEmpty)
        XCTAssertEqual(commands, ["/bin/echo"])
        XCTAssertTrue(events.contains { $0.type == .toolCalled && $0.payload["policy_decision"] == PolicyDecisionStatus.allowed.rawValue })
    }

    func testReplayReconstructionAndAuditCompleteness() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let task = FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Governed mission",
            rawInput: "Update CRM safely",
            state: .completed,
            plan: [],
            riskScore: 10,
            failureProbability: 0,
            performanceScore: 95,
            createdAt: Date(),
            updatedAt: Date()
        )
        let approvalID = UUID()
        let events = syntheticReplayEvents(workspaceID: workspaceID, taskID: taskID, approvalID: approvalID)
        let approval = ApprovalRequest(
            id: approvalID,
            workspaceID: workspaceID,
            taskID: taskID,
            stepID: "step.crm",
            toolCallID: "tool.crm",
            targetKind: .toolCall,
            action: "execute tool",
            resource: "crm.update_account",
            riskLevel: .high,
            state: .approved,
            requestedByRole: .fde,
            decidedByRole: .admin,
            decisionReason: "Approved for replay test.",
            requestedAt: Date(),
            decidedAt: Date(),
            expiresAt: nil,
            metadata: ["policy_decision": PolicyDecisionStatus.approvalRequired.rawValue]
        )

        let replay = MissionReplayBuilder().reconstruct(task: task, events: events, approvals: [approval])

        XCTAssertEqual(replay.userObjective, "Update CRM safely")
        XCTAssertEqual(replay.agentDecisions.count, 1)
        XCTAssertFalse(replay.stateTransitions.isEmpty)
        XCTAssertEqual(replay.approvals.count, 1)
        XCTAssertFalse(replay.actions.isEmpty)
        XCTAssertFalse(replay.evidence.isEmpty)
        XCTAssertNotNil(replay.outcome)
        XCTAssertTrue(replay.isAuditComplete)

        let incomplete = MissionReplayBuilder().reconstruct(task: nil, events: [], approvals: [])
        XCTAssertFalse(incomplete.isAuditComplete)
        XCTAssertTrue(incomplete.auditGaps.contains("Missing user objective."))
        XCTAssertTrue(incomplete.auditGaps.contains("Missing outcome."))
    }

    func testPolicyEngineDirectDecisions() {
        let engine = PolicyEngine()

        let denied = engine.evaluate(
            PolicyInput(
                userRole: .fde,
                system: "billing",
                environment: "production",
                action: "delete production invoices",
                riskLevel: .critical
            )
        )
        let approvalRequired = engine.evaluate(
            PolicyInput(
                userRole: .fde,
                system: "crm",
                environment: "workspace",
                action: "update customer account",
                riskLevel: .high
            )
        )
        let allowed = engine.evaluate(
            PolicyInput(
                userRole: .fde,
                system: "local_shell",
                environment: "workspace",
                action: "/bin/echo status",
                riskLevel: .low
            )
        )

        XCTAssertEqual(denied.status, .denied)
        XCTAssertEqual(approvalRequired.status, .approvalRequired)
        XCTAssertEqual(allowed.status, .allowed)
    }

    private func syntheticReplayEvents(workspaceID: UUID, taskID: UUID, approvalID: UUID) -> [ExecutionEvent] {
        let created = replayEvent(
            .taskCreated,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Mission created",
            payload: ["task_state": TaskState.created.rawValue]
        )
        let decision = replayEvent(
            .stateUpdated,
            sequence: 2,
            parent: created.id,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Agent decided",
            payload: [
                "agent_decision_summary": "Update CRM after approval.",
                "agent_decision_next_state": MissionState.execute.rawValue,
                "agent_decision_action_type": AgentRuntimeAction.executeTool.rawValue,
                "agent_decision_confidence": "0.91",
                "agent_decision_requires_human_approval": "true",
                "mission_state": MissionState.execute.rawValue,
                "task_state": TaskState.running.rawValue,
                "tool_state": ToolExecutionState.idle.rawValue
            ]
        )
        let approval = replayEvent(
            .humanApprovalRequested,
            sequence: 3,
            parent: decision.id,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Approval requested",
            payload: [
                "approval_request_id": approvalID.uuidString,
                "risk_level": RiskSeverity.high.rawValue,
                "policy_decision": PolicyDecisionStatus.approvalRequired.rawValue,
                "policy_reasons": "FDE role requires approval for elevated risk actions.",
                "mission_state": MissionState.waitingHuman.rawValue,
                "task_state": TaskState.pendingApproval.rawValue,
                "tool_state": ToolExecutionState.pendingApproval.rawValue
            ]
        )
        let tool = replayEvent(
            .toolCalled,
            sequence: 4,
            parent: approval.id,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "crm.update_account",
            payload: [
                "step_id": "step.crm",
                "tool_call_id": "tool.crm",
                "command": "crm.update_account",
                "risk_assessment_level": RiskSeverity.high.rawValue,
                "policy_decision": PolicyDecisionStatus.approvalRequired.rawValue,
                "mission_state": MissionState.execute.rawValue,
                "task_state": TaskState.running.rawValue,
                "tool_state": ToolExecutionState.running.rawValue
            ]
        )
        let observed = replayEvent(
            .stepExecuted,
            sequence: 5,
            parent: tool.id,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "CRM update observed",
            payload: [
                "step_id": "step.crm",
                "tool_call_id": "tool.crm",
                "command": "crm.update_account",
                "stdout": "updated",
                "mission_state": MissionState.observe.rawValue,
                "task_state": TaskState.running.rawValue,
                "tool_state": ToolExecutionState.succeeded.rawValue
            ]
        )
        let completed = replayEvent(
            .taskCompleted,
            sequence: 6,
            parent: observed.id,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Mission completed",
            payload: [
                "mission_state": MissionState.complete.rawValue,
                "task_state": TaskState.completed.rawValue,
                "tool_state": ToolExecutionState.succeeded.rawValue
            ]
        )
        return [created, decision, approval, tool, observed, completed]
    }

    private func replayEvent(
        _ type: EventType,
        sequence: Int64,
        parent: UUID? = nil,
        workspaceID: UUID,
        taskID: UUID,
        summary: String,
        payload: [String: String]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: parent,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(),
            summary: summary,
            payload: payload
        )
    }

    private func waitForPendingApproval(
        workspaceID: UUID,
        persistence: any PersistenceStore,
        attempts: Int = 100
    ) async throws -> ApprovalRequest {
        for _ in 0..<attempts {
            if let request = try await persistence.loadApprovalRequests(workspaceID: workspaceID, state: .pending).first {
                return request
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ApprovalQueueError.requestNotFound(workspaceID)
    }
}

private struct GovernancePlanner: ModelRouting {
    var stepTitle: String
    var stepIntent: String
    var tool: ToolCall

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.\(tool.id)",
                    title: stepTitle,
                    intent: stepIntent,
                    toolCallID: tool.id,
                    requiresApproval: tool.requiresApproval
                )
            ],
            actions: [
                AgentAction(id: "action.\(tool.id)", title: stepTitle, agent: .planner, stepID: "step.\(tool.id)")
            ],
            toolCalls: [tool],
            risks: [],
            confidence: 0.92
        )
    }
}

private actor GovernanceRecordingExecutor: ToolExecuting {
    private var commands: [String] = []

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        commands.append(call.command)
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "ok \(call.command)",
            standardError: "",
            duration: 0.001
        )
    }

    func executedCommands() -> [String] {
        commands
    }
}
