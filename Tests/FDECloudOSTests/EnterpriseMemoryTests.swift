import XCTest
@testable import FDECloudOS

final class EnterpriseMemoryTests: XCTestCase {
    func testPostgreSQLEnterpriseMemoryStorePersistsAndRetrievesMemory() async throws {
        let workspace = Workspace.default()
        let database = CapturingPostgreSQLMemoryDatabase()
        let store = PostgreSQLEnterpriseMemoryStore(
            configuration: PostgreSQLMemoryConfiguration(connectionString: "postgres://memory.test/fde"),
            database: database
        )
        let entry = MemoryEntry(
            workspaceID: workspace.id,
            type: .failureMemory,
            title: "OAuth token expired",
            summary: "Customer API integration failed after OAuth token expiry.",
            tags: ["oauth", "api"],
            relatedTaskFingerprint: "investigate customer api integration failure"
        )

        try await store.initialize()
        try await store.save(entry)

        let retrieved = try await store.retrieve(
            EnterpriseMemoryQuery(
                workspaceID: workspace.id,
                taskFingerprint: "investigate customer api integration failure",
                text: "Investigate customer API integration failure",
                types: [.failureMemory],
                limit: 4
            )
        )
        let initializedTables = await database.initializedTables()

        XCTAssertEqual(initializedTables, ["enterprise_memory"])
        XCTAssertEqual(retrieved, [entry])
    }

    func testEnterpriseMemoryRetrieverBucketsRelevantMemory() async throws {
        let workspace = Workspace.default()
        let store = InMemoryEnterpriseMemoryStore()
        let fingerprint = "investigate customer api integration failure"
        try await seedMemory(store: store, workspaceID: workspace.id, fingerprint: fingerprint)

        let context = await EnterpriseMemoryRetriever(store: store).retrieveContext(
            for: MemoryRetrievalRequest(
                workspace: workspace,
                taskInput: "Investigate customer API integration failure",
                taskFingerprint: fingerprint
            )
        )

        XCTAssertEqual(context.previousFailures.first?.title, "OAuth token expired")
        XCTAssertEqual(context.successfulFixes.first?.title, "Refresh token")
        XCTAssertEqual(context.customerSystemContext.first?.title, "Customer API uses OAuth")
        XCTAssertEqual(context.connectorHistory.first?.title, "GitHub connector healthy")
    }

    func testContextBundleInjectsEnterpriseMemoryBeforePlanning() async throws {
        let root = try makeTemporaryWorkspace()
        try writeFile(root.appendingPathComponent("README.md"), "# Demo")
        let workspace = Workspace.default()
        let store = InMemoryEnterpriseMemoryStore()
        let fingerprint = "investigate customer api integration failure"
        try await seedMemory(store: store, workspaceID: workspace.id, fingerprint: fingerprint)
        let diagnosticsStore = ContextCompilerDiagnosticsStore()
        let compiler = InstructionContextCompiler(
            workspaceRootURL: root,
            diagnosticsStore: diagnosticsStore,
            providerDiagnosticsSummary: "Local:enabled",
            persistenceStatus: "SQLitePersistenceStore initialized",
            memoryRetriever: EnterpriseMemoryRetriever(store: store)
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

        XCTAssertEqual(bundle.enterpriseMemory.previousFailures.first?.summary, "Customer API integration failed after OAuth token expiry.")
        XCTAssertEqual(bundle.enterpriseMemory.successfulFixes.first?.summary, "Refresh the OAuth token and retry the connector sync.")
        XCTAssertEqual(diagnostics.enterpriseMemory.previousFailures.first?.title, "OAuth token expired")
    }

    func testEnterpriseMemoryContextDoesNotChangeRuntimeExecutionCommands() async throws {
        let input = "Audit the local workspace and prepare an execution checkpoint"

        let baselinePersistence = InMemoryPersistenceStore()
        try await baselinePersistence.initialize()
        let baselineWorkspace = Workspace.default()
        try await baselinePersistence.saveWorkspace(baselineWorkspace)
        let baselineExecutor = MemoryRecordingToolExecutor()
        let baselineKernel = RuntimeKernel(
            persistence: baselinePersistence,
            eventBus: RuntimeEventBus(),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: baselineExecutor
        )

        let memoryPersistence = InMemoryPersistenceStore()
        try await memoryPersistence.initialize()
        let memoryWorkspace = Workspace.default()
        try await memoryPersistence.saveWorkspace(memoryWorkspace)
        let memoryStore = InMemoryEnterpriseMemoryStore()
        try await seedMemory(
            store: memoryStore,
            workspaceID: memoryWorkspace.id,
            fingerprint: TaskFingerprint.make(from: input)
        )
        let memoryExecutor = MemoryRecordingToolExecutor()
        let memoryKernel = RuntimeKernel(
            persistence: memoryPersistence,
            eventBus: RuntimeEventBus(),
            contextCompiler: InstructionContextCompiler(
                memoryRetriever: EnterpriseMemoryRetriever(store: memoryStore)
            ),
            modelRouter: ModelRouter(providers: [LocalDeterministicModelProvider()]),
            toolExecutor: memoryExecutor
        )

        let baselineTask = try await baselineKernel.submitTask(input: input, workspace: baselineWorkspace)
        let memoryTask = try await memoryKernel.submitTask(input: input, workspace: memoryWorkspace)
        let baselineCommands = await baselineExecutor.executedCommands()
        let memoryCommands = await memoryExecutor.executedCommands()

        XCTAssertEqual(baselineTask.state, .completed)
        XCTAssertEqual(memoryTask.state, .completed)
        XCTAssertEqual(memoryCommands, baselineCommands)
    }

    private func seedMemory(
        store: any EnterpriseMemoryStoring,
        workspaceID: UUID,
        fingerprint: String
    ) async throws {
        try await store.initialize()
        try await store.save(
            MemoryEntry(
                workspaceID: workspaceID,
                type: .failureMemory,
                title: "OAuth token expired",
                summary: "Customer API integration failed after OAuth token expiry.",
                tags: ["oauth", "api"],
                relatedTaskFingerprint: fingerprint,
                confidence: 0.95
            )
        )
        try await store.save(
            MemoryEntry(
                workspaceID: workspaceID,
                type: .solutionMemory,
                title: "Refresh token",
                summary: "Refresh the OAuth token and retry the connector sync.",
                tags: ["oauth", "fix"],
                relatedTaskFingerprint: fingerprint,
                confidence: 0.97
            )
        )
        try await store.save(
            MemoryEntry(
                workspaceID: workspaceID,
                type: .customerMemory,
                title: "Customer API uses OAuth",
                summary: "The customer integration depends on OAuth refresh tokens.",
                tags: ["customer", "oauth", "api"],
                confidence: 0.9
            )
        )
        try await store.save(
            MemoryEntry(
                workspaceID: workspaceID,
                type: .executionMemory,
                title: "GitHub connector healthy",
                summary: "Recent connector checks completed without errors.",
                tags: ["connector", "github", "api"],
                connectorID: "github",
                confidence: 0.8
            )
        )
    }

    private func makeTemporaryWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEEnterpriseMemoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeFile(_ url: URL, _ content: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor MemoryRecordingToolExecutor: ToolExecuting {
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

private actor CapturingPostgreSQLMemoryDatabase: PostgreSQLMemoryDatabase {
    private var initializedTableNames: [String] = []
    private var entries: [UUID: MemoryEntry] = [:]

    func initializeEnterpriseMemorySchema(tableName: String) async throws {
        initializedTableNames.append(tableName)
    }

    func upsertMemoryEntry(_ entry: MemoryEntry, tableName: String) async throws {
        entries[entry.id] = entry
    }

    func queryMemory(_ query: EnterpriseMemoryQuery, tableName: String) async throws -> [MemoryEntry] {
        entries.values
            .filter { entry in
                entry.workspaceID == query.workspaceID
                    && query.types.contains(entry.type)
                    && (entry.relatedTaskFingerprint == query.taskFingerprint || entry.summary.localizedCaseInsensitiveContains(query.text))
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func initializedTables() -> [String] {
        initializedTableNames
    }
}
