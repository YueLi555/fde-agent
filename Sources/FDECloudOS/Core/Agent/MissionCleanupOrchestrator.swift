import Foundation

struct MissionUndoRequest: Hashable, Sendable, Identifiable {
    var missionID: UUID
    var workspaceID: UUID
    var patchID: String?
    var patchPlanID: String?
    var patchRevision: Int?
    var sandboxID: String?
    var canonicalLegacyRoot: String?
    var sourceSnapshotID: String?
    var candidatePatchManifestID: String?
    var candidatePatchArtifactSHA256: String?
    var assessmentID: String?
    var lineageKey: String?
    var patchRequiresRevert: Bool
    var patchAlreadyReverted: Bool
    var sandboxAlreadyDestroyed: Bool

    var id: UUID { missionID }

    init(
        missionID: UUID,
        workspaceID: UUID,
        patchID: String?,
        patchPlanID: String?,
        patchRevision: Int?,
        sandboxID: String?,
        canonicalLegacyRoot: String?,
        patchRequiresRevert: Bool,
        patchAlreadyReverted: Bool,
        sandboxAlreadyDestroyed: Bool,
        sourceSnapshotID: String? = nil,
        candidatePatchManifestID: String? = nil,
        candidatePatchArtifactSHA256: String? = nil,
        assessmentID: String? = nil,
        lineageKey: String? = nil
    ) {
        self.missionID = missionID
        self.workspaceID = workspaceID
        self.patchID = patchID
        self.patchPlanID = patchPlanID
        self.patchRevision = patchRevision
        self.sandboxID = sandboxID
        self.canonicalLegacyRoot = canonicalLegacyRoot
        self.sourceSnapshotID = sourceSnapshotID
        self.candidatePatchManifestID = candidatePatchManifestID
        self.candidatePatchArtifactSHA256 = candidatePatchArtifactSHA256
        self.assessmentID = assessmentID
        self.lineageKey = lineageKey
        self.patchRequiresRevert = patchRequiresRevert
        self.patchAlreadyReverted = patchAlreadyReverted
        self.sandboxAlreadyDestroyed = sandboxAlreadyDestroyed
    }

    init?(summary: MissionSummary, workspaceID: UUID) {
        guard summary.undoEligible || summary.cleanup?.phase == .partialFailure,
              summary.lineageState == .exact,
              let lineage = summary.lineage,
              lineage.workspaceID == workspaceID,
              lineage.missionRunID == summary.missionID else {
            return nil
        }
        let patch = summary.candidatePatch
        missionID = summary.missionID
        self.workspaceID = workspaceID
        patchID = patch?.patchID
        patchPlanID = patch?.planID
        patchRevision = patch?.planRevision
        sandboxID = patch?.sandboxID
        canonicalLegacyRoot = patch?.canonicalLegacyRoot
        sourceSnapshotID = patch?.sourceSnapshotID
        candidatePatchManifestID = patch?.manifestID
        candidatePatchArtifactSHA256 = patch?.candidatePatchArtifactSHA256
        assessmentID = patch?.assessmentID
        lineageKey = lineage.lineageKey
        patchRequiresRevert = patch?.projectionState == .patchReady
            || patch?.status == .reviewReady
            || patch?.status == .applied
        patchAlreadyReverted = patch?.projectionState == .reverted
            || patch?.projectionState == .sandboxDestroyed
            || patch?.status == .reverted
        sandboxAlreadyDestroyed = patch?.projectionState == .sandboxDestroyed
    }

    var expectedOperations: [String] {
        var operations = [
            "Freeze new actions for this exact mission",
            "Cancel pending review actions where cancellation remains valid"
        ]
        if patchRequiresRevert {
            operations.append("Revert the exact Candidate Patch in its bound Safe Sandbox")
            operations.append("Verify the original Legacy remains unchanged")
        } else if patchAlreadyReverted {
            operations.append("Keep the completed exact Candidate Patch Revert")
            operations.append("Verify the original Legacy remains unchanged")
        } else {
            operations.append("Preserve review and audit records; no Patch Revert is needed")
        }
        if sandboxID != nil, patchRequiresRevert || patchAlreadyReverted {
            operations.append("Destroy only the exact bound temporary Safe Sandbox")
        }
        operations.append("Preserve the complete audit trail")
        return operations
    }
}

struct MissionUndoConfirmation: Identifiable, Hashable, Sendable {
    var confirmationID: UUID
    var request: MissionUndoRequest
    var issuedAt: Date

    var id: UUID { confirmationID }
}

struct MissionCleanupStore: Sendable {
    let storageRoot: URL

    private var stateRoot: URL {
        storageRoot.appendingPathComponent(".mission-cleanup-state", isDirectory: true)
    }

    func save(_ state: MissionCleanupState) throws {
        let root = try validatedStateRoot(createIfNeeded: true)
        let url = root.appendingPathComponent(
            state.missionID.uuidString.lowercased() + ".json",
            isDirectory: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: url, options: [.atomic])
    }

    func load(missionID: UUID) throws -> MissionCleanupState? {
        guard FileManager.default.fileExists(atPath: storageRoot.path),
              FileManager.default.fileExists(atPath: stateRoot.path) else {
            return nil
        }
        let root = try validatedStateRoot(createIfNeeded: false)
        let url = root.appendingPathComponent(
            missionID.uuidString.lowercased() + ".json",
            isDirectory: false
        )
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(MissionCleanupState.self, from: Data(contentsOf: url))
        guard state.missionID == missionID else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        return state
    }

    func loadAll(workspaceID: UUID) throws -> [MissionCleanupState] {
        guard FileManager.default.fileExists(atPath: storageRoot.path),
              FileManager.default.fileExists(atPath: stateRoot.path) else {
            return []
        }
        let root = try validatedStateRoot(createIfNeeded: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }
        .map { url in
            guard (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
                throw SandboxFoundationError.sandboxMetadataInvalid
            }
            return try decoder.decode(MissionCleanupState.self, from: Data(contentsOf: url))
        }
        .filter { $0.workspaceID == workspaceID }
        .sorted { lhs, rhs in
            if lhs.updatedAt == rhs.updatedAt { return lhs.missionID.uuidString < rhs.missionID.uuidString }
            return lhs.updatedAt < rhs.updatedAt
        }
    }

    private func validatedStateRoot(createIfNeeded: Bool) throws -> URL {
        if !FileManager.default.fileExists(atPath: storageRoot.path) {
            guard createIfNeeded else { throw SandboxFoundationError.sandboxMetadataInvalid }
            try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        }
        guard (try? SandboxFileSystem.isSymbolicLink(storageRoot)) == false else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        let canonicalStorage = try SandboxFileSystem.canonicalExistingDirectory(storageRoot)
        if !FileManager.default.fileExists(atPath: stateRoot.path) {
            guard createIfNeeded else { throw SandboxFoundationError.sandboxMetadataInvalid }
            try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: false)
        }
        guard (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        let canonicalState = try SandboxFileSystem.canonicalExistingDirectory(stateRoot)
        guard SandboxFileSystem.isDirectChild(canonicalState, of: canonicalStorage) else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        return canonicalState
    }

}

struct MissionCleanupOrchestrator: Sendable {
    let lifecycle: SandboxLifecycleService

    private var store: MissionCleanupStore {
        MissionCleanupStore(storageRoot: lifecycle.storageRoot)
    }

    func execute(
        _ request: MissionUndoRequest,
        now: Date = Date()
    ) -> MissionCleanupState {
        var state = ((try? store.load(missionID: request.missionID)) ?? nil)
            ?? MissionCleanupState(
                missionID: request.missionID,
                workspaceID: request.workspaceID,
                phase: .freezingActions,
                patchID: request.patchID,
                patchPlanID: request.patchPlanID,
                patchRevision: request.patchRevision,
                sandboxID: request.sandboxID,
                canonicalLegacyRoot: request.canonicalLegacyRoot,
                sourceSnapshotID: request.sourceSnapshotID,
                candidatePatchManifestID: request.candidatePatchManifestID,
                candidatePatchArtifactSHA256: request.candidatePatchArtifactSHA256,
                assessmentID: request.assessmentID,
                lineageKey: request.lineageKey,
                pendingReviewActionsCancelled: false,
                candidatePatchReverted: request.patchAlreadyReverted,
                legacyVerifiedUnchanged: false,
                sandboxDestroyed: request.sandboxAlreadyDestroyed,
                failureReason: nil,
                startedAt: now,
                updatedAt: now,
                completedAt: nil
            )
        guard state.workspaceID == request.workspaceID,
              state.patchID == request.patchID,
              state.patchPlanID == request.patchPlanID,
              state.patchRevision == request.patchRevision,
              state.sandboxID == request.sandboxID,
              state.canonicalLegacyRoot == request.canonicalLegacyRoot,
              state.sourceSnapshotID == request.sourceSnapshotID,
              state.candidatePatchManifestID == request.candidatePatchManifestID,
              state.candidatePatchArtifactSHA256 == request.candidatePatchArtifactSHA256,
              state.assessmentID == request.assessmentID,
              state.lineageKey == request.lineageKey else {
            state.phase = .partialFailure
            state.failureReason = "The exact persisted cleanup binding no longer matches this mission."
            state.updatedAt = now
            try? store.save(state)
            return state
        }
        if state.phase == .cleanedUp { return state }

        do {
            state.phase = .cancellingReviews
            state.failureReason = nil
            state.updatedAt = now
            try store.save(state)
            state.pendingReviewActionsCancelled = true
            state.updatedAt = Date()
            try store.save(state)

            guard request.patchRequiresRevert || request.patchAlreadyReverted else {
                state.candidatePatchReverted = true
                state.legacyVerifiedUnchanged = true
                state.sandboxDestroyed = true
                return try complete(&state)
            }

            let service = CandidatePatchService(lifecycle: lifecycle)
            guard let rawPatchID = request.patchID,
                  let patchID = CandidatePatchID(rawValue: rawPatchID),
                  let rawSandboxID = request.sandboxID,
                  let sandboxID = SandboxID(rawValue: rawSandboxID),
                  let expectedPlanID = request.patchPlanID.flatMap(UUID.init(uuidString:)),
                  let expectedRevision = request.patchRevision else {
                throw MissionCleanupFailure.invalidExactBinding
            }
            var manifest = try service.loadManifest(sandboxID: sandboxID, patchID: patchID)
            guard manifest.appliedBinding?.workspaceID == request.workspaceID,
                  manifest.appliedBinding?.taskID == request.missionID,
                  manifest.plan.planID == expectedPlanID,
                  manifest.plan.revision == expectedRevision,
                  manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot == request.canonicalLegacyRoot,
                  manifest.sourceSnapshotID == request.sourceSnapshotID,
                  manifest.stableManifestID == request.candidatePatchManifestID,
                  manifest.candidatePatchArtifactSHA256 == request.candidatePatchArtifactSHA256,
                  manifest.plan.assessmentID == request.assessmentID else {
                throw MissionCleanupFailure.invalidExactBinding
            }
            let binding = try service.appliedBinding(sandboxID: sandboxID, patchID: patchID)

            if !state.candidatePatchReverted {
                if manifest.status == .reverted || manifest.sandboxDestroyedAt != nil {
                    state.candidatePatchReverted = true
                } else {
                    state.phase = .revertingPatch
                    state.updatedAt = Date()
                    try store.save(state)
                    manifest = try service.revert(binding: binding)
                    guard manifest.status == .reverted else {
                        throw MissionCleanupFailure.revertNotVerified
                    }
                    state.candidatePatchReverted = true
                }
                state.updatedAt = Date()
                try store.save(state)
            }

            if !state.legacyVerifiedUnchanged {
                state.phase = .verifyingLegacy
                state.updatedAt = Date()
                try store.save(state)
                manifest = try service.loadManifest(sandboxID: sandboxID, patchID: patchID)
                guard manifest.status == .reverted,
                      manifest.sourceIntegrity == .unchanged else {
                    throw MissionCleanupFailure.legacyIntegrityNotVerified
                }
                if manifest.sandboxDestroyedAt == nil {
                    _ = try service.prepareSandboxDestruction(binding: binding)
                } else {
                    guard manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }) else {
                        throw MissionCleanupFailure.legacyIntegrityNotVerified
                    }
                }
                state.legacyVerifiedUnchanged = true
                state.updatedAt = Date()
                try store.save(state)
            }

            if !state.sandboxDestroyed {
                manifest = try service.loadManifest(sandboxID: sandboxID, patchID: patchID)
                if manifest.sandboxDestroyedAt != nil {
                    state.sandboxDestroyed = true
                } else {
                    state.phase = .destroyingSandbox
                    state.updatedAt = Date()
                    try store.save(state)
                    manifest = try service.destroyRevertedSandbox(binding: binding)
                    guard manifest.sandboxDestroyedAt != nil else {
                        throw MissionCleanupFailure.sandboxDestructionNotVerified
                    }
                    state.sandboxDestroyed = true
                }
                state.updatedAt = Date()
                try store.save(state)
            }
            return try complete(&state)
        } catch {
            state.phase = .partialFailure
            state.failureReason = error.localizedDescription
            state.updatedAt = Date()
            try? store.save(state)
            return state
        }
    }

    private func complete(_ state: inout MissionCleanupState) throws -> MissionCleanupState {
        guard state.pendingReviewActionsCancelled,
              state.candidatePatchReverted,
              state.legacyVerifiedUnchanged,
              state.sandboxDestroyed else {
            throw MissionCleanupFailure.incompleteCleanup
        }
        state.phase = .cleanedUp
        state.failureReason = nil
        state.updatedAt = Date()
        state.completedAt = state.updatedAt
        try store.save(state)
        return state
    }
}

private enum MissionCleanupFailure: LocalizedError {
    case invalidExactBinding
    case revertNotVerified
    case legacyIntegrityNotVerified
    case sandboxDestructionNotVerified
    case incompleteCleanup

    var errorDescription: String? {
        switch self {
        case .invalidExactBinding:
            return "The exact Mission, Patch, revision, Sandbox, and Legacy binding could not be verified."
        case .revertNotVerified:
            return "The exact Candidate Patch Revert did not reach REVERTED."
        case .legacyIntegrityNotVerified:
            return "The original Legacy could not be verified as unchanged."
        case .sandboxDestructionNotVerified:
            return "The exact temporary Sandbox could not be verified as destroyed."
        case .incompleteCleanup:
            return "Cleanup stopped before every exact step was verified."
        }
    }
}
