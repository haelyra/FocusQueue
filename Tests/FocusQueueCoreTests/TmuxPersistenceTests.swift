import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Managed tmux save and layout recovery")
struct TmuxPersistenceTests {
  @Test("Pinned plugins save detached panes and recover shells on their own server", .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func detachedSaveAndRestore() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("persistence ' #{pane_id} $dollars \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let resources = root.appendingPathComponent("bundled plugins")
    let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Vendor/Tmux")
    try FileManager.default.copyItem(at: original, to: resources)
    let server = "fq-persist-\(UUID().uuidString.lowercased())"
    let otherServer = "fq-unrelated-\(UUID().uuidString.lowercased())"
    let runner = FoundationProcessRunner()
    let persistence = try TmuxPersistence.prepare(executable: executable, serverName: server,
      supportDirectory: root.appendingPathComponent("Application Support"), resourcesDirectory: resources,
      heartbeatSeconds: 1)
    do {
      let unrelated = try await runner.run(.init(executable: executable,
        arguments: ["-f", "/dev/null", "-L", otherServer, "new-session", "-d", "-s", "untouched", "/bin/sleep", "120"],
        environment: ["TMUX_TMPDIR": "/tmp"]))
      #expect(unrelated.succeeded)
      let start = try await runner.run(.init(executable: executable,
        arguments: ["-u", "-f", persistence.configurationURL.path, "-L", server,
          "new-session", "-d", "-s", "fq-task", "-c", root.path.replacingOccurrences(of: "#", with: "##"), "/bin/sleep", "120"],
        environment: ["TMUX_TMPDIR": "/tmp", "TMUX": "/tmp/unrelated,1,0"]))
      #expect(start.succeeded, "\(start.standardError)")
      try await persistence.enable(runner: runner)
      let errors = try await tmux(runner, executable, server, ["show-messages"])
      #expect(!errors.standardOutput.contains("configuration"))
      try await persistence.save(runner: runner)
      let last = persistence.stateDirectory.appendingPathComponent("resurrect/last")
      let firstSave = try String(contentsOf: last, encoding: .utf8)
      #expect(firstSave.contains("pane\tfq-task\t"))
      #expect(firstSave.replacingOccurrences(of: "\\ ", with: " ").contains(root.path))
      #expect(!firstSave.contains("sleep 120"))
      #expect(persistence.status().canRestore)
      let identity = try await tmux(runner, executable, server, ["list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}"])
      try await persistence.restoreLayout(runner: runner)
      let sameIdentity = try await tmux(runner, executable, server, ["list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}"])
      #expect(sameIdentity.standardOutput == identity.standardOutput)

      let split = try await tmux(runner, executable, server, ["split-window", "-d", "-t", "fq-task", "-c", root.path.replacingOccurrences(of: "#", with: "##"), "/bin/sleep", "120"])
      #expect(split.succeeded)
      _ = try await tmux(runner, executable, server, ["set-option", "-g", "@continuum-save-last-timestamp", "0"])
      var autoSaved = false
      for _ in 0..<100 {
        let saved = (try? String(contentsOf: last, encoding: .utf8)) ?? ""
        if saved.split(separator: "\n").filter({ $0.hasPrefix("pane\t") }).count == 2 { autoSaved = true; break }
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(autoSaved, "Continuum must save without an attached client, even with another server running.")
      _ = try await tmux(runner, executable, server, ["kill-server"])
      let restart = try await runner.run(.init(executable: executable,
        arguments: ["-u", "-f", persistence.configurationURL.path, "-L", server,
          "new-session", "-d", "-s", "fq-current", "/bin/sleep", "120"],
        environment: ["TMUX_TMPDIR": "/tmp"]))
      #expect(restart.succeeded)
      try await persistence.enable(runner: runner)
      try await persistence.save(runner: runner)
      #expect(persistence.status().recoverySavedAt != nil)
      #expect(try String(contentsOf: last, encoding: .utf8).contains("fq-current"))
      _ = try await tmux(runner, executable, server, ["kill-server"])
      try await persistence.restoreLayout(runner: runner)
      let restored = try await tmux(runner, executable, server,
        ["list-panes", "-a", "-F", "#{session_name}|#{pane_current_command}|#{pane_current_path}|#{@focus-queue-restored}"])
      #expect(restored.succeeded)
      let panes = restored.standardOutput.split(separator: "\n")
      #expect(panes.count == 2, "\(restored.standardOutput)")
      #expect(panes.allSatisfy { $0.hasPrefix("fq-task|") && $0.hasSuffix("|1") })
      #expect(!restored.standardOutput.contains("sleep"))
      #expect(restored.standardOutput.contains(root.path))
      let untouched = try await tmux(runner, executable, otherServer, ["show-option", "-gqv", "@resurrect-dir"])
      #expect(untouched.standardOutput.isEmpty)
    } catch {
      _ = try? await tmux(runner, executable, server, ["kill-server"])
      _ = try? await tmux(runner, executable, otherServer, ["kill-server"])
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    _ = try await tmux(runner, executable, server, ["kill-server"])
    _ = try await tmux(runner, executable, otherServer, ["kill-server"])
    try FileManager.default.removeItem(at: root)
  }

  private func tmux(_ runner: FoundationProcessRunner, _ executable: String, _ server: String, _ arguments: [String]) async throws -> ProcessResult {
    try await runner.run(.init(executable: executable, arguments: ["-u", "-L", server] + arguments,
      environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 30))
  }
}
