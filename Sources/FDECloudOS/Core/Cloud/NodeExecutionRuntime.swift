import Foundation

enum NodeExecutionState: String, Codable, Sendable {
    case completed
    case failed
}

struct NodeExecutionRequest: Sendable {
    var routingDecision: ExecutionRoutingDecision
    var toolCall: ToolCall
    var workspaceID: UUID
    var taskID: UUID?
    var stepID: String?
    var simulateFailure: Bool

    init(
        routingDecision: ExecutionRoutingDecision,
        toolCall: ToolCall,
        workspaceID: UUID,
        taskID: UUID? = nil,
        stepID: String? = nil,
        simulateFailure: Bool = false
    ) {
        self.routingDecision = routingDecision
        self.toolCall = toolCall
        self.workspaceID = workspaceID
        self.taskID = taskID
        self.stepID = stepID
        self.simulateFailure = simulateFailure
    }
}

struct NodeExecutionResult: Equatable, Sendable {
    var state: NodeExecutionState
    var node: LogicalNode
    var callID: String
    var exitCode: Int32
    var standardOutput: String
    var standardError: String
    var duration: TimeInterval
    var simulated: Bool
    var networkAttempted: Bool
    var emittedEventIDs: [UUID]

    static func completed(
        node: LogicalNode,
        callID: String,
        exitCode: Int32,
        standardOutput: String,
        standardError: String = "",
        duration: TimeInterval,
        simulated: Bool,
        emittedEventIDs: [UUID]
    ) -> NodeExecutionResult {
        NodeExecutionResult(
            state: .completed,
            node: node,
            callID: callID,
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: standardError,
            duration: duration,
            simulated: simulated,
            networkAttempted: false,
            emittedEventIDs: emittedEventIDs
        )
    }

    static func failed(
        node: LogicalNode,
        callID: String,
        standardError: String,
        duration: TimeInterval,
        simulated: Bool,
        emittedEventIDs: [UUID]
    ) -> NodeExecutionResult {
        NodeExecutionResult(
            state: .failed,
            node: node,
            callID: callID,
            exitCode: 1,
            standardOutput: "",
            standardError: standardError,
            duration: duration,
            simulated: simulated,
            networkAttempted: false,
            emittedEventIDs: emittedEventIDs
        )
    }
}

protocol NodeSpecificExecutor: Sendable {
    var nodeType: LogicalNodeType { get }
    func execute(_ request: NodeExecutionRequest) async -> NodeExecutionResult
}

protocol NodeExecutionRuntime: Sendable {
    func execute(
        _ request: NodeExecutionRequest,
        runtime: RuntimeKernel
    ) async throws -> NodeExecutionResult
}

struct RoutingNodeExecutionRuntime: NodeExecutionRuntime {
    var macExecutor: any NodeSpecificExecutor = MacNodeExecutor()
    var cloudExecutor: any NodeSpecificExecutor = CloudNodeExecutor()
    var agentExecutor: any NodeSpecificExecutor = AgentNodeExecutor()
    var workerExecutor: any NodeSpecificExecutor = WorkerNodeExecutor()

    func execute(
        _ request: NodeExecutionRequest,
        runtime: RuntimeKernel
    ) async throws -> NodeExecutionResult {
        let startEvent = try await runtime.recordAuditEvent(
            type: .nodeExecutionStarted,
            workspaceID: request.workspaceID,
            taskID: request.taskID,
            summary: "\(request.routingDecision.selectedNode.type.rawValue) node execution started",
            payload: payload(for: request, state: .nodeExecutionStarted)
        )

        let executor = executor(for: request.routingDecision.selectedNode.type)
        var result = await executor.execute(request)
        var eventIDs = [startEvent.id]

        switch result.state {
        case .completed:
            let completedEvent = try await runtime.recordAuditEvent(
                type: .nodeExecutionCompleted,
                workspaceID: request.workspaceID,
                taskID: request.taskID,
                summary: "\(request.routingDecision.selectedNode.type.rawValue) node execution completed",
                payload: payload(for: request, result: result, state: .nodeExecutionCompleted)
            )
            eventIDs.append(completedEvent.id)
        case .failed:
            let failedEvent = try await runtime.recordAuditEvent(
                type: .nodeExecutionFailed,
                workspaceID: request.workspaceID,
                taskID: request.taskID,
                summary: "\(request.routingDecision.selectedNode.type.rawValue) node execution failed",
                payload: payload(for: request, result: result, state: .nodeExecutionFailed)
            )
            eventIDs.append(failedEvent.id)
        }

        result.emittedEventIDs = eventIDs
        return result
    }

    private func executor(for nodeType: LogicalNodeType) -> any NodeSpecificExecutor {
        switch nodeType {
        case .macNode:
            return macExecutor
        case .cloudNode:
            return cloudExecutor
        case .agentNode:
            return agentExecutor
        case .workerNode:
            return workerExecutor
        }
    }

    private func payload(
        for request: NodeExecutionRequest,
        result: NodeExecutionResult? = nil,
        state: EventType
    ) -> [String: String] {
        var payload = request.routingDecision.payload
        payload["node_execution_event"] = state.rawValue
        payload["node_id"] = request.routingDecision.selectedNode.id
        payload["node_type"] = request.routingDecision.selectedNode.type.rawValue
        payload["tool_call_id"] = request.toolCall.id
        payload["tool_type"] = request.toolCall.type.rawValue
        payload["command"] = request.toolCall.command
        payload["step_id"] = request.stepID ?? ""
        payload["simulated"] = result.map { $0.simulated ? "true" : "false" } ?? ""
        payload["exit_code"] = result.map { String($0.exitCode) } ?? ""
        payload["stdout"] = result?.standardOutput ?? ""
        payload["stderr"] = result?.standardError ?? ""
        payload["duration"] = result.map { String($0.duration) } ?? ""
        return payload
    }
}

struct MacNodeExecutor: NodeSpecificExecutor {
    let nodeType: LogicalNodeType = .macNode
    var toolExecutor: any ToolExecuting = LocalToolExecutor()

    func execute(_ request: NodeExecutionRequest) async -> NodeExecutionResult {
        let start = Date()
        if request.simulateFailure {
            return .failed(
                node: request.routingDecision.selectedNode,
                callID: request.toolCall.id,
                standardError: "Simulated MacNode failure.",
                duration: Date().timeIntervalSince(start),
                simulated: false,
                emittedEventIDs: []
            )
        }

        do {
            let result = try await toolExecutor.execute(request.toolCall)
            return .completed(
                node: request.routingDecision.selectedNode,
                callID: result.callID,
                exitCode: result.exitCode,
                standardOutput: result.standardOutput,
                standardError: result.standardError,
                duration: result.duration,
                simulated: false,
                emittedEventIDs: []
            )
        } catch {
            return .failed(
                node: request.routingDecision.selectedNode,
                callID: request.toolCall.id,
                standardError: error.localizedDescription,
                duration: Date().timeIntervalSince(start),
                simulated: false,
                emittedEventIDs: []
            )
        }
    }
}

struct CloudNodeExecutor: NodeSpecificExecutor {
    let nodeType: LogicalNodeType = .cloudNode

    func execute(_ request: NodeExecutionRequest) async -> NodeExecutionResult {
        mockResult(
            request,
            prefix: "mock-cloud",
            failureMessage: "Simulated CloudNode failure."
        )
    }
}

struct AgentNodeExecutor: NodeSpecificExecutor {
    let nodeType: LogicalNodeType = .agentNode

    func execute(_ request: NodeExecutionRequest) async -> NodeExecutionResult {
        mockResult(
            request,
            prefix: "mock-agent",
            failureMessage: "Simulated AgentNode failure."
        )
    }
}

struct WorkerNodeExecutor: NodeSpecificExecutor {
    let nodeType: LogicalNodeType = .workerNode

    func execute(_ request: NodeExecutionRequest) async -> NodeExecutionResult {
        mockResult(
            request,
            prefix: "mock-worker",
            failureMessage: "Simulated WorkerNode failure."
        )
    }
}

private func mockResult(
    _ request: NodeExecutionRequest,
    prefix: String,
    failureMessage: String
) -> NodeExecutionResult {
    let duration = Double(request.routingDecision.selectedNode.simulatedLatencyMilliseconds) / 1000
    if request.simulateFailure {
        return .failed(
            node: request.routingDecision.selectedNode,
            callID: request.toolCall.id,
            standardError: failureMessage,
            duration: duration,
            simulated: true,
            emittedEventIDs: []
        )
    }

    return .completed(
        node: request.routingDecision.selectedNode,
        callID: request.toolCall.id,
        exitCode: 0,
        standardOutput: "\(prefix):\(request.toolCall.id):\(request.toolCall.command)",
        duration: duration,
        simulated: true,
        emittedEventIDs: []
    )
}
