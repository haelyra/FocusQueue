import Darwin
import Foundation

/// Finds an existing local mux without launching a GUI or changing its windows.
public enum WezTermConnection {
  private static let paneArguments = ["cli", "list", "--format", "json"]
  private static let maximumCandidates = 12

  public static func resolve(
    configuration: WezTermConfiguration,
    runner: any ProcessRunning,
    candidateSockets: [String]? = nil
  ) async throws -> (configuration: WezTermConfiguration, result: ProcessResult) {
    let direct = try await runner.run(ProcessSpecification(
      executable: configuration.executable, arguments: paneArguments,
      environment: configuration.cliEnvironment, timeoutSeconds: 10))
    if hasValidPanes(direct) || direct.timedOut { return (configuration, direct) }

    var attempted = Set<String>()
    if let path = configuration.socketPath { attempted.insert(path) }
    var failures: [String] = []
    var encounteredTimeout = false
    var count = 0
    for path in candidateSockets ?? defaultCandidateSockets() {
      try Task.checkCancellation()
      guard count < maximumCandidates else { break }
      guard attempted.insert(path).inserted, isOwnedSocket(path) else { continue }
      count += 1
      var candidate = configuration
      candidate.socketPath = path
      let result = try await runner.run(ProcessSpecification(
        executable: candidate.executable, arguments: paneArguments,
        environment: candidate.cliEnvironment, timeoutSeconds: 2))
      if hasValidPanes(result) { return (candidate, result) }
      encounteredTimeout = encounteredTimeout || result.timedOut
      let detail = result.timedOut ? "timed out" : (
        result.succeeded ? "invalid pane JSON" : String(result.standardError.prefix(300)))
      failures.append("\(URL(fileURLWithPath: path).lastPathComponent): \(detail)")
    }
    let initialDetail = direct.succeeded ? "WezTerm returned invalid pane JSON." : direct.standardError
    let detail = failures.isEmpty ? initialDetail
      : initialDetail + "\nExisting WezTerm socket probes failed: " + failures.joined(separator: "; ")
    return (configuration, ProcessResult(
      exitCode: direct.exitCode == 0 ? 1 : direct.exitCode,
      standardOutput: direct.standardOutput, standardError: detail,
      timedOut: encounteredTimeout))
  }

  public static func defaultCandidateSockets() -> [String] {
    let files = FileManager.default
    var directories = [files.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/wezterm")]
    if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], runtime.hasPrefix("/") {
      directories.append(URL(fileURLWithPath: runtime).appendingPathComponent("wezterm"))
    }
    var candidates: [(path: String, modified: Date)] = []
    var seen = Set<String>()
    for directory in directories {
      let entries = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      for entry in entries where seen.insert(entry.path).inserted && isOwnedSocket(entry.path) {
        let attributes = try? files.attributesOfItem(atPath: entry.path)
        candidates.append((entry.path, attributes?[.modificationDate] as? Date ?? .distantPast))
      }
    }
    return candidates.sorted {
      $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified
    }.prefix(maximumCandidates).map(\.path)
  }

  private static func isOwnedSocket(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else { return false }
    return metadata.st_uid == getuid() && (metadata.st_mode & S_IFMT) == S_IFSOCK
  }

  private static func hasValidPanes(_ result: ProcessResult) -> Bool {
    result.succeeded && (try? JSONDecoder().decode([WezTermPane].self, from: Data(result.standardOutput.utf8))) != nil
  }
}
