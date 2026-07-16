import Foundation

enum ReadOnlyAcceptanceTerminalState: String, Codable, Hashable, Sendable {
    case completed
    case partial
}

struct ReadOnlyAcceptanceFixtureStep: Codable, Hashable, Sendable {
    var tool: String
    var workspaceIdentity: String
    var path: String
    var output: String
    var succeeded: Bool

    init(
        _ tool: String,
        path: String,
        output: String,
        workspaceIdentity: String = "legacy",
        succeeded: Bool = true
    ) {
        self.tool = tool
        self.workspaceIdentity = workspaceIdentity
        self.path = path
        self.output = output
        self.succeeded = succeeded
    }
}

struct ReadOnlyAcceptanceExpectation: Codable, Hashable, Sendable {
    var workspaceScope: String
    var successfulTools: [String]
    var inspectedPaths: [String]
    var canonicalPathsContaining: [String]
    var satisfiedRequirementsContaining: [String]
    var remainingRequirementsContaining: [String]
    var evidenceLevelsContaining: [ReadOnlyEngineeringClaimLevel]
    var terminalState: ReadOnlyAcceptanceTerminalState
    var reportLanguage: ReadOnlyResponseLanguage
    var providerFallbackUsed: Bool = false
}

struct ReadOnlyAcceptanceBenchmarkCase: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var request: String
    var steps: [ReadOnlyAcceptanceFixtureStep]
    var mockedProviderFallback: Bool
    var expectation: ReadOnlyAcceptanceExpectation
}

struct ReadOnlyAcceptanceBenchmarkResult: Identifiable, Codable, Hashable, Sendable {
    var id: String { caseID }
    var caseID: String
    var route: String
    var workspaceScope: String
    var successfulTools: [String]
    var inspectedPaths: [String]
    var canonicalPaths: [String]
    var evidenceLevels: [String: String]
    var satisfiedRequirements: [String]
    var remainingRequirements: [String]
    var unsupportedClaimViolations: [String]
    var terminalState: ReadOnlyAcceptanceTerminalState
    var reportLanguage: ReadOnlyResponseLanguage
    var noSecretExposure: Bool
    var providerFallbackUsed: Bool
    var passed: Bool
    var passFailReason: String
}

struct ReadOnlyAcceptanceBenchmarkRunner: Sendable {
    func runAll(
        cases: [ReadOnlyAcceptanceBenchmarkCase] = ReadOnlyAcceptanceBenchmarkCase.defaultCases
    ) -> [ReadOnlyAcceptanceBenchmarkResult] {
        cases.map { run($0) }
    }

    func runAllJSON(
        cases: [ReadOnlyAcceptanceBenchmarkCase] = ReadOnlyAcceptanceBenchmarkCase.defaultCases
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(runAll(cases: cases))
        return String(decoding: data, as: UTF8.self)
    }

    func run(_ benchmark: ReadOnlyAcceptanceBenchmarkCase) -> ReadOnlyAcceptanceBenchmarkResult {
        let intent = MissionIntentParser().parse(benchmark.request)
        let route = MissionExecutionSemantic(intent: intent).rawValue
        let scope = MissionWorkspaceScope(request: benchmark.request).rawValue
        let successfulSteps = benchmark.steps.filter {
            $0.succeeded && !ReadOnlySensitivePathPolicy.isSensitive($0.path)
        }
        let evidence = successfulSteps.enumerated().map { index, step in
            ReadOnlyInspectionEvidence(
                toolCallID: "\(benchmark.id).\(index)",
                toolName: step.tool,
                workspaceID: UUID(),
                workspaceIdentity: step.workspaceIdentity,
                targetPath: step.path,
                output: step.output,
                toolCalledEventID: UUID(),
                toolResultEventID: UUID()
            )
        }
        let requirements = ReadOnlyEvidenceRequirements(request: benchmark.request)
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: evidence)
        let remaining = ledger.unsatisfied.map(\.rawValue)
        let terminal: ReadOnlyAcceptanceTerminalState = remaining.isEmpty ? .completed : .partial
        let language = ReadOnlyResponseLanguage(request: benchmark.request)
        let report = deterministicReport(language: language, ledger: ledger)
        let validation = ReadOnlyFinalAnswerContract.validate(
            answer: report,
            request: benchmark.request,
            requirements: requirements,
            evidence: evidence,
            requireComplete: remaining.isEmpty
        )
        let unsupportedFailures: Set<ReadOnlyFinalAnswerContractFailure> = [
            .unsupportedBuildClaim, .unsupportedVerificationClaim, .unsupportedStaticClaim
        ]
        let unsupported = validation.safeContractFailures
            .filter(unsupportedFailures.contains)
            .map(\.rawValue)
        let canonicalPaths = ledger.paths.map(\.relativePath).sorted()
        let inspectedPaths = ledger.successfulReadPaths.sorted()
        let satisfied = ledger.satisfied.map(\.rawValue)
        let evidenceLevels = Dictionary(
            uniqueKeysWithValues: ledger.requirements.map { ($0.requirementID, $0.evidenceLevel.rawValue) }
        )
        let noSecretExposure = containsNoSecret(report: report, evidence: evidence)
        var failures: [String] = []

        assertEqual(route, MissionExecutionSemantic.readOnlyWorkspaceInspection.rawValue, "route", into: &failures)
        assertEqual(scope, benchmark.expectation.workspaceScope, "workspace scope", into: &failures)
        assertEqual(successfulSteps.map(\.tool), benchmark.expectation.successfulTools, "tool sequence", into: &failures)
        assertEqual(inspectedPaths, benchmark.expectation.inspectedPaths.sorted(), "inspected paths", into: &failures)
        assertContains(canonicalPaths, benchmark.expectation.canonicalPathsContaining, "canonical paths", into: &failures)
        assertContains(satisfied, benchmark.expectation.satisfiedRequirementsContaining, "satisfied requirements", into: &failures)
        assertContains(remaining, benchmark.expectation.remainingRequirementsContaining, "remaining requirements", into: &failures)
        assertContains(ledger.claimMaturityLevels, benchmark.expectation.evidenceLevelsContaining, "evidence levels", into: &failures)
        assertEqual(terminal, benchmark.expectation.terminalState, "terminal state", into: &failures)
        assertEqual(language, benchmark.expectation.reportLanguage, "report language", into: &failures)
        assertEqual(benchmark.mockedProviderFallback, benchmark.expectation.providerFallbackUsed, "provider fallback", into: &failures)
        if !language.matches(report) { failures.append("report language contract failed") }
        if !unsupported.isEmpty { failures.append("unsupported claim: \(unsupported.joined(separator: ", "))") }
        if !ledger.unsupportedExecutionClaimLevels.isEmpty {
            failures.append("execution-only claim level emitted")
        }
        if !noSecretExposure { failures.append("secret-like raw content was exposed") }
        if scope == MissionWorkspaceScope.legacyOnly.rawValue,
           evidence.contains(where: { $0.workspaceIdentity != "legacy" }) {
            failures.append("legacy-only scope included another workspace")
        }
        if remaining.isEmpty, !validation.accepted {
            failures.append("complete report contract failed: \(validation.issues.joined(separator: ", "))")
        }

        return ReadOnlyAcceptanceBenchmarkResult(
            caseID: benchmark.id,
            route: route,
            workspaceScope: scope,
            successfulTools: successfulSteps.map(\.tool),
            inspectedPaths: inspectedPaths,
            canonicalPaths: canonicalPaths,
            evidenceLevels: evidenceLevels,
            satisfiedRequirements: satisfied,
            remainingRequirements: remaining,
            unsupportedClaimViolations: unsupported,
            terminalState: terminal,
            reportLanguage: language,
            noSecretExposure: noSecretExposure,
            providerFallbackUsed: benchmark.mockedProviderFallback,
            passed: failures.isEmpty,
            passFailReason: failures.isEmpty ? "All deterministic read-only acceptance assertions passed." : failures.joined(separator: " | ")
        )
    }

    private func deterministicReport(
        language: ReadOnlyResponseLanguage,
        ledger: ReadOnlyFinalizationEvidenceLedger
    ) -> String {
        let completed = ledger.unsatisfied.isEmpty
        let requirementLines = ledger.requirements.map { entry -> String in
            let facts = entry.extractedSafeFacts.joined(separator: ", ")
            let paths = entry.supportingRelativePaths.joined(separator: ", ")
            if language == .chinese {
                let status = entry.status == .satisfied
                    ? "已读取或配置确认"
                    : (entry.evidenceLevel == .referencedButNotRead ? "被入口引用但未读取" : "尚未确认")
                return "- \(entry.requestedCategory)：\(status)；证据 \(paths.isEmpty ? "无" : paths)；事实 \(facts.isEmpty ? "无" : facts)。"
            }
            let status = entry.status == .satisfied
                ? "confirmed at \(entry.evidenceLevel.rawValue)"
                : (entry.evidenceLevel == .referencedButNotRead ? "referenced but not read" : "not confirmed")
            return "- \(entry.requestedCategory): \(status); evidence \(paths.isEmpty ? "none" : paths); facts \(facts.isEmpty ? "none" : facts)."
        }.joined(separator: "\n")
        let hasBuildConfig = ledger.claimMaturityLevels.contains(.buildConfigPresent)
        if language == .chinese {
            return """
            \(completed ? "只读检查已完成，所有明确要求均有对应证据。" : "只读检查为部分完成，剩余要求已明确列出。")
            \(requirementLines)
            - \(hasBuildConfig ? "已确认存在构建脚本和构建配置，但本轮未实际执行构建。" : "本轮未实际执行构建。")
            - 测试状态：本轮未执行。
            - 服务运行状态：未验证运行状态。
            - 部署状态：未验证部署状态。
            """
        }
        return """
        \(completed ? "The read-only inspection is complete and every explicit requirement has evidence." : "This is a partial read-only inspection; remaining requirements are stated below.")
        \(requirementLines)
        - \(hasBuildConfig ? "Build scripts and configuration are present, but no build was executed during this inspection." : "No build was executed during this inspection.")
        - Test status: not executed.
        - Runtime status: not verified.
        - Deployment status: not verified.
        """
    }

    private func containsNoSecret(report: String, evidence: [ReadOnlyInspectionEvidence]) -> Bool {
        let combined = ([report] + evidence.map(\.output)).joined(separator: "\n").lowercased()
        return !["-----begin private key-----", "password=", "api_key=", "secret_access_key=", "sk-live-", "sk-proj-"].contains {
            combined.contains($0)
        }
    }

    private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String, into failures: inout [String]) {
        if actual != expected { failures.append("\(label) mismatch") }
    }

    private func assertContains<T: Hashable>(_ actual: [T], _ expected: [T], _ label: String, into failures: inout [String]) {
        if !Set(expected).isSubset(of: Set(actual)) { failures.append("\(label) missing expected values") }
    }
}

extension ReadOnlyAcceptanceBenchmarkCase {
    private static let rootListing = "package.json 120b\nsrc/\nserver/"
    private static let frontendManifest = #"{"scripts":{"build":"vite build","test":"vitest"},"dependencies":{"react":"19"},"devDependencies":{"vite":"7"}}"#
    private static let backendManifest = #"{"scripts":{"build":"tsc"},"dependencies":{"express":"5","@prisma/client":"6"},"devDependencies":{"typescript":"5","prisma":"6"}}"#
    private static let backendEntry = "import app from './app';\nimport express from 'express';\napp.listen(3000);"
    private static let backendApp = "import express from 'express';\nconst app = express();\napp.use('/health', (_req, res) => res.send('ok'));\nexport default app;"
    private static let prismaSchema = "datasource db {\n provider = \"postgresql\"\n url = env(\"DATABASE_URL\")\n}\ngenerator client {\n provider = \"prisma-client-js\"\n}"

    private static func expectation(
        tools: [String],
        inspected: [String],
        canonical: [String],
        satisfied: [ReadOnlyEvidenceRequirementKind] = [],
        remaining: [ReadOnlyEvidenceRequirementKind] = [],
        levels: [ReadOnlyEngineeringClaimLevel],
        terminal: ReadOnlyAcceptanceTerminalState = .completed,
        language: ReadOnlyResponseLanguage = .english,
        fallback: Bool = false
    ) -> ReadOnlyAcceptanceExpectation {
        ReadOnlyAcceptanceExpectation(
            workspaceScope: MissionWorkspaceScope.legacyOnly.rawValue,
            successfulTools: tools,
            inspectedPaths: inspected,
            canonicalPathsContaining: canonical,
            satisfiedRequirementsContaining: satisfied.map(\.rawValue),
            remainingRequirementsContaining: remaining.map(\.rawValue),
            evidenceLevelsContaining: levels,
            terminalState: terminal,
            reportLanguage: language,
            providerFallbackUsed: fallback
        )
    }

    static let defaultCases: [ReadOnlyAcceptanceBenchmarkCase] = [
        .init(id: "ro.01.legacy_root_listing", title: "Legacy root listing", request: "Read-only inspect the Legacy only workspace root.", steps: [.init("engineering.list_directory", path: ".", output: rootListing)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory"], inspected: [], canonical: ["package.json", "server/"], satisfied: [.projectRoot], levels: [.discovered], terminal: .completed)),
        .init(id: "ro.02.frontend_framework", title: "Frontend framework identification", request: "Read-only inspect Legacy frontend framework.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "package.json", output: frontendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["package.json"], canonical: ["package.json"], satisfied: [.frontendManifestOrConfig], levels: [.configurationConfirmed, .contentRead])),
        .init(id: "ro.03.backend_framework", title: "Backend framework identification", request: "Read-only inspect Legacy backend framework.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/package.json", output: backendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["server/package.json"], canonical: ["server/package.json"], satisfied: [.backendManifest], levels: [.configurationConfirmed, .buildNotExecuted])),
        .init(id: "ro.04.startup_entry", title: "Startup entry identification", request: "Read-only inspect the Legacy backend startup entry point.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/package.json", output: backendManifest), .init("engineering.list_directory", path: "server/src", output: "index.ts 80b\napp.ts 90b"), .init("engineering.read_file", path: "server/src/index.ts", output: backendEntry)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.list_directory", "engineering.read_file"], inspected: ["server/package.json", "server/src/index.ts"], canonical: ["server/src/index.ts", "server/src/app.ts"], satisfied: [.backendEntryPoint], levels: [.sourceBehaviorConfirmed, .referencedButNotRead])),
        .init(id: "ro.05.application_assembly", title: "Application assembly identification", request: "Read-only inspect the Legacy backend application assembly.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/package.json", output: backendManifest), .init("engineering.list_directory", path: "server/src", output: "app.ts 90b"), .init("engineering.read_file", path: "server/src/app.ts", output: backendApp)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.list_directory", "engineering.read_file"], inspected: ["server/package.json", "server/src/app.ts"], canonical: ["server/src/app.ts"], satisfied: [.backendApplicationAssembly], levels: [.contentRead])),
        .init(id: "ro.06.orm_database", title: "ORM and database distinction", request: "Read-only inspect the Legacy Prisma ORM and database schema.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/prisma/schema.prisma", output: prismaSchema)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["server/prisma/schema.prisma"], canonical: ["server/prisma/schema.prisma"], satisfied: [.databaseSchemaOrConfig], levels: [.configurationConfirmed])),
        .init(id: "ro.07.dependencies", title: "Dependency extraction", request: "Read-only inspect Legacy important dependencies.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "package.json", output: frontendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["package.json"], canonical: ["package.json"], satisfied: [.importantDependencies], levels: [.configurationConfirmed])),
        .init(id: "ro.08.build_claim", title: "Build config is not build passed", request: "Read-only inspect Legacy build scripts and configuration.", steps: [.init("engineering.list_directory", path: ".", output: "package.json 120b\ntsconfig.json 60b"), .init("engineering.read_file", path: "package.json", output: frontendManifest), .init("engineering.read_file", path: "tsconfig.json", output: #"{"compilerOptions":{"strict":true}}"#)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.read_file"], inspected: ["package.json", "tsconfig.json"], canonical: ["tsconfig.json"], levels: [.buildConfigPresent, .buildNotExecuted], terminal: .completed)),
        .init(id: "ro.09.runtime_deployment", title: "Runtime and deployment not verified", request: "Read-only inspect Legacy runtime and deployment configuration.", steps: [.init("engineering.list_directory", path: ".", output: rootListing)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory"], inspected: [], canonical: ["package.json"], levels: [.discovered], terminal: .completed)),
        .init(id: "ro.10.frontend_only", title: "Frontend-only repository", request: "Read-only inspect Legacy frontend framework and dependencies.", steps: [.init("engineering.list_directory", path: ".", output: "package.json 120b\nsrc/"), .init("engineering.read_file", path: "package.json", output: frontendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["package.json"], canonical: ["package.json"], satisfied: [.frontendManifestOrConfig, .importantDependencies], levels: [.configurationConfirmed])),
        .init(id: "ro.11.nested_backend", title: "Nested backend repository", request: "Read-only inspect Legacy backend framework under services/api.", steps: [.init("engineering.list_directory", path: ".", output: "services/\npackage.json 20b"), .init("engineering.list_directory", path: "services/api", output: "package.json 90b\nsrc/"), .init("engineering.read_file", path: "services/api/package.json", output: backendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.list_directory", "engineering.read_file"], inspected: ["services/api/package.json"], canonical: ["services/api/package.json"], satisfied: [.backendManifest], levels: [.configurationConfirmed])),
        .init(id: "ro.12.duplicate_manifests", title: "Duplicate manifest basenames", request: "Read-only inspect Legacy frontend and backend dependencies.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "package.json", output: frontendManifest), .init("engineering.read_file", path: "server/package.json", output: backendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.read_file"], inspected: ["package.json", "server/package.json"], canonical: ["package.json", "server/package.json"], satisfied: [.frontendManifestOrConfig, .backendManifest, .importantDependencies], levels: [.contentRead])),
        .init(id: "ro.13.missing_entry", title: "Missing entry candidate", request: "Read-only inspect the Legacy backend framework and startup entry point.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/package.json", output: backendManifest), .init("engineering.list_directory", path: "server/src", output: "routes.ts 40b")], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.list_directory"], inspected: ["server/package.json"], canonical: ["server/src/routes.ts"], satisfied: [.backendManifest], remaining: [.backendEntryPoint], levels: [.discovered], terminal: .partial)),
        .init(id: "ro.14.ungrounded_guess", title: "Ungrounded guessed path rejection", request: "Read-only inspect the Legacy backend startup entry point.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/package.json", output: backendManifest), .init("engineering.list_directory", path: "server/src", output: "main.ts 40b"), .init("engineering.read_file", path: "server/src/index.js", output: "", succeeded: false)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.list_directory"], inspected: ["server/package.json"], canonical: ["server/src/main.ts"], remaining: [.backendEntryPoint], levels: [.discovered], terminal: .partial)),
        .init(id: "ro.15.same_task_continuation", title: "Partial then same-task continuation", request: "Read-only inspect the Legacy backend framework, startup entry, application assembly, and dependencies.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/package.json", output: backendManifest), .init("engineering.read_file", path: "server/src/index.ts", output: backendEntry), .init("engineering.read_file", path: "server/src/app.ts", output: backendApp)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.read_file", "engineering.read_file"], inspected: ["server/package.json", "server/src/index.ts", "server/src/app.ts"], canonical: ["server/src/index.ts", "server/src/app.ts"], satisfied: [.backendEntryPoint, .backendApplicationAssembly, .importantDependencies], levels: [.sourceBehaviorConfirmed, .contentRead])),
        .init(id: "ro.16.scope_isolation", title: "Legacy-only scope isolation", request: "Read-only inspect Legacy only and do not inspect Agent.", steps: [.init("engineering.list_directory", path: ".", output: rootListing)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory"], inspected: [], canonical: ["package.json"], satisfied: [.projectRoot], levels: [.discovered])),
        .init(id: "ro.17.provider_fallback", title: "Provider and finalizer fallback", request: "Read-only inspect Legacy frontend framework.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "package.json", output: frontendManifest)], mockedProviderFallback: true, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["package.json"], canonical: ["package.json"], satisfied: [.frontendManifestOrConfig], levels: [.configurationConfirmed], fallback: true)),
        .init(id: "ro.18.chinese_report", title: "Chinese language report", request: "只读检查 Legacy 项目的前端框架和重要依赖。", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "package.json", output: frontendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["package.json"], canonical: ["package.json"], satisfied: [.frontendManifestOrConfig, .importantDependencies], levels: [.configurationConfirmed], language: .chinese)),
        .init(id: "ro.19.discovered_vs_read", title: "Discovered versus successfully read", request: "Read-only inspect the Legacy backend startup entry and application assembly.", steps: [.init("engineering.list_directory", path: ".", output: rootListing), .init("engineering.read_file", path: "server/package.json", output: backendManifest), .init("engineering.list_directory", path: "server/src", output: "index.ts 80b\napp.ts 90b"), .init("engineering.read_file", path: "server/src/index.ts", output: backendEntry)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file", "engineering.list_directory", "engineering.read_file"], inspected: ["server/package.json", "server/src/index.ts"], canonical: ["server/src/app.ts"], satisfied: [.backendEntryPoint], remaining: [.backendApplicationAssembly], levels: [.referencedButNotRead], terminal: .partial)),
        .init(id: "ro.20.sensitive_exclusion", title: "Sensitive-file exclusion", request: "Read-only inspect Legacy important dependencies.", steps: [.init("engineering.list_directory", path: ".", output: ".env 40b\npackage.json 120b"), .init("engineering.read_file", path: ".env", output: "", succeeded: false), .init("engineering.read_file", path: "package.json", output: frontendManifest)], mockedProviderFallback: false, expectation: expectation(tools: ["engineering.list_directory", "engineering.read_file"], inspected: ["package.json"], canonical: ["package.json"], satisfied: [.importantDependencies], levels: [.contentRead]))
    ]
}
