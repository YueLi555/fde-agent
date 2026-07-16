import XCTest
@testable import FDECloudOS

final class SystemIntegrationTests: XCTestCase {
    func testConnectorDiscoveryBuildsEnvironmentModel() async throws {
        let workspace = Workspace.default()
        let connector = StaticSystemConnector(
            id: "crm",
            displayName: "Customer CRM",
            allowedActions: ["read_account"],
            approvalRequirements: ["update_account"],
            facts: ["region:us-east-1"],
            dependencies: ["identity-provider"]
        )
        let engine = SystemDiscoveryEngine(connectors: [connector])

        let model = await engine.discover(workspace: workspace)

        XCTAssertEqual(model.connectedSystems.map(\.id), ["crm"])
        XCTAssertTrue(model.facts.contains("region:us-east-1"))
        XCTAssertTrue(model.permissionGraph.summaryFacts.contains { $0.contains("approval_required:crm:update_account") })
        XCTAssertTrue(model.environmentGraphNodes.contains { $0.title == "Customer CRM" })
        XCTAssertTrue(model.environmentGraphEdges.contains { $0.label == "connected_system" })
        XCTAssertTrue(model.evidence.contains { $0.action == "discover" && $0.source == "Customer CRM" })
    }

    func testPermissionGraphDeniesAction() {
        let graph = PermissionGraph(entries: [
            PermissionGraphEntry(
                id: "permission.crm",
                user: "crm-service-account",
                role: "connector_service",
                system: "crm",
                allowedActions: ["read_account"],
                deniedActions: ["delete_account"],
                approvalRequirements: ["update_account"]
            )
        ])

        let decision = graph.decision(
            for: PermissionCheckRequest(
                user: "crm-service-account",
                role: "connector_service",
                system: "crm",
                action: "delete_account"
            )
        )

        XCTAssertEqual(decision, .denied("Denied action `delete_account` on `crm` for role `connector_service`."))
    }

    func testAgentLoopBlocksPermissionDeniedConnectorAction() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let connector = StaticSystemConnector(
            id: "crm",
            displayName: "Customer CRM",
            allowedActions: ["read_account"],
            deniedActions: ["delete_account"]
        )
        let executor = RecordingSystemToolExecutor()
        let deniedTool = connectorTool(id: "tool.crm.delete", command: "connector.crm.delete_account")
        let router = SystemIntegrationDecisionRouter(outputs: [
            noToolOutput(id: "understand"),
            toolOutput(id: "plan-delete", tool: deniedTool),
            toolOutput(id: "execute-delete", tool: deniedTool)
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            systemDiscoveryEngine: SystemDiscoveryEngine(connectors: [connector]),
            configuration: AgentLoopConfiguration(maxLoopIterations: 5)
        )

        let result = try await controller.runMission(input: "Inspect CRM permissions before changing customer data", workspace: workspace)
        let executedCommands = await executor.executedCommands()

        XCTAssertEqual(result.stopReason, .policyViolation)
        XCTAssertTrue(executedCommands.isEmpty)
        XCTAssertTrue(result.events.contains { $0.type == .authorizationDenied })
        XCTAssertTrue(result.events.contains { $0.payload["permission_denial"]?.contains("delete_account") == true })
    }

    func testAgentLoopPausesWhenPermissionRequiresApproval() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let connector = StaticSystemConnector(
            id: "crm",
            displayName: "Customer CRM",
            allowedActions: ["read_account", "update_account"],
            approvalRequirements: ["update_account"]
        )
        let executor = RecordingSystemToolExecutor()
        let approvalTool = connectorTool(id: "tool.crm.update", command: "connector.crm.update_account")
        let router = SystemIntegrationDecisionRouter(outputs: [
            noToolOutput(id: "understand"),
            toolOutput(id: "plan-update", tool: approvalTool),
            toolOutput(id: "execute-update", tool: approvalTool)
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            toolExecutor: executor,
            systemDiscoveryEngine: SystemDiscoveryEngine(connectors: [connector]),
            configuration: AgentLoopConfiguration(maxLoopIterations: 5)
        )

        let result = try await controller.runMission(input: "Update CRM account after permission review", workspace: workspace)
        let executedCommands = await executor.executedCommands()
        let approvals = try await persistence.loadApprovalRequests(workspaceID: workspace.id, state: .pending)

        XCTAssertEqual(result.stopReason, .waitingHuman)
        XCTAssertTrue(executedCommands.isEmpty)
        XCTAssertEqual(approvals.count, 1)
        XCTAssertEqual(approvals.first?.toolCallID, approvalTool.id)
        XCTAssertTrue(result.events.contains { $0.type == .humanApprovalRequested })
    }

    func testAgentLoopPersistsEnvironmentGraphAndWorldModelEvidence() async throws {
        let workspace = Workspace.default()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let connector = StaticSystemConnector(
            id: "billing",
            displayName: "Billing System",
            allowedActions: ["read_invoice"],
            facts: ["billing_mode:production"],
            dependencies: ["payment-processor"]
        )
        let router = SystemIntegrationDecisionRouter(outputs: [
            noToolOutput(id: "understand")
        ])
        let controller = makeController(
            persistence: persistence,
            router: router,
            systemDiscoveryEngine: SystemDiscoveryEngine(connectors: [connector]),
            configuration: AgentLoopConfiguration(maxLoopIterations: 1)
        )

        let result = try await controller.runMission(input: "Understand billing integration environment", workspace: workspace)
        let graph = try await persistence.loadGraph(workspaceID: workspace.id)
        let contextEvent = try XCTUnwrap(result.events.first { $0.type == .contextCompiled })

        XCTAssertTrue(graph.0.contains { $0.title == "Billing System" })
        XCTAssertTrue(graph.1.contains { $0.label == "depends_on" })
        XCTAssertEqual(contextEvent.payload["environment_system_count"], "1")
        XCTAssertTrue(contextEvent.payload["world_model_evidence"]?.contains("Billing System") == true)
    }

    func testConnectorExecutionCreatesEvidenceRecord() async throws {
        let connector = StaticSystemConnector(
            id: "warehouse",
            displayName: "Data Warehouse",
            allowedActions: ["query_health"]
        )

        let result = try await connector.execute(
            SystemConnectorActionRequest(action: "query_health", payload: ["scope": "readiness"], dryRun: true)
        )
        let evidence = await connector.collectEvidence()

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.evidence.action, "execute:query_health")
        XCTAssertEqual(result.evidence.validation, .valid)
        XCTAssertTrue(evidence.contains { $0.action == "execute:query_health" && $0.result.contains("query_health") })
    }

    private func makeController(
        persistence: any PersistenceStore,
        router: any ModelRouting,
        toolExecutor: any ToolExecuting = RecordingSystemToolExecutor(),
        systemDiscoveryEngine: SystemDiscoveryEngine,
        configuration: AgentLoopConfiguration
    ) -> AgentLoopController {
        AgentLoopController(
            persistence: persistence,
            contextCompiler: InstructionContextCompiler(
                workspaceRootURL: URL(fileURLWithPath: NSTemporaryDirectory()),
                workspaceScanner: LocalWorkspaceScanner(maxEntries: 20, maxSummaryEntries: 10)
            ),
            modelRouter: router,
            toolExecutor: toolExecutor,
            systemDiscoveryEngine: systemDiscoveryEngine,
            configuration: configuration
        )
    }

    private func noToolOutput(id: String) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.\(id)",
                    title: "Understand \(id)",
                    intent: "Understand the environment before planning.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(
                    id: "action.\(id)",
                    title: "Inspect environment model",
                    agent: .systemUnderstanding,
                    stepID: "step.\(id)"
                )
            ],
            toolCalls: [],
            risks: [],
            confidence: 0.9
        )
    }

    private func toolOutput(id: String, tool: ToolCall) -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.\(id)",
                    title: "Run \(id)",
                    intent: "Use the connector only after environment intelligence is available.",
                    toolCallID: tool.id,
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(
                    id: "action.\(id)",
                    title: "Evaluate connector permission",
                    agent: .policy,
                    stepID: "step.\(id)"
                )
            ],
            toolCalls: [tool],
            risks: [],
            confidence: 0.88
        )
    }

    private func connectorTool(id: String, command: String) -> ToolCall {
        ToolCall(
            id: id,
            type: .connector,
            command: command,
            arguments: [],
            workingDirectory: nil,
            requiresApproval: false
        )
    }
}

private actor StaticSystemConnector: SystemConnector {
    nonisolated let id: String
    nonisolated let displayName: String
    private let allowedActions: [String]
    private let deniedActions: [String]
    private let approvalRequirements: [String]
    private let facts: [String]
    private let dependencies: [String]
    private var evidence: [EvidenceRecord] = []

    init(
        id: String,
        displayName: String,
        allowedActions: [String],
        deniedActions: [String] = [],
        approvalRequirements: [String] = [],
        facts: [String] = [],
        dependencies: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.allowedActions = allowedActions
        self.deniedActions = deniedActions
        self.approvalRequirements = approvalRequirements
        self.facts = facts
        self.dependencies = dependencies
    }

    func discover() async -> SystemConnectorDiscovery {
        let record = record(action: "discover", result: "\(displayName) discovered.", validation: .valid)
        return SystemConnectorDiscovery(
            systemID: id,
            displayName: displayName,
            status: "Ready",
            facts: ["system:\(id)"] + facts,
            evidence: record
        )
    }

    func authenticate() async -> SystemConnectorAuthentication {
        let record = record(action: "authenticate", result: "\(displayName) service account authenticated.", validation: .valid)
        return SystemConnectorAuthentication(
            authenticated: true,
            principal: "\(id)-service-account",
            role: "connector_service",
            allowedActions: allowedActions,
            deniedActions: deniedActions,
            approvalRequirements: approvalRequirements,
            evidence: record
        )
    }

    func inspect() async -> SystemConnectorInspection {
        let record = record(action: "inspect", result: "\(displayName) capabilities inspected.", validation: .valid)
        return SystemConnectorInspection(
            capabilities: allowedActions + deniedActions + approvalRequirements,
            dependencies: dependencies,
            facts: facts,
            riskSignals: approvalRequirements.map { "risk:\(id):HIGH:approval=true:\($0)" },
            evidence: record
        )
    }

    func execute(_ request: SystemConnectorActionRequest) async throws -> SystemConnectorActionResult {
        let denied = deniedActions.contains(request.action)
        let record = record(
            action: "execute:\(request.action)",
            result: denied ? "\(request.action) denied." : "\(request.action) executed as \(request.dryRun ? "dry run" : "requested").",
            validation: denied ? .failed : .valid
        )
        return SystemConnectorActionResult(
            action: request.action,
            success: !denied,
            result: record.result,
            payload: request.payload,
            evidence: record
        )
    }

    func validate() async -> SystemConnectorValidation {
        let record = record(action: "validate", result: "\(displayName) validation passed.", validation: .valid)
        return SystemConnectorValidation(valid: true, message: record.result, evidence: record)
    }

    func collectEvidence() async -> [EvidenceRecord] {
        evidence
    }

    private func record(
        action: String,
        result: String,
        validation: EvidenceValidationStatus
    ) -> EvidenceRecord {
        let record = EvidenceRecord(
            action: action,
            source: displayName,
            result: result,
            validation: validation
        )
        evidence.append(record)
        return record
    }
}

private actor SystemIntegrationDecisionRouter: ModelRouting {
    private var outputs: [StructuredAgentOutput]
    private var index = 0

    init(outputs: [StructuredAgentOutput]) {
        self.outputs = outputs
    }

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try nextOutput()
    }

    func generateDecision(prompt: CompiledPrompt, context: ExecutionContext) async throws -> StructuredAgentOutput {
        try nextOutput()
    }

    private func nextOutput() throws -> StructuredAgentOutput {
        guard !outputs.isEmpty else {
            throw ModelRoutingError.providerUnavailable("No scripted output available.")
        }
        let output = outputs[min(index, outputs.count - 1)]
        index += 1
        return output
    }
}

private actor RecordingSystemToolExecutor: ToolExecuting {
    private var commands: [String] = []

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        commands.append(call.command)
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "executed",
            standardError: "",
            duration: 0.001
        )
    }

    func executedCommands() -> [String] {
        commands
    }
}
