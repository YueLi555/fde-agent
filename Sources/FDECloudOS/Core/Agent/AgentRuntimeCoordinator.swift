import Foundation

protocol AgentRuntimeExecuting: Sendable {
    func submitTask(input: String, workspace: Workspace) async throws -> FDETask
    func submitTask(input: String, workspace: Workspace, origin: OriginBinding) async throws -> FDETask
    func runSafeSandboxAcceptance(input: String, workspace: Workspace) async throws -> FDETask
    func runCandidatePatchGeneration(input: String, workspace: Workspace) async throws -> FDETask
    func runGeneratedTestPlanning(input: String, workspace: Workspace) async throws -> FDETask
    func runCandidatePatchRevert(input: String, workspace: Workspace) async throws -> FDETask
    func runCandidatePatchSandboxDestroy(input: String, workspace: Workspace) async throws -> FDETask
    func recoverTask(taskID: UUID, instruction: String, workspace: Workspace) async throws -> FDETask?
    func requestStepPause(taskID: UUID, reason: String) async
    func resumeTask(taskID: UUID, instruction: String?) async
    func changeTaskApproach(taskID: UUID, instruction: String) async
    func stopTask(taskID: UUID, reason: String) async
    func recordAuditEvent(
        type: EventType,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent
    func recordUserSubmissionAuditEvent(
        logicalEventID: UUID,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent
    func loadAuditEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent]
}

extension AgentRuntimeExecuting {
    func submitTask(input: String, workspace: Workspace, origin: OriginBinding) async throws -> FDETask {
        try await submitTask(input: input, workspace: workspace)
    }

    func loadAuditEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent] { [] }
    func recoverTask(taskID: UUID, instruction: String, workspace: Workspace) async throws -> FDETask? { nil }
    func runSafeSandboxAcceptance(input: String, workspace: Workspace) async throws -> FDETask {
        throw SafeSandboxAcceptanceRuntimeError.runtimeUnavailable
    }
    func runCandidatePatchGeneration(input: String, workspace: Workspace) async throws -> FDETask {
        throw CandidatePatchError.blocked(.assessmentMissing)
    }
    func runGeneratedTestPlanning(input: String, workspace: Workspace) async throws -> FDETask {
        throw GeneratedTestError.blocked(.explicitSourceBindingRequired)
    }
    func runCandidatePatchRevert(input: String, workspace: Workspace) async throws -> FDETask {
        throw CandidatePatchRuntimeError.runtimeUnavailable
    }
    func runCandidatePatchSandboxDestroy(input: String, workspace: Workspace) async throws -> FDETask {
        throw CandidatePatchRuntimeError.runtimeUnavailable
    }
    func recordUserSubmissionAuditEvent(
        logicalEventID: UUID,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String,
        payload: [String: String]
    ) async throws -> ExecutionEvent {
        try await recordAuditEvent(
            type: .userMessageReceived,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: summary,
            payload: payload.merging(["client_message_id": logicalEventID.uuidString]) { current, _ in current }
        )
    }
}

extension RuntimeKernel: AgentRuntimeExecuting {}

enum AgentRequestRoute: String, Codable, Hashable, Sendable {
    case conversationalChat
    case workspaceQuestion
    case workspaceReadOnlyInvestigation
    case safeSandboxAcceptance
    case candidatePatchGeneration
    case generatedTestPlan
    case candidatePatchRevert
    case candidatePatchSandboxDestroy
    case executableTask
    case clarificationRequired
    case activeMissionStatusQuery
    case activeMissionClarification
    case activeMissionRetry
    case activeMissionResume
}

/// The authoritative boundary between conversation and execution. This is
/// intentionally sentence-level: nouns such as "Legacy", "Agent", "inspect",
/// or "patch" never grant runtime authority on their own.
enum FDEExecutionIntentClassification: String, Codable, CaseIterable, Hashable, Sendable {
    case advisoryConversation
    case clarificationRequired
    case executableReadOnly
    case executableCandidateChange
    case ordinaryConversation
    case otherExecutable

    var startsRuntime: Bool {
        switch self {
        case .executableReadOnly, .executableCandidateChange, .otherExecutable:
            return true
        case .advisoryConversation, .clarificationRequired, .ordinaryConversation:
            return false
        }
    }
}

struct AgentRuntimePreflightContext: Equatable, Sendable {
    var hasExactProductionReadinessReport: Bool

    static let empty = AgentRuntimePreflightContext(
        hasExactProductionReadinessReport: false
    )
}

enum ConversationRuntimePreflightReason: String, Equatable, Sendable {
    case missingAssessmentTarget
    case missingPatchScope
    case missingInspectionTarget
    case missingProductionReadinessReport
    case productionReadinessReviewRequiresHumanAction
}

struct ConversationRuntimePreflightResult: Equatable, Sendable {
    var reason: ConversationRuntimePreflightReason
    var question: String
}

enum ConversationRuntimePreflight {
    static func evaluate(
        _ input: String,
        context: AgentRuntimePreflightContext = .empty
    ) -> ConversationRuntimePreflightResult? {
        let normalized = input
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:。！？；："))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        if normalized.contains("review production readiness")
            || normalized == "production readiness review" {
            if context.hasExactProductionReadinessReport {
                return ConversationRuntimePreflightResult(
                    reason: .productionReadinessReviewRequiresHumanAction,
                    question: "The exact Production Readiness Report is available for this Mission. Review it through the scoped Human Action so the decision remains bound to this conversation and artifact revision."
                )
            }
            return ConversationRuntimePreflightResult(
                reason: .missingProductionReadinessReport,
                question: "This conversation and Mission do not have an exact Production Readiness Report. Select the Mission that owns the report, or generate the prerequisite report before requesting review."
            )
        }

        if [
            "assess an ai integration",
            "assess ai integration",
            "assess an ai agent integration",
            "evaluate an ai integration"
        ].contains(normalized) {
            return ConversationRuntimePreflightResult(
                reason: .missingAssessmentTarget,
                question: "Which module, API, workflow, or subsystem should I assess for the AI integration?"
            )
        }

        if [
            "propose an isolated patch",
            "prepare an isolated patch",
            "propose a candidate patch",
            "prepare a candidate patch"
        ].contains(normalized) {
            return ConversationRuntimePreflightResult(
                reason: .missingPatchScope,
                question: "What behavior should change, and which component or files are in scope for the isolated patch?"
            )
        }

        if [
            "inspect a customer system",
            "inspect the customer system",
            "inspect customer system"
        ].contains(normalized) {
            return ConversationRuntimePreflightResult(
                reason: .missingInspectionTarget,
                question: "Which customer system, root, repository, integration, or other target should I inspect?"
            )
        }

        return nil
    }
}

struct AgentRuntimeCoordinatorResult: Sendable {
    var task: FDETask?
    var recordedEvents: [ExecutionEvent]
    var waitingForUser: Bool
    var normalChatLifecycle: NormalChatLifecycle?

    static func waiting(
        recordedEvents: [ExecutionEvent] = [],
        normalChatLifecycle: NormalChatLifecycle? = nil
    ) -> AgentRuntimeCoordinatorResult {
        AgentRuntimeCoordinatorResult(
            task: nil,
            recordedEvents: recordedEvents,
            waitingForUser: true,
            normalChatLifecycle: normalChatLifecycle
        )
    }

    static func running(task: FDETask, recordedEvents: [ExecutionEvent]) -> AgentRuntimeCoordinatorResult {
        AgentRuntimeCoordinatorResult(
            task: task,
            recordedEvents: recordedEvents,
            waitingForUser: false,
            normalChatLifecycle: nil
        )
    }

    static func continued(
        recordedEvents: [ExecutionEvent],
        normalChatLifecycle: NormalChatLifecycle? = nil
    ) -> AgentRuntimeCoordinatorResult {
        AgentRuntimeCoordinatorResult(
            task: nil,
            recordedEvents: recordedEvents,
            waitingForUser: false,
            normalChatLifecycle: normalChatLifecycle
        )
    }
}

struct AgentRuntimeCoordinator: Sendable {
    private let interactionController: AgentInteractionController
    private let missionClassifier: AgentMissionClassifier
    private let decisionEngine: AgentDecisionEngine
    private let chatProvider: (any AgentChatProviding)?
    private let workspaceQuestionAnswerer: any AgentWorkspaceQuestionAnswering

    init(
        interactionController: AgentInteractionController = AgentInteractionController(),
        missionClassifier: AgentMissionClassifier = AgentMissionClassifier(),
        decisionEngine: AgentDecisionEngine = AgentDecisionEngine(),
        chatProvider: (any AgentChatProviding)? = nil,
        workspaceQuestionAnswerer: any AgentWorkspaceQuestionAnswering = LocalWorkspaceQuestionAnswerer()
    ) {
        self.interactionController = interactionController
        self.missionClassifier = missionClassifier
        self.decisionEngine = decisionEngine
        self.chatProvider = chatProvider
        self.workspaceQuestionAnswerer = workspaceQuestionAnswerer
    }

    func startMission(
        input: String,
        workspace: Workspace,
        session: inout AgentSession,
        runtime: any AgentRuntimeExecuting,
        userMessageID: UUID? = nil,
        preflightContext: AgentRuntimePreflightContext = .empty
    ) async throws -> AgentRuntimeCoordinatorResult {
        session.refreshSelectedWorkspace(workspace)
        let safeInput = AgentPresentationSanitizer.safeMarkdownContent(input, fallback: "User mission")
        let intent = missionClassifier.intent(for: safeInput)
        let isCapabilityQuestion = missionClassifier.isCapabilityQuestion(safeInput)
        let isExplicitMission = missionClassifier.isExplicitMissionRequest(safeInput, intent: intent)
        let selectedMode = missionClassifier.conversationMode(
            for: safeInput,
            intent: intent,
            hasActiveRuntimeTask: false
        )
        let executionIntent = missionClassifier.executionIntentClassification(
            for: safeInput,
            intent: intent
        )
        let preflight = executionIntent == .advisoryConversation
            || executionIntent == .ordinaryConversation
            ? nil
            : ConversationRuntimePreflight.evaluate(safeInput, context: preflightContext)
        let route: AgentRequestRoute
        if preflight != nil || executionIntent == .clarificationRequired {
            route = .clarificationRequired
        } else {
            route = self.route(
                input: safeInput,
                intent: intent,
                isCapabilityQuestion: isCapabilityQuestion,
                isExplicitMission: isExplicitMission,
                selectedMode: selectedMode,
                executionIntent: executionIntent
            )
        }
        let missionSemantic = MissionExecutionSemantic(intent: intent)
        let startsRuntime = route == .workspaceReadOnlyInvestigation
            || route == .safeSandboxAcceptance
            || route == .candidatePatchGeneration
            || route == .generatedTestPlan
            || route == .candidatePatchRevert
            || route == .candidatePatchSandboxDestroy
            || route == .executableTask
        let shouldAnswerInChat = route == .conversationalChat
        let needsClarification = route == .clarificationRequired
        let decision = route == .conversationalChat || route == .workspaceQuestion
            ? decisionEngine.decideDirectChat(intent: intent)
            : decisionEngine.decideNewMission(
                intent: intent,
                isCapabilityQuestion: isCapabilityQuestion,
                needsClarification: needsClarification
            )
        let logicalUserEventID = userMessageID
            ?? session.workspaceContext.activeUserMessageID
            ?? session.conversation.messages.last(where: { $0.sender == .user })?.id
            ?? UUID()
        session.workspaceContext.activeTurnID = session.workspaceContext.activeTurnID ?? logicalUserEventID
        session.workspaceContext.activeUserMessageID = logicalUserEventID
        let userEvent = try await runtime.recordUserSubmissionAuditEvent(
            logicalEventID: logicalUserEventID,
            workspaceID: workspace.id,
            taskID: nil,
            summary: "User mission received",
            payload: [
                "session_id": session.sessionID.uuidString,
                "client_message_id": logicalUserEventID.uuidString,
                "turn_id": (session.workspaceContext.activeTurnID ?? logicalUserEventID).uuidString,
                "message": safeInput,
                "intent_type": intent.intentType.rawValue,
                "intent_confidence": String(intent.confidence),
                "intent_language": intent.detectedLanguage,
                "interaction_state": session.interactionState.rawValue,
                "agent_loop_phase": "observe",
                "selected_route": route.rawValue,
                "execution_intent_classification": executionIntent.rawValue,
                "mission_semantic": missionSemantic.rawValue,
                "runtime_mode": startsRuntime
                    ? AgentRuntimeMode.agentTask.rawValue
                    : AgentRuntimeMode.chat.rawValue,
                "chat_only": startsRuntime ? "false" : "true",
                "selected_chat_mode": selectedMode.rawValue
            ].merging(decision.auditPayload) { current, _ in current }
        )

        if shouldAnswerInChat {
            let response = await answerDirectlyInChat(
                input: safeInput,
                intent: intent,
                workspace: workspace,
                session: &session,
                selectedMode: selectedMode,
                runtime: runtime,
                includeActiveTaskContext: false
            )
            let answerEvent = try await runtime.recordAuditEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: nil,
                summary: "Agent answered chat message",
                payload: [
                    "session_id": session.sessionID.uuidString,
                    "interaction_state": session.interactionState.rawValue,
                    "agent_loop_phase": "answer",
                    "runtime_mode": response.runtimeMode.rawValue,
                    "model_provider": response.provider?.rawValue ?? "",
                    "used_fallback": response.usedFallback ? "true" : "false",
                    "selected_chat_mode": selectedMode.rawValue,
                    "model": response.model ?? "",
                    "quality_retry_used": response.qualityRetryUsed ? "true" : "false",
                    "quality_rejection_reason": response.qualityRejectionReason ?? "",
                    "chat_lifecycle": chatLifecycle(for: response).rawValue,
                    "chat_only": "true"
                ].merging(decision.auditPayload) { current, _ in current }
            )
            return .continued(
                recordedEvents: [userEvent, answerEvent],
                normalChatLifecycle: chatLifecycle(for: response)
            )
        }

        if route == .workspaceQuestion {
            let evidenceEvents = try await answerWorkspaceQuestion(
                input: safeInput,
                intent: intent,
                workspace: workspace,
                session: &session,
                runtime: runtime,
                decisionPayload: decision.auditPayload
            )
            return .continued(recordedEvents: [userEvent] + evidenceEvents)
        }

        if route == .candidatePatchGeneration {
            session.setInteractionState(.running)
            let task = try await runtime.runCandidatePatchGeneration(input: safeInput, workspace: workspace)
            return .running(task: task, recordedEvents: [userEvent])
        }

        if route == .generatedTestPlan {
            session.setInteractionState(.waitingForUser)
            let task = try await runtime.runGeneratedTestPlanning(input: safeInput, workspace: workspace)
            return .running(task: task, recordedEvents: [userEvent])
        }

        if route == .candidatePatchRevert {
            session.setInteractionState(.waitingForApproval)
            let task = try await runtime.runCandidatePatchRevert(input: safeInput, workspace: workspace)
            return .running(task: task, recordedEvents: [userEvent])
        }

        if route == .candidatePatchSandboxDestroy {
            session.setInteractionState(.waitingForApproval)
            let task = try await runtime.runCandidatePatchSandboxDestroy(input: safeInput, workspace: workspace)
            return .running(task: task, recordedEvents: [userEvent])
        }

        if route == .safeSandboxAcceptance {
            session.setInteractionState(.running)
            let task = try await runtime.runSafeSandboxAcceptance(input: safeInput, workspace: workspace)
            return .running(task: task, recordedEvents: [userEvent])
        }

        if route == .clarificationRequired {
            askForMissionClarification(
                session: &session,
                question: preflight?.question
                    ?? intent.clarificationQuestion
                    ?? "What would you like me to do in this workspace?",
                language: intent.detectedLanguage
            )
            let questionEvent = try await runtime.recordAuditEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: nil,
                summary: "Agent paused for user input",
                payload: [
                    "session_id": session.sessionID.uuidString,
                    "interaction_state": session.interactionState.rawValue,
                    "agent_loop_phase": "wait",
                    "selected_route": route.rawValue,
                    "runtime_mode": AgentRuntimeMode.chat.rawValue,
                    "chat_only": "true",
                    "turn_id": (session.workspaceContext.activeTurnID ?? logicalUserEventID).uuidString,
                    "user_message_id": logicalUserEventID.uuidString,
                    "preflight_reason": preflight?.reason.rawValue ?? "intent_clarification"
                ].merging(decision.auditPayload) { current, _ in current }
            )
            return .waiting(recordedEvents: [userEvent, questionEvent])
        }

        session.setInteractionState(.running)
        let task = try await runtime.submitTask(
            input: safeInput,
            workspace: workspace,
            origin: OriginBinding(
                sessionID: session.sessionID,
                turnID: session.workspaceContext.activeTurnID ?? logicalUserEventID,
                requestMessageID: logicalUserEventID
            )
        )
        return .running(task: task, recordedEvents: [userEvent])
    }

    func resumeMission(
        reply: String,
        workspace: Workspace,
        session: inout AgentSession,
        runtime: any AgentRuntimeExecuting,
        continuation: Bool = false,
        userMessageAlreadyAppended: Bool = false,
        userMessageID: UUID? = nil,
        preflightContext: AgentRuntimePreflightContext = .empty
    ) async throws -> AgentRuntimeCoordinatorResult {
        session.refreshSelectedWorkspace(workspace)
        let interactionStateBeforeReply = session.interactionState
        let wasWaitingForApproval = session.interactionState == .waitingForApproval
        let wasWaitingForRuntime = session.interactionState == .waitingForUser
            || session.interactionState == .waitingForApproval
        let replyIntent = missionClassifier.intent(for: reply)
        let isCapabilityQuestion = missionClassifier.isCapabilityQuestion(reply)
        let isExplicitMission = missionClassifier.isExplicitMissionRequest(reply, intent: replyIntent)
        let runtimeIsClosed = isClosedRuntime(session)
        let selectedMode = missionClassifier.conversationMode(
            for: reply,
            intent: replyIntent,
            hasActiveRuntimeTask: session.runtimeTaskID != nil && !runtimeIsClosed
        )
        let linkedTaskEvents: [ExecutionEvent]
        if let taskID = session.runtimeTaskID {
            linkedTaskEvents = (try? await runtime.loadAuditEvents(workspaceID: workspace.id, taskID: taskID)) ?? []
        } else {
            linkedTaskEvents = []
        }
        let activeMissionRoute = activeMissionRoute(
            input: reply,
            session: session,
            events: linkedTaskEvents
        )
        let executionIntent = missionClassifier.executionIntentClassification(
            for: reply,
            intent: replyIntent
        )
        let preflight = executionIntent == .advisoryConversation
            || executionIntent == .ordinaryConversation
            ? nil
            : ConversationRuntimePreflight.evaluate(reply, context: preflightContext)
        let requestRoute = preflight == nil && executionIntent != .clarificationRequired
            ? route(
                input: reply,
                intent: replyIntent,
                isCapabilityQuestion: isCapabilityQuestion,
                isExplicitMission: isExplicitMission,
                selectedMode: selectedMode,
                executionIntent: executionIntent
            )
            : .clarificationRequired
        let route: AgentRequestRoute
        if let activeMissionRoute,
           activeMissionRoute == .activeMissionRetry || activeMissionRoute == .activeMissionResume {
            route = activeMissionRoute
        } else if requestRoute == .workspaceReadOnlyInvestigation
            || requestRoute == .candidatePatchGeneration
            || requestRoute == .generatedTestPlan
            || requestRoute == .candidatePatchRevert
            || requestRoute == .candidatePatchSandboxDestroy
            || requestRoute == .safeSandboxAcceptance
            || requestRoute == .executableTask {
            route = requestRoute
        } else {
            route = activeMissionRoute ?? requestRoute
        }
        let selectedActiveMissionRoute = route == activeMissionRoute ? activeMissionRoute : nil
        let missionSemantic = MissionExecutionSemantic(intent: replyIntent)
        let isActiveMissionControl = session.runtimeTaskID != nil
            && !runtimeIsClosed
            && (missionClassifier.isMissionControlInstruction(reply, intent: replyIntent) || selectedActiveMissionRoute != nil)
        let includeActiveTaskContext = session.runtimeTaskID != nil && (
            isActiveMissionControl
                || missionClassifier.isPriorWorkQuestion(reply)
                || missionClassifier.isActiveMissionReference(reply)
                || missionClassifier.isLikelyActiveMissionClarification(
                    reply,
                    session: session,
                    wasWaitingForRuntime: wasWaitingForRuntime,
                    selectedMode: selectedMode
                )
        )
        let shouldAnswerInChat = route == .conversationalChat && !isActiveMissionControl
        let shouldAnswerWorkspaceQuestion = route == .workspaceQuestion && !isActiveMissionControl
        let needsClarification = route == .clarificationRequired
        let decision = shouldAnswerInChat || shouldAnswerWorkspaceQuestion
            ? decisionEngine.decideDirectChat(intent: replyIntent)
            : decisionEngine.decideMissionReply(
                reply: reply,
                intent: replyIntent,
                hasRuntimeTask: session.runtimeTaskID != nil,
                wasWaitingForRuntime: wasWaitingForRuntime,
                isCapabilityQuestion: isCapabilityQuestion,
                needsClarification: needsClarification
            )
        let event: AgentInteractionRuntimeEvent
        if continuation && userMessageAlreadyAppended {
            session.resumeInteraction()
            event = AgentInteractionRuntimeEvent(
                type: .userMessageReceived,
                summary: "User continued previous task",
                payload: [
                    "session_id": session.sessionID.uuidString,
                    "continuation": "true",
                    "interaction_state": session.interactionState.rawValue
                ]
            )
        } else if continuation {
            event = interactionController.continueMission(session: &session)
        } else if userMessageAlreadyAppended {
            let safeReply = AgentPresentationSanitizer.safeContent(reply, fallback: "User replied")
            session.resumeInteraction()
            event = AgentInteractionRuntimeEvent(
                type: .userMessageReceived,
                summary: "User message received",
                payload: [
                    "session_id": session.sessionID.uuidString,
                    "message": safeReply,
                    "interaction_state": session.interactionState.rawValue
                ]
            )
        } else {
            event = interactionController.receiveUserReply(reply, session: &session)
        }
        let logicalUserEventID = userMessageID
            ?? session.workspaceContext.activeUserMessageID
            ?? session.conversation.messages.last(where: { $0.sender == .user })?.id
            ?? UUID()
        session.workspaceContext.activeTurnID = session.workspaceContext.activeTurnID ?? logicalUserEventID
        session.workspaceContext.activeUserMessageID = logicalUserEventID
        let recordedUserEvent = try await runtime.recordUserSubmissionAuditEvent(
            logicalEventID: logicalUserEventID,
            workspaceID: workspace.id,
            taskID: includeActiveTaskContext ? session.runtimeTaskID : nil,
            summary: event.summary,
            payload: event.payload.merging([
                "client_message_id": logicalUserEventID.uuidString,
                "turn_id": (session.workspaceContext.activeTurnID ?? logicalUserEventID).uuidString,
                "agent_loop_phase": "resume",
                "selected_route": route.rawValue,
                "mission_semantic": missionSemantic.rawValue,
                "runtime_mode": shouldAnswerInChat || shouldAnswerWorkspaceQuestion ? AgentRuntimeMode.chat.rawValue : AgentRuntimeMode.agentTask.rawValue,
                "chat_only": shouldAnswerInChat || shouldAnswerWorkspaceQuestion ? "true" : "false",
                "selected_chat_mode": selectedMode.rawValue,
                "active_task_context_included": includeActiveTaskContext ? "true" : "false"
            ]) { current, _ in current }
            .merging(decision.auditPayload) { current, _ in current }
        )

        if let selectedActiveMissionRoute, let taskID = session.runtimeTaskID {
            switch selectedActiveMissionRoute {
            case .activeMissionStatusQuery:
                let taskState = recoverableTaskState(events: linkedTaskEvents, session: session) ?? .blocked
                let message = activeMissionStatusMessage(
                    input: reply,
                    events: linkedTaskEvents,
                    currentState: taskState
                )
                apply(taskState: taskState, to: &session)
                session.appendInteractionMessage(
                    AgentMessage(sender: .agent, type: .warning, content: message)
                )
                let statusEvent = try await runtime.recordAuditEvent(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: taskID,
                    summary: "Active mission status reported",
                    payload: [
                        "state": taskState.rawValue,
                        "selected_route": selectedActiveMissionRoute.rawValue,
                        "lifecycle_event": "ACTIVE_MISSION_STATUS_REPORTED",
                        "user_visible_message": message,
                        "blocker_reason": latestBlocker(in: linkedTaskEvents),
                        "successful_read_evidence": hasSuccessfulReadEvidence(linkedTaskEvents) ? "true" : "false",
                        "success": "true"
                    ]
                )
                return .continued(recordedEvents: [recordedUserEvent, statusEvent])
            case .activeMissionClarification, .activeMissionRetry, .activeMissionResume:
                if claimsPriorFileEvidence(reply), !hasSuccessfulReadEvidence(linkedTaskEvents) {
                    session.appendInteractionMessage(
                        AgentMessage(
                            sender: .agent,
                            type: .warning,
                            content: noPriorReadEvidenceMessage(events: linkedTaskEvents, language: replyIntent.detectedLanguage)
                        )
                    )
                }
                if let recovered = try await runtime.recoverTask(
                    taskID: taskID,
                    instruction: reply,
                    workspace: workspace
                ) {
                    session.syncRuntimeTask(recovered)
                    return .running(task: recovered, recordedEvents: [recordedUserEvent])
                }
            default:
                break
            }
        }

        if shouldAnswerInChat {
            let preservedState: AgentInteractionState? = session.runtimeTaskID != nil && !runtimeIsClosed
                ? interactionStateBeforeReply
                : nil
            let response = await answerDirectlyInChat(
                input: reply,
                intent: replyIntent,
                workspace: workspace,
                session: &session,
                restoreInteractionState: preservedState,
                selectedMode: selectedMode,
                runtime: runtime,
                includeActiveTaskContext: includeActiveTaskContext
            )
            let answerEvent = try await runtime.recordAuditEvent(
                type: .stateUpdated,
                workspaceID: workspace.id,
                taskID: includeActiveTaskContext ? session.runtimeTaskID : nil,
                summary: "Agent answered chat message",
                payload: [
                    "session_id": session.sessionID.uuidString,
                    "interaction_state": session.interactionState.rawValue,
                    "agent_loop_phase": "answer",
                    "runtime_mode": response.runtimeMode.rawValue,
                    "model_provider": response.provider?.rawValue ?? "",
                    "used_fallback": response.usedFallback ? "true" : "false",
                    "selected_chat_mode": selectedMode.rawValue,
                    "model": response.model ?? "",
                    "quality_retry_used": response.qualityRetryUsed ? "true" : "false",
                    "quality_rejection_reason": response.qualityRejectionReason ?? "",
                    "chat_lifecycle": chatLifecycle(for: response).rawValue,
                    "active_task_context_included": includeActiveTaskContext ? "true" : "false",
                    "chat_only": "true"
                ].merging(decision.auditPayload) { current, _ in current }
            )
            let recordedEvents = [recordedUserEvent, answerEvent]
            if preservedState == .waitingForUser || preservedState == .waitingForApproval {
                return .waiting(
                    recordedEvents: recordedEvents,
                    normalChatLifecycle: chatLifecycle(for: response)
                )
            }
            return .continued(
                recordedEvents: recordedEvents,
                normalChatLifecycle: chatLifecycle(for: response)
            )
        }

        if shouldAnswerWorkspaceQuestion {
            let preservedState: AgentInteractionState? = session.runtimeTaskID != nil && !runtimeIsClosed
                ? interactionStateBeforeReply
                : nil
            let evidenceEvents = try await answerWorkspaceQuestion(
                input: reply,
                intent: replyIntent,
                workspace: workspace,
                session: &session,
                runtime: runtime,
                decisionPayload: decision.auditPayload,
                restoreInteractionState: preservedState,
                includeActiveTaskContext: includeActiveTaskContext
            )
            let recordedEvents = [recordedUserEvent] + evidenceEvents
            if preservedState == .waitingForUser || preservedState == .waitingForApproval {
                return .waiting(recordedEvents: recordedEvents)
            }
            return .continued(recordedEvents: recordedEvents)
        }

        if route == .candidatePatchGeneration {
            session.setInteractionState(.running)
            let task = try await runtime.runCandidatePatchGeneration(input: reply, workspace: workspace)
            return .running(task: task, recordedEvents: [recordedUserEvent])
        }


        if route == .generatedTestPlan {
            session.setInteractionState(.waitingForUser)
            let task = try await runtime.runGeneratedTestPlanning(input: reply, workspace: workspace)
            return .running(task: task, recordedEvents: [recordedUserEvent])
        }


        if route == .candidatePatchRevert {
            session.setInteractionState(.waitingForApproval)
            let task = try await runtime.runCandidatePatchRevert(input: reply, workspace: workspace)
            return .running(task: task, recordedEvents: [recordedUserEvent])
        }


        if route == .candidatePatchSandboxDestroy {
            session.setInteractionState(.waitingForApproval)
            let task = try await runtime.runCandidatePatchSandboxDestroy(input: reply, workspace: workspace)
            return .running(task: task, recordedEvents: [recordedUserEvent])
        }

        if route == .safeSandboxAcceptance {
            session.setInteractionState(.running)
            let task = try await runtime.runSafeSandboxAcceptance(input: reply, workspace: workspace)
            return .running(task: task, recordedEvents: [recordedUserEvent])
        }

        if route == .workspaceReadOnlyInvestigation {
            session.setInteractionState(.running)
            let task = try await runtime.submitTask(
                input: reply,
                workspace: workspace,
                origin: OriginBinding(
                    sessionID: session.sessionID,
                    turnID: session.workspaceContext.activeTurnID ?? logicalUserEventID,
                    requestMessageID: logicalUserEventID
                )
            )
            return .running(task: task, recordedEvents: [recordedUserEvent])
        }

        if session.runtimeTaskID == nil || runtimeIsClosed {
            if route == .clarificationRequired {
                askForMissionClarification(
                    session: &session,
                    question: preflight?.question
                        ?? replyIntent.clarificationQuestion
                        ?? "What would you like me to do in this workspace?",
                    language: replyIntent.detectedLanguage
                )
                let clarificationEvent = try await runtime.recordAuditEvent(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: nil,
                    summary: "Agent still needs concrete task details",
                    payload: [
                        "session_id": session.sessionID.uuidString,
                        "interaction_state": session.interactionState.rawValue,
                        "agent_loop_phase": "wait",
                        "selected_route": route.rawValue,
                        "runtime_mode": AgentRuntimeMode.agentTask.rawValue,
                        "chat_only": "true",
                        "turn_id": (session.workspaceContext.activeTurnID ?? logicalUserEventID).uuidString,
                        "user_message_id": logicalUserEventID.uuidString,
                        "preflight_reason": preflight?.reason.rawValue ?? "intent_clarification",
                        "intent_type": replyIntent.intentType.rawValue,
                        "intent_confidence": String(replyIntent.confidence)
                    ].merging(decision.auditPayload) { current, _ in current }
                )
                return .waiting(recordedEvents: [recordedUserEvent, clarificationEvent])
            }

            session.setInteractionState(.running)
            let task = try await runtime.submitTask(input: resumedMissionInput(reply: reply, session: session), workspace: workspace)
            return .running(task: task, recordedEvents: [recordedUserEvent])
        }

        if let taskID = session.runtimeTaskID {
            if decision.nextAction == .stopTask {
                await runtime.stopTask(taskID: taskID, reason: reply)
                session.setInteractionState(.failed)
                session.appendInteractionMessage(
                    AgentMessage(
                        sender: .agent,
                        type: .warning,
                        content: "I will stop at the next safe checkpoint and keep the trace available."
                    )
                )
                return .continued(recordedEvents: [recordedUserEvent])
            }

            if decision.nextAction == .changeApproach {
                await runtime.changeTaskApproach(taskID: taskID, instruction: reply)
                session.setInteractionState(.running)
                session.appendInteractionMessage(
                    AgentMessage(
                        sender: .agent,
                        type: .decision,
                        content: "I will apply that change at the next safe checkpoint before running more work."
                    )
                )
                return .continued(recordedEvents: [recordedUserEvent])
            }

            if wasWaitingForApproval && decision.nextAction == .resumeTask {
                session.pauseForApproval()
                session.appendInteractionMessage(
                    AgentMessage(
                        sender: .agent,
                        type: .question,
                        content: approvalGateMessage(language: replyIntent.detectedLanguage)
                    )
                )
                return .waiting(recordedEvents: [recordedUserEvent])
            }

            if decision.nextAction == .resumeTask {
                await runtime.resumeTask(taskID: taskID, instruction: reply)
                session.resumeInteraction()
                session.appendInteractionMessage(
                    AgentMessage(
                        sender: .agent,
                        type: .progressUpdate,
                        content: "I have your answer. I will resume from the paused runtime checkpoint."
                    )
                )
                return .continued(recordedEvents: [recordedUserEvent])
            }

            if decision.nextAction == .requestPause {
                await runtime.requestStepPause(taskID: taskID, reason: reply)
                session.pauseForUser()
                session.appendInteractionMessage(
                    AgentMessage(
                        sender: .agent,
                        type: .question,
                        content: "I will pause at the next safe checkpoint before continuing."
                    )
                )
                return .waiting(recordedEvents: [recordedUserEvent])
            }
        }

        session.appendInteractionMessage(
            AgentMessage(
                sender: .agent,
                type: .progressUpdate,
                content: "I noted your instruction. I will apply it to the active mission context where the runtime allows it."
            )
        )
        return .continued(recordedEvents: [recordedUserEvent])
    }

    func resumeMissionFromSelectedDecision(
        decision: String,
        workspace: Workspace,
        session: inout AgentSession,
        runtime: any AgentRuntimeExecuting
    ) async throws -> AgentRuntimeCoordinatorResult {
        let safeDecision = AgentPresentationSanitizer.safeContent(decision, fallback: "Continue mission")

        if session.runtimeTaskID == nil {
            if selectedDecisionNeedsConcreteTaskDetails(safeDecision) {
                askForSelectedDecisionDetails(
                    decision: safeDecision,
                    session: &session,
                    language: selectedDecisionLanguage(decision: safeDecision, session: session)
                )
                let clarificationEvent = try await runtime.recordAuditEvent(
                    type: .stateUpdated,
                    workspaceID: workspace.id,
                    taskID: nil,
                    summary: "Agent requested concrete task details",
                    payload: [
                        "session_id": session.sessionID.uuidString,
                        "selected_decision": safeDecision,
                        "interaction_state": session.interactionState.rawValue,
                        "agent_loop_phase": "wait"
                    ]
                )
                return .waiting(recordedEvents: [clarificationEvent])
            }
            session.setInteractionState(.running)
            let task = try await runtime.submitTask(
                input: resumedMissionInput(reply: safeDecision, session: session),
                workspace: workspace
            )
            return .running(task: task, recordedEvents: [])
        }

        return try await resumeMission(
            reply: safeDecision,
            workspace: workspace,
            session: &session,
            runtime: runtime
        )
    }

    func startApprovedImplementation(
        workspace: Workspace,
        session: inout AgentSession,
        runtime: any AgentRuntimeExecuting
    ) async throws -> AgentRuntimeCoordinatorResult {
        let input = approvedImplementationInput(for: session)
        session.setInteractionState(.running)
        session.appendInteractionMessage(
            AgentMessage(
                sender: .agent,
                type: .progressUpdate,
                content: "Customer approval received. I will generate the integration test plan, code patch, and verification report."
            )
        )
        let task = try await runtime.submitTask(input: input, workspace: workspace)
        return .running(task: task, recordedEvents: [])
    }

    private func askForMissionClarification(session: inout AgentSession, question: String, language: String) {
        _ = interactionController.askQuestion(
            question,
            options: missionOptions(language: language),
            session: &session
        )
    }

    private func missionOptions(language: String) -> [AgentMessageOption] {
        if language == "zh" {
            return [
                AgentMessageOption(id: "inspect_workspace", title: "查看工作区"),
                AgentMessageOption(id: "debug_issue", title: "排查问题"),
                AgentMessageOption(id: "modify_code", title: "修改代码")
            ]
        }
        return [
            AgentMessageOption(id: "inspect_workspace", title: "Inspect the workspace"),
            AgentMessageOption(id: "debug_issue", title: "Debug an issue"),
            AgentMessageOption(id: "modify_code", title: "Modify code")
        ]
    }

    private func askForSelectedDecisionDetails(decision: String, session: inout AgentSession, language: String) {
        let normalized = decision.lowercased()
        let usesChinese = language == "zh"
        let question: String

        if normalized.contains("debug") || normalized.contains("排查") {
            question = usesChinese
                ? "你要我排查哪个具体问题？请提供报错、异常现象、复现步骤，或你期望我验证的失败场景。"
                : "What specific issue should I debug? Please provide the error, failing behavior, reproduction steps, or failure case to verify."
        } else {
            question = usesChinese
                ? "你要我具体修改什么代码？请说明目标功能、期望行为、相关文件，是否允许我写代码并跑测试。"
                : "What specific code change should I make? Please describe the target behavior, likely files or feature, and whether I may write code and run tests."
        }

        _ = interactionController.askQuestion(
            question,
            options: [],
            session: &session
        )
    }

    private func selectedDecisionNeedsConcreteTaskDetails(_ decision: String) -> Bool {
        let normalized = decision.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "modify code",
            "debug an issue",
            "debug issue",
            "修改代码",
            "排查问题"
        ].contains(normalized)
    }

    private func selectedDecisionLanguage(decision: String, session: AgentSession) -> String {
        if missionClassifier.intent(for: decision).detectedLanguage == "zh" {
            return "zh"
        }
        return missionClassifier.intent(for: session.userGoal).detectedLanguage
    }

    private func route(
        input: String,
        intent: MissionIntent,
        isCapabilityQuestion: Bool,
        isExplicitMission: Bool,
        selectedMode: FDEConversationMode,
        executionIntent: FDEExecutionIntentClassification
    ) -> AgentRequestRoute {
        if executionIntent == .advisoryConversation || executionIntent == .ordinaryConversation {
            return .conversationalChat
        }
        if executionIntent == .clarificationRequired {
            return .clarificationRequired
        }
        if intent.intentType == .candidatePatchSandboxDestroy {
            return .candidatePatchSandboxDestroy
        }
        if intent.intentType == .candidatePatchRevert {
            return .candidatePatchRevert
        }
        if intent.intentType == .candidatePatchGeneration {
            return .candidatePatchGeneration
        }
        if intent.intentType == .generatedTestPlan {
            return .generatedTestPlan
        }
        if intent.intentType == .safeSandboxAcceptance {
            return .safeSandboxAcceptance
        }
        if executionIntent == .executableReadOnly {
            return .workspaceReadOnlyInvestigation
        }
        if missionClassifier.isPriorWorkQuestion(input) {
            return .conversationalChat
        }
        if missionClassifier.isIdentityQuestion(input)
            || isCapabilityQuestion
            || missionClassifier.isAgentAbilityQuestion(input) {
            return .conversationalChat
        }
        if missionClassifier.isCasualChat(input) || missionClassifier.isFeedbackOrComplaint(input) {
            return .conversationalChat
        }
        if selectedMode == .legacyTransformationAdvisory || selectedMode == .engineeringExplanation {
            return .conversationalChat
        }
        if missionClassifier.isPassiveWorkspaceSummaryRequest(input) {
            return .workspaceQuestion
        }
        if missionClassifier.isWorkspaceQuestion(input, intent: intent) {
            return .workspaceReadOnlyInvestigation
        }
        if intent.intentType == .answerQuestion {
            return .conversationalChat
        }
        if isExplicitMission {
            return missionClassifier.needsMissionClarification(input, intent: intent)
                ? .clarificationRequired
                : .executableTask
        }
        return .conversationalChat
    }

    private func isClosedRuntime(_ session: AgentSession) -> Bool {
        session.currentState == .completed
            || session.currentState == .failed
            || session.interactionState == .completed
            || session.interactionState == .failed
    }

    private func answerWorkspaceQuestion(
        input: String,
        intent: MissionIntent,
        workspace: Workspace,
        session: inout AgentSession,
        runtime: any AgentRuntimeExecuting,
        decisionPayload: [String: String],
        restoreInteractionState: AgentInteractionState? = nil,
        includeActiveTaskContext: Bool = false
    ) async throws -> [ExecutionEvent] {
        session.setInteractionState(restoreInteractionState ?? .idle)
        if session.runtimeTaskID == nil {
            session.currentState = .idle
        }
        let auditTaskID = includeActiveTaskContext ? session.runtimeTaskID : nil
        let answer = await workspaceQuestionAnswerer.answer(input: input, intent: intent, workspace: workspace)
        session.appendInteractionMessage(
            AgentMessage(
                sender: .agent,
                type: .text,
                content: answer.content
            )
        )

        var recordedEvents: [ExecutionEvent] = []
        for evidence in answer.evidence {
            let eventType: EventType = evidence.success ? .stepExecuted : .toolFailed
            let event = try await runtime.recordAuditEvent(
                type: eventType,
                workspaceID: workspace.id,
                taskID: auditTaskID,
                summary: evidence.success ? "Workspace question evidence collected" : "Workspace question evidence failed",
                payload: [
                    "session_id": session.sessionID.uuidString,
                    "selected_route": AgentRequestRoute.workspaceQuestion.rawValue,
                    "runtime_mode": AgentRuntimeMode.chat.rawValue,
                    "chat_only": "true",
                    "tool_name": evidence.toolName,
                    "target_path": evidence.targetPath,
                    "actual_result": evidence.actualResult,
                    "success": evidence.success ? "true" : "false",
                    "error": evidence.error ?? "",
                    "interaction_state": session.interactionState.rawValue,
                    "agent_loop_phase": "answer"
                ].merging(decisionPayload) { current, _ in current }
            )
            recordedEvents.append(event)
        }

        let answerEvent = try await runtime.recordAuditEvent(
            type: .stateUpdated,
            workspaceID: workspace.id,
            taskID: auditTaskID,
            summary: "Agent answered workspace question from evidence",
            payload: [
                "session_id": session.sessionID.uuidString,
                "selected_route": AgentRequestRoute.workspaceQuestion.rawValue,
                "runtime_mode": AgentRuntimeMode.chat.rawValue,
                "chat_only": "true",
                "evidence_count": String(answer.evidence.count),
                "interaction_state": session.interactionState.rawValue,
                "agent_loop_phase": "answer"
            ].merging(decisionPayload) { current, _ in current }
        )
        recordedEvents.append(answerEvent)
        return recordedEvents
    }

    private func answerDirectlyInChat(
        input: String,
        intent: MissionIntent,
        workspace: Workspace,
        session: inout AgentSession,
        restoreInteractionState: AgentInteractionState? = nil,
        selectedMode: FDEConversationMode,
        runtime: any AgentRuntimeExecuting,
        includeActiveTaskContext: Bool
    ) async -> AgentChatResponse {
        if let restoreInteractionState {
            session.setInteractionState(restoreInteractionState)
        } else if session.runtimeTaskID == nil {
            session.setInteractionState(.responding)
        }
        let response: AgentChatResponse
        if missionClassifier.isPriorWorkQuestion(input) {
            response = priorWorkResponse(input: input, intent: intent, session: session)
        } else {
            response = await chatResponse(
                input: input,
                intent: intent,
                workspace: workspace,
                session: session,
                selectedMode: selectedMode,
                runtime: runtime,
                includeActiveTaskContext: includeActiveTaskContext
            )
        }
        session.appendInteractionMessage(
            AgentMessage(
                sender: .agent,
                type: .text,
                content: response.content
            )
        )
        let lifecycle = chatLifecycle(for: response)
        session.setInteractionState(
            lifecycle == .failed ? .blockedProvider : (restoreInteractionState ?? .idle)
        )
        if session.runtimeTaskID == nil {
            session.currentState = lifecycle == .failed ? .failed : .idle
        }
        return response
    }

    private func chatResponse(
        input: String,
        intent: MissionIntent,
        workspace: Workspace,
        session: AgentSession,
        selectedMode: FDEConversationMode,
        runtime: any AgentRuntimeExecuting,
        includeActiveTaskContext: Bool
    ) async -> AgentChatResponse {
        let toolEvidence: [AgentToolEvidenceContext]
        if includeActiveTaskContext, let taskID = session.runtimeTaskID {
            let events = (try? await runtime.loadAuditEvents(workspaceID: workspace.id, taskID: taskID)) ?? []
            toolEvidence = AgentToolEvidenceContext.successfulPairs(
                from: events,
                workspaceID: workspace.id,
                taskID: taskID
            )
        } else {
            toolEvidence = []
        }
        let request = AgentChatRequest(
            message: AgentPresentationSanitizer.safeMarkdownContent(input, fallback: "User message"),
            detectedLanguage: intent.detectedLanguage,
            intentType: intent.intentType,
            workspaceName: AgentPresentationSanitizer.safeContent(workspace.name, fallback: "Workspace"),
            legacyWorkspaceName: workspace.localProjectRootURL?.lastPathComponent,
            agentWorkspaceName: workspace.localAgentProjectRootURL?.lastPathComponent,
            interactionState: includeActiveTaskContext ? session.interactionState : .idle,
            hasRuntimeTask: includeActiveTaskContext && session.runtimeTaskID != nil,
            selectedMode: selectedMode,
            recentMessages: session.runtimeTaskID != nil && !includeActiveTaskContext
                ? []
                : recentChatMessages(session, currentInput: input),
            runtimeProfile: AgentRuntimeProfile.make(
                interactionState: includeActiveTaskContext ? session.interactionState : .idle,
                hasRuntimeTask: includeActiveTaskContext && session.runtimeTaskID != nil
            ),
            toolEvidence: toolEvidence,
            activeTaskContextIncluded: includeActiveTaskContext
        )
        guard let chatProvider, chatProvider.isAvailable else {
            return providerUnavailableResponse(for: request)
        }

        do {
            var generated = try await chatProvider.generateChatResponse(for: request)
            generated.model = generated.model ?? chatProvider.modelIdentifier
            let qualityGuard = FDEChatQualityGuard()
            if let reason = qualityGuard.rejectionReason(for: generated, request: request) {
                var repairRequest = request
                repairRequest.repairInstruction = qualityGuard.repairInstruction(
                    reason: reason,
                    mode: selectedMode
                )
                var repaired = try await chatProvider.generateChatResponse(for: repairRequest)
                repaired.model = repaired.model ?? chatProvider.modelIdentifier
                if let repairReason = qualityGuard.rejectionReason(for: repaired, request: request) {
                    return qualityFailureResponse(
                        for: request,
                        provider: chatProvider.kind,
                        model: chatProvider.modelIdentifier,
                        reason: "\(reason);repair:\(repairReason)"
                    )
                }
                repaired.qualityRetryUsed = true
                repaired.qualityRejectionReason = reason
                return repaired.sanitized(
                    fallbackContent: qualityFailureMessage(for: request),
                    provider: chatProvider.kind,
                    usedFallback: repaired.usedFallback || chatProvider.kind == .local,
                    runtimeMode: repaired.usedFallback || chatProvider.kind == .local ? .fallback : .chat
                )
            }
            return generated.sanitized(
                fallbackContent: qualityFailureMessage(for: request),
                provider: chatProvider.kind,
                usedFallback: generated.usedFallback || chatProvider.kind == .local,
                runtimeMode: generated.usedFallback || chatProvider.kind == .local ? .fallback : .chat
            )
        } catch {
            return providerFailureResponse(for: request, error: error)
        }
    }

    private func providerFailureResponse(for request: AgentChatRequest, error: Error) -> AgentChatResponse {
        let failure = ModelRoutingError.classified(error)
        return AgentChatResponse(
            content: "Unable to reach the configured AI provider.",
            confidence: 1,
            provider: nil,
            usedFallback: true,
            runtimeMode: .fallback,
            qualityRejectionReason: failure.diagnosticReason
        )
    }

    private func providerUnavailableResponse(for request: AgentChatRequest) -> AgentChatResponse {
        AgentChatResponse(
            content: "Unable to reach the configured AI provider.",
            confidence: 1,
            provider: nil,
            usedFallback: true,
            runtimeMode: .fallback,
            qualityRejectionReason: "chat_provider_unavailable"
        )
    }

    private func chatLifecycle(for response: AgentChatResponse) -> NormalChatLifecycle {
        let diagnostic = response.qualityRejectionReason?.lowercased() ?? ""
        let providerFailure = diagnostic == "chat_provider_unavailable"
            || diagnostic.contains("provider_request_failed")
            || diagnostic.contains("provider_transport_failed")
            || diagnostic.contains("provider_unavailable")
            || diagnostic.contains("provider_output_invalid")
        return providerFailure ? .failed : .completed
    }

    private func qualityFailureResponse(
        for request: AgentChatRequest,
        provider: ModelProviderKind,
        model: String?,
        reason: String
    ) -> AgentChatResponse {
        AgentChatResponse(
            content: qualityFailureMessage(for: request, reason: reason),
            confidence: 1,
            provider: provider,
            usedFallback: false,
            runtimeMode: .chat,
            model: model,
            qualityRetryUsed: true,
            qualityRejectionReason: reason
        )
    }

    private func qualityFailureMessage(for request: AgentChatRequest) -> String {
        qualityFailureMessage(for: request, reason: nil)
    }

    private func qualityFailureMessage(for request: AgentChatRequest, reason: String?) -> String {
        if reason?.contains("unsupported_evidence_claim") == true {
            return request.detectedLanguage == "zh"
                ? "当前对话中没有与这项文件检查或执行说法匹配的成功工具证据，因此我不能把它表述为已验证事实。"
                : "This dialog has no successful tool evidence matching that file-inspection or execution claim, so I cannot present it as a verified fact."
        }
        return request.detectedLanguage == "zh"
            ? "模型没有生成与当前问题可靠对应的回答。请重试。"
            : "The model did not produce a reliable answer to the current question. Please try again."
    }

    private func localChatResponse(for request: AgentChatRequest) async -> AgentChatResponse {
        let provider = StateMachineChatProvider()
        let response = (try? await provider.generateChatResponse(for: request))
            ?? AgentChatResponse(
                content: request.detectedLanguage == "zh"
                    ? "我在。普通问题会作为对话处理；只有明确的工作区动作才会启动执行。"
                    : "I’m here. Ordinary questions stay in chat; only an explicit workspace action starts execution.",
                confidence: 0.7,
                provider: .local,
                usedFallback: true,
                runtimeMode: .fallback
            )
        return response.sanitized(
            fallbackContent: response.content,
            provider: .local,
            usedFallback: true,
            runtimeMode: .fallback
        )
    }

    private func priorWorkResponse(
        input: String,
        intent: MissionIntent,
        session: AgentSession
    ) -> AgentChatResponse {
        let usesChinese = intent.detectedLanguage == "zh"
            || input.unicodeScalars.contains { (0x4E00...0x9FFF).contains(Int($0.value)) }
        let patchArtifacts = session.artifacts.filter { artifact in
            let searchable = "\(artifact.title) \(artifact.description) \(artifact.detail)".lowercased()
            let explicitlyEmpty = [
                "no patch",
                "no diff",
                "no code change",
                "no files modified",
                "no file modified",
                "没有补丁",
                "没有差异",
                "没有修改代码",
                "未修改代码",
                "未修改文件"
            ].contains { searchable.contains($0) }
            guard !explicitlyEmpty else { return false }
            return artifact.type == .codePatch
                || searchable.contains("patch")
                || searchable.contains("diff")
        }
        let changeEvidence = session.evidence.filter { item in
            let searchable = "\(item.title) \(item.detail)".lowercased()
            let describesChange = [
                "modified ",
                "changed ",
                "updated ",
                "created file",
                "file patch",
                "code patch",
                "git diff",
                "修改了",
                "变更了",
                "代码补丁",
                "文件差异"
            ].contains { searchable.contains($0) }
            let identifiesCode = [
                ".swift",
                ".ts",
                ".tsx",
                ".js",
                ".jsx",
                ".py",
                ".json",
                ".yaml",
                ".yml"
            ].contains { searchable.contains($0) }
            return describesChange && identifiesCode
        }

        var details: [String] = []
        details.append(contentsOf: patchArtifacts.compactMap { artifact in
            safeHistoryDetail(title: artifact.title, detail: artifact.detail)
        })
        details.append(contentsOf: changeEvidence.compactMap { item in
            safeHistoryDetail(title: item.title, detail: item.detail)
        })
        details = uniqueHistoryDetails(details)

        let content: String
        if details.isEmpty {
            content = usesChinese
                ? "我检查了当前对话保存的任务产物和证据，没有找到非空代码补丁或文件差异。因此根据现有记录，刚才没有修改代码。"
                : "I checked the mission artifacts and evidence saved in this dialog and found no non-empty code patch or file diff. Based on the recorded evidence, no code was modified."
        } else {
            let bullets = details.map { "- \($0)" }.joined(separator: "\n")
            content = usesChinese
                ? "我根据当前对话保存的任务产物和变更证据确认了这些代码修改：\n\(bullets)"
                : "From the mission artifacts and change evidence saved in this dialog, I found these code modifications:\n\(bullets)"
        }
        return AgentChatResponse(
            content: content,
            confidence: 1,
            provider: .local,
            usedFallback: false,
            runtimeMode: .chat
        )
    }

    private func safeHistoryDetail(title: String, detail: String) -> String? {
        let safeTitle = AgentPresentationSanitizer.safeContent(title, fallback: "")
        let safeDetail = AgentPresentationSanitizer.safeMarkdownContent(detail, fallback: "")
        guard !safeTitle.isEmpty || !safeDetail.isEmpty else { return nil }
        if safeTitle.isEmpty {
            return safeDetail
        }
        if safeDetail.isEmpty || safeDetail.caseInsensitiveCompare(safeTitle) == .orderedSame {
            return safeTitle
        }
        return "\(safeTitle): \(safeDetail)"
    }

    private func uniqueHistoryDetails(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private func recentChatMessages(
        _ session: AgentSession,
        currentInput: String
    ) -> [AgentChatMessageContext] {
        var messages = session.conversation.messages.compactMap { message -> AgentChatMessageContext? in
            guard message.sender == .user || message.sender == .agent else { return nil }
            guard message.type == .text || (message.sender == .user && message.type == .userRequest) else {
                return nil
            }
            let content = AgentPresentationSanitizer.safeMarkdownContent(message.content, fallback: "")
            guard !content.isEmpty, !AgentPresentationSanitizer.containsRestrictedContent(content) else {
                return nil
            }
            return AgentChatMessageContext(
                sender: message.sender,
                type: message.type,
                content: content
            )
        }
        let normalizedCurrent = normalizedChatText(currentInput)
        if let lastIndex = messages.lastIndex(where: { $0.sender == .user }),
           normalizedChatText(messages[lastIndex].content) == normalizedCurrent {
            messages.remove(at: lastIndex)
        }
        return Array(messages.suffix(16))
    }

    private func normalizedChatText(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func shouldTreatAsMissionClarification(
        reply: String,
        intent: MissionIntent,
        session: AgentSession,
        wasWaitingForRuntime: Bool,
        isCapabilityQuestion: Bool,
        isExplicitMission: Bool
    ) -> Bool {
        guard session.runtimeTaskID == nil, wasWaitingForRuntime else { return false }
        guard session.conversation.messages.last(where: { $0.sender == .agent })?.type == .question else {
            return false
        }
        if isExplicitMission {
            return true
        }
        if isCapabilityQuestion
            || missionClassifier.isAgentAbilityQuestion(reply)
            || missionClassifier.isCasualChat(reply)
            || missionClassifier.isFeedbackOrComplaint(reply)
            || intent.intentType == .answerQuestion {
            return false
        }
        return !missionClassifier.isVagueStandalone(reply)
    }

    private func approvalGateMessage(language: String) -> String {
        if language == "zh" {
            return "这次任务还停在审批点。直接继续会绕过安全门禁；请使用 Approve/Reject，或者告诉我“换个方式”“跳过这个动作”等更安全的方案。"
        }
        return "This mission is still paused at an approval gate. I cannot continue past it from a normal message; approve, reject, or tell me a safer change of approach."
    }

    private func activeMissionRoute(
        input: String,
        session: AgentSession,
        events: [ExecutionEvent]
    ) -> AgentRequestRoute? {
        guard session.runtimeTaskID != nil,
              let state = recoverableTaskState(events: events, session: session) else {
            return nil
        }
        let retryable = state != .failed || latestBlocker(in: events).hasPrefix("planner_")
        guard [.planned, .running, .waiting, .blocked, .failed].contains(state), retryable else {
            return nil
        }

        let text = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let statusPhrases = [
            "好了吗", "现在怎么样", "做到哪了", "为什么停了", "为什么停止", "为什么阻塞", "为何阻塞",
            "status", "how is it going", "where are we", "why did it stop", "why is it blocked"
        ]
        if statusPhrases.contains(where: { text.contains($0) }) {
            return .activeMissionStatusQuery
        }
        let retryPhrases = [
            "重试", "再试一次", "重新检查", "retry", "try again", "重新规划"
        ]
        if retryPhrases.contains(where: { text.contains($0) }) {
            return .activeMissionRetry
        }
        let resumePhrases = [
            "继续", "恢复任务", "恢复分析", "完成剩余分析", "完成剩余检查",
            "continue", "resume", "继续检查", "继续分析", "finish remaining analysis", "complete remaining analysis",
            "读取剩余文件", "后完成报告", "完成前端入口", "api 地址检查",
            "read remaining files", "then finish the report", "finish the frontend entry", "api address check"
        ]
        if resumePhrases.contains(where: { text.contains($0) }) {
            return .activeMissionResume
        }
        let hasResumablePartial = events.contains {
            $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
                && $0.payload["same_task_resumable"] == "true"
        }
        let readOnlyContinuationTerms = [
            "读取", "检查", "分析", "完成", "read", "inspect", "analy", "finish", "complete"
        ]
        if state == .blocked,
           hasResumablePartial,
           readOnlyContinuationTerms.contains(where: { text.contains($0) }) {
            return .activeMissionResume
        }
        let clarificationPhrases = [
            "只检查 legacy", "只看 legacy", "不要检查 agent", "不要分析 agent", "从项目根目录开始",
            "检查前端和后端连接", "当前 legacy", "legacy root", "only legacy", "do not inspect agent"
        ]
        if clarificationPhrases.contains(where: { text.contains($0) }) {
            return .activeMissionClarification
        }
        return nil
    }

    private func recoverableTaskState(
        events: [ExecutionEvent],
        session: AgentSession
    ) -> TaskState? {
        let stateEvents: Set<EventType> = [
            .taskCreated, .planGenerated, .stateUpdated, .taskCompleted,
            .toolCalled, .stepExecuted, .toolFailed
        ]
        if let persisted = events.reversed().first(where: { stateEvents.contains($0.type) }).flatMap({ event in
            event.payload["state"].flatMap(TaskState.init(rawValue:))
                ?? event.payload["task_state"].flatMap(TaskState.init(rawValue:))
        }) {
            return persisted
        }
        switch session.currentState {
        case .planning: return .planned
        case .executing, .recovering: return .running
        case .waitingApproval: return .waiting
        case .blocked: return .blocked
        case .failed: return .failed
        case .completed: return .completed
        case .idle, .understanding: return .created
        }
    }

    private func latestBlocker(in events: [ExecutionEvent]) -> String {
        events.reversed().compactMap { $0.payload["blocker_reason"] }.first ?? "unknown"
    }

    private func hasSuccessfulReadEvidence(_ events: [ExecutionEvent]) -> Bool {
        events.contains { event in
            event.type == .stepExecuted
                && event.payload["success"] == "true"
                && event.payload["command"] == "engineering.read_file"
        }
    }

    private func claimsPriorFileEvidence(_ input: String) -> Bool {
        let text = input.lowercased()
        return [
            "根据刚才真正读取到的文件", "根据刚才读取的文件", "根据之前读取的文件",
            "based on the files just read", "based on the files previously read"
        ].contains { text.contains($0) }
    }

    private func noPriorReadEvidenceMessage(events: [ExecutionEvent], language: String) -> String {
        let blocker = latestBlocker(in: events)
        if language == "zh" {
            return "刚才没有成功读取任何文件；原任务在执行前被阻止（\(blocker)）。我会把这条消息作为澄清，并在同一个任务中尝试修复或重试。"
        }
        return "No file was successfully read. The original task was blocked before execution (\(blocker)). I will use this message as clarification and attempt recovery on the same task."
    }

    private func activeMissionStatusMessage(
        input: String,
        events: [ExecutionEvent],
        currentState: TaskState
    ) -> String {
        let usesChinese = input.unicodeScalars.contains { $0.value > 127 }
        let blocker = latestBlocker(in: events)
        let noReadEvidence = !hasSuccessfulReadEvidence(events)
        if currentState == .blocked {
            if let partialMessage = events.reversed().first(where: {
                $0.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
            })?.payload["user_visible_message"], !partialMessage.isEmpty {
                return partialMessage
            }
            if blocker == PlanReadinessBlocker.workingDirectoryOutsideWorkspace.rawValue
                || blocker == PlanReadinessBlocker.workspaceScopeMismatch.rawValue {
                return usesChinese
                    ? "任务已阻止：计划中的工作目录不属于当前选择的 Legacy 项目。FDE 没有读取任何文件。你可以使用当前 Legacy 根目录重试。"
                    : "Task blocked: the planned working directory is outside the selected Legacy project. FDE read no files. Retry using the current Legacy root."
            }
            if blocker == PlanReadinessBlocker.plannerTimeout.rawValue
                || (blocker.contains("planner_provider_request_failed") && events.contains(where: { $0.payload["detail"]?.lowercased().contains("timed out") == true })) {
                return usesChinese
                    ? "任务已阻止：规划请求超时，尚未生成可执行计划。可以重试当前任务。"
                    : "Task blocked: the planner request timed out before an executable plan was generated. You can retry the current task."
            }
            let evidence = noReadEvidence
                ? (usesChinese ? "FDE 没有读取任何文件。" : "FDE read no files.")
                : (usesChinese ? "已保留成功读取的证据。" : "Successful read evidence is preserved.")
            return usesChinese
                ? "任务已阻止（\(blocker)）。\(evidence)可以修复或重试当前任务。"
                : "Task blocked (\(blocker)). \(evidence) The current task can be repaired or retried."
        }
        return usesChinese
            ? "当前任务状态：\(currentState.rawValue)。"
            : "Current task status: \(currentState.rawValue)."
    }

    private func apply(taskState: TaskState, to session: inout AgentSession) {
        switch taskState {
        case .blocked:
            session.currentState = .blocked
            session.setInteractionState(.blocked)
        case .failed:
            session.currentState = .failed
            session.setInteractionState(.failed)
        case .planned:
            session.currentState = .planning
            session.setInteractionState(.planning)
        case .running:
            session.currentState = .executing
            session.setInteractionState(.running)
        case .pendingApproval:
            session.currentState = .waitingApproval
            session.setInteractionState(.waitingForApproval)
        case .waiting:
            session.currentState = .waitingApproval
            session.setInteractionState(.waitingForUser)
        case .completed, .replayed:
            session.currentState = .completed
            session.setInteractionState(.completed)
        case .created:
            session.currentState = .understanding
            session.setInteractionState(.understanding)
        }
    }

    private func resumedMissionInput(reply: String, session: AgentSession) -> String {
        let safeReply = AgentPresentationSanitizer.safeContent(reply, fallback: "Continue mission")
        if safeReply.caseInsensitiveCompare(session.userGoal) == .orderedSame {
            return safeReply
        }
        if !missionClassifier.isExplicitMissionRequest(
            session.userGoal,
            intent: missionClassifier.intent(for: session.userGoal)
        ) {
            return safeReply
        }
        if missionClassifier.isCasualChat(session.userGoal) {
            return safeReply
        }
        return "\(session.userGoal)\n\nUser clarification: \(safeReply)"
    }

    private func approvedImplementationInput(for session: AgentSession) -> String {
        let goal = AgentPresentationSanitizer.safeContent(session.userGoal, fallback: "AI agent integration")
        let assessmentTitles = session.artifacts
            .filter { ["Integration assessment", "Implementation plan", "Test plan"].contains($0.title) }
            .map(\.title)
            .joined(separator: ", ")
        let evidence = assessmentTitles.isEmpty ? "previous assessment artifacts" : assessmentTitles
        return """
        Approved implementation for AI agent integration.
        Original goal: \(goal)
        Customer approved writing tests, generating adapter/client/service patch, preparing verification.
        Use assessment evidence: \(evidence).
        Generate patch artifact and verification report for the selected legacy project and AI agent project.
        """
    }
}

struct AgentMissionClassifier: Sendable {
    private let intentParser: any MissionIntentParsing

    init(intentParser: any MissionIntentParsing = MissionIntentParser()) {
        self.intentParser = intentParser
    }

    func intent(for input: String) -> MissionIntent {
        intentParser.parse(input)
    }

    func conversationMode(
        for input: String,
        intent: MissionIntent? = nil,
        hasActiveRuntimeTask: Bool
    ) -> FDEConversationMode {
        let resolvedIntent = intent ?? self.intent(for: input)
        if hasActiveRuntimeTask && isMissionControlInstruction(input, intent: resolvedIntent) {
            return .runtimeControl
        }
        if resolvedIntent.intentType == .safeSandboxAcceptance {
            return .executableEngineeringTask
        }
        if resolvedIntent.intentType == .candidatePatchGeneration
            || resolvedIntent.intentType == .generatedTestPlan
            || resolvedIntent.intentType == .candidatePatchRevert
            || resolvedIntent.intentType == .candidatePatchSandboxDestroy {
            return .executableEngineeringTask
        }
        if isLegacyTransformationAdvisory(input) {
            return .legacyTransformationAdvisory
        }
        if isIdentityQuestion(input) || isCapabilityQuestion(input) || isAgentAbilityQuestion(input) {
            return .fdeCapabilityExplanation
        }
        if requiresReadOnlyRuntime(input, intent: resolvedIntent) {
            return .workspaceReadOnlyInvestigation
        }
        if isPassiveWorkspaceSummaryRequest(input)
            || isWorkspaceQuestion(input, intent: resolvedIntent) {
            return .workspaceReadOnlyInvestigation
        }
        if isExplicitMissionRequest(input, intent: resolvedIntent) {
            return .executableEngineeringTask
        }
        if isEngineeringExplanation(input, intent: resolvedIntent) {
            return .engineeringExplanation
        }
        return .casualConversation
    }

    func isLegacyTransformationAdvisory(_ input: String) -> Bool {
        let text = normalized(input)
        guard isQuestionForm(input), !isExplicitReadOnlyActivation(input) else {
            return false
        }
        let refersToTransformation = containsAny(
            text,
            [
                "legacy", "traditional software", "existing software", "ai agent", "agent integration",
                "传统软件", "旧系统", "现有系统", "agent 化", "接入 agent", "接 agent", "集成 agent"
            ]
        )
        let advisoryQuestion = containsAny(
            text,
            [
                "what", "how", "which", "whether", "would", "should", "readiness", "suitable", "assess", "evaluate", "design", "first",
                "什么", "怎么", "如何", "哪些", "会先", "首先会", "需要考虑", "能不能", "适合", "判断", "评估", "设计", "权限", "审批"
            ]
        )
        let asksAboutFDEAbility = containsAny(text, ["你能", "你可以", "can you", "could you"])
        let explicitlySelectedWorkspace = containsAny(
            text,
            ["this project", "current project", "selected workspace", "这个项目", "当前项目", "当前工作区", "这个工作区"]
        )
        return refersToTransformation
            && advisoryQuestion
            && !asksAboutFDEAbility
            && !explicitlySelectedWorkspace
    }

    func executionIntentClassification(
        for input: String,
        intent: MissionIntent? = nil
    ) -> FDEExecutionIntentClassification {
        let resolvedIntent = intent ?? self.intent(for: input)

        if isCasualChat(input)
            || isFeedbackOrComplaint(input)
            || isIdentityQuestion(input)
            || isCapabilityQuestion(input)
            || isAgentAbilityQuestion(input) {
            return .ordinaryConversation
        }
        switch resolvedIntent.intentType {
        case .candidatePatchGeneration,
             .candidatePatchRevert,
             .candidatePatchSandboxDestroy:
            return needsMissionClarification(input, intent: resolvedIntent)
                ? .clarificationRequired
                : .executableCandidateChange
        case .generatedTestPlan,
             .safeSandboxAcceptance,
             .modifyCode,
             .runTests,
             .createFeature,
             .refactorCode,
             .manageRuntime:
            return needsMissionClarification(input, intent: resolvedIntent)
                ? .clarificationRequired
                : .otherExecutable
        default:
            break
        }
        if isExplicitReadOnlyActivation(input)
            || (isImperativeWorkspaceRequest(input, intent: resolvedIntent)
                && (requiresReadOnlyRuntime(input, intent: resolvedIntent)
                    || containsSourceFileReference(input))) {
            return .executableReadOnly
        }
        if isPriorWorkQuestion(input) {
            return .ordinaryConversation
        }
        if isLegacyTransformationAdvisory(input) || isHypotheticalInspectionQuestion(input) {
            return .advisoryConversation
        }
        if ConversationRuntimePreflight.evaluate(input) != nil {
            return .clarificationRequired
        }
        switch resolvedIntent.intentType {
        case .candidatePatchGeneration,
             .candidatePatchRevert,
             .candidatePatchSandboxDestroy,
             .generatedTestPlan,
             .safeSandboxAcceptance,
             .modifyCode,
             .runTests,
             .createFeature,
             .refactorCode,
             .manageRuntime:
            // Handled above so explicit mutation/runtime intents cannot be
            // downgraded merely because their scope references prior evidence.
            return .otherExecutable
        case .aiAgentCompatibilityAssessment,
             .inspectWorkspace,
             .architectureAnalysis,
             .explainCode,
             .generateReport:
            if isExplicitReadOnlyActivation(input)
                || isImperativeWorkspaceRequest(input, intent: resolvedIntent) {
                return .executableReadOnly
            }
            return isQuestionForm(input) ? .advisoryConversation : .executableReadOnly
        case .debugIssue:
            return needsMissionClarification(input, intent: resolvedIntent)
                ? .clarificationRequired
                : .otherExecutable
        case .answerQuestion, .unknown:
            return .ordinaryConversation
        }
    }

    func isEngineeringExplanation(_ input: String, intent: MissionIntent? = nil) -> Bool {
        let text = normalized(input)
        let resolvedIntent = intent ?? self.intent(for: input)
        guard resolvedIntent.intentType == .answerQuestion
            || resolvedIntent.intentType == .explainCode
            || resolvedIntent.intentType == .unknown else {
            return false
        }
        return containsAny(
            text,
            [
                "state machine", "routing", "swift", "swiftui", "swiftpm", "concurrency", "build", "dependency",
                "runtime", "mcp", "api", "architecture", "database", "permission", "testing",
                "状态机", "路由", "并发", "构建", "依赖", "运行时", "架构", "数据库", "权限", "测试"
            ]
        )
    }

    func isIdentityQuestion(_ input: String) -> Bool {
        let text = normalized(input)
        return containsAny(
            text,
            ["你是谁", "你的工作", "你是做什么", "who are you", "what is your job", "what are you"]
        )
    }

    func needsClarification(_ intent: MissionIntent) -> Bool {
        intent.shouldAskClarification
    }

    func needsClarification(_ input: String) -> Bool {
        needsClarification(intent(for: input))
    }

    func needsMissionClarification(_ input: String, intent: MissionIntent) -> Bool {
        needsClarification(intent) || isBareExecutionCommand(input, intent: intent)
    }

    func isExplicitMissionRequest(_ input: String, intent: MissionIntent? = nil) -> Bool {
        let resolvedIntent = intent ?? self.intent(for: input)
        if isPriorWorkQuestion(input)
            || isAgentAbilityQuestion(input)
            || isFeedbackOrComplaint(input)
            || isWorkspaceQuestion(input, intent: resolvedIntent) {
            return false
        }
        switch resolvedIntent.intentType {
        case .candidatePatchGeneration,
             .generatedTestPlan,
             .candidatePatchRevert,
             .candidatePatchSandboxDestroy,
             .safeSandboxAcceptance,
             .aiAgentCompatibilityAssessment,
             .inspectWorkspace,
             .architectureAnalysis,
             .debugIssue,
             .modifyCode,
             .runTests,
             .createFeature,
             .refactorCode,
             .generateReport:
            return true
        case .manageRuntime:
            return containsAny(normalized(input), ["execute", "run", "执行", "运行"])
        case .answerQuestion, .explainCode, .unknown:
            return false
        }
    }

    func isPriorWorkQuestion(_ input: String) -> Bool {
        let text = normalized(input)
        let chineseHistoryReference = containsAny(text, ["刚才", "刚刚", "之前", "上次", "前面", "先前"])
            && containsAny(text, ["修改", "改了", "变更", "做了", "执行", "运行", "代码", "文件", "测试"])
        let chinesePastChangeQuestion = containsAny(text, ["你修改了", "你改了", "修改了哪些", "改了哪些"])
            && containsAny(text, ["代码", "文件"])
        let englishHistoryQuestion = containsAny(
            text,
            [
                "what did you change",
                "what did you modify",
                "what code did you change",
                "what code did you modify",
                "what files changed",
                "what changes did you make",
                "did you modify any code",
                "did you change any code",
                "which files did you change",
                "which files did you modify",
                "how did you change",
                "how did you modify",
                "how was the code changed",
                "what changed",
                "previous mission",
                "previous task",
                "last mission",
                "last task",
                "earlier work"
            ]
        )
        return chineseHistoryReference || chinesePastChangeQuestion || englishHistoryQuestion
    }

    func isActiveMissionReference(_ input: String) -> Bool {
        let text = normalized(input)
        return containsAny(
            text,
            [
                "active task", "current task", "this task", "active mission", "current mission",
                "this inspection", "that inspection", "inspection result", "task status", "mission status",
                "why is it blocked", "why did it block", "continue the analysis", "resume the analysis",
                "当前任务", "这个任务", "这次任务", "当前使命", "这次检查", "刚才的检查",
                "检查结果", "任务状态", "为什么阻塞", "为何阻塞", "继续分析", "恢复分析"
            ]
        )
    }

    func isLikelyActiveMissionClarification(
        _ input: String,
        session: AgentSession,
        wasWaitingForRuntime: Bool,
        selectedMode: FDEConversationMode
    ) -> Bool {
        guard wasWaitingForRuntime,
              session.conversation.messages.last(where: { $0.sender == .agent })?.type == .question else {
            return false
        }
        switch selectedMode {
        case .fdeCapabilityExplanation,
             .engineeringExplanation,
             .legacyTransformationAdvisory,
             .workspaceReadOnlyInvestigation,
             .executableEngineeringTask:
            return false
        case .casualConversation, .runtimeControl:
            return !isCasualChat(input) && !isFeedbackOrComplaint(input)
        }
    }

    func isMissionControlInstruction(_ input: String, intent: MissionIntent? = nil) -> Bool {
        if isPriorWorkQuestion(input) || isAgentAbilityQuestion(input) {
            return false
        }
        let text = normalized(input)
        let exactControls: Set<String> = [
            "pause",
            "continue",
            "resume",
            "stop",
            "cancel",
            "pause task",
            "continue task",
            "resume task",
            "stop task",
            "cancel task",
            "change approach",
            "use another strategy",
            "暂停",
            "继续",
            "恢复",
            "停止",
            "取消",
            "暂停任务",
            "继续任务",
            "恢复任务",
            "停止任务",
            "取消任务",
            "改变方案",
            "换个方法"
        ]
        if exactControls.contains(text) {
            return true
        }
        let resolvedIntent = intent ?? self.intent(for: input)
        return resolvedIntent.intentType == .manageRuntime
            && !text.contains("?")
            && !text.contains("？")
            && !containsAny(text, ["why", "how", "为什么", "怎么", "如何"])
    }

    func isCapabilityQuestion(_ input: String) -> Bool {
        let normalized = normalized(input)
        guard !normalized.isEmpty else { return false }
        return [
            "你能做什么",
            "你可以做什么",
            "你会做什么",
            "你能干什么",
            "你可以干什么",
            "你有什么能力",
            "有什么能力",
            "你会什么",
            "你是否会",
            "你懂",
            "你会 swift",
            "你能帮我做什么",
            "能做什么",
            "what can you do",
            "what do you do",
            "what can u do",
            "do you know swift",
            "capabilities",
            "your capabilities"
        ].contains { normalized.contains($0) }
    }

    func isAgentAbilityQuestion(_ input: String) -> Bool {
        let normalized = normalized(input)
        guard !normalized.isEmpty else { return false }
        let asksQuestion = normalized.contains("吗")
            || normalized.contains("么")
            || normalized.contains("?")
            || normalized.contains("？")
            || normalized.contains("can you")
            || normalized.contains("could you")
            || normalized.contains("are you able")
        guard asksQuestion else { return isCapabilityQuestion(input) }
        let refersToAgent = normalized.contains("你")
            || normalized.contains("agent")
            || normalized.contains("you")
        let asksAboutAction = containsAny(
            normalized,
            [
                "改写代码",
                "改代码",
                "修改代码",
                "写代码",
                "跑测试",
                "修复测试",
                "解决测试",
                "解决软件测试",
                "软件测试",
                "测试的问题",
                "解决问题",
                "检查项目",
                "执行",
                "solve",
                "solve testing",
                "fix tests",
                "fix failing tests",
                "software testing",
                "testing problem",
                "test failure",
                "inspect",
                "modify",
                "edit",
                "write code",
                "run tests",
                "execute"
            ]
        )
        return isCapabilityQuestion(input) || (refersToAgent && asksAboutAction)
    }

    func isWorkspaceQuestion(_ input: String, intent: MissionIntent? = nil) -> Bool {
        let resolvedIntent = intent ?? self.intent(for: input)
        let text = normalized(input)
        guard !text.isEmpty else { return false }
        guard resolvedIntent.intentType != .safeSandboxAcceptance else { return false }
        if isAgentAbilityQuestion(input) || isCapabilityQuestion(input) || isCasualChat(input) {
            return false
        }

        let explicitlyReadOnly = resolvedIntent.constraints.contains(.readOnly)
            && containsAny(
                text,
                [
                    "read-only",
                    "readonly",
                    "do not modify",
                    "don't modify",
                    "do not change",
                    "without modifying",
                    "no changes",
                    "只读",
                    "不要修改",
                    "不要改",
                    "不修改"
                ]
            )
        let asksToMutateOrExecute = containsAny(
            text,
            [
                "run test",
                "run tests",
                "rerun",
                "execute",
                "fix",
                "modify",
                "edit",
                "change code",
                "add feature",
                "implement ",
                "create",
                "delete",
                "refactor",
                "build",
                "run command",
                "deploy",
                "运行测试",
                "跑测试",
                "执行",
                "修复",
                "修改",
                "改代码",
                "新增",
                "实现功能",
                "实现代码",
                "实施接入",
                "创建",
                "删除",
                "重构",
                "构建",
                "运行命令",
                "部署"
            ]
        )
        if asksToMutateOrExecute && !explicitlyReadOnly {
            return false
        }

        let asksForWorkspaceEvidence = containsAny(
            text,
            [
                "current project",
                "this project",
                "workspace",
                "repository",
                "repo",
                "file",
                "test files",
                "what is this project",
                "explain this file",
                "explain this code",
                "why did tests fail",
                "state machine implementation",
                "input field code",
                "legacy interface",
                "agent interface",
                "legacy project",
                "agent project",
                "root directory",
                "package.json",
                "manifest",
                "framework",
                "database",
                "dependency",
                "当前项目",
                "这个项目",
                "工作区",
                "文件",
                "legacy 项目",
                "agent 项目",
                "根目录",
                "框架",
                "数据库",
                "依赖",
                "测试文件",
                "有哪些测试",
                "解释这个文件",
                "这段代码",
                "为什么测试失败",
                "状态机实现",
                "输入框代码",
                "legacy 和 agent",
                "legacy 与 agent"
            ]
        ) || containsSourceFileReference(text)
        let asksForAnswer = text.contains("?")
            || text.contains("？")
            || text.contains("what")
            || text.contains("why")
            || text.contains("explain")
            || text.contains("tell me")
            || text.contains("list")
            || text.contains("列出")
            || text.contains("验证")
            || text.contains("告诉我")
            || text.contains("有哪些")
            || text.contains("解释")
            || text.contains("为什么")

        let asksForReadOnlyAction = containsAny(
            text,
            [
                "read ", "inspect", "review", "analyze", "search", "find", "list", "verify", "compare", "explain this file",
                "读取", "查看", "检查", "分析", "搜索", "列出", "验证", "只读", "找到", "看看", "审查", "对比"
            ]
        )

        switch resolvedIntent.intentType {
        case .aiAgentCompatibilityAssessment, .inspectWorkspace, .explainCode, .answerQuestion, .architectureAnalysis:
            return asksForWorkspaceEvidence && (asksForAnswer || asksForReadOnlyAction)
        default:
            return asksForWorkspaceEvidence && (asksForAnswer || asksForReadOnlyAction)
        }
    }

    func requiresReadOnlyRuntime(_ input: String, intent: MissionIntent? = nil) -> Bool {
        let resolvedIntent = intent ?? self.intent(for: input)
        guard resolvedIntent.intentType != .safeSandboxAcceptance else { return false }
        guard !isFeedbackOrComplaint(input),
              !isPassiveWorkspaceSummaryRequest(input) else {
            return false
        }
        return isWorkspaceQuestion(input, intent: resolvedIntent)
    }

    func isPassiveWorkspaceSummaryRequest(_ input: String) -> Bool {
        let text = normalized(input)
        guard !text.isEmpty else { return false }

        let asksForOverview = containsAny(
            text,
            [
                "workspace overview", "workspace summary", "project overview",
                "workspace 概览", "工作区概览", "工作区概况", "项目概览", "项目概况"
            ]
        )
        let asksForFileCounts = containsAny(
            text,
            ["how many files", "file count", "file counts", "多少文件", "几个文件", "文件数量"]
        )
        let asksForSelectedProjects = containsAny(
            text,
            [
                "which projects are selected", "what projects are selected", "selected projects",
                "选择了哪些项目", "选了哪些项目", "当前选择的项目"
            ]
        )
        return asksForOverview || asksForFileCounts || asksForSelectedProjects
    }

    private func isHypotheticalInspectionQuestion(_ input: String) -> Bool {
        let text = normalized(input)
        guard isQuestionForm(input) else { return false }
        let hypothetical = containsAny(
            text,
            [
                "what would you", "how would you", "what do you inspect", "what would be inspected",
                "would you inspect", "what should be considered", "what should i consider",
                "你会检查什么", "你会先检查", "你首先会检查", "会先检查什么", "首先检查什么",
                "需要考虑什么", "会怎么检查", "会如何检查"
            ]
        )
        let methodologyDomain = containsAny(
            text,
            [
                "legacy", "traditional software", "existing system", "ai agent", "agent integration",
                "传统软件", "旧系统", "现有系统", "智能体", "接入 agent", "集成 agent"
            ]
        )
        return hypothetical && methodologyDomain && !isExplicitReadOnlyActivation(input)
    }

    private func isQuestionForm(_ input: String) -> Bool {
        let text = normalized(input)
        return input.contains("?")
            || input.contains("？")
            || containsAny(
                text,
                [
                    "what", "why", "how", "which", "whether", "would", "should", "can you",
                    "什么", "为什么", "如何", "怎么", "哪些", "是否", "会不会", "你会", "吗"
                ]
            )
    }

    private func isExplicitReadOnlyActivation(_ input: String) -> Bool {
        let text = normalized(input)
        let directActivation = containsAny(
            text,
            [
                "start read-only assessment", "start the read-only assessment", "begin read-only assessment",
                "start a read-only inspection", "start the read-only inspection", "now start read-only",
                "inspect the selected", "inspect both selected", "assess the selected", "analyze the selected",
                "现在开始只读", "开始只读检查", "开始只读评估", "开始只读分析", "启动只读评估",
                "检查我选中的", "检查当前选择的", "只读检查我选中的", "只读分析我选中的"
            ]
        )
        let boundedContinuation = containsAny(
            text,
            [
                "continue inspecting", "continue the inspection", "continue checking", "continue reading",
                "继续检查", "继续只读检查", "继续读取"
            ]
        ) && containsAny(
            text,
            ["read-only", "do not modify", "without modifying", "只读", "不要修改", "不修改"]
        )
        return directActivation || boundedContinuation
    }

    private func isImperativeWorkspaceRequest(_ input: String, intent: MissionIntent) -> Bool {
        let text = normalized(input)
        let imperativePrefix = [
            "inspect ", "review ", "analyze ", "analyse ", "assess ", "audit ", "read ", "check ",
            "检查", "查看", "分析", "评估", "审查", "读取", "对比"
        ].contains { text.hasPrefix($0) }
        if isQuestionForm(input)
            && !isExplicitReadOnlyActivation(input)
            && !imperativePrefix {
            return false
        }
        let selectedTarget = containsAny(
            text,
            [
                "selected", "current project", "current workspace", "this project", "both projects", "both workspaces",
                "选中的", "当前项目", "当前工作区", "两个项目", "legacy 和 agent", "legacy 与 agent"
            ]
        )
        return imperativePrefix
            || (selectedTarget && [
                MissionIntentType.aiAgentCompatibilityAssessment,
                .inspectWorkspace,
                .architectureAnalysis,
                .explainCode,
                .generateReport
            ].contains(intent.intentType))
    }

    private func containsSourceFileReference(_ input: String) -> Bool {
        [
            ".swift",
            ".ts",
            ".tsx",
            ".js",
            ".jsx",
            ".py",
            ".md",
            ".json",
            ".yaml",
            ".yml"
        ].contains { input.contains($0) }
    }

    func isFeedbackOrComplaint(_ input: String) -> Bool {
        let normalized = normalized(input)
        return containsAny(
            normalized,
            [
                "机器人",
                "机械",
                "听不懂",
                "不理解",
                "无法理解",
                "像个",
                "很蠢",
                "太笨",
                "robotic",
                "like a robot",
                "doesn't understand",
                "does not understand",
                "not understanding",
                "too mechanical"
            ]
        )
    }

    func isVagueStandalone(_ input: String) -> Bool {
        let normalized = normalized(input)
        return normalized.isEmpty || [
            "help",
            "start",
            "开始",
            "帮我",
            "看一下",
            "看看",
            "随便看看"
        ].contains(normalized)
    }

    func isCasualChat(_ input: String) -> Bool {
        let normalized = input
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?.,， "))
        guard !normalized.isEmpty else { return false }
        return [
            "hi",
            "hello",
            "hey",
            "你好",
            "您好",
            "嗨",
            "哈喽",
            "早上好",
            "晚上好",
            "还在吗",
            "在吗",
            "哈哈哈",
            "怎么了",
            "你在干嘛",
            "谢谢",
            "thanks",
            "thank you"
        ].contains(normalized)
    }

    private func isBareExecutionCommand(_ input: String, intent: MissionIntent) -> Bool {
        let normalized = normalized(input)
        switch intent.intentType {
        case .modifyCode:
            return [
                "modify code",
                "change code",
                "update code",
                "edit code",
                "fix code",
                "修改代码",
                "改代码",
                "更新代码",
                "修复代码"
            ].contains(normalized)
        case .createFeature:
            return [
                "implement",
                "create feature",
                "add feature",
                "新增功能",
                "实现功能"
            ].contains(normalized)
        case .debugIssue:
            return [
                "debug",
                "debug issue",
                "排查",
                "排查问题"
            ].contains(normalized)
        default:
            return false
        }
    }

    private func normalized(_ input: String) -> String {
        input
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。！？!?.,， "))
    }

    private func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains { value.contains($0) }
    }
}
