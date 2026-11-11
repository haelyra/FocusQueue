import Darwin
import Foundation
import Testing
import FocusQueueCore
@testable import ECCFocusQueue

/// Document chat must never wait on a named pipe or read an unbounded file.
@Suite("Document chat file safety")
@MainActor
struct DocumentContextSafetyTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("document-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func fifo(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(.EIO) }
        return url
    }

    /// Releases a reader stuck opening `pipes` after the deadline, so a
    /// regression fails the timing check instead of hanging the suite.
    private func watchdog(_ pipes: [URL]) -> Task<Void, Never> {
        let paths = pipes.map(\.path)
        return Task.detached {
            try? await Task.sleep(for: .seconds(3))
            for path in paths {
                let writer = Darwin.open(path, O_RDWR | O_NONBLOCK)
                if writer >= 0 { Darwin.close(writer) }
            }
        }
    }

    @Test("A named pipe as the document or a PDF is reported unavailable without blocking")
    func fifoDocumentDoesNotBlock() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try await TaskContextStore(root: root).ensureContext(
            ticket: .init(id: "ECC-950", title: "Pipe", status: "open", summary: "Never block"))
        let document = try fifo("notes.md")
        let pdf = try fifo("report.pdf")
        let guardTask = watchdog([document, pdf])
        defer { guardTask.cancel() }
        let started = Date()

        let prompt = try await DocumentContextReader().prompt(
            document: document, subject: .init(kind: .task(context)), request: "Summarize",
            history: [], readOnly: true)
        #expect(DocumentConversation.editableSource(document) == nil)
        #expect(DocumentContextReader.pdfText(pdf, focusPage: nil, limit: 48_000) == nil)

        #expect(Date().timeIntervalSince(started) < 2)
        #expect(prompt.contains("Source unavailable: \(document.path)"))
        #expect(prompt.hasSuffix("User request:\nSummarize"))
    }

    @Test("The editor reads ordinary and symlinked documents and skips one past its ceiling")
    func editableSourceBounds() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = root.appendingPathComponent("plan.md")
        try Data("# Plan\n".utf8).write(to: plan)
        #expect(DocumentConversation.editableSource(plan)?.text == "# Plan\n")
        let link = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: plan)
        #expect(DocumentConversation.editableSource(link)?.text == "# Plan\n")

        let large = root.appendingPathComponent("large.md")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(FileReadLimits.editableDocumentBytes) + 1)
        try handle.close()
        #expect(DocumentConversation.editableSource(large) == nil)
        #expect(DocumentConversation.editableSource(root) == nil)
    }
}
