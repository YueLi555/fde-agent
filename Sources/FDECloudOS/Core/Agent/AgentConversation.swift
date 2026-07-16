import Foundation

enum AgentMessageType: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case text = "TEXT"
    case progressUpdate = "PROGRESS_UPDATE"
    case planUpdate = "PLAN_UPDATE"
    case question = "QUESTION"
    case decisionRequest = "DECISION_REQUEST"
    case warning = "WARNING"
    case artifact = "ARTIFACT"

    // Legacy V13 presentation types kept for replay and migration compatibility.
    case userRequest = "USER_REQUEST"
    case agentStatus = "AGENT_STATUS"
    case observation = "OBSERVATION"
    case actionUpdate = "ACTION_UPDATE"
    case decision = "DECISION"
    case evidence = "EVIDENCE"
    case result = "RESULT"
    case approvalRequest = "APPROVAL_REQUEST"

    var id: String { rawValue }
}

enum AgentMessageSender: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case user = "USER"
    case agent = "AGENT"
    case system = "SYSTEM"

    var id: String { rawValue }
}

struct AgentMessageOption: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var detail: String?

    init(id: String, title: String, detail: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

struct AgentMessage: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var timestamp: Date
    var sender: AgentMessageSender
    var type: AgentMessageType
    var content: String
    var options: [AgentMessageOption]
    var selectedOptionID: String?
    var relatedEventID: UUID?
    var relatedArtifactID: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sender: AgentMessageSender = .agent,
        type: AgentMessageType,
        content: String,
        options: [AgentMessageOption] = [],
        selectedOptionID: String? = nil,
        relatedEventID: UUID? = nil,
        relatedArtifactID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sender = sender
        self.type = type
        self.content = content
        self.options = options
        self.selectedOptionID = selectedOptionID
        self.relatedEventID = relatedEventID
        self.relatedArtifactID = relatedArtifactID
    }

    static func userRequest(_ content: String, timestamp: Date = Date()) -> AgentMessage {
        AgentMessage(
            timestamp: timestamp,
            sender: .user,
            type: .text,
            content: content
        )
    }

    static func question(
        _ content: String,
        options: [AgentMessageOption],
        timestamp: Date = Date()
    ) -> AgentMessage {
        AgentMessage(
            timestamp: timestamp,
            sender: .agent,
            type: .question,
            content: content,
            options: options
        )
    }

    static func decisionRequest(
        _ content: String,
        options: [AgentMessageOption],
        timestamp: Date = Date()
    ) -> AgentMessage {
        AgentMessage(
            timestamp: timestamp,
            sender: .agent,
            type: .decisionRequest,
            content: content,
            options: options
        )
    }
}

struct AgentNarrationRequest: Codable, Hashable, Sendable {
    var eventType: EventType
    var fallbackMessageType: AgentMessageType
    var deterministicFallback: String
    var eventSummary: String
    var safePayload: [String: String]
    var recentMessages: [String]

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type"
        case fallbackMessageType = "fallback_message_type"
        case deterministicFallback = "deterministic_fallback"
        case eventSummary = "event_summary"
        case safePayload = "safe_payload"
        case recentMessages = "recent_messages"
    }
}

struct AgentNarration: Codable, Hashable, Sendable {
    var content: String
    var messageType: AgentMessageType
    var confidence: Double?
    var provider: ModelProviderKind?
    var usedFallback: Bool
    private static let allowedGeneratedMessageTypes: Set<AgentMessageType> = [
        .text,
        .progressUpdate,
        .planUpdate,
        .warning,
        .artifact,
        .observation,
        .actionUpdate,
        .decision,
        .evidence,
        .result,
        .approvalRequest
    ]

    init(
        content: String,
        messageType: AgentMessageType,
        confidence: Double? = nil,
        provider: ModelProviderKind? = nil,
        usedFallback: Bool = false
    ) {
        self.content = content
        self.messageType = messageType
        self.confidence = confidence
        self.provider = provider
        self.usedFallback = usedFallback
    }

    enum CodingKeys: String, CodingKey {
        case content
        case messageType = "message_type"
        case confidence
        case provider
        case usedFallback = "used_fallback"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.content = try container.decode(String.self, forKey: .content)
        self.messageType = try container.decode(AgentMessageType.self, forKey: .messageType)
        self.confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        self.provider = try container.decodeIfPresent(ModelProviderKind.self, forKey: .provider)
        self.usedFallback = try container.decodeIfPresent(Bool.self, forKey: .usedFallback) ?? false
    }

    func sanitized(
        fallbackContent: String,
        fallbackMessageType: AgentMessageType,
        provider selectedProvider: ModelProviderKind?,
        usedFallback fallbackUsed: Bool
    ) -> AgentNarration {
        let safeContent = AgentPresentationSanitizer.safeMarkdownContent(content, fallback: fallbackContent)
        let finalContent = AgentPresentationSanitizer.containsRestrictedContent(safeContent)
            ? fallbackContent
            : safeContent
        let finalConfidence = confidence.map { min(max($0, 0), 1) }
        let finalMessageType = Self.allowedGeneratedMessageTypes.contains(messageType)
            ? messageType
            : fallbackMessageType

        return AgentNarration(
            content: finalContent,
            messageType: finalContent == fallbackContent ? fallbackMessageType : finalMessageType,
            confidence: finalConfidence,
            provider: selectedProvider ?? provider,
            usedFallback: fallbackUsed
        )
    }
}

struct AgentConversation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sessionID: UUID
    var workspaceID: UUID
    var messages: [AgentMessage]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        workspaceID: UUID,
        messages: [AgentMessage] = [],
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.workspaceID = workspaceID
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    static func started(
        sessionID: UUID,
        workspaceID: UUID,
        userRequest: String,
        createdAt: Date = Date()
    ) -> AgentConversation {
        AgentConversation(
            sessionID: sessionID,
            workspaceID: workspaceID,
            messages: [
                AgentMessage.userRequest(userRequest, timestamp: createdAt)
            ],
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    mutating func append(_ message: AgentMessage) {
        guard !messages.contains(where: { $0.id == message.id }) else { return }
        messages.append(message)
        updatedAt = max(updatedAt, message.timestamp)
    }

    mutating func append(contentsOf newMessages: [AgentMessage]) {
        for message in newMessages {
            append(message)
        }
    }

    @discardableResult
    mutating func appendMessageChunk(messageID: UUID, chunk: String, timestamp: Date = Date()) -> Bool {
        guard let index = messages.firstIndex(where: { $0.id == messageID }) else { return false }
        return appendMessageChunk(at: index, chunk: chunk, timestamp: timestamp)
    }

    @discardableResult
    mutating func appendMessageChunk(relatedEventID: UUID, chunk: String, timestamp: Date = Date()) -> Bool {
        guard let index = messages.firstIndex(where: { $0.relatedEventID == relatedEventID }) else { return false }
        return appendMessageChunk(at: index, chunk: chunk, timestamp: timestamp)
    }

    @discardableResult
    mutating func replaceMessage(relatedEventID: UUID, with message: AgentMessage) -> Bool {
        guard let index = messages.firstIndex(where: { $0.relatedEventID == relatedEventID }) else { return false }
        messages[index].content = message.content
        messages[index].type = message.type
        messages[index].relatedArtifactID = message.relatedArtifactID
        updatedAt = max(updatedAt, message.timestamp)
        return true
    }

    @discardableResult
    private mutating func appendMessageChunk(at index: Int, chunk: String, timestamp: Date) -> Bool {
        guard !chunk.isEmpty else { return false }
        let candidate = messages[index].content + chunk
        guard !AgentPresentationSanitizer.containsRestrictedContent(candidate) else { return false }
        messages[index].content = candidate
        updatedAt = max(updatedAt, timestamp)
        return true
    }
}

extension Array where Element == AgentMessage {
    func sortedByConversationOrder() -> [AgentMessage] {
        sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.timestamp < rhs.timestamp
        }
    }
}
