import Foundation
import Darwin

public enum DailyReportRunPhase: String, Codable, Equatable, Sendable {
  case running, completed, failed, interrupted
}

public struct DailyReportRunReceipt: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let startedAt: Date
  public var updatedAt: Date
  public var phase: DailyReportRunPhase
  public var message: String
  public var reportID: String?
}

public struct DailyReportHistorySnapshot: Equatable, Sendable {
  public var reports: [DailyReportDocument]
  public var runs: [DailyReportRunReceipt]
  public var viewedReportIDs: Set<String>
  public var standardOutput: String
  public var standardError: String
  public var warnings: [String]

  public init(
    reports: [DailyReportDocument] = [], runs: [DailyReportRunReceipt] = [],
    viewedReportIDs: Set<String> = [], standardOutput: String = "",
    standardError: String = "", warnings: [String] = []
  ) {
    self.reports = reports
    self.runs = runs
    self.viewedReportIDs = viewedReportIDs
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.warnings = warnings
  }

  public func isUnread(_ report: DailyReportDocument) -> Bool {
    !viewedReportIDs.contains(report.runID)
  }
}

/// Reads the worker's existing report archive. Presentation state is kept separately so
/// opening an old report never changes the worker's latest comprehensive report.
public actor JSONDailyReportHistoryRepository {
  private struct State: Codable {
    var version = 1
    var runs: [DailyReportRunReceipt] = []
    var viewedReportIDs: Set<String> = []
  }

  private let runtimeDirectory: URL
  private let supportDirectory: URL
  private let stateURL: URL
  private let files = FileManager.default
  private struct CachedReport {
    let modifiedAt: Date
    let size: Int
    let report: DailyReportDocument
  }
  private var reportCache: [URL: CachedReport] = [:]

  public init(runtimeDirectory: URL) {
    self.runtimeDirectory = runtimeDirectory
    self.supportDirectory = runtimeDirectory.deletingLastPathComponent()
    self.stateURL = runtimeDirectory.appendingPathComponent("report-presentation.json")
  }

  public func load() throws -> DailyReportHistorySnapshot {
    let state: State
    var warnings: [String] = []
    do {
      state = try readState()
    } catch {
      state = State()
      warnings.append("Could not read report viewing and run state: \(error.localizedDescription)")
    }
    var snapshot = DailyReportHistorySnapshot(
      runs: state.runs.sorted { $0.updatedAt > $1.updatedAt },
      viewedReportIDs: state.viewedReportIDs, warnings: warnings
    )
    var reports: [String: DailyReportDocument] = [:]
    var visitedURLs: Set<URL> = []
    let archive = runtimeDirectory.appendingPathComponent("reports", isDirectory: true)
    if files.fileExists(atPath: archive.path) {
      let days = try files.contentsOfDirectory(
        at: archive, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
      )
      for day in days {
        let values = try day.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
        let documents = try files.contentsOfDirectory(
          at: day, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
          options: [.skipsHiddenFiles]
        )
        for document in documents where document.pathExtension == "json" {
          do {
            let values = try document.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            visitedURLs.insert(document)
            let report = try readReport(at: document)
            reports[report.runID] = report
          } catch {
            snapshot.warnings.append("Could not read archived report \(document.lastPathComponent): \(error.localizedDescription)")
          }
        }
      }
    }
    // Older installations can have a latest report without a retained archive entry.
    let latest = runtimeDirectory.appendingPathComponent("latest-report.json")
    if files.fileExists(atPath: latest.path) {
      do {
        visitedURLs.insert(latest)
        let report = try readReport(at: latest)
        reports[report.runID] = report
      } catch {
        snapshot.warnings.append("Could not read latest report: \(error.localizedDescription)")
      }
    }
    reportCache = reportCache.filter { visitedURLs.contains($0.key) }
    var datedReports: [(report: DailyReportDocument, date: Date)] = reports.values.map {
      (report: $0, date: Self.timestamp($0.finishedAt))
    }
    datedReports.sort { left, right in
      if left.date == right.date { return left.report.runID > right.report.runID }
      return left.date > right.date
    }
    snapshot.reports = datedReports.map { $0.report }
    do { snapshot.standardOutput = try logTail("morning.stdout.log") }
    catch { snapshot.warnings.append("Could not read report output log: \(error.localizedDescription)") }
    do { snapshot.standardError = try logTail("morning.stderr.log") }
    catch { snapshot.warnings.append("Could not read report error log: \(error.localizedDescription)") }
    return snapshot
  }

  public func markViewed(runID: String) throws {
    var state = try readState()
    state.viewedReportIDs.insert(runID)
    try writeState(state)
  }

  /// Call only for report execution transitions, not settings confirmation messages.
  public func recordRun(
    isRunning: Bool, message: String, isError: Bool = false,
    reportID: String? = nil, now: Date = Date()
  ) throws {
    var state = try readState()
    let phase: DailyReportRunPhase = isRunning ? .running : (isError ? .failed : .completed)
    if let index = state.runs.lastIndex(where: { $0.phase == .running }) {
      state.runs[index].updatedAt = now
      state.runs[index].phase = phase
      state.runs[index].message = message
      state.runs[index].reportID = reportID ?? state.runs[index].reportID
    } else {
      state.runs.append(DailyReportRunReceipt(
        id: UUID().uuidString, startedAt: now, updatedAt: now,
        phase: phase, message: message, reportID: reportID
      ))
    }
    state.runs = Array(state.runs.suffix(200))
    try writeState(state)
  }

  /// Used after the app verifies that its previous report process is no longer running.
  public func markInterruptedRuns(now: Date = Date()) throws {
    var state = try readState()
    var changed = false
    for index in state.runs.indices where state.runs[index].phase == .running {
      state.runs[index].phase = .interrupted
      state.runs[index].updatedAt = now
      state.runs[index].message = "Report run was interrupted. Review the report history and logs before retrying."
      changed = true
    }
    if changed { try writeState(state) }
  }

  /// Call at startup before launching a worker. A nonblocking probe uses the same lock
  /// as Python, so a surviving worker is preserved. Returns true if a worker holds it.
  public func reconcileInactiveRuns(now: Date = Date()) throws -> Bool {
    let lockURL = runtimeDirectory.appendingPathComponent("daily-report.lock")
    guard files.fileExists(atPath: lockURL.path) else {
      try markInterruptedRuns(now: now)
      return false
    }
    let descriptor = Darwin.open(lockURL.path, O_RDONLY | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      if errno == EWOULDBLOCK || errno == EAGAIN { return true }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { flock(descriptor, LOCK_UN) }
    var state = try readState()
    guard state.runs.contains(where: { $0.phase == .running }) else { return false }
    let reports = try load().reports
    for index in state.runs.indices where state.runs[index].phase == .running {
      let run = state.runs[index]
      // A worker may finish after the UI exits. Recover its report instead of
      // claiming interruption when a matching execution completed successfully.
      let candidate = reports.last { report in
        let started = Self.timestamp(report.startedAt)
        return started >= run.startedAt.addingTimeInterval(-1)
          && started <= run.startedAt.addingTimeInterval(900)
      }
      state.runs[index].updatedAt = now
      if let candidate {
        state.runs[index].phase = candidate.status == .failed ? .failed : .completed
        state.runs[index].reportID = candidate.runID
        state.runs[index].message = candidate.summary
      } else {
        state.runs[index].phase = .interrupted
        state.runs[index].message = "Report run was interrupted. Review the report history and logs before retrying."
      }
    }
    try writeState(state)
    return false
  }

  private func readReport(at url: URL) throws -> DailyReportDocument {
    let metadata = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
    if let modifiedAt = metadata.contentModificationDate, let size = metadata.fileSize,
       let cached = reportCache[url], cached.modifiedAt == modifiedAt, cached.size == size {
      return cached.report
    }
    let report = try JSONDecoder().decode(DailyReportDocument.self, from: Data(contentsOf: url))
    if let modifiedAt = metadata.contentModificationDate, let size = metadata.fileSize {
      reportCache[url] = CachedReport(modifiedAt: modifiedAt, size: size, report: report)
    }
    return report
  }

  private func readState() throws -> State {
    guard files.fileExists(atPath: stateURL.path) else { return State() }
    return try JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))
  }

  private func writeState(_ state: State) throws {
    try files.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: stateURL, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
  }

  private func logTail(_ name: String) throws -> String {
    let url = supportDirectory.appendingPathComponent(name)
    guard files.fileExists(atPath: url.path) else { return "" }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let count = try handle.seekToEnd()
    try handle.seek(toOffset: count > 32_768 ? count - 32_768 : 0)
    return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
  }

  private static func timestamp(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value) ?? .distantPast
  }
}
