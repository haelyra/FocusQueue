import AppKit
import SwiftUI
import WebKit
import FocusQueueCore

enum SideDocumentContent: Sendable {
    case markdown(String), text(String), rendered(URL)
}

actor SideDocumentLoader {
    func load(_ url: URL) throws -> SideDocumentContent {
        guard url.isFileURL else { return .rendered(url) }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        guard values.isDirectory != true else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard (values.fileSize ?? 0) <= 20_000_000 else {
            throw DocumentPreviewError.message("This document exceeds the 20 MB preview limit.")
        }
        if ["pdf", "html", "htm", "png", "jpg", "jpeg", "gif", "svg"].contains(url.pathExtension.lowercased()) { return .rendered(url) }
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

struct SideDocumentPane: View {
    let queue: QueueViewModel
    let ticket: DashboardTicket
    @Bindable var state: DocumentPaneState
    @State private var content: SideDocumentContent?
    @State private var conversation: DocumentConversation?
    @State private var error: String?
    @State private var revision = 0
    private let loader = SideDocumentLoader()

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Document", systemImage: "rectangle.split.2x1").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Reload document")
                Button { state.dismiss() } label: { Image(systemName: "xmark") }.help("Hide document pane and restore central chat")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(state.tabs, id: \.self) { url in
                        HStack(spacing: 5) {
                            Button { state.select(url) } label: { Text(url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString)).lineLimit(1) }
                            Button { state.close(url) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .accessibilityLabel("Close \(url.lastPathComponent)")
                        }.buttonStyle(.plain).font(.caption).padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Color.primary.opacity(state.selected == url ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 6))
                            .help(url.absoluteString)
                    }
                }
            }
            GeometryReader { geometry in
                VStack(spacing: 8) {
                    Group {
                        if let error { ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(error)) }
                        else if let url = state.selected, let content {
                            switch content {
                            case .markdown(let text):
                                EmbeddedPlanDocument(markdown: text, sourceURL: url, appearance: queue.appearance,
                                    accentStyle: queue.accentStyle, canvasSelection: nil, open: { state.open($0) }, select: { action in
                                        conversation?.draft += "\nSelected passage: \(action.selection.excerpt)\n\(action.initialText)"
                                    })
                            case .text(let text):
                                ScrollView([.horizontal, .vertical]) {
                                    Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .topLeading).padding(12)
                                }.background(Color(nsColor: .textBackgroundColor))
                            case .rendered(let document): ReadOnlyResourceDocument(url: document, open: { state.open($0) })
                            }
                        } else { ProgressView("Loading document…") }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                    Divider()
                    if let conversation {
                        DocumentConversationView(model: conversation)
                            .frame(height: min(260, max(170, geometry.size.height * 0.3)))
                    } else { Text("Document chat will be available when the task context loads.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: "\(state.selected?.absoluteString ?? ""):\(revision)") {
            guard let url = state.selected else { return }
            content = nil; error = nil
            conversation = queue.documentConversation(for: url, ticketID: ticket.id)
            if let conversation { await conversation.load() }
            do {
                let loaded = try await loader.load(url)
                guard !Task.isCancelled, state.selected == url else { return }
                content = loaded
            } catch { if !Task.isCancelled, state.selected == url { self.error = error.localizedDescription } }
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
                            Text("Discuss this document with the central plan and applicable AGENTS.md context.").font(.caption).foregroundStyle(.secondary)
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
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        if url.isFileURL { view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { view.load(URLRequest(url: url)) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var url: URL?
        var open: (URL) -> Void
        init(open: @escaping (URL) -> Void) { self.open = open }
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
