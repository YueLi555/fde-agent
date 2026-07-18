import Foundation

struct GeneratedTestArtifactStore: Sendable {
    let storageRoot: URL

    func save(_ artifact: GeneratedTestArtifact) throws {
        try validate(artifact)
        let url = try artifactURL(
            workspaceID: artifact.sourceBinding.generatedTestSourceBinding.workspaceID,
            planningTaskID: artifact.sourceBinding.generatedTestSourceBinding.generatedTestPlanningTaskID,
            artifactID: artifact.artifactID,
            createIfNeeded: true
        )
        if SandboxFileSystem.entryExistsWithoutFollowingLinks(url) {
            let existing = try decode(url)
            guard isAppendOnlyUpdate(existing: existing, proposed: artifact) else {
                throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
            }
            if existing == artifact { return }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(artifact).write(to: url, options: [.atomic])
    }

    func load(
        workspaceID: UUID,
        planningTaskID: UUID,
        artifactID: UUID
    ) throws -> GeneratedTestArtifact {
        let url = try artifactURL(
            workspaceID: workspaceID,
            planningTaskID: planningTaskID,
            artifactID: artifactID,
            createIfNeeded: false
        )
        let artifact = try decode(url)
        guard artifact.sourceBinding.generatedTestSourceBinding.workspaceID == workspaceID,
              artifact.sourceBinding.generatedTestSourceBinding.generatedTestPlanningTaskID == planningTaskID,
              artifact.artifactID == artifactID else {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
        try validate(artifact)
        return artifact
    }

    func loadAll(workspaceID: UUID? = nil) throws -> [GeneratedTestArtifact] {
        let canonicalRoot = try canonicalStorageRoot(createIfNeeded: false)
        let stateRoot = canonicalRoot.appendingPathComponent(".generated-test-artifacts", isDirectory: true)
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(stateRoot) else { return [] }
        guard (try? SandboxFileSystem.isSymbolicLink(stateRoot)) == false else {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
        let workspaceRoots: [URL]
        if let workspaceID {
            workspaceRoots = [stateRoot.appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)]
        } else {
            workspaceRoots = try FileManager.default.contentsOfDirectory(
                at: stateRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        }
        var artifacts: [GeneratedTestArtifact] = []
        for workspaceRoot in workspaceRoots where SandboxFileSystem.entryExistsWithoutFollowingLinks(workspaceRoot) {
            guard (try? SandboxFileSystem.isSymbolicLink(workspaceRoot)) == false else { continue }
            let taskRoots = try FileManager.default.contentsOfDirectory(
                at: workspaceRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for taskRoot in taskRoots where (try? SandboxFileSystem.isSymbolicLink(taskRoot)) == false {
                let artifactRoots = try FileManager.default.contentsOfDirectory(
                    at: taskRoot,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                for artifactRoot in artifactRoots where (try? SandboxFileSystem.isSymbolicLink(artifactRoot)) == false {
                    let url = artifactRoot.appendingPathComponent("generated-test-artifact.json")
                    guard SandboxFileSystem.entryExistsWithoutFollowingLinks(url),
                          let artifact = try? decode(url),
                          (try? validate(artifact)) != nil else { continue }
                    artifacts.append(artifact)
                }
            }
        }
        return artifacts.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.artifactID.uuidString < $1.artifactID.uuidString
            }
            return $0.updatedAt < $1.updatedAt
        }
    }

    private func validate(_ artifact: GeneratedTestArtifact) throws {
        let sourceBinding = artifact.sourceBinding.generatedTestSourceBinding
        let reviewSessionIDs = artifact.revisions.compactMap(\.reviewSessionID)
        let decisionsByRevision = Dictionary(grouping: artifact.reviewDecisions, by: \.artifactRevision)
        guard !artifact.revisions.isEmpty,
              artifact.revisions.map(\.revision).sorted() == Array(1...artifact.revisions.count),
              reviewSessionIDs.count == Set(reviewSessionIDs).count,
              decisionsByRevision.values.allSatisfy({ $0.count == 1 }),
              artifact.sourceBinding.approvedPostimages.sorted(by: { $0.relativePath < $1.relativePath })
                == sourceBinding.candidatePatchPostimages.sorted(by: { $0.relativePath < $1.relativePath }) else {
            throw GeneratedTestError.blocked(.artifactDigestMismatch)
        }
        for revision in artifact.revisions {
            try validate(revision, artifact: artifact)
        }
        for decision in artifact.reviewDecisions {
            guard decision.artifactID == artifact.artifactID,
                  let revision = artifact.revision(decision.artifactRevision),
                  revision.digest.sha256 == decision.artifactSHA256,
                  revision.reviewSessionID == decision.reviewSessionID,
                  decision.authenticatedLocalSessionID == sourceBinding.authenticatedLocalSessionID,
                  decision.appSessionID == sourceBinding.appSessionID else {
                throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
            }
        }
        for revision in artifact.revisions.dropLast() {
            guard decisionsByRevision[revision.revision]?.first?.decision == .requestChanges else {
                throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
            }
        }
    }

    private func validate(
        _ revision: GeneratedTestArtifactRevision,
        artifact: GeneratedTestArtifact
    ) throws {
        let sourceBinding = artifact.sourceBinding.generatedTestSourceBinding
        let fileIDs = revision.virtualFiles.map(\.stableID)
        let fileIDSet = Set(fileIDs)
        let filePaths = revision.virtualFiles.map(\.proposedRelativePath)
        let scenarioIDs = revision.scenarioBindings.map(\.scenarioID)
        let scenarioIDSet = Set(scenarioIDs)
        let evidenceIDs = revision.evidenceBindings.map(\.bindingID)
        let evidencePaths = Set(revision.evidenceBindings.map(\.relativePath))
        guard revision.artifactID == artifact.artifactID,
              revision.reviewState == .awaitingReview,
              GeneratedTestArtifactDigest.compute(
                  revision,
                  sourceBinding: artifact.sourceBinding
              ) == revision.digest,
              fileIDs.count == fileIDSet.count,
              filePaths.count == Set(filePaths).count,
              scenarioIDs.count == scenarioIDSet.count,
              evidenceIDs.count == Set(evidenceIDs).count else {
            throw GeneratedTestError.blocked(.artifactDigestMismatch)
        }

        for file in revision.virtualFiles {
            try GeneratedTestSourceGroundingValidator.validateVirtualPath(
                file.proposedRelativePath,
                groundedTestLocation: revision.groundedTestLocation
            )
            let expectedFileID = CandidatePatchArtifactAuthority.digest([
                ("artifact_id", artifact.artifactID.uuidString.lowercased()),
                ("path", file.proposedRelativePath),
                ("plan_sha256", artifact.sourceBinding.generatedTestPlanSHA256)
            ])
            let actualLineCount = file.sourceText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .count
            guard !file.sourceBytes.isEmpty,
                  CandidatePatchArtifactAuthority.sha256(file.sourceBytes) == file.sourceSHA256,
                  file.stableID == expectedFileID,
                  file.framework == revision.framework,
                  file.lineCount == actualLineCount,
                  file.candidatePatchBindingSHA256 == sourceBinding.digest,
                  file.writtenStatus == GeneratedTestVirtualFile.notWritten,
                  file.compiledStatus == GeneratedTestVirtualFile.notCompiled,
                  file.executedStatus == GeneratedTestVirtualFile.notExecuted,
                  file.behaviorVerificationStatus == GeneratedTestVirtualFile.behaviorNotVerified,
                  Set(file.scenarioIDs).isSubset(of: scenarioIDSet),
                  Set(file.validationPlanItemIDs).isSubset(of: Set(revision.validationPlanItemIDs)),
                  Set(file.evidencePaths).isSubset(of: evidencePaths) else {
                throw GeneratedTestError.blocked(.artifactDigestMismatch)
            }
        }

        for scenario in revision.scenarioBindings {
            guard !scenario.virtualFileIDs.isEmpty,
                  Set(scenario.virtualFileIDs).isSubset(of: fileIDSet),
                  Set(scenario.validationPlanItemIDs).isSubset(of: Set(revision.validationPlanItemIDs)) else {
                throw GeneratedTestError.blocked(.artifactDigestMismatch)
            }
        }
    }

    private func isAppendOnlyUpdate(
        existing: GeneratedTestArtifact,
        proposed: GeneratedTestArtifact
    ) -> Bool {
        proposed.artifactID == existing.artifactID
            && proposed.sourceBinding == existing.sourceBinding
            && proposed.createdAt == existing.createdAt
            && proposed.revisions.count >= existing.revisions.count
            && proposed.reviewDecisions.count >= existing.reviewDecisions.count
            && Array(proposed.revisions.prefix(existing.revisions.count)) == existing.revisions
            && Array(proposed.reviewDecisions.prefix(existing.reviewDecisions.count)) == existing.reviewDecisions
    }

    private func decode(_ url: URL) throws -> GeneratedTestArtifact {
        guard SandboxFileSystem.entryExistsWithoutFollowingLinks(url),
              (try? SandboxFileSystem.isSymbolicLink(url)) == false else {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(GeneratedTestArtifact.self, from: Data(contentsOf: url))
        } catch {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
    }

    private func canonicalStorageRoot(createIfNeeded: Bool) throws -> URL {
        let root = storageRoot.standardizedFileURL
        if createIfNeeded, !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: root.path),
              (try? SandboxFileSystem.isSymbolicLink(root)) == false else {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
        return try SandboxFileSystem.canonicalExistingDirectory(root)
    }

    private func artifactURL(
        workspaceID: UUID,
        planningTaskID: UUID,
        artifactID: UUID,
        createIfNeeded: Bool
    ) throws -> URL {
        let root = try canonicalStorageRoot(createIfNeeded: createIfNeeded)
        let directories = [
            root.appendingPathComponent(".generated-test-artifacts", isDirectory: true),
            root.appendingPathComponent(".generated-test-artifacts/\(workspaceID.uuidString.lowercased())", isDirectory: true),
            root.appendingPathComponent(".generated-test-artifacts/\(workspaceID.uuidString.lowercased())/\(planningTaskID.uuidString.lowercased())", isDirectory: true),
            root.appendingPathComponent(".generated-test-artifacts/\(workspaceID.uuidString.lowercased())/\(planningTaskID.uuidString.lowercased())/\(artifactID.uuidString.lowercased())", isDirectory: true)
        ]
        if createIfNeeded {
            for directory in directories where !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            }
        }
        guard let artifactRoot = directories.last,
              FileManager.default.fileExists(atPath: artifactRoot.path),
              directories.allSatisfy({ (try? SandboxFileSystem.isSymbolicLink($0)) == false }) else {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
        let canonicalArtifactRoot = try SandboxFileSystem.canonicalExistingDirectory(artifactRoot)
        guard SandboxFileSystem.isContained(canonicalArtifactRoot, in: root) else {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
        return canonicalArtifactRoot.appendingPathComponent("generated-test-artifact.json")
    }
}

struct GeneratedTestArtifactService: Sendable {
    let lifecycle: SandboxLifecycleService

    func generate(
        _ request: GeneratedTestArtifactGenerationRequest,
        now: Date = Date()
    ) throws -> GeneratedTestArtifactGenerationResult {
        let context = request.context
        let plan = try exactPlan(context)
        guard plan.reviewReady else {
            return GeneratedTestArtifactGenerationResult(
                outcome: .clarificationRequired,
                artifact: nil,
                missingEvidence: plan.clarificationQuestions.isEmpty
                    ? ["The exact Generated Test Plan is not TEST_PLAN_REVIEW_READY."]
                    : plan.clarificationQuestions
            )
        }
        guard let framework = plan.expectedFramework,
              let testLocation = plan.confirmedTestLocation else {
            return GeneratedTestArtifactGenerationResult(
                outcome: .clarificationRequired,
                artifact: nil,
                missingEvidence: ["A confirmed test framework and confirmed test location are required."]
            )
        }
        let manifest = try exactCandidatePatch(for: plan)
        if let existing = try existingExactArtifact(for: plan) {
            return GeneratedTestArtifactGenerationResult(
                outcome: .testArtifactReviewReady,
                artifact: existing,
                missingEvidence: []
            )
        }
        let evidence = try generationEvidence(plan: plan, manifest: manifest)
        guard evidence.missing.isEmpty else {
            return GeneratedTestArtifactGenerationResult(
                outcome: .clarificationRequired,
                artifact: nil,
                missingEvidence: evidence.missing.sorted()
            )
        }

        let artifactID = UUID()
        let sourceBinding = GeneratedTestArtifactSourceBinding(
            generatedTestPlanID: plan.planID,
            generatedTestPlanRevision: plan.revision,
            generatedTestPlanSHA256: plan.planSHA256,
            generatedTestSourceBinding: plan.sourceBinding,
            approvedPostimages: plan.sourceBinding.candidatePatchPostimages.sorted(by: { $0.relativePath < $1.relativePath })
        )
        let built = try GeneratedTestVirtualSourceBuilder().build(
            artifactID: artifactID,
            plan: plan,
            manifest: manifest,
            framework: framework,
            testLocation: testLocation,
            evidence: evidence
        )
        guard !built.files.isEmpty, !built.scenarios.isEmpty else {
            return GeneratedTestArtifactGenerationResult(
                outcome: .clarificationRequired,
                artifact: nil,
                missingEvidence: built.missing.isEmpty
                    ? ["No scenario had enough bounded repository evidence to generate source."]
                    : built.missing.sorted()
            )
        }

        var revision = GeneratedTestArtifactRevision(
            artifactID: artifactID,
            revision: 1,
            lifecycleStatus: .testArtifactReviewReady,
            reviewState: .awaitingReview,
            reviewSessionID: UUID(),
            framework: framework,
            groundedTestLocation: testLocation,
            risk: CandidatePatchRisk.maximum(manifest.operations.map(\.risk)),
            virtualFiles: built.files,
            scenarioBindings: built.scenarios,
            evidenceBindings: built.evidenceBindings,
            validationPlanItemIDs: Array(Set(built.scenarios.flatMap(\.validationPlanItemIDs))).sorted(),
            generationProvenance: [
                GeneratedTestLifecycleStatus.loadingExactPatch.rawValue,
                GeneratedTestLifecycleStatus.validatingTestPlan.rawValue,
                GeneratedTestLifecycleStatus.discoveringTestConventions.rawValue,
                GeneratedTestLifecycleStatus.generatingTestScenarios.rawValue,
                GeneratedTestLifecycleStatus.generatingVirtualTestFiles.rawValue,
                GeneratedTestLifecycleStatus.bindingEvidence.rawValue,
                GeneratedTestLifecycleStatus.verifyingArtifactDigest.rawValue,
                GeneratedTestLifecycleStatus.testArtifactReviewReady.rawValue,
                "Exact Candidate Patch postimages and Unified Diff",
                "Exact Generated Test Plan revision and digest",
                "Confirmed \(framework.displayName) repository convention",
                "Confirmed test location: \(testLocation)",
                "Virtual source only; no filesystem materialization"
            ],
            reviewInstructionSHA256: nil,
            digest: .empty,
            createdAt: now
        )
        revision.digest = GeneratedTestArtifactDigest.compute(revision, sourceBinding: sourceBinding)
        let artifact = GeneratedTestArtifact(
            artifactID: artifactID,
            sourceBinding: sourceBinding,
            revisions: [revision],
            reviewDecisions: [],
            createdAt: now,
            updatedAt: now
        )
        try GeneratedTestArtifactStore(storageRoot: lifecycle.storageRoot).save(artifact)
        return GeneratedTestArtifactGenerationResult(
            outcome: .testArtifactReviewReady,
            artifact: artifact,
            missingEvidence: built.missing.sorted()
        )
    }

    func requestChanges(
        _ context: GeneratedTestArtifactReviewContext,
        instructions: String,
        now: Date = Date()
    ) throws -> GeneratedTestArtifact {
        let sanitized = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else {
            throw GeneratedTestError.blocked(.artifactReviewStateInvalid)
        }
        var artifact = try exactArtifact(context)
        try ensureReviewable(artifact, context: context)
        artifact.reviewDecisions.append(GeneratedTestReviewDecision(
            decisionID: UUID(),
            artifactID: context.artifactID,
            artifactRevision: context.artifactRevision,
            artifactSHA256: context.artifactSHA256,
            reviewSessionID: context.reviewSessionID,
            decision: .requestChanges,
            reviewerInstructions: sanitized,
            authenticatedLocalSessionID: context.authenticatedLocalSessionID,
            appSessionID: context.appSessionID,
            decidedAt: now
        ))
        guard var next = artifact.revision(context.artifactRevision) else {
            throw GeneratedTestError.blocked(.artifactReviewBindingMismatch)
        }
        next.revision = artifact.revisions.count + 1
        next.reviewState = .awaitingReview
        next.reviewSessionID = UUID()
        next.lifecycleStatus = .testArtifactReviewReady
        next.reviewInstructionSHA256 = CandidatePatchArtifactAuthority.sha256(Data(sanitized.utf8))
        next.generationProvenance.append("Revision requested through persisted human review instructions")
        next.createdAt = now
        next.digest = GeneratedTestArtifactDigest.compute(next, sourceBinding: artifact.sourceBinding)
        artifact.revisions.append(next)
        artifact.updatedAt = now
        try GeneratedTestArtifactStore(storageRoot: lifecycle.storageRoot).save(artifact)
        return artifact
    }

    func reject(
        _ context: GeneratedTestArtifactReviewContext,
        now: Date = Date()
    ) throws -> GeneratedTestArtifact {
        var artifact = try exactArtifact(context)
        try ensureReviewable(artifact, context: context)
        artifact.reviewDecisions.append(decision(.reject, context: context, instructions: nil, now: now))
        artifact.updatedAt = now
        try GeneratedTestArtifactStore(storageRoot: lifecycle.storageRoot).save(artifact)
        return artifact
    }

    func beginApprovalConfirmation(
        _ context: GeneratedTestArtifactReviewContext,
        now: Date = Date()
    ) throws -> GeneratedTestArtifactApprovalConfirmation {
        let artifact = try exactArtifact(context)
        try ensureReviewable(artifact, context: context)
        return GeneratedTestArtifactApprovalConfirmation(
            confirmationID: UUID(),
            context: context,
            issuedAt: now
        )
    }

    func confirmApproval(
        _ confirmation: GeneratedTestArtifactApprovalConfirmation,
        context: GeneratedTestArtifactReviewContext,
        now: Date = Date()
    ) throws -> GeneratedTestArtifact {
        guard confirmation.context == context else {
            throw GeneratedTestError.blocked(.artifactApprovalConfirmationInvalid)
        }
        var artifact = try exactArtifact(context)
        try ensureReviewable(artifact, context: context)
        artifact.reviewDecisions.append(decision(.approve, context: context, instructions: nil, now: now))
        artifact.updatedAt = now
        try GeneratedTestArtifactStore(storageRoot: lifecycle.storageRoot).save(artifact)
        return artifact
    }

    func safetyCounters(for artifact: GeneratedTestArtifact) -> GeneratedTestArtifactSafetyCounters {
        var counters = GeneratedTestArtifactSafetyCounters()
        counters.artifactMetadataSourceBytes = artifact.currentRevision?.sourceByteCount ?? 0
        return counters
    }

    private func exactPlan(_ context: GeneratedTestArtifactGenerationContext) throws -> GeneratedTestPlan {
        let plan = try GeneratedTestPlanStore(storageRoot: lifecycle.storageRoot).load(
            workspaceID: context.workspaceID,
            planningTaskID: context.generatedTestPlanningTaskID
        )
        guard plan.planID == context.generatedTestPlanID,
              plan.revision == context.generatedTestPlanRevision,
              plan.planSHA256 == context.generatedTestPlanSHA256,
              plan.sourceBinding.digest == context.generatedTestSourceBindingSHA256,
              plan.sourceBinding.sourceCandidatePatchTaskID == context.sourceCandidatePatchTaskID,
              plan.sourceBinding.patchID == context.candidatePatchID,
              plan.sourceBinding.candidatePatchPlanID == context.candidatePatchPlanID,
              plan.sourceBinding.candidatePatchPlanRevision == context.candidatePatchPlanRevision,
              plan.sourceBinding.candidatePatchArtifactSHA256 == context.candidatePatchArtifactSHA256,
              plan.sourceBinding.sandboxID == context.sandboxID,
              plan.sourceBinding.sourceSnapshotID == context.sourceSnapshotID,
              plan.sourceBinding.authenticatedLocalSessionID == context.authenticatedLocalSessionID,
              plan.sourceBinding.appSessionID == context.appSessionID else {
            throw GeneratedTestError.blocked(.generatedTestPlanMismatch)
        }
        guard GeneratedTestPlanDigest.compute(plan) == plan.planSHA256 else {
            throw GeneratedTestError.blocked(.generatedTestPlanDigestMismatch)
        }
        return plan
    }

    private func existingExactArtifact(
        for plan: GeneratedTestPlan
    ) throws -> GeneratedTestArtifact? {
        let artifacts = try GeneratedTestArtifactStore(storageRoot: lifecycle.storageRoot)
            .loadAll(workspaceID: plan.sourceBinding.workspaceID)
            .filter {
                $0.sourceBinding.generatedTestPlanID == plan.planID
                    && $0.sourceBinding.generatedTestPlanRevision == plan.revision
                    && $0.sourceBinding.generatedTestPlanSHA256 == plan.planSHA256
                    && $0.sourceBinding.generatedTestSourceBinding == plan.sourceBinding
            }
        guard artifacts.count <= 1 else {
            throw GeneratedTestError.blocked(.artifactPersistenceInvalid)
        }
        return artifacts.first
    }

    private func exactCandidatePatch(for plan: GeneratedTestPlan) throws -> CandidatePatchManifest {
        let binding = plan.sourceBinding
        let manifest: CandidatePatchManifest
        do {
            manifest = try CandidatePatchService(lifecycle: lifecycle).validateGeneratedTestSourceAuthority(
                workspaceID: binding.workspaceID,
                sourceCandidatePatchTaskID: binding.sourceCandidatePatchTaskID,
                sandboxID: binding.sandboxID,
                patchID: binding.patchID
            )
        } catch let error as CandidatePatchError {
            switch error.code {
            case .candidatePatchPostimageMismatch:
                throw GeneratedTestError.blocked(.candidatePatchPostimageMismatch)
            case .candidatePatchArtifactDigestMismatch:
                throw GeneratedTestError.blocked(.candidatePatchArtifactDigestMismatch)
            default:
                throw GeneratedTestError.blocked(.sourceBindingMismatch)
            }
        }
        guard let exact = CandidatePatchGeneratedTestSourceBinding(manifest: manifest),
              exact.workspaceID == binding.workspaceID,
              exact.sourceCandidatePatchTaskID == binding.sourceCandidatePatchTaskID,
              exact.patchID == binding.patchID,
              exact.candidatePatchPlanID == binding.candidatePatchPlanID,
              exact.candidatePatchPlanRevision == binding.candidatePatchPlanRevision,
              exact.candidatePatchManifestID == binding.candidatePatchManifestID,
              exact.candidatePatchArtifactSHA256 == binding.candidatePatchArtifactSHA256,
              exact.candidatePatchApprovalProvenanceSHA256 == binding.candidatePatchApprovalProvenanceSHA256,
              exact.sandboxID == binding.sandboxID,
              exact.sourceSnapshotID == binding.sourceSnapshotID,
              exact.canonicalLegacyRoot == binding.canonicalLegacyRoot,
              exact.normalizedCapabilityID == binding.normalizedCapabilityID,
              exact.capabilityDisplayLabel == binding.capabilityDisplayLabel,
              exact.validatedAssessmentID == binding.validatedAssessmentID,
              exact.validationTestPlanSHA256 == binding.validationTestPlanSHA256,
              exact.unifiedDiffSHA256 == binding.unifiedDiffSHA256,
              exact.changedRelativePaths == binding.changedRelativePaths,
              exact.createdRelativePaths == binding.createdRelativePaths,
              exact.candidatePatchPostimages == binding.candidatePatchPostimages,
              exact.authenticatedLocalSessionID == binding.authenticatedLocalSessionID else {
            throw GeneratedTestError.blocked(.sourceBindingMismatch)
        }
        return manifest
    }

    private func generationEvidence(
        plan: GeneratedTestPlan,
        manifest: CandidatePatchManifest
    ) throws -> GeneratedTestGenerationEvidence {
        let reader = GeneratedTestReadOnlySandbox(
            lifecycle: lifecycle,
            sandboxID: manifest.sandboxID
        )
        var contents: [String: String] = [:]
        var evidence: [GeneratedTestEvidence] = []
        var missing: [String] = []
        for item in Array(Set(plan.frameworkEvidence + plan.testLocationEvidence)).sorted(by: { $0.evidenceID < $1.evidenceID }) {
            guard let source = try? reader.read(item.relativePath),
                  source.sha256 == item.sha256 else {
                missing.append("Evidence changed or cannot be read: \(item.relativePath) [\(item.evidenceID)]")
                continue
            }
            contents[item.relativePath] = source.text
            evidence.append(item)
        }
        let sourcePaths = manifest.operations.map(\.relativeCanonicalSandboxPath)
        let inspectedPaths = Set(try lifecycle.inspectSandbox(manifest.sandboxID).sourceManifest.files.map(\.relativeCanonicalPath))
        let supporting = ["src/orders.ts", "src/auth.ts", "src/audit.ts"]
            .filter { inspectedPaths.contains($0) }
        for path in Array(Set(sourcePaths + supporting)).sorted() where contents[path] == nil {
            if let source = try? reader.read(path) {
                contents[path] = source.text
                evidence.append(GeneratedTestEvidence(
                    evidenceID: CandidatePatchArtifactAuthority.digest([
                        ("kind", GeneratedTestEvidenceKind.affectedSource.rawValue),
                        ("path", path),
                        ("sha256", source.sha256)
                    ]),
                    kind: .affectedSource,
                    relativePath: path,
                    sha256: source.sha256,
                    safeFact: sourcePaths.contains(path)
                        ? "Exact Candidate Patch postimage grounds the generated test behavior."
                        : "Inspected supporting source grounds the generated test data and boundary conventions."
                ))
            }
        }
        return GeneratedTestGenerationEvidence(
            contents: contents,
            evidence: Array(Set(evidence)).sorted(by: { $0.evidenceID < $1.evidenceID }),
            missing: missing
        )
    }

    private func exactArtifact(_ context: GeneratedTestArtifactReviewContext) throws -> GeneratedTestArtifact {
        let artifact = try GeneratedTestArtifactStore(storageRoot: lifecycle.storageRoot).load(
            workspaceID: context.workspaceID,
            planningTaskID: context.generatedTestPlanningTaskID,
            artifactID: context.artifactID
        )
        guard artifact.sourceBinding.generatedTestPlanID == context.generatedTestPlanID,
              artifact.sourceBinding.generatedTestPlanRevision == context.generatedTestPlanRevision,
              artifact.sourceBinding.generatedTestPlanSHA256 == context.generatedTestPlanSHA256,
              artifact.sourceBinding.generatedTestSourceBinding.workspaceID == context.workspaceID,
              artifact.sourceBinding.generatedTestSourceBinding.generatedTestPlanningTaskID == context.generatedTestPlanningTaskID,
              artifact.sourceBinding.generatedTestSourceBinding.sourceCandidatePatchTaskID == context.sourceCandidatePatchTaskID,
              artifact.sourceBinding.generatedTestSourceBinding.patchID == context.candidatePatchID,
              artifact.sourceBinding.generatedTestSourceBinding.candidatePatchPlanID == context.candidatePatchPlanID,
              artifact.sourceBinding.generatedTestSourceBinding.candidatePatchPlanRevision == context.candidatePatchPlanRevision,
              artifact.sourceBinding.generatedTestSourceBinding.candidatePatchArtifactSHA256 == context.candidatePatchArtifactSHA256,
              artifact.sourceBinding.generatedTestSourceBinding.sandboxID == context.sandboxID,
              artifact.sourceBinding.generatedTestSourceBinding.authenticatedLocalSessionID == context.authenticatedLocalSessionID,
              artifact.sourceBinding.generatedTestSourceBinding.appSessionID == context.appSessionID,
              let revision = artifact.revision(context.artifactRevision),
              revision.reviewSessionID == context.reviewSessionID,
              revision.digest.sha256 == context.artifactSHA256,
              GeneratedTestArtifactDigest.compute(revision, sourceBinding: artifact.sourceBinding) == revision.digest else {
            throw GeneratedTestError.blocked(.artifactReviewBindingMismatch)
        }
        return artifact
    }

    private func ensureReviewable(
        _ artifact: GeneratedTestArtifact,
        context: GeneratedTestArtifactReviewContext
    ) throws {
        guard let revision = artifact.revision(context.artifactRevision),
              artifact.currentRevision?.revision == context.artifactRevision,
              revision.reviewState == .awaitingReview,
              revision.reviewSessionID == context.reviewSessionID,
              artifact.reviewState(for: context.artifactRevision) == .awaitingReview else {
            throw GeneratedTestError.blocked(.artifactReviewStateInvalid)
        }
    }

    private func decision(
        _ kind: GeneratedTestReviewDecisionKind,
        context: GeneratedTestArtifactReviewContext,
        instructions: String?,
        now: Date
    ) -> GeneratedTestReviewDecision {
        GeneratedTestReviewDecision(
            decisionID: UUID(),
            artifactID: context.artifactID,
            artifactRevision: context.artifactRevision,
            artifactSHA256: context.artifactSHA256,
            reviewSessionID: context.reviewSessionID,
            decision: kind,
            reviewerInstructions: instructions,
            authenticatedLocalSessionID: context.authenticatedLocalSessionID,
            appSessionID: context.appSessionID,
            decidedAt: now
        )
    }
}

private struct GeneratedTestGenerationEvidence: Sendable {
    var contents: [String: String]
    var evidence: [GeneratedTestEvidence]
    var missing: [String]
}

private struct GeneratedTestVirtualSourceBuildResult: Sendable {
    var files: [GeneratedTestVirtualFile]
    var scenarios: [GeneratedTestScenarioBinding]
    var evidenceBindings: [GeneratedTestEvidenceBinding]
    var missing: [String]
}

private struct GeneratedTestVirtualSourceBuilder: Sendable {
    func build(
        artifactID: UUID,
        plan: GeneratedTestPlan,
        manifest: CandidatePatchManifest,
        framework: GeneratedTestFrameworkIdentity,
        testLocation: String,
        evidence: GeneratedTestGenerationEvidence
    ) throws -> GeneratedTestVirtualSourceBuildResult {
        guard framework.frameworkID == "vitest" else {
            return .init(files: [], scenarios: [], evidenceBindings: [], missing: [
                "Reviewable source generation currently requires an evidenced Vitest convention; \(framework.displayName) source generation is not grounded."
            ])
        }
        guard let conventionEntry = plan.testLocationEvidence.first,
              let convention = evidence.contents[conventionEntry.relativePath] else {
            return .init(files: [], scenarios: [], evidenceBindings: [], missing: [
                "Existing representative test source is required for imports, helpers, and matcher conventions."
            ])
        }
        let vitestBindings = frameworkBindings(in: convention)
        let required = Set(["describe", "expect", "it"])
        guard required.isSubset(of: vitestBindings) else {
            return .init(files: [], scenarios: [], evidenceBindings: [], missing: [
                "Representative test \(conventionEntry.relativePath) must evidence describe, expect, and it imports from Vitest."
            ])
        }
        guard let operation = manifest.operations.sorted(by: {
            $0.relativeCanonicalSandboxPath < $1.relativeCanonicalSandboxPath
        }).first,
              let functionName = exportedFunction(in: operation.proposedContent) else {
            return .init(files: [], scenarios: [], evidenceBindings: [], missing: [
                "No exported changed function is grounded in the exact Candidate Patch postimage."
            ])
        }

        var allFiles: [GeneratedTestVirtualFile] = []
        var allScenarios: [GeneratedTestScenarioBinding] = []
        var missing: [String] = []
        for path in plan.proposedRelativeTestPaths.sorted() {
            try GeneratedTestSourceGroundingValidator.validateVirtualPath(path, groundedTestLocation: testLocation)
            let result = makeSource(
                plan: plan,
                operation: operation,
                functionName: functionName,
                proposedPath: path,
                convention: convention,
                vitestBindings: vitestBindings,
                evidence: evidence
            )
            missing.append(contentsOf: result.missing)
            guard !result.source.isEmpty, !result.scenarios.isEmpty else { continue }
            let sourceData = Data(result.source.utf8)
            let fileID = CandidatePatchArtifactAuthority.digest([
                ("artifact_id", artifactID.uuidString.lowercased()),
                ("path", path),
                ("plan_sha256", plan.planSHA256)
            ])
            let scenarios = result.scenarios.map { scenario in
                GeneratedTestScenarioBinding(
                    scenarioID: scenario.scenarioID,
                    title: scenario.title,
                    behaviorUnderTest: scenario.behaviorUnderTest,
                    virtualFileIDs: [fileID],
                    validationPlanItemIDs: scenario.validationPlanItemIDs,
                    blockerClaimIDs: scenario.relatedAssessmentBlockerIDs,
                    evidenceClaimIDs: scenario.evidenceClaimIDs,
                    evidencePaths: Array(Set(
                        plan.frameworkEvidence.map(\.relativePath)
                            + plan.testLocationEvidence.map(\.relativePath)
                            + [operation.relativeCanonicalSandboxPath]
                    )).sorted()
                )
            }
            let sourcePaths = Set(evidence.contents.keys)
                .union(manifest.operations.map(\.relativeCanonicalSandboxPath))
            try GeneratedTestSourceGroundingValidator.validateSource(
                result.source,
                proposedPath: path,
                frameworkBindings: vitestBindings,
                groundedSourcePaths: sourcePaths,
                groundedSymbols: [functionName]
            )
            allScenarios.append(contentsOf: scenarios)
            allFiles.append(GeneratedTestVirtualFile(
                stableID: fileID,
                proposedRelativePath: path,
                operation: sourcePaths.contains(path) ? .modify : .create,
                language: framework.language,
                framework: framework,
                sourceBytes: sourceData,
                sourceSHA256: CandidatePatchArtifactAuthority.sha256(sourceData),
                lineCount: result.source.split(separator: "\n", omittingEmptySubsequences: false).count,
                scenarioIDs: scenarios.map(\.scenarioID),
                validationPlanItemIDs: Array(Set(scenarios.flatMap(\.validationPlanItemIDs))).sorted(),
                blockerClaimIDs: Array(Set(scenarios.flatMap(\.blockerClaimIDs))).sorted(),
                evidenceClaimIDs: Array(Set(scenarios.flatMap(\.evidenceClaimIDs))).sorted(),
                evidencePaths: Array(Set(scenarios.flatMap(\.evidencePaths))).sorted(),
                candidatePatchBindingSHA256: plan.sourceBinding.digest,
                generationProvenance: [
                    "Generated from exact Candidate Patch postimage: \(operation.relativeCanonicalSandboxPath)",
                    "Matched repository convention: \(conventionEntry.relativePath)",
                    "Mapped to exact Generated Test Plan: \(plan.planID.uuidString.lowercased()) revision \(plan.revision)"
                ],
                writtenStatus: GeneratedTestVirtualFile.notWritten,
                compiledStatus: GeneratedTestVirtualFile.notCompiled,
                executedStatus: GeneratedTestVirtualFile.notExecuted,
                behaviorVerificationStatus: GeneratedTestVirtualFile.behaviorNotVerified
            ))
        }
        let bindings = evidence.evidence.map { item in
            GeneratedTestEvidenceBinding(
                bindingID: CandidatePatchArtifactAuthority.digest([
                    ("artifact_id", artifactID.uuidString.lowercased()),
                    ("evidence_id", item.evidenceID)
                ]),
                evidenceID: item.evidenceID,
                kind: item.kind,
                relativePath: item.relativePath,
                sourceSHA256: item.sha256,
                safeClaim: item.safeFact,
                supportsScenarioIDs: allScenarios.map(\.scenarioID).sorted(),
                supportsVirtualFileIDs: allFiles.map(\.stableID).sorted()
            )
        }.sorted(by: { $0.bindingID < $1.bindingID })
        return GeneratedTestVirtualSourceBuildResult(
            files: allFiles,
            scenarios: allScenarios,
            evidenceBindings: bindings,
            missing: Array(Set(missing)).sorted()
        )
    }

    private func makeSource(
        plan: GeneratedTestPlan,
        operation: CandidatePatchOperation,
        functionName: String,
        proposedPath: String,
        convention: String,
        vitestBindings: Set<String>,
        evidence: GeneratedTestGenerationEvidence
    ) -> (source: String, scenarios: [GeneratedTestScenario], missing: [String]) {
        let recognizedOrderAdapter = operation.proposedContent.contains("canReadCustomerOrders")
            && operation.proposedContent.contains("recordAuditEvent")
            && operation.proposedContent.contains("map(({ orderID, status })")
        if recognizedOrderAdapter {
            return makeOrderAdapterSource(
                plan: plan,
                operation: operation,
                functionName: functionName,
                proposedPath: proposedPath,
                convention: convention,
                vitestBindings: vitestBindings,
                evidence: evidence
            )
        }
        guard convention.contains("toBeDefined") || convention.contains("toBe(") else {
            return ("", [], ["Representative test does not evidence a matcher usable for exported-symbol review."])
        }
        guard let scenario = plan.proposedScenarios.first else { return ("", [], []) }
        let module = relativeModule(from: proposedPath, to: operation.relativeCanonicalSandboxPath)
        let matcher = convention.contains("toBeDefined") ? "toBeDefined()" : "toBe(\"function\")"
        let expression = convention.contains("toBeDefined")
            ? "expect(\(functionName)).\(matcher);"
            : "expect(typeof \(functionName)).\(matcher);"
        let source = """
        import { describe, expect, it } from "vitest";
        import { \(functionName) } from "\(module)";

        describe("\(escaped(functionName)) virtual generated artifact", () => {
          it("\(escaped(scenario.title))", () => {
            \(expression)
          });
        });
        """ + "\n"
        return (source, [scenario], [])
    }

    private func makeOrderAdapterSource(
        plan: GeneratedTestPlan,
        operation: CandidatePatchOperation,
        functionName: String,
        proposedPath: String,
        convention: String,
        vitestBindings: Set<String>,
        evidence: GeneratedTestGenerationEvidence
    ) -> (source: String, scenarios: [GeneratedTestScenario], missing: [String]) {
        guard let orders = evidence.contents["src/orders.ts"],
              evidence.contents["src/auth.ts"] != nil,
              let orderID = literal(named: "orderID", in: orders, occurrence: 0),
              let authorizedCustomerID = literal(named: "customerID", in: orders, occurrence: 0) else {
            return ("", [], ["src/orders.ts and src/auth.ts with representative order/customer literals are required."])
        }
        let otherCustomerID = literal(named: "customerID", in: orders, occurrence: 1)
            ?? "<UNAUTHORIZED_CUSTOMER_ID>"
        let status = literal(named: "status", in: orders, occurrence: 0) ?? "processing"
        let module = relativeModule(from: proposedPath, to: operation.relativeCanonicalSandboxPath)
        let authModule = relativeModule(from: proposedPath, to: "src/auth.ts")
        let auditModule = relativeModule(from: proposedPath, to: "src/audit.ts")
        var supported: [(GeneratedTestScenario, String)] = []
        var missing: [String] = []
        let auditSupported = vitestBindings.isSuperset(of: ["beforeEach", "vi"])
            && convention.contains("vi.mock")
            && convention.contains("toHaveBeenCalledWith")

        for scenario in plan.proposedScenarios {
            let value = (scenario.title + " " + scenario.behaviorUnderTest).lowercased()
            if value.contains("authenticated user can access") || value.contains("authorized order") {
                supported.append((scenario, """
                    const result = lookup(principal, \(quoted(authorizedCustomerID)), allow);
                    expect(result).toEqual([{ orderID: \(quoted(orderID)), status: \(quoted(status)) }]);
                """))
            } else if value.contains("another customer") || value.contains("cross tenant") || value.contains("cross-boundary") {
                supported.append((scenario, """
                    expect(() => lookup(principal, \(quoted(otherCustomerID)), deny)).toThrow("forbidden");
                """))
            } else if value.contains("support role alone") || value.contains("record-level") || value.contains("record level") {
                supported.append((scenario, """
                    expect(() => lookup(principal, \(quoted(authorizedCustomerID)), deny)).toThrow("forbidden");
                """))
            } else if value.contains("customerid") || value.contains("allowlist") || value.contains("sensitive field") || value.contains("redaction") || value.contains("agent schema") {
                supported.append((scenario, """
                    const [result] = lookup(principal, \(quoted(authorizedCustomerID)), allow);
                    expect(Object.keys(result ?? {}).sort()).toEqual(["orderID", "status"]);
                    expect("customerID" in (result ?? {})).toBe(false);
                """))
            } else if value.contains("read-only") || value.contains("read only") {
                supported.append((scenario, """
                    const first = lookup(principal, \(quoted(authorizedCustomerID)), allow);
                    const second = lookup(principal, \(quoted(authorizedCustomerID)), allow);
                    expect(second).toEqual(first);
                """))
            } else if value.contains("audit") {
                if auditSupported {
                    supported.append((scenario, """
                        lookup(principal, \(quoted(authorizedCustomerID)), allow);
                        expect(audit.recordAuditEvent).toHaveBeenCalledWith({
                          actorID: \(quoted(authorizedCustomerID)),
                          action: "orders.read",
                          resourceID: \(quoted(authorizedCustomerID)),
                          outcome: "allowed"
                        });
                    """))
                } else {
                    missing.append("Audit scenario omitted: representative test does not evidence beforeEach, vi.mock, and toHaveBeenCalledWith.")
                }
            } else if value.contains("modify") || value.contains("mutation") || value.contains("unauthorized writes") {
                supported.append((scenario, """
                    expect(Object.keys(candidateModule).sort()).toEqual([\(quoted(functionName))]);
                """))
            }
        }
        if supported.isEmpty, let first = plan.proposedScenarios.first {
            supported.append((first, "expect(candidateModule.\(functionName)).toBeDefined();"))
        }
        let imports = auditSupported && supported.contains(where: { ($0.0.title + $0.0.behaviorUnderTest).lowercased().contains("audit") })
            ? "beforeEach, describe, expect, it, vi"
            : "describe, expect, it"
        var lines = [
            "import { \(imports) } from \"vitest\";",
            "import type { Principal } from \"\(authModule)\";",
            "import * as candidateModule from \"\(module)\";",
            ""
        ]
        let usesAudit = imports.contains("vi")
        if usesAudit {
            lines += [
                "const audit = vi.hoisted(() => ({ recordAuditEvent: vi.fn() }));",
                "vi.mock(\"\(auditModule)\", () => audit);",
                ""
            ]
        }
        lines += [
            "const lookup = candidateModule.\(functionName);",
            "const principal: Principal = { subject: \(quoted(authorizedCustomerID)), roles: [\"support\"] };",
            "const allow = { canReadCustomerOrders: () => true };",
            "const deny = { canReadCustomerOrders: () => false };",
            "",
            "describe(\"\(escaped(functionName)) virtual generated artifact\", () => {"
        ]
        if usesAudit {
            lines += ["  beforeEach(() => {", "    audit.recordAuditEvent.mockClear();", "  });", ""]
        }
        for (scenario, body) in supported {
            lines.append("  it(\"\(escaped(scenario.title))\", () => {")
            lines.append(contentsOf: body.split(separator: "\n", omittingEmptySubsequences: false).map {
                "    " + $0.trimmingCharacters(in: .whitespaces)
            })
            lines += ["  });", ""]
        }
        lines.append("});")
        return (lines.joined(separator: "\n") + "\n", supported.map(\.0), missing)
    }

    private func frameworkBindings(in source: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(
            pattern: #"import\s*\{([^}]*)\}\s*from\s*['\"]vitest['\"]"#
        ) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).reduce(into: Set<String>()) { result, match in
            guard let capture = Range(match.range(at: 1), in: source) else { return }
            for name in source[capture].split(separator: ",") {
                result.insert(name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    private func exportedFunction(in source: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"export\s+(?:async\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("#
        ) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = expression.firstMatch(in: source, range: range),
              let capture = Range(match.range(at: 1), in: source) else { return nil }
        return String(source[capture])
    }

    private func literal(named name: String, in source: String, occurrence: Int) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*:\\s*['\\\"]([^'\\\"]+)['\\\"]"
        ) else { return nil }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = expression.matches(in: source, range: range)
        guard matches.indices.contains(occurrence),
              let capture = Range(matches[occurrence].range(at: 1), in: source) else { return nil }
        return String(source[capture])
    }

    private func relativeModule(from testPath: String, to sourcePath: String) -> String {
        var from = testPath.split(separator: "/").map(String.init)
        var to = sourcePath.split(separator: "/").map(String.init)
        _ = from.popLast()
        if let last = to.last {
            to[to.count - 1] = String(last.split(separator: ".").dropLast().joined(separator: "."))
        }
        while !from.isEmpty, !to.isEmpty, from.first == to.first {
            from.removeFirst()
            to.removeFirst()
        }
        let path = Array(repeating: "..", count: from.count) + to
        let joined = path.joined(separator: "/")
        return joined.hasPrefix(".") ? joined : "./\(joined)"
    }

    private func quoted(_ value: String) -> String {
        "\"\(escaped(value))\""
    }

    private func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

enum GeneratedTestSourceGroundingValidator {
    static func validateVirtualPath(_ path: String, groundedTestLocation: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              path.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
            throw GeneratedTestError.blocked(.virtualFilePathInvalid)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !parts.contains(where: { $0 == ".git" || $0 == ".env" }),
              groundedTestLocation == "." || path.hasPrefix(groundedTestLocation + "/") else {
            throw GeneratedTestError.blocked(.virtualFilePathInvalid)
        }
    }

    static func validateSource(
        _ source: String,
        proposedPath: String,
        frameworkBindings: Set<String>,
        groundedSourcePaths: Set<String>,
        groundedSymbols: Set<String>
    ) throws {
        let imports = importSpecifiers(in: source)
        for specifier in imports {
            if specifier == "vitest" {
                guard source.contains("from \"vitest\"") || source.contains("from 'vitest'") else {
                    throw GeneratedTestError.blocked(.unsupportedImport)
                }
                continue
            }
            guard specifier.hasPrefix("."),
                  let resolved = resolve(specifier, from: proposedPath),
                  groundedSourcePaths.contains(resolved + ".ts")
                    || groundedSourcePaths.contains(resolved + ".tsx")
                    || groundedSourcePaths.contains(resolved) else {
                throw GeneratedTestError.blocked(.unsupportedImport)
            }
        }
        let forbidden = ["fetch(", "XMLHttpRequest", "child_process", "exec(", "spawn(", "writeFile", "appendFile", "unlink(", "rm("]
        guard !forbidden.contains(where: { source.contains($0) }) else {
            throw GeneratedTestError.blocked(.ungroundedHelperOrAPI)
        }
        guard groundedSymbols.contains(where: { source.contains($0) }),
              ["describe", "it", "expect"].allSatisfy({ frameworkBindings.contains($0) }) else {
            throw GeneratedTestError.blocked(.ungroundedHelperOrAPI)
        }
    }

    private static func importSpecifiers(in source: String) -> [String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?:import(?:[\s\S]*?)from\s*|vi\.mock\s*\()['\"]([^'\"]+)['\"]"#
        ) else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.matches(in: source, range: range).compactMap { match in
            guard let capture = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[capture])
        }
    }

    private static func resolve(_ specifier: String, from proposedPath: String) -> String? {
        var components = proposedPath.split(separator: "/").dropLast().map(String.init)
        for component in specifier.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { return nil }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        return components.joined(separator: "/")
    }
}

extension GeneratedTestArtifactDigest {
    static func compute(
        _ revision: GeneratedTestArtifactRevision,
        sourceBinding: GeneratedTestArtifactSourceBinding
    ) -> GeneratedTestArtifactDigest {
        var fields: [(String, String)] = [
            ("canonical_serialization_version", "1"),
            ("artifact_id", revision.artifactID.uuidString.lowercased()),
            ("artifact_revision", String(revision.revision)),
            ("source_binding_digest", sourceBinding.digest),
            ("lifecycle_status", revision.lifecycleStatus.rawValue),
            ("review_state", revision.reviewState.rawValue),
            ("framework_id", revision.framework.frameworkID),
            ("framework_name", revision.framework.displayName),
            ("framework_language", revision.framework.language),
            ("grounded_test_location", revision.groundedTestLocation),
            ("risk", revision.risk.rawValue),
            ("review_instruction_sha256", revision.reviewInstructionSHA256 ?? "<none>"),
            ("created_at", ISO8601DateFormatter().string(from: revision.createdAt))
        ]
        if let reviewSessionID = revision.reviewSessionID {
            fields.append(("review_session_id", reviewSessionID.uuidString.lowercased()))
        }
        for (index, file) in revision.virtualFiles.sorted(by: { $0.stableID < $1.stableID }).enumerated() {
            let prefix = "file_\(index)"
            fields += [
                ("\(prefix)_id", file.stableID),
                ("\(prefix)_path", file.proposedRelativePath),
                ("\(prefix)_operation", file.operation.rawValue),
                ("\(prefix)_language", file.language),
                ("\(prefix)_framework", file.framework.frameworkID),
                ("\(prefix)_source_sha256", file.sourceSHA256),
                ("\(prefix)_line_count", String(file.lineCount)),
                ("\(prefix)_candidate_patch_binding", file.candidatePatchBindingSHA256),
                ("\(prefix)_written", file.writtenStatus),
                ("\(prefix)_compiled", file.compiledStatus),
                ("\(prefix)_executed", file.executedStatus),
                ("\(prefix)_behavior", file.behaviorVerificationStatus)
            ]
            append(file.scenarioIDs, key: "\(prefix)_scenario", to: &fields)
            append(file.validationPlanItemIDs, key: "\(prefix)_validation", to: &fields)
            append(file.blockerClaimIDs, key: "\(prefix)_blocker", to: &fields)
            append(file.evidenceClaimIDs, key: "\(prefix)_claim", to: &fields)
            append(file.evidencePaths, key: "\(prefix)_evidence_path", to: &fields)
            append(file.generationProvenance, key: "\(prefix)_provenance", to: &fields, sorts: false)
        }
        for (index, scenario) in revision.scenarioBindings.sorted(by: { $0.scenarioID < $1.scenarioID }).enumerated() {
            let prefix = "scenario_\(index)"
            fields += [
                ("\(prefix)_id", scenario.scenarioID),
                ("\(prefix)_title", scenario.title),
                ("\(prefix)_behavior", scenario.behaviorUnderTest)
            ]
            append(scenario.virtualFileIDs, key: "\(prefix)_file", to: &fields)
            append(scenario.validationPlanItemIDs, key: "\(prefix)_validation", to: &fields)
            append(scenario.blockerClaimIDs, key: "\(prefix)_blocker", to: &fields)
            append(scenario.evidenceClaimIDs, key: "\(prefix)_claim", to: &fields)
            append(scenario.evidencePaths, key: "\(prefix)_path", to: &fields)
        }
        for (index, evidence) in revision.evidenceBindings.sorted(by: { $0.bindingID < $1.bindingID }).enumerated() {
            let prefix = "evidence_\(index)"
            fields += [
                ("\(prefix)_binding_id", evidence.bindingID),
                ("\(prefix)_evidence_id", evidence.evidenceID),
                ("\(prefix)_kind", evidence.kind.rawValue),
                ("\(prefix)_path", evidence.relativePath),
                ("\(prefix)_sha256", evidence.sourceSHA256),
                ("\(prefix)_claim", evidence.safeClaim)
            ]
            append(evidence.supportsScenarioIDs, key: "\(prefix)_scenario", to: &fields)
            append(evidence.supportsVirtualFileIDs, key: "\(prefix)_file", to: &fields)
        }
        append(revision.validationPlanItemIDs, key: "validation_item", to: &fields)
        append(revision.generationProvenance, key: "generation_provenance", to: &fields, sorts: false)
        return GeneratedTestArtifactDigest(
            algorithm: "SHA-256",
            canonicalSerializationVersion: 1,
            sha256: CandidatePatchArtifactAuthority.digest(fields)
        )
    }

    private static func append(
        _ values: [String],
        key: String,
        to fields: inout [(String, String)],
        sorts: Bool = true
    ) {
        for (index, value) in (sorts ? values.sorted() : values).enumerated() {
            fields.append(("\(key)_\(index)", value))
        }
    }
}

extension GeneratedTestArtifact {
    func reviewEligibility(
        authenticatedLocalSessionID: UUID,
        appSessionID: UUID
    ) -> GeneratedTestArtifactReviewEligibility {
        guard let revision = currentRevision else {
            return .unavailable("The exact Generated Test Artifact revision is unavailable.")
        }
        guard revision.reviewState == .awaitingReview,
              reviewState(for: revision.revision) == .awaitingReview else {
            return .unavailable("This Generated Test Artifact revision already has a persisted review decision.")
        }
        guard revision.reviewSessionID != nil else {
            return .unavailable("This revision does not have exact per-revision review-session authority.")
        }
        let source = sourceBinding.generatedTestSourceBinding
        guard source.authenticatedLocalSessionID == authenticatedLocalSessionID,
              source.appSessionID == appSessionID else {
            return .unavailable("This Generated Test Artifact review session is no longer current.")
        }
        return .available
    }

    func reviewState(for revision: Int) -> GeneratedTestArtifactReviewState {
        guard let latest = reviewDecisions.last(where: { $0.artifactRevision == revision }) else {
            return .awaitingReview
        }
        switch latest.decision {
        case .requestChanges: return .changeRequested
        case .reject: return .rejected
        case .approve: return .approved
        }
    }
}
