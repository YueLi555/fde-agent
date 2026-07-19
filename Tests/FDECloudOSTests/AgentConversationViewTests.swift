import SwiftUI
import XCTest
@testable import FDECloudOS

final class AgentConversationViewTests: XCTestCase {
    func testCandidatePatchPassiveAccessibilityAndFocusOperationsCannotEmitApproval() {
        let passiveOperations: [CandidatePatchApprovalUIOperation] = [
            .accessibilityEnumeration,
            .windowFocus,
            .screenshotCapture,
            .scrolling,
            .openConfirmation,
            .cancelConfirmation
        ]
        XCTAssertTrue(passiveOperations.allSatisfy { !$0.emitsRuntimeApproval })
        XCTAssertTrue(CandidatePatchApprovalUIOperation.confirmApproval.emitsRuntimeApproval)
    }

    func testCandidatePatchApprovalControlsHaveDistinctIdentifiersAndNoDefaultShortcut() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let conversationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/UI/Components/AgentConversationView.swift"
            ),
            encoding: .utf8
        )
        let workspaceSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/UI/Components/AgentWorkspaceView.swift"
            ),
            encoding: .utf8
        )
        for identifier in [
            "candidatePatch.requestChanges",
            "candidatePatch.reject",
            "candidatePatch.approve.openConfirmation"
        ] {
            XCTAssertTrue(conversationSource.contains(identifier), identifier)
        }
        for identifier in [
            "candidatePatch.approve.confirm",
            "candidatePatch.approve.cancel"
        ] {
            XCTAssertTrue(workspaceSource.contains(identifier), identifier)
        }
        let confirmationView = try XCTUnwrap(
            workspaceSource.components(separatedBy: "private struct CandidatePatchApprovalConfirmationView").last
        )
        XCTAssertFalse(confirmationView.contains(".keyboardShortcut(.defaultAction)"))
        XCTAssertTrue(confirmationView.contains(".focusable(false)"))
        XCTAssertTrue(confirmationView.contains(".onExitCommand(perform: onCancel)"))
    }

    func testSandboxSourcePresentationCoversEveryOptionalState() {
        let cases: [(sourceUnchanged: Bool?, status: String, color: Color)] = [
            (.some(true), "UNCHANGED", .green),
            (.some(false), "CHANGED", .orange),
            (.none, "UNKNOWN", .secondary)
        ]

        for testCase in cases {
            let snapshot = SandboxActivitySnapshot(
                sandboxID: nil,
                sourceSnapshotID: nil,
                status: nil,
                includedFileCount: 0,
                excludedItemCount: 0,
                integrityStatus: .notValidated,
                sourceUnchanged: testCase.sourceUnchanged
            )

            XCTAssertEqual(sandboxSourceStatus(for: snapshot), testCase.status)
            XCTAssertEqual(sandboxSourceColor(for: snapshot), testCase.color)
        }
    }

    func testCandidatePatchAssetUIUsesPersistedExactBindingAndExposesRequiredDetails() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let conversationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/UI/Components/AgentConversationView.swift"
            ),
            encoding: .utf8
        )
        let appStoreSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Sources/FDECloudOS/App/AppStore.swift"),
            encoding: .utf8
        )

        for label in [
            "Source Candidate Patch task ID", "Plan revision", "Manifest ID",
            "Candidate Patch artifact SHA-256", "Source snapshot ID", "Canonical Legacy root",
            "Capability label", "Assessment ID", "Validation-test-plan digest",
            "Unified Diff SHA-256", "Lifecycle status", "Approval status",
            "Files planned", "Files changed", "Source integrity"
        ] {
            XCTAssertTrue(conversationSource.contains(label), label)
        }
        XCTAssertTrue(conversationSource.contains("Prepare Generated Test Plan"))
        XCTAssertTrue(conversationSource.contains("exactGeneratedTestSourceBinding"))
        XCTAssertTrue(conversationSource.contains("Copy full"))

        let actionSource = try XCTUnwrap(
            appStoreSource.components(separatedBy: "func prepareGeneratedTestPlan").last?
                .components(separatedBy: "func confirmCandidatePatchRevert").first
        )
        XCTAssertTrue(actionSource.contains("snapshot.exactGeneratedTestSourceBinding"))
        XCTAssertTrue(actionSource.contains("sourceBinding: sourceBinding"))
        let authoritySource = try XCTUnwrap(
            actionSource.components(separatedBy: "let context = GeneratedTestPlanningContext").first
        )
        XCTAssertFalse(authoritySource.contains("selectedTaskID"))
        XCTAssertFalse(actionSource.lowercased().contains("latest"))
        XCTAssertFalse(actionSource.contains("prefix("))
    }

    func testUserMessagesUseAStructuredCodexStyleSurface() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let conversationSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Sources/FDECloudOS/UI/Components/AgentConversationView.swift"
            ),
            encoding: .utf8
        )
        let messageRow = try XCTUnwrap(
            conversationSource.components(separatedBy: "private struct AgentConversationMessageRow").last?
                .components(separatedBy: "private struct AgentStreamingMarkdownResponseRow").first
        )

        XCTAssertTrue(messageRow.contains("Text(message.sender == .user ? \"You\" : \"Agent\")"))
        XCTAssertTrue(messageRow.contains("WorkspaceVisualStyle.Typography.body"))
        XCTAssertTrue(messageRow.contains("WorkspaceVisualStyle.Radius.artifactCard"))
        XCTAssertTrue(messageRow.contains("message.sender == .user ? 0 : 0.7"))
        XCTAssertTrue(messageRow.contains("Text(message.content)"))
    }
}
