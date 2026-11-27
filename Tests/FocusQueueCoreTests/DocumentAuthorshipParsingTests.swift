import Foundation
import Testing

@testable import FocusQueueCore

@Suite("Document authorship tool-call boundaries")
struct DocumentAuthorshipParsingTests {
  private let document = "/tasks/FOC-1/evidence/report.md"
  private let timestamp = "2026-10-27T10:00:00Z"

  private func scan(_ record: [String: Any], provider: AgentProvider = .claude,
                    options: JSONSerialization.WritingOptions = .withoutEscapingSlashes) throws -> DocumentAuthorship.Touch {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("authorship-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    // Pretty-printing then removing physical newlines produces valid, spaced JSONL.
    let data = try JSONSerialization.data(withJSONObject: record, options: options)
    let line = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
    try Data((line + "\n").utf8).write(to: url)
    return DocumentAuthorship.touches(in: url, needles: [document], provider: provider)
  }

  private func tool(_ name: String, path: String) -> [String: Any] {
    ["type": "tool_use", "name": name, "input": ["file_path": path]]
  }

  private func message(_ content: [[String: Any]]) -> [String: Any] {
    ["type": "assistant", "timestamp": timestamp, "message": ["content": content]]
  }

  @Test("Reading a document and writing another in one message does not claim authorship",
        arguments: [false, true])
  func unrelatedWrite(reverse: Bool) throws {
    let calls = [tool("Read", path: document), tool("Write", path: "/tasks/other.md")]
    let touch = try scan(message(reverse ? Array(calls.reversed()) : calls))
    #expect(touch.firstWrite == nil)
    #expect(touch.toolCalls.count == 1)
  }

  @Test("Text outside a tool call does not supply its document path")
  func siblingTextMention() throws {
    let touch = try scan(message([
      ["type": "text", "text": "I read \(document)"],
      tool("Write", path: "/tasks/other.md"),
    ]))
    #expect(touch.firstWrite == nil)
    #expect(touch.toolCalls.isEmpty)
  }

  @Test("A matching write still wins over other calls in the same message")
  func matchingWrite() throws {
    let touch = try scan(message([
      tool("Read", path: document), tool("Write", path: document),
      tool("Write", path: "/tasks/other.md"),
    ]))
    #expect(touch.firstWrite == ISO8601DateFormatter().date(from: timestamp))
    #expect(touch.toolCalls.count == 1)
  }

  @Test("A write's content cannot claim authorship of a different file it mentions")
  func mentionInsideWrittenContent() throws {
    let touch = try scan(message([
      ["type": "tool_use", "name": "Write",
       "input": ["file_path": "/tasks/other.md", "content": "See \(document)"]],
    ]))
    #expect(touch.firstWrite == nil)
    #expect(touch.toolCalls.isEmpty)
  }

  @Test("Provider records accept JSON whitespace and escaped slashes",
        arguments: [AgentProvider.claude, .codex, .kimi, .copilot], [false, true])
  func serializedRecords(provider: AgentProvider, escaped: Bool) throws {
    let record: [String: Any]
    switch provider {
    case .claude:
      record = message([tool("Write", path: document)])
    case .codex:
      record = ["type": "response_item", "timestamp": timestamp,
                "payload": ["type": "custom_tool_call", "name": "apply_patch",
                            "input": "*** Begin Patch\n*** Add File: \(document)\n+Report\n*** End Patch"]]
    case .kimi:
      record = ["type": "context.append_loop_event", "time": 1_793_131_009_286.0,
                "event": ["type": "tool.call", "name": "WriteFile", "args": ["path": document]]]
    case .copilot:
      record = ["type": "tool.execution_start", "timestamp": timestamp,
                "data": ["toolName": "create", "arguments": ["path": document]]]
    }
    let options: JSONSerialization.WritingOptions = escaped ? [.prettyPrinted] : [.prettyPrinted, .withoutEscapingSlashes]
    let touch = try scan(record, provider: provider, options: options)
    #expect(touch.firstWrite != nil)
    #expect(touch.toolCalls.count == 1)
  }

  @Test("Tool-shaped data inside a result is not an invocation",
        arguments: [AgentProvider.codex, .kimi])
  func resultIsNotInvocation(provider: AgentProvider) throws {
    let fakeCall: [String: Any] = ["type": "custom_tool_call", "name": "apply_patch",
                                  "input": "*** Add File: \(document)"]
    let record: [String: Any]
    if provider == .codex {
      record = ["timestamp": timestamp, "type": "response_item",
                "payload": ["type": "function_call_output", "output": fakeCall]]
    } else {
      record = ["time": 1_793_131_009_286.0, "type": "context.append_loop_event",
                "event": ["type": "tool.result", "output": ["type": "tool.call", "name": "Write", "args": ["path": document]]]]
    }
    let touch = try scan(record, provider: provider)
    #expect(touch.firstWrite == nil)
    #expect(touch.toolCalls.isEmpty)
  }

  @Test("JSON-encoded function arguments retain quoted shell writes")
  func encodedFunctionArguments() throws {
    let arguments = try JSONSerialization.data(withJSONObject: ["cmd": "printf done > \"\(document)\""])
    let touch = try scan([
      "type": "response_item", "timestamp": timestamp,
      "payload": ["type": "function_call", "name": "exec_command",
                  "arguments": String(decoding: arguments, as: UTF8.self)],
    ], provider: .codex)
    #expect(touch.firstWrite == ISO8601DateFormatter().date(from: timestamp))
  }

  @Test("Incomplete tool inputs do not hide a valid sibling call")
  func malformedSiblingCalls() throws {
    let touch = try scan(message([
      ["type": "tool_use", "name": "Write", "input": NSNull()],
      ["type": "tool_use", "input": ["file_path": document]],
      tool("Edit", path: document),
    ]))
    #expect(touch.firstWrite == ISO8601DateFormatter().date(from: timestamp))
    #expect(touch.toolCalls.count == 1)
  }
}
