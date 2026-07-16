import XCTest
@testable import FDECloudOS

final class OutcomeTrackingTests: XCTestCase {
    func testCompletedMissionCreatesOutcome() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let completed = makeEvent(
            .taskCompleted,
            sequence: 1,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Salesforce authentication validated",
            payload: [
                "mission_state": MissionState.complete.rawValue,
                "impact_summary": "Support can resume connector validation."
            ]
        )

        let record = OutcomeTrackingLayer().record(
            missionID: taskID,
            objective: "Diagnose Salesforce integration",
            finalState: .complete,
            events: [completed]
        )

        XCTAssertEqual(record.missionID, taskID)
        XCTAssertEqual(record.objective, "Diagnose Salesforce integration")
        XCTAssertEqual(record.finalState, .complete)
        XCTAssertEqual(record.achievedOutcome, "Salesforce authentication validated")
        XCTAssertEqual(record.impactSummary, "Support can resume connector validation.")
        XCTAssertFalse(record.followUpRecommendations.isEmpty)
    }

    func testFailedMissionRecordsFailureReason() {
        let taskID = UUID()
        let failed = makeEvent(
            .authorizationDenied,
            sequence: 1,
            workspaceID: UUID(),
            taskID: taskID,
            summary: "Policy blocked autonomous tool request",
            payload: [
                "agent_loop_stop_reason": AgentLoopStopReason.policyViolation.rawValue,
                "command": "/bin/rm"
            ]
        )

        let record = OutcomeTrackingLayer().record(
            missionID: taskID,
            objective: "Apply risky migration",
            finalState: .adapt,
            events: [failed]
        )

        XCTAssertEqual(record.finalState, .adapt)
        XCTAssertTrue(record.achievedOutcome.contains("Policy blocked autonomous tool request"))
        XCTAssertTrue(record.impactSummary.contains("Mission did not complete"))
        XCTAssertTrue(record.followUpRecommendations.contains { $0.contains("Policy blocked autonomous tool request") })
    }

    func testEvidenceAttached() {
        let taskID = UUID()
        let execution = makeEvent(
            .stepExecuted,
            sequence: 1,
            workspaceID: UUID(),
            taskID: taskID,
            summary: "Checked authentication",
            payload: ["observation_summary": "API returned 200."]
        )
        let report = makeEvent(
            .feedbackGenerated,
            sequence: 2,
            workspaceID: execution.workspaceID,
            taskID: taskID,
            summary: "Investigation report",
            payload: ["detail": "Connector credentials are valid."]
        )

        let record = OutcomeTrackingLayer().record(
            missionID: taskID,
            objective: "Validate connector",
            finalState: .complete,
            events: [execution, report]
        )

        XCTAssertTrue(record.evidence.contains { $0.kind == .execution && $0.detail == "API returned 200." })
        XCTAssertTrue(record.evidence.contains { $0.kind == .artifact && $0.detail == "Connector credentials are valid." })
    }

    func testNoHallucinatedMetrics() {
        let taskID = UUID()
        let completed = makeEvent(
            .taskCompleted,
            sequence: 1,
            workspaceID: UUID(),
            taskID: taskID,
            summary: "Mission completed",
            payload: ["mission_state": MissionState.complete.rawValue]
        )

        let record = OutcomeTrackingLayer().record(
            missionID: taskID,
            objective: "Complete customer investigation",
            finalState: .complete,
            events: [completed]
        )

        XCTAssertTrue(record.metricsBefore.isEmpty)
        XCTAssertTrue(record.metricsAfter.isEmpty)
        XCTAssertTrue(record.impactSummary.contains("No explicit business metrics were recorded"))
    }

    private func makeEvent(
        _ type: EventType,
        sequence: Int64,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: summary,
            payload: payload
        )
    }
}
