import Foundation

enum ToolExecutionError: LocalizedError, Equatable {
    case approvalRequired(String)
    case commandNotAllowed(String)
    case workingDirectoryOutsideProject(String, String)
    case unsupportedTool(ToolType)
    case processFailed(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .approvalRequired(let id):
            return "Tool call requires human approval: \(id)"
        case .commandNotAllowed(let command):
            return "Command is not allowed by sandbox policy: \(command)"
        case .workingDirectoryOutsideProject(let directory, let projectRoot):
            return "Working directory \(directory) is outside selected project scope \(projectRoot)."
        case .unsupportedTool(let type):
            return "Unsupported tool type: \(type.rawValue)"
        case .processFailed(let detail):
            return "Process failed: \(detail)"
        case .timedOut(let command):
            return "Command timed out: \(command)"
        }
    }
}

protocol ToolExecuting: Sendable {
    func execute(_ call: ToolCall) async throws -> ToolExecutionResult
}

/// The executor composed by the public v0.1.0 application for generic
/// model-emitted tool calls.
///
/// Older internal executors remain in the source tree for compatibility with
/// deterministic tests, but the release application exposes only the bounded
/// read-only inspection commands used by Phase 2D.0. Safe Sandbox acceptance
/// is a separate mission route backed directly by `SandboxLifecycleService`;
/// it does not pass through this executor.
struct PublicReleaseToolExecutor: ToolExecuting {
    private let readOnlyExecutor: WorkspaceEngineeringToolExecutor

    init(readOnlyExecutor: WorkspaceEngineeringToolExecutor = WorkspaceEngineeringToolExecutor()) {
        self.readOnlyExecutor = readOnlyExecutor
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard call.type == .api,
              ReadOnlyInspectionPolicy.allowedTools.contains(call.command) else {
            throw ToolExecutionError.commandNotAllowed(call.command)
        }
        return try await readOnlyExecutor.execute(call)
    }
}

struct ShellSandboxPolicy: Sendable {
    var allowedExecutables: Set<String> = [
        "/bin/pwd",
        "/bin/ls",
        "/bin/echo",
        "/usr/bin/head",
        "/usr/bin/swift",
        "/usr/bin/whoami",
        "/usr/bin/env",
        "/usr/bin/osascript",
        "/usr/bin/true"
    ]
    var timeoutSeconds: TimeInterval = 5

    func validate(command: String) throws {
        guard allowedExecutables.contains(command) else {
            throw ToolExecutionError.commandNotAllowed(command)
        }
    }
}

struct LocalToolExecutor: ToolExecuting {
    let policy: ShellSandboxPolicy

    init(policy: ShellSandboxPolicy = ShellSandboxPolicy()) {
        self.policy = policy
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard !call.requiresApproval else {
            throw ToolExecutionError.approvalRequired(call.id)
        }

        switch call.type {
        case .shell:
            return try await runProcess(
                callID: call.id,
                command: call.command,
                arguments: call.arguments,
                workingDirectory: call.workingDirectory
            )
        case .appleScript:
            return try await runProcess(
                callID: call.id,
                command: "/usr/bin/osascript",
                arguments: ["-e", ([call.command] + call.arguments).joined(separator: " ")],
                workingDirectory: call.workingDirectory
            )
        case .api, .connector:
            throw ToolExecutionError.unsupportedTool(call.type)
        }
    }

    private func runProcess(
        callID: String,
        command: String,
        arguments: [String],
        workingDirectory: String?
    ) async throws -> ToolExecutionResult {
        try policy.validate(command: command)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let start = Date()
                let process = Process()
                let output = Pipe()
                let error = Pipe()
                let semaphore = DispatchSemaphore(value: 0)

                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = error
                if let workingDirectory {
                    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
                }
                process.terminationHandler = { _ in semaphore.signal() }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ToolExecutionError.processFailed(error.localizedDescription))
                    return
                }

                let waitResult = semaphore.wait(timeout: .now() + policy.timeoutSeconds)
                if waitResult == .timedOut {
                    process.terminate()
                    continuation.resume(throwing: ToolExecutionError.timedOut(command))
                    return
                }

                let stdout = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(
                    returning: ToolExecutionResult(
                        callID: callID,
                        exitCode: process.terminationStatus,
                        standardOutput: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                        standardError: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                        duration: Date().timeIntervalSince(start)
                    )
                )
            }
        }
    }
}

struct WorkspaceEngineeringToolExecutor: ToolExecuting {
    let fallback: any ToolExecuting
    let shellPolicy: ShellSandboxPolicy

    init(
        fallback: any ToolExecuting = LocalToolExecutor(),
        shellPolicy: ShellSandboxPolicy = ShellSandboxPolicy()
    ) {
        self.fallback = fallback
        self.shellPolicy = shellPolicy
    }

    func execute(_ call: ToolCall) async throws -> ToolExecutionResult {
        guard call.type == .api, Self.isWorkspaceEngineeringCommand(call.command) else {
            return try await fallback.execute(call)
        }

        let startedAt = Date()
        let workspaceRoot = URL(
            fileURLWithPath: call.workingDirectory ?? FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        .standardizedFileURL
        let connector = LocalEngineeringConnector(workspaceRoot: workspaceRoot)

        do {
            let output: String
            switch Self.normalizedAction(call.command) {
            case "list_directory":
                output = try listDirectory(call: call, workspaceRoot: workspaceRoot)
            case "read_file":
                output = try await connector.readFile(Self.argumentValue(["path", "file"], in: call.arguments) ?? ".").output
            case "search_files", "search_code":
                let query = Self.argumentValue(["query", "q", "pattern"], in: call.arguments) ?? ""
                let extensions = Self.argumentValue(["extensions", "ext", "file_extensions"], in: call.arguments)
                    .map(Self.commaSeparatedValues) ?? []
                let searchPath = Self.argumentValue(["path", "directory", "dir"], in: call.arguments) ?? "."
                let searchRoot = try Self.validatedURL(searchPath, workspaceRoot: workspaceRoot)
                let canonicalPrefix = Self.relativePath(searchRoot, root: workspaceRoot)
                if Self.normalizedAction(call.command) == "search_files" {
                    output = try searchFileSummary(
                        query: query,
                        fileExtensions: extensions,
                        searchRoot: searchRoot,
                        canonicalPrefix: canonicalPrefix
                    )
                } else {
                    let searchConnector = LocalEngineeringConnector(workspaceRoot: searchRoot)
                    output = try await searchSummary(
                        searchConnector.searchCode(query, fileExtensions: extensions),
                        canonicalPrefix: canonicalPrefix
                    )
                }
            case "inspect_project":
                output = try inspectProject(call: call, workspaceRoot: workspaceRoot)
            case "write_patch":
                output = try await writePatch(call: call, connector: connector)
            case "edit_file", "write_file", "create_file":
                output = try await editFile(call: call, connector: connector)
            case "run_safe_command":
                return try await runSafeCommand(call: call, workspaceRoot: workspaceRoot, startedAt: startedAt)
            case "report_validation":
                output = reportValidation(call: call)
            default:
                throw ToolExecutionError.unsupportedTool(call.type)
            }

            return ToolExecutionResult(
                callID: call.id,
                exitCode: 0,
                standardOutput: output,
                standardError: "",
                duration: Date().timeIntervalSince(startedAt)
            )
        } catch {
            return ToolExecutionResult(
                callID: call.id,
                exitCode: 1,
                standardOutput: "",
                standardError: error.localizedDescription,
                duration: Date().timeIntervalSince(startedAt)
            )
        }
    }

    private static func isWorkspaceEngineeringCommand(_ command: String) -> Bool {
        command.hasPrefix("engineering.") || command.hasPrefix("workspace.")
    }

    private static func normalizedAction(_ command: String) -> String {
        command
            .replacingOccurrences(of: "engineering.", with: "")
            .replacingOccurrences(of: "workspace.", with: "")
    }

    private func listDirectory(call: ToolCall, workspaceRoot: URL) throws -> String {
        let path = Self.argumentValue(["path", "directory", "dir"], in: call.arguments) ?? "."
        let url = try Self.validatedURL(path, workspaceRoot: workspaceRoot)
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let lines = children
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(120)
            .map { child -> String in
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let suffix = values?.isDirectory == true ? "/" : ""
                let size = values?.isDirectory == true ? "" : " \(values?.fileSize ?? 0)b"
                return "\(child.lastPathComponent)\(suffix)\(size)"
            }
        return lines.isEmpty ? "Directory is empty: \(path)" : lines.joined(separator: "\n")
    }

    private func searchSummary(
        _ result: EngineeringSearchResult,
        canonicalPrefix: String
    ) -> String {
        let matches = result.matches.prefix(80).map { match in
            "\(Self.joinRelativePath(canonicalPrefix, match.path)):\(match.line): \(match.preview)"
        }
        if matches.isEmpty {
            return "No matches for \(result.query)."
        }
        return matches.joined(separator: "\n")
    }

    private func searchFileSummary(
        query: String,
        fileExtensions: [String],
        searchRoot: URL,
        canonicalPrefix: String
    ) throws -> String {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedExtensions = Set(fileExtensions.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        })
        let model = try CodebaseIntelligence(maxFiles: 2_000).discover(rootPath: searchRoot.path)
        let paths = model.files.compactMap { file -> String? in
            let path = file.path
            let matchesQuery = normalizedQuery.isEmpty || path.lowercased().contains(normalizedQuery)
            let matchesExtension = normalizedExtensions.isEmpty
                || file.fileExtension.map { normalizedExtensions.contains($0.lowercased()) } == true
            guard matchesQuery, matchesExtension else { return nil }
            return Self.joinRelativePath(canonicalPrefix, path)
        }
        guard !paths.isEmpty else {
            return "No matches for \(query)."
        }
        return paths.prefix(80).map { "\($0):0: file path match" }.joined(separator: "\n")
    }

    private static func joinRelativePath(_ prefix: String, _ path: String) -> String {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard prefix != ".", !prefix.isEmpty else { return cleanPath }
        return "\(prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/\(cleanPath)"
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let canonicalURL = secureCanonicalURL(url)
        let canonicalRoot = secureCanonicalURL(root)
        guard canonicalURL.path != canonicalRoot.path else { return "." }
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : "\(canonicalRoot.path)/"
        return canonicalURL.path.hasPrefix(prefix)
            ? String(canonicalURL.path.dropFirst(prefix.count))
            : "."
    }

    private func inspectProject(call: ToolCall, workspaceRoot: URL) throws -> String {
        let path = Self.argumentValue(["path", "directory", "dir"], in: call.arguments) ?? "."
        let inspectionRoot = try Self.validatedURL(path, workspaceRoot: workspaceRoot)
        let model = try CodebaseIntelligence(maxFiles: 2_000).discover(rootPath: inspectionRoot.path)
        let sourceExtensions: Set<String> = [
            "swift", "m", "mm", "h", "c", "cc", "cpp", "cs", "java", "kt", "kts",
            "go", "rs", "py", "rb", "php", "ts", "tsx", "js", "jsx", "vue", "svelte"
        ]
        let sourceFileCount = model.files.filter { file in
            guard file.path != "Package.swift", let extensionName = file.fileExtension else { return false }
            return sourceExtensions.contains(extensionName.lowercased())
        }.count
        let topFiles = model.files.prefix(20).map(\.path).joined(separator: "\n")
        let topDirectories = model.directories.prefix(20).joined(separator: "\n")
        let symbols = model.symbols.prefix(20).map { "\($0.kind.rawValue) \($0.name) \($0.path):\($0.line)" }
            .joined(separator: "\n")
        return """
        Repository: \(model.repositoryName)
        Kind: \(model.repositoryKind.rawValue)
        Files: \(model.files.count)
        Source files: \(sourceFileCount)
        Directories: \(model.directories.count)
        Symbols: \(model.symbols.count)
        Dependencies: \(model.dependencies.count)

        Top files:
        \(topFiles)

        Top directories:
        \(topDirectories)

        Symbols:
        \(symbols)
        """
    }

    private func writePatch(call: ToolCall, connector: LocalEngineeringConnector) async throws -> String {
        let path = Self.argumentValue(["path", "file"], in: call.arguments)
            ?? ".fde/patches/\(UUID().uuidString).patch"
        let lowercasedPath = path.lowercased()
        guard lowercasedPath.hasSuffix(".patch") || lowercasedPath.hasSuffix(".diff") else {
            throw ToolExecutionError.commandNotAllowed("engineering.write_patch requires a .patch or .diff target")
        }
        let patch = Self.argumentValue(["patch", "content", "contents", "new_contents"], in: call.arguments)
            ?? Self.positionalArguments(in: call.arguments).joined(separator: "\n")
        guard !patch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError.commandNotAllowed("engineering.write_patch requires non-empty patch content")
        }
        let result = try await connector.editFile(
            EngineeringPlannedEdit(
                path: path,
                newContents: patch,
                summary: "Wrote patch artifact through workspace-scoped engineering tool."
            )
        )
        return "diff_nonempty=true; created_artifact=\(path); \(result.output)"
    }

    private func editFile(call: ToolCall, connector: LocalEngineeringConnector) async throws -> String {
        guard let path = Self.argumentValue(["path", "file"], in: call.arguments),
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolExecutionError.commandNotAllowed("engineering.edit_file requires a workspace-relative path")
        }
        guard let contents = Self.argumentValue(
            ["content", "contents", "new_contents"],
            in: call.arguments
        ), !contents.isEmpty else {
            throw ToolExecutionError.commandNotAllowed("engineering.edit_file requires non-empty new_contents")
        }
        let previousContents = try? await connector.readFile(path).output
        guard previousContents != contents else {
            throw ToolExecutionError.processFailed("engineering.edit_file produced no file diff for \(path)")
        }
        let result = try await connector.editFile(
            EngineeringPlannedEdit(
                path: path,
                newContents: contents,
                summary: "Updated a source file through the workspace-scoped engineering tool."
            )
        )
        return """
        diff_nonempty=true
        target_path=\(path)
        \(Self.boundedDiff(previous: previousContents, current: contents))
        \(result.output)
        """
    }

    private func runSafeCommand(
        call: ToolCall,
        workspaceRoot: URL,
        startedAt: Date
    ) async throws -> ToolExecutionResult {
        let command = Self.argumentValue(["command", "cmd"], in: call.arguments)
            ?? Self.positionalArguments(in: call.arguments).first
            ?? ""
        try shellPolicy.validate(command: command)
        let argumentValues = Self.argumentValue(["arguments", "args"], in: call.arguments)
            .map(Self.shellLikeArguments)
            ?? Array(Self.positionalArguments(in: call.arguments).dropFirst())
        let shellCall = ToolCall(
            id: call.id,
            type: .shell,
            command: command,
            arguments: argumentValues,
            workingDirectory: workspaceRoot.path,
            requiresApproval: call.requiresApproval
        )
        var result = try await LocalToolExecutor(policy: shellPolicy).execute(shellCall)
        result.duration = Date().timeIntervalSince(startedAt)
        return result
    }

    private func reportValidation(call: ToolCall) -> String {
        let status = Self.argumentValue(["status", "result"], in: call.arguments) ?? "reported"
        let summary = Self.argumentValue(["summary", "message"], in: call.arguments)
            ?? Self.positionalArguments(in: call.arguments).joined(separator: " ")
        return "Validation \(status): \(summary)"
    }

    private static func argumentValue(_ keys: Set<String>, in arguments: [String]) -> String? {
        for argument in arguments {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, keys.contains(parts[0].lowercased()) else {
                continue
            }
            return parts[1]
        }
        return nil
    }

    private static func argumentValue(_ keys: [String], in arguments: [String]) -> String? {
        argumentValue(Set(keys), in: arguments)
    }

    private static func positionalArguments(in arguments: [String]) -> [String] {
        arguments.filter { !$0.contains("=") }
    }

    private static func commaSeparatedValues(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func shellLikeArguments(_ value: String) -> [String] {
        value
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func boundedDiff(previous: String?, current: String) -> String {
        guard let previous else {
            return "+ created file (\(current.count) characters)"
        }
        let oldLines = previous.components(separatedBy: .newlines)
        let newLines = current.components(separatedBy: .newlines)
        let count = max(oldLines.count, newLines.count)
        var changes: [String] = []
        for index in 0..<count {
            let old = index < oldLines.count ? oldLines[index] : nil
            let new = index < newLines.count ? newLines[index] : nil
            guard old != new else { continue }
            if let old { changes.append("-\(index + 1): \(old)") }
            if let new { changes.append("+\(index + 1): \(new)") }
            if changes.count >= 12 { break }
        }
        return changes.isEmpty ? "diff recorded" : changes.joined(separator: "\n")
    }

    private static func validatedURL(_ path: String, workspaceRoot: URL) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : workspaceRoot.appendingPathComponent(trimmed)
        let standardized = secureCanonicalURL(candidate)
        let root = secureCanonicalURL(workspaceRoot)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : "\(root.path)/"
        guard standardized.path == root.path || standardized.path.hasPrefix(rootPrefix) else {
            throw EngineeringConnectorError.pathOutsideWorkspace(path)
        }
        return standardized
    }


    private static func secureCanonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
    }
}
