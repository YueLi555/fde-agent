import Foundation

struct SandboxPreflightValidator: Sendable {
    let storageRoot: URL
    var agentWorkspaceRoots: [URL] = []

    func validate(sourceRoot: URL, approvedLegacyRoot: URL) throws -> URL {
        let canonicalSource = try SandboxFileSystem.canonicalExistingDirectory(sourceRoot)
        let canonicalApproved = try SandboxFileSystem.canonicalExistingDirectory(approvedLegacyRoot)
        guard FileManager.default.isReadableFile(atPath: canonicalSource.path) else {
            throw SandboxFoundationError.sourceUnreadable
        }
        guard SandboxFileSystem.isContained(canonicalSource, in: canonicalApproved) else {
            throw SandboxFoundationError.sourceOutsideApprovedLegacyRoot
        }

        for rawAgentRoot in agentWorkspaceRoots {
            guard let canonicalAgent = try? SandboxFileSystem.canonicalExistingDirectory(rawAgentRoot) else {
                throw SandboxFoundationError.ambiguousSource
            }
            if SandboxFileSystem.isContained(canonicalSource, in: canonicalAgent)
                || SandboxFileSystem.isContained(canonicalAgent, in: canonicalSource) {
                throw SandboxFoundationError.agentWorkspaceRejected
            }
        }

        let canonicalStorage = try SandboxFileSystem.canonicalPotential(storageRoot)
        if SandboxFileSystem.isContained(canonicalSource, in: canonicalStorage) {
            throw SandboxFoundationError.nestedSandboxRootRejected
        }
        if SandboxFileSystem.isContained(canonicalStorage, in: canonicalApproved) {
            throw SandboxFoundationError.sandboxRootInsideLegacyRejected
        }
        return canonicalSource
    }
}

struct SandboxManifestStore: Sendable {
    let storageRoot: URL

    func ensureStorageRoot() throws -> URL {
        let expected = try SandboxFileSystem.canonicalPotential(storageRoot)
        if FileManager.default.fileExists(atPath: storageRoot.path),
           try SandboxFileSystem.isSymbolicLink(storageRoot) {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let canonical = try SandboxFileSystem.canonicalExistingDirectory(storageRoot)
        guard canonical.path == expected.path else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        return canonical
    }

    func createSkeleton(
        sandboxID: SandboxID,
        manifest: SandboxManifest,
        sourceManifest: SourceSnapshotManifest
    ) throws -> URL {
        let root = try ensureStorageRoot()
        let directory = root.appendingPathComponent(sandboxID.rawValue, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw SandboxFoundationError.duplicateSandboxID
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            for child in ["workspace", "evidence", "logs", "outputs"] {
                try FileManager.default.createDirectory(
                    at: directory.appendingPathComponent(child, isDirectory: true),
                    withIntermediateDirectories: false
                )
            }
            try write(sourceManifest, to: directory.appendingPathComponent("source-manifest.json"))
            try write(manifest, to: directory.appendingPathComponent("sandbox-manifest.json"))
            return directory
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func validatedSandboxDirectory(_ sandboxID: SandboxID) throws -> URL {
        let root = try SandboxFileSystem.canonicalExistingDirectory(storageRoot)
        let rawDirectory = root.appendingPathComponent(sandboxID.rawValue, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rawDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !(try SandboxFileSystem.isSymbolicLink(rawDirectory)) else {
            throw SandboxFoundationError.sandboxNotFound
        }
        let canonical = try SandboxFileSystem.canonicalExistingDirectory(rawDirectory)
        guard SandboxFileSystem.isDirectChild(canonical, of: root),
              canonical.lastPathComponent == sandboxID.rawValue else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        return canonical
    }

    func load(_ sandboxID: SandboxID) throws -> SandboxInspection {
        let directory = try validatedSandboxDirectory(sandboxID)
        let manifest: SandboxManifest = try read(
            SandboxManifest.self,
            from: directory.appendingPathComponent("sandbox-manifest.json")
        )
        let sourceManifest: SourceSnapshotManifest = try read(
            SourceSnapshotManifest.self,
            from: directory.appendingPathComponent("source-manifest.json")
        )
        guard manifest.sandboxID == sandboxID,
              manifest.sourceSnapshotID == sourceManifest.snapshotID,
              manifest.includedFileCount == sourceManifest.files.count,
              manifest.excludedItemCount == sourceManifest.exclusions.count else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        return SandboxInspection(
            descriptor: descriptor(manifest: manifest, source: sourceManifest, sourceUnchanged: nil),
            manifest: manifest,
            sourceManifest: sourceManifest
        )
    }

    func update(_ manifest: SandboxManifest) throws {
        let directory = try validatedSandboxDirectory(manifest.sandboxID)
        try write(manifest, to: directory.appendingPathComponent("sandbox-manifest.json"))
    }

    func descriptor(
        manifest: SandboxManifest,
        source: SourceSnapshotManifest,
        sourceUnchanged: Bool?
    ) -> SandboxDescriptor {
        SandboxDescriptor(
            sandboxID: manifest.sandboxID,
            sourceSnapshotID: source.snapshotID,
            status: manifest.status,
            sourceDisplayName: URL(fileURLWithPath: source.canonicalSourceRoot).lastPathComponent,
            includedFileCount: manifest.includedFileCount,
            excludedItemCount: manifest.excludedItemCount,
            integrityStatus: manifest.integrity.status,
            sourceUnchanged: sourceUnchanged
        )
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path),
              !(try SandboxFileSystem.isSymbolicLink(url)) else {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            throw SandboxFoundationError.sandboxMetadataInvalid
        }
    }
}

struct SourceIntegrityMonitor: Sendable {
    var snapshotBuilder = SourceSnapshotBuilder()

    func check(_ expected: SourceSnapshotManifest, checkedAt: Date = Date()) -> SourceIntegrityCheck {
        let root = URL(fileURLWithPath: expected.canonicalSourceRoot, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return result(.moved, expected: expected, observed: nil, checkedAt: checkedAt)
        }
        do {
            let canonical = try SandboxFileSystem.canonicalExistingDirectory(root)
            let identity = try SandboxFileSystem.identity(of: canonical)
            guard canonical.path == expected.canonicalSourceRoot,
                  identity.deviceID == expected.sourceRootDeviceID,
                  identity.inode == expected.sourceRootInode else {
                return result(.moved, expected: expected, observed: nil, checkedAt: checkedAt)
            }
            let observed = try snapshotBuilder.build(root: canonical, createdAt: checkedAt)
            let expectedByPath = Dictionary(uniqueKeysWithValues: expected.files.map {
                ($0.relativeCanonicalPath, $0)
            })
            let observedByPath = Dictionary(uniqueKeysWithValues: observed.files.map {
                ($0.relativeCanonicalPath, $0)
            })
            let expectedPaths = Set(expectedByPath.keys)
            let observedPaths = Set(observedByPath.keys)
            let added = observedPaths.subtracting(expectedPaths).count
            let removed = expectedPaths.subtracting(observedPaths).count
            let changed = expectedPaths.intersection(observedPaths).filter {
                expectedByPath[$0] != observedByPath[$0]
            }.count
            let expectedExclusions = Set(expected.exclusions)
            let observedExclusions = Set(observed.exclusions)
            let exclusionChanges = expectedExclusions.symmetricDifference(observedExclusions).count
            let state: SourceIntegrityState = observed.snapshotID == expected.snapshotID ? .unchanged : .changed
            return SourceIntegrityCheck(
                state: state,
                checkedAt: checkedAt,
                expectedSnapshotID: expected.snapshotID,
                observedSnapshotID: observed.snapshotID,
                changedFileCount: changed,
                addedFileCount: added,
                removedFileCount: removed,
                exclusionChangeCount: exclusionChanges,
                safeSummary: state == .unchanged
                    ? "Legacy source snapshot is unchanged."
                    : "Legacy source changed (changed \(changed), added \(added), removed \(removed), exclusion changes \(exclusionChanges))."
            )
        } catch SandboxFoundationError.ambiguousSource {
            return result(.ambiguous, expected: expected, observed: nil, checkedAt: checkedAt)
        } catch {
            return result(.inaccessible, expected: expected, observed: nil, checkedAt: checkedAt)
        }
    }

    private func result(
        _ state: SourceIntegrityState,
        expected: SourceSnapshotManifest,
        observed: String?,
        checkedAt: Date
    ) -> SourceIntegrityCheck {
        SourceIntegrityCheck(
            state: state,
            checkedAt: checkedAt,
            expectedSnapshotID: expected.snapshotID,
            observedSnapshotID: observed,
            changedFileCount: 0,
            addedFileCount: 0,
            removedFileCount: 0,
            exclusionChangeCount: 0,
            safeSummary: "Legacy source state is \(state.rawValue); Sandbox writes are blocked."
        )
    }
}

struct SandboxLifecycleService: Sendable {
    let storageRoot: URL
    var agentWorkspaceRoots: [URL] = []
    var snapshotBuilder = SourceSnapshotBuilder()

    static var defaultStorageRoot: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("FDECloudOS", isDirectory: true)
            .appendingPathComponent("Sandboxes", isDirectory: true)
    }

    func createSandbox(
        sourceRoot: URL,
        approvedLegacyRoot: URL,
        sandboxID: SandboxID = SandboxID()
    ) throws -> SandboxInspection {
        _ = try prepareSandbox(
            sourceRoot: sourceRoot,
            approvedLegacyRoot: approvedLegacyRoot,
            sandboxID: sandboxID
        )
        return try validateSandbox(sandboxID)
    }

    func prepareSandbox(
        sourceRoot: URL,
        approvedLegacyRoot: URL,
        sandboxID: SandboxID = SandboxID()
    ) throws -> SandboxInspection {
        let canonicalSource = try SandboxPreflightValidator(
            storageRoot: storageRoot,
            agentWorkspaceRoots: agentWorkspaceRoots
        ).validate(sourceRoot: sourceRoot, approvedLegacyRoot: approvedLegacyRoot)
        let sourceManifest = try snapshotBuilder.build(root: canonicalSource)
        let now = Date()
        var manifest = SandboxManifest(
            formatVersion: 1,
            sandboxID: sandboxID,
            sourceSnapshotID: sourceManifest.snapshotID,
            status: .creating,
            createdAt: now,
            updatedAt: now,
            includedFileCount: sourceManifest.files.count,
            excludedItemCount: sourceManifest.exclusions.count,
            integrity: .pending,
            exclusions: sourceManifest.exclusions
        )
        let store = SandboxManifestStore(storageRoot: storageRoot)
        let directory = try store.createSkeleton(
            sandboxID: sandboxID,
            manifest: manifest,
            sourceManifest: sourceManifest
        )
        do {
            let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
            for record in sourceManifest.files {
                let source = canonicalSource.appendingPathComponent(record.relativeCanonicalPath)
                let destination = workspace.appendingPathComponent(record.relativeCanonicalPath)
                guard SandboxFileSystem.isContained(destination.standardizedFileURL, in: workspace) else {
                    throw SandboxFoundationError.pathEscapeRejected
                }
                try SandboxFileSystem.physicallyCopy(
                    source: source,
                    destination: destination,
                    expected: record
                )
            }
            manifest.status = .validating
            manifest.updatedAt = Date()
            try store.update(manifest)
            return try store.load(sandboxID)
        } catch {
            manifest.status = .invalid
            manifest.updatedAt = Date()
            manifest.integrity = SandboxIntegrityValidation(
                status: .failed,
                checkedAt: Date(),
                copiedFileCount: 0,
                matchingHashCount: 0,
                independentlyStoredFileCount: 0,
                sensitiveItemsFound: 0,
                escapingLinkCount: 0,
                failures: ["safe_copy_failed"]
            )
            try? store.update(manifest)
            throw error
        }
    }

    func validateSandbox(_ sandboxID: SandboxID) throws -> SandboxInspection {
        let store = SandboxManifestStore(storageRoot: storageRoot)
        var inspection = try store.load(sandboxID)
        guard inspection.manifest.status != .destroying,
              inspection.manifest.status != .destroyed else {
            throw SandboxFoundationError.invalidStatusTransition
        }
        inspection.manifest.status = .validating
        inspection.manifest.updatedAt = Date()
        try store.update(inspection.manifest)

        let directory = try store.validatedSandboxDirectory(sandboxID)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        var failures: [String] = []
        var matchingHashes = 0
        var independentFiles = 0
        var sensitiveItems = 0
        var escapingLinks = 0
        var copiedFileCount = 0

        do {
            let copiedSnapshot = try snapshotBuilder.build(root: workspace)
            copiedFileCount = copiedSnapshot.files.count
            sensitiveItems = copiedSnapshot.exclusions.filter {
                snapshotBuilder.exclusionPolicy.isSensitive(reason: $0.reason)
            }.count
            escapingLinks = copiedSnapshot.exclusions.filter { $0.reason == .symbolicLink }.count
            if !copiedSnapshot.exclusions.isEmpty { failures.append("unexpected_excluded_or_special_entries") }

            let copiedByPath = Dictionary(uniqueKeysWithValues: copiedSnapshot.files.map {
                ($0.relativeCanonicalPath, $0)
            })
            let sourceByPath = Dictionary(uniqueKeysWithValues: inspection.sourceManifest.files.map {
                ($0.relativeCanonicalPath, $0)
            })
            if Set(copiedByPath.keys) != Set(sourceByPath.keys) {
                failures.append("workspace_file_set_mismatch")
            }
            for (path, sourceRecord) in sourceByPath {
                guard let copiedRecord = copiedByPath[path] else { continue }
                if copiedRecord.sha256 == sourceRecord.sha256,
                   copiedRecord.size == sourceRecord.size {
                    matchingHashes += 1
                } else {
                    failures.append("workspace_hash_mismatch")
                }
                if copiedRecord.deviceID != sourceRecord.deviceID
                    || copiedRecord.inode != sourceRecord.inode {
                    independentFiles += 1
                } else {
                    failures.append("shared_file_identity")
                }
            }
        } catch {
            failures.append("workspace_scan_failed")
        }

        let sourceCheck = SourceIntegrityMonitor(snapshotBuilder: snapshotBuilder)
            .check(inspection.sourceManifest)
        if !sourceCheck.isUnchanged { failures.append("source_snapshot_changed") }
        if sensitiveItems > 0 { failures.append("sensitive_item_present") }
        if escapingLinks > 0 { failures.append("symbolic_link_present") }

        failures = Array(Set(failures)).sorted()
        let passed = failures.isEmpty
            && copiedFileCount == inspection.sourceManifest.files.count
            && matchingHashes == inspection.sourceManifest.files.count
            && independentFiles == inspection.sourceManifest.files.count
        inspection.manifest.integrity = SandboxIntegrityValidation(
            status: passed ? .passed : .failed,
            checkedAt: Date(),
            copiedFileCount: copiedFileCount,
            matchingHashCount: matchingHashes,
            independentlyStoredFileCount: independentFiles,
            sensitiveItemsFound: sensitiveItems,
            escapingLinkCount: escapingLinks,
            failures: failures
        )
        inspection.manifest.status = passed
            ? .ready
            : (sourceCheck.isUnchanged ? .invalid : .stale)
        inspection.manifest.updatedAt = Date()
        try store.update(inspection.manifest)
        guard passed else { throw SandboxFoundationError.copyVerificationFailed }
        return try inspectSandbox(sandboxID)
    }

    func inspectSandbox(_ sandboxID: SandboxID) throws -> SandboxInspection {
        let store = SandboxManifestStore(storageRoot: storageRoot)
        var inspection = try store.load(sandboxID)
        let check = SourceIntegrityMonitor(snapshotBuilder: snapshotBuilder).check(inspection.sourceManifest)
        if !check.isUnchanged, inspection.manifest.status == .ready {
            inspection.manifest.status = check.state == .changed || check.state == .moved ? .stale : .tainted
            inspection.manifest.updatedAt = Date()
            try store.update(inspection.manifest)
        }
        inspection.descriptor = store.descriptor(
            manifest: inspection.manifest,
            source: inspection.sourceManifest,
            sourceUnchanged: check.isUnchanged
        )
        return inspection
    }

    func checkSourceIntegrity(_ sandboxID: SandboxID) throws -> SourceIntegrityCheck {
        let store = SandboxManifestStore(storageRoot: storageRoot)
        var inspection = try store.load(sandboxID)
        let check = SourceIntegrityMonitor(snapshotBuilder: snapshotBuilder).check(inspection.sourceManifest)
        if !check.isUnchanged, inspection.manifest.status == .ready {
            inspection.manifest.status = check.state == .changed || check.state == .moved ? .stale : .tainted
            inspection.manifest.updatedAt = Date()
            try store.update(inspection.manifest)
        }
        return check
    }

    func markSandbox(_ sandboxID: SandboxID, status: SandboxStatus) throws -> SandboxInspection {
        guard status == .invalid || status == .tainted || status == .stale else {
            throw SandboxFoundationError.invalidStatusTransition
        }
        let store = SandboxManifestStore(storageRoot: storageRoot)
        var inspection = try store.load(sandboxID)
        guard inspection.manifest.status != .destroying,
              inspection.manifest.status != .destroyed else {
            throw SandboxFoundationError.invalidStatusTransition
        }
        inspection.manifest.status = status
        inspection.manifest.updatedAt = Date()
        try store.update(inspection.manifest)
        return try store.load(sandboxID)
    }

    func listActiveSandboxes() throws -> [SandboxDescriptor] {
        guard FileManager.default.fileExists(atPath: storageRoot.path) else { return [] }
        let root = try SandboxFileSystem.canonicalExistingDirectory(storageRoot)
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).compactMap { entry in
            guard let sandboxID = SandboxID(rawValue: entry.lastPathComponent),
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  (try? SandboxFileSystem.isSymbolicLink(entry)) == false else {
                return nil
            }
            return try? inspectSandbox(sandboxID).descriptor
        }.sorted { $0.sandboxID.rawValue < $1.sandboxID.rawValue }
    }

    @discardableResult
    func destroySandbox(rawSandboxID: String) throws -> SandboxDescriptor {
        guard let sandboxID = SandboxID(rawValue: rawSandboxID) else {
            throw SandboxFoundationError.invalidSandboxID
        }
        return try destroySandbox(sandboxID)
    }

    @discardableResult
    func destroySandbox(_ sandboxID: SandboxID) throws -> SandboxDescriptor {
        let store = SandboxManifestStore(storageRoot: storageRoot)
        var inspection = try store.load(sandboxID)
        let directory = try store.validatedSandboxDirectory(sandboxID)
        let root = try SandboxFileSystem.canonicalExistingDirectory(storageRoot)
        guard SandboxFileSystem.isDirectChild(directory, of: root),
              directory.lastPathComponent == sandboxID.rawValue,
              directory.path != root.path else {
            throw SandboxFoundationError.destructionTargetRejected
        }
        inspection.manifest.status = .destroying
        inspection.manifest.updatedAt = Date()
        try store.update(inspection.manifest)

        let revalidated = try store.validatedSandboxDirectory(sandboxID)
        guard revalidated.path == directory.path else {
            throw SandboxFoundationError.destructionTargetRejected
        }
        try FileManager.default.removeItem(at: revalidated)
        inspection.descriptor.status = .destroyed
        inspection.descriptor.sourceUnchanged = nil
        return inspection.descriptor
    }
}
