import AppKit
import Observation
import PDFKit
import SwiftUI
import WebKit
import FocusQueueCore

enum SideDocumentContent: Sendable {
    case markdown(String), text(String), pdf(URL), rendered(URL)
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
        return ["md", "markdown"].contains(url.pathExtension.lowercased()) ? .markdown(text) : .text(text)
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
    @FocusState private var queryIsFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
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
            if state.isPresented {
                TextField("Find in document", text: $state.query)
                    .textFieldStyle(.roundedBorder)
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
        .font(.caption.weight(.medium))
        .onChange(of: state.request) { _, _ in
            guard state.isPresented else { return }
            DispatchQueue.main.async { queryIsFocused = true }
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
    let receiveDocument: (String) -> Bool
    let discuss: (PlanCanvasSelectionAction) -> Void
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
                    .draggable(document.absoluteString)
                Spacer()
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
                Button(action: close) { Image(systemName: "xmark") }
                    .help("Close this document viewer")
            }
            DocumentMetadataStrip(url: document, taskID: scopeLabel, revision: entry.revision)
            if editSession != nil { editor } else { viewer }
        }
        .dropDestination(for: String.self) { identifiers, _ in
            guard let identifier = identifiers.last else { return false }
            return receiveDocument(identifier)
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
                        url: file, open: open, findQuery: find.query,
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
            Button("Save") { _ = store.saveEdit(document) }
                .buttonStyle(.borderedProminent)
                .disabled(editSession.map { $0.draft == $0.baseline } ?? true)
                .keyboardShortcut("s", modifiers: .command)
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
            if let conversation { await conversation.load() }
        }
    }
}

struct DocumentConversationView: View {
    @Bindable var model: DocumentConversation
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Document chat", systemImage: "text.bubble").font(.system(size: 11, weight: .semibold))
                Text(model.taskID).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if model.isResponding { ProgressView().controlSize(.mini) }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.messages.isEmpty {
                            Text("Discuss this document with the \(model.subject.planLabel) and applicable AGENTS.md context.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(model.messages) { message in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(message.role == .user ? "YOU" : "DOCUMENT AGENT").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                                Text(message.text).font(.system(size: 12)).textSelection(.enabled)
                            }.id(message.id)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.onChange(of: model.messages.count) { _, _ in if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
            if let error = model.error { Text(error).font(.caption2).foregroundStyle(.orange) }
            HStack(alignment: .bottom) {
                TextField("Ask about this document", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...4)
                Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 23)) }
                    .buttonStyle(.plain).disabled(!model.isLoaded || model.isResponding || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Send to document agent")
            }
        }
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
struct PDFDocumentView: NSViewRepresentable {
    let url: URL
    let open: (URL) -> Void
    var findQuery = ""
    var findRequest = 0
    var findSearchesBackwards = false

    func makeCoordinator() -> Coordinator { Coordinator(open: open) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .underPageBackgroundColor
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.open = open
        if context.coordinator.url != url {
            context.coordinator.url = url
            view.document = PDFDocument(url: url)
        }
        context.coordinator.find(query: findQuery, request: findRequest, backwards: findSearchesBackwards, in: view)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) { view.delegate = nil }

    @MainActor final class Coordinator: NSObject, PDFViewDelegate {
        var url: URL?
        var open: (URL) -> Void
        private var handledFindRequest = 0
        init(open: @escaping (URL) -> Void) { self.open = open }

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
