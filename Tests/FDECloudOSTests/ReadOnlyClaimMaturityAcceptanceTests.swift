import XCTest
@testable import FDECloudOS

final class ReadOnlyClaimMaturityAcceptanceTests: XCTestCase {
    func testStartupEntryAndApplicationAssemblyHaveIndependentEvidenceLevels() throws {
        let request = "只读检查 Legacy 后端启动入口和应用组装文件。"
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let root = evidence("root", "engineering.list_directory", ".", "server/")
        let manifest = evidence(
            "manifest",
            "engineering.read_file",
            "server/package.json",
            #"{"dependencies":{"express":"5"}}"#
        )
        let entry = evidence(
            "entry",
            "engineering.read_file",
            "server/src/index.ts",
            "import app from './app';\napp.listen(3000);"
        )

        let referencedLedger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: [root, manifest, entry]
        )
        let startup = try XCTUnwrap(referencedLedger.requirements.first {
            $0.requirementID == ReadOnlyEvidenceRequirementKind.backendEntryPoint.rawValue
        })
        let assembly = try XCTUnwrap(referencedLedger.requirements.first {
            $0.requirementID == ReadOnlyEvidenceRequirementKind.backendApplicationAssembly.rawValue
        })

        XCTAssertEqual(startup.status, .satisfied)
        XCTAssertEqual(startup.evidenceLevel, .sourceBehaviorConfirmed)
        XCTAssertEqual(startup.supportingRelativePaths, ["server/src/index.ts"])
        XCTAssertEqual(assembly.status, .partiallySatisfied)
        XCTAssertEqual(assembly.evidenceLevel, .referencedButNotRead)
        XCTAssertEqual(assembly.supportingRelativePaths, ["server/src/app.ts"])
        XCTAssertTrue(referencedLedger.unsatisfied.contains(.backendApplicationAssembly))

        let app = evidence(
            "app",
            "engineering.read_file",
            "server/src/app.ts",
            "import express from 'express';\nconst app = express();\nexport default app;"
        )
        let readLedger = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: [root, manifest, entry, app]
        )
        let readAssembly = try XCTUnwrap(readLedger.requirements.first {
            $0.requirementID == ReadOnlyEvidenceRequirementKind.backendApplicationAssembly.rawValue
        })

        XCTAssertEqual(readAssembly.status, .satisfied)
        XCTAssertEqual(readAssembly.evidenceLevel, .contentRead)
        XCTAssertTrue(readLedger.allMaterialRequirementsSatisfied)
        XCTAssertTrue(readLedger.paths.first { $0.relativePath == "server/src/app.ts" }?.claimLevels.contains(.contentRead) == true)
    }

    func testBuildConfigurationDoesNotBecomeBuildPassedAndUnsafeLanguageIsRejected() {
        let request = "Read-only inspect Legacy build scripts and configuration."
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let items = [
            evidence("root", "engineering.list_directory", ".", "package.json 80b\ntsconfig.json 50b"),
            evidence("manifest", "engineering.read_file", "package.json", #"{"scripts":{"build":"tsc"}}"#),
            evidence("tsconfig", "engineering.read_file", "tsconfig.json", #"{"compilerOptions":{"strict":true}}"#)
        ]
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: items)

        XCTAssertTrue(ledger.claimMaturityLevels.contains(.buildConfigPresent))
        XCTAssertTrue(ledger.claimMaturityLevels.contains(.buildNotExecuted))
        XCTAssertFalse(ledger.claimMaturityLevels.contains(.buildPassed))
        XCTAssertTrue(ledger.unsupportedExecutionClaimLevels.isEmpty)

        let safe = ReadOnlyFinalAnswerContract.validate(
            answer: "Build scripts and configuration are present in package.json and tsconfig.json, but no build was executed during this inspection. Runtime status: not verified. Deployment status: not verified.",
            request: request,
            requirements: requirements,
            evidence: items,
            requireComplete: true
        )
        let unsafe = ReadOnlyFinalAnswerContract.validate(
            answer: "The project is buildable and production ready based on package.json and tsconfig.json.",
            request: request,
            requirements: requirements,
            evidence: items,
            requireComplete: true
        )

        XCTAssertTrue(safe.accepted, safe.issues.joined(separator: ", "))
        XCTAssertFalse(unsafe.accepted)
        XCTAssertTrue(unsafe.safeContractFailures.contains(.unsupportedBuildClaim))
    }

    func testReadOnlyVerificationSummaryNeverClaimsTestRuntimeOrDeploymentVerified() {
        let requirements = ReadOnlyEvidenceRequirements(request: "Read-only inspect Legacy runtime configuration.")
        let items = [
            evidence("root", "engineering.list_directory", ".", "package.json 80b"),
            evidence("manifest", "engineering.read_file", "package.json", #"{"scripts":{"test":"vitest"}}"#)
        ]
        let ledger = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: items)

        XCTAssertTrue(ledger.claimMaturityLevels.contains(.testNotExecuted))
        XCTAssertTrue(ledger.claimMaturityLevels.contains(.runtimeNotVerified))
        XCTAssertTrue(ledger.claimMaturityLevels.contains(.deploymentNotVerified))
        XCTAssertFalse(ledger.claimMaturityLevels.contains(.testPassed))
        XCTAssertFalse(ledger.claimMaturityLevels.contains(.runtimeVerified))
        XCTAssertFalse(ledger.claimMaturityLevels.contains(.deploymentVerified))
    }

    func testDiscoveredOrReferencedPathCannotBeClaimedAsSuccessfullyRead() {
        let request = "Read-only inspect the Legacy backend startup entry and application assembly."
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let items = [
            evidence("root", "engineering.list_directory", ".", "server/"),
            evidence("entry", "engineering.read_file", "server/src/index.ts", "import app from './app';\napp.listen(3000);")
        ]

        let unsafe = ReadOnlyFinalAnswerContract.validate(
            answer: "Files read: server/src/index.ts and server/src/app.ts. The application assembly is in server/src/app.ts.",
            request: request,
            requirements: requirements,
            evidence: items,
            requireComplete: false
        )
        let safe = ReadOnlyFinalAnswerContract.validate(
            answer: "Partial result. Files read: server/src/index.ts.\nReferenced but not read: server/src/app.ts.",
            request: request,
            requirements: requirements,
            evidence: items,
            requireComplete: false
        )

        XCTAssertFalse(unsafe.accepted)
        XCTAssertTrue(unsafe.issues.contains("unread_path_claimed_as_read:server/src/app.ts"))
        XCTAssertTrue(unsafe.safeContractFailures.contains(.unsupportedStaticClaim))
        XCTAssertTrue(unsafe.safeContractFailures.contains(.missingEvidencePath))
        XCTAssertTrue(safe.accepted, safe.issues.joined(separator: ", "))
    }

    func testExplicitStartupAndAssemblyRequestIsPartialUntilBothAreRead() {
        let request = "Read-only inspect the Legacy backend startup entry and application assembly."
        let requirements = ReadOnlyEvidenceRequirements(request: request)
        let partialEvidence = [
            evidence("root", "engineering.list_directory", ".", "server/"),
            evidence("manifest", "engineering.read_file", "server/package.json", #"{"dependencies":{"express":"5"}}"#),
            evidence("entry", "engineering.read_file", "server/src/index.ts", "import app from './app';\napp.listen(3000);")
        ]
        let partial = ReadOnlyFinalizationEvidenceLedger(requirements: requirements, evidence: partialEvidence)

        XCTAssertFalse(partial.allMaterialRequirementsSatisfied)
        XCTAssertEqual(partial.unsatisfied, [.backendApplicationAssembly])

        let completed = ReadOnlyFinalizationEvidenceLedger(
            requirements: requirements,
            evidence: partialEvidence + [
                evidence("app", "engineering.read_file", "server/src/app.ts", "export default {}")
            ]
        )
        XCTAssertTrue(completed.allMaterialRequirementsSatisfied)
    }

    func testAcceptanceBenchmarkProducesTwentyPassingMachineReadableResults() throws {
        let results = ReadOnlyAcceptanceBenchmarkRunner().runAll()

        XCTAssertEqual(results.count, 20)
        XCTAssertTrue(results.allSatisfy(\.passed), results.filter { !$0.passed }.map { "\($0.caseID): \($0.passFailReason)" }.joined(separator: "\n"))
        XCTAssertTrue(results.allSatisfy { $0.route == MissionExecutionSemantic.readOnlyWorkspaceInspection.rawValue })
        XCTAssertTrue(results.allSatisfy { $0.workspaceScope == MissionWorkspaceScope.legacyOnly.rawValue })
        XCTAssertTrue(results.allSatisfy(\.unsupportedClaimViolations.isEmpty))
        XCTAssertTrue(results.allSatisfy(\.noSecretExposure))
        XCTAssertTrue(results.allSatisfy { !$0.passFailReason.isEmpty })

        let encoded = try JSONEncoder().encode(results)
        let decoded = try JSONDecoder().decode([ReadOnlyAcceptanceBenchmarkResult].self, from: encoded)
        XCTAssertEqual(decoded.map(\.caseID), results.map(\.caseID))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("password="))
        let machineReadable = try ReadOnlyAcceptanceBenchmarkRunner().runAllJSON()
        XCTAssertTrue(machineReadable.contains("\"caseID\""))
        XCTAssertTrue(machineReadable.contains("\"passFailReason\""))
    }

    func testSensitivePathsAreExcludedFromDiscoveredAndReadEvidence() {
        let facts = ReadOnlySafeFactExtractor.extract(
            toolName: "engineering.list_directory",
            targetPath: ".",
            output: ".env 20b\nsecrets.json 30b\npackage.json 80b\nsrc/"
        )

        XCTAssertEqual(facts.structureEntries, ["package.json", "src/"])
        XCTAssertTrue(ReadOnlySensitivePathPolicy.isSensitive(".env"))
        XCTAssertTrue(ReadOnlySensitivePathPolicy.isSensitive("config/secrets.json"))
        XCTAssertFalse(ReadOnlySensitivePathPolicy.isSensitive("server/package.json"))
    }

    private func evidence(
        _ id: String,
        _ tool: String,
        _ path: String,
        _ output: String
    ) -> ReadOnlyInspectionEvidence {
        ReadOnlyInspectionEvidence(
            toolCallID: id,
            toolName: tool,
            workspaceID: UUID(),
            workspaceIdentity: "legacy",
            targetPath: path,
            output: output,
            toolCalledEventID: UUID(),
            toolResultEventID: UUID()
        )
    }
}
