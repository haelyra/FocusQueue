import Foundation
import Testing
import FocusQueueCore
import FocusQueueMap
@testable import ECCFocusQueue

private actor DocumentTestAgent: QueueAgentChatting {
    var requests: [(String, String)] = []
    var pending: [String: CheckedContinuation<QueueAgentReply, any Error>] = [:]
    func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
              deferredTicketIDs: [String], configuration: VerifierConfiguration) async throws -> QueueAgentReply {
        requests.append((configuration.sessionName, message))
        return try await withCheckedThrowingContinuation { pending[configuration.sessionName] = $0 }
    }
    func finish(_ session: String, message: String) { pending.removeValue(forKey: session)?.resume(returning: .init(message: message, log: "")) }
}

@Suite("Side document pane")
@MainActor
struct DocumentPaneTests {
    @Test("Links reuse a second pane, create tabs, and restore the central chat on dismissal")
    func navigation() {
        let pane = DocumentPaneState(), first = URL(fileURLWithPath: "/tmp/notes.md"), second = URL(fileURLWithPath: "/tmp/code.swift")
        pane.open(first); pane.open(second); pane.open(first)
        #expect(pane.tabs == [first, second])
        #expect(pane.selected == first && pane.centralChatCollapsed)
        pane.dismiss()
        #expect(!pane.isPresented && !pane.centralChatCollapsed)
        #expect(pane.tabs.count == 2)
        pane.open(second); pane.close(second)
        #expect(pane.selected == first)
        pane.close(first)
        #expect(!pane.isPresented && !pane.centralChatCollapsed)
    }

    @Test("Code links and web fragments normalize without accepting executable URLs")
    func URLs() {
        #expect(DocumentPaneLocation.normalized(URL(fileURLWithPath: "/tmp/a file.swift:42"))?.path == "/tmp/a file.swift")
        #expect(DocumentPaneLocation.normalized(URL(string: "https://example.com/guide#section")!)?.absoluteString == "https://example.com/guide")
        #expect(DocumentPaneLocation.normalized(URL(string: "javascript:alert(1)")!) == nil)
        #expect(DocumentPaneLocation.normalized(URL(string: "file://remote/path/doc.md")!) == nil)
        #expect(DocumentPaneLocation.normalized(URL(string: "obsidian://open?path=%2Ftmp%2Fplan.md")!)?.path == "/tmp/plan.md")
        #expect(DocumentPaneLocation.normalized(URL(string: "vscode://file/tmp/main.swift:12")!)?.path == "/tmp/main.swift")
    }

    @Test("Document requests survive hidden panes and receive distinct sessions and task context")
    func independentConversations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-chat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TaskContextStore(root: root)
        var context = try await store.ensureContext(ticket: .init(id: "ECC-901", title: "Task context title", status: "open", summary: "Specific task"))
        context.worktreePath = root.path
        try Data("Instruction sentinel".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let a = root.appendingPathComponent("first.md"), b = root.appendingPathComponent("second.md")
        try Data("First document sentinel".utf8).write(to: a)
        try Data("Second document sentinel".utf8).write(to: b)
        let agent = DocumentTestAgent(), config = SetupEnvironment.starter(supportDirectory: root).verifier
        let first = DocumentConversation(document: a, context: context, support: root, agent: agent, configuration: config, dashboardPath: "/dashboard", workspace: root.path)
        let second = DocumentConversation(document: b, context: context, support: root, agent: agent, configuration: config, dashboardPath: "/dashboard", workspace: root.path)
        await first.load(); await second.load()
        first.draft = "Review first"; first.send()
        second.draft = "Review second"; second.send()
        let pane = DocumentPaneState(); pane.open(a); pane.open(b); pane.dismiss()
        for _ in 0..<200 {
            if await agent.requests.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let requests = await agent.requests
        #expect(requests.count == 2)
        #expect(Set(requests.map { $0.0 }).count == 2)
        #expect(requests.allSatisfy { $0.1.contains("Instruction sentinel") && $0.1.contains(context.planPath) && $0.1.contains("ECC-901") })
        #expect(first.isResponding && second.isResponding)
        for request in requests.reversed() { await agent.finish(request.0, message: request.1.contains("First document sentinel") ? "First reply" : "Second reply") }
        for _ in 0..<200 {
            if !first.isResponding && !second.isResponding { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(first.messages.last?.text == "First reply")
        #expect(second.messages.last?.text == "Second reply")
        let restored = DocumentConversation(document: a, context: context, support: root, agent: agent, configuration: config, dashboardPath: "/dashboard", workspace: root.path)
        await restored.load()
        #expect(restored.messages.map(\.text) == first.messages.map(\.text))
    }
}

@Suite("Map focus and document metadata")
@MainActor
struct MapDocumentMetadataTests {
    @Test("Opening a file keeps the selected agent projection")
    func agentFocus() {
        let model = WorkspaceMapModel()
        let agent = FocusQueueMap.MapNode(id: "agent", parentID: "workspace", kind: .agent, label: "Agent", evidence: "Registration")
        model.select(agent)
        model.select(FocusQueueMap.MapNode(id: "file", parentID: "workspace", kind: .file, label: "Code", evidence: "Scope"))
        #expect(model.mode == .agent && model.options.agentID == "agent")
        model.select(FocusQueueMap.MapNode(id: "context", parentID: "queue", kind: .context, label: "Context", evidence: "Task"))
        #expect(model.mode == .context)
    }
    @Test("Code is plain text and metadata distinguishes local files from remote links")
    func metadata() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("let title = \"<script>hello</script>\"".utf8).write(to: file)
        let metadata = DocumentMetadata.read(file)
        #expect(metadata.exists && metadata.kind == "SWIFT" && metadata.size != nil && metadata.modified != nil)
        let content = try await SideDocumentLoader().load(file)
        if case .text(let value) = content { #expect(value.contains("<script>")) }
        else { Issue.record("Code should be rendered as plain text") }
        #expect(!DocumentMetadata.read(URL(string: "https://example.com/code.swift")!).exists)
        #expect(!DocumentMetadata.read(file.appendingPathExtension("missing")).exists)
    }
}
