import SwiftUI
import XCTest
@testable import FDECloudOS

final class AgentConversationViewTests: XCTestCase {
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
