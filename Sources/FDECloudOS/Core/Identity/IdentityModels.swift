import Foundation

enum SessionState: String, Codable, CaseIterable, Identifiable, Sendable {
    case signedOut
    case signedIn
    case expired
    case locked
    case switchingWorkspace

    var id: String { rawValue }
}

struct UserSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var subject: String
    var provider: String
    var state: SessionState
    var issuedAt: Date
    var expiresAt: Date?
    var updatedAt: Date
}

struct WorkspaceSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var userSessionID: UUID
    var workspaceID: UUID
    var orgID: UUID
    var role: UserRole
    var state: SessionState
    var startedAt: Date
    var updatedAt: Date
}

struct SessionMetadata: Codable, Hashable, Sendable {
    var userSession: UserSession
    var workspaceSession: WorkspaceSession?
}

enum SecureValueKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case sessionToken
    case providerToken
    case connectorToken
    case workspaceSecret

    var id: String { rawValue }
}

struct SecureValueKey: Codable, Hashable, Sendable {
    var kind: SecureValueKind
    var workspaceID: UUID?
    var provider: String?
    var connectorID: String?
    var name: String

    static func sessionToken(workspaceID: UUID) -> SecureValueKey {
        SecureValueKey(kind: .sessionToken, workspaceID: workspaceID, provider: nil, connectorID: nil, name: "active")
    }

    static func providerToken(provider: String, workspaceID: UUID? = nil) -> SecureValueKey {
        SecureValueKey(kind: .providerToken, workspaceID: workspaceID, provider: provider, connectorID: nil, name: "active")
    }

    static func connectorToken(connectorID: String, workspaceID: UUID) -> SecureValueKey {
        SecureValueKey(kind: .connectorToken, workspaceID: workspaceID, provider: nil, connectorID: connectorID, name: "active")
    }

    static func workspaceSecret(name: String, workspaceID: UUID) -> SecureValueKey {
        SecureValueKey(kind: .workspaceSecret, workspaceID: workspaceID, provider: nil, connectorID: nil, name: name)
    }

    var account: String {
        [
            kind.rawValue,
            workspaceID?.uuidString.lowercased() ?? "global",
            provider ?? "provider-none",
            connectorID ?? "connector-none",
            name
        ].joined(separator: ":")
    }
}

protocol SecureValueStoring: Sendable {
    func save(_ value: String, for key: SecureValueKey) throws
    func load(for key: SecureValueKey) throws -> String?
    func delete(for key: SecureValueKey) throws
}

enum Permission: String, Codable, CaseIterable, Identifiable, Sendable {
    case createTask
    case executeTool
    case approveRiskyAction
    case viewDiagnostics
    case manageWorkspace
    case manageConnectors
    case viewPolicy
    case updatePolicy

    var id: String { rawValue }
}

struct AuthorizationDecision: Codable, Hashable, Sendable {
    var allowed: Bool
    var role: UserRole
    var permission: Permission
    var action: String
    var resource: String?
    var reason: String
}

enum AuthorizationError: LocalizedError {
    case denied(AuthorizationDecision)

    var errorDescription: String? {
        switch self {
        case .denied(let decision):
            return decision.reason
        }
    }
}

struct AuthorizationService: Sendable {
    func hasPermission(_ permission: Permission, in workspace: Workspace) -> Bool {
        permissions(for: workspace.role).contains(permission)
    }

    func authorize(
        _ permission: Permission,
        workspace: Workspace,
        action: String,
        resource: String? = nil
    ) -> AuthorizationDecision {
        let allowed = hasPermission(permission, in: workspace)
        return AuthorizationDecision(
            allowed: allowed,
            role: workspace.role,
            permission: permission,
            action: action,
            resource: resource,
            reason: allowed
                ? "Allowed by \(workspace.role.rawValue) role."
                : "\(workspace.role.rawValue) role is not permitted to \(permission.rawValue)."
        )
    }

    private func permissions(for role: UserRole) -> Set<Permission> {
        switch role {
        case .admin:
            return Set(Permission.allCases)
        case .fde:
            return [
                .createTask,
                .executeTool,
                .approveRiskyAction,
                .viewDiagnostics,
                .viewPolicy,
                .updatePolicy
            ]
        case .user:
            return [
                .createTask,
                .viewPolicy
            ]
        }
    }
}
