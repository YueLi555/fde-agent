import Foundation

struct AppEnvironment: Sendable {
    let persistence: any PersistenceStore
    let eventBus: RuntimeEventBus
    let eventStream: any EventStream
    let runtime: RuntimeKernel
    let modelDiagnostics: ModelProviderDiagnosticsStore
    let contextDiagnostics: ContextCompilerDiagnosticsStore
    let keychain: KeychainSessionStore
    let sessionRepository: SessionRepository
    let authorizationService: AuthorizationService
    let connectors: ConnectorRegistry
    let agentResponseComposer: AgentResponseComposer
    let agentChatProvider: (any AgentChatProviding)?
    let enterpriseMemoryStore: any EnterpriseMemoryStoring
    let memoryRetriever: any MemoryRetrieving
    let enterpriseSystemGraphStore: any EnterpriseSystemGraphStoring
    let sandboxLifecycle: SandboxLifecycleService

    static func live() -> (AppEnvironment, String?) {
        let eventBus = RuntimeEventBus()
        let persistence: any PersistenceStore
        var startupIssue: String?

        do {
            let supportURL = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("FDECloudOS", isDirectory: true)
                ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("FDECloudOS", isDirectory: true)
            persistence = try SQLitePersistenceStore(databaseURL: supportURL.appendingPathComponent("FDECloudOS.sqlite"))
        } catch {
            persistence = InMemoryPersistenceStore()
            startupIssue = "SQLite unavailable; using in-memory store for this launch. \(error.localizedDescription)"
        }

        let keychain = KeychainSessionStore()
        let modelConfiguration = ModelProviderConfiguration.environment(secureStore: keychain)
        let rawModelProvider = ProcessInfo.processInfo.environment["FDE_MODEL_PROVIDER"] ?? "unset"
        LLMNarrationDebugLog.write(
            "app_environment provider_env=\(rawModelProvider) openai_key_present=\(modelConfiguration.openAIAPIKey != nil) openai_model=\(modelConfiguration.openAIModel)"
        )
        let providers = ModelProviderFactory.productionProviders(configuration: modelConfiguration)
        let modelDiagnostics = ModelProviderDiagnosticsStore(initial: .initial(providers: providers))
        let contextDiagnostics = ContextCompilerDiagnosticsStore()
        let initialModelDiagnostics = ModelProviderDiagnostics.initial(providers: providers)
        let authorizationService = AuthorizationService()
        let connectorRegistry = ConnectorRegistry.default()
        let agentResponseComposer = AgentResponseComposer.live(configuration: modelConfiguration)
        let agentChatProvider = ModelProviderFactory.chatProvider(configuration: modelConfiguration)
        let enterpriseMemoryStore = InMemoryEnterpriseMemoryStore()
        let memoryRetriever = EnterpriseMemoryRetriever(store: enterpriseMemoryStore)
        let enterpriseSystemGraphStore = InMemoryEnterpriseSystemGraphStore()
        let eventStream = InMemoryEventStream(eventBus: eventBus)
        let router = ModelRouter(
            providers: providers,
            diagnosticsStore: modelDiagnostics,
            contextDiagnosticsStore: contextDiagnostics
        )
        let contextCompiler = InstructionContextCompiler(
            diagnosticsStore: contextDiagnostics,
            providerDiagnosticsSummary: Self.providerSummary(initialModelDiagnostics),
            persistenceStatus: Self.persistenceStatus(for: persistence, startupIssue: startupIssue),
            memoryRetriever: memoryRetriever,
            enterpriseGraphStore: enterpriseSystemGraphStore
        )

        let sandboxLifecycle = SandboxLifecycleService(
            storageRoot: SandboxLifecycleService.defaultStorageRoot
        )
        let runtime = RuntimeKernel(
            persistence: persistence,
            eventBus: eventBus,
            eventStream: eventStream,
            contextCompiler: contextCompiler,
            modelRouter: router,
            toolExecutor: PublicReleaseToolExecutor(),
            authorizationService: authorizationService,
            enterpriseMemoryStore: enterpriseMemoryStore,
            completionPolicy: .evidenceRequired,
            requiresProjectScope: true,
            sandboxLifecycle: sandboxLifecycle
        )

        return (
            AppEnvironment(
                persistence: persistence,
                eventBus: eventBus,
                eventStream: eventStream,
                runtime: runtime,
                modelDiagnostics: modelDiagnostics,
                contextDiagnostics: contextDiagnostics,
                keychain: keychain,
                sessionRepository: SessionRepository(persistence: persistence, secureStore: keychain),
                authorizationService: authorizationService,
                connectors: connectorRegistry,
                agentResponseComposer: agentResponseComposer,
                agentChatProvider: agentChatProvider,
                enterpriseMemoryStore: enterpriseMemoryStore,
                memoryRetriever: memoryRetriever,
                enterpriseSystemGraphStore: enterpriseSystemGraphStore,
                sandboxLifecycle: sandboxLifecycle
            ),
            startupIssue
        )
    }

    private static func providerSummary(_ diagnostics: ModelProviderDiagnostics) -> String {
        diagnostics.liveProviderStates
            .map { state in
                "\(state.provider):\(state.enabled ? "enabled" : "disabled")"
            }
            .joined(separator: ", ")
    }

    private static func persistenceStatus(for persistence: any PersistenceStore, startupIssue: String?) -> String {
        let typeName = String(describing: type(of: persistence))
        if let startupIssue {
            return "\(typeName) fallback: \(startupIssue)"
        }
        return "\(typeName) initialized"
    }
}
