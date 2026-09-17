import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Task tmux organizer")
struct TmuxOrganizerTests {
  @Test("Pane capacity follows terminal cells and caps visual load")
  func capacity() throws {
    #expect(TmuxPaneLayout.capacity(width: 80, height: 24) == 1)
    #expect(TmuxPaneLayout.capacity(width: 160, height: 30) == 2)
    #expect(TmuxPaneLayout.capacity(width: 90, height: 60) == 2)
    #expect(TmuxPaneLayout.capacity(width: 240, height: 60) == 4)
    #expect(TmuxPaneLayout.capacity(width: 500, height: 200) == 4)
    #expect(TmuxPaneLayout.groups(Array(0..<9), width: 160, height: 50).map(\.count) == [4, 4, 1])
    #expect(throws: TmuxError.self) { try TmuxPaneLayout.layout(paneIDs: ["%0", "%1"], width: 80, height: 24) }
  }

  @Test("Malformed layouts and cross-task identities fail closed")
  func malformed() throws {
    #expect(throws: TmuxError.self) { try TmuxPaneLayout.layout(paneIDs: ["%1; kill-server"], width: 80, height: 24) }
    #expect(throws: TmuxError.self) { try TmuxController.taskSessionName(taskID: "ECC-1:other") }
    #expect(!TmuxController.ownsSession(name: "fq-task-ecc-2", taskID: "ECC-1", subtaskID: "agent"))
    #expect(TmuxController.ownsSession(name: "fq-agent", taskID: "ECC-1", subtaskID: "agent"))
    #expect(TmuxController.ownsSession(name: "fq-task-ecc-1", taskID: "ECC-1", subtaskID: "agent"))
  }

  @Test("Live panes survive reflow, overflow, manual swaps and neighbor cleanup",
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
    var references: [TmuxSessionReference] = []
    for index in 0..<5 {
      references.append(try await controller.startAgent(taskID: taskID, subtaskID: "agent-\(index)",
        directory: "/tmp", command: ["/bin/sleep", "90"], executable: executable))
    }
    #expect(Set(references.map(\.name)) == [name])
    #expect(Set(references.map(\.paneID)).count == 5)
    #expect(try await controller.inspectAgent(taskID: taskID, subtaskID: "agent-3", executable: executable) == references[3])
    await #expect(throws: TmuxError.self) {
      try await controller.startAgent(taskID: taskID, subtaskID: "agent-3", directory: "/tmp", command: ["/bin/sleep", "90"], executable: executable)
    }
    var panes = try await controller.panes(name: name, executable: executable)
    try await controller.select(references[3])
    for window in Set(panes.map(\.windowID)) { try await command(["resize-window", "-t", window, "-x", "160", "-y", "50"]) }
    try await controller.reflow(name: name, executable: executable, force: true)
    panes = try await controller.panes(name: name, executable: executable)
    #expect(Set(panes.map(\.windowID)).count == 2)
    let selected = try await controller.inspect(name: name, executable: executable)
    #expect(selected == references[3])
    for reference in references { #expect(try await controller.verify(reference) == reference) }
    let four = Dictionary(grouping: panes, by: \.windowID).values.first(where: { $0.count == 4 })
    #expect(four?.allSatisfy { $0.width >= 72 && $0.height >= 20 } == true)
    for window in Set(panes.map(\.windowID)) { try await command(["resize-window", "-t", window, "-x", "80", "-y", "24"]) }
    try await controller.reflow(name: name, executable: executable, force: true)
    panes = try await controller.panes(name: name, executable: executable)
    #expect(Set(panes.map(\.windowID)).count == 5)
    try await controller.swap(references[0], with: references[4])
    let manual = try await controller.panes(name: name, executable: executable)
    #expect(manual.allSatisfy { !$0.automatic })
    try await controller.reflow(name: name, executable: executable)
    #expect(try await controller.panes(name: name, executable: executable) == manual)
    try await controller.stop(references[0])
    for reference in references.dropFirst() { #expect(try await controller.verify(reference) == reference) }
    #expect(try await controller.panes(name: name, executable: executable).count == 4)
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

  @Test("A terminal resize invokes the installed hook and preserves manual layout",
    .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func resizeHook() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let server = "fq-hook-test-" + UUID().uuidString.lowercased()
    let taskID = "TEST-" + UUID().uuidString
    let name = try TmuxController.taskSessionName(taskID: taskID)
    let controller = TmuxController(serverName: server)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("fq-hook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var config = SetupEnvironment.starter(supportDirectory: root)
    config.tmuxExecutable = executable
    try JSONEncoder().encode(config).write(to: root.appendingPathComponent("config.json"))
    let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = sourceRoot.appendingPathComponent(".build/debug/focus-queue-session").path
    #expect(FileManager.default.isExecutableFile(atPath: helper))
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
    try await controller.configureTask(name: name, executable: executable, helper: helper, supportDirectory: root)
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
    #expect(try await controller.verify(first) == first)
    #expect(try await controller.verify(second) == second)
    try await controller.checked(executable, ["resize-pane", "-t", first.paneID, "-R", "1"])
    #expect(try await controller.panes(name: name, executable: executable).allSatisfy { !$0.automatic })
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
