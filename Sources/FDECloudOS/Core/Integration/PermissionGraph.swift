import Foundation

struct PermissionGraphEntry: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var user: String
    var role: String
    var system: String
    var allowedActions: [String]
    var deniedActions: [String]
    var approvalRequirements: [String]

    init(
        id: String,
        user: String,
        role: String,
        system: String,
        allowedActions: [String] = [],
        deniedActions: [String] = [],
        approvalRequirements: [String] = []
    ) {
        self.id = id
        self.user = user
        self.role = role
        self.system = system
        self.allowedActions = allowedActions
        self.deniedActions = deniedActions
        self.approvalRequirements = approvalRequirements
    }
}

struct PermissionCheckRequest: Codable, Hashable, Sendable {
    var user: String
    var role: String
    var system: String
    var action: String
}

enum PermissionDecision: Codable, Hashable, Sendable {
    case allowed
    case denied(String)
    case approvalRequired(String)

    var isAllowed: Bool {
        if case .allowed = self {
            return true
        }
        return false
    }

    var requiresApproval: Bool {
        if case .approvalRequired = self {
            return true
        }
        return false
    }
}

struct PermissionGraph: Codable, Hashable, Sendable {
    var entries: [PermissionGraphEntry]

    init(entries: [PermissionGraphEntry] = []) {
        self.entries = entries
    }

    func decision(for request: PermissionCheckRequest) -> PermissionDecision {
        let matchingEntries = entries.filter {
            matches($0.system, request.system)
                && matchesIdentity($0.user, request.user)
                && matchesIdentity($0.role, request.role)
        }
        guard !matchingEntries.isEmpty else {
            return .allowed
        }

        if let entry = matchingEntries.first(where: { matchesAny($0.deniedActions, request.action) }) {
            return .denied("Denied action `\(request.action)` on `\(entry.system)` for role `\(entry.role)`.")
        }

        if let entry = matchingEntries.first(where: { matchesAny($0.approvalRequirements, request.action) }) {
            return .approvalRequired("Action `\(request.action)` on `\(entry.system)` requires approval for role `\(entry.role)`.")
        }

        if matchingEntries.contains(where: { matchesAny($0.allowedActions, request.action) }) {
            return .allowed
        }

        return .denied("Action `\(request.action)` is not listed as allowed for `\(request.system)`.")
    }

    func merged(with other: PermissionGraph?) -> PermissionGraph {
        guard let other else { return self }
        var merged = entries
        let existingIDs = Set(merged.map(\.id))
        merged += other.entries.filter { !existingIDs.contains($0.id) }
        return PermissionGraph(entries: merged)
    }

    var summaryFacts: [String] {
        entries.flatMap { entry in
            [
                "permission:user:\(entry.user)",
                "permission:role:\(entry.role)",
                "permission:system:\(entry.system)",
                entry.allowedActions.isEmpty ? "" : "allows:\(entry.system):\(entry.allowedActions.joined(separator: ","))",
                entry.deniedActions.isEmpty ? "" : "denies:\(entry.system):\(entry.deniedActions.joined(separator: ","))",
                entry.approvalRequirements.isEmpty ? "" : "approval_required:\(entry.system):\(entry.approvalRequirements.joined(separator: ","))"
            ]
        }
        .filter { !$0.isEmpty }
    }

    private func matchesIdentity(_ pattern: String, _ value: String) -> Bool {
        pattern == "*" || pattern.caseInsensitiveCompare(value) == .orderedSame
    }

    private func matches(_ pattern: String, _ value: String) -> Bool {
        pattern == "*" || normalized(pattern) == normalized(value)
    }

    private func matchesAny(_ patterns: [String], _ action: String) -> Bool {
        patterns.contains { pattern in
            pattern == "*"
                || normalized(pattern) == normalized(action)
                || normalized(action).hasPrefix("\(normalized(pattern)).")
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
