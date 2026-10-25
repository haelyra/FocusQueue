import FocusQueueCore
import Foundation
import Testing
import WebKit

@testable import ECCFocusQueue

@Suite("Native UI Canvas inspector, stage, and editor bridge")
@MainActor
struct UICanvasTests {
  @Test("Typed inspector values are sanitized like ECC's fields.js")
  func fieldSanitizing() throws {
    let size = try #require(UICanvasFields.numeric["font-size"])
    #expect(UICanvasFields.sanitizeNumber("16", size) == .ok(css: "16px", value: 16))
    #expect(UICanvasFields.sanitizeNumber("1.25rem", size).css == "1.25rem")
    #expect(UICanvasFields.sanitizeNumber("2000", size).css == "999px")
    #expect(UICanvasFields.sanitizeNumber("12pt", size) == .error("Use px, rem, em, %"))
    #expect(UICanvasFields.sanitizeNumber("big", size) == .error("Not a number"))
    let opacity = try #require(UICanvasFields.numeric["opacity"])
    #expect(UICanvasFields.sanitizeNumber("50%", opacity).css == "0.5")
    #expect(UICanvasFields.sanitizeNumber("40", opacity).css == "0.4")
    let margin = try #require(UICanvasFields.numeric["margin"])
    #expect(UICanvasFields.sanitizeBoxList("0 auto", margin).css == "0 auto")
    #expect(UICanvasFields.sanitizeBoxList("8, 16", margin).css == "8px 16px")
    let gap = try #require(UICanvasFields.numeric["gap"])
    #expect(UICanvasFields.sanitizeBoxList("1 2 3", gap) == .error("Use at most 2 values"))
    #expect(UICanvasFields.sanitizeCssText("0 1px 2px rgba(0,0,0,.2)").css == "0 1px 2px rgba(0,0,0,.2)")
    #expect(UICanvasFields.sanitizeCssText("red; color: blue") == .error("Remove ; { } < > and comments"))
    #expect(UICanvasFields.sanitizeCssText("url(javascript:alert(1))") == .error("Remove ; { } < > and comments"))
  }

  @Test("Colors parse from computed styles and format back to readable CSS")
  func colors() {
    #expect(UICanvasFields.parseColor("rgb(34, 197, 94)") == UICanvasRGBA(r: 34, g: 197, b: 94, a: 1))
    #expect(UICanvasFields.parseColor("rgba(0, 0, 0, 0)") == UICanvasRGBA(r: 0, g: 0, b: 0, a: 0))
    #expect(UICanvasFields.parseColor("#0f08") == UICanvasRGBA(r: 0, g: 255, b: 0, a: 0.533))
    #expect(UICanvasFields.parseColor("transparent")?.a == 0)
    #expect(UICanvasFields.parseColor("hsl(0 0% 0%)") == nil)
    #expect(UICanvasFields.formatColor(UICanvasRGBA(r: 34, g: 197, b: 94, a: 1)) == "#22c55e")
    #expect(UICanvasFields.formatColor(UICanvasRGBA(r: 0, g: 0, b: 0, a: 0.25)) == "rgba(0, 0, 0, 0.25)")
    #expect(UICanvasFields.borderParts("1px solid rgb(39, 44, 62)").color == "rgb(39, 44, 62)")
    #expect(UICanvasFields.borderParts("none").width == 0)
  }

  @Test("Fixed viewports keep CSS size and only scale down; desktop fills the stage")
  func stageLayout() {
    let desktop = UICanvasStageLayout(available: CGSize(width: 900, height: 600), viewport: nil, isMobile: false)
    #expect(desktop.scale == 1)
    #expect(desktop.frame == CGSize(width: 876, height: 576))
    let mobile = UICanvasStageLayout(available: CGSize(width: 900, height: 600),
                                     viewport: CGSize(width: 393, height: 852), isMobile: true)
    #expect(mobile.scale < 1)
    #expect(mobile.frame.height <= 556)
    #expect(mobile.frame.width == mobile.frame.width.rounded())
    let small = UICanvasStageLayout(available: CGSize(width: 2000, height: 2000),
                                    viewport: CGSize(width: 320, height: 480), isMobile: false)
    #expect(small.scale == 1)
    #expect(small.frame == CGSize(width: 320, height: 480))
  }

  @Test("The stage only ever navigates to its own mockup")
  func navigationPolicy() {
    let artifact = URL(fileURLWithPath: "/tmp/previews/card.html")
    #expect(UICanvasNavigationPolicy.allows(artifact, isMainFrame: true, isLink: false, artifact: artifact))
    #expect(!UICanvasNavigationPolicy.allows(URL(string: "https://example.com")!, isMainFrame: true, isLink: false, artifact: artifact))
    #expect(!UICanvasNavigationPolicy.allows(URL(fileURLWithPath: "/tmp/previews/other.html"), isMainFrame: true, isLink: false, artifact: artifact))
    #expect(!UICanvasNavigationPolicy.allows(artifact, isMainFrame: true, isLink: true, artifact: artifact))
    #expect(UICanvasNavigationPolicy.allows(URL(string: "about:blank")!, isMainFrame: false, isLink: false, artifact: artifact))
  }

  @Test("WebKit runs the editor beside mockup scripts: select, restyle, live reload, chat, and finish")
  func editorBridgeEndToEnd() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-canvas-app-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let mockup = root.appendingPathComponent("card.html")
    func write(_ label: String) throws {
      try Data("""
        <!doctype html><html><head><title>Card</title><style>
        body{margin:0;font-family:sans-serif} #card{padding:24px} #cta{background:#22c55e;color:#fff}
        </style></head><body>
        <article id="card"><h2>Team</h2><button id="cta">\(label)</button></article>
        <script>document.body.dataset.ran = 'yes';</script>
        </body></html>
        """.utf8).write(to: mockup)
    }
    try write("Start trial")
    let store = UICanvasStore(root: root)
    guard case .opened(let session) = try store.open(
      file: mockup.path, taskID: "FOC-070", title: "Card", viewport: "mobile", reopen: false, agentName: "Claude Code")
    else { Issue.record("open refused"); return }

    let model = UICanvasModel(store: store, taskID: "FOC-070", key: session.key)
    #expect(model.preset == "mobile")
    let coordinator = UICanvasWebStage.Coordinator(model: model)
    let layout = UICanvasStageLayout(available: CGSize(width: 260, height: 560),
                                     viewport: model.fixedViewport, isMobile: true)
    #expect(layout.scale < 1)
    let view = WKWebView(frame: CGRect(origin: .zero, size: layout.frame),
                         configuration: UICanvasWebStage.configuration(coordinator: coordinator))
    view.navigationDelegate = coordinator
    view.pageZoom = layout.scale
    defer { UICanvasWebStage.dismantleNSView(view, coordinator: coordinator) }
    model.attach(view)

    // pageZoom turns the half-size frame into an honest 393 CSS px viewport.
    try await eventually { model.renderedViewport.width == 393 }
    #expect((852...854).contains(Int(model.renderedViewport.height)))
    #expect(try await view.evaluateJavaScript("document.body.dataset.ran") as? String == "yes")
    #expect(try await view.evaluateJavaScript("typeof window.__eccUiCanvasHandle") as? String == "undefined",
            "The editor bridge must stay out of the page's script world")

    model.select("#cta")
    try await eventually { model.selection?.selector == "#cta" }
    #expect(model.selection?.editable == true)
    #expect(model.selection?.style("background-color")?.value == "rgb(34, 197, 94)")
    model.setStyle("background-color", "#ff0000")
    try await eventually { model.edits.count == 1 && model.selection?.style("background-color")?.value == "rgb(255, 0, 0)" }
    #expect(model.canUndo)

    // The agent rewrites the file; the reload re-applies the human's pending edit.
    try write("Start free trial")
    model.reloadArtifact()
    try await eventually {
      let text = try? await view.evaluateJavaScript("document.getElementById('cta').textContent") as? String
      let background = try? await view.evaluateJavaScript(
        "getComputedStyle(document.getElementById('cta')).backgroundColor") as? String
      return text == "Start free trial" && background == "rgb(255, 0, 0)"
    }

    model.draft = "Make the button friendlier"
    model.sendChat()
    let queued = try #require(try store.load(taskID: "FOC-070", key: session.key))
    let chat = try #require(queued.pendingFeedback.first)
    #expect(chat.anchor?.selector == "#cta")
    #expect(chat.pendingEdits?.first?.contains("set background-color on #cta") == true)

    await model.sendEdits(finish: true)
    #expect(model.isEnded)
    let result = try store.takeFeedback(taskID: "FOC-070", key: session.key)
    #expect(result.sessionEnded)
    let finish = try #require(result.items.last)
    #expect(finish.kind == "finish")
    #expect(finish.viewport?.preset == "mobile")
    #expect(finish.viewport?.width == 393)
    let exported = try String(contentsOfFile: try #require(finish.exportPath), encoding: .utf8)
    #expect(exported.contains("background-color: rgb(255, 0, 0)"))
    #expect(exported.contains("Start free trial"))
    #expect(!exported.contains("data-ecc-ui-canvas"))
    #expect(exported.contains("document.body.dataset.ran"), "The mockup's own script stays in the export")
  }

  private func eventually(timeout: Duration = .seconds(8), _ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting for the canvas")
    throw CancellationError()
  }
}
