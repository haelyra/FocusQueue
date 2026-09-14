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
  @State private var documentTabs = PlanDocumentTabs()
  @State private var canvasSelection: PlanCanvasSelection?
  @State private var composerFocusRequest = 0
  @State private var showsWorkspaceMap = false
  @State private var workspaceMap = WorkspaceMapModel()

  private var sourceURL: URL {
    model.presentedPlanURL ?? URL(fileURLWithPath: model.taskContexts[ticket.id]?.planPath ?? "/")
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack(alignment: .top, spacing: 8) {
        Image(systemName: "square.grid.2x2.fill")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 34, height: 34)
          .background(
            LinearGradient(
              colors: [Color.accentColor, Color.accentColor.opacity(0.62)],
              startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 9))
        VStack(alignment: .leading, spacing: 3) {
          Text(showsWorkspaceMap ? "Workspace map" : (model.presentedPlanURL == nil ? "Central plan" : "Supporting document"))
            .font(.system(size: 20, weight: .bold, design: .rounded))
          Text("\(ticket.id) · \(ticket.title)").font(.caption).foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Spacer()
        Label(
          isEditing ? "Edit source" : "View · select to discuss",
          systemImage: isEditing ? "pencil.line" : "cursorarrow.click.2"
        )
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(isEditing ? Color.orange : Color.secondary)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.09), in: Capsule())
        Menu {
          Button("Central plan") { showsWorkspaceMap = false; model.openPlan(for: ticket) }
          ForEach(ticket.planLinks) { link in
            Button(link.label) {
              if let url = ResourceLocator.url(for: link.url), url.isFileURL,
                ["md", "markdown"].contains(url.pathExtension.lowercased())
              {
                openDocument(url)
              } else {
                model.open(link.url)
              }
            }
          }
        } label: {
          Image(systemName: "doc.on.doc").frame(width: 40, height: 40)
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(isEditing)
        .help("Choose the central plan or a supporting document").accessibilityLabel("Choose plan")
        if model.presentedPlanURL == nil {
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

      GeometryReader { geometry in
        ScrollView(.horizontal) {
          HSplitView {
            if model.windowPlacement == .upperRight { conversation }
            document
            if model.windowPlacement != .upperRight { conversation }
          }
          .frame(
            width: max(geometry.size.width, QueueInspectorLayout.inspectorMinimumWidth),
            height: geometry.size.height)
        }.scrollIndicators(.automatic)
      }
    }.frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
      .onAppear { rememberPresentedDocument() }
      .onChange(of: model.presentedPlanURL) { _, _ in
        isEditing = false
        canvasSelection = nil
        rememberPresentedDocument()
      }
  }

  private var document: some View {
    VStack(spacing: 8) {
      documentTabBar
      if showsWorkspaceMap {
        WorkspaceMapView(queue: model, ticket: ticket, model: workspaceMap,
          openDocument: { url in showsWorkspaceMap = false; openDocument(url) },
          discuss: { context in
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
      } else if model.presentedPlanMarkdown.isEmpty && model.planError == nil {
        ProgressView("Loading central plan…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if EmbeddedDocumentLink.documentURL(url) != nil {
              openDocument(url)
            } else {
              model.open(url.absoluteString)
            }
          },
          select: { action in
            canvasSelection = action.selection
            if !action.initialText.isEmpty { chatDraft += action.initialText }
            composerFocusRequest &+= 1
          }
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
        Button("Central plan") { showsWorkspaceMap = false; model.openPlan(for: ticket) }
          .buttonStyle(.bordered)
          .tint(model.presentedPlanURL == nil && !showsWorkspaceMap ? .accentColor : .secondary)
        Button("Map") { showsWorkspaceMap = true; canvasSelection = nil }
          .buttonStyle(.bordered).tint(showsWorkspaceMap ? .accentColor : .secondary)
          .help("See this task’s workspaces, agents, and files")
        ForEach(documentTabs.urls, id: \.self) { url in
          HStack(spacing: 4) {
            Button(url.lastPathComponent) { openDocument(url) }
              .buttonStyle(.plain).lineLimit(1)
            Button {
              documentTabs.close(url)
              if model.presentedPlanURL == url { model.openPlan(for: ticket) }
            } label: {
              Image(systemName: "xmark").font(.caption2)
            }.buttonStyle(.plain).accessibilityLabel("Close \(url.lastPathComponent)")
          }
          .padding(.horizontal, 9).padding(.vertical, 6)
          .background(
            model.presentedPlanURL == url && !showsWorkspaceMap
              ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
            in: RoundedRectangle(cornerRadius: 6)
          )
          .help(url.path)
        }
      }.padding(.vertical, 2)
    }.disabled(isEditing || isSaving)
      .accessibilityLabel("Open documents")
  }

  private func rememberPresentedDocument() {
    if let url = model.presentedPlanURL { documentTabs.open(url) }
  }

  private func openDocument(_ url: URL) {
    showsWorkspaceMap = false
    guard let documentURL = EmbeddedDocumentLink.documentURL(url) else { return }
    let centralURL = model.taskContexts[ticket.id].map { URL(fileURLWithPath: $0.planPath) }
    if documentURL == centralURL?.standardizedFileURL {
      model.openPlan(for: ticket)
    } else {
      documentTabs.open(documentURL)
      model.openPlan(for: ticket, sourceURL: documentURL)
    }
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
        minWidth: QueueInspectorLayout.chatMinimumWidth, idealWidth: 360,
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

  func makeCoordinator() -> Coordinator { Coordinator(open: open, select: select) }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = Self.webConfiguration(coordinator: context.coordinator)
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
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
    guard
      let html = context.coordinator.htmlIfChanged(
        markdown: markdown, sourceURL: sourceURL,
        appearance: appearance, accentStyle: accentStyle)
    else { return }
    view.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
    context.coordinator.pendingInitialLoad = true
    view.loadHTMLString(html, baseURL: sourceURL.deletingLastPathComponent())
  }

  static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
    view.stopLoading()
    view.navigationDelegate = nil
    view.configuration.userContentController.removeScriptMessageHandler(
      forName: PlanCanvasWebRuntime.messageHandlerName, contentWorld: .defaultClient)
  }

  @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private struct RenderInput: Equatable {
      let markdown: String
      let sourceURL: URL
      let appearance: QueueAppearance
      let accentStyle: QueueAccentStyle
    }
    private var lastInput: RenderInput?
    private var renderedCanvasSelection: PlanCanvasSelection?
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
  }
}

struct NewTaskAgentView: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var title = ""
  @State private var provider: AgentProvider = .codex
  @State private var repository = ""
  @AppStorage("agentIncludesInitializationPrompt") private var includePrompt = true
  @AppStorage("agentUsesTmux") private var useTmux = true

  private var tmuxAvailable: Bool {
    guard let executable = model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux") else {
      return false
    }
    return FileManager.default.isExecutableFile(atPath: executable)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("New agent · \(ticket.id)").font(.title2.weight(.semibold))
      Text(
        "Give this agent a clear assignment. Parallel subtasks share the task's worktree and central plan."
      )
      .font(.callout).foregroundStyle(.secondary)
      TextField("Clear subtask title, for example: Verify Telegram inbox polling", text: $title)
        .accessibilityLabel("Descriptive subtask title")
      Picker("Provider", selection: $provider) {
        ForEach(AgentProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
      }.pickerStyle(.segmented)
      TextField("Repository path", text: $repository).accessibilityLabel("Repository path")
      Toggle("Send task initialization prompt", isOn: $includePrompt)
        .help("Turn off to open your usual interactive session without submitting a message")
      Text(
        includePrompt
          ? "The agent receives its assignment, central plan, and progress instructions automatically."
          : "Opens an interactive session in the task worktree. No message is submitted; you choose what to ask."
      )
      .font(.caption).foregroundStyle(.secondary)
      Toggle(
        "Keep this agent running in tmux",
        isOn: Binding(
          get: { useTmux && tmuxAvailable },
          set: { useTmux = $0 }
        )
      )
      .disabled(!tmuxAvailable)
      .help("Keeps the agent alive when its terminal view closes")
      Text(
        tmuxAvailable
          ? (useTmux
            ? "The terminal can be closed and reopened without stopping this agent."
            : "This agent belongs to its WezTerm window. Closing that window ends the live session.")
          : "tmux is not available, so this agent will run directly in WezTerm."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "Uses your login shell's codex or claude alias, function, or command, including your custom flags and terminal setup."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text(
        "An existing task worktree is reused. A main checkout gets a dedicated task branch and worktree."
      )
      .font(.caption).foregroundStyle(.secondary)
      Text("The title appears in every agent list, so describe the outcome instead of using a number.")
        .font(.caption).foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Start agent") {
          model.launchAgent(
            for: ticket, title: title, provider: provider, repositoryPath: repository,
            includePrompt: includePrompt, useTmux: useTmux && tmuxAvailable)
          dismiss()
        }.buttonStyle(.borderedProminent)
          .disabled(
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !repository.hasPrefix("/"))
      }
    }.padding(24).frame(width: 430)
      .onAppear {
        title = ticket.next.map { String($0.prefix(100)) } ?? "Implement \(ticket.title)"
        let context = model.taskContexts[ticket.id]
        repository =
          [
            context?.worktreePath, context?.repositoryPath, ticket.worktree,
            model.config.workspacePath,
          ]
          .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
          ?? model.config.workspacePath
      }
  }
}
