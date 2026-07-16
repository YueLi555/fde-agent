import XCTest
@testable import FDECloudOS

final class EngineeringExecutionTests: XCTestCase {
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
    }

    func testRepositoryDiscoveryBuildsCodebaseModel() throws {
        let root = try makeRepository()
        try write(
            """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(name: "Fixture")
            """,
            to: "Package.swift",
            under: root
        )
        try write(
            """
            import Foundation

            struct AppModel {
                func run() {}
            }
            """,
            to: "Sources/App/AppModel.swift",
            under: root
        )
        try write(
            """
            import XCTest
            final class AppModelTests: XCTestCase {}
            """,
            to: "Tests/AppModelTests.swift",
            under: root
        )
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let model = try CodebaseIntelligence().discover(
            rootPath: root.path,
            changedFiles: ["Sources/App/AppModel.swift"]
        )

        XCTAssertEqual(model.repositoryKind, .swiftPackage)
        XCTAssertTrue(model.files.contains { $0.path == "Sources/App/AppModel.swift" })
        XCTAssertTrue(model.symbols.contains { $0.name == "AppModel" && $0.kind == .struct })
        XCTAssertTrue(model.symbols.contains { $0.name == "run" && $0.kind == .function })
        XCTAssertTrue(model.dependencies.contains { $0.name == "Foundation" })
        XCTAssertTrue(model.changeImpacts.contains { $0.changedPath == "Sources/App/AppModel.swift" })
        XCTAssertFalse(model.ownership.isEmpty)
        XCTAssertEqual(model.evidence.validation, .valid)
    }

    func testFileModificationProducesEvidence() async throws {
        let root = try makeRepository()
        try write("let value = 1\n", to: "Sources/App/Value.swift", under: root)
        let connector = LocalEngineeringConnector(workspaceRoot: root)

        let result = try await connector.editFile(
            EngineeringPlannedEdit(
                path: "Sources/App/Value.swift",
                newContents: "let value = 2\n",
                summary: "Update fixture value."
            )
        )

        let updated = try String(contentsOf: root.appendingPathComponent("Sources/App/Value.swift"), encoding: .utf8)
        XCTAssertTrue(updated.contains("value = 2"))
        XCTAssertEqual(result.kind, .editFile)
        XCTAssertEqual(result.evidence.validation, .valid)
        XCTAssertTrue(result.evidence.action.contains("engineering.edit_file"))
        XCTAssertEqual(result.files, ["Sources/App/Value.swift"])
    }

    func testFailedTestRecoveryRepairsAndValidatesAgain() async throws {
        let root = try makeRepository()
        try write("func value() -> Int { 1 }\n", to: "Sources/App/Value.swift", under: root)
        let runner = ScriptedCommandRunner(responses: [
            (1, "", "first validation failed"),
            (0, "second validation passed", "")
        ])
        let connector = LocalEngineeringConnector(workspaceRoot: root, commandRunner: runner)
        let validation = EngineeringValidationStep(
            command: EngineeringCommand(command: "swift", arguments: ["test"]),
            purpose: "Run unit tests"
        )
        let plan = EngineeringChangePlan(
            objective: "Fix value calculation",
            targetFiles: ["Sources/App/Value.swift"],
            expectedChanges: ["Update value implementation and verify tests."],
            validationPlan: [validation],
            plannedEdits: [
                EngineeringPlannedEdit(
                    path: "Sources/App/Value.swift",
                    newContents: "func value() -> Int { 2 }\n",
                    summary: "Apply initial implementation."
                )
            ],
            repairEdits: [
                EngineeringPlannedEdit(
                    path: "Sources/App/Value.swift",
                    newContents: "func value() -> Int { 3 }\n",
                    summary: "Repair failed validation."
                )
            ]
        )

        let result = await AutonomousEngineeringLoop().run(plan: plan, connector: connector, approved: true)

        let updated = try String(contentsOf: root.appendingPathComponent("Sources/App/Value.swift"), encoding: .utf8)
        XCTAssertTrue(result.validationPassed)
        XCTAssertTrue(result.stages.contains { $0.stage == .observeFailure })
        XCTAssertTrue(result.stages.contains { $0.stage == .repair })
        XCTAssertTrue(result.stages.contains { $0.stage == .validateAgain })
        XCTAssertTrue(updated.contains("3"))
        let callCount = await runner.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testApprovalRequiredChangeBlocksModification() async throws {
        let root = try makeRepository()
        try write(
            "struct BillingMigration { let enabled = false }\n",
            to: "Sources/Production/BillingMigration.swift",
            under: root
        )
        let connector = LocalEngineeringConnector(workspaceRoot: root, commandRunner: ScriptedCommandRunner(responses: []))
        let workspace = Workspace(
            id: UUID(),
            name: "Engineering",
            role: .fde,
            createdAt: Date(),
            localProjectRoot: root.path,
            localAgentProjectRoot: root.path
        )
        let plan = EngineeringChangePlan(
            objective: "Deploy production billing migration for customer database",
            targetFiles: ["Sources/Production/BillingMigration.swift"],
            expectedChanges: ["Modify production customer database migration."],
            validationPlan: [
                EngineeringValidationStep(
                    command: EngineeringCommand(command: "swift", arguments: ["test"]),
                    purpose: "Run unit tests before production change"
                )
            ],
            plannedEdits: [
                EngineeringPlannedEdit(
                    path: "Sources/Production/BillingMigration.swift",
                    newContents: "struct BillingMigration { let enabled = true }\n",
                    summary: "Enable production migration."
                )
            ]
        )

        let result = await AutonomousEngineeringLoop().run(
            plan: plan,
            connector: connector,
            workspace: workspace,
            approved: false
        )

        let unchanged = try String(
            contentsOf: root.appendingPathComponent("Sources/Production/BillingMigration.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(result.approvalRequired)
        XCTAssertEqual(result.governanceDecision.status, .approvalRequired)
        XCTAssertNotNil(result.governanceDecision.approvalRequest)
        XCTAssertFalse(result.stages.contains { $0.stage == .modify })
        XCTAssertTrue(unchanged.contains("enabled = false"))
    }

    func testEngineeringReplayReconstructionIsAuditComplete() {
        let plan = EngineeringChangePlan(
            objective: "Patch parser",
            targetFiles: ["Sources/App/Parser.swift"],
            expectedChanges: ["Handle empty input."],
            validationPlan: [
                EngineeringValidationStep(
                    command: EngineeringCommand(command: "swift", arguments: ["test"]),
                    purpose: "Run parser tests"
                )
            ]
        )
        let stages = [
            EngineeringLoopStageResult(
                stage: .inspect,
                success: true,
                summary: "Inspected parser.",
                evidence: [
                    EvidenceRecord(
                        action: "engineering.read_file:Sources/App/Parser.swift",
                        source: "EngineeringConnector",
                        result: "Read parser.",
                        validation: .valid
                    )
                ]
            ),
            EngineeringLoopStageResult(
                stage: .completed,
                success: true,
                summary: "Validated parser patch.",
                evidence: [
                    EvidenceRecord(
                        action: "engineering.completed",
                        source: "AutonomousEngineeringLoop",
                        result: "Validated parser patch.",
                        validation: .valid
                    )
                ]
            )
        ]

        let replay = EngineeringReplayRecord.reconstruct(
            objective: plan.objective,
            plan: plan,
            stages: stages,
            outcome: "validated"
        )

        XCTAssertTrue(replay.isAuditComplete)
        XCTAssertEqual(replay.targetFiles, ["Sources/App/Parser.swift"])
        XCTAssertEqual(replay.stageTransitions, [.inspect, .completed])
        XCTAssertTrue(replay.actions.contains("engineering.completed"))
        XCTAssertEqual(replay.outcome, "validated")
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FDEEngineeringTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoots.append(root)
        return root
    }

    private func write(_ contents: String, to path: String, under root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor ScriptedCommandRunner: EngineeringCommandRunning {
    private var responses: [(Int32, String, String)]
    private var runs = 0

    init(responses: [(Int32, String, String)]) {
        self.responses = responses
    }

    func run(command: EngineeringCommand, workingDirectory: URL) async throws -> EngineeringCommandOutput {
        runs += 1
        let response = responses.isEmpty ? (0, "ok", "") : responses.removeFirst()
        return EngineeringCommandOutput(
            command: command,
            exitCode: response.0,
            stdout: response.1,
            stderr: response.2
        )
    }

    func callCount() -> Int {
        runs
    }
}
