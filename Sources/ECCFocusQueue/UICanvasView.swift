import AppKit
import FocusQueueCore
import SwiftUI
import WebKit

/// Native UI Canvas: the mockup stage with its viewport and mode controls on
/// the left, and the inspector, edit log, and agent conversation on the right,
/// laid out like the plan viewer's document and chat panes.
struct UICanvasView: View {
  let model: UICanvasModel
  @State private var confirmsEnd = false
  @State private var confirmsReset = false

  var body: some View {
    VStack(spacing: 8) {
      toolbar
      PlanPaneSplit(initialFraction: 0.68, minimumPrimary: 380, minimumSecondary: 300) {
        stage.padding(.horizontal, 4)
      } secondary: {
        rail.padding(.horizontal, 4)
      }
    }
    .onAppear { model.start() }
    .onDisappear { model.stop() }
  }

  // MARK: Toolbar

  private var toolbar: some View {
    HStack(spacing: 10) {
      Picker("Viewport", selection: Binding(get: { model.preset }, set: { model.setPreset($0) })) {
        Image(systemName: "desktopcomputer").help("Desktop: fills the stage").tag("desktop")
        Image(systemName: "iphone").help("Mobile: 393 × 852 CSS px").tag("mobile")
        Image(systemName: "aspectratio").help("Custom: exact width and height").tag("custom")
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .accessibilityLabel("Viewport")
      UICanvasDimensionFields(model: model)
      Picker("Mode", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
        Text("Edit").tag(UICanvasMode.edit)
        Text("Interact").tag(UICanvasMode.interact)
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .help("Edit selects, moves, and resizes; Interact lets clicks reach the component (⌘I in the preview)")
      .disabled(model.isEnded)
      Spacer(minLength: 4)
      UICanvasPresencePill(presence: model.presence, agent: model.agentName)
      Group {
        toolButton("arrow.uturn.backward", "Undo (⌘Z in the preview)") { model.undo() }
          .disabled(model.isEnded || !model.canUndo)
        toolButton("arrow.uturn.forward", "Redo (⇧⌘Z in the preview)") { model.redo() }
          .disabled(model.isEnded || !model.canRedo)
        toolButton(model.animationsPaused ? "play.fill" : "pause.fill",
                   model.animationsPaused ? "Resume animations" : "Pause animations and transitions") {
          model.toggleAnimations()
        }
        toolButton("arrow.clockwise", "Reload the preview (your edits are re-applied)") { model.reloadArtifact() }
      }
      Button {
        Task { await model.sendEdits(finish: true) }
      } label: {
        Label("Save and Finish", systemImage: "checkmark")
      }
      .buttonStyle(.borderedProminent)
      .disabled(model.isEnded || model.isSending)
      .help("Export the edited design to your agent and close the session")
      Button("End", role: .destructive) { confirmsEnd = true }
        .disabled(model.isEnded)
        .help("End the session without saving")
        .confirmationDialog("End this canvas without saving?", isPresented: $confirmsEnd) {
          Button("End without saving", role: .destructive) { model.endSession() }
        } message: {
          Text("Your agent stops listening. Unapplied edits stay only in this preview.")
        }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
  }

  private func toolButton(_ systemImage: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: systemImage) }
      .buttonStyle(.plain).frame(width: 26, height: 26).contentShape(Rectangle())
      .help(help).accessibilityLabel(help)
  }

  // MARK: Stage

  private var stage: some View {
    VStack(spacing: 6) {
      GeometryReader { geometry in
        let layout = UICanvasStageLayout(available: geometry.size, viewport: model.fixedViewport,
                                         isMobile: model.preset == "mobile")
        UICanvasWebStage(model: model, zoom: layout.scale)
          .frame(width: layout.frame.width, height: layout.frame.height)
          .clipShape(RoundedRectangle(cornerRadius: layout.cornerRadius))
          .padding(layout.bezel)
          .background {
            if layout.bezel > 0 {
              RoundedRectangle(cornerRadius: layout.cornerRadius + layout.bezel)
                .fill(Color.black.opacity(0.88))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            }
          }
          .frame(width: geometry.size.width, height: geometry.size.height)
      }
      .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        if model.isEnded { endedCard }
        else if let error = model.loadError {
          ContentUnavailableView("Mockup unavailable", systemImage: "doc.badge.ellipsis", description: Text(error))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
      }
      statusBar
    }
  }

  private var statusBar: some View {
    HStack(spacing: 12) {
      Text(model.editorStatus.isEmpty
        ? (model.mode == .edit ? "Click selects · double-click edits text · drag reorders · ⌥-drag or arrows nudge · ⌫ removes"
                               : "Interact: clicks and keys reach the component")
        : model.editorStatus)
        .lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 8)
      if model.renderedViewport.width > 0 {
        Text("\(Int(model.renderedViewport.width)) × \(Int(model.renderedViewport.height)) CSS px")
          .monospacedDigit()
      }
    }
    .font(.system(size: 10.5)).foregroundStyle(.secondary)
    .padding(.horizontal, 6)
  }

  private var endedCard: some View {
    let finished = model.session?.pendingFeedback.contains { $0.kind == "finish" } == true
      || model.session?.chat.last?.kind == "finish"
    return VStack(spacing: 8) {
      Image(systemName: finished ? "checkmark.circle.fill" : "stop.circle")
        .font(.system(size: 30)).foregroundStyle(finished ? Color.green : Color.secondary)
      Text(finished ? "Saved and handed to \(model.agentName)" : "Session ended").font(.headline)
      Text(finished
        ? "Your edits and the final markup are on their way. The agent wires them into the real component next."
        : model.session?.endedBy == "agent" ? "Your agent closed this canvas." : "You ended this canvas without saving.")
        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
    .padding(22).frame(maxWidth: 360)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
  }

  // MARK: Rail

  private var rail: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        UICanvasInspector(model: model).frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(minHeight: 120, maxHeight: .infinity)
      railCard { editsSection }.frame(maxHeight: 170)
      railCard { UICanvasConversation(model: model) }
        .frame(minHeight: 240, maxHeight: .infinity).layoutPriority(1)
    }
  }

  private func railCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    content()
      .padding(10)
      .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
  }

  private var editsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Edits").font(.headline)
        Text("\(model.edits.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
          .padding(.horizontal, 6).padding(.vertical, 1).background(Color.secondary.opacity(0.12), in: Capsule())
        Spacer()
        Button("Apply to file") { Task { await model.sendEdits(finish: false) } }
          .controlSize(.small)
          .disabled(model.isEnded || model.isSending || model.liveEditCount == 0)
          .help("Send the edits so the agent writes them into the mockup file now")
        Button("Reset", role: .destructive) { confirmsReset = true }
          .controlSize(.small).disabled(model.isEnded || model.edits.isEmpty)
          .confirmationDialog("Revert every edit in the preview?", isPresented: $confirmsReset) {
            Button("Revert all", role: .destructive) { model.resetEdits() }
          }
      }
      if model.edits.isEmpty {
        Text("Your changes to the preview collect here. Apply to file asks the agent to bake them into the mockup; Save and Finish hands over the final design.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.edits.enumerated()), id: \.offset) { _, edit in
              let stale = edit["stale"]?.bool == true
              HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(edit["kind"]?.string ?? "edit")
                  .font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase)
                  .foregroundStyle(stale ? Color.secondary : Color.accentColor)
                  .frame(width: 44, alignment: .leading)
                Text(UICanvasEditSummary.summarize(edit))
                  .font(.caption).lineLimit(2).foregroundStyle(stale ? Color.secondary : Color.primary)
                  .strikethrough(stale)
              }
              .help(stale ? "Could not be re-applied after the last reload" : UICanvasEditSummary.summarize(edit))
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}

/// Where the mockup sits on the stage: desktop fills it; fixed viewports keep
/// their CSS size and scale down (never up) to fit, so media queries stay honest.
struct UICanvasStageLayout: Equatable {
  var frame: CGSize
  var scale: CGFloat
  var bezel: CGFloat
  var cornerRadius: CGFloat

  init(available: CGSize, viewport: CGSize?, isMobile: Bool, inset: CGFloat = 12) {
    bezel = isMobile ? 10 : 0
    let room = CGSize(width: max(1, available.width - inset * 2 - bezel * 2),
                      height: max(1, available.height - inset * 2 - bezel * 2))
    if let viewport, viewport.width > 0, viewport.height > 0 {
      let fit = min(1, room.width / viewport.width, room.height / viewport.height)
      if fit >= 1 {
        scale = 1
        frame = viewport
      } else {
        // WebKit truncates a fractional frame, so a 196.5 pt frame at 0.5 zoom
        // reports 392 CSS px. Use whole points and a zoom a hair under the
        // ratio so the reported width lands exactly on the requested one.
        let width = max(1, (viewport.width * fit).rounded(.down))
        scale = width / (viewport.width + 0.25)
        frame = CGSize(width: width, height: ((viewport.height + 0.25) * scale).rounded(.up))
      }
    } else {
      scale = 1
      frame = CGSize(width: room.width.rounded(.down), height: room.height.rounded(.down))
    }
    cornerRadius = isMobile ? max(8, 38 * scale) : 6
  }
}

private struct UICanvasDimensionFields: View {
  let model: UICanvasModel
  @State private var width = ""
  @State private var height = ""

  private var size: CGSize {
    model.fixedViewport ?? model.renderedViewport
  }

  var body: some View {
    HStack(spacing: 4) {
      TextField("W", text: $width).frame(width: 52).onSubmit(commit)
        .accessibilityLabel("Viewport width")
      Text("×").foregroundStyle(.secondary)
      TextField("H", text: $height).frame(width: 52).onSubmit(commit)
        .accessibilityLabel("Viewport height")
      Button { model.rotate() } label: { Image(systemName: "rotate.right") }
        .buttonStyle(.plain).help("Rotate (swap width and height)")
        .disabled(model.preset == "desktop")
    }
    .textFieldStyle(.roundedBorder).font(.system(size: 11).monospacedDigit())
    .help("Viewport in CSS px (100 to 20000). Typing a size switches to Custom.")
    .onAppear(perform: sync)
    .onChange(of: size) { _, _ in sync() }
    .onChange(of: model.preset) { _, _ in sync() }
  }

  private func sync() {
    width = size.width > 0 ? String(Int(size.width)) : ""
    height = size.height > 0 ? String(Int(size.height)) : ""
  }

  private func commit() {
    model.setCustomSize(width: Int(width.trimmingCharacters(in: .whitespaces)),
                        height: Int(height.trimmingCharacters(in: .whitespaces)))
    sync()
  }
}

struct UICanvasPresencePill: View {
  let presence: UICanvasPresence
  let agent: String

  private var color: Color {
    switch presence {
    case .listening: .green
    case .thinking, .typing: .accentColor
    case .queued: .orange
    case .waiting, .ended: .secondary
    }
  }

  var body: some View {
    HStack(spacing: 5) {
      Circle().fill(color).frame(width: 7, height: 7)
      Text(presence.label(agent: agent)).lineLimit(1)
    }
    .font(.system(size: 11, weight: .medium))
    .padding(.horizontal, 9).padding(.vertical, 4)
    .background(color.opacity(0.12), in: Capsule())
    .accessibilityElement(children: .combine)
  }
}

// MARK: Web stage

struct UICanvasWebStage: NSViewRepresentable {
  let model: UICanvasModel
  let zoom: CGFloat

  func makeCoordinator() -> Coordinator { Coordinator(model: model) }

  func makeNSView(context: Context) -> WKWebView {
    let view = WKWebView(frame: .zero, configuration: Self.configuration(coordinator: context.coordinator))
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    view.pageZoom = zoom
    view.isInspectable = true
    model.attach(view)
    return view
  }

  /// Mockup scripts run (tabs, toggles, animations must work); the editor runs
  /// beside them in the app's isolated content world.
  static func configuration(coordinator: Coordinator) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let controller = configuration.userContentController
    controller.addUserScript(WKUserScript(
      source: UICanvasEditorScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
    controller.add(coordinator, contentWorld: .defaultClient, name: UICanvasEditorScript.messageHandlerName)
    return configuration
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.model = model
    if abs(view.pageZoom - zoom) > 0.0005 { view.pageZoom = zoom }
    if model.webView !== view { model.attach(view) }
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(
      forName: UICanvasEditorScript.messageHandlerName, contentWorld: .defaultClient)
  }

  @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    weak var model: UICanvasModel?

    init(model: UICanvasModel) {
      self.model = model
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
      guard message.name == UICanvasEditorScript.messageHandlerName, message.frameInfo.isMainFrame else { return }
      model?.handle(message: message.body)
    }

    /// The stage shows one local file. Links and scripted navigations away from
    /// it are cancelled; subresources and subframes load normally.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      decisionHandler(UICanvasNavigationPolicy.allows(
        action.request.url, isMainFrame: action.targetFrame?.isMainFrame ?? true,
        isLink: action.navigationType == .linkActivated, artifact: model?.fileURL) ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      nil
    }
    // No alert or confirm handlers: WebKit then shows no modal panels, so a
    // mockup's dialogs can never block the editor.
  }
}

enum UICanvasNavigationPolicy {
  static func allows(_ url: URL?, isMainFrame: Bool, isLink: Bool, artifact: URL?) -> Bool {
    guard let url else { return false }
    guard isMainFrame else { return !isLink }
    guard !isLink, url.isFileURL, let artifact else { return false }
    return url.standardizedFileURL.path == artifact.standardizedFileURL.path
  }
}

// MARK: Conversation

private struct UICanvasConversation: View {
  @Bindable var model: UICanvasModel

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Conversation").font(.headline)
      ScrollViewReader { proxy in
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            let chat = model.session?.chat ?? []
            if chat.isEmpty {
              Text("Select something and describe the change, or just type. \(model.agentName.capitalizedFirst) answers here and the preview updates when it edits the file.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(chat.enumerated()), id: \.offset) { _, entry in
              bubble(entry)
            }
            activity.id("end")
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.session?.chat.count) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        .onChange(of: model.presence) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
      }
      composer
    }
  }

  @ViewBuilder private var activity: some View {
    switch model.presence {
    case .thinking, .typing:
      HStack(spacing: 6) {
        ProgressView().controlSize(.mini)
        Text(model.presence == .typing ? "\(model.agentName) is typing…" : "\(model.agentName) is working on it…")
      }.font(.caption).foregroundStyle(.secondary)
    case .queued:
      Text("Queued. \(model.agentName) is not listening right now and picks this up the moment it checks in.")
        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    default:
      EmptyView()
    }
  }

  private func bubble(_ entry: UICanvasChatEntry) -> some View {
    let isAgent = entry.role == "agent"
    return VStack(alignment: isAgent ? .leading : .trailing, spacing: 2) {
      Text(entry.text).font(.callout).textSelection(.enabled)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isAgent ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 10))
      Text("\(isAgent ? model.agentName : "you") · \(Self.time(entry.at))")
        .font(.system(size: 9.5)).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: isAgent ? .leading : .trailing)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let selection = model.selection, model.anchorEnabled {
        HStack(spacing: 4) {
          Text("About").foregroundStyle(.secondary)
          Text(selection.selector).font(.system(size: 10.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
          Button { model.anchorEnabled = false } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Send without an anchor")
        }
        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.1), in: Capsule())
      }
      TextField(placeholder, text: $model.draft, axis: .vertical)
        .lineLimit(1...5).textFieldStyle(.roundedBorder)
        .onSubmit { model.sendChat() }
        .disabled(model.isEnded)
        .accessibilityLabel("Message to agent")
      HStack {
        Text(model.sendStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        Spacer()
        Button("Send to agent") { model.sendChat() }
          .buttonStyle(.borderedProminent).controlSize(.small)
          .disabled(model.isEnded || model.isSending || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
  }

  private var placeholder: String {
    if let selection = model.selection, model.anchorEnabled {
      return "Describe the change to \(selection.tag)" + (selection.snippet.isEmpty ? "" : " “\(selection.snippet.prefix(30))”") + "…"
    }
    return "Ask your agent for a change… Return sends"
  }

  private static func time(_ iso: String) -> String {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = parser.date(from: iso) else { return "" }
    return date.formatted(date: .omitted, time: .shortened)
  }
}

private extension String {
  var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: Inspector

private struct UICanvasInspector: View {
  let model: UICanvasModel
  @State private var fieldError = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Selection").font(.headline)
        Spacer()
        if model.selection != nil {
          Button("Deselect") { model.deselect() }.controlSize(.small).help("Clear the selection (Esc)")
        }
      }
      if let selection = model.selection {
        selected(selection)
      } else {
        Text("Click anything in the preview to select it. Double-click edits its text, the handles resize it, dragging reorders it, and Delete removes it. Click the background to select the whole component.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10)
    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    .disabled(model.isEnded)
  }

  @ViewBuilder private func selected(_ selection: UICanvasSelectionInfo) -> some View {
    ScrollView(.horizontal) {
      HStack(spacing: 3) {
        ForEach(Array(selection.breadcrumb.enumerated()), id: \.offset) { index, crumb in
          if index > 0 { Text("›").foregroundStyle(.secondary) }
          Button(crumb.label) { model.select(crumb.selector) }
            .buttonStyle(.plain)
            .fontWeight(index == selection.breadcrumb.count - 1 ? .semibold : .regular)
            .help(crumb.selector)
        }
      }.font(.system(size: 10.5, design: .monospaced))
    }.scrollIndicators(.never)
    HStack(spacing: 6) {
      Text(selection.descriptor).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
        .help(selection.selector)
      Text(selection.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      Spacer(minLength: 4)
      Button("Edit text") { model.editText() }.controlSize(.small).disabled(!selection.editable)
      Button("Remove", role: .destructive) { model.removeSelection() }.controlSize(.small)
    }
    group("Size") {
      UICanvasSizeRow(label: "Width", value: selection.width) { model.setSize(width: $0, height: nil) }
      UICanvasSizeRow(label: "Height", value: selection.height) { model.setSize(width: nil, height: $0) }
    }
    let has = { (property: String) in selection.style(property) != nil }
    if has("background-color") || has("background-image") {
      group("Fill") {
        if let style = selection.style("background-color") { colorRow("Background", style) }
        if let style = selection.style("background-image") { textRow("Image", style) }
      }
    }
    if has("color") || has("font-size") {
      group("Text") {
        if let style = selection.style("color") { colorRow("Color", style) }
        ForEach(["font-size", "font-weight", "line-height"], id: \.self) { property in
          if let style = selection.style(property) { numericRow(style) }
        }
        if let style = selection.style("text-align") { alignRow(style) }
      }
    }
    if has("padding") || has("margin") || has("gap") {
      group("Spacing") {
        ForEach(["padding", "margin", "gap"], id: \.self) { property in
          if let style = selection.style(property) { numericRow(style) }
        }
      }
    }
    if let border = selection.style("border") {
      group("Border") {
        borderRows(border)
        if let style = selection.style("border-radius") { numericRow(style) }
      }
    }
    group("Effects") {
      if let style = selection.style("opacity") { numericRow(style) }
      if let style = selection.style("box-shadow") { textRow("Shadow", style) }
      if let style = selection.style("display") {
        UICanvasRow(label: "Display", isSet: false) { Text(style.value).font(.caption.monospaced()).foregroundStyle(.secondary) }
      }
    }
    if !fieldError.isEmpty {
      Text(fieldError).font(.caption).foregroundStyle(.orange)
    } else {
      Text("Drag a slider or type a value and press Return. The × clears a property.")
        .font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Divider()
      Text(title).font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase).foregroundStyle(.secondary)
      content()
    }
  }

  private func apply(_ property: String, _ result: UICanvasFieldResult) {
    switch result {
    case .ok(let css, _):
      fieldError = ""
      model.setStyle(property, css)
    case .error(let message):
      fieldError = message
    }
  }

  private func numericRow(_ style: UICanvasSelectionInfo.Style) -> some View {
    let spec = UICanvasFields.numeric[style.property] ?? UICanvasFieldSpec(label: style.property)
    return UICanvasNumericRow(style: style, spec: spec,
      commit: { text in apply(style.property, spec.box ? UICanvasFields.sanitizeBoxList(text, spec) : UICanvasFields.sanitizeNumber(text, spec)) },
      slide: { css in fieldError = ""; model.setStyle(style.property, css) },
      clear: { model.setStyle(style.property, nil) })
  }

  private func colorRow(_ label: String, _ style: UICanvasSelectionInfo.Style) -> some View {
    UICanvasColorRow(label: label, value: style.value, isSet: !style.inline.isEmpty,
      set: { model.setStyle(style.property, $0) },
      clear: style.resettable ? { model.setStyle(style.property, nil) } : nil,
      invalid: { fieldError = $0 })
  }

  private func textRow(_ label: String, _ style: UICanvasSelectionInfo.Style) -> some View {
    UICanvasTextRow(label: label, value: style.value == "none" ? "" : style.value, isSet: !style.inline.isEmpty,
      commit: { apply(style.property, UICanvasFields.sanitizeCssText($0)) },
      clear: { model.setStyle(style.property, nil) })
  }

  private func alignRow(_ style: UICanvasSelectionInfo.Style) -> some View {
    UICanvasRow(label: "Align", isSet: !style.inline.isEmpty) {
      Picker("Align", selection: Binding(
        get: { ["left", "center", "right", "justify"].contains(style.value) ? style.value : "left" },
        set: { model.setStyle("text-align", $0) })) {
        Image(systemName: "text.alignleft").tag("left")
        Image(systemName: "text.aligncenter").tag("center")
        Image(systemName: "text.alignright").tag("right")
        Image(systemName: "text.justify").tag("justify")
      }.pickerStyle(.segmented).labelsHidden()
    }
  }

  @ViewBuilder private func borderRows(_ style: UICanvasSelectionInfo.Style) -> some View {
    let parts = UICanvasFields.borderParts(style.value)
    let widthSpec = UICanvasFieldSpec(label: "Width", unit: "px", units: ["px"], min: 0, max: 64, step: 0.5, slider: 0...16)
    UICanvasNumericRow(
      style: .init(property: "border-width", value: "\(UICanvasFields.formatNumber(parts.width))px",
                   inline: style.inline, resettable: true),
      spec: widthSpec,
      commit: { text in
        if case .ok(_, let value?) = UICanvasFields.sanitizeNumber(text, widthSpec) {
          fieldError = ""
          model.setStyle("border", "\(UICanvasFields.formatNumber(value))px \(parts.style == "none" ? "solid" : parts.style) \(parts.color)")
        } else { fieldError = "Use px, like 1" }
      },
      slide: { css in model.setStyle("border", "\(css) \(parts.style == "none" ? "solid" : parts.style) \(parts.color)") },
      clear: { model.setStyle("border", nil) })
    UICanvasColorRow(label: "Color", value: parts.color, isSet: !style.inline.isEmpty,
      set: { model.setStyle("border", "\(UICanvasFields.formatNumber(max(1, parts.width)))px \(parts.style == "none" ? "solid" : parts.style) \($0)") },
      clear: nil, invalid: { fieldError = $0 })
  }
}

private struct UICanvasRow<Content: View>: View {
  let label: String
  let isSet: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 4) {
        Text(label).lineLimit(1)
        if isSet { Circle().fill(Color.accentColor).frame(width: 5, height: 5).help("Changed in this preview") }
      }
      .font(.caption).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
      content()
    }
  }
}

private struct UICanvasSizeRow: View {
  let label: String
  let value: Int
  let commit: (Double) -> Void
  @State private var text = ""

  var body: some View {
    UICanvasRow(label: label, isSet: false) {
      TextField(label, text: $text).textFieldStyle(.roundedBorder).font(.caption.monospacedDigit())
        .onSubmit {
          if case .ok(_, let number?) = UICanvasFields.sanitizeNumber(
            text, UICanvasFieldSpec(label: label, unit: "px", units: ["px"], min: 1, max: 20_000, step: 1)) {
            commit(number)
          } else { text = String(value) }
        }
      Text("px").font(.caption2).foregroundStyle(.secondary)
    }
    .onAppear { text = String(value) }
    .onChange(of: value) { _, newValue in text = String(newValue) }
  }
}

private struct UICanvasNumericRow: View {
  let style: UICanvasSelectionInfo.Style
  let spec: UICanvasFieldSpec
  let commit: (String) -> Void
  let slide: (String) -> Void
  let clear: () -> Void
  @State private var text = ""

  /// The slider drives single values in the spec's own unit; anything else is typed.
  private var sliderValue: Double? {
    let display = Self.display(style.value)
    guard let match = display.wholeMatch(of: /(-?[\d.]+)([a-z%]*)/), let number = Double(match.1) else { return nil }
    let unit = String(match.2)
    if spec.ratio { return unit.isEmpty ? number : nil }
    return unit == spec.unit ? number : nil
  }

  var body: some View {
    UICanvasRow(label: spec.label, isSet: !style.inline.isEmpty) {
      if let sliderValue {
        Slider(value: Binding(get: { min(spec.slider.upperBound, max(spec.slider.lowerBound, sliderValue)) },
                              set: { value in
                                let rounded = UICanvasFields.roundToStep(value, spec.sliderStep)
                                slide(spec.ratio ? UICanvasFields.formatNumber(rounded)
                                                 : UICanvasFields.formatNumber(rounded) + spec.unit)
                              }),
               in: spec.slider)
        .controlSize(.mini)
      }
      TextField(spec.label, text: $text).textFieldStyle(.roundedBorder).font(.caption.monospacedDigit())
        .frame(width: sliderValue == nil ? nil : 72)
        .onSubmit { commit(text) }
      if !style.inline.isEmpty || style.resettable {
        Button { clear() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
          .help("Clear \(spec.label.lowercased())")
      }
    }
    .onAppear { text = Self.display(style.value) }
    .onChange(of: style.value) { _, newValue in text = Self.display(newValue) }
  }

  /// Trims long computed decimals such as 23.999999px.
  static func display(_ value: String) -> String {
    value.replacingOccurrences(of: #"(\d+\.\d{2})\d+"#, with: "$1", options: .regularExpression)
  }
}

private struct UICanvasColorRow: View {
  let label: String
  let value: String
  let isSet: Bool
  let set: (String) -> Void
  let clear: (() -> Void)?
  let invalid: (String) -> Void
  @State private var text = ""

  private var rgba: UICanvasRGBA { UICanvasFields.parseColor(value) ?? UICanvasRGBA(r: 0, g: 0, b: 0, a: 0) }

  var body: some View {
    UICanvasRow(label: label, isSet: isSet) {
      ColorPicker(label, selection: Binding(
        get: { Color(.sRGB, red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, opacity: rgba.a) },
        set: { color in
          guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
          set(UICanvasFields.formatColor(UICanvasRGBA(
            r: Double(srgb.redComponent) * 255, g: Double(srgb.greenComponent) * 255,
            b: Double(srgb.blueComponent) * 255, a: (Double(srgb.alphaComponent) * 100).rounded() / 100)))
        }), supportsOpacity: true)
        .labelsHidden()
      TextField(label, text: $text).textFieldStyle(.roundedBorder).font(.caption.monospaced())
        .onSubmit {
          if let color = UICanvasFields.parseColor(text) { set(UICanvasFields.formatColor(color)) }
          else if case .ok(let css, _) = UICanvasFields.sanitizeCssText(text, maxLength: 40),
                  css.range(of: "^[a-z]+$", options: .regularExpression) != nil { set(css) }
          else { invalid("Use a hex color, rgb(), or a color name") }
        }
      if let clear {
        Button { clear() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
          .help("Clear \(label.lowercased())")
      }
    }
    .onAppear { text = Self.display(value) }
    .onChange(of: value) { _, newValue in text = Self.display(newValue) }
  }

  static func display(_ value: String) -> String {
    UICanvasFields.parseColor(value).map { UICanvasFields.formatColor($0).uppercased() } ?? value
  }
}

private struct UICanvasTextRow: View {
  let label: String
  let value: String
  let isSet: Bool
  let commit: (String) -> Void
  let clear: () -> Void
  @State private var text = ""

  var body: some View {
    UICanvasRow(label: label, isSet: isSet) {
      TextField("none", text: $text).textFieldStyle(.roundedBorder).font(.caption.monospaced())
        .onSubmit { commit(text) }
      Button { clear() } label: { Image(systemName: "xmark") }
        .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        .help("Clear \(label.lowercased())")
    }
    .onAppear { text = value }
    .onChange(of: value) { _, newValue in text = newValue }
  }
}
