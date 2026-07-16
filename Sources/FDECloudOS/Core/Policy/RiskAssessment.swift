import Foundation

enum ProductionImpact: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case limited
    case production

    var id: String { rawValue }
}

enum DataSensitivity: String, Codable, CaseIterable, Identifiable, Sendable {
    case publicData = "public"
    case internalUse = "internal"
    case confidential
    case regulated

    var id: String { rawValue }
}

enum ActionReversibility: String, Codable, CaseIterable, Identifiable, Sendable {
    case reversible
    case recoverable
    case destructive
    case irreversible

    var id: String { rawValue }
}

enum PermissionLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case readOnly = "read_only"
    case standard
    case elevated
    case admin

    var id: String { rawValue }
}

struct RiskAssessmentInput: Codable, Hashable, Sendable {
    var productionImpact: ProductionImpact
    var dataSensitivity: DataSensitivity
    var reversibility: ActionReversibility
    var permissionLevel: PermissionLevel
}

struct RiskAssessment: Codable, Hashable, Sendable {
    var level: RiskSeverity
    var score: Int
    var input: RiskAssessmentInput
    var reasons: [String]

    var requiresApproval: Bool {
        level.governanceRank >= RiskSeverity.high.governanceRank
    }

    var classification: RiskClassification {
        RiskClassification(level: level, reasons: reasons, requiresApproval: requiresApproval)
    }

    var policyEnvironment: String {
        input.productionImpact == .production ? "production" : "workspace"
    }

    var auditPayload: [String: String] {
        [
            "risk_assessment_level": level.rawValue,
            "risk_assessment_score": String(score),
            "risk_assessment_production_impact": input.productionImpact.rawValue,
            "risk_assessment_data_sensitivity": input.dataSensitivity.rawValue,
            "risk_assessment_reversibility": input.reversibility.rawValue,
            "risk_assessment_permission_level": input.permissionLevel.rawValue,
            "risk_assessment_reasons": reasons.joined(separator: " | ")
        ]
    }
}

struct RiskAssessmentEngine: Sendable {
    func assess(_ input: RiskAssessmentInput) -> RiskAssessment {
        let score = score(for: input)
        let level = level(for: score, input: input)
        return RiskAssessment(level: level, score: score, input: input, reasons: reasons(for: input, level: level))
    }

    func assess(
        step: PlanStep,
        toolCall: ToolCall,
        workspace: Workspace,
        globalPolicy: GlobalExecutionPolicy? = nil,
        systemFailureProfile: SystemFailureProfile? = nil,
        governorDecision: GlobalGovernorDecision? = nil,
        policyDeltas: [ExecutionPolicyDelta] = [],
        plannerRisks: [RiskSignal] = []
    ) -> RiskAssessment {
        let text = normalizedText(step: step, toolCall: toolCall)
        var assessment = assess(
            RiskAssessmentInput(
                productionImpact: productionImpact(from: text),
                dataSensitivity: dataSensitivity(from: text),
                reversibility: reversibility(from: text, toolCall: toolCall),
                permissionLevel: permissionLevel(from: text, toolCall: toolCall)
            )
        )

        if let plannerSeverity = plannerRisks.map(\.severity).max(by: {
            $0.governanceRank < $1.governanceRank
        }) {
            assessment = assessment.raised(
                to: plannerSeverity,
                reason: "Planner reported a \(plannerSeverity.rawValue) mission risk; action impact remains classified from the concrete step and tool call."
            )
        }

        if step.requiresApproval || toolCall.requiresApproval {
            assessment = assessment.raised(to: .high, reason: "Planner or tool marked this action as requiring approval.")
        }

        if toolCall.type == .connector
            || (toolCall.type == .api && !isReadOnlyWorkspaceAPI(toolCall.command)) {
            assessment = assessment.raised(to: .high, reason: "External system operation requires elevated governance.")
        }

        if workspace.role == .user && assessment.level.governanceRank >= RiskSeverity.medium.governanceRank {
            assessment = assessment.raised(to: .high, reason: "User role cannot bypass elevated action controls.")
        }

        if globalPolicy?.avoidedToolCommands.contains(toolCall.command) == true
            || policyDeltas.contains(where: { $0.avoidToolCommand == toolCall.command }) {
            assessment = assessment.raised(to: .high, reason: "Execution policy marks this tool as avoided.")
        }

        if let cluster = systemFailureProfile?.clusters.first(where: { $0.toolCommand == toolCall.command }) {
            assessment = assessment.raised(
                to: cluster.frequency >= 2 ? .high : .medium,
                reason: "Failure history contains \(cluster.frequency) prior occurrence(s) for this tool."
            )
        }

        if governorDecision?.selectedStrategy == .conservativeRecovery || governorDecision?.overrides.isEmpty == false {
            assessment = assessment.raised(to: .medium, reason: "Governor selected a cautious or overridden execution strategy.")
        }

        if assessment.input.productionImpact == .production,
           assessment.input.reversibility == .irreversible || assessment.input.reversibility == .destructive {
            assessment = assessment.raised(to: .critical, reason: "Production-impacting destructive action is critical risk.")
        }

        return assessment
    }

    private func score(for input: RiskAssessmentInput) -> Int {
        productionScore(input.productionImpact)
            + dataScore(input.dataSensitivity)
            + reversibilityScore(input.reversibility)
            + permissionScore(input.permissionLevel)
    }

    private func level(for score: Int, input: RiskAssessmentInput) -> RiskSeverity {
        if input.productionImpact == .production,
           input.reversibility == .irreversible || input.reversibility == .destructive {
            return .critical
        }
        if input.dataSensitivity == .regulated && input.permissionLevel.governanceRank >= PermissionLevel.elevated.governanceRank {
            return .critical
        }
        if score >= 9 { return .critical }
        if score >= 6 { return .high }
        if score >= 3 { return .medium }
        return .low
    }

    private func reasons(for input: RiskAssessmentInput, level: RiskSeverity) -> [String] {
        var values = ["Risk assessed as \(level.rawValue.uppercased())."]
        if input.productionImpact == .production {
            values.append("Action can affect production.")
        }
        if input.dataSensitivity.governanceRank >= DataSensitivity.confidential.governanceRank {
            values.append("Action can access sensitive data.")
        }
        if input.reversibility.governanceRank >= ActionReversibility.destructive.governanceRank {
            values.append("Action has limited reversibility.")
        }
        if input.permissionLevel.governanceRank >= PermissionLevel.elevated.governanceRank {
            values.append("Action requires elevated permissions.")
        }
        return values
    }

    private func normalizedText(step: PlanStep, toolCall: ToolCall) -> String {
        [
            step.title,
            step.intent,
            toolCall.command,
            toolCall.arguments.joined(separator: " "),
            toolCall.workingDirectory ?? ""
        ]
        .joined(separator: " ")
        .lowercased()
    }

    private func productionImpact(from text: String) -> ProductionImpact {
        let tokens = Set(
            text.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )
        if !tokens.isDisjoint(with: ["prod", "production", "live"])
            || containsAny(text, ["customer-facing", "deploy", "release", "kubectl", "gcloud run deploy", "terraform apply"]) {
            return .production
        }
        if containsAny(text, ["staging", "preprod", "integration", "shared", "remote"]) {
            return .limited
        }
        return .none
    }

    private func dataSensitivity(from text: String) -> DataSensitivity {
        if containsAny(text, ["regulated", "pci", "hipaa", "phi", "pii", "payment", "ssn"]) {
            return .regulated
        }
        if containsAny(text, ["secret", "token", "credential", "customer", "database", "db", "backup", "export", "invoice"]) {
            return .confidential
        }
        if containsAny(text, ["internal", "workspace", "config", "log"]) {
            return .internalUse
        }
        return .publicData
    }

    private func reversibility(from text: String, toolCall: ToolCall) -> ActionReversibility {
        if containsAny(text, ["drop database", "destroy", "irreversible", "purge", "wipe"]) {
            return .irreversible
        }
        if isDestructiveShellCommand(toolCall.command, arguments: toolCall.arguments)
            || containsAny(text, ["delete", "remove", "rm -rf", "migrate", "apply", "chmod", "chown", "deploy"]) {
            return .destructive
        }
        if containsAny(text, ["write", "update", "post", "patch", "create", "modify"]) {
            return .recoverable
        }
        return .reversible
    }

    private func permissionLevel(from text: String, toolCall: ToolCall) -> PermissionLevel {
        if containsAny(text, ["sudo", "admin", "root", "owner"]) {
            return .admin
        }
        if toolCall.type == .api, isReadOnlyWorkspaceAPI(toolCall.command) {
            return .readOnly
        }
        if toolCall.type == .connector || toolCall.type == .api {
            return .elevated
        }
        if isReadOnlyCommand(toolCall.command) {
            return .readOnly
        }
        if containsAny(text, ["write", "update", "delete", "deploy", "chmod", "chown", "kill", "launchctl"]) {
            return .elevated
        }
        return .standard
    }

    private func productionScore(_ value: ProductionImpact) -> Int {
        switch value {
        case .none: return 0
        case .limited: return 1
        case .production: return 3
        }
    }

    private func dataScore(_ value: DataSensitivity) -> Int {
        switch value {
        case .publicData: return 0
        case .internalUse: return 1
        case .confidential: return 2
        case .regulated: return 3
        }
    }

    private func reversibilityScore(_ value: ActionReversibility) -> Int {
        switch value {
        case .reversible: return 0
        case .recoverable: return 1
        case .destructive: return 3
        case .irreversible: return 4
        }
    }

    private func permissionScore(_ value: PermissionLevel) -> Int {
        switch value {
        case .readOnly: return 0
        case .standard: return 1
        case .elevated: return 2
        case .admin: return 3
        }
    }

    private func isReadOnlyCommand(_ command: String) -> Bool {
        let executable = (command as NSString).lastPathComponent.lowercased()
        return ["pwd", "ls", "cat", "head", "tail", "grep", "rg", "find", "sed", "awk", "echo"].contains(executable)
    }

    private func isReadOnlyWorkspaceAPI(_ command: String) -> Bool {
        [
            "engineering.list_directory",
            "engineering.read_file",
            "engineering.search_files",
            "engineering.search_code",
            "engineering.inspect_project",
            "engineering.report_validation",
            "workspace.list_directory",
            "workspace.read_file",
            "workspace.search_files",
            "workspace.search_code",
            "workspace.inspect_project",
            "workspace.report_validation"
        ].contains(command)
    }

    private func isDestructiveShellCommand(_ command: String, arguments: [String]) -> Bool {
        let executable = (command as NSString).lastPathComponent.lowercased()
        if ["rm", "mv", "chmod", "chown", "launchctl", "killall"].contains(executable) {
            return true
        }
        let combined = ([command] + arguments).joined(separator: " ").lowercased()
        return containsAny(combined, [" rm ", " --delete", " drop ", " destroy ", " defaults write "])
    }

    private func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

private extension RiskAssessment {
    func raised(to severity: RiskSeverity, reason: String) -> RiskAssessment {
        guard severity.governanceRank > level.governanceRank else {
            var copy = self
            if !copy.reasons.contains(reason) {
                copy.reasons.append(reason)
            }
            return copy
        }
        var copy = self
        copy.level = severity
        copy.score = max(copy.score, severity.minimumGovernanceScore)
        copy.reasons.append(reason)
        return copy
    }
}

extension RiskSeverity {
    var governanceRank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    var minimumGovernanceScore: Int {
        switch self {
        case .low: return 0
        case .medium: return 3
        case .high: return 6
        case .critical: return 9
        }
    }
}

private extension DataSensitivity {
    var governanceRank: Int {
        switch self {
        case .publicData: return 0
        case .internalUse: return 1
        case .confidential: return 2
        case .regulated: return 3
        }
    }
}

private extension ActionReversibility {
    var governanceRank: Int {
        switch self {
        case .reversible: return 0
        case .recoverable: return 1
        case .destructive: return 2
        case .irreversible: return 3
        }
    }
}

private extension PermissionLevel {
    var governanceRank: Int {
        switch self {
        case .readOnly: return 0
        case .standard: return 1
        case .elevated: return 2
        case .admin: return 3
        }
    }
}
