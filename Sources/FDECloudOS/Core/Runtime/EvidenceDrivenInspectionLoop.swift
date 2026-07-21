import Foundation

enum InspectionRequirementCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case projectStructure = "project_structure"
    case languageRuntime = "language_runtime"
    case architecture
    case apiSurface = "api_surface"
    case dataLayer = "data_layer"
    case integrationPoint = "integration_point"
}

enum InspectionRequiredEvidenceType: String, Codable, Hashable, Sendable {
    case projectInventory = "project_inventory"
    case fileDiscovery = "file_discovery"
    case codeSearch = "code_search"
    case fileContent = "file_content"

    var preferredCommands: [String] {
        switch self {
        case .projectInventory:
            return ["engineering.inspect_project", "engineering.list_directory"]
        case .fileDiscovery:
            return ["engineering.search_files", "engineering.inspect_project", "engineering.list_directory"]
        case .codeSearch:
            return ["engineering.search_code", "engineering.search_files", "engineering.read_file"]
        case .fileContent:
            return ["engineering.read_file", "engineering.search_files", "engineering.search_code", "engineering.inspect_project"]
        }
    }
}

enum InspectionRequirementStatus: String, Codable, Hashable, Sendable {
    case found = "FOUND"
    case missing = "MISSING"
    case unknown = "UNKNOWN"

    var isKnown: Bool { self != .unknown }
}

/// Runtime-owned presentation value for an approved plan evidence requirement.
/// It is persisted in the existing event payload; it grants no execution authority.
struct InspectionRequirement: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var category: InspectionRequirementCategory
    var description: String
    var requiredEvidenceType: InspectionRequiredEvidenceType
    var status: InspectionRequirementStatus
}

struct InspectionEvidenceCoverage: Codable, Hashable, Sendable {
    var requirements: [InspectionRequirement]

    var found: [InspectionRequirement] {
        requirements.filter { $0.status == .found }
    }

    var missing: [InspectionRequirement] {
        requirements.filter { $0.status == .missing }
    }

    var unknown: [InspectionRequirement] {
        requirements.filter { $0.status == .unknown }
    }

    var isSufficient: Bool {
        !requirements.isEmpty && unknown.isEmpty
    }

    static func derive(
        requirements requested: ReadOnlyEvidenceRequirements,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> InspectionEvidenceCoverage {
        // `evidence` is populated by RuntimeKernel only after both a successful
        // TOOL_RESULT and a successful ObservationLoop observation.
        let ledger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requested,
            evidence: evidence
        )
        let ledgerByID = Dictionary(uniqueKeysWithValues: ledger.requirements.map {
            ($0.requirementID, $0)
        })
        let requirements = requested.required.map { kind in
            let definition = InspectionRequirementDefinition(kind: kind)
            let status: InspectionRequirementStatus
            if Self.hasSuccessfulAbsenceObservation(
                for: kind,
                requiredEvidenceType: definition.requiredEvidenceType,
                evidence: evidence
            ) {
                status = .missing
            } else if ledgerByID[kind.rawValue]?.status == .satisfied
                        || Self.hasSuccessfulRootObservation(for: kind, evidence: evidence) {
                status = .found
            } else {
                status = .unknown
            }
            return InspectionRequirement(
                id: kind.rawValue,
                category: definition.category,
                description: definition.description,
                requiredEvidenceType: definition.requiredEvidenceType,
                status: status
            )
        }
        return InspectionEvidenceCoverage(requirements: requirements)
    }

    var auditPayload: [String: String] {
        [
            "inspection_requirements_json": Self.json(requirements),
            "evidence_coverage": requirements.map { "\($0.id):\($0.status.rawValue)" }.joined(separator: " | "),
            "evidence_coverage_found": found.map(\.id).joined(separator: " | "),
            "evidence_coverage_missing": missing.map(\.id).joined(separator: " | "),
            "evidence_coverage_unknown": unknown.map(\.id).joined(separator: " | "),
            "evidence_coverage_sufficient": isSufficient ? "true" : "false"
        ]
    }

    private static func hasSuccessfulAbsenceObservation(
        for kind: ReadOnlyEvidenceRequirementKind,
        requiredEvidenceType: InspectionRequiredEvidenceType,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> Bool {
        evidence.contains { item in
            guard isBoundedZeroResult(item.output) else { return false }
            switch requiredEvidenceType {
            case .projectInventory:
                return kind == .projectStructure
                    && (item.toolName == "engineering.inspect_project"
                    || item.toolName == "engineering.list_directory")
                    && item.structuredFacts.structureEntries.isEmpty
            case .fileDiscovery:
                return item.toolName == "engineering.search_files"
                    && query(item.query, isRelevantTo: kind)
            case .codeSearch:
                return item.toolName == "engineering.search_code"
                    && query(item.query, isRelevantTo: kind)
            case .fileContent:
                return (item.toolName == "engineering.search_files"
                    || item.toolName == "engineering.search_code")
                    && query(item.query, isRelevantTo: kind)
            }
        }
    }

    private static func hasSuccessfulRootObservation(
        for kind: ReadOnlyEvidenceRequirementKind,
        evidence: [ReadOnlyInspectionEvidence]
    ) -> Bool {
        kind == .projectRoot && evidence.contains {
            ($0.toolName == "engineering.inspect_project"
                || $0.toolName == "engineering.list_directory")
                && $0.targetPath == "."
        }
    }

    private static func isBoundedZeroResult(_ output: String) -> Bool {
        let normalized = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty
            || normalized.contains("found 0 match")
            || normalized.contains("0 matches")
            || normalized.contains("no matches")
            || normalized.contains("no files found")
    }

    private static func query(
        _ query: String?,
        isRelevantTo kind: ReadOnlyEvidenceRequirementKind
    ) -> Bool {
        let normalized = query?.lowercased() ?? ""
        guard !normalized.isEmpty else { return false }
        return InspectionRequirementDefinition.searchTerms(for: kind).contains {
            normalized.contains($0)
        }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

enum InspectionLoopStopReason: String, Codable, Hashable, Sendable {
    case coverageSufficient = "coverage_sufficient"
    case maximumInspectionStepsReached = "maximum_inspection_steps_reached"
    case maximumToolCallsReached = "maximum_tool_calls_reached"
    case maximumFilesInspectedReached = "maximum_files_inspected_reached"
    case deadlineReached = "deadline_reached"
    case evidenceUnavailable = "evidence_unavailable"

    var isBudgetExhaustion: Bool {
        switch self {
        case .maximumInspectionStepsReached, .maximumToolCallsReached,
             .maximumFilesInspectedReached, .deadlineReached:
            return true
        case .coverageSufficient, .evidenceUnavailable:
            return false
        }
    }
}

struct InspectionLoopBudgetUsage: Codable, Hashable, Sendable {
    var inspectionSteps: Int
    var toolCalls: Int
    var filesInspected: Int
    var maximumInspectionSteps: Int
    var maximumToolCalls: Int
    var maximumFilesInspected: Int
    var deadline: Date

    var auditPayload: [String: String] {
        [
            "inspection_steps_used": String(inspectionSteps),
            "inspection_tool_calls_used": String(toolCalls),
            "inspection_files_used": String(filesInspected),
            "bounded_inspection_step_limit": String(maximumInspectionSteps),
            "bounded_tool_limit": String(maximumToolCalls),
            "bounded_file_limit": String(maximumFilesInspected),
            "inspection_deadline": ISO8601DateFormatter().string(from: deadline)
        ]
    }
}

struct EvidenceDrivenInspectionSelector: Sendable {
    func next(
        from approvedSteps: [ReadOnlyExecutableStep],
        excluding executedToolCallIDs: Set<String>,
        coverage: InspectionEvidenceCoverage,
        evidence: [ReadOnlyInspectionEvidence],
        allowFileReads: Bool
    ) -> ReadOnlyExecutableStep? {
        let remaining = approvedSteps.filter { executable in
            !executedToolCallIDs.contains(executable.toolCall.id)
                && ReadOnlyInspectionPolicy.allowedTools.contains(executable.toolCall.command)
                && ReadOnlyToolSchemas.all[executable.toolCall.command] != nil
                && (allowFileReads || executable.toolCall.command != "engineering.read_file")
        }
        guard !remaining.isEmpty else { return nil }

        for requirement in coverage.unknown {
            for command in requirement.requiredEvidenceType.preferredCommands {
                if let match = remaining.first(where: {
                    $0.toolCall.command == command
                        && (command != "engineering.read_file"
                            || readTargetIsKnown($0, from: evidence))
                }) {
                    return match
                }
            }
        }

        for command in ReadOnlyInspectionPolicy.orderedAllowedTools {
            if let match = remaining.first(where: { $0.toolCall.command == command }) {
                return match
            }
        }
        return nil
    }

    private func readTargetIsKnown(
        _ executable: ReadOnlyExecutableStep,
        from evidence: [ReadOnlyInspectionEvidence]
    ) -> Bool {
        evidence.contains { item in
            guard item.workspaceIdentity == executable.workspaceIdentity else { return false }
            let facts = item.structuredFacts
            return item.targetPath == executable.relativeTargetPath
                || facts.structureEntries.contains(executable.relativeTargetPath)
                || facts.discoveredPaths.contains(executable.relativeTargetPath)
                || facts.manifestDerivedPaths.contains(executable.relativeTargetPath)
                || facts.referencedSourcePaths.contains(executable.relativeTargetPath)
        }
    }
}

private struct InspectionRequirementDefinition {
    var category: InspectionRequirementCategory
    var description: String
    var requiredEvidenceType: InspectionRequiredEvidenceType

    init(kind: ReadOnlyEvidenceRequirementKind) {
        description = "Collect successful read-only evidence for \(kind.label)."
        switch kind {
        case .projectRoot, .projectStructure:
            category = .projectStructure
            requiredEvidenceType = .projectInventory
        case .primaryLanguages, .projectManifest, .frontendManifestOrConfig,
             .frontendConfiguration, .backendManifest, .importantDependencies:
            category = .languageRuntime
            requiredEvidenceType = .fileContent
        case .requestedFile, .staticSourceEvidence, .backendEntryPoint,
             .backendApplicationAssembly, .inspectedManifestsAndKeyFiles,
             .assessmentArchitectureDocumentation:
            category = .architecture
            requiredEvidenceType = .fileContent
        case .assessmentAPIServiceBoundary, .assessmentAuthentication,
             .assessmentRecordAuthorization, .assessmentPermissionModel,
             .assessmentSensitiveResponseFields:
            category = .apiSurface
            requiredEvidenceType = .codeSearch
        case .databaseSchemaOrConfig, .assessmentOrderReadBoundary:
            category = .dataLayer
            requiredEvidenceType = .fileDiscovery
        case .assessmentAuditLogging, .assessmentMutationPaths,
             .assessmentExampleConfiguration:
            category = .integrationPoint
            requiredEvidenceType = .codeSearch
        }
    }

    static func searchTerms(for kind: ReadOnlyEvidenceRequirementKind) -> [String] {
        switch kind {
        case .requestedFile: return ["file", ".swift", ".ts", ".js", ".py"]
        case .projectRoot, .projectStructure: return ["project", "source", "src"]
        case .staticSourceEvidence: return ["source", "class", "struct", "func"]
        case .primaryLanguages: return ["swift", "typescript", "javascript", "python", "source"]
        case .projectManifest, .importantDependencies: return ["package", "manifest", "dependency"]
        case .frontendManifestOrConfig, .frontendConfiguration: return ["frontend", "vite", "webpack", "react"]
        case .backendManifest, .backendEntryPoint, .backendApplicationAssembly:
            return ["backend", "server", "app", "main", "bootstrap"]
        case .databaseSchemaOrConfig, .assessmentOrderReadBoundary:
            return ["database", "schema", "prisma", "order", "repository"]
        case .assessmentAPIServiceBoundary: return ["api", "route", "service", "controller"]
        case .assessmentAuthentication: return ["auth", "session", "token"]
        case .assessmentRecordAuthorization, .assessmentPermissionModel:
            return ["permission", "authorization", "policy", "role"]
        case .assessmentAuditLogging: return ["audit", "log"]
        case .assessmentMutationPaths: return ["mutation", "update", "write", "delete"]
        case .assessmentSensitiveResponseFields: return ["sensitive", "response", "email", "address"]
        case .assessmentArchitectureDocumentation: return ["architecture", "readme", "docs"]
        case .assessmentExampleConfiguration: return ["example", "config", "sample"]
        case .inspectedManifestsAndKeyFiles: return ["package", "manifest", "config", "source"]
        }
    }
}
