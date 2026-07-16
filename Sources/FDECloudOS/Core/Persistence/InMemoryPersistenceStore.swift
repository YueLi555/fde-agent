import Foundation

actor InMemoryPersistenceStore: PersistenceStore {
    private var workspaces: [UUID: Workspace] = [:]
    private var tasks: [UUID: FDETask] = [:]
    private var events: [ExecutionEvent] = []
    private var nodes: [String: SystemGraphNode] = [:]
    private var edges: [String: SystemGraphEdge] = [:]
    private var outcomes: [OutcomeMetrics] = []
    private var feedback: [FeedbackInsight] = []
    private var policyDeltas: [ExecutionPolicyDelta] = []
    private var executionMemory: [UUID: TaskExecutionMemory] = [:]
    private var failureProfiles: [SystemFailureProfile] = []
    private var systemInsights: [SystemLevelInsight] = []
    private var globalPolicies: [GlobalExecutionPolicy] = []
    private var governorDecisions: [GlobalGovernorDecision] = []
    private var sessionMetadata: SessionMetadata?
    private var approvalRequests: [UUID: ApprovalRequest] = [:]

    func initialize() async throws {}

    func loadWorkspaces() async throws -> [Workspace] {
        workspaces.values.sorted { $0.createdAt < $1.createdAt }
    }

    func saveWorkspace(_ workspace: Workspace) async throws {
        workspaces[workspace.id] = workspace
    }

    func saveSessionMetadata(_ metadata: SessionMetadata) async throws {
        sessionMetadata = metadata
    }

    func loadSessionMetadata() async throws -> SessionMetadata? {
        sessionMetadata
    }

    func clearSessionMetadata() async throws {
        sessionMetadata = nil
    }

    func loadTasks(workspaceID: UUID) async throws -> [FDETask] {
        tasks.values
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveTask(_ task: FDETask) async throws {
        tasks[task.id] = task
    }

    func appendEvent(_ event: ExecutionEvent) async throws {
        events.append(event)
    }

    func loadEvents(workspaceID: UUID, taskID: UUID?) async throws -> [ExecutionEvent] {
        events
            .filter { event in
                event.workspaceID == workspaceID && (taskID == nil || event.taskID == taskID)
            }
            .sorted { lhs, rhs in
                if lhs.sequence == rhs.sequence {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.sequence < rhs.sequence
            }
    }

    func loadMaxEventSequence() async throws -> Int64 {
        events.map(\.sequence).max() ?? 0
    }

    func saveApprovalRequest(_ request: ApprovalRequest) async throws {
        approvalRequests[request.id] = request
    }

    func loadApprovalRequest(id: UUID) async throws -> ApprovalRequest? {
        approvalRequests[id]
    }

    func loadApprovalRequests(workspaceID: UUID?, state: ApprovalState?) async throws -> [ApprovalRequest] {
        approvalRequests.values
            .filter { request in
                (workspaceID == nil || request.workspaceID == workspaceID)
                    && (state == nil || request.state == state)
            }
            .sorted { $0.requestedAt < $1.requestedAt }
    }

    func saveGraph(nodes newNodes: [SystemGraphNode], edges newEdges: [SystemGraphEdge]) async throws {
        for node in newNodes {
            nodes[node.id] = node
        }
        for edge in newEdges {
            edges[edge.id] = edge
        }
    }

    func loadGraph(workspaceID: UUID) async throws -> ([SystemGraphNode], [SystemGraphEdge]) {
        let workspaceNodes = nodes.values
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.title < $1.title }
        let workspaceEdges = edges.values
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.id < $1.id }
        return (workspaceNodes, workspaceEdges)
    }

    func saveOutcome(_ outcome: OutcomeMetrics) async throws {
        outcomes.append(outcome)
    }

    func loadLatestOutcome(workspaceID: UUID) async throws -> OutcomeMetrics? {
        outcomes
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func saveFeedback(_ feedbackItem: FeedbackInsight) async throws {
        feedback.append(feedbackItem)
    }

    func loadFeedback(workspaceID: UUID) async throws -> [FeedbackInsight] {
        feedback
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func savePolicyDelta(_ delta: ExecutionPolicyDelta) async throws {
        policyDeltas.append(delta)
    }

    func loadPolicyDeltas(workspaceID: UUID) async throws -> [ExecutionPolicyDelta] {
        policyDeltas
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func saveTaskExecutionMemory(_ memory: TaskExecutionMemory) async throws {
        executionMemory[memory.taskID] = memory
    }

    func loadTaskExecutionMemory(workspaceID: UUID) async throws -> [TaskExecutionMemory] {
        executionMemory.values
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func saveSystemFailureProfile(_ profile: SystemFailureProfile) async throws {
        failureProfiles.append(profile)
    }

    func loadLatestSystemFailureProfile(workspaceID: UUID) async throws -> SystemFailureProfile? {
        failureProfiles
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.generatedAt > $1.generatedAt }
            .first
    }

    func saveSystemInsight(_ insight: SystemLevelInsight) async throws {
        systemInsights.append(insight)
    }

    func loadSystemInsights(workspaceID: UUID) async throws -> [SystemLevelInsight] {
        systemInsights
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func saveGlobalExecutionPolicy(_ policy: GlobalExecutionPolicy) async throws {
        globalPolicies.append(policy)
    }

    func loadLatestGlobalExecutionPolicy(workspaceID: UUID) async throws -> GlobalExecutionPolicy? {
        globalPolicies
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt > $1.createdAt }
            .first
    }

    func saveGlobalGovernorDecision(_ decision: GlobalGovernorDecision) async throws {
        governorDecisions.append(decision)
    }

    func loadGlobalGovernorDecisions(workspaceID: UUID) async throws -> [GlobalGovernorDecision] {
        governorDecisions
            .filter { $0.workspaceID == workspaceID }
            .sorted { $0.createdAt > $1.createdAt }
    }
}
