import Foundation
import XCTest
@testable import FDECloudOS

final class SandboxFoundationTests: XCTestCase {
    func test01Through08SandboxIsOutsideSourceIndependentlyCopiedAndSafelyExcluded() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("print(\"safe\")", to: fixture.legacy.appendingPathComponent("Sources/App.swift"))
        try write("EXAMPLE=true", to: fixture.legacy.appendingPathComponent(".env.example"))
        try write("DO_NOT_READ=secret", to: fixture.legacy.appendingPathComponent(".env"))
        try write("PRIVATE KEY", to: fixture.legacy.appendingPathComponent("keys/server.pem"))
        try write("ref: main", to: fixture.legacy.appendingPathComponent(".git/HEAD"))
        try write("dependency", to: fixture.legacy.appendingPathComponent("node_modules/pkg/index.js"))
        try write("artifact", to: fixture.legacy.appendingPathComponent("build/output.bin"))
        let sourceBefore = try SourceSnapshotBuilder().build(root: fixture.legacy)

        let service = fixture.service()
        let inspection = try service.createSandbox(
            sourceRoot: fixture.legacy,
            approvedLegacyRoot: fixture.legacy
        )
        let sandboxDirectory = try SandboxManifestStore(storageRoot: fixture.sandboxes)
            .validatedSandboxDirectory(inspection.descriptor.sandboxID)
        let workspace = sandboxDirectory.appendingPathComponent("workspace", isDirectory: true)

        XCTAssertFalse(SandboxFileSystem.isContained(sandboxDirectory, in: fixture.legacy))
        XCTAssertEqual(inspection.manifest.status, .ready)
        XCTAssertEqual(inspection.manifest.integrity.status, .passed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Sources/App.swift").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".env.example").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".env").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("keys/server.pem").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent(".git").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("node_modules").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("build").path))

        let sourceIdentity = try SandboxFileSystem.identity(of: fixture.legacy.appendingPathComponent("Sources/App.swift"))
        let copiedIdentity = try SandboxFileSystem.identity(of: workspace.appendingPathComponent("Sources/App.swift"))
        XCTAssertTrue(sourceIdentity.deviceID != copiedIdentity.deviceID || sourceIdentity.inode != copiedIdentity.inode)
        XCTAssertEqual(try SourceSnapshotBuilder().build(root: fixture.legacy).snapshotID, sourceBefore.snapshotID)
        XCTAssertTrue(inspection.manifest.exclusions.contains { $0.reason == .environmentFile })
        XCTAssertTrue(inspection.manifest.exclusions.contains { $0.reason == .privateKey || $0.reason == .certificate })
        XCTAssertTrue(inspection.manifest.exclusions.contains { $0.reason == .versionControlMetadata })
        XCTAssertTrue(inspection.manifest.exclusions.contains { $0.reason == .dependencyDirectory })
        XCTAssertTrue(inspection.manifest.exclusions.contains { $0.reason == .buildArtifact })
    }

    func test09And10AbsoluteAndTraversalWritePathsAreRejected() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        let resolver = SandboxPathResolver(storageRoot: fixture.base.sandboxes)

        assertThrows(.absolutePathRejected) {
            _ = try resolver.resolve(sandboxID: fixture.inspection.descriptor.sandboxID, relativePath: "/tmp/escape")
        }
        assertThrows(.pathTraversalRejected) {
            _ = try resolver.resolve(sandboxID: fixture.inspection.descriptor.sandboxID, relativePath: "../escape")
        }
        assertThrows(.pathTraversalRejected) {
            _ = try resolver.resolve(sandboxID: fixture.inspection.descriptor.sandboxID, relativePath: "Sources/../../escape")
        }
        assertThrows(.metadataPathRejected) {
            _ = try resolver.resolve(sandboxID: fixture.inspection.descriptor.sandboxID, relativePath: "sandbox-manifest.json")
        }
    }

    func test11And12DirectAndNestedSymlinkEscapesAreRejected() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        let resolver = SandboxPathResolver(storageRoot: fixture.base.sandboxes)
        let directory = try SandboxManifestStore(storageRoot: fixture.base.sandboxes)
            .validatedSandboxDirectory(fixture.inspection.descriptor.sandboxID)
        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let outside = fixture.base.container.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try write("outside", to: outside.appendingPathComponent("file.txt"))
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        try FileManager.default.createDirectory(
            at: workspace.appendingPathComponent("nested/path"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("nested/path/escape"),
            withDestinationURL: outside
        )
        try FileManager.default.createSymbolicLink(
            atPath: workspace.appendingPathComponent("dangling-escape").path,
            withDestinationPath: fixture.base.container.appendingPathComponent("missing/outside.txt").path
        )

        assertThrows(.symbolicLinkEscapeRejected) {
            _ = try resolver.resolve(
                sandboxID: fixture.inspection.descriptor.sandboxID,
                relativePath: "escape/file.txt"
            )
        }
        assertThrows(.symbolicLinkEscapeRejected) {
            _ = try resolver.resolve(
                sandboxID: fixture.inspection.descriptor.sandboxID,
                relativePath: "dangling-escape"
            )
        }
        assertThrows(.symbolicLinkEscapeRejected) {
            _ = try resolver.resolve(
                sandboxID: fixture.inspection.descriptor.sandboxID,
                relativePath: "nested/path/escape/file.txt"
            )
        }
    }

    func testSourceSymlinksAreNeverFollowedOrCopied() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("safe", to: fixture.legacy.appendingPathComponent("safe.txt"))
        let outside = fixture.container.appendingPathComponent("outside-secret.txt")
        try write("secret", to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.legacy.appendingPathComponent("linked-secret.txt"),
            withDestinationURL: outside
        )

        let inspection = try fixture.service().createSandbox(
            sourceRoot: fixture.legacy,
            approvedLegacyRoot: fixture.legacy
        )
        let workspace = try SandboxManifestStore(storageRoot: fixture.sandboxes)
            .validatedSandboxDirectory(inspection.descriptor.sandboxID)
            .appendingPathComponent("workspace", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("linked-secret.txt").path))
        XCTAssertTrue(inspection.manifest.exclusions.contains { $0.reason == .symbolicLink })
    }

    func test13AgentWorkspaceSourceIsRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("agent", to: fixture.agent.appendingPathComponent("agent.swift"))
        let service = SandboxLifecycleService(
            storageRoot: fixture.sandboxes,
            agentWorkspaceRoots: [fixture.agent]
        )

        assertThrows(.agentWorkspaceRejected) {
            _ = try service.createSandbox(sourceRoot: fixture.agent, approvedLegacyRoot: fixture.agent)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sandboxes.path))
    }

    func test14SandboxStorageInsideLegacyAndNestedSandboxSourceAreRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("safe", to: fixture.legacy.appendingPathComponent("safe.txt"))
        let unsafeStorage = fixture.legacy.appendingPathComponent("Sandboxes", isDirectory: true)
        let unsafeService = SandboxLifecycleService(storageRoot: unsafeStorage)
        assertThrows(.sandboxRootInsideLegacyRejected) {
            _ = try unsafeService.createSandbox(sourceRoot: fixture.legacy, approvedLegacyRoot: fixture.legacy)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsafeStorage.path))

        try FileManager.default.createDirectory(at: fixture.sandboxes, withIntermediateDirectories: true)
        let nestedSource = fixture.sandboxes.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: true)
        try write("unsafe", to: nestedSource.appendingPathComponent("file.txt"))
        assertThrows(.nestedSandboxRootRejected) {
            _ = try fixture.service().createSandbox(sourceRoot: nestedSource, approvedLegacyRoot: nestedSource)
        }
    }

    func test15InvalidSandboxIDDestructionIsRejectedWithoutDeletion() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        let selectedDirectory = try SandboxManifestStore(storageRoot: fixture.base.sandboxes)
            .validatedSandboxDirectory(fixture.inspection.descriptor.sandboxID)

        assertThrows(.invalidSandboxID) {
            _ = try fixture.base.service().destroySandbox(rawSandboxID: "../../Legacy")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: selectedDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.base.legacy.path))
    }

    func test16DestructionRemovesOnlySelectedSandbox() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("safe", to: fixture.legacy.appendingPathComponent("safe.txt"))
        let service = fixture.service()
        let first = try service.createSandbox(sourceRoot: fixture.legacy, approvedLegacyRoot: fixture.legacy)
        let second = try service.createSandbox(sourceRoot: fixture.legacy, approvedLegacyRoot: fixture.legacy)

        let destroyed = try service.destroySandbox(first.descriptor.sandboxID)
        XCTAssertEqual(destroyed.status, .destroyed)
        XCTAssertThrowsError(try service.inspectSandbox(first.descriptor.sandboxID))
        XCTAssertEqual(try service.inspectSandbox(second.descriptor.sandboxID).manifest.status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacy.appendingPathComponent("safe.txt").path))
        XCTAssertEqual(try service.listActiveSandboxes().map(\.sandboxID), [second.descriptor.sandboxID])
    }

    func test17OriginalSourceHashesAndGitMetadataRemainUnchanged() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("source", to: fixture.legacy.appendingPathComponent("Sources/App.swift"))
        try write("ref: refs/heads/main", to: fixture.legacy.appendingPathComponent(".git/HEAD"))
        let sourceBefore = try SourceSnapshotBuilder().build(root: fixture.legacy)
        let gitBefore = try Data(contentsOf: fixture.legacy.appendingPathComponent(".git/HEAD"))

        _ = try fixture.service().createSandbox(sourceRoot: fixture.legacy, approvedLegacyRoot: fixture.legacy)

        XCTAssertEqual(try SourceSnapshotBuilder().build(root: fixture.legacy).snapshotID, sourceBefore.snapshotID)
        XCTAssertEqual(try Data(contentsOf: fixture.legacy.appendingPathComponent(".git/HEAD")), gitBefore)
    }

    func test18ExternalSourceModificationMarksSandboxStale() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        try write("externally changed", to: fixture.base.legacy.appendingPathComponent("Sources/App.swift"))

        let check = try fixture.base.service().checkSourceIntegrity(fixture.inspection.descriptor.sandboxID)
        XCTAssertEqual(check.state, .changed)
        XCTAssertGreaterThan(check.changedFileCount, 0)
        XCTAssertEqual(
            try fixture.base.service().inspectSandbox(fixture.inspection.descriptor.sandboxID).manifest.status,
            .stale
        )
    }

    func testSourceAdditionIsReportedAsStale() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        try write("added", to: fixture.base.legacy.appendingPathComponent("Sources/Added.swift"))

        let check = try fixture.base.service().checkSourceIntegrity(fixture.inspection.descriptor.sandboxID)
        XCTAssertEqual(check.state, .changed)
        XCTAssertEqual(check.addedFileCount, 1)
        XCTAssertEqual(try fixture.base.service().inspectSandbox(fixture.inspection.descriptor.sandboxID).manifest.status, .stale)
    }

    func testSensitiveSourceMetadataChangeIsDetectedWithoutReadingItsValue() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("safe", to: fixture.legacy.appendingPathComponent("Sources/App.swift"))
        try write("SECRET=one", to: fixture.legacy.appendingPathComponent(".env"))
        let service = fixture.service()
        let inspection = try service.createSandbox(sourceRoot: fixture.legacy, approvedLegacyRoot: fixture.legacy)
        try write("SECRET=a-different-value", to: fixture.legacy.appendingPathComponent(".env"))

        let check = try service.checkSourceIntegrity(inspection.descriptor.sandboxID)
        XCTAssertEqual(check.state, .changed)
        XCTAssertGreaterThan(check.exclusionChangeCount, 0)
        XCTAssertEqual(try service.inspectSandbox(inspection.descriptor.sandboxID).manifest.status, .stale)
    }

    func test19MissingSourceFileMarksSandboxStale() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        try FileManager.default.removeItem(at: fixture.base.legacy.appendingPathComponent("Sources/App.swift"))

        let check = try fixture.base.service().checkSourceIntegrity(fixture.inspection.descriptor.sandboxID)
        XCTAssertEqual(check.state, .changed)
        XCTAssertEqual(check.removedFileCount, 1)
        XCTAssertEqual(try fixture.base.service().inspectSandbox(fixture.inspection.descriptor.sandboxID).manifest.status, .stale)
    }

    func testMovedSourceRootIsReportedAndBlocksReadyStatus() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        let moved = fixture.base.container.appendingPathComponent("LegacyMoved", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.base.legacy, to: moved)

        let check = try fixture.base.service().checkSourceIntegrity(fixture.inspection.descriptor.sandboxID)
        XCTAssertEqual(check.state, .moved)
        XCTAssertEqual(try fixture.base.service().inspectSandbox(fixture.inspection.descriptor.sandboxID).manifest.status, .stale)
    }

    func test20SandboxCopyMismatchPreventsReadyState() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("safe", to: fixture.legacy.appendingPathComponent("Sources/App.swift"))
        let service = fixture.service()
        let prepared = try service.prepareSandbox(sourceRoot: fixture.legacy, approvedLegacyRoot: fixture.legacy)
        let workspace = try SandboxManifestStore(storageRoot: fixture.sandboxes)
            .validatedSandboxDirectory(prepared.descriptor.sandboxID)
            .appendingPathComponent("workspace", isDirectory: true)
        try write("tampered", to: workspace.appendingPathComponent("Sources/App.swift"))

        assertThrows(.copyVerificationFailed) {
            _ = try service.validateSandbox(prepared.descriptor.sandboxID)
        }
        let failed = try service.inspectSandbox(prepared.descriptor.sandboxID)
        XCTAssertEqual(failed.manifest.status, .invalid)
        XCTAssertEqual(failed.manifest.integrity.status, .failed)
        XCTAssertTrue(failed.manifest.integrity.failures.contains("workspace_hash_mismatch"))
    }

    func test21DuplicateSandboxIDIsRejected() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("safe", to: fixture.legacy.appendingPathComponent("safe.txt"))
        let sandboxID = SandboxID()
        let service = fixture.service()
        _ = try service.createSandbox(
            sourceRoot: fixture.legacy,
            approvedLegacyRoot: fixture.legacy,
            sandboxID: sandboxID
        )
        assertThrows(.duplicateSandboxID) {
            _ = try service.createSandbox(
                sourceRoot: fixture.legacy,
                approvedLegacyRoot: fixture.legacy,
                sandboxID: sandboxID
            )
        }
        XCTAssertEqual(try service.listActiveSandboxes().count, 1)
    }

    func test22ActivityUsesOnlySanitizedAggregateSandboxMetadata() throws {
        let sandboxID = SandboxID()
        let snapshot = SandboxActivitySnapshot(
            sandboxID: sandboxID.rawValue,
            sourceSnapshotID: String(repeating: "a", count: 64),
            status: .ready,
            includedFileCount: 3,
            excludedItemCount: 4,
            integrityStatus: .passed,
            sourceUnchanged: true
        )
        let activity = AgentConversationActivity(
            requestID: UUID(),
            startedAt: Date(),
            scope: .engineeringTask,
            kind: .sandboxReady,
            metadata: AgentConversationActivityMetadata(dialogID: UUID(), sandbox: snapshot)
        )
        let encoded = try JSONEncoder().encode(
            SandboxRuntimeActivityUpdate(phase: .sandboxReady, snapshot: snapshot)
        )
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertEqual(activity.label, "Sandbox ready")
        XCTAssertFalse(text.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertFalse(text.contains(".env"))
        XCTAssertFalse(text.lowercased().contains("private"))
    }

    func test23And24NoGitShellBuildTestDeployOrProductMutationCapabilityIsEnabled() throws {
        XCTAssertTrue(SandboxRuntimePolicy.phase2D0Allowlist.isEmpty)
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        let policy = SandboxRuntimePolicy(lifecycle: fixture.base.service())

        for operation in SandboxWritableOperation.allCases {
            let decision = policy.authorize(SandboxWritablePolicyRequest(
                mission: .futureApprovedSandboxMutation,
                sandboxID: fixture.inspection.descriptor.sandboxID,
                relativeTargetPath: "Sources/App.swift",
                operation: operation,
                requiresHumanApproval: false,
                humanApprovalSatisfied: false
            ))
            XCTAssertFalse(decision.allowed)
            XCTAssertTrue(decision.denials.contains(.operationUnavailable))
        }
        XCTAssertFalse(ReadOnlyInspectionPolicy.allowedTools.contains(where: {
            let value = $0.lowercased()
            return value.contains("shell") || value.contains("git") || value.contains("build")
                || value.contains("test") || value.contains("deploy")
        }))
    }

    func test25DisposableFixtureMutationChangesSandboxOnly() throws {
        let fixture = try readyFixture()
        defer { fixture.base.remove() }
        let source = fixture.base.legacy.appendingPathComponent("Sources/App.swift")
        let sourceBefore = try Data(contentsOf: source)
        let target = try SandboxPathResolver(storageRoot: fixture.base.sandboxes).resolve(
            sandboxID: fixture.inspection.descriptor.sandboxID,
            relativePath: "Sources/App.swift"
        )
        try write("sandbox-only mutation", to: target)

        XCTAssertEqual(try Data(contentsOf: source), sourceBefore)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "sandbox-only mutation")
        XCTAssertEqual(
            try fixture.base.service().checkSourceIntegrity(fixture.inspection.descriptor.sandboxID).state,
            .unchanged
        )
    }

    func testManualAcceptanceFlowUsesReadOnlySourceChecksAndSafeDestruction() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try write("safe", to: fixture.legacy.appendingPathComponent("Sources/App.swift"))
        try write("secret", to: fixture.legacy.appendingPathComponent(".env"))
        let expected = try SourceSnapshotBuilder().build(root: fixture.legacy).snapshotID

        let result = try SandboxManualAcceptanceRunner(lifecycle: fixture.service()).run(
            legacyRoot: fixture.legacy,
            approvedLegacyRoot: fixture.legacy,
            expectedSourceSnapshotID: expected,
            destroyAfterInspection: true
        )

        XCTAssertEqual(result.statusBeforeDestruction, .ready)
        XCTAssertEqual(result.integrityStatus, .passed)
        XCTAssertTrue(result.sourceUnchanged)
        XCTAssertEqual(result.expectedSnapshotResult, .matched)
        XCTAssertTrue(result.destroyed)
        XCTAssertTrue(result.activities.contains { $0.phase == .sandboxReady })
        XCTAssertTrue(result.activities.contains { $0.phase == .destroyingSandbox })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.legacy.appendingPathComponent("Sources/App.swift").path))
        XCTAssertTrue(try fixture.service().listActiveSandboxes().isEmpty)
    }

    func testLiveWorkspaceManualAcceptanceWhenExplicitlyEnabled() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FDE_RUN_LIVE_SANDBOX_ACCEPTANCE"] == "1",
              let rootPath = environment["FDE_LIVE_LEGACY_ROOT"],
              let storagePath = environment["FDE_LIVE_SANDBOX_ROOT"] else {
            throw XCTSkip("Set the explicit live-workspace read-only acceptance environment variables to run.")
        }
        let root = URL(fileURLWithPath: rootPath, isDirectory: true)
        let storage = URL(fileURLWithPath: storagePath, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storage) }
        let expectedSnapshotID = environment["FDE_LIVE_SOURCE_SNAPSHOT_ID"]
        let service = SandboxLifecycleService(storageRoot: storage)
        do {
            let sourceBefore = try SourceSnapshotBuilder().build(root: root)
            let result = try SandboxManualAcceptanceRunner(lifecycle: service).run(
                legacyRoot: root,
                approvedLegacyRoot: root,
                expectedSourceSnapshotID: expectedSnapshotID,
                destroyAfterInspection: true
            )
            let sourceAfter = try SourceSnapshotBuilder().build(root: root)

            XCTAssertEqual(result.statusBeforeDestruction, .ready)
            XCTAssertEqual(result.integrityStatus, .passed)
            XCTAssertTrue(result.sourceUnchanged)
            XCTAssertEqual(sourceAfter.snapshotID, sourceBefore.snapshotID)
            XCTAssertTrue(result.destroyed)
            XCTAssertTrue(try service.listActiveSandboxes().isEmpty)
            if expectedSnapshotID == nil {
                XCTAssertEqual(result.expectedSnapshotResult, .notProvided)
            }
            print(
                "FDE_LIVE_SANDBOX_ACCEPTANCE sandbox_id=\(result.sandboxID.rawValue) "
                + "source_snapshot_id=\(result.sourceSnapshotID) status=\(result.statusBeforeDestruction.rawValue) "
                + "included=\(result.includedFileCount) excluded=\(result.excludedItemCount) "
                + "integrity=\(result.integrityStatus.rawValue) source_unchanged=\(result.sourceUnchanged) "
                + "expected_snapshot=\(result.expectedSnapshotResult.rawValue) destroyed=\(result.destroyed)"
            )
        } catch SandboxFoundationError.sourceFileUnavailable {
            print("FDE_LIVE_SANDBOX_ACCEPTANCE_BLOCKED reason=source_file_requires_external_hydration")
            XCTFail("The live fixture contains source files that cannot be hashed without external cloud hydration.")
        }
    }
}

private extension SandboxFoundationTests {
    struct Fixture {
        var container: URL
        var legacy: URL
        var agent: URL
        var sandboxes: URL

        func service() -> SandboxLifecycleService {
            SandboxLifecycleService(storageRoot: sandboxes)
        }

        func remove() {
            try? FileManager.default.removeItem(at: container)
        }
    }

    struct ReadyFixture {
        var base: Fixture
        var inspection: SandboxInspection
    }

    func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDESandboxFoundation-\(UUID().uuidString)", isDirectory: true)
        let legacy = container.appendingPathComponent("Legacy", isDirectory: true)
        let agent = container.appendingPathComponent("Agent", isDirectory: true)
        let sandboxes = container.appendingPathComponent("Managed/Sandboxes", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        return Fixture(container: container, legacy: legacy, agent: agent, sandboxes: sandboxes)
    }

    func readyFixture() throws -> ReadyFixture {
        let fixture = try makeFixture()
        do {
            try write("print(\"source\")", to: fixture.legacy.appendingPathComponent("Sources/App.swift"))
            let inspection = try fixture.service().createSandbox(
                sourceRoot: fixture.legacy,
                approvedLegacyRoot: fixture.legacy
            )
            return ReadyFixture(base: fixture, inspection: inspection)
        } catch {
            fixture.remove()
            throw error
        }
    }

    func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(value.utf8).write(to: url)
    }

    func assertThrows(
        _ expected: SandboxFoundationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? SandboxFoundationError, expected, file: file, line: line)
        }
    }
}
