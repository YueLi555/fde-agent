import Foundation

struct SandboxID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        let normalized = rawValue.lowercased()
        guard normalized == rawValue,
              normalized.count == 36,
              UUID(uuidString: normalized) != nil,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef-").contains($0)
              }) else {
            return nil
        }
        self.rawValue = normalized
    }

    init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    var description: String { rawValue }
}

enum SandboxStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case creating
    case validating
    case ready
    case invalid
    case stale
    case tainted
    case destroying
    case destroyed

    var permitsFutureMutation: Bool { self == .ready }
}

enum SandboxExclusionReason: String, Codable, CaseIterable, Hashable, Sendable {
    case versionControlMetadata = "version_control_metadata"
    case buildArtifact = "build_artifact"
    case dependencyDirectory = "dependency_directory"
    case cacheOrTemporary = "cache_or_temporary"
    case environmentFile = "environment_file"
    case credentialMaterial = "credential_material"
    case privateKey = "private_key"
    case certificate = "certificate"
    case tokenFile = "token_file"
    case operatingSystemMetadata = "operating_system_metadata"
    case symbolicLink = "symbolic_link"
    case unsupportedFileType = "unsupported_file_type"
}

struct SandboxExclusion: Codable, Hashable, Sendable {
    var relativePath: String
    var reason: SandboxExclusionReason
    var size: UInt64? = nil
    var modificationTimeNanoseconds: Int64? = nil
}

struct SourceFileRecord: Codable, Hashable, Sendable {
    var relativeCanonicalPath: String
    var sha256: String
    var size: UInt64
    var modificationTimeNanoseconds: Int64
    var deviceID: UInt64
    var inode: UInt64
}

struct SourceSnapshotManifest: Codable, Hashable, Sendable {
    var snapshotID: String
    var canonicalSourceRoot: String
    var sourceRootDeviceID: UInt64
    var sourceRootInode: UInt64
    var createdAt: Date
    var files: [SourceFileRecord]
    var exclusions: [SandboxExclusion]

    var includedFileCount: Int { files.count }
    var excludedItemCount: Int { exclusions.count }
}

enum SandboxIntegrityStatus: String, Codable, Hashable, Sendable {
    case notValidated = "not_validated"
    case passed
    case failed
}

struct SandboxIntegrityValidation: Codable, Hashable, Sendable {
    var status: SandboxIntegrityStatus
    var checkedAt: Date?
    var copiedFileCount: Int
    var matchingHashCount: Int
    var independentlyStoredFileCount: Int
    var sensitiveItemsFound: Int
    var escapingLinkCount: Int
    var failures: [String]

    static let pending = SandboxIntegrityValidation(
        status: .notValidated,
        checkedAt: nil,
        copiedFileCount: 0,
        matchingHashCount: 0,
        independentlyStoredFileCount: 0,
        sensitiveItemsFound: 0,
        escapingLinkCount: 0,
        failures: []
    )
}

struct SandboxManifest: Codable, Hashable, Sendable {
    var formatVersion: Int
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var status: SandboxStatus
    var createdAt: Date
    var updatedAt: Date
    var includedFileCount: Int
    var excludedItemCount: Int
    var integrity: SandboxIntegrityValidation
    var exclusions: [SandboxExclusion]
}

struct SandboxDescriptor: Codable, Hashable, Sendable, Identifiable {
    var sandboxID: SandboxID
    var sourceSnapshotID: String
    var status: SandboxStatus
    var sourceDisplayName: String
    var includedFileCount: Int
    var excludedItemCount: Int
    var integrityStatus: SandboxIntegrityStatus
    var sourceUnchanged: Bool?

    var id: String { sandboxID.rawValue }
}

struct SandboxInspection: Codable, Hashable, Sendable {
    var descriptor: SandboxDescriptor
    var manifest: SandboxManifest
    var sourceManifest: SourceSnapshotManifest
}

enum SourceIntegrityState: String, Codable, Hashable, Sendable {
    case unchanged
    case changed
    case moved
    case inaccessible
    case ambiguous
}

struct SourceIntegrityCheck: Codable, Hashable, Sendable {
    var state: SourceIntegrityState
    var checkedAt: Date
    var expectedSnapshotID: String
    var observedSnapshotID: String?
    var changedFileCount: Int
    var addedFileCount: Int
    var removedFileCount: Int
    var exclusionChangeCount: Int
    var safeSummary: String

    var isUnchanged: Bool { state == .unchanged }
}

enum SandboxFoundationError: Error, Equatable, Sendable {
    case invalidSandboxID
    case duplicateSandboxID
    case sourceUnavailable
    case sourceUnreadable
    case sourceFileUnavailable
    case sourceOutsideApprovedLegacyRoot
    case agentWorkspaceRejected
    case nestedSandboxRootRejected
    case sandboxRootInsideLegacyRejected
    case ambiguousSource
    case unsafeSourceEntry
    case copyVerificationFailed
    case sandboxNotFound
    case sandboxMetadataInvalid
    case invalidStatusTransition
    case absolutePathRejected
    case pathTraversalRejected
    case metadataPathRejected
    case pathEscapeRejected
    case symbolicLinkEscapeRejected
    case sourceSnapshotChanged
    case operationNotAllowed
    case approvalRequired
    case destructionTargetRejected
}

extension SandboxFoundationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidSandboxID: "Sandbox ID is invalid."
        case .duplicateSandboxID: "Sandbox ID already exists."
        case .sourceUnavailable: "Legacy source is unavailable."
        case .sourceUnreadable: "Legacy source is not readable."
        case .sourceFileUnavailable: "A Legacy source file is unavailable without external hydration."
        case .sourceOutsideApprovedLegacyRoot: "Source is outside the approved Legacy workspace."
        case .agentWorkspaceRejected: "Agent workspace paths cannot be used as a Legacy Sandbox source."
        case .nestedSandboxRootRejected: "A Sandbox root cannot be used as a Legacy source."
        case .sandboxRootInsideLegacyRejected: "Sandbox storage must remain outside the Legacy source."
        case .ambiguousSource: "Legacy source identity is ambiguous."
        case .unsafeSourceEntry: "The source contains an entry that cannot be copied safely."
        case .copyVerificationFailed: "Sandbox copy verification failed."
        case .sandboxNotFound: "Sandbox was not found."
        case .sandboxMetadataInvalid: "Sandbox metadata is invalid."
        case .invalidStatusTransition: "Sandbox status transition is not allowed."
        case .absolutePathRejected: "Absolute Sandbox target paths are not allowed."
        case .pathTraversalRejected: "Sandbox target path traversal is not allowed."
        case .metadataPathRejected: "Sandbox metadata paths are not writable."
        case .pathEscapeRejected: "Sandbox target resolves outside its workspace."
        case .symbolicLinkEscapeRejected: "Sandbox target crosses an escaping symbolic link."
        case .sourceSnapshotChanged: "The Legacy source no longer matches the Sandbox snapshot."
        case .operationNotAllowed: "This writable operation is unavailable in Phase 2D.0."
        case .approvalRequired: "Human approval is required."
        case .destructionTargetRejected: "Sandbox destruction target failed containment validation."
        }
    }
}
