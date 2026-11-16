import FocusQueueCore
import Foundation
import Testing
import WebKit

@testable import ECCFocusQueue

/// The project map in the real document-viewer configuration: page scripts off,
/// the app's map script injected into its own content world.
@MainActor
@Suite(.serialized)
struct ProjectMapViewerTests {
  private func demoMap() -> ProjectMap {
    let plan = """
    ## Phase 1 — Build

    - [ ] **1.1. Core.** Task: DEM-1
      Deps: none. Gate: round trip.
    - [ ] **1.2. Storage.** Task: DEM-2
      Deps: 1.1. Gate: assertions pass.

    ## Phase 2 — Harden

    - [ ] **2.1. Freeze.**
      Deps: 1.2. Gate: suite green.
    """
    let tickets = [
      DashboardTicket(id: "DEM-1", title: "Core", status: "resolved", summary: ""),
      DashboardTicket(id: "DEM-2", title: "Storage", status: "in-progress", summary: ""),
    ]
    return ProjectMapBuilder.build(
      projectID: "demo", projectName: "Demo", process: DevelopmentProcess(), tickets: tickets,
      outline: DevelopmentPlanOutline.parse(plan), planFile: "devplan.md", agents: [:])
  }

  private func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out")
  }

  private func run(_ web: WKWebView, _ script: String) async -> String {
    let value = try? await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
    return value.map { "\($0)" } ?? "nil"
  }

  @Test("Phases start collapsed, a phase click expands it, a task click asks the queue to locate it")
  func mapInteractions() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fq-map-viewer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("project-map.html")
    try ProjectMapHTML.render(demoMap()).write(to: file, atomically: true, encoding: .utf8)

    var opened: [URL] = []
    let coordinator = ReadOnlyResourceDocument.Coordinator(open: { opened.append($0) })
    let web = ZoomableWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                              configuration: ReadOnlyResourceDocument.configuration(coordinator: coordinator))
    web.navigationDelegate = coordinator
    defer {
      web.configuration.userContentController.removeScriptMessageHandler(
        forName: ProjectMapScript.messageHandler, contentWorld: .defaultClient)
    }
    #expect(ProjectMapPage.isMap(file))
    web.loadFileURL(file, allowingReadAccessTo: folder)

    // The injected script ran although page scripts are off, and collapsed both phases.
    try await eventually { await run(web, "return document.documentElement.dataset.fqMap || ''") == "ready" }
    try await eventually {
      await run(web, "return document.querySelector('[data-node=\"DEM-1\"]').style.display") == "none"
    }
    #expect(await run(web, "return document.querySelector('[data-node=\"ghost:2.1\"]').style.display") == "none")

    // Clicking Phase 1 expands it with an animation; Phase 2 stays collapsed.
    _ = await run(web, "document.querySelector('[data-kind=\"phase\"]').click(); return 1")
    try await eventually {
      await run(web, "return document.querySelector('[data-node=\"DEM-2\"]').style.display") == ""
    }
    #expect(await run(web, "return document.querySelector('[data-node=\"ghost:2.1\"]').style.display") == "none")
    // Dependency lines carry arrowheads.
    #expect(await run(web, "return getComputedStyle(document.querySelector('line.dep')).markerEnd") .contains("#a"))

    // Clicking a task card reaches the app as a locate request.
    _ = await run(web, "document.querySelector('[data-node=\"DEM-2\"] .title').click(); return 1")
    try await eventually { opened.contains(URL(string: "focusqueue://task/DEM-2")!) }
    #expect(ProjectMapPage.taskID(from: URL(string: "focusqueue://task/dem-2")!) == "DEM-2")
    #expect(ProjectMapPage.taskID(from: URL(string: "focusqueue://task/../etc")!) == nil)
  }
}
