import Foundation

enum EngineeringActionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case readFile = "read_file"
    case searchCode = "search_code"
    case editFile = "edit_file"
    case runCommand = "run_command"
    case runTests = "run_tests"
    case inspectGitState = "inspect_git_state"

    var id: String { rawValue }
}

enum EngineeringLoopStage: String, Codable, CaseIterable, Identifiable, Sendable {
    case inspect
    case planChange = "plan_change"
    case approvalRequest = "approval_request"
    case modify
    case runValidation = "run_validation"
    case observeFailure = "observe_failure"
    case repair
    case validateAgain = "validate_again"
    case completed

    var id: String { rawValue }
}

enum EngineeringGovernanceStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case allowed
    case approvalRequired = "approval_required"
    case denied

    var id: String { rawValue }
}

struct EngineeringCommand: Codable, Hashable, Sendable {
    var command: String
    var arguments: [String]
    var workingDirectory: String?

    init(command: String, arguments: [String] = [], workingDirectory: String? = nil) {
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }
}

struct EngineeringValidationStep: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var command: EngineeringCommand
    var purpose: String

    init(id: UUID = UUID(), command: EngineeringCommand, purpose: String) {
        self.id = id
        self.command = command
        self.purpose = purpose
    }

    var isTest: Bool {
        let text = "\(purpose) \(command.command) \(command.arguments.joined(separator: " "))".lowercased()
        return text.contains("test") || text.contains("xctest") || text.contains("swift test")
    }
}

struct EngineeringPlannedEdit: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var path: String
    var newContents: String
    var summary: String

    init(id: UUID = UUID(), path: String, newContents: String, summary: String) {
        self.id = id
        self.path = path
        self.newContents = newContents
        self.summary = summary
    }
}

struct EngineeringChangePlan: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var objective: String
    var targetFiles: [String]
    var expectedChanges: [String]
    var validationPlan: [EngineeringValidationStep]
    var plannedEdits: [EngineeringPlannedEdit]
    var repairEdits: [EngineeringPlannedEdit]
    var riskAssessment: RiskAssessment

    init(
        id: UUID = UUID(),
        objective: String,
        targetFiles: [String],
        expectedChanges: [String],
        validationPlan: [EngineeringValidationStep],
        plannedEdits: [EngineeringPlannedEdit] = [],
        repairEdits: [EngineeringPlannedEdit] = [],
        riskAssessment: RiskAssessment? = nil
    ) {
        self.id = id
        self.objective = objective
        self.targetFiles = targetFiles
        self.expectedChanges = expectedChanges
        self.validationPlan = validationPlan
        self.plannedEdits = plannedEdits
        self.repairEdits = repairEdits
        self.riskAssessment = riskAssessment ?? EngineeringRiskAssessor().assess(
            objective: objective,
            targetFiles: targetFiles,
            expectedChanges: expectedChanges,
            validationPlan: validationPlan
        )
    }

    var requiresApproval: Bool {
        riskAssessment.requiresApproval
    }
}

struct EngineeringActionResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: EngineeringActionKind
    var success: Bool
    var target: String
    var output: String
    var files: [String]
    var command: EngineeringCommand?
    var exitCode: Int?
    var evidence: EvidenceRecord

    init(
        id: UUID = UUID(),
        kind: EngineeringActionKind,
        success: Bool,
        target: String,
        output: String,
        files: [String] = [],
        command: EngineeringCommand? = nil,
        exitCode: Int? = nil,
        evidence: EvidenceRecord
    ) {
        self.id = id
        self.kind = kind
        self.success = success
        self.target = target
        self.output = output
        self.files = files
        self.command = command
        self.exitCode = exitCode
        self.evidence = evidence
    }
}

struct EngineeringSearchMatch: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(path):\(line)" }
    var path: String
    var line: Int
    var preview: String
}

struct EngineeringSearchResult: Codable, Hashable, Sendable {
    var query: String
    var matches: [EngineeringSearchMatch]
    var evidence: EvidenceRecord
}

struct EngineeringCommandOutput: Codable, Hashable, Sendable {
    var command: EngineeringCommand
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

struct EngineeringGovernanceDecision: Codable, Hashable, Sendable {
    var status: EngineeringGovernanceStatus
    var riskAssessment: RiskAssessment
    var approvalRequest: ApprovalRequest?
    var evidence: EvidenceRecord
}

struct EngineeringLoopStageResult: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var stage: EngineeringLoopStage
    var success: Bool
    var summary: String
    var evidence: [EvidenceRecord]

    init(
        id: UUID = UUID(),
        stage: EngineeringLoopStage,
        success: Bool,
        summary: String,
        evidence: [EvidenceRecord]
    ) {
        self.id = id
        self.stage = stage
        self.success = success
        self.summary = summary
        self.evidence = evidence
    }
}

struct EngineeringReplayRecord: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var objective: String
    var targetFiles: [String]
    var expectedChanges: [String]
    var riskLevel: RiskSeverity
    var stageTransitions: [EngineeringLoopStage]
    var approvals: [String]
    var actions: [String]
    var evidence: [EvidenceRecord]
    var outcome: String
    var reconstructedAt: Date

    var isAuditComplete: Bool {
        !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !targetFiles.isEmpty
            && !stageTransitions.isEmpty
            && !actions.isEmpty
            && !evidence.isEmpty
            && !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func reconstruct(
        objective: String,
        plan: EngineeringChangePlan,
        stages: [EngineeringLoopStageResult],
        governanceDecision: EngineeringGovernanceDecision? = nil,
        outcome: String,
        reconstructedAt: Date = Date()
    ) -> EngineeringReplayRecord {
        let evidence = stages.flatMap(\.evidence)
        let approvals = [governanceDecision?.approvalRequest]
            .compactMap { request -> String? in
                guard let request else { return nil }
                return "\(request.state.rawValue):\(request.action):\(request.riskLevel.rawValue)"
            }
        return EngineeringReplayRecord(
            id: UUID(),
            objective: objective,
            targetFiles: plan.targetFiles,
            expectedChanges: plan.expectedChanges,
            riskLevel: plan.riskAssessment.level,
            stageTransitions: stages.map(\.stage),
            approvals: approvals,
            actions: evidence.map(\.action),
            evidence: evidence,
            outcome: outcome,
            reconstructedAt: reconstructedAt
        )
    }
}

struct EngineeringLoopResult: Codable, Hashable, Sendable {
    var plan: EngineeringChangePlan
    var governanceDecision: EngineeringGovernanceDecision
    var stages: [EngineeringLoopStageResult]
    var evidence: [EvidenceRecord]
    var validationPassed: Bool
    var approvalRequired: Bool
    var replay: EngineeringReplayRecord
}

struct EngineeringActivitySnapshot: Codable, Hashable, Sendable {
    var filesInspected: [String]
    var changesProposed: [String]
    var testsRunning: Bool
    var validationResults: [String]
    var evidenceRecords: [EvidenceRecord]
    var currentStage: EngineeringLoopStage?
    var riskLevel: RiskSeverity

    static let empty = EngineeringActivitySnapshot(
        filesInspected: [],
        changesProposed: [],
        testsRunning: false,
        validationResults: ["No engineering activity recorded."],
        evidenceRecords: [],
        currentStage: nil,
        riskLevel: .low
    )
}

enum EngineeringConnectorError: LocalizedError, Equatable {
    case pathOutsideWorkspace(String)
    case fileNotFound(String)
    case nonUTF8File(String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideWorkspace(let path):
            return "Path is outside the engineering workspace: \(path)"
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .nonUTF8File(let path):
            return "File is not valid UTF-8: \(path)"
        }
    }
}

protocol EngineeringCommandRunning: Sendable {
    func run(command: EngineeringCommand, workingDirectory: URL) async throws -> EngineeringCommandOutput
}

protocol EngineeringConnector: Sendable {
    var workspaceRoot: URL { get }

    func readFile(_ path: String) async throws -> EngineeringActionResult
    func searchCode(_ query: String, fileExtensions: [String]) async throws -> EngineeringSearchResult
    func editFile(_ edit: EngineeringPlannedEdit) async throws -> EngineeringActionResult
    func runCommand(_ command: EngineeringCommand) async throws -> EngineeringActionResult
    func runTests(_ command: EngineeringCommand) async throws -> EngineeringActionResult
    func inspectGitState() async throws -> EngineeringActionResult
}

struct ProcessEngineeringCommandRunner: EngineeringCommandRunning {
    func run(command: EngineeringCommand, workingDirectory: URL) async throws -> EngineeringCommandOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command.command] + command.arguments
                process.currentDirectoryURL = workingDirectory
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(
                        returning: EngineeringCommandOutput(
                            command: command,
                            exitCode: process.terminationStatus,
                            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                            stderr: String(data: stderrData, encoding: .utf8) ?? ""
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

struct LocalEngineeringConnector: EngineeringConnector {
    let workspaceRoot: URL
    private let commandRunner: any EngineeringCommandRunning

    init(workspaceRoot: URL, commandRunner: any EngineeringCommandRunning = ProcessEngineeringCommandRunner()) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.commandRunner = commandRunner
    }

    func readFile(_ path: String) async throws -> EngineeringActionResult {
        let url = try validatedURL(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EngineeringConnectorError.fileNotFound(path)
        }
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard byteCount <= 512_000 else {
            throw ToolExecutionError.processFailed("engineering.read_file exceeds the 512000-byte read limit for \(path)")
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw EngineeringConnectorError.nonUTF8File(path)
        }
        let relativePath = relativePath(for: url)
        return actionResult(
            kind: .readFile,
            success: true,
            target: relativePath,
            output: contents,
            files: [relativePath],
            validation: .valid,
            resultSummary: "Read \(relativePath) (\(contents.count) characters)."
        )
    }

    func searchCode(_ query: String, fileExtensions: [String] = []) async throws -> EngineeringSearchResult {
        let normalizedExtensions = Set(fileExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        let model = try CodebaseIntelligence(maxFiles: 2_000).discover(rootPath: workspaceRoot.path)
        var matches: [EngineeringSearchMatch] = []
        for file in model.files where normalizedExtensions.isEmpty || normalizedExtensions.contains(file.fileExtension ?? "") {
            let url = workspaceRoot.appendingPathComponent(file.path)
            guard file.byteCount <= 512_000, let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (offset, line) in contents.components(separatedBy: .newlines).enumerated() where line.localizedCaseInsensitiveContains(query) {
                matches.append(
                    EngineeringSearchMatch(
                        path: file.path,
                        line: offset + 1,
                        preview: line.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                )
            }
        }
        return EngineeringSearchResult(
            query: query,
            matches: matches,
            evidence: EvidenceRecord(
                action: "engineering.search_code:\(query)",
                source: "EngineeringConnector",
                result: "Found \(matches.count) match\(matches.count == 1 ? "" : "es").",
                validation: .valid
            )
        )
    }

    func editFile(_ edit: EngineeringPlannedEdit) async throws -> EngineeringActionResult {
        let url = try validatedURL(for: edit.path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try edit.newContents.write(to: url, atomically: true, encoding: .utf8)
        let relativePath = relativePath(for: url)
        return actionResult(
            kind: .editFile,
            success: true,
            target: relativePath,
            output: edit.summary,
            files: [relativePath],
            validation: .valid,
            resultSummary: "Edited \(relativePath): \(edit.summary)"
        )
    }

    func runCommand(_ command: EngineeringCommand) async throws -> EngineeringActionResult {
        let workingDirectory = try validatedWorkingDirectory(command.workingDirectory)
        let output = try await commandRunner.run(command: command, workingDirectory: workingDirectory)
        let summary = commandSummary(output)
        return actionResult(
            kind: .runCommand,
            success: output.exitCode == 0,
            target: workingDirectory.path,
            output: summary,
            command: command,
            exitCode: Int(output.exitCode),
            validation: output.exitCode == 0 ? .valid : .failed,
            resultSummary: summary
        )
    }

    func runTests(_ command: EngineeringCommand) async throws -> EngineeringActionResult {
        let workingDirectory = try validatedWorkingDirectory(command.workingDirectory)
        let output = try await commandRunner.run(command: command, workingDirectory: workingDirectory)
        let summary = commandSummary(output)
        return actionResult(
            kind: .runTests,
            success: output.exitCode == 0,
            target: workingDirectory.path,
            output: summary,
            command: command,
            exitCode: Int(output.exitCode),
            validation: output.exitCode == 0 ? .valid : .failed,
            resultSummary: summary
        )
    }

    func inspectGitState() async throws -> EngineeringActionResult {
        let gitDirectory = workspaceRoot.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDirectory.path) else {
            return actionResult(
                kind: .inspectGitState,
                success: true,
                target: workspaceRoot.path,
                output: "No git repository detected.",
                validation: .warning,
                resultSummary: "No git repository detected."
            )
        }
        let command = EngineeringCommand(command: "git", arguments: ["status", "--short"])
        let output = try await commandRunner.run(command: command, workingDirectory: workspaceRoot)
        let summary = commandSummary(output)
        return actionResult(
            kind: .inspectGitState,
            success: output.exitCode == 0,
            target: workspaceRoot.path,
            output: summary,
            command: command,
            exitCode: Int(output.exitCode),
            validation: output.exitCode == 0 ? .valid : .failed,
            resultSummary: summary
        )
    }

    private func actionResult(
        kind: EngineeringActionKind,
        success: Bool,
        target: String,
        output: String,
        files: [String] = [],
        command: EngineeringCommand? = nil,
        exitCode: Int? = nil,
        validation: EvidenceValidationStatus,
        resultSummary: String
    ) -> EngineeringActionResult {
        EngineeringActionResult(
            kind: kind,
            success: success,
            target: target,
            output: output,
            files: files,
            command: command,
            exitCode: exitCode,
            evidence: EvidenceRecord(
                action: "engineering.\(kind.rawValue):\(target)",
                source: "EngineeringConnector",
                result: resultSummary,
                validation: validation
            )
        )
    }

    private func commandSummary(_ output: EngineeringCommandOutput) -> String {
        let combined = [output.stdout, output.stderr]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if combined.isEmpty {
            return "Command \(output.command.command) exited with \(output.exitCode)."
        }
        return combined
    }

    private func validatedWorkingDirectory(_ path: String?) throws -> URL {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return workspaceRoot
        }
        return try validatedURL(for: path)
    }

    private func validatedURL(for path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : workspaceRoot.appendingPathComponent(trimmed)
        let standardized = secureCanonicalURL(candidate)
        let root = secureCanonicalURL(workspaceRoot)
        guard standardized.path == root.path || standardized.path.hasPrefix(root.path + "/") else {
            throw EngineeringConnectorError.pathOutsideWorkspace(path)
        }
        return standardized
    }

    private func secureCanonicalURL(_ url: URL) -> URL {
        let standardized = url.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardized.path) {
            return standardized.resolvingSymlinksInPath().standardizedFileURL
        }
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        return parent.appendingPathComponent(standardized.lastPathComponent).standardizedFileURL
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = workspaceRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath) else { return path }
        var relative = String(path.dropFirst(rootPath.count))
        if relative.hasPrefix("/") {
            relative.removeFirst()
        }
        return relative
    }
}

struct EngineeringRiskAssessor: Sendable {
    func assess(
        objective: String,
        targetFiles: [String],
        expectedChanges: [String],
        validationPlan: [EngineeringValidationStep]
    ) -> RiskAssessment {
        let text = ([objective] + targetFiles + expectedChanges + validationPlan.map(\.purpose))
            .joined(separator: " ")
            .lowercased()
        let input = RiskAssessmentInput(
            productionImpact: productionImpact(from: text),
            dataSensitivity: dataSensitivity(from: text),
            reversibility: reversibility(from: text, targetFiles: targetFiles),
            permissionLevel: permissionLevel(from: text, targetFiles: targetFiles)
        )
        return RiskAssessmentEngine().assess(input)
    }

    private func productionImpact(from text: String) -> ProductionImpact {
        if containsAny(text, ["prod", "production", "deploy", "release", "live", "customer-facing"]) {
            return .production
        }
        if containsAny(text, ["staging", "shared", "integration", "ci", "workflow"]) {
            return .limited
        }
        return .none
    }

    private func dataSensitivity(from text: String) -> DataSensitivity {
        if containsAny(text, ["pci", "hipaa", "phi", "pii", "ssn", "regulated"]) {
            return .regulated
        }
        if containsAny(text, ["secret", "token", "credential", "customer", "database", "payment"]) {
            return .confidential
        }
        if containsAny(text, ["config", "internal", "log"]) {
            return .internalUse
        }
        return .publicData
    }

    private func reversibility(from text: String, targetFiles: [String]) -> ActionReversibility {
        if containsAny(text, ["drop database", "irreversible", "purge", "wipe"]) {
            return .irreversible
        }
        if containsAny(text, ["delete", "remove", "migration", "schema", "chmod", "chown"]) {
            return .destructive
        }
        if !targetFiles.isEmpty || containsAny(text, ["edit", "write", "modify", "create", "update"]) {
            return .recoverable
        }
        return .reversible
    }

    private func permissionLevel(from text: String, targetFiles: [String]) -> PermissionLevel {
        if containsAny(text, ["sudo", "root", "admin", "owner"]) {
            return .admin
        }
        if targetFiles.contains(where: isElevatedPath) || containsAny(text, ["deploy", "production", "secret", "credential"]) {
            return .elevated
        }
        if targetFiles.isEmpty {
            return .readOnly
        }
        return .standard
    }

    private func isElevatedPath(_ path: String) -> Bool {
        let lowercased = path.lowercased()
        return lowercased.contains(".github/")
            || lowercased.contains("package.swift")
            || lowercased.contains("dockerfile")
            || lowercased.contains("production")
            || lowercased.contains("deploy")
            || lowercased.contains("migration")
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }
}

struct EngineeringChangePlanner: Sendable {
    func plan(
        objective: String,
        codebase: CodebaseModel,
        targetFiles: [String],
        expectedChanges: [String],
        validationPlan: [EngineeringValidationStep],
        plannedEdits: [EngineeringPlannedEdit] = [],
        repairEdits: [EngineeringPlannedEdit] = []
    ) -> EngineeringChangePlan {
        let knownFiles = Set(codebase.files.map(\.path))
        let normalizedTargets = targetFiles.map { target in
            knownFiles.contains(target) ? target : target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return EngineeringChangePlan(
            objective: objective,
            targetFiles: normalizedTargets,
            expectedChanges: expectedChanges,
            validationPlan: validationPlan,
            plannedEdits: plannedEdits,
            repairEdits: repairEdits
        )
    }
}

struct EngineeringGovernanceGate: Sendable {
    func evaluate(
        plan: EngineeringChangePlan,
        workspace: Workspace? = nil,
        approved: Bool = false,
        now: Date = Date()
    ) -> EngineeringGovernanceDecision {
        if shouldDeny(plan) {
            return decision(
                status: .denied,
                plan: plan,
                workspace: workspace,
                now: now,
                reason: "Denied critical irreversible production code change without sufficient validation controls."
            )
        }
        if plan.requiresApproval && !approved {
            return decision(
                status: .approvalRequired,
                plan: plan,
                workspace: workspace,
                now: now,
                reason: "Approval required for \(plan.riskAssessment.level.rawValue) engineering change."
            )
        }
        return decision(
            status: .allowed,
            plan: plan,
            workspace: workspace,
            now: now,
            reason: "Engineering change allowed by governance gate."
        )
    }

    private func shouldDeny(_ plan: EngineeringChangePlan) -> Bool {
        let text = ([plan.objective] + plan.targetFiles + plan.expectedChanges)
            .joined(separator: " ")
            .lowercased()
        return plan.riskAssessment.level == .critical
            && plan.validationPlan.isEmpty
            && (text.contains("drop database") || text.contains("purge") || text.contains("wipe"))
    }

    private func decision(
        status: EngineeringGovernanceStatus,
        plan: EngineeringChangePlan,
        workspace: Workspace?,
        now: Date,
        reason: String
    ) -> EngineeringGovernanceDecision {
        let approval = approvalRequest(status: status, plan: plan, workspace: workspace, now: now)
        return EngineeringGovernanceDecision(
            status: status,
            riskAssessment: plan.riskAssessment,
            approvalRequest: approval,
            evidence: EvidenceRecord(
                action: "engineering.governance:\(status.rawValue)",
                source: "EngineeringGovernanceGate",
                result: reason,
                validation: status == .denied ? .failed : (status == .approvalRequired ? .warning : .valid)
            )
        )
    }

    private func approvalRequest(
        status: EngineeringGovernanceStatus,
        plan: EngineeringChangePlan,
        workspace: Workspace?,
        now: Date
    ) -> ApprovalRequest? {
        guard status == .approvalRequired, let workspace else { return nil }
        return ApprovalRequest(
            id: UUID(),
            workspaceID: workspace.id,
            taskID: nil,
            stepID: nil,
            toolCallID: nil,
            targetKind: .systemChange,
            action: "engineering.code_change",
            resource: plan.targetFiles.joined(separator: ", "),
            riskLevel: plan.riskAssessment.level,
            state: .pending,
            requestedByRole: workspace.role,
            decidedByRole: nil,
            decisionReason: nil,
            requestedAt: now,
            decidedAt: nil,
            expiresAt: now.addingTimeInterval(30 * 60),
            metadata: [
                "engineering_plan_id": plan.id.uuidString,
                "objective": plan.objective,
                "expected_changes": plan.expectedChanges.joined(separator: " | ")
            ]
        )
    }
}

struct AutonomousEngineeringLoop: Sendable {
    func run(
        plan: EngineeringChangePlan,
        connector: any EngineeringConnector,
        workspace: Workspace? = nil,
        approved: Bool = false
    ) async -> EngineeringLoopResult {
        let governance = EngineeringGovernanceGate().evaluate(plan: plan, workspace: workspace, approved: approved)
        var stages: [EngineeringLoopStageResult] = []

        let inspectionEvidence = await inspect(plan: plan, connector: connector)
        stages.append(
            EngineeringLoopStageResult(
                stage: .inspect,
                success: !inspectionEvidence.contains { $0.validation == .failed },
                summary: "Inspected \(plan.targetFiles.count) target file\(plan.targetFiles.count == 1 ? "" : "s").",
                evidence: inspectionEvidence
            )
        )

        stages.append(
            EngineeringLoopStageResult(
                stage: .planChange,
                success: governance.status != .denied,
                summary: "Planned \(plan.expectedChanges.count) change\(plan.expectedChanges.count == 1 ? "" : "s") with \(plan.riskAssessment.level.rawValue) risk.",
                evidence: [governance.evidence]
            )
        )

        if governance.status == .approvalRequired {
            stages.append(
                EngineeringLoopStageResult(
                    stage: .approvalRequest,
                    success: false,
                    summary: "Waiting for approval before editing.",
                    evidence: [governance.evidence]
                )
            )
            return result(plan: plan, governance: governance, stages: stages, validationPassed: false, outcome: "approval_required")
        }

        if governance.status == .denied {
            return result(plan: plan, governance: governance, stages: stages, validationPassed: false, outcome: "denied")
        }

        let modificationEvidence = await apply(edits: plan.plannedEdits, connector: connector, stage: .modify)
        stages.append(
            EngineeringLoopStageResult(
                stage: .modify,
                success: !modificationEvidence.contains { $0.validation == .failed },
                summary: "Applied \(plan.plannedEdits.count) planned edit\(plan.plannedEdits.count == 1 ? "" : "s").",
                evidence: modificationEvidence
            )
        )

        let validation = await validate(plan: plan, connector: connector)
        stages.append(
            EngineeringLoopStageResult(
                stage: .runValidation,
                success: validation.passed,
                summary: validation.summary,
                evidence: validation.evidence
            )
        )

        if validation.passed {
            stages.append(completedStage(summary: "Engineering validation passed."))
            return result(plan: plan, governance: governance, stages: stages, validationPassed: true, outcome: "validated")
        }

        stages.append(
            EngineeringLoopStageResult(
                stage: .observeFailure,
                success: true,
                summary: "Observed validation failure and prepared repair path.",
                evidence: [
                    EvidenceRecord(
                        action: "engineering.observe_failure",
                        source: "AutonomousEngineeringLoop",
                        result: validation.summary,
                        validation: .warning
                    )
                ]
            )
        )

        guard !plan.repairEdits.isEmpty else {
            stages.append(completedStage(summary: "Validation failed and no repair edit was available.", validation: .failed))
            return result(plan: plan, governance: governance, stages: stages, validationPassed: false, outcome: "validation_failed")
        }

        let repairEvidence = await apply(edits: plan.repairEdits, connector: connector, stage: .repair)
        stages.append(
            EngineeringLoopStageResult(
                stage: .repair,
                success: !repairEvidence.contains { $0.validation == .failed },
                summary: "Applied \(plan.repairEdits.count) repair edit\(plan.repairEdits.count == 1 ? "" : "s").",
                evidence: repairEvidence
            )
        )

        let repairedValidation = await validate(plan: plan, connector: connector)
        stages.append(
            EngineeringLoopStageResult(
                stage: .validateAgain,
                success: repairedValidation.passed,
                summary: repairedValidation.summary,
                evidence: repairedValidation.evidence
            )
        )
        stages.append(
            completedStage(
                summary: repairedValidation.passed ? "Repair validated successfully." : "Repair did not pass validation.",
                validation: repairedValidation.passed ? .valid : .failed
            )
        )
        return result(
            plan: plan,
            governance: governance,
            stages: stages,
            validationPassed: repairedValidation.passed,
            outcome: repairedValidation.passed ? "repaired_and_validated" : "repair_failed"
        )
    }

    private func inspect(plan: EngineeringChangePlan, connector: any EngineeringConnector) async -> [EvidenceRecord] {
        guard !plan.targetFiles.isEmpty else {
            return [
                EvidenceRecord(
                    action: "engineering.inspect",
                    source: "AutonomousEngineeringLoop",
                    result: "No target files supplied.",
                    validation: .warning
                )
            ]
        }

        var evidence: [EvidenceRecord] = []
        for file in plan.targetFiles {
            do {
                evidence.append(try await connector.readFile(file).evidence)
            } catch {
                evidence.append(failureEvidence(action: "engineering.inspect:\(file)", error: error))
            }
        }
        return evidence
    }

    private func apply(
        edits: [EngineeringPlannedEdit],
        connector: any EngineeringConnector,
        stage: EngineeringLoopStage
    ) async -> [EvidenceRecord] {
        guard !edits.isEmpty else {
            return [
                EvidenceRecord(
                    action: "engineering.\(stage.rawValue)",
                    source: "AutonomousEngineeringLoop",
                    result: "No edits scheduled for \(stage.rawValue).",
                    validation: .warning
                )
            ]
        }

        var evidence: [EvidenceRecord] = []
        for edit in edits {
            do {
                evidence.append(try await connector.editFile(edit).evidence)
            } catch {
                evidence.append(failureEvidence(action: "engineering.\(stage.rawValue):\(edit.path)", error: error))
            }
        }
        return evidence
    }

    private func validate(
        plan: EngineeringChangePlan,
        connector: any EngineeringConnector
    ) async -> (passed: Bool, summary: String, evidence: [EvidenceRecord]) {
        guard !plan.validationPlan.isEmpty else {
            let evidence = EvidenceRecord(
                action: "engineering.run_validation",
                source: "AutonomousEngineeringLoop",
                result: "No validation command supplied.",
                validation: .warning
            )
            return (true, "No validation command supplied.", [evidence])
        }

        var evidence: [EvidenceRecord] = []
        var passed = true
        for step in plan.validationPlan {
            do {
                let result = step.isTest
                    ? try await connector.runTests(step.command)
                    : try await connector.runCommand(step.command)
                evidence.append(result.evidence)
                passed = passed && result.success
            } catch {
                passed = false
                evidence.append(failureEvidence(action: "engineering.validation:\(step.command.command)", error: error))
            }
        }

        let summary = passed
            ? "Validation passed for \(plan.validationPlan.count) step\(plan.validationPlan.count == 1 ? "" : "s")."
            : "Validation failed for at least one step."
        return (passed, summary, evidence)
    }

    private func completedStage(summary: String, validation: EvidenceValidationStatus = .valid) -> EngineeringLoopStageResult {
        EngineeringLoopStageResult(
            stage: .completed,
            success: validation != .failed,
            summary: summary,
            evidence: [
                EvidenceRecord(
                    action: "engineering.completed",
                    source: "AutonomousEngineeringLoop",
                    result: summary,
                    validation: validation
                )
            ]
        )
    }

    private func result(
        plan: EngineeringChangePlan,
        governance: EngineeringGovernanceDecision,
        stages: [EngineeringLoopStageResult],
        validationPassed: Bool,
        outcome: String
    ) -> EngineeringLoopResult {
        let replay = EngineeringReplayRecord.reconstruct(
            objective: plan.objective,
            plan: plan,
            stages: stages,
            governanceDecision: governance,
            outcome: outcome
        )
        return EngineeringLoopResult(
            plan: plan,
            governanceDecision: governance,
            stages: stages,
            evidence: stages.flatMap(\.evidence),
            validationPassed: validationPassed,
            approvalRequired: governance.status == .approvalRequired,
            replay: replay
        )
    }

    private func failureEvidence(action: String, error: Error) -> EvidenceRecord {
        EvidenceRecord(
            action: action,
            source: "AutonomousEngineeringLoop",
            result: error.localizedDescription,
            validation: .failed
        )
    }
}

struct EngineeringActivityProjector: Sendable {
    func snapshot(codebase: CodebaseModel) -> EngineeringActivitySnapshot {
        EngineeringActivitySnapshot(
            filesInspected: Array(codebase.files.prefix(6).map(\.path)),
            changesProposed: codebase.changeImpacts.isEmpty
                ? []
                : codebase.changeImpacts.prefix(4).map { "\($0.changedPath): \($0.reasons.joined(separator: " "))" },
            testsRunning: false,
            validationResults: [
                "Repository \(codebase.repositoryName): \(codebase.files.count) files, \(codebase.symbols.count) symbols, \(codebase.dependencies.count) dependencies."
            ],
            evidenceRecords: [codebase.evidence],
            currentStage: .inspect,
            riskLevel: codebase.changeImpacts.map(\.riskLevel).maxByGovernanceRank() ?? .low
        )
    }

    func snapshot(plan: EngineeringChangePlan, result: EngineeringLoopResult? = nil) -> EngineeringActivitySnapshot {
        let stages = result?.stages ?? []
        let validationResults = stages
            .filter { $0.stage == .runValidation || $0.stage == .validateAgain || $0.stage == .completed }
            .map(\.summary)
        return EngineeringActivitySnapshot(
            filesInspected: plan.targetFiles,
            changesProposed: plan.expectedChanges,
            testsRunning: stages.last?.stage == .runValidation,
            validationResults: validationResults.isEmpty ? plan.validationPlan.map(\.purpose) : validationResults,
            evidenceRecords: result?.evidence ?? [],
            currentStage: stages.last?.stage ?? .planChange,
            riskLevel: plan.riskAssessment.level
        )
    }
}

private extension Array where Element == RiskSeverity {
    func maxByGovernanceRank() -> RiskSeverity? {
        self.max { $0.governanceRank < $1.governanceRank }
    }
}
