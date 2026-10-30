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
  /// `titles` labels the new window; without them the terminal shows its
  /// own default, which for a tmux attach is just "tmux".
  public static func open(
    _ command: [String],
    configuration: WezTermConfiguration,
    titles: WezTermManagedConfig.Titles? = nil,
    supportDirectory: URL = TmuxPersistence.defaultSupportDirectory(),
    runner: any ProcessRunning = FoundationProcessRunner()
  ) async throws {
    let app = configuration.terminalApp
    var commandFile: URL?
    let arguments: [String]
    switch app {
    case .terminal:
      let file = try makeTerminalCommand(command, title: titles?.window)
      commandFile = file
      // No `-n`: every extra Terminal process restores the saved windows
      // again, and AppleScript can only reach one of them to close a window.
      arguments = ["-a", "Terminal", file.path]
    case .ghostty:
      // Each `open -n` starts its own Ghostty process; quitting with its last
      // window keeps one-off launches from leaving idle instances behind.
      // Ghostty still reads the user's own config; `--title` only pins the label.
      arguments = ["-na", "Ghostty", "--args", "--quit-after-last-window-closed=true"]
        + (titles.map { ["--title=\($0.window)"] } ?? []) + ["-e"] + command
    case .wezTerm:
      let configFile = try WezTermManagedConfig.install(supportDirectory: supportDirectory)
      arguments = WezTermManagedConfig.openArguments(
        applicationName: configuration.applicationName, configFile: configFile,
        titles: titles, directory: nil, command: command)
    }
    let result = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/open", arguments: arguments, timeoutSeconds: 15))
    guard result.succeeded else {
      if let commandFile { try? FileManager.default.removeItem(at: commandFile) }
      let detail = result.timedOut ? "terminal launch timed out" : String(result.standardError.prefix(800))
      throw WezTermError.actionFailed("\(app.displayName) could not open: \(detail)")
    }
  }

  static func makeTerminalCommand(_ command: [String], title: String? = nil) throws -> URL {
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
    // Terminal has no title option; an OSC 0 sequence before tmux starts sets it.
    let titleLine = title.map { "printf '\\033]0;%s\\007' \(shellQuote($0))\n" } ?? ""
    // Terminal keeps a window open after its shell exits unless the user's
    // profile says otherwise, so a watcher closes it once the command ends,
    // as WezTerm and Ghostty do. It runs in its own session: a watcher left
    // on the tty would make Terminal ask before every manual close.
    let closer = "/usr/bin/perl -e \(shellQuote(windowCloser)) -- \"$$\" \"$fq_tty\" "
      + "\(shellQuote(findWindowScript)) \(shellQuote(closeWindowScript))"
    let script = """
      #!/bin/zsh
      /bin/rm -f -- \(shellQuote(file.path))
      \(titleLine)if fq_tty=$(/usr/bin/tty); then
        \(closer) >/dev/null 2>&1 </dev/null &!
      fi
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

  /// Records the window while its tab is live (a finished tab keeps a stale
  /// tty name), waits for the command's process, then closes that window.
  /// The second fork detaches it from tmux, or Terminal titles the window
  /// "tmux ▸ perl".
  static let windowCloser = """
    use POSIX (); POSIX::setsid(); exit 0 if fork;
    my ($pid, $tty, $find, $close) = @ARGV;
    open(my $out, "-|", "/usr/bin/osascript", "-e", $find, $tty) or exit 1;
    my $window = <$out>; close $out;
    exit 1 unless defined $window && $window =~ /^(\\d+)\\s*$/;
    my $id = $1;
    sleep 1 while kill 0, $pid;
    exec "/usr/bin/osascript", "-e", $close, $id;
    """

  /// Windows are matched by id because index references shift while other
  /// windows open, which fails the lookup when several agents launch at once.
  static let findWindowScript = """
    on run argv
      tell application "Terminal"
        repeat 20 times
          try
            set windowIDs to id of every window whose tty of tab 1 is item 1 of argv
            repeat with i from 1 to count of windowIDs
              set windowID to item i of windowIDs
              if (count of processes of tab 1 of window id windowID) > 0 then return windowID as text
            end repeat
          end try
          delay 0.25
        end repeat
      end tell
      return ""
    end run
    """

  /// Waits for the shell to finish so the close never prompts, and leaves a
  /// window the user merged other tabs into: Terminal cannot close one tab.
  static let closeWindowScript = """
    on run argv
      set windowID to (item 1 of argv) as integer
      tell application "Terminal"
        repeat 40 times
          if not (exists window id windowID) then return
          set w to window id windowID
          -- A window the user already closed lingers, hidden, for a while.
          if not ((visible of w) or (miniaturized of w)) then return
          if (count of tabs of w) is not 1 then return
          if (count of processes of tab 1 of w) is 0 then
            close w
            return
          end if
          delay 0.25
        end repeat
      end tell
    end run
    """

  static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
