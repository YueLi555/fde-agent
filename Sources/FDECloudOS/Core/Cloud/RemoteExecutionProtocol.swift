import Foundation

struct ExecutionPolicyContext: Codable, Equatable, Sendable {
    var riskLevel: RiskSeverity
    var taskComplexity: TaskComplexity
    var toolType: ToolType?
    var eventClassification: EventClassification
    var distributionPolicy: WorkspaceDistributionPolicy
    var executionScope: WorkspaceExecutionScope
    var selectedNodeType: LogicalNodeType
    var fallbackNodeID: String
    var routingConfidence: Double

    init(
        riskLevel: RiskSeverity,
        taskComplexity: TaskComplexity,
        toolType: ToolType?,
        eventClassification: EventClassification,
        distributionPolicy: WorkspaceDistributionPolicy,
        executionScope: WorkspaceExecutionScope,
        selectedNodeType: LogicalNodeType,
        fallbackNodeID: String,
        routingConfidence: Double
    ) {
        self.riskLevel = riskLevel
        self.taskComplexity = taskComplexity
        self.toolType = toolType
        self.eventClassification = eventClassification
        self.distributionPolicy = distributionPolicy
        self.executionScope = executionScope
        self.selectedNodeType = selectedNodeType
        self.fallbackNodeID = fallbackNodeID
        self.routingConfidence = routingConfidence
    }

    init(decision: ExecutionRoutingDecision, workspace: Workspace) {
        self.init(
            riskLevel: decision.riskLevel,
            taskComplexity: decision.taskComplexity,
            toolType: decision.toolType,
            eventClassification: decision.eventClassification,
            distributionPolicy: workspace.distributionPolicy,
            executionScope: workspace.executionScope,
            selectedNodeType: decision.selectedNode.type,
            fallbackNodeID: decision.fallbackNode.id,
            routingConfidence: decision.confidence
        )
    }

    enum CodingKeys: String, CodingKey {
        case riskLevel = "risk_level"
        case taskComplexity = "task_complexity"
        case toolType = "tool_type"
        case eventClassification = "event_classification"
        case distributionPolicy = "distribution_policy"
        case executionScope = "execution_scope"
        case selectedNodeType = "selected_node_type"
        case fallbackNodeID = "fallback_node_id"
        case routingConfidence = "routing_confidence"
    }
}

struct ExecutionApprovalContext: Codable, Equatable, Sendable {
    var approvalRequired: Bool
    var approvalRequestID: UUID?
    var approved: Bool
    var approvedByRole: UserRole?
    var decisionReason: String?

    init(
        approvalRequired: Bool = false,
        approvalRequestID: UUID? = nil,
        approved: Bool = false,
        approvedByRole: UserRole? = nil,
        decisionReason: String? = nil
    ) {
        self.approvalRequired = approvalRequired
        self.approvalRequestID = approvalRequestID
        self.approved = approved
        self.approvedByRole = approvedByRole
        self.decisionReason = decisionReason
    }

    enum CodingKeys: String, CodingKey {
        case approvalRequired = "approval_required"
        case approvalRequestID = "approval_request_id"
        case approved
        case approvedByRole = "approved_by_role"
        case decisionReason = "decision_reason"
    }
}

struct ExecutionEnvelope: Identifiable, Codable, Equatable, Sendable {
    let executionID: UUID
    var taskID: UUID?
    var workspaceID: UUID
    var nodeID: String
    var toolCall: ToolCall
    var policyContext: ExecutionPolicyContext
    var approvalContext: ExecutionApprovalContext

    var id: UUID { executionID }

    init(
        executionID: UUID = UUID(),
        taskID: UUID?,
        workspaceID: UUID,
        nodeID: String,
        toolCall: ToolCall,
        policyContext: ExecutionPolicyContext,
        approvalContext: ExecutionApprovalContext = ExecutionApprovalContext()
    ) {
        self.executionID = executionID
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.nodeID = nodeID
        self.toolCall = toolCall
        self.policyContext = policyContext
        self.approvalContext = approvalContext
    }

    init(
        decision: ExecutionRoutingDecision,
        workspace: Workspace,
        taskID: UUID?,
        toolCall: ToolCall,
        approvalContext: ExecutionApprovalContext = ExecutionApprovalContext()
    ) {
        self.init(
            taskID: taskID,
            workspaceID: workspace.id,
            nodeID: decision.selectedNode.id,
            toolCall: toolCall,
            policyContext: ExecutionPolicyContext(decision: decision, workspace: workspace),
            approvalContext: approvalContext
        )
    }

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case taskID = "task_id"
        case workspaceID = "workspace_id"
        case nodeID = "node_id"
        case toolCall = "tool_call"
        case policyContext = "policy_context"
        case approvalContext = "approval_context"
    }
}

enum ExecutionResponseStatus: String, Codable, Sendable {
    case completed
    case failed
    case disabled
}

struct ExecutionOutput: Codable, Equatable, Sendable {
    var exitCode: Int32
    var standardOutput: String
    var standardError: String

    enum CodingKeys: String, CodingKey {
        case exitCode = "exit_code"
        case standardOutput = "standard_output"
        case standardError = "standard_error"
    }
}

struct ExecutionMetrics: Codable, Equatable, Sendable {
    var duration: TimeInterval
    var simulated: Bool
    var networkAttempted: Bool
    var nodeType: LogicalNodeType

    enum CodingKeys: String, CodingKey {
        case duration
        case simulated
        case networkAttempted = "network_attempted"
        case nodeType = "node_type"
    }
}

struct ExecutionResponse: Identifiable, Codable, Equatable, Sendable {
    var executionID: UUID
    var status: ExecutionResponseStatus
    var output: ExecutionOutput?
    var metrics: ExecutionMetrics
    var events: [ToolExecutionEvent]
    var failureReason: String?

    var id: UUID { executionID }

    init(
        executionID: UUID,
        status: ExecutionResponseStatus,
        output: ExecutionOutput?,
        metrics: ExecutionMetrics,
        events: [ToolExecutionEvent] = [],
        failureReason: String? = nil
    ) {
        self.executionID = executionID
        self.status = status
        self.output = output
        self.metrics = metrics
        self.events = events
        self.failureReason = failureReason
    }

    init(envelope: ExecutionEnvelope, result: NodeExecutionResult) {
        let status: ExecutionResponseStatus = result.state == .completed ? .completed : .failed
        let output = ExecutionOutput(
            exitCode: result.exitCode,
            standardOutput: result.standardOutput,
            standardError: result.standardError
        )
        self.init(
            executionID: envelope.executionID,
            status: status,
            output: output,
            metrics: ExecutionMetrics(
                duration: result.duration,
                simulated: result.simulated,
                networkAttempted: result.networkAttempted,
                nodeType: result.node.type
            ),
            events: [
                ToolExecutionEvent(
                    type: status == .completed ? .nodeExecutionCompleted : .nodeExecutionFailed,
                    summary: "Execution response prepared for \(result.node.type.rawValue)",
                    payload: [
                        "execution_id": envelope.executionID.uuidString,
                        "node_id": result.node.id,
                        "node_type": result.node.type.rawValue,
                        "status": status.rawValue,
                        "network_attempted": result.networkAttempted ? "true" : "false"
                    ]
                )
            ],
            failureReason: status == .failed ? result.standardError : nil
        )
    }

    enum CodingKeys: String, CodingKey {
        case executionID = "execution_id"
        case status
        case output
        case metrics
        case events
        case failureReason = "failure_reason"
    }
}

protocol NodeTransportProtocol: Sendable {
    var transportName: String { get }

    func send(
        _ envelope: ExecutionEnvelope,
        nodeRuntime: any NodeExecutionRuntime,
        runtime: RuntimeKernel
    ) async throws -> ExecutionResponse
}

struct LocalTransport: NodeTransportProtocol {
    let transportName = "local"

    func send(
        _ envelope: ExecutionEnvelope,
        nodeRuntime: any NodeExecutionRuntime = RoutingNodeExecutionRuntime(),
        runtime: RuntimeKernel
    ) async throws -> ExecutionResponse {
        try await record(.executionDispatched, envelope: envelope, runtime: runtime, status: "dispatched")
        try await record(.executionReceived, envelope: envelope, runtime: runtime, status: "received")

        let result = try await nodeRuntime.execute(
            NodeExecutionRequest(
                routingDecision: routingDecision(from: envelope),
                toolCall: envelope.toolCall,
                workspaceID: envelope.workspaceID,
                taskID: envelope.taskID
            ),
            runtime: runtime
        )
        let response = ExecutionResponse(envelope: envelope, result: result)

        try await record(
            .executionResponseReceived,
            envelope: envelope,
            runtime: runtime,
            status: response.status.rawValue,
            response: response
        )
        return response
    }

    private func routingDecision(from envelope: ExecutionEnvelope) -> ExecutionRoutingDecision {
        let selectedNode = logicalNode(
            id: envelope.nodeID,
            type: envelope.policyContext.selectedNodeType,
            workspaceID: envelope.workspaceID
        )
        let fallbackNode = logicalNode(
            id: envelope.policyContext.fallbackNodeID,
            type: .macNode,
            workspaceID: envelope.workspaceID
        )

        return ExecutionRoutingDecision(
            selectedNode: selectedNode,
            fallbackNode: fallbackNode,
            reason: "Execution envelope received by LocalTransport.",
            confidence: envelope.policyContext.routingConfidence,
            taskComplexity: envelope.policyContext.taskComplexity,
            riskLevel: envelope.policyContext.riskLevel,
            toolType: envelope.policyContext.toolType,
            eventClassification: envelope.policyContext.eventClassification,
            executionRemainsLocal: true,
            networkAttempted: false
        )
    }

    private func logicalNode(id: String, type: LogicalNodeType, workspaceID: UUID) -> LogicalNode {
        switch type {
        case .macNode:
            return LogicalNode.currentMac(workspaceID: workspaceID)
        case .cloudNode:
            return LogicalNode.futureCloud(workspaceID: workspaceID)
        case .agentNode:
            return LogicalNode.futureAgent(workspaceID: workspaceID)
        case .workerNode:
            return LogicalNode.futureWorker(workspaceID: workspaceID)
        }
    }

    private func record(
        _ type: EventType,
        envelope: ExecutionEnvelope,
        runtime: RuntimeKernel,
        status: String,
        response: ExecutionResponse? = nil
    ) async throws {
        try await runtime.recordAuditEvent(
            type: type,
            workspaceID: envelope.workspaceID,
            taskID: envelope.taskID,
            summary: "\(transportName) transport \(type.rawValue.lowercased())",
            payload: payload(envelope: envelope, status: status, response: response)
        )
    }

    private func payload(
        envelope: ExecutionEnvelope,
        status: String,
        response: ExecutionResponse?
    ) -> [String: String] {
        [
            "execution_id": envelope.executionID.uuidString,
            "task_id": envelope.taskID?.uuidString ?? "",
            "workspace_id": envelope.workspaceID.uuidString,
            "node_id": envelope.nodeID,
            "node_type": envelope.policyContext.selectedNodeType.rawValue,
            "transport": transportName,
            "status": status,
            "tool_call_id": envelope.toolCall.id,
            "tool_type": envelope.toolCall.type.rawValue,
            "command": envelope.toolCall.command,
            "network_attempted": response?.metrics.networkAttempted == true ? "true" : "false"
        ]
    }
}

struct RemoteTransportStub: NodeTransportProtocol {
    let transportName = "remote_stub"

    func send(
        _ envelope: ExecutionEnvelope,
        nodeRuntime: any NodeExecutionRuntime = RoutingNodeExecutionRuntime(),
        runtime: RuntimeKernel
    ) async throws -> ExecutionResponse {
        try await record(.executionDispatched, envelope: envelope, runtime: runtime, status: "disabled")
        try await record(.executionReceived, envelope: envelope, runtime: runtime, status: "disabled")

        let response = ExecutionResponse(
            executionID: envelope.executionID,
            status: .disabled,
            output: nil,
            metrics: ExecutionMetrics(
                duration: 0,
                simulated: true,
                networkAttempted: false,
                nodeType: envelope.policyContext.selectedNodeType
            ),
            events: [
                ToolExecutionEvent(
                    type: .executionResponseReceived,
                    summary: "Remote transport stub disabled.",
                    payload: [
                        "execution_id": envelope.executionID.uuidString,
                        "node_id": envelope.nodeID,
                        "network_attempted": "false"
                    ]
                )
            ],
            failureReason: "RemoteTransportStub is disabled; no network execution attempted."
        )
        try await record(.executionResponseReceived, envelope: envelope, runtime: runtime, status: response.status.rawValue, response: response)
        return response
    }

    private func record(
        _ type: EventType,
        envelope: ExecutionEnvelope,
        runtime: RuntimeKernel,
        status: String,
        response: ExecutionResponse? = nil
    ) async throws {
        try await runtime.recordAuditEvent(
            type: type,
            workspaceID: envelope.workspaceID,
            taskID: envelope.taskID,
            summary: "\(transportName) transport \(type.rawValue.lowercased())",
            payload: [
                "execution_id": envelope.executionID.uuidString,
                "task_id": envelope.taskID?.uuidString ?? "",
                "workspace_id": envelope.workspaceID.uuidString,
                "node_id": envelope.nodeID,
                "node_type": envelope.policyContext.selectedNodeType.rawValue,
                "transport": transportName,
                "status": status,
                "tool_call_id": envelope.toolCall.id,
                "tool_type": envelope.toolCall.type.rawValue,
                "command": envelope.toolCall.command,
                "network_attempted": response?.metrics.networkAttempted == true ? "true" : "false"
            ]
        )
    }
}

extension CloudControlPlane {
    func makeExecutionEnvelope(
        decision: ExecutionRoutingDecision,
        workspace: Workspace,
        taskID: UUID?,
        toolCall: ToolCall,
        approvalContext: ExecutionApprovalContext = ExecutionApprovalContext()
    ) -> ExecutionEnvelope {
        ExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall,
            approvalContext: approvalContext
        )
    }

    func dispatchExecutionEnvelope(
        _ envelope: ExecutionEnvelope,
        transport: any NodeTransportProtocol = LocalTransport(),
        runtime: RuntimeKernel
    ) async throws -> ExecutionResponse {
        try await transport.send(
            envelope,
            nodeRuntime: nodeExecutionRuntime,
            runtime: runtime
        )
    }
}
