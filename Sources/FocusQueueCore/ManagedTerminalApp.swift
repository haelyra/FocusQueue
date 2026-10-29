import Darwin
import Foundation

/// Desktop terminals that can open an agent's tmux pane. The configuration
/// stores the application name; this type gives each one its behavior.
public enum ManagedTerminalApp: String, CaseIterable, Identifiable, Sendable {
  case wezTerm = "WezTerm"
  case ghostty = "Ghostty"
  case terminal = "Terminal"

  public var id: String { rawValue }

  /// Unknown names keep the WezTerm path, which was the only one before.
  public init(applicationName: String) {
    self = Self.allCases.first {
      $0.applicationName.caseInsensitiveCompare(applicationName) == .orderedSame
    } ?? .wezTerm
  }

  /// The name passed to `open -a` and stored in `WezTermConfiguration`.
  public var applicationName: String { rawValue }

  public var displayName: String {
    switch self {
    case .wezTerm: "WezTerm"
    case .ghostty: "Ghostty"
    case .terminal: "macOS Terminal"
    }
  }

  public var bundleIdentifier: String {
    switch self {
    case .wezTerm: "com.github.wez.wezterm"
    case .ghostty: "com.mitchellh.ghostty"
    case .terminal: "com.apple.Terminal"
    }
  }

  public var downloadURL: URL? {
    switch self {
    case .wezTerm: URL(string: "https://wezterm.org/install/macos.html")
    case .ghostty: URL(string: "https://ghostty.org/download")
    case .terminal: nil
    }
  }

  public var summary: String {
    switch self {
    case .wezTerm: "Opens agents in tabs and lets Focus Queue find and label existing panes."
    case .ghostty: "Opens each agent's tmux pane in a new Ghostty window."
    case .terminal: "Built into macOS. Opens each agent's tmux pane in a new window."
    }
  }

  /// Only WezTerm has a CLI that can locate, spawn, and label panes. The
  /// others open a fresh window attached to tmux, so they need tmux.
  public var usesWezTermCLI: Bool { self == .wezTerm }
  public var requiresTmux: Bool { !usesWezTermCLI }
}

extension WezTermConfiguration {
  public var terminalApp: ManagedTerminalApp { ManagedTerminalApp(applicationName: applicationName) }
}

/// Opens a new desktop terminal window that runs one command. Used for
/// managed tmux attach and for provider sign-in.
public enum TerminalCommandLauncher {
  public static func open(
    _ command: [String],
    configuration: WezTermConfiguration,
    runner: any ProcessRunning = FoundationProcessRunner()
  ) async throws {
    let app = configuration.terminalApp
    var commandFile: URL?
    let arguments: [String]
    switch app {
    case .terminal:
      let file = try makeTerminalCommand(command)
      commandFile = file
      arguments = ["-na", "Terminal", file.path]
    case .ghostty:
      // Each `open -n` starts its own Ghostty process; quitting with its last
      // window keeps one-off launches from leaving idle instances behind.
      arguments = ["-na", "Ghostty", "--args", "--quit-after-last-window-closed=true", "-e"] + command
    case .wezTerm:
      arguments = ["-na", configuration.applicationName, "--args",
        "--skip-config", "start", "--always-new-process", "--"] + command
    }
    let result = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/open", arguments: arguments, timeoutSeconds: 15))
    guard result.succeeded else {
      if let commandFile { try? FileManager.default.removeItem(at: commandFile) }
      let detail = result.timedOut ? "terminal launch timed out" : String(result.standardError.prefix(800))
      throw WezTermError.actionFailed("\(app.displayName) could not open: \(detail)")
    }
  }

  static func makeTerminalCommand(_ command: [String]) throws -> URL {
    let files = FileManager.default
    let directory = files.temporaryDirectory.appendingPathComponent(
      "focus-queue-terminal-\(geteuid())", isDirectory: true)
    if Darwin.mkdir(directory.path, mode_t(0o700)) != 0, errno != EEXIST {
      throw WezTermError.actionFailed("Could not create the private Terminal launch directory.")
    }
    var metadata = stat()
    guard lstat(directory.path, &metadata) == 0,
      metadata.st_mode & S_IFMT == S_IFDIR,
      metadata.st_uid == geteuid(),
      metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
      throw WezTermError.actionFailed("The Terminal launch directory has unsafe ownership or permissions.")
    }

    let file = directory.appendingPathComponent("\(UUID().uuidString.lowercased()).command")
    let words = command.map(shellQuote).joined(separator: " ")
    let script = """
      #!/bin/zsh
      /bin/rm -f -- \(shellQuote(file.path))
      exec \(words)
      """ + "\n"
    do {
      try Data(script.utf8).write(to: file, options: .withoutOverwriting)
      try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    } catch {
      try? files.removeItem(at: file)
      throw WezTermError.actionFailed("Could not prepare the private Terminal launch command.")
    }
    return file
  }

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
