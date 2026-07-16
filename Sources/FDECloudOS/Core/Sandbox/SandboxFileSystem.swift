import CryptoKit
import Darwin
import Foundation

enum SandboxFileSystem {
    static func canonicalExistingDirectory(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SandboxFoundationError.sourceUnavailable
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL
    }

    static func canonicalPotential(_ url: URL) throws -> URL {
        var candidate = url.standardizedFileURL
        var missingComponents: [String] = []
        while !FileManager.default.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                throw SandboxFoundationError.ambiguousSource
            }
            missingComponents.insert(candidate.lastPathComponent, at: 0)
            candidate = parent
        }
        var canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        for component in missingComponents {
            canonical.appendPathComponent(component)
        }
        return canonical.standardizedFileURL
    }

    static func isContained(_ candidate: URL, in root: URL, allowRoot: Bool = true) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard candidateComponents.count >= rootComponents.count,
              Array(candidateComponents.prefix(rootComponents.count)) == rootComponents else {
            return false
        }
        return allowRoot || candidateComponents.count > rootComponents.count
    }

    static func isDirectChild(_ candidate: URL, of root: URL) -> Bool {
        candidate.standardizedFileURL.deletingLastPathComponent().path
            == root.standardizedFileURL.path
    }

    static func isSymbolicLink(_ url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    static func entryExistsWithoutFollowingLinks(_ url: URL) -> Bool {
        var info = stat()
        return url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return Darwin.lstat(path, &info) == 0
        }
    }

    static func identity(of url: URL) throws -> FileIdentity {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else { throw SandboxFoundationError.ambiguousSource }
        return FileIdentity(
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            modificationTimeNanoseconds: modificationTimeNanoseconds(info),
            isDataless: (info.st_flags & UInt32(SF_DATALESS)) != 0
        )
    }

    static func secureFileRecord(at url: URL, relativePath: String) throws -> SourceFileRecord {
        let handle = try secureReadHandle(at: url)
        defer { try? handle.close() }
        let before = try descriptorIdentity(handle.fileDescriptor)
        guard before.isRegularFile else { throw SandboxFoundationError.unsafeSourceEntry }
        guard !before.isDataless else { throw SandboxFoundationError.sourceFileUnavailable }

        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let after = try descriptorIdentity(handle.fileDescriptor)
        guard before == after else { throw SandboxFoundationError.ambiguousSource }

        return SourceFileRecord(
            relativeCanonicalPath: relativePath,
            sha256: hex(hasher.finalize()),
            size: before.size,
            modificationTimeNanoseconds: before.modificationTimeNanoseconds,
            deviceID: before.deviceID,
            inode: before.inode
        )
    }

    static func sha256(at url: URL) throws -> (hash: String, identity: FileIdentity) {
        let handle = try secureReadHandle(at: url)
        defer { try? handle.close() }
        let before = try descriptorIdentity(handle.fileDescriptor)
        guard before.isRegularFile else { throw SandboxFoundationError.unsafeSourceEntry }
        guard !before.isDataless else { throw SandboxFoundationError.sourceFileUnavailable }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let after = try descriptorIdentity(handle.fileDescriptor)
        guard before == after else { throw SandboxFoundationError.ambiguousSource }
        return (hex(hasher.finalize()), before)
    }

    static func physicallyCopy(
        source: URL,
        destination: URL,
        expected: SourceFileRecord
    ) throws {
        let sourceHandle = try secureReadHandle(at: source)
        defer { try? sourceHandle.close() }
        let sourceIdentity = try descriptorIdentity(sourceHandle.fileDescriptor)
        guard sourceIdentity.isRegularFile,
              !sourceIdentity.isDataless,
              sourceIdentity.deviceID == expected.deviceID,
              sourceIdentity.inode == expected.inode,
              sourceIdentity.size == expected.size,
              sourceIdentity.modificationTimeNanoseconds == expected.modificationTimeNanoseconds else {
            throw SandboxFoundationError.sourceSnapshotChanged
        }

        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw SandboxFoundationError.copyVerificationFailed
        }
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".fde-copy-\(UUID().uuidString.lowercased())")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw SandboxFoundationError.copyVerificationFailed
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        let destinationHandle = try FileHandle(forWritingTo: temporary)
        defer { try? destinationHandle.close() }
        var hasher = SHA256()
        var copiedBytes: UInt64 = 0
        while let data = try sourceHandle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
            copiedBytes += UInt64(data.count)
            try destinationHandle.write(contentsOf: data)
        }
        try destinationHandle.synchronize()

        let finalSourceIdentity = try descriptorIdentity(sourceHandle.fileDescriptor)
        guard finalSourceIdentity == sourceIdentity,
              copiedBytes == expected.size,
              hex(hasher.finalize()) == expected.sha256 else {
            throw SandboxFoundationError.sourceSnapshotChanged
        }

        try FileManager.default.moveItem(at: temporary, to: destination)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        var copiedAttributes: [FileAttributeKey: Any] = [:]
        if let permissions = attributes[.posixPermissions] {
            copiedAttributes[.posixPermissions] = permissions
        }
        if let modificationDate = attributes[.modificationDate] {
            copiedAttributes[.modificationDate] = modificationDate
        }
        if !copiedAttributes.isEmpty {
            try FileManager.default.setAttributes(copiedAttributes, ofItemAtPath: destination.path)
        }
    }

    static func stableSHA256(_ components: [String]) -> String {
        let payload = components.joined(separator: "\u{1f}")
        return hex(SHA256.hash(data: Data(payload.utf8)))
    }

    private static func secureReadHandle(at url: URL) throws -> FileHandle {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw SandboxFoundationError.unsafeSourceEntry }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func descriptorIdentity(_ descriptor: Int32) throws -> FileIdentity {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw SandboxFoundationError.ambiguousSource
        }
        return FileIdentity(
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            modificationTimeNanoseconds: modificationTimeNanoseconds(info),
            isRegularFile: (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
            isDataless: (info.st_flags & UInt32(SF_DATALESS)) != 0
        )
    }

    private static func modificationTimeNanoseconds(_ info: stat) -> Int64 {
        Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct FileIdentity: Equatable, Sendable {
    var deviceID: UInt64
    var inode: UInt64
    var size: UInt64
    var modificationTimeNanoseconds: Int64
    var isRegularFile: Bool = false
    var isDataless: Bool = false
}

struct SourceSnapshotBuilder: Sendable {
    var exclusionPolicy = SandboxExclusionPolicy()

    func build(root: URL, createdAt: Date = Date()) throws -> SourceSnapshotManifest {
        let canonicalRoot = try SandboxFileSystem.canonicalExistingDirectory(root)
        guard FileManager.default.isReadableFile(atPath: canonicalRoot.path) else {
            throw SandboxFoundationError.sourceUnreadable
        }
        let rootIdentity = try SandboxFileSystem.identity(of: canonicalRoot)
        var files: [SourceFileRecord] = []
        var exclusions: [SandboxExclusion] = []
        try walk(
            directory: canonicalRoot,
            canonicalRoot: canonicalRoot,
            relativeDirectory: "",
            files: &files,
            exclusions: &exclusions
        )
        files.sort { $0.relativeCanonicalPath < $1.relativeCanonicalPath }
        exclusions.sort {
            ($0.relativePath, $0.reason.rawValue) < ($1.relativePath, $1.reason.rawValue)
        }
        let snapshotComponents = [
            "root-device=\(rootIdentity.deviceID)",
            "root-inode=\(rootIdentity.inode)"
        ] + files.map {
            "file=\($0.relativeCanonicalPath)|\($0.sha256)|\($0.size)|\($0.modificationTimeNanoseconds)|\($0.deviceID)|\($0.inode)"
        } + exclusions.map {
            "excluded=\($0.relativePath)|\($0.reason.rawValue)|\($0.size.map(String.init) ?? "unknown")|\($0.modificationTimeNanoseconds.map(String.init) ?? "unknown")"
        }
        return SourceSnapshotManifest(
            snapshotID: SandboxFileSystem.stableSHA256(snapshotComponents),
            canonicalSourceRoot: canonicalRoot.path,
            sourceRootDeviceID: rootIdentity.deviceID,
            sourceRootInode: rootIdentity.inode,
            createdAt: createdAt,
            files: files,
            exclusions: exclusions
        )
    }

    private func walk(
        directory: URL,
        canonicalRoot: URL,
        relativeDirectory: String,
        files: inout [SourceFileRecord],
        exclusions: inout [SandboxExclusion]
    ) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }

        for entry in entries {
            let relativePath = relativeDirectory.isEmpty
                ? entry.lastPathComponent
                : "\(relativeDirectory)/\(entry.lastPathComponent)"
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            if values.isSymbolicLink == true {
                exclusions.append(exclusion(entry: entry, relativePath: relativePath, reason: .symbolicLink))
                continue
            }
            let isDirectory = values.isDirectory == true
            if let reason = exclusionPolicy.exclusion(
                forRelativePath: relativePath,
                isDirectory: isDirectory
            ) {
                exclusions.append(exclusion(entry: entry, relativePath: relativePath, reason: reason))
                continue
            }
            if isDirectory {
                let canonicalEntry = entry.resolvingSymlinksInPath().standardizedFileURL
                guard SandboxFileSystem.isContained(canonicalEntry, in: canonicalRoot, allowRoot: false) else {
                    throw SandboxFoundationError.unsafeSourceEntry
                }
                try walk(
                    directory: canonicalEntry,
                    canonicalRoot: canonicalRoot,
                    relativeDirectory: relativePath,
                    files: &files,
                    exclusions: &exclusions
                )
            } else if values.isRegularFile == true {
                guard !(try SandboxFileSystem.identity(of: entry).isDataless) else {
                    throw SandboxFoundationError.sourceFileUnavailable
                }
                files.append(try SandboxFileSystem.secureFileRecord(
                    at: entry,
                    relativePath: relativePath
                ))
            } else {
                exclusions.append(exclusion(
                    entry: entry,
                    relativePath: relativePath,
                    reason: .unsupportedFileType
                ))
            }
        }
    }

    private func exclusion(
        entry: URL,
        relativePath: String,
        reason: SandboxExclusionReason
    ) -> SandboxExclusion {
        let identity = try? SandboxFileSystem.identity(of: entry)
        return SandboxExclusion(
            relativePath: relativePath,
            reason: reason,
            size: identity?.size,
            modificationTimeNanoseconds: identity?.modificationTimeNanoseconds
        )
    }
}
