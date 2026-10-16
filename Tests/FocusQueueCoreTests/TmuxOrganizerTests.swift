import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Task tmux organizer")
struct TmuxOrganizerTests {
  @Test("Organizer locks reject redirected and writable temporary objects")
  func secureOrganizerLocks() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fq-secure-lock-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let actual = base.appendingPathComponent("actual", isDirectory: true)
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let redirected = base.appendingPathComponent("redirected", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: actual)
    await #expect(throws: TmuxError.self) {
      try await TmuxOrganizerLock.acquire(name: "redirected", root: redirected)
    }

    let writable = base.appendingPathComponent("writable", isDirectory: true)
    try FileManager.default.createDirectory(at: writable, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: writable.path)
    await #expect(throws: TmuxError.self) {
      try await TmuxOrganizerLock.acquire(name: "writable", root: writable)
    }

    let safe = base.appendingPathComponent("safe", isDirectory: true)
    try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let unsafeFile = safe.appendingPathComponent("unsafe.lock")
    try Data().write(to: unsafeFile)
    try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: unsafeFile.path)
    await #expect(throws: TmuxError.self) {
      try await TmuxOrganizerLock.acquire(name: "unsafe", root: safe)
    }
    let linkTarget = base.appendingPathComponent("target")
    try Data("preserve".utf8).write(to: linkTarget)
    try FileManager.default.createSymbolicLink(
      at: safe.appendingPathComponent("linked.lock"), withDestinationURL: linkTarget)
    await #expect(throws: TmuxError.self) {
      try await TmuxOrganizerLock.acquire(name: "linked", root: safe)
    }
    #expect(try String(contentsOf: linkTarget, encoding: .utf8) == "preserve")
  }

  @Test("Launch receipts reject redirected or writable temporary storage")
  func secureLaunchReceipts() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fq-secure-receipt-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let taskID = "TEST-\(UUID().uuidString)"
    let subtaskID = "agent"
    let temporary = FileManager.default.temporaryDirectory

    let redirectedServer = "fq-receipt-link-\(UUID().uuidString.lowercased())"
    let redirectedRoot = temporary.appendingPathComponent(
      "focus-queue-launches-\(redirectedServer)", isDirectory: true)
    let actual = base.appendingPathComponent("actual", isDirectory: true)
    try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    try FileManager.default.createSymbolicLink(at: redirectedRoot, withDestinationURL: actual)
    defer { try? FileManager.default.removeItem(at: redirectedRoot) }
    let redirectedRunner = MissingTaskSessionRunner()
    await #expect(throws: TmuxError.self) {
      try await TmuxController(runner: redirectedRunner, serverName: redirectedServer).startAgent(
        taskID: taskID, subtaskID: subtaskID, directory: base.path,
        command: ["/bin/sleep", "30"], executable: "/mock/tmux")
    }
    #expect(await redirectedRunner.launches == 0)

    let unsafeServer = "fq-receipt-mode-\(UUID().uuidString.lowercased())"
    let unsafeRoot = temporary.appendingPathComponent(
      "focus-queue-launches-\(unsafeServer)", isDirectory: true)
    try FileManager.default.createDirectory(at: unsafeRoot, withIntermediateDirectories: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o770], ofItemAtPath: unsafeRoot.path)
    defer { try? FileManager.default.removeItem(at: unsafeRoot) }
    let unsafeRunner = MissingTaskSessionRunner()
    await #expect(throws: TmuxError.self) {
      try await TmuxController(runner: unsafeRunner, serverName: unsafeServer).startAgent(
        taskID: taskID, subtaskID: subtaskID, directory: base.path,
        command: ["/bin/sleep", "30"], executable: "/mock/tmux")
    }
    #expect(await unsafeRunner.launches == 0)

    let fileServer = "fq-receipt-file-\(UUID().uuidString.lowercased())"
    let fileRoot = temporary.appendingPathComponent(
      "focus-queue-launches-\(fileServer)", isDirectory: true)
    try FileManager.default.createDirectory(at: fileRoot, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: fileRoot) }
    let target = base.appendingPathComponent("receipt-target")
    try Data("preserve".utf8).write(to: target)
    let leaf = fileRoot.appendingPathComponent("\(taskID.lowercased())-\(subtaskID).receipt")
    try FileManager.default.createSymbolicLink(at: leaf, withDestinationURL: target)
    let fileRunner = MissingTaskSessionRunner()
    await #expect(throws: TmuxError.self) {
      try await TmuxController(runner: fileRunner, serverName: fileServer).startAgent(
        taskID: taskID, subtaskID: subtaskID, directory: base.path,
        command: ["/bin/sleep", "30"], executable: "/mock/tmux")
    }
    #expect(await fileRunner.launches == 0)
    #expect(try String(contentsOf: target, encoding: .utf8) == "preserve")
  }

  @Test("Task-aware CLI launches share one tracked tmux session",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func taskAgentCLI() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let helper = sourceRoot.appendingPathComponent(".build/debug/focus-queue-session").path
    try #require(FileManager.default.isExecutableFile(atPath: helper))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fq-start-agent-cli-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var configuration = SetupEnvironment.starter(supportDirectory: root)
    configuration.tmuxExecutable = executable
    try JSONEncoder().encode(configuration).write(to: root.appendingPathComponent("config.json"))
    let taskID = "TEST-\(UUID().uuidString)"
    let sessionName = try TmuxController.taskSessionName(taskID: taskID)
    let runner = FoundationProcessRunner()
    defer {
      let cleanup = Process()
      cleanup.executableURL = URL(fileURLWithPath: executable)
      cleanup.arguments = ["-L", TmuxController.serverName, "kill-session", "-t", "=\(sessionName)"]
      cleanup.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
      cleanup.standardError = FileHandle.nullDevice
      try? cleanup.run(); cleanup.waitUntilExit()
      try? FileManager.default.removeItem(at: root)
    }
    func launch(agentID: String, marker: URL) async throws -> TmuxSessionReference {
      let script = "printf '%s|%s|%s|%s' \"$FOCUS_QUEUE_MANAGED_TMUX\" \"$FOCUS_QUEUE_TASK_ID\" \"$FOCUS_QUEUE_SUBTASK_ID\" \"$FOCUS_QUEUE_RUNTIME_MODE\" > \"$1\"; exec /bin/sleep 30"
      let result = try await runner.run(.init(executable: helper, arguments: [
        "tmux", "start-agent", taskID, agentID, "--cwd", root.path, "--",
        "/bin/sh", "-c", script, "focus-queue-agent", marker.path,
      ], environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path], timeoutSeconds: 15))
      #expect(result.succeeded, "\(result.standardError)")
      return try JSONDecoder().decode(TmuxSessionReference.self, from: Data(result.standardOutput.utf8))
    }

    let firstID = UUID().uuidString.lowercased()
    let secondID = UUID().uuidString.lowercased()
    let firstMarker = root.appendingPathComponent("first.env")
    let secondMarker = root.appendingPathComponent("second.env")
    let first = try await launch(agentID: firstID, marker: firstMarker)
    let second = try await launch(agentID: secondID, marker: secondMarker)

    #expect(first.name == sessionName)
    #expect(second.name == sessionName)
    #expect(first.paneID != second.paneID)
    let firstJSON = String(decoding: try JSONEncoder().encode(first), as: UTF8.self)
    let verifiedAttach = try await runner.run(.init(executable: helper, arguments: [
      "tmux", "attach-reference", firstJSON, "--task", taskID, "--agent", firstID,
    ], environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path], timeoutSeconds: 15))
    #expect(!verifiedAttach.succeeded)
    #expect(verifiedAttach.standardError.contains("Attach needs an interactive terminal"))
    let wrongAgent = try await runner.run(.init(executable: helper, arguments: [
      "tmux", "attach-reference", firstJSON, "--task", taskID, "--agent", secondID,
    ], environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path], timeoutSeconds: 15))
    #expect(!wrongAgent.succeeded)
    #expect(!wrongAgent.standardError.contains("Attach needs an interactive terminal"))
    let panes = try await TmuxController().panes(name: sessionName, executable: executable)
    #expect(Set(panes.map(\.subtaskID)) == [firstID, secondID])
    #expect(try String(contentsOf: firstMarker, encoding: .utf8) == "1|\(taskID.uppercased())|\(firstID)|tmux")
    #expect(try String(contentsOf: secondMarker, encoding: .utf8) == "1|\(taskID.uppercased())|\(secondID)|tmux")
    let hooks = try await runner.run(.init(executable: executable, arguments: [
      "-L", TmuxController.serverName, "show-hooks", "-t", sessionName, "client-attached",
    ], environment: ["TMUX_TMPDIR": "/tmp"]))
    #expect(hooks.succeeded)
    #expect(hooks.standardOutput.contains("focus-queue-session") && hooks.standardOutput.contains("reflow"))
    let resurrect = try await runner.run(.init(executable: executable, arguments: [
      "-L", TmuxController.serverName, "show-options", "-gqv", "@resurrect-dir",
    ], environment: ["TMUX_TMPDIR": "/tmp"]))
    #expect(resurrect.succeeded)
    #expect(!resurrect.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    let mouse = try await runner.run(.init(executable: executable, arguments: [
      "-L", TmuxController.serverName, "show-options", "-gv", "mouse",
    ], environment: ["TMUX_TMPDIR": "/tmp"]))
    let history = try await runner.run(.init(executable: executable, arguments: [
      "-L", TmuxController.serverName, "display-message", "-p", "-t", first.paneID,
      "#{history_limit}",
    ], environment: ["TMUX_TMPDIR": "/tmp"]))
    #expect(mouse.succeeded)
    #expect(mouse.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "on")
    #expect(history.succeeded)
    #expect(Int(history.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines))
      == TmuxController.managedHistoryLimit)
  }

  @Test("Every usable task window supports at most four agent panes")
  func capacity() throws {
    #expect(TmuxPaneLayout.capacity(width: 80, height: 24) == 4)
    #expect(TmuxPaneLayout.capacity(width: 160, height: 30) == 4)
    #expect(TmuxPaneLayout.capacity(width: 90, height: 60) == 4)
    #expect(TmuxPaneLayout.capacity(width: 240, height: 60) == 4)
    #expect(TmuxPaneLayout.capacity(width: 500, height: 200) == 4)
    #expect(TmuxPaneLayout.capacity(width: 0, height: 24) == 0)
    #expect(TmuxPaneLayout.groups(Array(0..<9), width: 160, height: 50).map(\.count) == [4, 4, 1])
    #expect(TmuxPaneLayout.contentHeight(clientHeight: 51, status: "4", controlMode: false) == 47)
    #expect(TmuxPaneLayout.contentHeight(clientHeight: 51, status: "on", controlMode: false) == 50)
    #expect(TmuxPaneLayout.contentHeight(clientHeight: 51, status: "off", controlMode: false) == 51)
    #expect(TmuxPaneLayout.contentHeight(clientHeight: 51, status: "4", controlMode: true) == 51)
    #expect(!((try? TmuxPaneLayout.layout(paneIDs: ["%0", "%1"], width: 80, height: 24)) ?? "").isEmpty)
    #expect(throws: TmuxError.self) {
      try TmuxPaneLayout.layout(paneIDs: ["%0", "%1", "%2", "%3", "%4"], width: 240, height: 60)
    }
  }

  @Test("Malformed layouts and cross-task identities fail closed")
  func malformed() throws {
    #expect(throws: TmuxError.self) { try TmuxPaneLayout.layout(paneIDs: ["%1; kill-server"], width: 80, height: 24) }
    #expect(throws: TmuxError.self) { try TmuxController.taskSessionName(taskID: "ECC-1:other") }
    #expect(!TmuxController.ownsSession(name: "fq-task-ecc-2", taskID: "ECC-1", subtaskID: "agent"))
    #expect(TmuxController.ownsSession(name: "fq-agent", taskID: "ECC-1", subtaskID: "agent"))
    #expect(TmuxController.ownsSession(name: "fq-task-ecc-1", taskID: "ECC-1", subtaskID: "agent"))
  }

  @Test("Task presentation gives every pane its own top usage border",
    .enabled(if: SetupEnvironment.executable("tmux") != nil
      && SetupEnvironment.executable("node") != nil))
  func taskPresentation() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let node = try #require(SetupEnvironment.executable("node"))
    let server = "fq-presentation-test-" + UUID().uuidString.lowercased()
    let controller = TmuxController(serverName: server)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("fq-presentation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["-L", server, "kill-server"]
      process.standardError = FileHandle.nullDevice
      try? process.run(); process.waitUntilExit()
      try? FileManager.default.removeItem(at: root)
    }
    let context = root.appendingPathComponent("context.json")
    try JSONSerialization.data(withJSONObject: [
      "ticketID":"ECC-035", "title":"Usage task",
      "subtasks":[["id":"agent-one"]],
    ]).write(to: context)
    let renderer = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Scripts/focus_queue_codex_bar.js")
    let reference = try await controller.startAgent(
      taskID: "ECC-035", subtaskID: "agent-one", taskTitle: "Usage task",
      directory: root.path, command: ["/bin/sleep", "30"], executable: executable)

    try await controller.configureTaskPresentation(
      taskID: "ECC-035", taskTitle: "Usage task", contextPath: context.path,
      rendererPath: renderer.path, nodePath: node, usageBarEnabled: true,
      executable: executable)
    let runner = FoundationProcessRunner()
    func output(_ arguments: [String]) async throws -> String {
      let result = try await runner.run(.init(
        executable: executable, arguments: ["-L", server] + arguments,
        environment: ["TMUX_TMPDIR":"/tmp"]))
      #expect(result.succeeded, "\(result.standardError)")
      return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #expect(try await output(["show-options", "-v", "-t", reference.name, "status"]) == "on")
    #expect(try await output(["show-window-options", "-v", "-t", reference.paneID,
      "pane-border-status"]) == "top")
    #expect(try await output(["show-options", "-qv", "-t", reference.name,
      "@focus-queue-task-title"]) == "Usage task")
    let usage = try await output(["show-options", "-qv", "-t", reference.name,
      "@focus-queue-usage-command"])
    #expect(usage.contains(renderer.path))
    #expect(usage.contains(context.path))
    #expect(usage.contains("#{@focus-queue-agent}"))
    #expect(usage.contains("--line 0"))
    #expect(!usage.contains("$FOCUS_QUEUE_USAGE_BAR_PATH"))
    let border = try await output(["show-window-options", "-v", "-t", reference.paneID,
      "pane-border-format"])
    #expect(border.contains("#{@focus-queue-task-title}"))
    #expect(border.contains("#(\(usage))"))
    for line in 1...3 {
      let retired = try await output([
        "show-options", "-v", "-t", reference.name, "status-format[\(line)]"])
      #expect(!retired.contains(renderer.path),
        "The retired session usage row \(line) must fall back to the global default")
    }
    try await controller.configureTaskPresentation(
      taskID: "ECC-035", taskTitle: "Usage task", contextPath: context.path,
      rendererPath: renderer.path, nodePath: node, usageBarEnabled: false,
      executable: executable)
    #expect(try await output(["show-options", "-v", "-t", reference.name, "status"]) == "on")
    #expect(try await output(["show-options", "-qv", "-t", reference.name,
      "@focus-queue-usage-command"]) == "")
    let disabledBorder = try await output(["show-window-options", "-v", "-t", reference.paneID,
      "pane-border-format"])
    #expect(disabledBorder.contains("#{@focus-queue-task-title}"))
    #expect(!disabledBorder.contains("focus_queue_codex_bar.js"))
    try await controller.label(reference, title: "Codex: Agent one")
    let labeledBorder = try await output(["show-window-options", "-v", "-t", reference.paneID,
      "pane-border-format"])
    #expect(labeledBorder.contains("Codex: Agent one"))
    #expect(!labeledBorder.contains("#{@focus-queue-task-title}"),
      "A pane with an agent label must lead with it instead of the task title reference")
  }

  @Test("Live agents share one task session across four-pane window tabs and survive removal",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func liveTaskLayout() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let server = "fq-layout-test-" + UUID().uuidString.lowercased()
    let controller = TmuxController(serverName: server)
    let runner = FoundationProcessRunner()
    let taskID = "TEST-" + UUID().uuidString
    let name = try TmuxController.taskSessionName(taskID: taskID)
    defer {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["-L", server, "kill-server"]
      process.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
      process.standardError = FileHandle.nullDevice
      try? process.run(); process.waitUntilExit()
    }
    func command(_ arguments: [String]) async throws {
      let result = try await runner.run(.init(executable: executable, arguments: ["-L", server] + arguments,
        environment: ["TMUX_TMPDIR": "/tmp"]))
      #expect(result.succeeded, "\(arguments): \(result.standardError)")
    }
    // Real upgrades already have legacy sessions. A bare target is interpreted
    // as a window by list-panes, which used to abort every first task launch.
    try await command(["-f", "/dev/null", "new-session", "-d", "-s", "fq-legacy-agent", "/bin/sleep", "90"])
    #expect(try await controller.panes(name: name, executable: executable).isEmpty)
    var references: [TmuxSessionReference] = []
    for index in 0..<9 {
      references.append(try await controller.startAgent(
        taskID: taskID, subtaskID: "agent-\(index)", taskTitle: "Task banner title",
        directory: "/tmp", command: ["/bin/sleep", "90"], executable: executable))
    }
    #expect(Set(references.map(\.name)) == [name])
    #expect(Set(references.map(\.paneID)).count == 9)
    #expect(try await controller.inspectAgent(taskID: taskID, subtaskID: "agent-8", executable: executable) == references[8])
    #expect(try await controller.verifyAgent(
      references[8], taskID: taskID, subtaskID: "agent-8", executable: executable) == references[8])
    await #expect(throws: TmuxError.self) {
      try await controller.verifyAgent(
        references[8], taskID: taskID, subtaskID: "agent-2", executable: executable)
    }
    await #expect(throws: TmuxError.self) {
      try await controller.verifyAgent(
        references[8], taskID: "ECC-OTHER", subtaskID: "agent-8", executable: executable)
    }
    await #expect(throws: TmuxError.self) {
      try await controller.startAgent(taskID: taskID, subtaskID: "agent-8", directory: "/tmp", command: ["/bin/sleep", "90"], executable: executable)
    }
    var panes = try await controller.panes(name: name, executable: executable)
    try await controller.select(references[8])
    for window in Set(panes.map(\.windowID)) { try await command(["resize-window", "-t", window, "-x", "160", "-y", "50"]) }
    try await controller.reflow(name: name, executable: executable, force: true)
    panes = try await controller.panes(name: name, executable: executable)
    let windowCounts = Dictionary(grouping: panes, by: \.windowID).values.map(\.count).sorted(by: >)
    #expect(Set(panes.map(\.windowID)).count == 3)
    #expect(windowCounts == [4, 4, 1])
    try await command(["set-option", "-t", name, "status-left", "old task padding "])
    try await command(["set-option", "-t", name, "status-right", " old instructions"])
    for window in Set(panes.map(\.windowID)) {
      try await command(["set-window-option", "-t", window, "pane-border-status", "bottom"])
      try await command(["set-window-option", "-t", window, "pane-border-format", " old pane padding "])
    }
    try await controller.reflow(name: name, executable: executable, force: true)
    let plainSession = try await runner.run(.init(executable: executable,
      arguments: ["-L", server, "display-message", "-p", "-t", "=\(name):", "#{status-left}|#{status-right}"],
      environment: ["TMUX_TMPDIR": "/tmp"]))
    #expect(plainSession.succeeded)
    #expect(plainSession.standardOutput.trimmingCharacters(in: .newlines) == "|")
    let plainWindows = try await runner.run(.init(executable: executable,
      arguments: ["-L", server, "list-windows", "-t", "=\(name):", "-F", "#{pane-border-status}"],
      environment: ["TMUX_TMPDIR": "/tmp"]))
    #expect(plainWindows.succeeded)
    #expect(plainWindows.standardOutput.split(separator: "\n").allSatisfy { $0 == "top" })
    let borderFormats = try await runner.run(.init(executable: executable,
      arguments: ["-L", server, "list-windows", "-t", "=\(name):", "-F", "#{pane-border-format}"],
      environment: ["TMUX_TMPDIR": "/tmp"]))
    #expect(borderFormats.succeeded)
    #expect(borderFormats.standardOutput.split(separator: "\n").allSatisfy {
      $0.contains("#{@focus-queue-task-title}")
    })
    let banner = try await runner.run(.init(executable: executable,
      arguments: ["-L", server, "show-options", "-qv", "-t", name, "@focus-queue-task-title"],
      environment: ["TMUX_TMPDIR": "/tmp"]))
    #expect(banner.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == "Task banner title")
    let selected = try await controller.inspect(name: name, executable: executable)
    #expect(selected == references[8])
    for reference in references { #expect(try await controller.verify(reference) == reference) }
    #expect(panes.count == 9)
    #expect(panes.allSatisfy { $0.width > 0 && $0.height > 0 })
    for window in Set(panes.map(\.windowID)) { try await command(["resize-window", "-t", window, "-x", "80", "-y", "24"]) }
    try await controller.reflow(name: name, executable: executable, force: true)
    panes = try await controller.panes(name: name, executable: executable)
    #expect(Dictionary(grouping: panes, by: \.windowID).values.map(\.count).sorted(by: >) == [4, 4, 1])
    try await controller.swap(references[0], with: references[3])
    let manual = try await controller.panes(name: name, executable: executable)
    #expect(manual.allSatisfy { !$0.automatic })
    try await controller.reflow(name: name, executable: executable)
    #expect(try await controller.panes(name: name, executable: executable) == manual)
    try await controller.setAutomatic(name: name, executable: executable, enabled: true)
    try await controller.stop(references[0])
    do {
      _ = try await controller.verify(references[0])
      Issue.record("A pane removed while sibling sessions remain must be reported stopped")
    } catch TmuxError.stopped { }
    for reference in references.dropFirst() { #expect(try await controller.verify(reference) == reference) }
    let remaining = try await controller.panes(name: name, executable: executable)
    #expect(remaining.count == 8)
    #expect(Dictionary(grouping: remaining, by: \.windowID).values.map(\.count).sorted(by: >) == [4, 4])

    var completedAgent = TaskSubtask(
      id: "agent-1", title: "Completed agent", sessionID: UUID().uuidString,
      status: .completed, runtimeMode: .tmux)
    completedAgent.tmux = references[1]
    let context = TaskContext(
      ticketID: taskID, title: "Window tabs", summary: "", successCriteria: "",
      planPath: "/tmp/plan.md", worktreePath: "/tmp", updatedAt: Date())
    let completion = try AgentCompletionMessage(
      context: context, subtask: completedAgent, taskCompleted: false)
    let completionReference = try await controller.finish(
      references[1], subtaskID: completedAgent.id, message: completion)
    #expect(try await controller.verify(completionReference) == completionReference)
    await #expect(throws: TmuxError.self) {
      try await controller.verifyAgent(
        completionReference, taskID: taskID, subtaskID: completedAgent.id,
        executable: executable)
    }
    let afterCompletion = try await controller.panes(name: name, executable: executable)
    let activeAfterCompletion = afterCompletion.filter { !$0.subtaskID.isEmpty }
    #expect(activeAfterCompletion.count == 7)
    #expect(afterCompletion.filter { $0.completedSubtaskID == completedAgent.id }.count == 1)
    #expect(Dictionary(grouping: activeAfterCompletion, by: \.windowID).values.map(\.count).sorted(by: >) == [4, 3])
    #expect(Set(activeAfterCompletion.map(\.windowID)).isDisjoint(
      with: Set(afterCompletion.filter { !$0.completedSubtaskID.isEmpty }.map(\.windowID))))

    let resumed = try await controller.startAgent(
      taskID: taskID, subtaskID: completedAgent.id, directory: "/tmp",
      command: ["/bin/sleep", "90"], executable: executable)
    #expect(resumed.name == name)
    let afterResume = try await controller.panes(name: name, executable: executable)
    #expect(afterResume.filter { !$0.subtaskID.isEmpty }.count == 8)
    #expect(afterResume.allSatisfy { $0.completedSubtaskID != completedAgent.id })
    #expect(Dictionary(grouping: afterResume, by: \.windowID).values.map(\.count).sorted(by: >) == [4, 4])
  }

  @Test("A lost ownership-tag response cannot launch a second agent",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func uncertainLaunch() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let server = "fq-uncertain-test-" + UUID().uuidString.lowercased()
    let taskID = "TEST-" + UUID().uuidString
    let name = try TmuxController.taskSessionName(taskID: taskID)
    let runner = RejectOwnershipTagRunner()
    let controller = TmuxController(runner: runner, serverName: server)
    defer {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["-L", server, "kill-server"]
      process.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
      process.standardError = FileHandle.nullDevice
      try? process.run(); process.waitUntilExit()
    }
    do {
      _ = try await controller.startAgent(taskID: taskID, subtaskID: "agent", directory: "/tmp",
        command: ["/bin/sleep", "90"], executable: executable)
      Issue.record("The dropped tagging response should leave a recoverable launch")
    } catch TmuxError.startedButUnconfirmed { }
    await #expect(throws: TmuxError.self) {
      try await controller.startAgent(taskID: taskID, subtaskID: "agent", directory: "/tmp",
        command: ["/bin/sleep", "90"], executable: executable)
    }
    #expect(try await controller.panes(name: name, executable: executable).count == 1)
    let recovered = try await controller.inspectAgent(taskID: taskID, subtaskID: "agent", executable: executable)
    #expect(try await controller.verify(recovered) == recovered)
  }

  @Test("A task launch joins only an exactly owned session",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func taskSessionOwnership() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let server = "fq-owner-test-" + UUID().uuidString.lowercased()
    let controller = TmuxController(serverName: server)
    let runner = FoundationProcessRunner()
    defer {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["-L", server, "kill-server"]
      process.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
      process.standardError = FileHandle.nullDevice
      try? process.run(); process.waitUntilExit()
    }
    func raw(_ arguments: [String]) async throws {
      let result = try await runner.run(.init(executable: executable,
        arguments: ["-f", "/dev/null", "-L", server] + arguments,
        environment: ["TMUX_TMPDIR": "/tmp"]))
      #expect(result.succeeded, "\(arguments): \(result.standardError)")
    }
    func makeCollision(taskID: String, owner: String?) async throws -> String {
      let name = try TmuxController.taskSessionName(taskID: taskID)
      try await raw(["new-session", "-d", "-s", name, "/bin/sleep", "90"])
      if let owner { try await raw(["set-option", "-t", name, "@focus-queue-task", owner]) }
      return name
    }
    for owner in [nil, "ECC-OTHER"] as [String?] {
      let taskID = "TEST-\(UUID().uuidString)"
      let name = try await makeCollision(taskID: taskID, owner: owner)
      await #expect(throws: TmuxError.self) {
        try await controller.startAgent(taskID: taskID, subtaskID: UUID().uuidString.lowercased(),
          directory: "/tmp", command: ["/bin/sleep", "90"], executable: executable)
      }
      await #expect(throws: TmuxError.self) {
        try await controller.inspectAgent(taskID: taskID, subtaskID: "agent",
          executable: executable)
      }
      #expect(try await controller.panes(name: name, executable: executable).count == 1)
    }
    let ownedTask = "TEST-\(UUID().uuidString)"
    let ownedName = try await makeCollision(taskID: ownedTask, owner: ownedTask.uppercased())
    let reference = try await controller.startAgent(taskID: ownedTask,
      subtaskID: UUID().uuidString.lowercased(), directory: "/tmp",
      command: ["/bin/sleep", "90"], executable: executable)
    #expect(reference.name == ownedName)
    #expect(try await controller.panes(name: ownedName, executable: executable).count == 2)
  }

  @Test("A terminal resize invokes the installed hook and preserves manual layout",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func resizeHook() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let server = "fq-hook-test-" + UUID().uuidString.lowercased()
    let taskID = "TEST-" + UUID().uuidString
    let name = try TmuxController.taskSessionName(taskID: taskID)
    let controller = TmuxController(serverName: server)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fq-hook-#\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var config = SetupEnvironment.starter(supportDirectory: root)
    config.tmuxExecutable = executable
    try JSONEncoder().encode(config).write(to: root.appendingPathComponent("config.json"))
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let installedHelper = sourceRoot.appendingPathComponent(".build/debug/focus-queue-session")
    let helper = root.appendingPathComponent("focus#queue-session")
    try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: installedHelper)
    #expect(FileManager.default.isExecutableFile(atPath: helper.path))
    let first = try await controller.startAgent(taskID: taskID, subtaskID: "one", directory: root.path,
      command: ["/bin/sleep", "90"], executable: executable)
    let second = try await controller.startAgent(taskID: taskID, subtaskID: "two", directory: root.path,
      command: ["/bin/sleep", "90"], executable: executable)
    let input = Pipe()
    let client = Process()
    defer {
      try? input.fileHandleForWriting.close()
      if client.isRunning { client.terminate() }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = ["-L", server, "kill-server"]
      process.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin"]
      process.standardError = FileHandle.nullDevice
      try? process.run(); process.waitUntilExit()
      try? FileManager.default.removeItem(at: root)
    }
    try await controller.configureTask(name: name, executable: executable, helper: helper.path, supportDirectory: root)
    try await controller.checked(executable, ["set-option", "-t", name, "status", "4"])
    client.executableURL = URL(fileURLWithPath: executable)
    client.arguments = ["-L", server, "-C", "attach-session", "-t", "=\(name)"]
    client.environment = ["TMUX_TMPDIR": "/tmp", "PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]
    client.standardInput = input
    client.standardOutput = FileHandle.nullDevice
    client.standardError = FileHandle.nullDevice
    try client.run()
    try input.fileHandleForWriting.write(contentsOf: Data("refresh-client -C 160,51\n".utf8))
    var regrouped = false
    for _ in 0..<80 {
      let panes = try await controller.panes(name: name, executable: executable)
      if Set(panes.map(\.windowID)).count == 1, panes.first?.windowWidth == 160 {
        regrouped = true; break
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(regrouped, "The actual resize hook must invoke the helper and combine panes")
    #expect(try await controller.panes(name: name, executable: executable).allSatisfy { $0.windowHeight == 51 },
      "Control clients have no status display; use their full advertised pane height")
    #expect(try await controller.verify(first) == first)
    #expect(try await controller.verify(second) == second)
    try await controller.checked(executable, ["resize-pane", "-t", first.paneID, "-R", "1"])
    #expect(try await controller.panes(name: name, executable: executable).allSatisfy { !$0.automatic })
  }

  @Test("Pane capacity honors agentsPerWindow and defaults to four")
  func paneCapacityAgentsPerWindow() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(
      "fq-agents-per-window-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let config = base.appendingPathComponent("config.json")

    #expect(TmuxPaneLayout.maximumPanes(supportDirectory: base) == 4,
      "A missing configuration keeps the default of four")

    try Data("{\"agentsPerWindow\": 7}\n".utf8).write(to: config)
    #expect(TmuxPaneLayout.maximumPanes(supportDirectory: base) == 7)

    try Data("{\"agentsPerWindow\": 0}\n".utf8).write(to: config)
    #expect(TmuxPaneLayout.maximumPanes(supportDirectory: base) == 4,
      "Out-of-range values fall back to the default")

    try Data("not json".utf8).write(to: config)
    #expect(TmuxPaneLayout.maximumPanes(supportDirectory: base) == 4,
      "Unreadable configurations fall back to the default")

    var appConfiguration = AppConfiguration.eccDefault()
    appConfiguration.agentsPerWindow = 6
    appConfiguration.placementModel = "claude-sonnet-light"
    appConfiguration.placementConfidenceThreshold = 0.6
    let decoded = try JSONDecoder().decode(
      AppConfiguration.self, from: JSONEncoder().encode(appConfiguration))
    #expect(decoded.agentsPerWindow == 6)
    #expect(decoded.placementModel == "claude-sonnet-light")
    #expect(decoded.placementConfidenceThreshold == 0.6)
  }
}

private actor RejectOwnershipTagRunner: ProcessRunning {
  private let runner = FoundationProcessRunner()
  private var rejected = false
  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    if !rejected, specification.arguments.contains("set-option"), specification.arguments.contains("@focus-queue-agent") {
      rejected = true
      return .init(exitCode: 1, standardOutput: "", standardError: "Simulated lost ownership update", timedOut: true)
    }
    return try await runner.run(specification)
  }
}

private actor MissingTaskSessionRunner: ProcessRunning {
  private(set) var launches = 0
  func run(_ specification: ProcessSpecification) -> ProcessResult {
    if specification.arguments.contains("new-session") || specification.arguments.contains("new-window") {
      launches += 1
      return .init(exitCode: 1, standardOutput: "", standardError: "simulated launch", timedOut: false)
    }
    if specification.arguments.contains("has-session") || specification.arguments.contains("list-panes") {
      return .init(exitCode: 1, standardOutput: "", standardError: "can't find session", timedOut: false)
    }
    return .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
  }
}
