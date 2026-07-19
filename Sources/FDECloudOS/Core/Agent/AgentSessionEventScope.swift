import Foundation

/// The only authority boundary used to project mission-owned data into a
/// conversation. A session without an exact runtime task is a chat-only
/// conversation and cannot inherit workspace-wide mission state.
struct AgentSessionMissionScope: Equatable, Sendable {
    let sessionID: UUID
    let workspaceID: UUID
    let missionTaskIDs: Set<UUID>

    init(session: AgentSession) {
        sessionID = session.sessionID
        workspaceID = session.workspaceID
        if let runtimeTaskID = session.runtimeTaskID {
            missionTaskIDs = Set((session.workspaceContext.missionTaskIDs ?? []) + [runtimeTaskID])
        } else {
            missionTaskIDs = []
        }
    }

    var hasLinkedMission: Bool {
        !missionTaskIDs.isEmpty
    }

    func containsMissionTask(_ taskID: UUID?) -> Bool {
        guard let taskID else { return false }
        return missionTaskIDs.contains(taskID)
    }

    func contains(_ event: ExecutionEvent) -> Bool {
        guard event.workspaceID == workspaceID else { return false }
        if event.payload["session_id"] == sessionID.uuidString {
            return true
        }
        return containsMissionTask(event.taskID)
            || containsMissionTask(event.exactParentMissionRunID)
    }
}

enum AgentSessionAuthorityEvaluator {
    static func approvalIsEligibleForSubmission(
        _ approval: ApprovalRequest,
        task: FDETask?,
        interactionState: AgentInteractionState
    ) -> Bool {
        guard interactionState == .waitingForApproval,
              approval.state == .pending,
              let task,
              approval.taskID == task.id else {
            return false
        }
        return task.state != .blocked && task.state != .failed
    }

    static func approvalIsBound(
        _ approval: ApprovalRequest,
        scope: AgentSessionMissionScope?,
        visiblePendingApprovalIDs: Set<UUID>
    ) -> Bool {
        guard let scope, scope.hasLinkedMission else { return false }
        return approval.workspaceID == scope.workspaceID
            && scope.containsMissionTask(approval.taskID)
            && visiblePendingApprovalIDs.contains(approval.id)
    }

    static func missionIsBound(
        _ summary: MissionSummary,
        current: MissionSummary?,
        scope: AgentSessionMissionScope?
    ) -> Bool {
        guard let scope, scope.hasLinkedMission,
              scope.containsMissionTask(summary.missionID),
              let summaryLineageKey = summary.lineage?.lineageKey,
              let current,
              let currentLineageKey = current.lineage?.lineageKey else {
            return false
        }
        return current.missionID == summary.missionID
            && currentLineageKey == summaryLineageKey
    }
}

enum AgentSessionEventScope {
    static func events(from events: [ExecutionEvent], for session: AgentSession?) -> [ExecutionEvent] {
        guard let session else {
            return []
        }

        return events.filter { event in
            belongsToSession(event, session: session)
        }
    }

    static func belongsToSession(_ event: ExecutionEvent, session: AgentSession) -> Bool {
        AgentSessionMissionScope(session: session).contains(event)
    }
}
