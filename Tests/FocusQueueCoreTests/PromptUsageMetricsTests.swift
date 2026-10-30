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

    func testAppendOnlyCorrectionReplacesUsageWithoutAddingRuns() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: support) }
        for total in [10_761_047, 32_175] {
            PromptUsageMetrics.record(PromptUsageEvent(source: "document_chat", component: "provider_usage",
                actualTotalTokens: total, runID: "fork", scope: "provider", id: "same-report"), in: support)
        }
        let loaded = PromptUsageMetrics.load(in: support)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(PromptUsageSummary(events: loaded).actualTokens, 32_175)
        XCTAssertEqual(PromptUsageSummary(events: loaded).reportedRuns, 1)
    }

    func testSummaryUsesDistinctRunsAndOnlyReportedActualUsage() {
        let events = [
            PromptUsageEvent(source: "placement", component: "system", characters: 400, runID: "a"),
            PromptUsageEvent(source: "placement", component: "tasks", characters: 200, runID: "a"),
            PromptUsageEvent(source: "placement", component: "provider_usage", actualTotalTokens: 360,
                runID: "a", scope: "provider"),
            PromptUsageEvent(source: "placement", component: "system", characters: 400, runID: "b")
        ]
        let summary = PromptUsageSummary(events: events)
        XCTAssertEqual(summary.runs, 2)
        XCTAssertEqual(summary.estimatedTokens, 250)
        XCTAssertEqual(summary.estimatedAverage, 125)
        XCTAssertEqual(summary.reportedRuns, 1)
        XCTAssertEqual(summary.actualTokens, 360)
        XCTAssertEqual(summary.actualAverage, 360)
        XCTAssertEqual(summary.reportedInputTokens, 0)
    }
}
