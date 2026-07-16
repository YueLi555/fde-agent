import Foundation

struct ExecutionContext: Codable, Hashable, Sendable {
    var workspace: Workspace
    var policyRules: [String]
    var graphSummary: String
    var recentTaskTitles: [String]
    var taskFingerprint: String
    var policyDeltas: [ExecutionPolicyDelta]
    var failurePatterns: [ExecutionFailurePattern]
    var systemFailureProfile: SystemFailureProfile?
    var globalExecutionPolicy: GlobalExecutionPolicy?
    var missionIntent: MissionIntent? = nil
    var missionWorkspaceScope: MissionWorkspaceScope? = nil
    var contextBundle: ContextBundle? = nil
}

struct ContextBundle: Codable, Hashable, Sendable {
    var missionIntent: MissionIntent?
    var missionWorkspaceScope: MissionWorkspaceScope
    var workspace: WorkspaceContextSummary
    var codebases: [CodebaseContextSummary]
    var systemState: SystemStateContext
    var taskMemory: TaskMemoryContext
    var enterpriseMemory: EnterpriseMemoryContext
    var graphSummary: GraphContextSummary
    var policySummary: PolicyContextSummary
    var redactions: [ContextRedaction]

    enum CodingKeys: String, CodingKey {
        case missionIntent = "mission_intent"
        case missionWorkspaceScope = "mission_workspace_scope"
        case workspace
        case codebases
        case systemState = "system_state"
        case taskMemory = "task_memory"
        case enterpriseMemory = "enterprise_memory"
        case graphSummary = "graph_summary"
        case policySummary = "policy_summary"
        case redactions
    }
}

struct WorkspaceContextSummary: Codable, Hashable, Sendable {
    var workspaceID: UUID
    var orgID: UUID
    var workspaceName: String
    var displayName: String
    var role: String
    var localDataNamespace: String
    var policyNamespace: String
    var memoryNamespace: String
    var eventNamespace: String
    var rootPath: String
    var agentRootPath: String?
    var fileTreeSummary: [String]
    var packageIndicators: [String]
    var readmePresent: Bool
    var readmePaths: [String]
    var configFiles: [String]
    var testFiles: [String]
    var sourceDirectories: [String]
    var recentlyModifiedFiles: [String]

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case orgID = "org_id"
        case workspaceName = "workspace_name"
        case displayName = "display_name"
        case role
        case localDataNamespace = "local_data_namespace"
        case policyNamespace = "policy_namespace"
        case memoryNamespace = "memory_namespace"
        case eventNamespace = "event_namespace"
        case rootPath = "root_path"
        case agentRootPath = "agent_root_path"
        case fileTreeSummary = "file_tree_summary"
        case packageIndicators = "package_indicators"
        case readmePresent = "readme_present"
        case readmePaths = "readme_paths"
        case configFiles = "config_files"
        case testFiles = "test_files"
        case sourceDirectories = "source_directories"
        case recentlyModifiedFiles = "recently_modified_files"
    }
}

struct CodebaseContextSummary: Codable, Hashable, Sendable {
    var role: String
    var rootPath: String
    var fileTreeSummary: [String]
    var packageIndicators: [String]
    var readmePresent: Bool
    var readmePaths: [String]
    var configFiles: [String]
    var testFiles: [String]
    var sourceDirectories: [String]
    var recentlyModifiedFiles: [String]

    enum CodingKeys: String, CodingKey {
        case role
        case rootPath = "root_path"
        case fileTreeSummary = "file_tree_summary"
        case packageIndicators = "package_indicators"
        case readmePresent = "readme_present"
        case readmePaths = "readme_paths"
        case configFiles = "config_files"
        case testFiles = "test_files"
        case sourceDirectories = "source_directories"
        case recentlyModifiedFiles = "recently_modified_files"
    }
}

struct SystemStateContext: Codable, Hashable, Sendable {
    var currentWorkingDirectory: String
    var appVersion: String
    var buildMode: String
    var availableLocalTools: [String]
    var selectedWorkspace: String
    var providerDiagnosticsSummary: String
    var persistenceStatus: String

    enum CodingKeys: String, CodingKey {
        case currentWorkingDirectory = "current_working_directory"
        case appVersion = "app_version"
        case buildMode = "build_mode"
        case availableLocalTools = "available_local_tools"
        case selectedWorkspace = "selected_workspace"
        case providerDiagnosticsSummary = "provider_diagnostics_summary"
        case persistenceStatus = "persistence_status"
    }
}

struct TaskMemoryContext: Codable, Hashable, Sendable {
    var recentSuccessfulTaskPatterns: [String]
    var recentFailureSignatures: [String]
    var avoidedTools: [String]
    var fallbackMappings: [String: String]
    var globalExecutionPolicySummary: String?

    enum CodingKeys: String, CodingKey {
        case recentSuccessfulTaskPatterns = "recent_successful_task_patterns"
        case recentFailureSignatures = "recent_failure_signatures"
        case avoidedTools = "avoided_tools"
        case fallbackMappings = "fallback_mappings"
        case globalExecutionPolicySummary = "global_execution_policy_summary"
    }
}

struct GraphContextSummary: Codable, Hashable, Sendable {
    var knownTaskNodes: [String]
    var knownTools: [String]
    var knownAgentNodes: [String]
    var dependencyEdgesCount: Int
    var recentlyUsedTools: [String]
    var detectedSystems: [String]
    var dependencyChains: [String]
    var integrationRisks: [String]
    var previousIncidents: [String]
    var previousSolutions: [String]
    var systemUnderstandingSummary: String

    enum CodingKeys: String, CodingKey {
        case knownTaskNodes = "known_task_nodes"
        case knownTools = "known_tools"
        case knownAgentNodes = "known_agent_nodes"
        case dependencyEdgesCount = "dependency_edges_count"
        case recentlyUsedTools = "recently_used_tools"
        case detectedSystems = "detected_systems"
        case dependencyChains = "dependency_chains"
        case integrationRisks = "integration_risks"
        case previousIncidents = "previous_incidents"
        case previousSolutions = "previous_solutions"
        case systemUnderstandingSummary = "system_understanding_summary"
    }
}

struct PolicyContextSummary: Codable, Hashable, Sendable {
    var policyRules: [String]
    var policyDeltaIDs: [UUID]
    var avoidedTools: [String]
    var fallbackMappings: [String: String]
    var retryBudget: Int
    var globalPolicySummary: String?

    enum CodingKeys: String, CodingKey {
        case policyRules = "policy_rules"
        case policyDeltaIDs = "policy_delta_ids"
        case avoidedTools = "avoided_tools"
        case fallbackMappings = "fallback_mappings"
        case retryBudget = "retry_budget"
        case globalPolicySummary = "global_policy_summary"
    }
}

struct ContextRedaction: Codable, Hashable, Sendable {
    var path: String
    var reason: String
}

struct ContextCompilerDiagnostics: Codable, Hashable, Sendable {
    var filesScanned: Int
    var ignoredPathsCount: Int
    var redactionsCount: Int
    var contextBundleSizeBytes: Int
    var lastCompileLatencyMilliseconds: Double
    var contextPassedToPlanner: Bool
    var enterpriseMemory: EnterpriseMemoryContext
    var enterpriseSystemGraph: EnterpriseSystemUnderstandingSummary
    var rootPath: String
    var compiledAt: Date

    static let empty = ContextCompilerDiagnostics(
        filesScanned: 0,
        ignoredPathsCount: 0,
        redactionsCount: 0,
        contextBundleSizeBytes: 0,
        lastCompileLatencyMilliseconds: 0,
        contextPassedToPlanner: false,
        enterpriseMemory: .empty,
        enterpriseSystemGraph: .empty,
        rootPath: "",
        compiledAt: Date()
    )

    init(
        filesScanned: Int,
        ignoredPathsCount: Int,
        redactionsCount: Int,
        contextBundleSizeBytes: Int,
        lastCompileLatencyMilliseconds: Double,
        contextPassedToPlanner: Bool,
        enterpriseMemory: EnterpriseMemoryContext = .empty,
        enterpriseSystemGraph: EnterpriseSystemUnderstandingSummary = .empty,
        rootPath: String,
        compiledAt: Date
    ) {
        self.filesScanned = filesScanned
        self.ignoredPathsCount = ignoredPathsCount
        self.redactionsCount = redactionsCount
        self.contextBundleSizeBytes = contextBundleSizeBytes
        self.lastCompileLatencyMilliseconds = lastCompileLatencyMilliseconds
        self.contextPassedToPlanner = contextPassedToPlanner
        self.enterpriseMemory = enterpriseMemory
        self.enterpriseSystemGraph = enterpriseSystemGraph
        self.rootPath = rootPath
        self.compiledAt = compiledAt
    }
}

actor ContextCompilerDiagnosticsStore {
    private var current: ContextCompilerDiagnostics

    init(initial: ContextCompilerDiagnostics = .empty) {
        self.current = initial
    }

    func update(_ diagnostics: ContextCompilerDiagnostics) {
        current = diagnostics
    }

    func markPassedToPlanner(bundleSizeBytes: Int) {
        current.contextPassedToPlanner = true
        current.contextBundleSizeBytes = bundleSizeBytes
        current.compiledAt = Date()
    }

    func snapshot() -> ContextCompilerDiagnostics {
        current
    }
}

struct LocalWorkspaceSnapshot: Codable, Hashable, Sendable {
    var rootPath: String
    var fileTreeSummary: [String]
    var packageIndicators: [String]
    var readmePresent: Bool
    var readmePaths: [String]
    var configFiles: [String]
    var testFiles: [String]
    var sourceDirectories: [String]
    var recentlyModifiedFiles: [String]
    var filesScanned: Int
    var ignoredPathsCount: Int
    var redactions: [ContextRedaction]
}

struct LocalWorkspaceScanner: Sendable {
    var maxEntries: Int = 600
    var maxSummaryEntries: Int = 80

    func scan(rootURL: URL) -> LocalWorkspaceSnapshot {
        let fileManager = FileManager.default
        let standardizedRoot = rootURL.standardizedFileURL
        let rootPath = standardizedRoot.path
        var fileTree: [String] = []
        var packageIndicators = Set<String>()
        var readmePaths: [String] = []
        var configFiles: [String] = []
        var testFiles: [String] = []
        var sourceDirectories = Set<String>()
        var modifiedFiles: [(path: String, date: Date)] = []
        var redactions: [ContextRedaction] = []
        var ignoredPathsCount = 0
        var filesScanned = 0
        var visitedEntries = 0

        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsPackageDescendants]
        ) else {
            return LocalWorkspaceSnapshot(
                rootPath: rootPath,
                fileTreeSummary: [],
                packageIndicators: [],
                readmePresent: false,
                readmePaths: [],
                configFiles: [],
                testFiles: [],
                sourceDirectories: [],
                recentlyModifiedFiles: [],
                filesScanned: 0,
                ignoredPathsCount: 1,
                redactions: [ContextRedaction(path: rootPath, reason: "Workspace root was not enumerable")]
            )
        }

        for case let url as URL in enumerator {
            visitedEntries += 1
            if visitedEntries > maxEntries {
                ignoredPathsCount += 1
                break
            }

            let relativePath = Self.relativePath(for: url, rootPath: rootPath)
            let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let name = url.lastPathComponent

            if shouldIgnore(relativePath: relativePath, name: name) {
                ignoredPathsCount += 1
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if secretRedactionReason(relativePath: relativePath, name: name) != nil {
                redactions.append(
                    ContextRedaction(
                        path: relativePath,
                        reason: "Secret-like file path redacted; content was not read"
                    )
                )
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }

            if fileTree.count < maxSummaryEntries {
                fileTree.append(isDirectory ? "\(relativePath)/" : relativePath)
            }

            if isDirectory {
                if isSourceDirectory(name: name) {
                    sourceDirectories.insert(relativePath)
                }
                if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                    packageIndicators.insert("Xcode")
                    configFiles.append(relativePath)
                }
                continue
            }

            filesScanned += 1
            classifyFile(
                relativePath: relativePath,
                name: name,
                packageIndicators: &packageIndicators,
                readmePaths: &readmePaths,
                configFiles: &configFiles,
                testFiles: &testFiles
            )

            if let modified = resourceValues?.contentModificationDate {
                modifiedFiles.append((relativePath, modified))
            }
        }

        return LocalWorkspaceSnapshot(
            rootPath: rootPath,
            fileTreeSummary: fileTree,
            packageIndicators: packageIndicators.sorted(),
            readmePresent: !readmePaths.isEmpty,
            readmePaths: Array(readmePaths.prefix(12)),
            configFiles: Array(configFiles.prefix(24)),
            testFiles: Array(testFiles.prefix(24)),
            sourceDirectories: sourceDirectories.sorted(),
            recentlyModifiedFiles: modifiedFiles
                .sorted { $0.date > $1.date }
                .prefix(12)
                .map(\.path),
            filesScanned: filesScanned,
            ignoredPathsCount: ignoredPathsCount,
            redactions: redactions
        )
    }

    private func shouldIgnore(relativePath: String, name: String) -> Bool {
        let ignoredNames: Set<String> = [
            ".git",
            ".build",
            ".swiftpm",
            "node_modules",
            "DerivedData",
            ".cache",
            "Cache",
            "Caches",
            ".build-cache",
            ".build-home"
        ]
        if ignoredNames.contains(name) {
            return true
        }
        let components = relativePath.split(separator: "/").map(String.init)
        return components.contains { ignoredNames.contains($0) }
    }

    private func secretRedactionReason(relativePath: String, name: String) -> String? {
        let lowerName = name.lowercased()
        let lowerPath = relativePath.lowercased()
        if lowerName == ".env" || lowerName.hasPrefix(".env.") {
            return "environment file"
        }
        if lowerName == ".npmrc" || lowerName == ".pypirc" || lowerName == ".netrc" {
            return "credential configuration"
        }
        if lowerName.hasSuffix(".pem") || lowerName.hasSuffix(".key") || lowerName.hasSuffix(".p12") {
            return "private key material"
        }
        if lowerPath.contains(".aws/") || lowerPath.contains(".ssh/") {
            return "credential directory"
        }
        if lowerPath.contains("secret")
            || lowerPath.contains("credential")
            || lowerPath.contains("token")
            || lowerPath.contains("apikey")
            || lowerPath.contains("api_key")
            || lowerPath.contains("private_key") {
            return "secret-like filename"
        }
        return nil
    }

    private func isSourceDirectory(name: String) -> Bool {
        ["Sources", "Source", "src", "lib", "App"].contains(name)
    }

    private func classifyFile(
        relativePath: String,
        name: String,
        packageIndicators: inout Set<String>,
        readmePaths: inout [String],
        configFiles: inout [String],
        testFiles: inout [String]
    ) {
        let lowerName = name.lowercased()
        let lowerPath = relativePath.lowercased()

        if lowerName.hasPrefix("readme") {
            readmePaths.append(relativePath)
        }

        switch lowerName {
        case "package.swift":
            packageIndicators.insert("SwiftPM")
            configFiles.append(relativePath)
        case "package.json":
            packageIndicators.insert("Node")
            configFiles.append(relativePath)
        case "pyproject.toml", "requirements.txt":
            packageIndicators.insert("Python")
            configFiles.append(relativePath)
        case "project.yml", "workspace.yml", "xcodegen.yml", "dockerfile", "docker-compose.yml":
            configFiles.append(relativePath)
        default:
            if lowerName.hasSuffix(".xcodeproj") || lowerName.hasSuffix(".xcworkspace") {
                packageIndicators.insert("Xcode")
                configFiles.append(relativePath)
            } else if lowerName.hasSuffix(".yml")
                || lowerName.hasSuffix(".yaml")
                || lowerName.hasSuffix(".json")
                || lowerName.hasSuffix(".toml")
                || lowerName.hasSuffix(".plist") {
                configFiles.append(relativePath)
            }
        }

        if lowerPath.contains("/tests/") || lowerPath.contains("/test/") || lowerName.contains("test") {
            testFiles.append(relativePath)
        }
    }

    private static func relativePath(for url: URL, rootPath: String) -> String {
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/"
        if path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return url.lastPathComponent
    }
}

enum TaskFingerprint {
    static func make(from input: String) -> String {
        input
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .punctuationCharacters)
    }
}

struct InstructionContextCompiler: Sendable {
    var workspaceRootURL: URL
    var workspaceScanner: LocalWorkspaceScanner
    var diagnosticsStore: ContextCompilerDiagnosticsStore?
    var providerDiagnosticsSummary: String
    var persistenceStatus: String
    var memoryRetriever: (any MemoryRetrieving)?
    var enterpriseGraphStore: (any EnterpriseSystemGraphStoring)?
    var enterpriseGraphIntelligence: EnterpriseSystemGraphIntelligence

    init(
        workspaceRootURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        workspaceScanner: LocalWorkspaceScanner = LocalWorkspaceScanner(),
        diagnosticsStore: ContextCompilerDiagnosticsStore? = nil,
        providerDiagnosticsSummary: String = "Provider diagnostics unavailable",
        persistenceStatus: String = "Persistence status unavailable",
        memoryRetriever: (any MemoryRetrieving)? = nil,
        enterpriseGraphStore: (any EnterpriseSystemGraphStoring)? = nil,
        enterpriseGraphIntelligence: EnterpriseSystemGraphIntelligence = EnterpriseSystemGraphIntelligence()
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.workspaceScanner = workspaceScanner
        self.diagnosticsStore = diagnosticsStore
        self.providerDiagnosticsSummary = providerDiagnosticsSummary
        self.persistenceStatus = persistenceStatus
        self.memoryRetriever = memoryRetriever
        self.enterpriseGraphStore = enterpriseGraphStore
        self.enterpriseGraphIntelligence = enterpriseGraphIntelligence
    }

    func compile(
        workspace: Workspace,
        taskInput: String = "",
        missionWorkspaceScope requestedScope: MissionWorkspaceScope? = nil,
        recentTasks: [FDETask],
        graph: ([SystemGraphNode], [SystemGraphEdge]),
        policyDeltas: [ExecutionPolicyDelta] = [],
        workspaceEvents: [ExecutionEvent] = [],
        failureEvents: [ExecutionEvent] = [],
        systemFailureProfile: SystemFailureProfile? = nil,
        globalExecutionPolicy: GlobalExecutionPolicy? = nil
    ) async -> ExecutionContext {
        let startedAt = Date()
        let missionIntent = MissionIntentParser().parse(taskInput)
        let missionWorkspaceScope = requestedScope ?? (
            MissionExecutionSemantic(intent: missionIntent) == .readOnlyWorkspaceInspection
                ? MissionWorkspaceScope(request: taskInput)
                : .legacyAndAgentComparison
        )
        let legacyWorkspaceSnapshot = missionWorkspaceScope.codebaseRoles.contains("legacy_software")
            ? workspace.localProjectRootURL.map { workspaceScanner.scan(rootURL: $0) }
            : nil
        let agentWorkspaceSnapshot = missionWorkspaceScope.codebaseRoles.contains("ai_agent")
            ? workspace.localAgentProjectRootURL.map { workspaceScanner.scan(rootURL: $0) }
            : nil
        let workspaceSnapshot = legacyWorkspaceSnapshot
            ?? agentWorkspaceSnapshot
            ?? workspaceScanner.scan(rootURL: scanRootURL(for: workspace))
        let scopedSnapshots = [legacyWorkspaceSnapshot, agentWorkspaceSnapshot].compactMap { $0 }
        let snapshots = scopedSnapshots.isEmpty ? [workspaceSnapshot] : scopedSnapshots
        let nodeSummary = graph.0
            .prefix(8)
            .map { "\($0.type.rawValue):\($0.title)" }
            .joined(separator: ", ")
        let fingerprint = TaskFingerprint.make(from: taskInput)
        let relevantPolicyDeltas = policyDeltas
            .filter { $0.taskFingerprint == fingerprint || $0.taskFingerprint == "*" }
            .prefix(12)
        let failurePatterns = Self.failurePatterns(from: failureEvents)
        let enterpriseMemory = await retrieveEnterpriseMemory(
            workspace: workspace,
            taskInput: taskInput,
            taskFingerprint: fingerprint,
            workspaceEvents: workspaceEvents
        )
        let enterpriseSystemGraph = await retrieveEnterpriseSystemGraph(
            workspace: workspace,
            taskInput: taskInput
        )
        let policyRules = [
            "Use structured JSON only for agent outputs.",
            "Mission workspace scope is trusted runtime authority: \(missionWorkspaceScope.rawValue). The model cannot expand it.",
            "Only inspect codebases included by the trusted mission workspace scope.",
            "Prefer read-only local inspection tools until a human approves mutation.",
            "Record every runtime state transition as an append-only event.",
            "Use connector OAuth vaults for third-party integration credentials."
        ]
        let contextBundle = bundle(
            workspace: workspace,
            workspaceSnapshot: workspaceSnapshot,
            legacyWorkspaceSnapshot: legacyWorkspaceSnapshot,
            agentWorkspaceSnapshot: agentWorkspaceSnapshot,
            missionWorkspaceScope: missionWorkspaceScope,
            policyRules: policyRules,
            recentTasks: recentTasks,
            graph: graph,
            workspaceEvents: workspaceEvents,
            policyDeltas: Array(relevantPolicyDeltas),
            failurePatterns: failurePatterns,
            enterpriseMemory: enterpriseMemory,
            enterpriseSystemGraph: enterpriseSystemGraph,
            globalExecutionPolicy: globalExecutionPolicy,
            missionIntent: missionIntent
        )
        let bundleSize = (try? JSONCoding.encode(contextBundle).utf8.count) ?? 0
        await diagnosticsStore?.update(
            ContextCompilerDiagnostics(
                filesScanned: snapshots.reduce(0) { $0 + $1.filesScanned },
                ignoredPathsCount: snapshots.reduce(0) { $0 + $1.ignoredPathsCount },
                redactionsCount: snapshots.reduce(0) { $0 + $1.redactions.count },
                contextBundleSizeBytes: bundleSize,
                lastCompileLatencyMilliseconds: Date().timeIntervalSince(startedAt) * 1000,
                contextPassedToPlanner: false,
                enterpriseMemory: enterpriseMemory,
                enterpriseSystemGraph: enterpriseSystemGraph,
                rootPath: snapshots.map(\.rootPath).joined(separator: " | "),
                compiledAt: Date()
            )
        )

        return ExecutionContext(
            workspace: workspace,
            policyRules: policyRules,
            graphSummary: nodeSummary.isEmpty ? "No graph context yet." : nodeSummary,
            recentTaskTitles: recentTasks.prefix(5).map(\.title),
            taskFingerprint: fingerprint,
            policyDeltas: Array(relevantPolicyDeltas),
            failurePatterns: failurePatterns,
            systemFailureProfile: systemFailureProfile,
            globalExecutionPolicy: globalExecutionPolicy,
            missionIntent: missionIntent,
            missionWorkspaceScope: missionWorkspaceScope,
            contextBundle: contextBundle
        )
    }

    private func scanRootURL(for workspace: Workspace) -> URL {
        workspace.localProjectRootURL ?? workspaceRootURL.standardizedFileURL
    }

    private func bundle(
        workspace: Workspace,
        workspaceSnapshot: LocalWorkspaceSnapshot,
        legacyWorkspaceSnapshot: LocalWorkspaceSnapshot?,
        agentWorkspaceSnapshot: LocalWorkspaceSnapshot?,
        missionWorkspaceScope: MissionWorkspaceScope,
        policyRules: [String],
        recentTasks: [FDETask],
        graph: ([SystemGraphNode], [SystemGraphEdge]),
        workspaceEvents: [ExecutionEvent],
        policyDeltas: [ExecutionPolicyDelta],
        failurePatterns: [ExecutionFailurePattern],
        enterpriseMemory: EnterpriseMemoryContext,
        enterpriseSystemGraph: EnterpriseSystemUnderstandingSummary,
        globalExecutionPolicy: GlobalExecutionPolicy?,
        missionIntent: MissionIntent?
    ) -> ContextBundle {
        let avoidedTools = Array(Set(
            policyDeltas.compactMap(\.avoidToolCommand)
                + (globalExecutionPolicy?.avoidedToolCommands ?? [])
        )).sorted()
        var fallbackMappings = globalExecutionPolicy?.toolPreferences ?? [:]
        for delta in policyDeltas {
            if let avoid = delta.avoidToolCommand, let replacement = delta.replacementToolCommand {
                fallbackMappings[avoid] = replacement
            }
        }

        return ContextBundle(
            missionIntent: missionIntent,
            missionWorkspaceScope: missionWorkspaceScope,
            workspace: WorkspaceContextSummary(
                workspaceID: workspace.id,
                orgID: workspace.orgID,
                workspaceName: workspace.name,
                displayName: workspace.displayName,
                role: workspace.role.rawValue,
                localDataNamespace: workspace.localDataNamespace,
                policyNamespace: workspace.policyNamespace,
                memoryNamespace: workspace.memoryNamespace,
                eventNamespace: workspace.eventNamespace,
                rootPath: workspaceSnapshot.rootPath,
                agentRootPath: agentWorkspaceSnapshot?.rootPath,
                fileTreeSummary: workspaceSnapshot.fileTreeSummary,
                packageIndicators: workspaceSnapshot.packageIndicators,
                readmePresent: workspaceSnapshot.readmePresent,
                readmePaths: workspaceSnapshot.readmePaths,
                configFiles: workspaceSnapshot.configFiles,
                testFiles: workspaceSnapshot.testFiles,
                sourceDirectories: workspaceSnapshot.sourceDirectories,
                recentlyModifiedFiles: workspaceSnapshot.recentlyModifiedFiles
            ),
            codebases: codebaseContexts(
                legacySnapshot: legacyWorkspaceSnapshot,
                agentSnapshot: agentWorkspaceSnapshot
            ),
            systemState: SystemStateContext(
                currentWorkingDirectory: workspaceSnapshot.rootPath,
                appVersion: appVersion(),
                buildMode: buildMode(),
                availableLocalTools: availableLocalTools(),
                selectedWorkspace: "\(workspace.name) (\(workspace.role.rawValue))",
                providerDiagnosticsSummary: providerDiagnosticsSummary,
                persistenceStatus: persistenceStatus
            ),
            taskMemory: TaskMemoryContext(
                recentSuccessfulTaskPatterns: recentTasks
                    .filter { $0.state == .completed && $0.performanceScore >= 70 }
                    .prefix(8)
                    .map { TaskFingerprint.make(from: $0.rawInput) },
                recentFailureSignatures: failurePatterns.prefix(12).map { "\($0.command)|\($0.toolCallID)|count:\($0.count)" },
                avoidedTools: avoidedTools,
                fallbackMappings: fallbackMappings,
                globalExecutionPolicySummary: globalExecutionPolicy?.summary
            ),
            enterpriseMemory: enterpriseMemory,
            graphSummary: GraphContextSummary(
                knownTaskNodes: graph.0.filter { $0.id.hasPrefix("task:") }.prefix(12).map(\.title),
                knownTools: graph.0.filter { $0.id.hasPrefix("tool:") }.prefix(16).map(\.title),
                knownAgentNodes: graph.0.filter { $0.id.hasPrefix("agent:") }.prefix(12).map(\.title),
                dependencyEdgesCount: graph.1.filter { $0.kind == .dependency }.count,
                recentlyUsedTools: recentlyUsedTools(from: workspaceEvents),
                detectedSystems: enterpriseSystemGraph.detectedSystems,
                dependencyChains: enterpriseSystemGraph.dependencies,
                integrationRisks: enterpriseSystemGraph.risks.map { "\($0.title): \($0.detail)" },
                previousIncidents: enterpriseSystemGraph.previousIncidents,
                previousSolutions: enterpriseSystemGraph.previousSolutions,
                systemUnderstandingSummary: enterpriseSystemGraph.narrative
            ),
            policySummary: PolicyContextSummary(
                policyRules: policyRules,
                policyDeltaIDs: policyDeltas.prefix(12).map(\.id),
                avoidedTools: avoidedTools,
                fallbackMappings: fallbackMappings,
                retryBudget: max(policyDeltas.map(\.retryBudget).max() ?? 0, globalExecutionPolicy?.defaultRetryBudget ?? 0),
                globalPolicySummary: globalExecutionPolicy?.summary
            ),
            redactions: legacyWorkspaceSnapshot == nil && agentWorkspaceSnapshot == nil
                ? workspaceSnapshot.redactions
                : (legacyWorkspaceSnapshot?.redactions ?? []) + (agentWorkspaceSnapshot?.redactions ?? [])
        )
    }

    private func codebaseContexts(
        legacySnapshot: LocalWorkspaceSnapshot?,
        agentSnapshot: LocalWorkspaceSnapshot?
    ) -> [CodebaseContextSummary] {
        var codebases: [CodebaseContextSummary] = []
        if let legacySnapshot {
            codebases.append(codebaseContext(role: "legacy_software", snapshot: legacySnapshot))
        }
        if let agentSnapshot {
            codebases.append(codebaseContext(role: "ai_agent", snapshot: agentSnapshot))
        }
        return codebases
    }

    private func codebaseContext(
        role: String,
        snapshot: LocalWorkspaceSnapshot
    ) -> CodebaseContextSummary {
        CodebaseContextSummary(
            role: role,
            rootPath: snapshot.rootPath,
            fileTreeSummary: snapshot.fileTreeSummary,
            packageIndicators: snapshot.packageIndicators,
            readmePresent: snapshot.readmePresent,
            readmePaths: snapshot.readmePaths,
            configFiles: snapshot.configFiles,
            testFiles: snapshot.testFiles,
            sourceDirectories: snapshot.sourceDirectories,
            recentlyModifiedFiles: snapshot.recentlyModifiedFiles
        )
    }

    private func retrieveEnterpriseSystemGraph(
        workspace: Workspace,
        taskInput: String
    ) async -> EnterpriseSystemUnderstandingSummary {
        guard let enterpriseGraphStore else {
            return .empty
        }

        do {
            try await enterpriseGraphStore.initialize()
            let snapshot = try await enterpriseGraphStore.load(workspaceID: workspace.id)
            return enterpriseGraphIntelligence.summarize(snapshot: snapshot, taskInput: taskInput)
        } catch {
            return .empty
        }
    }

    private func retrieveEnterpriseMemory(
        workspace: Workspace,
        taskInput: String,
        taskFingerprint: String,
        workspaceEvents: [ExecutionEvent]
    ) async -> EnterpriseMemoryContext {
        guard let memoryRetriever else {
            return .empty
        }

        return await memoryRetriever.retrieveContext(
            for: MemoryRetrievalRequest(
                workspace: workspace,
                taskInput: taskInput,
                taskFingerprint: taskFingerprint,
                recentEvents: workspaceEvents
            )
        )
    }

    private func recentlyUsedTools(from events: [ExecutionEvent]) -> [String] {
        var seen = Set<String>()
        var tools: [String] = []

        for event in events.reversed() where event.type == .toolCalled || event.type == .stepExecuted || event.type == .toolFailed {
            guard let command = event.payload["command"], !command.isEmpty, seen.insert(command).inserted else {
                continue
            }
            tools.append(command)
            if tools.count >= 12 {
                break
            }
        }

        return tools
    }

    private func availableLocalTools() -> [String] {
        ReadOnlyInspectionPolicy.orderedAllowedTools
    }

    private func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
    }

    private func buildMode() -> String {
        #if DEBUG
        "debug"
        #else
        "release"
        #endif
    }

    private static func failurePatterns(from events: [ExecutionEvent]) -> [ExecutionFailurePattern] {
        let failures = events.filter { $0.type == .toolFailed }
        let grouped = Dictionary(grouping: failures) { event in
            let command = event.payload["command"] ?? "unknown"
            let toolCallID = event.payload["tool_call_id"] ?? "unknown"
            return "\(command)|\(toolCallID)"
        }

        return grouped.map { key, values in
            let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
            let latest = values.sorted { $0.sequence < $1.sequence }.last
            return ExecutionFailurePattern(
                command: parts.first ?? "unknown",
                toolCallID: parts.dropFirst().first ?? "unknown",
                count: values.count,
                latestSummary: latest?.summary ?? "Unknown failure"
            )
        }
        .sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs.command < rhs.command
            }
            return lhs.count > rhs.count
        }
    }
}
