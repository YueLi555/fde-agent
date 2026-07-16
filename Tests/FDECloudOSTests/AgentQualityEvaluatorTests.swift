import XCTest
@testable import FDECloudOS

final class AgentQualityEvaluatorTests: XCTestCase {
    func testQualityScoringForCompletedMission() {
        let workspaceID = UUID()
        let taskID = UUID()
        let task = makeTask(workspaceID: workspaceID, taskID: taskID, state: .completed)
        let approval = makeApproval(workspaceID: workspaceID, taskID: taskID, state: .approved)
        let events = successfulMissionEvents(workspaceID: workspaceID, taskID: taskID, approvalID: approval.id)
        let outcome = OutcomeTrackingLayer().record(
            missionID: taskID,
            objective: task.rawInput,
            finalState: .complete,
            events: events,
            task: task
        )
        let replay = MissionReplayBuilder().reconstruct(
            task: task,
            events: events,
            approvals: [approval],
            outcome: outcome
        )

        let evaluation = AgentQualityEvaluator().evaluate(
            replay: replay,
            outcome: outcome,
            events: events,
            task: task
        )

        XCTAssertEqual(evaluation.policyViolations, 0)
        XCTAssertEqual(evaluation.unnecessaryActionCount, 0)
        XCTAssertGreaterThanOrEqual(evaluation.planningAccuracy, 0.95)
        XCTAssertGreaterThanOrEqual(evaluation.executionEfficiency, 0.95)
        XCTAssertEqual(evaluation.recoverySuccess, 1)
        XCTAssertEqual(evaluation.outcomeAchievement, 1)
        XCTAssertGreaterThanOrEqual(evaluation.overallScore, 90)
    }

    func testReflectionGenerationUsesReplayOutcomeEvidenceAndDecisions() {
        let workspaceID = UUID()
        let taskID = UUID()
        let task = makeTask(workspaceID: workspaceID, taskID: taskID, state: .completed)
        let approval = makeApproval(workspaceID: workspaceID, taskID: taskID, state: .approved)
        let events = successfulMissionEvents(workspaceID: workspaceID, taskID: taskID, approvalID: approval.id)
        let outcome = OutcomeTrackingLayer().record(
            missionID: taskID,
            objective: task.rawInput,
            finalState: .complete,
            events: events,
            task: task
        )
        let replay = MissionReplayBuilder().reconstruct(
            task: task,
            events: events,
            approvals: [approval],
            outcome: outcome
        )
        let evaluation = AgentQualityEvaluator().evaluate(replay: replay, outcome: outcome, events: events, task: task)

        let reflection = AgentQualityEvaluator().reflect(
            replay: replay,
            outcome: outcome,
            evidence: outcome.evidence,
            humanDecisions: ["approved: crm.update_account"],
            evaluation: evaluation
        )

        XCTAssertFalse(reflection.whatWorked.isEmpty)
        XCTAssertFalse(reflection.improvementSuggestions.isEmpty)
        XCTAssertTrue(reflection.reusableKnowledge.contains { $0.contains("Action pattern") || $0.contains("Quality score") })
        XCTAssertFalse(
            (reflection.whatWorked + reflection.whatFailed + reflection.improvementSuggestions + reflection.reusableKnowledge)
                .joined(separator: " ")
                .localizedCaseInsensitiveContains("chain-of-thought")
        )
    }

    func testMemoryUpdateStoresSuccessfulAndFailedMissionPatterns() {
        let workspaceID = UUID()
        let successTaskID = UUID()
        let successTask = makeTask(workspaceID: workspaceID, taskID: successTaskID, state: .completed)
        let approval = makeApproval(workspaceID: workspaceID, taskID: successTaskID, state: .approved)
        let successEvents = successfulMissionEvents(workspaceID: workspaceID, taskID: successTaskID, approvalID: approval.id)
        let successOutcome = OutcomeTrackingLayer().record(
            missionID: successTaskID,
            objective: successTask.rawInput,
            finalState: .complete,
            events: successEvents,
            task: successTask
        )
        let successReplay = MissionReplayBuilder().reconstruct(
            task: successTask,
            events: successEvents,
            approvals: [approval],
            outcome: successOutcome
        )
        let evaluator = AgentQualityEvaluator()
        let successEvaluation = evaluator.evaluate(
            replay: successReplay,
            outcome: successOutcome,
            events: successEvents,
            task: successTask
        )
        let successReflection = evaluator.reflect(
            replay: successReplay,
            outcome: successOutcome,
            evidence: successOutcome.evidence,
            evaluation: successEvaluation
        )

        let successUpdate = AgentMemoryImprovementPipeline().update(
            replay: successReplay,
            outcome: successOutcome,
            evaluation: successEvaluation,
            reflection: successReflection,
            task: successTask,
            events: successEvents
        )

        XCTAssertTrue(successUpdate.succeeded)
        XCTAssertFalse(successUpdate.solutionPatterns.isEmpty)
        XCTAssertFalse(successUpdate.riskPatterns.isEmpty)
        XCTAssertTrue(successUpdate.failureSignatures.isEmpty)
        XCTAssertTrue(successUpdate.enterpriseMemoryEntries.contains { $0.type == .solutionMemory })

        let failedTaskID = UUID()
        let failedTask = makeTask(workspaceID: workspaceID, taskID: failedTaskID, state: .failed)
        let failedEvents = failedMissionEvents(workspaceID: workspaceID, taskID: failedTaskID)
        let failedOutcome = OutcomeTrackingLayer().record(
            missionID: failedTaskID,
            objective: failedTask.rawInput,
            finalState: .adapt,
            events: failedEvents,
            task: failedTask
        )
        let failedReplay = MissionReplayBuilder().reconstruct(
            task: failedTask,
            events: failedEvents,
            approvals: [],
            outcome: failedOutcome
        )
        let failedEvaluation = evaluator.evaluate(
            replay: failedReplay,
            outcome: failedOutcome,
            events: failedEvents,
            task: failedTask
        )
        let failedReflection = evaluator.reflect(
            replay: failedReplay,
            outcome: failedOutcome,
            evidence: failedOutcome.evidence,
            errors: ["crm.update_account failed with permission denied"],
            evaluation: failedEvaluation
        )

        let failedUpdate = AgentMemoryImprovementPipeline().update(
            replay: failedReplay,
            outcome: failedOutcome,
            evaluation: failedEvaluation,
            reflection: failedReflection,
            task: failedTask,
            events: failedEvents
        )

        XCTAssertFalse(failedUpdate.succeeded)
        XCTAssertFalse(failedUpdate.failureSignatures.isEmpty)
        XCTAssertFalse(failedUpdate.preventionRules.isEmpty)
        XCTAssertTrue(failedUpdate.solutionPatterns.isEmpty)
        XCTAssertTrue(failedUpdate.enterpriseMemoryEntries.contains { $0.type == .failureMemory })
    }

    func testBenchmarkAggregation() {
        let workspaceID = UUID()
        let completedTaskID = UUID()
        let failedTaskID = UUID()
        let completedTask = makeTask(
            workspaceID: workspaceID,
            taskID: completedTaskID,
            state: .completed,
            performanceScore: 92
        )
        let failedTask = makeTask(
            workspaceID: workspaceID,
            taskID: failedTaskID,
            state: .failed,
            performanceScore: 42
        )
        let approvalA = makeApproval(workspaceID: workspaceID, taskID: completedTaskID, state: .approved)
        let approvalB = makeApproval(workspaceID: workspaceID, taskID: failedTaskID, state: .rejected)
        let events = [
            makeEvent(.recoveryAttempted, sequence: 1, workspaceID: workspaceID, taskID: completedTaskID, summary: "Recovery started"),
            makeEvent(.taskCompleted, sequence: 2, workspaceID: workspaceID, taskID: completedTaskID, summary: "Recovered"),
            makeEvent(.toolFailed, sequence: 3, workspaceID: workspaceID, taskID: failedTaskID, summary: "crm.update_account failed", payload: ["command": "crm.update_account"])
        ]
        let memories = [
            TaskExecutionMemory(
                id: UUID(),
                workspaceID: workspaceID,
                taskID: failedTaskID,
                taskFingerprint: "crm-update",
                taskType: "crm",
                state: .failed,
                planStepCount: 1,
                toolCommands: ["crm.update_account"],
                failedCommands: ["crm.update_account"],
                failureSignatures: ["crm|permission|crm.update_account"],
                riskScore: 75,
                performanceScore: 42,
                createdAt: Date()
            )
        ]

        let summary = AgentQualityEvaluator().benchmark(
            tasks: [completedTask, failedTask],
            events: events,
            approvals: [approvalA, approvalB],
            memories: memories
        )

        XCTAssertEqual(summary.missionCount, 2)
        XCTAssertEqual(summary.successRate, 0.5, accuracy: 0.001)
        XCTAssertEqual(summary.recoveryRate, 1, accuracy: 0.001)
        XCTAssertEqual(summary.approvalEfficiency, 0.5, accuracy: 0.001)
        XCTAssertTrue(summary.commonFailurePatterns.contains { $0.contains("crm.update_account") })
    }

    private func makeTask(
        workspaceID: UUID,
        taskID: UUID,
        state: TaskState,
        performanceScore: Double = 0
    ) -> FDETask {
        FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Update CRM account",
            rawInput: "Update CRM account after validating customer state",
            state: state,
            plan: [
                PlanStep(
                    id: "step.crm",
                    title: "Update CRM",
                    intent: "Apply account update",
                    toolCallID: "tool.crm",
                    requiresApproval: true
                )
            ],
            riskScore: 60,
            failureProbability: state == .completed ? 0.1 : 0.7,
            performanceScore: performanceScore,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func makeApproval(workspaceID: UUID, taskID: UUID, state: ApprovalState) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID(),
            workspaceID: workspaceID,
            taskID: taskID,
            stepID: "step.crm",
            toolCallID: "tool.crm",
            targetKind: .connectorOperation,
            action: "execute tool",
            resource: "crm.update_account",
            riskLevel: .high,
            state: state,
            requestedByRole: .fde,
            decidedByRole: state == .pending ? nil : .admin,
            decisionReason: state == .approved ? "Approved for test" : "Rejected for test",
            requestedAt: Date(),
            decidedAt: state == .pending ? nil : Date(),
            expiresAt: nil,
            metadata: [:]
        )
    }

    private func successfulMissionEvents(workspaceID: UUID, taskID: UUID, approvalID: UUID) -> [ExecutionEvent] {
        [
            makeEvent(
                .taskCreated,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Mission created",
                payload: ["task_state": TaskState.created.rawValue]
            ),
            makeEvent(
                .stateUpdated,
                sequence: 2,
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
                    "task_state": TaskState.running.rawValue
                ]
            ),
            makeEvent(
                .humanApprovalRequested,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Approval requested",
                payload: [
                    "approval_request_id": approvalID.uuidString,
                    "risk_level": RiskSeverity.high.rawValue,
                    "policy_decision": PolicyDecisionStatus.approvalRequired.rawValue,
                    "risk_reasons": "Customer data update",
                    "mission_state": MissionState.waitingHuman.rawValue,
                    "task_state": TaskState.pendingApproval.rawValue
                ]
            ),
            makeEvent(
                .toolCalled,
                sequence: 4,
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
                    "task_state": TaskState.running.rawValue
                ]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 5,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "CRM update observed",
                payload: [
                    "step_id": "step.crm",
                    "tool_call_id": "tool.crm",
                    "command": "crm.update_account",
                    "stdout": "updated",
                    "environment_evidence": "CRM account API is reachable",
                    "mission_state": MissionState.observe.rawValue,
                    "task_state": TaskState.running.rawValue
                ]
            ),
            makeEvent(
                .taskCompleted,
                sequence: 6,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Mission completed",
                payload: [
                    "mission_state": MissionState.complete.rawValue,
                    "task_state": TaskState.completed.rawValue
                ]
            )
        ]
    }

    private func failedMissionEvents(workspaceID: UUID, taskID: UUID) -> [ExecutionEvent] {
        [
            makeEvent(
                .taskCreated,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Mission created",
                payload: ["task_state": TaskState.created.rawValue]
            ),
            makeEvent(
                .toolCalled,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "crm.update_account",
                payload: [
                    "step_id": "step.crm",
                    "tool_call_id": "tool.crm",
                    "command": "crm.update_account",
                    "mission_state": MissionState.execute.rawValue,
                    "task_state": TaskState.running.rawValue
                ]
            ),
            makeEvent(
                .toolFailed,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "crm.update_account failed with permission denied",
                payload: [
                    "step_id": "step.crm",
                    "tool_call_id": "tool.crm",
                    "command": "crm.update_account",
                    "error": "permission denied",
                    "mission_state": MissionState.observe.rawValue,
                    "task_state": TaskState.failed.rawValue
                ]
            )
        ]
    }

    private func makeEvent(
        _ type: EventType,
        sequence: Int64,
        workspaceID: UUID,
        taskID: UUID,
        summary: String,
        payload: [String: String] = [:]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(),
            summary: summary,
            payload: payload
        )
    }
}
