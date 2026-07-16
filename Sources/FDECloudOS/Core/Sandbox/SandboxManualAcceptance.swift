import Foundation

enum SandboxRuntimeActivityPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case validatingSelectedLegacyWorkspace = "Validating selected Legacy workspace"
    case confirmingCanonicalLegacyRoot = "Confirming canonical Legacy root"
    case checkingLocalSourceAvailability = "Checking local source availability"
    case creatingSourceSnapshot = "Creating source snapshot"
    case copyingApprovedFiles = "Copying approved files"
    case verifyingSHA256 = "Verifying SHA-256"
    case verifyingFilesystemIsolation = "Verifying filesystem isolation"
    case confirmingOriginalLegacyUnchanged = "Confirming original Legacy unchanged"
    case finalizingSandboxAcceptance = "Finalizing Sandbox acceptance"

    // Retained for the standalone Phase 2D.0 foundation runner.
    case validatingLegacySource = "Validating Legacy source"
    case creatingIsolatedSandbox = "Creating isolated Sandbox"
    case copyingApprovedSourceFiles = "Copying approved source files"
    case excludingSensitiveFiles = "Excluding sensitive files"
    case verifyingFileHashes = "Verifying file hashes"
    case checkingPathContainment = "Checking path containment"
    case confirmingSourceIsolation = "Confirming source isolation"
    case sandboxReady = "Sandbox ready"
    case sandboxCreationBlocked = "Sandbox creation blocked"
    case destroyingSandbox = "Destroying Sandbox"

    static let productAcceptancePhases: [SandboxRuntimeActivityPhase] = [
        .validatingSelectedLegacyWorkspace,
        .confirmingCanonicalLegacyRoot,
        .checkingLocalSourceAvailability,
        .creatingSourceSnapshot,
        .creatingIsolatedSandbox,
        .copyingApprovedFiles,
        .excludingSensitiveFiles,
        .verifyingSHA256,
        .verifyingFilesystemIsolation,
        .confirmingOriginalLegacyUnchanged,
        .destroyingSandbox,
        .finalizingSandboxAcceptance
    ]
}

struct SandboxActivitySnapshot: Codable, Hashable, Sendable {
    var sandboxID: String?
    var sourceSnapshotID: String?
    var status: SandboxStatus?
    var includedFileCount: Int
    var excludedItemCount: Int
    var integrityStatus: SandboxIntegrityStatus
    var sourceUnchanged: Bool?

    static let empty = SandboxActivitySnapshot(
        sandboxID: nil,
        sourceSnapshotID: nil,
        status: nil,
        includedFileCount: 0,
        excludedItemCount: 0,
        integrityStatus: .notValidated,
        sourceUnchanged: nil
    )

    init(
        sandboxID: String?,
        sourceSnapshotID: String?,
        status: SandboxStatus?,
        includedFileCount: Int,
        excludedItemCount: Int,
        integrityStatus: SandboxIntegrityStatus,
        sourceUnchanged: Bool?
    ) {
        self.sandboxID = sandboxID
        self.sourceSnapshotID = sourceSnapshotID
        self.status = status
        self.includedFileCount = includedFileCount
        self.excludedItemCount = excludedItemCount
        self.integrityStatus = integrityStatus
        self.sourceUnchanged = sourceUnchanged
    }

    init?(eventPayload: [String: String]) {
        guard eventPayload["sandbox_activity_phase"] != nil
                || eventPayload["sandbox_id"] != nil
                || eventPayload["source_snapshot_id"] != nil else {
            return nil
        }
        sandboxID = eventPayload["sandbox_id"].flatMap { $0.isEmpty ? nil : $0 }
        sourceSnapshotID = eventPayload["source_snapshot_id"].flatMap { $0.isEmpty ? nil : $0 }
        status = eventPayload["sandbox_status"].flatMap(SandboxStatus.init(rawValue:))
        includedFileCount = eventPayload["included_file_count"].flatMap(Int.init) ?? 0
        excludedItemCount = eventPayload["excluded_item_count"].flatMap(Int.init) ?? 0
        integrityStatus = eventPayload["integrity_status"]
            .flatMap(SandboxIntegrityStatus.init(rawValue:)) ?? .notValidated
        sourceUnchanged = eventPayload["source_unchanged"].flatMap {
            switch $0.lowercased() {
            case "true": true
            case "false": false
            default: nil
            }
        }
    }

    init(inspection: SandboxInspection) {
        self.init(
            sandboxID: inspection.descriptor.sandboxID.rawValue,
            sourceSnapshotID: inspection.sourceManifest.snapshotID,
            status: inspection.manifest.status,
            includedFileCount: inspection.manifest.includedFileCount,
            excludedItemCount: inspection.manifest.excludedItemCount,
            integrityStatus: inspection.manifest.integrity.status,
            sourceUnchanged: inspection.descriptor.sourceUnchanged
        )
    }

    var eventPayload: [String: String] {
        [
            "sandbox_id": sandboxID ?? "",
            "source_snapshot_id": sourceSnapshotID ?? "",
            "sandbox_status": status?.rawValue ?? "",
            "included_file_count": String(includedFileCount),
            "excluded_item_count": String(excludedItemCount),
            "integrity_status": integrityStatus.rawValue,
            "source_unchanged": sourceUnchanged.map(String.init) ?? ""
        ]
    }
}

struct SandboxRuntimeActivityUpdate: Codable, Hashable, Sendable {
    var phase: SandboxRuntimeActivityPhase
    var snapshot: SandboxActivitySnapshot
}

enum SandboxExpectedSnapshotResult: String, Codable, Hashable, Sendable {
    case matched
    case changed
    case notProvided = "not_provided"
}

struct SandboxManualAcceptanceResult: Codable, Hashable, Sendable {
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var statusBeforeDestruction: SandboxStatus
    var includedFileCount: Int
    var excludedItemCount: Int
    var integrityStatus: SandboxIntegrityStatus
    var sourceUnchanged: Bool
    var expectedSnapshotResult: SandboxExpectedSnapshotResult
    var destroyed: Bool
    var activities: [SandboxRuntimeActivityUpdate]
}

enum SafeSandboxAcceptanceFailureCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case workspaceNotSelected = "workspace_not_selected"
    case workspaceRootMismatch = "workspace_root_mismatch"
    case sourceUnavailable = "source_unavailable"
    case sourceFileRequiresExternalHydration = "source_file_requires_external_hydration"
    case sourceChanged = "source_changed"
    case sandboxCopyMismatch = "sandbox_copy_mismatch"
    case pathContainmentFailed = "path_containment_failed"
    case insufficientDiskSpace = "insufficient_disk_space"
    case sandboxDestructionFailed = "sandbox_destruction_failed"
    case agentWorkspaceRejected = "agent_workspace_rejected"
    case sandboxRuntimeUnavailable = "sandbox_runtime_unavailable"
    case sandboxAcceptanceFailed = "sandbox_acceptance_failed"

    static func sanitized(error: Error) -> SafeSandboxAcceptanceFailureCategory {
        if let runtimeError = error as? SafeSandboxAcceptanceRuntimeError {
            switch runtimeError {
            case .workspaceNotSelected: return .workspaceNotSelected
            case .workspaceRootMismatch: return .workspaceRootMismatch
            case .runtimeUnavailable: return .sandboxRuntimeUnavailable
            case .sandboxDestructionFailed: return .sandboxDestructionFailed
            }
        }
        if let foundationError = error as? SandboxFoundationError {
            switch foundationError {
            case .sourceUnavailable, .sourceUnreadable, .ambiguousSource:
                return .sourceUnavailable
            case .sourceFileUnavailable:
                return .sourceFileRequiresExternalHydration
            case .sourceSnapshotChanged:
                return .sourceChanged
            case .copyVerificationFailed:
                return .sandboxCopyMismatch
            case .agentWorkspaceRejected:
                return .agentWorkspaceRejected
            case .sourceOutsideApprovedLegacyRoot,
                 .nestedSandboxRootRejected,
                 .sandboxRootInsideLegacyRejected,
                 .absolutePathRejected,
                 .pathTraversalRejected,
                 .metadataPathRejected,
                 .pathEscapeRejected,
                 .symbolicLinkEscapeRejected,
                 .destructionTargetRejected:
                return .pathContainmentFailed
            default:
                return .sandboxAcceptanceFailed
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC) {
            return .insufficientDiskSpace
        }
        return .sandboxAcceptanceFailed
    }
}

enum SafeSandboxAcceptanceRuntimeError: Error, Equatable, Sendable {
    case workspaceNotSelected
    case workspaceRootMismatch
    case runtimeUnavailable
    case sandboxDestructionFailed
}

extension SafeSandboxAcceptanceRuntimeError: LocalizedError {
    var errorDescription: String? {
        SafeSandboxAcceptanceFailureCategory.sanitized(error: self).rawValue
    }
}

struct SafeSandboxAcceptanceReport: Codable, Hashable, Sendable {
    var canonicalLegacyRoot: String
    var sourceAvailability: String
    var sourceSnapshotID: String
    var sandboxID: String
    var lifecycleStates: [SandboxStatus]
    var includedFileCount: Int
    var excludedItemCount: Int
    var hashValidationPassed: Bool
    var inodeIsolationPassed: Bool
    var sensitiveExclusionPassed: Bool
    var sensitiveExcludedItemCount: Int
    var originalLegacyBeforeIntegrity: SourceIntegrityState
    var originalLegacyAfterIntegrity: SourceIntegrityState
    var sandboxDestroyed: Bool
    var phase2D1Started: Bool

    var markdown: String {
        """
        Phase 2D.0 Safe Sandbox acceptance completed from runtime manifests.

        - Canonical Legacy root: `\(canonicalLegacyRoot)`
        - Source availability: \(sourceAvailability)
        - Snapshot ID: `\(sourceSnapshotID)`
        - Sandbox ID: `\(sandboxID)`
        - Lifecycle states: \(lifecycleStates.map(\.rawValue).joined(separator: " → "))
        - Included / excluded: \(includedFileCount) / \(excludedItemCount)
        - SHA-256 validation: \(hashValidationPassed ? "passed" : "failed")
        - Inode isolation: \(inodeIsolationPassed ? "passed" : "failed")
        - Sensitive exclusion: \(sensitiveExclusionPassed ? "passed" : "failed") (\(sensitiveExcludedItemCount) sensitive item(s) excluded)
        - Original Legacy integrity before / after: \(originalLegacyBeforeIntegrity.rawValue) / \(originalLegacyAfterIntegrity.rawValue)
        - Sandbox destruction: \(sandboxDestroyed ? "passed" : "failed")
        - Phase 2D.1 started: \(phase2D1Started ? "yes" : "no")
        """
    }

    var eventPayload: [String: String] {
        [
            "canonical_legacy_root": canonicalLegacyRoot,
            "source_availability": sourceAvailability,
            "source_snapshot_id": sourceSnapshotID,
            "sandbox_id": sandboxID,
            "lifecycle_states": lifecycleStates.map(\.rawValue).joined(separator: " | "),
            "included_file_count": String(includedFileCount),
            "excluded_item_count": String(excludedItemCount),
            "hash_validation_passed": String(hashValidationPassed),
            "inode_isolation_passed": String(inodeIsolationPassed),
            "sensitive_exclusion_passed": String(sensitiveExclusionPassed),
            "sensitive_excluded_item_count": String(sensitiveExcludedItemCount),
            "original_legacy_before_integrity": originalLegacyBeforeIntegrity.rawValue,
            "original_legacy_after_integrity": originalLegacyAfterIntegrity.rawValue,
            "sandbox_destroyed": String(sandboxDestroyed),
            "phase_2d_1_started": String(phase2D1Started),
            "manifest_backed": "true"
        ]
    }
}

enum SafeSandboxAcceptanceRequest {
    static func assertedAbsoluteRoots(in input: String) -> [String] {
        let boundaries = CharacterSet(charactersIn: "\"'“”‘’`，。；;！？!?、()（）[]{}<>")
        let separators = CharacterSet.whitespacesAndNewlines.union(boundaries)
        return input
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: boundaries) }
            .filter { NSString(string: $0).isAbsolutePath }
    }
}

struct SandboxManualAcceptanceRunner: Sendable {
    let lifecycle: SandboxLifecycleService

    func run(
        legacyRoot: URL,
        approvedLegacyRoot: URL,
        expectedSourceSnapshotID: String? = nil,
        destroyAfterInspection: Bool = true
    ) throws -> SandboxManualAcceptanceResult {
        var activities: [SandboxRuntimeActivityUpdate] = [
            SandboxRuntimeActivityUpdate(phase: .validatingLegacySource, snapshot: .empty),
            SandboxRuntimeActivityUpdate(phase: .creatingIsolatedSandbox, snapshot: .empty),
            SandboxRuntimeActivityUpdate(phase: .copyingApprovedSourceFiles, snapshot: .empty),
            SandboxRuntimeActivityUpdate(phase: .excludingSensitiveFiles, snapshot: .empty)
        ]
        do {
            let inspection = try lifecycle.createSandbox(
                sourceRoot: legacyRoot,
                approvedLegacyRoot: approvedLegacyRoot
            )
            var snapshot = SandboxActivitySnapshot(
                sandboxID: inspection.descriptor.sandboxID.rawValue,
                sourceSnapshotID: inspection.descriptor.sourceSnapshotID,
                status: inspection.descriptor.status,
                includedFileCount: inspection.descriptor.includedFileCount,
                excludedItemCount: inspection.descriptor.excludedItemCount,
                integrityStatus: inspection.descriptor.integrityStatus,
                sourceUnchanged: inspection.descriptor.sourceUnchanged
            )
            activities.append(.init(phase: .verifyingFileHashes, snapshot: snapshot))
            activities.append(.init(phase: .checkingPathContainment, snapshot: snapshot))
            let resolver = SandboxPathResolver(storageRoot: lifecycle.storageRoot)
            _ = try resolver.resolve(sandboxID: inspection.descriptor.sandboxID, relativePath: ".")
            let sourceCheck = try lifecycle.checkSourceIntegrity(inspection.descriptor.sandboxID)
            snapshot.sourceUnchanged = sourceCheck.isUnchanged
            activities.append(.init(phase: .confirmingSourceIsolation, snapshot: snapshot))
            activities.append(.init(phase: .sandboxReady, snapshot: snapshot))

            let expectedResult: SandboxExpectedSnapshotResult
            if let expectedSourceSnapshotID {
                expectedResult = expectedSourceSnapshotID == inspection.sourceManifest.snapshotID ? .matched : .changed
            } else {
                expectedResult = .notProvided
            }
            var destroyed = false
            if destroyAfterInspection {
                activities.append(.init(phase: .destroyingSandbox, snapshot: snapshot))
                _ = try lifecycle.destroySandbox(inspection.descriptor.sandboxID)
                destroyed = true
            }
            return SandboxManualAcceptanceResult(
                sandboxID: inspection.descriptor.sandboxID,
                sourceSnapshotID: inspection.descriptor.sourceSnapshotID,
                statusBeforeDestruction: inspection.descriptor.status,
                includedFileCount: inspection.descriptor.includedFileCount,
                excludedItemCount: inspection.descriptor.excludedItemCount,
                integrityStatus: inspection.descriptor.integrityStatus,
                sourceUnchanged: sourceCheck.isUnchanged,
                expectedSnapshotResult: expectedResult,
                destroyed: destroyed,
                activities: activities
            )
        } catch {
            activities.append(.init(phase: .sandboxCreationBlocked, snapshot: .empty))
            throw error
        }
    }
}
