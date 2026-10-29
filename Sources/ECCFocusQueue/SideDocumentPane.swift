import AppKit
import Observation
import PDFKit
import SwiftUI
import WebKit
import FocusQueueCore

enum SideDocumentContent: Sendable {
    case markdown(String), text(String), pdf(URL), rendered(URL)

    /// Markdown files preview rendered; every other text file shows as source.
    static func text(_ text: String, for url: URL) -> SideDocumentContent {
        ["md", "markdown"].contains(url.pathExtension.lowercased()) ? .markdown(text) : .text(text)
    }
}

actor SideDocumentLoader {
    func load(_ url: URL) throws -> SideDocumentContent {
        guard url.isFileURL else { return .rendered(url) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard (values.fileSize ?? 0) <= 20_000_000 else {
            throw DocumentPreviewError.message("This document exceeds the 20 MB preview limit.")
        }
        if InAppDocument.pdfExtensions.contains(url.pathExtension.lowercased()) { return .pdf(url) }
        if ["html", "htm", "png", "jpg", "jpeg", "gif", "svg"].contains(url.pathExtension.lowercased()) { return .rendered(url) }
        guard (values.fileSize ?? 0) <= 2_000_000 else { throw DocumentPreviewError.message("This text file exceeds the 2 MB preview limit.") }
        let text = try String(contentsOf: url, encoding: .utf8)
        guard !text.contains("\0") else { throw DocumentPreviewError.message("This binary file has no text preview.") }
        return .text(text, for: url)
    }
}

enum DocumentPreviewError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): text } }
}

@MainActor
@Observable
final class DocumentFindState {
    var isPresented = false
    var query = ""
    private(set) var request = 0
    private(set) var searchesBackwards = false

    func activate() {
        isPresented = true
        request += 1
    }

    func find(backwards: Bool = false) {
        isPresented = true
        searchesBackwards = backwards
        request += 1
    }

    func dismiss() {
        isPresented = false
    }
}

struct DocumentFindBar: View {
    @Bindable var state: DocumentFindState
    /// Header placement opens the field to the left so the Find button stays put.
    var placesFieldFirst = false
    @FocusState private var queryIsFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if placesFieldFirst { queryControls }
            Button("Find", systemImage: "magnifyingglass") { state.activate() }
                .buttonStyle(.bordered)
                .keyboardShortcut("f", modifiers: .command)
                .help("Find in this document (Command-F or Control-F)")
            // macOS uses Command-F by convention. Control-F is also registered
            // for terminal-oriented workflows without adding a second visible control.
            Button(action: { state.activate() }) { EmptyView() }
                .keyboardShortcut("f", modifiers: .control)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            if !placesFieldFirst { queryControls }
        }
        .font(.caption.weight(.medium))
        .onChange(of: state.request) { _, _ in
            guard state.isPresented else { return }
            DispatchQueue.main.async { queryIsFocused = true }
        }
    }

    @ViewBuilder private var queryControls: some View {
        if state.isPresented {
            TextField("Find in document", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 140, idealWidth: 180, maxWidth: 220)
                .focused($queryIsFocused)
                .onChange(of: state.query) { _, _ in state.find() }
                .onSubmit { state.find() }
            Button { state.find(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Find previous")
            Button { state.find() } label: { Image(systemName: "chevron.down") }
                .help("Find next")
            Button { state.dismiss() } label: { Image(systemName: "xmark") }
                .help("Close find")
        }
    }
}

struct FindableTextDocument: NSViewRepresentable {
    let text: String
    let query: String
    let request: Int
    let searchesBackwards: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.usesFindBar = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text { textView.string = text }
        context.coordinator.find(
            query: query, request: request, searchesBackwards: searchesBackwards,
            in: textView)
    }

    @MainActor final class Coordinator {
        weak var textView: NSTextView?
        private var handledRequest = 0

        func find(query: String, request: Int, searchesBackwards: Bool, in textView: NSTextView) {
            guard request > handledRequest else { return }
            handledRequest = request
            guard !query.isEmpty else { return }
            let source = textView.string as NSString
            let fullRange = NSRange(location: 0, length: source.length)
            let selected = textView.selectedRange()
            let searchRange: NSRange
            let options: NSString.CompareOptions
            if searchesBackwards {
                searchRange = selected.location == NSNotFound ? fullRange : NSRange(location: 0, length: selected.location)
                options = [.caseInsensitive, .backwards]
            } else {
                let start = selected.location == NSNotFound ? 0 : min(NSMaxRange(selected), source.length)
                searchRange = NSRange(location: start, length: source.length - start)
                options = [.caseInsensitive]
            }
            var match = source.range(of: query, options: options, range: searchRange)
            if match.location == NSNotFound { match = source.range(of: query, options: options, range: fullRange) }
            guard match.location != NSNotFound else { return }
            textView.setSelectedRange(match)
            textView.scrollRangeToVisible(match)
            textView.showFindIndicator(for: match)
        }
    }
}

/// Saves an in-app edit only when the file still holds the text the editor
/// started from, so an agent's concurrent write is never silently replaced.
enum DocumentFileWriter {
    enum SaveError: LocalizedError {
        case changedOnDisk, invalidJSON(String)
        var errorDescription: String? {
            switch self {
            case .changedOnDisk: "This file changed on disk after you started editing."
            case .invalidJSON(let detail): "The JSON is not valid, so it was not saved: \(detail)"
            }
        }
    }

    static func save(_ text: String, to url: URL, expected: String?) throws {
        if let expected, (try? String(contentsOf: url, encoding: .utf8)) != expected { throw SaveError.changedOnDisk }
        if url.pathExtension.lowercased() == "json" {
            do { _ = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
            catch { throw SaveError.invalidJSON(error.localizedDescription) }
        }
        // Atomic replacement creates a new file; keep the original's private permissions.
        let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try Data(text.utf8).write(to: url, options: .atomic)
        if let permissions { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }
}

struct SideDocumentPane: View {
    let queue: QueueViewModel
    /// The task ID or project name the document is viewed under.
    let scopeLabel: String
    let document: URL
    let open: (URL) -> Void
    let close: () -> Void
    let discuss: (PlanCanvasSelectionAction) -> Void
    /// Called when the header title starts a drag, so the container can preview a split.
    var dragStarted: (URL) -> Void = { _ in }
    @State private var find = DocumentFindState()

    private var store: DocumentContentStore { queue.documentContentStore }
    private var entry: DocumentContentStore.Entry { store.entry(for: document) }
    private var editSession: DocumentContentStore.EditSession? { store.editSessions[document] }
    private var editDraftBinding: Binding<String> {
        Binding(
            get: { editSession?.draft ?? "" },
            set: { store.updateDraft(document, $0) })
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label(document.isFileURL ? document.lastPathComponent : (document.host ?? "Document"),
                      systemImage: document.pathExtension.lowercased() == "pdf" ? "doc.richtext" : "doc.text")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .documentDrag(document, started: dragStarted)
                Spacer()
                if case .pdf = entry.content {
                    Button { queue.togglePDFDarkMode() } label: {
                        Image(systemName: queue.isPDFDarkMode ? "moon.fill" : "moon")
                    }
                        .help(queue.isPDFDarkMode ? "Show the PDF with its own colors" : "Show the PDF in dark mode")
                        .accessibilityLabel("PDF dark mode")
                        .accessibilityValue(queue.isPDFDarkMode ? "On" : "Off")
                }
                if let editSession {
                    Button("Save") { _ = store.saveEdit(document) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(editSession.draft == editSession.baseline)
                        .keyboardShortcut("s", modifiers: .command)
                        .help("Save to this file and return to the preview")
                }
                if document.isFileURL, store.loadedText(for: document) != nil {
                    Button {
                        if editSession != nil { store.discardEdit(document) }
                        else { store.beginEditing(document) }
                    } label: { Image(systemName: editSession != nil ? "eye" : "pencil") }
                        .help(editSession != nil ? "Stop editing without saving" : "Edit this document")
                        .accessibilityLabel(editSession != nil ? "Stop editing" : "Edit document")
                }
                Button { store.reload(document) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload document").disabled(editSession != nil)
                if document.isFileURL {
                    Button { NSWorkspace.shared.open(document) } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Open in the default app")
                }
                Button {
                    // Pending edits are saved on close; a refused save keeps the pane open with its error.
                    if store.saveBeforeClose(document) { close() }
                } label: { Image(systemName: "xmark") }
                    .help(editSession == nil ? "Close this document viewer" : "Save and close this document viewer")
            }
            DocumentMetadataStrip(url: document, taskID: scopeLabel, revision: entry.revision)
            // The viewer stays mounted under the editor, so saving reveals a rendered
            // preview instead of building a new web view that paints white first.
            ZStack {
                VStack(spacing: 8) { viewer }
                    .opacity(editSession == nil ? 1 : 0)
                    .allowsHitTesting(editSession == nil)
                    .accessibilityHidden(editSession != nil)
                if editSession != nil { VStack(spacing: 8) { editor } }
            }
        }
        .task(id: document.absoluteString) { store.ensureLoaded(document) }
    }

    @ViewBuilder private var viewer: some View {
        DocumentFindBar(state: find)
        Group {
            if let error = entry.error, entry.content == nil {
                ContentUnavailableView {
                    Label("Preview unavailable", systemImage: "doc")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { store.reload(document) }
                }
            } else if let content = entry.content {
                switch content {
                case .markdown(let text):
                    EmbeddedPlanDocument(markdown: text, sourceURL: document, appearance: queue.appearance,
                        accentStyle: queue.accentStyle, canvasSelection: nil, open: open, select: discuss,
                        findQuery: find.query, findRequest: find.request,
                        findSearchesBackwards: find.searchesBackwards)
                case .text(let text):
                    FindableTextDocument(
                        text: text, query: find.query, request: find.request,
                        searchesBackwards: find.searchesBackwards)
                case .pdf(let file):
                    PDFDocumentView(
                        url: file, open: open, discuss: discuss, darkMode: queue.isPDFDarkMode,
                        findQuery: find.query,
                        findRequest: find.request, findSearchesBackwards: find.searchesBackwards)
                case .rendered(let resource):
                    ReadOnlyResourceDocument(
                        url: resource, open: open, findQuery: find.query,
                        findRequest: find.request, findSearchesBackwards: find.searchesBackwards)
                }
            } else { ProgressView("Loading document…") }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder private var editor: some View {
        TextEditor(text: editDraftBinding).font(.system(size: 13, design: .monospaced))
            .accessibilityLabel("\(document.lastPathComponent) source")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        if let saveError = editSession?.saveError {
            Text(saveError).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
        }
        HStack {
            Text("Saves directly to this file.").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { store.discardEdit(document) }
            if editSession?.changedOnDisk == true {
                Button("Overwrite") { _ = store.saveEdit(document, overwrite: true) }
                    .help("Replace the newer file on disk with your draft")
            }
        }
    }
}

struct DocumentConversationPane: View {
    let queue: QueueViewModel
    let scope: DocumentScope?
    let document: URL
    @State private var conversation: DocumentConversation?

    var body: some View {
        Group {
            if let conversation {
                DocumentConversationView(model: conversation)
            } else {
                ContentUnavailableView(
                    "Document chat unavailable", systemImage: "text.bubble",
                    description: Text(scope == nil
                        ? "Open this document from a task or project to discuss it."
                        : "Document chat will be available when the task context loads."))
            }
        }
        .padding(.horizontal, 4)
        .frame(
            minWidth: QueueInspectorLayout.chatMinimumWidth, idealWidth: 270,
            maxWidth: .infinity, minHeight: 200, maxHeight: .infinity)
        .task(id: "\(document.absoluteString)|\(String(describing: scope))") {
            conversation = scope.flatMap { queue.documentConversation(for: document, scope: $0) }
            guard let conversation else { return }
            // Reopening rechecks whether the creating agent still runs.
            if conversation.isLoaded { await conversation.refreshCreator() } else { await conversation.load() }
        }
    }
}

/// Document chat in the task chat's appearance. The settings bar names the
/// Choose a fresh document reader, the creator's fork, or a new agent.
struct DocumentConversationView: View {
    @Bindable var model: DocumentConversation
    @FocusState private var composerIsFocused: Bool
    @State private var showsClearConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                settingsBar
                QueueChatTranscript(
                    messages: model.messages,
                    emptyText: "Discuss this document with \(model.subject.planLabel) context. Select text and start typing to ask about it.",
                    agentLabel: agentLabel,
                    progressText: model.isResponding ? progressText : nil)
                if let error = model.error {
                    Text(error).font(.caption2).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                QueueChatComposer(
                    draft: $model.draft,
                    isFocused: $composerIsFocused,
                    focusRequest: model.focusRequest,
                    maxHeight: max(120, geometry.size.height * 0.7),
                    placeholder: "Ask about this document",
                    accessibilityLabel: "Ask about this document",
                    isResponding: model.isResponding,
                    canSend: model.isLoaded && !model.isClearing,
                    sendLabel: model.route.kind == .ephemeralReader ? "Ask the ephemeral reader"
                        : model.route.kind == .creatorFork ? "Send to a fork of the creating agent" : "Send to a new agent",
                    stopLabel: "Stop the document agent response",
                    selection: model.selection,
                    clearSelection: { model.selection = nil },
                    onSend: model.send,
                    onStop: model.cancel)
            }
        }
    }

    private var agentLabel: String {
        let route = model.route
        if route.kind == .ephemeralReader { return "READER · \(route.provider.displayName.uppercased())" }
        return route.kind == .creatorFork
            ? "CREATOR FORK · \(route.provider.displayName.uppercased())"
            : "NEW AGENT · \(route.provider.displayName.uppercased())"
    }

    private var progressText: String {
        let route = model.route
        if route.kind == .ephemeralReader { return "The document reader is replying" }
        return route.kind == .creatorFork
            ? "The creating agent's fork is replying"
            : "New \(route.provider.displayName) agent is replying"
    }

    private var settingsBar: some View {
        QueueChatSettingsBar {
            HStack(spacing: 6) {
                Label("Document chat", systemImage: "text.bubble")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text(model.taskID).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear Chat") { showsClearConfirmation = true }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .disabled(model.messages.isEmpty && model.lockedRoute == nil)
                    .help("Erase this conversation and choose its recipient again")
            }
            Picker("Recipient", selection: Binding(
                get: { model.route.kind }, set: { model.setRecipient($0) })) {
                Text("Ephemeral reader").tag(DocumentChatRoute.Kind.ephemeralReader)
                Text("Creating agent fork").tag(DocumentChatRoute.Kind.creatorFork)
                    .disabled(model.creator == nil && model.route.kind != .creatorFork)
                Text("New agent").tag(DocumentChatRoute.Kind.newAgent)
            }
            .font(.caption)
            .disabled(!model.canChooseProvider || model.isResponding)
            .help("Choose who answers. Clear Chat to change a started conversation's recipient.")
            recipient
            if model.lockedRoute == nil, model.route.kind != .creatorFork {
                Button {
                    Task { await model.reconnectToCreator() }
                } label: {
                    Label("Reconnect to creating agent", systemImage: "arrow.triangle.branch")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .disabled(model.isResolvingCreator || model.isResponding || model.isClearing)
                .help("Find the agent that created this document and use a fork of its saved conversation, even when archived")
            }
            if model.route.kind != .creatorFork {
                HStack(spacing: 8) {
                    QueueChatAgentMenus(
                        provider: model.route.provider,
                        model: model.newAgentModel,
                        effort: model.newAgentEffort,
                        modelChoices: model.modelChoices(for: model.route.provider),
                        providerEnabled: model.canChooseProvider,
                        providerDisabledHelp: "Clear the chat to switch providers",
                        setProvider: model.setNewAgentProvider,
                        setModel: model.setNewAgentModel,
                        setEffort: model.setNewAgentEffort)
                    Spacer(minLength: 0)
                }
                if model.canChooseProvider, let creator = model.creator {
                    Button("Use creator's model: \(creator.model ?? creator.author.provider.displayName + " default")") { model.useCreatorModel() }
                        .font(.caption).buttonStyle(.borderless)
                        .disabled(model.isResponding)
                        .help("Use the document author's model and effort with this recipient")
                }
            }
        }
        .confirmationDialog(
            "Clear this conversation?",
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Conversation", role: .destructive) { model.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript is erased. Choose an ephemeral reader, a creating-agent fork, or a new agent for the next message.")
        }
    }

    /// Which agent the next message reaches, and why.
    private var recipient: some View {
        let route = model.route
        let isFork = route.kind == .creatorFork
        return HStack(alignment: .top, spacing: 7) {
            Image(systemName: route.kind == .ephemeralReader ? "doc.text.magnifyingglass" : isFork ? "arrow.triangle.branch" : "plus.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.kind == .ephemeralReader ? "To an ephemeral \(route.provider.displayName) reader" : isFork
                    ? "To the creating agent · \(route.provider.displayName) fork"
                    : "To a new \(route.provider.displayName) agent")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(2)
                Text(recipientDetail)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.lockedRoute == nil {
                Button {
                    Task { await model.refreshCreator() }
                } label: {
                    if model.isResolvingCreator {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                }
                .buttonStyle(.borderless)
                .disabled(model.isResolvingCreator)
                .accessibilityLabel("Check for the creating agent again")
                .help("Check again whether the agent that created this document is running")
            }
        }
        .padding(.top, 2)
        .accessibilityElement(children: .contain)
    }

    private var recipientDetail: String {
        let route = model.route
        if route.kind == .ephemeralReader {
            return "Reads this document with \(model.subject.planLabel) context. Answers questions and searches without changing files. Each turn starts fresh."
        }
        if route.kind == .creatorFork {
            let agent = route.sourceTitle.map { "“\($0)”" } ?? "The creating agent"
            return model.lockedRoute == nil
                ? "\(agent) wrote this document. Messages go to a fork of its conversation, so its terminal is not interrupted."
                : "Continues a fork of \(agent), which wrote this document."
        }
        if model.lockedRoute != nil { return "This conversation started with a new agent." }
        if model.isResolvingCreator && model.creator == nil { return "Looking for the agent that created this document…" }
        if let creator = model.creator {
            if creator.isOpen {
                return "You chose a new agent. “\(creator.author.title)” also has a creating-agent fork available."
            }
            return "“\(creator.author.title)” wrote this document but is not running. Reconnect to use a fork of its saved conversation."
        }
        return "No agent in this task wrote this document, so a new agent answers."
    }
}

/// Static local resources and remote links stay inside the side pane. Link
/// activation always requests another tab. Page scripts and popups are disabled.
struct ReadOnlyResourceDocument: NSViewRepresentable {
    let url: URL
    let open: (URL) -> Void
    var findQuery = ""
    var findRequest = 0
    var findSearchesBackwards = false
    func makeCoordinator() -> Coordinator { Coordinator(open: open) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.open = open
        if context.coordinator.url != url {
            context.coordinator.url = url
            context.coordinator.willLoadDocument()
            if url.isFileURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
            else { view.load(URLRequest(url: url)) }
        }
        context.coordinator.requestFind(
            query: findQuery, request: findRequest, searchesBackwards: findSearchesBackwards, in: view)
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var url: URL?
        var open: (URL) -> Void
        private var isDocumentLoaded = false
        private var handledFindRequest = 0
        private var pendingFind: (query: String, searchesBackwards: Bool)?
        init(open: @escaping (URL) -> Void) { self.open = open }

        func willLoadDocument() { isDocumentLoaded = false }

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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isDocumentLoaded = true
            performPendingFind(in: webView)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let target = navigationAction.request.url { open(target) }
            return nil
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let target = action.request.url {
                open(target); decisionHandler(.cancel)
            } else if let target = action.request.url,
                      ["file", "http", "https", "about"].contains(target.scheme ?? ""),
                      !(target.isFileURL && url?.isFileURL == false),
                      action.targetFrame?.isMainFrame != false { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }
    }
}

/// Focus Queue's PDF viewer. Internal links stay in PDFKit; web and file
/// links route through the same document opener as every other viewer.
/// Typing with text selected starts a document-chat message about that passage.
struct PDFDocumentView: NSViewRepresentable {
    let url: URL
    let open: (URL) -> Void
    var discuss: (PlanCanvasSelectionAction) -> Void = { _ in }
    var darkMode = false
    var findQuery = ""
    var findRequest = 0
    var findSearchesBackwards = false

    func makeCoordinator() -> Coordinator { Coordinator(open: open, discuss: discuss) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.delegate = context.coordinator
        context.coordinator.watchTyping(in: view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.open = open
        context.coordinator.discuss = discuss
        if context.coordinator.darkMode != darkMode {
            context.coordinator.darkMode = darkMode
            PDFDarkMode.apply(darkMode, to: view)
        }
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.document = PDFDocument(url: url)
        }
        context.coordinator.find(query: findQuery, request: findRequest, backwards: findSearchesBackwards, in: view)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.stopWatchingTyping()
    }

    @MainActor final class Coordinator: NSObject, PDFViewDelegate {
        var url: URL?
        var darkMode = false
        var open: (URL) -> Void
        var discuss: (PlanCanvasSelectionAction) -> Void
        private var handledFindRequest = 0
        private var keyMonitor: Any?
        init(open: @escaping (URL) -> Void, discuss: @escaping (PlanCanvasSelectionAction) -> Void) {
            self.open = open
            self.discuss = discuss
        }

        /// PDFKit hands key presses to private subviews, so a local monitor
        /// catches them while focus is anywhere inside this viewer.
        func watchTyping(in view: PDFView) {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak view] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, let view else { return false }
                    return self.discussSelection(in: view, typing: event)
                }
                return handled ? nil : event
            }
        }

        func stopWatchingTyping() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }

        /// Returns true when the key press became a discussion of the selected passage.
        func discussSelection(in view: PDFView, typing event: NSEvent) -> Bool {
            guard event.window === view.window,
                  let responder = view.window?.firstResponder as? NSView, responder.isDescendant(of: view),
                  let character = PDFSelectionContext.typedCharacter(event),
                  let selection = view.currentSelection, let document = view.document,
                  let action = PDFSelectionContext.action(
                    for: selection, in: document, sourceURL: url ?? document.documentURL ?? URL(fileURLWithPath: "/"),
                    initialText: character)
            else { return false }
            discuss(action)
            return true
        }

        func find(query: String, request: Int, backwards: Bool, in view: PDFView) {
            guard request > handledFindRequest else { return }
            handledFindRequest = request
            guard !query.isEmpty, let document = view.document else { return }
            var options: NSString.CompareOptions = [.caseInsensitive]
            if backwards { options.insert(.backwards) }
            let match = document.findString(query, fromSelection: view.currentSelection, withOptions: options)
                ?? document.findString(query, fromSelection: nil, withOptions: options)
            guard let match else { return }
            view.setCurrentSelection(match, animate: true)
            view.go(to: match)
        }

        nonisolated func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
            MainActor.assumeIsolated { open(url) }
        }
    }
}

/// Dark mode for PDFs: brightness flips (white paper to dark gray, black ink to
/// near white) while each color keeps its distance from gray, so links and charts
/// stay recognizable. The flip runs on sRGB values so midtones stay midtones.
enum PDFDarkMode {
    /// Where white paper and black ink land after the flip.
    static let paper = 0.11, ink = 0.92

    static func filters() -> [CIFilter] {
        // Rec. 709 luma; every channel moves by the same amount, which keeps chroma.
        let luma = (r: 0.2126, g: 0.7152, b: 0.0722), k = 1 + (ink - paper)
        let matrix = CIFilter(name: "CIColorMatrix")!
        matrix.setValue(CIVector(x: 1 - k * luma.r, y: -k * luma.g, z: -k * luma.b, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: -k * luma.r, y: 1 - k * luma.g, z: -k * luma.b, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: -k * luma.r, y: -k * luma.g, z: 1 - k * luma.b, w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: ink, y: ink, z: ink, w: 0), forKey: "inputBiasVector")
        return [CIFilter(name: "CILinearToSRGBToneCurve")!, matrix, CIFilter(name: "CISRGBToneCurveToLinear")!]
    }

    /// The flip turns this light gray into a gray a step lighter than the pages, so their edges show.
    static let invertedBackground = NSColor(srgbRed: 0.9, green: 0.9, blue: 0.9, alpha: 1)

    @MainActor static func apply(_ enabled: Bool, to view: PDFView) {
        view.contentFilters = enabled ? filters() : []
        view.backgroundColor = enabled ? invertedBackground : .underPageBackgroundColor
    }
}

struct PlanPaneSplit<Primary: View, Secondary: View>: View {
    var initialFraction: CGFloat
    var minimumPrimary: CGFloat
    var minimumSecondary: CGFloat
    @ViewBuilder let primary: () -> Primary
    @ViewBuilder let secondary: () -> Secondary
    @State private var fraction: CGFloat?
    @State private var dragStart: CGFloat?
    var body: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.width - 10)
            let width = min(available - minimumSecondary, max(minimumPrimary, available * (fraction ?? initialFraction)))
            HStack(spacing: 0) {
                primary().frame(width: max(1, width))
                Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 1)
                    .frame(width: 10, height: geometry.size.height).contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        if dragStart == nil { dragStart = width }
                        fraction = min(1 - minimumSecondary / available, max(minimumPrimary / available, ((dragStart ?? width) + value.translation.width) / available))
                    }.onEnded { _ in dragStart = nil })
                    .accessibilityLabel("Resize document panes")
                    .accessibilityAdjustableAction { direction in
                        let step: CGFloat = direction == .increment ? 0.05 : -0.05
                        fraction = min(1 - minimumSecondary / available, max(minimumPrimary / available, (fraction ?? initialFraction) + step))
                    }
                secondary().frame(width: max(1, available - width))
            }
        }
    }
}

extension View {
    /// Makes a document draggable by URL string and reports the drag start, so the
    /// viewer can preview where the document would land before it is dropped.
    func documentDrag(_ url: URL, started: @escaping (URL) -> Void) -> some View {
        onDrag {
            started(url)
            return NSItemProvider(object: url.absoluteString as NSString)
        }
    }

    /// Accepts a dragged document tab anywhere over the viewer area. While a tab
    /// is being dragged the content below stops taking hits, so web and PDF views
    /// cannot swallow the drop. A cancelled drag never reports its end, so the
    /// next pointer movement over the idle area clears the stale drag.
    func splitDropTarget(
        tabs: [URL], dragged: Binding<URL?>, isTargeted: Binding<Bool>,
        drop: @escaping (URL) -> Bool
    ) -> some View {
        allowsHitTesting(dragged.wrappedValue == nil)
            .background(
                Color.clear.contentShape(Rectangle()).onContinuousHover { phase in
                    guard case .active = phase, dragged.wrappedValue != nil,
                          !isTargeted.wrappedValue else { return }
                    dragged.wrappedValue = nil
                })
            .dropDestination(for: String.self) { identifiers, _ in
                defer { dragged.wrappedValue = nil; isTargeted.wrappedValue = false }
                guard let identifier = identifiers.last,
                      let url = tabs.first(where: { $0.absoluteString == identifier }) else { return false }
                return drop(url)
            } isTargeted: { isTargeted.wrappedValue = $0 }
    }
}

/// The empty slot shown on the right while a tab is dragged over the viewer: the
/// open document slides left to make room, signalling that the tab can split.
struct SplitDropPlaceholder: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 26, weight: .regular))
            Text("Drop to open side by side").font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Color.accentColor)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.accentColor.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
        .padding(.horizontal, 4)
        .transition(.opacity)
        .accessibilityLabel("Drop to open side by side")
    }
}
