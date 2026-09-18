import Foundation

public struct TmuxPersistenceStatus: Equatable, Sendable {
  public var available: Bool
  public var lastSavedAt: Date?
  public var recoverySavedAt: Date?
  public var snapshotDirectory: String
  public var saveIntervalMinutes: Int
  public var canRestore: Bool { lastSavedAt != nil || recoverySavedAt != nil }
  public static let restoreExplanation = "Restore saved windows, pane layouts and folders. Resume agent conversations separately from Focus Queue."
}

/// Persistence belongs to one named server. No user tmux config or login item is changed.
public struct TmuxPersistence: Sendable {
  public let executable: String
  public let serverName: String
  public let configurationURL: URL
  public let stateDirectory: URL
  public let resourcesDirectory: URL
  public let saveIntervalMinutes: Int
  public let heartbeatSeconds: Int

  public static func prepare(
    executable: String,
    serverName: String = TmuxController.serverName,
    supportDirectory: URL? = nil,
    resourcesDirectory: URL? = nil,
    saveIntervalMinutes: Int = 5,
    heartbeatSeconds: Int = 30
  ) throws -> TmuxPersistence {
    try TmuxController.validateName(serverName)
    guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
      throw ProcessRunnerError.executableMissing(executable)
    }
    guard let resources = resourcesDirectory ?? bundledResources(),
      FileManager.default.fileExists(atPath: resources.appendingPathComponent("focus-queue-persistence.sh").path),
      FileManager.default.fileExists(atPath: resources.appendingPathComponent("tmux-resurrect/scripts/save.sh").path),
      FileManager.default.fileExists(atPath: resources.appendingPathComponent("tmux-continuum/scripts/continuum_save.sh").path)
    else { throw TmuxError.unavailable("The bundled tmux persistence scripts are missing. Reinstall Focus Queue to restore automatic saves.") }
    let support = supportDirectory ?? defaultSupportDirectory()
    guard [executable, resources.path, support.path].allSatisfy({ $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
      throw TmuxError.unavailable("tmux save folders and executable paths cannot contain tabs or line breaks.")
    }
    let state = support.appendingPathComponent("tmux", isDirectory: true).appendingPathComponent(serverName, isDirectory: true)
    let value = TmuxPersistence(executable: executable, serverName: serverName,
      configurationURL: state.appendingPathComponent("tmux.conf"), stateDirectory: state,
      resourcesDirectory: resources, saveIntervalMinutes: max(1, saveIntervalMinutes),
      heartbeatSeconds: max(1, heartbeatSeconds))
    try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.path)
    let saveLauncher = "#!/bin/bash\nexec " + value.command(action: "save") + "\n"
    try value.writeIfChanged(saveLauncher, to: state.appendingPathComponent("save.sh"), permissions: 0o700)
    let config = """
    # Generated for the Focus Queue managed server. User tmux configuration is separate.
    set-option -g @resurrect-processes 'false'
    set-option -g @resurrect-never-overwrite 'on'
    set-option -g @resurrect-capture-pane-contents 'off'
    set-option -g @continuum-restore 'off'
    set-option -g @continuum-boot 'off'
    set-option -g @continuum-save-interval '\(value.saveIntervalMinutes)'
    run-shell -b \(Self.tmuxQuote(value.command(action: "setup")))

    """
    try value.writeIfChanged(config, to: value.configurationURL, permissions: 0o600)
    return value
  }

  public static func defaultSupportDirectory() -> URL {
    if let override = ProcessInfo.processInfo.environment["FOCUS_QUEUE_SUPPORT_DIR"], override.hasPrefix("/") {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/ECC Focus Queue", isDirectory: true)
  }

  public static func bundledResources() -> URL? {
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
      .resolvingSymlinksInPath().deletingLastPathComponent()
    let candidates = [
      Bundle.main.resourceURL?.appendingPathComponent("tmux", isDirectory: true),
      executableURL.deletingLastPathComponent().appendingPathComponent("Resources/tmux", isDirectory: true),
    ].compactMap { $0 }
      + installedResourceCandidates(homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
      + [sourceRoot.appendingPathComponent("Vendor/Tmux", isDirectory: true)]
    return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("focus-queue-persistence.sh").path) }
  }

  static func installedResourceCandidates(homeDirectory: URL) -> [URL] {
    [
      "Applications/Focus Queue.app/Contents/Resources/tmux",
      "Applications/ECC Focus Queue.app/Contents/Resources/tmux",
    ].map { homeDirectory.appendingPathComponent($0, isDirectory: true) }
  }

  public func enable(runner: any ProcessRunning = FoundationProcessRunner()) async throws {
    try await perform(action: "setup", runner: runner)
  }

  public func save(runner: any ProcessRunning = FoundationProcessRunner()) async throws {
    try await perform(action: "save", runner: runner)
  }

  /// Recreates layout as shells. It never relaunches provider commands or initial prompts.
  public func restoreLayout(runner: any ProcessRunning = FoundationProcessRunner()) async throws {
    // A detached placeholder is needed only if the managed server has stopped.
    // The script removes only the exact placeholder pane it creates itself.
    try await perform(action: "restore", runner: runner)
  }

  public func status() -> TmuxPersistenceStatus {
    let snapshots = stateDirectory.appendingPathComponent("resurrect", isDirectory: true)
    return .init(available: FileManager.default.fileExists(atPath: resourcesDirectory.appendingPathComponent("focus-queue-persistence.sh").path),
      lastSavedAt: modificationDate(snapshots.appendingPathComponent("last")),
      recoverySavedAt: modificationDate(snapshots.appendingPathComponent("recovery/last")),
      snapshotDirectory: snapshots.path, saveIntervalMinutes: saveIntervalMinutes)
  }

  private func modificationDate(_ url: URL) -> Date? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
  }

  private var arguments: [String] {
    [executable, serverName, stateDirectory.path, resourcesDirectory.path,
      String(saveIntervalMinutes), String(heartbeatSeconds)]
  }

  private func command(action: String) -> String {
    (["/bin/bash", resourcesDirectory.appendingPathComponent("focus-queue-persistence.sh").path, action] + arguments)
      .map(Self.shellQuote).joined(separator: " ")
  }

  private func perform(action: String, runner: any ProcessRunning) async throws {
    let result = try await runner.run(.init(executable: "/bin/bash",
      arguments: [resourcesDirectory.appendingPathComponent("focus-queue-persistence.sh").path, action] + arguments,
      environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 30))
    guard result.succeeded else {
      throw TmuxError.unavailable(result.timedOut ? "Saving or restoring the tmux layout timed out. Check the session before retrying." : String(result.standardError.prefix(800)))
    }
  }

  private func writeIfChanged(_ text: String, to url: URL, permissions: Int) throws {
    let data = Data(text.utf8)
    if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
    try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  static func tmuxQuote(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "$", with: "\\$")
      .replacingOccurrences(of: "\n", with: "\\n") + "\""
  }
}
