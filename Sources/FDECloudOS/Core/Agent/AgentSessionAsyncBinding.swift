import Foundation

/// Commits an async coordinator result to the conversation that originated
/// the request. Array position and current UI selection are never authority:
/// New Chat can insert or conversation switching can occur while the provider
/// or runtime is still working.
enum AgentSessionAsyncBinding {
    @discardableResult
    static func commit(
        originatingSession: AgentSession,
        updatedSession: AgentSession,
        into sessions: inout [AgentSession]
    ) -> Bool {
        guard updatedSession.sessionID == originatingSession.sessionID,
              updatedSession.workspaceID == originatingSession.workspaceID,
              let targetIndex = sessions.firstIndex(where: {
                  $0.sessionID == originatingSession.sessionID
                      && $0.workspaceID == originatingSession.workspaceID
              }) else {
            return false
        }

        let current = sessions[targetIndex]
        var committed = updatedSession

        // Preserve state that changed independently while the request was in
        // flight. Coordinator changes win only when that field still matches
        // the captured submission snapshot.
        if current.currentState != originatingSession.currentState {
            committed.currentState = current.currentState
        }
        if current.interactionState != originatingSession.interactionState {
            committed.interactionState = current.interactionState
        }
        if current.previousInteractionState != originatingSession.previousInteractionState {
            committed.previousInteractionState = current.previousInteractionState
        }
        if current.planApprovalStatus != originatingSession.planApprovalStatus {
            committed.planApprovalStatus = current.planApprovalStatus
        }
        if current.currentPlan != originatingSession.currentPlan {
            committed.currentPlan = current.currentPlan
        }
        if current.workspaceContext != originatingSession.workspaceContext {
            committed.workspaceContext = mergedWorkspaceContext(
                current: current.workspaceContext,
                updated: updatedSession.workspaceContext
            )
        }

        committed.conversation = mergedConversation(
            current: current.conversation,
            updated: updatedSession.conversation
        )
        committed.messages = committed.conversation.messages
        committed.evidence = mergedByID(current.evidence, updatedSession.evidence, id: \.id)
        committed.artifacts = mergedByID(current.artifacts, updatedSession.artifacts, id: \.id)
        sessions[targetIndex] = committed
        return true
    }
}

private extension AgentSessionAsyncBinding {
    static func mergedConversation(
        current: AgentConversation,
        updated: AgentConversation
    ) -> AgentConversation {
        var merged = updated
        var byID = Dictionary(uniqueKeysWithValues: current.messages.map { ($0.id, $0) })
        for message in updated.messages {
            byID[message.id] = message
        }
        merged.messages = byID.values.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }
        merged.updatedAt = max(current.updatedAt, updated.updatedAt)
        return merged
    }

    static func mergedWorkspaceContext(
        current: AgentWorkspaceContext,
        updated: AgentWorkspaceContext
    ) -> AgentWorkspaceContext {
        var merged = current
        if merged.runtimeTaskID == nil {
            merged.runtimeTaskID = updated.runtimeTaskID
        }
        var missionTaskIDs = merged.missionTaskIDs ?? []
        for taskID in updated.missionTaskIDs ?? [] where !missionTaskIDs.contains(taskID) {
            missionTaskIDs.append(taskID)
        }
        merged.missionTaskIDs = missionTaskIDs.isEmpty ? nil : missionTaskIDs
        switch (current.latestEventSequence, updated.latestEventSequence) {
        case let (current?, updated?): merged.latestEventSequence = max(current, updated)
        case let (current?, nil): merged.latestEventSequence = current
        case let (nil, updated?): merged.latestEventSequence = updated
        case (nil, nil): merged.latestEventSequence = nil
        }
        return merged
    }

    static func mergedByID<Element, ID: Hashable>(
        _ current: [Element],
        _ updated: [Element],
        id: (Element) -> ID
    ) -> [Element] {
        var result = current
        var indexes = Dictionary(uniqueKeysWithValues: current.enumerated().map { (id($0.element), $0.offset) })
        for element in updated {
            let elementID = id(element)
            if let index = indexes[elementID] {
                result[index] = element
            } else {
                indexes[elementID] = result.count
                result.append(element)
            }
        }
        return result
    }
}
