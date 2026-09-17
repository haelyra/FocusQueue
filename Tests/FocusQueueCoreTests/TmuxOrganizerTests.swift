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
    for window in Set(panes.map(\.windowID)) { try await command(["resize-window", "-t", window, "-x", "160", "-y", "50"]) }
    try await controller.reflow(name: name, executable: executable, force: true)
    panes = try await controller.panes(name: name, executable: executable)
    #expect(Set(panes.map(\.windowID)).count == 2)
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
}
