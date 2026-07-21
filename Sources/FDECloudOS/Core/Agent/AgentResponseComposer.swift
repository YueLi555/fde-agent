import Foundation
import OSLog

struct AgentResponseComposer: Sendable {
    private let narrationProvider: (any AgentNarrationProviding)?
    private static let logger = Logger(subsystem: "FDECloudOS", category: "AgentResponseComposer")
    private static let safePayloadKeys: Set<String> = [
        "arguments",
        "attempt",
        "command",
        "confidence",
        "completion_evidence",
        "commands_run",
        "detail",
        "diff_summary",
        "actual_result",
        "codebase_count",
        "error",
        "exit_code",
        "failed_command",
        "files_inspected",
        "files_modified",
        "governor_strategy",
        "kind",
        "max_attempts",
        "message",
        "network",
        "node_id",
        "decision",
        "performance_score",
        "recovery_command",
        "risk_level",
        "risk_score",
        "routing_decision",
        "remaining_risks",
        "root_cause",
        "selected_route",
        "success",
        "target_path",
        "target_node_id",
        "tool_call_count",
        "tool_name",
        "verification_results",
        "worker_id",
        "user_visible_message",
        "blocker_reason",
        "successful_read_evidence"
    ]

    init(narrationProvider: (any AgentNarrationProviding)? = nil) {
        self.narrationProvider = narrationProvider
        if let narrationProvider {
            Self.logger.debug(
                "Agent narration provider configured provider=\(narrationProvider.kind.rawValue, privacy: .public) available=\(narrationProvider.isAvailable, privacy: .public) reason=\(narrationProvider.disabledReason ?? "enabled", privacy: .public)"
            )
            LLMNarrationDebugLog.write(
                "composer_config provider=\(narrationProvider.kind.rawValue) available=\(narrationProvider.isAvailable) reason=\(narrationProvider.disabledReason ?? "enabled")"
            )
        } else {
            Self.logger.debug("Agent narration provider configured provider=Local deterministic fallback")
            LLMNarrationDebugLog.write("composer_config provider=Local reason=no_live_narration_provider")
        }
    }

    static func live(configuration: ModelProviderConfiguration = .environment()) -> AgentResponseComposer {
        AgentResponseComposer(
            narrationProvider: ModelProviderFactory.narrationProvider(configuration: configuration)
        )
    }

    var usesLiveNarration: Bool {
        guard let narrationProvider else { return false }
        return narrationProvider.kind == .openAI && narrationProvider.isAvailable
    }

    func message(for event: ExecutionEvent) -> AgentMessage {
        Self.message(for: event)
    }

    func liveMessage(for event: ExecutionEvent, history: [AgentMessage] = []) async -> AgentMessage {
        var fallbackMessage = Self.message(for: event)
        LLMNarrationDebugLog.write(
            "composer_liveMessage event_id=\(event.id.uuidString) event_type=\(event.type.rawValue) fallback_type=\(fallbackMessage.type.rawValue) provider=\(narrationProvider?.kind.rawValue ?? "Local")"
        )
        guard fallbackMessage.sender == .agent else {
            LLMNarrationDebugLog.write("composer_liveMessage_skipped event_id=\(event.id.uuidString) reason=user_sender")
            return fallbackMessage
        }
        if Self.isCanonicalGroundedAnswerEvent(event) {
            LLMNarrationDebugLog.write("composer_liveMessage_skipped event_id=\(event.id.uuidString) reason=canonical_grounded_answer")
            return fallbackMessage
        }

        let narration = await Self.narration(
            for: event,
            fallbackMessage: fallbackMessage,
            history: history,
            provider: narrationProvider
        )
        fallbackMessage.type = narration.messageType
        fallbackMessage.content = narration.content
        return fallbackMessage
    }

    static func message(for event: ExecutionEvent) -> AgentMessage {
        let stableMessageID = event.type == .userMessageReceived
            ? event.payload["client_message_id"].flatMap(UUID.init(uuidString:)) ?? event.id
            : event.id
        return AgentMessage(
            id: stableMessageID,
            timestamp: event.timestamp,
            sender: sender(for: event.type),
            type: isCanonicalGroundedAnswerEvent(event) ? .result : messageType(for: event.type),
            content: content(for: event),
            turnID: event.payload["turn_id"].flatMap(UUID.init(uuidString:))
                ?? (event.type == .userMessageReceived ? stableMessageID : nil),
            inReplyToMessageID: event.payload["user_message_id"].flatMap(UUID.init(uuidString:)),
            relatedEventID: event.id,
            relatedArtifactID: relatedArtifactID(for: event)
        )
    }

    static func messages(for events: [ExecutionEvent]) -> [AgentMessage] {
        events.sortedByComposerOrder().reduce(into: [AgentMessage]()) { result, event in
            guard shouldPresentInConversation(event) else { return }
            let message = message(for: event)
            guard shouldAppend(message, to: result) else { return }
            result.append(message)
        }
    }

    /// Produces deterministic narration for replay/export without changing the
    /// intentionally compact live conversation projection. Low-level dispatch
    /// transport events are excluded because they duplicate the user-facing
    /// tool or connector activity that initiated them.
    static func shouldComposeNarration(_ event: ExecutionEvent) -> Bool {
        if event.payload["chat_only"] == "true" {
            return event.type == .userMessageReceived
        }
        switch event.type {
        case .executionDispatched,
             .executionReceived,
             .executionResponseReceived,
             .workerRegistered,
             .workerTaskReceived,
             .workerTaskCompleted:
            return false
        default:
            return true
        }
    }

    static func replayConversation(
        sessionID: UUID,
        workspaceID: UUID,
        userRequest: String,
        events: [ExecutionEvent],
        createdAt: Date = Date()
    ) -> AgentConversation {
        var conversation = AgentConversation.started(
            sessionID: sessionID,
            workspaceID: workspaceID,
            userRequest: userRequest,
            createdAt: createdAt
        )
        let orderedEventsByID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        let usesLegacyInteractionReplayCopy = events.contains {
            $0.type == .userDecisionSelected
                || $0.type == .userApprovalGranted
                || $0.type == .userApprovalRejected
        }
        let replayMessages = messages(for: events).map { message in
            guard usesLegacyInteractionReplayCopy,
                  let eventID = message.relatedEventID,
                  let event = orderedEventsByID[eventID] else {
                return message
            }
            var compatible = message
            switch event.type {
            case .taskCreated:
                compatible.content = "I'll take a quick look at the workspace first, then turn that into a plan."
            case .taskCompleted where event.payload["detail"]?.isEmpty != false
                && event.payload["grounded_answer"] != "true":
                compatible.content = "Finished successfully."
            default:
                break
            }
            return compatible
        }
        conversation.append(contentsOf: replayMessages)
        return conversation
    }

    static func containsRestrictedContent(_ value: String) -> Bool {
        AgentPresentationSanitizer.containsRestrictedContent(value)
    }

    private static func narration(
        for event: ExecutionEvent,
        fallbackMessage: AgentMessage,
        history: [AgentMessage],
        provider: (any AgentNarrationProviding)?
    ) async -> AgentNarration {
        let fallback = AgentNarration(
            content: fallbackMessage.content,
            messageType: fallbackMessage.type,
            confidence: 1,
            provider: .local,
            usedFallback: true
        )

        guard let provider else {
            logger.debug("Agent narration provider selected provider=Local reason=no live provider")
            LLMNarrationDebugLog.write("composer_fallback event_id=\(event.id.uuidString) reason=no_live_provider")
            return fallback
        }

        guard provider.kind == .openAI else {
            logger.debug(
                "Agent narration provider selected provider=Local reason=unsupported provider \(provider.kind.rawValue, privacy: .public)"
            )
            LLMNarrationDebugLog.write("composer_fallback event_id=\(event.id.uuidString) reason=unsupported_provider provider=\(provider.kind.rawValue)")
            return fallback
        }

        guard provider.isAvailable else {
            logger.debug(
                "Agent narration provider selected provider=Local reason=\(provider.disabledReason ?? "provider unavailable", privacy: .public)"
            )
            LLMNarrationDebugLog.write("composer_fallback event_id=\(event.id.uuidString) reason=\(provider.disabledReason ?? "provider_unavailable")")
            return fallback
        }

        let request = narrationRequest(for: event, fallbackMessage: fallbackMessage, history: history)
        do {
            LLMNarrationDebugLog.write("composer_generateNarration_call event_id=\(event.id.uuidString) event_type=\(event.type.rawValue) provider=OpenAI")
            let generated = try await provider.generateNarration(for: request)
            let sanitized = generated.sanitized(
                fallbackContent: fallbackMessage.content,
                fallbackMessageType: fallbackMessage.type,
                provider: provider.kind,
                usedFallback: false
            )
            logger.debug("Agent narration provider selected provider=OpenAI result=generated")
            LLMNarrationDebugLog.write(
                "composer_generateNarration_success event_id=\(event.id.uuidString) message_type=\(sanitized.messageType.rawValue) used_fallback=\(sanitized.usedFallback)"
            )
            return sanitized
        } catch {
            logger.debug(
                "Agent narration provider selected provider=Local reason=OpenAI failed: \(error.localizedDescription, privacy: .public)"
            )
            LLMNarrationDebugLog.write("composer_fallback event_id=\(event.id.uuidString) reason=openai_failed detail=\(error.localizedDescription)")
            return fallback
        }
    }

    private static func narrationRequest(
        for event: ExecutionEvent,
        fallbackMessage: AgentMessage,
        history: [AgentMessage]
    ) -> AgentNarrationRequest {
        AgentNarrationRequest(
            eventType: event.type,
            fallbackMessageType: fallbackMessage.type,
            deterministicFallback: AgentPresentationSanitizer.safeContent(
                fallbackMessage.content,
                fallback: "Agent updated execution state"
            ),
            eventSummary: safeSummary(event, fallback: event.type.rawValue),
            safePayload: safePayload(for: event),
            recentMessages: safeRecentAgentMessages(history)
        )
    }

    private static func safePayload(for event: ExecutionEvent) -> [String: String] {
        safePayloadKeys.sorted().reduce(into: [:]) { values, key in
            if key == "detail",
               let detail = safeMarkdownPayloadValue(event, key: key) {
                values[key] = detail
                return
            }
            if let value = safePayloadValue(event, key: key) {
                values[key] = value
            }
        }
    }

    private static func safeRecentAgentMessages(_ messages: [AgentMessage]) -> [String] {
        messages.suffix(4).compactMap { message in
            guard message.sender == .agent else { return nil }
            let safe = AgentPresentationSanitizer.safeContent(message.content, fallback: "")
            guard !safe.isEmpty, !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
                return nil
            }
            return "\(message.type.rawValue): \(safe)"
        }
    }

    static func shouldPresentInConversation(_ event: ExecutionEvent) -> Bool {
        if event.payload["chat_only"] == "true" {
            return event.type == .userMessageReceived
        }
        switch event.type {
        case .stateUpdated:
            if event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT",
               event.payload["grounded_answer"] == "true" {
                return true
            }
            guard let state = event.payload["state"].flatMap(TaskState.init(rawValue:)) else {
                return false
            }
            return state == .pendingApproval || state == .failed || state == .blocked
        case .taskCompleted,
             .humanApprovalRequested,
             .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted,
             .userApprovalRejected:
            return true
        case .taskCreated,
             .contextCompiled,
             .planGenerated,
             .toolCalled,
             .connectorCalled,
             .connectorDryRun,
             .connectorExecuted,
             .stepExecuted,
             .toolFailed,
             .connectorFailed,
             .recoveryAttempted,
             .humanApproved,
             .humanRejected,
             .authorizationDenied,
             .feedbackGenerated,
             .policyUpdated,
             .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned,
             .nodeExecutionStarted,
             .nodeExecutionCompleted,
             .executionDispatched,
             .executionReceived,
             .executionResponseReceived,
             .workerRegistered,
             .workerTaskReceived,
             .workerTaskCompleted,
             .nodeExecutionFailed,
             .workerTaskFailed:
            return false
        }
    }

    static func shouldAppend(_ message: AgentMessage, to existingMessages: [AgentMessage]) -> Bool {
        guard !existingMessages.contains(where: { $0.id == message.id }) else { return false }
        guard let eventID = message.relatedEventID else { return true }
        return !existingMessages.contains {
            $0.sender == message.sender && $0.relatedEventID == eventID
        }
    }

    static func isCanonicalGroundedAnswerEvent(_ event: ExecutionEvent) -> Bool {
        let completedReadOnlyAnswer = event.type == .taskCompleted
            && (event.payload["grounded_answer"] == "true"
                || event.payload["completion_contract"] == RuntimeCompletionContractKind.readOnlyInspection.rawValue
                || event.payload["completion_contract"] == RuntimeCompletionContractKind.safeSandboxAcceptance.rawValue)
        let partialReadOnlyAnswer = event.type == .stateUpdated
            && event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
            && event.payload["grounded_answer"] == "true"
            && event.payload["final_answer"]?.isEmpty == false
        return completedReadOnlyAnswer || partialReadOnlyAnswer
    }

    private static func messageType(for eventType: EventType) -> AgentMessageType {
        switch eventType {
        case .taskCreated,
             .contextCompiled,
             .stateUpdated,
             .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .workerRegistered:
            return .progressUpdate
        case .toolCalled,
             .connectorCalled,
             .connectorDryRun,
             .nodeExecutionStarted,
             .executionDispatched,
             .executionReceived,
             .workerTaskReceived:
            return .actionUpdate
        case .toolFailed,
             .connectorFailed,
             .nodeExecutionFailed,
             .workerTaskFailed:
            return .warning
        case .planGenerated:
            return .planUpdate
        case .recoveryAttempted,
             .humanApproved,
             .humanRejected,
             .authorizationDenied,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned:
            return .decision
        case .policyUpdated:
            return .decision
        case .stepExecuted,
             .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            return .observation
        case .connectorExecuted:
            return .evidence
        case .feedbackGenerated:
            return .artifact
        case .humanApprovalRequested:
            return .approvalRequest
        case .taskCompleted:
            return .result
        case .userMessageReceived:
            return .text
        case .userDecisionSelected:
            return .decisionRequest
        case .userApprovalGranted:
            return .approvalRequest
        case .userApprovalRejected:
            return .approvalRequest
        }
    }

    private static func sender(for eventType: EventType) -> AgentMessageSender {
        switch eventType {
        case .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted,
             .userApprovalRejected:
            return .user
        default:
            return .agent
        }
    }

    private static func content(for event: ExecutionEvent) -> String {
        switch event.type {
        case .taskCreated:
            return "Runtime task created for the executable request."
        case .contextCompiled:
            return contextCompiledContent(for: event)
        case .planGenerated:
            return planGeneratedContent(for: event)
        case .toolCalled:
            return toolCallContent(for: event)
        case .connectorCalled:
            return connectorCallContent(for: event)
        case .connectorDryRun:
            return "I prepared the connector path as a dry run. This lets me validate the integration route without relying on live external changes."
        case .connectorExecuted:
            return connectorResultContent(for: event)
        case .stepExecuted:
            return stepResultContent(for: event)
        case .toolFailed:
            return failureContent(for: event, fallback: "I hit an issue while running a workspace check. I will retry within the allowed budget or move to recovery.")
        case .connectorFailed:
            return failureContent(for: event, fallback: "I hit an issue while checking the external system path. I will keep the failure as evidence before choosing the next step.")
        case .recoveryAttempted:
            return recoveryContent(for: event)
        case .humanApprovalRequested:
            return approvalRequestContent(for: event)
        case .humanApproved:
            return "Approved. I'll continue from the paused step and keep the action trace visible."
        case .humanRejected:
            return "Rejected. I will not continue that path; send a new instruction if you want me to use a different approach."
        case .authorizationDenied:
            return "Policy blocked this action. I will not bypass the approval or workspace security boundary."
        case .stateUpdated:
            return stateUpdateContent(for: event)
        case .taskCompleted:
            return completionContent(for: event)
        case .feedbackGenerated:
            return artifactContent(for: event)
        case .policyUpdated:
            return policyContent(for: event)
        case .sessionStarted:
            return "The agent session is active."
        case .sessionEnded:
            return "The agent session ended."
        case .workspaceSwitched:
            return "I switched to the selected workspace context."
        case .roleChanged:
            return "The workspace role changed, so I will apply the updated permissions."
        case .routingDecisionMade:
            return routeContent(for: event)
        case .nodeSelected:
            return nodeContent(for: event, fallback: "I selected the execution node for this run.")
        case .executionTargetAssigned:
            return nodeContent(for: event, fallback: "I assigned the execution target for this run.")
        case .nodeExecutionStarted:
            return nodeContent(for: event, fallback: "The runtime node started work.")
        case .nodeExecutionCompleted:
            return nodeContent(for: event, fallback: "The runtime node returned a result I can use as evidence.")
        case .nodeExecutionFailed:
            return nodeContent(for: event, fallback: "The runtime node reported an execution issue.")
        case .executionDispatched:
            return nodeContent(for: event, fallback: "I dispatched the work to the runtime.")
        case .executionReceived:
            return nodeContent(for: event, fallback: "The runtime received the work.")
        case .executionResponseReceived:
            return nodeContent(for: event, fallback: "The runtime returned a result I can use as evidence.")
        case .workerRegistered:
            return nodeContent(for: event, fallback: "A worker registered with the session.")
        case .workerTaskReceived:
            return nodeContent(for: event, fallback: "The worker received the task.")
        case .workerTaskCompleted:
            return nodeContent(for: event, fallback: "The worker returned a result I can use as evidence.")
        case .workerTaskFailed:
            return nodeContent(for: event, fallback: "The worker reported an execution issue.")
        case .userMessageReceived:
            return safePayloadValue(event, key: "message")
                ?? safeSummary(event, fallback: "User added an instruction")
        case .userDecisionSelected:
            return safePayloadValue(event, key: "decision")
                ?? safeSummary(event, fallback: "User selected a path forward")
        case .userApprovalGranted:
            return safeSummary(event, fallback: "User approved the requested action")
        case .userApprovalRejected:
            return safeSummary(event, fallback: "User rejected the requested action")
        }
    }

    private static func planGeneratedContent(for event: ExecutionEvent) -> String {
        let toolCount = safePayloadValue(event, key: "tool_call_count")
        if let toolCount {
            return "Plan generated with \(toolCount) recorded tool call(s)."
        }
        return safeSummary(event, fallback: "Plan generated from model output.")
    }

    private static func contextCompiledContent(for event: ExecutionEvent) -> String {
        let codebaseCount = safePayloadValue(event, key: "codebase_count")
        if codebaseCount == "0" {
            return "Workspace metadata compiled; no codebase files were available in the selected scope."
        }
        if let codebaseCount {
            return "Workspace context compiled from \(codebaseCount) selected codebase(s)."
        }
        return safeSummary(event, fallback: "Workspace context compiled from recorded inputs.")
    }

    private static func toolCallContent(for event: ExecutionEvent) -> String {
        if let semantic = semanticToolCallContent(for: event) {
            return semantic
        }
        let command = commandText(for: event)
        let attempt = attemptText(for: event)
        let risk = safePayloadValue(event, key: "risk_level").map { " Risk is \($0.lowercased())." } ?? ""
        if let command {
            return "Checking `\(command)`\(attempt).\(risk)"
        }
        return "Checking the workspace now.\(risk)"
    }

    private static func connectorCallContent(for event: ExecutionEvent) -> String {
        let command = commandText(for: event)
        let network = safePayloadValue(event, key: "network")
        let networkText = network == "disabled" ? " This run records the connector path without live network traffic." : ""
        if let command {
            return "Checking the external path with `\(command)`.\(networkText)"
        }
        return "Checking the external system path now.\(networkText)"
    }

    private static func connectorResultContent(for event: ExecutionEvent) -> String {
        if let command = commandText(for: event) {
            return "Connector check returned evidence from `\(command)`."
        }
        return "Connector check returned evidence."
    }

    private static func stepResultContent(for event: ExecutionEvent) -> String {
        if let semantic = semanticStepResultContent(for: event) {
            return semantic
        }
        let exit = safePayloadValue(event, key: "exit_code")
        let command = commandText(for: event)
        let statusText = exit.map { " Exit code \($0);" } ?? ""
        if let command {
            return "Finished `\(command)`.\(statusText) I recorded the result as evidence."
        }
        return "Step completed.\(statusText) I recorded the result as evidence."
    }

    private static func failureContent(for event: ExecutionEvent, fallback: String) -> String {
        if let command = commandText(for: event) {
            return "I hit an issue while running `\(command)`\(attemptText(for: event)). I will retry within the allowed budget or move to recovery."
        }
        return fallback
    }

    private static func recoveryContent(for event: ExecutionEvent) -> String {
        if event.payload["recovery_kind"] == "read_only_same_task",
           event.payload["prior_evidence_available"] == "false" {
            return "No file was successfully read before the blocker. I am preserving the same task and retrying it from the planner with the new clarification."
        }
        let failed = safePayloadValue(event, key: "failed_command")
        let recovery = safePayloadValue(event, key: "recovery_command")
        switch (failed, recovery) {
        case let (failed?, recovery?):
            return "I selected a recovery path: replace `\(failed)` with `\(recovery)` and continue from the failed step."
        case let (_, recovery?):
            return "I selected a recovery path and will continue with `\(recovery)`."
        case let (failed?, _):
            return "I selected a recovery path for `\(failed)` and will avoid repeating the same failure."
        case (nil, nil):
            return "I selected a recovery path and will continue from the last safe checkpoint."
        }
    }

    private static func approvalRequestContent(for event: ExecutionEvent) -> String {
        var parts = ["I need your approval before continuing."]
        if let command = commandText(for: event) {
            parts.append("Requested action: `\(command)`.")
        }
        if let risk = safePayloadValue(event, key: "risk_level") {
            parts.append("Risk: \(risk).")
        }
        return parts.joined(separator: " ")
    }

    private static func stateUpdateContent(for event: ExecutionEvent) -> String {
        if let userVisible = safeMarkdownPayloadValue(event, key: "user_visible_message") {
            return userVisible
        }
        guard let state = event.payload["state"].flatMap(TaskState.init(rawValue:)) else {
            return "The runtime state changed."
        }
        switch state {
        case .pendingApproval:
            return "I paused because this step needs approval before I can continue."
        case .failed:
            return "The runtime marked the task failed. I will keep the failure evidence available for recovery or a new instruction."
        case .blocked:
            let blocker = event.payload["blocker_reason"] ?? ""
            let isChinese = event.payload["response_language"] == "zh"
            let noReadEvidence = event.payload["successful_read_evidence"] != "true"
            if blocker == PlanReadinessBlocker.ungroundedFinalAnswer.rawValue {
                return isChinese
                    ? "只读检查已经结束，但现有证据还不足以支持完整的最终接入建议。已验证的观察和仍缺少的信息会保留在结果中。"
                    : "The read-only inspection finished, but the available evidence is not sufficient for a complete integration recommendation. Verified observations and missing information remain available in the result."
            }
            if blocker == PlanReadinessBlocker.workingDirectoryOutsideWorkspace.rawValue
                || blocker == PlanReadinessBlocker.workspaceScopeMismatch.rawValue {
                return isChinese
                    ? "任务已阻止：计划中的工作目录不属于当前选择的 Legacy 项目。FDE 没有读取任何文件。你可以使用当前 Legacy 根目录重试。"
                    : "Task blocked: the planned working directory is outside the selected Legacy project. FDE read no files. Retry using the current Legacy root."
            }
            if blocker == PlanReadinessBlocker.plannerTimeout.rawValue {
                return isChinese
                    ? "任务已阻止：规划请求超时，尚未生成可执行计划。可以重试当前任务。"
                    : "Task blocked: the planner request timed out before an executable plan was generated. You can retry the current task."
            }
            let evidence = noReadEvidence
                ? (isChinese ? "FDE 没有读取任何文件。" : "FDE read no files.")
                : ""
            return isChinese
                ? "任务已阻止：\(blocker)。\(evidence)可以修复或重试当前任务。"
                : "Task blocked: \(blocker). \(evidence) You can repair or retry the current task."
        case .completed:
            return "The runtime marked the task complete."
        case .running:
            return "I started running the plan."
        case .created, .planned, .waiting, .replayed:
            return "The runtime state is now \(state.rawValue)."
        }
    }

    private static func completionContent(for event: ExecutionEvent) -> String {
        if let detail = safeMarkdownPayloadValue(event, key: "detail") {
            return detail
        }
        if event.summary != "Task completed with real execution evidence",
           event.summary != "Autonomous mission completed",
           event.summary != event.type.rawValue {
            return safeSummary(event, fallback: "The mission completed with validated evidence.")
        }
        if let evidence = safePayloadValue(event, key: "completion_evidence") {
            return "Task completed after recorded evidence: \(evidence)."
        }
        return safeSummary(event, fallback: "The runtime did not provide a grounded completion report.")
    }

    private static func artifactContent(for event: ExecutionEvent) -> String {
        let summary = safeSummary(event, fallback: "execution report")
        return "Artifact event recorded: \(summary)."
    }

    private static func policyContent(for event: ExecutionEvent) -> String {
        let fallback = "Policy event recorded from execution evidence."
        let summary = safeSummary(event, fallback: fallback)
        guard event.summary != event.type.rawValue, summary != fallback else {
            return fallback
        }
        return "I captured a planning lesson: \(summary)."
    }

    private static func routeContent(for event: ExecutionEvent) -> String {
        if let route = safePayloadValue(event, key: "selected_route") ?? safePayloadValue(event, key: "routing_decision") {
            return "I selected the execution route: \(route)."
        }
        return "I selected the execution route for this run."
    }

    private static func nodeContent(for event: ExecutionEvent, fallback: String) -> String {
        if let node = safePayloadValue(event, key: "node_id") ?? safePayloadValue(event, key: "target_node_id") ?? safePayloadValue(event, key: "worker_id") {
            return "\(fallback) Node: \(node)."
        }
        return fallback
    }

    private static func commandText(for event: ExecutionEvent) -> String? {
        let command = safePayloadValue(event, key: "command")
            ?? safePayloadValue(event, key: "failed_command")
            ?? safePayloadValue(event, key: "recovery_command")
        guard let command else { return nil }
        guard let arguments = safePayloadValue(event, key: "arguments") else {
            return command
        }
        return "\(command) \(arguments)"
    }

    private static func semanticToolCallContent(for event: ExecutionEvent) -> String? {
        let command = safePayloadValue(event, key: "command")
        let arguments = safePayloadValue(event, key: "arguments") ?? ""
        let summary = safeSummary(event, fallback: "")
        let semanticSource = "\(summary) \(arguments)".lowercased()

        if command == "/bin/pwd" {
            return "Checking the current workspace path."
        }

        if command == "/bin/ls" {
            if let target = inspectionTarget(from: arguments) {
                return "Inspecting `\(target)`."
            }
            return "Inspecting the workspace files."
        }

        if command == "/bin/echo" {
            if semanticSource.contains("checkpoint") {
                return "Preparing a checkpoint before inspecting the workspace."
            }
            if semanticSource.contains("policy") || semanticSource.contains("strategy") {
                return "Applying the learned execution policy before choosing tools."
            }
            if semanticSource.contains("architecture") {
                return "Capturing architecture context for the review."
            }
            return "Recording a safe execution note for this step."
        }

        return nil
    }

    private static func semanticStepResultContent(for event: ExecutionEvent) -> String? {
        let command = safePayloadValue(event, key: "command")
        let arguments = safePayloadValue(event, key: "arguments") ?? ""
        let summary = safeSummary(event, fallback: "")
        let semanticSource = "\(summary) \(arguments)".lowercased()

        if command == "/bin/pwd" {
            return "Confirmed the current workspace path and recorded it as evidence."
        }

        if command == "/bin/ls" {
            if let target = inspectionTarget(from: arguments) {
                return "Finished inspecting `\(target)` and recorded the result as evidence."
            }
            return "Finished inspecting the workspace files and recorded the result as evidence."
        }

        if command == "/bin/echo" {
            if semanticSource.contains("checkpoint") {
                return "Created a checkpoint before inspecting the workspace."
            }
            if semanticSource.contains("policy") || semanticSource.contains("strategy") {
                return "Recorded execution policy context from the step output."
            }
            if semanticSource.contains("architecture") {
                return "Captured the architecture context needed for the review."
            }
            return "Recorded the step note as evidence."
        }

        return nil
    }

    private static func inspectionTarget(from arguments: String) -> String? {
        let tokens = arguments
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.hasPrefix("-") }
        return tokens.last
    }

    private static func attemptText(for event: ExecutionEvent) -> String {
        guard let attempt = safePayloadValue(event, key: "attempt") else { return "" }
        if let maxAttempts = safePayloadValue(event, key: "max_attempts") {
            return " (attempt \(attempt)/\(maxAttempts))"
        }
        return " (attempt \(attempt))"
    }

    private static func safePayloadValue(_ event: ExecutionEvent, key: String) -> String? {
        guard safePayloadKeys.contains(key),
              let value = event.payload[key],
              !value.isEmpty else {
            return nil
        }
        let safe = AgentPresentationSanitizer.safeContent(value, fallback: "")
        guard !safe.isEmpty, !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return nil
        }
        return safe
    }

    private static func safeMarkdownPayloadValue(_ event: ExecutionEvent, key: String) -> String? {
        guard safePayloadKeys.contains(key),
              let value = event.payload[key],
              !value.isEmpty else {
            return nil
        }
        let safe = AgentPresentationSanitizer.safeMarkdownContent(value, fallback: "")
        guard !safe.isEmpty, !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return nil
        }
        return safe
    }

    private static func safeSummary(_ event: ExecutionEvent, fallback: String) -> String {
        guard event.summary != event.type.rawValue else { return fallback }
        let safe = AgentPresentationSanitizer.safeContent(event.summary, fallback: fallback)
        guard !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return fallback
        }
        return safe
    }

    private static func dedupeKey(for message: AgentMessage) -> String {
        "\(message.type.rawValue)|\(message.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private static func relatedArtifactID(for event: ExecutionEvent) -> String? {
        switch event.type {
        case .taskCompleted:
            return "completion-\(event.id.uuidString)"
        case .feedbackGenerated:
            return event.payload["feedback_id"].map { "feedback-\($0)" } ?? "event-\(event.id.uuidString)"
        case .policyUpdated:
            return event.payload["policy_delta_id"].map { "policy-\($0)" } ?? "event-\(event.id.uuidString)"
        case .humanApprovalRequested:
            return event.payload["approval_request_id"].map { "approval-\($0)" } ?? "event-\(event.id.uuidString)"
        case .userDecisionSelected:
            return event.payload["message_id"].map { "decision-\($0)" }
        case .contextCompiled,
             .stepExecuted,
             .connectorExecuted,
             .nodeExecutionCompleted,
             .executionResponseReceived,
             .workerTaskCompleted:
            return "event-\(event.id.uuidString)"
        default:
            return nil
        }
    }
}

enum AgentPresentationSanitizer {
    static func safeContent(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard !containsPrivateReasoningMarker(trimmed) else { return fallback }

        let redacted = redactSensitiveInlineValues(trimmed)
        guard !redacted.isEmpty else { return fallback }
        return String(redacted.prefix(180))
    }

    static func safeMarkdownContent(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fallback }
        guard !containsPrivateReasoningMarker(trimmed) else { return fallback }

        let redacted = redactSensitiveInlineValues(trimmed)
        guard !redacted.isEmpty,
              !containsRestrictedContent(redacted) else {
            return fallback
        }
        return String(redacted.prefix(8_000))
    }

    static func containsRestrictedContent(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return containsPrivateReasoningMarker(value)
            || lowercased.contains("stdout")
            || lowercased.contains("stderr")
            || lowercased.contains("secret_value")
            || lowercased.contains("sk-")
            || lowercased.contains("token=")
            || lowercased.contains("api_key=")
            || lowercased.contains("x-api-key=")
            || lowercased.contains("authorization=")
            || lowercased.contains("credential=")
            || lowercased.contains("password=")
            || lowercased.contains("secret=")
    }

    private static func containsPrivateReasoningMarker(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return [
            "chain_of_thought",
            "chain-of-thought",
            "chain of thought",
            "scratchpad",
            "private reasoning",
            "reasoning:",
            "thought:",
            "analysis:"
        ].contains { lowercased.contains($0) }
    }

    private static func redactSensitiveInlineValues(_ value: String) -> String {
        var words = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var redactNext = false

        for index in words.indices {
            let lowercased = words[index].lowercased()
            if redactNext {
                words[index] = "[redacted]"
                redactNext = false
                continue
            }

            if isSensitiveFlag(lowercased) {
                redactNext = true
                continue
            }
            if containsSensitiveAssignment(lowercased) {
                words[index] = redactedAssignment(words[index])
            } else if lowercased == "bearer" || lowercased == "bearer:" {
                words[index] = "[redacted]"
                redactNext = true
            } else if lowercased.hasPrefix("bearer") {
                words[index] = "[redacted]"
            }
        }

        return words.joined(separator: " ")
    }

    private static func isSensitiveFlag(_ value: String) -> Bool {
        [
            "--api-key",
            "--apikey",
            "--authorization",
            "--credential",
            "--header",
            "--password",
            "--secret",
            "--token",
            "-p"
        ].contains(value)
    }

    private static func containsSensitiveAssignment(_ value: String) -> Bool {
        [
            "api_key=",
            "apikey=",
            "anthropic_api_key=",
            "authorization=",
            "credential=",
            "openai_api_key=",
            "password=",
            "secret=",
            "token=",
            "x-api-key="
        ].contains { value.contains($0) }
    }

    private static func redactedAssignment(_ value: String) -> String {
        guard let separatorIndex = value.firstIndex(of: "=") else {
            return "[redacted]"
        }
        return "\(value[..<value.index(after: separatorIndex)])[redacted]"
    }
}

private extension Array where Element == ExecutionEvent {
    func sortedByComposerOrder() -> [ExecutionEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }
}
