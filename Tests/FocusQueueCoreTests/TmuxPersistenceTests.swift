import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Managed tmux save and layout recovery")
struct TmuxPersistenceTests {
  @Test("Restore never claims preexisting reserved-name sessions", .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func restoreDoesNotClaimPreexistingSessions() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("persistence collision \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let resources = root.appendingPathComponent("bundled plugins")
    let original = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Vendor/Tmux")
    try FileManager.default.copyItem(at: original, to: resources)
    let server = "fq-persist-collision-\(UUID().uuidString.lowercased())"
    let runner = FoundationProcessRunner()
    let persistence = try TmuxPersistence.prepare(executable: executable, serverName: server,
      supportDirectory: root.appendingPathComponent("Application Support"), resourcesDirectory: resources,
      heartbeatSeconds: 30)
    do {
      let start = try await runner.run(.init(executable: executable,
        arguments: ["-u", "-f", persistence.configurationURL.path, "-L", server,
          "new-session", "-d", "-s", "fq-task-ecc-collision", "/bin/sleep", "120"],
        environment: ["TMUX_TMPDIR": "/tmp"]))
      #expect(start.succeeded, "\(start.standardError)")
      _ = try await tmux(runner, executable, server,
        ["set-option", "-t", "fq-task-ecc-collision", "@focus-queue-task", "ECC-COLLISION"])
      try await persistence.enable(runner: runner)
      try await persistence.save(runner: runner)

      _ = try await tmux(runner, executable, server,
        ["new-session", "-d", "-s", "guard", "/bin/sleep", "120"])
      _ = try await tmux(runner, executable, server, ["kill-session", "-t", "fq-task-ecc-collision"])
      _ = try await tmux(runner, executable, server,
        ["new-session", "-d", "-s", "fq-task-ecc-collision", "/bin/sleep", "120"])
      _ = try await tmux(runner, executable, server,
        ["new-session", "-d", "-s", "fq-task-ecc-unlisted", "/bin/sleep", "120"])

      try await persistence.restoreLayout(runner: runner)
      let collisionOwner = try await tmux(runner, executable, server,
        ["show-option", "-qv", "-t", "fq-task-ecc-collision", "@focus-queue-task"])
      let unlistedOwner = try await tmux(runner, executable, server,
        ["show-option", "-qv", "-t", "fq-task-ecc-unlisted", "@focus-queue-task"])
      #expect(collisionOwner.standardOutput.isEmpty,
        "A preexisting session that collides with saved metadata must remain unowned.")
      #expect(unlistedOwner.standardOutput.isEmpty,
        "Legacy inference must not claim a preexisting reserved-name session absent from the snapshot.")
    } catch {
      _ = try? await tmux(runner, executable, server, ["kill-server"])
      try? FileManager.default.removeItem(at: root)
      throw error
    }
    _ = try await tmux(runner, executable, server, ["kill-server"])
    try FileManager.default.removeItem(at: root)
  }

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
          "new-session", "-d", "-s", "fq-task-ecc-restore", "-c", root.path.replacingOccurrences(of: "#", with: "##"), "/bin/sleep", "120"],
        environment: ["TMUX_TMPDIR": "/tmp", "TMUX": "/tmp/unrelated,1,0"]))
      #expect(start.succeeded, "\(start.standardError)")
      _ = try await tmux(runner, executable, server,
        ["set-option", "-t", "fq-task-ecc-restore", "@focus-queue-task", "ECC-RESTORE"])
      _ = try await tmux(runner, executable, server,
        ["set-option", "-p", "-t", "fq-task-ecc-restore:0.0", "@focus-queue-agent", "agent-one"])
      try await persistence.enable(runner: runner)
      let errors = try await tmux(runner, executable, server, ["show-messages"])
      #expect(!errors.standardOutput.contains("configuration"))
      try await persistence.save(runner: runner)
      let last = persistence.stateDirectory.appendingPathComponent("resurrect/last")
      let firstSave = try String(contentsOf: last, encoding: .utf8)
      #expect(firstSave.contains("pane\tfq-task-ecc-restore\t"))
      #expect(firstSave.contains("focus_queue\tfq-task-ecc-restore\t0\t0\tECC-RESTORE\tagent-one"))
      #expect(firstSave.replacingOccurrences(of: "\\ ", with: " ").contains(root.path))
      #expect(!firstSave.contains("sleep 120"))
      #expect(persistence.status().canRestore)
      let identity = try await tmux(runner, executable, server, ["list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}"])
      try await persistence.restoreLayout(runner: runner)
      let sameIdentity = try await tmux(runner, executable, server, ["list-panes", "-a", "-F", "#{pane_id}|#{pane_pid}"])
      #expect(sameIdentity.standardOutput == identity.standardOutput)

      let split = try await tmux(runner, executable, server, ["split-window", "-d", "-P", "-F", "#{pane_id}",
        "-t", "fq-task-ecc-restore", "-c", root.path.replacingOccurrences(of: "#", with: "##"), "/bin/sleep", "120"])
      #expect(split.succeeded)
      let secondPane = split.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(secondPane.range(of: "^%[0-9]+$", options: .regularExpression) != nil)
      _ = try await tmux(runner, executable, server,
        ["set-option", "-p", "-t", secondPane, "@focus-queue-agent", "agent-two"])
      _ = try await tmux(runner, executable, server, ["set-option", "-g", "@continuum-save-last-timestamp", "0"])
      var autoSaved = false
      for _ in 0..<100 {
        let saved = (try? String(contentsOf: last, encoding: .utf8)) ?? ""
        if saved.split(separator: "\n").filter({ $0.hasPrefix("pane\t") }).count == 2,
          saved.split(separator: "\n").filter({ $0.hasPrefix("focus_queue\t") }).count == 2,
          saved.contains("\tECC-RESTORE\tagent-one"), saved.contains("\tECC-RESTORE\tagent-two")
        { autoSaved = true; break }
        try await Task.sleep(for: .milliseconds(100))
      }
      #expect(autoSaved, "Continuum must save without an attached client, even with another server running.")
      let automaticSnapshot = try String(contentsOf: last, encoding: .utf8)
      #expect(automaticSnapshot.contains("\tECC-RESTORE\tagent-one"), "\(automaticSnapshot)")
      #expect(automaticSnapshot.contains("\tECC-RESTORE\tagent-two"), "\(automaticSnapshot)")
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
        ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}|#{pane_current_command}|#{pane_current_path}|#{@focus-queue-task}|#{@focus-queue-agent}|#{@focus-queue-restored-agent}|#{@focus-queue-restored}"])
      #expect(restored.succeeded)
      let panes = restored.standardOutput.split(separator: "\n")
      #expect(panes.count == 2, "\(restored.standardOutput)")
      #expect(panes.allSatisfy { $0.contains("|fq-task-ecc-restore|") && $0.hasSuffix("|1") })
      #expect(panes.allSatisfy { $0.contains("|ECC-RESTORE||agent-") }, "\(restored.standardOutput)")
      #expect(!restored.standardOutput.contains("sleep"))
      #expect(restored.standardOutput.contains(root.path))
      try await persistence.save(runner: runner)
      let repeatSnapshot = try String(contentsOf: last, encoding: .utf8)
      #expect(repeatSnapshot.contains("\tECC-RESTORE\tagent-one"), "\(repeatSnapshot)")
      #expect(repeatSnapshot.contains("\tECC-RESTORE\tagent-two"), "\(repeatSnapshot)")
      _ = try await tmux(runner, executable, server, ["kill-server"])
      try await persistence.restoreLayout(runner: runner)
      let twiceRestored = try await tmux(runner, executable, server,
        ["list-panes", "-a", "-F", "#{pane_id}|#{session_name}|#{@focus-queue-task}|#{@focus-queue-agent}|#{@focus-queue-restored-agent}|#{@focus-queue-restored}"])
      #expect(twiceRestored.standardOutput.split(separator: "\n").count == 2)
      #expect(twiceRestored.standardOutput.contains("|ECC-RESTORE||agent-one|1"))
      #expect(twiceRestored.standardOutput.contains("|ECC-RESTORE||agent-two|1"))
      let repeatedPanes = twiceRestored.standardOutput.split(separator: "\n")
      let firstRestoredLine = try #require(repeatedPanes.first(where: { $0.contains("||agent-one|1") }))
      let firstRestoredPane = String(firstRestoredLine.split(
        separator: "|", omittingEmptySubsequences: false)[0])
      let receiptRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
        "focus-queue-launches-\(server)", isDirectory: true)
      try FileManager.default.createDirectory(at: receiptRoot, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
      let staleReceipt = receiptRoot.appendingPathComponent("ecc-restore-agent-one.receipt")
      try Data("fq-launch-stale".utf8).write(to: staleReceipt)
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staleReceipt.path)
      let resumed = try await TmuxController(serverName: server).startAgent(
        taskID: "ECC-RESTORE", subtaskID: "agent-one", directory: root.path,
        command: ["/bin/sleep", "120"], executable: executable)
      #expect(resumed.paneID != firstRestoredPane,
        "A restored shell may have been repurposed and must never be killed during resume.")
      let resumedMetadata = try await tmux(runner, executable, server,
        ["display-message", "-p", "-t", resumed.paneID,
          "#{@focus-queue-agent}|#{@focus-queue-restored-agent}|#{@focus-queue-restored}"])
      #expect(resumedMetadata.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "agent-one||")
      let retainedMetadata = try await tmux(runner, executable, server,
        ["display-message", "-p", "-t", firstRestoredPane,
          "#{@focus-queue-agent}|#{@focus-queue-restored-agent}|#{@focus-queue-restored}"])
      #expect(retainedMetadata.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "||1")
      try? FileManager.default.removeItem(at: receiptRoot)
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
