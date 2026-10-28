import AppKit
import FocusQueueCore
import SwiftUI
import Testing
@testable import ECCFocusQueue

private actor RecordingDocumentAgent: QueueAgentChatting {
  var sessions: [String] = []
  var messages: [String] = []
  func send(message: String, dashboardPath: String, workspace: String, visibleOrder: [String],
            deferredTicketIDs: [String], configuration: VerifierConfiguration,
            model: String?, effort: String?) async throws -> QueueAgentReply {
    sessions.append(configuration.sessionName)
    messages.append(message)
    return QueueAgentReply(message: "Project reply", log: "")
  }
  func reset(configuration: VerifierConfiguration) async throws {}
}

@Suite("Project files and the in-app document viewer")
@MainActor
struct ProjectFilesSectionTests {
  private func bootstrappedModel() async throws -> (QueueViewModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-files \(UUID().uuidString)")
    let model = QueueViewModel(paths: AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path]))
    await model.bootstrap()
    await model.bootstrapTail?.value
    return (model, root)
  }

  @Test("Settings lists project files and opens one in the side viewer with project scope")
  func settingsOpensProjectFiles() async throws {
    let (model, root) = try await bootstrappedModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try #require(model.activeProjects.first)
    let directory = try model.projectContextStore.ensurePlan(for: project).deletingLastPathComponent()
    let architecture = directory.appendingPathComponent("architecture.md")
    try Data("# Architecture\n\n- One shared tmux session per task.\n".utf8).write(to: architecture)
    try Data("Plain notes for the project.\n".utf8).write(to: directory.appendingPathComponent("notes.txt"))

    let section = render(ProjectSettingsSection(model: model), size: NSSize(width: 420, height: 360), name: "settings-project-files")
    #expect(section.fittingSize.width > 0)

    model.openDocumentViewer(architecture, scope: .project(project.id))
    #expect(model.isDocumentViewerPresented && model.isInspectorPresented)
    #expect(model.documentViewerScope == .project(project.id))
    #expect(model.documentViewer.selected == architecture.standardizedFileURL)

    // Another inspector replaces the viewer, and the viewer closes with its last tab.
    model.setQueueChatInspectorPresented(true)
    #expect(!model.isDocumentViewerPresented)
    model.openDocumentViewer(architecture, scope: .project(project.id))
    #expect(!model.isQueueChatInspectorPresented)
    model.closeDocumentViewerTab(architecture.standardizedFileURL)
    #expect(!model.isDocumentViewerPresented && !model.isInspectorPresented)

    let text = directory.appendingPathComponent("notes.txt")
    model.openDocumentViewer(text, scope: .project(project.id))
    let viewer = render(DocumentViewerInspector(model: model), size: NSSize(width: 900, height: 560), name: "document-viewer")
    #expect(viewer.fittingSize.width > 0)
    let queue = render(QueueView(model: model), size: NSSize(width: 420, height: 700), name: "queue-header")
    #expect(queue.fittingSize.width > 0)
  }

  @Test("In-app links keep PDFs, Markdown, and text in Focus Queue and route by owner")
  func linkRouting() async throws {
    let (model, root) = try await bootstrappedModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try #require(model.activeProjects.first)
    let directory = try model.projectContextStore.ensurePlan(for: project).deletingLastPathComponent()
    let pdf = directory.appendingPathComponent("Brief.pdf")
    try Data("%PDF-1.4\n".utf8).write(to: pdf)

    #expect(InAppDocument.fileURL(for: pdf) != nil)
    #expect(InAppDocument.fileURL(for: URL(fileURLWithPath: "/tmp/notes.md:12"))?.path == "/tmp/notes.md")
    #expect(InAppDocument.fileURL(for: URL(fileURLWithPath: "/tmp/run.log")) != nil)
    #expect(InAppDocument.fileURL(for: URL(fileURLWithPath: "/tmp/app.zip")) == nil)
    #expect(InAppDocument.fileURL(for: URL(string: "https://example.com/a.pdf")!) == nil)

    // Editing is gated on the loaded content, not the extension: anything that
    // loads as text is editable; PDFs and rendered pages are not.
    let store = DocumentContentStore()
    let notes = directory.appendingPathComponent("notes.md")
    try Data("editable".utf8).write(to: notes)
    store.ensureLoaded(notes)
    for _ in 0..<200 where store.loadedText(for: notes) == nil {
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.loadedText(for: notes) == "editable")
    #expect(store.loadedText(for: pdf) == nil)

    // A project file with no task opens in the viewer under its own project.
    model.open(pdf.path)
    #expect(model.isDocumentViewerPresented)
    #expect(model.documentViewerScope == .project(project.id))
    #expect(model.documentViewer.selected == pdf.standardizedFileURL)
    #expect(model.documentScope(for: root.appendingPathComponent("tasks/NOPE-1/plan.md")) == .project(
      (model.selectedProject ?? project).id))

    // A link from a task card opens beside that task's plan.
    #expect(await model.createTask(title: "Viewer routing", summary: "Routes links", projectID: project.id))
    let ticket = try #require(model.dashboard.tickets.first { $0.title == "Viewer routing" })
    model.open(pdf.path, ticketID: ticket.id)
    #expect(model.presentedPlanTicketID == ticket.id)
    #expect(model.presentedPlanURL == pdf.standardizedFileURL)
    #expect(!model.isDocumentViewerPresented)
    #expect(model.documentScope(for: root.appendingPathComponent("tasks/\(ticket.id)/evidence.md")) == .task(ticket.id))
  }

  @Test("PDFs load into the native viewer")
  func pdfContent() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let pdf = root.appendingPathComponent("brief.pdf")
    try Data("%PDF-1.4\n".utf8).write(to: pdf)
    guard case .pdf(let url) = try await SideDocumentLoader().load(pdf) else {
      Issue.record("PDF did not load as a PDF document"); return
    }
    #expect(url == pdf)
  }

  @Test("Edits save only over the text they started from, keep permissions, and validate JSON")
  func fileWriter() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("writer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("plan.md")
    try Data("one".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

    try DocumentFileWriter.save("two", to: file, expected: "one")
    #expect(try String(contentsOf: file, encoding: .utf8) == "two")
    #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)

    #expect(throws: DocumentFileWriter.SaveError.self) { try DocumentFileWriter.save("three", to: file, expected: "one") }
    #expect(try String(contentsOf: file, encoding: .utf8) == "two")
    try DocumentFileWriter.save("three", to: file, expected: nil)
    #expect(try String(contentsOf: file, encoding: .utf8) == "three")

    let json = root.appendingPathComponent("context.json")
    try Data("{}".utf8).write(to: json)
    #expect(throws: DocumentFileWriter.SaveError.self) { try DocumentFileWriter.save("{broken", to: json, expected: "{}") }
    #expect(try String(contentsOf: json, encoding: .utf8) == "{}")
  }

  @Test("The settings page lays out every group with one project list")
  func settingsPageRenders() async throws {
    let (model, root) = try await bootstrappedModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let page = render(
      QueueSettingsView(model: model, focusedSection: nil, openSessions: {}, openAnalytics: {}, close: {}),
      size: NSSize(width: 460, height: 4200), name: "settings-page")
    #expect(page.fittingSize.width > 0)
  }

  @Test("Project document chat uses its own session, project context, and storage")
  func projectConversation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-chat-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let project = ProjectDefinition(id: "focus-queue", name: "Focus Queue", dashboardPath: "/tmp/d.json",
      workspacePath: root.path, taskPrefix: "FOC")
    let plan = try ProjectContextStore(root: root).ensurePlan(for: project)
    let document = plan.deletingLastPathComponent().appendingPathComponent("architecture.md")
    try Data("Architecture sentinel".utf8).write(to: document)
    let agent = RecordingDocumentAgent()
    let subject = DocumentConversationSubject(
      kind: .project(project, planPath: plan.path, directory: plan.deletingLastPathComponent()))
    let conversation = DocumentConversation(document: document, subject: subject, support: root, agent: agent,
      configuration: SetupEnvironment.starter(supportDirectory: root).verifier, dashboardPath: "/tmp/d.json",
      workspace: root.path)
    #expect(conversation.taskID == "Focus Queue")
    await conversation.load()
    conversation.draft = "Summarize"
    conversation.send()
    for _ in 0..<200 where conversation.isResponding { try await Task.sleep(for: .milliseconds(10)) }
    #expect(conversation.messages.last?.text == "Project reply")
    let session = try #require(await agent.sessions.first)
    // The harness gives this shape its own session and runtime instead of the shared queue chat.
    #expect(session.hasPrefix("ecc-focus-queue-task-project-focus-queue-document-"))
    var configuration = SetupEnvironment.starter(supportDirectory: root).verifier
    configuration.sessionName = session
    configuration.contextDirectory = plan.deletingLastPathComponent().path
    #expect(!HarnessQueueAgent.documentRuntimeArguments(configuration).isEmpty)
    let prompt = try #require(await agent.messages.first)
    #expect(prompt.contains("Document conversation for project Focus Queue"))
    #expect(prompt.contains(plan.path) && prompt.contains("Architecture sentinel"))
    let stored = plan.deletingLastPathComponent().appendingPathComponent("documents")
    #expect(FileManager.default.fileExists(atPath: stored.path))
  }

  private func render<Content: View>(_ view: Content, size: NSSize, name: String) -> NSHostingView<Content> {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    // Pin light appearance: a transparent capture of dark-mode text is unreadable.
    window.appearance = NSAppearance(named: .aqua)
    window.backgroundColor = .white
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: size)
    window.contentView = hosting
    for _ in 0..<20 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      hosting.layoutSubtreeIfNeeded()
    }
    if let output = ProcessInfo.processInfo.environment["FOCUS_QUEUE_RENDER_DIR"],
       let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      try? bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
    }
    return hosting
  }
}
