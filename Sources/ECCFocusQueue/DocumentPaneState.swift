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

/// What stays on the left when a tab is split to the right.
enum DocumentSplitCompanion: Equatable {
    /// The central plan (or map), which is not a document tab.
    case centralContent
    case document(URL)
}

@MainActor
@Observable
final class DocumentPaneState {
    private(set) var tabs: [URL] = []
    private(set) var primaryDocument: URL?
    private(set) var secondaryDocument: URL?
    /// Earlier left-hand selections, newest last; nil is the central content.
    /// A split puts the current tab on the right and restores the one clicked before it.
    @ObservationIgnored private var primaryHistory: [URL?] = []
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
            setPrimary(location)
            secondaryDocument = nil
        case .secondary:
            // A document can be left in the secondary viewer after a drag. Keep
            // that visible document when the next link opens by promoting it to
            // the central viewer, then put the new document on the right.
            if primaryDocument == nil, secondaryDocument != location {
                setPrimary(secondaryDocument)
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
        setPrimary(url)
        if secondaryDocument == url { secondaryDocument = nil }
    }

    /// The left-hand content a split of `url` would leave in place: the visible
    /// left document, or, when `url` is that document, the tab or central
    /// content selected before it. Nil when there is nothing to put beside it.
    /// `hasCentralContent` is false for viewers with no central plan behind the tabs.
    func splitCompanion(for url: URL, hasCentralContent: Bool = true) -> DocumentSplitCompanion? {
        guard tabs.contains(url) else { return nil }
        if let primaryDocument, primaryDocument != url { return .document(primaryDocument) }
        if primaryDocument == nil, hasCentralContent { return .centralContent }
        for entry in primaryHistory.reversed() {
            if let entry {
                if entry != url, tabs.contains(entry) { return .document(entry) }
            } else if hasCentralContent {
                return .centralContent
            }
        }
        if hasCentralContent { return .centralContent }
        let index = tabs.firstIndex(of: url) ?? 0
        return tabs.indices.reversed().lazy.filter { $0 != index }
            .min { abs($0 - index) < abs($1 - index) }
            .map { .document(tabs[$0]) }
    }

    func canSplit(_ url: URL, hasCentralContent: Bool = true) -> Bool {
        splitCompanion(for: url, hasCentralContent: hasCentralContent) != nil
    }

    /// Show `url` on the right, next to the document that was open before it.
    @discardableResult
    func split(_ url: URL, hasCentralContent: Bool = true) -> Bool {
        guard let companion = splitCompanion(for: url, hasCentralContent: hasCentralContent) else { return false }
        switch companion {
        case .centralContent: setPrimary(nil)
        case .document(let document): setPrimary(document)
        }
        secondaryDocument = url
        centralChatCollapsed = true
        return true
    }

    /// Leave the split viewer, keeping the right-hand document as the only one shown.
    func endSplit() {
        guard let secondaryDocument else { return }
        select(secondaryDocument)
    }

    func showCentralContent() {
        setPrimary(nil)
    }

    private func setPrimary(_ url: URL?) {
        guard primaryDocument != url else { return }
        primaryHistory.append(primaryDocument)
        if primaryHistory.count > 16 { primaryHistory.removeFirst() }
        primaryDocument = url
    }

    func close(_ url: URL) {
        let index = tabs.firstIndex(of: url) ?? 0
        tabs.removeAll { $0 == url }
        primaryHistory.removeAll { $0 == url }
        if primaryDocument == url {
            setPrimary(secondaryDocument == nil && !tabs.isEmpty
                ? tabs[min(index, tabs.count - 1)] : nil)
        }
        if secondaryDocument == url { secondaryDocument = nil }
        if tabs.isEmpty { dismiss() }
    }

    func dismiss() {
        primaryDocument = nil
        secondaryDocument = nil
        primaryHistory = []
        centralChatCollapsed = false
    }
}

/// Which conversation a document viewer belongs to. Task documents discuss
/// the task; project documents opened from settings discuss the project.
enum DocumentScope: Hashable, Sendable {
    case task(String)
    case project(String)
}

/// Local files Focus Queue renders itself instead of handing to another app.
enum InAppDocument {
    static let pdfExtensions: Set<String> = ["pdf"]
    static let markdownExtensions: Set<String> = ["md", "markdown"]
    static let textExtensions: Set<String> = [
        "txt", "text", "log", "json", "jsonl", "csv", "tsv", "yaml", "yml", "toml", "xml",
    ]

    /// The file to show for a link, or nil when the link should leave the app.
    static func fileURL(for url: URL) -> URL? {
        guard let location = DocumentPaneLocation.normalized(url), location.isFileURL else { return nil }
        let ext = location.pathExtension.lowercased()
        guard pdfExtensions.contains(ext) || markdownExtensions.contains(ext) || textExtensions.contains(ext) else {
            return nil
        }
        return location
    }
}
