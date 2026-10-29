import Foundation

/// Setup discovery only checks files. Providers, shell profiles and network tools are never run.
public enum SetupEnvironment {
  public static func executable(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
    let candidates = [home.appendingPathComponent(".local/bin/\(name)").path,
      "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "/usr/bin/\(name)"]
      + (name == "wezterm" ? [home.appendingPathComponent("Applications/WezTerm.app/Contents/MacOS/wezterm").path,
          "/Applications/WezTerm.app/Contents/MacOS/wezterm"] : [])
      + (name == "tailscale" ? ["/Applications/Tailscale.app/Contents/MacOS/Tailscale"] : [])
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  public static func starter(supportDirectory: URL,
                             home: URL = FileManager.default.homeDirectoryForCurrentUser) -> AppConfiguration {
    var configuration = AppConfiguration(appName: "Focus Queue",
      dashboardPath: supportDirectory.appendingPathComponent("workspace/dashboard.json").path,
      workspacePath: supportDirectory.appendingPathComponent("workspace").path,
      defaultPlacement: .upperLeft, refreshIntervalSeconds: 2, dailyRoutines: [],
      wezTerm: .init(executable: executable("wezterm", home: home) ?? "/Applications/WezTerm.app/Contents/MacOS/wezterm"),
      verifier: .init(enabled: false, executable: home.appendingPathComponent(".local/bin/focus-queue-codex").path,
        sessionName: "focus-queue-verifier"))
    configuration.setupCompleted = false
    return configuration
  }

  /// An existing dashboard is validated and retained byte for byte.
  public static func prepareWorkspace(configuration: AppConfiguration) throws {
    _ = try configuration.validated()
    let files = FileManager.default
    let workspace = URL(fileURLWithPath: configuration.workspacePath)
    var directory: ObjCBool = false
    guard files.fileExists(atPath: workspace.path, isDirectory: &directory), directory.boolValue else {
      throw SetupError.invalidWorkspace
    }
    let dashboard = URL(fileURLWithPath: configuration.dashboardPath)
    if files.fileExists(atPath: dashboard.path) {
      _ = try JSONDecoder().decode(DashboardDocument.self, from: Data(contentsOf: dashboard))
    } else {
      // Create a starter queue only in the chosen workspace, never at an arbitrary missing path.
      guard dashboard.deletingLastPathComponent().standardizedFileURL == workspace.standardizedFileURL else {
        throw SetupError.missingDashboard
      }
      try Data("{\"tickets\":[]}\n".utf8).write(to: dashboard, options: [.withoutOverwriting])
      try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dashboard.path)
    }
  }

  public static func createStarterWorkspace(supportDirectory: URL) throws {
    let workspace = supportDirectory.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try prepareWorkspace(configuration: starter(supportDirectory: supportDirectory))
  }

  public static func installSessionHelper(source: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
    let destination = home.appendingPathComponent(".local/bin/focus-queue-session")
    let files = FileManager.default
    guard files.isExecutableFile(atPath: source.path) else { throw ProcessRunnerError.executableMissing(source.path) }
    var parent = destination
    while parent.path != home.path && parent.path != "/" {
      if (try? parent.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
        throw SetupError.helperConflict
      }
      parent.deleteLastPathComponent()
    }
    let data = try Data(contentsOf: source)
    if files.fileExists(atPath: destination.path) {
      guard try Data(contentsOf: destination) == data else { throw SetupError.helperConflict }
      return destination
    }
    try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination, options: .withoutOverwriting)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    return destination
  }

  public static let terminalCapabilities: [(name: String, support: String)] = [
    ("WezTerm", "Deterministic managed-session recall, pane browsing and direct-session control."),
    ("Terminal.app", "Deterministic managed-session recall through a private one-use command file."),
    ("Ghostty", "Deterministic managed-session recall in a new window attached to the tmux pane."),
    ("iTerm2, kitty", "Use the session helper inside the terminal to create and attach tmux sessions. Automated desktop opening is not configured."),
    ("VS Code / Cursor terminals", "The tmux command-line path is available inside integrated terminals. Editor pane discovery is not implemented."),
    ("SSH clients", "Reconnect to tmux on the original Mac. Tailscale supplies private network access; SSH access must be configured separately.")
  ]
}

public enum SetupError: Error, LocalizedError {
  case invalidWorkspace, missingDashboard, helperConflict
  public var errorDescription: String? {
    switch self {
    case .invalidWorkspace: "Choose an existing workspace folder."
    case .missingDashboard: "Choose an existing dashboard, or create dashboard.json directly in the selected workspace."
    case .helperConflict: "An existing helper or symlink needs review. Use the staged installer to update an existing Focus Queue installation."
    }
  }
}
