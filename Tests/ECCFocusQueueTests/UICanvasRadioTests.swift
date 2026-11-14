import FocusQueueCore
import Foundation
import Testing
import WebKit

@testable import ECCFocusQueue

@Suite("UI Canvas radio selection history")
@MainActor
struct UICanvasRadioTests {
  @Test("Radio selections undo together, preserve form scope, and survive reload",
        arguments: [false, true])
  func radioHistory(reversed: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let mockup = root.appendingPathComponent("radio.html")
    let options = [
      #"<input id="basic" type="radio" name="plan" checked>"#,
      #"<input id="pro" type="RADIO" name="plan">"#,
    ]
    let ordered = reversed ? Array(options.reversed()) : options
    try Data("""
      <!doctype html><html><body>
      <form>\(ordered.joined())<input id="team" type="radio" name="plan"></form>
      <form><input id="other" type="radio" name="plan" checked></form>
      <input id="unnamed1" type="radio" checked><input id="unnamed2" type="radio">
      <form><input id="empty" type="radio" name="empty"></form>
      </body></html>
      """.utf8).write(to: mockup)
    let store = UICanvasStore(root: root)
    guard case .opened(let session) = try store.open(
      file: mockup.path, taskID: "TEST-1", title: "Radio", viewport: nil, reopen: false, agentName: "Codex")
    else { Issue.record("open refused"); return }
    let model = UICanvasModel(store: store, taskID: "TEST-1", key: session.key)
    let coordinator = UICanvasWebStage.Coordinator(model: model)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                        configuration: UICanvasWebStage.configuration(coordinator: coordinator))
    view.navigationDelegate = coordinator
    defer { UICanvasWebStage.dismantleNSView(view, coordinator: coordinator) }
    model.attach(view)
    try await eventually { model.renderedViewport.width > 0 }
    model.setMode(.interact)

    func choose(_ id: String, edits: Int) async throws {
      _ = try await view.evaluateJavaScript("document.getElementById('\(id)').click()")
      try await eventually { model.edits.count == edits }
    }
    func selection(_ expected: String) async throws {
      try await eventually {
        let result = try? await view.evaluateJavaScript(
          "Array.from(document.querySelectorAll('input')).filter(e => e.checked).map(e => e.id).sort().join(',')") as? String
        return result == expected
      }
    }
    try await choose("pro", edits: 1)
    try await selection("other,pro,unnamed1")
    model.undo()
    try await selection("basic,other,unnamed1")
    try await eventually { model.edits.isEmpty && model.canRedo }
    model.redo()
    try await selection("other,pro,unnamed1")
    try await eventually { model.edits.count == 1 }

    try await choose("team", edits: 2)
    model.undo()
    try await selection("other,pro,unnamed1")
    try await eventually { model.edits.count == 1 && model.canRedo }
    try await choose("basic", edits: 2)
    #expect(!model.canRedo, "A new choice clears the discarded redo history")
    model.undo()
    try await selection("other,pro,unnamed1")
    try await eventually { model.edits.count == 1 }

    // Reload through the production model, then undo the persisted group.
    _ = try await view.evaluateJavaScript("window.__beforeReload = true")
    model.reloadArtifact()
    try await eventually {
      (try? await view.evaluateJavaScript("window.__beforeReload === undefined") as? Bool) == true
    }
    try await selection("other,pro,unnamed1")
    model.undo()
    try await selection("basic,other,unnamed1")
    try await eventually { model.edits.isEmpty }

    try await choose("unnamed2", edits: 1)
    try await selection("basic,other,unnamed1,unnamed2")
    model.undo()
    try await selection("basic,other,unnamed1")
    try await eventually { model.edits.isEmpty }
    try await choose("empty", edits: 1)
    model.undo()
    try await selection("basic,other,unnamed1")
    try await eventually { model.edits.isEmpty }

    // Earlier versions persisted separate boolean input edits.
    let legacy = """
      window.__eccUiCanvasHandle({type:'uc:restore', edits:[
        {id:'e1-old',kind:'input',selector:'#basic',inputType:'radio',before:true,after:false},
        {id:'e2-old',kind:'input',selector:'#pro',inputType:'radio',before:false,after:true}
      ]});
      """
    _ = try await view.evaluateJavaScript(legacy, in: nil, in: .defaultClient)
    try await selection("other,pro,unnamed1")
    try await eventually { model.edits.count == 2 }
    try await choose("team", edits: 3)
    let saved = String(decoding: try JSONEncoder().encode(model.edits), as: UTF8.self)
    model.undo()
    try await selection("other,pro,unnamed1")

    // A changed mockup must not partially apply a recorded group.
    _ = try await view.evaluateJavaScript("document.getElementById('team').remove()")
    _ = try await view.evaluateJavaScript(
      "window.__eccUiCanvasHandle({type:'uc:restore', edits:\(saved)})", in: nil, in: .defaultClient)
    try await eventually { model.edits.last?["stale"]?.bool == true }
    try await selection("other,pro,unnamed1")
  }

  private func eventually(_ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(8))
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting for radio selection")
    throw CancellationError()
  }
}
