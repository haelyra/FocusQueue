import AppKit
import FocusQueueCore
import SwiftUI
import Testing
@testable import ECCFocusQueue

@Suite("Project files panel")
@MainActor
struct ProjectFilesPanelTests {
  @Test("The project files panel and header button render for a project with documents")
  func listsProjectDocuments() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-files \(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = QueueViewModel(paths: AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path]))
    await model.bootstrap()
    await model.bootstrapTail?.value
    let project = try #require(model.activeProjects.first)
    let directory = try model.projectContextStore.ensurePlan(for: project).deletingLastPathComponent()
    try Data("# Practices\n\n- Verify before handoff.\n".utf8).write(to: directory.appendingPathComponent("practices.md"))
    try Data("# Evidence\n".utf8).write(to: directory.appendingPathComponent("evidence.md"))
    try Data(#"{"links":[{"kind":"repository","label":"GitHub repository","url":"https://github.com/o/r"}]}"#.utf8)
      .write(to: directory.appendingPathComponent("context.json"))

    // Documents are listed from disk in reading order; the panel shows exactly these.
    #expect(try model.projectContextStore.documents(projectID: project.id).map(\.kind)
      == [.plan, .practices, .evidence, .context])
    #expect(try model.projectContextStore.links(projectID: project.id).map(\.label) == ["GitHub repository"])
    // Offscreen hosting has no accessibility tree, so these renders are smoke checks.
    // Set FOCUS_QUEUE_RENDER_DIR to write PNG snapshots for visual review.
    let panel = render(ProjectFilesPanel(model: model, rendersPreview: false),
      size: NSSize(width: 780, height: 540), name: "project-files-panel")
    #expect(panel.fittingSize.width > 0)
    let queue = render(QueueView(model: model), size: NSSize(width: 420, height: 700), name: "queue-header")
    #expect(queue.fittingSize.width > 0)
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
