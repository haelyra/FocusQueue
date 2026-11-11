import Darwin
import Foundation
import Testing

@testable import FocusQueueCore

/// Holds a value produced on another thread; the semaphore orders the access.
private final class ThreadResult<T>: @unchecked Sendable {
    var value: T?
}

/// Runs `body` on its own thread and returns nil when it misses the deadline.
/// A thread stuck opening `fifo` is released by briefly opening the pipe for
/// writing, so a regression fails the test instead of hanging the suite.
func finishes<T: Sendable>(within seconds: Double, releasing fifo: URL? = nil,
                           _ body: @escaping @Sendable () -> T) -> T? {
    let done = DispatchSemaphore(value: 0)
    let result = ThreadResult<T>()
    Thread.detachNewThread {
        result.value = body()
        done.signal()
    }
    if done.wait(timeout: .now() + seconds) == .success { return result.value }
    if let fifo {
        let writer = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK)
        if writer >= 0 { Darwin.close(writer) }
    }
    return nil
}

func makeFIFO(_ url: URL) throws {
    guard mkfifo(url.path, 0o600) == 0 else { throw POSIXError(.EIO) }
}

/// A file whose size metadata says `bytes` without writing them (sparse).
func makeSparseFile(_ url: URL, bytes: UInt64) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: bytes)
    try handle.close()
}

@Suite("Nonblocking regular-file reads with actual-byte limits")
struct SafeFileReadTests {
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("safe-file-read-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func cleanUp() { try? FileManager.default.removeItem(at: root) }

    @Test("A named pipe with no writer is refused at once by every entry point")
    func fifoRefusedPromptly() throws {
        defer { cleanUp() }
        let fifo = root.appendingPathComponent("mockup.md")
        try makeFIFO(fifo)
        let started = Date()
        let outcomes = finishes(within: 2, releasing: fifo) {
            [Result { try SafeFileRead.data(at: fifo, limit: 1_024) }.map { _ in 0 },
             Result { try SafeFileRead.prefix(of: fifo, count: 48_000) }.map { _ in 0 },
             Result { try SafeFileRead.validateRegularFile(at: fifo) }]
        }
        let results = try #require(outcomes, "A FIFO read blocked past the deadline")
        #expect(Date().timeIntervalSince(started) < 1)
        for result in results {
            #expect(throws: SafeFileReadError.notRegularFile(fifo.path)) { try result.get() }
        }
    }

    @Test("Folders and devices are refused without reading")
    func directoryAndDeviceRefused() throws {
        defer { cleanUp() }
        #expect(throws: SafeFileReadError.notRegularFile(root.path)) {
            try SafeFileRead.data(at: root, limit: 1_024)
        }
        // /dev/zero never ends; a type check is the only thing that stops it.
        let zero = URL(fileURLWithPath: "/dev/zero")
        let outcome = finishes(within: 2) { Result { try SafeFileRead.data(at: zero, limit: 1_024) } }
        let result = try #require(outcome, "Reading a device blocked past the deadline")
        #expect(throws: SafeFileReadError.notRegularFile(zero.path)) { try result.get() }
    }

    @Test("A file over the limit is refused; one exactly at the limit is read")
    func oversizedRefused() throws {
        defer { cleanUp() }
        let exact = root.appendingPathComponent("exact.json")
        try Data(repeating: 0x61, count: 4_096).write(to: exact)
        #expect(try SafeFileRead.data(at: exact, limit: 4_096).count == 4_096)
        let over = root.appendingPathComponent("over.json")
        try Data(repeating: 0x61, count: 4_097).write(to: over)
        #expect(throws: SafeFileReadError.tooLarge(over.path, limit: 4_096)) {
            try SafeFileRead.data(at: over, limit: 4_096)
        }
        #expect(throws: SafeFileReadError.tooLarge(over.path, limit: 4_096)) {
            try SafeFileRead.validateRegularFile(at: over, limit: 4_096)
        }
        // The prefix reader takes the head of any regular file.
        #expect(try SafeFileRead.prefix(of: over, count: 10) == Data(repeating: 0x61, count: 10))
    }

    @Test("Growth after the size check is caught by the bytes actually read")
    func concurrentGrowthRefused() throws {
        defer { cleanUp() }
        let growing = root.appendingPathComponent("growing.json")
        try Data("{}".utf8).write(to: growing)
        let opened = try SafeFileRead.openRegularFile(growing, followSymlinks: true)
        defer { Darwin.close(opened.descriptor) }
        #expect(opened.size == 2)
        // Another writer appends after metadata said the file was tiny.
        let writer = try FileHandle(forWritingTo: growing)
        try writer.seekToEnd()
        try writer.write(contentsOf: Data(repeating: 0x20, count: 8_192))
        try writer.close()
        #expect(throws: SafeFileReadError.tooLarge(growing.path, limit: 1_024)) {
            try SafeFileRead.readAll(opened, limit: 1_024)
        }
    }

    @Test("Ordinary Markdown, HTML, and PDF-sized files read intact under the production limits")
    func ordinaryFilesRead() throws {
        defer { cleanUp() }
        let samples: [(String, Int, Int)] = [
            ("notes.md", 750 * 1_024, FileReadLimits.editableDocumentBytes),
            ("mockup.html", 250 * 1_024, FileReadLimits.canvasArtifactBytes),
            ("context.json", 370 * 1_024, FileReadLimits.metadataBytes),
            ("report.pdf", 9 * 1_024 * 1_024, 10_000_000),
        ]
        for (name, size, limit) in samples {
            let url = root.appendingPathComponent(name)
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try bytes.write(to: url)
            #expect(try SafeFileRead.data(at: url, limit: limit) == bytes, "\(name)")
            #expect(try SafeFileRead.validateRegularFile(at: url, limit: limit) == size)
        }
        #expect(FileReadLimits.metadataBytes >= 10 * 370_777)
        #expect(FileReadLimits.canvasArtifactBytes >= 10 * 249_750)
        #expect(FileReadLimits.editableDocumentBytes >= 10 * 747_498)
    }

    @Test("Symlinks to regular files are followed unless the caller forbids them")
    func symlinkHandling() throws {
        defer { cleanUp() }
        let target = root.appendingPathComponent("AGENTS.md")
        try Data("instructions".utf8).write(to: target)
        let link = root.appendingPathComponent("CLAUDE.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(try SafeFileRead.data(at: link, limit: 1_024) == Data("instructions".utf8))
        #expect(throws: SafeFileReadError.notRegularFile(link.path)) {
            try SafeFileRead.data(at: link, limit: 1_024, followSymlinks: false)
        }
        let fifo = root.appendingPathComponent("pipe")
        try makeFIFO(fifo)
        let pipeLink = root.appendingPathComponent("linked.md")
        try FileManager.default.createSymbolicLink(at: pipeLink, withDestinationURL: fifo)
        let outcome = finishes(within: 2, releasing: fifo) { Result { try SafeFileRead.prefix(of: pipeLink, count: 100) } }
        let result = try #require(outcome, "A symlinked FIFO blocked past the deadline")
        #expect(throws: SafeFileReadError.notRegularFile(pipeLink.path)) { try result.get() }
    }

    @Test("A missing file keeps Foundation's no-such-file code")
    func missingFile() throws {
        defer { cleanUp() }
        let missing = root.appendingPathComponent("missing.json")
        do {
            _ = try SafeFileRead.data(at: missing, limit: 1_024)
            Issue.record("Expected a missing-file error")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadNoSuchFile)
        }
    }

    @Test("An oversized task context is reported and never rewritten")
    func oversizedTaskContextPreserved() async throws {
        defer { cleanUp() }
        let store = TaskContextStore(root: root)
        _ = try await store.ensureContext(ticket: DashboardTicket(id: "FOC-950", title: "Big", status: "open", summary: "Bounded"))
        let url = root.appendingPathComponent("tasks/FOC-950/context.json")
        try makeSparseFile(url, bytes: UInt64(FileReadLimits.metadataBytes) + 1)
        await #expect(throws: SafeFileReadError.tooLarge(url.path, limit: FileReadLimits.metadataBytes)) {
            _ = try await store.load(ticketID: "FOC-950")
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        #expect(size?.intValue == FileReadLimits.metadataBytes + 1)

        let fifo = root.appendingPathComponent("tasks/FOC-950/context.json")
        try FileManager.default.removeItem(at: fifo)
        try makeFIFO(fifo)
        let outcome = finishes(within: 2, releasing: fifo) { Result { try TaskContextStore.contextData(at: fifo) } }
        let result = try #require(outcome, "Loading a FIFO context blocked past the deadline")
        #expect(throws: SafeFileReadError.notRegularFile(fifo.path)) { try result.get() }
    }
}
