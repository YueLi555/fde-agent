import Foundation

enum EnterpriseSystemNodeType: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case customer = "CustomerNode"
    case application = "ApplicationNode"
    case integration = "IntegrationNode"
    case api = "APINode"
    case database = "DatabaseNode"
    case workflow = "WorkflowNode"
    case failure = "FailureNode"
    case solution = "SolutionNode"

    var id: String { rawValue }
}

struct CustomerNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var name: String
    var segment: String
    var metadata: [String: String]
}

struct ApplicationNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var name: String
    var owner: String
    var metadata: [String: String]
}

struct IntegrationNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var name: String
    var provider: String
    var metadata: [String: String]
}

struct APINode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var name: String
    var baseURL: String
    var metadata: [String: String]
}

struct DatabaseNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var name: String
    var engine: String
    var metadata: [String: String]
}

struct WorkflowNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var name: String
    var trigger: String
    var metadata: [String: String]
}

struct FailureNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var title: String
    var severity: RiskSeverity
    var metadata: [String: String]
}

struct SolutionNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var title: String
    var summary: String
    var metadata: [String: String]
}

struct EnterpriseSystemNode: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var type: EnterpriseSystemNodeType
    var title: String
    var subtitle: String
    var metadata: [String: String]
    var updatedAt: Date

    init(
        id: String,
        workspaceID: UUID,
        type: EnterpriseSystemNodeType,
        title: String,
        subtitle: String = "",
        metadata: [String: String] = [:],
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.type = type
        self.title = title
        self.subtitle = subtitle
        self.metadata = metadata
        self.updatedAt = updatedAt
    }

    init(_ node: CustomerNode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .customer,
            title: node.name,
            subtitle: node.segment,
            metadata: node.metadata,
            updatedAt: updatedAt
        )
    }

    init(_ node: ApplicationNode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .application,
            title: node.name,
            subtitle: node.owner,
            metadata: node.metadata,
            updatedAt: updatedAt
        )
    }

    init(_ node: IntegrationNode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .integration,
            title: node.name,
            subtitle: node.provider,
            metadata: node.metadata,
            updatedAt: updatedAt
        )
    }

    init(_ node: APINode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .api,
            title: node.name,
            subtitle: node.baseURL,
            metadata: node.metadata,
            updatedAt: updatedAt
        )
    }

    init(_ node: DatabaseNode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .database,
            title: node.name,
            subtitle: node.engine,
            metadata: node.metadata,
            updatedAt: updatedAt
        )
    }

    init(_ node: WorkflowNode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .workflow,
            title: node.name,
            subtitle: node.trigger,
            metadata: node.metadata,
            updatedAt: updatedAt
        )
    }

    init(_ node: FailureNode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .failure,
            title: node.title,
            subtitle: node.severity.rawValue,
            metadata: node.metadata.merging(["severity": node.severity.rawValue]) { current, _ in current },
            updatedAt: updatedAt
        )
    }

    init(_ node: SolutionNode, updatedAt: Date = Date()) {
        self.init(
            id: node.id,
            workspaceID: node.workspaceID,
            type: .solution,
            title: node.title,
            subtitle: node.summary,
            metadata: node.metadata,
            updatedAt: updatedAt
        )
    }
}

enum EnterpriseGraphRelationship: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case dependsOn = "depends_on"
    case connectsTo = "connects_to"
    case failsAt = "fails_at"
    case resolvedBy = "resolved_by"
    case usedBy = "used_by"

    var id: String { rawValue }
}

struct EnterpriseSystemEdge: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var workspaceID: UUID
    var fromNodeID: String
    var toNodeID: String
    var relationship: EnterpriseGraphRelationship
    var evidence: String
    var updatedAt: Date

    init(
        id: String,
        workspaceID: UUID,
        fromNodeID: String,
        toNodeID: String,
        relationship: EnterpriseGraphRelationship,
        evidence: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.fromNodeID = fromNodeID
        self.toNodeID = toNodeID
        self.relationship = relationship
        self.evidence = evidence
        self.updatedAt = updatedAt
    }
}

struct EnterpriseSystemGraphSnapshot: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var nodes: [EnterpriseSystemNode]
    var edges: [EnterpriseSystemEdge]
    var updatedAt: Date

    static func empty(workspaceID: UUID) -> EnterpriseSystemGraphSnapshot {
        EnterpriseSystemGraphSnapshot(workspaceID: workspaceID, nodes: [], edges: [], updatedAt: Date())
    }
}

protocol EnterpriseSystemGraphStoring: Sendable {
    func initialize() async throws
    func save(_ snapshot: EnterpriseSystemGraphSnapshot) async throws
    func load(workspaceID: UUID) async throws -> EnterpriseSystemGraphSnapshot
}

actor InMemoryEnterpriseSystemGraphStore: EnterpriseSystemGraphStoring {
    private var nodesByWorkspace: [UUID: [String: EnterpriseSystemNode]] = [:]
    private var edgesByWorkspace: [UUID: [String: EnterpriseSystemEdge]] = [:]

    func initialize() async throws {}

    func save(_ snapshot: EnterpriseSystemGraphSnapshot) async throws {
        var nodes = nodesByWorkspace[snapshot.workspaceID, default: [:]]
        var edges = edgesByWorkspace[snapshot.workspaceID, default: [:]]
        for node in snapshot.nodes {
            nodes[node.id] = node
        }
        for edge in snapshot.edges {
            edges[edge.id] = edge
        }
        nodesByWorkspace[snapshot.workspaceID] = nodes
        edgesByWorkspace[snapshot.workspaceID] = edges
    }

    func load(workspaceID: UUID) async throws -> EnterpriseSystemGraphSnapshot {
        EnterpriseSystemGraphSnapshot(
            workspaceID: workspaceID,
            nodes: nodesByWorkspace[workspaceID, default: [:]]
                .values
                .sorted { $0.title < $1.title },
            edges: edgesByWorkspace[workspaceID, default: [:]]
                .values
                .sorted { $0.id < $1.id },
            updatedAt: Date()
        )
    }
}

struct DependencyChain: Codable, Hashable, Sendable {
    var nodeTitles: [String]
    var relationships: [EnterpriseGraphRelationship]
}

struct IntegrationRisk: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var detail: String
    var severity: RiskSeverity
    var nodeIDs: [String]
}

struct EnterpriseSystemUnderstandingSummary: Codable, Hashable, Sendable {
    var detectedSystems: [String]
    var dependencies: [String]
    var risks: [IntegrationRisk]
    var previousIncidents: [String]
    var previousSolutions: [String]
    var dependencyChains: [DependencyChain]
    var narrative: String

    static let empty = EnterpriseSystemUnderstandingSummary(
        detectedSystems: [],
        dependencies: [],
        risks: [],
        previousIncidents: [],
        previousSolutions: [],
        dependencyChains: [],
        narrative: "No enterprise system graph context available."
    )

    var isEmpty: Bool {
        detectedSystems.isEmpty
            && dependencies.isEmpty
            && risks.isEmpty
            && previousIncidents.isEmpty
            && previousSolutions.isEmpty
            && dependencyChains.isEmpty
    }
}

struct EnterpriseSystemGraphIntelligence: Sendable {
    func summarize(
        snapshot: EnterpriseSystemGraphSnapshot,
        taskInput: String
    ) -> EnterpriseSystemUnderstandingSummary {
        guard !snapshot.nodes.isEmpty else {
            return .empty
        }

        let chains = detectDependencyChains(snapshot: snapshot)
        let risks = identifyIntegrationRisk(snapshot: snapshot)
        let previousSolutions = findPreviousSolutions(snapshot: snapshot, taskInput: taskInput)
        let incidents = snapshot.nodes
            .filter { $0.type == .failure }
            .prefix(8)
            .map(\.title)

        let detectedSystems = snapshot.nodes
            .filter { [.customer, .application, .integration, .api, .database, .workflow].contains($0.type) }
            .prefix(16)
            .map { "\($0.type.rawValue): \($0.title)" }

        let dependencySummaries = chains
            .prefix(8)
            .map { $0.nodeTitles.joined(separator: " -> ") }

        return EnterpriseSystemUnderstandingSummary(
            detectedSystems: Array(detectedSystems),
            dependencies: Array(dependencySummaries),
            risks: risks,
            previousIncidents: Array(incidents),
            previousSolutions: previousSolutions,
            dependencyChains: chains,
            narrative: narrative(
                systems: Array(detectedSystems),
                chains: chains,
                risks: risks,
                incidents: Array(incidents),
                solutions: previousSolutions
            )
        )
    }

    func detectDependencyChains(snapshot: EnterpriseSystemGraphSnapshot) -> [DependencyChain] {
        let dependencyRelationships: Set<EnterpriseGraphRelationship> = [.dependsOn, .connectsTo, .usedBy]
        let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let adjacency = Dictionary(grouping: snapshot.edges.filter { dependencyRelationships.contains($0.relationship) }) {
            $0.fromNodeID
        }
        let startNodes = snapshot.nodes.filter { [.customer, .application, .workflow].contains($0.type) }
        var chains: [DependencyChain] = []

        for startNode in startNodes {
            walk(
                from: startNode.id,
                nodesByID: nodesByID,
                adjacency: adjacency,
                visited: [startNode.id],
                relationships: [],
                chains: &chains
            )
        }

        return Array(chains.prefix(12))
    }

    func identifyIntegrationRisk(snapshot: EnterpriseSystemGraphSnapshot) -> [IntegrationRisk] {
        let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let failureEdges = snapshot.edges.filter { $0.relationship == .failsAt }
        var risks: [IntegrationRisk] = []

        for edge in failureEdges {
            let failureNode = nodesByID[edge.fromNodeID]?.type == .failure ? nodesByID[edge.fromNodeID] : nodesByID[edge.toNodeID]
            let targetNode = nodesByID[edge.fromNodeID]?.type == .failure ? nodesByID[edge.toNodeID] : nodesByID[edge.fromNodeID]
            guard let failureNode, let targetNode else { continue }
            let severity = failureNode.metadata["severity"].flatMap(RiskSeverity.init(rawValue:)) ?? .medium
            let hasResolution = snapshot.edges.contains { candidate in
                candidate.relationship == .resolvedBy
                    && (candidate.fromNodeID == failureNode.id || candidate.toNodeID == failureNode.id)
            }
            risks.append(
                IntegrationRisk(
                    id: "risk:\(failureNode.id):\(targetNode.id)",
                    title: "\(targetNode.title) failure risk",
                    detail: hasResolution ? failureNode.title : "\(failureNode.title) has no recorded solution.",
                    severity: severity,
                    nodeIDs: [targetNode.id, failureNode.id]
                )
            )
        }

        return risks.sorted { lhs, rhs in
            severityRank(lhs.severity) > severityRank(rhs.severity)
        }
    }

    func findPreviousSolutions(
        snapshot: EnterpriseSystemGraphSnapshot,
        taskInput: String
    ) -> [String] {
        let nodesByID = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.id, $0) })
        let solutionIDs = Set(snapshot.nodes.filter { $0.type == .solution }.map(\.id))
        var solutions: [String] = []

        for edge in snapshot.edges where edge.relationship == .resolvedBy {
            let targetID = solutionIDs.contains(edge.toNodeID) ? edge.toNodeID : edge.fromNodeID
            guard let solution = nodesByID[targetID], solution.type == .solution else { continue }
            solutions.append(solution.subtitle.isEmpty ? solution.title : "\(solution.title): \(solution.subtitle)")
        }

        let tokens = normalizedTokens(taskInput)
        for solution in snapshot.nodes where solution.type == .solution {
            let searchable = normalizedTokens([solution.title, solution.subtitle] + Array(solution.metadata.values))
            if !tokens.isEmpty, !tokens.isDisjoint(with: searchable), !solutions.contains(solution.title) {
                solutions.append(solution.subtitle.isEmpty ? solution.title : "\(solution.title): \(solution.subtitle)")
            }
        }

        return Array(solutions.prefix(8))
    }

    private func walk(
        from nodeID: String,
        nodesByID: [String: EnterpriseSystemNode],
        adjacency: [String: [EnterpriseSystemEdge]],
        visited: [String],
        relationships: [EnterpriseGraphRelationship],
        chains: inout [DependencyChain]
    ) {
        guard visited.count < 7 else { return }
        guard let edges = adjacency[nodeID], !edges.isEmpty else {
            if visited.count > 1 {
                chains.append(
                    DependencyChain(
                        nodeTitles: visited.compactMap { nodesByID[$0]?.title },
                        relationships: relationships
                    )
                )
            }
            return
        }

        for edge in edges {
            guard !visited.contains(edge.toNodeID) else { continue }
            walk(
                from: edge.toNodeID,
                nodesByID: nodesByID,
                adjacency: adjacency,
                visited: visited + [edge.toNodeID],
                relationships: relationships + [edge.relationship],
                chains: &chains
            )
        }
    }

    private func narrative(
        systems: [String],
        chains: [DependencyChain],
        risks: [IntegrationRisk],
        incidents: [String],
        solutions: [String]
    ) -> String {
        let systemCount = systems.count
        let chainCount = chains.count
        let riskText = risks.first.map { "\($0.title) (\($0.severity.rawValue))" } ?? "no active graph risk"
        let incidentText = incidents.first ?? "no previous incidents"
        let solutionText = solutions.first ?? "no previous solutions"
        return "\(systemCount) system(s), \(chainCount) dependency chain(s), top risk: \(riskText), previous incident: \(incidentText), previous solution: \(solutionText)."
    }

    private func severityRank(_ severity: RiskSeverity) -> Int {
        switch severity {
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    private func normalizedTokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
    }

    private func normalizedTokens(_ values: [String]) -> Set<String> {
        normalizedTokens(values.joined(separator: " "))
    }
}
