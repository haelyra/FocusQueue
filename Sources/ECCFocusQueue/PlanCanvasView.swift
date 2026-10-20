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
  @State private var showsTaskSessions = false
  @State private var planFind = DocumentFindState()

  private var sourceURL: URL {
    model.presentedPlanURL ?? URL(fileURLWithPath: model.taskContexts[ticket.id]?.planPath ?? "/")
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "square.grid.2x2.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 34, height: 34)
          .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 3) {
          Text(
            showsWorkspaceMap ? "Workspace map"
              : (sideDocuments.primaryDocument?.lastPathComponent ?? (model.presentedPlanURL == nil ? "Central plan" : "Supporting document"))
          )
            .font(.system(size: 20, weight: .bold, design: .rounded))
          HStack(spacing: 4) {
            Text("\(ticket.id) ·")
            RenamableTaskTitle(
              ticket: ticket, model: model, size: 11, weight: .regular,
              maximumLines: 2)
          }
          .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Sessions", systemImage: "rectangle.split.2x2") { showsTaskSessions = true }
          .help("Open this task's tmux panes and layout")
        Label(
          isEditing ? "Edit source" : "View · select to discuss",
          systemImage: isEditing ? "pencil.line" : "cursorarrow.click.2"
        )
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(isEditing ? Color.orange : Color.secondary)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.09), in: Capsule())
        Menu {
          Button("Central plan") {
            sideDocuments.showCentralContent()
            showsWorkspaceMap = false
            model.openPlan(for: ticket)
          }
          ForEach(ticket.planLinks) { link in
            Button(link.label) {
              if let url = ResourceLocator.url(for: link.url) { openDocument(url) }
            }
          }
        } label: {
          Image(systemName: "doc.on.doc").frame(width: 40, height: 40)
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(isEditing)
        .help("Choose the central plan or a supporting document").accessibilityLabel("Choose plan")
        if model.presentedPlanURL == nil, sideDocuments.primaryDocument == nil {
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
          model.closePlan()
        } label: {
          Image(systemName: "xmark")
        }
        .buttonStyle(.plain).frame(width: 40, height: 40)
        .help("Collapse the plan and return to the queue").accessibilityLabel("Close plan")
      }
      .padding(12)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
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
          if model.isQueueAgentResponding && model.respondingTicketID == ticket.id {
            ProgressView().controlSize(.mini)
            Text("Central conversation is still working").font(.caption).foregroundStyle(.secondary)
          }
          Spacer()
        }
      }
      GeometryReader { geometry in
        ScrollView(.horizontal) {
          if let secondaryDocument = sideDocuments.secondaryDocument {
            PlanPaneSplit(initialFraction: 0.5, minimumPrimary: 500, minimumSecondary: 460) {
              primaryViewer
            } secondary: {
              SideDocumentPane(
                queue: model, ticket: ticket, document: secondaryDocument,
                open: openDocument, close: { sideDocuments.close(secondaryDocument) },
                receiveDocument: moveDocumentToSecondary,
                discuss: { discussDocument($0, for: secondaryDocument) })
                .padding(.horizontal, 4)
            }
            .frame(width: max(geometry.size.width, QueueInspectorLayout.documentPairMinimumWidth), height: geometry.size.height)
          } else if let primaryDocument = sideDocuments.primaryDocument {
            PlanPaneSplit(initialFraction: 0.74, minimumPrimary: QueueInspectorLayout.documentMinimumWidth,
                          minimumSecondary: QueueInspectorLayout.chatMinimumWidth) {
              primaryViewer
            } secondary: {
              if sideDocuments.centralChatCollapsed {
                DocumentConversationPane(queue: model, ticket: ticket, document: primaryDocument)
              } else {
                conversation
              }
            }
            .frame(width: max(geometry.size.width, QueueInspectorLayout.inspectorMinimumWidth), height: geometry.size.height)
          } else {
            PlanPaneSplit(initialFraction: 0.74, minimumPrimary: QueueInspectorLayout.documentMinimumWidth,
                          minimumSecondary: QueueInspectorLayout.chatMinimumWidth) {
              document
            } secondary: { conversation }
            .frame(width: max(geometry.size.width, QueueInspectorLayout.inspectorMinimumWidth), height: geometry.size.height)
          }
        }.scrollIndicators(.automatic)
      }

    }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      .sheet(isPresented: $showsTaskSessions) { TaskSessionsView(model: model, initialTaskID: ticket.id) }
      .onAppear { rememberPresentedDocument() }
      .onChange(of: model.presentedPlanURL) { _, _ in
        isEditing = false
        canvasSelection = nil
        rememberPresentedDocument()
      }
  }

  @ViewBuilder private var primaryViewer: some View {
    if let primaryDocument = sideDocuments.primaryDocument {
      VStack(spacing: 8) {
        documentTabBar
        SideDocumentPane(
          queue: model, ticket: ticket, document: primaryDocument,
          open: openDocument, close: { sideDocuments.close(primaryDocument) },
          receiveDocument: moveDocumentToSecondary,
          discuss: { discussDocument($0, for: primaryDocument) })
      }
    } else {
      document
    }
  }

  private var document: some View {
    VStack(spacing: 8) {
      documentTabBar
      if !showsWorkspaceMap, let context = model.taskContexts[ticket.id] {
        DocumentMetadataStrip(url: URL(fileURLWithPath: context.planPath), taskID: ticket.id)
      }
      if !showsWorkspaceMap, !isEditing {
        DocumentFindBar(state: planFind)
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
      } else if isEditing {
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
        TextEditor(text: $editDraft).font(.system(size: 13, design: .monospaced))
          .accessibilityLabel("Central plan Markdown")
          .onChange(of: editDraft) { _, text in
            model.updatePlanDraft(text, baseline: editBaseline, ticketID: ticket.id)
          }
        HStack {
          Text("Saves an archive snapshot. Conflicting agent edits are preserved.")
            .font(.caption2).foregroundStyle(.secondary)
          Spacer()
          Button("Keep draft") { isEditing = false }.disabled(isSaving)
          Button(
            editBaseline == model.presentedPlanMarkdown ? "Save plan" : "Save reconciled draft"
          ) {
            isSaving = true
            let expected =
              editBaseline == model.presentedPlanMarkdown
              ? editBaseline : model.presentedPlanMarkdown
            Task {
              if await model.savePlan(editDraft, expectedMarkdown: expected, ticketID: ticket.id) {
                isEditing = false
              }
              isSaving = false
            }
          }.buttonStyle(.borderedProminent).disabled(isSaving)
        }
      } else if model.isPlanLoading {
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
    }.frame(
      minWidth: QueueInspectorLayout.documentMinimumWidth, idealWidth: 540,
      maxWidth: .infinity, minHeight: 180, maxHeight: .infinity
    )
    .padding(.horizontal, 4)
  }

  private var documentTabBar: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 6) {
        Button("Central plan") {
          sideDocuments.showCentralContent()
          showsWorkspaceMap = false
          model.openPlan(for: ticket)
        }
          .buttonStyle(.bordered)
          .tint(model.presentedPlanURL == nil && !showsWorkspaceMap ? .accentColor : .secondary)
          .background(Color(nsColor: .controlBackgroundColor).opacity(0.96), in: Capsule())
          .overlay(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
        Button("Map") {
          sideDocuments.showCentralContent()
          showsWorkspaceMap = true
          canvasSelection = nil
        }
          .buttonStyle(.bordered).tint(showsWorkspaceMap ? .accentColor : .secondary)
          .background(Color(nsColor: .controlBackgroundColor).opacity(0.96), in: Capsule())
          .overlay(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
          .help("See this task’s workspaces, agents, and files")
        ForEach(sideDocuments.tabs, id: \.self) { url in
          HStack(spacing: 4) {
            Button(url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString)) {
              showsWorkspaceMap = false
              sideDocuments.select(url)
            }
            .lineLimit(1)
            Button { sideDocuments.close(url) } label: {
              Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .accessibilityLabel("Close \(url.lastPathComponent)")
          }
          .font(.caption.weight(.medium))
          .foregroundStyle(sideDocuments.primaryDocument == url ? Color.accentColor : Color.primary)
          .padding(.horizontal, 8).padding(.vertical, 6)
          .background(
            Color(nsColor: .controlBackgroundColor).opacity(sideDocuments.primaryDocument == url ? 0.98 : 0.94),
            in: RoundedRectangle(cornerRadius: 7))
          .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18), lineWidth: 1)
              .allowsHitTesting(false)
          )
          .draggable(url.absoluteString)
          .help(url.absoluteString)
        }
      }
      .padding(.vertical, 2)
      .dropDestination(for: String.self) { identifiers, _ in
        guard let identifier = identifiers.last,
              let url = sideDocuments.tabs.first(where: { $0.absoluteString == identifier }) else { return false }
        showsWorkspaceMap = false
        sideDocuments.select(url)
        return true
      }
    }.disabled(isEditing || isSaving)
      .accessibilityLabel("Open documents")
  }

  private func rememberPresentedDocument() {
    if let url = model.presentedPlanURL {
      openDocument(url)
      model.openPlan(for: ticket)
    }
  }

  private func openDocument(_ url: URL) {
    sideDocuments.openLinkedDocument(url, besideCentralContent: showsWorkspaceMap)
  }

  private func discussDocument(_ action: PlanCanvasSelectionAction, for document: URL) {
    guard let documentConversation = model.documentConversation(for: document, ticketID: ticket.id) else { return }
    if !documentConversation.draft.isEmpty { documentConversation.draft += "\n\n" }
    documentConversation.draft += "Selected passage: \(action.selection.excerpt)\n\(action.initialText)"
  }

  private func moveDocumentToSecondary(_ identifier: String) -> Bool {
    guard let url = sideDocuments.tabs.first(where: { $0.absoluteString == identifier }) else { return false }
    sideDocuments.moveToSecondary(url)
    return true
  }

  private var conversation: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Task orchestrator", systemImage: "terminal")
        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
      QueueAgentChatView(
        model: model, draft: $chatDraft, ticketID: ticket.id,
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
        "document.querySelectorAll('figure[data-plan-canvas-diagram].is-selected').forEach(function(element) { element.classList.remove('is-selected'); element.setAttribute('aria-pressed', 'false'); });",
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
  @State private var includePrompt = false
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
    model.config.wezTerm.applicationName.caseInsensitiveCompare("Terminal") == .orderedSame
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
      || !effort.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      subtask.launchConfiguration = AgentLaunchConfiguration(
        model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
        effort: effort.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    return context.agentPrompt(subtask: subtask)
  }

  private var proposedWorkspace: AgentWorkspace {
    var workspace = sourceWorkspace ?? AgentWorkspace(path: repository, repositoryPath: repository)
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
          Text("Each new agent gets its own worktree and branch from this checkout's current commit. Reopening an agent reuses its workspace.")
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
          Text("Branch: \(proposedWorkspace.branch ?? (sourceWorkspace == nil ? "checking…" : "detached at \(String((sourceWorkspace?.baseCommit ?? "").prefix(8)))"))")
            .font(.caption).textSelection(.enabled)
          if let sourceWorkspace {
            Text("Source: \(sourceWorkspace.branch ?? "unknown") at \(String((sourceWorkspace.baseCommit ?? "").prefix(8)))")
              .font(.caption).foregroundStyle(.secondary)
          }
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
            workspacePolicy: .isolatedCommittedSnapshot) { started in
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
            || (model.project(for: ticket) != nil && repositoryMatchesProject != true && !allowsOtherRepository))
      }
    }.padding(24).frame(width: 540, height: 660)
      .interactiveDismissDisabled(isStarting)
      .task(id: repository) {
        allowsOtherRepository = false
        repositoryMatchesProject = nil
        await workspacePreview.load(path: repository)
        if let project = model.project(for: ticket) {
          let matches = (try? await ProjectRepositoryResolver().matches(path: repository, project: project)) ?? false
          if !Task.isCancelled { repositoryMatchesProject = matches }
        }
      }
      .onAppear {
        includePrompt = false
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
