import XCTest
@testable import FDECloudOS

final class EnterpriseSystemGraphTests: XCTestCase {
    func testEnterpriseGraphPersistsNodesAndRelationships() async throws {
        let workspace = Workspace.default()
        let store = InMemoryEnterpriseSystemGraphStore()
        let snapshot = sampleEnterpriseGraph(workspaceID: workspace.id)

        try await store.initialize()
        try await store.save(snapshot)

        let loaded = try await store.load(workspaceID: workspace.id)

        XCTAssertEqual(Set(loaded.nodes.map(\.id)), Set(snapshot.nodes.map(\.id)))
        XCTAssertEqual(Set(loaded.edges.map(\.id)), Set(snapshot.edges.map(\.id)))
        XCTAssertTrue(loaded.edges.contains { $0.relationship == .dependsOn })
        XCTAssertTrue(loaded.edges.contains { $0.relationship == .resolvedBy })
    }

    func testEnterpriseGraphIntelligenceTraversesDependenciesAndFindsSolutions() {
        let workspace = Workspace.default()
        let snapshot = sampleEnterpriseGraph(workspaceID: workspace.id)
        let intelligence = EnterpriseSystemGraphIntelligence()

        let chains = intelligence.detectDependencyChains(snapshot: snapshot)
        let risks = intelligence.identifyIntegrationRisk(snapshot: snapshot)
        let solutions = intelligence.findPreviousSolutions(
            snapshot: snapshot,
            taskInput: "Investigate customer API integration failure"
        )
        let summary = intelligence.summarize(
            snapshot: snapshot,
            taskInput: "Investigate customer API integration failure"
        )

        XCTAssertTrue(chains.contains { $0.nodeTitles.joined(separator: " -> ").contains("Customer Portal -> Billing Sync -> Customer API -> Customer Database") })
        XCTAssertEqual(risks.first?.title, "Billing Sync failure risk")
        XCTAssertEqual(risks.first?.severity, .high)
        XCTAssertTrue(solutions.contains { $0.contains("Refresh OAuth token") })
        XCTAssertTrue(summary.previousIncidents.contains("OAuth token expired"))
    }

    func testEnterpriseGraphSummaryEntersContextBundle() async throws {
        let workspace = Workspace.default()
        let root = try makeTemporaryWorkspace()
        try writeFile(root.appendingPathComponent("README.md"), "# Demo")
        let store = InMemoryEnterpriseSystemGraphStore()
        try await store.initialize()
        try await store.save(sampleEnterpriseGraph(workspaceID: workspace.id))
        let diagnosticsStore = ContextCompilerDiagnosticsStore()
        let compiler = InstructionContextCompiler(
            workspaceRootURL: root,
            diagnosticsStore: diagnosticsStore,
            providerDiagnosticsSummary: "Local:enabled",
            persistenceStatus: "SQLitePersistenceStore initialized",
            enterpriseGraphStore: store
        )

        let context = await compiler.compile(
            workspace: workspace,
            taskInput: "Investigate customer API integration failure",
            recentTasks: [],
            graph: ([], []),
            workspaceEvents: [],
            failureEvents: []
        )
        let bundle = try XCTUnwrap(context.contextBundle)
        let diagnostics = await diagnosticsStore.snapshot()

        XCTAssertTrue(bundle.graphSummary.detectedSystems.contains { $0.contains("Customer Portal") })
        XCTAssertTrue(bundle.graphSummary.dependencyChains.contains { $0.contains("Customer Portal -> Billing Sync") })
        XCTAssertTrue(bundle.graphSummary.integrationRisks.contains { $0.contains("OAuth token expired") })
        XCTAssertTrue(bundle.graphSummary.previousSolutions.contains { $0.contains("Refresh OAuth token") })
        XCTAssertTrue(diagnostics.enterpriseSystemGraph.narrative.contains("dependency chain"))
    }

    func testEnterpriseGraphContextDoesNotChangeRuntimeExecutionCommands() async throws {
        let input = "Audit the local workspace and prepare an execution checkpoint"

        let baselinePersistence = InMemoryPersistenceStore()
        try await baselinePersistence.initialize()
        let baselineWorkspace = Workspace.default()
        try await baselinePersistence.saveWorkspace(baselineWorkspace)
        let baselineExecutor = GraphRecordingToolExecutor()
        let baselineKernel = RuntimeKernel(
            persistence: baselinePersistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: baselineExecutor
        )

        let graphPersistence = InMemoryPersistenceStore()
        try await graphPersistence.initialize()
        let graphWorkspace = Workspace.default()
        try await graphPersistence.saveWorkspace(graphWorkspace)
        let graphStore = InMemoryEnterpriseSystemGraphStore()
        try await graphStore.initialize()
        try await graphStore.save(sampleEnterpriseGraph(workspaceID: graphWorkspace.id))
        let graphExecutor = GraphRecordingToolExecutor()
        let graphKernel = RuntimeKernel(
            persistence: graphPersistence,
            eventBus: RuntimeEventBus(),
            contextCompiler: InstructionContextCompiler(enterpriseGraphStore: graphStore),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: graphExecutor
        )

        let baselineTask = try await baselineKernel.submitTask(input: input, workspace: baselineWorkspace)
        let graphTask = try await graphKernel.submitTask(input: input, workspace: graphWorkspace)
        let baselineCommands = await baselineExecutor.executedCommands()
        let graphCommands = await graphExecutor.executedCommands()

        XCTAssertEqual(baselineTask.state, .completed)
        XCTAssertEqual(graphTask.state, .completed)
        XCTAssertEqual(graphCommands, baselineCommands)
    }

    private func sampleEnterpriseGraph(workspaceID: UUID) -> EnterpriseSystemGraphSnapshot {
        let nodes = [
            EnterpriseSystemNode(
                ApplicationNode(
                    id: "application:customer-portal",
                    workspaceID: workspaceID,
                    name: "Customer Portal",
                    owner: "Field Engineering",
                    metadata: ["tier": "customer-facing"]
                )
            ),
            EnterpriseSystemNode(
                IntegrationNode(
                    id: "integration:billing-sync",
                    workspaceID: workspaceID,
                    name: "Billing Sync",
                    provider: "Stripe",
                    metadata: ["auth": "OAuth"]
                )
            ),
            EnterpriseSystemNode(
                APINode(
                    id: "api:customer-api",
                    workspaceID: workspaceID,
                    name: "Customer API",
                    baseURL: "https://api.customer.example",
                    metadata: ["auth": "OAuth"]
                )
            ),
            EnterpriseSystemNode(
                DatabaseNode(
                    id: "database:customer-db",
                    workspaceID: workspaceID,
                    name: "Customer Database",
                    engine: "Postgres",
                    metadata: ["contains": "customer records"]
                )
            ),
            EnterpriseSystemNode(
                FailureNode(
                    id: "failure:oauth-token-expired",
                    workspaceID: workspaceID,
                    title: "OAuth token expired",
                    severity: .high,
                    metadata: ["severity": RiskSeverity.high.rawValue]
                )
            ),
            EnterpriseSystemNode(
                SolutionNode(
                    id: "solution:refresh-oauth-token",
                    workspaceID: workspaceID,
                    title: "Refresh OAuth token",
                    summary: "Rotate the OAuth refresh token and retry Billing Sync.",
                    metadata: ["runbook": "oauth-refresh"]
                )
            )
        ]

        let edges = [
            EnterpriseSystemEdge(
                id: "edge.portal.billing",
                workspaceID: workspaceID,
                fromNodeID: "application:customer-portal",
                toNodeID: "integration:billing-sync",
                relationship: .dependsOn
            ),
            EnterpriseSystemEdge(
                id: "edge.billing.api",
                workspaceID: workspaceID,
                fromNodeID: "integration:billing-sync",
                toNodeID: "api:customer-api",
                relationship: .connectsTo
            ),
            EnterpriseSystemEdge(
                id: "edge.api.database",
                workspaceID: workspaceID,
                fromNodeID: "api:customer-api",
                toNodeID: "database:customer-db",
                relationship: .dependsOn
            ),
            EnterpriseSystemEdge(
                id: "edge.failure.billing",
                workspaceID: workspaceID,
                fromNodeID: "failure:oauth-token-expired",
                toNodeID: "integration:billing-sync",
                relationship: .failsAt
            ),
            EnterpriseSystemEdge(
                id: "edge.failure.solution",
                workspaceID: workspaceID,
                fromNodeID: "failure:oauth-token-expired",
                toNodeID: "solution:refresh-oauth-token",
                relationship: .resolvedBy
            )
        ]

        return EnterpriseSystemGraphSnapshot(
            workspaceID: workspaceID,
            nodes: nodes,
            edges: edges,
            updatedAt: Date()
        )
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEEnterpriseSystemGraphTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor GraphRecordingToolExecutor: ToolExecuting {
    private var commands: [String] = []

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        commands.append(call.command)
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "ok \(call.command)",
            standardError: "",
            duration: 0.001
        )
    }

    func executedCommands() -> [String] {
        commands
    }
}
