import Foundation

enum AgentConversationDisplayContent: Equatable, Sendable {
    case message(AgentMessage)
    case streamingResponse(AgentConversationStreamingResponse)
}

struct AgentConversationDisplayItem: Identifiable, Equatable, Sendable {
    let id: String
    var timestamp: Date
    var sortRank: Int
    var content: AgentConversationDisplayContent
}

struct AgentConversationStreamingChunk: Identifiable, Equatable, Sendable {
    let id: String
    var timestamp: Date
    var markdown: String
    var messageType: AgentMessageType
    var relatedEventID: UUID?
    var relatedArtifactID: String?
}

struct AgentConversationStreamingResponse: Identifiable, Equatable, Sendable {
    let id: String
    var timestamp: Date
    var chunks: [AgentConversationStreamingChunk]
    var messageType: AgentMessageType
    var relatedWorkUnitID: String?
    var status: AgentWorkUnitStatus?
    var isStreaming: Bool

    var markdown: String {
        chunks.map(\.markdown).joined(separator: "\n\n")
    }

    var relatedArtifactID: String? {
        chunks.reversed().compactMap(\.relatedArtifactID).first
    }
}

struct AgentConversationWorkUnitCard: Identifiable, Equatable, Sendable {
    let id: String
    var title: String
    var status: AgentWorkUnitStatus
    var narration: String
    var completedSteps: [String]
    var toolsUsed: [String]
    var evidenceSummary: String?
    var rawEvents: [AgentConversationRawEventRow]
    var metrics: AgentConversationWorkMetrics
    var kind: AgentWorkUnitKind
    var agent: AgentKind?
}

struct AgentConversationWorkMetrics: Equatable, Sendable {
    var filesExplored: [String] = []
    var filesModified: [String] = []
    var commandsRun: Int = 0
    var testsPassed: Int = 0
    var errorsRecovered: Int = 0

    var isEmpty: Bool {
        filesExplored.isEmpty
            && filesModified.isEmpty
            && commandsRun == 0
            && testsPassed == 0
            && errorsRecovered == 0
    }
}

struct AgentConversationRawEventRow: Identifiable, Equatable, Sendable {
    let id: UUID
    var sequence: Int64
    var eventType: EventType
    var detail: String?
}

struct AgentConversationWorkUnitAdapter: Sendable {
    func displayItems(
        conversation: AgentConversation,
        events: [ExecutionEvent]
    ) -> [AgentConversationDisplayItem] {
        Self.displayItems(conversation: conversation, events: events)
    }

    static func displayItems(
        conversation: AgentConversation,
        events: [ExecutionEvent]
    ) -> [AgentConversationDisplayItem] {
        let orderedEvents = deduplicatedEvents(events).sortedByConversationWorkUnitOrder()
        let conversationMessages = deduplicatedMessages(conversation.messages)
        let workUnits = normalizedWorkUnits(
            EventToWorkUnitAggregator.workUnits(from: orderedEvents),
            events: orderedEvents
        )
            .filter(shouldRenderAsConversationCard)
        let canonicalAnswerEventIDs = Set(orderedEvents.filter(isCanonicalAnswerEvent).map(\.id))
        let workUnitIDByEventID = Dictionary(
            uniqueKeysWithValues: workUnits.flatMap { unit in
                unit.eventIDs.map { ($0, unit.id) }
            }
        )
        let items = conversationMessages.compactMap { message -> AgentConversationDisplayItem? in
            if message.sender == .agent,
               let eventID = message.relatedEventID,
               orderedEvents.contains(where: { $0.id == eventID }),
               !canonicalAnswerEventIDs.contains(eventID) {
                return nil
            }
            if shouldRenderAsStreamingResponse(message),
               let response = streamingResponse(for: message, workUnitIDByEventID: workUnitIDByEventID) {
                return AgentConversationDisplayItem(
                    id: response.id,
                    timestamp: response.timestamp,
                    sortRank: 1,
                    content: .streamingResponse(response)
                )
            }
            return AgentConversationDisplayItem(
                id: "message-\(message.id.uuidString)",
                timestamp: message.timestamp,
                sortRank: 0,
                content: .message(message)
            )
        }

        return items.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                if lhs.sortRank == rhs.sortRank {
                    return lhs.id < rhs.id
                }
                return lhs.sortRank < rhs.sortRank
            }
            return lhs.timestamp < rhs.timestamp
        }
    }

    /// Conversation-first visibility keeps the latest ordinary Agent reply
    /// visible even when it is represented as a streaming response. Mission
    /// assets may replace only their own duplicated terminal result card.
    static func conciseDisplayItems(
        from displayItems: [AgentConversationDisplayItem],
        hasMissionAssets: Bool
    ) -> [AgentConversationDisplayItem] {
        let lastAgentID = displayItems.reversed().first(where: { item in
            switch item.content {
            case let .message(message): return message.sender == .agent
            case .streamingResponse: return true
            }
        })?.id

        return displayItems.filter { item in
            switch item.content {
            case let .message(message):
                if item.id == lastAgentID,
                   !(hasMissionAssets && message.type == .result) {
                    return true
                }
                return message.sender == .user
                    || !message.options.isEmpty
                    || message.type == .question
                    || message.type == .decisionRequest
                    || message.type == .warning
                    || (!hasMissionAssets && message.type == .result)
            case let .streamingResponse(response):
                if item.id == lastAgentID,
                   !(hasMissionAssets && response.messageType == .result) {
                    return true
                }
                return response.messageType == .warning
                    || (!hasMissionAssets && response.messageType == .result)
            }
        }
    }

    static func workStatusCards(
        conversation: AgentConversation,
        events: [ExecutionEvent]
    ) -> [AgentConversationWorkUnitCard] {
        let orderedEvents = deduplicatedEvents(events).sortedByConversationWorkUnitOrder()
        let conversationMessages = deduplicatedMessages(conversation.messages)
        let eventsByID = Dictionary(uniqueKeysWithValues: orderedEvents.map { ($0.id, $0) })
        let messagesByEventID = Dictionary(grouping: conversationMessages.compactMap { message -> (UUID, AgentMessage)? in
            guard let eventID = message.relatedEventID else { return nil }
            return (eventID, message)
        }, by: \.0)
            .mapValues { pairs in
                pairs.map(\.1).sortedByMessageTime()
            }

        return normalizedWorkUnits(
            EventToWorkUnitAggregator.workUnits(from: orderedEvents),
            events: orderedEvents
        )
            .filter(shouldRenderAsConversationCard)
            .map { unit in
                card(
                    for: unit,
                    eventsByID: eventsByID,
                    messagesByEventID: messagesByEventID
                )
            }
    }

    private static func normalizedWorkUnits(
        _ workUnits: [AgentWorkUnit],
        events: [ExecutionEvent]
    ) -> [AgentWorkUnit] {
        let ordered = events.sortedByConversationWorkUnitOrder()
        let terminalSequenceByTask = Dictionary(grouping: ordered.filter(isTerminalTaskEvent), by: \.taskID)
            .compactMapValues { $0.map(\.sequence).max() }
        return workUnits.map { unit in
            let presentsGroundedPartial = unit.eventIDs.contains { id in
                guard let event = ordered.first(where: { $0.id == id }) else { return false }
                return event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
            }
            if presentsGroundedPartial {
                var partialUnit = unit
                partialUnit.status = .partial
                return partialUnit
            }
            guard let lastSequence = unit.eventIDs.compactMap({ id in
                ordered.first(where: { $0.id == id })?.sequence
            }).max() else {
                return unit
            }
            let terminalClosedUnit = terminalSequenceByTask[unit.taskID].map { terminalSequence in
                terminalSequence > lastSequence
                    && (unit.status == .active || unit.status == .planned || unit.status == .waitingApproval)
            } ?? false
            let executionAdvancedPlan = unit.status == .planned
                && ordered.contains(where: { event in
                    event.sequence > lastSequence
                        && event.taskID == unit.taskID
                        && actualExecutionEventTypes.contains(event.type)
                })
            guard terminalClosedUnit || executionAdvancedPlan else { return unit }
            var advancedUnit = unit
            advancedUnit.status = .completed
            return advancedUnit
        }
    }

    private static func isTerminalTaskEvent(_ event: ExecutionEvent) -> Bool {
        if event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT" {
            return true
        }
        if event.type == .taskCompleted && event.payload["completion_gate_passed"] != "false" {
            return true
        }
        return event.payload["state"] == TaskState.blocked.rawValue
            || event.payload["state"] == TaskState.failed.rawValue
            || event.payload["state"] == TaskState.completed.rawValue
    }

    private static func isCanonicalAnswerEvent(_ event: ExecutionEvent) -> Bool {
        if event.type == .taskCompleted {
            return event.payload["grounded_answer"] == "true"
                || event.payload["completion_contract"] == RuntimeCompletionContractKind.readOnlyInspection.rawValue
        }
        return event.type == .stateUpdated
            && event.payload["partial_completion_state"] == "BLOCKED_WITH_PARTIAL_RESULT"
            && event.payload["grounded_answer"] == "true"
            && event.payload["final_answer"]?.isEmpty == false
    }

    private static func shouldRenderAsStreamingResponse(_ message: AgentMessage) -> Bool {
        message.sender == .agent && message.options.isEmpty
    }

    private static func streamingResponse(
        for message: AgentMessage,
        workUnitIDByEventID: [UUID: String]
    ) -> AgentConversationStreamingResponse? {
        guard let chunk = streamingChunk(for: message) else { return nil }
        let relatedWorkUnitID = message.relatedEventID.flatMap { workUnitIDByEventID[$0] }
        return AgentConversationStreamingResponse(
            id: "stream-message-\(message.id.uuidString)",
            timestamp: message.timestamp,
            chunks: [chunk],
            messageType: message.type,
            relatedWorkUnitID: relatedWorkUnitID,
            status: nil,
            isStreaming: false
        )
    }

    private static func deduplicatedEvents(_ events: [ExecutionEvent]) -> [ExecutionEvent] {
        var seen = Set<UUID>()
        return events.filter { seen.insert($0.id).inserted }
    }

    private static func deduplicatedMessages(_ messages: [AgentMessage]) -> [AgentMessage] {
        var result: [AgentMessage] = []
        var indexByPresentationKey: [String: Int] = [:]
        for message in messages {
            guard let eventID = message.relatedEventID else {
                result.append(message)
                continue
            }
            let role = message.sender == .user ? "user" : "main_activity"
            let key = "event:\(eventID.uuidString):\(role)"
            if let index = indexByPresentationKey[key] {
                // A live narration replacement and its deterministic projection
                // are the same presentation role for the same runtime event.
                // Keep the latest projection without suppressing other event IDs.
                result[index] = message
            } else {
                indexByPresentationKey[key] = result.count
                result.append(message)
            }
        }
        return result
    }

    private static func streamingChunk(for message: AgentMessage) -> AgentConversationStreamingChunk? {
        guard let safe = safeMarkdownText(message.content) else { return nil }
        return AgentConversationStreamingChunk(
            id: message.id.uuidString,
            timestamp: message.timestamp,
            markdown: safe,
            messageType: message.type,
            relatedEventID: message.relatedEventID,
            relatedArtifactID: message.relatedArtifactID
        )
    }

    private static func shouldRenderAsConversationCard(_ unit: AgentWorkUnit) -> Bool {
        switch unit.kind {
        case .request,
             .system:
            return false
        case .understanding,
             .planning,
             .execution,
             .approval,
             .recovery,
             .policy,
             .result:
            return true
        }
    }

    private static func card(
        for unit: AgentWorkUnit,
        eventsByID: [UUID: ExecutionEvent],
        messagesByEventID: [UUID: [AgentMessage]]
    ) -> AgentConversationWorkUnitCard {
        let rawEvents = unit.eventIDs
            .compactMap { eventsByID[$0] }
            .sortedByConversationWorkUnitOrder()
        let relatedMessages = unit.eventIDs
            .flatMap { messagesByEventID[$0] ?? [] }
            .filter { $0.sender == .agent }
            .sortedByMessageTime()

        return AgentConversationWorkUnitCard(
            id: unit.id,
            title: title(for: unit, events: rawEvents),
            status: unit.status,
            narration: narration(for: unit, messages: relatedMessages),
            completedSteps: completedSteps(from: rawEvents),
            toolsUsed: toolsUsed(from: rawEvents),
            evidenceSummary: evidenceSummary(from: rawEvents),
            rawEvents: rawEvents.map(rawEventRow),
            metrics: metrics(from: rawEvents, allEvents: Array(eventsByID.values)),
            kind: unit.kind,
            agent: unit.agent
        )
    }

    private static func title(for unit: AgentWorkUnit, events: [ExecutionEvent]) -> String {
        if unit.kind == .execution,
           let latestStepTitle = events.reversed().compactMap(stepTitle).first {
            return latestStepTitle
        }
        return unit.title
    }

    private static func narration(
        for unit: AgentWorkUnit,
        messages: [AgentMessage]
    ) -> String {
        if let latest = messages.reversed().compactMap({ safeDisplayText($0.content) }).first {
            return latest
        }
        if let detail = unit.detail.flatMap(safeDisplayText) {
            return detail
        }

        switch unit.status {
        case .planned:
            return "The plan is ready; execution has not started."
        case .active:
            return "Work is in progress."
        case .waitingApproval:
            return "Waiting for approval before continuing."
        case .blocked:
            return "Work is blocked and has not completed."
        case .partial:
            return "A grounded partial result is available and can be continued."
        case .completed:
            return "Work completed."
        case .failed:
            return "Work did not complete successfully."
        }
    }

    private static func completedSteps(from events: [ExecutionEvent]) -> [String] {
        unique(
            events.compactMap { event in
                guard completedStepEventTypes.contains(event.type) else { return nil }
                return stepTitle(for: event) ?? safeDisplayText(event.summary)
            }
        )
    }

    private static func toolsUsed(from events: [ExecutionEvent]) -> [String] {
        unique(events.compactMap { event in
            guard toolActivityEventTypes.contains(event.type) else { return nil }
            return commandText(for: event)
        })
    }

    private static func evidenceSummary(from events: [ExecutionEvent]) -> String? {
        let evidenceEvents = events.filter { evidenceEventTypes.contains($0.type) }
        guard let latest = evidenceEvents.last else { return nil }
        let latestDetail = stepTitle(for: latest)
            ?? safeDisplayText(latest.summary)
            ?? latest.type.rawValue
        if evidenceEvents.count == 1 {
            return latestDetail
        }
        return "\(evidenceEvents.count) evidence updates. Latest: \(latestDetail)"
    }

    private static func metrics(
        from events: [ExecutionEvent],
        allEvents: [ExecutionEvent]
    ) -> AgentConversationWorkMetrics {
        let resultEvents = events.filter(isObservedToolResult)
        let filesExplored = unique(resultEvents.compactMap { event in
            guard isSuccessful(event), isInspectionResult(event) else { return nil }
            return targetPath(from: event)
        })
        let filesModified = unique(resultEvents.compactMap { event in
            guard isSuccessful(event), isModificationResult(event) else { return nil }
            return targetPath(from: event)
        })
        let commandIDs = Set(resultEvents.compactMap { event in
            safePayloadValue(event, key: "tool_call_id")
                ?? safePayloadValue(event, key: "command")
                ?? safePayloadValue(event, key: "tool_name")
        })
        let testsPassed = resultEvents.filter { event in
            isSuccessful(event) && isTestResult(event)
        }.count
        let errorsRecovered = events.filter { event in
            guard event.type == .recoveryAttempted else { return false }
            return allEvents.contains { later in
                later.sequence > event.sequence
                    && isObservedToolResult(later)
                    && isSuccessful(later)
            }
        }.count

        return AgentConversationWorkMetrics(
            filesExplored: filesExplored,
            filesModified: filesModified,
            commandsRun: commandIDs.count,
            testsPassed: testsPassed,
            errorsRecovered: errorsRecovered
        )
    }

    private static func isObservedToolResult(_ event: ExecutionEvent) -> Bool {
        observedToolResultEventTypes.contains(event.type)
    }

    private static func isSuccessful(_ event: ExecutionEvent) -> Bool {
        if event.payload["success"] == "true" { return true }
        return event.payload["exit_code"] == "0"
            || event.payload["observation_outcome"] == "SUCCEEDED"
            || event.payload["observation_outcome"] == "succeeded"
    }

    private static func isInspectionResult(_ event: ExecutionEvent) -> Bool {
        let value = evidenceText(for: event)
        return ["read_file", "search_files", "search_code", "inspect_project", "list_directory", "/usr/bin/head", "/bin/ls"]
            .contains { value.contains($0) }
    }

    private static func isModificationResult(_ event: ExecutionEvent) -> Bool {
        let value = evidenceText(for: event)
        guard ["write_file", "edit_file", "write_patch", "apply_patch", "file_patch", "git_diff"]
            .contains(where: value.contains) else {
            return false
        }
        if let nonEmpty = event.payload["diff_nonempty"] {
            return nonEmpty == "true"
        }
        if event.payload["diff"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return true
        }
        let result = (event.payload["actual_result"] ?? event.payload["stdout"] ?? "").lowercased()
        return result.contains("diff_nonempty=true")
    }

    private static func isTestResult(_ event: ExecutionEvent) -> Bool {
        let value = evidenceText(for: event)
        return value.contains("swift test")
            || value.contains("xctest")
            || value.contains("pytest")
            || value.contains("npm test")
            || value.contains(" test ")
            || value.hasSuffix(" test")
    }

    private static func evidenceText(for event: ExecutionEvent) -> String {
        [
            event.payload["evidence_kind"],
            event.payload["tool_name"],
            event.payload["command"],
            event.payload["arguments"],
            event.payload["actual_result"]
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
    }

    private static func targetPath(from event: ExecutionEvent) -> String? {
        if let target = safePayloadValue(event, key: "target_path")
            ?? safePayloadValue(event, key: "path") {
            return target
        }
        guard let arguments = event.payload["arguments"] else { return nil }
        if let keyed = arguments
            .split(separator: " ")
            .map(String.init)
            .first(where: { $0.hasPrefix("path=") || $0.hasPrefix("file=") }) {
            return String(keyed.drop(while: { $0 != "=" }).dropFirst())
        }
        let positional = arguments
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.hasPrefix("-") && Int($0) == nil }
        return positional.last
    }

    private static func rawEventRow(for event: ExecutionEvent) -> AgentConversationRawEventRow {
        AgentConversationRawEventRow(
            id: event.id,
            sequence: event.sequence,
            eventType: event.type,
            detail: stepTitle(for: event)
                ?? commandText(for: event)
                ?? safeDisplayText(event.summary)
        )
    }

    private static func stepTitle(for event: ExecutionEvent) -> String? {
        guard event.summary != event.type.rawValue else { return nil }
        return safeDisplayText(event.summary)
    }

    private static func commandText(for event: ExecutionEvent) -> String? {
        let command = safePayloadValue(event, key: "command")
            ?? safePayloadValue(event, key: "failed_command")
            ?? safePayloadValue(event, key: "recovery_command")
        guard let command else { return nil }
        if let label = readOnlyToolLabel(command) {
            let path = safeCanonicalRelativePath(
                event.payload["normalized_relative_path"]
                    ?? event.payload["target_path"]
                    ?? event.payload["path"]
            )
            return path.map { "\(label) · \($0)" } ?? label
        }
        guard let arguments = safePayloadValue(event, key: "arguments") else {
            return command
        }
        return "\(command) \(arguments)"
    }

    private static func readOnlyToolLabel(_ command: String) -> String? {
        switch command {
        case "engineering.inspect_project": return "Inspect project"
        case "engineering.list_directory": return "List directory"
        case "engineering.search_files": return "Search files"
        case "engineering.search_code": return "Search code"
        case "engineering.read_file": return "Read file"
        default: return nil
        }
    }

    private static func safeCanonicalRelativePath(_ value: String?) -> String? {
        guard var path = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              path.count <= 240,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !ReadOnlySensitivePathPolicy.isSensitive(path) else {
            return nil
        }
        while path.hasPrefix("./") { path.removeFirst(2) }
        if path == "." { return "." }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private static func safePayloadValue(_ event: ExecutionEvent, key: String) -> String? {
        guard let value = event.payload[key], !value.isEmpty else { return nil }
        return safeDisplayText(value)
    }

    private static func safeDisplayText(_ value: String) -> String? {
        let safe = AgentPresentationSanitizer.safeContent(value, fallback: "")
        guard !safe.isEmpty,
              !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return nil
        }
        return safe
    }

    private static func safeMarkdownText(_ value: String) -> String? {
        let safe = AgentPresentationSanitizer.safeMarkdownContent(value, fallback: "")
        guard !safe.isEmpty,
              !AgentPresentationSanitizer.containsRestrictedContent(safe) else {
            return nil
        }
        return safe
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = value.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static let completedStepEventTypes: Set<EventType> = [
        .stepExecuted,
        .connectorExecuted,
        .nodeExecutionCompleted,
        .executionResponseReceived,
        .workerTaskCompleted
    ]

    private static let evidenceEventTypes: Set<EventType> = [
        .stepExecuted,
        .connectorExecuted,
        .nodeExecutionCompleted,
        .executionResponseReceived,
        .workerTaskCompleted,
        .toolFailed,
        .connectorFailed,
        .nodeExecutionFailed,
        .workerTaskFailed
    ]

    private static let actualExecutionEventTypes: Set<EventType> = [
        .toolCalled,
        .connectorCalled,
        .stepExecuted,
        .connectorExecuted,
        .toolFailed,
        .connectorFailed
    ]

    private static let observedToolResultEventTypes: Set<EventType> = [
        .stepExecuted,
        .connectorExecuted,
        .nodeExecutionCompleted,
        .executionResponseReceived,
        .workerTaskCompleted
    ]

    private static let toolActivityEventTypes: Set<EventType> = [
        .toolCalled,
        .stepExecuted,
        .toolFailed,
        .connectorCalled,
        .connectorDryRun,
        .connectorExecuted,
        .connectorFailed,
        .recoveryAttempted,
        .nodeExecutionStarted,
        .nodeExecutionCompleted,
        .nodeExecutionFailed,
        .executionDispatched,
        .executionReceived,
        .executionResponseReceived,
        .workerTaskReceived,
        .workerTaskCompleted,
        .workerTaskFailed
    ]
}

private extension Array where Element == ExecutionEvent {
    func sortedByConversationWorkUnitOrder() -> [ExecutionEvent] {
        sorted { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }
    }
}

private extension Array where Element == AgentMessage {
    func sortedByMessageTime() -> [AgentMessage] {
        sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }
    }
}
