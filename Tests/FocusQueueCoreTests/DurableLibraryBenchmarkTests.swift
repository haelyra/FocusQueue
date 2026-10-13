import Foundation
import Testing
@testable import FocusQueueCore

/// Opt-in timing against a disposable copy of real support data. Point
/// FOCUS_QUEUE_LIBRARY_BENCHMARK_DIR at a cloned support directory, never the
/// live one: reconcile and capture write to it.
@Suite("Durable library benchmark")
struct DurableLibraryBenchmarkTests {
    static let root = ProcessInfo.processInfo.environment["FOCUS_QUEUE_LIBRARY_BENCHMARK_DIR"]

    @Test("Startup history operations on copied real data", .enabled(if: root != nil))
    func startupOperations() async throws {
        let root = URL(fileURLWithPath: try #require(Self.root), isDirectory: true)
        // Retained source paths name the original support directory, so the
        // first pass records the copy's paths. The second pass, with a fresh
        // store, matches an ordinary relaunch where nothing changed.
        try await Self.launchPass("adopt copy", root: root)
        try await Self.launchPass("relaunch", root: root)

        let store = DurableLibraryStore(root: root)
        let contexts = try await TaskContextStore(root: root).loadAvailableForDiscovery()
        var context = try #require(contexts.first)
        _ = try await store.snapshot()
        context.summary += " benchmark"
        try await Self.time("one changed context write") { _ = try await store.reconcile(contexts: [context]) }
    }

    private static func launchPass(_ pass: String, root: URL) async throws {
        let store = DurableLibraryStore(root: root)
        try await time("\(pass): first snapshot") { _ = try await store.snapshot() }
        try await time("\(pass): second snapshot") { _ = try await store.snapshot() }

        let history = try await JSONDailyReportHistoryRepository(
            runtimeDirectory: root.appendingPathComponent("ingestion")).load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try await time("\(pass): captureReport x\(history.reports.count)") {
            for report in history.reports {
                try await store.captureReport(data: encoder.encode(report), runID: report.runID)
            }
        }

        let contexts = try await TaskContextStore(root: root).loadAvailableForDiscovery()
        try await time("\(pass): reconcile contexts x\(contexts.count)") {
            _ = try await store.reconcile(contexts: contexts)
        }
        let plans = contexts.map {
            ($0.ticketID, root.appendingPathComponent("tasks/\($0.ticketID.uppercased())/plan.md"))
        }.filter { FileManager.default.fileExists(atPath: $0.1.path) }
        await time("\(pass): captureDocument plans x\(plans.count)") {
            for (ticketID, plan) in plans {
                try? await store.captureDocument(at: plan, kind: "central-plan", ticketID: ticketID)
            }
        }
        try await time("\(pass): full reconcile") { _ = try await store.reconcile() }
    }

    private static func time(_ label: String, _ body: () async throws -> Void) async rethrows {
        let elapsed = try await ContinuousClock().measure { try await body() }
        print("BENCH \(label): \(elapsed)")
    }
}
