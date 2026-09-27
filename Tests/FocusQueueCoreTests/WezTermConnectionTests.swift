import Darwin
import Foundation
import Testing

@testable import FocusQueueCore

private actor ConnectionProbeRunner: ProcessRunning {
  var results: [ProcessResult]
  private(set) var specifications: [ProcessSpecification] = []
  init(_ results: [ProcessResult]) { self.results = results }
  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    specifications.append(specification)
    guard !results.isEmpty else { throw CocoaError(.fileReadUnknown) }
    return results.removeFirst()
  }
}

private final class SocketFixtures {
  let directory: URL
  private var descriptors: [Int32] = []

  init() throws {
    directory = URL(fileURLWithPath: "/tmp/fq-sockets-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  func socket(_ name: String) throws -> String {
    let path = directory.appendingPathComponent(name).path
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    descriptors.append(descriptor)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let bytes = Array(path.utf8) + [0]
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in buffer.copyBytes(from: bytes) }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard result == 0 else { throw POSIXError(.EIO) }
    return path
  }

  deinit {
    for descriptor in descriptors { Darwin.close(descriptor) }
    try? FileManager.default.removeItem(at: directory)
  }
}

@Suite("WezTerm connection recovery")
struct WezTermConnectionTests {
  @Test("Task labels retry until the tmux client attaches")
  func taskLabelsRetryAfterClientAttach() async throws {
    let paneJSON = #"[{"window_id":12,"tab_id":21,"pane_id":41,"cwd":"file:///tmp/worktree","tty_name":"/dev/ttys028"}]"#
    let success = ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
    let runner = ConnectionProbeRunner([
      success,
      ProcessResult(exitCode: 0, standardOutput: "/dev/ttys028\n", standardError: "", timedOut: false),
      ProcessResult(exitCode: 0, standardOutput: paneJSON, standardError: "", timedOut: false),
      success,
      success,
    ])
    let controller = WezTermController(runner: runner, candidateSockets: [], verificationAttempts: 2)
    let reference = TmuxSessionReference(name: "fq-task-ecc-35", serverPID: 10,
      createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys099",
      executable: "/mock/tmux")
    let session = TaskAgentSession(ticketID: "ECC-35", provider: .codex,
      sessionID: UUID().uuidString, tabTitle: "Tracked launch",
      workingDirectory: "/tmp/worktree", subtaskID: UUID().uuidString, tmux: reference)

    try await controller.labelTmuxClients(session: session,
      configuration: .init(executable: "/mock/wezterm"))

    let calls = await runner.specifications
    #expect(calls.filter { $0.arguments.contains("list-clients") }.count == 2)
    #expect(calls.contains { $0.arguments == ["cli", "set-tab-title", "--pane-id", "41", "ECC-35 · tmux"] })
    #expect(calls.contains { $0.arguments == ["cli", "set-window-title", "--pane-id", "41", "ECC-35"] })
  }

  @Test("Task labels prefer the task name when the session carries it")
  func taskLabelsPreferTaskName() async throws {
    let paneJSON = #"[{"window_id":12,"tab_id":21,"pane_id":41,"cwd":"file:///tmp/worktree","tty_name":"/dev/ttys028"}]"#
    let success = ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
    let runner = ConnectionProbeRunner([
      ProcessResult(exitCode: 0, standardOutput: "/dev/ttys028\n", standardError: "", timedOut: false),
      ProcessResult(exitCode: 0, standardOutput: paneJSON, standardError: "", timedOut: false),
      success,
      success,
    ])
    let controller = WezTermController(runner: runner, candidateSockets: [])
    let reference = TmuxSessionReference(name: "fq-task-ecc-35", serverPID: 10,
      createdAt: 20, paneID: "%3", panePID: 30, tty: "/dev/ttys099",
      executable: "/mock/tmux")
    let session = TaskAgentSession(ticketID: "ECC-35", provider: .codex,
      sessionID: UUID().uuidString, tabTitle: "Tracked launch",
      taskTitle: "Ship the  login  redesign",
      workingDirectory: "/tmp/worktree", subtaskID: UUID().uuidString, tmux: reference)

    try await controller.labelTmuxClients(session: session,
      configuration: .init(executable: "/mock/wezterm"))

    let calls = await runner.specifications
    #expect(calls.contains {
      $0.arguments == ["cli", "set-tab-title", "--pane-id", "41", "Ship the login redesign · tmux"] })
    #expect(calls.contains {
      $0.arguments == ["cli", "set-window-title", "--pane-id", "41", "Ship the login redesign"] })
  }

  @Test("Local terminal discovery pins the live GUI connection using read-only probes",
    .enabled(if: ProcessInfo.processInfo.environment["ECC_FOCUS_QUEUE_LOCAL_TRANSPORT_TESTS"] == "1"))
  func localConnectionIdentity() async throws {
    let executable = try #require(SetupEnvironment.executable("wezterm"))
    let connection = try await WezTermConnection.resolve(
      configuration: .init(executable: executable), runner: FoundationProcessRunner())
    #expect(connection.result.succeeded, "\(connection.result.standardError)")
    let socket = try #require(connection.configuration.socketPath)
    #expect(socket.hasPrefix("/"))
    let repeated = try await WezTermConnection.resolve(
      configuration: connection.configuration, runner: FoundationProcessRunner())
    #expect(repeated.result.succeeded)
    #expect(repeated.configuration.socketPath == socket)
  }
  @Test("Installed WezTerm accepts the background mux configuration without opening a GUI",
    .enabled(if: SetupEnvironment.executable("wezterm") != nil))
  func realConfigurationParser() async throws {
    let executable = try #require(SetupEnvironment.executable("wezterm"))
    let arguments = WezTermConnection.revealArguments(configuration:
      .init(executable: executable, socketPath: "/tmp/a'\"\\\n日本.sock"))
    let override = try #require(arguments.first { $0.hasPrefix("unix_domains=") })
    let result = try await FoundationProcessRunner().run(.init(executable: executable,
      arguments: ["-n", "--config", override, "show-keys"], timeoutSeconds: 10))
    #expect(result.succeeded, "\(result.standardError)")
  }
  @Test("GUI reveal preserves socket paths as literal Lua bytes")
  func revealArguments() throws {
    let socket = "/tmp/a'\"\\\n日本.sock"
    let arguments = WezTermConnection.revealArguments(
      configuration: .init(executable: "/mock/wezterm", socketPath: socket))
    let override = try #require(arguments.first { $0.hasPrefix("unix_domains=") })
    #expect(override.contains("no_serve_automatically=true"))
    let encoded = socket.utf8.map { String(format: "\\%03d", Int($0)) }.joined()
    #expect(override.contains("socket_path=\"\(encoded)\""))
    #expect(!override.contains(socket))
    #expect(arguments.suffix(4).first == "connect")
    #expect(WezTermConnection.revealArguments(configuration:
      .init(executable: "/mock/wezterm", socketPath: "/tmp/gui-sock-123")) == ["-a", "WezTerm"])
    #expect(arguments != WezTermConnection.revealArguments(configuration:
      .init(executable: "/mock/wezterm", socketPath: "/tmp/other.sock")))
  }
  private var valid: ProcessResult { .init(exitCode: 0, standardOutput: "[]", standardError: "", timedOut: false) }
  private var failed: ProcessResult { .init(exitCode: 1, standardOutput: "", standardError: "stale socket", timedOut: false) }
  private var timeout: ProcessResult { .init(exitCode: 1, standardOutput: "", standardError: "deadline", timedOut: true) }

  @Test("A working connection is preserved without probing or starting applications")
  func preservesWorkingConnection() async throws {
    let runner = ConnectionProbeRunner([valid])
    let initial = WezTermConfiguration(executable: "/mock/wezterm")
    let result = try await WezTermConnection.resolve(configuration: initial, runner: runner, candidateSockets: [])
    #expect(result.configuration == initial)
    #expect(result.result.succeeded)
    #expect(await runner.specifications.count == 1)
  }

  @Test("Recovery skips malformed pane JSON and retains the responding socket for later CLI calls")
  func recoversExistingSocket() async throws {
    let fixtures = try SocketFixtures()
    let stale = try fixtures.socket("stale")
    let working = try fixtures.socket("working")
    let invalid = ProcessResult(exitCode: 0, standardOutput: "{}", standardError: "", timedOut: false)
    let runner = ConnectionProbeRunner([failed, invalid, valid])
    let result = try await WezTermConnection.resolve(
      configuration: .init(executable: "/mock/wezterm"), runner: runner, candidateSockets: [stale, working])
    #expect(result.configuration.socketPath == working)
    #expect(result.configuration.cliEnvironment?["WEZTERM_UNIX_SOCKET"] == working)
    let calls = await runner.specifications
    #expect(calls.count == 3)
    #expect(calls[1].timeoutSeconds == 2)
    #expect(calls[2].environment?["WEZTERM_UNIX_SOCKET"] == working)
    #expect(calls.allSatisfy { $0.arguments == ["cli", "list", "--format", "json"] })
  }

  @Test("Initial timeout stops discovery and remains visible to prevent duplicate launch")
  func preservesInitialTimeout() async throws {
    let fixtures = try SocketFixtures()
    let path = try fixtures.socket("candidate")
    let runner = ConnectionProbeRunner([timeout])
    let result = try await WezTermConnection.resolve(
      configuration: .init(executable: "/mock/wezterm"), runner: runner, candidateSockets: [path])
    #expect(result.result.timedOut)
    #expect(await runner.specifications.count == 1)
  }

  @Test("Socket probe deadlines remain visible after discovery exhausts candidates")
  func preservesProbeTimeout() async throws {
    let fixtures = try SocketFixtures()
    let path = try fixtures.socket("candidate")
    let runner = ConnectionProbeRunner([failed, timeout])
    let result = try await WezTermConnection.resolve(
      configuration: .init(executable: "/mock/wezterm"), runner: runner, candidateSockets: [path])
    #expect(result.result.timedOut)
    #expect(result.result.standardError.contains("candidate: timed out"))
  }

  @Test("Discovery rejects regular files and symlinks, deduplicates paths, and caps probes at twelve")
  func validatesAndBoundsCandidates() async throws {
    let fixtures = try SocketFixtures()
    let paths = try (0..<13).map { try fixtures.socket("socket-\($0)") }
    let regular = fixtures.directory.appendingPathComponent("regular")
    try Data().write(to: regular)
    let link = fixtures.directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: paths[0])
    let runner = ConnectionProbeRunner(Array(repeating: failed, count: 13))
    let result = try await WezTermConnection.resolve(
      configuration: .init(executable: "/mock/wezterm"), runner: runner,
      candidateSockets: [regular.path, link.path, paths[0]] + paths)
    #expect(!result.result.succeeded)
    let calls = await runner.specifications
    #expect(calls.count == 13)
    #expect(!calls.contains { $0.environment?["WEZTERM_UNIX_SOCKET"] == paths[12] })
    #expect(!calls.contains { $0.environment?["WEZTERM_UNIX_SOCKET"] == link.path })
  }
}
