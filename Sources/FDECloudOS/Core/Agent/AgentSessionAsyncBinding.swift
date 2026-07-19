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
        merged.messages = current.messages
        for message in updated.messages {
            if let existingIndex = merged.messages.firstIndex(where: { $0.id == message.id }) {
                merged.messages[existingIndex] = message
            } else {
                merged.append(message)
            }
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
        merged.activeTurnID = current.activeTurnID ?? updated.activeTurnID
        merged.activeUserMessageID = current.activeUserMessageID ?? updated.activeUserMessageID
        merged.turnIDByRuntimeTaskID = mergedBindings(
            current.turnIDByRuntimeTaskID,
            updated.turnIDByRuntimeTaskID
        )
        merged.userMessageIDByRuntimeTaskID = mergedBindings(
            current.userMessageIDByRuntimeTaskID,
            updated.userMessageIDByRuntimeTaskID
        )
        return merged
    }

    static func mergedBindings(
        _ current: [UUID: UUID]?,
        _ updated: [UUID: UUID]?
    ) -> [UUID: UUID]? {
        var merged = updated ?? [:]
        for (key, value) in current ?? [:] {
            merged[key] = value
        }
        return merged.isEmpty ? nil : merged
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
