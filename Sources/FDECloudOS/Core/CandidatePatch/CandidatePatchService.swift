import CryptoKit
import Darwin
import Foundation

protocol CandidatePatchDiskSpaceChecking: Sendable {
    func availableBytes(at url: URL) throws -> UInt64
}

struct LocalCandidatePatchDiskSpaceChecker: CandidatePatchDiskSpaceChecking {
    func availableBytes(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let capacity = values.volumeAvailableCapacityForImportantUsage, capacity >= 0 else {
            throw CandidatePatchError.blocked(.insufficientDiskSpace)
        }
        return UInt64(capacity)
    }
}

struct CandidatePatchLegacyIntegrityMonitor: Sendable {
    func capture(root: URL, createdAt: Date = Date()) throws -> CandidatePatchLegacyIntegrityBaseline {
        let canonicalRoot = try SandboxFileSystem.canonicalExistingDirectory(root)
        let rootStat = try metadata(at: canonicalRoot)
        var records: [String] = []
        try walk(directory: canonicalRoot, root: canonicalRoot, records: &records)
        records.sort()
        return CandidatePatchLegacyIntegrityBaseline(
            canonicalLegacyRoot: canonicalRoot.path,
            rootDeviceID: rootStat.deviceID,
            rootInode: rootStat.inode,
            fingerprint: CandidatePatchSecureFileIO.stableSHA256(records),
            entryCount: records.count,
            createdAt: createdAt
        )
    }

    func verify(_ baseline: CandidatePatchLegacyIntegrityBaseline) -> SourceIntegrityState {
        do {
            let current = try capture(root: URL(fileURLWithPath: baseline.canonicalLegacyRoot, isDirectory: true))
            guard current.canonicalLegacyRoot == baseline.canonicalLegacyRoot,
                  current.rootDeviceID == baseline.rootDeviceID,
                  current.rootInode == baseline.rootInode else {
                return .moved
            }
            return current.fingerprint == baseline.fingerprint && current.entryCount == baseline.entryCount
                ? .unchanged
                : .changed
        } catch SandboxFoundationError.ambiguousSource {
            return .ambiguous
        } catch SandboxFoundationError.sourceUnavailable {
            return .inaccessible
        } catch {
            return .inaccessible
        }
    }

    private func walk(directory: URL, root: URL, records: inout [String]) throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        for entry in entries {
            let item = try metadata(at: entry)
            let relative = String(entry.path.dropFirst(root.path.count + 1))
            let type: String
            let contentFingerprint: String
            switch item.kind {
            case .regular:
                guard !item.isDataless else { throw SandboxFoundationError.sourceFileUnavailable }
                type = "file"
                contentFingerprint = try CandidatePatchSecureFileIO.sha256(at: entry).hash
            case .directory:
                type = "directory"
                contentFingerprint = "-"
            case .symbolicLink:
                type = "symlink"
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: entry.path)
                contentFingerprint = CandidatePatchSecureFileIO.sha256(Data(destination.utf8))
            case .other:
                throw SandboxFoundationError.unsafeSourceEntry
            }
            records.append([
                relative, type, String(item.deviceID), String(item.inode), String(item.size),
                String(item.modificationTimeNanoseconds), String(item.permissions), String(item.ownerID),
                String(item.groupID), String(item.linkCount), contentFingerprint
            ].joined(separator: "|"))
            if item.kind == .directory {
                try walk(directory: entry, root: root, records: &records)
            }
        }
    }

    private func metadata(at url: URL) throws -> CandidatePatchRawMetadata {
        try CandidatePatchSecureFileIO.rawMetadata(at: url)
    }
}

private enum CandidatePatchEntryKind: Equatable {
    case regular
    case directory
    case symbolicLink
    case other
}

private struct CandidatePatchRawMetadata {
    var kind: CandidatePatchEntryKind
    var deviceID: UInt64
    var inode: UInt64
    var size: UInt64
    var modificationTimeNanoseconds: Int64
    var permissions: UInt16
    var ownerID: UInt32
    var groupID: UInt32
    var linkCount: UInt64
    var isDataless: Bool

    var publicMetadata: CandidatePatchFileMetadata {
        CandidatePatchFileMetadata(
            sha256: "",
            size: size,
            permissions: permissions,
            deviceID: deviceID,
            inode: inode,
            linkCount: linkCount
        )
    }
}

enum CandidatePatchMutationInterlockPoint: Sendable {
    case beforeMutation
    case beforeAtomicRename
    case beforeUnlink
}

typealias CandidatePatchMutationInterlock = @Sendable (
    _ point: CandidatePatchMutationInterlockPoint,
    _ relativePath: String
) throws -> Void

private enum CandidatePatchSecureFileIO {

    final class Workspace: @unchecked Sendable {
        private final class Descriptor {
            let value: Int32

            init(_ value: Int32) {
                self.value = value
            }

            deinit {
                Darwin.close(value)
            }
        }

        private struct DirectoryLink {
            var name: String
            var expectedDeviceID: UInt64
            var expectedInode: UInt64
        }

        private struct ResolvedParent {
            var descriptors: [Descriptor]
            var links: [DirectoryLink]
            var targetName: String

            var parentDescriptor: Int32 {
                descriptors[descriptors.count - 1].value
            }
        }

        private let rootDescriptor: Descriptor
        private let rootDeviceID: UInt64
        private let rootInode: UInt64
        private let interlock: CandidatePatchMutationInterlock?

        init(root: URL, interlock: CandidatePatchMutationInterlock?) throws {
            let descriptor = root.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            let owned = Descriptor(descriptor)
            let metadata = try CandidatePatchSecureFileIO.descriptorMetadata(descriptor)
            guard metadata.kind == .directory else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            self.rootDescriptor = owned
            self.rootDeviceID = metadata.deviceID
            self.rootInode = metadata.inode
            self.interlock = interlock
        }

        func preflightCreate(relativePath: String) throws {
            let parent = try resolveParent(relativePath)
            try verifyDirectoryChain(parent)
            guard try metadataAt(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                missingAllowed: true
            ) == nil else {
                throw CandidatePatchError.blocked(.sandboxPreimageChanged)
            }
        }

        func preflightReplace(
            relativePath: String,
            expectedSHA256: String,
            expectedData: Data?
        ) throws {
            let parent = try resolveParent(relativePath)
            try verifyDirectoryChain(parent)
            let opened = try openRegularFile(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                writable: false
            )
            let data = try CandidatePatchSecureFileIO.readAll(
                descriptor: opened.descriptor.value,
                size: opened.metadata.size
            )
            guard CandidatePatchSecureFileIO.sha256(data) == expectedSHA256,
                  expectedData == nil || expectedData == data else {
                throw CandidatePatchError.blocked(.sandboxPreimageChanged)
            }
            try verifyFinalEntry(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                expected: opened.metadata
            )
        }

        func createText(
            relativePath: String,
            content: Data
        ) throws -> CandidatePatchFileMetadata {
            let parent = try resolveParent(relativePath)
            try interlock?(.beforeMutation, relativePath)
            try verifyDirectoryChain(parent)
            guard try metadataAt(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                missingAllowed: true
            ) == nil else {
                throw CandidatePatchError.blocked(.targetAlreadyExists)
            }

            let temporaryName = ".fde-candidate-\(UUID().uuidString.lowercased()).tmp"
            let temporary = try createTemporaryFile(
                parentDescriptor: parent.parentDescriptor,
                name: temporaryName,
                permissions: 0o600,
                content: content
            )
            var renamed = false
            defer {
                if !renamed {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(parent.parentDescriptor, $0, 0)
                    }
                }
            }
            try interlock?(.beforeAtomicRename, relativePath)
            try verifyDirectoryChain(parent)
            guard try metadataAt(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                missingAllowed: true
            ) == nil else {
                throw CandidatePatchError.blocked(.targetAlreadyExists)
            }
            let renameResult = temporaryName.withCString { temporaryPath in
                parent.targetName.withCString { targetPath in
                    Darwin.renameatx_np(
                        parent.parentDescriptor,
                        temporaryPath,
                        parent.parentDescriptor,
                        targetPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
            guard renameResult == 0 else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            renamed = true
            try verifyDirectoryChain(parent)
            let created = try openRegularFile(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                writable: false
            )
            guard created.metadata.deviceID == temporary.metadata.deviceID,
                  created.metadata.inode == temporary.metadata.inode,
                  created.metadata.linkCount == 1,
                  created.metadata.permissions & 0o111 == 0 else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            var metadata = created.metadata.publicMetadata
            metadata.sha256 = CandidatePatchSecureFileIO.sha256(content)
            return metadata
        }

        func replaceText(
            relativePath: String,
            expectedSHA256: String,
            content: Data
        ) throws -> (
            before: Data,
            beforeMetadata: CandidatePatchFileMetadata,
            afterMetadata: CandidatePatchFileMetadata
        ) {
            let parent = try resolveParent(relativePath)
            try interlock?(.beforeMutation, relativePath)
            try verifyDirectoryChain(parent)
            let existing = try openRegularFile(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                writable: false
            )
            let before = try CandidatePatchSecureFileIO.readAll(
                descriptor: existing.descriptor.value,
                size: existing.metadata.size
            )
            guard String(data: before, encoding: .utf8) != nil,
                  !before.contains(0) else {
                throw CandidatePatchError.blocked(.binaryFileRejected)
            }
            let beforeHash = CandidatePatchSecureFileIO.sha256(before)
            guard beforeHash == expectedSHA256 else {
                throw CandidatePatchError.blocked(.sandboxPreimageChanged)
            }
            try verifyFinalEntry(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                expected: existing.metadata
            )

            let temporaryName = ".fde-candidate-\(UUID().uuidString.lowercased()).tmp"
            let temporary = try createTemporaryFile(
                parentDescriptor: parent.parentDescriptor,
                name: temporaryName,
                permissions: existing.metadata.permissions,
                content: content
            )
            var renamed = false
            defer {
                if !renamed {
                    _ = temporaryName.withCString {
                        Darwin.unlinkat(parent.parentDescriptor, $0, 0)
                    }
                }
            }
            try interlock?(.beforeAtomicRename, relativePath)
            try verifyDirectoryChain(parent)
            try verifyFinalEntry(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                expected: existing.metadata
            )
            let renameResult = temporaryName.withCString { temporaryPath in
                parent.targetName.withCString { targetPath in
                    Darwin.renameat(
                        parent.parentDescriptor,
                        temporaryPath,
                        parent.parentDescriptor,
                        targetPath
                    )
                }
            }
            guard renameResult == 0 else {
                throw CandidatePatchError.blocked(.partialApplication)
            }
            renamed = true
            try verifyDirectoryChain(parent)
            let replaced = try openRegularFile(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                writable: false
            )
            let afterData = try CandidatePatchSecureFileIO.readAll(
                descriptor: replaced.descriptor.value,
                size: replaced.metadata.size
            )
            guard replaced.metadata.deviceID == temporary.metadata.deviceID,
                  replaced.metadata.inode == temporary.metadata.inode,
                  replaced.metadata.permissions == existing.metadata.permissions,
                  replaced.metadata.ownerID == existing.metadata.ownerID,
                  replaced.metadata.groupID == existing.metadata.groupID,
                  replaced.metadata.linkCount == 1,
                  afterData == content else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            var beforeMetadata = existing.metadata.publicMetadata
            beforeMetadata.sha256 = beforeHash
            var afterMetadata = replaced.metadata.publicMetadata
            afterMetadata.sha256 = CandidatePatchSecureFileIO.sha256(afterData)
            return (before, beforeMetadata, afterMetadata)
        }

        func removeCreatedText(relativePath: String, expectedSHA256: String) throws {
            let parent = try resolveParent(relativePath)
            try interlock?(.beforeMutation, relativePath)
            try verifyDirectoryChain(parent)
            let existing = try openRegularFile(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                writable: false
            )
            let data = try CandidatePatchSecureFileIO.readAll(
                descriptor: existing.descriptor.value,
                size: existing.metadata.size
            )
            guard CandidatePatchSecureFileIO.sha256(data) == expectedSHA256 else {
                throw CandidatePatchError.blocked(.currentPatchImageChanged)
            }
            try interlock?(.beforeUnlink, relativePath)
            try verifyDirectoryChain(parent)
            try verifyFinalEntry(
                parentDescriptor: parent.parentDescriptor,
                name: parent.targetName,
                expected: existing.metadata
            )
            let result = parent.targetName.withCString {
                Darwin.unlinkat(parent.parentDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw CandidatePatchError.blocked(.revertUnavailable)
            }
            try verifyDirectoryChain(parent)
        }

        private func resolveParent(_ relativePath: String) throws -> ResolvedParent {
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw CandidatePatchError.blocked(.traversalRejected)
            }
            let duplicatedRoot = Darwin.fcntl(rootDescriptor.value, F_DUPFD_CLOEXEC, 0)
            guard duplicatedRoot >= 0 else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            var descriptors = [Descriptor(duplicatedRoot)]
            var links: [DirectoryLink] = []
            for component in components.dropLast() {
                let parent = descriptors[descriptors.count - 1].value
                guard let before = try metadataAt(
                    parentDescriptor: parent,
                    name: component,
                    missingAllowed: false
                ), before.kind == .directory,
                   before.deviceID == rootDeviceID else {
                    throw CandidatePatchError.blocked(.pathContainmentFailed)
                }
                let childDescriptor = component.withCString {
                    Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard childDescriptor >= 0 else {
                    throw CandidatePatchError.blocked(.symlinkRejected)
                }
                let child = Descriptor(childDescriptor)
                let after = try CandidatePatchSecureFileIO.descriptorMetadata(childDescriptor)
                guard after.kind == .directory,
                      after.deviceID == before.deviceID,
                      after.inode == before.inode else {
                    throw CandidatePatchError.blocked(.pathContainmentFailed)
                }
                descriptors.append(child)
                links.append(DirectoryLink(
                    name: component,
                    expectedDeviceID: after.deviceID,
                    expectedInode: after.inode
                ))
            }
            let resolved = ResolvedParent(
                descriptors: descriptors,
                links: links,
                targetName: components[components.count - 1]
            )
            try verifyDirectoryChain(resolved)
            return resolved
        }

        private func verifyDirectoryChain(_ parent: ResolvedParent) throws {
            let root = try CandidatePatchSecureFileIO.descriptorMetadata(parent.descriptors[0].value)
            guard root.kind == .directory,
                  root.deviceID == rootDeviceID,
                  root.inode == rootInode else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            for index in parent.links.indices {
                let link = parent.links[index]
                guard let named = try metadataAt(
                    parentDescriptor: parent.descriptors[index].value,
                    name: link.name,
                    missingAllowed: false
                ), named.kind == .directory,
                   named.deviceID == link.expectedDeviceID,
                   named.inode == link.expectedInode else {
                    throw CandidatePatchError.blocked(.pathContainmentFailed)
                }
                let opened = try CandidatePatchSecureFileIO.descriptorMetadata(
                    parent.descriptors[index + 1].value
                )
                guard opened.kind == .directory,
                      opened.deviceID == link.expectedDeviceID,
                      opened.inode == link.expectedInode else {
                    throw CandidatePatchError.blocked(.pathContainmentFailed)
                }
            }
        }

        private func metadataAt(
            parentDescriptor: Int32,
            name: String,
            missingAllowed: Bool
        ) throws -> CandidatePatchRawMetadata? {
            var info = stat()
            let result = name.withCString {
                Darwin.fstatat(parentDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
            }
            if result != 0 {
                if missingAllowed && errno == ENOENT { return nil }
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
            return CandidatePatchSecureFileIO.rawMetadata(info)
        }

        private func openRegularFile(
            parentDescriptor: Int32,
            name: String,
            writable: Bool
        ) throws -> (descriptor: Descriptor, metadata: CandidatePatchRawMetadata) {
            let flags = (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC
            let value = name.withCString { Darwin.openat(parentDescriptor, $0, flags) }
            guard value >= 0 else {
                if errno == ELOOP { throw CandidatePatchError.blocked(.symlinkRejected) }
                throw CandidatePatchError.blocked(.targetMissing)
            }
            let descriptor = Descriptor(value)
            let metadata = try CandidatePatchSecureFileIO.descriptorMetadata(value)
            guard metadata.kind == .regular else {
                throw CandidatePatchError.blocked(.binaryFileRejected)
            }
            guard !metadata.isDataless else {
                throw SandboxFoundationError.sourceFileUnavailable
            }
            guard metadata.linkCount == 1,
                  metadata.deviceID == rootDeviceID else {
                throw CandidatePatchError.blocked(.hardLinkRejected)
            }
            return (descriptor, metadata)
        }

        private func createTemporaryFile(
            parentDescriptor: Int32,
            name: String,
            permissions: UInt16,
            content: Data
        ) throws -> (descriptor: Descriptor, metadata: CandidatePatchRawMetadata) {
            let value = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(permissions)
                )
            }
            guard value >= 0 else {
                throw CandidatePatchError.blocked(.partialApplication)
            }
            let descriptor = Descriptor(value)
            do {
                guard Darwin.fchmod(value, mode_t(permissions)) == 0 else {
                    throw CandidatePatchError.blocked(.partialApplication)
                }
                try CandidatePatchSecureFileIO.writeAll(descriptor: value, data: content)
                guard Darwin.fsync(value) == 0 else {
                    throw CandidatePatchError.blocked(.partialApplication)
                }
                let metadata = try CandidatePatchSecureFileIO.descriptorMetadata(value)
                guard metadata.kind == .regular,
                      metadata.deviceID == rootDeviceID,
                      metadata.linkCount == 1,
                      metadata.permissions == permissions,
                      metadata.permissions & 0o111 == 0 else {
                    throw CandidatePatchError.blocked(.pathContainmentFailed)
                }
                return (descriptor, metadata)
            } catch {
                _ = name.withCString { Darwin.unlinkat(parentDescriptor, $0, 0) }
                throw error
            }
        }

        private func verifyFinalEntry(
            parentDescriptor: Int32,
            name: String,
            expected: CandidatePatchRawMetadata
        ) throws {
            guard let current = try metadataAt(
                parentDescriptor: parentDescriptor,
                name: name,
                missingAllowed: false
            ), current.kind == .regular,
               current.deviceID == expected.deviceID,
               current.inode == expected.inode,
               current.linkCount == 1 else {
                throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
        }
    }

    static func rawMetadata(at url: URL) throws -> CandidatePatchRawMetadata {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &info)
        }
        guard result == 0 else { throw SandboxFoundationError.ambiguousSource }
        let masked = info.st_mode & mode_t(S_IFMT)
        let kind: CandidatePatchEntryKind
        switch masked {
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        return CandidatePatchRawMetadata(
            kind: kind,
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            modificationTimeNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec),
            permissions: UInt16(info.st_mode & 0o7777),
            ownerID: info.st_uid,
            groupID: info.st_gid,
            linkCount: UInt64(info.st_nlink),
            isDataless: (info.st_flags & UInt32(SF_DATALESS)) != 0
        )
    }

    static func readText(at url: URL) throws -> (data: Data, text: String, metadata: CandidatePatchFileMetadata) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw CandidatePatchError.blocked(.targetMissing) }
        defer { Darwin.close(descriptor) }
        let raw = try descriptorMetadata(descriptor)
        guard raw.kind == .regular else { throw CandidatePatchError.blocked(.binaryFileRejected) }
        guard !raw.isDataless else { throw SandboxFoundationError.sourceFileUnavailable }
        guard raw.linkCount == 1 else { throw CandidatePatchError.blocked(.hardLinkRejected) }
        let data = try readAll(descriptor: descriptor, size: raw.size)
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
            throw CandidatePatchError.blocked(.binaryFileRejected)
        }
        var metadata = raw.publicMetadata
        metadata.sha256 = sha256(data)
        return (data, text, metadata)
    }

    static func sha256(at url: URL) throws -> (hash: String, metadata: CandidatePatchFileMetadata) {
        let value = try readText(at: url)
        return (value.metadata.sha256, value.metadata)
    }

    static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    static func stableSHA256(_ components: [String]) -> String {
        sha256(Data(components.joined(separator: "\u{1f}").utf8))
    }

    fileprivate static func descriptorMetadata(_ descriptor: Int32) throws -> CandidatePatchRawMetadata {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            throw CandidatePatchError.blocked(.pathContainmentFailed)
        }
        return rawMetadata(info)
    }

    fileprivate static func rawMetadata(_ info: stat) -> CandidatePatchRawMetadata {
        let masked = info.st_mode & mode_t(S_IFMT)
        let kind: CandidatePatchEntryKind
        switch masked {
        case mode_t(S_IFREG): kind = .regular
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        return CandidatePatchRawMetadata(
            kind: kind,
            deviceID: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: UInt64(max(0, info.st_size)),
            modificationTimeNanoseconds: Int64(info.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(info.st_mtimespec.tv_nsec),
            permissions: UInt16(info.st_mode & 0o7777),
            ownerID: info.st_uid,
            groupID: info.st_gid,
            linkCount: UInt64(info.st_nlink),
            isDataless: (info.st_flags & UInt32(SF_DATALESS)) != 0
        )
    }

    fileprivate static func readAll(descriptor: Int32, size: UInt64) throws -> Data {
        guard size <= UInt64(Int.max) else { throw CandidatePatchError.blocked(.binaryFileRejected) }
        var data = Data(count: Int(size))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.pread(descriptor, base.advanced(by: offset), remaining, off_t(offset))
            }
            guard count >= 0 else { throw CandidatePatchError.blocked(.pathContainmentFailed) }
            if count == 0 { break }
            offset += count
        }
        guard offset == data.count else { throw CandidatePatchError.blocked(.sandboxPreimageChanged) }
        return data
    }

    fileprivate static func writeAll(descriptor: Int32, data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            guard count > 0 else { throw CandidatePatchError.blocked(.partialApplication) }
            offset += count
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct CandidatePatchContentPolicy: Sendable {
    private let reservedComponents: Set<String> = [
        ".git", ".fde-sandbox-metadata", "sandbox-manifest.json", "source-manifest.json",
        "candidate-patches", "outputs", "logs", "evidence"
    ]
    private let credentialNames: Set<String> = [
        "credentials", "credentials.json", "secrets.json", "service-account.json",
        "service_account.json", ".npmrc", ".pypirc", ".netrc", "id_rsa", "id_ed25519"
    ]
    private let credentialExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "pk8", "mobileprovision"
    ]

    func validate(relativePath: String, content: Data) throws {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let lowered = components.map { $0.lowercased() }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CandidatePatchError.blocked(.traversalRejected)
        }
        if lowered.contains(where: reservedComponents.contains) {
            throw CandidatePatchError.blocked(.sandboxMetadataPathRejected)
        }
        guard let name = lowered.last else { throw CandidatePatchError.blocked(.traversalRejected) }
        if name == ".env" || name.hasPrefix(".env.")
            || credentialNames.contains(name)
            || name.contains("credential")
            || name.contains("secret")
            || credentialExtensions.contains(URL(fileURLWithPath: name).pathExtension) {
            throw CandidatePatchError.blocked(.sensitivePathRejected)
        }
        if lowered.contains("tests")
            || lowered.contains("test")
            || name.hasSuffix("tests.swift")
            || name.hasSuffix("test.swift")
            || name.hasSuffix(".spec.ts")
            || name.hasSuffix(".test.ts") {
            throw CandidatePatchError.blocked(.generatedTestUnavailable)
        }
        guard String(data: content, encoding: .utf8) != nil, !content.contains(0) else {
            throw CandidatePatchError.blocked(.binaryFileRejected)
        }
        if containsSensitiveValue(content) {
            throw CandidatePatchError.blocked(.sensitiveContentRejected)
        }
    }

    private func containsSensitiveValue(_ content: Data) -> Bool {
        guard let text = String(data: content, encoding: .utf8) else { return true }
        let lower = text.lowercased()
        if lower.contains("-----begin private key") || lower.contains("-----begin rsa private key") {
            return true
        }
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace || ",;\"'()[]{}".contains($0) })
            .map(String.init)
        if tokens.contains(where: { token in
            token.hasPrefix("AKIA") && token.count >= 20
                || token.hasPrefix("sk-") && token.count >= 24
                || token.hasPrefix("ghp_") && token.count >= 24
        }) {
            return true
        }
        return lower.split(whereSeparator: \.isNewline).contains { line in
            let value = String(line)
            guard value.contains("=") || value.contains(":") else { return false }
            let sensitiveKey = ["password", "secret", "api_key", "apikey", "access_token", "private_key"]
                .contains { value.contains($0) }
            let placeholder = ["example", "placeholder", "redacted", "<", "${", "process.env", "environment"]
                .contains { value.contains($0) }
            return sensitiveKey && !placeholder
        }
    }
}

struct CandidatePatchManifestStore: Sendable {
    let lifecycle: SandboxLifecycleService

    func save(_ manifest: CandidatePatchManifest) throws {
        let directory = try patchDirectory(
            sandboxID: manifest.sandboxID,
            patchID: manifest.patchID,
            createIfNeeded: true
        )
        let url = directory.appendingPathComponent("candidate-patch-manifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }

    func load(sandboxID: SandboxID, patchID: CandidatePatchID) throws -> CandidatePatchManifest {
        let directory = try patchDirectory(sandboxID: sandboxID, patchID: patchID, createIfNeeded: false)
        let url = directory.appendingPathComponent("candidate-patch-manifest.json")
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(url),
              (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
            throw CandidatePatchError.blocked(.patchNotFound)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(CandidatePatchManifest.self, from: Data(contentsOf: url)),
              manifest.patchID == patchID,
              manifest.sandboxID == sandboxID,
              manifest.sourceSnapshotID == manifest.plan.sourceSnapshotID else {
            throw CandidatePatchError.blocked(.manifestInvalid)
        }
        return manifest
    }

    func loadAll() throws -> [CandidatePatchManifest] {
        let storage = lifecycle.storageRoot.standardizedFileURL
        guard FileManager.default.fileExists(atPath: storage.path) else { return [] }
        let canonicalStorage = try SandboxFileSystem.canonicalExistingDirectory(storage)
        let stateRoot = canonicalStorage.appendingPathComponent(".candidate-patch-state", isDirectory: true)
        guard FileManager.default.fileExists(atPath: stateRoot.path) else { return [] }
        guard (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false else {
            throw CandidatePatchError.blocked(.manifestInvalid)
        }
        let sandboxDirectories = try FileManager.default.contentsOfDirectory(
            at: stateRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        var manifests: [CandidatePatchManifest] = []
        for sandboxDirectory in sandboxDirectories.sorted(by: { $0.path < $1.path }) {
            guard let sandboxID = SandboxID(rawValue: sandboxDirectory.lastPathComponent) else {
                throw CandidatePatchError.blocked(.manifestInvalid)
            }
            let patchDirectories = try FileManager.default.contentsOfDirectory(
                at: sandboxDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for patchDirectory in patchDirectories.sorted(by: { $0.path < $1.path }) {
                guard let patchID = CandidatePatchID(rawValue: patchDirectory.lastPathComponent) else {
                    throw CandidatePatchError.blocked(.manifestInvalid)
                }
                manifests.append(try load(sandboxID: sandboxID, patchID: patchID))
            }
        }
        return manifests
    }

    private func patchDirectory(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        createIfNeeded: Bool
    ) throws -> URL {
        let fileManager = FileManager.default
        let storage = lifecycle.storageRoot.standardizedFileURL
        if createIfNeeded, !fileManager.fileExists(atPath: storage.path) {
            try fileManager.createDirectory(at: storage, withIntermediateDirectories: true)
        }
        guard fileManager.fileExists(atPath: storage.path),
              (try? SandboxFileSystem.isSymbolicLink(storage)) == false else {
            throw CandidatePatchError.blocked(createIfNeeded ? .manifestInvalid : .patchNotFound)
        }
        let canonicalStorage = try SandboxFileSystem.canonicalExistingDirectory(storage)
        let stateRoot = canonicalStorage.appendingPathComponent(".candidate-patch-state", isDirectory: true)
        if createIfNeeded, !fileManager.fileExists(atPath: stateRoot.path) {
            try fileManager.createDirectory(at: stateRoot, withIntermediateDirectories: false)
        }
        guard fileManager.fileExists(atPath: stateRoot.path),
              (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false else {
            throw CandidatePatchError.blocked(createIfNeeded ? .manifestInvalid : .patchNotFound)
        }
        let canonicalStateRoot = try SandboxFileSystem.canonicalExistingDirectory(stateRoot)
        guard SandboxFileSystem.isDirectChild(canonicalStateRoot, of: canonicalStorage) else {
            throw CandidatePatchError.blocked(.manifestInvalid)
        }
        let sandboxState = canonicalStateRoot.appendingPathComponent(sandboxID.rawValue, isDirectory: true)
        if createIfNeeded, !fileManager.fileExists(atPath: sandboxState.path) {
            try fileManager.createDirectory(at: sandboxState, withIntermediateDirectories: false)
        }
        guard fileManager.fileExists(atPath: sandboxState.path),
              (try? SandboxFileSystem.isSymbolicLink(sandboxState)) == false else {
            throw CandidatePatchError.blocked(createIfNeeded ? .manifestInvalid : .patchNotFound)
        }
        let canonicalSandboxState = try SandboxFileSystem.canonicalExistingDirectory(sandboxState)
        guard SandboxFileSystem.isDirectChild(canonicalSandboxState, of: canonicalStateRoot) else {
            throw CandidatePatchError.blocked(.manifestInvalid)
        }
        let patch = canonicalSandboxState.appendingPathComponent(patchID.rawValue, isDirectory: true)
        if createIfNeeded, !FileManager.default.fileExists(atPath: patch.path) {
            try FileManager.default.createDirectory(at: patch, withIntermediateDirectories: false)
        }
        guard FileManager.default.fileExists(atPath: patch.path),
              !(try SandboxFileSystem.isSymbolicLink(patch)) else {
            throw CandidatePatchError.blocked(createIfNeeded ? .manifestInvalid : .patchNotFound)
        }
        let canonicalPatch = try SandboxFileSystem.canonicalExistingDirectory(patch)
        guard SandboxFileSystem.isDirectChild(canonicalPatch, of: canonicalSandboxState),
              canonicalPatch.lastPathComponent == patchID.rawValue else {
            throw CandidatePatchError.blocked(.manifestInvalid)
        }
        return canonicalPatch
    }
}

struct CandidatePatchService: Sendable {
    let lifecycle: SandboxLifecycleService
    var diskSpaceChecker: any CandidatePatchDiskSpaceChecking = LocalCandidatePatchDiskSpaceChecker()
    var integrityMonitor = CandidatePatchLegacyIntegrityMonitor()
    var contentPolicy = CandidatePatchContentPolicy()
    var mutationInterlock: CandidatePatchMutationInterlock? = nil

    func preflightApprovedPlan(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        planID: UUID,
        approvalRequestID: UUID
    ) throws -> SandboxInspection {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try store.load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .awaitingApproval,
              manifest.plan.status == .awaitingApproval,
              manifest.plan.planID == planID,
              manifest.plan.approvalRequestID == approvalRequestID,
              manifest.plan.approvalRecord == nil else {
            throw CandidatePatchError.blocked(.planRevisionMismatch)
        }
        let legacyRoot = try canonicalDirectory(
            URL(fileURLWithPath: manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot, isDirectory: true),
            failure: .legacyRootMismatch
        )
        guard integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sourceDrift)
        }
        let currentSnapshot = try SourceSnapshotBuilder().build(root: legacyRoot)
        guard currentSnapshot.snapshotID == manifest.sourceSnapshotID,
              currentSnapshot.canonicalSourceRoot == manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot else {
            throw CandidatePatchError.blocked(.sourceSnapshotStale)
        }
        let storage = try SandboxManifestStore(storageRoot: lifecycle.storageRoot).ensureStorageRoot()
        guard try diskSpaceChecker.availableBytes(at: storage) >= 1_048_576 else {
            throw CandidatePatchError.blocked(.insufficientDiskSpace)
        }

        let inspection: SandboxInspection
        do {
            if let existing = try? lifecycle.inspectSandbox(sandboxID) {
                inspection = existing.manifest.status == .ready
                    && existing.manifest.integrity.status == .passed
                    ? existing
                    : try lifecycle.validateSandbox(sandboxID)
            } else {
                inspection = try lifecycle.createSandbox(
                    sourceRoot: legacyRoot,
                    approvedLegacyRoot: legacyRoot,
                    sandboxID: sandboxID
                )
            }
        } catch let error as CandidatePatchError {
            throw error
        } catch {
            throw CandidatePatchError.blocked(.sandboxNotReady)
        }
        guard inspection.descriptor.sandboxID == sandboxID,
              inspection.manifest.status == .ready,
              inspection.manifest.integrity.status == .passed else {
            throw CandidatePatchError.blocked(.sandboxNotReady)
        }
        guard inspection.sourceManifest.canonicalSourceRoot == legacyRoot.path,
              inspection.sourceManifest.snapshotID == manifest.sourceSnapshotID else {
            throw CandidatePatchError.blocked(.sourceSnapshotStale)
        }
        guard try lifecycle.checkSourceIntegrity(sandboxID).isUnchanged,
              integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sourceDrift)
        }
        manifest.sandboxRoot = try SandboxManifestStore(storageRoot: lifecycle.storageRoot)
            .validatedSandboxDirectory(sandboxID).path
        manifest.updatedAt = Date()
        try store.save(manifest)
        return inspection
    }

    func preparePlan(_ request: CandidatePatchPlanRequest, now: Date = Date()) throws -> CandidatePatchPlan {
        let context = try validatePlanningPreconditions(request, now: now)
        let patchID = request.patchID ?? CandidatePatchID()
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var revision = 1
        var previousManifest: CandidatePatchManifest?
        if request.patchID != nil,
           let previous = try? store.load(sandboxID: request.sandboxID, patchID: patchID) {
            guard previous.status == .planning,
                  previous.plan.approvalRecord?.decision == .requestChanges else {
                throw CandidatePatchError.blocked(.invalidApprovalState)
            }
            revision = previous.plan.revision + 1
            previousManifest = previous
        }
        let planID = UUID()
        var revisionHistory = previousManifest?.revisionHistory ?? []
        if previousManifest != nil,
           let lastIndex = revisionHistory.indices.last,
           revisionHistory[lastIndex].decision == .requestChanges,
           revisionHistory[lastIndex].revisedPlanID == nil {
            revisionHistory[lastIndex].revisedPlanID = planID
        }

        let groundedByID = Dictionary(uniqueKeysWithValues: context.assessment.evidence.map { ($0.claimID, $0) })
        var operations: [CandidatePatchOperation] = []
        for (index, proposed) in request.proposedOperations.enumerated() {
            let relativePath = try canonicalRelativePath(proposed.relativePath)
            let proposedData = Data(proposed.proposedContent.utf8)
            try contentPolicy.validate(relativePath: relativePath, content: proposedData)
            guard scopeContains(relativePath, approvedScope: context.approvedScope) else {
                throw CandidatePatchError.blocked(.scopeNotApproved)
            }
            guard !proposed.evidenceClaimIDs.isEmpty,
                  proposed.evidenceClaimIDs.allSatisfy({ groundedByID[$0]?.isGrounded == true }) else {
                throw CandidatePatchError.blocked(.evidenceClaimMissing)
            }
            let target = try resolvePlanningTarget(context.canonicalLegacyRoot, relativePath: relativePath)
            let rollback: CandidatePatchRollbackData
            let expectedHash: String?
            let beforeMetadata: CandidatePatchFileMetadata?
            switch proposed.operationType {
            case .createTextFile:
                guard !SandboxFileSystem.entryExistsWithoutFollowingLinks(target) else {
                    throw CandidatePatchError.blocked(.targetAlreadyExists)
                }
                rollback = CandidatePatchRollbackData(
                    kind: .removeCreatedFile,
                    preimage: nil,
                    preimageMetadata: nil
                )
                expectedHash = nil
                beforeMetadata = nil
            case .replaceTextFile:
                guard SandboxFileSystem.entryExistsWithoutFollowingLinks(target) else {
                    throw CandidatePatchError.blocked(.targetMissing)
                }
                let existing = try CandidatePatchSecureFileIO.readText(at: target)
                try contentPolicy.validate(relativePath: relativePath, content: existing.data)
                guard proposed.expectedPreimageSHA256 == existing.metadata.sha256 else {
                    throw CandidatePatchError.blocked(.sandboxPreimageChanged)
                }
                rollback = CandidatePatchRollbackData(
                    kind: .restorePreimage,
                    preimage: existing.data,
                    preimageMetadata: existing.metadata
                )
                expectedHash = existing.metadata.sha256
                beforeMetadata = existing.metadata
            }
            operations.append(CandidatePatchOperation(
                operationID: "operation-\(index + 1)",
                relativeCanonicalSandboxPath: relativePath,
                operationType: proposed.operationType,
                expectedPreimageSHA256: expectedHash,
                resultingSHA256: nil,
                proposedContent: proposed.proposedContent,
                implementationRecipe: proposed.implementationRecipe,
                purpose: proposed.purpose,
                evidenceClaimIDs: proposed.evidenceClaimIDs.sorted(),
                blockersAddressed: proposed.blockersAddressed,
                risk: proposed.risk,
                impact: proposed.impact,
                rollbackData: rollback,
                approvalRecord: nil,
                beforeMetadata: beforeMetadata,
                afterMetadata: nil
            ))
        }

        let plan = CandidatePatchPlan(
            patchID: patchID,
            planID: planID,
            revision: revision,
            sandboxID: request.sandboxID,
            sourceSnapshotID: context.sourceManifest.snapshotID,
            assessmentID: context.assessment.assessmentID,
            assessmentContext: context.assessment,
            requestedCapabilityID: context.assessment.requestedCapabilityID,
            compatibilityDecision: context.assessment.compatibilityDecision,
            status: .awaitingApproval,
            requestedOutcome: request.requestedOutcome,
            operations: operations,
            supportingEvidence: context.assessment.evidence.filter { evidence in
                operations.contains { $0.evidenceClaimIDs.contains(evidence.claimID) }
            },
            blockersAddressed: Array(Set(operations.flatMap(\.blockersAddressed))).sorted(),
            expectedBehavior: request.expectedBehavior,
            risk: CandidatePatchRisk.maximum(operations.map(\.risk)),
            prohibitedActions: Self.prohibitedActions,
            validationRequiredLater: request.validationRequiredLater,
            rollbackApproach: request.rollbackApproach,
            unknowns: request.unknowns,
            approvedScope: context.approvedScope,
            legacyIntegrityBaseline: context.baseline,
            createdAt: now,
            updatedAt: now,
            approvalRequestID: nil,
            approvalRecord: nil
        )
        let event = CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .planPrepared,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: .unchanged,
            safeDetail: "Candidate Patch plan revision \(revision) is awaiting explicit human approval."
        )
        try store.save(CandidatePatchManifest(
            formatVersion: 3,
            patchID: patchID,
            sandboxID: request.sandboxID,
            sourceSnapshotID: context.sourceManifest.snapshotID,
            sandboxRoot: "",
            status: .awaitingApproval,
            plan: plan,
            operations: operations,
            unifiedDiff: nil,
            additions: 0,
            deletions: 0,
            sourceIntegrity: .unchanged,
            auditEvents: (previousManifest?.auditEvents ?? []) + [event],
            revisionHistory: revisionHistory,
            createdAt: previousManifest?.createdAt ?? now,
            updatedAt: now
        ))
        return plan
    }

    func recordDecision(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        decision: CandidatePatchApprovalDecision,
        decidedBy: String,
        rationale: String,
        requestedChanges: [String] = [],
        approvalRequestID: UUID? = nil,
        approvalProvenance: CandidatePatchApprovalProvenance? = nil,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try store.load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .awaitingApproval,
              manifest.plan.status == .awaitingApproval else {
            throw CandidatePatchError.blocked(.invalidApprovalState)
        }
        let normalizedChanges = try normalizedRevisionInstructions(
            requestedChanges,
            required: decision == .requestChanges
        )
        let effectiveApprovalRequestID = approvalRequestID
            ?? manifest.plan.approvalRequestID
            ?? UUID()
        guard manifest.plan.approvalRequestID == nil
                || manifest.plan.approvalRequestID == effectiveApprovalRequestID else {
            throw CandidatePatchError.blocked(.planRevisionMismatch)
        }
        let record = CandidatePatchApprovalRecord(
            decision: decision,
            approvalRequestID: effectiveApprovalRequestID,
            planID: manifest.plan.planID,
            planRevision: manifest.plan.revision,
            decidedAt: now,
            decidedBy: decidedBy,
            rationale: rationale,
            requestedChanges: normalizedChanges,
            provenance: approvalProvenance
        )
        let nextStatus: CandidatePatchStatus
        switch decision {
        case .approve: nextStatus = .approved
        case .reject: nextStatus = .rejected
        case .requestChanges: nextStatus = .planning
        }
        manifest.status = nextStatus
        manifest.plan.status = nextStatus
        manifest.plan.approvalRequestID = effectiveApprovalRequestID
        manifest.plan.approvalRecord = record
        manifest.plan.updatedAt = now
        manifest.operations = manifest.operations.map { operation in
            var updated = operation
            updated.approvalRecord = record
            return updated
        }
        manifest.plan.operations = manifest.operations
        if decision == .approve, let provenance = approvalProvenance {
            manifest.appliedBinding = CandidatePatchAppliedBinding(
                workspaceID: provenance.workspaceID,
                taskID: provenance.taskID,
                patchID: manifest.patchID,
                planID: manifest.plan.planID,
                planRevision: manifest.plan.revision,
                sandboxID: manifest.sandboxID,
                manifestID: manifest.stableManifestID,
                sourceSnapshotID: manifest.sourceSnapshotID,
                canonicalLegacyRoot: manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
                authenticatedLocalSessionID: provenance.authenticatedUserSessionID
            )
        }
        manifest.updatedAt = now
        if decision == .requestChanges {
            manifest.revisionHistory.append(CandidatePatchRevisionRecord(
                originalApprovalRequestID: effectiveApprovalRequestID,
                decision: .requestChanges,
                revisionInstructions: normalizedChanges,
                supersededPlanID: manifest.plan.planID,
                revisedPlanID: nil,
                freshApprovalRequestID: nil,
                decidedAt: now
            ))
        }
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: decision == .requestChanges ? .revisionRequested : .approvalRecorded,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: manifest.sourceIntegrity,
            safeDetail: "Human decision \(decision.rawValue) recorded for plan revision \(manifest.plan.revision).",
            approvalProvenance: approvalProvenance
        ))
        try store.save(manifest)
        return manifest
    }

    func recordApprovalConfirmationOpened(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        confirmation: CandidatePatchApprovalConfirmation,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try store.load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .awaitingApproval,
              manifest.plan.status == .awaitingApproval,
              manifest.plan.planID == confirmation.planID,
              manifest.plan.revision == confirmation.planRevision,
              manifest.plan.approvalRequestID == confirmation.approvalRequestID,
              manifest.plan.assessmentID == confirmation.assessmentID,
              manifest.plan.sourceSnapshotID == confirmation.sourceSnapshotID,
              manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot == confirmation.canonicalLegacyRoot,
              manifest.plan.approvalRecord == nil else {
            throw CandidatePatchError.blocked(.planRevisionMismatch)
        }
        manifest.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .approvalConfirmationOpened,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: manifest.sourceIntegrity,
            safeDetail: "Candidate Patch approval confirmation opened without authorizing the plan."
        ))
        try store.save(manifest)
        return manifest
    }

    func materializeApprovedImplementation(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try store.load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .approved,
              manifest.plan.status == .approved,
              manifest.plan.approvalRecord?.decision == .approve else {
            throw CandidatePatchError.blocked(.humanApprovalMissing)
        }
        manifest.operations = try manifest.operations.map { operation in
            guard let recipe = operation.implementationRecipe else { return operation }
            var materialized = operation
            switch recipe {
            case .customerSupportOrderLookupReadOnlyAdapter:
                materialized.proposedContent = Self.customerSupportOrderLookupReadOnlyAdapter
            }
            try contentPolicy.validate(
                relativePath: materialized.relativeCanonicalSandboxPath,
                content: Data(materialized.proposedContent.utf8)
            )
            return materialized
        }
        manifest.plan.operations = manifest.operations
        manifest.plan.updatedAt = now
        manifest.updatedAt = now
        try store.save(manifest)
        return manifest
    }

    func recordApprovalRequest(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        planID: UUID,
        approvalRequestID: UUID,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try store.load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .awaitingApproval,
              manifest.plan.status == .awaitingApproval,
              manifest.plan.planID == planID,
              manifest.plan.approvalRecord == nil,
              manifest.plan.approvalRequestID == nil else {
            throw CandidatePatchError.blocked(.invalidApprovalState)
        }
        manifest.plan.approvalRequestID = approvalRequestID
        if let lastIndex = manifest.revisionHistory.indices.last,
           manifest.revisionHistory[lastIndex].revisedPlanID == planID,
           manifest.revisionHistory[lastIndex].freshApprovalRequestID == nil {
            manifest.revisionHistory[lastIndex].freshApprovalRequestID = approvalRequestID
        }
        manifest.updatedAt = now
        manifest.plan.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .approvalRequested,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: manifest.sourceIntegrity,
            safeDetail: "Fresh explicit approval requested for plan revision \(manifest.plan.revision)."
        ))
        try store.save(manifest)
        return manifest
    }

    func apply(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        now: Date = Date()
    ) throws -> CandidatePatchApplicationResult {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try store.load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .approved,
              manifest.plan.status == .approved,
              manifest.plan.approvalRecord?.decision == .approve else {
            throw CandidatePatchError.blocked(.humanApprovalMissing)
        }
        guard manifest.plan.approvalRecord?.planRevision == manifest.plan.revision,
              manifest.plan.approvalRecord?.planID == manifest.plan.planID,
              manifest.plan.approvalRecord?.approvalRequestID == manifest.plan.approvalRequestID,
              manifest.operations.allSatisfy({
                  $0.approvalRecord?.planRevision == manifest.plan.revision
                      && $0.approvalRecord?.planID == manifest.plan.planID
                      && $0.approvalRecord?.approvalRequestID == manifest.plan.approvalRequestID
              }) else {
            throw CandidatePatchError.blocked(.planRevisionMismatch)
        }
        let secureWorkspace: CandidatePatchSecureFileIO.Workspace
        do {
            try verifyMutationPreconditions(manifest)
            secureWorkspace = try CandidatePatchSecureFileIO.Workspace(
                root: resolveTarget(sandboxID, relativePath: "."),
                interlock: mutationInterlock
            )
            try preflightOperations(manifest, workspace: secureWorkspace)
        } catch {
            let failure = normalizedError(error)
            manifest.status = failure.code == .sourceDrift || failure.code == .sandboxPreimageChanged
                ? .stale
                : .invalid
            manifest.plan.status = manifest.status
            manifest.sourceIntegrity = failure.code == .sourceDrift ? .changed : manifest.sourceIntegrity
            manifest.updatedAt = Date()
            manifest.auditEvents.append(CandidatePatchAuditEvent(
                eventID: UUID(),
                type: .operationFailed,
                timestamp: manifest.updatedAt,
                operationID: nil,
                relativePath: nil,
                beforeSHA256: nil,
                afterSHA256: nil,
                sourceIntegrity: manifest.sourceIntegrity,
                safeDetail: failure.code.rawValue
            ))
            try? store.save(manifest)
            throw failure
        }

        manifest.status = .applying
        manifest.plan.status = .applying
        manifest.updatedAt = now
        try store.save(manifest)
        var applied: [CandidatePatchAppliedOperation] = []
        do {
            for index in manifest.operations.indices {
                try verifyMutationPreconditions(manifest)
                var operation = manifest.operations[index]
                try authorizeSandboxOperation(
                    sandboxID: sandboxID,
                    relativePath: operation.relativeCanonicalSandboxPath,
                    operation: operation.operationType == .createTextFile
                        ? .candidatePatchCreateText
                        : .candidatePatchReplaceText,
                    approvalSatisfied: true,
                    requiresApproval: true
                )
                let content = Data(operation.proposedContent.utf8)
                switch operation.operationType {
                case .createTextFile:
                    operation.afterMetadata = try secureWorkspace.createText(
                        relativePath: operation.relativeCanonicalSandboxPath,
                        content: content
                    )
                case .replaceTextFile:
                    guard let expected = operation.expectedPreimageSHA256 else {
                        throw CandidatePatchError.blocked(.sandboxPreimageChanged)
                    }
                    let result = try secureWorkspace.replaceText(
                        relativePath: operation.relativeCanonicalSandboxPath,
                        expectedSHA256: expected,
                        content: content
                    )
                    operation.beforeMetadata = result.beforeMetadata
                    operation.afterMetadata = result.afterMetadata
                }
                operation.resultingSHA256 = operation.afterMetadata?.sha256
                guard let resultingHash = operation.resultingSHA256 else {
                    throw CandidatePatchError.blocked(.partialApplication)
                }
                try verifyMutationPreconditions(manifest)
                manifest.operations[index] = operation
                manifest.plan.operations[index] = operation
                manifest.auditEvents.append(CandidatePatchAuditEvent(
                    eventID: UUID(),
                    type: .operationApplied,
                    timestamp: Date(),
                    operationID: operation.operationID,
                    relativePath: operation.relativeCanonicalSandboxPath,
                    beforeSHA256: operation.expectedPreimageSHA256,
                    afterSHA256: resultingHash,
                    sourceIntegrity: .unchanged,
                    safeDetail: "Approved structured Sandbox text operation applied."
                ))
                manifest.updatedAt = Date()
                try store.save(manifest)
                applied.append(CandidatePatchAppliedOperation(
                    operationID: operation.operationID,
                    relativePath: operation.relativeCanonicalSandboxPath,
                    resultingSHA256: resultingHash
                ))
            }
            manifest.status = .applied
            manifest.plan.status = .applied
            let diff = CandidatePatchUnifiedDiff.generate(operations: manifest.operations)
            manifest.unifiedDiff = diff.text
            manifest.additions = diff.additions
            manifest.deletions = diff.deletions
            manifest.auditEvents.append(CandidatePatchAuditEvent(
                eventID: UUID(),
                type: .diffGenerated,
                timestamp: Date(),
                operationID: nil,
                relativePath: nil,
                beforeSHA256: nil,
                afterSHA256: nil,
                sourceIntegrity: .unchanged,
                safeDetail: "Deterministic unified diff generated from recorded Sandbox preimages and postimages."
            ))
            try verifyMutationPreconditions(manifest)
            manifest.status = .reviewReady
            manifest.plan.status = .reviewReady
            manifest.sourceIntegrity = .unchanged
            manifest.updatedAt = Date()
            manifest.appliedAt = manifest.updatedAt
            manifest.auditEvents.append(CandidatePatchAuditEvent(
                eventID: UUID(),
                type: .reviewPrepared,
                timestamp: manifest.updatedAt,
                operationID: nil,
                relativePath: nil,
                beforeSHA256: nil,
                afterSHA256: nil,
                sourceIntegrity: .unchanged,
                safeDetail: "Candidate Patch is ready for human review; runtime validation remains unexecuted."
            ))
            try store.save(manifest)
            return CandidatePatchApplicationResult(
                manifest: manifest,
                appliedOperations: applied,
                failedOperations: []
            )
        } catch {
            let failure = normalizedError(error)
            manifest.status = failure.code == .sourceDrift || failure.code == .sandboxPreimageChanged
                ? .stale
                : .invalid
            manifest.plan.status = manifest.status
            manifest.sourceIntegrity = failure.code == .sourceDrift ? .changed : manifest.sourceIntegrity
            manifest.updatedAt = Date()
            manifest.auditEvents.append(CandidatePatchAuditEvent(
                eventID: UUID(),
                type: .operationFailed,
                timestamp: manifest.updatedAt,
                operationID: manifest.operations.dropFirst(applied.count).first?.operationID,
                relativePath: manifest.operations.dropFirst(applied.count).first?.relativeCanonicalSandboxPath,
                beforeSHA256: nil,
                afterSHA256: nil,
                sourceIntegrity: manifest.sourceIntegrity,
                safeDetail: failure.code.rawValue
            ))
            try? store.save(manifest)
            throw failure
        }
    }

    func reviewSummary(
        sandboxID: SandboxID,
        patchID: CandidatePatchID
    ) throws -> CandidatePatchReviewSummary {
        let manifest = try CandidatePatchManifestStore(lifecycle: lifecycle)
            .load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .reviewReady,
              let diff = manifest.unifiedDiff else {
            throw CandidatePatchError.blocked(.manifestInvalid)
        }
        try verifyMutationPreconditions(manifest)
        let files = manifest.operations.map { operation in
            CandidatePatchFileReview(
                relativePath: operation.relativeCanonicalSandboxPath,
                operationType: operation.operationType,
                purpose: operation.purpose,
                evidenceClaimIDs: operation.evidenceClaimIDs,
                expectedEffect: operation.impact,
                risk: operation.risk,
                unknowns: manifest.plan.unknowns,
                rollbackMethod: operation.rollbackData.kind == .restorePreimage
                    ? "Restore the approved preimage through Candidate Patch revert."
                    : "Remove only this Candidate Patch-created file through Candidate Patch revert."
            )
        }
        return CandidatePatchReviewSummary(
            patchID: patchID,
            sandboxID: sandboxID,
            sourceSnapshotID: manifest.sourceSnapshotID,
            requestedOutcome: manifest.plan.requestedOutcome,
            assessmentEvidence: manifest.plan.supportingEvidence,
            approvedPlan: manifest.plan,
            files: files,
            unifiedDiff: diff,
            additions: manifest.additions,
            deletions: manifest.deletions,
            expectedBehavior: manifest.plan.expectedBehavior,
            validationStillRequired: manifest.plan.validationRequiredLater,
            unknowns: manifest.plan.unknowns,
            rollbackInstructions: "Use the app-managed revert action for Candidate Patch \(patchID.rawValue); do not destroy the Sandbox.",
            originalLegacyIntegrity: .unchanged,
            buildOrTestExecuted: false,
            gitOrDeploymentActionOccurred: false
        )
    }

    func locateRevertTarget(
        workspaceID: UUID,
        request: String
    ) throws -> CandidatePatchRevertTarget {
        let manifests = try CandidatePatchManifestStore(lifecycle: lifecycle).loadAll()
        let normalized = request.lowercased()
        let explicitlyReferenced = manifests.filter { manifest in
            normalized.contains(manifest.patchID.rawValue)
                || normalized.contains(manifest.sandboxID.rawValue)
        }
        if explicitlyReferenced.count > 1 {
            throw CandidatePatchError.blocked(.revertSelectionAmbiguous)
        }
        if let exact = explicitlyReferenced.first {
            let target = try revertTarget(for: exact)
            guard target.binding.workspaceID == workspaceID else {
                throw CandidatePatchError.blocked(.revertBindingMismatch)
            }
            return target
        }

        let eligible = try manifests.compactMap { manifest -> CandidatePatchRevertTarget? in
            guard manifest.status == .reviewReady || manifest.status == .applied,
                  manifest.sandboxDestroyedAt == nil,
                  !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }) else {
                return nil
            }
            let target = try revertTarget(for: manifest)
            return target.binding.workspaceID == workspaceID ? target : nil
        }
        guard !eligible.isEmpty else {
            throw CandidatePatchError.blocked(.revertUnavailable)
        }
        guard eligible.count == 1, let target = eligible.first else {
            throw CandidatePatchError.blocked(.revertSelectionAmbiguous)
        }
        return target
    }

    func revertTargets(workspaceID: UUID) throws -> [CandidatePatchRevertTarget] {
        try CandidatePatchManifestStore(lifecycle: lifecycle).loadAll().compactMap { manifest in
            guard manifest.status == .reviewReady || manifest.status == .applied,
                  manifest.sandboxDestroyedAt == nil,
                  !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }) else {
                return nil
            }
            let target = try revertTarget(for: manifest)
            return target.binding.workspaceID == workspaceID ? target : nil
        }.sorted { lhs, rhs in
            lhs.binding.patchID.rawValue < rhs.binding.patchID.rawValue
        }
    }

    func locateSandboxDestructionTarget(
        workspaceID: UUID,
        request: String
    ) throws -> CandidatePatchSandboxDestructionTarget {
        let manifests = try CandidatePatchManifestStore(lifecycle: lifecycle).loadAll()
        let normalized = request.lowercased()
        let explicitlyReferenced = manifests.filter { manifest in
            normalized.contains(manifest.patchID.rawValue)
                || normalized.contains(manifest.sandboxID.rawValue)
        }
        if explicitlyReferenced.count > 1 {
            throw CandidatePatchError.blocked(.sandboxDestructionSelectionAmbiguous)
        }
        if let exact = explicitlyReferenced.first {
            let target = try sandboxDestructionTarget(for: exact)
            guard target.binding.workspaceID == workspaceID else {
                throw CandidatePatchError.blocked(.revertBindingMismatch)
            }
            return target
        }

        let eligible = try manifests.compactMap { manifest -> CandidatePatchSandboxDestructionTarget? in
            guard manifest.status == .reverted,
                  manifest.sandboxDestroyedAt == nil,
                  !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }) else {
                return nil
            }
            let target = try sandboxDestructionTarget(for: manifest)
            return target.binding.workspaceID == workspaceID ? target : nil
        }
        guard !eligible.isEmpty else {
            throw CandidatePatchError.blocked(.sandboxDestructionUnavailable)
        }
        guard eligible.count == 1, let target = eligible.first else {
            throw CandidatePatchError.blocked(.sandboxDestructionSelectionAmbiguous)
        }
        return target
    }

    func prepareSandboxDestruction(
        binding: CandidatePatchAppliedBinding
    ) throws -> CandidatePatchSandboxDestructionTarget {
        let manifest: CandidatePatchManifest
        do {
            manifest = try boundManifest(binding, allowedStatuses: [.reverted])
        } catch let error as CandidatePatchError where error.code == .patchNotFound {
            throw CandidatePatchError.blocked(.revertBindingMismatch)
        }
        guard manifest.sandboxDestroyedAt == nil,
              !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }),
              integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sandboxDestructionUnavailable)
        }
        _ = try lifecycle.inspectSandbox(binding.sandboxID)
        return CandidatePatchSandboxDestructionTarget(binding: binding)
    }

    func prepareRevert(
        binding: CandidatePatchAppliedBinding
    ) throws -> CandidatePatchRevertTarget {
        let manifest = try boundManifest(binding, allowedStatuses: [.applied, .reviewReady])
        try preflightRevert(manifest)
        guard integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sourceDrift)
        }
        return try revertTarget(for: manifest)
    }

    func appliedBinding(
        sandboxID: SandboxID,
        patchID: CandidatePatchID
    ) throws -> CandidatePatchAppliedBinding {
        try effectiveBinding(for: CandidatePatchManifestStore(lifecycle: lifecycle).load(
            sandboxID: sandboxID,
            patchID: patchID
        ))
    }

    func recordRevertConfirmationOpened(
        _ confirmation: CandidatePatchRevertConfirmation,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try boundManifest(
            confirmation.binding,
            allowedStatuses: [.applied, .reviewReady]
        )
        try preflightRevert(manifest)
        manifest.appliedBinding = confirmation.binding
        manifest.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .revertConfirmationOpened,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: .unchanged,
            safeDetail: "Explicit Candidate Patch Revert confirmation opened; no Sandbox mutation occurred."
        ))
        try store.save(manifest)
        return manifest
    }

    func recordRevertConfirmationCancelled(
        binding: CandidatePatchAppliedBinding,
        now: Date = Date()
    ) throws {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try boundManifest(binding, allowedStatuses: [.applied, .reviewReady])
        manifest.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .revertConfirmationCancelled,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: manifest.sourceIntegrity,
            safeDetail: "Candidate Patch Revert confirmation cancelled; no Sandbox mutation occurred."
        ))
        try store.save(manifest)
    }

    func revert(
        binding: CandidatePatchAppliedBinding,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try boundManifest(binding, allowedStatuses: [.applied, .reviewReady])
        try preflightRevert(manifest)
        let secureWorkspace = try CandidatePatchSecureFileIO.Workspace(
            root: resolveTarget(binding.sandboxID, relativePath: "."),
            interlock: mutationInterlock
        )
        manifest.appliedBinding = binding
        manifest.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .revertStarted,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: .unchanged,
            safeDetail: "Exact-bound Candidate Patch Revert started inside the existing Sandbox."
        ))
        try store.save(manifest)

        do {
            for reverseIndex in manifest.operations.indices.reversed() {
                try verifyMutationPreconditions(manifest)
                let operation = manifest.operations[reverseIndex]
                guard let resultingHash = operation.resultingSHA256 else {
                    throw CandidatePatchError.blocked(.manifestInvalid)
                }
                try authorizeSandboxOperation(
                    sandboxID: binding.sandboxID,
                    relativePath: operation.relativeCanonicalSandboxPath,
                    operation: .candidatePatchRevert,
                    approvalSatisfied: true,
                    requiresApproval: true
                )
                let restoredHash: String?
                switch operation.rollbackData.kind {
                case .removeCreatedFile:
                    try secureWorkspace.removeCreatedText(
                        relativePath: operation.relativeCanonicalSandboxPath,
                        expectedSHA256: resultingHash
                    )
                    try secureWorkspace.preflightCreate(relativePath: operation.relativeCanonicalSandboxPath)
                    restoredHash = nil
                case .restorePreimage:
                    guard let preimage = operation.rollbackData.preimage,
                          let expectedMetadata = operation.rollbackData.preimageMetadata else {
                        throw CandidatePatchError.blocked(.manifestInvalid)
                    }
                    let restored = try secureWorkspace.replaceText(
                        relativePath: operation.relativeCanonicalSandboxPath,
                        expectedSHA256: resultingHash,
                        content: preimage
                    )
                    guard restored.afterMetadata.sha256 == expectedMetadata.sha256,
                          restored.afterMetadata.permissions == expectedMetadata.permissions else {
                        throw CandidatePatchError.blocked(.revertUnavailable)
                    }
                    try secureWorkspace.preflightReplace(
                        relativePath: operation.relativeCanonicalSandboxPath,
                        expectedSHA256: expectedMetadata.sha256,
                        expectedData: preimage
                    )
                    restoredHash = expectedMetadata.sha256
                }
                try verifyMutationPreconditions(manifest)
                manifest.auditEvents.append(CandidatePatchAuditEvent(
                    eventID: UUID(),
                    type: .operationReverted,
                    timestamp: Date(),
                    operationID: operation.operationID,
                    relativePath: operation.relativeCanonicalSandboxPath,
                    beforeSHA256: resultingHash,
                    afterSHA256: restoredHash,
                    sourceIntegrity: .unchanged,
                    safeDetail: "Candidate Patch operation reverted inside the exact bound Sandbox."
                ))
                manifest.updatedAt = Date()
                try store.save(manifest)
            }

            let integrity = integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline)
            guard integrity == .unchanged else {
                throw CandidatePatchError.blocked(.sourceDrift)
            }
            manifest.status = .reverted
            manifest.plan.status = .reverted
            manifest.sourceIntegrity = integrity
            manifest.revertedAt = now
            manifest.updatedAt = now
            manifest.auditEvents.append(CandidatePatchAuditEvent(
                eventID: UUID(),
                type: .sourceIntegrityChecked,
                timestamp: now,
                operationID: nil,
                relativePath: nil,
                beforeSHA256: manifest.plan.legacyIntegrityBaseline.fingerprint,
                afterSHA256: manifest.plan.legacyIntegrityBaseline.fingerprint,
                sourceIntegrity: integrity,
                safeDetail: "Original Legacy integrity confirmed unchanged after Candidate Patch Revert."
            ))
            manifest.auditEvents.append(CandidatePatchAuditEvent(
                eventID: UUID(),
                type: .revertCompleted,
                timestamp: now,
                operationID: nil,
                relativePath: nil,
                beforeSHA256: nil,
                afterSHA256: nil,
                sourceIntegrity: integrity,
                safeDetail: "Candidate Patch Revert completed; audit retained and Sandbox preserved."
            ))
            try store.save(manifest)
            return manifest
        } catch {
            let failure = normalizedError(error)
            manifest.status = failure.code == .sourceDrift || failure.code == .currentPatchImageChanged
                ? .stale
                : .invalid
            manifest.plan.status = manifest.status
            manifest.updatedAt = Date()
            try? store.save(manifest)
            throw failure
        }
    }

    func recordSandboxDestructionConfirmationOpened(
        _ confirmation: CandidatePatchSandboxDestructionConfirmation,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try boundManifest(confirmation.binding, allowedStatuses: [.reverted])
        guard manifest.sandboxDestroyedAt == nil,
              !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }),
              integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sandboxDestructionUnavailable)
        }
        _ = try lifecycle.inspectSandbox(confirmation.binding.sandboxID)
        manifest.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .sandboxDestructionConfirmationOpened,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: .unchanged,
            safeDetail: "Separate Sandbox destruction confirmation opened after Revert."
        ))
        try store.save(manifest)
        return manifest
    }

    func recordSandboxDestructionConfirmationCancelled(
        binding: CandidatePatchAppliedBinding,
        now: Date = Date()
    ) throws {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try boundManifest(binding, allowedStatuses: [.reverted])
        manifest.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .sandboxDestructionConfirmationCancelled,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: manifest.sourceIntegrity,
            safeDetail: "Sandbox destruction confirmation cancelled; Sandbox preserved."
        ))
        try store.save(manifest)
    }

    func destroyRevertedSandbox(
        binding: CandidatePatchAppliedBinding,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try boundManifest(binding, allowedStatuses: [.reverted])
        guard manifest.sandboxDestroyedAt == nil,
              !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }),
              integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sandboxDestructionUnavailable)
        }
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .sandboxDestructionStarted,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: .unchanged,
            safeDetail: "Separately confirmed destruction of the already-reverted Sandbox started."
        ))
        try store.save(manifest)
        _ = try lifecycle.destroySandbox(binding.sandboxID)
        manifest.sandboxDestroyedAt = now
        manifest.updatedAt = now
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .sandboxDestroyed,
            timestamp: now,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: .unchanged,
            safeDetail: "Already-reverted Sandbox destroyed through the separate audited action."
        ))
        try store.save(manifest)
        return manifest
    }

    func revert(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        var manifest = try store.load(sandboxID: sandboxID, patchID: patchID)
        guard manifest.status == .reviewReady || manifest.status == .applied else {
            throw CandidatePatchError.blocked(.revertUnavailable)
        }
        try verifyMutationPreconditions(manifest)
        let secureWorkspace = try CandidatePatchSecureFileIO.Workspace(
            root: resolveTarget(sandboxID, relativePath: "."),
            interlock: mutationInterlock
        )
        do {
            for reverseIndex in manifest.operations.indices.reversed() {
                try verifyMutationPreconditions(manifest)
                let operation = manifest.operations[reverseIndex]
                guard let resultingHash = operation.resultingSHA256 else {
                    throw CandidatePatchError.blocked(.manifestInvalid)
                }
                try authorizeSandboxOperation(
                    sandboxID: sandboxID,
                    relativePath: operation.relativeCanonicalSandboxPath,
                    operation: .candidatePatchRevert,
                    approvalSatisfied: true,
                    requiresApproval: true
                )
                switch operation.rollbackData.kind {
                case .removeCreatedFile:
                    try secureWorkspace.removeCreatedText(
                        relativePath: operation.relativeCanonicalSandboxPath,
                        expectedSHA256: resultingHash
                    )
                case .restorePreimage:
                    guard let preimage = operation.rollbackData.preimage,
                          let expectedMetadata = operation.rollbackData.preimageMetadata else {
                        throw CandidatePatchError.blocked(.manifestInvalid)
                    }
                    let restored = try secureWorkspace.replaceText(
                        relativePath: operation.relativeCanonicalSandboxPath,
                        expectedSHA256: resultingHash,
                        content: preimage
                    )
                    guard restored.afterMetadata.sha256 == expectedMetadata.sha256,
                          restored.afterMetadata.permissions == expectedMetadata.permissions else {
                        throw CandidatePatchError.blocked(.revertUnavailable)
                    }
                }
                try verifyMutationPreconditions(manifest)
                manifest.auditEvents.append(CandidatePatchAuditEvent(
                    eventID: UUID(),
                    type: .operationReverted,
                    timestamp: Date(),
                    operationID: operation.operationID,
                    relativePath: operation.relativeCanonicalSandboxPath,
                    beforeSHA256: resultingHash,
                    afterSHA256: operation.expectedPreimageSHA256,
                    sourceIntegrity: .unchanged,
                    safeDetail: "Candidate Patch operation reverted inside the isolated Sandbox."
                ))
                manifest.updatedAt = Date()
                try store.save(manifest)
            }
            manifest.status = .reverted
            manifest.plan.status = .reverted
            manifest.sourceIntegrity = .unchanged
            manifest.updatedAt = now
            try store.save(manifest)
            return manifest
        } catch {
            let failure = normalizedError(error)
            manifest.status = failure.code == .sourceDrift || failure.code == .currentPatchImageChanged
                ? .stale
                : .invalid
            manifest.plan.status = manifest.status
            manifest.updatedAt = Date()
            try? store.save(manifest)
            throw failure
        }
    }

    func revertAndDestroySandbox(
        sandboxID: SandboxID,
        patchID: CandidatePatchID,
        now: Date = Date()
    ) throws -> CandidatePatchManifest {
        var manifest = try revert(sandboxID: sandboxID, patchID: patchID, now: now)
        let integrity = integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline)
        manifest.sourceIntegrity = integrity
        manifest.updatedAt = Date()
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .sourceIntegrityChecked,
            timestamp: manifest.updatedAt,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: manifest.plan.legacyIntegrityBaseline.fingerprint,
            afterSHA256: integrity == .unchanged
                ? manifest.plan.legacyIntegrityBaseline.fingerprint
                : nil,
            sourceIntegrity: integrity,
            safeDetail: "Original Legacy integrity checked after Candidate Patch revert."
        ))
        let store = CandidatePatchManifestStore(lifecycle: lifecycle)
        try store.save(manifest)
        guard integrity == .unchanged else {
            throw CandidatePatchError.blocked(.sourceDrift)
        }
        _ = try lifecycle.destroySandbox(sandboxID)
        manifest.updatedAt = Date()
        manifest.auditEvents.append(CandidatePatchAuditEvent(
            eventID: UUID(),
            type: .sandboxDestroyed,
            timestamp: manifest.updatedAt,
            operationID: nil,
            relativePath: nil,
            beforeSHA256: nil,
            afterSHA256: nil,
            sourceIntegrity: .unchanged,
            safeDetail: "Validated reverted Sandbox destroyed through the Sandbox lifecycle."
        ))
        try store.save(manifest)
        return manifest
    }

    func loadManifest(sandboxID: SandboxID, patchID: CandidatePatchID) throws -> CandidatePatchManifest {
        try CandidatePatchManifestStore(lifecycle: lifecycle).load(sandboxID: sandboxID, patchID: patchID)
    }

    func readApprovedSandboxTextFile(sandboxID: SandboxID, relativePath: String) throws -> String {
        let inspection = try lifecycle.inspectSandbox(sandboxID)
        guard inspection.manifest.status == .ready else {
            throw CandidatePatchError.blocked(.sandboxNotReady)
        }
        let relative = try canonicalRelativePath(relativePath)
        try authorizeSandboxOperation(
            sandboxID: sandboxID,
            relativePath: relative,
            operation: .candidatePatchReadText,
            approvalSatisfied: false,
            requiresApproval: false
        )
        let target = try resolveTarget(sandboxID, relativePath: relative)
        try contentPolicy.validate(relativePath: relative, content: Data())
        return try CandidatePatchSecureFileIO.readText(at: target).text
    }

    static let prohibitedActions = [
        "Original Legacy writes", "Agent workspace writes", "absolute paths", "path traversal",
        "symbolic links", "hard links", "binary mutation", "deletion", "rename or move",
        "permission, ownership, or executable-bit changes", "Sandbox metadata mutation",
        ".git mutation", ".env or credential files", "dependency installation", "shell execution",
        "Git operations", "generated tests", "build or test execution", "deployment",
        "credential access", "production access"
    ]

    private static let customerSupportOrderLookupReadOnlyAdapter = """
    import { Principal } from "./auth";
    import { recordAuditEvent } from "./audit";
    import { listCustomerOrders } from "./orders";

    export interface CustomerOrderAuthorizer {
      canReadCustomerOrders(principal: Principal, customerID: string): boolean;
    }

    export interface CustomerSupportOrderResult {
      orderID: string;
      status: "processing" | "shipped";
    }

    export function lookupCustomerOrdersReadOnly(
      principal: Principal,
      customerID: string,
      authorization: CustomerOrderAuthorizer
    ): CustomerSupportOrderResult[] {
      const allowed = authorization.canReadCustomerOrders(principal, customerID);
      recordAuditEvent({
        actorID: principal.subject,
        action: "orders.read",
        resourceID: customerID,
        outcome: allowed ? "allowed" : "denied"
      });
      if (!allowed) {
        throw new Error("forbidden");
      }
      return listCustomerOrders(principal, customerID).map(({ orderID, status }) => ({ orderID, status }));
    }
    """

    private func revertTarget(for manifest: CandidatePatchManifest) throws -> CandidatePatchRevertTarget {
        guard manifest.status == .reviewReady || manifest.status == .applied,
              manifest.sandboxDestroyedAt == nil,
              !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }) else {
            throw CandidatePatchError.blocked(.revertUnavailable)
        }
        let binding = try effectiveBinding(for: manifest)
        let appliedAt = manifest.appliedAt
            ?? manifest.auditEvents.last(where: { $0.type == .operationApplied })?.timestamp
            ?? manifest.updatedAt
        return CandidatePatchRevertTarget(
            binding: binding,
            appliedAt: appliedAt,
            filesToRestore: manifest.operations.compactMap { operation in
                operation.rollbackData.kind == .restorePreimage
                    ? operation.relativeCanonicalSandboxPath
                    : nil
            },
            filesToRemove: manifest.operations.compactMap { operation in
                operation.rollbackData.kind == .removeCreatedFile
                    ? operation.relativeCanonicalSandboxPath
                    : nil
            }
        )
    }

    private func sandboxDestructionTarget(
        for manifest: CandidatePatchManifest
    ) throws -> CandidatePatchSandboxDestructionTarget {
        guard manifest.status == .reverted,
              manifest.plan.status == .reverted,
              manifest.sandboxDestroyedAt == nil,
              !manifest.auditEvents.contains(where: { $0.type == .sandboxDestroyed }) else {
            throw CandidatePatchError.blocked(.sandboxDestructionUnavailable)
        }
        return CandidatePatchSandboxDestructionTarget(
            binding: try effectiveBinding(for: manifest)
        )
    }

    private func effectiveBinding(
        for manifest: CandidatePatchManifest
    ) throws -> CandidatePatchAppliedBinding {
        let binding: CandidatePatchAppliedBinding
        if let persisted = manifest.appliedBinding {
            binding = persisted
        } else if let provenance = manifest.plan.approvalRecord?.provenance {
            binding = CandidatePatchAppliedBinding(
                workspaceID: provenance.workspaceID,
                taskID: provenance.taskID,
                patchID: manifest.patchID,
                planID: manifest.plan.planID,
                planRevision: manifest.plan.revision,
                sandboxID: manifest.sandboxID,
                manifestID: manifest.stableManifestID,
                sourceSnapshotID: manifest.sourceSnapshotID,
                canonicalLegacyRoot: manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
                authenticatedLocalSessionID: provenance.authenticatedUserSessionID
            )
        } else {
            throw CandidatePatchError.blocked(.revertBindingMissing)
        }
        guard binding.patchID == manifest.patchID,
              binding.planID == manifest.plan.planID,
              binding.planRevision == manifest.plan.revision,
              binding.sandboxID == manifest.sandboxID,
              binding.manifestID == manifest.stableManifestID,
              binding.sourceSnapshotID == manifest.sourceSnapshotID,
              binding.canonicalLegacyRoot == manifest.plan.legacyIntegrityBaseline.canonicalLegacyRoot,
              manifest.plan.approvalRecord?.decision == .approve,
              let provenance = manifest.plan.approvalRecord?.provenance,
              provenance.workspaceID == binding.workspaceID,
              provenance.taskID == binding.taskID,
              provenance.planID == binding.planID,
              provenance.planRevision == binding.planRevision,
              provenance.sourceSnapshotID == binding.sourceSnapshotID,
              provenance.canonicalLegacyRoot == binding.canonicalLegacyRoot,
              provenance.authenticatedUserSessionID == binding.authenticatedLocalSessionID else {
            throw CandidatePatchError.blocked(.revertBindingMismatch)
        }
        return binding
    }

    private func boundManifest(
        _ binding: CandidatePatchAppliedBinding,
        allowedStatuses: [CandidatePatchStatus]
    ) throws -> CandidatePatchManifest {
        let manifest = try CandidatePatchManifestStore(lifecycle: lifecycle).load(
            sandboxID: binding.sandboxID,
            patchID: binding.patchID
        )
        guard allowedStatuses.contains(manifest.status),
              manifest.plan.status == manifest.status,
              try effectiveBinding(for: manifest) == binding else {
            throw CandidatePatchError.blocked(.revertBindingMismatch)
        }
        return manifest
    }

    private func preflightRevert(_ manifest: CandidatePatchManifest) throws {
        try verifyMutationPreconditions(manifest)
        let workspace = try CandidatePatchSecureFileIO.Workspace(
            root: resolveTarget(manifest.sandboxID, relativePath: "."),
            interlock: mutationInterlock
        )
        do {
            for operation in manifest.operations {
                guard let resultingHash = operation.resultingSHA256 else {
                    throw CandidatePatchError.blocked(.manifestInvalid)
                }
                try workspace.preflightReplace(
                    relativePath: operation.relativeCanonicalSandboxPath,
                    expectedSHA256: resultingHash,
                    expectedData: Data(operation.proposedContent.utf8)
                )
            }
        } catch let error as CandidatePatchError {
            if error.code == .sandboxPreimageChanged || error.code == .targetMissing {
                throw CandidatePatchError.blocked(.currentPatchImageChanged)
            }
            throw error
        } catch {
            throw CandidatePatchError.blocked(.currentPatchImageChanged)
        }
        guard integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sourceDrift)
        }
    }

    private func validatePlanningPreconditions(
        _ request: CandidatePatchPlanRequest,
        now: Date
    ) throws -> PlanningContext {
        guard let selectedRoot = request.selectedLegacyRoot else {
            throw CandidatePatchError.blocked(.workspaceNotSelected)
        }
        let canonicalSelected = try canonicalDirectory(selectedRoot, failure: .workspaceNotSelected)
        let canonicalTrusted = try canonicalDirectory(request.trustedLegacyRoot, failure: .workspaceRootUntrusted)
        guard SandboxFileSystem.isContained(canonicalSelected, in: canonicalTrusted) else {
            throw CandidatePatchError.blocked(.workspaceRootUntrusted)
        }
        for agentRoot in request.agentWorkspaceRoots {
            let canonicalAgent = try canonicalDirectory(agentRoot, failure: .agentWorkspaceRejected)
            if SandboxFileSystem.isContained(canonicalSelected, in: canonicalAgent)
                || SandboxFileSystem.isContained(canonicalAgent, in: canonicalSelected) {
                throw CandidatePatchError.blocked(.agentWorkspaceRejected)
            }
        }
        guard let assessment = request.assessment else {
            throw CandidatePatchError.blocked(.assessmentMissing)
        }
        guard assessment.validationStatus == .validated else {
            throw CandidatePatchError.blocked(.assessmentEvidenceMissing)
        }
        let sourceManifest = try SourceSnapshotBuilder().build(root: canonicalSelected)
        guard assessment.canonicalLegacyRoot == canonicalSelected.path else {
            throw CandidatePatchError.blocked(.legacyRootMismatch)
        }
        guard assessment.sourceSnapshotID == sourceManifest.snapshotID else {
            throw CandidatePatchError.blocked(.assessmentStale)
        }
        if let requestedCapabilityID = request.requestedCapabilityID,
           assessment.requestedCapabilityID != requestedCapabilityID {
            throw CandidatePatchError.blocked(.assessmentCapabilityMismatch)
        }
        let material = assessment.evidence.filter(\.material)
        guard !material.isEmpty, material.allSatisfy(\.isGrounded) else {
            throw CandidatePatchError.blocked(.assessmentEvidenceMissing)
        }
        if assessment.compatibilityDecision == .no {
            guard !assessment.blockers.isEmpty else {
                throw CandidatePatchError.blocked(.assessmentVerdictNotEligible)
            }
        }
        guard !request.proposedOperations.isEmpty else {
            throw CandidatePatchError.blocked(.emptyPlan)
        }
        let approvedScope = try request.approvedScope.map(canonicalRelativeScope)
        guard !approvedScope.isEmpty else { throw CandidatePatchError.blocked(.scopeNotApproved) }
        let baseline = try integrityMonitor.capture(root: canonicalSelected, createdAt: now)
        guard integrityMonitor.verify(baseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sourceDrift)
        }
        return PlanningContext(
            canonicalLegacyRoot: canonicalSelected,
            sourceManifest: sourceManifest,
            assessment: assessment,
            approvedScope: approvedScope,
            baseline: baseline
        )
    }

    private func verifyMutationPreconditions(_ manifest: CandidatePatchManifest) throws {
        let sourceCheck = try lifecycle.checkSourceIntegrity(manifest.sandboxID)
        guard sourceCheck.isUnchanged,
              integrityMonitor.verify(manifest.plan.legacyIntegrityBaseline) == .unchanged else {
            throw CandidatePatchError.blocked(.sourceDrift)
        }
        let inspection = try SandboxManifestStore(storageRoot: lifecycle.storageRoot).load(manifest.sandboxID)
        guard inspection.manifest.status == .ready else {
            throw CandidatePatchError.blocked(.sandboxNotReady)
        }
        guard inspection.sourceManifest.snapshotID == manifest.sourceSnapshotID else {
            throw CandidatePatchError.blocked(.sourceSnapshotStale)
        }
        _ = try resolveTarget(manifest.sandboxID, relativePath: ".")
    }

    private func preflightOperations(
        _ manifest: CandidatePatchManifest,
        workspace: CandidatePatchSecureFileIO.Workspace
    ) throws {
        for operation in manifest.operations {
            try authorizeSandboxOperation(
                sandboxID: manifest.sandboxID,
                relativePath: operation.relativeCanonicalSandboxPath,
                operation: operation.operationType == .createTextFile
                    ? .candidatePatchCreateText
                    : .candidatePatchReplaceText,
                approvalSatisfied: true,
                requiresApproval: true
            )
            let content = Data(operation.proposedContent.utf8)
            try contentPolicy.validate(
                relativePath: operation.relativeCanonicalSandboxPath,
                content: content
            )
            guard scopeContains(
                operation.relativeCanonicalSandboxPath,
                approvedScope: manifest.plan.approvedScope
            ) else {
                throw CandidatePatchError.blocked(.scopeNotApproved)
            }
            switch operation.operationType {
            case .createTextFile:
                try workspace.preflightCreate(relativePath: operation.relativeCanonicalSandboxPath)
            case .replaceTextFile:
                guard let expected = operation.expectedPreimageSHA256 else {
                    throw CandidatePatchError.blocked(.sandboxPreimageChanged)
                }
                try workspace.preflightReplace(
                    relativePath: operation.relativeCanonicalSandboxPath,
                    expectedSHA256: expected,
                    expectedData: operation.rollbackData.preimage
                )
            }
        }
    }

    private func validateExistingParent(of target: URL, sandboxID: SandboxID) throws {
        let parent = target.deletingLastPathComponent()
        let canonicalParent: URL
        do {
            canonicalParent = try SandboxFileSystem.canonicalExistingDirectory(parent)
        } catch {
            throw CandidatePatchError.blocked(.pathContainmentFailed)
        }
        let workspace = try resolveTarget(sandboxID, relativePath: ".")
        guard SandboxFileSystem.isContained(canonicalParent, in: workspace),
              !(try SandboxFileSystem.isSymbolicLink(parent)) else {
            throw CandidatePatchError.blocked(.pathContainmentFailed)
        }
    }

    private func resolvePlanningTarget(_ root: URL, relativePath: String) throws -> URL {
        let target = root.appendingPathComponent(relativePath).standardizedFileURL
        guard SandboxFileSystem.isContained(target, in: root) else {
            throw CandidatePatchError.blocked(.pathContainmentFailed)
        }
        return target
    }

    private func validateExistingPlanningParent(of target: URL, root: URL) throws {
        let parent = target.deletingLastPathComponent()
        let canonicalParent: URL
        do {
            canonicalParent = try SandboxFileSystem.canonicalExistingDirectory(parent)
        } catch {
            throw CandidatePatchError.blocked(.pathContainmentFailed)
        }
        guard SandboxFileSystem.isContained(canonicalParent, in: root),
              !(try SandboxFileSystem.isSymbolicLink(parent)) else {
            throw CandidatePatchError.blocked(.pathContainmentFailed)
        }
    }

    private func resolveTarget(_ sandboxID: SandboxID, relativePath: String) throws -> URL {
        do {
            return try SandboxPathResolver(storageRoot: lifecycle.storageRoot).resolve(
                sandboxID: sandboxID,
                relativePath: relativePath
            )
        } catch let error as SandboxFoundationError {
            switch error {
            case .absolutePathRejected: throw CandidatePatchError.blocked(.absolutePathRejected)
            case .pathTraversalRejected: throw CandidatePatchError.blocked(.traversalRejected)
            case .metadataPathRejected: throw CandidatePatchError.blocked(.sandboxMetadataPathRejected)
            case .symbolicLinkEscapeRejected: throw CandidatePatchError.blocked(.symlinkRejected)
            default: throw CandidatePatchError.blocked(.pathContainmentFailed)
            }
        }
    }

    private func authorizeSandboxOperation(
        sandboxID: SandboxID,
        relativePath: String,
        operation: SandboxWritableOperation,
        approvalSatisfied: Bool,
        requiresApproval: Bool
    ) throws {
        let decision = SandboxRuntimePolicy(lifecycle: lifecycle).authorizePhase2D1(
            SandboxWritablePolicyRequest(
                mission: .futureApprovedSandboxMutation,
                sandboxID: sandboxID,
                relativeTargetPath: relativePath,
                operation: operation,
                requiresHumanApproval: requiresApproval,
                humanApprovalSatisfied: approvalSatisfied
            )
        )
        guard decision.allowed else {
            if decision.denials.contains(.humanApprovalMissing) {
                throw CandidatePatchError.blocked(.humanApprovalMissing)
            }
            if decision.denials.contains(.operationUnavailable) {
                throw CandidatePatchError.blocked(.operationUnavailable)
            }
            if decision.denials.contains(.sourceChanged) {
                throw CandidatePatchError.blocked(.sourceDrift)
            }
            if decision.denials.contains(.sandboxNotReady) {
                throw CandidatePatchError.blocked(.sandboxNotReady)
            }
            throw CandidatePatchError.blocked(.pathContainmentFailed)
        }
    }

    private func canonicalRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CandidatePatchError.blocked(.traversalRejected) }
        guard !NSString(string: trimmed).isAbsolutePath,
              !trimmed.hasPrefix("~"),
              !trimmed.contains("\\") else {
            throw CandidatePatchError.blocked(.absolutePathRejected)
        }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CandidatePatchError.blocked(.traversalRejected)
        }
        return components.joined(separator: "/")
    }

    private func normalizedRevisionInstructions(
        _ values: [String],
        required: Bool
    ) throws -> [String] {
        var seen: Set<String> = []
        let normalized = values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { return nil }
            return trimmed
        }
        guard required else { return normalized }
        let combined = normalized.joined(separator: " ")
        let ambiguous: Set<String> = [
            "change", "changes", "change it", "revise", "revision", "fix it", "update it",
            "修改", "改一下", "调整", "变更"
        ]
        guard combined.count >= 8,
              !ambiguous.contains(combined.lowercased()) else {
            throw CandidatePatchError.blocked(.invalidApprovalState)
        }
        return normalized
    }

    private func canonicalRelativeScope(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "." { return "." }
        return try canonicalRelativePath(trimmed)
    }

    private func scopeContains(_ path: String, approvedScope: [String]) -> Bool {
        approvedScope.contains { scope in
            scope == "." || path == scope || path.hasPrefix(scope + "/")
        }
    }

    private func canonicalDirectory(_ url: URL, failure: CandidatePatchFailureCode) throws -> URL {
        do {
            return try SandboxFileSystem.canonicalExistingDirectory(url)
        } catch {
            throw CandidatePatchError.blocked(failure)
        }
    }

    private func normalizedError(_ error: Error) -> CandidatePatchError {
        if let error = error as? CandidatePatchError { return error }
        if let error = error as? SandboxFoundationError {
            switch error {
            case .sourceSnapshotChanged: return .blocked(.sourceDrift)
            case .symbolicLinkEscapeRejected: return .blocked(.symlinkRejected)
            case .absolutePathRejected: return .blocked(.absolutePathRejected)
            case .pathTraversalRejected: return .blocked(.traversalRejected)
            case .metadataPathRejected: return .blocked(.sandboxMetadataPathRejected)
            default: return .blocked(.pathContainmentFailed)
            }
        }
        return .blocked(.partialApplication)
    }
}

private struct PlanningContext {
    var canonicalLegacyRoot: URL
    var sourceManifest: SourceSnapshotManifest
    var assessment: CandidatePatchAssessmentContext
    var approvedScope: [String]
    var baseline: CandidatePatchLegacyIntegrityBaseline
}

enum CandidatePatchUnifiedDiff {
    struct Result: Equatable, Sendable {
        var text: String
        var additions: Int
        var deletions: Int
    }

    private enum Edit {
        case equal(String)
        case remove(String)
        case add(String)
    }

    static func generate(operations: [CandidatePatchOperation]) -> Result {
        var sections: [String] = []
        var additions = 0
        var deletions = 0
        for operation in operations.sorted(by: {
            $0.relativeCanonicalSandboxPath < $1.relativeCanonicalSandboxPath
        }) {
            let oldData = operation.rollbackData.preimage ?? Data()
            let newData = Data(operation.proposedContent.utf8)
            let old = decodedLines(oldData)
            let new = decodedLines(newData)
            let edits = lineEdits(old.lines, new.lines)
            let path = operation.relativeCanonicalSandboxPath
            var lines: [String] = [
                operation.operationType == .createTextFile ? "--- /dev/null" : "--- a/\(path)",
                "+++ b/\(path)",
                "@@ -\(old.lines.isEmpty ? 0 : 1),\(old.lines.count) +\(new.lines.isEmpty ? 0 : 1),\(new.lines.count) @@"
            ]
            for edit in edits {
                switch edit {
                case .equal(let line): lines.append(" \(line)")
                case .remove(let line):
                    lines.append("-\(line)")
                    deletions += 1
                case .add(let line):
                    lines.append("+\(line)")
                    additions += 1
                }
            }
            if (!old.hasTrailingNewline && !old.lines.isEmpty)
                || (!new.hasTrailingNewline && !new.lines.isEmpty) {
                lines.append("\\ No newline at end of file")
            }
            sections.append(lines.joined(separator: "\n"))
        }
        return Result(
            text: sections.joined(separator: "\n"),
            additions: additions,
            deletions: deletions
        )
    }

    private static func decodedLines(_ data: Data) -> (lines: [String], hasTrailingNewline: Bool) {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else {
            return ([], true)
        }
        var lines = text.components(separatedBy: "\n")
        let trailing = text.hasSuffix("\n")
        if trailing { lines.removeLast() }
        return (lines, trailing)
    }

    private static func lineEdits(_ old: [String], _ new: [String]) -> [Edit] {
        var lengths = Array(repeating: Array(repeating: 0, count: new.count + 1), count: old.count + 1)
        if !old.isEmpty, !new.isEmpty {
            for oldIndex in stride(from: old.count - 1, through: 0, by: -1) {
                for newIndex in stride(from: new.count - 1, through: 0, by: -1) {
                    lengths[oldIndex][newIndex] = old[oldIndex] == new[newIndex]
                        ? lengths[oldIndex + 1][newIndex + 1] + 1
                        : max(lengths[oldIndex + 1][newIndex], lengths[oldIndex][newIndex + 1])
                }
            }
        }
        var edits: [Edit] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count, newIndex < new.count, old[oldIndex] == new[newIndex] {
                edits.append(.equal(old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else if newIndex < new.count,
                      oldIndex == old.count || lengths[oldIndex][newIndex + 1] > lengths[oldIndex + 1][newIndex] {
                edits.append(.add(new[newIndex]))
                newIndex += 1
            } else if oldIndex < old.count {
                edits.append(.remove(old[oldIndex]))
                oldIndex += 1
            }
        }
        return edits
    }
}
