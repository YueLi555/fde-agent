import Foundation

enum CodebaseRepositoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case swiftPackage
    case xcodeProject
    case nodePackage
    case pythonPackage
    case gitRepository
    case generic

    var id: String { rawValue }
}

enum CodebaseLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case swift
    case objectiveC
    case javascript
    case typescript
    case python
    case markdown
    case json
    case yaml
    case shell
    case packageManifest
    case unknown

    var id: String { rawValue }
}

enum CodebaseSymbolKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case `struct`
    case `class`
    case `enum`
    case `protocol`
    case actor
    case function
    case constant
    case variable

    var id: String { rawValue }
}

enum CodebaseDependencyKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case external
    case `internal`
    case packageManifest

    var id: String { rawValue }
}

enum CodebaseOwnershipSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case codeowners
    case inferred

    var id: String { rawValue }
}

struct CodebaseFile: Identifiable, Codable, Hashable, Sendable {
    var id: String { path }
    var path: String
    var name: String
    var fileExtension: String?
    var language: CodebaseLanguage
    var byteCount: Int
    var isTest: Bool
    var modifiedAt: Date?
}

struct CodebaseSymbol: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(path):\(line):\(kind.rawValue):\(name)" }
    var name: String
    var kind: CodebaseSymbolKind
    var path: String
    var line: Int
}

struct CodebaseDependency: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(sourcePath):\(kind.rawValue):\(name)" }
    var sourcePath: String
    var name: String
    var kind: CodebaseDependencyKind
}

struct CodebaseOwnership: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(pathPattern):\(owner)" }
    var pathPattern: String
    var owner: String
    var source: CodebaseOwnershipSource
}

struct CodebaseChangeImpact: Identifiable, Codable, Hashable, Sendable {
    var id: String { changedPath }
    var changedPath: String
    var impactedPaths: [String]
    var impactedSymbols: [String]
    var riskLevel: RiskSeverity
    var reasons: [String]
}

struct CodebaseModel: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var rootPath: String
    var repositoryName: String
    var repositoryKind: CodebaseRepositoryKind
    var discoveredAt: Date
    var files: [CodebaseFile]
    var directories: [String]
    var symbols: [CodebaseSymbol]
    var dependencies: [CodebaseDependency]
    var changeImpacts: [CodebaseChangeImpact]
    var ownership: [CodebaseOwnership]
    var evidence: EvidenceRecord

    static let empty = CodebaseModel(
        id: UUID(),
        rootPath: "",
        repositoryName: "No repository",
        repositoryKind: .generic,
        discoveredAt: Date.distantPast,
        files: [],
        directories: [],
        symbols: [],
        dependencies: [],
        changeImpacts: [],
        ownership: [],
        evidence: EvidenceRecord(
            action: "codebase.discover",
            source: "CodebaseIntelligence",
            result: "No repository scope selected.",
            validation: .warning
        )
    )
}

enum CodebaseIntelligenceError: LocalizedError, Equatable {
    case rootNotFound(String)

    var errorDescription: String? {
        switch self {
        case .rootNotFound(let path):
            return "Codebase root does not exist: \(path)"
        }
    }
}

struct CodebaseIntelligence: Sendable {
    var maxFiles: Int
    var maxFileBytesForAnalysis: Int

    init(maxFiles: Int = 2_000, maxFileBytesForAnalysis: Int = 512_000) {
        self.maxFiles = maxFiles
        self.maxFileBytesForAnalysis = maxFileBytesForAnalysis
    }

    func discover(rootPath: String, changedFiles: [String] = []) throws -> CodebaseModel {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodebaseIntelligenceError.rootNotFound(rootPath)
        }

        let scan = scanFiles(rootURL: rootURL)
        let symbols = discoverSymbols(files: scan.files, rootURL: rootURL)
        let dependencies = discoverDependencies(files: scan.files, rootURL: rootURL)
        let impacts = changeImpacts(
            changedFiles: changedFiles,
            files: scan.files,
            symbols: symbols,
            dependencies: dependencies
        )
        let ownership = ownershipMappings(rootURL: rootURL, files: scan.files)
        let repositoryKind = repositoryKind(rootURL: rootURL)

        return CodebaseModel(
            id: UUID(),
            rootPath: rootURL.path,
            repositoryName: rootURL.lastPathComponent,
            repositoryKind: repositoryKind,
            discoveredAt: Date(),
            files: scan.files,
            directories: scan.directories.sorted(),
            symbols: symbols,
            dependencies: dependencies,
            changeImpacts: impacts,
            ownership: ownership,
            evidence: EvidenceRecord(
                action: "codebase.discover",
                source: "CodebaseIntelligence",
                result: "Discovered \(scan.files.count) files, \(symbols.count) symbols, and \(dependencies.count) dependencies in \(rootURL.lastPathComponent).",
                validation: .valid
            )
        )
    }

    private func scanFiles(rootURL: URL) -> (files: [CodebaseFile], directories: Set<String>) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ([], [])
        }

        var files: [CodebaseFile] = []
        var directories = Set<String>()

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if shouldSkipDirectory(name) {
                    enumerator.skipDescendants()
                    continue
                }
                let path = relativePath(for: url, rootURL: rootURL)
                if !path.isEmpty {
                    directories.insert(path)
                }
                continue
            }

            guard !shouldSkipFile(name), files.count < maxFiles else { continue }
            let path = relativePath(for: url, rootURL: rootURL)
            let fileExtension = url.pathExtension.isEmpty ? nil : url.pathExtension.lowercased()
            let language = language(for: url)
            files.append(
                CodebaseFile(
                    path: path,
                    name: name,
                    fileExtension: fileExtension,
                    language: language,
                    byteCount: values?.fileSize ?? 0,
                    isTest: isTestPath(path),
                    modifiedAt: values?.contentModificationDate
                )
            )
        }

        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (files, directories)
    }

    private func discoverSymbols(files: [CodebaseFile], rootURL: URL) -> [CodebaseSymbol] {
        files.flatMap { file -> [CodebaseSymbol] in
            guard isAnalyzable(file), file.byteCount <= maxFileBytesForAnalysis else { return [] }
            let url = rootURL.appendingPathComponent(file.path)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
            return symbols(in: contents, file: file)
        }
        .sorted {
            if $0.path == $1.path { return $0.line < $1.line }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    private func symbols(in contents: String, file: CodebaseFile) -> [CodebaseSymbol] {
        var result: [CodebaseSymbol] = []
        for (offset, line) in contents.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            switch file.language {
            case .swift:
                result += swiftSymbols(in: line, path: file.path, line: lineNumber)
            case .javascript, .typescript:
                result += scriptSymbols(in: line, path: file.path, line: lineNumber)
            case .python:
                result += pythonSymbols(in: line, path: file.path, line: lineNumber)
            default:
                continue
            }
        }
        return result
    }

    private func swiftSymbols(in line: String, path: String, line lineNumber: Int) -> [CodebaseSymbol] {
        var result: [CodebaseSymbol] = []
        let declarations: [(String, CodebaseSymbolKind)] = [
            ("struct", .struct),
            ("class", .class),
            ("enum", .enum),
            ("protocol", .protocol),
            ("actor", .actor)
        ]
        for declaration in declarations {
            if let name = firstCapture(in: line, pattern: "\\b\(declaration.0)\\s+([A-Za-z_][A-Za-z0-9_]*)") {
                result.append(CodebaseSymbol(name: name, kind: declaration.1, path: path, line: lineNumber))
            }
        }
        if let name = firstCapture(in: line, pattern: "\\bfunc\\s+([A-Za-z_][A-Za-z0-9_]*)") {
            result.append(CodebaseSymbol(name: name, kind: .function, path: path, line: lineNumber))
        }
        return result
    }

    private func scriptSymbols(in line: String, path: String, line lineNumber: Int) -> [CodebaseSymbol] {
        var result: [CodebaseSymbol] = []
        if let name = firstCapture(in: line, pattern: "\\bclass\\s+([A-Za-z_][A-Za-z0-9_]*)") {
            result.append(CodebaseSymbol(name: name, kind: .class, path: path, line: lineNumber))
        }
        if let name = firstCapture(in: line, pattern: "\\bfunction\\s+([A-Za-z_][A-Za-z0-9_]*)") {
            result.append(CodebaseSymbol(name: name, kind: .function, path: path, line: lineNumber))
        }
        if let name = firstCapture(in: line, pattern: "\\b(?:const|let|var)\\s+([A-Za-z_][A-Za-z0-9_]*)\\s*=\\s*(?:async\\s*)?\\(") {
            result.append(CodebaseSymbol(name: name, kind: .function, path: path, line: lineNumber))
        }
        return result
    }

    private func pythonSymbols(in line: String, path: String, line lineNumber: Int) -> [CodebaseSymbol] {
        var result: [CodebaseSymbol] = []
        if let name = firstCapture(in: line, pattern: "^\\s*class\\s+([A-Za-z_][A-Za-z0-9_]*)") {
            result.append(CodebaseSymbol(name: name, kind: .class, path: path, line: lineNumber))
        }
        if let name = firstCapture(in: line, pattern: "^\\s*def\\s+([A-Za-z_][A-Za-z0-9_]*)") {
            result.append(CodebaseSymbol(name: name, kind: .function, path: path, line: lineNumber))
        }
        return result
    }

    private func discoverDependencies(files: [CodebaseFile], rootURL: URL) -> [CodebaseDependency] {
        var dependencies: [CodebaseDependency] = []
        for file in files where isAnalyzable(file) && file.byteCount <= maxFileBytesForAnalysis {
            let url = rootURL.appendingPathComponent(file.path)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            dependencies += sourceDependencies(in: contents, file: file)
            if file.name == "package.json" {
                dependencies += packageJSONDependencies(url: url, sourcePath: file.path)
            }
        }
        return Array(Set(dependencies)).sorted {
            if $0.sourcePath == $1.sourcePath { return $0.name < $1.name }
            return $0.sourcePath.localizedStandardCompare($1.sourcePath) == .orderedAscending
        }
    }

    private func sourceDependencies(in contents: String, file: CodebaseFile) -> [CodebaseDependency] {
        var result: [CodebaseDependency] = []
        for line in contents.components(separatedBy: .newlines) {
            switch file.language {
            case .swift:
                if let name = firstCapture(in: line, pattern: "^\\s*import\\s+([A-Za-z_][A-Za-z0-9_]*)") {
                    result.append(CodebaseDependency(sourcePath: file.path, name: name, kind: .external))
                }
            case .javascript, .typescript:
                if let name = firstCapture(in: line, pattern: "\\bfrom\\s+[\"']([^\"']+)[\"']") {
                    result.append(CodebaseDependency(sourcePath: file.path, name: name, kind: dependencyKind(for: name)))
                } else if let name = firstCapture(in: line, pattern: "\\brequire\\([\"']([^\"']+)[\"']\\)") {
                    result.append(CodebaseDependency(sourcePath: file.path, name: name, kind: dependencyKind(for: name)))
                }
            case .python:
                if let name = firstCapture(in: line, pattern: "^\\s*from\\s+([A-Za-z_][A-Za-z0-9_\\.]*)\\s+import") {
                    result.append(CodebaseDependency(sourcePath: file.path, name: name, kind: dependencyKind(for: name)))
                } else if let name = firstCapture(in: line, pattern: "^\\s*import\\s+([A-Za-z_][A-Za-z0-9_\\.]*)") {
                    result.append(CodebaseDependency(sourcePath: file.path, name: name, kind: dependencyKind(for: name)))
                }
            default:
                continue
            }
        }
        return result
    }

    private func packageJSONDependencies(url: URL, sourcePath: String) -> [CodebaseDependency] {
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        var result: [CodebaseDependency] = []
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            guard let dependencies = object[key] as? [String: Any] else { continue }
            for name in dependencies.keys.sorted() {
                result.append(CodebaseDependency(sourcePath: sourcePath, name: name, kind: .packageManifest))
            }
        }
        return result
    }

    private func changeImpacts(
        changedFiles: [String],
        files: [CodebaseFile],
        symbols: [CodebaseSymbol],
        dependencies: [CodebaseDependency]
    ) -> [CodebaseChangeImpact] {
        changedFiles.map { changedFile in
            let normalized = changedFile.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let impactedSymbols = symbols
                .filter { $0.path == normalized }
                .map(\.name)
                .sorted()
            let sameArea = files
                .filter { topLevelComponent($0.path) == topLevelComponent(normalized) && $0.path != normalized }
                .map(\.path)
            let dependencyUsers = dependencies
                .filter { dependency in
                    dependency.name == normalized
                        || impactedSymbols.contains(dependency.name)
                        || normalized.hasSuffix(dependency.name)
                }
                .map(\.sourcePath)
            let impactedPaths = Array(Set([normalized] + sameArea + dependencyUsers)).sorted()
            let risk = impactRisk(for: normalized)
            return CodebaseChangeImpact(
                changedPath: normalized,
                impactedPaths: impactedPaths,
                impactedSymbols: impactedSymbols,
                riskLevel: risk.level,
                reasons: risk.reasons
            )
        }
    }

    private func ownershipMappings(rootURL: URL, files: [CodebaseFile]) -> [CodebaseOwnership] {
        let codeowners = codeownersMappings(rootURL: rootURL)
        guard codeowners.isEmpty else { return codeowners }

        let inferred = Set(files.map { inferredOwner(for: $0.path) })
        return inferred.sorted { $0.pathPattern < $1.pathPattern }
    }

    private func codeownersMappings(rootURL: URL) -> [CodebaseOwnership] {
        let candidates = [
            rootURL.appendingPathComponent("CODEOWNERS"),
            rootURL.appendingPathComponent(".github/CODEOWNERS"),
            rootURL.appendingPathComponent("docs/CODEOWNERS")
        ]
        guard
            let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        return contents
            .components(separatedBy: .newlines)
            .compactMap { line -> CodebaseOwnership? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
                let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let pattern = parts.first, parts.count > 1 else { return nil }
                return CodebaseOwnership(
                    pathPattern: pattern,
                    owner: parts.dropFirst().joined(separator: " "),
                    source: .codeowners
                )
            }
    }

    private func inferredOwner(for path: String) -> CodebaseOwnership {
        let lowercased = path.lowercased()
        let pattern = topLevelComponent(path) + "/"
        let owner: String
        if lowercased.contains("/runtime/") {
            owner = "runtime"
        } else if lowercased.contains("/policy/") || lowercased.contains("/approval/") {
            owner = "governance"
        } else if lowercased.contains("/ui/") {
            owner = "workspace-ui"
        } else if lowercased.hasPrefix("tests/") {
            owner = "quality"
        } else if lowercased.contains("/engineering/") {
            owner = "engineering"
        } else {
            owner = "codebase"
        }
        return CodebaseOwnership(pathPattern: pattern, owner: owner, source: .inferred)
    }

    private func repositoryKind(rootURL: URL) -> CodebaseRepositoryKind {
        if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("Package.swift").path) {
            return .swiftPackage
        }
        if hasChild(rootURL: rootURL, pathExtension: "xcodeproj") || hasChild(rootURL: rootURL, pathExtension: "xcworkspace") {
            return .xcodeProject
        }
        if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("package.json").path) {
            return .nodePackage
        }
        if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("pyproject.toml").path) {
            return .pythonPackage
        }
        if FileManager.default.fileExists(atPath: rootURL.appendingPathComponent(".git").path) {
            return .gitRepository
        }
        return .generic
    }

    private func hasChild(rootURL: URL, pathExtension targetExtension: String) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
            return false
        }
        return children.contains { $0.pathExtension == targetExtension }
    }

    private func impactRisk(for path: String) -> (level: RiskSeverity, reasons: [String]) {
        let lowercased = path.lowercased()
        var reasons: [String] = []
        if lowercased.contains("production") || lowercased.contains("prod") || lowercased.contains("deploy") {
            reasons.append("Change touches production or deployment surface.")
        }
        if lowercased.contains("migration") || lowercased.contains("schema") || lowercased.contains("package.swift") {
            reasons.append("Change can alter schema, dependencies, or build behavior.")
        }
        if isTestPath(path) {
            reasons.append("Change is limited to test coverage.")
        }
        if reasons.isEmpty {
            reasons.append("Change impact is localized to repository source.")
        }

        if reasons.contains(where: { $0.contains("production") }) {
            return (.high, reasons)
        }
        if reasons.contains(where: { $0.contains("schema") || $0.contains("dependencies") || $0.contains("build") }) {
            return (.medium, reasons)
        }
        if isTestPath(path) {
            return (.low, reasons)
        }
        return (.medium, reasons)
    }

    private func language(for url: URL) -> CodebaseLanguage {
        let name = url.lastPathComponent.lowercased()
        let fileExtension = url.pathExtension.lowercased()
        if name == "package.swift" || name == "package.json" || name == "pyproject.toml" {
            return .packageManifest
        }
        switch fileExtension {
        case "swift": return .swift
        case "m", "mm", "h": return .objectiveC
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "py": return .python
        case "md", "markdown": return .markdown
        case "json": return .json
        case "yml", "yaml": return .yaml
        case "sh", "zsh", "bash": return .shell
        default: return .unknown
        }
    }

    private func isAnalyzable(_ file: CodebaseFile) -> Bool {
        switch file.language {
        case .swift, .javascript, .typescript, .python, .json, .packageManifest:
            return true
        default:
            return false
        }
    }

    private func dependencyKind(for name: String) -> CodebaseDependencyKind {
        name.hasPrefix(".") || name.hasPrefix("/") ? .internal : .external
    }

    private func shouldSkipDirectory(_ name: String) -> Bool {
        [
            ".git",
            ".build",
            ".swiftpm",
            ".tmp",
            ".next",
            ".turbo",
            ".idea",
            ".vscode",
            "DerivedData",
            "node_modules",
            "build",
            "dist",
            "target",
            "Pods",
            "Carthage",
            "__pycache__",
            ".pytest_cache"
        ].contains(name)
    }

    private func shouldSkipFile(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasSuffix(".xcuserstate")
    }

    private func isTestPath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.hasPrefix("tests/")
            || lowercased.contains("/tests/")
            || lowercased.contains("test")
            || lowercased.contains("spec")
    }

    private func topLevelComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? path
    }

    private func relativePath(for url: URL, rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        var relative = String(path.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }

    private func firstCapture(in line: String, pattern: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard
            let match = expression.firstMatch(in: line, range: range),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return String(line[captureRange])
    }
}
