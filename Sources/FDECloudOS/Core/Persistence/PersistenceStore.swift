import Foundation

protocol PersistenceStore: Sendable {
    func initialize() async throws
    func loadWorkspaces() async throws -> [Workspace]
    func saveWorkspace(_ workspace: Workspace) async throws
    func saveSessionMetadata(_ metadata: SessionMetadata) async throws
    func loadSessionMetadata() async throws -> SessionMetadata?
    func clearSessionMetadata() async throws
    func loadTasks(workspaceID: UUID) async throws -> [FDETask]
    func saveTask(_ task: FDETask) async throws
    func appendEvent(
        _ event: ExecutionEvent,
        mode: EventAppendMode,
        initialTask: FDETask?
    ) async throws -> ExecutionEvent
    func loadEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent]
    func saveApprovalRequest(_ request: ApprovalRequest) async throws
    func loadApprovalRequest(id: UUID) async throws -> ApprovalRequest?
    func loadApprovalRequests(workspaceID: UUID?, state: ApprovalState?) async throws -> [ApprovalRequest]
    func saveGraph(nodes: [SystemGraphNode], edges: [SystemGraphEdge]) async throws
    func loadGraph(workspaceID: UUID) async throws -> ([SystemGraphNode], [SystemGraphEdge])
    func saveOutcome(_ outcome: OutcomeMetrics) async throws
    func loadLatestOutcome(workspaceID: UUID) async throws -> OutcomeMetrics?
    func saveFeedback(_ feedback: FeedbackInsight) async throws
    func loadFeedback(workspaceID: UUID) async throws -> [FeedbackInsight]
    func savePolicyDelta(_ delta: ExecutionPolicyDelta) async throws
    func loadPolicyDeltas(workspaceID: UUID) async throws -> [ExecutionPolicyDelta]
    func saveTaskExecutionMemory(_ memory: TaskExecutionMemory) async throws
    func loadTaskExecutionMemory(workspaceID: UUID) async throws -> [TaskExecutionMemory]
    func saveSystemFailureProfile(_ profile: SystemFailureProfile) async throws
    func loadLatestSystemFailureProfile(workspaceID: UUID) async throws -> SystemFailureProfile?
    func saveSystemInsight(_ insight: SystemLevelInsight) async throws
    func loadSystemInsights(workspaceID: UUID) async throws -> [SystemLevelInsight]
    func saveGlobalExecutionPolicy(_ policy: GlobalExecutionPolicy) async throws
    func loadLatestGlobalExecutionPolicy(workspaceID: UUID) async throws -> GlobalExecutionPolicy?
    func saveGlobalGovernorDecision(_ decision: GlobalGovernorDecision) async throws
    func loadGlobalGovernorDecisions(workspaceID: UUID) async throws -> [GlobalGovernorDecision]
}

enum EventAppendMode: Equatable, Sendable {
    case live
    case historicalReplay
}

extension PersistenceStore {
    @discardableResult
    func appendEvent(_ event: ExecutionEvent) async throws -> ExecutionEvent {
        try await appendEvent(event, mode: .historicalReplay, initialTask: nil)
    }

    @discardableResult
    func appendEvent(_ event: ExecutionEvent, mode: EventAppendMode) async throws -> ExecutionEvent {
        try await appendEvent(event, mode: mode, initialTask: nil)
    }
}

enum EventStoreFailureCategory: String, Equatable, Sendable {
    case eventSequenceConflict = "event_sequence_conflict"
    case eventDuplicateID = "event_duplicate_id"
    case eventStoreUnavailable = "event_store_unavailable"
    case eventStoreCorrupt = "event_store_corrupt"
    case eventTransactionFailed = "event_transaction_failed"
}

enum PersistenceError: LocalizedError, Sendable {
    case databaseUnavailable(String)
    case encodingFailed(String)
    case decodingFailed(String)
    case eventSequenceConflict
    case eventDuplicateID
    case eventStoreUnavailable
    case eventStoreCorrupt
    case eventTransactionFailed

    var eventStoreFailureCategory: EventStoreFailureCategory? {
        switch self {
        case .eventSequenceConflict:
            return .eventSequenceConflict
        case .eventDuplicateID:
            return .eventDuplicateID
        case .eventStoreUnavailable, .databaseUnavailable:
            return .eventStoreUnavailable
        case .eventStoreCorrupt, .decodingFailed:
            return .eventStoreCorrupt
        case .eventTransactionFailed, .encodingFailed:
            return .eventTransactionFailed
        }
    }

    var isSanitizedEventStoreFailure: Bool {
        switch self {
        case .eventSequenceConflict, .eventDuplicateID, .eventStoreUnavailable,
             .eventStoreCorrupt, .eventTransactionFailed:
            return true
        case .databaseUnavailable, .encodingFailed, .decodingFailed:
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let detail):
            return "Database unavailable: \(detail)"
        case .encodingFailed(let detail):
            return "Encoding failed: \(detail)"
        case .decodingFailed(let detail):
            return "Decoding failed: \(detail)"
        case .eventSequenceConflict:
            return "Event store failure: \(EventStoreFailureCategory.eventSequenceConflict.rawValue)"
        case .eventDuplicateID:
            return "Event store failure: \(EventStoreFailureCategory.eventDuplicateID.rawValue)"
        case .eventStoreUnavailable:
            return "Event store failure: \(EventStoreFailureCategory.eventStoreUnavailable.rawValue)"
        case .eventStoreCorrupt:
            return "Event store failure: \(EventStoreFailureCategory.eventStoreCorrupt.rawValue)"
        case .eventTransactionFailed:
            return "Event store failure: \(EventStoreFailureCategory.eventTransactionFailed.rawValue)"
        }
    }
}
