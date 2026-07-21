import Foundation

enum ReadOnlyRequirementStatus: String, Codable, Hashable, Sendable {
    case satisfied
    case partiallySatisfied = "partially_satisfied"
    case unsatisfied
}

enum ReadOnlyEvidenceConfidence: String, Codable, Hashable, Sendable {
    case confirmed
    case inferred
    case unknown
}

enum ReadOnlyEngineeringClaimLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case discovered
    case existsConfirmed = "exists_confirmed"
    case contentRead = "content_read"
    case configurationConfirmed = "configuration_confirmed"
    case sourceBehaviorConfirmed = "source_behavior_confirmed"
    case referencedButNotRead = "referenced_but_not_read"
    case buildConfigPresent = "build_config_present"
    case buildNotExecuted = "build_not_executed"
    case buildPassed = "build_passed"
    case testNotExecuted = "test_not_executed"
    case testPassed = "test_passed"
    case runtimeNotVerified = "runtime_not_verified"
    case runtimeVerified = "runtime_verified"
    case deploymentNotVerified = "deployment_not_verified"
    case deploymentVerified = "deployment_verified"

    var requiresExecutionOrExternalVerification: Bool {
        switch self {
        case .buildPassed, .testPassed, .runtimeVerified, .deploymentVerified:
            return true
        default:
            return false
        }
    }
}

enum ReadOnlyDirectoryEntryType: String, Codable, Hashable, Sendable {
    case file
    case directory
}

struct ReadOnlyDirectoryEntryFact: Codable, Hashable, Sendable {
    var requestedParentRelativePath: String
    var canonicalChildRelativePath: String
    var entryType: ReadOnlyDirectoryEntryType
}

enum ReadOnlyResponseLanguage: String, Codable, Hashable, Sendable {
    case chinese = "zh"
    case english = "en"

    init(request: String) {
        self = request.unicodeScalars.contains(where: { scalar in
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }) ? .chinese : .english
    }

    func matches(_ answer: String) -> Bool {
        switch self {
        case .chinese:
            return ReadOnlyResponseLanguage(request: answer) == .chinese
        case .english:
            // Canonical identifiers and paths are language-neutral. Reject only
            // prose that is clearly Chinese rather than an isolated character.
            let chineseCount = answer.unicodeScalars.filter { scalar in
                (0x3400...0x4DBF).contains(scalar.value)
                    || (0x4E00...0x9FFF).contains(scalar.value)
                    || (0xF900...0xFAFF).contains(scalar.value)
            }.count
            return chineseCount < 8
        }
    }
}

struct ReadOnlyExtractedFacts: Codable, Hashable, Sendable {
    var manifestName: String?
    var manifestTypes: [String]
    var scriptKeys: [String]
    var dependencyNames: [String]
    var devDependencyNames: [String]
    var moduleType: String?
    var frontendFrameworks: [String]
    var backendFrameworks: [String]
    var ormNames: [String]
    var databaseProviders: [String]
    var generatorProviders: [String]
    var modelNames: [String]
    var enumNames: [String]
    var importedPackages: [String]
    var registeredPlugins: [String]
    /// Programming languages only. Configuration/data formats and schema
    /// languages are intentionally tracked separately.
    var languages: [String]
    var configurationFormats: [String]
    var schemaLanguages: [String]
    var structureEntries: [String]
    var discoveredPaths: [String]
    var manifestDerivedPaths: [String]
    var referencedSourcePaths: [String]
    var directoryEntries: [ReadOnlyDirectoryEntryFact]
    var serverBootstrap: Bool
    var buildConfigurationPresent: Bool
    var testConfigurationPresent: Bool
    var contentRead: Bool

    init(
        manifestName: String? = nil,
        manifestTypes: [String] = [],
        scriptKeys: [String] = [],
        dependencyNames: [String] = [],
        devDependencyNames: [String] = [],
        moduleType: String? = nil,
        frontendFrameworks: [String] = [],
        backendFrameworks: [String] = [],
        ormNames: [String] = [],
        databaseProviders: [String] = [],
        generatorProviders: [String] = [],
        modelNames: [String] = [],
        enumNames: [String] = [],
        importedPackages: [String] = [],
        registeredPlugins: [String] = [],
        languages: [String] = [],
        configurationFormats: [String] = [],
        schemaLanguages: [String] = [],
        structureEntries: [String] = [],
        discoveredPaths: [String] = [],
        manifestDerivedPaths: [String] = [],
        referencedSourcePaths: [String] = [],
        directoryEntries: [ReadOnlyDirectoryEntryFact] = [],
        serverBootstrap: Bool = false,
        buildConfigurationPresent: Bool = false,
        testConfigurationPresent: Bool = false,
        contentRead: Bool = false
    ) {
        self.manifestName = manifestName
        self.manifestTypes = manifestTypes
        self.scriptKeys = scriptKeys
        self.dependencyNames = dependencyNames
        self.devDependencyNames = devDependencyNames
        self.moduleType = moduleType
        self.frontendFrameworks = frontendFrameworks
        self.backendFrameworks = backendFrameworks
        self.ormNames = ormNames
        self.databaseProviders = databaseProviders
        self.generatorProviders = generatorProviders
        self.modelNames = modelNames
        self.enumNames = enumNames
        self.importedPackages = importedPackages
        self.registeredPlugins = registeredPlugins
        self.languages = languages
        self.configurationFormats = configurationFormats
        self.schemaLanguages = schemaLanguages
        self.structureEntries = structureEntries
        self.discoveredPaths = discoveredPaths
        self.manifestDerivedPaths = manifestDerivedPaths
        self.referencedSourcePaths = referencedSourcePaths
        self.directoryEntries = directoryEntries
        self.serverBootstrap = serverBootstrap
        self.buildConfigurationPresent = buildConfigurationPresent
        self.testConfigurationPresent = testConfigurationPresent
        self.contentRead = contentRead
    }

    var dependencyFacts: [String] {
        Self.unique(dependencyNames + devDependencyNames)
    }

    var factKinds: [String] {
        var kinds: [String] = []
        if manifestName != nil { kinds.append("manifest_name") }
        if !manifestTypes.isEmpty { kinds.append("manifest_type") }
        if !scriptKeys.isEmpty { kinds.append("script_keys") }
        if !dependencyNames.isEmpty { kinds.append("dependency_names") }
        if !devDependencyNames.isEmpty { kinds.append("dev_dependency_names") }
        if moduleType != nil { kinds.append("module_type") }
        if !frontendFrameworks.isEmpty { kinds.append("frontend_frameworks") }
        if !backendFrameworks.isEmpty { kinds.append("backend_frameworks") }
        if !ormNames.isEmpty { kinds.append("orm_names") }
        if !databaseProviders.isEmpty { kinds.append("database_providers") }
        if !generatorProviders.isEmpty { kinds.append("generator_providers") }
        if !modelNames.isEmpty { kinds.append("model_names") }
        if !enumNames.isEmpty { kinds.append("enum_names") }
        if !importedPackages.isEmpty { kinds.append("imported_packages") }
        if !registeredPlugins.isEmpty { kinds.append("registered_plugins") }
        if !languages.isEmpty { kinds.append("programming_languages") }
        if !configurationFormats.isEmpty { kinds.append("configuration_formats") }
        if !schemaLanguages.isEmpty { kinds.append("schema_languages") }
        if !structureEntries.isEmpty { kinds.append("project_structure") }
        if !discoveredPaths.isEmpty { kinds.append("discovered_paths") }
        if !manifestDerivedPaths.isEmpty { kinds.append("manifest_derived_paths") }
        if !referencedSourcePaths.isEmpty { kinds.append("referenced_source_paths") }
        if !directoryEntries.isEmpty { kinds.append("directory_entry_provenance") }
        if serverBootstrap { kinds.append("server_bootstrap") }
        if buildConfigurationPresent { kinds.append("build_configuration_present") }
        if testConfigurationPresent { kinds.append("test_configuration_present") }
        if contentRead { kinds.append("content_read") }
        return kinds
    }

    var safeSummaries: [String] {
        var facts: [String] = []
        if let manifestName { facts.append("manifest.name=\(manifestName)") }
        if !manifestTypes.isEmpty { facts.append("manifest.types=\(manifestTypes.joined(separator: ", "))") }
        if !scriptKeys.isEmpty { facts.append("scripts=\(scriptKeys.joined(separator: ", "))") }
        if !dependencyNames.isEmpty { facts.append("dependencies=\(dependencyNames.joined(separator: ", "))") }
        if !devDependencyNames.isEmpty { facts.append("devDependencies=\(devDependencyNames.joined(separator: ", "))") }
        if let moduleType { facts.append("module.type=\(moduleType)") }
        if !frontendFrameworks.isEmpty { facts.append("frontend.frameworks=\(frontendFrameworks.joined(separator: ", "))") }
        if !backendFrameworks.isEmpty { facts.append("backend.frameworks=\(backendFrameworks.joined(separator: ", "))") }
        if !ormNames.isEmpty { facts.append("orm=\(ormNames.joined(separator: ", "))") }
        if !databaseProviders.isEmpty { facts.append("database.providers=\(databaseProviders.joined(separator: ", "))") }
        if !generatorProviders.isEmpty { facts.append("generators=\(generatorProviders.joined(separator: ", "))") }
        if !modelNames.isEmpty { facts.append("models=\(modelNames.joined(separator: ", "))") }
        if !enumNames.isEmpty { facts.append("enums=\(enumNames.joined(separator: ", "))") }
        if !importedPackages.isEmpty { facts.append("imports=\(importedPackages.joined(separator: ", "))") }
        if !registeredPlugins.isEmpty { facts.append("plugins=\(registeredPlugins.joined(separator: ", "))") }
        if !languages.isEmpty { facts.append("programming.languages=\(languages.joined(separator: ", "))") }
        if !configurationFormats.isEmpty { facts.append("configuration.formats=\(configurationFormats.joined(separator: ", "))") }
        if !schemaLanguages.isEmpty { facts.append("schema.languages=\(schemaLanguages.joined(separator: ", "))") }
        if !structureEntries.isEmpty { facts.append("structure=\(structureEntries.prefix(24).joined(separator: ", "))") }
        if !discoveredPaths.isEmpty { facts.append("discovered=\(discoveredPaths.prefix(24).joined(separator: ", "))") }
        if !manifestDerivedPaths.isEmpty { facts.append("manifest.derived.paths=\(manifestDerivedPaths.prefix(12).joined(separator: ", "))") }
        if !referencedSourcePaths.isEmpty { facts.append("source.references=\(referencedSourcePaths.prefix(12).joined(separator: ", "))") }
        if serverBootstrap { facts.append("server.bootstrap=confirmed") }
        if buildConfigurationPresent { facts.append("build.configuration=present") }
        if testConfigurationPresent { facts.append("test.configuration=present") }
        return facts
    }

    var eventPayload: [String: String] {
        [
            "extracted_fact_kinds": factKinds.joined(separator: " | "),
            "extracted_safe_facts": safeSummaries.joined(separator: " | "),
            "manifest_name": manifestName ?? "",
            "manifest_types": manifestTypes.joined(separator: " | "),
            "script_keys": scriptKeys.joined(separator: " | "),
            "dependency_names": dependencyNames.joined(separator: " | "),
            "dev_dependency_names": devDependencyNames.joined(separator: " | "),
            "module_type": moduleType ?? "",
            "frontend_frameworks": frontendFrameworks.joined(separator: " | "),
            "backend_frameworks": backendFrameworks.joined(separator: " | "),
            "orm_names": ormNames.joined(separator: " | "),
            "database_providers": databaseProviders.joined(separator: " | "),
            "generator_providers": generatorProviders.joined(separator: " | "),
            "model_names": modelNames.joined(separator: " | "),
            "enum_names": enumNames.joined(separator: " | "),
            "imported_packages": importedPackages.joined(separator: " | "),
            "registered_plugins": registeredPlugins.joined(separator: " | "),
            "detected_languages": languages.joined(separator: " | "),
            "programming_languages": languages.joined(separator: " | "),
            "configuration_formats": configurationFormats.joined(separator: " | "),
            "schema_languages": schemaLanguages.joined(separator: " | "),
            "structure_entries": structureEntries.prefix(40).joined(separator: " | "),
            "discovered_paths": discoveredPaths.prefix(40).joined(separator: " | "),
            "manifest_derived_paths": manifestDerivedPaths.prefix(40).joined(separator: " | "),
            "referenced_source_paths": referencedSourcePaths.prefix(40).joined(separator: " | "),
            "directory_entries_json": Self.json(directoryEntries),
            "server_bootstrap": serverBootstrap ? "true" : "false",
            "build_configuration_present": buildConfigurationPresent ? "true" : "false",
            "test_configuration_present": testConfigurationPresent ? "true" : "false",
            "content_read": contentRead ? "true" : "false"
        ]
    }

    init(eventPayload: [String: String]) {
        func values(_ key: String) -> [String] {
            (eventPayload[key] ?? "")
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let manifestName = eventPayload["manifest_name"].flatMap { $0.isEmpty ? nil : $0 }
        let moduleType = eventPayload["module_type"].flatMap { $0.isEmpty ? nil : $0 }
        let directoryEntries: [ReadOnlyDirectoryEntryFact]
        if let json = eventPayload["directory_entries_json"],
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([ReadOnlyDirectoryEntryFact].self, from: data) {
            directoryEntries = decoded
        } else {
            directoryEntries = []
        }
        self.init(
            manifestName: manifestName,
            manifestTypes: values("manifest_types"),
            scriptKeys: values("script_keys"),
            dependencyNames: values("dependency_names"),
            devDependencyNames: values("dev_dependency_names"),
            moduleType: moduleType,
            frontendFrameworks: values("frontend_frameworks"),
            backendFrameworks: values("backend_frameworks"),
            ormNames: values("orm_names"),
            databaseProviders: values("database_providers"),
            generatorProviders: values("generator_providers"),
            modelNames: values("model_names"),
            enumNames: values("enum_names"),
            importedPackages: values("imported_packages"),
            registeredPlugins: values("registered_plugins"),
            languages: values("programming_languages").isEmpty
                ? values("detected_languages").filter { $0 != "JSON" && !$0.lowercased().contains("prisma") }
                : values("programming_languages"),
            configurationFormats: values("configuration_formats"),
            schemaLanguages: values("schema_languages"),
            structureEntries: values("structure_entries"),
            discoveredPaths: values("discovered_paths"),
            manifestDerivedPaths: values("manifest_derived_paths"),
            referencedSourcePaths: values("referenced_source_paths"),
            directoryEntries: directoryEntries,
            serverBootstrap: eventPayload["server_bootstrap"] == "true",
            buildConfigurationPresent: eventPayload["build_configuration_present"] == "true",
            testConfigurationPresent: eventPayload["test_configuration_present"] == "true",
            contentRead: eventPayload["content_read"] == "true"
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }.sorted()
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

enum ReadOnlySafeFactExtractor {
    private static let manifestNames: Set<String> = [
        "package.json", "package.swift", "pyproject.toml", "requirements.txt", "pom.xml",
        "build.gradle", "build.gradle.kts", "cargo.toml", "gemfile", "composer.json", "go.mod"
    ]

    static func extract(toolName: String, targetPath: String, output: String) -> ReadOnlyExtractedFacts {
        var facts = ReadOnlyExtractedFacts()
        let normalizedPath = targetPath.lowercased()
        let fileName = URL(fileURLWithPath: normalizedPath).lastPathComponent
        let lines = output.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        switch toolName {
        case "engineering.inspect_project":
            facts.structureEntries = inspectionStructure(lines, parentPath: targetPath)
            facts.discoveredPaths = facts.structureEntries
            classify(paths: facts.structureEntries, into: &facts)
        case "engineering.list_directory":
            facts.directoryEntries = directoryEntries(parentPath: targetPath, lines: lines)
            facts.structureEntries = facts.directoryEntries.map(\.canonicalChildRelativePath)
            facts.discoveredPaths = facts.structureEntries
            classify(paths: facts.structureEntries, into: &facts)
        case "engineering.search_files", "engineering.search_code":
            facts.discoveredPaths = discoveredPaths(lines)
        case "engineering.read_file":
            facts.contentRead = true
            classify(paths: [targetPath], into: &facts)
            if manifestNames.contains(fileName) || normalizedPath.hasSuffix(".csproj") || normalizedPath.hasSuffix(".podspec") {
                facts.manifestTypes = [manifestType(fileName: fileName, path: normalizedPath)]
            }
            if fileName == "package.json", let data = output.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                extractPackageJSON(object, path: normalizedPath, into: &facts)
                facts.manifestDerivedPaths = manifestDerivedPaths(object, manifestPath: targetPath)
                facts.discoveredPaths.append(contentsOf: facts.manifestDerivedPaths)
            } else if fileName == "package.swift" {
                facts.manifestTypes = ["Swift Package"]
                facts.importedPackages = output.contains("import PackageDescription") ? ["PackageDescription"] : []
                facts.dependencyNames = swiftPackageDependencies(output)
            } else if fileName == "schema.prisma" {
                extractPrisma(output, into: &facts)
            }
            extractImportsAndBootstrap(output, path: targetPath, into: &facts)
        default:
            break
        }

        let configurationCandidates = [targetPath]
            + facts.structureEntries
            + facts.discoveredPaths
            + facts.manifestDerivedPaths
        if configurationCandidates.contains(where: isBuildConfigurationPath) {
            facts.buildConfigurationPresent = true
        }
        if configurationCandidates.contains(where: isTestConfigurationPath) {
            facts.testConfigurationPresent = true
        }

        normalize(&facts)
        return facts
    }

    private static func extractPackageJSON(
        _ object: [String: Any],
        path: String,
        into facts: inout ReadOnlyExtractedFacts
    ) {
        facts.manifestName = (object["name"] as? String).flatMap(safeIdentifier)
        facts.moduleType = (object["type"] as? String).flatMap(safeIdentifier)
        facts.scriptKeys = safeKeys(object["scripts"])
        facts.buildConfigurationPresent = facts.scriptKeys.contains { ["build", "compile", "bundle"].contains($0.lowercased()) }
        facts.testConfigurationPresent = facts.scriptKeys.contains { $0.lowercased().hasPrefix("test") }
        facts.dependencyNames = safeKeys(object["dependencies"])
        facts.devDependencyNames = safeKeys(object["devDependencies"])
        let all = facts.dependencyNames + facts.devDependencyNames
        let backend = isBackendPath(path)
        for dependency in all {
            if let framework = frontendFramework(for: dependency), !backend {
                facts.frontendFrameworks.append(framework)
            }
            if let framework = backendFramework(for: dependency), backend {
                facts.backendFrameworks.append(framework)
            }
            if let orm = orm(for: dependency) {
                facts.ormNames.append(orm)
            }
        }
    }

    private static func extractPrisma(_ output: String, into facts: inout ReadOnlyExtractedFacts) {
        var block: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("datasource ") && line.contains("{") {
                block = "datasource"
            } else if line.hasPrefix("generator ") && line.contains("{") {
                block = "generator"
            } else if line == "}" {
                block = nil
            } else if line.hasPrefix("model ") {
                facts.modelNames.append(String(line.dropFirst("model ".count).split(separator: " ").first ?? ""))
            } else if line.hasPrefix("enum ") {
                facts.enumNames.append(String(line.dropFirst("enum ".count).split(separator: " ").first ?? ""))
            } else if line.hasPrefix("provider"), let value = quotedValue(line) {
                if block == "datasource" {
                    facts.databaseProviders.append(displayDatabaseProvider(value))
                } else if block == "generator" {
                    facts.generatorProviders.append(value)
                }
            }
        }
        if output.lowercased().contains("prisma-client") {
            facts.ormNames.append("Prisma")
        }
    }

    private static func extractImportsAndBootstrap(
        _ output: String,
        path: String,
        into facts: inout ReadOnlyExtractedFacts
    ) {
        let patterns = [#"from\s+['\"]([^'\"]+)['\"]"#, #"require\(\s*['\"]([^'\"]+)['\"]\s*\)"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            for match in regex.matches(in: output, range: range) {
                guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: output),
                      let identifier = safeIdentifier(String(output[valueRange])) else { continue }
                facts.importedPackages.append(identifier)
                if let referencedPath = sourceReferencePath(importValue: identifier, importerPath: path) {
                    facts.referencedSourcePaths.append(referencedPath)
                }
                if let framework = frontendFramework(for: identifier), !isBackendPath(path) {
                    facts.frontendFrameworks.append(framework)
                }
                if let framework = backendFramework(for: identifier), isBackendPath(path) {
                    facts.backendFrameworks.append(framework)
                }
                if let orm = orm(for: identifier) { facts.ormNames.append(orm) }
                if identifier.hasPrefix("@fastify/") || identifier.hasPrefix("@nestjs/") {
                    facts.registeredPlugins.append(identifier)
                }
            }
        }
        let normalized = output.lowercased()
        if isBackendPath(path), normalized.contains(".listen(") || normalized.contains(".listen (") {
            facts.serverBootstrap = true
        }
    }

    private static func inspectionStructure(_ lines: [String], parentPath: String) -> [String] {
        enum Section { case none, files, directories }
        var section = Section.none
        var values: [String] = []
        for line in lines {
            if line == "Top files:" {
                section = .files
                continue
            }
            if line == "Top directories:" {
                section = .directories
                continue
            }
            if line == "Symbols:" {
                section = .none
                continue
            }
            if section != .none, !line.contains(": "),
               let path = canonicalChildPath(parentPath: parentPath, rawChild: line, isDirectory: section == .directories) {
                values.append(path)
            }
        }
        if values.isEmpty {
            let metadataPrefixes = ["Repository:", "Kind:", "Files:", "Source files:", "Directories:", "Symbols:", "Dependencies:"]
            values = lines.compactMap { line in
                !metadataPrefixes.contains(where: { line.hasPrefix($0) })
                    && line != "Top files:"
                    && line != "Top directories:"
                    ? canonicalChildPath(parentPath: parentPath, rawChild: line, isDirectory: line.hasSuffix("/"))
                    : nil
            }
        }
        return Array(values.prefix(80))
    }

    private static func directoryEntries(parentPath: String, lines: [String]) -> [ReadOnlyDirectoryEntryFact] {
        let parent = canonicalParentPath(parentPath)
        guard parent != nil else { return [] }
        return lines.prefix(120).compactMap { rawLine in
            guard !rawLine.hasPrefix("Directory is empty:") else { return nil }
            var child = rawLine
            if let range = child.range(of: #"\s+\d+b$"#, options: .regularExpression) {
                child.removeSubrange(range)
            }
            let isDirectory = child.hasSuffix("/")
            guard let canonical = canonicalChildPath(
                parentPath: parentPath,
                rawChild: child,
                isDirectory: isDirectory
            ) else { return nil }
            return ReadOnlyDirectoryEntryFact(
                requestedParentRelativePath: parent!,
                canonicalChildRelativePath: canonical,
                entryType: isDirectory ? .directory : .file
            )
        }
    }

    private static func discoveredPaths(_ lines: [String]) -> [String] {
        lines.compactMap { line in
            guard !line.hasPrefix("No matches") else { return nil }
            let components = line.split(separator: ":", maxSplits: 2).map(String.init)
            guard let first = components.first else { return nil }
            return safeRelativePath(first)
        }
    }

    private static func safeRelativePath(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            return nil
        }
        let components = trimmed.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    private static func canonicalParentPath(_ value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("./") { trimmed.removeFirst(2) }
        if trimmed == "." || trimmed.isEmpty { return "." }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return safeRelativePath(trimmed)
    }

    private static func canonicalChildPath(
        parentPath: String,
        rawChild: String,
        isDirectory: Bool
    ) -> String? {
        guard let parent = canonicalParentPath(parentPath) else { return nil }
        var child = rawChild.trimmingCharacters(in: .whitespacesAndNewlines)
        while child.hasSuffix("/") { child.removeLast() }
        guard let safeChild = safeRelativePath(child) else { return nil }
        let path = parent == "." ? safeChild : "\(parent)/\(safeChild)"
        return isDirectory ? "\(path)/" : path
    }

    private static func manifestDerivedPaths(_ object: [String: Any], manifestPath: String) -> [String] {
        let base = manifestPath.split(separator: "/").dropLast().joined(separator: "/")
        var candidates: [String] = []
        for key in ["main", "module"] {
            if let value = object[key] as? String,
               let path = manifestRelativeSourcePath(base: base, candidate: value) {
                candidates.append(path)
            }
        }
        if let scripts = object["scripts"] as? [String: Any] {
            for key in ["dev", "start", "serve"] {
                guard let command = scripts[key] as? String else { continue }
                let separators = CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: "'\";&|(),"))
                for token in command.components(separatedBy: separators) {
                    guard let path = manifestRelativeSourcePath(base: base, candidate: token) else { continue }
                    candidates.append(path)
                }
            }
        }
        return unique(candidates)
    }

    private static func manifestRelativeSourcePath(base: String, candidate: String) -> String? {
        let extensions: Set<String> = ["ts", "tsx", "js", "jsx", "mjs", "cjs", "swift", "py", "go", "rs", "java", "kt"]
        var normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        while normalized.hasPrefix("./") { normalized.removeFirst(2) }
        guard extensions.contains(URL(fileURLWithPath: normalized).pathExtension.lowercased()),
              let child = safeRelativePath(normalized) else { return nil }
        return base.isEmpty ? child : "\(base)/\(child)"
    }

    private static func swiftPackageDependencies(_ output: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\.package\([^\n]*?(?:url|name):\s*\"([^\"]+)\""#) else {
            return []
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        return regex.matches(in: output, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let valueRange = Range(match.range(at: 1), in: output) else { return nil }
            let value = String(output[valueRange])
            return URL(string: value)?.deletingPathExtension().lastPathComponent ?? value
        }
    }

    private static func safeKeys(_ value: Any?) -> [String] {
        guard let dictionary = value as? [String: Any] else { return [] }
        return dictionary.keys.compactMap(safeIdentifier).sorted()
    }

    private static func safeIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@/._+-"))
        guard trimmed.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return trimmed
    }

    private static func quotedValue(_ line: String) -> String? {
        guard let first = line.firstIndex(of: "\"") else { return nil }
        let remainder = line[line.index(after: first)...]
        guard let last = remainder.firstIndex(of: "\"") else { return nil }
        return safeIdentifier(String(remainder[..<last]))
    }

    private static func manifestType(fileName: String, path: String) -> String {
        switch fileName {
        case "package.json": return "Node package"
        case "package.swift": return "Swift Package"
        case "pyproject.toml", "requirements.txt": return "Python package"
        case "pom.xml", "build.gradle", "build.gradle.kts": return "JVM package"
        case "cargo.toml": return "Rust package"
        case "go.mod": return "Go module"
        default: return URL(fileURLWithPath: path).lastPathComponent
        }
    }

    private static func programmingLanguage(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "ts": return "TypeScript"
        case "tsx": return "TypeScript"
        case "js": return "JavaScript"
        case "jsx": return "JavaScript"
        case "swift": return "Swift"
        case "py": return "Python"
        case "go": return "Go"
        case "rs": return "Rust"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "vue": return "Vue SFC"
        case "svelte": return "Svelte"
        default: return nil
        }
    }

    private static func configurationFormat(for path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "json", "jsonc": return "JSON"
        case "yaml", "yml": return "YAML"
        case "toml": return "TOML"
        case "xml": return "XML"
        default: return nil
        }
    }

    private static func isBuildConfigurationPath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path.lowercased()).lastPathComponent
        return name == "tsconfig.json"
            || name.hasPrefix("tsconfig.")
            || name == "vite.config.ts"
            || name == "vite.config.js"
            || name == "webpack.config.js"
            || name == "webpack.config.ts"
            || name == "package.swift"
            || name == "build.gradle"
            || name == "build.gradle.kts"
            || name == "cargo.toml"
    }

    private static func isTestConfigurationPath(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path.lowercased()).lastPathComponent
        return name.hasPrefix("jest.config")
            || name.hasPrefix("vitest.config")
            || name.hasPrefix("pytest.ini")
            || name == "package.swift"
    }

    private static func sourceReferencePath(importValue: String, importerPath: String) -> String? {
        guard importValue.hasPrefix("."), !importerPath.hasPrefix("/") else { return nil }
        var components = importerPath.split(separator: "/").dropLast().map(String.init)
        for component in importValue.split(separator: "/").map(String.init) {
            switch component {
            case ".", "":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        guard !components.isEmpty else { return nil }
        var candidate = components.joined(separator: "/")
        if URL(fileURLWithPath: candidate).pathExtension.isEmpty {
            let importerExtension = URL(fileURLWithPath: importerPath).pathExtension
            if !importerExtension.isEmpty { candidate += ".\(importerExtension)" }
        }
        return ReadOnlySensitivePathPolicy.isSensitive(candidate) ? nil : candidate
    }

    private static func schemaLanguage(for path: String) -> String? {
        URL(fileURLWithPath: path).pathExtension.lowercased() == "prisma"
            ? "Prisma Schema Language"
            : nil
    }

    private static func classify(paths: [String], into facts: inout ReadOnlyExtractedFacts) {
        facts.languages.append(contentsOf: paths.compactMap(programmingLanguage(for:)))
        facts.configurationFormats.append(contentsOf: paths.compactMap(configurationFormat(for:)))
        facts.schemaLanguages.append(contentsOf: paths.compactMap(schemaLanguage(for:)))
    }

    private static func isBackendPath(_ path: String) -> Bool {
        let backendSegments: Set<String> = ["server", "backend", "api", "service", "services"]
        return path.split(separator: "/").contains { backendSegments.contains(String($0).lowercased()) }
    }

    private static func frontendFramework(for dependency: String) -> String? {
        let normalized = dependency.lowercased()
        if normalized == "react" || normalized == "react-dom" { return "React" }
        if normalized == "vite" || normalized.hasPrefix("@vitejs/") { return "Vite" }
        if normalized == "vue" || normalized.hasPrefix("@vue/") { return "Vue" }
        if normalized == "next" { return "Next.js" }
        if normalized == "svelte" || normalized.hasPrefix("@sveltejs/") { return "Svelte" }
        if normalized == "@angular/core" { return "Angular" }
        return nil
    }

    private static func backendFramework(for dependency: String) -> String? {
        let normalized = dependency.lowercased()
        if normalized == "fastify" || normalized.hasPrefix("@fastify/") { return "Fastify" }
        if normalized == "express" { return "Express" }
        if normalized == "koa" || normalized.hasPrefix("@koa/") { return "Koa" }
        if normalized == "@nestjs/core" || normalized.hasPrefix("@nestjs/") { return "NestJS" }
        if normalized == "hono" { return "Hono" }
        return nil
    }

    private static func orm(for dependency: String) -> String? {
        switch dependency.lowercased() {
        case "prisma", "@prisma/client": return "Prisma"
        case "typeorm": return "TypeORM"
        case "sequelize": return "Sequelize"
        case "drizzle-orm": return "Drizzle ORM"
        default: return nil
        }
    }

    private static func displayDatabaseProvider(_ provider: String) -> String {
        switch provider.lowercased() {
        case "postgresql", "postgres": return "PostgreSQL"
        case "mysql": return "MySQL"
        case "sqlite": return "SQLite"
        case "sqlserver": return "SQL Server"
        case "mongodb": return "MongoDB"
        case "cockroachdb": return "CockroachDB"
        default: return provider
        }
    }

    private static func normalize(_ facts: inout ReadOnlyExtractedFacts) {
        facts.manifestTypes = unique(facts.manifestTypes)
        facts.scriptKeys = unique(facts.scriptKeys)
        facts.dependencyNames = unique(facts.dependencyNames)
        facts.devDependencyNames = unique(facts.devDependencyNames)
        facts.frontendFrameworks = unique(facts.frontendFrameworks)
        facts.backendFrameworks = unique(facts.backendFrameworks)
        facts.ormNames = unique(facts.ormNames)
        facts.databaseProviders = unique(facts.databaseProviders)
        facts.generatorProviders = unique(facts.generatorProviders)
        facts.modelNames = unique(facts.modelNames)
        facts.enumNames = unique(facts.enumNames)
        facts.importedPackages = unique(facts.importedPackages)
        facts.registeredPlugins = unique(facts.registeredPlugins)
        facts.languages = unique(facts.languages)
        facts.configurationFormats = unique(facts.configurationFormats)
        facts.schemaLanguages = unique(facts.schemaLanguages)
        facts.structureEntries = unique(facts.structureEntries)
        facts.discoveredPaths = unique(facts.discoveredPaths)
        facts.manifestDerivedPaths = unique(facts.manifestDerivedPaths)
        facts.referencedSourcePaths = unique(facts.referencedSourcePaths)
        facts.structureEntries.removeAll(where: ReadOnlySensitivePathPolicy.isSensitive)
        facts.discoveredPaths.removeAll(where: ReadOnlySensitivePathPolicy.isSensitive)
        facts.manifestDerivedPaths.removeAll(where: ReadOnlySensitivePathPolicy.isSensitive)
        facts.referencedSourcePaths.removeAll(where: ReadOnlySensitivePathPolicy.isSensitive)
        facts.directoryEntries.removeAll { ReadOnlySensitivePathPolicy.isSensitive($0.canonicalChildRelativePath) }
        var seenEntries: Set<String> = []
        facts.directoryEntries = facts.directoryEntries.filter {
            seenEntries.insert("\($0.requestedParentRelativePath)|\($0.canonicalChildRelativePath)|\($0.entryType.rawValue)").inserted
        }
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }.sorted()
    }
}

struct ReadOnlyRequirementLedgerEntry: Codable, Hashable, Sendable {
    var requirementID: String
    var requestedCategory: String
    var status: ReadOnlyRequirementStatus
    var supportingSuccessfulEventIDs: [UUID]
    var supportingRelativePaths: [String]
    var extractedSafeFacts: [String]
    var confidence: ReadOnlyEvidenceConfidence
    var evidenceLevel: ReadOnlyEngineeringClaimLevel
    var explanationOfWhatRemains: String
}

struct ReadOnlyEvidencePathRecord: Codable, Hashable, Sendable {
    var workspaceIdentity: String
    var relativePath: String
    var requestedParentRelativePath: String?
    var entryType: ReadOnlyDirectoryEntryType?
    var directoryEntrySuccessfulEventIDs: [UUID]
    var discoveredBySuccessfulEventIDs: [UUID]
    var searchedBySuccessfulEventIDs: [UUID]
    var manifestDerivedBySuccessfulEventIDs: [UUID]
    var referencedBySuccessfulEventIDs: [UUID]
    var successfullyReadByEventIDs: [UUID]
    var extractedFactKinds: [String]
    var claimLevels: [ReadOnlyEngineeringClaimLevel]
    var includedInFinalAnswer: Bool
}

struct ReadOnlyFinalizationEvidenceLedger: Codable, Hashable, Sendable {
    var requirements: [ReadOnlyRequirementLedgerEntry]
    var paths: [ReadOnlyEvidencePathRecord]

    init(
        requirements requested: ReadOnlyEvidenceRequirements,
        evidence: [ReadOnlyInspectionEvidence],
        finalAnswer: String? = nil
    ) {
        requirements = requested.required.map { requirement in
            Self.entry(for: requirement, evidence: evidence)
        }
        paths = Self.pathRecords(evidence: evidence, finalAnswer: finalAnswer)
    }

    var satisfied: [ReadOnlyEvidenceRequirementKind] {
        requirements.compactMap { entry in
            guard entry.status == .satisfied else { return nil }
            return ReadOnlyEvidenceRequirementKind(rawValue: entry.requirementID)
        }
    }

    var unsatisfied: [ReadOnlyEvidenceRequirementKind] {
        requirements.compactMap { entry in
            guard entry.status != .satisfied else { return nil }
            return ReadOnlyEvidenceRequirementKind(rawValue: entry.requirementID)
        }
    }

    var successfulReadPaths: [String] {
        paths.filter { !$0.successfullyReadByEventIDs.isEmpty }.map(\.relativePath)
    }

    var discoveredOnlyPaths: [String] {
        paths.filter {
            !$0.discoveredBySuccessfulEventIDs.isEmpty && $0.successfullyReadByEventIDs.isEmpty
        }.map(\.relativePath)
    }

    var allMaterialRequirementsSatisfied: Bool {
        requirements.allSatisfy { $0.status == .satisfied }
    }

    var claimMaturityLevels: [ReadOnlyEngineeringClaimLevel] {
        var levels = paths.flatMap(\.claimLevels)
        if !paths.isEmpty {
            levels.append(contentsOf: [.runtimeNotVerified, .deploymentNotVerified])
        }
        return Self.uniqueClaimLevels(levels)
    }

    var unsupportedExecutionClaimLevels: [ReadOnlyEngineeringClaimLevel] {
        claimMaturityLevels.filter(\.requiresExecutionOrExternalVerification)
    }

    var auditPayload: [String: String] {
        let satisfiedEntries = requirements.filter { $0.status == .satisfied }
        let incompleteEntries = requirements.filter { $0.status != .satisfied }
        return [
            "evidence_requirements": requirements.map(\.requirementID).joined(separator: " | "),
            "satisfied_evidence_requirements": satisfiedEntries.map(\.requirementID).joined(separator: " | "),
            "unsatisfied_evidence_requirements": incompleteEntries.map(\.requirementID).joined(separator: " | "),
            "partially_satisfied_evidence_requirements": requirements.filter { $0.status == .partiallySatisfied }.map(\.requirementID).joined(separator: " | "),
            "evidence_requirements_satisfied_count": String(satisfiedEntries.count),
            "evidence_requirements_unsatisfied_count": String(incompleteEntries.count),
            "successful_inspected_paths": successfulReadPaths.joined(separator: " | "),
            "discovered_only_paths": discoveredOnlyPaths.joined(separator: " | "),
            "requirement_evidence_ledger": Self.json(requirements),
            "evidence_path_ledger": Self.json(paths),
            "claim_maturity_levels": claimMaturityLevels.map(\.rawValue).joined(separator: " | "),
            "unsupported_execution_claim_levels": unsupportedExecutionClaimLevels.map(\.rawValue).joined(separator: " | "),
            "evidence_ledger_consistent": consistencyIssues.isEmpty ? "true" : "false",
            "evidence_ledger_consistency_issues": consistencyIssues.joined(separator: " | ")
        ]
    }

    var consistencyIssues: [String] {
        var issues: [String] = []
        for entry in requirements where entry.status == .satisfied {
            if entry.supportingSuccessfulEventIDs.isEmpty { issues.append("\(entry.requirementID):missing_success_event") }
            if entry.supportingRelativePaths.isEmpty { issues.append("\(entry.requirementID):missing_relative_path") }
            if entry.extractedSafeFacts.isEmpty { issues.append("\(entry.requirementID):missing_extracted_fact") }
        }
        for path in paths where !path.successfullyReadByEventIDs.isEmpty && path.extractedFactKinds.isEmpty {
            issues.append("\(path.relativePath):read_without_fact")
        }
        return issues
    }

    private static func entry(
        for requirement: ReadOnlyEvidenceRequirementKind,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> ReadOnlyRequirementLedgerEntry {
        let manifestDerivedBackendEntries = Set(
            evidence.flatMap(\.structuredFacts.manifestDerivedPaths).filter {
                isBackendPath($0) && isBackendEntry($0)
            }
        )
        let referencedAssemblyPaths = Set(
            evidence.flatMap(\.structuredFacts.referencedSourcePaths).filter(isBackendApplicationAssembly)
        )
        let related = evidence.filter { item in
            isRelated(requirement, item: item)
                || (requirement == .backendEntryPoint
                    && item.toolName == "engineering.read_file"
                    && manifestDerivedBackendEntries.contains(item.targetPath))
                || (requirement == .backendApplicationAssembly
                    && !item.structuredFacts.referencedSourcePaths.filter(isBackendApplicationAssembly).isEmpty)
        }
        let supporting = related.filter { item in
            satisfies(requirement, item: item)
                || (requirement == .backendEntryPoint
                    && manifestDerivedBackendEntries.contains(item.targetPath)
                    && item.structuredFacts.contentRead)
        }
        let status: ReadOnlyRequirementStatus = !supporting.isEmpty
            ? .satisfied
            : (related.isEmpty ? .unsatisfied : .partiallySatisfied)
        let facts = safeFacts(
            for: requirement,
            evidence: status == .satisfied ? supporting : related
        )
        let paths: [String]
        if requirement == .backendApplicationAssembly, status != .satisfied, !referencedAssemblyPaths.isEmpty {
            paths = unique(Array(referencedAssemblyPaths))
        } else {
            paths = unique((status == .satisfied ? supporting : related).map(\.targetPath))
        }
        let eventIDs = uniqueUUIDs((status == .satisfied ? supporting : related).map(\.toolResultEventID))
        let level = evidenceLevel(
            for: requirement,
            status: status,
            evidence: status == .satisfied ? supporting : related
        )
        let explanation: String
        switch status {
        case .satisfied:
            explanation = "Direct successful evidence, a requested extracted fact, and a relative path are recorded."
        case .partiallySatisfied:
            explanation = requirement == .backendApplicationAssembly
                ? "The startup entry references the application assembly, but the assembly file was not successfully read."
                : "Related evidence was recorded, but it did not extract the requested fact."
        case .unsatisfied:
            explanation = "No successful direct evidence with the requested fact is recorded."
        }
        return ReadOnlyRequirementLedgerEntry(
            requirementID: requirement.rawValue,
            requestedCategory: requirement.label,
            status: status,
            supportingSuccessfulEventIDs: eventIDs,
            supportingRelativePaths: paths,
            extractedSafeFacts: facts,
            confidence: status == .satisfied || level == .referencedButNotRead ? .confirmed : .unknown,
            evidenceLevel: level,
            explanationOfWhatRemains: explanation
        )
    }

    private static func isRelated(
        _ requirement: ReadOnlyEvidenceRequirementKind,
        item: ReadOnlyInspectionEvidence
    ) -> Bool {
        let path = item.targetPath.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent
        let facts = item.structuredFacts
        switch requirement {
        case .requestedFile:
            return item.toolName == "engineering.read_file"
        case .projectRoot, .projectStructure:
            return (item.toolName == "engineering.inspect_project" || item.toolName == "engineering.list_directory")
                && item.targetPath == "."
        case .staticSourceEvidence:
            return item.toolName == "engineering.read_file"
        case .primaryLanguages:
            return item.toolName == "engineering.read_file" || item.toolName == "engineering.inspect_project"
        case .projectManifest, .importantDependencies:
            return item.toolName == "engineering.read_file" && isManifest(path)
        case .frontendManifestOrConfig, .frontendConfiguration:
            return item.toolName == "engineering.read_file" && !isBackendPath(path)
                && (isManifest(path) || name.contains("vite.config") || name.contains("webpack")
                    || name.contains("next.config") || !facts.frontendFrameworks.isEmpty)
        case .backendManifest:
            return item.toolName == "engineering.read_file" && isBackendPath(path)
                && (isManifest(path) || !facts.backendFrameworks.isEmpty)
        case .databaseSchemaOrConfig:
            return item.toolName == "engineering.read_file"
                && (name == "schema.prisma" || path.contains("database") || path.contains("migration") || path.contains("schema"))
        case .backendEntryPoint:
            return item.toolName == "engineering.read_file" && isBackendEntry(path)
        case .backendApplicationAssembly:
            return item.toolName == "engineering.read_file" && isBackendApplicationAssembly(path)
        case .inspectedManifestsAndKeyFiles:
            return item.toolName == "engineering.read_file"
        case .assessmentOrderReadBoundary:
            return assessmentEvidence(item, paths: ["order"], queries: ["order", "listcustomerorders"])
        case .assessmentAPIServiceBoundary:
            return assessmentEvidence(item, paths: ["order", "route", "architecture"], queries: ["route", "controller", "endpoint", "service"])
        case .assessmentAuthentication:
            return assessmentEvidence(item, paths: ["auth", "identity", "session"], queries: ["auth", "authenticate", "principal", "session"])
        case .assessmentRecordAuthorization:
            return assessmentEvidence(item, paths: ["auth", "order", "architecture"], queries: ["customerid", "orderid", "authorize", "requirerole"])
        case .assessmentPermissionModel:
            return assessmentEvidence(item, paths: ["auth", "permission", "order"], queries: ["permission", "role", "rbac", "requirerole"])
        case .assessmentAuditLogging:
            return assessmentEvidence(item, paths: ["audit", "architecture", "config"], queries: ["audit", "recordauditevent"])
        case .assessmentMutationPaths:
            return assessmentEvidence(item, paths: ["order", "architecture", "config"], queries: ["post", "put", "patch", "delete", "mutation", "outboundactions"])
        case .assessmentSensitiveResponseFields:
            return assessmentEvidence(item, paths: ["order", "architecture", "config"], queries: ["ordersummary", "customerid", "redact", "allowedfields"])
        case .assessmentArchitectureDocumentation:
            return assessmentEvidence(item, paths: ["docs/architecture", "architecture.md"], queries: ["architecture.md"])
        case .assessmentExampleConfiguration:
            return assessmentEvidence(item, paths: ["config/app.example", "app.example.json"], queries: ["app.example.json"])
        }
    }

    private static func satisfies(
        _ requirement: ReadOnlyEvidenceRequirementKind,
        item: ReadOnlyInspectionEvidence
    ) -> Bool {
        guard isRelated(requirement, item: item) else { return false }
        let facts = item.structuredFacts
        switch requirement {
        case .requestedFile:
            return facts.contentRead
        case .projectRoot, .projectStructure:
            return !facts.structureEntries.isEmpty
        case .staticSourceEvidence:
            return facts.contentRead && !facts.languages.isEmpty
        case .primaryLanguages:
            return !facts.languages.isEmpty
        case .projectManifest:
            return !facts.manifestTypes.isEmpty
                || facts.manifestName != nil
                || !facts.scriptKeys.isEmpty
                || !facts.dependencyFacts.isEmpty
        case .frontendManifestOrConfig:
            return !facts.frontendFrameworks.isEmpty
        case .frontendConfiguration:
            return !facts.frontendFrameworks.isEmpty
                && (item.targetPath.lowercased().contains("config") || item.targetPath.lowercased().hasSuffix("package.json"))
        case .backendManifest:
            return !facts.backendFrameworks.isEmpty
        case .databaseSchemaOrConfig:
            return !facts.databaseProviders.isEmpty
        case .backendEntryPoint:
            return !facts.backendFrameworks.isEmpty || facts.serverBootstrap
        case .backendApplicationAssembly:
            return facts.contentRead
        case .importantDependencies:
            return !facts.dependencyFacts.isEmpty
        case .inspectedManifestsAndKeyFiles:
            return facts.contentRead
        case .assessmentOrderReadBoundary, .assessmentAPIServiceBoundary,
             .assessmentAuthentication, .assessmentRecordAuthorization,
             .assessmentPermissionModel, .assessmentAuditLogging,
             .assessmentMutationPaths, .assessmentSensitiveResponseFields,
             .assessmentArchitectureDocumentation, .assessmentExampleConfiguration:
            return facts.contentRead || isBoundedZeroResultSearch(item)
        }
    }

    private static func safeFacts(
        for requirement: ReadOnlyEvidenceRequirementKind,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> [String] {
        let facts = evidence.flatMap { item -> [String] in
            let extracted = item.structuredFacts
            switch requirement {
            case .requestedFile:
                return ["successfully read \(item.targetPath)"]
            case .projectRoot, .projectStructure:
                return extracted.structureEntries.prefix(24).map { "structure=\($0)" }
            case .staticSourceEvidence:
                return extracted.languages.map { "language=\($0)" }
            case .primaryLanguages:
                return extracted.languages.map { "language=\($0)" }
            case .projectManifest:
                return extracted.safeSummaries.filter { $0.hasPrefix("manifest.") || $0.hasPrefix("scripts=") || $0.hasPrefix("dependencies=") || $0.hasPrefix("devDependencies=") }
            case .frontendManifestOrConfig, .frontendConfiguration:
                return extracted.frontendFrameworks.map { "frontend.framework=\($0)" }
            case .backendManifest:
                return extracted.backendFrameworks.map { "backend.framework=\($0)" }
            case .databaseSchemaOrConfig:
                return extracted.databaseProviders.map { "database=\($0)" }
                    + extracted.ormNames.map { "orm=\($0)" }
            case .backendEntryPoint:
                let details = extracted.backendFrameworks.map { "backend.bootstrap.framework=\($0)" }
                    + (extracted.serverBootstrap ? ["server.bootstrap=confirmed"] : [])
                return details.isEmpty ? ["successfully read backend entry \(item.targetPath)"] : details
            case .backendApplicationAssembly:
                if item.toolName == "engineering.read_file", isBackendApplicationAssembly(item.targetPath), extracted.contentRead {
                    return ["successfully read application assembly \(item.targetPath)"]
                }
                return extracted.referencedSourcePaths
                    .filter(isBackendApplicationAssembly)
                    .map { "referenced but not read \($0)" }
            case .importantDependencies:
                return extracted.dependencyFacts.map { "dependency=\($0)" }
            case .inspectedManifestsAndKeyFiles:
                return ["successfully read \(item.targetPath)"]
            case .assessmentOrderReadBoundary, .assessmentAPIServiceBoundary,
                 .assessmentAuthentication, .assessmentRecordAuthorization,
                 .assessmentPermissionModel, .assessmentAuditLogging,
                 .assessmentMutationPaths, .assessmentSensitiveResponseFields,
                 .assessmentArchitectureDocumentation, .assessmentExampleConfiguration:
                return item.toolName == "engineering.read_file"
                    ? ["bounded assessment evidence read from \(item.targetPath)"]
                    : ["bounded assessment search completed for \(item.query ?? item.targetPath) with zero results"]
            }
        }
        return unique(facts)
    }

    private static func pathRecords(
        evidence: [ReadOnlyInspectionEvidence],
        finalAnswer: String?
    ) -> [ReadOnlyEvidencePathRecord] {
        func key(workspace: String, path: String) -> String { "\(workspace)\u{0}\(path)" }
        func split(_ key: String) -> (workspace: String, path: String) {
            let values = key.split(separator: "\u{0}", maxSplits: 1).map(String.init)
            return (values.first ?? "legacy", values.count > 1 ? values[1] : "")
        }
        var discovered: [String: [UUID]] = [:]
        var searched: [String: [UUID]] = [:]
        var manifestDerived: [String: [UUID]] = [:]
        var referenced: [String: [UUID]] = [:]
        var reads: [String: [UUID]] = [:]
        var factKinds: [String: [String]] = [:]
        var directoryEvents: [String: [UUID]] = [:]
        var directoryParents: [String: String] = [:]
        var entryTypes: [String: ReadOnlyDirectoryEntryType] = [:]
        for item in evidence {
            let itemKey = key(workspace: item.workspaceIdentity, path: item.targetPath)
            if item.toolName == "engineering.search_files" || item.toolName == "engineering.search_code" {
                searched[itemKey, default: []].append(item.toolResultEventID)
            }
            for path in item.structuredFacts.discoveredPaths {
                let pathKey = key(workspace: item.workspaceIdentity, path: path)
                discovered[pathKey, default: []].append(item.toolResultEventID)
            }
            for path in item.structuredFacts.manifestDerivedPaths {
                let pathKey = key(workspace: item.workspaceIdentity, path: path)
                manifestDerived[pathKey, default: []].append(item.toolResultEventID)
                entryTypes[pathKey] = .file
            }
            for path in item.structuredFacts.referencedSourcePaths {
                let pathKey = key(workspace: item.workspaceIdentity, path: path)
                referenced[pathKey, default: []].append(item.toolResultEventID)
                entryTypes[pathKey] = .file
            }
            for entry in item.structuredFacts.directoryEntries {
                let pathKey = key(workspace: item.workspaceIdentity, path: entry.canonicalChildRelativePath)
                directoryEvents[pathKey, default: []].append(item.toolResultEventID)
                directoryParents[pathKey] = entry.requestedParentRelativePath
                entryTypes[pathKey] = entry.entryType
            }
            if item.toolName == "engineering.read_file" {
                reads[itemKey, default: []].append(item.toolResultEventID)
                entryTypes[itemKey] = .file
            }
            if !item.structuredFacts.factKinds.isEmpty {
                factKinds[itemKey, default: []].append(contentsOf: item.structuredFacts.factKinds)
            }
        }
        let paths = Set(discovered.keys)
            .union(searched.keys)
            .union(manifestDerived.keys)
            .union(referenced.keys)
            .union(reads.keys)
            .union(factKinds.keys)
            .union(directoryEvents.keys)
        let normalizedAnswer = finalAnswer?.lowercased() ?? ""
        return paths.sorted().map { recordKey in
            let identity = split(recordKey)
            let matchingEvidence = evidence.filter {
                $0.workspaceIdentity == identity.workspace && $0.targetPath == identity.path
            }
            var claimLevels: [ReadOnlyEngineeringClaimLevel] = []
            if !(discovered[recordKey] ?? []).isEmpty
                || !(searched[recordKey] ?? []).isEmpty
                || !(directoryEvents[recordKey] ?? []).isEmpty
                || !(manifestDerived[recordKey] ?? []).isEmpty {
                claimLevels.append(.discovered)
                claimLevels.append(.existsConfirmed)
            }
            if !(referenced[recordKey] ?? []).isEmpty, (reads[recordKey] ?? []).isEmpty {
                claimLevels.append(.referencedButNotRead)
            }
            if !(reads[recordKey] ?? []).isEmpty {
                claimLevels.append(contentsOf: [.existsConfirmed, .contentRead])
                if matchingEvidence.contains(where: {
                    let facts = $0.structuredFacts
                    return facts.buildConfigurationPresent
                        || !facts.configurationFormats.isEmpty
                        || !facts.schemaLanguages.isEmpty
                        || !facts.manifestTypes.isEmpty
                        || !facts.databaseProviders.isEmpty
                }) {
                    claimLevels.append(.configurationConfirmed)
                }
                if matchingEvidence.contains(where: {
                    $0.structuredFacts.serverBootstrap || !$0.structuredFacts.referencedSourcePaths.isEmpty
                }) {
                    claimLevels.append(.sourceBehaviorConfirmed)
                }
            }
            if matchingEvidence.contains(where: { $0.structuredFacts.buildConfigurationPresent }) {
                claimLevels.append(contentsOf: [.buildConfigPresent, .buildNotExecuted])
            }
            if matchingEvidence.contains(where: { $0.structuredFacts.testConfigurationPresent }) {
                claimLevels.append(.testNotExecuted)
            }
            return ReadOnlyEvidencePathRecord(
                workspaceIdentity: identity.workspace,
                relativePath: identity.path,
                requestedParentRelativePath: directoryParents[recordKey],
                entryType: entryTypes[recordKey],
                directoryEntrySuccessfulEventIDs: uniqueUUIDs(directoryEvents[recordKey] ?? []),
                discoveredBySuccessfulEventIDs: uniqueUUIDs(discovered[recordKey] ?? []),
                searchedBySuccessfulEventIDs: uniqueUUIDs(searched[recordKey] ?? []),
                manifestDerivedBySuccessfulEventIDs: uniqueUUIDs(manifestDerived[recordKey] ?? []),
                referencedBySuccessfulEventIDs: uniqueUUIDs(referenced[recordKey] ?? []),
                successfullyReadByEventIDs: uniqueUUIDs(reads[recordKey] ?? []),
                extractedFactKinds: unique(factKinds[recordKey] ?? []),
                claimLevels: uniqueClaimLevels(claimLevels),
                includedInFinalAnswer: !normalizedAnswer.isEmpty && normalizedAnswer.contains(identity.path.lowercased())
            )
        }
    }

    private static func isManifest(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return [
            "package.json", "package.swift", "pyproject.toml", "requirements.txt", "pom.xml",
            "build.gradle", "build.gradle.kts", "cargo.toml", "gemfile", "composer.json", "go.mod"
        ].contains(name) || path.hasSuffix(".csproj") || path.hasSuffix(".podspec")
    }

    private static func assessmentEvidence(
        _ item: ReadOnlyInspectionEvidence,
        paths: [String],
        queries: [String]
    ) -> Bool {
        let path = item.targetPath.lowercased()
        if item.toolName == "engineering.read_file" {
            return paths.contains { path.contains($0) }
        }
        guard item.toolName == "engineering.search_code" || item.toolName == "engineering.search_files" else {
            return false
        }
        let query = item.query?.lowercased() ?? ""
        return queries.contains { query.contains($0) }
    }

    private static func isBoundedZeroResultSearch(_ item: ReadOnlyInspectionEvidence) -> Bool {
        guard item.toolName == "engineering.search_code" || item.toolName == "engineering.search_files" else {
            return false
        }
        let value = item.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty
            || value.contains("found 0 match")
            || value.contains("0 matches")
            || value.contains("no matches")
            || value.contains("no files found")
    }

    private static func isBackendPath(_ path: String) -> Bool {
        let segments: Set<String> = ["server", "backend", "api", "service", "services"]
        return path.split(separator: "/").contains { segments.contains(String($0).lowercased()) }
    }

    private static func isBackendEntry(_ path: String) -> Bool {
        guard isBackendPath(path) else { return false }
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return ["index", "main", "server", "bootstrap", "start"].contains(stem)
            && ["swift", "ts", "tsx", "js", "jsx", "py", "java", "kt", "go", "rs"].contains(url.pathExtension.lowercased())
    }

    private static func isBackendApplicationAssembly(_ path: String) -> Bool {
        guard isBackendPath(path) else { return false }
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        return ["app", "application"].contains(stem)
            && ["swift", "ts", "tsx", "js", "jsx", "py", "java", "kt", "go", "rs"].contains(url.pathExtension.lowercased())
    }

    private static func evidenceLevel(
        for requirement: ReadOnlyEvidenceRequirementKind,
        status: ReadOnlyRequirementStatus,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> ReadOnlyEngineeringClaimLevel {
        guard status == .satisfied else {
            if requirement == .backendApplicationAssembly,
               evidence.contains(where: { !$0.structuredFacts.referencedSourcePaths.filter(isBackendApplicationAssembly).isEmpty }) {
                return .referencedButNotRead
            }
            return evidence.isEmpty ? .discovered : .existsConfirmed
        }
        switch requirement {
        case .projectRoot, .projectStructure:
            return .discovered
        case .projectManifest, .frontendManifestOrConfig, .frontendConfiguration,
             .backendManifest, .databaseSchemaOrConfig, .importantDependencies:
            return .configurationConfirmed
        case .backendEntryPoint:
            return evidence.contains(where: { $0.structuredFacts.serverBootstrap })
                ? .sourceBehaviorConfirmed
                : .contentRead
        case .backendApplicationAssembly, .requestedFile, .staticSourceEvidence,
             .primaryLanguages, .inspectedManifestsAndKeyFiles,
             .assessmentOrderReadBoundary, .assessmentAPIServiceBoundary,
             .assessmentAuthentication, .assessmentRecordAuthorization,
             .assessmentPermissionModel, .assessmentAuditLogging,
             .assessmentMutationPaths, .assessmentSensitiveResponseFields,
             .assessmentArchitectureDocumentation, .assessmentExampleConfiguration:
            return .contentRead
        }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.lowercased()).inserted }
    }

    private static func uniqueUUIDs(_ values: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueClaimLevels(_ values: [ReadOnlyEngineeringClaimLevel]) -> [ReadOnlyEngineeringClaimLevel] {
        let present = Set(values)
        return ReadOnlyEngineeringClaimLevel.allCases.filter(present.contains)
    }
}

struct ReadOnlyFinalAnswerValidation: Hashable, Sendable {
    var accepted: Bool
    var issues: [String]
    var safeContractFailures: [ReadOnlyFinalAnswerContractFailure]
    var ledger: ReadOnlyFinalizationEvidenceLedger
}

enum ReadOnlyFinalAnswerContractFailure: String, Codable, CaseIterable, Hashable, Sendable {
    case missingExplicitRequirement = "missing_explicit_requirement"
    case unsupportedBuildClaim = "unsupported_build_claim"
    case unsupportedVerificationClaim = "unsupported_verification_claim"
    case unsupportedStaticClaim = "unsupported_static_claim"
    case missingEvidencePath = "missing_evidence_path"
    case incorrectLanguage = "incorrect_language"
    case contradictoryCompletionState = "contradictory_completion_state"
    case assessmentSemanticInconsistency = "assessment_semantic_inconsistency"
    case unboundAssessmentClaim = "unbound_assessment_claim"
}

enum ReadOnlyFinalAnswerContract {
    private static let frameworkNames = [
        "React", "Vite", "Vue", "Next.js", "Svelte", "Angular",
        "Fastify", "Express", "Koa", "NestJS", "Hono"
    ]
    private static let databaseNames = [
        "PostgreSQL", "MySQL", "SQLite", "SQL Server", "MongoDB", "CockroachDB"
    ]

    static func validate(
        answer: String,
        request: String,
        requirements: ReadOnlyEvidenceRequirements,
        evidence: [ReadOnlyInspectionEvidence],
        requireComplete: Bool
    ) -> ReadOnlyFinalAnswerValidation {
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: evidence,
            finalAnswer: answer
        )
        let normalized = answer.lowercased()
        var issues: [String] = []
        var safeFailures: [ReadOnlyFinalAnswerContractFailure] = []
        let language = ReadOnlyResponseLanguage(request: request)
        if !language.matches(answer) {
            issues.append("final_answer_language_mismatch_expected_\(language.rawValue)")
            safeFailures.append(.incorrectLanguage)
        }
        if requireComplete, !ledger.allMaterialRequirementsSatisfied {
            issues.append("material_requirements_unsatisfied")
            safeFailures.append(.missingExplicitRequirement)
        }
        if requireComplete, containsUnresolvedMaterialClaim(normalized) {
            issues.append("complete_answer_contains_unresolved_material_requirement")
            safeFailures.append(.contradictoryCompletionState)
        }
        if containsVagueDependencyClaim(normalized) {
            issues.append("dependency_claim_is_vague_or_unconfirmed")
            safeFailures.append(.unsupportedStaticClaim)
        }
        if containsUnsupportedBuildClaim(normalized) {
            issues.append("unsupported_build_claim")
            safeFailures.append(.unsupportedBuildClaim)
        }
        if containsUnsupportedVerificationClaim(normalized) {
            issues.append("unsupported_test_runtime_or_deployment_claim")
            safeFailures.append(.unsupportedVerificationClaim)
        }

        let successfulReadPaths = ledger.successfulReadPaths
        for record in ledger.paths where record.successfullyReadByEventIDs.isEmpty && isFileRecord(record) {
            if claimsSuccessfulRead(path: record.relativePath, answer: answer) {
                issues.append("unread_path_claimed_as_read:\(record.relativePath)")
                safeFailures.append(contentsOf: [.unsupportedStaticClaim, .missingEvidencePath])
            }
        }
        if requirements.required.contains(.inspectedManifestsAndKeyFiles) {
            for path in successfulReadPaths where !normalized.contains(path.lowercased()) {
                issues.append("successful_read_missing_from_final_answer:\(path)")
                safeFailures.append(.missingEvidencePath)
            }
        }
        for path in successfulReadPaths where recommendsReading(path: path, answer: answer) {
            issues.append("successfully_read_file_recommended_as_unread:\(path)")
            safeFailures.append(.contradictoryCompletionState)
        }

        let allFacts = evidence.map(\.structuredFacts)
        let confirmedFrameworks = Set(allFacts.flatMap { $0.frontendFrameworks + $0.backendFrameworks }.map { $0.lowercased() })
        for name in frameworkNames where normalized.contains(name.lowercased())
            && !confirmedFrameworks.contains(name.lowercased()) {
            issues.append("unsupported_framework_claim:\(name)")
            safeFailures.append(.unsupportedStaticClaim)
        }
        let confirmedDatabases = Set(allFacts.flatMap(\.databaseProviders).map { $0.lowercased() })
        for name in databaseNames where normalized.contains(name.lowercased())
            && !confirmedDatabases.contains(name.lowercased()) {
            issues.append("unsupported_database_claim:\(name)")
            safeFailures.append(.unsupportedStaticClaim)
        }

        for entry in ledger.requirements where entry.status == .satisfied {
            switch ReadOnlyEvidenceRequirementKind(rawValue: entry.requirementID) {
            case .primaryLanguages, .frontendManifestOrConfig, .frontendConfiguration,
                 .backendManifest, .databaseSchemaOrConfig, .importantDependencies:
                let factValues = entry.extractedSafeFacts.compactMap { fact in
                    fact.split(separator: "=", maxSplits: 1).last.map(String.init)
                }
                if !factValues.contains(where: { normalized.contains($0.lowercased()) }) {
                    issues.append("satisfied_requirement_fact_missing_from_answer:\(entry.requirementID)")
                    safeFailures.append(.missingExplicitRequirement)
                }
                if !entry.supportingRelativePaths.contains(where: { normalized.contains($0.lowercased()) }) {
                    issues.append("satisfied_requirement_path_missing_from_answer:\(entry.requirementID)")
                    safeFailures.append(.missingEvidencePath)
                }
            case .projectManifest, .backendEntryPoint, .backendApplicationAssembly:
                if !entry.supportingRelativePaths.contains(where: { normalized.contains($0.lowercased()) }) {
                    issues.append("satisfied_requirement_path_missing_from_answer:\(entry.requirementID)")
                    safeFailures.append(.missingEvidencePath)
                }
            default:
                break
            }
        }

        if !requireComplete {
            let hasPartialLanguage = [
                "partial", "incomplete", "not established", "not verified", "unresolved", "remains",
                "部分", "未完成", "未确认", "未验证", "尚未", "仍需"
            ].contains { normalized.contains($0) }
            if !ledger.allMaterialRequirementsSatisfied && !hasPartialLanguage {
                issues.append("partial_answer_does_not_identify_remaining_requirements")
                safeFailures.append(.contradictoryCompletionState)
            }
        }
        return ReadOnlyFinalAnswerValidation(
            accepted: issues.isEmpty,
            issues: unique(issues),
            safeContractFailures: uniqueFailures(safeFailures),
            ledger: ledger
        )
    }

    /// Canonical assessment reports use their structured claim/evidence graph
    /// as the single grounding authority. Prose keyword/path heuristics remain
    /// available for generic read-only answers, but must not override a valid
    /// structured assessment.
    static func validateAssessment(
        report: FDEIntegrationAssessment,
        answer: String,
        request: String,
        requirements: ReadOnlyEvidenceRequirements,
        evidence: [ReadOnlyInspectionEvidence],
        requireComplete: Bool
    ) -> ReadOnlyFinalAnswerValidation {
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: evidence,
            finalAnswer: answer
        )
        var issues: [String] = []
        var failures: [ReadOnlyFinalAnswerContractFailure] = []
        let language = ReadOnlyResponseLanguage(request: request)
        if !language.matches(answer) {
            issues.append("final_answer_language_mismatch_expected_\(language.rawValue)")
            failures.append(.incorrectLanguage)
        }
        if requireComplete, !ledger.allMaterialRequirementsSatisfied {
            issues.append("material_requirements_unsatisfied")
            failures.append(.missingExplicitRequirement)
        }
        if report.markdown(language: language) != answer {
            issues.append("canonical_assessment_does_not_match_visible_answer")
            failures.append(.assessmentSemanticInconsistency)
        }
        if !AssessmentSemanticConsistencyValidator.validate(report).isValid {
            issues.append("assessment_semantic_inconsistency")
            failures.append(.assessmentSemanticInconsistency)
        }
        let grounding = FDEAssessmentGroundingValidator.validate(report, evidence: evidence)
        if !grounding.accepted {
            issues.append(contentsOf: grounding.unsupportedClaimIDs.map { "unbound_assessment_claim:\($0)" })
            issues.append(contentsOf: grounding.invalidEvidenceReferenceIDs.map { "invalid_assessment_evidence_reference:\($0)" })
            failures.append(.unboundAssessmentClaim)
        }
        if !requireComplete, !ledger.allMaterialRequirementsSatisfied,
           report.unknownsAndNextInvestigationSteps.isEmpty {
            issues.append("partial_assessment_does_not_identify_remaining_requirements")
            failures.append(.contradictoryCompletionState)
        }
        return ReadOnlyFinalAnswerValidation(
            accepted: issues.isEmpty,
            issues: unique(issues),
            safeContractFailures: uniqueFailures(failures),
            ledger: ledger
        )
    }

    private static func containsUnresolvedMaterialClaim(_ answer: String) -> Bool {
        [
            "frontend framework was not established", "backend framework was not established",
            "framework was not established", "dependency verification was incomplete",
            "dependencies were not verified", "database was not established",
            "remains to be inspected", "requires another read",
            "前端框架未确认", "后端框架未确认", "框架尚未确认", "依赖验证不完整",
            "依赖尚未验证", "数据库未确认", "仍需读取", "需要再次读取", "尚未检查"
        ].contains { answer.contains($0) }
    }

    private static func containsVagueDependencyClaim(_ answer: String) -> Bool {
        [
            "likely other dependencies", "likely dependencies", "likely other node dependencies",
            "and other dependencies", "可能还有其他依赖", "可能的其他依赖", "其他 node 依赖"
        ].contains { answer.contains($0) }
    }

    private static func containsUnsupportedBuildClaim(_ answer: String) -> Bool {
        [
            "build succeeds", "build succeeded", "build passed", "build verified",
            "build is verified", "buildable", "production ready", "production-ready",
            "可构建", "构建成功", "构建已通过", "已验证构建", "生产就绪"
        ].contains { answer.contains($0) }
    }

    private static func containsUnsupportedVerificationClaim(_ answer: String) -> Bool {
        let negativeMarkers = [
            "not verified", "not executed", "no test was", "no runtime", "no deployment",
            "未验证", "未执行", "没有执行", "未部署"
        ]
        let positiveMarkers = [
            "tests passed", "test passed", "runtime verified", "service is running",
            "service is currently running", "deployment verified", "is deployed",
            "测试通过", "运行状态已验证", "服务正在运行", "部署已验证", "已经部署"
        ]
        return answer.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = String(rawLine)
            return positiveMarkers.contains(where: line.contains)
                && !negativeMarkers.contains(where: line.contains)
        }
    }

    private static func recommendsReading(path: String, answer: String) -> Bool {
        let pathValue = path.lowercased()
        return answer.split(whereSeparator: \.isNewline).contains { rawLine in
            let line = rawLine.lowercased()
            guard line.contains(pathValue) else { return false }
            let futureMarkers = [
                "recommend", "next", "continue", "should read", "need to read", "not read", "unread", "re-read",
                "建议", "下一步", "继续读取", "需要读取", "尚未读取", "未读取", "重新读取"
            ]
            return futureMarkers.contains { line.contains($0) }
        }
    }

    private static func claimsSuccessfulRead(path: String, answer: String) -> Bool {
        let pathValue = path.lowercased()
        var inReadSection = false
        let readSectionMarkers = [
            "files read", "read files", "files/manifests read", "actual files read",
            "实际读取的文件", "实际读取文件"
        ]
        for rawLine in answer.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.lowercased().trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inReadSection = readSectionMarkers.contains(where: line.contains)
            }
            guard line.contains(pathValue) else { continue }
            let negativeMarkers = [
                "not read", "unread", "referenced but not read", "discovered only",
                "未读取", "尚未读取", "仅发现", "只发现", "引用但未读取", "仅被引用"
            ]
            guard !negativeMarkers.contains(where: line.contains) else { continue }
            let positiveMarkers = [
                "files read", "file read", "manifests read", "manifest read", "read files",
                "files/manifests read", "successfully read", "content read", "read:",
                "实际读取", "已读取", "读取过", "成功读取", "读取文件", "读取的文件"
            ]
            if inReadSection || positiveMarkers.contains(where: line.contains) { return true }
        }
        return false
    }

    private static func isFileRecord(_ record: ReadOnlyEvidencePathRecord) -> Bool {
        let path = record.relativePath
        guard path != ".", !path.hasSuffix("/") else { return false }
        if record.entryType == .directory { return false }
        if record.entryType == .file { return true }
        let url = URL(fileURLWithPath: path)
        if !url.pathExtension.isEmpty { return true }
        return ["gemfile", "dockerfile", "makefile", "procfile"].contains(url.lastPathComponent.lowercased())
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func uniqueFailures(
        _ values: [ReadOnlyFinalAnswerContractFailure]
    ) -> [ReadOnlyFinalAnswerContractFailure] {
        let present = Set(values)
        return ReadOnlyFinalAnswerContractFailure.allCases.filter(present.contains)
    }
}
