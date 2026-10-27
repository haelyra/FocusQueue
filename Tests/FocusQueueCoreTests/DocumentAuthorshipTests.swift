import Foundation
import Testing

@testable import FocusQueueCore

private func transcript(_ lines: [[String: Any]], in root: URL, name: String) throws -> URL {
  let url = root.appendingPathComponent(name)
  let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: .withoutEscapingSlashes), as: UTF8.self) }
    .joined(separator: "\n") + "\n"
  try Data(text.utf8).write(to: url)
  return url
}

private func claudeToolUse(_ name: String, path: String, at timestamp: String) -> [String: Any] {
  ["type": "assistant", "timestamp": timestamp,
   "message": ["content": [["type": "tool_use", "name": name, "input": ["file_path": path]]]]]
}

private func agent(_ id: String, _ provider: AgentProvider, workspace: String? = nil) -> TaskSubtask {
  var subtask = TaskSubtask(id: id, title: "Agent \(id)", provider: provider, sessionID: "session-\(id)")
  if let workspace { subtask.workspace = AgentWorkspace(path: workspace, repositoryPath: workspace) }
  return subtask
}

@Suite("Document authorship from agent transcripts")
struct DocumentAuthorshipTests {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("authorship-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  @Test("A write tool call outranks an earlier read by another agent")
  func writeBeatsEarlierRead() throws {
    let document = "/tasks/FOC-1/evidence/report.md"
    let writer = try transcript([
      claudeToolUse("Write", path: document, at: "2026-10-27T10:05:00.000Z"),
    ], in: root, name: "writer.jsonl")
    let reader = try transcript([
      ["timestamp": "2026-10-27T10:00:00.000Z", "type": "response_item",
       "payload": ["type": "function_call", "name": "exec_command", "arguments": "{\"cmd\":\"cat \(document)\"}"]],
    ], in: root, name: "reader.jsonl")
    let author = DocumentAuthorship.author(of: document, agents: [
      (agent("reader", .codex), reader), (agent("writer", .claude), writer),
    ])
    #expect(author?.subtaskID == "writer")
    #expect(author?.provider == .claude)
    #expect(author?.sessionID == "session-writer")
  }

  @Test("Among writers the earliest wins; Codex relative patches and Kimi records count")
  func earliestWriterAcrossProviders() throws {
    let workspace = "/repo/.worktrees/agent"
    let document = workspace + "/Docs/plan.md"
    let codex = try transcript([
      ["timestamp": "2026-10-27T09:00:00Z", "type": "response_item",
       "payload": ["type": "custom_tool_call", "name": "apply_patch",
                   "input": "*** Begin Patch\n*** Add File: Docs/plan.md\n+# Plan\n*** End Patch"]],
    ], in: root, name: "codex.jsonl")
    let kimi = try transcript([
      ["type": "context.append_loop_event", "time": 1_793_131_009_286.0,
       "event": ["type": "tool.call", "name": "Edit", "args": ["path": document]]],
    ], in: root, name: "kimi.jsonl")
    let author = DocumentAuthorship.author(of: document, agents: [
      (agent("kimi", .kimi), kimi), (agent("codex", .codex, workspace: workspace), codex),
    ])
    #expect(author?.subtaskID == "codex")

    let kimiOnly = DocumentAuthorship.touches(in: kimi, needles: [document], provider: .kimi)
    #expect(kimiOnly.firstWrite == Date(timeIntervalSince1970: 1_793_131_009.286))
  }

  @Test("Reading a file never makes an author; a shell redirect or a creating command does")
  func readsAreNotAuthorship() throws {
    let document = "/tasks/FOC-1/evidence/report.md"
    func bash(_ command: String, at timestamp: String) -> [String: Any] {
      ["type": "assistant", "timestamp": timestamp,
       "message": ["content": [["type": "tool_use", "name": "Bash", "input": ["command": command]]]]]
    }
    let reader = try transcript([bash("cat \(document)", at: "2026-10-27T11:00:00Z")], in: root, name: "cat.jsonl")
    let created = ISO8601DateFormatter().date(from: "2026-10-27T10:00:30Z")!
    #expect(DocumentAuthorship.author(of: document, agents: [(agent("r", .claude), reader)], createdAt: created) == nil)

    let redirect = try transcript([bash("printf done > \"\(document)\"", at: "2026-10-27T11:00:00Z")],
      in: root, name: "redirect.jsonl")
    #expect(DocumentAuthorship.author(of: document, agents: [(agent("w", .claude), redirect)])?.subtaskID == "w")

    let generator = try transcript([bash("python3 render.py --report \(document)", at: "2026-10-27T10:00:00Z")],
      in: root, name: "generator.jsonl")
    #expect(DocumentAuthorship.author(of: document, agents: [(agent("g", .claude), generator)], createdAt: created)?
      .subtaskID == "g")
    #expect(DocumentAuthorship.author(of: document, agents: [(agent("g", .claude), generator)]) == nil)
  }

  @Test("A path mentioned outside a tool call names no author")
  func mentionsAreNotAuthorship() throws {
    let document = "/tasks/FOC-1/evidence/report.md"
    let mention = try transcript([
      ["type": "user", "timestamp": "2026-10-27T10:00:00Z",
       "message": ["content": "Please look at \(document)"]],
      ["type": "assistant", "timestamp": "2026-10-27T10:01:00Z",
       "message": ["content": [["type": "text", "text": "I will read \(document)."]]]],
    ], in: root, name: "mention.jsonl")
    #expect(DocumentAuthorship.author(of: document, agents: [(agent("a", .claude), mention)]) == nil)
  }
}

private actor PromptCapturingRunner: ProcessRunning {
  private(set) var arguments: [String] = []
  private(set) var prompt = ""

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    arguments = specification.arguments
    if let index = specification.arguments.firstIndex(of: "--prompt-file") {
      prompt = try String(contentsOfFile: specification.arguments[index + 1], encoding: .utf8)
    }
    return ProcessResult(exitCode: 0, standardOutput: "reply", standardError: "", timedOut: false)
  }
}

@Test("A forked document chat passes its source session and keeps the agent's own identity")
func forkedHarnessTurn() async throws {
  var configuration = VerifierConfiguration(
    enabled: true, executable: "/usr/bin/focus-queue-claude",
    sessionName: "ecc-focus-queue-task-foc-1-document-0123456789abcdef")
  configuration.forkSourceSessionID = "source-session"
  let runner = PromptCapturingRunner()
  _ = try await HarnessQueueAgent(provider: .claude, runner: runner).send(
    message: "Document question", dashboardPath: "/dashboard", workspace: "/workspace",
    visibleOrder: [], deferredTicketIDs: [], configuration: configuration, model: nil, effort: nil)
  let arguments = await runner.arguments
  let fork = try #require(arguments.firstIndex(of: "--fork-from"))
  #expect(arguments[fork + 1] == "source-session")
  #expect(!arguments.contains("--fresh"))
  #expect(await runner.prompt == "Document question")

  configuration.forkSourceSessionID = nil
  _ = try await HarnessQueueAgent(provider: .claude, runner: runner).send(
    message: "Document question", dashboardPath: "/dashboard", workspace: "/workspace",
    visibleOrder: [], deferredTicketIDs: [], configuration: configuration, model: nil, effort: nil)
  #expect(!(await runner.arguments).contains("--fork-from"))
  #expect((await runner.arguments).contains("--fresh"))
  #expect(await runner.prompt.hasPrefix("You are the Claude Queue agent"))
}
