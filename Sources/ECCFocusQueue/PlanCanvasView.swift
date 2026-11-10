import AppKit
import FocusQueueCore
import SwiftUI
import WebKit

struct PlanCanvasView: View {
  let model: QueueViewModel
  let ticket: DashboardTicket
  @Binding var chatDraft: String
  @State private var isEditing = false
  @State private var editDraft = ""
  @State private var editBaseline = ""
  @State private var isSaving = false
  @State private var sideDocuments = DocumentPaneState()
  @State private var canvasSelection: PlanCanvasSelection?
  @State private var composerFocusRequest = 0
  @State private var showsWorkspaceMap = false
  @State private var workspaceMap = WorkspaceMapModel()
  @State private var planFind = DocumentFindState()
  @State private var draggedTab: URL?
  @State private var isSplitTargeted = false
  /// The native UI Canvas tab in front, if any.
  @State private var selectedCanvasKey: String?

  private var sourceURL: URL {
    model.presentedPlanURL ?? URL(fileURLWithPath: model.taskContexts[ticket.id]?.planPath ?? "/")
  }

  /// The central plan is in the primary viewer, so header Find searches it.
  private var isCentralPlanVisible: Bool {
    sideDocuments.primaryDocument == nil && !showsWorkspaceMap && selectedCanvasKey == nil
  }

  /// The selected canvas while it fills the viewer in place of the plan.
  private var presentedCanvas: UICanvasSession? {
    guard let selectedCanvasKey, sideDocuments.primaryDocument == nil, sideDocuments.secondaryDocument == nil
    else { return nil }
    return model.visibleUICanvases(ticketID: ticket.id).first { $0.key == selectedCanvasKey }
  }

  /// The tab a split would act on: the right-hand document, or the one in front.
  private var splitCandidate: URL? {
    sideDocuments.secondaryDocument ?? sideDocuments.primaryDocument
  }

  /// A dragged tab is over the viewer and could open beside what is showing.
  private var previewsSplit: Bool {
    guard isSplitTargeted, sideDocuments.secondaryDocument == nil, let draggedTab else { return false }
    return sideDocuments.canSplit(draggedTab)
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(alignment: .center, spacing: 8) {
        VStack(alignment: .leading, spacing: 3) {
          documentTabBar
          HStack(spacing: 4) {
            Text("\(ticket.id) ·")
            RenamableTaskTitle(
              ticket: ticket, model: model, size: 11, weight: .regular,
              maximumLines: 2)
          }
          .foregroundStyle(.secondary)
        }
        Spacer()
        if isCentralPlanVisible, !isEditing {
          DocumentFindBar(state: planFind, placesFieldFirst: true)
        }
        if presentedCanvas == nil, let candidate = splitCandidate,
           sideDocuments.hasSecondaryViewer || sideDocuments.canSplit(candidate) {
          Button {
            toggleSplit(candidate)
          } label: {
            Image(systemName: sideDocuments.hasSecondaryViewer ? "rectangle" : "rectangle.split.2x1")
          }
          .buttonStyle(.plain).frame(width: 40, height: 40).disabled(isEditing || isSaving)
          .help(sideDocuments.hasSecondaryViewer ? "Close split view" : "Open this document in split view")
          .accessibilityLabel(sideDocuments.hasSecondaryViewer ? "Close split view" : "Open split view")
        }
        if isEditing {
          Button("Save") { Task { _ = await saveCentralPlanEdit() } }
            .buttonStyle(.borderedProminent).disabled(isSaving || editDraft == editBaseline)
            .keyboardShortcut("s", modifiers: .command)
            .help(editBaseline == model.presentedPlanMarkdown
              ? "Save the plan and return to the preview"
              : "Save the reconciled draft and return to the preview")
        }
        if model.presentedPlanURL == nil, sideDocuments.primaryDocument == nil, !showsWorkspaceMap,
           presentedCanvas == nil {
          Button {
            showsWorkspaceMap = false
            editDraft = model.planEditDrafts[ticket.id]?.markdown ?? model.presentedPlanMarkdown
            editBaseline = model.planEditDrafts[ticket.id]?.baseline ?? model.presentedPlanMarkdown
            isEditing.toggle()
            canvasSelection = nil
          } label: {
            Image(systemName: isEditing ? "eye" : "pencil")
          }
          .buttonStyle(.plain).frame(width: 40, height: 40).disabled(isSaving)
          .help(isEditing ? "Preview and keep draft" : "Edit central plan")
          .accessibilityLabel(isEditing ? "Preview plan" : "Edit central plan")
        }
        Button {
          Task { await closePlanSavingEdits() }
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).frame(width: 40, height: 40).disabled(isSaving)
        .help("Save any edits and return to the queue").accessibilityLabel("Close plan")
      }
      .padding(12)
      .opaqueAwareMaterialBackground(in: RoundedRectangle(cornerRadius: 16))
      .overlay(
        RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1)
          .allowsHitTesting(false)
      )

      if let error = model.planError {
        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      if let error = sideDocuments.error {
        HStack {
          Text(error).font(.caption).foregroundStyle(.orange)
          Button("Dismiss") { sideDocuments.error = nil }.font(.caption)
        }
      }

      if sideDocuments.primaryDocument != nil && sideDocuments.secondaryDocument == nil {
        HStack {
          Button(sideDocuments.centralChatCollapsed ? "Show central chat" : "Show document chat") {
            sideDocuments.centralChatCollapsed.toggle()
          }
          .font(.caption.weight(.semibold))
          .buttonStyle(.borderedProminent)
          .tint(.accentColor)
          if model.isChatResponding(ticketID: ticket.id) {
            ProgressView().controlSize(.mini)
            Text("Central conversation is still working").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
      }
      GeometryReader { geometry in
        if let canvas = presentedCanvas {
          UICanvasView(model: model.uiCanvasModel(ticketID: ticket.id, key: canvas.key)).id(canvas.key)
            .frame(width: geometry.size.width, height: geometry.size.height)
        } else {
        ScrollView(.horizontal) {
          if let secondaryDocument = sideDocuments.secondaryDocument {
            PlanPaneSplit(initialFraction: 0.5, minimumPrimary: 500, minimumSecondary: 460) {
              primaryViewer
            } secondary: {
              documentPane(secondaryDocument).padding(.horizontal, 4)
            }
            .frame(width: max(geometry.size.width, QueueInspectorLayout.documentPairMinimumWidth), height: geometry.size.height)
          } else {
            // One layout for the resting and drag-preview states, so the open
            // document slides left to make room instead of being replaced.
            let previewing = previewsSplit
            PlanPaneSplit(
              initialFraction: previewing ? 0.5 : 0.74, minimumPrimary: QueueInspectorLayout.documentMinimumWidth,
              minimumSecondary: previewing ? 460 : QueueInspectorLayout.chatMinimumWidth
            ) {
              leftViewer(previewing ? draggedTab.flatMap { sideDocuments.splitCompanion(for: $0) } : nil)
            } secondary: {
              if previewing {
                SplitDropPlaceholder()
              } else if let primaryDocument = sideDocuments.primaryDocument, sideDocuments.centralChatCollapsed {
                DocumentConversationPane(queue: model, scope: .task(ticket.id), document: primaryDocument)
              } else {
                conversation
              }
            }
            .frame(
              width: max(geometry.size.width, previewing
                ? QueueInspectorLayout.documentPairMinimumWidth : QueueInspectorLayout.inspectorMinimumWidth),
              height: geometry.size.height)
          }
        }.scrollIndicators(.automatic)
          .animation(.snappy(duration: 0.22), value: previewsSplit)
        }
      }
      .splitDropTarget(
        tabs: sideDocuments.tabs, dragged: $draggedTab, isTargeted: $isSplitTargeted
      ) { sideDocuments.split($0) }

    }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      .onAppear {
        rememberPresentedDocument()
        model.refreshUICanvases(ticketID: ticket.id)
        showRequestedCanvas()
      }
      .onChange(of: model.requestedUICanvas) { _, _ in showRequestedCanvas() }
      .onChange(of: model.presentedPlanURL) { _, _ in
        isEditing = false
        canvasSelection = nil
        rememberPresentedDocument()
      }
  }

  @ViewBuilder private var primaryViewer: some View {
    if let primaryDocument = sideDocuments.primaryDocument {
      documentPane(primaryDocument)
    } else {
      document
    }
  }

  /// The left pane, or what it will hold once a dragged tab splits off to the right.
  @ViewBuilder private func leftViewer(_ companion: DocumentSplitCompanion?) -> some View {
    switch companion {
    case .document(let url) where url != sideDocuments.primaryDocument: documentPane(url)
    case .centralContent where sideDocuments.primaryDocument != nil: document
    default: primaryViewer
    }
  }

  private func documentPane(_ url: URL) -> some View {
    SideDocumentPane(
      queue: model, scopeLabel: ticket.id, document: url,
      open: openDocument, close: { sideDocuments.close(url) },
      discuss: { discussDocument($0, for: url) },
      dragStarted: { draggedTab = $0 })
  }

  private var document: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !showsWorkspaceMap, let context = model.taskContexts[ticket.id] {
        DocumentMetadataStrip(url: URL(fileURLWithPath: context.planPath), taskID: ticket.id)
      }
      if showsWorkspaceMap {
        WorkspaceMapView(queue: model, ticket: ticket, model: workspaceMap,
          openDocument: { url in openDocument(url) },
          discuss: { context in
            sideDocuments.centralChatCollapsed = false
            if !chatDraft.isEmpty { chatDraft += "\n\n" }
            chatDraft += context
            canvasSelection = nil
            composerFocusRequest &+= 1
          })
      } else {
        ZStack(alignment: .topLeading) {
          VStack(alignment: .leading, spacing: 8) {
            if model.isPlanLoading {
              ProgressView("Loading central plan…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.planError, model.presentedPlanMarkdown.isEmpty {
              ContentUnavailableView {
                Label("Could not load this plan", systemImage: "doc.badge.ellipsis")
              } description: {
                Text(error)
              } actions: {
                Button("Retry") { model.openPlan(for: ticket, sourceURL: model.presentedPlanURL) }
              }
            } else {
              if model.presentedPlanURL == nil, model.planEditDrafts[ticket.id] != nil {
                HStack {
                  Text("Saved draft available").font(.caption).foregroundStyle(.secondary)
                  Spacer()
                  Button("Resume edit") {
                    editDraft = model.planEditDrafts[ticket.id]!.markdown
                    editBaseline = model.planEditDrafts[ticket.id]!.baseline
                    isEditing = true
                  }
                  Button("Discard draft") { model.discardPlanDraft(ticketID: ticket.id) }
                }
              }
              modeIndicator
              EmbeddedPlanDocument(
                markdown: model.presentedPlanMarkdown, sourceURL: sourceURL,
                appearance: model.appearance, accentStyle: model.accentStyle,
                canvasSelection: canvasSelection,
                open: { url in
                  openDocument(url)
                },
                select: { action in
                  canvasSelection = action.selection
                  if !action.initialText.isEmpty { chatDraft += action.initialText }
                  composerFocusRequest &+= 1
                },
                findQuery: planFind.query,
                findRequest: planFind.request,
                findSearchesBackwards: planFind.searchesBackwards
              )
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .overlay(
                RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1)
                  .allowsHitTesting(false)
              )
            }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .opacity(isEditing ? 0 : 1).allowsHitTesting(!isEditing).accessibilityHidden(isEditing)
          if isEditing {
            VStack(alignment: .leading, spacing: 8) {
              if editBaseline != model.presentedPlanMarkdown {
                VStack(alignment: .leading, spacing: 6) {
                  Text(
                    "Another agent changed the plan. Merge the latest changes into your draft before saving."
                  )
                  .font(.caption).foregroundStyle(.orange)
                  DisclosureGroup("Latest saved version") {
                    ScrollView {
                      Text(model.presentedPlanMarkdown).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                  }.font(.caption)
                }
              }
              modeIndicator
              TextEditor(text: $editDraft).font(.system(size: 13, design: .monospaced))
                .accessibilityLabel("Central plan Markdown")
                .onChange(of: editDraft) { _, text in
                  model.updatePlanDraft(text, baseline: editBaseline, ticketID: ticket.id)
                }
              HStack {
                Text("Save in the top bar writes an archive snapshot. Conflicting agent edits are preserved.")
                  .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Keep draft") { isEditing = false }.disabled(isSaving)
              }
            }
          }
        }
      }
    }.frame(
      minWidth: QueueInspectorLayout.documentMinimumWidth, idealWidth: 540,
      maxWidth: .infinity, minHeight: 180, maxHeight: .infinity
    )
    .padding(.horizontal, 4)
  }

  private var documentTabBar: some View {
    ScrollView(.horizontal) {
      HStack(alignment: .firstTextBaseline, spacing: 18) {
        documentTab("Central plan", isSelected: isCentralPlanVisible) {
          sideDocuments.showCentralContent()
          showsWorkspaceMap = false
          selectedCanvasKey = nil
          model.openPlan(for: ticket)
        }
        documentTab("Map", isSelected: sideDocuments.primaryDocument == nil && showsWorkspaceMap && selectedCanvasKey == nil) {
          sideDocuments.showCentralContent()
          showsWorkspaceMap = true
          selectedCanvasKey = nil
          canvasSelection = nil
        }
          .help("See this task’s workspaces, agents, and files")
        ForEach(model.visibleUICanvases(ticketID: ticket.id)) { canvas in
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "paintbrush.pointed").font(.system(size: 11)).foregroundStyle(.secondary)
            documentTab(canvas.displayTitle, isSelected: presentedCanvas?.key == canvas.key) {
              selectCanvas(canvas.key)
            }
            if canvas.isEnded {
              Image(systemName: "checkmark.circle").font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityLabel("Canvas session ended")
            }
            Button { closeCanvasTab(canvas.key) } label: {
              Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(canvas.displayTitle) canvas")
          }
          .help("UI Canvas · \(canvas.file)")
        }
        ForEach(sideDocuments.tabs, id: \.self) { url in
          HStack(alignment: .firstTextBaseline, spacing: 5) {
            documentTab(
              url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString),
              isSelected: sideDocuments.primaryDocument == url || sideDocuments.secondaryDocument == url
            ) {
              showsWorkspaceMap = false
              selectedCanvasKey = nil
              sideDocuments.select(url)
            }
            if sideDocuments.secondaryDocument == url {
              Image(systemName: "rectangle.righthalf.inset.filled")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .accessibilityLabel("Shown in split view")
            }
            Button { closeTab(url) } label: {
              Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(url.lastPathComponent)")
          }
          .documentDrag(url) { draggedTab = $0 }
          .help(url.absoluteString)
          .contextMenu {
            if sideDocuments.secondaryDocument == url {
              Button("Close Split View", systemImage: "rectangle") { sideDocuments.endSplit() }
            } else if sideDocuments.canSplit(url) {
              Button("Open in Split View", systemImage: "rectangle.split.2x1") { toggleSplit(url) }
            }
            Button("Close Tab", systemImage: "xmark") { closeTab(url) }
          }
        }
      }
      .padding(.vertical, 2)
      .dropDestination(for: String.self) { identifiers, _ in
        draggedTab = nil
        guard let identifier = identifiers.last,
              let url = sideDocuments.tabs.first(where: { $0.absoluteString == identifier }) else { return false }
        showsWorkspaceMap = false
        sideDocuments.select(url)
        return true
      }
    }.scrollIndicators(.never)
      .disabled(isEditing || isSaving)
      .accessibilityLabel("Open documents")
  }

  /// Text tab: the selected document is bold primary, others stay readable gray.
  private func documentTab(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: isSelected ? 17 : 15, weight: isSelected ? .bold : .medium))
        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.62))
        .lineLimit(1)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  private var modeIndicator: some View {
    Label(
      isEditing ? "Edit source" : "View · select to discuss",
      systemImage: isEditing ? "pencil.line" : "cursorarrow.click.2"
    )
    .font(.system(size: 10.5, weight: .medium))
    .foregroundStyle(isEditing ? Color.orange : Color.secondary)
    .padding(.horizontal, 9).padding(.vertical, 6)
    .background(Color.secondary.opacity(0.09), in: Capsule())
  }

  /// Saves the central plan draft. A conflict with another agent's edit keeps
  /// the editor open; the reconciled-draft save is a deliberate click only.
  private func saveCentralPlanEdit() async -> Bool {
    guard isEditing, !isSaving else { return !isEditing }
    isSaving = true
    defer { isSaving = false }
    let expected = editBaseline == model.presentedPlanMarkdown ? editBaseline : model.presentedPlanMarkdown
    guard await model.savePlan(editDraft, expectedMarkdown: expected, ticketID: ticket.id) else { return false }
    isEditing = false
    return true
  }

  /// Closing a document tab saves its pending edit first; a refused save keeps it open.
  private func closeTab(_ url: URL) {
    if model.documentContentStore.saveBeforeClose(url) { sideDocuments.close(url) }
  }

  /// Closing the plan saves every pending edit. If any save is refused, the
  /// plan stays open so the error and the draft remain in view.
  private func closePlanSavingEdits() async {
    if isEditing {
      if editDraft == editBaseline { isEditing = false }
      else if editBaseline != model.presentedPlanMarkdown {
        // The editor already warns about the newer plan; never overwrite it silently.
        return
      } else if !(await saveCentralPlanEdit()) { return }
    }
    for url in sideDocuments.tabs {
      guard model.documentContentStore.saveBeforeClose(url) else {
        sideDocuments.select(url)
        return
      }
    }
    model.closePlan()
  }

  private func rememberPresentedDocument() {
    if let url = model.presentedPlanURL {
      openDocument(url)
      model.openPlan(for: ticket)
    }
  }

  private func openDocument(_ url: URL) {
    if presentedCanvas != nil {
      selectedCanvasKey = nil
      sideDocuments.open(url, in: .primary)
      return
    }
    sideDocuments.openLinkedDocument(url, besideCentralContent: showsWorkspaceMap)
  }

  private func selectCanvas(_ key: String) {
    if isEditing { isEditing = false }
    // Clear both panes but keep the document tabs, so the canvas fills the viewer.
    sideDocuments.dismiss()
    showsWorkspaceMap = false
    canvasSelection = nil
    selectedCanvasKey = key
  }

  private func closeCanvasTab(_ key: String) {
    model.dismissUICanvas(ticketID: ticket.id, key: key)
    if selectedCanvasKey == key { selectedCanvasKey = nil }
  }

  /// An agent opened a canvas for this task: bring its tab to the front.
  private func showRequestedCanvas() {
    guard let request = model.requestedUICanvas, request.ticketID == ticket.id else { return }
    model.refreshUICanvases(ticketID: ticket.id)
    selectCanvas(request.key)
    model.consumeUICanvasRequest(request)
  }

  private func discussDocument(_ action: PlanCanvasSelectionAction, for document: URL) {
    guard let documentConversation = model.documentConversation(for: document, ticketID: ticket.id) else { return }
    // The document chat replaces the central chat only beside the primary document.
    if document == sideDocuments.primaryDocument { sideDocuments.centralChatCollapsed = true }
    documentConversation.discuss(action)
  }

  /// Open `url` beside the document that was open before it, or leave the split.
  private func toggleSplit(_ url: URL) {
    if sideDocuments.hasSecondaryViewer {
      sideDocuments.endSplit()
    } else {
      sideDocuments.split(url)
    }
  }

  private var conversation: some View {
    VStack(alignment: .leading, spacing: 8) {
      QueueAgentChatView(
        model: model, draft: $chatDraft, title: "Task Chat", ticketID: ticket.id,
        canvasSelection: $canvasSelection, focusRequest: composerFocusRequest)
    }.padding(.horizontal, 4)
      .frame(
        minWidth: QueueInspectorLayout.chatMinimumWidth, idealWidth: 270,
        maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
  }
}

struct EmbeddedPlanDocument: NSViewRepresentable {
  let markdown: String
  let sourceURL: URL
  let appearance: QueueAppearance
  let accentStyle: QueueAccentStyle
  let canvasSelection: PlanCanvasSelection?
  let open: (URL) -> Void
  let select: (PlanCanvasSelectionAction) -> Void
  var findQuery = ""
  var findRequest = 0
  var findSearchesBackwards = false

  func makeCoordinator() -> Coordinator { Coordinator(open: open, select: select) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = Self.webConfiguration(coordinator: context.coordinator)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.uiDelegate = context.coordinator
    return view
  }

  /// Mirrors `--page` in `MarkdownHTMLRenderer`.
  static func pageBackground(_ appearance: QueueAppearance) -> NSColor {
    appearance == .dark
      ? NSColor(srgbRed: 0x24 / 255, green: 0x24 / 255, blue: 0x24 / 255, alpha: 1)
      : NSColor(srgbRed: 0xf3 / 255, green: 0xf3 / 255, blue: 0xf3 / 255, alpha: 1)
  }

  static func webConfiguration(coordinator: Coordinator) -> WKWebViewConfiguration {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    // Plan-authored scripts stay disabled. Selection and Mermaid run in the
    // app-owned isolated content world installed below.
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let userContentController = configuration.userContentController
    userContentController.addUserScript(
      WKUserScript(
        source: PlanCanvasWebRuntime.script(), injectionTime: .atDocumentEnd,
        forMainFrameOnly: true, in: .defaultClient))
    userContentController.add(
      coordinator, contentWorld: .defaultClient,
      name: PlanCanvasWebRuntime.messageHandlerName)
    return configuration
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    context.coordinator.open = open
    context.coordinator.select = select
    context.coordinator.sourceURL = sourceURL
    context.coordinator.updateCanvasSelection(canvasSelection, in: view)
    if let html = context.coordinator.htmlIfChanged(
      markdown: markdown, sourceURL: sourceURL,
      appearance: appearance, accentStyle: accentStyle)
    {
      // Match the page background so a reload never flashes the default white.
      view.underPageBackgroundColor = Self.pageBackground(appearance)
      view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
      context.coordinator.willLoadDocument()
      context.coordinator.pendingInitialLoad = true
      view.loadHTMLString(html, baseURL: sourceURL.deletingLastPathComponent())
    }
    context.coordinator.requestFind(
      query: findQuery, request: findRequest, searchesBackwards: findSearchesBackwards, in: view)
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
    view.uiDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(
      forName: PlanCanvasWebRuntime.messageHandlerName, contentWorld: .defaultClient)
  }

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, WKUIDelegate {
    private struct RenderInput: Equatable {
      let markdown: String
      let sourceURL: URL
      let appearance: QueueAppearance
      let accentStyle: QueueAccentStyle
    }
    private var lastInput: RenderInput?
    private var renderedCanvasSelection: PlanCanvasSelection?
    private var isDocumentLoaded = false
    private var handledFindRequest = 0
    private var pendingFind: (query: String, searchesBackwards: Bool)?
    var pendingInitialLoad = true
    var sourceURL = URL(fileURLWithPath: "/")
    var open: (URL) -> Void
    var select: (PlanCanvasSelectionAction) -> Void
    init(
      open: @escaping (URL) -> Void,
      select: @escaping (PlanCanvasSelectionAction) -> Void = { _ in }
    ) {
      self.open = open
      self.select = select
    }

    // Compare source inputs before Markdown parsing. Chat keystrokes, progress
    // heartbeats, and other unrelated SwiftUI updates must not re-render a plan.
    func htmlIfChanged(
      markdown: String, sourceURL: URL, appearance: QueueAppearance,
      accentStyle: QueueAccentStyle,
      render: (String, URL, QueueAccentStyle) -> String = {
        MarkdownHTMLRenderer.page(markdown: $0, sourceURL: $1, accentStyle: $2)
      }
    ) -> String? {
      let input = RenderInput(
        markdown: markdown, sourceURL: sourceURL, appearance: appearance,
        accentStyle: accentStyle)
      guard input != lastInput else { return nil }
      lastInput = input
      return EmbeddedDocumentLink.routeLocalLinks(
        in: render(markdown, sourceURL, accentStyle), sourceURL: sourceURL
      )
      .replacingOccurrences(
        of: "default-src 'none';",
        with: PlanCanvasWebRuntime.mermaidScriptSource().map {
          "default-src 'none'; script-src \($0);"
        } ?? "default-src 'none';"
      )
      .replacingOccurrences(of: "img-src file: data: https: http:", with: "img-src file: data:")
      .replacingOccurrences(
        of: "media-src file: data: https: http:", with: "media-src file: data:"
      )
      .replacingOccurrences(
        of: "color-scheme: light dark", with: "color-scheme: \(appearance.rawValue)")
    }

    func updateCanvasSelection(_ selection: PlanCanvasSelection?, in webView: WKWebView) {
      guard selection != renderedCanvasSelection else { return }
      let shouldClear = selection == nil && renderedCanvasSelection != nil
      renderedCanvasSelection = selection
      guard shouldClear else { return }
      webView.evaluateJavaScript(
        "window.__eccFocusQueuePlanCanvas?.clearSelection();",
        in: nil, in: .defaultClient,
        completionHandler: nil)
    }

    func willLoadDocument() {
      isDocumentLoaded = false
    }

    func requestFind(
      query: String, request: Int, searchesBackwards: Bool, in webView: WKWebView
    ) {
      guard request > handledFindRequest else { return }
      handledFindRequest = request
      pendingFind = query.isEmpty ? nil : (query, searchesBackwards)
      performPendingFind(in: webView)
    }

    private func performPendingFind(in webView: WKWebView) {
      guard isDocumentLoaded, let pendingFind else { return }
      self.pendingFind = nil
      let configuration = WKFindConfiguration()
      configuration.backwards = pendingFind.searchesBackwards
      configuration.caseSensitive = false
      configuration.wraps = true
      webView.find(pendingFind.query, configuration: configuration) { _ in }
    }

    func userContentController(
      _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      guard message.name == PlanCanvasWebRuntime.messageHandlerName,
        message.frameInfo.isMainFrame,
        let action = PlanCanvasWebRuntime.selectionAction(from: message.body, sourceURL: sourceURL)
      else { return }
      renderedCanvasSelection = action.selection
      select(action)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      if let url = navigationAction.request.url, let target = EmbeddedDocumentLink.destination(url),
         EmbeddedDocumentPolicy.allowsLink(target) { open(target) }
      return nil
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      if action.navigationType == .linkActivated, let url = action.request.url {
        if let destination = EmbeddedDocumentLink.destination(url),
          EmbeddedDocumentPolicy.allowsLink(destination)
        {
          open(destination)
        }
        decisionHandler(.cancel)
      } else if pendingInitialLoad, action.navigationType == .other,
        ["about", "file"].contains(action.request.url?.scheme ?? ""),
        action.targetFrame?.isMainFrame != false
      {
        pendingInitialLoad = false
        decisionHandler(.allow)
      } else {
        decisionHandler(.cancel)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      isDocumentLoaded = true
      performPendingFind(in: webView)
    }
  }
}

struct NewTaskAgentView: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  var targetSubtask: TaskSubtask?
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var prompt = ""
  @AppStorage("newAgentProvider") private var storedProvider: AgentProvider?
  private var provider: AgentProvider {
    get { model.preferredNewAgentProvider(stored: storedProvider) }
    nonmutating set { storedProvider = newValue }
  }
  @State private var repository = ""
  @State private var modelName = ""
  @State private var effort = ""
  // On, matching the other launch surfaces: off opens the agent at an empty
  // input and even drops the typed work description.
  @State private var includePrompt = true
  @State private var role: AgentContractRole = .engineering
  @State private var assignmentID = UUID().uuidString
  @State private var workspacePreview = WorkspacePreviewModel()
  @State private var isStarting = false
  @State private var launchError: String?
  @State private var repositoryMatchesProject: Bool?
  @State private var allowsOtherRepository = false
  private var sourceWorkspace: AgentWorkspace? {
    workspacePreview.workspace?.path == repository ? workspacePreview.workspace : nil
  }
  private var workspaceBlockReason: String? {
    workspacePreview.launchBlockReason(path: repository, policy: .isolatedCommittedSnapshot)
  }
  private var sourceHasChanges: Bool {
    sourceWorkspace != nil && workspacePreview.hasUncommittedChanges == true
  }
  @AppStorage("agentUsesTmux") private var useTmux = true

  private var tmuxAvailable: Bool {
    guard let executable = model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux") else { return false }
    return FileManager.default.isExecutableFile(atPath: executable)
  }
  private var requiresTmux: Bool {
    model.config.wezTerm.terminalApp.requiresTmux
  }
  private var name: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var preview: String {
    guard let context = model.taskContexts[ticket.id] else { return "Task context will be prepared at launch." }
    var subtask = TaskSubtask(id: assignmentID, title: name,
      assignmentDescription: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
      provider: provider)
    subtask.workspace = proposedWorkspace
    subtask.initialPrompt = prompt
    if !modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || role == .orchestrator {
      subtask.launchConfiguration = AgentLaunchConfiguration(
        model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
        effort: effort.trimmingCharacters(in: .whitespacesAndNewlines),
        role: role == .orchestrator ? role.rawValue : nil)
    }
    return context.agentPrompt(subtask: subtask)
  }

  /// A directory without a Git repository hosts the agent directly: isolation
  /// is suggested, not required.
  private var sourceIsPlainDirectory: Bool {
    sourceWorkspace != nil && sourceWorkspace?.baseCommit == nil
  }

  private var proposedWorkspace: AgentWorkspace {
    var workspace = sourceWorkspace ?? AgentWorkspace(path: repository, repositoryPath: repository)
    guard !sourceIsPlainDirectory else { return workspace }
    workspace.path = model.proposedAgentWorktreePath(repositoryPath: workspace.repositoryPath,
      ticketID: ticket.id, subtaskID: assignmentID)
    workspace.branch = "focus-queue/\(ticket.id.lowercased())-\(assignmentID.lowercased())"
    workspace.managed = true
    return workspace
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(targetSubtask == nil ? "New work item" : "Start work item") · \(ticket.id)").font(.title2.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Title").font(.headline)
          TextField("Short, specific name", text: $title)
            .accessibilityLabel("Work item title")
          Text("Brief work description").font(.headline)
          TextEditor(text: $prompt).font(.body).frame(minHeight: 130, maxHeight: 180)
            .padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            .accessibilityLabel("Work item description")
          Text("Every item keeps this title and description with its agent, workspace, and terminal.")
            .font(.caption).foregroundStyle(.secondary)
          Picker("Provider", selection: Binding(get: { provider }, set: { provider = $0 })) {
            ForEach(AgentProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }.pickerStyle(.segmented)
          HStack {
            Picker("Model", selection: $modelName) {
              ForEach(model.agentModelChoices(for: provider)) { choice in
                Text(choice.label).tag(choice.model ?? "")
              }
            }.accessibilityLabel("Agent model")
            Picker("Effort", selection: $effort) {
              Text("Default").tag("")
              ForEach(AppConfiguration.agentEffortLevels(for: provider), id: \.self) { level in
                Text(level).tag(level)
              }
            }.accessibilityLabel("Agent reasoning effort")
          }
          .onChange(of: provider) { _, _ in
            if !model.agentModelChoices(for: provider).contains(where: { ($0.model ?? "") == modelName }) {
              modelName = ""
            }
            if !AppConfiguration.agentEffortLevels(for: provider).contains(effort) { effort = "" }
          }
          Text("Explicit model and effort choices are saved with the agent and reused for exact conversation recall. Leave them on Default to use your alias or provider defaults.")
            .font(.caption).foregroundStyle(.secondary)
          TextField("Source checkout", text: $repository).accessibilityLabel("Source checkout")
          if let project = model.project(for: ticket) {
            Text("Project: \(project.name)").font(.caption).foregroundStyle(.secondary)
            if repositoryMatchesProject == false {
              Text("This checkout could not be matched to the repository for \(project.name). The task's project and existing workspaces will stay unchanged.")
                .font(.caption).foregroundStyle(.orange)
              Toggle("Use this repository for this agent", isOn: $allowsOtherRepository)
            }
          }
          Text(sourceIsPlainDirectory
            ? "No Git repository here, so this agent runs directly in the folder. Git is suggested for worktree isolation, not required."
            : "Each new agent gets its own worktree and branch from this checkout's current commit. Reopening an agent reuses its workspace.")
            .font(.caption).foregroundStyle(.secondary)
          if let workspaceBlockReason {
            Text(workspaceBlockReason).font(.caption)
              .foregroundStyle(workspacePreview.error == nil ? Color.secondary : Color.orange)
          }
          if sourceHasChanges {
            Text("Uncommitted changes stay in the source checkout. This agent starts from the committed version and will not see those edits.")
              .font(.caption).foregroundStyle(.orange)
          }
          Text("Agent workspace: \(proposedWorkspace.path)")
            .font(.caption).textSelection(.enabled)
          Text("Branch: \(proposedWorkspace.branch ?? (sourceIsPlainDirectory ? "none (no Git repository)" : (sourceWorkspace == nil ? "checking…" : "detached at \(String((sourceWorkspace?.baseCommit ?? "").prefix(8)))")))")
            .font(.caption).textSelection(.enabled)
          if let sourceWorkspace, !sourceIsPlainDirectory {
            Text("Source: \(sourceWorkspace.branch ?? "unknown") at \(String((sourceWorkspace.baseCommit ?? "").prefix(8)))")
              .font(.caption).foregroundStyle(.secondary)
          }
          Picker("Role", selection: $role) {
            Text("Engineering").tag(AgentContractRole.engineering)
            Text("Orchestrator").tag(AgentContractRole.orchestrator)
          }
          .pickerStyle(.segmented)
          .accessibilityLabel("Agent role")
          Text(role == .orchestrator
            ? "Gets the project's signed orchestrator contract instead of the engineering one, and plans, assigns, reviews, and closes work."
            : "Gets the project's signed engineering contract, if the project has one.")
            .font(.caption).foregroundStyle(.secondary)
          Toggle("Include detailed task instructions", isOn: $includePrompt)
          Text("Task identity remains in the launch environment. When this is off, the agent opens at an empty input. Turning it on adds the full assignment and reporting instructions.")
            .font(.caption).foregroundStyle(.secondary)
          if includePrompt {
            DisclosureGroup("Initialization prompt preview") {
              Text(preview).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          Toggle("Open in tmux", isOn: Binding(
            get: { tmuxAvailable && (requiresTmux || useTmux) },
            set: { useTmux = $0 }))
            .disabled(!tmuxAvailable || requiresTmux)
          Text("tmux keeps the process alive after closing its terminal. A stopped agent can resume its saved conversation in a new terminal.")
            .font(.caption).foregroundStyle(.secondary)
          if requiresTmux {
            Text("macOS Terminal uses tmux for reliable launch and recall.")
              .font(.caption).foregroundStyle(.secondary)
          }
          Text("Uses your login shell's codex, claude, or kimi alias, function, or command and custom flags.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(2).disabled(isStarting)
      }
      if let launchError {
        Text(launchError).font(.callout).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          .accessibilityLabel("Agent launch error: \(launchError)")
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.disabled(isStarting)
        Button(isStarting ? "Starting…" : "Start agent") {
          isStarting = true
          launchError = nil
          model.launchAgent(for: ticket, title: name, provider: provider, repositoryPath: repository,
            assignmentDescription: prompt,
            includePrompt: includePrompt, useTmux: tmuxAvailable && (requiresTmux || useTmux),
            initialPrompt: prompt, tracksCompletion: true,
            subtaskID: targetSubtask?.id ?? assignmentID,
            allowProjectRepositoryMismatch: allowsOtherRepository,
            parentSubtaskID: nil, createAssignment: false,
            modelName: modelName, effort: effort,
            workspacePolicy: .isolatedCommittedSnapshot, role: role) { started in
              isStarting = false
              if started { dismiss() }
              else { launchError = model.actionMessages[ticket.id] ?? "Agent could not start. Check the workspace and try again." }
            }
          model.rememberAgentLaunch(AgentLaunchPreset(
            provider: provider, model: modelName, effort: effort,
            workspacePolicy: .isolatedCommittedSnapshot,
            useTmux: tmuxAvailable && (requiresTmux || useTmux), includePrompt: includePrompt))
        }.buttonStyle(.borderedProminent)
          .disabled(isStarting || name.isEmpty
            || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || model.launchingTaskIDs.contains(ticket.id) || workspaceBlockReason != nil
            || (requiresTmux && !tmuxAvailable)
            // Only a project with a bound repository can reject a mismatched checkout.
            || (model.project(for: ticket).map { !$0.repositoryPath.isEmpty } == true
              && repositoryMatchesProject != true && !allowsOtherRepository))
      }
    }.padding(24).frame(width: 540, height: 660)
      .interactiveDismissDisabled(isStarting)
      .task(id: repository) {
        allowsOtherRepository = false
        repositoryMatchesProject = nil
        await workspacePreview.load(path: repository)
        if let project = model.project(for: ticket), !project.repositoryPath.isEmpty {
          let matches = (try? await ProjectRepositoryResolver().matches(path: repository, project: project)) ?? false
          if !Task.isCancelled { repositoryMatchesProject = matches }
        }
      }
      .onAppear {
        if let targetSubtask {
          assignmentID = targetSubtask.id
          title = targetSubtask.title
          prompt = targetSubtask.workDescription
          provider = targetSubtask.provider
          modelName = targetSubtask.launchConfiguration?.model ?? ""
          effort = targetSubtask.launchConfiguration?.effort ?? ""
        } else {
          title = ""
          prompt = ""
          modelName = ""
          effort = ""
        }
        repository = targetSubtask?.workspace?.path ?? model.defaultRepository(for: ticket)
      }
  }
}
