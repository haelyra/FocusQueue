import Foundation
import Testing
import Darwin

@testable import FocusQueueCore

@Suite("Daily report history")
struct DailyReportHistoryTests {
  private func temporaryRuntime() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let runtime = root.appendingPathComponent("ingestion")
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    return runtime
  }

  private func report(_ id: String, finishedAt: String = "2026-09-10T14:00:00Z") -> DailyReportDocument {
    DailyReportDocument(
      runID: id, reportDate: "2026-09-10", trigger: .manual, comprehensive: true,
      mode: .unseenOnly, startedAt: "2026-09-10T13:00:00Z", finishedAt: finishedAt,
      status: .success, summary: "Reviewed messages", tokenBudget: 75_000,
      usage: nil, platforms: [], errors: []
    )
  }

  private func archive(_ report: DailyReportDocument, runtime: URL) throws {
    let directory = runtime.appendingPathComponent("reports/2026-09-10")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(report).write(to: directory.appendingPathComponent("\(report.runID).json"))
  }

  @Test("Archived reports sort by actual timestamp, and reading persists without replacing latest")
  func historyAndUnread() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let older = report("older", finishedAt: "2026-09-10T14:00:00+02:00")
    let newer = report("newer", finishedAt: "2026-09-10T13:00:00.500Z")
    try archive(older, runtime: runtime)
    try archive(newer, runtime: runtime)
    let latestURL = runtime.appendingPathComponent("latest-report.json")
    try JSONEncoder().encode(newer).write(to: latestURL)
    let latestBefore = try Data(contentsOf: latestURL)
    let store = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    let snapshot = try await store.load()
    #expect(snapshot.reports.map(\.runID) == ["newer", "older"])
    #expect(snapshot.isUnread(older))
    try await store.markViewed(runID: older.runID)
    let restartedStore = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    let restarted = try await restartedStore.load()
    #expect(!restarted.isUnread(older))
    #expect(restarted.isUnread(newer))
    #expect(try Data(contentsOf: latestURL) == latestBefore)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: runtime.appendingPathComponent("report-presentation.json").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  }

  @Test("Failures persist as one run receipt with their original start time")
  func runLifecycle() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let store = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    let start = Date(timeIntervalSince1970: 100)
    try await store.recordRun(isRunning: true, message: "Reading messages", now: start)
    try await store.recordRun(isRunning: true, message: "Already running", now: start.addingTimeInterval(5))
    try await store.recordRun(isRunning: false, message: "Mail reader failed", isError: true,
                              now: start.addingTimeInterval(10))
    let reopened = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    let snapshot = try await reopened.load()
    #expect(snapshot.runs.count == 1)
    #expect(snapshot.runs.first?.phase == .failed)
    #expect(snapshot.runs.first?.startedAt == start)
    #expect(snapshot.runs.first?.message == "Mail reader failed")
    try await reopened.recordRun(isRunning: true, message: "Retry", now: start.addingTimeInterval(20))
    try await reopened.recordRun(isRunning: false, message: "Complete", reportID: "report-2",
                                 now: start.addingTimeInterval(30))
    let retried = try await reopened.load()
    #expect(retried.runs.count == 2)
    #expect(retried.runs.first?.reportID == "report-2")
    #expect(retried.runs.first?.phase == .completed)
  }

  @Test("One malformed archived report does not hide valid reports, and logs stay bounded")
  func partialArchiveAndLogs() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    try archive(report("valid"), runtime: runtime)
    try Data("broken".utf8).write(to: runtime.appendingPathComponent("reports/2026-09-10/bad.json"))
    try Data(String(repeating: "x", count: 40_000).utf8).write(
      to: runtime.deletingLastPathComponent().appendingPathComponent("morning.stdout.log"))
    let snapshot = try await JSONDailyReportHistoryRepository(runtimeDirectory: runtime).load()
    #expect(snapshot.reports.map(\.runID) == ["valid"])
    #expect(snapshot.warnings.count == 1)
    #expect(snapshot.standardOutput.utf8.count == 32_768)
    #expect(snapshot.standardError.isEmpty)
  }

  @Test("Interrupted runs retain an explicit diagnostic")
  func interruptedRun() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let store = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    try await store.recordRun(isRunning: true, message: "Reading messages")
    try await store.markInterruptedRuns()
    let snapshot = try await store.load()
    #expect(snapshot.runs.first?.phase == .interrupted)
    #expect(snapshot.runs.first?.message.contains("interrupted") == true)
  }

  @Test("Damaged viewing state preserves report visibility and is not overwritten")
  func damagedViewingState() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    try archive(report("valid"), runtime: runtime)
    let stateURL = runtime.appendingPathComponent("report-presentation.json")
    let broken = Data("invalid state".utf8)
    try broken.write(to: stateURL)
    let store = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    let snapshot = try await store.load()
    #expect(snapshot.reports.count == 1)
    #expect(snapshot.warnings.count == 1)
    await #expect(throws: (any Error).self) { try await store.markViewed(runID: "valid") }
    #expect(try Data(contentsOf: stateURL) == broken)
  }

  @Test("Startup preserves a live worker and reconciles its report after the lock releases")
  func startupWorkerLock() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let lockURL = runtime.appendingPathComponent("daily-report.lock")
    try Data().write(to: lockURL)
    let handle = try FileHandle(forUpdating: lockURL)
    defer { try? handle.close() }
    #expect(flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0)
    let store = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    let start = try #require(ISO8601DateFormatter().date(from: "2026-09-10T13:00:00Z"))
    try await store.recordRun(isRunning: true, message: "Reading", now: start)
    #expect(try await store.reconcileInactiveRuns())
    #expect(try await store.load().runs.first?.phase == .running)
    try archive(report("finished-after-ui-exit"), runtime: runtime)
    #expect(flock(handle.fileDescriptor, LOCK_UN) == 0)
    #expect(try await !store.reconcileInactiveRuns())
    let recovered = try await store.load()
    #expect(recovered.runs.first?.phase == .completed)
    #expect(recovered.runs.first?.reportID == "finished-after-ui-exit")
  }

  @Test("Startup marks a vanished worker interrupted")
  func startupMissingWorker() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let store = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    try await store.recordRun(isRunning: true, message: "Reading")
    #expect(try await !store.reconcileInactiveRuns())
    #expect(try await store.load().runs.first?.phase == .interrupted)
  }

  @Test("Cached archives update after replacement and forget removed files")
  func cacheInvalidation() async throws {
    let runtime = try temporaryRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let store = JSONDailyReportHistoryRepository(runtimeDirectory: runtime)
    try archive(report("first"), runtime: runtime)
    #expect(try await store.load().reports.first?.runID == "first")
    let document = runtime.appendingPathComponent("reports/2026-09-10/first.json")
    try JSONEncoder().encode(report("replacement-report")).write(to: document, options: .atomic)
    #expect(try await store.load().reports.first?.runID == "replacement-report")
    try FileManager.default.removeItem(at: document)
    #expect(try await store.load().reports.isEmpty)
  }
}
