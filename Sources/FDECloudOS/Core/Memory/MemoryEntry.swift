import Foundation

enum EnterpriseMemoryType: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case customerMemory = "CustomerMemory"
    case systemMemory = "SystemMemory"
    case failureMemory = "FailureMemory"
    case solutionMemory = "SolutionMemory"
    case executionMemory = "ExecutionMemory"

    var id: String { rawValue }
}

struct MemoryEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var type: EnterpriseMemoryType
    var title: String
    var summary: String
    var detail: String
    var tags: [String]
    var relatedTaskFingerprint: String?
    var connectorID: String?
    var sourceTaskID: UUID?
    var confidence: Double
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        workspaceID: UUID,
        type: EnterpriseMemoryType,
        title: String,
        summary: String,
        detail: String = "",
        tags: [String] = [],
        relatedTaskFingerprint: String? = nil,
        connectorID: String? = nil,
        sourceTaskID: UUID? = nil,
        confidence: Double = 1.0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.type = type
        self.title = title
        self.summary = summary
        self.detail = detail
        self.tags = tags
        self.relatedTaskFingerprint = relatedTaskFingerprint
        self.connectorID = connectorID
        self.sourceTaskID = sourceTaskID
        self.confidence = confidence
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspace_id"
        case type
        case title
        case summary
        case detail
        case tags
        case relatedTaskFingerprint = "related_task_fingerprint"
        case connectorID = "connector_id"
        case sourceTaskID = "source_task_id"
        case confidence
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct EnterpriseMemoryContext: Codable, Hashable, Sendable {
    var previousFailures: [MemoryEntry]
    var successfulFixes: [MemoryEntry]
    var customerSystemContext: [MemoryEntry]
    var connectorHistory: [MemoryEntry]

    static let empty = EnterpriseMemoryContext(
        previousFailures: [],
        successfulFixes: [],
        customerSystemContext: [],
        connectorHistory: []
    )

    var isEmpty: Bool {
        previousFailures.isEmpty
            && successfulFixes.isEmpty
            && customerSystemContext.isEmpty
            && connectorHistory.isEmpty
    }

    var allEntries: [MemoryEntry] {
        previousFailures + successfulFixes + customerSystemContext + connectorHistory
    }
}
