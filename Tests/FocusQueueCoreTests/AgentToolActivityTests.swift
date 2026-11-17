import Foundation
import Testing
@testable import FocusQueueCore

@Test("Tool calls classify into rough activities with a short detail")
func toolActivityClassification() {
    func check(_ tool: String, _ input: [String: Any], _ kind: AgentToolActivity.Kind, _ detail: String) {
        let activity = AgentToolActivity.classify(tool: tool, input: input)
        #expect(activity.kind == kind, "\(tool)")
        #expect(activity.detail == detail, "\(tool)")
    }
    check("Read", ["file_path": "/repo/Sources/App/QueueView.swift"], .reading, "App/QueueView.swift")
    check("Grep", ["pattern": "revealMapTask"], .reading, "search revealMapTask")
    check("Edit", ["file_path": "/repo/Sources/Core/ProjectMap.swift"], .editing, "Core/ProjectMap.swift")
    check("Bash", ["command": "swift test --filter Map"], .testing, "swift test --filter Map")
    check("Bash", ["command": "git status --short"], .running, "git status --short")
    check("WebSearch", ["query": "WKWebView magnification"], .researching, "WKWebView magnification")
    check("WebFetch", ["url": "https://developer.apple.com/documentation"], .researching, "developer.apple.com")
    check("Task", ["description": "Survey map code"], .delegating, "Survey map code")
    check("TodoWrite", [:], .planning, "updating its plan")
    check("apply_patch", ["input": "*** Begin Patch\n*** Update File: Sources/App/Map.swift\n@@"], .editing, "App/Map.swift")
    check("SomethingNew", [:], .working, "SomethingNew")
}

@Test("The newest tool call is read from a Claude or Codex transcript tail")
func toolActivityFromTranscripts() throws {
    let claude = [
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/old.swift"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"…"}]}}"#,
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Now editing"},{"type":"tool_use","name":"Edit","input":{"file_path":"/a/b/new.swift"}}]}}"#,
        #"{"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}"#,
    ].joined(separator: "\n")
    #expect(AgentToolActivity.latest(in: Data(claude.utf8), provider: .claude)
            == AgentToolActivity(kind: .editing, detail: "b/new.swift"))

    let codex = [
        #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"pytest -q\"]}"}}"#,
        #"{"type":"response_item","payload":{"type":"message","content":[]}}"#,
    ].joined(separator: "\n")
    #expect(AgentToolActivity.latest(in: Data(codex.utf8), provider: .codex)?.kind == .testing)

    // The tail reader skips a record cut in half at the start of the window.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let padding = String(repeating: #"{"type":"progress"}"# + "\n", count: 8_000)
    try (padding + claude + "\n").write(to: url, atomically: true, encoding: .utf8)
    #expect(AgentToolActivity.read(url: url, provider: .claude)?.detail == "b/new.swift")
    #expect(AgentToolActivity.latest(in: Data("{\"type\":\"user\"}".utf8), provider: .claude) == nil)
}
