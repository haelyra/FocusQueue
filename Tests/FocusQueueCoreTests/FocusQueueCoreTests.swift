import Foundation
import Testing

@testable import FocusQueueCore

@Test("Dashboard decoding keeps source-backed progress and open state")
func dashboardDecoding() throws {
  let json = """
    {
      "updatedAt": "2026-08-29",
      "tickets": [
        {
          "id": "ECC-035",
          "title": "Ship Focus Queue",
          "priority": "critical",
          "status": "in-progress",
          "summary": "Build the panel",
          "resolutionPrs": [99],
          "prs": [{"number": 99, "title": "Queue", "url": "https://example.test/99", "state": "OPEN"}],
          "steps": [
            {"id": "plan", "label": "Approve", "status": "done", "evidence": ["/tmp/plan.md"]},
            {"id": "build", "label": "Build", "status": "in-progress", "evidence": []}
          ]
        }
      ]
    }
    """

  let dashboard = try JSONDecoder().decode(DashboardDocument.self, from: Data(json.utf8))
  let ticket = try #require(dashboard.tickets.first)

  #expect(ticket.isOpen)
  #expect(ticket.priorityRank == 0)
  #expect(ticket.progressLabel == "1/2")
  #expect(ticket.prs.first?.isMerged == false)
}

@Test("PR progress is used only when no explicit step ledger exists")
func pullRequestProgress() {
  let ticket = DashboardTicket(
    id: "ECC-100",
    title: "Merge work",
    status: "in-progress",
    summary: "",
    resolutionPrs: [1, 2],
    prs: [
      DashboardPR(number: 1, title: "One", url: "https://example.test/1", state: "MERGED"),
      DashboardPR(number: 2, title: "Two", url: "https://example.test/2", state: "OPEN"),
    ]
  )

  #expect(ticket.progressLabel == "1/2 PRs")
}

@Test("Local state survives a new repository instance")
func localStatePersistence() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let url = root.appendingPathComponent("state.json")
  let request = CompletionRequest(
    ticketID: "ECC-035",
    requestFilePath: root.appendingPathComponent("request.json").path
  )
  let expected = LocalState(
    routineDate: "2026-08-29",
    completedRoutineIDs: ["review-prs"],
    completionRequests: [request],
    window: WindowSnapshot(x: 10, y: 20, width: 420, height: 680, placement: .upperRight),
    appearance: .dark,
    accentStyle: .pastel
  )

  let writer = JSONLocalStateStore(url: url)
  try await writer.save(expected)
  let reader = JSONLocalStateStore(url: url)

  #expect(try await reader.load() == expected)
}

@Test("Existing local state without an appearance remains compatible")
func legacyLocalStateDecoding() throws {
  let data = Data(
    """
    {
      "routineDate": "2026-08-29",
      "completedRoutineIDs": [],
      "completionRequests": []
    }
    """.utf8
  )

  let state = try JSONDecoder().decode(LocalState.self, from: data)
  #expect(state.appearance == nil)
  #expect(state.accentStyle == nil)
}

@Test("VS Code file links resolve to local files")
func vscodeFileLinkResolution() throws {
  let rawValue = "vscode://file/Users/hira/Documents/ECC/release%20approval.pdf"
  let url = try #require(ResourceLocator.url(for: rawValue))

  #expect(url.isFileURL)
  #expect(url.path == "/Users/hira/Documents/ECC/release approval.pdf")
}

@Test("WezTerm matching accepts task subdirectories and prefers the active pane")
func wezTermPaneMatching() {
  let panes = [
    WezTermPane(windowID: 1, paneID: 7, cwd: "file:///Users/hira/project", isActive: false),
    WezTermPane(windowID: 2, paneID: 9, cwd: "file:///Users/hira/project/Sources", isActive: true),
    WezTermPane(windowID: 3, paneID: 11, cwd: "file:///Users/hira/other", isActive: true),
  ]

  let result = WezTermController.bestMatchingPane(in: panes, directory: "/Users/hira/project")
  #expect(result?.paneID == 9)
}

@Test("Config rejects relative source paths")
func configValidation() {
  var config = AppConfiguration.eccDefault(homeDirectory: URL(fileURLWithPath: "/Users/test"))
  config.dashboardPath = "relative/dashboard.json"

  #expect(throws: ConfigurationError.pathsMustBeAbsolute) {
    try config.validated()
  }
}

@Test("Hermes review is bounded, named, and never uses yolo")
func hermesReviewArguments() async throws {
  let runner = MockProcessRunner(results: [
    ProcessResult(
      exitCode: 0, standardOutput: "More evidence is needed.", standardError: "", timedOut: false)
  ])
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("focus-queue-hermes-test-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let request = root.appendingPathComponent("request.json")
  try Data("{}".utf8).write(to: request)

  let verifier = HermesCompletionVerifier(runner: runner)
  let result = try await verifier.verify(
    ticketID: "ECC-035",
    requestFile: request,
    workspace: root.path,
    configuration: VerifierConfiguration(
      enabled: true,
      executable: "/mock/hermes",
      sessionName: "focus-verifier",
      timeoutSeconds: 60,
      maxTurns: 12
    )
  )
  let invocation = try #require(await runner.specifications.first)

  #expect(result.succeeded)
  #expect(invocation.arguments.contains("focus-verifier"))
  #expect(invocation.arguments.contains("--run-budget"))
  #expect(invocation.arguments.contains("--query-file"))
  #expect(!invocation.arguments.contains("--yolo"))
  #expect(!invocation.arguments.contains("--accept-hooks"))
}

@Test("WezTerm controller focuses a matching pane without spawning")
func wezTermFocusArguments() async throws {
  let panes = """
    [{"window_id":4,"pane_id":17,"cwd":"file:///Users/test/project","is_active":true}]
    """
  let runner = MockProcessRunner(results: [
    ProcessResult(exitCode: 0, standardOutput: panes, standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
    ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false),
  ])
  let controller = WezTermController(runner: runner)

  let result = try await controller.focusOrSpawn(
    directory: "/Users/test/project",
    configuration: WezTermConfiguration(executable: "/mock/wezterm")
  )
  let invocations = await runner.specifications

  #expect(result == .focused(paneID: 17))
  #expect(invocations.count == 3)
  #expect(invocations[1].arguments == ["cli", "activate-pane", "--pane-id", "17"])
  #expect(!invocations.flatMap(\.arguments).contains("spawn"))
}

private actor MockProcessRunner: ProcessRunning {
  private var results: [ProcessResult]
  private(set) var specifications: [ProcessSpecification] = []

  init(results: [ProcessResult]) {
    self.results = results
  }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    specifications.append(specification)
    guard !results.isEmpty else {
      return ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
    }
    return results.removeFirst()
  }
}
