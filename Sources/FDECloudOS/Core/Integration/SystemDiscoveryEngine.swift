import Foundation

struct DiscoveredSystem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    var status: String
    var capabilities: [String]
    var dependencies: [String]
    var facts: [String]
}

struct SystemEnvironmentRisk: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var systemID: String
    var severity: RiskSeverity
    var title: String
    var detail: String
    var requiresApproval: Bool
}

struct SystemEnvironmentModel: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var connectedSystems: [DiscoveredSystem]
    var environmentGraphNodes: [SystemGraphNode]
    var environmentGraphEdges: [SystemGraphEdge]
    var risks: [SystemEnvironmentRisk]
    var facts: [String]
    var permissionGraph: PermissionGraph
    var evidence: [EvidenceRecord]
    var discoveredAt: Date

    var auditPayload: [String: String] {
        [
            "environment_discovery": "true",
            "environment_system_count": String(connectedSystems.count),
            "environment_connected_systems": connectedSystems.prefix(8).map(\.displayName).joined(separator: " | "),
            "environment_risk_count": String(risks.count),
            "environment_risks": risks.prefix(8).map { "\($0.severity.rawValue):\($0.title)" }.joined(separator: " | "),
            "environment_permission_count": String(permissionGraph.entries.count),
            "environment_evidence_count": String(evidence.count),
            "environment_evidence": evidence.prefix(8).map(\.summary).joined(separator: " | ")
        ]
    }

    var worldModelSystemLabels: [String] {
        connectedSystems.map { "system:\($0.id):\($0.displayName)" }
    }

    var worldModelEvidence: [String] {
        evidence.map(\.summary)
    }
}

struct SystemDiscoveryEngine: Sendable {
    var connectors: [any SystemConnector]

    init(connectors: [any SystemConnector] = ConnectorRegistry.default().systemConnectors()) {
        self.connectors = connectors
    }

    func discover(workspace: Workspace) async -> SystemEnvironmentModel {
        let discoveredAt = Date()
        var systems: [DiscoveredSystem] = []
        var risks: [SystemEnvironmentRisk] = []
        var facts: [String] = []
        var permissionEntries: [PermissionGraphEntry] = []
        var evidence: [EvidenceRecord] = []

        for connector in connectors {
            let discovery = await connector.discover()
            let authentication = await connector.authenticate()
            let inspection = await connector.inspect()
            let validation = await connector.validate()
            let collectedEvidence = await connector.collectEvidence()

            evidence += [
                discovery.evidence,
                authentication.evidence,
                inspection.evidence,
                validation.evidence
            ] + collectedEvidence

            let system = DiscoveredSystem(
                id: discovery.systemID,
                displayName: discovery.displayName,
                status: discovery.status,
                capabilities: inspection.capabilities,
                dependencies: inspection.dependencies,
                facts: uniqueStrings(discovery.facts + inspection.facts)
            )
            systems.append(system)
            facts += system.facts

            permissionEntries.append(
                PermissionGraphEntry(
                    id: "permission:\(workspace.id.uuidString):\(system.id):\(authentication.principal):\(authentication.role)",
                    user: authentication.principal,
                    role: authentication.role,
                    system: system.id,
                    allowedActions: authentication.allowedActions,
                    deniedActions: authentication.deniedActions,
                    approvalRequirements: authentication.approvalRequirements
                )
            )

            risks += risksFromConnector(
                system: system,
                authentication: authentication,
                inspection: inspection,
                validation: validation
            )
        }

        let permissionGraph = PermissionGraph(entries: permissionEntries)
        let graph = buildEnvironmentGraph(
            workspace: workspace,
            systems: systems,
            risks: risks,
            permissionGraph: permissionGraph,
            discoveredAt: discoveredAt
        )

        return SystemEnvironmentModel(
            workspaceID: workspace.id,
            connectedSystems: uniqueSystems(systems),
            environmentGraphNodes: graph.nodes,
            environmentGraphEdges: graph.edges,
            risks: uniqueRisks(risks),
            facts: uniqueStrings(facts + permissionGraph.summaryFacts),
            permissionGraph: permissionGraph,
            evidence: uniqueEvidence(evidence),
            discoveredAt: discoveredAt
        )
    }

    private func risksFromConnector(
        system: DiscoveredSystem,
        authentication: SystemConnectorAuthentication,
        inspection: SystemConnectorInspection,
        validation: SystemConnectorValidation
    ) -> [SystemEnvironmentRisk] {
        var values: [SystemEnvironmentRisk] = []

        if !authentication.authenticated {
            values.append(
                SystemEnvironmentRisk(
                    id: "risk:\(system.id):authentication",
                    systemID: system.id,
                    severity: .high,
                    title: "\(system.displayName) authentication failed",
                    detail: authentication.evidence.result,
                    requiresApproval: true
                )
            )
        }

        if !validation.valid {
            values.append(
                SystemEnvironmentRisk(
                    id: "risk:\(system.id):validation",
                    systemID: system.id,
                    severity: .high,
                    title: "\(system.displayName) validation failed",
                    detail: validation.message,
                    requiresApproval: true
                )
            )
        }

        values += inspection.riskSignals.enumerated().map { index, signal in
            SystemEnvironmentRisk(
                id: "risk:\(system.id):inspection:\(index)",
                systemID: system.id,
                severity: signal.contains(RiskSeverity.high.rawValue) ? .high : .medium,
                title: "\(system.displayName) connector risk",
                detail: signal,
                requiresApproval: signal.contains("approval=true")
            )
        }

        if !authentication.approvalRequirements.isEmpty {
            values.append(
                SystemEnvironmentRisk(
                    id: "risk:\(system.id):approval",
                    systemID: system.id,
                    severity: .high,
                    title: "\(system.displayName) actions require approval",
                    detail: authentication.approvalRequirements.joined(separator: ", "),
                    requiresApproval: true
                )
            )
        }

        return values
    }

    private func buildEnvironmentGraph(
        workspace: Workspace,
        systems: [DiscoveredSystem],
        risks: [SystemEnvironmentRisk],
        permissionGraph: PermissionGraph,
        discoveredAt: Date
    ) -> GraphSnapshot {
        let workspaceNodeID = "environment:\(workspace.id.uuidString):workspace"
        var nodes = [
            SystemGraphNode(
                id: workspaceNodeID,
                workspaceID: workspace.id,
                type: .app,
                title: workspace.displayName,
                subtitle: "Environment discovery root",
                metadata: [
                    "kind": "environment",
                    "permission_entries": String(permissionGraph.entries.count)
                ],
                updatedAt: discoveredAt
            )
        ]
        var edges: [SystemGraphEdge] = []

        for system in systems {
            let systemNodeID = graphID(workspace: workspace, prefix: "system", value: system.id)
            nodes.append(
                SystemGraphNode(
                    id: systemNodeID,
                    workspaceID: workspace.id,
                    type: .api,
                    title: system.displayName,
                    subtitle: system.status,
                    metadata: [
                        "system_id": system.id,
                        "capabilities": system.capabilities.joined(separator: ","),
                        "facts": system.facts.joined(separator: " | ")
                    ],
                    updatedAt: discoveredAt
                )
            )
            edges.append(
                SystemGraphEdge(
                    id: graphID(workspace: workspace, prefix: "edge.environment", value: system.id),
                    workspaceID: workspace.id,
                    fromNodeID: workspaceNodeID,
                    toNodeID: systemNodeID,
                    kind: .dependency,
                    label: "connected_system",
                    updatedAt: discoveredAt
                )
            )

            for dependency in system.dependencies {
                let dependencyNodeID = graphID(workspace: workspace, prefix: "dependency", value: "\(system.id).\(dependency)")
                nodes.append(
                    SystemGraphNode(
                        id: dependencyNodeID,
                        workspaceID: workspace.id,
                        type: .app,
                        title: dependency,
                        subtitle: "External dependency",
                        metadata: ["source_system": system.id],
                        updatedAt: discoveredAt
                    )
                )
                edges.append(
                    SystemGraphEdge(
                        id: graphID(workspace: workspace, prefix: "edge.dependency", value: "\(system.id).\(dependency)"),
                        workspaceID: workspace.id,
                        fromNodeID: systemNodeID,
                        toNodeID: dependencyNodeID,
                        kind: .dependency,
                        label: "depends_on",
                        updatedAt: discoveredAt
                    )
                )
            }
        }

        for risk in risks {
            let riskNodeID = graphID(workspace: workspace, prefix: "risk", value: risk.id)
            nodes.append(
                SystemGraphNode(
                    id: riskNodeID,
                    workspaceID: workspace.id,
                    type: .task,
                    title: risk.title,
                    subtitle: risk.severity.rawValue,
                    metadata: [
                        "system_id": risk.systemID,
                        "detail": risk.detail,
                        "requires_approval": risk.requiresApproval ? "true" : "false"
                    ],
                    updatedAt: discoveredAt
                )
            )
            edges.append(
                SystemGraphEdge(
                    id: graphID(workspace: workspace, prefix: "edge.risk", value: risk.id),
                    workspaceID: workspace.id,
                    fromNodeID: graphID(workspace: workspace, prefix: "system", value: risk.systemID),
                    toNodeID: riskNodeID,
                    kind: .dataFlow,
                    label: "risk_signal",
                    updatedAt: discoveredAt
                )
            )
        }

        return GraphSnapshot(nodes: uniqueNodes(nodes), edges: uniqueEdges(edges))
    }

    private func graphID(workspace: Workspace, prefix: String, value: String) -> String {
        "\(prefix):\(workspace.id.uuidString):\(slug(value))"
    }

    private func slug(_ value: String) -> String {
        value
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber || character == "." || character == "-" ? character : "-"
            }
            .reduce(into: "") { $0.append($1) }
    }

    private func uniqueSystems(_ systems: [DiscoveredSystem]) -> [DiscoveredSystem] {
        var seen = Set<String>()
        var result: [DiscoveredSystem] = []
        for system in systems where !seen.contains(system.id) {
            seen.insert(system.id)
            result.append(system)
        }
        return result
    }

    private func uniqueRisks(_ risks: [SystemEnvironmentRisk]) -> [SystemEnvironmentRisk] {
        var seen = Set<String>()
        var result: [SystemEnvironmentRisk] = []
        for risk in risks where !seen.contains(risk.id) {
            seen.insert(risk.id)
            result.append(risk)
        }
        return result
    }

    private func uniqueEvidence(_ evidence: [EvidenceRecord]) -> [EvidenceRecord] {
        var seen = Set<String>()
        var result: [EvidenceRecord] = []
        for record in evidence {
            let key = "\(record.source)|\(record.action)|\(record.result)|\(record.validation.rawValue)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(record)
        }
        return result
    }

    private func uniqueNodes(_ nodes: [SystemGraphNode]) -> [SystemGraphNode] {
        var seen = Set<String>()
        var result: [SystemGraphNode] = []
        for node in nodes where !seen.contains(node.id) {
            seen.insert(node.id)
            result.append(node)
        }
        return result
    }

    private func uniqueEdges(_ edges: [SystemGraphEdge]) -> [SystemGraphEdge] {
        var seen = Set<String>()
        var result: [SystemGraphEdge] = []
        for edge in edges where !seen.contains(edge.id) {
            seen.insert(edge.id)
            result.append(edge)
        }
        return result
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let safeValue = AgentPresentationSanitizer.safeContent(value, fallback: "")
            guard !safeValue.isEmpty, !seen.contains(safeValue) else { continue }
            seen.insert(safeValue)
            result.append(safeValue)
        }
        return result
    }
}
