import XCTest
@testable import FDECloudOS

final class FieldFeedbackEngineTests: XCTestCase {
    func testIntegrationTaskProducesAssessmentAndImplementationPlan() {
        let workspaceID = UUID()
        let taskID = UUID()
        let task = FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Assess AI agent integration",
            rawInput: "Check whether this legacy project can integrate with the AI agent project",
            state: .completed,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        let events = [
            makeEvent(
                .contextCompiled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Workspace context compiled",
                payload: [
                    "legacy_project_root": "/tmp/PetFound",
                    "agent_project_root": "/tmp/FDE",
                    "codebase_roles": "legacy_software | ai_agent"
                ]
            ),
            makeEvent(
                .toolCalled,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "command": "/bin/ls",
                    "arguments": "-la Sources"
                ]
            ),
            makeEvent(
                .stepExecuted,
                sequence: 3,
                workspaceID: workspaceID,
                taskID: taskID,
                summary: "Inspect AI agent project"
            )
        ]

        let insights = FieldFeedbackEngine().insights(
            for: task,
            events: events,
            assessment: RealityAssessment(
                realityRiskScore: 27.25,
                failureProbability: 0.12,
                mitigations: []
            )
        )

        XCTAssertTrue(insights.contains { $0.title == "Integration assessment" })
        XCTAssertTrue(insights.contains { $0.title == "Implementation plan" })
        XCTAssertTrue(insights.contains { $0.title == "Test plan" })
        XCTAssertFalse(insights.contains { $0.title == "Code patch" })
        XCTAssertFalse(insights.contains { $0.title == "Verification report" })
        XCTAssertFalse(insights.contains { $0.title == "Capture reusable workflow template" })
        XCTAssertTrue(insights.first { $0.title == "Integration assessment" }?.detail.contains("Problems to resolve") == true)
        XCTAssertTrue(insights.first { $0.title == "Integration assessment" }?.detail.contains("Runtime evidence actually captured") == true)
        XCTAssertTrue(insights.first { $0.title == "Integration assessment" }?.detail.contains("Inference boundary") == true)
        XCTAssertTrue(insights.first { $0.title == "Integration assessment" }?.detail.contains("STRUCTURAL ONLY") == true)
        XCTAssertTrue(insights.first { $0.title == "Integration assessment" }?.detail.contains("CONDITIONALLY CONNECTABLE, NOT PRODUCTION-READY") == true)
        XCTAssertTrue(insights.first { $0.title == "Integration assessment" }?.detail.contains("Can honestly claim the legacy app is already connected to the agent: NO") == true)
        XCTAssertTrue(insights.first { $0.title == "Implementation plan" }?.detail.contains("AgentIntegrationService") == true)
        XCTAssertTrue(insights.first { $0.title == "Test plan" }?.detail.contains("Integration smoke test") == true)
        XCTAssertTrue(insights.first { $0.title == "Test plan" }?.detail.contains("REQUIRED BEFORE CLAIMING INTEGRATION SUCCESS") == true)
    }

    func testIntegrationAssessmentReportsSourceSampleEvidenceWhenCaptured() throws {
        let workspaceID = UUID()
        let taskID = UUID()
        let task = FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Assess AI agent integration",
            rawInput: "Check whether this legacy project can integrate with the AI agent project",
            state: .completed,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        let events = [
            makeEvent(
                .contextCompiled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "legacy_project_root": "/tmp/PetFound",
                    "agent_project_root": "/tmp/FDE",
                    "codebase_roles": "legacy_software | ai_agent"
                ]
            ),
            makeEvent(
                .toolCalled,
                sequence: 2,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "command": "/usr/bin/head",
                    "arguments": "-n 160 Sources/App.swift"
                ]
            )
        ]

        let insights = FieldFeedbackEngine().insights(
            for: task,
            events: events,
            assessment: RealityAssessment(
                realityRiskScore: 22,
                failureProbability: 0.08,
                mitigations: []
            )
        )

        let assessment = try XCTUnwrap(insights.first { $0.title == "Integration assessment" })
        XCTAssertTrue(assessment.detail.contains("SOURCE-SAMPLED"))
        XCTAssertTrue(assessment.detail.contains("/usr/bin/head -n 160 Sources/App.swift"))
    }

    func testApprovedImplementationProducesPatchAndVerificationArtifacts() {
        let workspaceID = UUID()
        let taskID = UUID()
        let task = FDETask(
            id: taskID,
            workspaceID: workspaceID,
            title: "Approved AI agent implementation",
            rawInput: "Customer approved implementation for AI agent integration, generate patch and write code",
            state: .completed,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )
        let events = [
            makeEvent(
                .contextCompiled,
                sequence: 1,
                workspaceID: workspaceID,
                taskID: taskID,
                payload: [
                    "legacy_project_root": "/tmp/PetFound",
                    "agent_project_root": "/tmp/FDE",
                    "codebase_roles": "legacy_software | ai_agent"
                ]
            )
        ]

        let insights = FieldFeedbackEngine().insights(
            for: task,
            events: events,
            assessment: RealityAssessment(
                realityRiskScore: 31,
                failureProbability: 0.18,
                mitigations: []
            )
        )

        XCTAssertTrue(insights.contains { $0.kind == .codePatch && $0.title == "Code patch" })
        XCTAssertTrue(insights.contains { $0.kind == .verificationReport && $0.title == "Verification report" })
        XCTAssertTrue(insights.first { $0.title == "Code patch" }?.detail.contains("AgentClient protocol") == true)
        XCTAssertTrue(insights.first { $0.title == "Code patch" }?.detail.contains("BLUEPRINT ONLY IN THIS RUN") == true)
        XCTAssertTrue(insights.first { $0.title == "Code patch" }?.detail.contains("No source files were changed") == true)
        XCTAssertTrue(insights.first { $0.title == "Verification report" }?.detail.contains("Required verification") == true)
        XCTAssertTrue(insights.first { $0.title == "Verification report" }?.detail.contains("NOT VERIFIED YET") == true)
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
            timestamp: Date(),
            summary: summary ?? type.rawValue,
            payload: payload
        )
    }
}
