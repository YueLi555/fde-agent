import XCTest
@testable import FDECloudOS

final class AgentNarrationEngineTests: XCTestCase {
    func testNarrationMapsCoreRuntimeEventsToHumanUpdates() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.planGenerated, sequence: 2, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.toolCalled, sequence: 3, workspaceID: workspaceID, taskID: taskID, payload: ["command": "/bin/pwd"]),
            makeEvent(.connectorCalled, sequence: 4, workspaceID: workspaceID, taskID: taskID, payload: ["command": "salesforce.query"]),
            makeEvent(.recoveryAttempted, sequence: 5, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.humanApprovalRequested, sequence: 6, workspaceID: workspaceID, taskID: taskID, payload: ["command": "/bin/rm", "risk_level": "high"])
        ]

        let feed = AgentNarrationEngine.feed(task: nil, events: events)

        XCTAssertEqual(feed.currentAction?.title, "Human approval required before continuing")
        XCTAssertEqual(feed.nextAction?.title, "Waiting for approval decision")
        XCTAssertTrue(feed.completedActions.contains { $0.title == "Agent started investigating the request" })
        XCTAssertTrue(feed.completedActions.contains { $0.title == "Planner created execution strategy" })
        XCTAssertTrue(feed.completedActions.contains { $0.title == "Executor is inspecting workspace" })
        XCTAssertTrue(feed.completedActions.contains { $0.title == "Agent is querying external system" })
        XCTAssertTrue(feed.completedActions.contains { $0.title == "Agent detected failure and is attempting recovery" })
        XCTAssertTrue(feed.evidenceProduced.contains { $0.title == "Approval request recorded" })
    }

    func testNarrationInfersNextActionFromUnfinishedPlanStep() {
        let workspaceID = UUID()
        let taskID = UUID()
        let task = FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Investigate API",
            rawInput: "Investigate API",
            state: .running,
            plan: [
                PlanStep(
                    id: "inspect",
                    title: "Inspect workspace",
                    intent: "Inspect",
                    toolCallID: "tool.inspect",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "retry",
                    title: "Retry connector sync",
                    intent: "Retry",
                    toolCallID: "tool.retry",
                    requiresApproval: false
                )
            ],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        let events = [
            makeEvent(.planGenerated, sequence: 1, workspaceID: workspaceID, taskID: taskID),
            makeEvent(.stepExecuted, sequence: 2, workspaceID: workspaceID, taskID: taskID, payload: ["step_id": "inspect", "exit_code": "0"])
        ]

        let feed = AgentNarrationEngine.feed(task: task, events: events)

        XCTAssertEqual(feed.nextAction?.title, "Executor will run next planned action")
        XCTAssertEqual(feed.nextAction?.detail, "Retry connector sync")
    }

    func testFeedbackNarrationUsesSpecificArtifactNames() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(
                .feedbackGenerated,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Integration assessment"
            ),
            makeEvent(
                .feedbackGenerated,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Implementation plan"
            ),
            makeEvent(
                .feedbackGenerated,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Test plan"
            )
        ]

        let feed = AgentNarrationEngine.feed(task: nil, events: events)

        XCTAssertEqual(feed.currentAction?.title, "Agent generated test plan")
        XCTAssertTrue(feed.completedActions.contains { $0.title == "Agent generated integration assessment" })
        XCTAssertTrue(feed.completedActions.contains { $0.title == "Agent generated implementation plan" })
        XCTAssertTrue(feed.evidenceProduced.contains { $0.title == "Integration assessment generated" })
        XCTAssertTrue(feed.evidenceProduced.contains { $0.title == "Implementation plan generated" })
        XCTAssertTrue(feed.evidenceProduced.contains { $0.title == "Test plan generated" })
        XCTAssertFalse(renderedText(feed).contains("Execution report generated"))
    }

    func testNarrationRedactsSensitivePayloadsAndPrivateReasoningMarkers() {
        let workspaceID = UUID()
        let taskID = UUID()
        let events = [
            makeEvent(
                .toolCalled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "chain_of_thought: use token=SECRET_VALUE",
                payload: [
                    "command": "/usr/bin/curl --token SECRET_VALUE https://example.com",
                    "stdout": "SECRET_VALUE",
                    "stderr": "chain_of_thought"
                ]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "exit_code": "0",
                    "stdout": "SECRET_VALUE"
                ]
            )
        ]

        let feed = AgentNarrationEngine.feed(task: nil, events: events)
        let rendered = renderedText(feed)

        XCTAssertFalse(rendered.contains("SECRET_VALUE"))
        XCTAssertFalse(rendered.lowercased().contains("chain_of_thought"))
        XCTAssertFalse(rendered.lowercased().contains("stdout"))
        XCTAssertTrue(rendered.contains("[redacted]"))
    }

    private func renderedText(_ feed: AgentNarrationFeed) -> String {
        var values: [String] = []
        if let currentAction = feed.currentAction {
            values.append(currentAction.title)
            values.append(currentAction.detail ?? "")
        }
        if let nextAction = feed.nextAction {
            values.append(nextAction.title)
            values.append(nextAction.detail ?? "")
        }
        for item in feed.completedActions {
            values.append(item.title)
            values.append(item.detail ?? "")
        }
        for evidence in feed.evidenceProduced {
            values.append(evidence.title)
            values.append(evidence.detail ?? "")
        }
        return values.joined(separator: "\n")
    }

    private func makeEvent(
        _ type: EventType,
        sequence: Int64,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String? = nil,
        payload: [String: String] = [:]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: summary ?? type.rawValue,
            payload: payload
        )
    }
}
