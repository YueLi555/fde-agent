import Foundation

struct ControlledEvalRestoredRuns: Hashable, Sendable {
    var runs: [EvalRun]
    var restorationFailures: [EvalRunRestorationFailure]
}

struct ControlledEvalRunStore: Sendable {
    let storageRoot: URL

    func save(_ run: EvalRun) throws {
        try ControlledEvalArtifactValidator.validate(run)
        let url = try runURL(
            workspaceID: run.request.authority.workspaceID,
            missionRunID: run.request.authority.missionRunID,
            runID: run.runID,
            createIfNeeded: true
        )
        if SandboxFileSystem.entryExistsWithoutFollowingLinks(url) {
            let existing: EvalRun = try decode(url)
            try ControlledEvalArtifactValidator.validate(existing)
            if existing == run { return }
            guard ControlledEvalArtifactValidator.isAppendOnly(existing: existing, proposed: run) else {
                throw ControlledEvalFailure.revisionImmutable
            }
        }
        try encode(run, to: url)
    }

    func load(
        workspaceID: UUID,
        missionRunID: UUID,
        runID: UUID
    ) throws -> EvalRun {
        let run: EvalRun = try decode(try runURL(
            workspaceID: workspaceID,
            missionRunID: missionRunID,
            runID: runID,
            createIfNeeded: false
        ))
        guard run.runID == runID,
              run.request.authority.workspaceID == workspaceID,
              run.request.authority.missionRunID == missionRunID else {
            throw ControlledEvalFailure.authorityMismatch
        }
        try ControlledEvalArtifactValidator.validate(run)
        return run
    }

    func loadAll(workspaceID: UUID? = nil) throws -> [EvalRun] {
        try runFiles(workspaceID: workspaceID).map { url in
            let run: EvalRun = try decode(url)
            if let workspaceID, run.request.authority.workspaceID != workspaceID {
                throw ControlledEvalFailure.authorityMismatch
            }
            try ControlledEvalArtifactValidator.validate(run)
            return run
        }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.runID.uuidString < $1.runID.uuidString }
            return $0.updatedAt < $1.updatedAt
        }
    }

    func restoreAll(
        workspaceID: UUID? = nil,
        now: Date = Date()
    ) throws -> ControlledEvalRestoredRuns {
        var restored: [EvalRun] = []
        var failures: [EvalRunRestorationFailure] = []
        for run in try loadAll(workspaceID: workspaceID) {
            let recovered = try ControlledEvalExecutionService()
                .failClosedInterruptedRestoration(run, now: now)
            if recovered != run {
                try save(recovered)
                failures.append(contentsOf: recovered.restorationFailures.dropFirst(run.restorationFailures.count))
            }
            restored.append(recovered)
        }
        return ControlledEvalRestoredRuns(runs: restored, restorationFailures: failures)
    }

    private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(value).write(to: url, options: [.atomic])
        } catch {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
    }

    private func decode<Value: Decodable>(_ url: URL) throws -> Value {
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(url),
              (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
    }

    private func canonicalStorageRoot(createIfNeeded: Bool) throws -> URL {
        let root = storageRoot.standardizedFileURL
        if createIfNeeded, !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: root.path),
              (try? SandboxFileSystem.isSymbolicLink(root)) == false else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
        return try SandboxFileSystem.canonicalExistingDirectory(root)
    }

    private func runURL(
        workspaceID: UUID,
        missionRunID: UUID,
        runID: UUID,
        createIfNeeded: Bool
    ) throws -> URL {
        let root = try canonicalStorageRoot(createIfNeeded: createIfNeeded)
        var current = root
        for component in [
            ".controlled-eval-runs",
            workspaceID.uuidString.lowercased(),
            missionRunID.uuidString.lowercased(),
            runID.uuidString.lowercased()
        ] {
            current.appendPathComponent(component, isDirectory: true)
            if createIfNeeded, !FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            guard FileManager.default.fileExists(atPath: current.path),
                  (try? SandboxFileSystem.isSymbolicLink(current)) == false else {
                throw ControlledEvalFailure.artifactPersistenceInvalid
            }
        }
        let canonical = try SandboxFileSystem.canonicalExistingDirectory(current)
        guard SandboxFileSystem.isContained(canonical, in: root) else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
        return canonical.appendingPathComponent("eval-run.json")
    }

    private func runFiles(workspaceID: UUID?) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: storageRoot.path) else { return [] }
        let root = try canonicalStorageRoot(createIfNeeded: false)
        let stateRoot = root.appendingPathComponent(".controlled-eval-runs", isDirectory: true)
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(stateRoot) else { return [] }
        guard (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
        let workspaceRoots: [URL]
        if let workspaceID {
            workspaceRoots = [stateRoot.appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)]
        } else {
            workspaceRoots = try directories(in: stateRoot)
        }
        var urls: [URL] = []
        for workspaceRoot in workspaceRoots where FileManager.default.fileExists(atPath: workspaceRoot.path) {
            for missionRoot in try directories(in: workspaceRoot) {
                for runRoot in try directories(in: missionRoot) {
                    let url = runRoot.appendingPathComponent("eval-run.json")
                    guard SandboxFileSystem.entryExistsWithoutFollowingLinks(url),
                          (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
                        throw ControlledEvalFailure.artifactPersistenceInvalid
                    }
                    urls.append(url)
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func directories(in root: URL) throws -> [URL] {
        guard (try? SandboxFileSystem.isSymbolicLink(root)) == false else {
            throw ControlledEvalFailure.artifactPersistenceInvalid
        }
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard (try? SandboxFileSystem.isSymbolicLink(url)) == false else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.path < $1.path }
    }
}
