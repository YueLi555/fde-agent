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
    func appendEvent(_ event: ExecutionEvent) async throws
    func loadEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent]
    func loadMaxEventSequence() async throws -> Int64
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

enum PersistenceError: LocalizedError {
    case databaseUnavailable(String)
    case encodingFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable(let detail):
            return "Database unavailable: \(detail)"
        case .encodingFailed(let detail):
            return "Encoding failed: \(detail)"
        case .decodingFailed(let detail):
            return "Decoding failed: \(detail)"
        }
    }
}
