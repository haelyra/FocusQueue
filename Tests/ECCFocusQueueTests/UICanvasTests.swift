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

  @Test("Shadows parse into per-layer controls and format back to CSS")
  func shadows() throws {
    let computed = try #require(UICanvasFields.parseShadows("rgba(0, 0, 0, 0.08) 0px 8px 28px 0px"))
    #expect(computed == [UICanvasShadow(x: 0, y: 8, blur: 28, spread: 0, color: "rgba(0, 0, 0, 0.08)", inset: false)])
    let layered = try #require(UICanvasFields.parseShadows("inset 0 1px 2px #fff, 2px 4px rgba(10, 20, 30, .5)"))
    #expect(layered.count == 2 && layered[0].inset && layered[0].color == "#ffffff")
    #expect(layered[1].blur == 0 && layered[1].color == "rgba(10, 20, 30, 0.5)")
    #expect(UICanvasFields.formatShadows(layered) == "inset 0 1px 2px 0 #ffffff, 2px 4px 0 0 rgba(10, 20, 30, 0.5)")
    #expect(UICanvasFields.parseShadows("none") == [])
    #expect(UICanvasFields.formatShadows([]) == "none")
    #expect(UICanvasFields.parseShadows("0 1em 2em black") == nil, "em lengths stay as text")
    #expect(UICanvasFields.parseShadows("var(--shadow)") == nil)
  }

  @Test("Linear gradients parse into an angle and stops; other images stay text")
  func gradients() throws {
    let computed = try #require(UICanvasFields.parseGradient("linear-gradient(135deg, rgb(255, 0, 0), rgb(0, 0, 255) 80%)"))
    #expect(computed.angle == 135)
    #expect(computed.stops == [.init(color: "#ff0000", position: nil), .init(color: "#0000ff", position: "80%")])
    #expect(UICanvasFields.formatGradient(computed) == "linear-gradient(135deg, #ff0000, #0000ff 80%)")
    #expect(UICanvasFields.parseGradient("linear-gradient(to right, #fff, #000)")?.angle == 90)
    #expect(UICanvasFields.parseGradient("linear-gradient(0.5turn, #fff, #000)")?.angle == 180)
    #expect(UICanvasFields.parseGradient("linear-gradient(#fff, #000)")?.angle == 180)
    #expect(UICanvasFields.parseGradient("url(\"a.png\")") == nil)
    #expect(UICanvasFields.parseGradient("radial-gradient(#fff, #000)") == nil)
    #expect(UICanvasFields.parseGradient("linear-gradient(#fff, #000), url(a.png)") == nil)
    #expect(UICanvasFields.parseGradient("linear-gradient(90deg, #fff)") == nil)
  }

  @Test("Box shorthands expand per side and compose back to the shortest form")
  func boxSides() {
    #expect(UICanvasFields.boxSides("8px", count: 4) == ["8px", "8px", "8px", "8px"])
    #expect(UICanvasFields.boxSides("8px 16px", count: 4) == ["8px", "16px", "8px", "16px"])
    #expect(UICanvasFields.boxSides("1px 2px 3px", count: 4) == ["1px", "2px", "3px", "2px"])
    #expect(UICanvasFields.boxSides("4px 8px", count: 2) == ["4px", "8px"])
    #expect(UICanvasFields.boxSides("1px 2px 3px", count: 2) == nil)
    #expect(UICanvasFields.composeBox(["8px", "8px", "8px", "8px"]) == "8px")
    #expect(UICanvasFields.composeBox(["8px", "16px", "8px", "16px"]) == "8px 16px")
    #expect(UICanvasFields.composeBox(["1px", "2px", "3px", "2px"]) == "1px 2px 3px")
    #expect(UICanvasFields.composeBox(["1px", "2px", "3px", "4px"]) == "1px 2px 3px 4px")
    #expect(UICanvasFields.composeBox(["4px", "8px"]) == "4px 8px")
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

    // CSS from the structured controls is what WebKit computes back.
    model.setStyle("box-shadow", UICanvasFields.formatShadows([UICanvasShadow(x: 2, y: 6, blur: 18, spread: -2, color: "rgba(0, 0, 0, 0.25)")]))
    try await eventually { model.selection?.style("box-shadow")?.value == "rgba(0, 0, 0, 0.25) 2px 6px 18px -2px" }
    let shadowCSS = try #require(model.selection?.style("box-shadow")?.value)
    let shadows = try #require(UICanvasFields.parseShadows(shadowCSS))
    #expect(shadows.first?.blur == 18 && shadows.first?.spread == -2)
    model.setStyle("background-image", UICanvasFields.formatGradient(UICanvasGradient(
      angle: 45, stops: [.init(color: "#ffffff", position: nil), .init(color: "#e0457b", position: "90%")])))
    try await eventually {
      UICanvasFields.parseGradient(model.selection?.style("background-image")?.value ?? "")
        == UICanvasGradient(angle: 45, stops: [.init(color: "#ffffff", position: nil), .init(color: "#e0457b", position: "90%")])
    }
    model.setStyle("padding", UICanvasFields.composeBox(["4px", "12px", "4px", "12px"]))
    try await eventually { model.selection?.style("padding")?.value == "4px 12px" }
    let editsBeforeReload = model.edits.count

    // The agent rewrites the file; the reload re-applies the human's pending edit.
    try write("Start free trial")
    model.reloadArtifact()
    try await eventually {
      let text = try? await view.evaluateJavaScript("document.getElementById('cta').textContent") as? String
      let background = try? await view.evaluateJavaScript(
        "getComputedStyle(document.getElementById('cta')).backgroundColor") as? String
      return text == "Start free trial" && background == "rgb(255, 0, 0)"
    }
    #expect(model.edits.count == editsBeforeReload)

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

  @Test("Save writes the edits into the mockup file itself and keeps the session open")
  func saveWithoutFinish() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ui-canvas-save-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let mockup = root.appendingPathComponent("card.html")
    try Data("""
      <!doctype html><html><head><title>Card</title><style>
      body{margin:0;font-family:sans-serif} #cta{background:#22c55e;color:#fff}
      </style></head><body>
      <article id="card"><button id="cta">Start trial</button></article>
      </body></html>
      """.utf8).write(to: mockup)
    let store = UICanvasStore(root: root)
    guard case .opened(let session) = try store.open(
      file: mockup.path, taskID: "FOC-125", title: "Card", viewport: nil, reopen: false, agentName: "Claude Code")
    else { Issue.record("open refused"); return }

    let model = UICanvasModel(store: store, taskID: "FOC-125", key: session.key)
    let coordinator = UICanvasWebStage.Coordinator(model: model)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                         configuration: UICanvasWebStage.configuration(coordinator: coordinator))
    view.navigationDelegate = coordinator
    defer { UICanvasWebStage.dismantleNSView(view, coordinator: coordinator) }
    model.attach(view)
    try await eventually { model.renderedViewport.width > 0 }

    model.select("#cta")
    try await eventually { model.selection?.selector == "#cta" }
    model.setStyle("background-color", "#ff0000")
    try await eventually { model.liveEditCount == 1 }

    await model.saveEdits()

    let saved = try String(contentsOf: mockup, encoding: .utf8)
    #expect(saved.contains("background-color: rgb(255, 0, 0)"))
    #expect(!saved.contains("data-ecc-ui-canvas"), "Editor instrumentation never reaches the saved file")
    #expect(!model.isEnded)
    #expect(model.edits.isEmpty)
    #expect(!model.canUndo)
    let unchanged = try #require(try store.load(taskID: "FOC-125", key: session.key))
    #expect(unchanged.pendingFeedback.isEmpty, "Save is local: nothing is queued for the agent")
    #expect(unchanged.status == "open")
    let exports = UICanvasStore.exportPaths(for: mockup)
    #expect(FileManager.default.fileExists(atPath: exports.html.path))
    #expect(FileManager.default.fileExists(atPath: exports.edits.path))
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
