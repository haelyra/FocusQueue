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
          Text(model.presentedPlanURL == nil ? "Central plan" : "Supporting document")
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
          Button("Central plan") { model.openPlan(for: ticket) }
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
      if isEditing {
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
        Button("Central plan") { model.openPlan(for: ticket) }
          .buttonStyle(.bordered)
          .tint(model.presentedPlanURL == nil ? .accentColor : .secondary)
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
            model.presentedPlanURL == url
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
  var blank = false
  @Environment(\.dismiss) private var dismiss
  @State private var prompt = ""
  @AppStorage("newAgentProvider") private var provider: AgentProvider = .codex
  @State private var repository = ""
  @State private var includePrompt = true
  @State private var createWorktree = true
  @State private var assignmentID = UUID().uuidString
  @State private var sourceWorkspace: AgentWorkspace?
  @State private var workspaceError: String?
  @AppStorage("agentUsesTmux") private var useTmux = true

  private var tmuxAvailable: Bool {
    guard let executable = model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux") else { return false }
    return FileManager.default.isExecutableFile(atPath: executable)
  }
  private var name: String { TaskSubtask.agentName(prompt: prompt, provider: provider) }
  private var preview: String {
    guard let context = model.taskContexts[ticket.id] else { return "Task context will be prepared at launch." }
    var subtask = TaskSubtask(id: assignmentID, title: name, provider: provider)
    subtask.workspace = proposedWorkspace
    subtask.initialPrompt = prompt
    return context.agentPrompt(subtask: subtask)
  }

  private var proposedWorkspace: AgentWorkspace {
    var workspace = sourceWorkspace ?? AgentWorkspace(path: repository, repositoryPath: repository)
    if createWorktree {
      workspace.path = model.proposedAgentWorktreePath(subtaskID: assignmentID)
      workspace.branch = "focus-queue/\(ticket.id.lowercased())-\(assignmentID.lowercased())"
      workspace.managed = true
    }
    return workspace
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("\(blank ? "New blank agent" : "New agent") · \(ticket.id)").font(.title2.weight(.semibold))
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          Text("Initial prompt").font(.headline)
          TextEditor(text: $prompt).font(.body).frame(minHeight: 130, maxHeight: 180)
            .padding(6).overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
            .accessibilityLabel("Initial prompt")
          Text("Name: \(name)").font(.caption).foregroundStyle(.secondary)
          Picker("Provider", selection: $provider) {
            ForEach(AgentProvider.allCases, id: \.self) { Text($0.displayName).tag($0) }
          }.pickerStyle(.segmented)
          TextField("Workspace path", text: $repository).accessibilityLabel("Workspace path")
          Toggle("Create worktree", isOn: $createWorktree)
          Text(createWorktree
            ? "Creates a separate worktree and branch from the selected checkout's current commit. Uncommitted changes must be committed first."
            : "Uses the selected path and its current branch, including local changes.")
            .font(.caption).foregroundStyle(.secondary)
          Text("\(createWorktree ? "New worktree" : "Workspace"): \(proposedWorkspace.path)")
            .font(.caption).textSelection(.enabled)
          Text("Branch: \(proposedWorkspace.branch ?? "checking…")")
            .font(.caption).textSelection(.enabled)
          if createWorktree, let sourceWorkspace {
            Text("Source: \(sourceWorkspace.branch ?? "unknown") at \(String((sourceWorkspace.baseCommit ?? "").prefix(8)))")
              .font(.caption).foregroundStyle(.secondary)
          }
          if let workspaceError { Text(workspaceError).font(.caption).foregroundStyle(.orange) }
          Toggle("Send task initialization prompt", isOn: $includePrompt)
          Text("Adds the task plan, assignment, and progress instructions to your initial prompt. Turn off to send only your prompt, or leave it empty for a blank session.")
            .font(.caption).foregroundStyle(.secondary)
          if includePrompt {
            DisclosureGroup("Initialization prompt preview") {
              Text(preview).font(.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          Toggle("Open in tmux", isOn: Binding(get: { useTmux && tmuxAvailable }, set: { useTmux = $0 }))
            .disabled(!tmuxAvailable)
          Text("tmux keeps the process alive after closing its terminal. A stopped agent can resume its saved conversation in a new terminal.")
            .font(.caption).foregroundStyle(.secondary)
          Text("Uses your login shell's codex or claude alias, function, or command and custom flags.")
            .font(.caption).foregroundStyle(.secondary)
        }.padding(2)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
        Button("Start agent") {
          model.launchAgent(for: ticket, title: name, provider: provider, repositoryPath: repository,
            includePrompt: includePrompt, useTmux: useTmux && tmuxAvailable, createWorktree: createWorktree,
            initialPrompt: prompt, tracksCompletion: includePrompt, subtaskID: assignmentID)
          dismiss()
        }.buttonStyle(.borderedProminent).disabled(!repository.hasPrefix("/"))
      }
    }.padding(24).frame(width: 540, height: 660)
      .task(id: repository) {
        sourceWorkspace = nil; workspaceError = nil
        guard !repository.isEmpty else { return }
        do { sourceWorkspace = try await TaskWorktreeManager().workspace(at: repository) }
        catch { workspaceError = error.localizedDescription }
      }
      .onAppear {
        includePrompt = !blank
        createWorktree = !blank
        prompt = blank ? "" : (ticket.next ?? "Implement \(ticket.title)")
        let context = model.taskContexts[ticket.id]
        repository = [context?.worktreePath, context?.repositoryPath, ticket.worktree, model.config.workspacePath]
          .compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) } ?? model.config.workspacePath
      }
  }
}
