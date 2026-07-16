import XCTest
@testable import FDECloudOS

final class EventToWorkUnitAggregatorTests: XCTestCase {
    func testPartialReadOnlyResultCreatesBlockedPartialWorkUnit() {
        let workspaceID = UUID()
        let taskID = UUID()
        let partial = makeEvent(
            .stateUpdated,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Read-only inspection partially finalized with grounded evidence",
            payload: [
                "state": TaskState.blocked.rawValue,
                "partial_completion_state": "BLOCKED_WITH_PARTIAL_RESULT",
                "same_task_resumable": "true"
            ]
        )

        let unit = EventToWorkUnitAggregator.workUnits(from: [partial]).first

        XCTAssertEqual(unit?.kind, .execution)
        XCTAssertEqual(unit?.status, .blocked)
        XCTAssertEqual(unit?.title, "Partial investigation result")
    }

    func testOrdersWorkUnitsByRuntimeEventSequence() {
        let workspaceID = UUID()
        let taskID = UUID()
        let taskCreated = makeEvent(.taskCreated, sequence: 1, workspaceID: workspaceID, taskID: taskID)
        let planGenerated = makeEvent(.planGenerated, sequence: 2, workspaceID: workspaceID, taskID: taskID)
        let completed = makeEvent(.taskCompleted, sequence: 3, workspaceID: workspaceID, taskID: taskID)

        let units = EventToWorkUnitAggregator.workUnits(from: [completed, taskCreated, planGenerated])

        XCTAssertEqual(units.map(\.kind), [.understanding, .planning, .result])
        XCTAssertEqual(units.map(\.eventIDs.first), [taskCreated.id, planGenerated.id, completed.id])
    }

    func testGroupsToolLifecycleByStepID() {
        let workspaceID = UUID()
        let taskID = UUID()
        let payload = [
            "step_id": "inspect",
            "tool_call_id": "tool.inspect"
        ]
        let toolCalled = makeEvent(.toolCalled, sequence: 1, workspaceID: workspaceID, taskID: taskID, payload: payload)
        let stepExecuted = makeEvent(.stepExecuted, sequence: 2, workspaceID: workspaceID, taskID: taskID, payload: payload)

        let units = EventToWorkUnitAggregator().workUnits(from: [stepExecuted, toolCalled])

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.kind, .execution)
        XCTAssertEqual(units.first?.status, .completed)
        XCTAssertEqual(units.first?.eventIDs, [toolCalled.id, stepExecuted.id])
        XCTAssertEqual(units.first?.eventTypes, [.toolCalled, .stepExecuted])
    }

    func testGroupsApprovalDecisionWithApprovalRequest() {
        let workspaceID = UUID()
        let taskID = UUID()
        let approvalID = UUID().uuidString
        let payload = ["approval_request_id": approvalID]
        let requested = makeEvent(.humanApprovalRequested, sequence: 1, workspaceID: workspaceID, taskID: taskID, payload: payload)
        let approved = makeEvent(.humanApproved, sequence: 2, workspaceID: workspaceID, taskID: taskID, payload: payload)

        let units = EventToWorkUnitAggregator.workUnits(from: [approved, requested])

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.kind, .approval)
        XCTAssertEqual(units.first?.status, .completed)
        XCTAssertEqual(units.first?.eventIDs, [requested.id, approved.id])
        XCTAssertEqual(units.first?.relatedArtifactID, "approval-\(approvalID)")
    }

    func testChatOnlyEventsDoNotCreateWorkUnits() {
        let workspaceID = UUID()
        let userMessage = makeEvent(
            .userMessageReceived,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: nil,
            payload: [
                "chat_only": "true",
                "mission_state": MissionState.waitingHuman.rawValue
            ]
        )
        let answered = makeEvent(
            .stateUpdated,
            sequence: 2,
            workspaceID: workspaceID,
            taskID: nil,
            summary: "Agent answered chat message",
            payload: [
                "chat_only": "true",
                "mission_state": MissionState.waitingHuman.rawValue
            ]
        )

        let units = EventToWorkUnitAggregator.workUnits(from: [userMessage, answered])

        XCTAssertTrue(units.isEmpty)
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
