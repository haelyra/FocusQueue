import Foundation
import Observation

enum DocumentPaneLocation {
    static func normalized(_ input: URL) -> URL? {
        guard let url = EmbeddedDocumentLink.destination(input) else { return nil }
        if url.scheme == "obsidian", url.host == "open",
           let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
           path.hasPrefix("/") { return normalized(URL(fileURLWithPath: path)) }
        if url.scheme == "vscode", url.host == "file", url.path.hasPrefix("/") {
            return normalized(URL(fileURLWithPath: url.path))
        }
        if url.isFileURL {
            guard url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
            var path = url.path
            if let range = path.range(of: #"(?<=\.[A-Za-z0-9]{1,16}):[0-9]+(?::[0-9]+)?$"#, options: .regularExpression) {
                path.removeSubrange(range)
            }
            var components = URLComponents(url: URL(fileURLWithPath: path).standardizedFileURL, resolvingAgainstBaseURL: false)
            // A tab represents a document, rather than one tab per fragment.
            components?.fragment = nil
            return components?.url
        }
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url
    }
}

enum DocumentPanePlacement {
    case primary
    case secondary
}

@MainActor
@Observable
final class DocumentPaneState {
    private(set) var tabs: [URL] = []
    private(set) var primaryDocument: URL?
    private(set) var secondaryDocument: URL?
    /// The document in the foreground. In a split viewer, the right-hand
    /// document is the newest one and is treated as the selected document.
    var selected: URL? { secondaryDocument ?? primaryDocument }
    var isPresented: Bool { primaryDocument != nil || secondaryDocument != nil }
    var hasSecondaryViewer: Bool { secondaryDocument != nil }
    var centralChatCollapsed = false
    var error: String?

    func open(_ url: URL) {
        open(url, in: .primary)
    }

    /// Links from either the canvas or an external evidence view share the
    /// same placement rule. The first document replaces central content;
    /// every later document opens beside the visible document.
    func openLinkedDocument(_ url: URL, besideCentralContent: Bool = false) {
        open(url, in: besideCentralContent || isPresented ? .secondary : .primary)
    }

    func open(_ url: URL, in placement: DocumentPanePlacement) {
        guard let location = DocumentPaneLocation.normalized(url) else {
            error = "This link cannot be displayed as a document."
            return
        }
        if !tabs.contains(location) { tabs.append(location) }
        switch placement {
        case .primary:
            primaryDocument = location
            secondaryDocument = nil
        case .secondary:
            // A document can be left in the secondary viewer after a drag. Keep
            // that visible document when the next link opens by promoting it to
            // the central viewer, then put the new document on the right.
            if primaryDocument == nil, secondaryDocument != location {
                primaryDocument = secondaryDocument
            }
            // Reopening the central document selects it instead of rendering the
            // same document in both panes.
            if primaryDocument == location {
                secondaryDocument = nil
            } else {
                secondaryDocument = location
            }
        }
        centralChatCollapsed = true
        error = nil
    }

    /// Select a document as a tab in the central viewer. A dragged document
    /// becomes a central tab without removing it from the document history.
    func select(_ url: URL) {
        guard tabs.contains(url) else { return }
        primaryDocument = url
        if secondaryDocument == url { secondaryDocument = nil }
    }

    func moveToSecondary(_ url: URL) {
        guard tabs.contains(url) else { return }
        secondaryDocument = url
        if primaryDocument == url { primaryDocument = nil }
        centralChatCollapsed = true
    }

    func showCentralContent() {
        primaryDocument = nil
    }

    func close(_ url: URL) {
        let index = tabs.firstIndex(of: url) ?? 0
        tabs.removeAll { $0 == url }
        if primaryDocument == url {
            primaryDocument = secondaryDocument == nil && !tabs.isEmpty
                ? tabs[min(index, tabs.count - 1)] : nil
        }
        if secondaryDocument == url { secondaryDocument = nil }
        if tabs.isEmpty { dismiss() }
    }

    func dismiss() {
        primaryDocument = nil
        secondaryDocument = nil
        centralChatCollapsed = false
    }
}
