import Darwin
import Foundation
import Observation

/// Shared cache for side-document content. Loading once per document keeps
/// previews alive across split-view layout changes, retries transient read
/// failures instead of sticking on an error, and follows on-disk writes so
/// files that agents rewrite stay current.
@MainActor
@Observable
final class DocumentContentStore {
    struct Entry {
        var content: SideDocumentContent?
        var error: String?
        var revision = 0
        var isLoading = false
    }

    /// An in-progress edit, kept per document so a draft survives the pane
    /// being recreated when the split layout changes.
    struct EditSession {
        var draft: String
        var baseline: String
        var saveError: String?
        var changedOnDisk = false
    }

    private(set) var entries: [URL: Entry] = [:]
    private(set) var editSessions: [URL: EditSession] = [:]
    private var accessOrder: [URL] = []
    private var loadTasks: [URL: Task<Void, Never>] = [:]
    private var pendingReloads: [URL: Task<Void, Never>] = [:]
    private var watchers: [URL: DispatchSourceFileSystemObject] = [:]
    private let entryLimit = 24
    private let load: @Sendable (URL) async throws -> SideDocumentContent
    /// Called after an in-app edit replaced a file, with the saved text.
    @ObservationIgnored var didSave: ((URL, String) -> Void)?

    init(load: @escaping @Sendable (URL) async throws -> SideDocumentContent = { try await SideDocumentLoader().load($0) }) {
        self.load = load
    }

    func entry(for url: URL) -> Entry { entries[url] ?? Entry() }

    /// Loads the document unless it is already loaded or in flight. A previous
    /// error retries, so revisiting a failed document recovers on its own.
    func ensureLoaded(_ url: URL) {
        touch(url)
        guard let entry = entries[url] else { startLoad(url); return }
        if entry.isLoading || entry.content != nil { return }
        if entry.error != nil { startLoad(url) }
    }

    /// Reloads from disk even when a cached copy exists.
    func reload(_ url: URL) {
        touch(url)
        startLoad(url)
    }

    /// Starts an edit over the currently loaded text. No-op for content the
    /// editor cannot write back, such as PDFs and rendered web pages.
    func beginEditing(_ url: URL) {
        guard editSessions[url] == nil, let text = loadedText(for: url) else { return }
        editSessions[url] = EditSession(draft: text, baseline: text)
    }

    func updateDraft(_ url: URL, _ draft: String) {
        editSessions[url]?.draft = draft
    }

    /// Returns true when the draft replaced the file on disk.
    func saveEdit(_ url: URL, overwrite: Bool = false) -> Bool {
        guard let session = editSessions[url] else { return false }
        do {
            try DocumentFileWriter.save(session.draft, to: url, expected: overwrite ? nil : session.baseline)
            // Publish the saved text now so the preview renders it directly,
            // instead of showing stale text or a blank page until the reload lands.
            var saved = entries[url] ?? Entry()
            saved.content = SideDocumentContent.saved(session.draft, for: url)
            saved.error = nil
            saved.revision += 1
            entries[url] = saved
            editSessions[url] = nil
            reload(url)
            didSave?(url, session.draft)
            return true
        } catch {
            editSessions[url]?.saveError = error.localizedDescription
            if case DocumentFileWriter.SaveError.changedOnDisk = error {
                editSessions[url]?.changedOnDisk = true
            }
            return false
        }
    }

    func discardEdit(_ url: URL) {
        editSessions[url] = nil
    }

    /// Whether the open edit holds changes the file does not have yet.
    func hasUnsavedEdit(_ url: URL) -> Bool {
        editSessions[url].map { $0.draft != $0.baseline } ?? false
    }

    /// Saves a pending edit before its document closes. Returns false when the
    /// save is refused, so the caller keeps the document open with the error showing.
    func saveBeforeClose(_ url: URL) -> Bool {
        guard editSessions[url] != nil else { return true }
        guard hasUnsavedEdit(url) else { discardEdit(url); return true }
        return saveEdit(url)
    }

    /// Text the pane may edit, or nil for non-text content and failed loads.
    /// Rendered text files (HTML, SVG) read their source from disk; binary
    /// renders such as PDFs and images have no editable text.
    func loadedText(for url: URL) -> String? {
        switch entries[url]?.content {
        case .markdown(let text), .text(let text):
            return text
        case .rendered(let file):
            guard InAppDocument.editableRenderedExtensions.contains(file.pathExtension.lowercased()),
                  let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 2_000_000 else { return nil }
            return try? String(contentsOf: file, encoding: .utf8)
        default:
            return nil
        }
    }

    private func touch(_ url: URL) {
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
        while entries.count > entryLimit,
              let oldest = accessOrder.first(where: { entries[$0]?.isLoading == false }) {
            accessOrder.removeAll { $0 == oldest }
            loadTasks[oldest]?.cancel()
            loadTasks[oldest] = nil
            pendingReloads[oldest]?.cancel()
            pendingReloads[oldest] = nil
            watchers[oldest]?.cancel()
            watchers[oldest] = nil
            entries[oldest] = nil
        }
    }

    private func startLoad(_ url: URL) {
        loadTasks[url]?.cancel()
        var entry = entries[url] ?? Entry()
        entry.isLoading = true
        entry.error = nil
        entries[url] = entry
        loadTasks[url] = Task {
            var attempt = 0
            while true {
                do {
                    let content = try await load(url)
                    if Task.isCancelled { return }
                    var current = self.entries[url] ?? Entry()
                    current.content = content
                    current.error = nil
                    current.isLoading = false
                    current.revision += 1
                    self.entries[url] = current
                    self.watch(url)
                    return
                } catch {
                    if Task.isCancelled { return }
                    attempt += 1
                    guard Self.isTransient(error), attempt < 3 else {
                        var current = self.entries[url] ?? Entry()
                        current.isLoading = false
                        if current.content == nil { current.error = error.localizedDescription }
                        self.entries[url] = current
                        self.watch(url)
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        }
    }

    /// Size limits, directories, and undecodable bytes fail the same way on
    /// every attempt; only I/O races with a concurrent writer are retried.
    private static func isTransient(_ error: Error) -> Bool {
        if error is DocumentPreviewError { return false }
        guard let cocoa = error as? CocoaError else { return true }
        return cocoa.code != .fileReadUnsupportedScheme && cocoa.code != .fileReadInapplicableStringEncoding
    }

    private func watch(_ url: URL) {
        watchers[url]?.cancel()
        watchers[url] = nil
        guard url.isFileURL else { return }
        let descriptor = open(url.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fileChanged(url) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watchers[url] = source
    }

    /// Atomic saves replace the file, so every change re-arms the watcher after
    /// the reload. A short debounce folds a writer's burst of events into one load.
    private func fileChanged(_ url: URL) {
        guard entries[url] != nil else { return }
        pendingReloads[url]?.cancel()
        pendingReloads[url] = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self.startLoad(url)
        }
    }
}
