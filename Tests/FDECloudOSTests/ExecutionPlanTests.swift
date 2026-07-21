import XCTest
@testable import FDECloudOS

final class ExecutionPlanTests: XCTestCase {
    func testValidPlanComputesStableSelfValidatingDigest() throws {
        let plan = try makePlan()

        XCTAssertEqual(plan.digest.algorithm, "SHA-256")
        XCTAssertEqual(plan.digest.canonicalSerializationVersion, 1)
        XCTAssertEqual(plan.digest.sha256.count, 64)
        XCTAssertEqual(try PlanDigest.compute(plan), plan.digest)
        XCTAssertTrue(plan.isSelfValidating)
        XCTAssertNoThrow(try plan.validate())
    }

    func testDigestCanonicalizesToolArgumentsAndUnorderedCollections() throws {
        let original = try makePlan()
        var reordered = original
        reordered.toolCalls.reverse()
        reordered.toolCalls[0].arguments.reverse()
        reordered.toolCalls[1].arguments.reverse()
        reordered.evidenceRequirementIDs.reverse()
        reordered.risks.reverse()
        reordered.constraints.allowedTools.reverse()

        XCTAssertEqual(try PlanDigest.compute(original), try PlanDigest.compute(reordered))
    }

    func testDigestPreservesStepOrder() throws {
        let original = try makePlan()
        var reordered = original
        reordered.steps.reverse()

        XCTAssertNotEqual(try PlanDigest.compute(original), try PlanDigest.compute(reordered))
    }

    func testDigestBindsAuthorityAndReviewFields() throws {
        let original = try makePlan()

        var changedOrigin = original
        changedOrigin.origin.requestMessageID = UUID()
        XCTAssertNotEqual(try PlanDigest.compute(original), try PlanDigest.compute(changedOrigin))

        var changedSummary = original
        changedSummary.summary = "Inspect a different bounded surface."
        XCTAssertNotEqual(try PlanDigest.compute(original), try PlanDigest.compute(changedSummary))

        var changedArgument = original
        changedArgument.toolCalls[1].arguments = ["workspace=legacy", "path=README.md"]
        XCTAssertNotEqual(try PlanDigest.compute(original), try PlanDigest.compute(changedArgument))

        var changedRequirement = original
        changedRequirement.evidenceRequirementIDs.append("assessment_audit_logging")
        XCTAssertNotEqual(try PlanDigest.compute(original), try PlanDigest.compute(changedRequirement))

        var changedConstraint = original
        changedConstraint.constraints.networkAllowed = true
        XCTAssertNotEqual(try PlanDigest.compute(original), try PlanDigest.compute(changedConstraint))
    }

    func testDigestExcludesAuditTimestamps() throws {
        let original = try makePlan()
        var changedDates = original
        changedDates.createdAt = Date(timeIntervalSince1970: 9_999)
        changedDates.revision.createdAt = Date(timeIntervalSince1970: 8_888)

        XCTAssertEqual(try PlanDigest.compute(original), try PlanDigest.compute(changedDates))
    }

    func testValidationRejectsDigestMismatch() throws {
        var plan = try makePlan()
        plan.summary = "Tampered after digest creation."

        assertValidationError(.digestMismatch) {
            try plan.validate()
        }
        XCTAssertFalse(plan.isSelfValidating)
    }

    func testRevisionValidationRequiresExactParentShape() throws {
        var initialWithParent = try makePlan()
        initialWithParent.revision.parentDigest = initialWithParent.digest
        initialWithParent.digest = try PlanDigest.compute(initialWithParent)
        assertValidationError(.unexpectedParentDigest) {
            try initialWithParent.validate()
        }

        var subsequentWithoutParent = try makePlan()
        subsequentWithoutParent.revision = PlanRevision(
            number: 2,
            parentDigest: nil,
            reason: .humanRequestedChanges,
            createdAt: Date(timeIntervalSince1970: 200)
        )
        subsequentWithoutParent.digest = try PlanDigest.compute(subsequentWithoutParent)
        assertValidationError(.missingParentDigest) {
            try subsequentWithoutParent.validate()
        }

        let original = try makePlan()
        let revisionTwo = try makePlan(
            id: original.id,
            revision: PlanRevision(
                number: 2,
                parentDigest: original.digest,
                reason: .humanRequestedChanges,
                createdAt: Date(timeIntervalSince1970: 200)
            )
        )
        XCTAssertNoThrow(try revisionTwo.validate())
    }

    func testValidationRejectsDuplicateAndBrokenPlanReferences() throws {
        var duplicateStep = try makePlan()
        let originalSecondStep = duplicateStep.steps[1]
        duplicateStep.steps[1] = PlanStep(
            id: duplicateStep.steps[0].id,
            title: originalSecondStep.title,
            intent: originalSecondStep.intent,
            kind: originalSecondStep.kind,
            toolCallID: originalSecondStep.toolCallID,
            requiresApproval: originalSecondStep.requiresApproval,
            retryBudget: originalSecondStep.retryBudget
        )
        duplicateStep.digest = try PlanDigest.compute(duplicateStep)
        assertValidationError(.duplicateStepID(duplicateStep.steps[0].id)) {
            try duplicateStep.validate()
        }

        var brokenReference = try makePlan()
        brokenReference.steps[0].toolCallID = "missing-call"
        brokenReference.digest = try PlanDigest.compute(brokenReference)
        assertValidationError(.invalidToolCallReference(brokenReference.steps[0].id)) {
            try brokenReference.validate()
        }

        var unreferenced = try makePlan()
        unreferenced.steps.removeLast()
        unreferenced.digest = try PlanDigest.compute(unreferenced)
        assertValidationError(.unreferencedToolCall("call-read")) {
            try unreferenced.validate()
        }
    }

    func testValidationRejectsNonReadOnlyAuthority() throws {
        var shellPlan = try makePlan()
        shellPlan.toolCalls[0].type = .shell
        shellPlan.toolCalls[0].command = "/bin/ls"
        shellPlan.digest = try PlanDigest.compute(shellPlan)
        assertValidationError(.toolTypeNotAllowed(.shell)) {
            try shellPlan.validate()
        }

        var mutationPlan = try makePlan()
        mutationPlan.constraints.mutationAllowed = true
        mutationPlan.digest = try PlanDigest.compute(mutationPlan)
        assertValidationError(.invalidReadOnlyConstraints) {
            try mutationPlan.validate()
        }

        var executablePlan = try makePlan()
        executablePlan.constraints.executionEnabled = true
        executablePlan.digest = try PlanDigest.compute(executablePlan)
        assertValidationError(.invalidReadOnlyConstraints) {
            try executablePlan.validate()
        }
    }

    func testValidationRejectsUnsafePathsAndWorkspaceMismatch() throws {
        var traversal = try makePlan()
        traversal.toolCalls[1].arguments = ["workspace=legacy", "path=../Secrets.swift"]
        traversal.digest = try PlanDigest.compute(traversal)
        assertValidationError(.invalidToolPath("call-read")) {
            try traversal.validate()
        }

        var sensitive = try makePlan()
        sensitive.toolCalls[1].arguments = ["workspace=legacy", "path=.env"]
        sensitive.digest = try PlanDigest.compute(sensitive)
        assertValidationError(.invalidToolPath("call-read")) {
            try sensitive.validate()
        }

        var wrongWorkspace = try makePlan()
        wrongWorkspace.toolCalls[0].arguments = ["workspace=agent", "path=."]
        wrongWorkspace.digest = try PlanDigest.compute(wrongWorkspace)
        assertValidationError(.workspaceScopeMismatch("call-inspect")) {
            try wrongWorkspace.validate()
        }
    }

    func testValidationRejectsDuplicateEvidenceAndRiskIdentifiers() throws {
        var duplicateEvidence = try makePlan()
        duplicateEvidence.evidenceRequirementIDs.append(duplicateEvidence.evidenceRequirementIDs[0])
        duplicateEvidence.digest = try PlanDigest.compute(duplicateEvidence)
        assertValidationError(.duplicateEvidenceRequirement(duplicateEvidence.evidenceRequirementIDs[0])) {
            try duplicateEvidence.validate()
        }

        var duplicateRisk = try makePlan()
        duplicateRisk.risks.append(duplicateRisk.risks[0])
        duplicateRisk.digest = try PlanDigest.compute(duplicateRisk)
        assertValidationError(.duplicateRiskID(duplicateRisk.risks[0].id)) {
            try duplicateRisk.validate()
        }
    }

    private func makePlan(
        id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        revision: PlanRevision = .initial(createdAt: Date(timeIntervalSince1970: 100))
    ) throws -> ExecutionPlan {
        try ExecutionPlan.make(
            id: id,
            taskID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            workspaceID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            origin: OriginBinding(
                sessionID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                turnID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                requestMessageID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
            ),
            missionSemantic: .readOnlyWorkspaceInspection,
            workspaceScope: .legacyOnly,
            objective: "Analyze the selected Legacy application and propose AI integration.",
            summary: "Inspect bounded Legacy architecture evidence for a future assessment.",
            steps: [
                PlanStep(
                    id: "step-inspect",
                    title: "Inspect project structure",
                    intent: "Discover bounded project structure without mutation.",
                    kind: .tool,
                    toolCallID: "call-inspect",
                    requiresApproval: false
                ),
                PlanStep(
                    id: "step-read",
                    title: "Read project manifest",
                    intent: "Read an exact discovered manifest as direct static evidence.",
                    kind: .tool,
                    toolCallID: "call-read",
                    requiresApproval: false
                )
            ],
            toolCalls: [
                ToolCall(
                    id: "call-inspect",
                    type: .api,
                    command: "engineering.inspect_project",
                    arguments: ["workspace=legacy", "path=."],
                    workingDirectory: nil,
                    requiresApproval: false
                ),
                ToolCall(
                    id: "call-read",
                    type: .api,
                    command: "engineering.read_file",
                    arguments: ["workspace=legacy", "path=Package.swift"],
                    workingDirectory: nil,
                    requiresApproval: false
                )
            ],
            evidenceRequirementIDs: ["project_structure", "project_manifest"],
            risks: [
                RiskSignal(
                    id: "risk-static-only",
                    title: "Static evidence only",
                    severity: .low,
                    mitigation: "Keep runtime, build, test, and deployment status unverified."
                ),
                RiskSignal(
                    id: "risk-sensitive-paths",
                    title: "Sensitive paths excluded",
                    severity: .medium,
                    mitigation: "Reject secret-bearing and out-of-scope paths before future execution."
                )
            ],
            revision: revision,
            createdAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func assertValidationError(
        _ expected: ExecutionPlanValidationError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? ExecutionPlanValidationError, expected, file: file, line: line)
        }
    }
}
