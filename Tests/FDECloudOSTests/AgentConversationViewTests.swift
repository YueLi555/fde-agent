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
}
