import Foundation

actor SessionRepository {
    private let persistence: any PersistenceStore
    private let secureStore: any SecureValueStoring

    init(persistence: any PersistenceStore, secureStore: any SecureValueStoring) {
        self.persistence = persistence
        self.secureStore = secureStore
    }

    func loadCredential() async throws -> SessionCredential? {
        guard let metadata = try await persistence.loadSessionMetadata(),
              metadata.userSession.state == .signedIn,
              let workspaceSession = metadata.workspaceSession,
              workspaceSession.state == .signedIn else {
            return nil
        }

        return SessionCredential(
            id: metadata.userSession.id,
            workspaceID: workspaceSession.workspaceID,
            subject: metadata.userSession.subject,
            provider: metadata.userSession.provider,
            issuedAt: metadata.userSession.issuedAt
        )
    }

    func startLocalSession(subject: String, provider: String, workspace: Workspace) async throws -> SessionCredential {
        let now = Date()
        let userSession = UserSession(
            id: UUID(),
            subject: subject,
            provider: provider,
            state: .signedIn,
            issuedAt: now,
            expiresAt: nil,
            updatedAt: now
        )
        let workspaceSession = WorkspaceSession(
            id: UUID(),
            userSessionID: userSession.id,
            workspaceID: workspace.id,
            orgID: workspace.orgID,
            role: workspace.role,
            state: .signedIn,
            startedAt: now,
            updatedAt: now
        )

        try secureStore.save(UUID().uuidString, for: .sessionToken(workspaceID: workspace.id))
        try await persistence.saveSessionMetadata(
            SessionMetadata(userSession: userSession, workspaceSession: workspaceSession)
        )

        return SessionCredential(
            id: userSession.id,
            workspaceID: workspace.id,
            subject: subject,
            provider: provider,
            issuedAt: now
        )
    }

    func switchWorkspace(to workspace: Workspace) async throws -> SessionCredential? {
        guard var metadata = try await persistence.loadSessionMetadata() else {
            return nil
        }

        let now = Date()
        metadata.userSession.state = .switchingWorkspace
        metadata.userSession.updatedAt = now
        metadata.workspaceSession = WorkspaceSession(
            id: UUID(),
            userSessionID: metadata.userSession.id,
            workspaceID: workspace.id,
            orgID: workspace.orgID,
            role: workspace.role,
            state: .switchingWorkspace,
            startedAt: now,
            updatedAt: now
        )
        try await persistence.saveSessionMetadata(metadata)

        metadata.userSession.state = .signedIn
        metadata.userSession.updatedAt = Date()
        metadata.workspaceSession?.state = .signedIn
        metadata.workspaceSession?.updatedAt = Date()
        try secureStore.save(UUID().uuidString, for: .sessionToken(workspaceID: workspace.id))
        try await persistence.saveSessionMetadata(metadata)

        return try await loadCredential()
    }

    func endSession() async throws {
        guard var metadata = try await persistence.loadSessionMetadata() else {
            try await persistence.clearSessionMetadata()
            return
        }

        if let workspaceID = metadata.workspaceSession?.workspaceID {
            try secureStore.delete(for: .sessionToken(workspaceID: workspaceID))
        }
        metadata.userSession.state = .signedOut
        metadata.userSession.updatedAt = Date()
        metadata.workspaceSession?.state = .signedOut
        metadata.workspaceSession?.updatedAt = Date()
        try await persistence.saveSessionMetadata(metadata)
    }

    func lockSession() async throws {
        try await updateState(.locked)
    }

    func expireSession() async throws {
        try await updateState(.expired)
    }

    private func updateState(_ state: SessionState) async throws {
        guard var metadata = try await persistence.loadSessionMetadata() else {
            return
        }
        metadata.userSession.state = state
        metadata.userSession.updatedAt = Date()
        metadata.workspaceSession?.state = state
        metadata.workspaceSession?.updatedAt = Date()
        try await persistence.saveSessionMetadata(metadata)
    }
}
