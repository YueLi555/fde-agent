import XCTest
@testable import FDECloudOS

final class RuntimeCoreTests: XCTestCase {
    func testStructuredOutputValidatorDefersMissingToolCallToPlanReadiness() throws {
        let output = StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step",
                    title: "Step",
                    intent: "Intent",
                    toolCallID: "missing",
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [],
            risks: [],
            confidence: 0.8
        )

        XCTAssertNoThrow(try StructuredOutputValidator().validate(output))
        let readiness = ReadOnlyPlanReadinessValidator().validate(output, workspace: .default())
        XCTAssertFalse(readiness.isReady)
        XCTAssertEqual(readiness.blockerReason, .invalidToolCallReference)
    }

    func testWorkflowStateMachineAllowsCorePath() throws {
        var task = FDETask(
            id: UUID(),
            workspaceID: UUID(),
            title: "Task",
            rawInput: "Task",
            state: .created,
            plan: [],
            riskScore: 0,
            failureProbability: 0,
            performanceScore: 0,
            createdAt: Date(),
            updatedAt: Date()
        )

        let stateMachine = WorkflowStateMachine()
        try stateMachine.transition(&task, to: .planned)
        try stateMachine.transition(&task, to: .running)
        try stateMachine.transition(&task, to: .completed)

        XCTAssertEqual(task.state, .completed)
    }

    func testLocalProviderProducesSchemaCompliantOutput() async throws {
        let workspace = Workspace.default()
        let context = ExecutionContext(
            workspace: workspace,
            policyRules: [],
            graphSummary: "empty",
            recentTaskTitles: [],
            taskFingerprint: TaskFingerprint.make(from: "Investigate GitHub deployment failure"),
            policyDeltas: [],
            failurePatterns: [],
            systemFailureProfile: nil,
            globalExecutionPolicy: nil
        )

        let output = try await LocalDeterministicModelProvider()
            .generatePlan(for: "Investigate GitHub deployment failure", context: context)

        XCTAssertFalse(output.plan.isEmpty)
        XCTAssertFalse(output.toolCalls.isEmpty)
        XCTAssertNoThrow(try StructuredOutputValidator().validate(output))
    }

    func testWorkspaceEngineeringToolExecutorExposesProjectToolsAndPublicReleaseDeniesMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEEngineeringToolExecutor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "let modelClient = \"live\"\n".write(
            to: root.appendingPathComponent("Agent.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "# Test Project\n".write(
            to: root.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        let executor = WorkspaceEngineeringToolExecutor()
        let list = try await executor.execute(
            ToolCall(
                id: "list",
                type: .api,
                command: "engineering.list_directory",
                arguments: ["path=."],
                workingDirectory: root.path,
                requiresApproval: false
            )
        )
        let read = try await executor.execute(
            ToolCall(
                id: "read",
                type: .api,
                command: "engineering.read_file",
                arguments: ["path=Agent.swift"],
                workingDirectory: root.path,
                requiresApproval: false
            )
        )
        let search = try await executor.execute(
            ToolCall(
                id: "search",
                type: .api,
                command: "engineering.search_code",
                arguments: ["query=modelClient", "extensions=swift"],
                workingDirectory: root.path,
                requiresApproval: false
            )
        )
        let inspect = try await executor.execute(
            ToolCall(
                id: "inspect",
                type: .api,
                command: "engineering.inspect_project",
                arguments: [],
                workingDirectory: root.path,
                requiresApproval: false
            )
        )
        let patch = try await executor.execute(
            ToolCall(
                id: "patch",
                type: .api,
                command: "engineering.write_patch",
                arguments: ["path=.fde/patches/live-chat.patch", "content=diff --git a/Agent.swift b/Agent.swift"],
                workingDirectory: root.path,
                requiresApproval: false
            )
        )
        let validation = try await executor.execute(
            ToolCall(
                id: "validation",
                type: .api,
                command: "engineering.report_validation",
                arguments: ["status=passed", "summary=manual smoke checks passed"],
                workingDirectory: root.path,
                requiresApproval: false
            )
        )

        XCTAssertEqual(list.exitCode, 0)
        XCTAssertTrue(list.standardOutput.contains("Agent.swift"))
        XCTAssertEqual(read.exitCode, 0)
        XCTAssertTrue(read.standardOutput.contains("modelClient"))
        XCTAssertEqual(search.exitCode, 0)
        XCTAssertTrue(search.standardOutput.contains("Agent.swift:1"))
        XCTAssertEqual(inspect.exitCode, 0)
        XCTAssertTrue(inspect.standardOutput.contains("Repository:"))
        XCTAssertEqual(patch.exitCode, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".fde/patches/live-chat.patch").path))
        XCTAssertEqual(validation.exitCode, 0)
        XCTAssertTrue(validation.standardOutput.contains("Validation passed"))

        let publicExecutor = PublicReleaseToolExecutor()
        let publicRead = try await publicExecutor.execute(
            ToolCall(
                id: "public-read",
                type: .api,
                command: "engineering.read_file",
                arguments: ["path=Agent.swift"],
                workingDirectory: root.path,
                requiresApproval: false
            )
        )
        XCTAssertEqual(publicRead.exitCode, 0)
        XCTAssertTrue(publicRead.standardOutput.contains("modelClient"))

        do {
            _ = try await publicExecutor.execute(
                ToolCall(
                    id: "public-write",
                    type: .api,
                    command: "engineering.edit_file",
                    arguments: ["path=Agent.swift", "content=changed"],
                    workingDirectory: root.path,
                    requiresApproval: false
                )
            )
            XCTFail("Public release executor must reject workspace mutation")
        } catch {
            XCTAssertEqual(error as? ToolExecutionError, .commandNotAllowed("engineering.edit_file"))
        }
        do {
            _ = try await publicExecutor.execute(
                ToolCall(
                    id: "public-shell",
                    type: .shell,
                    command: "/bin/ls",
                    arguments: [],
                    workingDirectory: root.path,
                    requiresApproval: false
                )
            )
            XCTFail("Public release executor must reject shell execution")
        } catch {
            XCTAssertEqual(error as? ToolExecutionError, .commandNotAllowed("/bin/ls"))
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Agent.swift"), encoding: .utf8),
            "let modelClient = \"live\"\n"
        )
    }

    func testRouterDefaultsToLocalWhenOpenAIKeyIsMissing() async throws {
        let workspace = Workspace.default()
        let context = emptyContext(workspace: workspace, input: "Audit workspace")
        let openAI = OpenAIProvider(apiKey: nil, httpClient: UnusedHTTPClient())
        let providers: [any ModelProvider] = [openAI, LocalDeterministicModelProvider()]
        let diagnosticsStore = ModelProviderDiagnosticsStore(initial: .initial(providers: providers))
        let router = ModelRouter(providers: providers, diagnosticsStore: diagnosticsStore)

        let output = try await router.generatePlan(for: "Audit workspace", context: context)
        let diagnostics = await diagnosticsStore.snapshot()

        XCTAssertTrue(output.toolCalls.contains { $0.command == "/bin/pwd" })
        XCTAssertEqual(diagnostics.activeProvider, ModelProviderKind.local.rawValue)
        XCTAssertTrue(diagnostics.fallbackReason.contains("OPENAI_API_KEY is missing"))
        XCTAssertTrue(diagnostics.lastValidationResult.contains("valid structured output"))
        XCTAssertTrue(
            diagnostics.liveProviderStates.contains {
                $0.provider == ModelProviderKind.openAI.rawValue
                    && $0.liveProvider
                    && !$0.enabled
            }
        )
    }

    func testProviderFactoryAutoSelectsLiveProviderWhenKeyExists() {
        let localConfiguration = ModelProviderConfiguration(
            preferredProvider: nil,
            openAIAPIKey: nil,
            anthropicAPIKey: nil,
            openAIModel: "test-openai",
            claudeModel: "test-claude"
        )
        let autoOpenAIConfiguration = ModelProviderConfiguration(
            preferredProvider: nil,
            openAIAPIKey: "test-key",
            anthropicAPIKey: "test-anthropic",
            openAIModel: "test-openai",
            claudeModel: "test-claude"
        )
        let openAIConfiguration = ModelProviderConfiguration(
            preferredProvider: .openAI,
            openAIAPIKey: "test-key",
            anthropicAPIKey: "test-anthropic",
            openAIModel: "test-openai",
            claudeModel: "test-claude"
        )
        let autoClaudeConfiguration = ModelProviderConfiguration(
            preferredProvider: nil,
            openAIAPIKey: nil,
            anthropicAPIKey: "test-anthropic",
            openAIModel: "test-openai",
            claudeModel: "test-claude"
        )
        let claudeConfiguration = ModelProviderConfiguration(
            preferredProvider: .claude,
            openAIAPIKey: nil,
            anthropicAPIKey: "test-anthropic",
            openAIModel: "test-openai",
            claudeModel: "test-claude"
        )

        XCTAssertEqual(ModelProviderFactory.providers(configuration: localConfiguration).map(\.kind), [.local])
        XCTAssertNil(ModelProviderFactory.narrationProvider(configuration: localConfiguration))
        XCTAssertNil(ModelProviderFactory.chatProvider(configuration: localConfiguration))
        XCTAssertEqual(ModelProviderFactory.providers(configuration: autoOpenAIConfiguration).map(\.kind), [.openAI, .local])
        XCTAssertEqual(ModelProviderFactory.productionProviders(configuration: autoOpenAIConfiguration).map(\.kind), [.openAI])
        XCTAssertEqual(ModelProviderFactory.narrationProvider(configuration: autoOpenAIConfiguration)?.kind, .openAI)
        XCTAssertEqual(ModelProviderFactory.chatProvider(configuration: autoOpenAIConfiguration)?.kind, .openAI)
        XCTAssertEqual(ModelProviderFactory.providers(configuration: openAIConfiguration).map(\.kind), [.openAI, .local])
        XCTAssertEqual(ModelProviderFactory.productionProviders(configuration: openAIConfiguration).map(\.kind), [.openAI])
        XCTAssertEqual(ModelProviderFactory.narrationProvider(configuration: openAIConfiguration)?.kind, .openAI)
        XCTAssertEqual(ModelProviderFactory.chatProvider(configuration: openAIConfiguration)?.kind, .openAI)
        XCTAssertEqual(ModelProviderFactory.providers(configuration: autoClaudeConfiguration).map(\.kind), [.claude, .local])
        XCTAssertNil(ModelProviderFactory.narrationProvider(configuration: autoClaudeConfiguration))
        XCTAssertEqual(ModelProviderFactory.chatProvider(configuration: autoClaudeConfiguration)?.kind, .claude)
        XCTAssertEqual(ModelProviderFactory.providers(configuration: claudeConfiguration).map(\.kind), [.claude, .local])
        XCTAssertNil(ModelProviderFactory.narrationProvider(configuration: claudeConfiguration))
        XCTAssertEqual(ModelProviderFactory.chatProvider(configuration: claudeConfiguration)?.kind, .claude)
    }

    func testModelConfigurationReadsOpenAIKeyFromSecureStoreWhenEnvironmentIsMissing() throws {
        let secureStore = MockSecureValueStore()
        try secureStore.save("keychain-openai-key", for: .providerToken(provider: "OpenAI", workspaceID: nil))

        let configuration = ModelProviderConfiguration.environment(
            [
                "OPENAI_MODEL": "test-openai",
                "ANTHROPIC_MODEL": "test-claude"
            ],
            secureStore: secureStore
        )

        XCTAssertEqual(configuration.openAIAPIKey, "keychain-openai-key")
        XCTAssertEqual(ModelProviderFactory.chatProvider(configuration: configuration)?.kind, .openAI)
    }

    func testMalformedLiveProviderFallsBackToLocal() async throws {
        let workspace = Workspace.default()
        let context = emptyContext(workspace: workspace, input: "Audit workspace")
        let providers: [any ModelProvider] = [
            MalformedLiveProvider(),
            LocalDeterministicModelProvider()
        ]
        let diagnosticsStore = ModelProviderDiagnosticsStore(initial: .initial(providers: providers))
        let router = ModelRouter(providers: providers, diagnosticsStore: diagnosticsStore)

        let output = try await router.generatePlan(for: "Audit workspace", context: context)
        let diagnostics = await diagnosticsStore.snapshot()

        XCTAssertTrue(output.toolCalls.contains { $0.command == "/bin/pwd" })
        XCTAssertEqual(diagnostics.activeProvider, ModelProviderKind.local.rawValue)
        XCTAssertTrue(diagnostics.fallbackReason.contains(ModelProviderKind.openAI.rawValue))
        XCTAssertTrue(diagnostics.fallbackReason.contains("Planner output must include at least one plan step"))
        XCTAssertTrue(diagnostics.lastValidationResult.contains(ModelProviderKind.local.rawValue))
        XCTAssertNotNil(diagnostics.lastLatencyMilliseconds)
    }

    func testOpenAIPlannerRequestsStrictJSONSchemaAndDecodesPlan() async throws {
        let workspace = Workspace.default()
        let context = emptyContext(workspace: workspace, input: "Audit workspace")
        let client = CapturingPlannerHTTPClient(content: schemaValidPlannerJSON)
        let openAI = OpenAIProvider(apiKey: "test-key", model: "test-model", httpClient: client)
        let router = ModelRouter(providers: [openAI, LocalDeterministicModelProvider()])

        let output = try await router.generatePlan(for: "Audit workspace", context: context)
        let capturedBody = await client.lastRequestBody()
        let requestBody = try XCTUnwrap(capturedBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(requestBody.utf8)) as? [String: Any]
        )
        let inputMessages = try XCTUnwrap(body["input"] as? [[String: Any]])
        let systemMessage = try XCTUnwrap(inputMessages.first?["content"] as? String)
        let userMessage = try XCTUnwrap(inputMessages.dropFirst().first?["content"] as? String)
        let text = try XCTUnwrap(body["text"] as? [String: Any])
        let format = try XCTUnwrap(text["format"] as? [String: Any])
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        let required = try XCTUnwrap(schema["required"] as? [String])

        XCTAssertEqual(output.toolCalls.map(\.command), ["/bin/pwd"])
        XCTAssertTrue(systemMessage.contains("mission state PLAN"))
        XCTAssertTrue(systemMessage.contains("MissionStateMachine controls behavior"))
        XCTAssertTrue(userMessage.contains(#""current_mission_state":"PLAN""#))
        XCTAssertTrue(userMessage.contains(#""output_contract""#))
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["name"] as? String, "structured_agent_output")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(required), Set(["plan", "actions", "tool_calls", "risks", "confidence"]))
        XCTAssertFalse(requestBody.contains("json_object"))
        XCTAssertFalse(requestBody.contains("```"))
    }

    func testOpenAIPlannerRejectsSchemaInvalidOutputAndFallsBackToLocal() async throws {
        let workspace = Workspace.default()
        let context = emptyContext(workspace: workspace, input: "Audit workspace")
        let client = CapturingPlannerHTTPClient(
            content: #"{"plan":[],"actions":[],"risks":[],"confidence":0.9}"#
        )
        let openAI = OpenAIProvider(apiKey: "test-key", model: "test-model", httpClient: client)
        let providers: [any ModelProvider] = [openAI, LocalDeterministicModelProvider()]
        let diagnosticsStore = ModelProviderDiagnosticsStore(initial: .initial(providers: providers))
        let router = ModelRouter(providers: providers, diagnosticsStore: diagnosticsStore)

        let output = try await router.generatePlan(for: "Audit workspace", context: context)
        let diagnostics = await diagnosticsStore.snapshot()

        XCTAssertTrue(output.toolCalls.contains { $0.command == "/bin/pwd" })
        XCTAssertEqual(diagnostics.activeProvider, ModelProviderKind.local.rawValue)
        XCTAssertTrue(diagnostics.fallbackReason.contains("JSON schema validation failed"))
    }

    func testOpenAIPlannerRejectsMarkdownWrappedOutputAndFallsBackToLocal() async throws {
        let workspace = Workspace.default()
        let context = emptyContext(workspace: workspace, input: "Audit workspace")
        let client = CapturingPlannerHTTPClient(
            content: "```json\n\(schemaValidPlannerJSON)\n```"
        )
        let openAI = OpenAIProvider(apiKey: "test-key", model: "test-model", httpClient: client)
        let providers: [any ModelProvider] = [openAI, LocalDeterministicModelProvider()]
        let diagnosticsStore = ModelProviderDiagnosticsStore(initial: .initial(providers: providers))
        let router = ModelRouter(providers: providers, diagnosticsStore: diagnosticsStore)

        let output = try await router.generatePlan(for: "Audit workspace", context: context)
        let diagnostics = await diagnosticsStore.snapshot()

        XCTAssertTrue(output.toolCalls.contains { $0.command == "/bin/pwd" })
        XCTAssertEqual(diagnostics.activeProvider, ModelProviderKind.local.rawValue)
        XCTAssertTrue(diagnostics.fallbackReason.contains("wrapped or malformed structured JSON"))
    }

    func testWorkspaceScannerIgnoresSecretsAndBuildArtifacts() throws {
        let root = try makeTemporaryWorkspace()
        try writeFile(root.appendingPathComponent("Package.swift"), "let package = Package(name: \"Demo\")")
        try writeFile(root.appendingPathComponent("README.md"), "# Demo")
        try writeFile(root.appendingPathComponent("Sources/App.swift"), "print(\"ok\")")
        try writeFile(root.appendingPathComponent("Tests/AppTests.swift"), "import XCTest")
        try writeFile(root.appendingPathComponent(".env"), "API_KEY=SUPER_SECRET_VALUE")
        try writeFile(root.appendingPathComponent(".build/debug/artifact.txt"), "ignored")
        try writeFile(root.appendingPathComponent("node_modules/pkg/index.js"), "ignored")

        let snapshot = LocalWorkspaceScanner().scan(rootURL: root)
        let encoded = try JSONCoding.encode(snapshot)

        XCTAssertTrue(snapshot.readmePresent)
        XCTAssertTrue(snapshot.packageIndicators.contains("SwiftPM"))
        XCTAssertTrue(snapshot.sourceDirectories.contains("Sources"))
        XCTAssertTrue(snapshot.testFiles.contains("Tests/AppTests.swift"))
        XCTAssertTrue(snapshot.redactions.contains { $0.path == ".env" })
        XCTAssertGreaterThanOrEqual(snapshot.ignoredPathsCount, 2)
        XCTAssertFalse(encoded.contains("SUPER_SECRET_VALUE"))
        XCTAssertFalse(snapshot.fileTreeSummary.contains { $0.contains(".build") || $0.contains("node_modules") || $0 == ".env" })
    }

    func testContextBundleIncludesWorkspaceAndPolicySummaryWithoutSecrets() async throws {
        let root = try makeTemporaryWorkspace()
        try writeFile(root.appendingPathComponent("README.md"), "# Demo")
        try writeFile(root.appendingPathComponent("Sources/App.swift"), "print(\"ok\")")
        try writeFile(root.appendingPathComponent(".env.local"), "TOKEN=DO_NOT_LEAK")
        let workspace = Workspace.default()
        let policy = globalPolicyAvoidingList(workspaceID: workspace.id)
        let delta = ExecutionPolicyDelta(
            id: UUID(),
            workspaceID: workspace.id,
            sourceTaskID: nil,
            parentEventID: nil,
            kind: .avoidFailedTool,
            taskFingerprint: "*",
            failureSignature: "workspace-inspection|TOOL_EXECUTION|/bin/ls|tool.workspace.list",
            avoidToolCommand: "/bin/ls",
            replacementToolCommand: "/usr/bin/env",
            retryBudget: 1,
            reorderCheckpointBeforeRiskyTool: true,
            summary: "Avoid /bin/ls in test context.",
            createdAt: Date()
        )
        let compiler = InstructionContextCompiler(
            workspaceRootURL: root,
            diagnosticsStore: ContextCompilerDiagnosticsStore(),
            providerDiagnosticsSummary: "Local:enabled",
            persistenceStatus: "SQLitePersistenceStore initialized"
        )

        let context = await compiler.compile(
            workspace: workspace,
            taskInput: "Audit workspace",
            recentTasks: [],
            graph: ([], []),
            policyDeltas: [delta],
            workspaceEvents: [],
            failureEvents: [],
            globalExecutionPolicy: policy
        )
        let bundle = try XCTUnwrap(context.contextBundle)
        let encoded = try JSONCoding.encode(bundle)

        XCTAssertTrue(bundle.workspace.readmePresent)
        XCTAssertTrue(bundle.workspace.sourceDirectories.contains("Sources"))
        XCTAssertTrue(bundle.policySummary.avoidedTools.contains("/bin/ls"))
        XCTAssertEqual(bundle.policySummary.fallbackMappings["/bin/ls"], "/usr/bin/env")
        XCTAssertEqual(bundle.taskMemory.globalExecutionPolicySummary, policy.summary)
        XCTAssertEqual(bundle.redactions.count, 1)
        XCTAssertFalse(encoded.contains("DO_NOT_LEAK"))
    }

    func testWorkspaceLocalProjectRootPersistsInSQLite() async throws {
        let root = try makeTemporaryWorkspace()
        let agentRoot = try makeTemporaryWorkspace()
        let databaseURL = root.appendingPathComponent("FDECloudOS.sqlite")
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Project",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: root.path,
            localAgentProjectRoot: agentRoot.path
        )

        try await persistence.saveWorkspace(workspace)
        let loaded = try await persistence.loadWorkspaces()

        XCTAssertEqual(loaded.first?.localProjectRoot, root.standardizedFileURL.path)
        XCTAssertEqual(loaded.first?.localAgentProjectRoot, agentRoot.standardizedFileURL.path)
    }

    func testContextCompilerUsesWorkspaceLocalProjectRoot() async throws {
        let fallbackRoot = try makeTemporaryWorkspace()
        let projectRoot = try makeTemporaryWorkspace()
        try writeFile(fallbackRoot.appendingPathComponent("README.md"), "# Wrong Root")
        try writeFile(projectRoot.appendingPathComponent("Sources/App.swift"), "print(\"ok\")")
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Project",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: projectRoot.path
        )
        let compiler = InstructionContextCompiler(workspaceRootURL: fallbackRoot)

        let context = await compiler.compile(
            workspace: workspace,
            taskInput: "Audit workspace",
            recentTasks: [],
            graph: ([], [])
        )
        let bundle = try XCTUnwrap(context.contextBundle)

        XCTAssertEqual(bundle.workspace.rootPath, projectRoot.standardizedFileURL.path)
        XCTAssertTrue(bundle.workspace.sourceDirectories.contains("Sources"))
        XCTAssertFalse(bundle.workspace.readmePaths.contains("README.md"))
    }

    func testContextCompilerIncludesLegacyAndAgentCodebases() async throws {
        let legacyRoot = try makeTemporaryWorkspace()
        let agentRoot = try makeTemporaryWorkspace()
        try writeFile(legacyRoot.appendingPathComponent("Sources/App.swift"), "print(\"legacy\")")
        try writeFile(agentRoot.appendingPathComponent("src/agent.ts"), "export const agent = true")
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Integration",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacyRoot.path,
            localAgentProjectRoot: agentRoot.path
        )
        let compiler = InstructionContextCompiler()

        let context = await compiler.compile(
            workspace: workspace,
            taskInput: "Can this project integrate the AI agent?",
            recentTasks: [],
            graph: ([], [])
        )
        let bundle = try XCTUnwrap(context.contextBundle)

        XCTAssertEqual(bundle.workspace.rootPath, legacyRoot.standardizedFileURL.path)
        XCTAssertEqual(bundle.workspace.agentRootPath, agentRoot.standardizedFileURL.path)
        XCTAssertEqual(bundle.codebases.map(\.role), ["legacy_software", "ai_agent"])
        XCTAssertEqual(bundle.codebases.first?.rootPath, legacyRoot.standardizedFileURL.path)
        XCTAssertEqual(bundle.codebases.last?.rootPath, agentRoot.standardizedFileURL.path)
        XCTAssertTrue(bundle.codebases.first?.sourceDirectories.contains("Sources") == true)
        XCTAssertTrue(bundle.codebases.last?.sourceDirectories.contains("src") == true)
    }

    func testArchitecturePlannerInspectsAgentProjectWhenSelected() async throws {
        let legacyRoot = try makeTemporaryWorkspace()
        let agentRoot = try makeTemporaryWorkspace()
        try writeFile(legacyRoot.appendingPathComponent("Sources/App.swift"), "print(\"legacy\")")
        try writeFile(agentRoot.appendingPathComponent("src/agent.ts"), "export const agent = true")
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Integration",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacyRoot.path,
            localAgentProjectRoot: agentRoot.path
        )
        let context = await InstructionContextCompiler().compile(
            workspace: workspace,
            taskInput: "看看这个项目可以接ai agent吗",
            recentTasks: [],
            graph: ([], [])
        )

        let output = try await LocalDeterministicModelProvider().generatePlan(
            for: "看看这个项目可以接ai agent吗",
            context: context
        )

        XCTAssertTrue(output.plan.contains { $0.id == "step.agent-root" })
        XCTAssertTrue(output.plan.contains { $0.id == "step.agent-sources" })
        XCTAssertTrue(output.plan.contains { $0.id == "step.legacy-source" })
        XCTAssertTrue(output.plan.contains { $0.id == "step.agent-source" })
        XCTAssertTrue(output.toolCalls.contains { $0.id == "tool.agent.root.inspect" && $0.workingDirectory == agentRoot.standardizedFileURL.path })
        XCTAssertTrue(output.toolCalls.contains { $0.id == "tool.agent.sources.inspect" && $0.workingDirectory == agentRoot.standardizedFileURL.path })
        XCTAssertTrue(output.toolCalls.contains { $0.id == "tool.legacy.source.read" && $0.command == "/usr/bin/head" && $0.arguments.contains("Sources/App.swift") })
        XCTAssertTrue(output.toolCalls.contains { $0.id == "tool.agent.source.read" && $0.command == "/usr/bin/head" && $0.arguments.contains("src/agent.ts") })
    }

    func testRuntimeScopesToolWorkingDirectoriesToWorkspaceProjectRoot() async throws {
        let projectRoot = try makeTemporaryWorkspace()
        try FileManager.default.createDirectory(
            at: projectRoot.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Project",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: projectRoot.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let executor = WorkingDirectoryRecordingExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [RelativeWorkingDirectoryPlanner()]),
            toolExecutor: executor
        )

        let task = try await kernel.submitTask(input: "Audit workspace", workspace: workspace)
        let workingDirectories = await executor.executedWorkingDirectories()

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(
            workingDirectories,
            [
                projectRoot.standardizedFileURL.path,
                projectRoot.appendingPathComponent("Sources", isDirectory: true).standardizedFileURL.path
            ]
        )
    }

    func testRuntimeAllowsToolWorkingDirectoryInsideAgentProjectRoot() async throws {
        let projectRoot = try makeTemporaryWorkspace()
        let agentRoot = try makeTemporaryWorkspace()
        try FileManager.default.createDirectory(
            at: agentRoot.appendingPathComponent("src", isDirectory: true),
            withIntermediateDirectories: true
        )
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Integration",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: projectRoot.path,
            localAgentProjectRoot: agentRoot.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let executor = WorkingDirectoryRecordingExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [AgentProjectWorkingDirectoryPlanner(agentRoot: agentRoot.path)]),
            toolExecutor: executor,
            requiresProjectScope: true
        )

        let task = try await kernel.submitTask(input: "Audit integration", workspace: workspace)
        let workingDirectories = await executor.executedWorkingDirectories()

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(
            workingDirectories,
            [
                projectRoot.standardizedFileURL.path,
                agentRoot.standardizedFileURL.path
            ]
        )
    }

    func testRuntimeBlocksToolWorkingDirectoryOutsideProjectRoot() async throws {
        let projectRoot = try makeTemporaryWorkspace()
        let outsideRoot = try makeTemporaryWorkspace()
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Project",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: projectRoot.path
        )
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        try await persistence.saveWorkspace(workspace)
        let executor = RecordingToolExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [OutsideProjectWorkingDirectoryPlanner(workingDirectory: outsideRoot.path)]),
            toolExecutor: executor
        )

        let task = try await kernel.submitTask(input: "Audit workspace", workspace: workspace)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let commands = await executor.executedCommands()

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(
            events.contains {
                $0.type == .toolFailed
                    && $0.payload["project_root"] == projectRoot.standardizedFileURL.path
                    && ($0.payload["error"]?.contains("outside selected project scope") ?? false)
            }
        )
    }

    func testRuntimeCanRequireBothProjectRootsBeforeTaskCreation() async throws {
        let legacyRoot = try makeTemporaryWorkspace()
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: UUID(),
            name: "Scoped Project",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: legacyRoot.path
        )
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            requiresProjectScope: true
        )

        do {
            _ = try await kernel.submitTask(input: "Audit workspace", workspace: workspace)
            XCTFail("Expected missing AI agent root to reject task creation.")
        } catch let error as RuntimeKernelError {
            XCTAssertEqual(error, .projectRootRequired)
        }
    }

    func testRuntimeCanRequireProjectRootBeforeTaskCreation() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            requiresProjectScope: true
        )

        do {
            _ = try await kernel.submitTask(input: "Audit workspace", workspace: workspace)
            XCTFail("Expected project root requirement to reject task creation.")
        } catch let error as RuntimeKernelError {
            XCTAssertEqual(error, .projectRootRequired)
        }
    }

    func testPlannerReceivesContextBundleAndDiagnosticsMarksPassedToPlanner() async throws {
        let root = try makeTemporaryWorkspace()
        try writeFile(root.appendingPathComponent("README.md"), "# Demo")
        let workspace = Workspace.default()
        let contextDiagnostics = ContextCompilerDiagnosticsStore()
        let compiler = InstructionContextCompiler(
            workspaceRootURL: root,
            diagnosticsStore: contextDiagnostics,
            providerDiagnosticsSummary: "Local:enabled",
            persistenceStatus: "InMemoryPersistenceStore initialized"
        )
        let context = await compiler.compile(
            workspace: workspace,
            taskInput: "Audit workspace",
            recentTasks: [],
            graph: ([], []),
            workspaceEvents: [],
            failureEvents: []
        )
        let provider = ContextCapturingProvider()
        let router = ModelRouter(providers: [provider], contextDiagnosticsStore: contextDiagnostics)

        _ = try await router.generatePlan(for: "Audit workspace", context: context)
        let receivedBundle = await provider.receivedBundle()
        let diagnostics = await contextDiagnostics.snapshot()

        XCTAssertNotNil(receivedBundle)
        XCTAssertTrue(diagnostics.contextPassedToPlanner)
        XCTAssertGreaterThan(diagnostics.contextBundleSizeBytes, 0)
        XCTAssertGreaterThan(diagnostics.filesScanned, 0)
    }

    func testMockKeychainStoresAndRetrievesSecureValues() throws {
        let store = MockSecureValueStore()
        let workspaceID = UUID()
        let sessionKey = SecureValueKey.sessionToken(workspaceID: workspaceID)
        let providerKey = SecureValueKey.providerToken(provider: "OpenAI", workspaceID: workspaceID)
        let connectorKey = SecureValueKey.connectorToken(connectorID: "github", workspaceID: workspaceID)
        let secretKey = SecureValueKey.workspaceSecret(name: "local-placeholder", workspaceID: workspaceID)

        try store.save("session-token-placeholder", for: sessionKey)
        try store.save("provider-token-placeholder", for: providerKey)
        try store.save("connector-token-placeholder", for: connectorKey)
        try store.save("workspace-secret-placeholder", for: secretKey)

        XCTAssertEqual(try store.load(for: sessionKey), "session-token-placeholder")
        XCTAssertEqual(try store.load(for: providerKey), "provider-token-placeholder")
        XCTAssertEqual(try store.load(for: connectorKey), "connector-token-placeholder")
        XCTAssertEqual(try store.load(for: secretKey), "workspace-secret-placeholder")

        try store.delete(for: sessionKey)
        XCTAssertNil(try store.load(for: sessionKey))
    }

    func testSQLiteSessionMetadataNeverStoresTokenValues() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEIdentity-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        let secureStore = MockSecureValueStore()
        let repository = SessionRepository(persistence: persistence, secureStore: secureStore)
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)

        let credential = try await repository.startLocalSession(
            subject: "token-test-user",
            provider: "Local Session",
            workspace: workspace
        )
        let secureValues = secureStore.allValues()
        let databaseBytes = try Data(contentsOf: databaseURL)
        let databaseText = String(decoding: databaseBytes, as: UTF8.self)

        XCTAssertEqual(credential.workspaceID, workspace.id)
        XCTAssertFalse(secureValues.isEmpty)
        for secureValue in secureValues {
            XCTAssertFalse(databaseText.contains(secureValue))
        }
    }

    func testWorkspaceMemoryAndPolicyDoNotLeakAcrossWorkspaces() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspaceA = Workspace(id: UUID(), name: "Workspace A", role: .fde, createdAt: Date())
        let workspaceB = Workspace(id: UUID(), name: "Workspace B", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspaceA)
        try await persistence.saveWorkspace(workspaceB)
        let delta = ExecutionPolicyDelta(
            id: UUID(),
            workspaceID: workspaceA.id,
            sourceTaskID: nil,
            parentEventID: nil,
            kind: .avoidFailedTool,
            taskFingerprint: "*",
            failureSignature: "workspace-inspection|TOOL_EXECUTION|/bin/ls|tool.workspace.list",
            avoidToolCommand: "/bin/ls",
            replacementToolCommand: "/usr/bin/env",
            retryBudget: 1,
            reorderCheckpointBeforeRiskyTool: true,
            summary: "Workspace A policy only.",
            createdAt: Date()
        )
        try await persistence.savePolicyDelta(delta)
        try await persistence.saveTaskExecutionMemory(
            syntheticMemory(
                workspaceID: workspaceA.id,
                signature: "workspace-inspection|TOOL_EXECUTION|/bin/ls|tool.workspace.list",
                score: 70
            )
        )

        XCTAssertNotEqual(workspaceA.policyNamespace, workspaceB.policyNamespace)
        XCTAssertNotEqual(workspaceA.memoryNamespace, workspaceB.memoryNamespace)
        let workspaceAPolicyDeltas = try await persistence.loadPolicyDeltas(workspaceID: workspaceA.id)
        let workspaceAMemory = try await persistence.loadTaskExecutionMemory(workspaceID: workspaceA.id)
        let workspaceBPolicyDeltas = try await persistence.loadPolicyDeltas(workspaceID: workspaceB.id)
        let workspaceBMemory = try await persistence.loadTaskExecutionMemory(workspaceID: workspaceB.id)
        XCTAssertEqual(workspaceAPolicyDeltas.count, 1)
        XCTAssertEqual(workspaceAMemory.count, 1)
        XCTAssertTrue(workspaceBPolicyDeltas.isEmpty)
        XCTAssertTrue(workspaceBMemory.isEmpty)
    }

    func testRBACRolePermissionsAreLocalAndDeterministic() {
        let authorization = AuthorizationService()
        let admin = Workspace(id: UUID(), name: "Admin", role: .admin, createdAt: Date())
        let fde = Workspace(id: UUID(), name: "FDE", role: .fde, createdAt: Date())
        let user = Workspace(id: UUID(), name: "User", role: .user, createdAt: Date())

        XCTAssertTrue(authorization.hasPermission(.viewDiagnostics, in: admin))
        XCTAssertTrue(authorization.hasPermission(.manageWorkspace, in: admin))
        XCTAssertTrue(authorization.hasPermission(.manageConnectors, in: admin))
        XCTAssertTrue(authorization.hasPermission(.executeTool, in: fde))
        XCTAssertTrue(authorization.hasPermission(.updatePolicy, in: fde))
        XCTAssertFalse(authorization.hasPermission(.executeTool, in: user))
        XCTAssertFalse(authorization.hasPermission(.approveRiskyAction, in: user))
        XCTAssertFalse(authorization.hasPermission(.manageConnectors, in: user))
    }

    func testWorkspaceSwitchUpdatesSessionAndContextWorkspaceIdentity() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let secureStore = MockSecureValueStore()
        let repository = SessionRepository(persistence: persistence, secureStore: secureStore)
        let workspaceA = Workspace(id: UUID(), name: "Workspace A", role: .fde, createdAt: Date())
        let workspaceB = Workspace(id: UUID(), name: "Workspace B", role: .admin, createdAt: Date())
        try await persistence.saveWorkspace(workspaceA)
        try await persistence.saveWorkspace(workspaceB)

        _ = try await repository.startLocalSession(subject: "local-user", provider: "Local Session", workspace: workspaceA)
        let switchedCredential = try await repository.switchWorkspace(to: workspaceB)
        let context = await InstructionContextCompiler().compile(
            workspace: workspaceB,
            taskInput: "Audit workspace",
            recentTasks: [],
            graph: ([], []),
            workspaceEvents: [],
            failureEvents: []
        )
        let bundle = try XCTUnwrap(context.contextBundle)

        XCTAssertEqual(switchedCredential?.workspaceID, workspaceB.id)
        XCTAssertEqual(bundle.workspace.workspaceID, workspaceB.id)
        XCTAssertEqual(bundle.workspace.orgID, workspaceB.orgID)
        XCTAssertEqual(bundle.workspace.role, UserRole.admin.rawValue)
        XCTAssertEqual(bundle.workspace.policyNamespace, workspaceB.policyNamespace)
        XCTAssertEqual(bundle.workspace.memoryNamespace, workspaceB.memoryNamespace)
        XCTAssertEqual(bundle.workspace.eventNamespace, workspaceB.eventNamespace)
    }

    func testRuntimeKernelExecutesEndToEndLoop() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )

        let task = try await kernel.submitTask(
            input: "Audit the local workspace and prepare an execution checkpoint",
            workspace: workspace
        )

        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let graph = try await persistence.loadGraph(workspaceID: workspace.id)
        let feedback = try await persistence.loadFeedback(workspaceID: workspace.id)
        let replay = try await kernel.replay(taskID: task.id, workspaceID: workspace.id)

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(
            events.contains {
                $0.type == .taskCreated
                    && $0.payload["workspace_id"] == workspace.id.uuidString
                    && $0.payload["event_namespace"] == workspace.eventNamespace
            }
        )
        XCTAssertTrue(events.contains { $0.type == .contextCompiled })
        XCTAssertTrue(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains { $0.type == .stepExecuted })
        XCTAssertTrue(events.contains { $0.type == .taskCompleted })
        XCTAssertTrue(events.contains { $0.type == .feedbackGenerated })
        XCTAssertTrue(events.contains { $0.type == .policyUpdated })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
        XCTAssertFalse(graph.0.isEmpty)
        XCTAssertFalse(feedback.isEmpty)
        XCTAssertEqual(replay.count, events.count)
    }

    func testEvidenceRequiredPlanOnlyRequestRemainsPlannedWithoutExecutionEvents() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [PlanOnlyPlanner()]),
            completionPolicy: .evidenceRequired
        )

        let task = try await kernel.submitTask(
            input: "Create an implementation plan only; do not execute it.",
            workspace: workspace
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .planned)
        XCTAssertTrue(events.contains {
            $0.type == .planGenerated
                && $0.payload["mission_disposition"] == "PLANNED"
                && $0.payload["completion_contract"] == RuntimeCompletionContractKind.planOnly.rawValue
        })
        XCTAssertFalse(events.contains { $0.summary == "Execution started" })
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
    }

    func testEvidenceRequiredExecutablePlanWithoutToolsFailsWithoutStartingExecution() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [PlanOnlyPlanner()]),
            completionPolicy: .evidenceRequired
        )

        let task = try await kernel.submitTask(
            input: "Modify the title text in App.swift.",
            workspace: workspace
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .failed)
        XCTAssertFalse(events.contains { $0.summary == "Execution started" })
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        XCTAssertTrue(events.contains {
            $0.payload["completion_gate_passed"] == "false"
                && $0.payload["completion_gate_reason"]?.contains("successful file inspection") == true
        })
    }

    func testModificationCompletionContractRequiresInspectionDiffAndLaterVerification() {
        let input = "Modify the title in Sources/App.swift, then run swift build."
        let contract = RuntimeCompletionContract(
            input: input,
            intent: MissionIntentParser().parse(input)
        )
        let events = [
            completionContractEvent(
                type: .stepExecuted,
                sequence: 1,
                summary: "Read App.swift",
                payload: [
                    "tool_call_id": "tool.read",
                    "command": "engineering.read_file",
                    "arguments": "path=Sources/App.swift",
                    "target_path": "Sources/App.swift",
                    "exit_code": "0",
                    "success": "true"
                ]
            ),
            completionContractEvent(
                type: .stepExecuted,
                sequence: 2,
                summary: "Wrote source diff",
                payload: [
                    "tool_call_id": "tool.patch",
                    "command": "engineering.write_patch",
                    "arguments": "path=.fde/patches/title.diff content=diff --git a/Sources/App.swift b/Sources/App.swift",
                    "exit_code": "0",
                    "success": "true",
                    "stdout": "diff_nonempty=true; created_artifact=.fde/patches/title.diff"
                ]
            ),
            completionContractEvent(
                type: .stepExecuted,
                sequence: 3,
                summary: "swift build passed",
                payload: [
                    "tool_call_id": "tool.build",
                    "command": "/usr/bin/swift",
                    "arguments": "build",
                    "exit_code": "0",
                    "success": "true",
                    "stdout": "Build complete"
                ]
            )
        ]

        let evaluation = contract.evaluate(events: events)

        XCTAssertEqual(contract.kind, .modification)
        XCTAssertTrue(evaluation.allowed)
        XCTAssertEqual(evaluation.inspectedTargets, ["Sources/App.swift"])
        XCTAssertEqual(evaluation.changedArtifacts, [".fde/patches/title.diff"])
        XCTAssertEqual(evaluation.verificationCommands, ["/usr/bin/swift build"])
        XCTAssertTrue(evaluation.report.contains("Sources/App.swift"))
        XCTAssertTrue(evaluation.report.contains("swift build"))
    }

    func testModificationCompletionContractRejectsSyntheticPhasesAndMissingDiff() {
        let input = "Modify the title in Sources/App.swift, then run swift build."
        let contract = RuntimeCompletionContract(
            input: input,
            intent: MissionIntentParser().parse(input)
        )
        let events = [
            completionContractEvent(type: .contextCompiled, sequence: 1, summary: "Context compiled"),
            completionContractEvent(type: .planGenerated, sequence: 2, summary: "Plan generated"),
            completionContractEvent(
                type: .stateUpdated,
                sequence: 3,
                summary: "Execution started",
                payload: ["mission_state": MissionState.execute.rawValue]
            ),
            completionContractEvent(
                type: .toolCalled,
                sequence: 4,
                summary: "Patch tool called",
                payload: [
                    "tool_call_id": "tool.patch",
                    "command": "engineering.write_patch"
                ]
            ),
            completionContractEvent(
                type: .stepExecuted,
                sequence: 5,
                summary: "Mutation arguments were accepted but no diff was observed",
                payload: [
                    "tool_call_id": "tool.edit",
                    "command": "engineering.edit_file",
                    "arguments": "path=Sources/App.swift new_contents=Changed title",
                    "exit_code": "0",
                    "success": "true",
                    "stdout": "request accepted"
                ]
            ),
            completionContractEvent(
                type: .stepExecuted,
                sequence: 6,
                summary: "Read App.swift",
                payload: [
                    "tool_call_id": "tool.read",
                    "command": "engineering.read_file",
                    "arguments": "path=Sources/App.swift",
                    "exit_code": "0",
                    "success": "true"
                ]
            ),
            completionContractEvent(
                type: .stepExecuted,
                sequence: 7,
                summary: "swift build passed",
                payload: [
                    "tool_call_id": "tool.build",
                    "command": "/usr/bin/swift",
                    "arguments": "build",
                    "exit_code": "0",
                    "success": "true"
                ]
            )
        ]

        let evaluation = contract.evaluate(events: events)

        XCTAssertFalse(evaluation.allowed)
        XCTAssertTrue(evaluation.reason.contains("non-empty source diff"))
        XCTAssertTrue(evaluation.changedArtifacts.isEmpty)
    }

    func testModificationCompletionContractDoesNotClearFailureWithUnrelatedValidation() {
        let input = "Modify the title in Sources/App.swift, then run swift build."
        let contract = RuntimeCompletionContract(
            input: input,
            intent: MissionIntentParser().parse(input)
        )
        let events = [
            completionContractEvent(
                type: .stepExecuted,
                sequence: 1,
                summary: "Read App.swift",
                payload: [
                    "tool_call_id": "tool.read",
                    "command": "engineering.read_file",
                    "arguments": "path=Sources/App.swift",
                    "exit_code": "0"
                ]
            ),
            completionContractEvent(
                type: .stepExecuted,
                sequence: 2,
                summary: "Wrote source diff",
                payload: [
                    "tool_call_id": "tool.patch",
                    "command": "engineering.write_patch",
                    "arguments": "path=.fde/patches/title.diff content=diff --git a/Sources/App.swift b/Sources/App.swift",
                    "exit_code": "0",
                    "stdout": "diff_nonempty=true; created_artifact=.fde/patches/title.diff"
                ]
            ),
            completionContractEvent(
                type: .toolFailed,
                sequence: 3,
                summary: "Applying the patch failed",
                payload: [
                    "tool_call_id": "tool.apply",
                    "step_id": "step.apply",
                    "command": "engineering.apply_patch",
                    "success": "false"
                ]
            ),
            completionContractEvent(
                type: .stepExecuted,
                sequence: 4,
                summary: "swift build passed",
                payload: [
                    "tool_call_id": "tool.build",
                    "command": "/usr/bin/swift",
                    "arguments": "build",
                    "exit_code": "0"
                ]
            )
        ]

        let evaluation = contract.evaluate(events: events)

        XCTAssertFalse(evaluation.allowed)
        XCTAssertEqual(evaluation.unresolvedErrors.count, 1)
        XCTAssertTrue(evaluation.reason.contains("unresolved tool or policy errors"))
    }

    func testCommandAndInspectionCompletionContractsRequireTheirOwnResultEvidence() {
        let commandInput = "Run swift build"
        let commandContract = RuntimeCompletionContract(
            input: commandInput,
            intent: MissionIntentParser().parse(commandInput)
        )
        let resultWithoutExit = completionContractEvent(
            type: .stepExecuted,
            sequence: 1,
            summary: "Build returned",
            payload: [
                "tool_call_id": "tool.build",
                "command": "/usr/bin/swift",
                "arguments": "build",
                "success": "true"
            ]
        )
        let resultWithExit = completionContractEvent(
            type: .stepExecuted,
            sequence: 2,
            summary: "Build returned",
            payload: [
                "tool_call_id": "tool.build",
                "command": "/usr/bin/swift",
                "arguments": "build",
                "exit_code": "0"
            ]
        )

        XCTAssertEqual(commandContract.kind, .commandExecution)
        XCTAssertFalse(commandContract.evaluate(events: [resultWithoutExit]).allowed)
        XCTAssertTrue(commandContract.evaluate(events: [resultWithExit]).allowed)

        let inspectionInput = "Inspect Sources/App.swift read-only"
        let inspectionContract = RuntimeCompletionContract(
            input: inspectionInput,
            intent: MissionIntentParser().parse(inspectionInput)
        )
        let syntheticContext = completionContractEvent(
            type: .contextCompiled,
            sequence: 1,
            summary: "Workspace context compiled",
            payload: ["success": "true"]
        )
        let readResult = completionContractEvent(
            type: .stepExecuted,
            sequence: 2,
            summary: "Read App.swift",
            payload: [
                "tool_call_id": "tool.read",
                "command": "engineering.read_file",
                "arguments": "path=Sources/App.swift",
                "workspace_identity": "legacy",
                "success": "true"
            ]
        )
        let groundedAnswer = completionContractEvent(
            type: .stateUpdated,
            sequence: 3,
            summary: "Grounded inspection answer",
            payload: [
                "lifecycle_event": "INSPECTION_COMPLETED",
                "grounded_answer": "true",
                "final_answer": "Sources/App.swift was inspected."
            ]
        )

        XCTAssertEqual(inspectionContract.kind, .readOnlyInspection)
        XCTAssertFalse(inspectionContract.evaluate(events: [syntheticContext]).allowed)
        XCTAssertFalse(inspectionContract.evaluate(events: [syntheticContext, readResult]).allowed)
        XCTAssertTrue(inspectionContract.evaluate(events: [syntheticContext, readResult, groundedAnswer]).allowed)
    }

    func testEvidenceRequiredCompletionGateRejectsEchoOnlySimulation() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [EchoOnlyPlanner()]),
            completionPolicy: .evidenceRequired
        )

        let task = try await kernel.submitTask(
            input: "Complete mission with a checkpoint only",
            workspace: workspace
        )

        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let feedback = try await persistence.loadFeedback(workspaceID: workspace.id)

        XCTAssertEqual(task.state, .failed)
        XCTAssertTrue(events.contains { $0.type == .stepExecuted && $0.payload["command"] == "/bin/echo" })
        XCTAssertTrue(events.contains { $0.type == .stateUpdated && $0.payload["completion_gate_passed"] == "false" })
        XCTAssertFalse(events.contains { $0.type == .taskCompleted })
        XCTAssertTrue(feedback.isEmpty)
        let executionStarted = try XCTUnwrap(events.first { $0.summary == "Execution started" })
        let toolCalled = try XCTUnwrap(events.first { $0.type == .toolCalled })
        XCTAssertLessThan(executionStarted.sequence, toolCalled.sequence)
        XCTAssertEqual(events.filter { $0.summary == "Execution started" }.count, 1)
    }

    func testEventStreamMirrorsSQLiteEventsAndEnrichesDistributionMetadata() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEEventStream-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let eventBus = RuntimeEventBus()
        let remoteSink = TrackingRemoteEventSink()
        let nodeRegistry = TrackingNodeRegistry()
        let eventStream = InMemoryEventStream(
            eventBus: eventBus,
            ingestionPoint: CloudEventIngestionPoint(state: .disabled, remoteSink: remoteSink),
            nodeRegistry: nodeRegistry,
            nodeRegistration: .placeholder(workspaceID: workspace.id)
        )
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: eventStream,
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: RecordingToolExecutor()
        )

        let task = try await kernel.submitTask(
            input: "Audit the local workspace and prepare an execution checkpoint",
            workspace: workspace
        )
        let persistedEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let streamedEvents = eventStream.replay(.task(workspaceID: workspace.id, taskID: task.id))
        let registrations = nodeRegistry.registrations()

        XCTAssertEqual(streamedEvents.map(\.id), persistedEvents.map(\.id))
        XCTAssertEqual(streamedEvents.map(\.sequence), persistedEvents.map(\.sequence))
        XCTAssertEqual(registrations.map(\.workspaceID), [workspace.id])
        XCTAssertEqual(remoteSink.enqueuedCount(), 0)
        XCTAssertTrue(
            persistedEvents.allSatisfy {
                $0.metadata.workspaceID == workspace.id
                    && $0.metadata.correlationID == task.id.uuidString
                    && $0.metadata.nodeID == nil
                    && $0.metadata.distributedReady
                    && $0.payload["workspace_id"] == workspace.id.uuidString
                    && $0.payload["node_id"] == ""
                    && $0.payload["correlation_id"] == task.id.uuidString
                    && $0.payload["distributed_ready"] == "true"
            }
        )
    }

    func testReplayRemainsDeterministicWithEventStreamBackbone() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let eventBus = RuntimeEventBus()
        let eventStream = InMemoryEventStream(eventBus: eventBus)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: eventStream,
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: RecordingToolExecutor()
        )

        let task = try await kernel.submitTask(
            input: "Audit the local workspace and prepare an execution checkpoint",
            workspace: workspace
        )
        let persistedEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let graph = try await persistence.loadGraph(workspaceID: workspace.id)
        let sqliteReplay = try await kernel.replay(taskID: task.id, workspaceID: workspace.id)
        let repeatedReplay = try await kernel.replay(taskID: task.id, workspaceID: workspace.id)
        let streamReplay = try ReplayEngine().frames(
            events: eventStream.replay(.task(workspaceID: workspace.id, taskID: task.id)),
            graph: graph
        )

        XCTAssertEqual(sqliteReplay, repeatedReplay)
        XCTAssertEqual(sqliteReplay, streamReplay)
        XCTAssertEqual(sqliteReplay.count, persistedEvents.count)
    }

    func testLiveExecutionMapperRendersHumanEventTranslations() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let events = [
            liveEvent(.taskCreated, sequence: 1, workspaceID: workspace.id, taskID: taskID, summary: "Task created"),
            liveEvent(.contextCompiled, sequence: 2, workspaceID: workspace.id, taskID: taskID, summary: "Workspace analyzed"),
            liveEvent(.planGenerated, sequence: 3, workspaceID: workspace.id, taskID: taskID, summary: "Plan ready"),
            liveEvent(
                .toolCalled,
                sequence: 4,
                workspaceID: workspace.id,
                taskID: taskID,
                summary: "api: /usr/bin/curl",
                payload: ["command": "/usr/bin/curl"]
            ),
            liveEvent(.taskCompleted, sequence: 5, workspaceID: workspace.id, taskID: taskID, summary: "Done")
        ]

        let snapshot = LiveExecutionMapper.snapshot(task: nil, events: events)

        XCTAssertEqual(
            snapshot.timeline.map(\.humanTitle),
            [
                "Mission Created",
                "System Understanding Agent analyzed environment",
                "Planner Agent created execution plan",
                "Executor Agent running tool: /usr/bin/curl",
                "Mission completed"
            ]
        )
        XCTAssertEqual(snapshot.state, .completed)
    }

    func testLiveExecutionMapperRendersStateTransitions() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let created = liveEvent(.taskCreated, sequence: 1, workspaceID: workspace.id, taskID: taskID)
        let context = liveEvent(.contextCompiled, sequence: 2, workspaceID: workspace.id, taskID: taskID)
        let plan = liveEvent(.planGenerated, sequence: 3, workspaceID: workspace.id, taskID: taskID)
        let tool = liveEvent(.toolCalled, sequence: 4, workspaceID: workspace.id, taskID: taskID)
        let step = liveEvent(.stepExecuted, sequence: 5, workspaceID: workspace.id, taskID: taskID)
        let completed = liveEvent(.taskCompleted, sequence: 6, workspaceID: workspace.id, taskID: taskID)

        XCTAssertEqual(LiveExecutionMapper.state(for: nil, events: []), .idle)
        XCTAssertEqual(LiveExecutionMapper.state(for: nil, events: [created]), .understanding)
        XCTAssertEqual(LiveExecutionMapper.state(for: nil, events: [created, context]), .planning)
        XCTAssertEqual(LiveExecutionMapper.state(for: nil, events: [created, context, plan]), .planning)
        XCTAssertEqual(LiveExecutionMapper.state(for: nil, events: [created, context, plan, tool]), .executing)
        XCTAssertEqual(LiveExecutionMapper.state(for: nil, events: [created, context, plan, tool, step]), .verifying)
        XCTAssertEqual(LiveExecutionMapper.state(for: nil, events: [created, context, plan, tool, step, completed]), .completed)
    }

    func testLiveExecutionHeaderProjectsRepairableFailuresAsBlocked() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let task = liveTask(id: taskID, workspaceID: workspace.id, state: .blocked)

        for blocker in [
            PlanReadinessBlocker.workspaceScopeMismatch.rawValue,
            PlanReadinessBlocker.plannerTimeout.rawValue
        ] {
            let blocked = liveEvent(
                .stateUpdated,
                sequence: 1,
                workspaceID: workspace.id,
                taskID: taskID,
                payload: [
                    "state": TaskState.blocked.rawValue,
                    "blocker_reason": blocker
                ]
            )
            XCTAssertEqual(LiveExecutionMapper.snapshot(task: task, events: [blocked]).state, .blocked)
        }
    }

    func testLiveExecutionMapperRendersApprovalWaitingUIState() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let task = liveTask(
            id: taskID,
            workspaceID: workspace.id,
            state: .pendingApproval
        )
        let approval = liveEvent(
            .humanApprovalRequested,
            sequence: 1,
            workspaceID: workspace.id,
            taskID: taskID,
            summary: "High-risk approval requested",
            payload: [
                "approval_request_id": UUID().uuidString,
                "command": "/bin/rm",
                "risk_level": "high"
            ]
        )

        let snapshot = LiveExecutionMapper.snapshot(task: task, events: [approval])

        XCTAssertEqual(snapshot.state, .waitingApproval)
        XCTAssertEqual(snapshot.timeline.first?.humanTitle, "Waiting for human approval")
        XCTAssertTrue(snapshot.timeline.first?.developerTrace.contains { $0.key == "risk_level" && $0.value == "high" } == true)
    }

    func testLiveExecutionMapperRendersCompletionArtifacts() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let task = liveTask(
            id: taskID,
            workspaceID: workspace.id,
            state: .completed,
            plan: [
                PlanStep(id: "inspect", title: "Inspect API", intent: "Check dependency", toolCallID: "tool.api", requiresApproval: false),
                PlanStep(id: "verify", title: "Verify recovery", intent: "Validate result", toolCallID: "tool.verify", requiresApproval: false)
            ],
            riskScore: 42,
            failureProbability: 0.18,
            performanceScore: 91
        )
        let feedback = FeedbackInsight(
            id: UUID(),
            workspaceID: workspace.id,
            taskID: taskID,
            kind: .bugReport,
            title: "Customer API failure isolated",
            detail: "Permission issue detected.",
            createdAt: Date()
        )
        let delta = ExecutionPolicyDelta(
            id: UUID(),
            workspaceID: workspace.id,
            sourceTaskID: taskID,
            parentEventID: nil,
            kind: .avoidFailedTool,
            taskFingerprint: "api-failure",
            failureSignature: "permission",
            avoidToolCommand: "/usr/bin/curl",
            replacementToolCommand: "/usr/bin/env",
            retryBudget: 1,
            reorderCheckpointBeforeRiskyTool: true,
            summary: "Avoid failed API probe.",
            createdAt: Date()
        )
        let diagnostics = ContextCompilerDiagnostics(
            filesScanned: 24,
            ignoredPathsCount: 2,
            redactionsCount: 1,
            contextBundleSizeBytes: 2048,
            lastCompileLatencyMilliseconds: 12,
            contextPassedToPlanner: true,
            rootPath: "/workspace",
            compiledAt: Date()
        )

        let snapshot = LiveExecutionMapper.snapshot(
            task: task,
            events: [liveEvent(.taskCompleted, sequence: 1, workspaceID: workspace.id, taskID: taskID)],
            feedback: [feedback],
            policyDeltas: [delta],
            contextDiagnostics: diagnostics
        )
        let artifacts = Dictionary(uniqueKeysWithValues: snapshot.artifacts.map { ($0.kind, $0) })

        XCTAssertEqual(artifacts[.executionPlan]?.value, "2 steps")
        XCTAssertEqual(artifacts[.riskScore]?.value, "42")
        XCTAssertEqual(artifacts[.fdeScore]?.value, "91")
        XCTAssertEqual(artifacts[.discoveredDependency]?.value, "24 files")
        XCTAssertEqual(artifacts[.report]?.detail, "Customer API failure isolated")
        XCTAssertEqual(artifacts[.policyUpdate]?.detail, "Avoid failed API probe.")
    }

    func testLiveExecutionMapperIsReplayCompatibleWithPersistedEventOrdering() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let first = liveEvent(.taskCreated, sequence: 1, workspaceID: workspace.id, taskID: taskID)
        let second = liveEvent(.planGenerated, sequence: 2, workspaceID: workspace.id, taskID: taskID)
        let third = liveEvent(.toolCalled, sequence: 3, workspaceID: workspace.id, taskID: taskID)

        let liveSnapshot = LiveExecutionMapper.snapshot(task: nil, events: [first, second, third])
        let replaySnapshot = LiveExecutionMapper.snapshot(task: nil, events: [third, first, second])

        XCTAssertEqual(replaySnapshot.timeline.map(\.id), liveSnapshot.timeline.map(\.id))
        XCTAssertEqual(replaySnapshot.timeline.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(replaySnapshot.state, .executing)
    }

    func testEventStreamBackboneDoesNotChangeLocalExecutionCommands() async throws {
        let baselinePersistence = InMemoryPersistenceStore()
        try await baselinePersistence.initialize()
        let baselineWorkspace = Workspace.default()
        try await baselinePersistence.saveWorkspace(baselineWorkspace)
        let baselineExecutor = RecordingToolExecutor()
        let baselineKernel = RuntimeKernel(
            persistence: baselinePersistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: baselineExecutor
        )

        let streamedPersistence = InMemoryPersistenceStore()
        try await streamedPersistence.initialize()
        let streamedWorkspace = Workspace.default()
        try await streamedPersistence.saveWorkspace(streamedWorkspace)
        let streamedExecutor = RecordingToolExecutor()
        let streamedBus = RuntimeEventBus()
        let streamedKernel = RuntimeKernel(
            persistence: streamedPersistence,
            eventBus: streamedBus,
            eventStream: InMemoryEventStream(eventBus: streamedBus),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: streamedExecutor
        )

        let baselineTask = try await baselineKernel.submitTask(
            input: "Audit the local workspace and prepare an execution checkpoint",
            workspace: baselineWorkspace
        )
        let streamedTask = try await streamedKernel.submitTask(
            input: "Audit the local workspace and prepare an execution checkpoint",
            workspace: streamedWorkspace
        )
        let baselineCommands = await baselineExecutor.executedCommands()
        let streamedCommands = await streamedExecutor.executedCommands()

        XCTAssertEqual(baselineTask.state, .completed)
        XCTAssertEqual(streamedTask.state, .completed)
        XCTAssertEqual(streamedCommands, baselineCommands)
    }

    func testCloudControlPlaneClassifiesEventsWithoutNetworkRouting() {
        let workspace = Workspace.default()
        let taskID = UUID()
        let distributableEvent = makeTestEvent(type: .taskCreated, workspaceID: workspace.id, taskID: taskID)
        let localOnlyEvent = makeTestEvent(type: .connectorDryRun, workspaceID: workspace.id, taskID: taskID)
        let systemOnlyEvent = makeTestEvent(type: .sessionStarted, workspaceID: workspace.id, taskID: nil)
        let endpoint = TrackingEventIngestionEndpoint()
        let controlPlane = FoundationCloudControlPlane(eventIngestionEndpoint: endpoint)

        let distributableDecision = controlPlane.routeEvent(
            distributableEvent,
            workspace: workspace,
            cloudRoutingEnabled: true
        )
        let localOnlyDecision = controlPlane.routeEvent(localOnlyEvent, workspace: workspace)
        let systemOnlyDecision = controlPlane.routeEvent(systemOnlyEvent, workspace: workspace)

        XCTAssertEqual(distributableEvent.metadata.eventClassification, .distributable)
        XCTAssertEqual(localOnlyEvent.metadata.eventClassification, .localOnly)
        XCTAssertEqual(systemOnlyEvent.metadata.eventClassification, .systemOnly)
        XCTAssertTrue(distributableDecision.cloudRoutingEnabled)
        XCTAssertEqual(distributableDecision.route, .localRuntimeOnly)
        XCTAssertEqual(localOnlyDecision.route, .localRuntimeOnly)
        XCTAssertEqual(systemOnlyDecision.route, .notRouted)
        XCTAssertFalse(distributableDecision.networkAttempted)
        XCTAssertFalse(localOnlyDecision.networkAttempted)
        XCTAssertFalse(systemOnlyDecision.networkAttempted)
        XCTAssertEqual(endpoint.ingestedCount(), 0)
    }

    func testCloudRoutingFlagDoesNotAffectRuntimeExecution() async throws {
        let baselinePersistence = InMemoryPersistenceStore()
        try await baselinePersistence.initialize()
        let baselineWorkspace = Workspace.default()
        try await baselinePersistence.saveWorkspace(baselineWorkspace)
        let baselineExecutor = RecordingToolExecutor()
        let baselineKernel = RuntimeKernel(
            persistence: baselinePersistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: baselineExecutor
        )

        let distributedPersistence = InMemoryPersistenceStore()
        try await distributedPersistence.initialize()
        let distributedWorkspace = Workspace(
            id: UUID(),
            name: "Prepared Distributed Workspace",
            role: .fde,
            createdAt: Date(),
            allowedNodes: [LogicalNode.localMacNodeID, LogicalNode.cloudNodeID],
            executionScope: .multiNodePrepared,
            distributionPolicy: .metadataOnly
        )
        try await distributedPersistence.saveWorkspace(distributedWorkspace)
        let distributedExecutor = RecordingToolExecutor()
        let distributedKernel = RuntimeKernel(
            persistence: distributedPersistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: distributedExecutor
        )

        let input = "Audit the local workspace and prepare an execution checkpoint"
        let baselineTask = try await baselineKernel.submitTask(input: input, workspace: baselineWorkspace)
        let distributedTask = try await distributedKernel.submitTask(input: input, workspace: distributedWorkspace)
        let baselineCommands = await baselineExecutor.executedCommands()
        let distributedCommands = await distributedExecutor.executedCommands()
        let distributedEvents = try await distributedPersistence.loadEvents(workspaceID: distributedWorkspace.id, taskID: distributedTask.id)
        let decision = FoundationCloudControlPlane().routeEvent(
            try XCTUnwrap(distributedEvents.first),
            workspace: distributedWorkspace,
            cloudRoutingEnabled: true
        )
        let executionDecision = FoundationCloudControlPlane().routeExecution(
            ExecutionRoutingRequest(
                workspace: distributedWorkspace,
                taskID: distributedTask.id,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .api,
                eventClassification: .distributable,
                taskSummary: distributedTask.title
            )
        )

        XCTAssertEqual(baselineTask.state, .completed)
        XCTAssertEqual(distributedTask.state, .completed)
        XCTAssertEqual(distributedCommands, baselineCommands)
        XCTAssertTrue(distributedEvents.allSatisfy { !$0.metadata.cloudRoutingEnabled })
        XCTAssertTrue(decision.cloudRoutingEnabled)
        XCTAssertEqual(decision.route, .localRuntimeOnly)
        XCTAssertEqual(decision.targetNodeIDs, [LogicalNode.localMacNodeID])
        XCTAssertFalse(decision.networkAttempted)
        XCTAssertEqual(executionDecision.selectedNode.type, .cloudNode)
        XCTAssertTrue(executionDecision.executionRemainsLocal)
        XCTAssertFalse(executionDecision.networkAttempted)
    }

    func testExecutionRouterSelectsNodeTypeFromTaskMetadata() {
        let workspace = Workspace(
            id: UUID(),
            name: "Routing Workspace",
            role: .fde,
            createdAt: Date(),
            allowedNodes: [
                LogicalNode.localMacNodeID,
                LogicalNode.cloudNodeID,
                LogicalNode.agentNodeID,
                LogicalNode.workerNodeID
            ],
            executionScope: .multiNodePrepared,
            distributionPolicy: .metadataOnly
        )
        let controlPlane = FoundationCloudControlPlane()

        let cloudDecision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .api,
                eventClassification: .distributable
            )
        )
        let agentDecision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskComplexity: .medium,
                riskLevel: .high,
                toolType: .shell,
                eventClassification: .distributable
            )
        )
        let workerDecision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskComplexity: .medium,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .distributable
            )
        )

        XCTAssertEqual(cloudDecision.selectedNode.type, .cloudNode)
        XCTAssertEqual(cloudDecision.fallbackNode.type, .macNode)
        XCTAssertEqual(cloudDecision.selectedNode.capacity, .elastic)
        XCTAssertEqual(agentDecision.selectedNode.type, .agentNode)
        XCTAssertEqual(workerDecision.selectedNode.type, .workerNode)
        XCTAssertTrue([cloudDecision, agentDecision, workerDecision].allSatisfy(\.executionRemainsLocal))
        XCTAssertTrue([cloudDecision, agentDecision, workerDecision].allSatisfy { !$0.networkAttempted })
    }

    func testExecutionRouterPinsLocalOnlyToMacNode() {
        let workspace = Workspace(
            id: UUID(),
            name: "Local Only Routing Workspace",
            role: .fde,
            createdAt: Date(),
            allowedNodes: [LogicalNode.localMacNodeID, LogicalNode.cloudNodeID],
            executionScope: .multiNodePrepared,
            distributionPolicy: .metadataOnly
        )

        let decision = FoundationCloudControlPlane().routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .connector,
                eventClassification: .localOnly
            )
        )

        XCTAssertEqual(decision.selectedNode.type, .macNode)
        XCTAssertEqual(decision.fallbackNode.type, .macNode)
        XCTAssertEqual(decision.confidence, 1.0)
        XCTAssertTrue(decision.executionRemainsLocal)
        XCTAssertFalse(decision.networkAttempted)
    }

    func testExecutionRouterRoutesSystemOnlyToAgentOrWorker() {
        let workspace = Workspace(
            id: UUID(),
            name: "System Routing Workspace",
            role: .admin,
            createdAt: Date(),
            allowedNodes: [LogicalNode.localMacNodeID, LogicalNode.agentNodeID, LogicalNode.workerNodeID],
            executionScope: .multiNodePrepared,
            distributionPolicy: .metadataOnly
        )
        let controlPlane = FoundationCloudControlPlane()

        let agentDecision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskComplexity: .low,
                riskLevel: .low,
                toolType: nil,
                eventClassification: .systemOnly
            )
        )
        let workerDecision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: nil,
                eventClassification: .systemOnly
            )
        )

        XCTAssertEqual(agentDecision.selectedNode.type, .agentNode)
        XCTAssertEqual(workerDecision.selectedNode.type, .workerNode)
        XCTAssertTrue(agentDecision.reason.contains("SYSTEM_ONLY"))
        XCTAssertTrue(workerDecision.reason.contains("SYSTEM_ONLY"))
        XCTAssertTrue(agentDecision.executionRemainsLocal)
        XCTAssertTrue(workerDecision.executionRemainsLocal)
    }

    func testExecutionRoutingEventsAreRecordedThroughRuntimeAuditPath() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(
            id: UUID(),
            name: "Routing Event Workspace",
            role: .fde,
            createdAt: Date(),
            allowedNodes: [LogicalNode.localMacNodeID, LogicalNode.cloudNodeID],
            executionScope: .multiNodePrepared,
            distributionPolicy: .metadataOnly
        )
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let taskID = UUID()
        let controlPlane = FoundationCloudControlPlane()
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .api,
                eventClassification: .distributable
            )
        )

        let recordedEvents = try await controlPlane.recordRoutingEvents(
            decision,
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: taskID
        )
        let persistedEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)

        XCTAssertEqual(recordedEvents.map(\.type), [.routingDecisionMade, .nodeSelected, .executionTargetAssigned])
        XCTAssertEqual(persistedEvents.map(\.type), recordedEvents.map(\.type))
        XCTAssertTrue(persistedEvents.allSatisfy { EventClassification.classify(eventType: $0.type) == .systemOnly })
        XCTAssertTrue(
            persistedEvents.allSatisfy {
                $0.payload["selected_node_type"] == LogicalNodeType.cloudNode.rawValue
                    && $0.payload["actual_execution_node_type"] == LogicalNodeType.macNode.rawValue
                    && $0.payload["event_classification"] == EventClassification.distributable.rawValue
                    && $0.payload["execution_remains_local"] == "true"
                    && $0.payload["network_attempted"] == "false"
            }
        )
        XCTAssertNoThrow(try assertStrictCausalChain(persistedEvents))
    }

    func testNodeExecutionRuntimeMapsRoutingDecisionToCorrectExecutor() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.mock.cloud",
            type: .api,
            command: "api.synthetic",
            arguments: [],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .api,
                eventClassification: .distributable
            )
        )

        let result = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: decision,
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: taskID,
            stepID: "step.cloud",
            simulateFailure: false
        )

        XCTAssertEqual(decision.selectedNode.type, .cloudNode)
        XCTAssertEqual(result.node.type, .cloudNode)
        XCTAssertEqual(result.standardOutput, "mock-cloud:tool.mock.cloud:api.synthetic")
        XCTAssertTrue(result.simulated)
        XCTAssertFalse(result.networkAttempted)
    }

    func testMacNodeExecutorRunsRealAllowedToolAndRecordsEvents() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.real.echo",
            type: .shell,
            command: "/bin/echo",
            arguments: ["node-runtime-ok"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .low,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .localOnly
            )
        )

        let result = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: decision,
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: taskID,
            stepID: "step.echo",
            simulateFailure: false
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)

        XCTAssertEqual(result.node.type, .macNode)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(result.standardOutput, "node-runtime-ok")
        XCTAssertFalse(result.simulated)
        XCTAssertEqual(events.map(\.type), [.nodeExecutionStarted, .nodeExecutionCompleted])
        XCTAssertTrue(events.allSatisfy { $0.payload["node_type"] == LogicalNodeType.macNode.rawValue })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testNonMacNodeExecutorsReturnDeterministicMockOutputs() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.mock.echo",
            type: .shell,
            command: "/bin/echo",
            arguments: ["should-not-run-remotely"],
            workingDirectory: nil,
            requiresApproval: false
        )

        let cloudResult = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: controlPlane.routeExecution(
                ExecutionRoutingRequest(
                    workspace: workspace,
                    taskID: taskID,
                    taskComplexity: .high,
                    riskLevel: .low,
                    toolType: .api,
                    eventClassification: .distributable
                )
            ),
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: taskID,
            stepID: "step.cloud",
            simulateFailure: false
        )
        let agentResult = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: controlPlane.routeExecution(
                ExecutionRoutingRequest(
                    workspace: workspace,
                    taskID: taskID,
                    taskComplexity: .medium,
                    riskLevel: .high,
                    toolType: .shell,
                    eventClassification: .distributable
                )
            ),
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: taskID,
            stepID: "step.agent",
            simulateFailure: false
        )
        let workerResult = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: controlPlane.routeExecution(
                ExecutionRoutingRequest(
                    workspace: workspace,
                    taskID: taskID,
                    taskComplexity: .medium,
                    riskLevel: .low,
                    toolType: .shell,
                    eventClassification: .distributable
                )
            ),
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: taskID,
            stepID: "step.worker",
            simulateFailure: false
        )

        XCTAssertEqual(cloudResult.standardOutput, "mock-cloud:tool.mock.echo:/bin/echo")
        XCTAssertEqual(agentResult.standardOutput, "mock-agent:tool.mock.echo:/bin/echo")
        XCTAssertEqual(workerResult.standardOutput, "mock-worker:tool.mock.echo:/bin/echo")
        XCTAssertTrue([cloudResult, agentResult, workerResult].allSatisfy(\.simulated))
        XCTAssertTrue([cloudResult, agentResult, workerResult].allSatisfy { !$0.networkAttempted })
    }

    func testNodeExecutionFailureSimulationRecordsFailureEvent() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.mock.fail",
            type: .api,
            command: "api.fail",
            arguments: [],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .api,
                eventClassification: .distributable
            )
        )

        let result = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: decision,
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: taskID,
            stepID: "step.fail",
            simulateFailure: true
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)

        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.node.type, .cloudNode)
        XCTAssertEqual(result.standardError, "Simulated CloudNode failure.")
        XCTAssertEqual(events.map(\.type), [.nodeExecutionStarted, .nodeExecutionFailed])
        XCTAssertTrue(events.contains { $0.payload["stderr"] == "Simulated CloudNode failure." })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testNodeExecutionRuntimeIsDeterministicForMockNodes() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let toolCall = ToolCall(
            id: "tool.mock.deterministic",
            type: .connector,
            command: "connector.mock",
            arguments: ["payload=ignored"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .connector,
                eventClassification: .distributable
            )
        )

        let first = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: decision,
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: UUID(),
            stepID: "step.first",
            simulateFailure: false
        )
        let second = try await controlPlane.executeRoutedTool(
            toolCall,
            decision: decision,
            runtime: kernel,
            workspaceID: workspace.id,
            taskID: UUID(),
            stepID: "step.second",
            simulateFailure: false
        )

        XCTAssertEqual(first.node, second.node)
        XCTAssertEqual(first.state, second.state)
        XCTAssertEqual(first.exitCode, second.exitCode)
        XCTAssertEqual(first.standardOutput, second.standardOutput)
        XCTAssertEqual(first.standardError, second.standardError)
        XCTAssertEqual(first.simulated, second.simulated)
        XCTAssertEqual(first.networkAttempted, second.networkAttempted)
    }

    func testExecutionEnvelopeSerializationRoundTrips() throws {
        let workspace = fullyDistributedWorkspace()
        let controlPlane = FoundationCloudControlPlane()
        let toolCall = ToolCall(
            id: "tool.protocol.serialize",
            type: .api,
            command: "api.serialize",
            arguments: ["a=b"],
            workingDirectory: nil,
            requiresApproval: true
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: UUID(),
                taskComplexity: .high,
                riskLevel: .high,
                toolType: .api,
                eventClassification: .distributable
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: UUID(),
            toolCall: toolCall,
            approvalContext: ExecutionApprovalContext(
                approvalRequired: true,
                approvalRequestID: UUID(),
                approved: true,
                approvedByRole: .admin,
                decisionReason: "Serialized approval context."
            )
        )

        let encoded = try JSONCoding.encode(envelope)
        let decoded = try JSONCoding.decode(ExecutionEnvelope.self, from: encoded)

        XCTAssertTrue(encoded.contains("execution_id"))
        XCTAssertTrue(encoded.contains("policy_context"))
        XCTAssertTrue(encoded.contains("approval_context"))
        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.nodeID, decision.selectedNode.id)
        XCTAssertEqual(decoded.policyContext.selectedNodeType, decision.selectedNode.type)
    }

    func testLocalTransportExecutesEnvelopeThroughMacNode() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.protocol.echo",
            type: .shell,
            command: "/bin/echo",
            arguments: ["protocol-ok"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .low,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .localOnly
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall
        )

        let response = try await controlPlane.dispatchExecutionEnvelope(
            envelope,
            transport: LocalTransport(),
            runtime: kernel
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)

        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.standardOutput, "protocol-ok")
        XCTAssertEqual(response.metrics.nodeType, .macNode)
        XCTAssertFalse(response.metrics.simulated)
        XCTAssertFalse(response.metrics.networkAttempted)
        XCTAssertEqual(
            events.map(\.type),
            [.executionDispatched, .executionReceived, .nodeExecutionStarted, .nodeExecutionCompleted, .executionResponseReceived]
        )
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testRemoteTransportStubIsDisabledSafely() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.protocol.remote",
            type: .api,
            command: "api.remote",
            arguments: [],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .high,
                riskLevel: .low,
                toolType: .api,
                eventClassification: .distributable
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall
        )

        let response = try await controlPlane.dispatchExecutionEnvelope(
            envelope,
            transport: RemoteTransportStub(),
            runtime: kernel
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)

        XCTAssertEqual(response.status, .disabled)
        XCTAssertNil(response.output)
        XCTAssertEqual(response.metrics.nodeType, .cloudNode)
        XCTAssertTrue(response.metrics.simulated)
        XCTAssertFalse(response.metrics.networkAttempted)
        XCTAssertEqual(response.failureReason, "RemoteTransportStub is disabled; no network execution attempted.")
        XCTAssertEqual(events.map(\.type), [.executionDispatched, .executionReceived, .executionResponseReceived])
        XCTAssertTrue(events.allSatisfy { $0.payload["transport"] == "remote_stub" && $0.payload["network_attempted"] == "false" })
    }

    func testExecutionProtocolReplayRemainsDeterministic() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.protocol.replay",
            type: .shell,
            command: "/bin/echo",
            arguments: ["replay-ok"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .low,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .localOnly
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall
        )

        _ = try await controlPlane.dispatchExecutionEnvelope(
            envelope,
            transport: LocalTransport(),
            runtime: kernel
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)
        let firstReplay = try await kernel.replay(taskID: taskID, workspaceID: workspace.id)
        let secondReplay = try await kernel.replay(taskID: taskID, workspaceID: workspace.id)

        XCTAssertEqual(firstReplay, secondReplay)
        XCTAssertEqual(firstReplay.count, events.count)
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testWorkerRuntimeReceivesEnvelopeAndReturnsResponse() async throws {
        let workspace = fullyDistributedWorkspace()
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.worker.receive",
            type: .shell,
            command: "/bin/echo",
            arguments: ["worker-ok"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .medium,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .distributable
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall
        )
        let workerRuntime = WorkerRuntime()

        _ = await workerRuntime.register()
        let response = await workerRuntime.receive(envelope)
        let session = await workerRuntime.currentSession()

        XCTAssertEqual(decision.selectedNode.type, .workerNode)
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.standardOutput, "worker-runtime:tool.worker.receive:/bin/echo")
        XCTAssertEqual(response.metrics.nodeType, .workerNode)
        XCTAssertTrue(response.metrics.simulated)
        XCTAssertFalse(response.metrics.networkAttempted)
        XCTAssertEqual(response.events.map(\.type), [.workerTaskCompleted])
        XCTAssertEqual(session.status, .idle)
    }

    func testWorkerTransportAdapterRecordsWorkerEvents() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.worker.transport",
            type: .shell,
            command: "/bin/echo",
            arguments: ["worker-transport"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .medium,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .distributable
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall
        )

        let response = try await controlPlane.dispatchExecutionEnvelope(
            envelope,
            transport: WorkerTransportAdapter(),
            runtime: kernel
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)

        XCTAssertEqual(decision.selectedNode.type, .workerNode)
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.output?.standardOutput, "worker-runtime:tool.worker.transport:/bin/echo")
        XCTAssertEqual(events.map(\.type), [.workerRegistered, .workerTaskReceived, .workerTaskCompleted])
        XCTAssertTrue(events.allSatisfy { $0.payload["transport"] == "worker_ipc_mock" })
        XCTAssertTrue(events.allSatisfy { $0.payload["network_attempted"] == "false" })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testWorkerRuntimeRejectsInvalidEnvelope() async throws {
        let workspace = fullyDistributedWorkspace()
        let controlPlane = FoundationCloudControlPlane()
        let toolCall = ToolCall(
            id: "tool.worker.invalid",
            type: .shell,
            command: "/bin/echo",
            arguments: ["invalid"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: UUID(),
                taskComplexity: .medium,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .distributable
            )
        )
        var envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: UUID(),
            toolCall: toolCall
        )
        envelope.nodeID = LogicalNode.agentNodeID
        let workerRuntime = WorkerRuntime()

        _ = await workerRuntime.register()
        let response = await workerRuntime.receive(envelope)

        XCTAssertEqual(response.status, .failed)
        XCTAssertEqual(response.output?.exitCode, 1)
        XCTAssertTrue(response.failureReason?.contains("expected \(LogicalNode.workerNodeID)") == true)
        XCTAssertFalse(response.metrics.networkAttempted)
        XCTAssertEqual(response.events.map(\.type), [.workerTaskFailed])
    }

    func testWorkerRuntimeReplayRemainsDeterministic() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.worker.replay",
            type: .shell,
            command: "/bin/echo",
            arguments: ["worker-replay"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .medium,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .distributable
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall
        )

        _ = try await controlPlane.dispatchExecutionEnvelope(
            envelope,
            transport: WorkerTransportAdapter(),
            runtime: kernel
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)
        let firstReplay = try await kernel.replay(taskID: taskID, workspaceID: workspace.id)
        let secondReplay = try await kernel.replay(taskID: taskID, workspaceID: workspace.id)

        XCTAssertEqual(firstReplay, secondReplay)
        XCTAssertEqual(firstReplay.count, events.count)
        XCTAssertEqual(events.map(\.type), [.workerRegistered, .workerTaskReceived, .workerTaskCompleted])
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testWorkerTransportAdapterDoesNotAttemptNetwork() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = fullyDistributedWorkspace()
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )
        let controlPlane = FoundationCloudControlPlane()
        let taskID = UUID()
        let toolCall = ToolCall(
            id: "tool.worker.network",
            type: .shell,
            command: "/bin/echo",
            arguments: ["offline"],
            workingDirectory: nil,
            requiresApproval: false
        )
        let decision = controlPlane.routeExecution(
            ExecutionRoutingRequest(
                workspace: workspace,
                taskID: taskID,
                taskComplexity: .medium,
                riskLevel: .low,
                toolType: .shell,
                eventClassification: .distributable
            )
        )
        let envelope = controlPlane.makeExecutionEnvelope(
            decision: decision,
            workspace: workspace,
            taskID: taskID,
            toolCall: toolCall
        )

        let response = try await controlPlane.dispatchExecutionEnvelope(
            envelope,
            transport: WorkerTransportAdapter(),
            runtime: kernel
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskID)

        XCTAssertFalse(response.metrics.networkAttempted)
        XCTAssertTrue(response.metrics.simulated)
        XCTAssertTrue(events.allSatisfy { $0.payload["network_attempted"] == "false" })
        XCTAssertTrue(events.allSatisfy { EventClassification.classify(eventType: $0.type) == .systemOnly })
    }

    func testWorkspaceDistributionMetadataIsLogicalOnly() {
        let workspace = Workspace(
            id: UUID(),
            name: "Enterprise Prepared Workspace",
            role: .admin,
            createdAt: Date(),
            allowedNodes: [LogicalNode.localMacNodeID, LogicalNode.agentNodeID, LogicalNode.workerNodeID],
            executionScope: .multiNodePrepared,
            distributionPolicy: .metadataOnly
        )
        let workspaceRegistry = TrackingWorkspaceRegistry()
        let nodeRegistry = TrackingControlPlaneNodeRegistry()
        let controlPlane = FoundationCloudControlPlane(
            workspaceRegistry: workspaceRegistry,
            nodeRegistry: nodeRegistry
        )

        controlPlane.registerWorkspace(workspace)
        controlPlane.registerNode(.currentMac(workspaceID: workspace.id))
        controlPlane.registerNode(
            .futureWorker(workspaceID: workspace.id)
        )

        let metadata = workspace.distributionMetadata
        let storedMetadata = workspaceRegistry.distributionMetadata(workspaceID: workspace.id)
        let nodes = nodeRegistry.nodes()

        XCTAssertEqual(metadata.allowedNodes, [LogicalNode.localMacNodeID, LogicalNode.agentNodeID, LogicalNode.workerNodeID])
        XCTAssertEqual(metadata.executionScope, .multiNodePrepared)
        XCTAssertEqual(metadata.distributionPolicy, .metadataOnly)
        XCTAssertEqual(storedMetadata, metadata)
        XCTAssertEqual(Set(nodes.map(\.type)), Set([.macNode, .workerNode]))
        XCTAssertEqual(EventStreamNodeRegistration(node: .currentMac(workspaceID: workspace.id)).metadata["node_type"], LogicalNodeType.macNode.rawValue)
        XCTAssertEqual(EventStreamNodeRegistration(node: .futureWorker(workspaceID: workspace.id)).metadata["capacity"], LogicalNodeCapacity.batch.rawValue)
    }

    func testDefaultWorkspaceAndControlPlaneRemainSingleNodeLocalOnly() {
        let workspace = Workspace.default()
        let event = makeTestEvent(type: .toolCalled, workspaceID: workspace.id, taskID: UUID())
        let controlPlane = FoundationCloudControlPlane()
        let envelope = InMemoryEventStream().routingEnvelope(for: event, cloudRoutingEnabled: true)
        let decision = controlPlane.routeEvent(event, workspace: workspace, cloudRoutingEnabled: envelope.cloudRoutingEnabled)
        let ingestionResult = StubEventIngestionEndpoint().ingest(envelope)

        XCTAssertEqual(workspace.allowedNodes, [LogicalNode.localMacNodeID])
        XCTAssertEqual(workspace.executionScope, .singleNode)
        XCTAssertEqual(workspace.distributionPolicy, .localOnly)
        XCTAssertEqual(envelope.classification, .distributable)
        XCTAssertTrue(envelope.cloudRoutingEnabled)
        XCTAssertEqual(decision.targetNodeIDs, [LogicalNode.localMacNodeID])
        XCTAssertEqual(decision.route, .localRuntimeOnly)
        XCTAssertFalse(decision.networkAttempted)
        XCTAssertFalse(ingestionResult.accepted)
        XCTAssertFalse(ingestionResult.networkAttempted)
    }

    func testFDERoleCanExecuteToolsAndUpdatePolicy() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "FDE Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = RecordingToolExecutor()

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: executor
        )

        let task = try await kernel.submitTask(input: "Audit the local workspace", workspace: workspace)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let commands = await executor.executedCommands()

        XCTAssertEqual(task.state, .completed)
        XCTAssertFalse(commands.isEmpty)
        XCTAssertTrue(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(events.contains { $0.type == .policyUpdated })
        XCTAssertFalse(events.contains { $0.type == .authorizationDenied })
    }

    func testHighRiskToolBlockedUntilApprovalAndApprovalResumesExecution() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Approval Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = RecordingToolExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [HighRiskApprovalPlanner()]),
            toolExecutor: executor
        )

        let execution = Task {
            try await kernel.submitTask(input: "Run high-risk approved echo", workspace: workspace)
        }
        let request = try await waitForPendingApproval(workspaceID: workspace.id, persistence: persistence)
        let commandsBeforeApproval = await executor.executedCommands()

        XCTAssertEqual(request.state, .pending)
        XCTAssertEqual(request.riskLevel, .high)
        XCTAssertTrue(commandsBeforeApproval.isEmpty)

        let approved = try await kernel.approveApprovalRequest(request.id, workspace: workspace, reason: "Approved for test.")
        let task = try await execution.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let replay = try await kernel.replay(taskID: task.id, workspaceID: workspace.id)
        let commandsAfterApproval = await executor.executedCommands()

        XCTAssertEqual(approved.state, .approved)
        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(commandsAfterApproval, ["/bin/echo"])
        XCTAssertTrue(events.contains { $0.type == .humanApprovalRequested && $0.payload["approval_request_id"] == request.id.uuidString })
        XCTAssertTrue(events.contains { $0.type == .humanApproved && $0.payload["approval_request_id"] == request.id.uuidString })
        XCTAssertTrue(events.contains { $0.type == .toolCalled && $0.payload["command"] == "/bin/echo" })
        XCTAssertTrue(replay.contains { $0.title.contains(EventType.humanApprovalRequested.rawValue) })
        XCTAssertTrue(replay.contains { $0.title.contains(EventType.humanApproved.rawValue) })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testApprovalRejectionAbortsExecution() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Rejection Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = RecordingToolExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [HighRiskApprovalPlanner()]),
            toolExecutor: executor
        )

        let execution = Task {
            try await kernel.submitTask(input: "Run high-risk rejected echo", workspace: workspace)
        }
        let request = try await waitForPendingApproval(workspaceID: workspace.id, persistence: persistence)
        let rejected = try await kernel.rejectApprovalRequest(request.id, workspace: workspace, reason: "Rejected for test.")
        let task = try await execution.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let commandsAfterRejection = await executor.executedCommands()

        XCTAssertEqual(rejected.state, .rejected)
        XCTAssertEqual(task.state, .failed)
        XCTAssertTrue(commandsAfterRejection.isEmpty)
        XCTAssertTrue(events.contains { $0.type == .humanApprovalRequested })
        XCTAssertTrue(events.contains { $0.type == .humanRejected && $0.payload["approval_state"] == ApprovalState.rejected.rawValue })
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testRBACPreventsUnauthorizedApprovalAndKeepsRequestPending() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "RBAC Approval Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = RecordingToolExecutor()
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [HighRiskApprovalPlanner()]),
            toolExecutor: executor
        )

        let execution = Task {
            try await kernel.submitTask(input: "Run high-risk approval with unauthorized approver", workspace: workspace)
        }
        let request = try await waitForPendingApproval(workspaceID: workspace.id, persistence: persistence)
        let unauthorizedWorkspace = Workspace(id: workspace.id, name: workspace.name, role: .user, createdAt: workspace.createdAt)

        do {
            _ = try await kernel.approveApprovalRequest(request.id, workspace: unauthorizedWorkspace, reason: "User tries to approve.")
            XCTFail("User role should not approve high-risk actions.")
        } catch {
            XCTAssertTrue(error is AuthorizationError)
        }

        let pendingRequest = try await persistence.loadApprovalRequest(id: request.id)
        let stillPending = try XCTUnwrap(pendingRequest)
        let commandsAfterDeniedApproval = await executor.executedCommands()
        XCTAssertEqual(stillPending.state, .pending)
        XCTAssertTrue(commandsAfterDeniedApproval.isEmpty)

        _ = try await kernel.approveApprovalRequest(request.id, workspace: workspace, reason: "FDE approved after denial.")
        let task = try await execution.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let commandsAfterAuthorizedApproval = await executor.executedCommands()

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(
            events.contains {
                $0.type == .authorizationDenied
                    && $0.payload["permission"] == Permission.approveRiskyAction.rawValue
                    && $0.payload["approval_request_id"] == request.id.uuidString
            }
        )
        XCTAssertTrue(events.contains { $0.type == .humanApproved })
        XCTAssertEqual(commandsAfterAuthorizedApproval, ["/bin/echo"])
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testApprovalDecisionStatePersistsInSQLite() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEApproval-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        let workspace = Workspace.default()
        let queue = ApprovalQueue(persistence: persistence)
        let request = ApprovalRequest(
            id: UUID(),
            workspaceID: workspace.id,
            taskID: UUID(),
            stepID: "step.high-risk",
            toolCallID: "tool.high-risk",
            targetKind: .toolCall,
            action: "execute tool",
            resource: "/bin/echo",
            riskLevel: .high,
            state: .pending,
            requestedByRole: .fde,
            decidedByRole: nil,
            decisionReason: nil,
            requestedAt: Date(),
            decidedAt: nil,
            expiresAt: nil,
            metadata: ["reason": "test"]
        )

        _ = try await queue.enqueue(request)
        _ = try await queue.approve(requestID: request.id, approverRole: .admin, reason: "Persist approval.")
        let storedRequest = try await persistence.loadApprovalRequest(id: request.id)
        let stored = try XCTUnwrap(storedRequest)
        let approvedRequests = try await persistence.loadApprovalRequests(workspaceID: workspace.id, state: .approved)

        XCTAssertEqual(stored.state, .approved)
        XCTAssertEqual(stored.decidedByRole, .admin)
        XCTAssertEqual(stored.decisionReason, "Persist approval.")
        XCTAssertEqual(approvedRequests.map(\.id), [request.id])
    }

    func testConnectorRegistryMockConnectorsExecuteDeterministicallyOffline() async throws {
        let registry = ConnectorRegistry.default()
        let statuses = await registry.statuses()
        let capabilities = await registry.capabilities()
        let connectorIDs = ["slack", "github", "notion", "gmail"]

        XCTAssertEqual(Set(statuses.map(\.id)), Set(connectorIDs))
        XCTAssertTrue(statuses.allSatisfy { $0.state == .ready && $0.lastSyncSummary.contains("Network") })
        XCTAssertEqual(Set(capabilities.map(\.connectorID)), Set(connectorIDs))
        XCTAssertTrue(capabilities.allSatisfy(\.requiresApproval))

        for connectorID in connectorIDs {
            let request = ConnectorRequest(
                id: "request.\(connectorID)",
                connectorID: connectorID,
                action: "mock_action",
                payload: ["target": "local-test", "token": "SHOULD_NOT_LEAK"],
                dryRun: false,
                simulateFailure: false
            )

            let validation = try await registry.validate(request: request)
            let dryRun = try await registry.dryRun(request)
            let secondDryRun = try await registry.dryRun(request)
            let first = try await registry.execute(request)
            let second = try await registry.execute(request)

            XCTAssertTrue(validation.valid)
            XCTAssertEqual(dryRun, secondDryRun)
            XCTAssertEqual(first, second)
            XCTAssertEqual(dryRun.eventPayload["network"], "disabled")
            XCTAssertEqual(first.eventPayload["network"], "disabled")
            XCTAssertEqual(first.payload["token"], "[redacted]")
            XCTAssertFalse(try JSONCoding.encode(first).contains("SHOULD_NOT_LEAK"))
        }
    }

    func testConnectorRuntimeApprovalGatesAndEmitsConnectorEvents() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Connector Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [
                ConnectorPlanner(connectorID: "slack", action: "post_message", arguments: ["channel=#field", "text=hello"])
            ]),
            toolExecutor: ConnectorToolExecutor(registry: .default())
        )

        let execution = Task {
            try await kernel.submitTask(input: "Post a local mock Slack update", workspace: workspace)
        }
        let request = try await waitForPendingApproval(workspaceID: workspace.id, persistence: persistence)
        let pendingEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: request.taskID)

        XCTAssertEqual(request.targetKind, .connectorOperation)
        XCTAssertEqual(request.riskLevel, .high)
        XCTAssertTrue(pendingEvents.contains { $0.type == .humanApprovalRequested })
        XCTAssertFalse(pendingEvents.contains { $0.type == .connectorCalled })

        _ = try await kernel.approveApprovalRequest(request.id, workspace: workspace, reason: "Approve connector mock.")
        let task = try await execution.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let replay = try await kernel.replay(taskID: task.id, workspaceID: workspace.id)

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(events.contains { $0.type == .humanApproved && $0.payload["approval_request_id"] == request.id.uuidString })
        XCTAssertTrue(events.contains { $0.type == .connectorCalled && $0.payload["command"] == "slack.post_message" })
        XCTAssertTrue(events.contains { $0.type == .toolCalled && $0.payload["command"] == "slack.post_message" })
        XCTAssertTrue(events.contains { $0.type == .connectorDryRun && $0.payload["connector_id"] == "slack" && $0.payload["network"] == "disabled" })
        XCTAssertTrue(events.contains { $0.type == .connectorExecuted && $0.payload["connector_id"] == "slack" && $0.payload["network"] == "disabled" })
        XCTAssertTrue(events.contains { $0.type == .stepExecuted && $0.payload["tool_call_id"] == "tool.connector.slack" })
        XCTAssertEqual(replay.count, events.count)
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testConnectorExecutionDeniedByRBACBeforeRuntimeCall() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Restricted Connector Workspace", role: .user, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [
                ConnectorPlanner(connectorID: "github", action: "create_issue", arguments: ["title=mock"])
            ]),
            toolExecutor: ConnectorToolExecutor(registry: .default())
        )

        let task = try await kernel.submitTask(input: "Create a local mock GitHub issue", workspace: workspace)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(
            events.contains {
                $0.type == .authorizationDenied
                    && $0.payload["permission"] == Permission.executeTool.rawValue
                    && $0.payload["tool_type"] == ToolType.connector.rawValue
            }
        )
        XCTAssertFalse(events.contains { $0.type == .connectorCalled })
        XCTAssertFalse(events.contains { $0.type == .connectorDryRun })
        XCTAssertFalse(events.contains { $0.type == .connectorExecuted })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testConnectorFailureSimulationEmitsFailureAndRecoveryEvents() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Connector Failure Workspace", role: .fde, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [
                ConnectorPlanner(connectorID: "notion", action: "fail_create_page", arguments: ["title=mock", "simulate_failure=true"])
            ]),
            toolExecutor: ConnectorToolExecutor(registry: .default())
        )

        let execution = Task {
            try await kernel.submitTask(input: "Run a local mock Notion connector failure", workspace: workspace)
        }
        let request = try await waitForPendingApproval(workspaceID: workspace.id, persistence: persistence)
        _ = try await kernel.approveApprovalRequest(request.id, workspace: workspace, reason: "Approve failure simulation.")
        let task = try await execution.value
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(events.contains { $0.type == .connectorCalled && $0.payload["command"] == "notion.fail_create_page" })
        XCTAssertTrue(events.contains { $0.type == .connectorDryRun && $0.payload["connector_id"] == "notion" })
        XCTAssertTrue(events.contains { $0.type == .connectorFailed && $0.payload["command"] == "notion.fail_create_page" })
        XCTAssertTrue(events.contains { $0.type == .toolFailed && $0.payload["command"] == "notion.fail_create_page" })
        XCTAssertTrue(events.contains { $0.type == .recoveryAttempted && $0.payload["failed_command"] == "notion.fail_create_page" })
        XCTAssertTrue(
            events.contains {
                $0.type == .toolFailed
                    && $0.payload["observation_outcome"] == ToolObservationOutcome.failed.rawValue
                    && $0.payload["observation_next_action"] == AgentRuntimeAction.replan.rawValue
                    && $0.payload["agent_work_trace_stage"] == AgentWorkTraceStage.observation.rawValue
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.type == .recoveryAttempted
                    && $0.payload["replan_modified_step_id"] == "replan.step.connector.notion"
                    && $0.payload["agent_work_trace_stage"] == AgentWorkTraceStage.adaptation.rawValue
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.type == .stepExecuted
                    && $0.payload["tool_call_id"] == "recovery.tool.connector.notion"
                    && $0.payload["command"] == "/bin/echo"
            }
        )
        XCTAssertFalse(events.contains { $0.type == .connectorExecuted })
        XCTAssertNoThrow(try assertStrictCausalChain(events))
    }

    func testUserRoleAuthorizationDenialBlocksToolExecutionAndEmitsEvent() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace(id: UUID(), name: "Restricted Workspace", role: .user, createdAt: Date())
        try await persistence.saveWorkspace(workspace)
        let executor = RecordingToolExecutor()

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: executor
        )

        let task = try await kernel.submitTask(input: "Audit the local workspace", workspace: workspace)
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let commands = await executor.executedCommands()

        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(commands.isEmpty)
        XCTAssertFalse(events.contains { $0.type == .toolCalled })
        XCTAssertTrue(
            events.contains {
                $0.type == .authorizationDenied
                    && $0.payload["permission"] == Permission.executeTool.rawValue
                    && $0.payload["role"] == UserRole.user.rawValue
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.type == .authorizationDenied
                    && $0.payload["permission"] == Permission.updatePolicy.rawValue
            }
        )
    }

    func testFailureClosesFeedbackPolicyLoopAndAdaptsNextPlan() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: FailingListOnceToolExecutor()
        )

        let input = "Audit the local workspace and prepare an execution checkpoint"
        let firstTask = try await kernel.submitTask(input: input, workspace: workspace)
        let firstEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: firstTask.id)
        let deltas = try await persistence.loadPolicyDeltas(workspaceID: workspace.id)

        XCTAssertTrue(firstTask.plan.contains { $0.toolCallID == "tool.workspace.list" })
        XCTAssertTrue(firstTask.plan.contains { $0.id == "replan.step.inspect" && $0.toolCallID == "recovery.tool.workspace.list" })
        XCTAssertTrue(firstEvents.contains { $0.type == .toolFailed && $0.payload["command"] == "/bin/ls" })
        XCTAssertTrue(firstEvents.contains { $0.type == .toolFailed && $0.payload["observation_next_action"] == AgentRuntimeAction.replan.rawValue })
        XCTAssertTrue(firstEvents.contains { $0.type == .recoveryAttempted && $0.payload["replan_hypothesis"]?.contains("/bin/ls") == true })
        XCTAssertTrue(firstEvents.contains { $0.type == .feedbackGenerated })
        XCTAssertTrue(firstEvents.contains { $0.type == .policyUpdated })
        XCTAssertTrue(deltas.contains { $0.kind == .avoidFailedTool && $0.avoidToolCommand == "/bin/ls" && $0.replacementToolCommand == "/usr/bin/env" })
        XCTAssertNoThrow(try assertStrictCausalChain(firstEvents))

        let secondTask = try await kernel.submitTask(input: input, workspace: workspace)
        let secondEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: secondTask.id)

        XCTAssertNotEqual(firstTask.plan.map(\.toolCallID), secondTask.plan.map(\.toolCallID))
        XCTAssertTrue(secondTask.plan.contains { $0.toolCallID == "tool.workspace.env" && $0.retryBudget == 1 })
        XCTAssertLessThan(
            secondTask.plan.firstIndex { $0.toolCallID == "tool.execution.checkpoint" } ?? Int.max,
            secondTask.plan.firstIndex { $0.toolCallID == "tool.workspace.env" } ?? Int.max
        )
        XCTAssertFalse(secondEvents.contains { $0.type == .toolCalled && $0.payload["command"] == "/bin/ls" })
        XCTAssertTrue(secondEvents.contains { $0.type == .toolCalled && $0.payload["command"] == "/usr/bin/env" })
        XCTAssertNoThrow(try assertStrictCausalChain(secondEvents))
    }

    func testFailureLoopPromptFailsOnceRecoversPersistsAndNextRunAvoidsFailure() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDECloudOS-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
        let persistence = try SQLitePersistenceStore(databaseURL: databaseURL)
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()])
        )

        let failedCommand = "api.missing_dependency"
        let firstTask = try await kernel.submitTask(
            input: "Simulate a missing API dependency, trigger recovery, and generate a failure report",
            workspace: workspace
        )
        let firstEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: firstTask.id)
        let firstReplay = try await kernel.replay(taskID: firstTask.id, workspaceID: workspace.id)
        let feedback = try await persistence.loadFeedback(workspaceID: workspace.id)
        let deltas = try await persistence.loadPolicyDeltas(workspaceID: workspace.id)
        let firstPolicy = try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)

        XCTAssertTrue(firstTask.plan.contains { $0.toolCallID == "tool.api.missing-dependency" })
        XCTAssertTrue(firstTask.plan.contains { $0.id == "replan.step.missing-api.failure-validation" && $0.toolCallID == "recovery.tool.api.missing-dependency" })
        XCTAssertTrue(firstEvents.contains { $0.type == .toolCalled && $0.payload["command"] == failedCommand })
        XCTAssertTrue(firstEvents.contains { $0.type == .toolFailed && $0.payload["command"] == failedCommand })
        XCTAssertTrue(firstEvents.contains { $0.type == .toolFailed && $0.payload["world_model_previous_failures"]?.contains(failedCommand) == true })
        XCTAssertTrue(
            firstEvents.contains {
                $0.type == .recoveryAttempted
                    && $0.payload["failed_command"] == failedCommand
                    && $0.payload["recovery_command"] == "/bin/echo"
                    && $0.payload["replan_modified_step_id"] == "replan.step.missing-api.failure-validation"
                    && $0.payload["agent_work_trace_stage"] == AgentWorkTraceStage.adaptation.rawValue
            }
        )
        XCTAssertTrue(
            firstEvents.contains {
                $0.type == .stepExecuted
                    && $0.payload["tool_call_id"] == "recovery.tool.api.missing-dependency"
                    && $0.payload["command"] == "/bin/echo"
            }
        )
        XCTAssertTrue(
            firstEvents.contains {
                $0.type == .policyUpdated
                    && $0.payload["kind"] == PolicyAdjustmentKind.avoidFailedTool.rawValue
                    && $0.payload["avoid_tool_command"] == failedCommand
                    && $0.payload["replacement_tool_command"] == "/usr/bin/env"
            }
        )
        XCTAssertTrue(deltas.contains { $0.kind == .avoidFailedTool && $0.avoidToolCommand == failedCommand && $0.replacementToolCommand == "/usr/bin/env" })
        XCTAssertTrue(firstPolicy?.avoidedToolCommands.contains(failedCommand) == true)
        XCTAssertEqual(firstPolicy?.toolPreferences[failedCommand], "/usr/bin/env")
        XCTAssertTrue(feedback.contains { $0.kind == .bugReport && $0.title.contains("Tool failure") })
        XCTAssertEqual(firstReplay.count, firstEvents.count)
        XCTAssertNoThrow(try assertStrictCausalChain(firstEvents))

        let secondTask = try await kernel.submitTask(
            input: "Run a task that intentionally fails once, recovers, and updates policy for the next run",
            workspace: workspace
        )
        let secondEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: secondTask.id)
        let secondReplay = try await kernel.replay(taskID: secondTask.id, workspaceID: workspace.id)
        let decisions = try await persistence.loadGlobalGovernorDecisions(workspaceID: workspace.id)
        let secondDecision = try XCTUnwrap(decisions.first { $0.taskID == secondTask.id })
        let secondPolicy = try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)

        XCTAssertTrue(secondTask.plan.contains { $0.id == "step.learning-preflight" })
        XCTAssertTrue(secondTask.plan.contains { $0.toolCallID == "tool.api.missing-dependency.fallback" })
        XCTAssertFalse(secondTask.plan.contains { $0.toolCallID == "tool.api.missing-dependency" })
        XCTAssertFalse(secondEvents.contains { $0.type == .toolCalled && $0.payload["command"] == failedCommand })
        XCTAssertFalse(secondEvents.contains { $0.type == .toolFailed && $0.payload["command"] == failedCommand })
        XCTAssertFalse(secondEvents.contains { $0.type == .recoveryAttempted && $0.payload["failed_command"] == failedCommand })
        XCTAssertTrue(
            secondEvents.contains {
                $0.type == .toolCalled
                    && $0.payload["tool_call_id"] == "tool.api.missing-dependency.fallback"
                    && $0.payload["command"] == "/usr/bin/env"
            }
        )
        XCTAssertTrue(
            secondEvents.contains {
                $0.type == .planGenerated
                    && $0.payload["governor_strategy"] == GovernorStrategy.conservativeRecovery.rawValue
            }
        )
        XCTAssertEqual(secondDecision.selectedStrategy, .conservativeRecovery)
        XCTAssertEqual(secondReplay.count, secondEvents.count)
        XCTAssertEqual(secondPolicy?.learningEffectCurve.count, 2)
        XCTAssertNoThrow(try assertStrictCausalChain(secondEvents))
    }

    func testSystemLearningTransfersFailureFromTaskAToDifferentTaskB() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: FailingListOnceToolExecutor()
        )

        let taskA = try await kernel.submitTask(
            input: "Audit the local workspace before a customer handoff",
            workspace: workspace
        )
        let profileAfterA = try await persistence.loadLatestSystemFailureProfile(workspaceID: workspace.id)
        let policyAfterA = try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)
        let insightsAfterA = try await persistence.loadSystemInsights(workspaceID: workspace.id)

        XCTAssertTrue(taskA.plan.contains { $0.toolCallID == "tool.workspace.list" })
        XCTAssertEqual(profileAfterA?.clusters.first?.taskType, "workspace-inspection")
        XCTAssertTrue(policyAfterA?.avoidedToolCommands.contains("/bin/ls") == true)
        XCTAssertEqual(policyAfterA?.toolPreferences["/bin/ls"], "/usr/bin/env")
        XCTAssertFalse(insightsAfterA.isEmpty)

        let taskB = try await kernel.submitTask(
            input: "Review project directory state before execution",
            workspace: workspace
        )
        let taskBEvents = try await persistence.loadEvents(workspaceID: workspace.id, taskID: taskB.id)
        let memory = try await persistence.loadTaskExecutionMemory(workspaceID: workspace.id)
        let policyAfterB = try await persistence.loadLatestGlobalExecutionPolicy(workspaceID: workspace.id)

        XCTAssertEqual(TaskTypeClassifier.classify(taskA.rawInput), TaskTypeClassifier.classify(taskB.rawInput))
        XCTAssertNotEqual(TaskFingerprint.make(from: taskA.rawInput), TaskFingerprint.make(from: taskB.rawInput))
        XCTAssertTrue(taskB.plan.contains { $0.id == "step.learning-preflight" })
        XCTAssertTrue(taskB.plan.contains { $0.toolCallID == "tool.workspace.env" && $0.retryBudget >= 1 })
        XCTAssertFalse(taskBEvents.contains { $0.type == .toolCalled && $0.payload["command"] == "/bin/ls" })
        XCTAssertTrue(taskBEvents.contains { $0.type == .toolCalled && $0.payload["command"] == "/usr/bin/env" })
        XCTAssertGreaterThan(taskB.performanceScore, taskA.performanceScore)
        XCTAssertEqual(memory.count, 2)
        XCTAssertEqual(policyAfterB?.learningEffectCurve.count, 2)
        XCTAssertEqual(policyAfterB?.learningEffectCurve.last?.taskID, taskB.id)
        XCTAssertGreaterThan(
            policyAfterB?.learningEffectCurve.last?.movingAveragePerformance ?? 0,
            policyAfterB?.learningEffectCurve.first?.movingAveragePerformance ?? 100
        )
    }

    func testFailurePatternMinerDetectsRecurringFailureSignatures() {
        let workspaceID = UUID()
        let signature = "workspace-inspection|TOOL_EXECUTION|/bin/ls|tool.workspace.list"
        let memories = [
            syntheticMemory(workspaceID: workspaceID, signature: signature, score: 60),
            syntheticMemory(workspaceID: workspaceID, signature: signature, score: 62)
        ]

        let profile = FailurePatternMiner().profile(workspaceID: workspaceID, memories: memories)

        XCTAssertEqual(profile.clusters.first?.signature, signature)
        XCTAssertEqual(profile.clusters.first?.frequency, 2)
        XCTAssertTrue(profile.recurringSignatures.contains(signature))
        XCTAssertEqual(profile.taskTypeFailureCounts["workspace-inspection"], 2)
    }

    func testGovernorOverridesPlannerWhenGlobalPolicyIsViolated() async throws {
        let persistence = InMemoryPersistenceStore()
        try await persistence.initialize()
        let workspace = Workspace.default()
        try await persistence.saveWorkspace(workspace)
        try await persistence.saveGlobalExecutionPolicy(globalPolicyAvoidingList(workspaceID: workspace.id))

        let kernel = RuntimeKernel(
            persistence: persistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [NonCompliantListPlanner()]),
            toolExecutor: RecordingToolExecutor()
        )

        let task = try await kernel.submitTask(
            input: "Audit the workspace with a planner that ignores global policy",
            workspace: workspace
        )
        let events = try await persistence.loadEvents(workspaceID: workspace.id, taskID: task.id)
        let decisions = try await persistence.loadGlobalGovernorDecisions(workspaceID: workspace.id)
        let decision = try XCTUnwrap(decisions.first { $0.taskID == task.id })

        XCTAssertTrue(task.plan.contains { $0.id == "step.governor-preflight" })
        XCTAssertTrue(task.plan.allSatisfy { $0.retryBudget >= 2 })
        XCTAssertFalse(events.contains { $0.type == .toolCalled && $0.payload["command"] == "/bin/ls" })
        XCTAssertTrue(events.contains { $0.type == .toolCalled && $0.payload["command"] == "/usr/bin/env" })
        XCTAssertEqual(decision.selectedStrategy, .globalPolicyPreferred)
        XCTAssertTrue(decision.overrides.contains { $0.kind == .replaceAvoidedTool && $0.before == "/bin/ls" && $0.after == "/usr/bin/env" })
        XCTAssertTrue(decision.overrides.contains { $0.kind == .insertPreflightConstraint })
        XCTAssertEqual(decision.objective.goal, .minimizeFailureRate)
        XCTAssertGreaterThanOrEqual(decision.efficiencyScore.globalPolicyCompliance, 0)
        XCTAssertTrue(events.contains { $0.type == .planGenerated && $0.payload["governor_decision_id"] == decision.id.uuidString })
    }

    func testReplayRejectsBrokenParentChain() {
        let workspaceID = UUID()
        let taskID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let events = [
            ExecutionEvent(
                id: firstID,
                parentEventID: nil,
                workspaceID: workspaceID,
                taskID: taskID,
                type: .taskCreated,
                sequence: 1,
                timestamp: Date(),
                summary: "one",
                payload: [:]
            ),
            ExecutionEvent(
                id: secondID,
                parentEventID: nil,
                workspaceID: workspaceID,
                taskID: taskID,
                type: .planGenerated,
                sequence: 2,
                timestamp: Date(),
                summary: "two",
                payload: [:]
            )
        ]

        XCTAssertThrowsError(try ReplayEngine().validate(events: events))
    }

    private func assertStrictCausalChain(_ events: [ExecutionEvent]) throws {
        XCTAssertFalse(events.isEmpty)
        var previousSequence: Int64?
        var previousEventID: UUID?

        for event in events {
            if let previousSequence {
                XCTAssertGreaterThan(event.sequence, previousSequence)
            }
            XCTAssertEqual(event.parentEventID, previousEventID)
            previousSequence = event.sequence
            previousEventID = event.id
        }
    }

    private func liveEvent(
        _ type: EventType,
        sequence: Int64,
        workspaceID: UUID,
        taskID: UUID?,
        summary: String? = nil,
        payload: [String: String] = [:]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: sequence,
            timestamp: Date(timeIntervalSince1970: TimeInterval(sequence)),
            summary: summary ?? "Test \(type.rawValue)",
            payload: payload
        )
    }

    private func liveTask(
        id: UUID,
        workspaceID: UUID,
        state: TaskState,
        plan: [PlanStep] = [],
        riskScore: Double = 0,
        failureProbability: Double = 0,
        performanceScore: Double = 0
    ) -> FDETask {
        FDETask(
            id: id,
            workspaceID: workspaceID,
            title: "Investigate customer API failure",
            rawInput: "Investigate customer API failure",
            state: state,
            plan: plan,
            riskScore: riskScore,
            failureProbability: failureProbability,
            performanceScore: performanceScore,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func emptyContext(workspace: Workspace, input: String) -> ExecutionContext {
        ExecutionContext(
            workspace: workspace,
            policyRules: [],
            graphSummary: "empty",
            recentTaskTitles: [],
            taskFingerprint: TaskFingerprint.make(from: input),
            policyDeltas: [],
            failurePatterns: [],
            systemFailureProfile: nil,
            globalExecutionPolicy: nil
        )
    }

    private var schemaValidPlannerJSON: String {
        """
        {
          "plan": [
            {
              "id": "step.context",
              "title": "Compile context",
              "intent": "Inspect current workspace state.",
              "kind": "tool",
              "toolCallID": "tool.workspace.pwd",
              "requiresApproval": false,
              "retryBudget": 0
            }
          ],
          "actions": [
            {
              "id": "action.plan",
              "title": "Create plan",
              "agent": "Planner Agent",
              "stepID": "step.context"
            }
          ],
          "tool_calls": [
            {
              "id": "tool.workspace.pwd",
              "type": "shell",
              "command": "/bin/pwd",
              "arguments": [],
              "workingDirectory": null,
              "requiresApproval": false
            }
          ],
          "risks": [
            {
              "id": "risk.readonly",
              "title": "Read-only inspection",
              "severity": "low",
              "mitigation": "Use a non-mutating workspace command."
            }
          ],
          "confidence": 0.87
        }
        """
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEContextTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func waitForPendingApproval(
        workspaceID: UUID,
        persistence: any PersistenceStore,
        attempts: Int = 100
    ) async throws -> ApprovalRequest {
        for _ in 0..<attempts {
            if let request = try await persistence.loadApprovalRequests(workspaceID: workspaceID, state: .pending).first {
                return request
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ApprovalQueueError.requestNotFound(workspaceID)
    }

    private func makeTestEvent(type: EventType, workspaceID: UUID, taskID: UUID?) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: workspaceID,
            taskID: taskID,
            type: type,
            sequence: 1,
            timestamp: Date(),
            summary: "Test \(type.rawValue)",
            payload: [:]
        )
    }

    private func completionContractEvent(
        type: EventType,
        sequence: Int64,
        summary: String,
        payload: [String: String] = [:]
    ) -> ExecutionEvent {
        ExecutionEvent(
            id: UUID(),
            parentEventID: nil,
            workspaceID: UUID(),
            taskID: UUID(),
            type: type,
            sequence: sequence,
            timestamp: Date(),
            summary: summary,
            payload: payload
        )
    }

    private func fullyDistributedWorkspace(role: UserRole = .fde) -> Workspace {
        Workspace(
            id: UUID(),
            name: "Fully Distributed Test Workspace",
            role: role,
            createdAt: Date(),
            allowedNodes: [
                LogicalNode.localMacNodeID,
                LogicalNode.cloudNodeID,
                LogicalNode.agentNodeID,
                LogicalNode.workerNodeID
            ],
            executionScope: .multiNodePrepared,
            distributionPolicy: .metadataOnly
        )
    }

    private func syntheticMemory(workspaceID: UUID, signature: String, score: Double) -> TaskExecutionMemory {
        TaskExecutionMemory(
            id: UUID(),
            workspaceID: workspaceID,
            taskID: UUID(),
            taskFingerprint: UUID().uuidString,
            taskType: "workspace-inspection",
            state: .completed,
            planStepCount: 3,
            toolCommands: ["/bin/ls"],
            failedCommands: ["/bin/ls"],
            failureSignatures: [signature],
            riskScore: 55,
            performanceScore: score,
            createdAt: Date()
        )
    }

    private func globalPolicyAvoidingList(workspaceID: UUID) -> GlobalExecutionPolicy {
        let firstTaskID = UUID()
        let secondTaskID = UUID()
        let curve = [
            LearningEffectPoint(
                id: UUID(),
                workspaceID: workspaceID,
                taskID: firstTaskID,
                taskType: "workspace-inspection",
                executionIndex: 1,
                performanceScore: 76,
                failureCount: 1,
                movingAveragePerformance: 76,
                createdAt: Date().addingTimeInterval(-60)
            ),
            LearningEffectPoint(
                id: UUID(),
                workspaceID: workspaceID,
                taskID: secondTaskID,
                taskType: "workspace-inspection",
                executionIndex: 2,
                performanceScore: 72,
                failureCount: 1,
                movingAveragePerformance: 74,
                createdAt: Date()
            )
        ]

        return GlobalExecutionPolicy(
            id: UUID(),
            workspaceID: workspaceID,
            avoidedToolCommands: ["/bin/ls"],
            toolPreferences: ["/bin/ls": "/usr/bin/env"],
            defaultRetryBudget: 2,
            decompositionDepth: 5,
            checkpointBeforeInspection: true,
            sourceInsightIDs: [],
            sourceClusterSignatures: ["workspace-inspection|TOOL_EXECUTION|/bin/ls|tool.workspace.list"],
            learningEffectCurve: curve,
            summary: "Test policy forbids /bin/ls globally.",
            createdAt: Date()
        )
    }
}

private actor FailingListOnceToolExecutor: ToolExecuting {
    private var hasFailedList = false

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        if call.command == "/bin/ls", !hasFailedList {
            hasFailedList = true
            throw ToolExecutionError.processFailed("Injected deterministic /bin/ls failure")
        }

        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: "ok \(call.command)",
            standardError: "",
            duration: 0.001
        )
    }
}

private struct NonCompliantListPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.context",
                    title: "Compile context",
                    intent: "Planner context",
                    toolCallID: "tool.workspace.pwd",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "step.inspect",
                    title: "Inspect with forbidden list",
                    intent: "This intentionally ignores global policy.",
                    toolCallID: "tool.workspace.list",
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(id: "action.plan", title: "Non-compliant plan", agent: .planner, stepID: "step.inspect")
            ],
            toolCalls: [
                ToolCall(
                    id: "tool.workspace.pwd",
                    type: .shell,
                    command: "/bin/pwd",
                    arguments: [],
                    workingDirectory: nil,
                    requiresApproval: false
                ),
                ToolCall(
                    id: "tool.workspace.list",
                    type: .shell,
                    command: "/bin/ls",
                    arguments: ["-la", "."],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [],
            confidence: 0.9
        )
    }
}

private struct RelativeWorkingDirectoryPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.root",
                    title: "Inspect root",
                    intent: "Confirm the selected project root.",
                    toolCallID: "tool.root",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "step.sources",
                    title: "Inspect sources",
                    intent: "Confirm project source directory within selected root.",
                    toolCallID: "tool.sources",
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(id: "action.inspect", title: "Inspect project", agent: .executor, stepID: "step.root")
            ],
            toolCalls: [
                ToolCall(
                    id: "tool.root",
                    type: .shell,
                    command: "/bin/pwd",
                    arguments: [],
                    workingDirectory: nil,
                    requiresApproval: false
                ),
                ToolCall(
                    id: "tool.sources",
                    type: .shell,
                    command: "/bin/ls",
                    arguments: ["-la", "."],
                    workingDirectory: "Sources",
                    requiresApproval: false
                )
            ],
            risks: [],
            confidence: 0.9
        )
    }
}

private struct OutsideProjectWorkingDirectoryPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true
    let workingDirectory: String

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.outside",
                    title: "Inspect outside directory",
                    intent: "This should be blocked by project scope.",
                    toolCallID: "tool.outside",
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(id: "action.block", title: "Block outside directory", agent: .policy, stepID: "step.outside")
            ],
            toolCalls: [
                ToolCall(
                    id: "tool.outside",
                    type: .shell,
                    command: "/bin/pwd",
                    arguments: [],
                    workingDirectory: workingDirectory,
                    requiresApproval: false
                )
            ],
            risks: [],
            confidence: 0.9
        )
    }
}

private struct AgentProjectWorkingDirectoryPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true
    var agentRoot: String

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.legacy-root",
                    title: "Inspect legacy root",
                    intent: "Confirm default relative scope remains the legacy project.",
                    toolCallID: "tool.legacy-root",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "step.agent-root",
                    title: "Inspect agent root",
                    intent: "Confirm explicit agent root work is allowed inside selected scope.",
                    toolCallID: "tool.agent-root",
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(id: "action.inspect", title: "Inspect both project roots", agent: .executor, stepID: "step.agent-root")
            ],
            toolCalls: [
                ToolCall(
                    id: "tool.legacy-root",
                    type: .shell,
                    command: "/bin/pwd",
                    arguments: [],
                    workingDirectory: nil,
                    requiresApproval: false
                ),
                ToolCall(
                    id: "tool.agent-root",
                    type: .shell,
                    command: "/bin/pwd",
                    arguments: [],
                    workingDirectory: agentRoot,
                    requiresApproval: false
                )
            ],
            risks: [],
            confidence: 0.9
        )
    }
}

private struct HighRiskApprovalPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.high-risk-echo",
                    title: "Run approved echo",
                    intent: "Exercise high-risk human approval gate.",
                    toolCallID: "tool.high-risk-echo",
                    requiresApproval: true
                )
            ],
            actions: [
                AgentAction(
                    id: "action.high-risk-approval",
                    title: "Request approval",
                    agent: .planner,
                    stepID: "step.high-risk-echo"
                )
            ],
            toolCalls: [
                ToolCall(
                    id: "tool.high-risk-echo",
                    type: .shell,
                    command: "/bin/echo",
                    arguments: ["approved"],
                    workingDirectory: nil,
                    requiresApproval: true
                )
            ],
            risks: [
                RiskSignal(
                    id: "risk.high",
                    title: "Human approval required",
                    severity: .high,
                    mitigation: "Wait for Admin/FDE approval before executing."
                )
            ],
            confidence: 0.95
        )
    }
}

private struct ConnectorPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true
    var connectorID: String
    var action: String
    var arguments: [String]

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        let toolID = "tool.connector.\(connectorID)"
        let stepID = "step.connector.\(connectorID)"
        return StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: stepID,
                    title: "Execute \(connectorID) mock connector",
                    intent: "Exercise the local deterministic connector runtime.",
                    toolCallID: toolID,
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(
                    id: "action.connector.\(connectorID)",
                    title: "Prepare connector request",
                    agent: .executor,
                    stepID: stepID
                )
            ],
            toolCalls: [
                ToolCall(
                    id: toolID,
                    type: .connector,
                    command: "\(connectorID).\(action)",
                    arguments: arguments,
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [
                RiskSignal(
                    id: "risk.connector.\(connectorID)",
                    title: "Connector mock requires local approval",
                    severity: .high,
                    mitigation: "Use approval queue before connector runtime execution."
                )
            ],
            confidence: 0.9
        )
    }
}

private actor RecordingToolExecutor: ToolExecuting {
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

private actor WorkingDirectoryRecordingExecutor: ToolExecuting {
    private var workingDirectories: [String] = []

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        workingDirectories.append(call.workingDirectory ?? "")
        return ToolExecutionResult(
            callID: call.id,
            exitCode: 0,
            standardOutput: call.workingDirectory ?? "",
            standardError: "",
            duration: 0.001
        )
    }

    func executedWorkingDirectories() -> [String] {
        workingDirectories
    }
}

private final class TrackingRemoteEventSink: RemoteEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ExecutionEvent] = []

    func enqueue(_ event: ExecutionEvent) {
        lock.withLock {
            events.append(event)
        }
    }

    func enqueuedCount() -> Int {
        lock.withLock {
            events.count
        }
    }
}

private final class TrackingNodeRegistry: EventStreamNodeRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [EventStreamNodeRegistration] = []

    func register(_ node: EventStreamNodeRegistration) {
        lock.withLock {
            nodes.append(node)
        }
    }

    func registrations() -> [EventStreamNodeRegistration] {
        lock.withLock {
            nodes
        }
    }
}

private final class TrackingEventIngestionEndpoint: EventIngestionEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [EventRoutingEnvelope] = []

    func ingest(_ envelope: EventRoutingEnvelope) -> EventIngestionResult {
        lock.withLock {
            envelopes.append(envelope)
        }
        return .disabled
    }

    func ingestedCount() -> Int {
        lock.withLock {
            envelopes.count
        }
    }
}

private final class TrackingWorkspaceRegistry: WorkspaceRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var metadataByWorkspaceID: [UUID: WorkspaceDistributionMetadata] = [:]

    func register(_ workspace: Workspace) {
        lock.withLock {
            metadataByWorkspaceID[workspace.id] = workspace.distributionMetadata
        }
    }

    func distributionMetadata(workspaceID: UUID) -> WorkspaceDistributionMetadata? {
        lock.withLock {
            metadataByWorkspaceID[workspaceID]
        }
    }
}

private final class TrackingControlPlaneNodeRegistry: NodeRegistry, @unchecked Sendable {
    private let lock = NSLock()
    private var nodesByID: [String: LogicalNode] = [:]

    func register(_ node: LogicalNode) {
        lock.withLock {
            nodesByID[node.id] = node
        }
    }

    func register(_ node: EventStreamNodeRegistration) {
        let logicalNode = LogicalNode(
            id: node.id,
            type: node.metadata["node_type"].flatMap(LogicalNodeType.init(rawValue:)) ?? .macNode,
            workspaceID: node.workspaceID,
            displayName: node.id,
            metadata: node.metadata
        )
        register(logicalNode)
    }

    func node(id: String) -> LogicalNode? {
        lock.withLock {
            nodesByID[id]
        }
    }

    func nodes() -> [LogicalNode] {
        lock.withLock {
            nodesByID.values.sorted { $0.id < $1.id }
        }
    }
}

private struct MalformedLiveProvider: ModelProvider {
    let kind: ModelProviderKind = .openAI
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [],
            actions: [],
            toolCalls: [],
            risks: [],
            confidence: 0.8
        )
    }
}

private struct PlanOnlyPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.plan-only",
                    title: "Prepare an actionable plan",
                    intent: "Describe the requested work without claiming execution.",
                    toolCallID: nil,
                    requiresApproval: false
                )
            ],
            actions: [
                AgentAction(
                    id: "action.plan-only",
                    title: "Prepare the plan",
                    agent: .planner,
                    stepID: "step.plan-only"
                )
            ],
            toolCalls: [],
            risks: [],
            confidence: 0.9
        )
    }
}

private struct EchoOnlyPlanner: ModelProvider {
    let kind: ModelProviderKind = .local
    let isAvailable = true

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        StructuredAgentOutput(
            plan: [
                PlanStep(
                    id: "step.echo",
                    title: "Emit checkpoint only",
                    intent: "Emit a deterministic checkpoint without reading files or running validation.",
                    toolCallID: "tool.echo",
                    requiresApproval: false
                )
            ],
            actions: [],
            toolCalls: [
                ToolCall(
                    id: "tool.echo",
                    type: .shell,
                    command: "/bin/echo",
                    arguments: ["checkpoint"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            risks: [],
            confidence: 0.9
        )
    }
}

private struct UnusedHTTPClient: LLMHTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ModelRoutingError.providerUnavailable("HTTP client should not be used in this test.")
    }
}

private actor CapturingPlannerHTTPClient: LLMHTTPClient {
    private let content: String
    private var requestBody: String?

    init(content: String) {
        self.content = content
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let responseData = try JSONSerialization.data(withJSONObject: [
            "output": [
                [
                    "type": "message",
                    "content": [
                        [
                            "type": "output_text",
                            "text": content
                        ]
                    ]
                ]
            ]
        ])
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://api.openai.com/v1/responses")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (responseData, response)
    }

    func lastRequestBody() -> String? {
        requestBody
    }
}

private actor ContextCapturingProvider: ModelProvider {
    nonisolated let kind: ModelProviderKind = .local
    nonisolated let isAvailable = true

    private var capturedBundle: ContextBundle?

    func generatePlan(for input: String, context: ExecutionContext) async throws -> StructuredAgentOutput {
        capturedBundle = context.contextBundle
        return try await LocalDeterministicModelProvider().generatePlan(for: input, context: context)
    }

    func receivedBundle() -> ContextBundle? {
        capturedBundle
    }
}

private final class MockSecureValueStore: SecureValueStoring, @unchecked Sendable {
    private var values: [SecureValueKey: String] = [:]
    private let lock = NSLock()

    func save(_ value: String, for key: SecureValueKey) throws {
        lock.withLock {
            values[key] = value
        }
    }

    func load(for key: SecureValueKey) throws -> String? {
        lock.withLock {
            values[key]
        }
    }

    func delete(for key: SecureValueKey) throws {
        _ = lock.withLock {
            values.removeValue(forKey: key)
        }
    }

    func allValues() -> [String] {
        lock.withLock {
            Array(values.values)
        }
    }
}
