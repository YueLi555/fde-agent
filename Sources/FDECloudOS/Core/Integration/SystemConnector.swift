import Foundation

enum EvidenceValidationStatus: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case unvalidated = "UNVALIDATED"
    case valid = "VALID"
    case warning = "WARNING"
    case failed = "FAILED"

    var id: String { rawValue }
}

struct EvidenceRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var action: String
    var timestamp: Date
    var source: String
    var result: String
    var validation: EvidenceValidationStatus

    init(
        id: UUID = UUID(),
        action: String,
        timestamp: Date = Date(),
        source: String,
        result: String,
        validation: EvidenceValidationStatus
    ) {
        self.id = id
        self.action = AgentPresentationSanitizer.safeContent(action, fallback: "connector action")
        self.timestamp = timestamp
        self.source = AgentPresentationSanitizer.safeContent(source, fallback: "system connector")
        self.result = AgentPresentationSanitizer.safeContent(result, fallback: "Evidence captured")
        self.validation = validation
    }

    var summary: String {
        "\(source):\(action):\(validation.rawValue)"
    }
}

struct SystemConnectorDiscovery: Codable, Hashable, Sendable {
    var systemID: String
    var displayName: String
    var status: String
    var facts: [String]
    var evidence: EvidenceRecord
}

struct SystemConnectorAuthentication: Codable, Hashable, Sendable {
    var authenticated: Bool
    var principal: String
    var role: String
    var allowedActions: [String]
    var deniedActions: [String]
    var approvalRequirements: [String]
    var evidence: EvidenceRecord
}

struct SystemConnectorInspection: Codable, Hashable, Sendable {
    var capabilities: [String]
    var dependencies: [String]
    var facts: [String]
    var riskSignals: [String]
    var evidence: EvidenceRecord
}

struct SystemConnectorActionRequest: Codable, Hashable, Sendable {
    var action: String
    var payload: [String: String]
    var dryRun: Bool

    init(action: String, payload: [String: String] = [:], dryRun: Bool = true) {
        self.action = action
        self.payload = payload
        self.dryRun = dryRun
    }
}

struct SystemConnectorActionResult: Codable, Hashable, Sendable {
    var action: String
    var success: Bool
    var result: String
    var payload: [String: String]
    var evidence: EvidenceRecord
}

struct SystemConnectorValidation: Codable, Hashable, Sendable {
    var valid: Bool
    var message: String
    var evidence: EvidenceRecord
}

protocol SystemConnector: Sendable {
    var id: String { get }
    var displayName: String { get }

    func discover() async -> SystemConnectorDiscovery
    func authenticate() async -> SystemConnectorAuthentication
    func inspect() async -> SystemConnectorInspection
    func execute(_ request: SystemConnectorActionRequest) async throws -> SystemConnectorActionResult
    func validate() async -> SystemConnectorValidation
    func collectEvidence() async -> [EvidenceRecord]
}

struct ConnectorRegistrySystemConnector: SystemConnector {
    let connector: any ConnectorProtocol

    var id: String { connector.id }
    var displayName: String { connector.displayName }

    func discover() async -> SystemConnectorDiscovery {
        let status = await connector.status()
        return SystemConnectorDiscovery(
            systemID: status.id,
            displayName: status.displayName,
            status: status.state.rawValue,
            facts: [
                "connector:\(status.id)",
                "connector_state:\(status.state.rawValue)",
                "last_sync:\(status.lastSyncSummary)"
            ],
            evidence: EvidenceRecord(
                action: "discover",
                source: status.displayName,
                result: status.lastSyncSummary,
                validation: status.state == .ready ? .valid : .warning
            )
        )
    }

    func authenticate() async -> SystemConnectorAuthentication {
        let validation = await connector.validate()
        let capabilities = await connector.getCapabilities()
        let allowedActions = capabilities.flatMap(\.actions)
        let approvalActions = capabilities
            .filter(\.requiresApproval)
            .flatMap(\.actions)
        return SystemConnectorAuthentication(
            authenticated: validation.valid,
            principal: "\(connector.id)-service-account",
            role: validation.valid ? "connector_service" : "unauthenticated",
            allowedActions: allowedActions,
            deniedActions: validation.valid ? [] : allowedActions,
            approvalRequirements: approvalActions,
            evidence: EvidenceRecord(
                action: "authenticate",
                source: connector.displayName,
                result: validation.message,
                validation: validation.valid ? .valid : .failed
            )
        )
    }

    func inspect() async -> SystemConnectorInspection {
        let capabilities = await connector.getCapabilities()
        let actions = capabilities.flatMap(\.actions)
        return SystemConnectorInspection(
            capabilities: actions,
            dependencies: ["connector_registry"],
            facts: capabilities.map { "capability:\($0.connectorID):\($0.name)" },
            riskSignals: capabilities
                .filter { $0.riskLevel == .high || $0.requiresApproval }
                .map { "risk:\($0.connectorID):\($0.riskLevel.rawValue):approval=\($0.requiresApproval)" },
            evidence: EvidenceRecord(
                action: "inspect",
                source: connector.displayName,
                result: "Inspected \(actions.count) connector action\(actions.count == 1 ? "" : "s").",
                validation: .valid
            )
        )
    }

    func execute(_ request: SystemConnectorActionRequest) async throws -> SystemConnectorActionResult {
        let connectorRequest = ConnectorRequest(
            id: UUID().uuidString,
            connectorID: connector.id,
            action: request.action,
            payload: request.payload,
            dryRun: request.dryRun,
            simulateFailure: request.payload["simulate_failure"] == "true"
        )
        let response = request.dryRun
            ? try await connector.dryRun(connectorRequest)
            : try await connector.execute(connectorRequest)
        return SystemConnectorActionResult(
            action: request.action,
            success: response.success,
            result: response.message,
            payload: response.payload,
            evidence: EvidenceRecord(
                action: "execute:\(request.action)",
                source: connector.displayName,
                result: response.message,
                validation: response.success ? .valid : .failed
            )
        )
    }

    func validate() async -> SystemConnectorValidation {
        let validation = await connector.validate()
        return SystemConnectorValidation(
            valid: validation.valid,
            message: validation.message,
            evidence: EvidenceRecord(
                action: "validate",
                source: connector.displayName,
                result: validation.message,
                validation: validation.valid ? .valid : .failed
            )
        )
    }

    func collectEvidence() async -> [EvidenceRecord] {
        let status = await connector.status()
        let validation = await connector.validate()
        return [
            EvidenceRecord(
                action: "collectEvidence:status",
                source: connector.displayName,
                result: status.lastSyncSummary,
                validation: status.state == .ready ? .valid : .warning
            ),
            EvidenceRecord(
                action: "collectEvidence:validation",
                source: connector.displayName,
                result: validation.message,
                validation: validation.valid ? .valid : .failed
            )
        ]
    }
}

extension ConnectorRegistry {
    func systemConnectors() -> [any SystemConnector] {
        connectors.map { ConnectorRegistrySystemConnector(connector: $0) }
    }
}
