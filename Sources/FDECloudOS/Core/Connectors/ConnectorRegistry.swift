import Foundation

enum ConnectorState: String, Codable, CaseIterable, Identifiable, Sendable {
    case disconnected = "Disconnected"
    case needsOAuth = "Needs OAuth"
    case ready = "Ready"
    case degraded = "Degraded"

    var id: String { rawValue }
}

struct ConnectorStatus: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    var state: ConnectorState
    var lastSyncSummary: String
}

struct ConnectorCapability: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var connectorID: String
    var name: String
    var actions: [String]
    var riskLevel: RiskSeverity
    var requiresApproval: Bool
}

struct ConnectorRequest: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var connectorID: String
    var action: String
    var payload: [String: String]
    var dryRun: Bool
    var simulateFailure: Bool
}

struct ConnectorResponse: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var requestID: String
    var connectorID: String
    var action: String
    var state: ConnectorState
    var success: Bool
    var dryRun: Bool
    var message: String
    var payload: [String: String]
    var duration: TimeInterval

    var emittedEvent: ToolExecutionEvent {
        ToolExecutionEvent(
            type: dryRun ? .connectorDryRun : .connectorExecuted,
            summary: message,
            payload: eventPayload
        )
    }

    var eventPayload: [String: String] {
        var values = payload
        values["connector_id"] = connectorID
        values["connector_action"] = action
        values["connector_state"] = state.rawValue
        values["connector_success"] = success ? "true" : "false"
        values["connector_dry_run"] = dryRun ? "true" : "false"
        values["connector_response_id"] = id
        values["connector_request_id"] = requestID
        values["network"] = "disabled"
        return values
    }
}

struct ConnectorValidationResult: Codable, Hashable, Sendable {
    var connectorID: String
    var valid: Bool
    var state: ConnectorState
    var message: String
}

enum ConnectorRuntimeError: LocalizedError, Equatable {
    case connectorNotFound(String)
    case invalidCommand(String)
    case validationFailed(String)
    case mockFailure(connectorID: String, action: String)

    var errorDescription: String? {
        switch self {
        case .connectorNotFound(let id):
            return "Connector not found: \(id)"
        case .invalidCommand(let command):
            return "Invalid connector command: \(command)"
        case .validationFailed(let message):
            return "Connector validation failed: \(message)"
        case .mockFailure(let connectorID, let action):
            return "\(connectorID) mock connector failed deterministically for action \(action)."
        }
    }
}

struct ConnectorExecutionFailure: LocalizedError, Sendable {
    var error: ConnectorRuntimeError
    var emittedEvents: [ToolExecutionEvent]

    var errorDescription: String? {
        error.localizedDescription
    }
}

protocol ConnectorProtocol: Sendable {
    var id: String { get }
    var displayName: String { get }

    func execute(_ request: ConnectorRequest) async throws -> ConnectorResponse
    func validate() async -> ConnectorValidationResult
    func dryRun(_ request: ConnectorRequest) async throws -> ConnectorResponse
    func getCapabilities() async -> [ConnectorCapability]
    func status() async -> ConnectorStatus
}

struct SlackConnector: ConnectorProtocol {
    private let mock = DeterministicMockConnector(
        id: "slack",
        displayName: "Slack",
        actions: ["post_message", "search_messages", "summarize_channel"]
    )

    var id: String { mock.id }
    var displayName: String { mock.displayName }

    func execute(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.execute(request)
    }

    func validate() async -> ConnectorValidationResult {
        await mock.validate()
    }

    func dryRun(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.dryRun(request)
    }

    func getCapabilities() async -> [ConnectorCapability] {
        await mock.getCapabilities()
    }

    func status() async -> ConnectorStatus {
        await mock.status()
    }
}

struct GitHubConnector: ConnectorProtocol {
    private let mock = DeterministicMockConnector(
        id: "github",
        displayName: "GitHub",
        actions: ["create_issue", "list_issues", "summarize_pr"]
    )

    var id: String { mock.id }
    var displayName: String { mock.displayName }

    func execute(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.execute(request)
    }

    func validate() async -> ConnectorValidationResult {
        await mock.validate()
    }

    func dryRun(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.dryRun(request)
    }

    func getCapabilities() async -> [ConnectorCapability] {
        await mock.getCapabilities()
    }

    func status() async -> ConnectorStatus {
        await mock.status()
    }
}

struct NotionConnector: ConnectorProtocol {
    private let mock = DeterministicMockConnector(
        id: "notion",
        displayName: "Notion",
        actions: ["create_page", "search_pages", "summarize_database"]
    )

    var id: String { mock.id }
    var displayName: String { mock.displayName }

    func execute(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.execute(request)
    }

    func validate() async -> ConnectorValidationResult {
        await mock.validate()
    }

    func dryRun(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.dryRun(request)
    }

    func getCapabilities() async -> [ConnectorCapability] {
        await mock.getCapabilities()
    }

    func status() async -> ConnectorStatus {
        await mock.status()
    }
}

struct GmailConnector: ConnectorProtocol {
    private let mock = DeterministicMockConnector(
        id: "gmail",
        displayName: "Gmail",
        actions: ["draft_email", "search_mail", "summarize_thread"]
    )

    var id: String { mock.id }
    var displayName: String { mock.displayName }

    func execute(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.execute(request)
    }

    func validate() async -> ConnectorValidationResult {
        await mock.validate()
    }

    func dryRun(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        try await mock.dryRun(request)
    }

    func getCapabilities() async -> [ConnectorCapability] {
        await mock.getCapabilities()
    }

    func status() async -> ConnectorStatus {
        await mock.status()
    }
}

struct ConnectorRegistry: Sendable {
    let connectors: [any ConnectorProtocol]

    static func `default`() -> ConnectorRegistry {
        ConnectorRegistry(connectors: [
            SlackConnector(),
            GitHubConnector(),
            NotionConnector(),
            GmailConnector()
        ])
    }

    func connector(id: String) -> (any ConnectorProtocol)? {
        connectors.first { $0.id == id.lowercased() }
    }

    func statuses() async -> [ConnectorStatus] {
        var values: [ConnectorStatus] = []
        for connector in connectors {
            values.append(await connector.status())
        }
        return values
    }

    func capabilities() async -> [ConnectorCapability] {
        var values: [ConnectorCapability] = []
        for connector in connectors {
            values.append(contentsOf: await connector.getCapabilities())
        }
        return values
    }

    func validate(request: ConnectorRequest) async throws -> ConnectorValidationResult {
        guard let connector = connector(id: request.connectorID) else {
            throw ConnectorRuntimeError.connectorNotFound(request.connectorID)
        }
        return await connector.validate()
    }

    func dryRun(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        guard let connector = connector(id: request.connectorID) else {
            throw ConnectorRuntimeError.connectorNotFound(request.connectorID)
        }
        return try await connector.dryRun(request)
    }

    func execute(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        guard let connector = connector(id: request.connectorID) else {
            throw ConnectorRuntimeError.connectorNotFound(request.connectorID)
        }
        return try await connector.execute(request)
    }

    func request(from call: ToolCall) throws -> ConnectorRequest {
        let parts = call.command
            .lowercased()
            .split(separator: ".")
            .map(String.init)
        let commandParts = parts.first == "connector" ? Array(parts.dropFirst()) : parts
        guard commandParts.count >= 2 else {
            throw ConnectorRuntimeError.invalidCommand(call.command)
        }

        let payload = Self.payload(from: call.arguments)
        let action = commandParts.dropFirst().joined(separator: ".")
        let shouldFail = payload["simulate_failure"] == "true"
            || payload["mock_failure"] == "true"
            || action.contains("fail")

        return ConnectorRequest(
            id: call.id,
            connectorID: commandParts[0],
            action: action,
            payload: payload,
            dryRun: payload["dry_run"] == "true",
            simulateFailure: shouldFail
        )
    }

    private static func payload(from arguments: [String]) -> [String: String] {
        var payload: [String: String] = [:]
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                payload[parts[0]] = sanitizedValue(key: parts[0], value: parts[1])
            } else {
                payload["arg\(payload.count + 1)"] = argument
            }
        }
        return payload
    }

    private static func sanitizedValue(key: String, value: String) -> String {
        let lowercased = key.lowercased()
        if lowercased.contains("token")
            || lowercased.contains("secret")
            || lowercased.contains("password")
            || lowercased == "api_key"
            || lowercased == "key" {
            return "[redacted]"
        }
        return value
    }
}

struct ConnectorToolExecutor: ToolExecuting {
    let registry: ConnectorRegistry
    let fallback: any ToolExecuting

    init(
        registry: ConnectorRegistry = .default(),
        fallback: any ToolExecuting = LocalToolExecutor()
    ) {
        self.registry = registry
        self.fallback = fallback
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard call.type == .connector else {
            return try await fallback.execute(call)
        }

        guard !call.requiresApproval else {
            throw ToolExecutionError.approvalRequired(call.id)
        }

        let request = try registry.request(from: call)
        let validation = try await registry.validate(request: request)
        guard validation.valid else {
            throw ConnectorRuntimeError.validationFailed(validation.message)
        }

        let dryRun = try await registry.dryRun(request)
        do {
            let response = try await registry.execute(request)
            return ToolExecutionResult(
                callID: call.id,
                exitCode: response.success ? 0 : 1,
                standardOutput: response.message,
                standardError: response.success ? "" : response.message,
                duration: response.duration,
                emittedEvents: [dryRun.emittedEvent, response.emittedEvent]
            )
        } catch let error as ConnectorRuntimeError {
            throw ConnectorExecutionFailure(error: error, emittedEvents: [dryRun.emittedEvent])
        }
    }
}

private struct DeterministicMockConnector: Sendable {
    let id: String
    let displayName: String
    let actions: [String]

    func execute(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        if request.simulateFailure {
            throw ConnectorRuntimeError.mockFailure(connectorID: id, action: request.action)
        }
        return response(for: request, dryRun: false)
    }

    func validate() async -> ConnectorValidationResult {
        ConnectorValidationResult(
            connectorID: id,
            valid: true,
            state: .ready,
            message: "\(displayName) local mock connector validated without network access."
        )
    }

    func dryRun(_ request: ConnectorRequest) async throws -> ConnectorResponse {
        response(for: request, dryRun: true)
    }

    func getCapabilities() async -> [ConnectorCapability] {
        [
            ConnectorCapability(
                id: "\(id).mock",
                connectorID: id,
                name: "\(displayName) deterministic mock runtime",
                actions: actions,
                riskLevel: .high,
                requiresApproval: true
            )
        ]
    }

    func status() async -> ConnectorStatus {
        ConnectorStatus(
            id: id,
            displayName: displayName,
            state: .ready,
            lastSyncSummary: "Local mock connector ready. Network, OAuth, and external API calls are disabled."
        )
    }

    private func response(for request: ConnectorRequest, dryRun: Bool) -> ConnectorResponse {
        ConnectorResponse(
            id: "\(request.id).\(dryRun ? "dry-run" : "executed")",
            requestID: request.id,
            connectorID: id,
            action: request.action,
            state: .ready,
            success: true,
            dryRun: dryRun,
            message: "\(displayName) mock \(dryRun ? "dry run" : "execution") completed for \(request.action).",
            payload: [
                "connector_id": id,
                "action": request.action,
                "mode": dryRun ? "dry_run" : "execute",
                "mock": "true"
            ].merging(Self.sanitizedPayload(request.payload)) { current, _ in current },
            duration: 0.001
        )
    }

    private static func sanitizedPayload(_ payload: [String: String]) -> [String: String] {
        payload.reduce(into: [:]) { values, item in
            let key = item.key.lowercased()
            if key.contains("token")
                || key.contains("secret")
                || key.contains("password")
                || key == "api_key"
                || key == "key" {
                values[item.key] = "[redacted]"
            } else {
                values[item.key] = item.value
            }
        }
    }
}
