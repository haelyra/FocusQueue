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
  /// The rail card the human is working in opens fully; the other condenses.
  @State private var railFocus = UICanvasRailFocus.inspector
  @FocusState private var composerFocused: Bool

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
        Task { await model.saveEdits() }
      } label: {
        Label("Save", systemImage: "square.and.arrow.down")
      }
      .keyboardShortcut("s", modifiers: .command)
      .disabled(model.isEnded || model.isSending)
      .help("Write your edits into the mockup file now; the session stays open and the agent is not notified")
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
    .opaqueAwareMaterialBackground(in: RoundedRectangle(cornerRadius: 12))
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
            .opaqueAwareMaterialBackground(in: RoundedRectangle(cornerRadius: 12))
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
    .opaqueAwareMaterialBackground(in: RoundedRectangle(cornerRadius: 16))
    .shadow(color: .black.opacity(0.15), radius: 18, y: 6)
  }

  // MARK: Rail

  /// The inspector opens to its full height while the human selects and
  /// restyles, and condenses to one line while they write to the agent.
  private var rail: some View {
    VStack(alignment: .leading, spacing: 10) {
      UICanvasInspector(model: model, expanded: railFocus == .inspector) { expanded in
        if expanded { composerFocused = false }
        railFocus = expanded ? .inspector : .chat
      }
      .uiCanvasRailCard()
      .layoutPriority(railFocus == .inspector ? 2 : 0)
      editsSection(compact: railFocus == .inspector).uiCanvasRailCard()
        .frame(maxHeight: railFocus == .inspector ? nil : 170)
      UICanvasConversation(model: model, composerFocused: $composerFocused).uiCanvasRailCard()
        .frame(minHeight: railFocus == .chat ? 320 : 150, maxHeight: .infinity).layoutPriority(1)
    }
    .animation(.snappy(duration: 0.22), value: railFocus)
    .onChange(of: composerFocused) { _, focused in if focused { railFocus = .chat } }
    .onChange(of: model.selection?.selector) { _, selector in
      if selector != nil { composerFocused = false; railFocus = .inspector }
    }
  }

  /// Compact keeps only the header so the open inspector has room.
  private func editsSection(compact: Bool) -> some View {
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
      if compact {
        EmptyView()
      } else if model.edits.isEmpty {
        Text("Your changes to the preview collect here. Save writes them into the mockup file so a break loses nothing; Apply to file asks the agent to bake them in; Save and Finish hands over the final design.")
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
  /// beside them in the app's isolated content world. The stage is offline:
  /// `OfflineWebContent` blocks every network request and WebRTC. Its data
  /// store persists, so a mockup's own saves (localStorage form answers)
  /// survive app restarts and breaks between edits.
  static func configuration(coordinator: Coordinator) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .canvasStage
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    OfflineWebContent.configure(configuration, allowsPageScripts: true)
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
    /// it are cancelled; subframes may only show local content.
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

extension WKWebsiteDataStore {
  /// The UI Canvas stage's own persistent store, kept apart from the app's
  /// other web views so mockup state never mixes with document previews.
  static let canvasStage = WKWebsiteDataStore(
    forIdentifier: UUID(uuidString: "3F8C2E71-9B4D-4A6F-8C1E-5D2A7B9E0F43")!)
}

enum UICanvasNavigationPolicy {
  static func allows(_ url: URL?, isMainFrame: Bool, isLink: Bool, artifact: URL?) -> Bool {
    guard let url else { return false }
    guard isMainFrame else {
      return !isLink && OfflineWebContent.localSchemes.contains(url.scheme?.lowercased() ?? "")
    }
    guard !isLink, url.isFileURL, let artifact else { return false }
    return url.standardizedFileURL.path == artifact.standardizedFileURL.path
  }
}

enum UICanvasRailFocus {
  case inspector, chat
}

extension View {
  /// Opaque like QChat, so text over a translucent window stays readable.
  func uiCanvasRailCard() -> some View {
    padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1).allowsHitTesting(false))
  }
}

// MARK: Conversation

private struct UICanvasConversation: View {
  @Bindable var model: UICanvasModel
  var composerFocused: FocusState<Bool>.Binding
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      connection
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

  /// Whether the agent hears this canvas, with a reconnect while it does not.
  private var connection: some View {
    let presence = model.presence
    let disconnected = [.waiting, .queued, .ended].contains(presence) && !model.isAgentTurnRunning
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("Conversation").font(.headline)
        Spacer(minLength: 4)
        if model.isAgentTurnRunning {
          ProgressView().controlSize(.mini)
        } else if disconnected {
          Button {
            model.reconnect()
          } label: {
            Label(presence == .ended ? "Reopen and Reconnect" : "Reconnect Agent",
                  systemImage: "arrow.triangle.2.circlepath")
          }
          .controlSize(.small)
          .help("Reach the agent that built this canvas through a fork of its conversation, or a new agent when none is found")
        }
      }
      HStack(spacing: 5) {
        Circle().fill(disconnected ? Color.orange : Color.green).frame(width: 6, height: 6)
        Text(connectionText(presence))
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
      .accessibilityElement(children: .combine)
    }
  }

  private func connectionText(_ presence: UICanvasPresence) -> String {
    if model.isAgentTurnRunning { return "Connecting to \(model.agentName)…" }
    switch presence {
    case .listening: return "\(model.agentName.capitalizedFirst) is listening."
    case .thinking, .typing: return "\(model.agentName.capitalizedFirst) is working on it."
    case .ended: return "Session ended. Reopen to keep iterating with \(model.agentName)."
    case .waiting, .queued:
      return "\(model.agentName.capitalizedFirst) is not listening. Messages you send reconnect it automatically."
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
      Text("Queued. Focus Queue delivers this to \(model.agentName) in a moment if it does not check in.")
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
        .background(QueueChatMessageRow.surface(for: isAgent ? .agent : .user, colorScheme: colorScheme),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07), lineWidth: 1))
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
          Text(selection.snippet.isEmpty ? selection.descriptor : "\(selection.descriptor) “\(selection.snippet)”")
            .lineLimit(1).truncationMode(.tail)
            .help(selection.selector)
          Button { model.anchorEnabled = false } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("Send without an anchor")
        }
        .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.1), in: Capsule())
      }
      TextField(placeholder, text: $model.draft, axis: .vertical)
        .lineLimit(1...5).textFieldStyle(.roundedBorder)
        .onSubmit { model.sendChat() }
        .focused(composerFocused)
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
  /// Full controls, or one summary line while the human writes to the agent.
  let expanded: Bool
  let setExpanded: (Bool) -> Void
  @State private var fieldError = ""
  /// Section titles the human closed; Border and Effects start closed so the
  /// common controls fit without scrolling.
  @AppStorage("uiCanvasCollapsedSections") private var collapsedSections = "Border,Effects"

  var body: some View {
    Group {
      if expanded {
        // Open at full height; scroll only when the window is too short to hold it.
        ViewThatFits(in: .vertical) {
          expandedContent
          ScrollView { expandedContent }
        }
      } else {
        condensed
      }
    }
    .disabled(model.isEnded)
  }

  private var condensed: some View {
    Button { setExpanded(true) } label: {
      HStack(spacing: 6) {
        Text("Selection").font(.headline)
        if let selection = model.selection {
          Text(selection.descriptor).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
          Text(selection.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
          Text("Nothing selected").font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 4)
        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Show the selection controls")
    .accessibilityLabel("Show selection controls")
  }

  private var expandedContent: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Selection").font(.headline)
        Spacer()
        if model.selection != nil {
          Button("Deselect") { model.deselect() }.controlSize(.small).help("Clear the selection (Esc)")
        }
        Button { setExpanded(false) } label: { Image(systemName: "chevron.up") }
          .buttonStyle(.plain).foregroundStyle(.secondary)
          .help("Condense the selection controls to give the conversation room")
          .accessibilityLabel("Condense selection controls")
      }
      if let selection = model.selection {
        selected(selection)
      } else {
        Text("Click anything in the preview to select it. Double-click edits its text, the handles resize it, dragging reorders it, and Delete removes it. Click the background to select the whole component.")
          .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
    UICanvasRow(label: "Size", isSet: false) {
      UICanvasSizeField(label: "Width", value: selection.width) { model.setSize(width: $0, height: nil) }
      Text("×").foregroundStyle(.secondary)
      UICanvasSizeField(label: "Height", value: selection.height) { model.setSize(width: nil, height: $0) }
      Text("px").font(.caption2).foregroundStyle(.secondary)
    }
    group("Fill", summary: summary(selection, ["background-color", "background-image"])) {
      if let style = selection.style("background-color") { colorRow("Background", style) }
      if let style = selection.style("background-image") {
        if let gradient = UICanvasFields.parseGradient(style.value) { gradientRows(style, gradient) }
        else { textRow("Image", style) }
      } else {
        UICanvasRow(label: "Gradient", isSet: false) {
          Button("Add gradient") {
            let base = selection.style("background-color").flatMap { UICanvasFields.parseColor($0.value) }
              .flatMap { $0.a > 0 ? UICanvasFields.formatColor($0) : nil } ?? "#ffffff"
            model.setStyle("background-image", UICanvasFields.formatGradient(UICanvasGradient(
              angle: 180, stops: [.init(color: base, position: nil), .init(color: "#d9d9de", position: nil)])))
          }.controlSize(.small)
          Spacer()
        }
      }
    }
    let has = { (property: String) in selection.style(property) != nil }
    if has("color") || has("font-size") {
      group("Text", summary: summary(selection, ["font-size", "font-weight", "color"])) {
        if let style = selection.style("color") { colorRow("Color", style) }
        ForEach(["font-size", "font-weight"], id: \.self) { property in
          if let style = selection.style(property) { numericRow(style) }
        }
        if let style = selection.style("line-height") { lineHeightRow(style, fontSize: selection.style("font-size")?.value) }
        if let style = selection.style("text-align") { alignRow(style) }
      }
    }
    if has("padding") || has("margin") || has("gap") {
      group("Spacing", summary: summary(selection, ["padding", "margin", "gap"])) {
        ForEach(["padding", "margin", "gap"], id: \.self) { property in
          if let style = selection.style(property) { boxRow(style) }
        }
      }
    }
    if let border = selection.style("border") {
      group("Border", summary: summary(selection, ["border", "border-radius"])) {
        borderRows(border)
        if let style = selection.style("border-radius") { boxRow(style) }
      }
    }
    group("Effects", summary: summary(selection, ["box-shadow", "opacity"])) {
      if let style = selection.style("opacity") { numericRow(style) }
      if let style = selection.style("box-shadow") { shadowRows(style) }
      if let style = selection.style("display") { displayRow(style) }
    }
    if !fieldError.isEmpty {
      Text(fieldError).font(.caption).foregroundStyle(.orange)
    } else {
      Text("Drag a slider or type a value and press Return. Click a swatch for the color panel. The × clears a property.")
        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func group<Content: View>(_ title: String, summary: String, @ViewBuilder content: () -> Content) -> some View {
    let closed = Set(collapsedSections.split(separator: ",").map(String.init))
    let isOpen = !closed.contains(title)
    return VStack(alignment: .leading, spacing: 5) {
      Divider()
      Button {
        var next = closed
        if isOpen { next.insert(title) } else { next.remove(title) }
        collapsedSections = next.sorted().joined(separator: ",")
      } label: {
        HStack(spacing: 5) {
          Image(systemName: isOpen ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold))
            .frame(width: 9)
          Text(title).font(.system(size: 9.5, weight: .semibold)).textCase(.uppercase)
          if !isOpen {
            Text(summary).font(.caption2).lineLimit(1).truncationMode(.tail)
          }
          Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(isOpen ? "Hide \(title.lowercased()) controls" : "Show \(title.lowercased()) controls")
      if isOpen { content() }
    }
  }

  /// A closed section's one-line readout, such as "14px · 400 · #F1F1F4".
  private func summary(_ selection: UICanvasSelectionInfo, _ properties: [String]) -> String {
    properties.compactMap { property -> String? in
      guard let value = selection.style(property)?.value, value != "none" else { return nil }
      if property == "box-shadow", let shadow = UICanvasFields.parseShadows(value)?.first {
        return "shadow \(UICanvasFields.formatNumber(shadow.x)) \(UICanvasFields.formatNumber(shadow.y)) \(UICanvasFields.formatNumber(shadow.blur))"
      }
      if property == "background-image" { return UICanvasFields.parseGradient(value) == nil ? "image" : "gradient" }
      if property == "opacity" { return value == "1" ? nil : "opacity \(value)" }
      if property == "border" {
        let parts = UICanvasFields.borderParts(value)
        return "\(UICanvasFields.formatNumber(parts.width))px \(parts.style) \(UICanvasColorRow.display(parts.color))"
      }
      if property.hasSuffix("color") { return UICanvasColorRow.display(value) }
      return UICanvasNumericDisplay.display(value)
    }.joined(separator: " · ")
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

  /// Computed line heights arrive in px; show them as a multiple of the font
  /// size so the slider works, and write the unitless ratio CSS prefers.
  private func lineHeightRow(_ style: UICanvasSelectionInfo.Style, fontSize: String?) -> some View {
    var shown = style
    if style.value.hasSuffix("px"), let pixels = Double(style.value.dropLast(2)),
       let fontSize, fontSize.hasSuffix("px"), let size = Double(fontSize.dropLast(2)), size > 0 {
      shown.value = UICanvasFields.formatNumber(pixels / size)
    } else if style.value == "normal" {
      shown.value = "1.2"
    }
    return numericRow(shown)
  }

  private func boxRow(_ style: UICanvasSelectionInfo.Style) -> some View {
    let spec = UICanvasFields.numeric[style.property] ?? UICanvasFieldSpec(label: style.property, box: true)
    return UICanvasBoxRow(style: style, spec: spec,
      commit: { text in apply(style.property, UICanvasFields.sanitizeBoxList(text, spec)) },
      slide: { css in fieldError = ""; model.setStyle(style.property, css) },
      clear: { model.setStyle(style.property, nil) },
      invalid: { fieldError = $0 })
  }

  /// One slider-and-field row for a numeric part of a compound value, such as a shadow's blur.
  private func partRow(_ label: String, _ value: Double, unit: String = "px", range: ClosedRange<Double>,
                       limits: ClosedRange<Double>? = nil, set: @escaping (Double) -> Void) -> some View {
    let bounds = limits ?? range
    let spec = UICanvasFieldSpec(label: label, unit: unit, units: [unit], min: bounds.lowerBound, max: bounds.upperBound,
                                 step: 0.5, slider: range, sliderStep: 1)
    return UICanvasNumericRow(
      style: .init(property: label, value: UICanvasFields.formatNumber(value) + unit, inline: "", resettable: false),
      spec: spec,
      commit: { text in
        if case .ok(_, let number?) = UICanvasFields.sanitizeNumber(text, spec) { fieldError = ""; set(number) }
        else { fieldError = "Use \(unit), like 8" }
      },
      slide: { css in if let number = Double(css.dropLast(unit.count)) { fieldError = ""; set(number) } },
      clear: {})
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

  @ViewBuilder private func shadowRows(_ style: UICanvasSelectionInfo.Style) -> some View {
    if let shadows = UICanvasFields.parseShadows(style.value) {
      if let shadow = shadows.first {
        let rest = Array(shadows.dropFirst())
        let update = { (changed: UICanvasShadow) in
          fieldError = ""
          model.setStyle("box-shadow", UICanvasFields.formatShadows([changed] + rest))
        }
        UICanvasRow(label: "Shadow", isSet: !style.inline.isEmpty) {
          Toggle("Inset", isOn: Binding(get: { shadow.inset }, set: { var next = shadow; next.inset = $0; update(next) }))
            .toggleStyle(.checkbox).controlSize(.small)
            .help("Draw the shadow inside the element")
          Spacer()
          Button("Remove") { model.setStyle("box-shadow", UICanvasFields.formatShadows(rest)) }
            .controlSize(.small).help("Remove this shadow")
        }
        partRow("X offset", shadow.x, range: -40...40, limits: -500...500) { var next = shadow; next.x = $0; update(next) }
        partRow("Y offset", shadow.y, range: -40...40, limits: -500...500) { var next = shadow; next.y = $0; update(next) }
        partRow("Blur", shadow.blur, range: 0...80, limits: 0...500) { var next = shadow; next.blur = $0; update(next) }
        partRow("Spread", shadow.spread, range: -20...40, limits: -500...500) { var next = shadow; next.spread = $0; update(next) }
        UICanvasColorRow(label: "Shadow color", value: shadow.color, isSet: !style.inline.isEmpty,
          set: { var next = shadow; next.color = $0; update(next) }, clear: nil, invalid: { fieldError = $0 })
        if !rest.isEmpty {
          Text("\(rest.count) more shadow layer\(rest.count == 1 ? "" : "s") kept as is.")
            .font(.caption2).foregroundStyle(.secondary)
        }
      } else {
        UICanvasRow(label: "Shadow", isSet: !style.inline.isEmpty) {
          Button("Add shadow") { model.setStyle("box-shadow", UICanvasFields.formatShadows([UICanvasShadow()])) }
            .controlSize(.small)
          Spacer()
        }
      }
    } else {
      textRow("Shadow", style)
    }
  }

  @ViewBuilder private func gradientRows(_ style: UICanvasSelectionInfo.Style, _ gradient: UICanvasGradient) -> some View {
    let update = { (changed: UICanvasGradient) in
      fieldError = ""
      model.setStyle("background-image", UICanvasFields.formatGradient(changed))
    }
    partRow("Angle", gradient.angle, unit: "deg", range: 0...360) { var next = gradient; next.angle = $0; update(next) }
    ForEach(Array(gradient.stops.enumerated()), id: \.offset) { index, stop in
      UICanvasColorRow(
        label: index == 0 ? "From" : index == gradient.stops.count - 1 ? "To" : "Stop \(index + 1)",
        value: stop.color, isSet: !style.inline.isEmpty,
        set: { var next = gradient; next.stops[index].color = $0; update(next) },
        clear: nil, invalid: { fieldError = $0 })
    }
    UICanvasRow(label: "", isSet: false) {
      Spacer()
      Button("Remove gradient") { model.setStyle("background-image", "none") }.controlSize(.small)
    }
  }

  private func displayRow(_ style: UICanvasSelectionInfo.Style) -> some View {
    let options = ["block", "flex", "grid", "inline-block", "inline", "inline-flex", "none"]
    return UICanvasRow(label: "Display", isSet: !style.inline.isEmpty) {
      Picker("Display", selection: Binding(get: { style.value }, set: { model.setStyle("display", $0) })) {
        ForEach(options.contains(style.value) ? options : [style.value] + options, id: \.self) { Text($0).tag($0) }
      }
      .labelsHidden().controlSize(.small).fixedSize()
      Spacer()
    }
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
    let lineStyle = parts.style == "none" ? "solid" : parts.style
    let border = { (width: Double, line: String, color: String) in
      fieldError = ""
      model.setStyle("border", "\(UICanvasFields.formatNumber(width))px \(line) \(color)")
    }
    partRow("Width", parts.width, range: 0...16, limits: 0...64) { border($0, lineStyle, parts.color) }
    UICanvasRow(label: "Style", isSet: !style.inline.isEmpty) {
      Picker("Style", selection: Binding(get: { lineStyle }, set: { border(max(1, parts.width), $0, parts.color) })) {
        ForEach(["solid", "dashed", "dotted", "double"], id: \.self) { Text($0).tag($0) }
      }.labelsHidden().controlSize(.small).fixedSize()
      Spacer()
      if !style.inline.isEmpty {
        Button { model.setStyle("border", nil) } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
          .help("Clear border")
      }
    }
    UICanvasColorRow(label: "Color", value: parts.color, isSet: !style.inline.isEmpty,
      set: { border(max(1, parts.width), lineStyle, $0) },
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

private struct UICanvasSizeField: View {
  let label: String
  let value: Int
  let commit: (Double) -> Void
  @State private var text = ""

  var body: some View {
    TextField(label, text: $text).textFieldStyle(.roundedBorder).font(.caption.monospacedDigit())
      .help(label)
      .accessibilityLabel(label)
      .onSubmit {
        if case .ok(_, let number?) = UICanvasFields.sanitizeNumber(
          text, UICanvasFieldSpec(label: label, unit: "px", units: ["px"], min: 1, max: 20_000, step: 1)) {
          commit(number)
        } else { text = String(value) }
      }
    .onAppear { text = String(value) }
    .onChange(of: value) { _, newValue in text = String(newValue) }
  }
}

private struct UICanvasNumericRow<Accessory: View>: View {
  let style: UICanvasSelectionInfo.Style
  let spec: UICanvasFieldSpec
  let commit: (String) -> Void
  let slide: (String) -> Void
  let clear: () -> Void
  @ViewBuilder var accessory: () -> Accessory
  @State private var text = ""

  /// The slider drives single values in the spec's own unit; anything else is typed.
  private var sliderValue: Double? {
    let display = Self.display(style.value)
    guard let match = display.wholeMatch(of: /(-?[\d.]+)([a-z%]*)/), let number = Double(match.1) else { return nil }
    let unit = String(match.2)
    if spec.ratio { return unit.isEmpty ? number : nil }
    return unit == spec.unit || (number == 0 && unit.isEmpty) ? number : nil
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
        .frame(width: sliderValue == nil ? nil : 64)
        .onSubmit { commit(text) }
      accessory()
      if !style.inline.isEmpty || style.resettable {
        Button { clear() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
          .help("Clear \(spec.label.lowercased())")
      }
    }
    .onAppear { text = Self.display(style.value) }
    .onChange(of: style.value) { _, newValue in text = Self.display(newValue) }
  }
}

extension UICanvasNumericRow where Accessory == EmptyView {
  init(style: UICanvasSelectionInfo.Style, spec: UICanvasFieldSpec, commit: @escaping (String) -> Void,
       slide: @escaping (String) -> Void, clear: @escaping () -> Void) {
    self.init(style: style, spec: spec, commit: commit, slide: slide, clear: clear, accessory: { EmptyView() })
  }
}

private enum UICanvasNumericDisplay {
  /// Trims long computed decimals such as 23.999999px.
  static func display(_ value: String) -> String {
    value.replacingOccurrences(of: #"(\d+\.\d{2})\d+"#, with: "$1", options: .regularExpression)
  }
}

extension UICanvasNumericRow {
  static func display(_ value: String) -> String { UICanvasNumericDisplay.display(value) }
}

/// Padding, margin, gap, and radius: one slider while every side matches,
/// or a field per side once they differ or the human splits them.
private struct UICanvasBoxRow: View {
  let style: UICanvasSelectionInfo.Style
  let spec: UICanvasFieldSpec
  let commit: (String) -> Void
  let slide: (String) -> Void
  let clear: () -> Void
  let invalid: (String) -> Void
  @State private var splits = false
  @State private var texts: [String] = []

  private var count: Int { style.property == "gap" ? 2 : 4 }
  private var sides: [String]? { UICanvasFields.boxSides(UICanvasNumericDisplay.display(style.value), count: count) }
  private var uniform: Bool { sides.map { Set($0).count == 1 } ?? false }

  var body: some View {
    Group {
      if uniform, !splits, let sides {
        UICanvasNumericRow(
          style: .init(property: style.property, value: sides[0], inline: style.inline, resettable: style.resettable),
          spec: spec, commit: commit, slide: slide, clear: clear
        ) {
          Button { splits = true } label: { Image(systemName: count == 2 ? "rectangle.split.2x1" : "square.split.2x2") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Set each \(count == 2 ? "direction" : "side") separately")
        }
      } else if sides != nil {
        UICanvasRow(label: spec.label, isSet: !style.inline.isEmpty) {
          HStack(spacing: 4) {
            ForEach(Array(texts.enumerated()), id: \.offset) { index, _ in
              VStack(spacing: 1) {
                TextField(UICanvasFields.sideLabels(style.property)[index], text: Binding(
                  get: { index < texts.count ? texts[index] : "" },
                  set: { if index < texts.count { texts[index] = $0 } }))
                  .textFieldStyle(.roundedBorder).font(.caption2.monospacedDigit())
                  .onSubmit(commitSides)
                  .help(UICanvasFields.sideLabels(style.property)[index])
                Text(Self.shortLabel(style.property, index)).font(.system(size: 8.5)).foregroundStyle(.secondary)
              }
            }
          }
          Button {
            splits = false
            if let first = sides?.first { commit(first) }
          } label: { Image(systemName: "link") }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Use one value for every \(count == 2 ? "direction" : "side")")
          if !style.inline.isEmpty || style.resettable {
            Button { clear() } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
              .help("Clear \(spec.label.lowercased())")
          }
        }
      } else {
        UICanvasNumericRow(style: style, spec: spec, commit: commit, slide: slide, clear: clear)
      }
    }
    .onAppear(perform: sync)
    .onChange(of: style.value) { _, _ in sync() }
  }

  private func sync() { texts = sides ?? [] }

  private func commitSides() {
    var values: [String] = []
    for text in texts {
      if text.trimmingCharacters(in: .whitespaces) == "auto", spec.allowAuto { values.append("auto"); continue }
      guard case .ok(let css, let value) = UICanvasFields.sanitizeNumber(text, spec) else {
        invalid("Each side takes one value, like 8 or 1rem"); return
      }
      values.append(value == 0 ? "0" : css)
    }
    commit(UICanvasFields.composeBox(values))
  }

  static func shortLabel(_ property: String, _ index: Int) -> String {
    switch property {
    case "gap": ["Row", "Col"][index]
    case "border-radius": ["↖", "↗", "↘", "↙"][index]
    default: ["Top", "Right", "Bottom", "Left"][index]
    }
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
  @State private var showsPanel = false

  var body: some View {
    UICanvasRow(label: label, isSet: isSet) {
      Button { showsPanel.toggle() } label: {
        UICanvasSwatch(rgba: UICanvasFields.parseColor(value)).frame(width: 30, height: 20)
      }
      .buttonStyle(.plain)
      .help("Open the color panel")
      .accessibilityLabel("\(label) color panel")
      .popover(isPresented: $showsPanel, arrowEdge: .leading) {
        UICanvasColorPanel(title: label, value: value, set: set)
      }
      TextField(label, text: $text).textFieldStyle(.roundedBorder).font(.caption.monospaced())
        .onSubmit {
          if let color = UICanvasFields.parseColor(text) { set(UICanvasFields.formatColor(color)) }
          else if case .ok(let css, _) = UICanvasFields.sanitizeCssText(text, maxLength: 40),
                  css.range(of: "^[a-z]+$", options: .regularExpression) != nil { set(css) }
          else { invalid("Use a hex color, rgb(), or a color name") }
        }
        .help("Hex like #E0457B, rgb(), or a color name")
      if let clear {
        Button { clear() } label: { Image(systemName: "xmark") }
          .buttonStyle(.plain).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
          .help("Clear \(label.lowercased())")
      }
    }
    .onAppear { text = Self.display(value) }
    .onChange(of: value) { _, newValue in text = Self.display(newValue) }
  }

  /// Hex in capitals, rgba() as written.
  static func display(_ value: String) -> String {
    guard let color = UICanvasFields.parseColor(value) else { return value }
    let css = UICanvasFields.formatColor(color)
    return css.hasPrefix("#") ? css.uppercased() : css
  }
}

/// A color chip over a checkerboard, so transparency reads as transparency.
struct UICanvasSwatch: View {
  let rgba: UICanvasRGBA?

  var body: some View {
    ZStack {
      Canvas { context, size in
        let cell: CGFloat = 5
        for row in 0..<Int(ceil(size.height / cell)) {
          for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
            context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                         with: .color(Color.gray.opacity(0.3)))
          }
        }
      }
      if let rgba {
        Color(.sRGB, red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, opacity: rgba.a)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 5))
    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.25), lineWidth: 1))
  }
}

/// RGB and alpha sliders, a hex field, quick swatches, and the system color
/// panel (wheel, eyedropper) for one color value.
struct UICanvasColorPanel: View {
  let title: String
  let value: String
  let set: (String) -> Void
  @State private var hex = ""

  private static let presets = [
    "#ffffff", "#f4f4f6", "#c7c7cc", "#8e8e93", "#3a3a3c", "#1d1d22", "#000000",
    "#e0457b", "#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#007aff", "#5856d6",
  ]

  private var rgba: UICanvasRGBA { UICanvasFields.parseColor(value) ?? UICanvasRGBA(r: 0, g: 0, b: 0, a: 1) }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        UICanvasSwatch(rgba: UICanvasFields.parseColor(value)).frame(width: 46, height: 46)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.headline)
          TextField("#RRGGBB", text: $hex).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            .onSubmit { if let color = UICanvasFields.parseColor(hex) { set(UICanvasFields.formatColor(color)) } }
            .accessibilityLabel("Hex color")
        }
      }
      channel("R", value: rgba.r, tint: .red) { var next = rgba; next.r = $0; return next }
      channel("G", value: rgba.g, tint: .green) { var next = rgba; next.g = $0; return next }
      channel("B", value: rgba.b, tint: .blue) { var next = rgba; next.b = $0; return next }
      channel("A", value: (rgba.a * 100).rounded(), range: 0...100, tint: .gray, suffix: "%") { var next = rgba; next.a = $0 / 100; return next }
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 7), spacing: 6) {
        ForEach(Self.presets, id: \.self) { preset in
          Button { set(preset) } label: { UICanvasSwatch(rgba: UICanvasFields.parseColor(preset)).frame(width: 24, height: 18) }
            .buttonStyle(.plain).help(preset.uppercased())
        }
      }
      ColorPicker("Color wheel and eyedropper", selection: Binding(
        get: { Color(.sRGB, red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, opacity: rgba.a) },
        set: { color in
          guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
          set(UICanvasFields.formatColor(UICanvasRGBA(
            r: Double(srgb.redComponent) * 255, g: Double(srgb.greenComponent) * 255,
            b: Double(srgb.blueComponent) * 255, a: (Double(srgb.alphaComponent) * 100).rounded() / 100)))
        }), supportsOpacity: true)
        .font(.caption)
    }
    .padding(14)
    .frame(width: 270)
    .onAppear { hex = UICanvasColorRow.display(value) }
    .onChange(of: value) { _, newValue in hex = UICanvasColorRow.display(newValue) }
  }

  private func channel(_ label: String, value: Double, range: ClosedRange<Double> = 0...255, tint: Color,
                       suffix: String = "", change: @escaping (Double) -> UICanvasRGBA) -> some View {
    HStack(spacing: 8) {
      Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint).frame(width: 12)
      Slider(value: Binding(get: { value }, set: { set(UICanvasFields.formatColor(change($0.rounded()))) }), in: range)
        .tint(tint).controlSize(.small)
      Text("\(Int(value))\(suffix)").font(.caption.monospacedDigit()).frame(width: 38, alignment: .trailing)
    }
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
