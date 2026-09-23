import Darwin
import Foundation

/// Opens a new desktop terminal view for one already verified tmux pane.
///
/// Managed recall intentionally does not discover or reuse a GUI pane. The
/// durable identity is tmux's server/session/pane tuple, so every button press
/// performs the same operation a user would: open a terminal and attach to the
/// exact pane.
enum ManagedTerminalLauncher {
  static func open(
    reference: TmuxSessionReference,
    configuration: WezTermConfiguration,
    runner: any ProcessRunning
  ) async throws -> TerminalActionResult {
    let attach = try TmuxController.attachCommand(reference: reference)
    let specification: ProcessSpecification
    var commandFile: URL?

    if configuration.applicationName.caseInsensitiveCompare("Terminal") == .orderedSame {
      let file = try makeTerminalCommand(attach)
      commandFile = file
      specification = ProcessSpecification(
        executable: "/usr/bin/open",
        arguments: ["-na", "Terminal", file.path],
        timeoutSeconds: 15)
    } else {
      specification = ProcessSpecification(
        executable: "/usr/bin/open",
        arguments: ["-na", configuration.applicationName, "--args",
          "--skip-config", "start", "--always-new-process", "--"] + attach,
        timeoutSeconds: 15)
    }

    let result = try await runner.run(specification)
    guard result.succeeded else {
      if let commandFile { try? FileManager.default.removeItem(at: commandFile) }
      let detail = result.timedOut ? "terminal launch timed out" : String(result.standardError.prefix(800))
      throw WezTermError.actionFailed(
        "The managed agent is still running, but (configuration.applicationName) could not open it: \(detail)")
    }
    return .spawned(paneID: nil)
  }

  private static func makeTerminalCommand(_ command: [String]) throws -> URL {
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

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
