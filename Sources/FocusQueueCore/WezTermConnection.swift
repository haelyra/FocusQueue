import Darwin
import CryptoKit
import Foundation

/// Finds an existing local mux without launching a GUI or changing its windows.
public enum WezTermConnection {
  static let paneArguments = ["cli", "list", "--format", "json"]
  private static let pinnedPaneArguments = ["cli", "--no-auto-start", "list", "--format", "json"]
  private static let maximumCandidates = 12
  static let probeTimeoutSeconds = 2

  public static func resolve(
    configuration: WezTermConfiguration,
    runner: any ProcessRunning,
    candidateSockets: [String]? = nil
  ) async throws -> (configuration: WezTermConfiguration, result: ProcessResult) {
    // Pin an implicit connection too. A GUI launch has no WEZTERM_UNIX_SOCKET;
    // the CLI's default can silently select a background mux instead of the GUI.
    var requested = configuration
    if requested.socketPath == nil, candidateSockets == nil {
      if let inherited = ProcessInfo.processInfo.environment["WEZTERM_UNIX_SOCKET"],
         isOwnedSocket(inherited) {
        requested.socketPath = inherited
      } else {
        requested.socketPath = defaultCandidateSockets().first
      }
    }
    let direct = try await runner.run(ProcessSpecification(
      executable: requested.executable, arguments: paneArguments(for: requested),
      environment: requested.cliEnvironment, timeoutSeconds: probeTimeoutSeconds))
    if hasValidPanes(direct) || direct.timedOut {
      // The CLI may have created its default mux during the initial probe.
      if !direct.timedOut, requested.socketPath == nil, candidateSockets == nil,
         let created = defaultCandidateSockets().first {
        requested.socketPath = created
        return try await resolve(configuration: requested, runner: runner)
      }
      return (requested, direct)
    }

    var attempted = Set<String>()
    if let path = requested.socketPath { attempted.insert(path) }
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
        executable: candidate.executable, arguments: paneArguments(for: candidate),
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

  /// A socket left by a quit GUI makes the CLI spawn a headless mux server and
  /// wait for it, which outlasts the probe deadline. A pinned probe must fail fast.
  static func paneArguments(for configuration: WezTermConfiguration) -> [String] {
    configuration.socketPath == nil ? paneArguments : pinnedPaneArguments
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
      let leftGUI = URL(fileURLWithPath: $0.path).lastPathComponent.hasPrefix("gui-sock-")
      let rightGUI = URL(fileURLWithPath: $1.path).lastPathComponent.hasPrefix("gui-sock-")
      if leftGUI != rightGUI { return leftGUI }
      return $0.modified == $1.modified ? $0.path < $1.path : $0.modified > $1.modified
    }.prefix(maximumCandidates).map(\.path)
  }

  private static func isOwnedSocket(_ path: String) -> Bool {
    guard path.hasPrefix("/") else { return false }
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else { return false }
    return metadata.st_uid == getuid() && (metadata.st_mode & S_IFMT) == S_IFSOCK
  }

  /// A mux daemon can accept panes without any GUI attached. Opening the app
  /// alone does not reveal those panes; connect a GUI to the exact saved socket.
  public static func revealArguments(configuration: WezTermConfiguration) -> [String] {
    guard let socket = configuration.socketPath,
          !URL(fileURLWithPath: socket).lastPathComponent.hasPrefix("gui-sock-") else {
      return ["-a", configuration.applicationName]
    }
    // Decimal byte escapes are literal Lua data, including quotes and newlines.
    let literal = "\"" + socket.utf8.map { String(format: "\\%03d", Int($0)) }.joined() + "\""
    let identity = SHA256.hash(data: Data(socket.utf8)).prefix(8)
      .map { String(format: "%02x", $0) }.joined()
    return ["-na", configuration.applicationName, "--args", "--config",
      "unix_domains={{name='focus-queue',socket_path=\(literal),no_serve_automatically=true}}",
      "connect", "--class", "com.haelyra.focus-queue-mux.\(identity)", "focus-queue"]
  }

  static func hasValidPanes(_ result: ProcessResult) -> Bool {
    result.succeeded && (try? JSONDecoder().decode([WezTermPane].self, from: Data(result.standardOutput.utf8))) != nil
  }
}
