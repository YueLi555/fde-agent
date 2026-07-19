import Foundation

struct AgentSession: Identifiable, Codable, Hashable, Sendable {
    let sessionID: UUID
    var workspaceID: UUID
    var userGoal: String
    var createdAt: Date
    var currentState: AgentState
    var interactionState: AgentInteractionState
    var previousInteractionState: AgentInteractionState?
    var planApprovalStatus: AgentArtifactApprovalStatus
    var currentPlan: [PlanStep]
    var messages: [AgentMessage]
    var conversation: AgentConversation
    var evidence: [AgentEvidence]
    var artifacts: [AgentArtifact]
    var workspaceContext: AgentWorkspaceContext

    var id: UUID { sessionID }
    var runtimeTaskID: UUID? { workspaceContext.runtimeTaskID }

    init(
        sessionID: UUID = UUID(),
        workspaceID: UUID,
        userGoal: String,
        createdAt: Date = Date(),
        currentState: AgentState = .understanding,
        interactionState: AgentInteractionState = .understanding,
        previousInteractionState: AgentInteractionState? = nil,
        planApprovalStatus: AgentArtifactApprovalStatus = .pending,
        currentPlan: [PlanStep] = [],
        messages: [AgentMessage]? = nil,
        conversation: AgentConversation? = nil,
        evidence: [AgentEvidence] = [],
        artifacts: [AgentArtifact] = [],
        workspaceContext: AgentWorkspaceContext? = nil
    ) {
        let initialConversation = conversation ?? AgentConversation(
            sessionID: sessionID,
            workspaceID: workspaceID,
            messages: messages ?? [
                AgentMessage.userRequest(userGoal, timestamp: createdAt)
            ],
            createdAt: createdAt,
            updatedAt: createdAt
        )

        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.userGoal = userGoal
        self.createdAt = createdAt
        self.currentState = currentState
        self.interactionState = interactionState
        self.previousInteractionState = previousInteractionState
        self.planApprovalStatus = planApprovalStatus
        self.currentPlan = currentPlan
        self.messages = initialConversation.messages
        self.conversation = initialConversation
        self.evidence = evidence
        self.artifacts = artifacts
        self.workspaceContext = workspaceContext ?? AgentWorkspaceContext(
            workspaceID: workspaceID,
            workspaceName: "Workspace"
        )
    }

    init(workspace: Workspace, userGoal: String, createdAt: Date = Date()) {
        self.init(
            workspaceID: workspace.id,
            userGoal: userGoal,
            createdAt: createdAt,
            workspaceContext: AgentWorkspaceContext(workspace: workspace)
        )
    }

    @discardableResult
    mutating func appendUserMessage(
        _ content: String,
        messageID: UUID = UUID(),
        turnID: UUID? = nil,
        timestamp: Date = Date()
    ) -> UUID {
        let resolvedTurnID = turnID ?? messageID
        appendConversationMessage(AgentMessage.userRequest(
            content,
            id: messageID,
            turnID: resolvedTurnID,
            timestamp: timestamp
        ))
        workspaceContext.activeTurnID = resolvedTurnID
        workspaceContext.activeUserMessageID = messageID
        return messageID
    }

    mutating func refreshSelectedWorkspace(_ workspace: Workspace) {
        workspaceID = workspace.id
        workspaceContext.refreshSelectedWorkspace(workspace)
        conversation.workspaceID = workspace.id
    }

    mutating func appendInteractionMessage(_ message: AgentMessage) {
        var bound = message
        if bound.sender == .user {
            let turnID = bound.turnID ?? bound.id
            bound.turnID = turnID
            workspaceContext.activeTurnID = turnID
            workspaceContext.activeUserMessageID = bound.id
        } else if bound.sender == .agent, bound.turnID == nil {
            bound.turnID = workspaceContext.activeTurnID
            bound.inReplyToMessageID = bound.inReplyToMessageID
                ?? workspaceContext.activeUserMessageID
        }
        appendConversationMessage(bound)
    }

    mutating func markOptionSelected(messageID: UUID, optionID: String) {
        guard let index = conversation.messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversation.messages[index].selectedOptionID = optionID
        messages = conversation.messages
        conversation.updatedAt = Date()
    }

    mutating func pauseForUser() {
        previousInteractionState = interactionState
        interactionState = .waitingForUser
    }

    mutating func pauseForApproval() {
        previousInteractionState = interactionState
        interactionState = .waitingForApproval
    }

    mutating func resumeInteraction(defaultState: AgentInteractionState = .working) {
        interactionState = previousInteractionState ?? defaultState
        if interactionState == .waitingForUser || interactionState == .waitingForApproval {
            interactionState = defaultState
        }
        previousInteractionState = nil
    }

    mutating func setInteractionState(_ state: AgentInteractionState) {
        interactionState = state
    }

    mutating func addArtifact(_ artifact: AgentArtifact) {
        guard !artifacts.contains(where: { $0.id == artifact.id }) else { return }
        artifacts.append(artifact)
    }

    mutating func linkRuntimeTask(_ task: FDETask) {
        workspaceContext.linkRuntimeTask(
            task,
            turnID: workspaceContext.activeTurnID,
            userMessageID: workspaceContext.activeUserMessageID
        )
        currentPlan = task.plan
    }

    mutating func syncRuntimeTask(_ task: FDETask) {
        if runtimeTaskID == nil {
            linkRuntimeTask(task)
        } else {
            workspaceContext.linkRuntimeTask(
                task,
                turnID: workspaceContext.activeTurnID,
                userMessageID: workspaceContext.activeUserMessageID
            )
        }
        currentPlan = task.plan
        switch task.state {
        case .blocked:
            currentState = .blocked
            interactionState = .blocked
        case .failed:
            currentState = .failed
            interactionState = .failed
        case .completed, .replayed:
            currentState = .completed
            interactionState = .completed
        case .pendingApproval, .waiting:
            currentState = .waitingApproval
            interactionState = .waitingForApproval
        case .created:
            currentState = .understanding
            interactionState = .understanding
        case .planned:
            currentState = .planning
            interactionState = .planning
        case .running:
            currentState = .executing
            interactionState = .running
        }
    }

    mutating func linkMissionChildTask(_ task: FDETask, missionRunID: UUID) {
        guard workspaceID == task.workspaceID,
              runtimeTaskID == missionRunID else {
            return
        }
        var missionIDs = workspaceContext.missionTaskIDs ?? [missionRunID]
        if !missionIDs.contains(missionRunID) { missionIDs.append(missionRunID) }
        if !missionIDs.contains(task.id) { missionIDs.append(task.id) }
        workspaceContext.missionTaskIDs = missionIDs
    }

    mutating func apply(event: ExecutionEvent) {
        let isExactSessionEvent = AgentSessionEventScope.belongsToSession(event, session: self)
        // Reducer callers may explicitly seed a session with its first task.
        // AppStore never chooses that session by selection/recency: its event
        // index requires a session ID or an already-linked exact task.
        let isInitialTaskLink = runtimeTaskID == nil
            && event.workspaceID == workspaceID
            && event.type == .taskCreated
            && event.taskID != nil
        guard isExactSessionEvent || isInitialTaskLink else { return }
        if let runtimeTaskID, let eventTaskID = event.taskID, runtimeTaskID != eventTaskID {
            let isKnownMissionChild = workspaceContext.missionTaskIDs?.contains(eventTaskID) == true
            guard event.exactParentMissionRunID == runtimeTaskID
                    || isKnownMissionChild
                    || (event.type == .taskCreated
                        && (currentState == .completed || currentState == .failed)) else {
                return
            }
        }

        if event.type == .taskCreated, let taskID = event.taskID {
            var missionIDs = workspaceContext.missionTaskIDs ?? []
            if !missionIDs.contains(taskID) {
                missionIDs.append(taskID)
            }
            workspaceContext.missionTaskIDs = missionIDs
            if let parentMissionRunID = event.exactParentMissionRunID,
               parentMissionRunID != taskID,
               workspaceContext.runtimeTaskID == parentMissionRunID
                    || missionIDs.contains(parentMissionRunID) {
                // Generated Test planning and Artifact generation are child
                // activities. Keep the exact Candidate Patch task as the
                // Current Run while still retaining the child in its timeline.
                workspaceContext.runtimeTaskID = parentMissionRunID
            } else {
                workspaceContext.runtimeTaskID = taskID
            }
            workspaceContext.bindRuntimeTask(
                taskID,
                turnID: workspaceContext.activeTurnID,
                userMessageID: workspaceContext.activeUserMessageID
            )
        }
        workspaceContext.latestEventSequence = event.sequence

        if event.type == .taskCompleted,
           event.payload["completion_gate_passed"] == "false" {
            return
        }

        if event.payload["chat_only"] == "true" {
            interactionState = event.payload["interaction_state"]
                .flatMap(AgentInteractionState.init(rawValue:)) ?? .idle
        } else {
            if let mappedState = AgentState.state(for: event) {
                currentState = mappedState
            }
            if event.type == .humanApprovalRequested {
                pauseForApproval()
            } else if let mappedInteractionState = AgentInteractionState.state(for: event) {
                interactionState = mappedInteractionState
            }
        }

        if AgentEvidence.isGroundingEvidence(event) {
            let eventEvidence = AgentEvidence(event: event)
            if !evidence.contains(where: { $0.id == eventEvidence.id }) {
                evidence.append(eventEvidence)
            }
        }
        if event.payload["chat_only"] == "true", event.type != .userMessageReceived {
            return
        }
        if event.type == .userMessageReceived {
            let message = AgentResponseComposer.message(for: event)
            if shouldAppendUserMessage(from: event, message: message) {
                appendConversationMessage(message)
                workspaceContext.activeTurnID = message.turnID ?? message.id
                workspaceContext.activeUserMessageID = message.id
            }
        } else if !isUserInteractionEvent(event.type), AgentResponseComposer.shouldComposeNarration(event) {
            var message = AgentResponseComposer.message(for: event)
            let identity = workspaceContext.interactionIdentity(
                taskID: event.taskID ?? event.exactParentMissionRunID
            )
            message.turnID = message.turnID ?? identity.turnID ?? workspaceContext.activeTurnID
            message.inReplyToMessageID = message.inReplyToMessageID
                ?? identity.userMessageID
                ?? workspaceContext.activeUserMessageID
            if AgentResponseComposer.shouldAppend(message, to: conversation.messages) {
                appendConversationMessage(message)
            }
        }

        if let artifact = AgentArtifact(event: event) {
            addArtifact(artifact)
        }
    }

    @discardableResult
    mutating func replaceMessage(relatedEventID: UUID, with message: AgentMessage) -> Bool {
        guard message.sender == .agent,
              !AgentResponseComposer.containsRestrictedContent(message.content) else {
            return false
        }
        let replaced = conversation.replaceMessage(relatedEventID: relatedEventID, with: message)
        messages = conversation.messages
        return replaced
    }

    @discardableResult
    mutating func appendMessageChunk(relatedEventID: UUID, chunk: String, timestamp: Date = Date()) -> Bool {
        guard !AgentResponseComposer.containsRestrictedContent(chunk) else { return false }
        let appended = conversation.appendMessageChunk(
            relatedEventID: relatedEventID,
            chunk: chunk,
            timestamp: timestamp
        )
        messages = conversation.messages
        return appended
    }

    mutating func fail(with error: Error) {
        currentState = .failed
        interactionState = .failed
        appendConversationMessage(
            AgentMessage(
                sender: .agent,
                type: .result,
                content: AgentPresentationSanitizer.safeContent(
                    error.localizedDescription,
                    fallback: "Agent failed before completion"
                )
            )
        )
    }

    private mutating func appendConversationMessage(_ message: AgentMessage) {
        conversation.append(message)
        messages = conversation.messages
    }

    private func shouldAppendUserMessage(from event: ExecutionEvent, message: AgentMessage) -> Bool {
        guard message.sender == .user else { return false }
        if conversation.messages.contains(where: {
            $0.id == message.id || $0.relatedEventID == event.id
        }) {
            return false
        }

        let content = normalizedUserMessage(message.content)
        guard !content.isEmpty else { return false }
        return true
    }

    private func normalizedUserMessage(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func isUserInteractionEvent(_ eventType: EventType) -> Bool {
        switch eventType {
        case .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted,
             .userApprovalRejected:
            return true
        default:
            return false
        }
    }
}

extension ExecutionEvent {
    var exactParentMissionRunID: UUID? {
        [
            payload["generated_test_source_candidate_patch_task_id"],
            payload["candidate_patch_source_task_id"],
            payload["source_candidate_patch_task_id"]
        ]
        .compactMap { $0 }
        .compactMap(UUID.init(uuidString:))
        .first
    }
}
