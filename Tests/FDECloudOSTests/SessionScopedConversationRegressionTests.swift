import Foundation
import XCTest
@testable import FDECloudOS

final class SessionScopedConversationRegressionTests: XCTestCase {
    func testNewAndCasualConversationHaveNoMissionOrMutationAuthority() {
        let workspace = Workspace.default()
        var casual = AgentSession.newConversation(in: workspace)
        casual.beginConversation(with: "Hello, who are you? What can you do?")

        let scope = AgentSessionMissionScope(session: casual)
        let presentation = MissionPresentationProjector.project(
            session: casual,
            activity: nil,
            candidatePatches: [],
            generatedTestPlans: [],
            generatedTestArtifacts: [],
            approvals: []
        )

        XCTAssertFalse(scope.hasLinkedMission)
        XCTAssertTrue(scope.missionTaskIDs.isEmpty)
        XCTAssertFalse(presentation.current.undoEligible)
        XCTAssertNil(presentation.current.candidatePatchApproval)
        XCTAssertTrue(presentation.previousRuns.isEmpty)
    }

    func testCasualConversationPersistsExactlyOneReplyWhenProviderIsUnavailable() async throws {
        let workspace = Workspace.default()
        var casual = AgentSession(workspace: workspace, userGoal: "Hello, who are you? What can you do?")

        let result = try await AgentRuntimeCoordinator(chatProvider: nil).startMission(
            input: "Hello, who are you? What can you do?",
            workspace: workspace,
            session: &casual,
            runtime: SessionScopedRegressionRuntime()
        )

        XCTAssertNil(result.task)
        XCTAssertEqual(result.normalChatLifecycle, .failed)
        XCTAssertNil(casual.runtimeTaskID)
        XCTAssertTrue(casual.artifacts.isEmpty)
        XCTAssertTrue(casual.evidence.isEmpty)
        XCTAssertEqual(casual.conversation.messages.filter { $0.sender == .user }.count, 1)
        XCTAssertEqual(casual.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertEqual(casual.conversation.messages.last?.content, "Unable to reach the configured AI provider.")
    }

    func testPreviousMissionEventAndEvidenceCannotEnterNewConversation() {
        let workspace = Workspace.default()
        let previousTaskID = UUID()
        let previousEvent = event(
            workspaceID: workspace.id,
            taskID: previousTaskID,
            sessionID: nil,
            sequence: 1,
            type: .stepExecuted
        )
        var casual = AgentSession.newConversation(in: workspace)
        casual.beginConversation(with: "Hello")
        let chatEvent = event(
            workspaceID: workspace.id,
            taskID: nil,
            sessionID: casual.sessionID,
            sequence: 2,
            type: .stateUpdated
        )
        let original = casual

        casual.apply(event: previousEvent)
        let projected = AgentSessionEventScope.events(
            from: [previousEvent, chatEvent],
            for: casual
        )

        XCTAssertEqual(casual, original)
        XCTAssertEqual(projected.map(\.id), [chatEvent.id])
        XCTAssertTrue(casual.evidence.isEmpty)
    }

    func testExactMissionScopeIncludesOnlyRootChildrenAndOriginatingSessionEvents() {
        let workspace = Workspace.default()
        let rootTaskID = UUID()
        let childTaskID = UUID()
        let unrelatedTaskID = UUID()
        var business = AgentSession(workspace: workspace, userGoal: "Prepare an isolated patch")
        business.workspaceContext.runtimeTaskID = rootTaskID
        business.workspaceContext.missionTaskIDs = [rootTaskID, childTaskID]

        let root = event(
            workspaceID: workspace.id,
            taskID: rootTaskID,
            sessionID: nil,
            sequence: 1
        )
        let child = event(
            workspaceID: workspace.id,
            taskID: childTaskID,
            sessionID: nil,
            sequence: 2
        )
        let directChat = event(
            workspaceID: workspace.id,
            taskID: nil,
            sessionID: business.sessionID,
            sequence: 3,
            type: .stateUpdated
        )
        let unrelated = event(
            workspaceID: workspace.id,
            taskID: unrelatedTaskID,
            sessionID: nil,
            sequence: 4
        )

        let projected = AgentSessionEventScope.events(
            from: [root, child, directChat, unrelated],
            for: business
        )

        XCTAssertEqual(projected.map(\.id), [root.id, child.id, directChat.id])
    }

    func testApprovalAuthorityRejectsNewConversationAndUnrelatedMission() {
        let workspace = Workspace.default()
        let missionID = UUID()
        var business = AgentSession(workspace: workspace, userGoal: "Review Candidate Patch")
        business.workspaceContext.runtimeTaskID = missionID
        business.workspaceContext.missionTaskIDs = [missionID]
        let approval = approval(workspaceID: workspace.id, taskID: missionID)
        let casual = AgentSession.newConversation(in: workspace)

        XCTAssertTrue(AgentSessionAuthorityEvaluator.approvalIsBound(
            approval,
            scope: AgentSessionMissionScope(session: business),
            visiblePendingApprovalIDs: [approval.id]
        ))
        XCTAssertFalse(AgentSessionAuthorityEvaluator.approvalIsBound(
            approval,
            scope: AgentSessionMissionScope(session: casual),
            visiblePendingApprovalIDs: [approval.id]
        ))
        XCTAssertFalse(AgentSessionAuthorityEvaluator.approvalIsBound(
            approval,
            scope: AgentSessionMissionScope(session: business),
            visiblePendingApprovalIDs: []
        ))
    }

    func testDirectApprovalFailsClosedForBlockedFailedOrNonWaitingTask() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let request = approval(workspaceID: workspace.id, taskID: taskID)
        let blocked = task(id: taskID, workspaceID: workspace.id, state: .blocked)
        let failed = task(id: taskID, workspaceID: workspace.id, state: .failed)
        let pending = task(id: taskID, workspaceID: workspace.id, state: .pendingApproval)

        XCTAssertFalse(AgentSessionAuthorityEvaluator.approvalIsEligibleForSubmission(
            request,
            task: blocked,
            interactionState: .waitingForApproval
        ))
        XCTAssertFalse(AgentSessionAuthorityEvaluator.approvalIsEligibleForSubmission(
            request,
            task: failed,
            interactionState: .waitingForApproval
        ))
        XCTAssertFalse(AgentSessionAuthorityEvaluator.approvalIsEligibleForSubmission(
            request,
            task: pending,
            interactionState: .blockedPermission
        ))
        XCTAssertTrue(AgentSessionAuthorityEvaluator.approvalIsEligibleForSubmission(
            request,
            task: pending,
            interactionState: .waitingForApproval
        ))
    }

    func testMissionAndUndoAuthorityRestoreOnlyForOwningBusinessConversation() {
        let workspace = Workspace.default()
        let missionID = UUID()
        var business = AgentSession(workspace: workspace, userGoal: "Assess the selected workspace")
        business.workspaceContext.runtimeTaskID = missionID
        business.workspaceContext.missionTaskIDs = [missionID]
        let current = MissionPresentationProjector.project(
            session: business,
            activity: nil,
            candidatePatches: [],
            generatedTestPlans: [],
            generatedTestArtifacts: [],
            approvals: []
        ).current
        let casual = AgentSession.newConversation(in: workspace)

        XCTAssertFalse(current.undoEligible)
        XCTAssertTrue(AgentSessionAuthorityEvaluator.missionIsBound(
            current,
            current: current,
            scope: AgentSessionMissionScope(session: business)
        ))
        XCTAssertFalse(AgentSessionAuthorityEvaluator.missionIsBound(
            current,
            current: current,
            scope: AgentSessionMissionScope(session: casual)
        ))
    }

    func testAsyncReplyCommitsByOriginatingSessionAfterNewChatInsertion() throws {
        let workspace = Workspace.default()
        let firstTimestamp = Date(timeIntervalSince1970: 10)
        var origin = AgentSession.newConversation(in: workspace, createdAt: firstTimestamp)
        origin.beginConversation(with: "Hello", timestamp: firstTimestamp)
        let captured = origin
        var completion = captured
        completion.appendInteractionMessage(AgentMessage(
            timestamp: Date(timeIntervalSince1970: 20),
            sender: .agent,
            type: .text,
            content: "Hello — I am FDE."
        ))
        completion.currentState = .idle
        completion.interactionState = .idle
        let newChat = AgentSession.newConversation(
            in: workspace,
            createdAt: Date(timeIntervalSince1970: 15)
        )
        var sessions = [newChat, origin]

        XCTAssertTrue(AgentSessionAsyncBinding.commit(
            originatingSession: captured,
            updatedSession: completion,
            into: &sessions
        ))

        let committed = try XCTUnwrap(sessions.first { $0.sessionID == origin.sessionID })
        XCTAssertEqual(committed.conversation.messages.filter { $0.sender == .user }.count, 1)
        XCTAssertEqual(committed.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertTrue(try XCTUnwrap(sessions.first { $0.sessionID == newChat.sessionID }).conversation.messages.isEmpty)
    }

    func testAsyncBindingPreservesConcurrentTurnsAndDeduplicatesRepeatedCompletion() throws {
        let workspace = Workspace.default()
        var origin = AgentSession.newConversation(in: workspace, createdAt: Date(timeIntervalSince1970: 1))
        origin.beginConversation(with: "Hello", timestamp: Date(timeIntervalSince1970: 1))
        let captured = origin
        var completion = captured
        completion.appendInteractionMessage(AgentMessage(
            timestamp: Date(timeIntervalSince1970: 3),
            sender: .agent,
            type: .text,
            content: "First reply"
        ))
        var current = origin
        current.appendUserMessage("Who are you?", timestamp: Date(timeIntervalSince1970: 2))
        var sessions = [current]

        XCTAssertTrue(AgentSessionAsyncBinding.commit(
            originatingSession: captured,
            updatedSession: completion,
            into: &sessions
        ))
        XCTAssertTrue(AgentSessionAsyncBinding.commit(
            originatingSession: captured,
            updatedSession: completion,
            into: &sessions
        ))

        let committed = try XCTUnwrap(sessions.first)
        XCTAssertEqual(committed.conversation.messages.filter { $0.sender == .user }.count, 2)
        XCTAssertEqual(committed.conversation.messages.filter { $0.sender == .agent }.count, 1)
        XCTAssertEqual(
            AgentConversationWorkUnitAdapter.displayItems(
                conversation: committed.conversation,
                events: []
            ).count,
            3
        )
    }

    func testNoSelectionProjectsNoWorkspaceEvents() {
        let workspace = Workspace.default()
        let workspaceEvent = event(
            workspaceID: workspace.id,
            taskID: UUID(),
            sessionID: nil,
            sequence: 1
        )

        XCTAssertTrue(AgentSessionEventScope.events(from: [workspaceEvent], for: nil).isEmpty)
    }

    func testInitialTaskCreatedCannotLinkAcrossWorkspaces() {
        let selectedWorkspace = Workspace.default()
        let unrelatedWorkspace = Workspace.default()
        var session = AgentSession(workspace: selectedWorkspace, userGoal: "Hello")
        let unrelatedTaskID = UUID()

        session.apply(event: event(
            workspaceID: unrelatedWorkspace.id,
            taskID: unrelatedTaskID,
            sessionID: nil,
            sequence: 1
        ))

        XCTAssertNil(session.runtimeTaskID)
        XCTAssertFalse(session.workspaceContext.missionTaskIDs?.contains(unrelatedTaskID) == true)
    }

    private func event(
        workspaceID: UUID,
        taskID: UUID?,
        sessionID: UUID?,
        sequence: Int64,
        type: EventType = .taskCreated
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: "Scoped event",
            payload: sessionID.map { ["session_id": $0.uuidString] } ?? [:]
        )
    }

    private func approval(workspaceID: UUID, taskID: UUID) -> ApprovalRequest {
        ApprovalRequest(
            id: UUID(),
            workspaceID: workspaceID,
            taskID: taskID,
            stepID: "review",
            toolCallID: nil,
            targetKind: .candidatePatchPlan,
            action: "Approve Candidate Patch",
            resource: "Exact Candidate Patch",
            riskLevel: .high,
            state: .pending,
            requestedByRole: .fde,
            decidedByRole: nil,
            decisionReason: nil,
            requestedAt: Date(timeIntervalSince1970: 1),
            decidedAt: nil,
            expiresAt: nil,
            metadata: [:]
        )
    }

    private func task(id: UUID, workspaceID: UUID, state: TaskState) -> FDETask {
        FDETask(
            id: id,
            workspaceID: workspaceID,
            title: "Exact task",
            rawInput: "Review exact task",
            state: state,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}

private actor SessionScopedRegressionRuntime: AgentRuntimeExecuting {
    private var sequence: Int64 = 0

    func submitTask(input: String, workspace: Workspace) async throws -> FDETask {
        XCTFail("Casual conversation must not submit a runtime task")
        throw SafeSandboxAcceptanceRuntimeError.runtimeUnavailable
    }

    func requestStepPause(taskID: UUID, reason: String) async {}
    func resumeTask(taskID: UUID, instruction: String?) async {}
    func changeTaskApproach(taskID: UUID, instruction: String) async {}
    func stopTask(taskID: UUID, reason: String) async {}

    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        sequence += 1
        return ExecutionEvent(
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
