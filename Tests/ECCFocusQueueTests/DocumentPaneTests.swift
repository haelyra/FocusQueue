import Foundation
import Testing
import FocusQueueCore
import FocusQueueMap
@testable import ECCFocusQueue

private actor DocumentTestAgent: QueueAgentChatting {
    var requests: [(String, String)] = []
    var pending: [String: CheckedContinuation<QueueAgentReply, any Error>] = [:]
    func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
              deferredTicketIDs: [String], configuration: VerifierConfiguration,
              model: String?, effort: String?) async throws -> QueueAgentReply {
        requests.append((configuration.sessionName, message))
        return try await withCheckedThrowingContinuation { pending[configuration.sessionName] = $0 }
    }
    func reset(configuration: VerifierConfiguration) async throws {}
    func finish(_ session: String, message: String) { pending.removeValue(forKey: session)?.resume(returning: .init(message: message, log: "")) }
}

private actor RoutingTestAgent: QueueAgentChatting {
    struct Request: Sendable { let message: String; let workspace: String; let configuration: VerifierConfiguration; let model: String?; let effort: String? }
    let provider: AgentProvider
    var requests: [Request] = []
    var resets = 0
    init(provider: AgentProvider) { self.provider = provider }
    func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
              deferredTicketIDs: [String], configuration: VerifierConfiguration,
              model: String?, effort: String?) async throws -> QueueAgentReply {
        requests.append(Request(message: message, workspace: workspace, configuration: configuration, model: model, effort: effort))
        return QueueAgentReply(message: "\(provider.rawValue) reply", log: "")
    }
    func reset(configuration: VerifierConfiguration) async throws { resets += 1 }
}

@MainActor
private final class RoutingTestCreator {
    var liveWorkspace: String? = "/live/agent"
    var isAvailable = true
    var scans = 0
    func resolve(_ known: DocumentAuthor?) -> DocumentChatCreator? {
        guard isAvailable else { return nil }
        if known == nil { scans += 1 }
        let author = known ?? DocumentAuthor(subtaskID: "agent-1", provider: .claude, sessionID: "source-session",
            title: "Draft the report", touchedAt: Date())
        return DocumentChatCreator(author: author, forkSessionID: author.sessionID, liveWorkspace: liveWorkspace,
            savedWorkspace: "/saved/agent", model: "opus", effort: "high")
    }
}

@Suite("Side document pane")
@MainActor
struct DocumentPaneTests {
    @Test("Document tabs persist and restore the central chat on dismissal")
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

    @Test("First file uses the central tab while later files use and can leave the split viewer")
    func primaryAndSecondaryPlacement() {
        let pane = DocumentPaneState()
        let first = URL(fileURLWithPath: "/tmp/evidence.md")
        let second = URL(fileURLWithPath: "/tmp/implementation.swift")

        pane.open(first, in: .primary)
        #expect(pane.primaryDocument == first)
        #expect(pane.secondaryDocument == nil)
        #expect(!pane.hasSecondaryViewer)

        pane.open(second, in: .secondary)
        #expect(pane.primaryDocument == first)
        #expect(pane.secondaryDocument == second)
        #expect(pane.selected == second && pane.hasSecondaryViewer)

        pane.select(second)
        #expect(pane.primaryDocument == second)
        #expect(pane.secondaryDocument == nil)

        // The tab clicked before `second` stays on the left.
        pane.split(second)
        #expect(pane.primaryDocument == first)
        #expect(pane.secondaryDocument == second)
    }

    @Test("A new link restores a split after the only open document was moved right")
    func restoresSplitFromSecondaryDocument() {
        let pane = DocumentPaneState()
        let first = URL(fileURLWithPath: "/tmp/evidence.md")
        let second = URL(fileURLWithPath: "/tmp/implementation.swift")

        pane.open(first, in: .primary)
        pane.split(first)
        #expect(pane.primaryDocument == nil && pane.secondaryDocument == first)

        pane.open(second, in: .secondary)
        #expect(pane.primaryDocument == first)
        #expect(pane.secondaryDocument == second)
        #expect(pane.hasSecondaryViewer)
    }

    @Test("Splitting a tab keeps the document that was open before it on the left")
    func splitRestoresPreviousTab() {
        let pane = DocumentPaneState()
        let a = URL(fileURLWithPath: "/tmp/a.md"), b = URL(fileURLWithPath: "/tmp/b.md"), c = URL(fileURLWithPath: "/tmp/c.md")
        pane.open(a); pane.open(b); pane.open(c)
        pane.select(a); pane.select(b)

        // b is current, a was clicked before it.
        #expect(pane.splitCompanion(for: b) == .document(a))
        #expect(pane.split(b))
        #expect(pane.primaryDocument == a && pane.secondaryDocument == b)

        // Dragging another tab while a split is open keeps the visible left document.
        #expect(pane.splitCompanion(for: c) == .document(a))
        pane.split(c)
        #expect(pane.primaryDocument == a && pane.secondaryDocument == c)

        pane.endSplit()
        #expect(pane.primaryDocument == c && pane.secondaryDocument == nil)
    }

    @Test("Splitting the first tab sits beside the central plan, or the previous tab if it was the last viewed")
    func splitBesideCentralContent() {
        let pane = DocumentPaneState()
        let a = URL(fileURLWithPath: "/tmp/a.md"), b = URL(fileURLWithPath: "/tmp/b.md")
        pane.open(a); pane.open(b)
        pane.showCentralContent()
        pane.select(b)

        // Central content was in front before b, so it stays on the left.
        #expect(pane.splitCompanion(for: b) == .centralContent)
        pane.split(b)
        #expect(pane.primaryDocument == nil && pane.secondaryDocument == b)

        // A viewer with no central content needs a second tab to split against.
        let viewer = DocumentPaneState()
        viewer.open(a)
        #expect(!viewer.canSplit(a, hasCentralContent: false))
        viewer.open(b)
        viewer.select(b)
        #expect(viewer.splitCompanion(for: b, hasCentralContent: false) == .document(a))
        viewer.split(b, hasCentralContent: false)
        #expect(viewer.primaryDocument == a && viewer.secondaryDocument == b)
        #expect(!viewer.canSplit(URL(fileURLWithPath: "/tmp/unknown.md")))
    }

    @Test("Closing the split tab drops it from history so it cannot return on the left")
    func closedTabLeavesHistory() {
        let pane = DocumentPaneState()
        let a = URL(fileURLWithPath: "/tmp/a.md"), b = URL(fileURLWithPath: "/tmp/b.md")
        pane.open(a); pane.open(b); pane.select(a); pane.select(b)
        pane.close(a)
        #expect(pane.splitCompanion(for: b, hasCentralContent: false) == nil)
        #expect(pane.splitCompanion(for: b) == .centralContent)
    }

    @Test("External evidence links share the split routing used by canvas links")
    func externalEvidenceLinksUseSplitRouting() {
        let pane = DocumentPaneState()
        let first = URL(fileURLWithPath: "/tmp/evidence.md")
        let second = URL(fileURLWithPath: "/tmp/implementation.swift")

        pane.openLinkedDocument(first)
        #expect(pane.primaryDocument == first && pane.secondaryDocument == nil)

        pane.openLinkedDocument(second)
        #expect(pane.primaryDocument == first)
        #expect(pane.secondaryDocument == second)
    }

    @Test("Find state opens a shared find field and records direction")
    func findState() {
        let find = DocumentFindState()
        find.activate()
        #expect(find.isPresented && find.request == 1)
        find.query = "sentinel"
        find.find(backwards: true)
        #expect(find.request == 2 && find.searchesBackwards)
        find.dismiss()
        #expect(!find.isPresented)
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
        first.setRecipient(.newAgent); second.setRecipient(.newAgent)
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
    @Test("Document chat forks the running creator, keeps that route, and falls back to a chosen new agent")
    func creatorRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-route-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try await TaskContextStore(root: root).ensureContext(
            ticket: .init(id: "ECC-905", title: "Routing", status: "open", summary: "Routing"))
        let document = root.appendingPathComponent("report.md")
        try Data("Report body".utf8).write(to: document)
        let agents = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, RoutingTestAgent(provider: $0)) })
        let creator = RoutingTestCreator()
        let services = DocumentChatServices(
            agent: { agents[$0]! }, executable: { "/bin/focus-queue-\($0.rawValue)" },
            resolveCreator: { creator.resolve($0) }, modelChoices: { _ in [] })
        func conversation() -> DocumentConversation {
            DocumentConversation(document: document, subject: DocumentConversationSubject(kind: .task(context)),
                support: root, services: services, configuration: SetupEnvironment.starter(supportDirectory: root).verifier,
                dashboardPath: "/dashboard", workspace: root.path, provider: .codex)
        }
        func waitForReply(_ chat: DocumentConversation) async throws {
            for _ in 0..<200 where chat.isResponding { try await Task.sleep(for: .milliseconds(10)) }
        }

        let chat = conversation()
        await chat.load()
        #expect(chat.route.kind == .ephemeralReader && chat.route.model == "gpt-6-luna")
        chat.setRecipient(.creatorFork)
        #expect(chat.route.kind == .creatorFork)
        #expect(chat.route.provider == .claude && chat.route.sourceTitle == "Draft the report")
        chat.draft = "What does section two claim?"
        chat.send()
        try await waitForReply(chat)
        let forked = try #require(await agents[.claude]!.requests.first)
        #expect(forked.configuration.forkSourceSessionID == "source-session")
        #expect(forked.configuration.executable == "/bin/focus-queue-claude")
        #expect(forked.workspace == "/live/agent" && forked.model == "opus")
        #expect(forked.message.hasPrefix(DocumentConversation.forkPreamble))
        #expect(await agents[.claude]!.resets == 1)
        #expect(chat.messages.last?.text == "claude reply")

        // The started conversation keeps its fork even after the creator closes.
        creator.liveWorkspace = nil
        let restored = conversation()
        await restored.load()
        #expect(restored.lockedRoute?.kind == .creatorFork && restored.route.kind == .creatorFork)
        #expect(!restored.canChooseProvider)
        #expect(creator.scans == 2)

        restored.clear()
        for _ in 0..<200 where restored.isClearing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(restored.messages.isEmpty)
        #expect(restored.route.kind == .ephemeralReader && restored.creator?.isOpen == false)

        await restored.reconnectToCreator()
        #expect(restored.route.kind == .creatorFork && restored.route.workspace == "/saved/agent")
        restored.draft = "Reconnect to the author"
        restored.send()
        try await waitForReply(restored)
        let archivedFork = try #require(await agents[.claude]!.requests.last)
        #expect(archivedFork.configuration.forkSourceSessionID == "source-session")
        #expect(archivedFork.workspace == "/saved/agent")

        restored.clear()
        for _ in 0..<200 where restored.isClearing {
            try await Task.sleep(for: .milliseconds(10))
        }
        creator.isAvailable = false
        await restored.reconnectToCreator()
        #expect(restored.route.kind == .ephemeralReader)
        #expect(restored.error == "Could not reconnect to the creating agent. Focus Queue could not find its saved conversation.")

        restored.setRecipient(.newAgent)
        restored.setNewAgentProvider(.kimi)
        restored.setNewAgentModel("kimi-code/k3")
        restored.draft = "Summarize it"
        restored.send()
        try await waitForReply(restored)
        let fresh = try #require(await agents[.kimi]!.requests.first)
        #expect(fresh.configuration.forkSourceSessionID == nil)
        #expect(fresh.model == "kimi-code/k3" && fresh.workspace == root.path)
        #expect(!fresh.message.hasPrefix(DocumentConversation.forkPreamble))
        #expect(restored.lockedRoute?.kind == .newAgent && !restored.canChooseProvider)
        restored.setNewAgentProvider(.codex)
        #expect(restored.route.provider == .kimi)
    }

    @Test("Reader defaults to a small model, includes task sources, and preserves the creator-model option")
    func ephemeralReaderRouting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("document-reader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try await TaskContextStore(root: root).ensureContext(
            ticket: .init(id: "ECC-906", title: "Reader task", status: "open", summary: "Explain the report"))
        let document = root.appendingPathComponent("report.md")
        try Data("Document sentinel: the answer is violet.".utf8).write(to: document)
        try Data("Coding instruction sentinel".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        let agents = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, RoutingTestAgent(provider: $0)) })
        let creator = RoutingTestCreator()
        let services = DocumentChatServices(agent: { agents[$0]! }, executable: { "/mock/\($0.rawValue)" },
            resolveCreator: { creator.resolve($0) }, modelChoices: { _ in [] })
        func conversation() -> DocumentConversation {
            DocumentConversation(document: document, subject: .init(kind: .task(context)), support: root,
                services: services, configuration: SetupEnvironment.starter(supportDirectory: root).verifier,
                dashboardPath: "/dashboard", workspace: root.path, provider: .codex)
        }
        func reply(_ chat: DocumentConversation, _ text: String) async throws {
            chat.draft = text; chat.send()
            for _ in 0..<200 where chat.isResponding { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!chat.isResponding)
        }
        let chat = conversation()
        await chat.load()
        #expect(chat.creator?.isOpen == true)
        #expect(chat.route.kind == .ephemeralReader)
        #expect(chat.route.model == "gpt-6-luna" && chat.route.effort == "low")
        try await reply(chat, "What is the answer?")
        let request = try #require(await agents[.codex]!.requests.first)
        #expect(request.configuration.documentReader == true && request.configuration.forkSourceSessionID == nil)
        #expect(request.model == "gpt-6-luna" && request.effort == "low" && request.workspace == root.path)
        #expect(request.message.hasPrefix(DocumentConversation.readerPreamble))
        #expect(request.message.contains("Document sentinel") && request.message.contains("Explain the report"))
        #expect(request.message.contains(context.planPath) && request.message.contains("Reader task"))
        #expect(!request.message.contains("Coding instruction sentinel"))
        #expect(await agents[.claude]!.requests.isEmpty)
        chat.setRecipient(.creatorFork)
        #expect(chat.route.kind == .ephemeralReader)
        try await reply(chat, "Can you explain that?")
        #expect(await agents[.codex]!.requests.last?.message.contains("codex reply") == true)
        let restored = conversation()
        await restored.load()
        #expect(restored.route.kind == .ephemeralReader && restored.route.model == "gpt-6-luna")
        #expect(restored.messages.count == 4 && !restored.canChooseProvider)

        restored.clear()
        for _ in 0..<200 where restored.isClearing { try await Task.sleep(for: .milliseconds(10)) }
        // The full creator model is also available with a fresh, restricted reader.
        restored.useCreatorModel()
        #expect(restored.route.kind == .ephemeralReader)
        #expect(restored.route.provider == .claude && restored.route.model == "opus")
        try await reply(restored, "Explain with the creator's model")
        let fullModel = try #require(await agents[.claude]!.requests.first)
        #expect(fullModel.model == "opus" && fullModel.effort == "high" && fullModel.configuration.documentReader == true)
        #expect(fullModel.configuration.forkSourceSessionID == nil && fullModel.workspace == root.path)
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
