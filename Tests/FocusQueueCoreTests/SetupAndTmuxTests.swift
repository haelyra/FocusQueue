import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Portable setup and persistent terminals")
struct SetupAndTmuxTests {
  @Test("Starter setup is private, portable and preserves an existing dashboard")
  func starterSetup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("setup test \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try SetupEnvironment.createStarterWorkspace(supportDirectory: root)
    let config = SetupEnvironment.starter(supportDirectory: root, home: root)
    #expect(!config.verifier.enabled)
    #expect(config.dailyRoutines.isEmpty)
    #expect(config.dashboardPath.hasPrefix(root.path))
    #expect(!String(decoding: try JSONEncoder().encode(config), as: UTF8.self).contains("hira"))
    let dashboard = URL(fileURLWithPath: config.dashboardPath)
    let original = Data("{\"tickets\":[],\"custom\":\"retained\"}\n".utf8)
    try original.write(to: dashboard)
    try SetupEnvironment.prepareWorkspace(configuration: config)
    #expect(try Data(contentsOf: dashboard) == original)
    try Data("broken json".utf8).write(to: dashboard)
    #expect(throws: (any Error).self) { try SetupEnvironment.prepareWorkspace(configuration: config) }
    #expect(try Data(contentsOf: dashboard) == Data("broken json".utf8))
  }

  @Test("Setup refuses a missing external dashboard and retains legacy configuration")
  func validation() throws {
    var config = AppConfiguration.eccDefault(homeDirectory: URL(fileURLWithPath: "/Users/Second User"))
    let decoded = try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config))
    #expect(decoded.persistentTerminals == nil)
    #expect(decoded.setupCompleted == nil)
    config.workspacePath = FileManager.default.temporaryDirectory.path
    config.dashboardPath = "/missing-external-workspace/dashboard.json"
    #expect(throws: SetupError.self) { try SetupEnvironment.prepareWorkspace(configuration: config) }
  }

  @Test("tmux preserves hostile arguments as data and rejects command targets")
  func arguments() throws {
    let command = ["/bin/echo", "$(touch /tmp/never) ; 'quoted'\nsecond line"]
    let args = try TmuxController.startArguments(name: "fq-test", directory: "/tmp/with spaces", command: command)
    #expect(Array(args.suffix(2)) == command)
    #expect(args.contains("/tmp/with spaces"))
    #expect(args.contains("WEZTERM_PANE"))
    for name in ["-flag", "a:b", "a.b", "a;kill-server", "$(id)", "a\nb", "", String(repeating: "a", count: 81)] {
      #expect(throws: TmuxError.self) { try TmuxController.validateName(name) }
    }
    let ssh = try TmuxController.sshCommand(host: "person@my-mac.tailnet.ts.net", name: "fq-test")
    #expect(ssh.contains("StrictHostKeyChecking=yes"))
    #expect(ssh.contains("ForwardAgent=no"))
    #expect(ssh.contains("\"$HOME/.local/bin/focus-queue-session\" tmux attach fq-test"))
    for host in ["-oProxyCommand=id", "a;id", "a b", "user@host\ncommand", "user@$(id)"] {
      #expect(throws: TmuxError.self) { try TmuxController.sshCommand(host: host, name: "fq-test") }
    }
  }

  @Test("tmux identity survives registration updates and rejects a reused runtime")
  func identity() async throws {
    let output = "fq-test\t123\t1000\t%0\t124\t/dev/ttys099\t0\n"
    let reference = try #require(TmuxController.decode(output, executable: "/usr/local/bin/tmux").first)
    let session = TaskAgentSession(ticketID: "ECC-1", provider: .codex, sessionID: UUID().uuidString,
      tabTitle: "task", workingDirectory: "/tmp", tmux: reference)
    var state = LocalState(agentSessions: [session])
    var updated = session
    updated.tmux = nil
    state.upsertAgentSession(updated)
    #expect(state.agentSessions.first?.tmux == reference)
    #expect(session.canonicalizedForTerminal().tmux == reference)
    #expect(try JSONDecoder().decode(TaskAgentSession.self, from: JSONEncoder().encode(session)).tmux == reference)
    let runner = TmuxFixtureRunner(output: output.replacingOccurrences(of: "1000", with: "2000"))
    await #expect(throws: TmuxError.self) { try await TmuxController(runner: runner).verify(reference) }
    #expect(await runner.calls.count == 1)
    #expect(throws: TmuxError.self) {
      try TmuxController.decode(output.replacingOccurrences(of: "\t0\n", with: "\t1\n"), executable: "/usr/local/bin/tmux")
    }
  }

  @Test("A disposable tmux execution survives a control client disconnect", .enabled(if: SetupEnvironment.executable("tmux") != nil))
  func disconnect() async throws {
    let executable = try #require(SetupEnvironment.executable("tmux"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tmux #{pid} test \(UUID().uuidString);")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let server = "fq-test-\(UUID().uuidString.lowercased())"
    let runner = FoundationProcessRunner()
    let controller = TmuxController(runner: runner, serverName: server)
    let capture = root.appendingPathComponent("arguments.txt")
    let hostile = "$(touch \(root.path)/unwanted) ; 'quotes'\nnext line"
    let reference = try await controller.start(name: "fixture", directory: root.path,
      command: ["/bin/sh", "-c", "[ \"$PWD\" -ef \"$5\" ] || exit 73; printf '%s\\n' \"$1\" \"$3\" \"$4\" > \"$2\"; exec /bin/sleep 30", "fixture", hostile, capture.path, ";", "trailing;", root.path], executable: executable)
    do {
      for _ in 0..<40 {
        if FileManager.default.fileExists(atPath: capture.path) { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(try String(contentsOf: capture, encoding: .utf8) == hostile + "\n;\ntrailing;\n")
      let client = Process()
      client.executableURL = URL(fileURLWithPath: executable)
      client.arguments = ["-L", server, "-C", "attach-session", "-t", "=fixture"]
      client.environment = ["PATH": "/usr/bin:/bin", "TMUX_TMPDIR": "/tmp", "TERM": "xterm-256color"]
      client.standardInput = Pipe()
      client.standardOutput = FileHandle.nullDevice
      client.standardError = FileHandle.nullDevice
      try client.run()
      defer { if client.isRunning { client.terminate() } }
      var attached = false
      for _ in 0..<40 {
        let clients = try await runner.run(.init(executable: executable,
          arguments: ["-L", server, "list-clients", "-F", "#{client_pid}"], environment: ["TMUX_TMPDIR": "/tmp"]))
        if clients.standardOutput.split(separator: "\n").contains(Substring(String(client.processIdentifier))) { attached = true; break }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(attached)
      client.terminate()
      for _ in 0..<40 {
        if !client.isRunning { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(!client.isRunning)
      #expect(try await controller.verify(reference) == reference)

      let reopened = Process()
      reopened.executableURL = URL(fileURLWithPath: executable)
      reopened.arguments = ["-L", server, "-C", "attach-session", "-t", "=fixture"]
      reopened.environment = ["PATH": "/usr/bin:/bin", "TMUX_TMPDIR": "/tmp", "TERM": "xterm-256color"]
      reopened.standardInput = Pipe()
      reopened.standardOutput = FileHandle.nullDevice
      reopened.standardError = FileHandle.nullDevice
      try reopened.run()
      defer { if reopened.isRunning { reopened.terminate() } }
      var reattached = false
      for _ in 0..<40 {
        let clients = try await runner.run(.init(
          executable: executable,
          arguments: ["-L", server, "list-clients", "-F", "#{client_pid}"],
          environment: ["TMUX_TMPDIR": "/tmp"]))
        if clients.standardOutput.split(separator: "\n").contains(
          Substring(String(reopened.processIdentifier))) {
          reattached = true
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(reattached)
      #expect(try await controller.verify(reference) == reference)
      reopened.terminate()
      for _ in 0..<40 {
        if !reopened.isRunning { break }
        try await Task.sleep(for: .milliseconds(25))
      }
      #expect(!reopened.isRunning)

      _ = try await runner.run(.init(executable: executable, arguments: ["-L", server, "kill-server"], environment: ["TMUX_TMPDIR": "/tmp"]))
      await #expect(throws: TmuxError.self) { try await controller.verify(reference) }
    } catch {
      _ = try? await runner.run(.init(executable: executable, arguments: ["-L", server, "kill-server"], environment: ["TMUX_TMPDIR": "/tmp"]))
      throw error
    }
  }

  @Test("A created session with pending pane fields is not reported as a stopped launch")
  func createdButPending() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tmux-pending-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = TmuxSequenceRunner([
      .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
      .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
      .init(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ])
    let controller = TmuxController(
      runner: runner, serverName: "fixture", confirmationAttempts: 2,
      confirmationDelayMilliseconds: 0, requiredStableObservations: 2)
    do {
      _ = try await controller.start(
        name: "fq-pending", directory: root.path,
        command: ["/bin/sleep", "30"], executable: "/mock/tmux")
      Issue.record("A pending runtime must remain distinguishable from a stopped launch")
    } catch let error as TmuxError {
      guard case let .startedButUnconfirmed(name, executable, attempts, detail) = error else {
        Issue.record("Expected created-but-unconfirmed, received \(error)")
        return
      }
      #expect(name == "fq-pending")
      #expect(executable == "/mock/tmux")
      #expect(attempts == 2)
      #expect(detail.contains("no pane record"))
      #expect(!error.localizedDescription.contains("stopped"))
    }
    let calls = await runner.calls
    #expect(calls.filter { $0.arguments.contains("new-session") }.count == 1)
    #expect(calls.filter { $0.arguments.contains("display-message") }.count == 2)
  }
}

private actor TmuxFixtureRunner: ProcessRunning {
  let output: String
  var calls: [ProcessSpecification] = []
  init(output: String) { self.output = output }
  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    calls.append(specification)
    return .init(exitCode: 0, standardOutput: output, standardError: "", timedOut: false)
  }
}

private actor TmuxSequenceRunner: ProcessRunning {
  var results: [ProcessResult]
  var calls: [ProcessSpecification] = []
  init(_ results: [ProcessResult]) { self.results = results }
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    calls.append(specification)
    return results.removeFirst()
  }
}
