import Darwin
import Foundation

struct GeneratedTestPlanningRequest: Sendable {
    var workspaceID: UUID
    var planningTaskID: UUID
    var sourceContext: GeneratedTestPlanningContext
}

struct GeneratedTestPlanStore: Sendable {
    let storageRoot: URL

    func save(_ plan: GeneratedTestPlan) throws {
        guard GeneratedTestPlanDigest.compute(plan) == plan.planSHA256 else {
            throw GeneratedTestError.blocked(.planPersistenceInvalid)
        }
        let url = try planURL(
            workspaceID: plan.sourceBinding.workspaceID,
            planningTaskID: plan.sourceBinding.generatedTestPlanningTaskID,
            createIfNeeded: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if SandboxFileSystem.entryExistsWithoutFollowingLinks(url) {
            guard (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
                throw GeneratedTestError.blocked(.planPersistenceInvalid)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let existing = try? decoder.decode(
                GeneratedTestPlan.self,
                from: Data(contentsOf: url)
            ), GeneratedTestPlanDigest.compute(existing) == existing.planSHA256 else {
                throw GeneratedTestError.blocked(.planPersistenceInvalid)
            }
            if existing.planSHA256 == plan.planSHA256 {
                return
            }
            guard plan.planID == existing.planID,
                  plan.revision == existing.revision + 1,
                  plan.sourceBinding == existing.sourceBinding else {
                throw GeneratedTestError.blocked(.planPersistenceInvalid)
            }
        }
        try encoder.encode(plan).write(to: url, options: [.atomic])
    }

    func load(workspaceID: UUID, planningTaskID: UUID) throws -> GeneratedTestPlan {
        let url = try planURL(
            workspaceID: workspaceID,
            planningTaskID: planningTaskID,
            createIfNeeded: false
        )
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(url),
              (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
            throw GeneratedTestError.blocked(.planPersistenceInvalid)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let plan = try? decoder.decode(GeneratedTestPlan.self, from: Data(contentsOf: url)),
              plan.sourceBinding.workspaceID == workspaceID,
              plan.sourceBinding.generatedTestPlanningTaskID == planningTaskID,
              GeneratedTestPlanDigest.compute(plan) == plan.planSHA256 else {
            throw GeneratedTestError.blocked(.planPersistenceInvalid)
        }
        return plan
    }

    private func planURL(
        workspaceID: UUID,
        planningTaskID: UUID,
        createIfNeeded: Bool
    ) throws -> URL {
        let root = storageRoot.standardizedFileURL
        if createIfNeeded, !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: root.path),
              (try? SandboxFileSystem.isSymbolicLink(root)) == false else {
            throw GeneratedTestError.blocked(.planPersistenceInvalid)
        }
        let canonicalRoot = try SandboxFileSystem.canonicalExistingDirectory(root)
        let stateRoot = canonicalRoot.appendingPathComponent(".generated-test-plans", isDirectory: true)
        let workspaceRoot = stateRoot.appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
        let taskRoot = workspaceRoot.appendingPathComponent(planningTaskID.uuidString.lowercased(), isDirectory: true)
        if createIfNeeded {
            for directory in [stateRoot, workspaceRoot, taskRoot]
                where !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
        }
        guard FileManager.default.fileExists(atPath: taskRoot.path),
              (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false,
              (try? SandboxFileSystem.isSymbolicLink(workspaceRoot)) == false,
              (try? SandboxFileSystem.isSymbolicLink(taskRoot)) == false else {
            throw GeneratedTestError.blocked(.planPersistenceInvalid)
        }
        let canonicalTaskRoot = try SandboxFileSystem.canonicalExistingDirectory(taskRoot)
        guard SandboxFileSystem.isContained(canonicalTaskRoot, in: canonicalRoot) else {
            throw GeneratedTestError.blocked(.planPersistenceInvalid)
        }
        return canonicalTaskRoot.appendingPathComponent("generated-test-plan.json")
    }
}

struct GeneratedTestPlanningService: Sendable {
    let lifecycle: SandboxLifecycleService

    func preparePlan(
        _ request: GeneratedTestPlanningRequest,
        now: Date = Date()
    ) throws -> GeneratedTestPlanningResult {
        let candidateService = CandidatePatchService(lifecycle: lifecycle)
        let manifest: CandidatePatchManifest
        do {
            manifest = try candidateService.validateGeneratedTestSourceAuthority(
                workspaceID: request.workspaceID,
                sourceCandidatePatchTaskID: request.sourceContext.sourceCandidatePatchTaskID,
                sandboxID: request.sourceContext.sandboxID,
                patchID: request.sourceContext.patchID
            )
        } catch let error as CandidatePatchError {
            throw GeneratedTestError.blocked(mapCandidatePatchFailure(error.code))
        }
        guard let artifactSHA256 = manifest.candidatePatchArtifactSHA256,
              let validationPlanSHA256 = manifest.validationTestPlanSHA256,
              let validationPlan = manifest.plan.assessmentContext?.validationTestPlan,
              let diff = manifest.unifiedDiff else {
            throw GeneratedTestError.blocked(.sourceBindingMismatch)
        }

        guard let persistedBinding = CandidatePatchGeneratedTestSourceBinding(manifest: manifest),
              persistedBinding == request.sourceContext.sourceBinding else {
            throw GeneratedTestError.blocked(.sourceBindingMismatch)
        }

        let binding = GeneratedTestSourceBinding(
            workspaceID: persistedBinding.workspaceID,
            generatedTestPlanningTaskID: request.planningTaskID,
            sourceCandidatePatchTaskID: persistedBinding.sourceCandidatePatchTaskID,
            patchID: persistedBinding.patchID,
            candidatePatchPlanID: persistedBinding.candidatePatchPlanID,
            candidatePatchPlanRevision: persistedBinding.candidatePatchPlanRevision,
            candidatePatchManifestID: persistedBinding.candidatePatchManifestID,
            candidatePatchArtifactSHA256: artifactSHA256,
            candidatePatchApprovalProvenanceSHA256: persistedBinding.candidatePatchApprovalProvenanceSHA256,
            sandboxID: persistedBinding.sandboxID,
            sourceSnapshotID: persistedBinding.sourceSnapshotID,
            canonicalLegacyRoot: persistedBinding.canonicalLegacyRoot,
            normalizedCapabilityID: persistedBinding.normalizedCapabilityID,
            capabilityDisplayLabel: persistedBinding.capabilityDisplayLabel,
            validatedAssessmentID: persistedBinding.validatedAssessmentID,
            validationTestPlanSHA256: validationPlanSHA256,
            unifiedDiffSHA256: persistedBinding.unifiedDiffSHA256,
            changedRelativePaths: persistedBinding.changedRelativePaths,
            createdRelativePaths: persistedBinding.createdRelativePaths,
            candidatePatchPostimages: persistedBinding.candidatePatchPostimages,
            authenticatedLocalSessionID: persistedBinding.authenticatedLocalSessionID,
            appSessionID: request.sourceContext.appSessionID
        )

        let resolution = try GeneratedTestEnvironmentResolver(lifecycle: lifecycle)
            .resolve(manifest: manifest, validationPlan: validationPlan)
        let diffHunks = GeneratedTestDiffAnalyzer.hunks(diff: diff, operations: manifest.operations)
        let symbols = GeneratedTestDiffAnalyzer.affectedSymbols(
            operations: manifest.operations,
            hunks: diffHunks
        )

        let shouldClarify = !resolution.isConfirmed || symbols.isEmpty || diffHunks.isEmpty
        var unknowns = resolution.remainingUnknowns
        var questions = resolution.clarificationQuestions
        if diffHunks.isEmpty {
            unknowns.append("No actual Candidate Patch diff hunk was available for scenario grounding.")
            questions.append("Provide a reviewed Candidate Patch with an actual Unified Diff.")
        }
        if symbols.isEmpty {
            unknowns.append("No affected or introduced source symbol could be grounded from the actual diff.")
            questions.append("Identify the exact changed behavior or symbol that the test plan should cover.")
        }

        let proposedPaths = shouldClarify
            ? []
            : proposedTestPaths(
                location: resolution.testLocation!,
                framework: resolution.framework!,
                operations: manifest.operations
            )
        let scenarios = shouldClarify
            ? []
            : makeScenarios(
                manifest: manifest,
                validationPlan: validationPlan,
                diffHunks: diffHunks,
                symbols: symbols,
                proposedPaths: proposedPaths
            )
        if !shouldClarify, scenarios.isEmpty {
            throw GeneratedTestError.blocked(.ungroundedScenario)
        }

        var plan = GeneratedTestPlan(
            planID: UUID(),
            revision: 1,
            status: shouldClarify ? .clarificationRequired : .testPlanReviewReady,
            sourceBinding: binding,
            expectedFramework: resolution.framework,
            frameworkEvidence: resolution.evidence.filter {
                [.projectManifest, .testScript, .dependency, .frameworkConfiguration, .testImport, .testTarget]
                    .contains($0.kind)
            },
            testLocationEvidence: resolution.evidence.filter { $0.kind == .existingTest },
            confirmedTestLocation: resolution.testLocation,
            proposedRelativeTestPaths: proposedPaths,
            proposedScenarios: scenarios,
            diffHunks: diffHunks,
            affectedSymbols: symbols,
            relatedValidationPlanItemIDs: Array(Set(validationPlan.items.map(\.validationItemID))).sorted(),
            relatedAssessmentBlockerIDs: Array(Set(
                validationPlan.items.flatMap(\.relatedBlockerIDs)
                    + scenarios.flatMap(\.relatedAssessmentBlockerIDs)
                    + manifest.plan.blockersAddressed
            )).sorted(),
            relatedEvidenceClaimIDs: Array(Set(
                validationPlan.items.flatMap(\.relatedEvidenceClaimIDs)
                    + scenarios.flatMap(\.evidenceClaimIDs)
            )).sorted(),
            prohibitedOperations: Self.prohibitedOperations,
            remainingUnknowns: Array(Set(unknowns)).sorted(),
            clarificationQuestions: Array(Set(questions)).sorted(),
            planSHA256: "",
            createdAt: now
        )
        plan.planSHA256 = GeneratedTestPlanDigest.compute(plan)
        try GeneratedTestPlanStore(storageRoot: lifecycle.storageRoot).save(plan)
        return GeneratedTestPlanningResult(
            outcome: shouldClarify ? .clarificationRequired : .testPlanReviewReady,
            plan: plan
        )
    }

    static let prohibitedOperations = [
        "Generated test bytes", "Sandbox writes", "test file creation", "test file replacement",
        "generated test revert", "directory creation", "Candidate Patch mutation", "Legacy mutation",
        "dependency modification", "package manager execution", "syntax checking", "Build execution",
        "Test execution", "Shell", "Git", "deployment", "credential access", "production access",
        "Phase 2D.3"
    ]

    private func makeScenarios(
        manifest: CandidatePatchManifest,
        validationPlan: CandidatePatchValidationTestPlan,
        diffHunks: [GeneratedTestDiffHunk],
        symbols: [GeneratedTestAffectedSymbol],
        proposedPaths: [String]
    ) -> [GeneratedTestScenario] {
        guard let testPath = proposedPaths.first else { return [] }
        let hunkIDs = diffHunks.map(\.hunkID).sorted()
        let symbolIDs = symbols.map(\.symbolID).sorted()
        let operationEvidence = Array(Set(manifest.operations.flatMap(\.evidenceClaimIDs))).sorted()
        let blockers = Array(Set(manifest.plan.blockersAddressed)).sorted()
        return validationPlan.items.prefix(16).enumerated().map { index, item in
            GeneratedTestScenario(
                scenarioID: "scenario-\(index + 1)-\(CandidatePatchArtifactAuthority.digest([("item", item.validationItemID)]).prefix(12))",
                title: item.title,
                behaviorUnderTest: item.expectedBehavior,
                sourceDiffHunkIDs: hunkIDs,
                affectedSymbolReferences: symbolIDs,
                validationPlanItemIDs: [item.validationItemID],
                relatedAssessmentBlockerIDs: item.relatedBlockerIDs.isEmpty ? blockers : item.relatedBlockerIDs,
                evidenceClaimIDs: Array(Set(item.relatedEvidenceClaimIDs + operationEvidence)).sorted(),
                expectedTestLevel: item.suggestedTestLevel,
                proposedTestRelativePath: testPath,
                remainingUnknowns: ["Test syntax and behavioral correctness remain unverified."]
            )
        }
    }

    private func proposedTestPaths(
        location: String,
        framework: GeneratedTestFrameworkIdentity,
        operations: [CandidatePatchOperation]
    ) -> [String] {
        guard let source = operations.first?.relativeCanonicalSandboxPath else { return [] }
        let base = URL(fileURLWithPath: source).deletingPathExtension().lastPathComponent
        let name: String
        switch framework.language {
        case "swift": name = "\(base.capitalized)GeneratedTests.swift"
        case "python": name = "test_\(base.replacingOccurrences(of: "-", with: "_"))_generated.py"
        default: name = "\(base).generated.test.ts"
        }
        return [location == "." ? name : "\(location)/\(name)"]
    }

    private func mapCandidatePatchFailure(_ code: CandidatePatchFailureCode) -> GeneratedTestFailureCode {
        switch code {
        case .candidatePatchArtifactDigestMissing: .candidatePatchArtifactDigestMissing
        case .candidatePatchArtifactDigestMismatch: .candidatePatchArtifactDigestMismatch
        case .candidatePatchDiffMismatch: .candidatePatchDiffMismatch
        case .candidatePatchPostimageMismatch: .candidatePatchPostimageMismatch
        case .validationTestPlanMissing: .validationTestPlanMissing
        case .validationTestPlanMismatch: .validationTestPlanMismatch
        default: .sourceBindingMismatch
        }
    }
}

struct GeneratedTestReadOnlySandbox: Sendable {
    let lifecycle: SandboxLifecycleService
    let sandboxID: SandboxID
    let maximumBytes = 524_288

    func read(_ relativePath: String) throws -> (text: String, sha256: String) {
        guard GeneratedTestPlanningPolicy.permits(.readGroundedTestConfiguration) else {
            throw GeneratedTestError.blocked(.sandboxReadRejected)
        }
        let target: URL
        do {
            target = try SandboxPathResolver(storageRoot: lifecycle.storageRoot).resolve(
                sandboxID: sandboxID,
                relativePath: relativePath
            )
        } catch {
            throw GeneratedTestError.blocked(.sandboxReadRejected)
        }
        let descriptor = target.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw GeneratedTestError.blocked(.sandboxReadRejected) }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= off_t(maximumBytes) else {
            throw GeneratedTestError.blocked(.sandboxReadRejected)
        }
        var data = Data(count: Int(info.st_size))
        var offset = 0
        while offset < data.count {
            let remaining = data.count - offset
            let count = data.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.pread(descriptor, base.advanced(by: offset), remaining, off_t(offset))
            }
            guard count > 0 else { throw GeneratedTestError.blocked(.sandboxReadRejected) }
            offset += count
        }
        guard let text = String(data: data, encoding: .utf8), !data.contains(0) else {
            throw GeneratedTestError.blocked(.sandboxReadRejected)
        }
        return (text, CandidatePatchArtifactAuthority.sha256(data))
    }
}

private struct GeneratedTestEnvironmentResolver: Sendable {
    let lifecycle: SandboxLifecycleService

    func resolve(
        manifest: CandidatePatchManifest,
        validationPlan: CandidatePatchValidationTestPlan
    ) throws -> GeneratedTestEnvironmentResolution {
        let inspection = try lifecycle.inspectSandbox(manifest.sandboxID)
        let sourcePaths = inspection.sourceManifest.files.map(\.relativeCanonicalPath)
        let affectedPaths = Set(manifest.operations.map(\.relativeCanonicalSandboxPath))
        let assessmentPaths = Set(manifest.plan.supportingEvidence.flatMap(\.evidenceReferences).map(\.path))
        let relevant = Set(sourcePaths.filter(isRelevantEvidencePath))
            .union(affectedPaths)
            .union(assessmentPaths.filter { sourcePaths.contains($0) })
            .sorted()
            .prefix(64)
        let reader = GeneratedTestReadOnlySandbox(lifecycle: lifecycle, sandboxID: manifest.sandboxID)
        var contents: [String: (text: String, sha256: String)] = [:]
        for path in relevant {
            if let value = try? reader.read(path) { contents[path] = value }
        }

        var frameworkEvidence: [String: [GeneratedTestEvidence]] = [:]
        var testFiles: [(path: String, evidence: GeneratedTestEvidence)] = []
        for (path, value) in contents.sorted(by: { $0.key < $1.key }) {
            let lowerPath = path.lowercased()
            let lowerText = value.text.lowercased()
            if URL(fileURLWithPath: path).lastPathComponent.lowercased() == "package.json",
               let data = value.text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let dependencies = ((object["dependencies"] as? [String: Any]) ?? [:])
                    .merging((object["devDependencies"] as? [String: Any]) ?? [:]) { current, _ in current }
                let testScript = (object["scripts"] as? [String: Any])?["test"] as? String
                for framework in ["vitest", "jest", "mocha"] where dependencies[framework] != nil {
                    frameworkEvidence[framework, default: []].append(evidence(
                        path: path,
                        sha256: value.sha256,
                        kind: .dependency,
                        fact: "Manifest declares the \(framework) test dependency."
                    ))
                    if testScript?.lowercased().contains(framework) == true {
                        frameworkEvidence[framework, default: []].append(evidence(
                            path: path,
                            sha256: value.sha256,
                            kind: .testScript,
                            fact: "Manifest test script invokes \(framework)."
                        ))
                    }
                }
            }
            if lowerPath.hasSuffix("package.swift"), lowerText.contains(".testtarget") {
                frameworkEvidence["swift-test-target", default: []].append(evidence(
                    path: path,
                    sha256: value.sha256,
                    kind: .testTarget,
                    fact: "Package manifest declares a Swift test target."
                ))
            }
            if lowerPath.contains("vitest.config") {
                frameworkEvidence["vitest", default: []].append(evidence(path: path, sha256: value.sha256, kind: .frameworkConfiguration, fact: "Vitest configuration exists."))
            }
            if lowerPath.contains("jest.config") {
                frameworkEvidence["jest", default: []].append(evidence(path: path, sha256: value.sha256, kind: .frameworkConfiguration, fact: "Jest configuration exists."))
            }
            if lowerPath.hasSuffix("pytest.ini") || (lowerPath.hasSuffix("pyproject.toml") && lowerText.contains("pytest")) {
                frameworkEvidence["pytest", default: []].append(evidence(path: path, sha256: value.sha256, kind: .frameworkConfiguration, fact: "Pytest configuration or dependency exists."))
            }
            if isTestPath(path) {
                let item = evidence(path: path, sha256: value.sha256, kind: .existingTest, fact: "Existing test file establishes a project test location.")
                testFiles.append((path, item))
                if lowerText.contains("from \"vitest\"") || lowerText.contains("from 'vitest'") {
                    frameworkEvidence["vitest", default: []].append(evidence(path: path, sha256: value.sha256, kind: .testImport, fact: "Existing test imports Vitest."))
                }
                if lowerText.contains("@jest/") || lowerText.contains("from \"@jest") || lowerText.contains("jest.") {
                    frameworkEvidence["jest", default: []].append(evidence(path: path, sha256: value.sha256, kind: .testImport, fact: "Existing test uses Jest."))
                }
                if lowerText.contains("import xctest") {
                    frameworkEvidence["xctest", default: []].append(evidence(path: path, sha256: value.sha256, kind: .testImport, fact: "Existing test imports XCTest."))
                }
                if lowerText.contains("import testing") {
                    frameworkEvidence["swift-testing", default: []].append(evidence(path: path, sha256: value.sha256, kind: .testImport, fact: "Existing test imports Swift Testing."))
                }
                if lowerText.contains("import pytest") || lowerText.contains("@pytest") {
                    frameworkEvidence["pytest", default: []].append(evidence(path: path, sha256: value.sha256, kind: .testImport, fact: "Existing test uses pytest."))
                }
            }
        }

        frameworkEvidence.removeValue(forKey: "swift-test-target")
        let confirmedFrameworks = frameworkEvidence.keys.sorted()
        let frameworkStatus: GeneratedTestEnvironmentResolutionStatus
        let framework: GeneratedTestFrameworkIdentity?
        if confirmedFrameworks.count == 1, let value = confirmedFrameworks.first {
            frameworkStatus = .frameworkConfirmed
            framework = identity(value)
        } else if confirmedFrameworks.isEmpty {
            frameworkStatus = .frameworkUnknown
            framework = nil
        } else {
            frameworkStatus = .frameworkConflict
            framework = nil
        }

        let locations = Set(testFiles.map { parentPath($0.path) })
        let locationStatus: GeneratedTestEnvironmentResolutionStatus
        let location: String?
        if locations.count == 1, let only = locations.first {
            locationStatus = .testLocationConfirmed
            location = only.isEmpty ? "." : only
        } else if locations.isEmpty {
            locationStatus = .testLocationUnknown
            location = nil
        } else {
            let affectedNames = Set(affectedPaths.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() })
            let nearby = Set(testFiles.filter { file in
                affectedNames.contains { file.path.lowercased().contains($0) }
            }.map { parentPath($0.path) })
            if nearby.count == 1, let only = nearby.first {
                locationStatus = .testLocationConfirmed
                location = only.isEmpty ? "." : only
            } else {
                locationStatus = .testLocationConflict
                location = nil
            }
        }

        var unknowns: [String] = []
        var questions: [String] = []
        if frameworkStatus == .frameworkUnknown {
            unknowns.append("No manifest dependency, test script, framework configuration, or existing test import grounds a test framework.")
            questions.append("Which existing test framework should be used, and which checked-in file confirms it?")
        } else if frameworkStatus == .frameworkConflict {
            unknowns.append("Conflicting concrete framework evidence was found: \(confirmedFrameworks.joined(separator: ", ")).")
            questions.append("Which of the detected frameworks is authoritative for this Candidate Patch?")
        }
        if locationStatus == .testLocationUnknown {
            unknowns.append("No existing test file establishes a grounded test location.")
            questions.append("Which existing test directory should contain the proposed Generated Test Candidate?")
        } else if locationStatus == .testLocationConflict {
            unknowns.append("Multiple test locations exist and none is uniquely related to the changed source.")
            questions.append("Which detected test directory is authoritative for this Patch?")
        }
        let evidenceValues = Array(Set(frameworkEvidence.values.flatMap { $0 } + testFiles.map(\.evidence)))
            .sorted { $0.evidenceID < $1.evidenceID }
        _ = validationPlan
        return GeneratedTestEnvironmentResolution(
            frameworkStatus: frameworkStatus,
            locationStatus: locationStatus,
            framework: framework,
            testLocation: location,
            evidence: evidenceValues,
            remainingUnknowns: unknowns,
            clarificationQuestions: questions
        )
    }

    private func isRelevantEvidencePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: lower).lastPathComponent
        return ["package.json", "package.swift", "pyproject.toml", "pytest.ini", "setup.cfg"]
            .contains(name)
            || name.contains("jest.config")
            || name.contains("vitest.config")
            || isTestPath(path)
    }

    private func parentPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count > 1 else { return "." }
        return components.dropLast().joined(separator: "/")
    }

    private func isTestPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: lower).lastPathComponent
        return lower.hasPrefix("tests/")
            || lower.contains("/tests/")
            || lower.contains("/__tests__/")
            || name.hasSuffix("tests.swift")
            || name.hasSuffix("test.swift")
            || name.hasSuffix(".test.ts")
            || name.hasSuffix(".spec.ts")
            || name.hasPrefix("test_") && name.hasSuffix(".py")
    }

    private func evidence(
        path: String,
        sha256: String,
        kind: GeneratedTestEvidenceKind,
        fact: String
    ) -> GeneratedTestEvidence {
        GeneratedTestEvidence(
            evidenceID: CandidatePatchArtifactAuthority.digest([
                ("kind", kind.rawValue), ("path", path), ("sha256", sha256), ("fact", fact)
            ]),
            kind: kind,
            relativePath: path,
            sha256: sha256,
            safeFact: fact
        )
    }

    private func identity(_ value: String) -> GeneratedTestFrameworkIdentity {
        switch value {
        case "vitest": .init(frameworkID: value, displayName: "Vitest", language: "typescript")
        case "jest": .init(frameworkID: value, displayName: "Jest", language: "typescript")
        case "mocha": .init(frameworkID: value, displayName: "Mocha", language: "typescript")
        case "xctest": .init(frameworkID: value, displayName: "XCTest", language: "swift")
        case "swift-testing": .init(frameworkID: value, displayName: "Swift Testing", language: "swift")
        case "pytest": .init(frameworkID: value, displayName: "pytest", language: "python")
        default: .init(frameworkID: value, displayName: value, language: "unknown")
        }
    }
}

enum GeneratedTestDiffAnalyzer {
    static func hunks(
        diff: String,
        operations: [CandidatePatchOperation]
    ) -> [GeneratedTestDiffHunk] {
        operations.sorted(by: { $0.relativeCanonicalSandboxPath < $1.relativeCanonicalSandboxPath }).compactMap { operation in
            let marker = "+++ b/\(operation.relativeCanonicalSandboxPath)\n"
            guard let markerRange = diff.range(of: marker) else { return nil }
            let remainder = diff[markerRange.upperBound...]
            let sectionEnd = remainder.range(of: "\n--- ")?.lowerBound ?? remainder.endIndex
            let lines = remainder[..<sectionEnd].components(separatedBy: "\n")
            guard let header = lines.first(where: { $0.hasPrefix("@@ ") }) else { return nil }
            let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.map { String($0.dropFirst()) }
            let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.map { String($0.dropFirst()) }
            let hunkID = CandidatePatchArtifactAuthority.digest([
                ("path", operation.relativeCanonicalSandboxPath),
                ("header", header),
                ("added", added.joined(separator: "\n")),
                ("removed", removed.joined(separator: "\n"))
            ])
            return GeneratedTestDiffHunk(
                hunkID: hunkID,
                relativePath: operation.relativeCanonicalSandboxPath,
                header: header,
                addedLines: added,
                removedLines: removed
            )
        }
    }

    static func affectedSymbols(
        operations: [CandidatePatchOperation],
        hunks: [GeneratedTestDiffHunk]
    ) -> [GeneratedTestAffectedSymbol] {
        var result: [GeneratedTestAffectedSymbol] = []
        for operation in operations {
            let addedText = hunks.first(where: { $0.relativePath == operation.relativeCanonicalSandboxPath })?
                .addedLines.joined(separator: "\n") ?? ""
            let patterns: [(String, String)] = [
                (#"\b(?:function|class|interface|struct|enum|protocol|actor|def)\s+([A-Za-z_][A-Za-z0-9_]*)"#, "declaration"),
                (#"\b(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:async\s*)?\("#, "function")
            ]
            for (pattern, kind) in patterns {
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                let text = operation.proposedContent
                let range = NSRange(text.startIndex..<text.endIndex, in: text)
                for match in expression.matches(in: text, range: range) where match.numberOfRanges > 1 {
                    guard let capture = Range(match.range(at: 1), in: text) else { continue }
                    let name = String(text[capture])
                    if operation.operationType == .createTextFile || addedText.contains(name) {
                        result.append(GeneratedTestAffectedSymbol(
                            symbolID: CandidatePatchArtifactAuthority.digest([
                                ("path", operation.relativeCanonicalSandboxPath), ("name", name), ("kind", kind)
                            ]),
                            name: name,
                            relativePath: operation.relativeCanonicalSandboxPath,
                            declarationKind: kind
                        ))
                    }
                }
            }
        }
        return Array(Set(result)).sorted { $0.symbolID < $1.symbolID }
    }
}

enum GeneratedTestPlanDigest {
    static func compute(_ plan: GeneratedTestPlan) -> String {
        var fields: [(String, String)] = [
            ("source_binding_digest", plan.sourceBinding.digest),
            ("plan_id", plan.planID.uuidString.lowercased()),
            ("revision", String(plan.revision)),
            ("status", plan.status.rawValue),
            ("framework_id", plan.expectedFramework?.frameworkID ?? "<unknown>"),
            ("framework_display_name", plan.expectedFramework?.displayName ?? "<unknown>"),
            ("framework_language", plan.expectedFramework?.language ?? "<unknown>"),
            ("test_location", plan.confirmedTestLocation ?? "<unknown>")
        ]
        for (index, evidence) in plan.frameworkEvidence.sorted(by: { $0.evidenceID < $1.evidenceID }).enumerated() {
            fields.append(("framework_evidence_\(index)_path", evidence.relativePath))
            fields.append(("framework_evidence_\(index)_sha256", evidence.sha256))
            fields.append(("framework_evidence_\(index)_kind", evidence.kind.rawValue))
            fields.append(("framework_evidence_\(index)_fact", evidence.safeFact))
        }
        for (index, evidence) in plan.testLocationEvidence.sorted(by: { $0.evidenceID < $1.evidenceID }).enumerated() {
            fields.append(("location_evidence_\(index)_path", evidence.relativePath))
            fields.append(("location_evidence_\(index)_sha256", evidence.sha256))
            fields.append(("location_evidence_\(index)_kind", evidence.kind.rawValue))
        }
        for (index, path) in plan.proposedRelativeTestPaths.sorted().enumerated() {
            fields.append(("proposed_path_\(index)", path))
        }
        for (index, scenario) in plan.proposedScenarios.enumerated() {
            let prefix = "scenario_\(index)"
            fields.append(("\(prefix)_id", scenario.scenarioID))
            fields.append(("\(prefix)_title", scenario.title))
            fields.append(("\(prefix)_behavior", scenario.behaviorUnderTest))
            fields.append(("\(prefix)_path", scenario.proposedTestRelativePath))
            fields.append(("\(prefix)_level", scenario.expectedTestLevel.rawValue))
            for (child, value) in scenario.relatedAssessmentBlockerIDs.sorted().enumerated() {
                fields.append(("\(prefix)_blocker_\(child)", value))
            }
            for (child, value) in scenario.evidenceClaimIDs.sorted().enumerated() {
                fields.append(("\(prefix)_evidence_\(child)", value))
            }
            for (child, value) in scenario.remainingUnknowns.sorted().enumerated() {
                fields.append(("\(prefix)_unknown_\(child)", value))
            }
            for (child, value) in scenario.sourceDiffHunkIDs.sorted().enumerated() {
                fields.append(("\(prefix)_hunk_\(child)", value))
            }
            for (child, value) in scenario.affectedSymbolReferences.sorted().enumerated() {
                fields.append(("\(prefix)_symbol_\(child)", value))
            }
            for (child, value) in scenario.validationPlanItemIDs.sorted().enumerated() {
                fields.append(("\(prefix)_validation_\(child)", value))
            }
        }
        for (index, hunk) in plan.diffHunks.sorted(by: { $0.hunkID < $1.hunkID }).enumerated() {
            fields.append(("hunk_\(index)_id", hunk.hunkID))
            fields.append(("hunk_\(index)_path", hunk.relativePath))
            fields.append(("hunk_\(index)_header", hunk.header))
            fields.append(("hunk_\(index)_added", hunk.addedLines.joined(separator: "\n")))
            fields.append(("hunk_\(index)_removed", hunk.removedLines.joined(separator: "\n")))
        }
        for (index, symbol) in plan.affectedSymbols.sorted(by: { $0.symbolID < $1.symbolID }).enumerated() {
            fields.append(("symbol_\(index)_id", symbol.symbolID))
            fields.append(("symbol_\(index)_name", symbol.name))
            fields.append(("symbol_\(index)_path", symbol.relativePath))
            fields.append(("symbol_\(index)_kind", symbol.declarationKind))
        }
        for (index, value) in plan.relatedValidationPlanItemIDs.sorted().enumerated() {
            fields.append(("validation_reference_\(index)", value))
        }
        for (index, value) in plan.relatedAssessmentBlockerIDs.sorted().enumerated() {
            fields.append(("assessment_blocker_\(index)", value))
        }
        for (index, value) in plan.relatedEvidenceClaimIDs.sorted().enumerated() {
            fields.append(("evidence_claim_\(index)", value))
        }
        for (index, value) in plan.prohibitedOperations.sorted().enumerated() {
            fields.append(("prohibited_\(index)", value))
        }
        for (index, value) in plan.remainingUnknowns.sorted().enumerated() {
            fields.append(("unknown_\(index)", value))
        }
        for (index, value) in plan.clarificationQuestions.sorted().enumerated() {
            fields.append(("clarification_question_\(index)", value))
        }
        return CandidatePatchArtifactAuthority.digest(fields)
    }
}
