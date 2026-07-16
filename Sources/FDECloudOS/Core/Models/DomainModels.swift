import Foundation

enum UserRole: String, Codable, CaseIterable, Identifiable, Sendable {
    case admin = "Admin"
    case fde = "FDE"
    case user = "User"

    var id: String { rawValue }
}

enum WorkspaceExecutionScope: String, Codable, CaseIterable, Identifiable, Sendable {
    case singleNode = "single_node"
    case multiNodePrepared = "multi_node_prepared"

    var id: String { rawValue }
}

enum WorkspaceDistributionPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case localOnly = "local_only"
    case metadataOnly = "metadata_only"

    var id: String { rawValue }
}

struct WorkspaceDistributionMetadata: Codable, Hashable, Sendable {
    var allowedNodes: [String]
    var executionScope: WorkspaceExecutionScope
    var distributionPolicy: WorkspaceDistributionPolicy
}

struct Workspace: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var orgID: UUID
    var displayName: String
    var role: UserRole
    var localDataNamespace: String
    var policyNamespace: String
    var memoryNamespace: String
    var eventNamespace: String
    var localProjectRoot: String?
    var localAgentProjectRoot: String?
    var allowedNodes: [String]
    var executionScope: WorkspaceExecutionScope
    var distributionPolicy: WorkspaceDistributionPolicy
    var createdAt: Date

    init(
        id: UUID,
        name: String,
        role: UserRole,
        createdAt: Date,
        orgID: UUID? = nil,
        displayName: String? = nil,
        localDataNamespace: String? = nil,
        policyNamespace: String? = nil,
        memoryNamespace: String? = nil,
        eventNamespace: String? = nil,
        localProjectRoot: String? = nil,
        localAgentProjectRoot: String? = nil,
        allowedNodes: [String]? = nil,
        executionScope: WorkspaceExecutionScope = .singleNode,
        distributionPolicy: WorkspaceDistributionPolicy = .localOnly
    ) {
        self.id = id
        self.name = name
        self.orgID = orgID ?? id
        self.displayName = displayName ?? name
        self.role = role
        self.localDataNamespace = localDataNamespace ?? Self.namespace("local", workspaceID: id)
        self.policyNamespace = policyNamespace ?? Self.namespace("policy", workspaceID: id)
        self.memoryNamespace = memoryNamespace ?? Self.namespace("memory", workspaceID: id)
        self.eventNamespace = eventNamespace ?? Self.namespace("event", workspaceID: id)
        self.localProjectRoot = Self.normalizedProjectRoot(localProjectRoot)
        self.localAgentProjectRoot = Self.normalizedProjectRoot(localAgentProjectRoot)
        self.allowedNodes = allowedNodes ?? ["local-node-placeholder"]
        self.executionScope = executionScope
        self.distributionPolicy = distributionPolicy
        self.createdAt = createdAt
    }

    static func `default`() -> Workspace {
        Workspace(id: UUID(), name: "Local Field Workspace", role: .fde, createdAt: Date())
    }

    var distributionMetadata: WorkspaceDistributionMetadata {
        WorkspaceDistributionMetadata(
            allowedNodes: allowedNodes,
            executionScope: executionScope,
            distributionPolicy: distributionPolicy
        )
    }

    var hasLocalProjectScope: Bool {
        localProjectRoot != nil
    }

    var hasAgentProjectScope: Bool {
        localAgentProjectRoot != nil
    }

    var hasIntegrationProjectScope: Bool {
        hasLocalProjectScope && hasAgentProjectScope
    }

    var localProjectRootURL: URL? {
        guard let localProjectRoot else { return nil }
        return URL(fileURLWithPath: localProjectRoot, isDirectory: true).standardizedFileURL
    }

    var localAgentProjectRootURL: URL? {
        guard let localAgentProjectRoot else { return nil }
        return URL(fileURLWithPath: localAgentProjectRoot, isDirectory: true).standardizedFileURL
    }

    var localProjectScopeRootURLs: [URL] {
        [localProjectRootURL, localAgentProjectRootURL].compactMap { $0 }
    }

    private static func namespace(_ prefix: String, workspaceID: UUID) -> String {
        "\(prefix):\(workspaceID.uuidString.lowercased())"
    }

    private static func normalizedProjectRoot(_ path: String?) -> String? {
        guard let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed, isDirectory: true).standardizedFileURL.path
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case orgID = "org_id"
        case displayName = "display_name"
        case role
        case localDataNamespace = "local_data_namespace"
        case policyNamespace = "policy_namespace"
        case memoryNamespace = "memory_namespace"
        case eventNamespace = "event_namespace"
        case localProjectRoot = "local_project_root"
        case localAgentProjectRoot = "local_agent_project_root"
        case allowedNodes = "allowed_nodes"
        case executionScope = "execution_scope"
        case distributionPolicy = "distribution_policy"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let role = try container.decode(UserRole.self, forKey: .role)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.init(
            id: id,
            name: name,
            role: role,
            createdAt: createdAt,
            orgID: try container.decodeIfPresent(UUID.self, forKey: .orgID),
            displayName: try container.decodeIfPresent(String.self, forKey: .displayName),
            localDataNamespace: try container.decodeIfPresent(String.self, forKey: .localDataNamespace),
            policyNamespace: try container.decodeIfPresent(String.self, forKey: .policyNamespace),
            memoryNamespace: try container.decodeIfPresent(String.self, forKey: .memoryNamespace),
            eventNamespace: try container.decodeIfPresent(String.self, forKey: .eventNamespace),
            localProjectRoot: try container.decodeIfPresent(String.self, forKey: .localProjectRoot),
            localAgentProjectRoot: try container.decodeIfPresent(String.self, forKey: .localAgentProjectRoot),
            allowedNodes: try container.decodeIfPresent([String].self, forKey: .allowedNodes),
            executionScope: try container.decodeIfPresent(WorkspaceExecutionScope.self, forKey: .executionScope) ?? .singleNode,
            distributionPolicy: try container.decodeIfPresent(WorkspaceDistributionPolicy.self, forKey: .distributionPolicy) ?? .localOnly
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(orgID, forKey: .orgID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(role, forKey: .role)
        try container.encode(localDataNamespace, forKey: .localDataNamespace)
        try container.encode(policyNamespace, forKey: .policyNamespace)
        try container.encode(memoryNamespace, forKey: .memoryNamespace)
        try container.encode(eventNamespace, forKey: .eventNamespace)
        try container.encodeIfPresent(localProjectRoot, forKey: .localProjectRoot)
        try container.encodeIfPresent(localAgentProjectRoot, forKey: .localAgentProjectRoot)
        try container.encode(allowedNodes, forKey: .allowedNodes)
        try container.encode(executionScope, forKey: .executionScope)
        try container.encode(distributionPolicy, forKey: .distributionPolicy)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

enum TaskState: String, Codable, CaseIterable, Identifiable, Sendable {
    case created = "CREATED"
    case planned = "PLANNED"
    case running = "RUNNING"
    case waiting = "WAITING"
    case pendingApproval = "PENDING_APPROVAL"
    case blocked = "BLOCKED"
    case failed = "FAILED"
    case completed = "COMPLETED"
    case replayed = "REPLAYED"

    var id: String { rawValue }
}

struct FDETask: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let workspaceID: UUID
    var title: String
    var rawInput: String
    var state: TaskState
    var plan: [PlanStep]
    var riskScore: Double
    var failureProbability: Double
    var performanceScore: Double
    var createdAt: Date
    var updatedAt: Date
}

enum PlanStepKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case tool
    case reasoning
    case finalization
    case clarification
    case blocker

    var id: String { rawValue }
}

struct PlanStep: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var intent: String
    var kind: PlanStepKind
    var toolCallID: String?
    var requiresApproval: Bool
    var retryBudget: Int

    init(
        id: String,
        title: String,
        intent: String,
        kind: PlanStepKind? = nil,
        toolCallID: String?,
        requiresApproval: Bool,
        retryBudget: Int = 0
    ) {
        self.id = id
        self.title = title
        self.intent = intent
        self.kind = kind ?? (toolCallID == nil ? .reasoning : .tool)
        self.toolCallID = toolCallID
        self.requiresApproval = requiresApproval
        self.retryBudget = retryBudget
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case intent
        case kind
        case toolCallID
        case requiresApproval
        case retryBudget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        intent = try container.decode(String.self, forKey: .intent)
        toolCallID = try container.decodeIfPresent(String.self, forKey: .toolCallID)
        kind = try container.decodeIfPresent(PlanStepKind.self, forKey: .kind)
            ?? (toolCallID == nil ? .reasoning : .tool)
        requiresApproval = try container.decode(Bool.self, forKey: .requiresApproval)
        retryBudget = try container.decodeIfPresent(Int.self, forKey: .retryBudget) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(intent, forKey: .intent)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(toolCallID, forKey: .toolCallID)
        try container.encode(requiresApproval, forKey: .requiresApproval)
        try container.encode(retryBudget, forKey: .retryBudget)
    }
}

struct AgentAction: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var agent: AgentKind
    var stepID: String?
}

enum AgentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case planner = "Planner Agent"
    case executor = "Executor Agent"
    case systemUnderstanding = "System Understanding Agent"
    case recovery = "Recovery Agent"
    case policy = "Policy Agent"

    var id: String { rawValue }
}

enum ToolType: String, Codable, CaseIterable, Identifiable, Sendable {
    case shell = "shell"
    case appleScript = "apple_script"
    case api = "api"
    case connector = "connector"

    var id: String { rawValue }
}

struct ToolCall: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var type: ToolType
    var command: String
    var arguments: [String]
    var workingDirectory: String?
    var requiresApproval: Bool

    enum CodingKeys: String, CodingKey {
        case id, type, command, arguments, workingDirectory, requiresApproval
    }

    init(
        id: String,
        type: ToolType,
        command: String,
        arguments: [String],
        workingDirectory: String?,
        requiresApproval: Bool
    ) {
        self.id = id
        self.type = type
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.requiresApproval = requiresApproval
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(ToolType.self, forKey: .type)
        command = try container.decode(String.self, forKey: .command)
        arguments = try container.decode(FlexibleToolArguments.self, forKey: .arguments).values
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        requiresApproval = try container.decode(Bool.self, forKey: .requiresApproval)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encode(command, forKey: .command)
        try container.encode(arguments, forKey: .arguments)
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        try container.encode(requiresApproval, forKey: .requiresApproval)
    }
}

private struct FlexibleToolArguments: Decodable {
    let values: [String]

    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            var result: [String] = []
            while !array.isAtEnd {
                result.append(try array.decode(String.self))
            }
            values = result
            return
        }
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            values = [single]
            return
        }

        let object = try decoder.container(keyedBy: DynamicToolArgumentKey.self)
        var result: [String] = []
        for key in object.allKeys.sorted(by: { $0.stringValue < $1.stringValue }) {
            if key.stringValue == "arguments" {
                result.append(contentsOf: try object.decode(FlexibleToolArguments.self, forKey: key).values)
            } else {
                let value = try object.decode(String.self, forKey: key)
                result.append("\(key.stringValue)=\(value)")
            }
        }
        values = result
    }
}

private struct DynamicToolArgumentKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

struct RiskSignal: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var severity: RiskSeverity
    var mitigation: String
}

enum RiskSeverity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case critical

    var id: String { rawValue }
}

struct StructuredAgentOutput: Codable, Hashable, Sendable {
    var plan: [PlanStep]
    var actions: [AgentAction]
    var toolCalls: [ToolCall]
    var risks: [RiskSignal]
    var confidence: Double

    enum CodingKeys: String, CodingKey {
        case plan
        case actions
        case toolCalls = "tool_calls"
        case risks
        case confidence
    }
}

enum EventType: String, Codable, CaseIterable, Identifiable, Sendable {
    case taskCreated = "TASK_CREATED"
    case contextCompiled = "CONTEXT_COMPILED"
    case planGenerated = "PLAN_GENERATED"
    case stepExecuted = "STEP_EXECUTED"
    case toolCalled = "TOOL_CALLED"
    case toolFailed = "TOOL_FAILED"
    case connectorCalled = "CONNECTOR_CALLED"
    case connectorDryRun = "CONNECTOR_DRY_RUN"
    case connectorExecuted = "CONNECTOR_EXECUTED"
    case connectorFailed = "CONNECTOR_FAILED"
    case recoveryAttempted = "RECOVERY_ATTEMPTED"
    case humanApprovalRequested = "HUMAN_APPROVAL_REQUESTED"
    case stateUpdated = "STATE_UPDATED"
    case taskCompleted = "TASK_COMPLETED"
    case feedbackGenerated = "FEEDBACK_GENERATED"
    case policyUpdated = "POLICY_UPDATED"
    case humanApproved = "HUMAN_APPROVED"
    case humanRejected = "HUMAN_REJECTED"
    case sessionStarted = "SESSION_STARTED"
    case sessionEnded = "SESSION_ENDED"
    case workspaceSwitched = "WORKSPACE_SWITCHED"
    case authorizationDenied = "AUTHORIZATION_DENIED"
    case roleChanged = "ROLE_CHANGED"
    case routingDecisionMade = "ROUTING_DECISION_MADE"
    case nodeSelected = "NODE_SELECTED"
    case executionTargetAssigned = "EXECUTION_TARGET_ASSIGNED"
    case nodeExecutionStarted = "NODE_EXECUTION_STARTED"
    case nodeExecutionCompleted = "NODE_EXECUTION_COMPLETED"
    case nodeExecutionFailed = "NODE_EXECUTION_FAILED"
    case executionDispatched = "EXECUTION_DISPATCHED"
    case executionReceived = "EXECUTION_RECEIVED"
    case executionResponseReceived = "EXECUTION_RESPONSE_RECEIVED"
    case workerRegistered = "WORKER_REGISTERED"
    case workerTaskReceived = "WORKER_TASK_RECEIVED"
    case workerTaskCompleted = "WORKER_TASK_COMPLETED"
    case workerTaskFailed = "WORKER_TASK_FAILED"
    case userMessageReceived = "USER_MESSAGE_RECEIVED"
    case userDecisionSelected = "USER_DECISION_SELECTED"
    case userApprovalGranted = "USER_APPROVAL_GRANTED"
    case userApprovalRejected = "USER_APPROVAL_REJECTED"

    var id: String { rawValue }
}

enum EventClassification: String, Codable, CaseIterable, Identifiable, Sendable {
    case localOnly = "LOCAL_ONLY"
    case distributable = "DISTRIBUTABLE"
    case systemOnly = "SYSTEM_ONLY"

    var id: String { rawValue }

    static func classify(eventType: EventType) -> EventClassification {
        switch eventType {
        case .sessionStarted,
             .sessionEnded,
             .workspaceSwitched,
             .roleChanged,
             .routingDecisionMade,
             .nodeSelected,
             .executionTargetAssigned,
             .nodeExecutionStarted,
             .nodeExecutionCompleted,
             .nodeExecutionFailed,
             .executionDispatched,
             .executionReceived,
             .executionResponseReceived,
             .workerRegistered,
             .workerTaskReceived,
             .workerTaskCompleted,
             .workerTaskFailed,
             .userMessageReceived,
             .userDecisionSelected,
             .userApprovalGranted,
             .userApprovalRejected:
            return .systemOnly
        case .connectorDryRun:
            return .localOnly
        default:
            return .distributable
        }
    }
}

struct EventMetadata: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var nodeID: String?
    var correlationID: String
    var distributedReady: Bool
    var eventClassification: EventClassification
    var cloudRoutingEnabled: Bool

    init(
        workspaceID: UUID,
        nodeID: String? = nil,
        correlationID: String,
        distributedReady: Bool = true,
        eventClassification: EventClassification = .distributable,
        cloudRoutingEnabled: Bool = false
    ) {
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.correlationID = correlationID
        self.distributedReady = distributedReady
        self.eventClassification = eventClassification
        self.cloudRoutingEnabled = cloudRoutingEnabled
    }

    init(payload: [String: String], workspaceID: UUID, taskID: UUID?, eventType: EventType? = nil) {
        let payloadNodeID = payload["node_id"].flatMap { $0.isEmpty ? nil : $0 }
        let payloadCorrelationID = payload["correlation_id"].flatMap { $0.isEmpty ? nil : $0 }
        let payloadDistributedReady = payload["distributed_ready"].map { $0 == "true" }
        let payloadClassification = payload["event_classification"].flatMap(EventClassification.init(rawValue:))
        let payloadCloudRoutingEnabled = payload["cloud_routing_enabled"].map { $0 == "true" }

        self.init(
            workspaceID: workspaceID,
            nodeID: payloadNodeID,
            correlationID: payloadCorrelationID ?? taskID?.uuidString ?? workspaceID.uuidString,
            distributedReady: payloadDistributedReady ?? true,
            eventClassification: payloadClassification ?? eventType.map(EventClassification.classify(eventType:)) ?? .distributable,
            cloudRoutingEnabled: payloadCloudRoutingEnabled ?? false
        )
    }

    func enriching(_ payload: [String: String]) -> [String: String] {
        var enrichedPayload = payload
        enrichedPayload["workspace_id"] = workspaceID.uuidString
        enrichedPayload["node_id"] = nodeID ?? ""
        enrichedPayload["correlation_id"] = correlationID
        enrichedPayload["distributed_ready"] = distributedReady ? "true" : "false"
        enrichedPayload["event_classification"] = eventClassification.rawValue
        enrichedPayload["cloud_routing_enabled"] = cloudRoutingEnabled ? "true" : "false"
        return enrichedPayload
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case correlationID = "correlation_id"
        case distributedReady = "distributed_ready"
        case eventClassification = "event_classification"
        case cloudRoutingEnabled = "cloud_routing_enabled"
    }
}

struct ExecutionEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var parentEventID: UUID?
    var workspaceID: UUID
    var taskID: UUID?
    var type: EventType
    var sequence: Int64
    var timestamp: Date
    var summary: String
    var payload: [String: String]
    var metadata: EventMetadata

    init(
        id: UUID,
        parentEventID: UUID?,
        workspaceID: UUID,
        taskID: UUID?,
        type: EventType,
        sequence: Int64,
        timestamp: Date,
        summary: String,
        payload: [String: String],
        metadata: EventMetadata? = nil
    ) {
        let resolvedMetadata = metadata ?? EventMetadata(payload: payload, workspaceID: workspaceID, taskID: taskID, eventType: type)
        self.id = id
        self.parentEventID = parentEventID
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.type = type
        self.sequence = sequence
        self.timestamp = timestamp
        self.summary = summary
        self.metadata = resolvedMetadata
        self.payload = resolvedMetadata.enriching(payload)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case parentEventID
        case workspaceID
        case taskID
        case type
        case sequence
        case timestamp
        case summary
        case payload
        case metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let parentEventID = try container.decodeIfPresent(UUID.self, forKey: .parentEventID)
        let workspaceID = try container.decode(UUID.self, forKey: .workspaceID)
        let taskID = try container.decodeIfPresent(UUID.self, forKey: .taskID)
        let payload = try container.decode([String: String].self, forKey: .payload)
        let metadata = try container.decodeIfPresent(EventMetadata.self, forKey: .metadata)
        self.init(
            id: id,
            parentEventID: parentEventID,
            workspaceID: workspaceID,
            taskID: taskID,
            type: try container.decode(EventType.self, forKey: .type),
            sequence: try container.decode(Int64.self, forKey: .sequence),
            timestamp: try container.decode(Date.self, forKey: .timestamp),
            summary: try container.decode(String.self, forKey: .summary),
            payload: payload,
            metadata: metadata
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(parentEventID, forKey: .parentEventID)
        try container.encode(workspaceID, forKey: .workspaceID)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encode(type, forKey: .type)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(summary, forKey: .summary)
        try container.encode(payload, forKey: .payload)
        try container.encode(metadata, forKey: .metadata)
    }
}

enum ApprovalState: String, Codable, CaseIterable, Identifiable, Sendable {
    case pending
    case approved
    case rejected
    case expired

    var id: String { rawValue }
}

enum ApprovalTargetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case toolCall
    case policyUpdate
    case connectorOperation
    case systemChange

    var id: String { rawValue }
}

struct ApprovalRequest: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID?
    var stepID: String?
    var toolCallID: String?
    var targetKind: ApprovalTargetKind
    var action: String
    var resource: String
    var riskLevel: RiskSeverity
    var state: ApprovalState
    var requestedByRole: UserRole
    var decidedByRole: UserRole?
    var decisionReason: String?
    var requestedAt: Date
    var decidedAt: Date?
    var expiresAt: Date?
    var metadata: [String: String]
}

struct RiskClassification: Codable, Hashable, Sendable {
    var level: RiskSeverity
    var reasons: [String]
    var requiresApproval: Bool
}

enum GraphNodeType: String, Codable, CaseIterable, Identifiable, Sendable {
    case app
    case file
    case api
    case task
    case agent

    var id: String { rawValue }
}

struct SystemGraphNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var type: GraphNodeType
    var title: String
    var subtitle: String
    var metadata: [String: String]
    var updatedAt: Date
}

enum GraphEdgeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case dependency
    case executionFlow = "execution_flow"
    case dataFlow = "data_flow"

    var id: String { rawValue }
}

struct SystemGraphEdge: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var fromNodeID: String
    var toNodeID: String
    var kind: GraphEdgeKind
    var label: String
    var updatedAt: Date
}

struct RealityAssessment: Codable, Hashable, Sendable {
    var realityRiskScore: Double
    var failureProbability: Double
    var mitigations: [String]
}

struct OutcomeMetrics: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var taskSuccessRate: Double
    var retryRate: Double
    var rollbackRate: Double
    var humanInterventionRate: Double
    var integrationSuccessScore: Double
    var fdePerformanceScore: Double
    var createdAt: Date
}

enum FeedbackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bugReport = "Bug Report"
    case productGap = "Product Gap"
    case missingIntegration = "Missing Integration"
    case roadmapSuggestion = "Roadmap Suggestion"
    case testPlan = "Test Plan"
    case codePatch = "Code Patch"
    case verificationReport = "Verification Report"

    var id: String { rawValue }
}

struct FeedbackInsight: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID?
    var kind: FeedbackKind
    var title: String
    var detail: String
    var createdAt: Date
}

enum PolicyAdjustmentKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case avoidFailedTool = "AVOID_FAILED_TOOL"
    case stabilizeSuccessfulPlan = "STABILIZE_SUCCESSFUL_PLAN"

    var id: String { rawValue }
}

struct ExecutionPolicyDelta: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var sourceTaskID: UUID?
    var parentEventID: UUID?
    var kind: PolicyAdjustmentKind
    var taskFingerprint: String
    var failureSignature: String?
    var avoidToolCommand: String?
    var replacementToolCommand: String?
    var retryBudget: Int
    var reorderCheckpointBeforeRiskyTool: Bool
    var summary: String
    var createdAt: Date
}

struct ExecutionFailurePattern: Codable, Hashable, Sendable {
    var command: String
    var toolCallID: String
    var count: Int
    var latestSummary: String
}

struct TaskExecutionMemory: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var taskFingerprint: String
    var taskType: String
    var state: TaskState
    var planStepCount: Int
    var toolCommands: [String]
    var failedCommands: [String]
    var failureSignatures: [String]
    var riskScore: Double
    var performanceScore: Double
    var createdAt: Date
}

enum FailureClusterCause: String, Codable, CaseIterable, Identifiable, Sendable {
    case toolExecution = "TOOL_EXECUTION"
    case api = "API"
    case permission = "PERMISSION"
    case approval = "APPROVAL"
    case unknown = "UNKNOWN"

    var id: String { rawValue }
}

struct FailureCluster: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var signature: String
    var taskType: String
    var cause: FailureClusterCause
    var toolCommand: String?
    var frequency: Int
    var affectedTaskIDs: [UUID]
    var latestSummary: String
    var firstSeenAt: Date
    var lastSeenAt: Date
}

struct SystemFailureProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var clusters: [FailureCluster]
    var recurringSignatures: [String]
    var taskTypeFailureCounts: [String: Int]
    var generatedAt: Date
}

enum SystemInsightKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case recurringFailure = "RECURRING_FAILURE"
    case taskTypeRisk = "TASK_TYPE_RISK"
    case toolReliability = "TOOL_RELIABILITY"
    case learningCurve = "LEARNING_CURVE"

    var id: String { rawValue }
}

struct SystemLevelInsight: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var kind: SystemInsightKind
    var taskType: String
    var failureSignature: String?
    var title: String
    var detail: String
    var frequency: Int
    var createdAt: Date
}

struct LearningEffectPoint: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var taskType: String
    var executionIndex: Int
    var performanceScore: Double
    var failureCount: Int
    var movingAveragePerformance: Double
    var createdAt: Date
}

struct GlobalExecutionPolicy: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var avoidedToolCommands: [String]
    var toolPreferences: [String: String]
    var defaultRetryBudget: Int
    var decompositionDepth: Int
    var checkpointBeforeInspection: Bool
    var sourceInsightIDs: [UUID]
    var sourceClusterSignatures: [String]
    var learningEffectCurve: [LearningEffectPoint]
    var summary: String
    var createdAt: Date
}

enum GlobalOptimizationGoal: String, Codable, CaseIterable, Identifiable, Sendable {
    case maximizePerformance = "MAXIMIZE_PERFORMANCE"
    case minimizeFailureRate = "MINIMIZE_FAILURE_RATE"
    case stabilizeLearning = "STABILIZE_LEARNING"

    var id: String { rawValue }
}

struct GlobalPerformanceObjective: Codable, Hashable, Sendable {
    var goal: GlobalOptimizationGoal
    var targetEfficiencyScore: Double
    var maximumFailureRate: Double
    var minimumLearningGradient: Double
}

enum LearningTrend: String, Codable, CaseIterable, Identifiable, Sendable {
    case improving = "IMPROVING"
    case flat = "FLAT"
    case regressing = "REGRESSING"

    var id: String { rawValue }
}

struct LearningCurveGradient: Codable, Hashable, Sendable {
    var value: Double
    var trend: LearningTrend
    var sampleCount: Int
}

struct SystemEfficiencyScore: Codable, Hashable, Sendable {
    var score: Double
    var averagePerformance: Double
    var failureRate: Double
    var globalPolicyCompliance: Double
}

enum GovernorStrategy: String, Codable, CaseIterable, Identifiable, Sendable {
    case plannerPreferred = "PLANNER_PREFERRED"
    case globalPolicyPreferred = "GLOBAL_POLICY_PREFERRED"
    case conservativeRecovery = "CONSERVATIVE_RECOVERY"

    var id: String { rawValue }
}

enum GovernorOverrideKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case replaceAvoidedTool = "REPLACE_AVOIDED_TOOL"
    case raiseRetryBudget = "RAISE_RETRY_BUDGET"
    case insertPreflightConstraint = "INSERT_PREFLIGHT_CONSTRAINT"
    case reorderCheckpoint = "REORDER_CHECKPOINT"

    var id: String { rawValue }
}

struct GovernorOverride: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: GovernorOverrideKind
    var targetID: String
    var before: String
    var after: String
    var reason: String
}

struct StrategyArbitrationDecision: Codable, Hashable, Sendable {
    var selectedStrategy: GovernorStrategy
    var objective: GlobalPerformanceObjective
    var learningGradient: LearningCurveGradient
    var efficiencyScore: SystemEfficiencyScore
    var reasons: [String]
}

struct GlobalGovernorDecision: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var taskID: UUID
    var selectedStrategy: GovernorStrategy
    var objective: GlobalPerformanceObjective
    var learningGradient: LearningCurveGradient
    var efficiencyScore: SystemEfficiencyScore
    var overrides: [GovernorOverride]
    var approved: Bool
    var summary: String
    var createdAt: Date
}

struct ReplayFrame: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var sequence: Int64
    var timestamp: Date
    var title: String
    var state: TaskState?
    var graphNodeCount: Int
    var graphEdgeCount: Int
}

struct ToolExecutionResult: Codable, Hashable, Sendable {
    var callID: String
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
    var duration: TimeInterval
    var emittedEvents: [ToolExecutionEvent] = []
}

struct ToolExecutionEvent: Codable, Hashable, Sendable {
    var type: EventType
    var summary: String
    var payload: [String: String]
}

struct SessionCredential: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var workspaceID: UUID
    var subject: String
    var provider: String
    var issuedAt: Date
}
