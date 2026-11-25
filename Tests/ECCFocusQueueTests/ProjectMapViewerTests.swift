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
  private func demoMap(storageTitle: String = "Storage") -> ProjectMap {
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
      DashboardTicket(id: "DEM-2", title: storageTitle, status: "in-progress", summary: ""),
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

  @Test("Resting on a card for half a second grows it to show its whole title; leaving shrinks it")
  func hoverRevealsFullTitle() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("fq-map-hover-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("project-map.html")
    let long = "Persist every queue snapshot atomically with checksums, rotate old journals, and recover the last good state after a crash mid-write"
    try ProjectMapHTML.render(demoMap(storageTitle: long)).write(to: file, atomically: true, encoding: .utf8)
    let coordinator = ReadOnlyResourceDocument.Coordinator(open: { _ in })
    let web = ZoomableWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 700),
                              configuration: ReadOnlyResourceDocument.configuration(coordinator: coordinator))
    web.navigationDelegate = coordinator
    defer {
      web.configuration.userContentController.removeScriptMessageHandler(
        forName: ProjectMapScript.messageHandler, contentWorld: .defaultClient)
    }
    web.loadFileURL(file, allowingReadAccessTo: folder)
    try await eventually { await run(web, "return document.documentElement.dataset.fqMap || ''") == "ready" }
    _ = await run(web, "document.querySelector('[data-kind=\"phase\"]').click(); return 1")
    _ = await run(web, "document.querySelector('[data-node=\"DEM-1\"]').click(); return 1")
    try await eventually {
      await run(web, "return document.querySelector('[data-node=\"DEM-2\"]').style.display") == ""
    }
    let card = "document.querySelector('[data-node=\"DEM-2\"]')"
    // At rest the title is clamped: its text overflows the two visible lines.
    #expect(await run(web, "const t = \(card).querySelector('.title'); return t.scrollHeight > t.clientHeight") == "1")
    _ = await run(web, "\(card).querySelector('.title').dispatchEvent(new MouseEvent('mouseover', {bubbles: true})); return 1")
    try await Task.sleep(for: .milliseconds(250))
    #expect(await run(web, "return \(card).classList.contains('full')") == "0")
    try await eventually(timeout: .seconds(2)) { await run(web, "return \(card).classList.contains('full')") == "1" }
    #expect(await run(web, "const t = \(card).querySelector('.title'); return t.scrollHeight <= t.clientHeight") == "1")
    #expect(Int(await run(web, "return \(card).offsetHeight")) ?? 0 > 74)
    _ = await run(web, "\(card).dispatchEvent(new MouseEvent('mouseout', {bubbles: true, relatedTarget: document.body})); return 1")
    #expect(await run(web, "return \(card).classList.contains('full')") == "0")
    #expect(Int(await run(web, "return \(card).offsetHeight")) == 74)
  }

  @Test("Milestones and dependents start collapsed, a click expands and zooms, a leaf task click locates it")
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

    // Clicking the first milestone expands it with an animation and zooms in
    // on it; its task's dependents and the second milestone stay collapsed.
    #expect(await run(web, "return document.querySelector('[data-kind=\"phase\"] b').textContent") == "Build")
    let before = web.magnification
    _ = await run(web, "document.querySelector('[data-kind=\"phase\"]').click(); return 1")
    try await eventually {
      await run(web, "return document.querySelector('[data-node=\"DEM-1\"]').style.display") == ""
    }
    #expect(await run(web, "return document.querySelector('[data-node=\"DEM-2\"]').style.display") == "none")
    #expect(await run(web, "return document.querySelector('[data-node=\"ghost:2.1\"]').style.display") == "none")
    #expect(await run(web, "return document.querySelector('[data-node=\"DEM-1\"] .kids').textContent") == "▸ 1")
    try await eventually { abs(web.magnification - before) > 0.01 }
    #expect(ZoomableWebView.focusRange.contains(web.magnification))

    // Clicking a task with dependents opens them instead of locating it.
    _ = await run(web, "document.querySelector('[data-node=\"DEM-1\"] .title').click(); return 1")
    try await eventually {
      await run(web, "return document.querySelector('[data-node=\"DEM-2\"]').style.display") == ""
    }
    #expect(await run(web, "return document.querySelector('[data-node=\"DEM-1\"] .kids').textContent") == "▾ 1")
    #expect(!opened.contains(URL(string: "focusqueue://task/DEM-1")!))
    // Dependency lines carry arrowheads.
    #expect(await run(web, "return getComputedStyle(document.querySelector('line.dep')).markerEnd") .contains("#a"))

    // Clicking a task card reaches the app as a locate request.
    _ = await run(web, "document.querySelector('[data-node=\"DEM-2\"] .title').click(); return 1")
    try await eventually { opened.contains(URL(string: "focusqueue://task/DEM-2")!) }
    // Right-click opens the task menu; a provider choice reaches the app as a launch.
    _ = await run(web, """
      const card = document.querySelector('[data-node="DEM-2"]');
      card.dispatchEvent(new MouseEvent('contextmenu', {bubbles: true, cancelable: true, clientX: 50, clientY: 50}));
      return 1
      """)
    try await eventually { await run(web, "return document.querySelectorAll('.menu button').length") == "5" }
    _ = await run(web, "[...document.querySelectorAll('.menu button')].find(b => b.textContent === 'Launch Codex agent').click(); return 1")
    try await eventually { opened.contains(URL(string: "focusqueue://task/DEM-2?action=launch&provider=codex")!) }
    #expect(await run(web, "return document.querySelectorAll('.menu').length") == "0")

    // Live pushes add one state-colored mark per unfinished agent under the
    // card, the working agent's activity, and phase marks (most urgent first,
    // idle agents left out).
    _ = await run(web, """
      window.fqMapLive({tasks: {"DEM-2": [
          {p: "claude", t: "Builder", s: "working", k: "editing", d: "Core/Map.swift"},
          {p: "codex", t: "Reviewer", s: "idle", a: "Needs approval", ak: "approval"},
          {p: "kimi", t: "Old", s: "blocked", a: "Interrupted", ak: "interrupted"},
          {p: "claude", t: "Spare", s: "idle"},
          {p: "claude", t: "Done", s: "completed"}]},
        defaultProvider: "claude", providers: ["claude", "codex", "kimi"], names: {claude: "Claude"}});
      return 1
      """)
    #expect(await run(web, "return [...document.querySelectorAll('[data-node=\"DEM-2\"] .agents .pv')].map(e => e.className).join(',')")
            == "pv working,pv attention,pv interrupted,pv idle")
    #expect(await run(web, "return document.querySelector('[data-node=\"DEM-2\"] .act').textContent") == "editing Core/Map.swift")
    #expect(await run(web, "return [...document.querySelector('[data-kind=\"phase\"] .live').children].map(e => e.className).join(',')")
            == "pv attention,pv interrupted,pv working")

    #expect(ProjectMapPage.taskID(from: URL(string: "focusqueue://task/dem-2")!) == "DEM-2")
    let launch = ProjectMapPage.request(from: URL(string: "focusqueue://task/DEM-2?action=launch&provider=kimi")!)
    #expect(launch?.action == .launch && launch?.provider == .kimi)
    #expect(ProjectMapPage.request(from: URL(string: "focusqueue://task/DEM-2?action=rm&provider=evil")!)?.action == .locate)
    #expect(ProjectMapPage.taskID(from: URL(string: "focusqueue://task/../etc")!) == nil)
  }
}

@Test("A focus request fits the opened box, or leads with the node when the box is too big")
func focusTargetFits() {
  let view = CGSize(width: 800, height: 600)
  let small = ZoomableWebView.focusTarget(
    box: CGRect(x: 100, y: 200, width: 400, height: 300), node: CGRect(x: 200, y: 200, width: 176, height: 74), viewSize: view)
  #expect(small.magnification == 1.25)   // a small box zooms to the close-up cap
  #expect(small.center == CGPoint(x: 300, y: 350))
  let huge = ZoomableWebView.focusTarget(
    box: CGRect(x: 0, y: 100, width: 5000, height: 3000), node: CGRect(x: 2000, y: 100, width: 200, height: 56), viewSize: view)
  #expect(huge.magnification == 0.5)
  #expect(huge.center.x == 2100)         // centered across on the node
  #expect(abs(huge.center.y - 604) < 0.001)   // the node sits near the top
}
