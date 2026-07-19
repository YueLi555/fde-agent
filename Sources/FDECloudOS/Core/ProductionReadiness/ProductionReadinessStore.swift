import Foundation

struct ProductionReadinessRestoredArtifacts: Hashable, Sendable {
    var reports: [ProductionReadinessReport]
    var evalPlans: [AIEvalPlan]
}

private struct ProductionReadinessArtifactPairManifest: Codable, Hashable, Sendable {
    var missionRunID: UUID
    var workspaceID: UUID
    var reportID: UUID
    var evalPlanID: UUID
    var sourceBindingSHA256: String
}

struct ProductionReadinessArtifactStore: Sendable {
    let storageRoot: URL

    func save(_ artifacts: ProductionReadinessArtifacts) throws {
        let report = artifacts.report
        let plan = artifacts.evalPlan
        guard artifacts.safetyCounters.hasZeroExecutionAuthority,
              report.sourceBinding == plan.sourceBinding.readinessSourceBinding else {
            throw ProductionReadinessFailure.sourceBindingContradiction
        }
        try ProductionReadinessArtifactValidator.validate(report)
        try ProductionReadinessArtifactValidator.validate(plan)

        // The immutable pair marker is written last. An interrupted first save is
        // therefore never restored as a lone report or Eval Plan, and deterministic
        // artifact IDs make retrying the same exact Mission Run idempotent.
        try save(report)
        try save(plan)
        try savePairManifest(ProductionReadinessArtifactPairManifest(
            missionRunID: report.sourceBinding.missionRunID,
            workspaceID: report.sourceBinding.workspaceID,
            reportID: report.reportID,
            evalPlanID: plan.planID,
            sourceBindingSHA256: report.sourceBinding.sourceBindingSHA256
        ))
    }

    func save(_ report: ProductionReadinessReport) throws {
        try ProductionReadinessArtifactValidator.validate(report)
        let url = try artifactURL(
            workspaceID: report.sourceBinding.workspaceID,
            missionRunID: report.sourceBinding.missionRunID,
            kind: "readiness-reports",
            artifactID: report.reportID,
            filename: "production-readiness-report.json",
            createIfNeeded: true
        )
        if SandboxFileSystem.entryExistsWithoutFollowingLinks(url) {
            let existing: ProductionReadinessReport = try decode(url)
            if isEquivalentInitialGeneration(existing: existing, proposed: report) {
                return
            }
            guard isAppendOnly(existing: existing, proposed: report) else {
                throw ProductionReadinessFailure.revisionImmutable
            }
            if existing == report { return }
        }
        try encode(report, to: url)
    }

    func save(_ plan: AIEvalPlan) throws {
        try ProductionReadinessArtifactValidator.validate(plan)
        let binding = plan.sourceBinding.readinessSourceBinding
        let url = try artifactURL(
            workspaceID: binding.workspaceID,
            missionRunID: binding.missionRunID,
            kind: "ai-eval-plans",
            artifactID: plan.planID,
            filename: "ai-eval-plan.json",
            createIfNeeded: true
        )
        if SandboxFileSystem.entryExistsWithoutFollowingLinks(url) {
            let existing: AIEvalPlan = try decode(url)
            if isEquivalentInitialGeneration(existing: existing, proposed: plan) {
                return
            }
            guard isAppendOnly(existing: existing, proposed: plan) else {
                throw ProductionReadinessFailure.revisionImmutable
            }
            if existing == plan { return }
        }
        try encode(plan, to: url)
    }

    func loadReport(
        workspaceID: UUID,
        missionRunID: UUID,
        reportID: UUID
    ) throws -> ProductionReadinessReport {
        let url = try artifactURL(
            workspaceID: workspaceID,
            missionRunID: missionRunID,
            kind: "readiness-reports",
            artifactID: reportID,
            filename: "production-readiness-report.json",
            createIfNeeded: false
        )
        let report: ProductionReadinessReport = try decode(url)
        guard report.reportID == reportID,
              report.sourceBinding.workspaceID == workspaceID,
              report.sourceBinding.missionRunID == missionRunID else {
            throw ProductionReadinessFailure.sourceBindingContradiction
        }
        try ProductionReadinessArtifactValidator.validate(report)
        return report
    }

    func loadEvalPlan(
        workspaceID: UUID,
        missionRunID: UUID,
        planID: UUID
    ) throws -> AIEvalPlan {
        let url = try artifactURL(
            workspaceID: workspaceID,
            missionRunID: missionRunID,
            kind: "ai-eval-plans",
            artifactID: planID,
            filename: "ai-eval-plan.json",
            createIfNeeded: false
        )
        let plan: AIEvalPlan = try decode(url)
        let binding = plan.sourceBinding.readinessSourceBinding
        guard plan.planID == planID,
              binding.workspaceID == workspaceID,
              binding.missionRunID == missionRunID else {
            throw ProductionReadinessFailure.sourceBindingContradiction
        }
        try ProductionReadinessArtifactValidator.validate(plan)
        return plan
    }

    func loadAllReports(workspaceID: UUID? = nil) throws -> [ProductionReadinessReport] {
        let urls = try artifactFiles(
            workspaceID: workspaceID,
            kind: "readiness-reports",
            filename: "production-readiness-report.json"
        )
        return try urls.map { url in
            let report: ProductionReadinessReport = try decode(url)
            try ProductionReadinessArtifactValidator.validate(report)
            if let workspaceID, report.sourceBinding.workspaceID != workspaceID {
                throw ProductionReadinessFailure.sourceBindingContradiction
            }
            return report
        }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.reportID.uuidString < $1.reportID.uuidString }
            return $0.updatedAt < $1.updatedAt
        }
    }

    func loadAllEvalPlans(workspaceID: UUID? = nil) throws -> [AIEvalPlan] {
        let urls = try artifactFiles(
            workspaceID: workspaceID,
            kind: "ai-eval-plans",
            filename: "ai-eval-plan.json"
        )
        return try urls.map { url in
            let plan: AIEvalPlan = try decode(url)
            try ProductionReadinessArtifactValidator.validate(plan)
            if let workspaceID,
               plan.sourceBinding.readinessSourceBinding.workspaceID != workspaceID {
                throw ProductionReadinessFailure.sourceBindingContradiction
            }
            return plan
        }.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.planID.uuidString < $1.planID.uuidString }
            return $0.updatedAt < $1.updatedAt
        }
    }

    func loadAllPairs(workspaceID: UUID? = nil) throws -> ProductionReadinessRestoredArtifacts {
        let manifests = try pairManifestFiles(workspaceID: workspaceID).map { url -> ProductionReadinessArtifactPairManifest in
            let manifest: ProductionReadinessArtifactPairManifest = try decode(url)
            if let workspaceID, manifest.workspaceID != workspaceID {
                throw ProductionReadinessFailure.sourceBindingContradiction
            }
            return manifest
        }
        var reports: [ProductionReadinessReport] = []
        var plans: [AIEvalPlan] = []
        for manifest in manifests {
            let report = try loadReport(
                workspaceID: manifest.workspaceID,
                missionRunID: manifest.missionRunID,
                reportID: manifest.reportID
            )
            let plan = try loadEvalPlan(
                workspaceID: manifest.workspaceID,
                missionRunID: manifest.missionRunID,
                planID: manifest.evalPlanID
            )
            guard report.sourceBinding == plan.sourceBinding.readinessSourceBinding,
                  report.sourceBinding.sourceBindingSHA256 == manifest.sourceBindingSHA256 else {
                throw ProductionReadinessFailure.sourceBindingContradiction
            }
            reports.append(report)
            plans.append(plan)
        }
        reports.sort {
            if $0.updatedAt == $1.updatedAt { return $0.reportID.uuidString < $1.reportID.uuidString }
            return $0.updatedAt < $1.updatedAt
        }
        plans.sort {
            if $0.updatedAt == $1.updatedAt { return $0.planID.uuidString < $1.planID.uuidString }
            return $0.updatedAt < $1.updatedAt
        }
        return ProductionReadinessRestoredArtifacts(reports: reports, evalPlans: plans)
    }

    private func isAppendOnly(
        existing: ProductionReadinessReport,
        proposed: ProductionReadinessReport
    ) -> Bool {
        proposed.reportID == existing.reportID
            && proposed.sourceBinding == existing.sourceBinding
            && proposed.createdAt == existing.createdAt
            && proposed.revisions.count >= existing.revisions.count
            && proposed.reviewDecisions.count >= existing.reviewDecisions.count
            && Array(proposed.revisions.prefix(existing.revisions.count)) == existing.revisions
            && Array(proposed.reviewDecisions.prefix(existing.reviewDecisions.count)) == existing.reviewDecisions
    }

    private func isEquivalentInitialGeneration(
        existing: ProductionReadinessReport,
        proposed: ProductionReadinessReport
    ) -> Bool {
        guard existing.reportID == proposed.reportID,
              existing.sourceBinding == proposed.sourceBinding,
              existing.revisions.count == 1,
              proposed.revisions.count == 1,
              existing.reviewDecisions.isEmpty,
              proposed.reviewDecisions.isEmpty else {
            return false
        }
        var normalized = proposed
        normalized.createdAt = existing.createdAt
        normalized.updatedAt = existing.updatedAt
        normalized.revisions[0].createdAt = existing.revisions[0].createdAt
        normalized.revisions[0].digest = .compute(
            normalized.revisions[0],
            sourceBinding: normalized.sourceBinding
        )
        return normalized == existing
    }

    private func isAppendOnly(existing: AIEvalPlan, proposed: AIEvalPlan) -> Bool {
        proposed.planID == existing.planID
            && proposed.sourceBinding == existing.sourceBinding
            && proposed.createdAt == existing.createdAt
            && proposed.revisions.count >= existing.revisions.count
            && proposed.reviewDecisions.count >= existing.reviewDecisions.count
            && Array(proposed.revisions.prefix(existing.revisions.count)) == existing.revisions
            && Array(proposed.reviewDecisions.prefix(existing.reviewDecisions.count)) == existing.reviewDecisions
    }

    private func isEquivalentInitialGeneration(
        existing: AIEvalPlan,
        proposed: AIEvalPlan
    ) -> Bool {
        guard existing.planID == proposed.planID,
              existing.sourceBinding == proposed.sourceBinding,
              existing.revisions.count == 1,
              proposed.revisions.count == 1,
              existing.reviewDecisions.isEmpty,
              proposed.reviewDecisions.isEmpty else {
            return false
        }
        var normalized = proposed
        normalized.createdAt = existing.createdAt
        normalized.updatedAt = existing.updatedAt
        normalized.revisions[0].createdAt = existing.revisions[0].createdAt
        normalized.revisions[0].digest = .compute(
            normalized.revisions[0],
            sourceBinding: normalized.sourceBinding
        )
        return normalized == existing
    }

    private func savePairManifest(_ manifest: ProductionReadinessArtifactPairManifest) throws {
        let url = try pairManifestURL(
            workspaceID: manifest.workspaceID,
            missionRunID: manifest.missionRunID,
            createIfNeeded: true
        )
        if SandboxFileSystem.entryExistsWithoutFollowingLinks(url) {
            let existing: ProductionReadinessArtifactPairManifest = try decode(url)
            guard existing == manifest else {
                throw ProductionReadinessFailure.revisionImmutable
            }
            return
        }
        try encode(manifest, to: url)
    }

    private func encode<Value: Encodable>(_ value: Value, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try encoder.encode(value).write(to: url, options: [.atomic])
        } catch {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
        }
    }

    private func decode<Value: Decodable>(_ url: URL) throws -> Value {
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(url),
              (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
        }
    }

    private func canonicalStorageRoot(createIfNeeded: Bool) throws -> URL {
        let root = storageRoot.standardizedFileURL
        if createIfNeeded, !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: root.path),
              (try? SandboxFileSystem.isSymbolicLink(root)) == false else {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
        }
        return try SandboxFileSystem.canonicalExistingDirectory(root)
    }

    private func artifactURL(
        workspaceID: UUID,
        missionRunID: UUID,
        kind: String,
        artifactID: UUID,
        filename: String,
        createIfNeeded: Bool
    ) throws -> URL {
        let root = try canonicalStorageRoot(createIfNeeded: createIfNeeded)
        let componentPath = [
            ".production-readiness-artifacts",
            workspaceID.uuidString.lowercased(),
            missionRunID.uuidString.lowercased(),
            kind,
            artifactID.uuidString.lowercased()
        ]
        var current = root
        for component in componentPath {
            current.appendPathComponent(component, isDirectory: true)
            if createIfNeeded, !FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            guard FileManager.default.fileExists(atPath: current.path),
                  (try? SandboxFileSystem.isSymbolicLink(current)) == false else {
                throw ProductionReadinessFailure.artifactPersistenceInvalid
            }
        }
        let canonical = try SandboxFileSystem.canonicalExistingDirectory(current)
        guard SandboxFileSystem.isContained(canonical, in: root) else {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
        }
        return canonical.appendingPathComponent(filename)
    }

    private func artifactFiles(
        workspaceID: UUID?,
        kind: String,
        filename: String
    ) throws -> [URL] {
        let root = try canonicalStorageRoot(createIfNeeded: false)
        let stateRoot = root.appendingPathComponent(".production-readiness-artifacts", isDirectory: true)
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(stateRoot) else { return [] }
        guard (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false else {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
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
                let kindRoot = missionRoot.appendingPathComponent(kind, isDirectory: true)
                guard FileManager.default.fileExists(atPath: kindRoot.path) else { continue }
                for artifactRoot in try directories(in: kindRoot) {
                    urls.append(artifactRoot.appendingPathComponent(filename))
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func pairManifestURL(
        workspaceID: UUID,
        missionRunID: UUID,
        createIfNeeded: Bool
    ) throws -> URL {
        let root = try canonicalStorageRoot(createIfNeeded: createIfNeeded)
        var current = root
        for component in [
            ".production-readiness-artifacts",
            workspaceID.uuidString.lowercased(),
            missionRunID.uuidString.lowercased()
        ] {
            current.appendPathComponent(component, isDirectory: true)
            if createIfNeeded, !FileManager.default.fileExists(atPath: current.path) {
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            guard FileManager.default.fileExists(atPath: current.path),
                  (try? SandboxFileSystem.isSymbolicLink(current)) == false else {
                throw ProductionReadinessFailure.artifactPersistenceInvalid
            }
        }
        let canonical = try SandboxFileSystem.canonicalExistingDirectory(current)
        guard SandboxFileSystem.isContained(canonical, in: root) else {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
        }
        return canonical.appendingPathComponent("artifact-pair.json")
    }

    private func pairManifestFiles(workspaceID: UUID?) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: storageRoot.path) else { return [] }
        let root = try canonicalStorageRoot(createIfNeeded: false)
        let stateRoot = root.appendingPathComponent(".production-readiness-artifacts", isDirectory: true)
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(stateRoot) else { return [] }
        guard (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false else {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
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
                let manifestURL = missionRoot.appendingPathComponent("artifact-pair.json")
                if SandboxFileSystem.entryExistsWithoutFollowingLinks(manifestURL) {
                    urls.append(manifestURL)
                }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private func directories(in root: URL) throws -> [URL] {
        guard (try? SandboxFileSystem.isSymbolicLink(root)) == false else {
            throw ProductionReadinessFailure.artifactPersistenceInvalid
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
