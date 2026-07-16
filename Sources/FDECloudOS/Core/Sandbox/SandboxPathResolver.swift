import Foundation

struct SandboxPathResolver: Sendable {
    let storageRoot: URL

    func resolve(
        sandboxID: SandboxID,
        relativePath: String,
        metadataAccessAuthorized: Bool = false
    ) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SandboxFoundationError.pathTraversalRejected }
        guard !NSString(string: trimmed).isAbsolutePath,
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\"),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SandboxFoundationError.absolutePathRejected
        }

        let components: [String]
        if trimmed == "." {
            components = []
        } else {
            components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw SandboxFoundationError.pathTraversalRejected
            }
        }
        if !metadataAccessAuthorized,
           components.contains(where: { Self.reservedMetadataComponents.contains($0.lowercased()) }) {
            throw SandboxFoundationError.metadataPathRejected
        }

        let store = SandboxManifestStore(storageRoot: storageRoot)
        let sandboxDirectory = try store.validatedSandboxDirectory(sandboxID)
        _ = try store.load(sandboxID)
        let workspace = sandboxDirectory.appendingPathComponent("workspace", isDirectory: true)
        let canonicalWorkspace = try SandboxFileSystem.canonicalExistingDirectory(workspace)
        guard SandboxFileSystem.isDirectChild(canonicalWorkspace, of: sandboxDirectory),
              !(try SandboxFileSystem.isSymbolicLink(workspace)) else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }

        var cursor = canonicalWorkspace
        for (index, component) in components.enumerated() {
            let next = cursor.appendingPathComponent(component)
            if SandboxFileSystem.entryExistsWithoutFollowingLinks(next) {
                if try SandboxFileSystem.isSymbolicLink(next) {
                    // Phase 2D.0 copies no links, so any link later found in a writable path is
                    // unexpected. Rejecting all links avoids dangling-link and TOCTOU ambiguity.
                    throw SandboxFoundationError.symbolicLinkEscapeRejected
                } else {
                    cursor = next.resolvingSymlinksInPath().standardizedFileURL
                }
                if index < components.count - 1,
                   SandboxFileSystem.entryExistsWithoutFollowingLinks(cursor) {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: cursor.path, isDirectory: &isDirectory),
                          isDirectory.boolValue else {
                        throw SandboxFoundationError.pathEscapeRejected
                    }
                }
            } else {
                cursor = next.standardizedFileURL
            }
            guard SandboxFileSystem.isContained(cursor, in: canonicalWorkspace) else {
                throw SandboxFoundationError.pathEscapeRejected
            }
        }
        return cursor
    }

    private static let reservedMetadataComponents: Set<String> = [
        ".fde-sandbox-metadata", "sandbox-manifest.json", "source-manifest.json"
    ]
}
