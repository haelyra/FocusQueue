import Foundation
import XCTest
@testable import FocusQueueCore

final class PromptUsageMetricsTests: XCTestCase {
    func testRecordsOnlyMetadataAndReadsEvents() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        PromptUsageMetrics.record(PromptUsageEvent(source: "agent_launch", component: "app_context",
            provider: "codex", taskID: "FOC-056", characters: 400), in: support)
        let events = PromptUsageMetrics.load(in: support)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.estimatedInputTokens, 100)
        XCTAssertEqual(events.first?.taskID, "FOC-056")
        let raw = try String(contentsOf: PromptUsageMetrics.file(in: support), encoding: .utf8)
        XCTAssertFalse(raw.contains("promptBody"))
    }
}
