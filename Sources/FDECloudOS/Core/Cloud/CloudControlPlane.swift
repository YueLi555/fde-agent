import Foundation

enum LogicalNodeType: String, Codable, CaseIterable, Identifiable, Sendable {
    case macNode = "MacNode"
    case cloudNode = "CloudNode"
    case agentNode = "AgentNode"
    case workerNode = "WorkerNode"

    var id: String { rawValue }
}

enum LogicalNodeCapacity: String, Codable, CaseIterable, Identifiable, Sendable {
    case constrainedLocal = "constrained_local"
    case elastic = "elastic"
    case orchestration = "orchestration"
    case batch = "batch"

    var id: String { rawValue }
}

enum LogicalNodeCost: String, Codable, CaseIterable, Identifiable, Sendable {
    case local = "local"
    case low = "low"
    case medium = "medium"
    case metered = "metered"

    var id: String { rawValue }
}

struct LogicalNode: Identifiable, Codable, Hashable, Sendable {
    static let localMacNodeID = "local-node-placeholder"
    static let cloudNodeID = "cloud-node-placeholder"
    static let agentNodeID = "agent-node-placeholder"
    static let workerNodeID = "worker-node-placeholder"

    let id: String
    var type: LogicalNodeType
    var workspaceID: UUID?
    var displayName: String
    var metadata: [String: String]
    var capacity: LogicalNodeCapacity = .constrainedLocal
    var simulatedLatencyMilliseconds: Int = 5
    var logicalCost: LogicalNodeCost = .local
    var available: Bool = true

    var routingMetadata: [String: String] {
        metadata.merging(
            [
                "node_type": type.rawValue,
                "capacity": capacity.rawValue,
                "simulated_latency_ms": String(simulatedLatencyMilliseconds),
                "logical_cost": logicalCost.rawValue,
                "available": available ? "true" : "false"
            ]
        ) { current, _ in current }
    }

    static func currentMac(workspaceID: UUID? = nil) -> LogicalNode {
        LogicalNode(
            id: localMacNodeID,
            type: .macNode,
            workspaceID: workspaceID,
            displayName: "Local Mac Runtime",
            metadata: ["runtime": "single-node", "network": "disabled"],
            capacity: .constrainedLocal,
            simulatedLatencyMilliseconds: 5,
            logicalCost: .local,
            available: true
        )
    }

    static func futureCloud(workspaceID: UUID? = nil) -> LogicalNode {
        LogicalNode(
            id: cloudNodeID,
            type: .cloudNode,
            workspaceID: workspaceID,
            displayName: "Future Cloud Runtime",
            metadata: ["runtime": "future-cloud", "network": "disabled"],
            capacity: .elastic,
            simulatedLatencyMilliseconds: 80,
            logicalCost: .metered,
            available: true
        )
    }

    static func futureAgent(workspaceID: UUID? = nil) -> LogicalNode {
        LogicalNode(
            id: agentNodeID,
            type: .agentNode,
            workspaceID: workspaceID,
            displayName: "Future Agent Runtime",
            metadata: ["runtime": "future-agent", "network": "disabled"],
            capacity: .orchestration,
            simulatedLatencyMilliseconds: 20,
            logicalCost: .low,
            available: true
        )
    }

    static func futureWorker(workspaceID: UUID? = nil) -> LogicalNode {
        LogicalNode(
            id: workerNodeID,
            type: .workerNode,
            workspaceID: workspaceID,
            displayName: "Future Worker Runtime",
            metadata: ["runtime": "future-worker", "network": "disabled"],
            capacity: .batch,
            simulatedLatencyMilliseconds: 40,
            logicalCost: .medium,
            available: true
        )
    }
}

extension EventStreamNodeRegistration {
    init(node: LogicalNode) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            registeredAt: Date(timeIntervalSince1970: 0),
            metadata: node.routingMetadata
        )
    }
}

struct EventRoutingEnvelope: Identifiable, Sendable {
    var id: UUID { event.id }
    var event: ExecutionEvent
    var classification: EventClassification
    var cloudRoutingEnabled: Bool

    init(event: ExecutionEvent, cloudRoutingEnabled: Bool? = nil) {
        self.event = event
        self.classification = event.metadata.eventClassification
        self.cloudRoutingEnabled = cloudRoutingEnabled ?? event.metadata.cloudRoutingEnabled
    }
}

extension EventStream {
    func routingEnvelope(for event: ExecutionEvent, cloudRoutingEnabled: Bool? = nil) -> EventRoutingEnvelope {
        EventRoutingEnvelope(event: event, cloudRoutingEnabled: cloudRoutingEnabled)
    }
}

struct EventIngestionResult: Equatable, Sendable {
    var accepted: Bool
    var networkAttempted: Bool
    var reason: String

    static let disabled = EventIngestionResult(
        accepted: false,
        networkAttempted: false,
        reason: "Cloud event ingestion is a disabled foundation stub."
    )
}

protocol EventIngestionEndpoint: Sendable {
    func ingest(_ envelope: EventRoutingEnvelope) -> EventIngestionResult
}

struct StubEventIngestionEndpoint: EventIngestionEndpoint {
    func ingest(_ envelope: EventRoutingEnvelope) -> EventIngestionResult {
        .disabled
    }
}

protocol WorkspaceRegistry: Sendable {
    func register(_ workspace: Workspace)
    func distributionMetadata(workspaceID: UUID) -> WorkspaceDistributionMetadata?
}

struct NoOpWorkspaceRegistry: WorkspaceRegistry {
    func register(_ workspace: Workspace) {}
    func distributionMetadata(workspaceID: UUID) -> WorkspaceDistributionMetadata? {
        nil
    }
}

protocol NodeRegistry: EventStreamNodeRegistry {
    func register(_ node: LogicalNode)
    func node(id: String) -> LogicalNode?
}

struct NoOpNodeRegistry: NodeRegistry {
    func register(_ node: LogicalNode) {}
    func register(_ node: EventStreamNodeRegistration) {}
    func node(id: String) -> LogicalNode? {
        nil
    }
}

enum DistributionRoute: String, Codable, Sendable {
    case localRuntimeOnly = "local_runtime_only"
    case notRouted = "not_routed"
}

struct DistributionRouteDecision: Equatable, Sendable {
    var eventID: UUID
    var classification: EventClassification
    var cloudRoutingEnabled: Bool
    var route: DistributionRoute
    var targetNodeIDs: [String]
    var networkAttempted: Bool
    var reason: String
}

protocol DistributionRouter: Sendable {
    func route(_ envelope: EventRoutingEnvelope, workspace: Workspace) -> DistributionRouteDecision
}

struct NoOpDistributionRouter: DistributionRouter {
    func route(_ envelope: EventRoutingEnvelope, workspace: Workspace) -> DistributionRouteDecision {
        let targetNodes: [String]
        let route: DistributionRoute

        switch envelope.classification {
        case .systemOnly:
            targetNodes = []
            route = .notRouted
        case .localOnly, .distributable:
            targetNodes = [workspace.allowedNodes.first ?? LogicalNode.localMacNodeID]
            route = .localRuntimeOnly
        }

        return DistributionRouteDecision(
            eventID: envelope.event.id,
            classification: envelope.classification,
            cloudRoutingEnabled: envelope.cloudRoutingEnabled,
            route: route,
            targetNodeIDs: targetNodes,
            networkAttempted: false,
            reason: "Foundation router is no-op; cloud execution is disabled."
        )
    }
}

enum TaskComplexity: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high

    var id: String { rawValue }

    static func infer(planStepCount: Int, toolType: ToolType?) -> TaskComplexity {
        if planStepCount >= 5 {
            return .high
        }
        if planStepCount >= 3 || toolType == .connector || toolType == .api {
            return .medium
        }
        return .low
    }
}

struct ExecutionRoutingRequest: Equatable, Sendable {
    var workspace: Workspace
    var taskID: UUID?
    var taskComplexity: TaskComplexity
    var riskLevel: RiskSeverity
    var toolType: ToolType?
    var eventClassification: EventClassification
    var taskSummary: String

    init(
        workspace: Workspace,
        taskID: UUID? = nil,
        taskComplexity: TaskComplexity,
        riskLevel: RiskSeverity,
        toolType: ToolType? = nil,
        eventClassification: EventClassification,
        taskSummary: String = ""
    ) {
        self.workspace = workspace
        self.taskID = taskID
        self.taskComplexity = taskComplexity
        self.riskLevel = riskLevel
        self.toolType = toolType
        self.eventClassification = eventClassification
        self.taskSummary = taskSummary
    }
}

struct ExecutionRoutingDecision: Equatable, Sendable {
    var selectedNode: LogicalNode
    var fallbackNode: LogicalNode
    var reason: String
    var confidence: Double
    var taskComplexity: TaskComplexity
    var riskLevel: RiskSeverity
    var toolType: ToolType?
    var eventClassification: EventClassification
    var executionRemainsLocal: Bool
    var networkAttempted: Bool

    var payload: [String: String] {
        [
            "selected_node_id": selectedNode.id,
            "selected_node_type": selectedNode.type.rawValue,
            "fallback_node_id": fallbackNode.id,
            "fallback_node_type": fallbackNode.type.rawValue,
            "reason": reason,
            "confidence": String(confidence),
            "task_complexity": taskComplexity.rawValue,
            "risk_level": riskLevel.rawValue,
            "tool_type": toolType?.rawValue ?? "",
            "event_classification": eventClassification.rawValue,
            "execution_remains_local": executionRemainsLocal ? "true" : "false",
            "actual_execution_node_id": LogicalNode.localMacNodeID,
            "actual_execution_node_type": LogicalNodeType.macNode.rawValue,
            "network_attempted": networkAttempted ? "true" : "false",
            "selected_node_capacity": selectedNode.capacity.rawValue,
            "selected_node_latency_ms": String(selectedNode.simulatedLatencyMilliseconds),
            "selected_node_cost": selectedNode.logicalCost.rawValue,
            "selected_node_available": selectedNode.available ? "true" : "false"
        ]
    }
}

protocol ExecutionRouter: Sendable {
    func route(_ request: ExecutionRoutingRequest) -> ExecutionRoutingDecision
}

extension ExecutionRouter {
    func execute(
        _ toolCall: ToolCall,
        with decision: ExecutionRoutingDecision,
        nodeRuntime: any NodeExecutionRuntime,
        runtime: RuntimeKernel,
        workspaceID: UUID,
        taskID: UUID? = nil,
        stepID: String? = nil,
        simulateFailure: Bool = false
    ) async throws -> NodeExecutionResult {
        try await nodeRuntime.execute(
            NodeExecutionRequest(
                routingDecision: decision,
                toolCall: toolCall,
                workspaceID: workspaceID,
                taskID: taskID,
                stepID: stepID,
                simulateFailure: simulateFailure
            ),
            runtime: runtime
        )
    }
}

struct DeterministicExecutionRouter: ExecutionRouter {
    func route(_ request: ExecutionRoutingRequest) -> ExecutionRoutingDecision {
        let macNode = LogicalNode.currentMac(workspaceID: request.workspace.id)
        let fallbackNode = macNode

        if request.eventClassification == .localOnly {
            return decision(
                selectedNode: macNode,
                fallbackNode: fallbackNode,
                reason: "LOCAL_ONLY events are pinned to the current Mac runtime.",
                confidence: 1.0,
                request: request
            )
        }

        if request.workspace.distributionPolicy == .localOnly || request.workspace.executionScope == .singleNode {
            return decision(
                selectedNode: macNode,
                fallbackNode: fallbackNode,
                reason: "Workspace policy is local-only, so routing remains on MacNode.",
                confidence: 1.0,
                request: request
            )
        }

        if request.eventClassification == .systemOnly {
            let systemNode = request.taskComplexity == .high
                ? LogicalNode.futureWorker(workspaceID: request.workspace.id)
                : LogicalNode.futureAgent(workspaceID: request.workspace.id)
            return decision(
                selectedNode: allowed(systemNode, for: request.workspace, fallback: fallbackNode),
                fallbackNode: fallbackNode,
                reason: "SYSTEM_ONLY events route to logical control-plane nodes without execution.",
                confidence: request.taskComplexity == .high ? 0.82 : 0.86,
                request: request
            )
        }

        if request.riskLevel == .high {
            let agentNode = LogicalNode.futureAgent(workspaceID: request.workspace.id)
            return decision(
                selectedNode: allowed(agentNode, for: request.workspace, fallback: fallbackNode),
                fallbackNode: fallbackNode,
                reason: "High-risk work routes to AgentNode for logical oversight before local execution.",
                confidence: 0.78,
                request: request
            )
        }

        if request.toolType == .api || request.toolType == .connector || request.taskComplexity == .high {
            let cloudNode = LogicalNode.futureCloud(workspaceID: request.workspace.id)
            return decision(
                selectedNode: allowed(cloudNode, for: request.workspace, fallback: fallbackNode),
                fallbackNode: fallbackNode,
                reason: "Distributable high-complexity or integration work maps to CloudNode logically.",
                confidence: 0.84,
                request: request
            )
        }

        if request.taskComplexity == .medium {
            let workerNode = LogicalNode.futureWorker(workspaceID: request.workspace.id)
            return decision(
                selectedNode: allowed(workerNode, for: request.workspace, fallback: fallbackNode),
                fallbackNode: fallbackNode,
                reason: "Medium-complexity distributable work maps to WorkerNode logically.",
                confidence: 0.72,
                request: request
            )
        }

        return decision(
            selectedNode: macNode,
            fallbackNode: fallbackNode,
            reason: "Low-complexity work remains on MacNode.",
            confidence: 0.9,
            request: request
        )
    }

    private func allowed(_ node: LogicalNode, for workspace: Workspace, fallback: LogicalNode) -> LogicalNode {
        guard workspace.allowedNodes.contains(node.id) else {
            return fallback
        }
        return node
    }

    private func decision(
        selectedNode: LogicalNode,
        fallbackNode: LogicalNode,
        reason: String,
        confidence: Double,
        request: ExecutionRoutingRequest
    ) -> ExecutionRoutingDecision {
        ExecutionRoutingDecision(
            selectedNode: selectedNode,
            fallbackNode: fallbackNode,
            reason: reason,
            confidence: confidence,
            taskComplexity: request.taskComplexity,
            riskLevel: request.riskLevel,
            toolType: request.toolType,
            eventClassification: request.eventClassification,
            executionRemainsLocal: true,
            networkAttempted: false
        )
    }
}

protocol CloudControlPlane: Sendable {
    var eventIngestionEndpoint: any EventIngestionEndpoint { get }
    var workspaceRegistry: any WorkspaceRegistry { get }
    var nodeRegistry: any NodeRegistry { get }
    var distributionRouter: any DistributionRouter { get }
    var executionRouter: any ExecutionRouter { get }
    var nodeExecutionRuntime: any NodeExecutionRuntime { get }

    func registerWorkspace(_ workspace: Workspace)
    func registerNode(_ node: LogicalNode)
    func routeEvent(
        _ event: ExecutionEvent,
        workspace: Workspace,
        cloudRoutingEnabled: Bool?
    ) -> DistributionRouteDecision
    func routeExecution(_ request: ExecutionRoutingRequest) -> ExecutionRoutingDecision
    func executeRoutedTool(
        _ toolCall: ToolCall,
        decision: ExecutionRoutingDecision,
        runtime: RuntimeKernel,
        workspaceID: UUID,
        taskID: UUID?,
        stepID: String?,
        simulateFailure: Bool
    ) async throws -> NodeExecutionResult
}

extension CloudControlPlane {
    func routeEvent(_ event: ExecutionEvent, workspace: Workspace) -> DistributionRouteDecision {
        routeEvent(event, workspace: workspace, cloudRoutingEnabled: nil)
    }

    func routeExecution(_ request: ExecutionRoutingRequest) -> ExecutionRoutingDecision {
        executionRouter.route(request)
    }

    func executeRoutedTool(
        _ toolCall: ToolCall,
        decision: ExecutionRoutingDecision,
        runtime: RuntimeKernel,
        workspaceID: UUID,
        taskID: UUID? = nil,
        stepID: String? = nil,
        simulateFailure: Bool = false
    ) async throws -> NodeExecutionResult {
        try await executionRouter.execute(
            toolCall,
            with: decision,
            nodeRuntime: nodeExecutionRuntime,
            runtime: runtime,
            workspaceID: workspaceID,
            taskID: taskID,
            stepID: stepID,
            simulateFailure: simulateFailure
        )
    }

    @discardableResult
    func recordRoutingEvents(
        _ decision: ExecutionRoutingDecision,
        runtime: RuntimeKernel,
        workspaceID: UUID,
        taskID: UUID?
    ) async throws -> [ExecutionEvent] {
        let routingEvent = try await runtime.recordAuditEvent(
            type: .routingDecisionMade,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Execution routing decision made",
            payload: decision.payload
        )
        let nodeSelectedEvent = try await runtime.recordAuditEvent(
            type: .nodeSelected,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "\(decision.selectedNode.type.rawValue) selected for logical execution routing",
            payload: decision.payload
        )
        let targetAssignedEvent = try await runtime.recordAuditEvent(
            type: .executionTargetAssigned,
            workspaceID: workspaceID,
            taskID: taskID,
            summary: "Execution target assigned to local Mac runtime",
            payload: decision.payload
        )
        return [routingEvent, nodeSelectedEvent, targetAssignedEvent]
    }
}

struct FoundationCloudControlPlane: CloudControlPlane {
    var eventIngestionEndpoint: any EventIngestionEndpoint
    var workspaceRegistry: any WorkspaceRegistry
    var nodeRegistry: any NodeRegistry
    var distributionRouter: any DistributionRouter
    var executionRouter: any ExecutionRouter
    var nodeExecutionRuntime: any NodeExecutionRuntime

    init(
        eventIngestionEndpoint: any EventIngestionEndpoint = StubEventIngestionEndpoint(),
        workspaceRegistry: any WorkspaceRegistry = NoOpWorkspaceRegistry(),
        nodeRegistry: any NodeRegistry = NoOpNodeRegistry(),
        distributionRouter: any DistributionRouter = NoOpDistributionRouter(),
        executionRouter: any ExecutionRouter = DeterministicExecutionRouter(),
        nodeExecutionRuntime: any NodeExecutionRuntime = RoutingNodeExecutionRuntime()
    ) {
        self.eventIngestionEndpoint = eventIngestionEndpoint
        self.workspaceRegistry = workspaceRegistry
        self.nodeRegistry = nodeRegistry
        self.distributionRouter = distributionRouter
        self.executionRouter = executionRouter
        self.nodeExecutionRuntime = nodeExecutionRuntime
    }

    func registerWorkspace(_ workspace: Workspace) {
        workspaceRegistry.register(workspace)
    }

    func registerNode(_ node: LogicalNode) {
        nodeRegistry.register(node)
    }

    func routeEvent(
        _ event: ExecutionEvent,
        workspace: Workspace,
        cloudRoutingEnabled: Bool? = nil
    ) -> DistributionRouteDecision {
        let envelope = EventRoutingEnvelope(event: event, cloudRoutingEnabled: cloudRoutingEnabled)
        return distributionRouter.route(envelope, workspace: workspace)
    }

    func routeExecution(_ request: ExecutionRoutingRequest) -> ExecutionRoutingDecision {
        executionRouter.route(request)
    }

    func executeRoutedTool(
        _ toolCall: ToolCall,
        decision: ExecutionRoutingDecision,
        runtime: RuntimeKernel,
        workspaceID: UUID,
        taskID: UUID? = nil,
        stepID: String? = nil,
        simulateFailure: Bool = false
    ) async throws -> NodeExecutionResult {
        try await executionRouter.execute(
            toolCall,
            with: decision,
            nodeRuntime: nodeExecutionRuntime,
            runtime: runtime,
            workspaceID: workspaceID,
            taskID: taskID,
            stepID: stepID,
            simulateFailure: simulateFailure
        )
    }
}
