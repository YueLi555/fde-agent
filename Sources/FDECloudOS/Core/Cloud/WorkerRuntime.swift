import Foundation

enum WorkerNodeStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case registered
    case idle
    case busy
    case offline

    var id: String { rawValue }
}

enum WorkerNodeCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case shellSimulation = "shell_simulation"
    case appleScriptSimulation = "applescript_simulation"
    case apiSimulation = "api_simulation"
    case connectorSimulation = "connector_simulation"

    var id: String { rawValue }

    static func required(for toolType: ToolType) -> WorkerNodeCapability {
        switch toolType {
        case .shell:
            return .shellSimulation
        case .appleScript:
            return .appleScriptSimulation
        case .api:
            return .apiSimulation
        case .connector:
            return .connectorSimulation
        }
    }
}

struct WorkerHeartbeatPlaceholder: Codable, Hashable, Sendable {
    var enabled: Bool
    var intervalSeconds: TimeInterval
    var description: String

    static let disabled = WorkerHeartbeatPlaceholder(
        enabled: false,
        intervalSeconds: 0,
        description: "heartbeat-disabled-foundation-placeholder"
    )

    enum CodingKeys: String, CodingKey {
        case enabled
        case intervalSeconds = "interval_seconds"
        case description
    }
}

struct WorkerNodeSession: Identifiable, Codable, Hashable, Sendable {
    let nodeID: String
    var capabilities: [WorkerNodeCapability]
    var heartbeat: WorkerHeartbeatPlaceholder
    var status: WorkerNodeStatus
    var registeredAt: Date

    var id: String { nodeID }

    init(
        nodeID: String = LogicalNode.workerNodeID,
        capabilities: [WorkerNodeCapability] = WorkerNodeCapability.allCases,
        heartbeat: WorkerHeartbeatPlaceholder = .disabled,
        status: WorkerNodeStatus = .registered,
        registeredAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.nodeID = nodeID
        self.capabilities = capabilities
        self.heartbeat = heartbeat
        self.status = status
        self.registeredAt = registeredAt
    }

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case capabilities
        case heartbeat
        case status
        case registeredAt = "registered_at"
    }
}

enum WorkerRuntimeValidationError: LocalizedError, Equatable, Sendable {
    case nodeMismatch(expected: String, actual: String)
    case nonWorkerPolicy(LogicalNodeType)
    case localOnlyPolicy
    case unapprovedAction(String)
    case unsupportedToolType(ToolType)
    case workerOffline(String)

    var errorDescription: String? {
        switch self {
        case .nodeMismatch(let expected, let actual):
            return "WorkerRuntime rejected envelope for node \(actual); expected \(expected)."
        case .nonWorkerPolicy(let selectedType):
            return "WorkerRuntime rejected \(selectedType.rawValue) policy context."
        case .localOnlyPolicy:
            return "WorkerRuntime rejected LOCAL_ONLY policy context."
        case .unapprovedAction(let callID):
            return "WorkerRuntime rejected unapproved tool call \(callID)."
        case .unsupportedToolType(let toolType):
            return "WorkerRuntime rejected unsupported tool type \(toolType.rawValue)."
        case .workerOffline(let nodeID):
            return "WorkerRuntime node \(nodeID) is offline."
        }
    }
}

actor WorkerRuntime {
    private var session: WorkerNodeSession

    init(session: WorkerNodeSession = WorkerNodeSession()) {
        self.session = session
    }

    func register() -> WorkerNodeSession {
        if session.status != .offline {
            session.status = .idle
        }
        return session
    }

    func currentSession() -> WorkerNodeSession {
        session
    }

    func receive(_ envelope: ExecutionEnvelope) async -> ExecutionResponse {
        do {
            try validate(envelope)
            session.status = .busy
            let response = completedResponse(for: envelope)
            session.status = .idle
            return response
        } catch {
            if session.status != .offline {
                session.status = .idle
            }
            return failedResponse(for: envelope, reason: validationReason(error))
        }
    }

    private func validate(_ envelope: ExecutionEnvelope) throws {
        guard session.status != .offline else {
            throw WorkerRuntimeValidationError.workerOffline(session.nodeID)
        }
        guard envelope.nodeID == session.nodeID else {
            throw WorkerRuntimeValidationError.nodeMismatch(expected: session.nodeID, actual: envelope.nodeID)
        }
        guard envelope.policyContext.selectedNodeType == .workerNode else {
            throw WorkerRuntimeValidationError.nonWorkerPolicy(envelope.policyContext.selectedNodeType)
        }
        guard envelope.policyContext.eventClassification != .localOnly else {
            throw WorkerRuntimeValidationError.localOnlyPolicy
        }
        guard !envelope.approvalContext.approvalRequired || envelope.approvalContext.approved else {
            throw WorkerRuntimeValidationError.unapprovedAction(envelope.toolCall.id)
        }

        let requiredCapability = WorkerNodeCapability.required(for: envelope.toolCall.type)
        guard session.capabilities.contains(requiredCapability) else {
            throw WorkerRuntimeValidationError.unsupportedToolType(envelope.toolCall.type)
        }
    }

    private func completedResponse(for envelope: ExecutionEnvelope) -> ExecutionResponse {
        ExecutionResponse(
            executionID: envelope.executionID,
            status: .completed,
            output: ExecutionOutput(
                exitCode: 0,
                standardOutput: "worker-runtime:\(envelope.toolCall.id):\(envelope.toolCall.command)",
                standardError: ""
            ),
            metrics: workerMetrics(for: envelope),
            events: [
                ToolExecutionEvent(
                    type: .workerTaskCompleted,
                    summary: "Worker runtime task completed.",
                    payload: responsePayload(envelope: envelope, status: ExecutionResponseStatus.completed.rawValue)
                )
            ],
            failureReason: nil
        )
    }

    private func failedResponse(for envelope: ExecutionEnvelope, reason: String) -> ExecutionResponse {
        ExecutionResponse(
            executionID: envelope.executionID,
            status: .failed,
            output: ExecutionOutput(
                exitCode: 1,
                standardOutput: "",
                standardError: reason
            ),
            metrics: workerMetrics(for: envelope),
            events: [
                ToolExecutionEvent(
                    type: .workerTaskFailed,
                    summary: "Worker runtime task failed.",
                    payload: responsePayload(envelope: envelope, status: ExecutionResponseStatus.failed.rawValue, failureReason: reason)
                )
            ],
            failureReason: reason
        )
    }

    private func workerMetrics(for envelope: ExecutionEnvelope) -> ExecutionMetrics {
        ExecutionMetrics(
            duration: Double(LogicalNode.futureWorker(workspaceID: envelope.workspaceID).simulatedLatencyMilliseconds) / 1000,
            simulated: true,
            networkAttempted: false,
            nodeType: .workerNode
        )
    }

    private func responsePayload(
        envelope: ExecutionEnvelope,
        status: String,
        failureReason: String = ""
    ) -> [String: String] {
        [
            "execution_id": envelope.executionID.uuidString,
            "task_id": envelope.taskID?.uuidString ?? "",
            "workspace_id": envelope.workspaceID.uuidString,
            "node_id": session.nodeID,
            "node_type": LogicalNodeType.workerNode.rawValue,
            "event_classification": EventClassification.systemOnly.rawValue,
            "status": status,
            "tool_call_id": envelope.toolCall.id,
            "tool_type": envelope.toolCall.type.rawValue,
            "command": envelope.toolCall.command,
            "simulated": "true",
            "network_attempted": "false",
            "failure_reason": failureReason
        ]
    }

    private func validationReason(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

struct WorkerTransportAdapter: NodeTransportProtocol {
    let transportName = "worker_ipc_mock"
    let workerRuntime: WorkerRuntime

    init(workerRuntime: WorkerRuntime = WorkerRuntime()) {
        self.workerRuntime = workerRuntime
    }

    func send(
        _ envelope: ExecutionEnvelope,
        nodeRuntime: any NodeExecutionRuntime = RoutingNodeExecutionRuntime(),
        runtime: RuntimeKernel
    ) async throws -> ExecutionResponse {
        let session = await workerRuntime.register()
        try await record(
            .workerRegistered,
            envelope: envelope,
            session: session,
            runtime: runtime,
            status: "registered"
        )
        try await record(
            .workerTaskReceived,
            envelope: envelope,
            session: session,
            runtime: runtime,
            status: "received"
        )

        let response = await workerRuntime.receive(envelope)
        let finalSession = await workerRuntime.currentSession()
        let finalEvent: EventType = response.status == .completed ? .workerTaskCompleted : .workerTaskFailed
        try await record(
            finalEvent,
            envelope: envelope,
            session: finalSession,
            runtime: runtime,
            status: response.status.rawValue,
            response: response
        )
        return response
    }

    private func record(
        _ type: EventType,
        envelope: ExecutionEnvelope,
        session: WorkerNodeSession,
        runtime: RuntimeKernel,
        status: String,
        response: ExecutionResponse? = nil
    ) async throws {
        try await runtime.recordAuditEvent(
            type: type,
            workspaceID: envelope.workspaceID,
            taskID: envelope.taskID,
            summary: "\(transportName) \(type.rawValue.lowercased())",
            payload: payload(envelope: envelope, session: session, status: status, response: response)
        )
    }

    private func payload(
        envelope: ExecutionEnvelope,
        session: WorkerNodeSession,
        status: String,
        response: ExecutionResponse?
    ) -> [String: String] {
        [
            "execution_id": envelope.executionID.uuidString,
            "task_id": envelope.taskID?.uuidString ?? "",
            "workspace_id": envelope.workspaceID.uuidString,
            "node_id": envelope.nodeID,
            "worker_node_id": session.nodeID,
            "node_type": envelope.policyContext.selectedNodeType.rawValue,
            "event_classification": EventClassification.systemOnly.rawValue,
            "session_status": session.status.rawValue,
            "capabilities": session.capabilities.map(\.rawValue).sorted().joined(separator: ","),
            "heartbeat_placeholder": session.heartbeat.description,
            "transport": transportName,
            "status": status,
            "tool_call_id": envelope.toolCall.id,
            "tool_type": envelope.toolCall.type.rawValue,
            "command": envelope.toolCall.command,
            "simulated": response.map { $0.metrics.simulated ? "true" : "false" } ?? "true",
            "network_attempted": response?.metrics.networkAttempted == true ? "true" : "false",
            "failure_reason": response?.failureReason ?? ""
        ]
    }
}
