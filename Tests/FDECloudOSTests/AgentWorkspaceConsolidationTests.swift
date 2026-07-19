import Foundation
import XCTest
@testable import FDECloudOS

final class AgentWorkspaceConsolidationTests: XCTestCase {
    func testNewChatCreatesDistinctEmptyConversationWithoutMission() {
        let workspace = Workspace.default()
        let existing = AgentSession(workspace: workspace, userGoal: "Inspect the customer API")

        let newChat = AgentSession.newConversation(in: workspace)

        XCTAssertNotEqual(newChat.sessionID, existing.sessionID)
        XCTAssertNotEqual(newChat.conversation.id, existing.conversation.id)
        XCTAssertTrue(newChat.conversation.messages.isEmpty)
        XCTAssertNil(newChat.runtimeTaskID)
        XCTAssertEqual(newChat.currentState, .idle)
        XCTAssertEqual(newChat.interactionState, .idle)
    }

    func testNewChatPreservesWorkspaceAndProjectScope() {
        var workspace = Workspace.default()
        workspace.localProjectRoot = "/tmp/example-legacy"
        workspace.localAgentProjectRoot = "/tmp/example-agent"

        let newChat = AgentSession.newConversation(in: workspace)

        XCTAssertEqual(newChat.workspaceID, workspace.id)
        XCTAssertEqual(newChat.workspaceContext.localProjectRoot, workspace.localProjectRoot)
        XCTAssertEqual(newChat.workspaceContext.localAgentProjectRoot, workspace.localAgentProjectRoot)
    }

    func testNewChatDoesNotMutateExistingMissionLineageOrArtifacts() {
        let workspace = Workspace.default()
        var existing = AgentSession(workspace: workspace, userGoal: "Prepare isolated patch")
        existing.workspaceContext.runtimeTaskID = UUID()
        existing.workspaceContext.missionTaskIDs = [existing.workspaceContext.runtimeTaskID!]
        existing.addArtifact(AgentArtifact(
            id: "artifact-1",
            title: "Candidate Patch",
            detail: "Preserved"
        ))
        let original = existing

        let sessions = [AgentSession.newConversation(in: workspace), existing]

        XCTAssertEqual(sessions[1], original)
        XCTAssertEqual(sessions[1].workspaceContext.missionTaskIDs, original.workspaceContext.missionTaskIDs)
        XCTAssertEqual(sessions[1].artifacts, original.artifacts)
        XCTAssertNil(sessions[0].runtimeTaskID)
        XCTAssertTrue(sessions[0].artifacts.isEmpty)
    }

    func testFirstRequestGivesConversationHumanReadableTitle() {
        let workspace = Workspace.default()
        var session = AgentSession.newConversation(in: workspace)

        session.beginConversation(with: "Assess whether the customer API supports a read-only AI integration")

        XCTAssertEqual(session.userGoal, "Assess whether the customer API supports a read-only AI integration")
        XCTAssertEqual(session.conversation.messages.count, 1)
        XCTAssertEqual(session.displayTitle, "Assess whether the customer API supports a read-only AI…")
        XCTAssertFalse(session.displayTitle.hasPrefix("Dialog "))
    }

    func testConversationTitleNormalizesWhitespaceAndBoundsLength() {
        let title = ConversationTitleGenerator.title(
            for: "  Inspect   the customer\nservice and explain the safest integration plan. More details follow.  ",
            maximumLength: 36
        )

        XCTAssertFalse(title.contains("  "))
        XCTAssertLessThanOrEqual(title.count, 37)
        XCTAssertTrue(title.hasSuffix("…"))
    }

    func testNewConversationRoundTripRestoresWithoutCreatingMessageOrMission() throws {
        let session = AgentSession.newConversation(in: .default())

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(AgentSession.self, from: data)

        XCTAssertEqual(restored, session)
        XCTAssertTrue(restored.isEmptyConversation)
        XCTAssertNil(restored.runtimeTaskID)
    }

    func testExactlyOneHighestPriorityHumanActionIsSelected() throws {
        let candidate = action(id: "candidate", domain: .candidatePatch)
        let generated = action(id: "generated", domain: .generatedTest)
        let eval = action(id: "eval", domain: .controlledEvalResult)

        let selected = try XCTUnwrap(HumanActionBarProjector.highestPriority(
            in: [candidate, eval, generated]
        ))

        XCTAssertEqual(selected.id, "eval")
    }

    func testHumanActionBarExcludesIneligibleActions() throws {
        var ineligible = action(id: "blocked", domain: .controlledEvalResult)
        ineligible.isEligible = false
        let eligible = action(id: "candidate", domain: .candidatePatch)

        let selected = try XCTUnwrap(HumanActionBarProjector.highestPriority(
            in: [ineligible, eligible]
        ))

        XCTAssertEqual(selected.id, eligible.id)
    }

    func testPassiveFocusAndAccessibilityCannotSubmitHumanDecision() {
        for operation in HumanActionUIOperation.allCases where operation != .submitDecision {
            XCTAssertFalse(operation.emitsMutation, operation.rawValue)
        }
        XCTAssertTrue(HumanActionUIOperation.submitDecision.emitsMutation)
    }

    func testRequestChangesRequiresAndAcceptsReviewNote() {
        let descriptor = action(id: "review", domain: .candidatePatch)

        XCTAssertFalse(descriptor.canSubmit(decision: .requestChanges, note: "   "))
        XCTAssertTrue(descriptor.canSubmit(decision: .requestChanges, note: "Keep the adapter read-only"))
    }

    func testInFlightHumanActionLocksDuplicateSubmission() {
        var descriptor = action(id: "review", domain: .generatedTest)
        descriptor.isInFlight = true

        XCTAssertFalse(descriptor.canSubmit(decision: .approve, note: ""))
    }

    func testFinalizedHumanActionIsReadOnlyAndCannotSubmit() {
        var descriptor = action(id: "review", domain: .productionReadiness)
        descriptor.isEligible = false
        descriptor.isFinalized = true

        XCTAssertTrue(descriptor.isReadOnly)
        XCTAssertFalse(descriptor.canSubmit(decision: .approve, note: ""))
    }

    func testStructuredAgentResponseRendersExpectedSections() {
        let response = StructuredAgentResponseProjector.response(for: AgentMessage(
            sender: .agent,
            type: .result,
            content: "The isolated change is ready for review."
        ))

        XCTAssertEqual(response.title, "Result")
        XCTAssertEqual(response.status, .completed)
        XCTAssertEqual(response.sections.map(\.kind), [.summary, .workCompleted])
    }

    func testStructuredAgentResponseExcludesRawInternalsPrivateReasoningAndHashes() {
        let hash = String(repeating: "a", count: 64)
        let content = """
        Safe summary for the reviewer.
        chain_of_thought: hidden analysis
        session_id: internal-session
        exact hash: \(hash)
        """

        let response = StructuredAgentResponseProjector.response(for: AgentMessage(
            sender: .agent,
            type: .result,
            content: content
        ))
        let rendered = response.sections.map(\.content).joined(separator: "\n")

        XCTAssertTrue(rendered.contains("Safe summary"))
        XCTAssertFalse(rendered.lowercased().contains("chain_of_thought"))
        XCTAssertFalse(rendered.lowercased().contains("session_id"))
        XCTAssertFalse(rendered.contains(hash))
    }

    func testStructuredAgentResponseCollapsesUnifiedDiffIntoViewerReference() {
        let content = """
        # Candidate Patch Review
        6. Unified diff:
        ```diff
        --- /dev/null
        +++ b/Sources/Example.swift
        @@ -0,0 +1,2 @@
        +let secretImplementation = true
        ```
        7. Validation still required: review the generated tests.
        """

        let response = StructuredAgentResponseProjector.response(for: AgentMessage(
            sender: .agent,
            type: .result,
            content: content
        ))
        let rendered = response.sections.map(\.content).joined(separator: "\n")

        XCTAssertTrue(rendered.contains("Open the validated file card"))
        XCTAssertTrue(rendered.contains("Validation still required"))
        XCTAssertFalse(rendered.contains("--- /dev/null"))
        XCTAssertFalse(rendered.contains("+++ b/Sources/Example.swift"))
        XCTAssertFalse(rendered.contains("secretImplementation"))
    }

    func testFileArtifactCardNeverExpandsLargeDiffInlineByDefault() {
        let card = fileCard(diff: String(repeating: "+line\n", count: 20_000))

        XCTAssertFalse(card.expandsLargeDiffInlineByDefault)
        XCTAssertNotNil(card.unifiedDiff)
    }

    func testArtifactPathAuthorityAcceptsOnlyValidatedRelativePaths() {
        XCTAssertTrue(ArtifactPathAuthority.isValidatedRelativePath("Sources/App/Client.swift"))
        XCTAssertFalse(ArtifactPathAuthority.isValidatedRelativePath("/tmp/secret"))
        XCTAssertFalse(ArtifactPathAuthority.isValidatedRelativePath("../secret"))
        XCTAssertFalse(ArtifactPathAuthority.isValidatedRelativePath("Sources/../secret"))
        XCTAssertFalse(ArtifactPathAuthority.isValidatedRelativePath("~/secret"))
    }

    func testLegacyAndVirtualArtifactSourcesAreReadOnly() {
        XCTAssertTrue(ArtifactSafeSource.legacyReadOnly.isReadOnly)
        XCTAssertTrue(ArtifactSafeSource.virtualArtifact.isReadOnly)
        XCTAssertFalse(ArtifactSafeSource.safeSandbox.isReadOnly)
    }

    func testComposerGrowsFromOneLineToMaximumAndThenScrolls() {
        XCTAssertEqual(AutoGrowingComposerMetrics.visibleLineCount(for: 0), 1)
        XCTAssertEqual(AutoGrowingComposerMetrics.visibleLineCount(for: 5), 5)
        XCTAssertEqual(AutoGrowingComposerMetrics.visibleLineCount(for: 20), 8)
        XCTAssertFalse(AutoGrowingComposerMetrics.shouldScrollInternally(for: 8))
        XCTAssertTrue(AutoGrowingComposerMetrics.shouldScrollInternally(for: 9))
    }

    func testShiftEnterInsertsNewlineAndIMECompositionNeverSubmits() {
        XCTAssertEqual(
            ComposerSubmissionPolicy.action(text: "long request", shiftPressed: true, hasMarkedText: false),
            .insertNewline
        )
        XCTAssertEqual(
            ComposerSubmissionPolicy.action(text: "输入中", shiftPressed: false, hasMarkedText: true),
            .ignore
        )
    }

    func testWhitespaceCannotSendAndEnterSendsExactlyOnce() {
        XCTAssertEqual(
            ComposerSubmissionPolicy.action(text: " \n ", shiftPressed: false, hasMarkedText: false),
            .ignore
        )
        XCTAssertEqual(
            ComposerSubmissionPolicy.action(text: "Inspect the workspace", shiftPressed: false, hasMarkedText: false),
            .submit
        )
    }

    func testRestartStateRoundTripRestoresConversationDraftSelectionAndInspector() throws {
        let session = AgentSession.newConversation(in: .default())
        let state = AgentWorkspacePersistedUIState(
            sessions: [session],
            selectedSessionID: session.sessionID,
            drafts: [session.sessionID: "Unsent multiline\ndraft"],
            isInspectorPresented: true
        )

        let data = try JSONEncoder().encode(state)
        let restored = try JSONDecoder().decode(AgentWorkspacePersistedUIState.self, from: data)

        XCTAssertEqual(restored, state)
        XCTAssertEqual(restored.sessions.count, 1)
        XCTAssertEqual(restored.drafts[session.sessionID], "Unsent multiline\ndraft")
        XCTAssertTrue(restored.isInspectorPresented)
    }

    func testUIUsesExistingSharedEligibilityAndOneHumanActionBar() throws {
        let source = try workspaceConsolidationSource()

        for evaluator in [
            "store.candidatePatchReviewEligibility",
            "store.generatedTestArtifactReviewEligibility",
            "store.productionReadinessReviewEligibility",
            "store.aiEvalPlanReviewEligibility",
            "store.controlledEvalExecutionReviewEligibility",
            "store.evalResultsReviewEligibility"
        ] {
            XCTAssertTrue(source.contains(evaluator), evaluator)
        }
        XCTAssertTrue(source.contains("HumanActionBarProjector.highestPriority"))
        XCTAssertFalse(source.contains(".keyboardShortcut(.defaultAction)"))
    }

    func testUIUsesAppOwnedViewerAndDoesNotOpenArbitraryPath() throws {
        let source = try workspaceConsolidationSource()

        XCTAssertTrue(source.contains("AppOwnedArtifactViewer"))
        XCTAssertTrue(source.contains("ArtifactPathAuthority.isValidatedRelativePath"))
        XCTAssertFalse(source.contains("NSWorkspace.shared.open"))
    }

    func testInspectorUsesExistingMissionPreviousRunsProjection() throws {
        let source = try workspaceConsolidationSource()

        XCTAssertTrue(source.contains("store.selectedMissionPresentation?.previousRuns"))
        XCTAssertTrue(source.contains("Read-only Mission history"))
        XCTAssertFalse(source.contains("duplicateMission"))
    }

    func testPhase3BAndDeploymentRemainUnavailable() throws {
        let repositoryRoot = try repositoryRoot()
        let evalModels = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/Core/ControlledEval/ControlledEvalModels.swift"
            ),
            encoding: .utf8
        )
        let readinessModels = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/Core/ProductionReadiness/ProductionReadinessModels.swift"
            ),
            encoding: .utf8
        )

        XCTAssertTrue(evalModels.contains("var deploymentAuthorized: Bool { false }"))
        XCTAssertTrue(evalModels.contains("var phase3BAvailable: Bool { false }"))
        XCTAssertTrue(readinessModels.contains("var productionRolloutAvailable: Bool { false }"))
    }

    func testNewChatImplementationDoesNotClearMissionArtifactOrEventCollections() throws {
        let repositoryRoot = try repositoryRoot()
        let appStoreSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/FDECloudOS/App/AppStore.swift"),
            encoding: .utf8
        )
        let method = try XCTUnwrap(
            appStoreSource.components(separatedBy: "func createNewChat()").last?
                .components(separatedBy: "func requestComposerFocus()").first
        )

        XCTAssertTrue(method.contains("AgentSession.newConversation"))
        XCTAssertFalse(method.contains("tasks = []"))
        XCTAssertFalse(method.contains("events = []"))
        XCTAssertFalse(method.contains("conversationAssetProjection ="))
        XCTAssertFalse(method.contains("runtimeCoordinator"))
    }

    private func action(id: String, domain: HumanActionDomain) -> HumanActionDescriptor {
        HumanActionDescriptor(
            id: id,
            domain: domain,
            title: "Review",
            scope: "Exact review scope",
            revision: 1,
            status: "Awaiting decision",
            decisions: HumanReviewDecision.allCases,
            isEligible: true,
            isInFlight: false,
            isFinalized: false
        )
    }

    private func fileCard(diff: String?) -> ArtifactFileCardModel {
        ArtifactFileCardModel(
            id: "file",
            relativePath: "Sources/App.swift",
            status: .modified,
            language: "Swift",
            additions: 10,
            deletions: 2,
            purpose: "Expose the workspace shell",
            safeSource: .safeSandbox,
            content: "import SwiftUI",
            unifiedDiff: diff,
            metadata: [],
            evidence: [],
            exactBinding: []
        )
    }

    private func workspaceConsolidationSource() throws -> String {
        try String(
            contentsOf: try repositoryRoot().appendingPathComponent(
                "Sources/FDECloudOS/UI/Components/AgentWorkspaceConsolidationViews.swift"
            ),
            encoding: .utf8
        )
    }

    private func repositoryRoot() throws -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
