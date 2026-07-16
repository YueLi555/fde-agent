import Foundation

struct AgentInteractionRuntimeEvent: Equatable, Sendable {
    var type: EventType
    var summary: String
    var payload: [String: String]
}

struct AgentInteractionController: Sendable {
    @discardableResult
    func askQuestion(
        _ question: String,
        options: [AgentMessageOption],
        session: inout AgentSession,
        timestamp: Date = Date()
    ) -> UUID {
        let message = AgentMessage.question(
            AgentPresentationSanitizer.safeContent(question, fallback: "Agent needs your input before continuing"),
            options: options,
            timestamp: timestamp
        )
        session.appendInteractionMessage(message)
        session.pauseForUser()
        return message.id
    }

    @discardableResult
    func requestDecision(
        _ prompt: String,
        options: [AgentMessageOption],
        session: inout AgentSession,
        timestamp: Date = Date()
    ) -> UUID {
        let message = AgentMessage.decisionRequest(
            AgentPresentationSanitizer.safeContent(prompt, fallback: "Agent needs one decision before continuing"),
            options: options,
            timestamp: timestamp
        )
        session.appendInteractionMessage(message)
        session.pauseForUser()
        return message.id
    }

    func receiveUserReply(
        _ reply: String,
        session: inout AgentSession,
        timestamp: Date = Date()
    ) -> AgentInteractionRuntimeEvent {
        let safeReply = AgentPresentationSanitizer.safeContent(reply, fallback: "User replied")
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp,
                sender: .user,
                type: .text,
                content: safeReply
            )
        )
        session.resumeInteraction()

        return AgentInteractionRuntimeEvent(
            type: .userMessageReceived,
            summary: "User message received",
            payload: [
                "session_id": session.sessionID.uuidString,
                "message": safeReply,
                "interaction_state": session.interactionState.rawValue
            ]
        )
    }

    func selectDecision(
        optionID: String,
        messageID: UUID,
        session: inout AgentSession,
        timestamp: Date = Date()
    ) -> AgentInteractionRuntimeEvent {
        session.markOptionSelected(messageID: messageID, optionID: optionID)
        let selectedTitle = session.conversation.messages
            .first(where: { $0.id == messageID })?
            .options
            .first(where: { $0.id == optionID })?
            .title ?? "Selected option"
        let safeTitle = AgentPresentationSanitizer.safeContent(selectedTitle, fallback: "Selected option")

        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp,
                sender: .user,
                type: .text,
                content: safeTitle
            )
        )
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp.addingTimeInterval(0.001),
                sender: .agent,
                type: .progressUpdate,
                content: "Continuing with your selected approach"
            )
        )
        session.resumeInteraction()

        return AgentInteractionRuntimeEvent(
            type: .userDecisionSelected,
            summary: "User decision selected",
            payload: [
                "session_id": session.sessionID.uuidString,
                "message_id": messageID.uuidString,
                "option_id": optionID,
                "decision": safeTitle,
                "interaction_state": session.interactionState.rawValue
            ]
        )
    }

    func approvePlan(session: inout AgentSession, timestamp: Date = Date()) -> AgentInteractionRuntimeEvent {
        session.planApprovalStatus = .approved
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp,
                sender: .user,
                type: .text,
                content: "Approve current plan"
            )
        )
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp.addingTimeInterval(0.001),
                sender: .agent,
                type: .progressUpdate,
                content: "Plan approved; continuing execution"
            )
        )
        session.resumeInteraction()

        return AgentInteractionRuntimeEvent(
            type: .userDecisionSelected,
            summary: "User approved plan",
            payload: [
                "session_id": session.sessionID.uuidString,
                "decision": "approve_plan",
                "interaction_state": session.interactionState.rawValue
            ]
        )
    }

    func requestPlanModification(session: inout AgentSession, timestamp: Date = Date()) -> AgentInteractionRuntimeEvent {
        session.planApprovalStatus = .pending
        let questionID = requestDecision(
            "How should I adjust the plan?",
            options: [
                AgentMessageOption(id: "change_approach", title: "Change approach"),
                AgentMessageOption(id: "ignore_connector", title: "Ignore this connector"),
                AgentMessageOption(id: "use_another_strategy", title: "Use another strategy")
            ],
            session: &session,
            timestamp: timestamp
        )

        return AgentInteractionRuntimeEvent(
            type: .userDecisionSelected,
            summary: "User requested plan modification",
            payload: [
                "session_id": session.sessionID.uuidString,
                "message_id": questionID.uuidString,
                "decision": "modify_plan",
                "interaction_state": session.interactionState.rawValue
            ]
        )
    }

    func approvalGranted(session: inout AgentSession, approvalID: UUID, timestamp: Date = Date()) -> AgentInteractionRuntimeEvent {
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp,
                sender: .user,
                type: .text,
                content: "Approve requested action"
            )
        )
        session.resumeInteraction()

        return AgentInteractionRuntimeEvent(
            type: .userApprovalGranted,
            summary: "User approval granted",
            payload: [
                "session_id": session.sessionID.uuidString,
                "approval_request_id": approvalID.uuidString,
                "interaction_state": session.interactionState.rawValue
            ]
        )
    }

    func approvalRejected(session: inout AgentSession, approvalID: UUID, timestamp: Date = Date()) -> AgentInteractionRuntimeEvent {
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp,
                sender: .user,
                type: .text,
                content: "Reject requested action"
            )
        )
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp.addingTimeInterval(0.001),
                sender: .agent,
                type: .warning,
                content: "I stopped this mission because the requested action was rejected. Send a new instruction or choose a safer approach if you want me to continue differently."
            )
        )
        session.currentState = .failed
        session.setInteractionState(.failed)

        return AgentInteractionRuntimeEvent(
            type: .userApprovalRejected,
            summary: "User approval rejected",
            payload: [
                "session_id": session.sessionID.uuidString,
                "approval_request_id": approvalID.uuidString,
                "interaction_state": session.interactionState.rawValue
            ]
        )
    }

    func continueMission(session: inout AgentSession, timestamp: Date = Date()) -> AgentInteractionRuntimeEvent {
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp,
                sender: .user,
                type: .text,
                content: "Continue previous task"
            )
        )
        session.appendInteractionMessage(
            AgentMessage(
                timestamp: timestamp.addingTimeInterval(0.001),
                sender: .agent,
                type: .progressUpdate,
                content: "Continuing from the previous mission context"
            )
        )
        session.resumeInteraction()

        return AgentInteractionRuntimeEvent(
            type: .userMessageReceived,
            summary: "User continued previous task",
            payload: [
                "session_id": session.sessionID.uuidString,
                "continuation": "true",
                "interaction_state": session.interactionState.rawValue
            ]
        )
    }
}
