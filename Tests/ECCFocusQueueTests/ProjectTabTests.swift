import AppKit
import FocusQueueCore
import SwiftUI
import Testing
@testable import ECCFocusQueue

@Suite("Project tab and development process wiring")
@MainActor
struct ProjectTabTests {
  private func bootstrappedModel() async throws -> (QueueViewModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-tab \(UUID().uuidString)")
    let model = QueueViewModel(paths: AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path]))
    await model.bootstrap()
    await model.bootstrapTail?.value
    return (model, root)
  }

  @Test("Enabling the process publishes it, mutations persist, and the tab renders")
  func enableMutateRender() async throws {
    let (model, root) = try await bootstrappedModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try #require(model.selectedProject)

    #expect(model.developmentProcess == nil)
    #expect(!model.developmentProcessEnabled(for: project.id))

    model.setDevelopmentProcessEnabled(true)
    let process = try #require(model.developmentProcess)
    #expect(process.enabled && process.currentPhase == .planning)
    #expect(model.developmentProcessEnabled(for: project.id))

    // The file landed beside the project plan with owner-only permissions.
    let url = try DevelopmentProcessStore(root: root).url(projectID: project.id)
    #expect(FileManager.default.fileExists(atPath: url.path))

    // Step status cycles forward and persists.
    model.setDevelopmentStepStatus(.done, stepID: "concept")
    #expect(model.developmentProcess?.steps["concept"]?.status == .done)

    // Modules enforce sequential acceptance and surface the rejection.
    model.addDevelopmentModule(name: "Auth", file: nil)
    model.addDevelopmentModule(name: "Sync", file: nil)
    let modules = try #require(model.developmentProcess?.modules)
    model.acceptDevelopmentModuleCriteria(moduleID: modules[1].id)
    #expect(model.developmentProcessError?.contains("Auth") == true)
    #expect(model.developmentProcess?.modules[1].criteriaAccepted == false)
    model.acceptDevelopmentModuleCriteria(moduleID: modules[0].id)
    model.acceptDevelopmentModuleCriteria(moduleID: modules[1].id)
    #expect(model.developmentProcess?.modules[1].criteriaAccepted == true)
    #expect(model.developmentProcessError == nil)

    // QA requires implementation first in the UI; the flags persist on disk.
    model.setDevelopmentModuleImplemented(true, moduleID: modules[0].id)
    model.setDevelopmentModuleQAAccepted(true, moduleID: modules[0].id)
    let reloaded = try DevelopmentProcessStore(root: root).load(projectID: project.id)
    #expect(reloaded?.modules[0].qaAccepted == true)

    // Phase moves persist.
    model.setDevelopmentPhase(.phase0)
    #expect(model.developmentProcess?.currentPhase == .phase0)

    // Step documents render as clickable chips: reviewed, present, missing.
    model.setDevelopmentPhase(.planning)
    let projectDirectory = try DevelopmentProcessStore(root: root).url(projectID: project.id)
      .deletingLastPathComponent()
    for name in ["concept.md", "research.md"] {
      try Data("# \(name)\n".utf8).write(to: projectDirectory.appendingPathComponent(name))
    }
    model.setDevelopmentArtifactChecked(true, review: try #require({
      model.openDocumentViewer(projectDirectory.appendingPathComponent("concept.md"),
                               scope: .project(project.id))
      return model.developmentArtifactReview(
        for: projectDirectory.appendingPathComponent("concept.md"))
    }()))
    model.closeDocumentViewer()
    #expect(model.developmentProcess?.steps["concept"]?.status == .done)

    // The tab and the settings row render.
    let tab = render(ProjectTabView(model: model), size: NSSize(width: 420, height: 700), name: "project-tab")
    #expect(tab.fittingSize.width > 0)
    let row = render(DevelopmentProcessSettingsRow(model: model, projectID: project.id),
                     size: NSSize(width: 420, height: 80), name: "project-process-settings")
    #expect(row.fittingSize.width > 0)

    // Disabling hides it from the tab but keeps the file.
    model.setDevelopmentProcessEnabled(false)
    #expect(model.developmentProcess == nil)
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try DevelopmentProcessStore(root: root).load(projectID: project.id)?.enabled == false)
  }

  @Test("The viewer offers a review toggle for step artifacts and check-off completes the step")
  func artifactReviewFlow() async throws {
    let (model, root) = try await bootstrappedModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let project = try #require(model.selectedProject)
    model.setDevelopmentProcessEnabled(true)
    let directory = try DevelopmentProcessStore(root: root).url(projectID: project.id)
      .deletingLastPathComponent()
    let prd = directory.appendingPathComponent("prd.md")
    try Data("# PRD\n".utf8).write(to: prd)

    // Only the matching document inside the project folder gets a toggle.
    model.openDocumentViewer(prd, scope: .project(project.id))
    let review = try #require(model.developmentArtifactReview(for: prd))
    #expect(review.stepID == "prd" && review.artifact == "prd.md" && !review.checked)
    let outsider = root.appendingPathComponent("prd.md")
    try Data("# unrelated\n".utf8).write(to: outsider)
    #expect(model.developmentArtifactReview(for: outsider) == nil)
    #expect(model.developmentArtifactReview(
      for: directory.appendingPathComponent("plan.md")) == nil)

    // Checking the only document of the step marks the step done.
    model.setDevelopmentArtifactChecked(true, review: review)
    #expect(model.developmentProcess?.steps["prd"]?.checkedArtifacts == ["prd.md"])
    #expect(model.developmentProcess?.steps["prd"]?.status == .done)
    #expect(model.developmentArtifactReview(for: prd)?.checked == true)

    // Task-scoped viewing never offers the toggle.
    model.openDocumentViewer(prd, scope: .task("FOC-1"))
    #expect(model.developmentArtifactReview(for: prd) == nil)

    // The viewer renders with the review toggle for the artifact.
    model.openDocumentViewer(prd, scope: .project(project.id))
    let inspector = render(DocumentViewerInspector(model: model),
                           size: NSSize(width: 900, height: 500), name: "document-viewer-review")
    #expect(inspector.fittingSize.width > 0)
  }

  @Test("QueueView renders with the project button beside the title")
  func queueChromeRenders() async throws {
    let (model, root) = try await bootstrappedModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let queue = render(QueueView(model: model), size: NSSize(width: 420, height: 700), name: "queue-with-project-button")
    #expect(queue.fittingSize.width > 0)
  }

  private func render<Content: View>(_ view: Content, size: NSSize, name: String) -> NSHostingView<Content> {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
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
