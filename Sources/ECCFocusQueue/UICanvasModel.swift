import FocusQueueCore
import Foundation
import Observation
import WebKit

/// The element selected in the mockup, as the in-page editor reports it.
struct UICanvasSelectionInfo: Equatable {
  struct Style: Equatable {
    var property: String
    var value: String
    var inline: String
    var resettable: Bool
  }

  struct Crumb: Equatable {
    var selector: String
    var label: String
  }

  var selector: String
  var tag: String
  var id: String
  var classes: [String]
  var snippet: String
  var width: Int
  var height: Int
  var editable: Bool
  var styles: [Style]
  var breadcrumb: [Crumb]

  init?(_ json: UICanvasJSON) {
    guard let selector = json["selector"]?.string, let tag = json["tag"]?.string else { return nil }
    self.selector = selector
    self.tag = tag
    id = json["id"]?.string ?? ""
    classes = json["classes"]?.array?.compactMap(\.string) ?? []
    snippet = json["snippet"]?.string ?? ""
    width = Int(json["size"]?["width"]?.number ?? 0)
    height = Int(json["size"]?["height"]?.number ?? 0)
    editable = json["editable"]?.bool ?? false
    styles = json["styles"]?.array?.compactMap { style in
      guard let property = style["property"]?.string, let value = style["value"]?.string else { return nil }
      return Style(property: property, value: value, inline: style["inline"]?.string ?? "",
                   resettable: style["resettable"]?.bool ?? false)
    } ?? []
    breadcrumb = json["breadcrumb"]?.array?.compactMap { crumb in
      guard let selector = crumb["selector"]?.string, let label = crumb["label"]?.string else { return nil }
      return Crumb(selector: selector, label: label)
    } ?? []
  }

  func style(_ property: String) -> Style? { styles.first { $0.property == property } }

  var descriptor: String {
    "<\(tag)>" + (id.isEmpty ? "" : "#\(id)") + (classes.isEmpty ? "" : "." + classes.joined(separator: "."))
  }
}

enum UICanvasMode: String {
  case edit, interact
}

/// One canvas session as shown in the app: the stored session, the live
/// editor state reported by the mockup, and the human's actions.
@MainActor
@Observable
final class UICanvasModel {
  let taskID: String
  let key: String
  private let store: UICanvasStore

  private(set) var session: UICanvasSession?
  private(set) var now = Date()
  private(set) var preset = "desktop"
  var customWidth = UICanvasViewport.custom.width
  var customHeight = UICanvasViewport.custom.height
  private(set) var mode: UICanvasMode = .edit
  private(set) var animationsPaused = false
  private(set) var selection: UICanvasSelectionInfo?
  private(set) var edits: [UICanvasJSON] = []
  private(set) var canUndo = false
  private(set) var canRedo = false
  private(set) var editorStatus = ""
  private(set) var sendStatus = ""
  private(set) var isSending = false
  private(set) var loadError: String?
  /// The CSS viewport the mockup reports, after scaling.
  private(set) var renderedViewport = CGSize.zero
  var draft = ""
  var anchorEnabled = true
  /// The app is running a reconnect or relay turn for this session.
  var isAgentTurnRunning = false

  /// Supplied by QueueViewModel: deliver queued feedback to the reconnected
  /// agent, and reconnect it explicitly.
  @ObservationIgnored var relayQueuedFeedback: (() -> Void)?
  @ObservationIgnored var reconnectAgent: (() -> Void)?

  @ObservationIgnored weak var webView: WKWebView?
  @ObservationIgnored private var scroll: (x: Double, y: Double) = (0, 0)
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var sessionStamp: Date?
  @ObservationIgnored private var artifactStamp: Date?
  @ObservationIgnored private var viewerMarkedAt = Date.distantPast

  init(store: UICanvasStore, taskID: String, key: String) {
    self.store = store
    self.taskID = taskID
    self.key = key
    session = try? store.load(taskID: taskID, key: key)
    if let spec = session?.viewport, let viewport = UICanvasViewport.parse(spec) {
      preset = viewport.preset
      if viewport.preset == "custom" {
        customWidth = viewport.width
        customHeight = viewport.height
      }
    }
    edits = loadPendingEdits()
    canUndo = edits.contains { $0["stale"]?.bool != true }
  }

  var fileURL: URL? { session.map { URL(fileURLWithPath: $0.file) } }
  var title: String { session?.displayTitle ?? "UI Canvas" }
  var isEnded: Bool { session?.isEnded ?? false }
  var agentName: String { session?.listener?.name ?? session?.agentName ?? "agent" }
  var presence: UICanvasPresence { session.map { UICanvasStore.presence(of: $0, now: now) } ?? .waiting }
  var liveEditCount: Int { edits.filter { $0["stale"]?.bool != true }.count }

  /// CSS pixel size of a fixed viewport; nil when desktop fills the stage.
  var fixedViewport: CGSize? {
    switch preset {
    case "mobile": CGSize(width: UICanvasViewport.mobile.width, height: UICanvasViewport.mobile.height)
    case "custom": CGSize(width: customWidth, height: customHeight)
    default: nil
    }
  }

  // MARK: Lifecycle

  func start() {
    guard pollTask == nil else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.refresh()
        try? await Task.sleep(nanoseconds: 400_000_000)
      }
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
    viewerMarkedAt = .distantPast
  }

  /// Picks up CLI changes to the session and agent writes to the mockup.
  func refresh() {
    now = Date()
    // While the tab is on screen, tell the agent the human is looking at it.
    if pollTask != nil, !isEnded, now.timeIntervalSince(viewerMarkedAt) >= UICanvasStore.heartbeatInterval {
      viewerMarkedAt = now
      try? store.markViewer(taskID: taskID, key: key, at: now)
    }
    if let url = try? store.directory(taskID: taskID).appendingPathComponent("\(key).json"),
       let stamp = modificationDate(url), stamp != sessionStamp {
      sessionStamp = stamp
      if let loaded = try? store.load(taskID: taskID, key: key) {
        let wasEnded = isEnded
        session = loaded
        if loaded.isEnded, !wasEnded { setMode(.interact) }
      }
    }
    // No agent picked up the feedback: the app delivers it, so an open canvas
    // reaches its agent even when nothing is parked in `canvas await`.
    if !isAgentTurnRunning, let session, UICanvasStore.needsRelay(session, now: now) {
      relayQueuedFeedback?()
    }
    if let fileURL, let stamp = modificationDate(fileURL), stamp != artifactStamp {
      let isFirst = artifactStamp == nil
      artifactStamp = stamp
      if !isFirst { reloadArtifact() }
    }
  }

  private func modificationDate(_ url: URL) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
  }

  func attach(_ webView: WKWebView) {
    self.webView = webView
    artifactStamp = fileURL.flatMap(modificationDate)
    reloadArtifact()
  }

  func reloadArtifact() {
    guard let webView, let fileURL else { return }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      loadError = "The mockup file no longer exists: \(fileURL.path)"
      return
    }
    // A saved session is revalidated on every load: a regular file under the size limit.
    do {
      try UICanvasArtifactValidation.validate(fileURL)
    } catch {
      loadError = error.localizedDescription
      return
    }
    loadError = nil
    // Local sibling assets (images, styles) still load; nothing reaches the network.
    OfflineWebContent.load(
      fileURL, readAccess: fileURL.deletingLastPathComponent(), in: webView,
      shouldLoad: { [weak self, weak webView] in
        guard let self, let webView else { return false }
        return self.webView === webView && self.fileURL == fileURL
      },
      onFailure: { [weak self] error in self?.loadError = error.localizedDescription })
  }

  // MARK: Editor bridge

  func command(_ message: [String: Any]) {
    guard let webView,
          let data = try? JSONSerialization.data(withJSONObject: message),
          let json = String(data: data, encoding: .utf8) else { return }
    webView.evaluateJavaScript(
      "window.__eccUiCanvasHandle && window.__eccUiCanvasHandle(\(json))", in: nil, in: .defaultClient,
      completionHandler: nil)
  }

  func handle(message body: Any) {
    let message = UICanvasJSON(any: body)
    switch message["type"]?.string {
    case "uc:ready":
      readViewport(message["viewport"])
      var restore: [String: Any] = ["type": "uc:restore", "edits": edits.map(\.foundationValue),
                                    "scroll": ["x": scroll.x, "y": scroll.y]]
      if let selector = selection?.selector { restore["selection"] = selector }
      command(restore)
      if mode == .interact { command(["type": "uc:set-mode", "mode": "interact"]) }
      if animationsPaused { command(["type": "uc:pause-animations", "paused": true]) }
    case "uc:selection":
      selection = message["selection"].flatMap(UICanvasSelectionInfo.init)
      if selection == nil { anchorEnabled = true }
    case "uc:edits":
      edits = UICanvasEditSummary.normalized(message["edits"]?.array ?? [])
      canUndo = message["canUndo"]?.bool ?? false
      canRedo = message["canRedo"]?.bool ?? false
      savePendingEdits()
    case "uc:status":
      editorStatus = message["text"]?.string ?? ""
    case "uc:toggle-mode":
      setMode(mode == .edit ? .interact : .edit)
    case "uc:scroll":
      scroll = (message["x"]?.number ?? 0, message["y"]?.number ?? 0)
    case "uc:viewport":
      readViewport(message)
    default:
      break
    }
  }

  private func readViewport(_ json: UICanvasJSON?) {
    guard let width = json?["width"]?.number, let height = json?["height"]?.number else { return }
    renderedViewport = CGSize(width: width, height: height)
  }

  // MARK: Human actions

  func setPreset(_ preset: String) {
    self.preset = preset
  }

  func rotate() {
    if preset == "mobile" {
      preset = "custom"
      customWidth = UICanvasViewport.mobile.height
      customHeight = UICanvasViewport.mobile.width
    } else if preset == "custom" {
      swap(&customWidth, &customHeight)
    }
  }

  func setCustomSize(width: Int?, height: Int?) {
    let range = UICanvasViewport.dimensionRange
    if let width { customWidth = min(range.upperBound, max(range.lowerBound, width)) }
    if let height { customHeight = min(range.upperBound, max(range.lowerBound, height)) }
    preset = "custom"
  }

  func setMode(_ mode: UICanvasMode) {
    self.mode = mode
    command(["type": "uc:set-mode", "mode": mode.rawValue])
  }

  func toggleAnimations() {
    animationsPaused.toggle()
    command(["type": "uc:pause-animations", "paused": animationsPaused])
  }

  func select(_ selector: String) { command(["type": "uc:select", "selector": selector]) }
  func deselect() { command(["type": "uc:deselect"]) }
  func undo() { command(["type": "uc:undo"]) }
  func redo() { command(["type": "uc:redo"]) }
  func resetEdits() { command(["type": "uc:reset"]) }
  func editText() { command(["type": "uc:edit-text"]) }
  func removeSelection() { command(["type": "uc:remove"]) }

  /// Sets one CSS property on the selection; nil removes it (border → none, padding → 0).
  func setStyle(_ property: String, _ value: String?) {
    command(["type": "uc:style", "property": property, "value": value as Any? ?? NSNull()])
  }

  func setSize(width: Double?, height: Double?) {
    command(["type": "uc:size", "width": width as Any? ?? NSNull(), "height": height as Any? ?? NSNull()])
  }

  /// One-line summaries of hand edits the agent has not written into the file yet.
  var pendingEditSummaries: [String] {
    edits.filter { $0["stale"]?.bool != true }.suffix(30).map(UICanvasEditSummary.summarize)
  }

  func sendChat() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !isEnded, !isSending else { return }
    guard !text.isEmpty else { sendStatus = "Type a message first."; return }
    var anchor: UICanvasAnchor?
    if let selection, anchorEnabled {
      anchor = UICanvasAnchor(selector: selection.selector, tag: selection.tag, snippet: selection.snippet,
                              size: .init(width: selection.width, height: selection.height))
    }
    let summaries = pendingEditSummaries
    let item = UICanvasFeedbackItem(kind: "chat", text: text, anchor: anchor,
                                    pendingEdits: summaries.isEmpty ? nil : summaries)
    do {
      try store.queueFeedback(taskID: taskID, key: key, items: [item])
      draft = ""
      sendStatus = deliveryNote
      refresh()
    } catch {
      sendStatus = "Send failed (\(error.localizedDescription))."
    }
  }

  /// Save without finishing: writes the DOM the human sees straight back into
  /// the mockup file, so longer editing sessions survive breaks. The session
  /// stays open and nothing is queued for the agent.
  func saveEdits() async {
    guard !isEnded, !isSending, let webView, let fileURL else { return }
    isSending = true
    sendStatus = "Saving to \(fileURL.lastPathComponent)…"
    defer { isSending = false }
    do {
      let result = try await webView.callAsyncJavaScript(
        "return window.__eccUiCanvasExport ? window.__eccUiCanvasExport() : null",
        arguments: [:], in: nil, contentWorld: .defaultClient)
      let snapshot = UICanvasJSON(any: result)
      guard let html = snapshot["html"]?.string else {
        sendStatus = "The preview is still loading. Try again in a moment."
        return
      }
      let exported = UICanvasEditSummary.normalized(snapshot["edits"]?.array ?? edits)
      let viewport = UICanvasViewport(
        preset: preset, width: Int(renderedViewport.width.rounded()), height: Int(renderedViewport.height.rounded()))
      _ = try UICanvasStore.writeExport(artifact: fileURL, html: html, edits: exported, viewport: viewport, kind: "save")
      try UICanvasStore.writeArtifact(fileURL, html: html)
      // The file now holds every edit, so the preview's pending log starts over.
      command(["type": "uc:forget"])
      edits = []
      canUndo = false
      canRedo = false
      artifactStamp = modificationDate(fileURL)
      sendStatus = "Saved to \(fileURL.lastPathComponent). The session stays open."
      savePendingEdits()
      refresh()
    } catch {
      sendStatus = "Save failed (\(error.localizedDescription))."
    }
  }

  /// Apply to file (`edits`) or Save and Finish (`finish`): exports the DOM the
  /// human sees plus the edit log next to the mockup, then queues the item.
  func sendEdits(finish: Bool) async {
    guard !isEnded, !isSending, let webView, let fileURL else { return }
    isSending = true
    sendStatus = finish ? "Saving the final design…" : "Capturing the preview…"
    defer { isSending = false }
    do {
      let result = try await webView.callAsyncJavaScript(
        "return window.__eccUiCanvasExport ? window.__eccUiCanvasExport() : null",
        arguments: [:], in: nil, contentWorld: .defaultClient)
      let snapshot = UICanvasJSON(any: result)
      guard let html = snapshot["html"]?.string else {
        sendStatus = "The preview is still loading. Try again in a moment."
        return
      }
      let exported = UICanvasEditSummary.normalized(snapshot["edits"]?.array ?? edits)
      let viewport = UICanvasViewport(
        preset: preset, width: Int(renderedViewport.width.rounded()), height: Int(renderedViewport.height.rounded()))
      let kind = finish ? "finish" : "edits"
      let paths = try UICanvasStore.writeExport(artifact: fileURL, html: html, edits: exported, viewport: viewport, kind: kind)
      let note = draft.trimmingCharacters(in: .whitespacesAndNewlines)
      let item = UICanvasFeedbackItem(kind: kind, text: note, edits: exported, viewport: viewport,
                                      exportPath: paths.html.path, editsPath: paths.edits.path)
      try store.queueFeedback(taskID: taskID, key: key, items: [item], endSession: finish)
      draft = ""
      if finish {
        setMode(.interact)
        sendStatus = "Saved and handed to \(agentName)."
      } else {
        command(["type": "uc:forget"])
        edits = []
        canUndo = false
        canRedo = false
        sendStatus = deliveryNote + " The preview updates when it writes the file."
      }
      savePendingEdits()
      refresh()
    } catch {
      sendStatus = (finish ? "Save failed (" : "Apply failed (") + error.localizedDescription + ")."
    }
  }

  func reconnect() {
    guard !isAgentTurnRunning else { return }
    reconnectAgent?()
  }

  func endSession() {
    do {
      try store.end(taskID: taskID, key: key, endedBy: "user")
      refresh()
    } catch {
      sendStatus = "Could not end the session (\(error.localizedDescription))."
    }
  }

  private var deliveryNote: String {
    switch presence {
    case .listening, .thinking, .typing: "Delivered. \(agentName) has it."
    default: "Queued. Focus Queue reconnects \(agentName) if it does not check in."
    }
  }

  // MARK: Pending edits survive app restarts

  private var pendingEditsURL: URL? {
    try? store.directory(taskID: taskID).appendingPathComponent("\(key).pending.json")
  }

  private func loadPendingEdits() -> [UICanvasJSON] {
    guard let url = pendingEditsURL, let data = try? Data(contentsOf: url),
          let edits = try? JSONDecoder().decode([UICanvasJSON].self, from: data) else { return [] }
    return UICanvasEditSummary.normalized(edits)
  }

  private func savePendingEdits() {
    guard let url = pendingEditsURL else { return }
    if edits.isEmpty || isEnded {
      try? FileManager.default.removeItem(at: url)
    } else if let data = try? JSONEncoder().encode(edits) {
      try? data.write(to: url, options: .atomic)
    }
  }
}
