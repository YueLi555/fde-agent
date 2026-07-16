import Foundation

enum PolicyDecisionStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case allowed
    case approvalRequired = "approval_required"
    case denied

    var id: String { rawValue }
}

struct PolicyInput: Codable, Hashable, Sendable {
    var userRole: UserRole
    var system: String
    var environment: String
    var action: String
    var riskLevel: RiskSeverity

    init(
        userRole: UserRole,
        system: String,
        environment: String,
        action: String,
        riskLevel: RiskSeverity
    ) {
        self.userRole = userRole
        self.system = system
        self.environment = environment
        self.action = action
        self.riskLevel = riskLevel
    }

    init(workspace: Workspace, toolCall: ToolCall, risk: RiskAssessment) {
        self.init(
            userRole: workspace.role,
            system: Self.systemName(for: toolCall),
            environment: risk.policyEnvironment,
            action: Self.actionName(for: toolCall),
            riskLevel: risk.level
        )
    }

    private static func systemName(for toolCall: ToolCall) -> String {
        let command = toolCall.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return "unknown" }

        if toolCall.type == .connector || toolCall.type == .api {
            let parts = command
                .lowercased()
                .split(separator: ".")
                .map(String.init)
            return parts.first == "connector" ? parts.dropFirst().first ?? "connector" : parts.first ?? "external_system"
        }

        if command.hasPrefix("/") {
            return "local_shell"
        }

        return command
            .lowercased()
            .split(separator: ".")
            .map(String.init)
            .first ?? "workspace"
    }

    private static func actionName(for toolCall: ToolCall) -> String {
        ([toolCall.command] + toolCall.arguments)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct PolicyEvaluation: Codable, Hashable, Sendable {
    var status: PolicyDecisionStatus
    var input: PolicyInput
    var reasons: [String]

    var requiresApproval: Bool {
        status == .approvalRequired
    }

    var allowsExecution: Bool {
        status == .allowed
    }

    var summary: String {
        reasons.joined(separator: " | ")
    }

    var auditPayload: [String: String] {
        [
            "policy_decision": status.rawValue,
            "policy_user_role": input.userRole.rawValue,
            "policy_system": input.system,
            "policy_environment": input.environment,
            "policy_action": input.action,
            "policy_risk_level": input.riskLevel.rawValue,
            "policy_reasons": summary
        ]
    }
}

struct PolicyEngine: Sendable {
    func evaluate(
        _ input: PolicyInput,
        permissionDecision: PermissionDecision? = nil,
        globallyAvoided: Bool = false
    ) -> PolicyEvaluation {
        var reasons: [String] = []

        if globallyAvoided {
            return decision(.denied, input: input, reasons: ["Action is blocked by global execution policy."])
        }

        if let permissionDecision {
            switch permissionDecision {
            case .allowed:
                break
            case .approvalRequired(let reason):
                reasons.append(reason)
                return decision(.approvalRequired, input: input, reasons: reasons)
            case .denied(let reason):
                return decision(.denied, input: input, reasons: [reason])
            }
        }

        if isProduction(input), isDestructive(input.action) {
            return decision(.denied, input: input, reasons: ["Destructive production action is denied by governance policy."])
        }

        switch input.userRole {
        case .user:
            if input.riskLevel.governanceRank >= RiskSeverity.high.governanceRank || isProduction(input) {
                return decision(.denied, input: input, reasons: ["User role cannot execute high-risk or production-impacting actions."])
            }
            if input.riskLevel == .medium {
                return decision(.approvalRequired, input: input, reasons: ["User role requires approval for medium-risk actions."])
            }
        case .fde:
            if input.riskLevel == .critical {
                return decision(.denied, input: input, reasons: ["FDE role cannot execute critical actions without administrative policy override."])
            }
            if input.riskLevel == .high || (isProduction(input) && input.riskLevel == .medium) {
                return decision(.approvalRequired, input: input, reasons: ["FDE role requires approval for elevated risk actions."])
            }
        case .admin:
            if input.riskLevel == .critical {
                return decision(.approvalRequired, input: input, reasons: ["Admin role requires explicit approval for critical actions."])
            }
            if input.riskLevel == .high {
                return decision(.approvalRequired, input: input, reasons: ["Admin role requires approval for high-risk actions."])
            }
        }

        if input.riskLevel == .medium, isProduction(input) {
            return decision(.approvalRequired, input: input, reasons: ["Production medium-risk action requires approval."])
        }

        reasons.append("Allowed by role, environment, action, and risk policy.")
        return decision(.allowed, input: input, reasons: reasons)
    }

    private func decision(
        _ status: PolicyDecisionStatus,
        input: PolicyInput,
        reasons: [String]
    ) -> PolicyEvaluation {
        PolicyEvaluation(status: status, input: input, reasons: reasons)
    }

    private func isProduction(_ input: PolicyInput) -> Bool {
        let value = "\(input.system) \(input.environment) \(input.action)".lowercased()
        return value.contains("prod") || value.contains("production") || value.contains("live")
    }

    private func isDestructive(_ action: String) -> Bool {
        let normalized = action.lowercased()
        return [
            "delete",
            "destroy",
            "drop",
            "purge",
            "wipe",
            "rm -rf",
            "terraform apply",
            "kubectl delete",
            "gcloud run deploy",
            "deploy"
        ].contains { normalized.contains($0) }
    }
}
