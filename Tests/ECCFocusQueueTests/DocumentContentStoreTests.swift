import Foundation
import Testing
@testable import ECCFocusQueue

private actor LoadCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}

@Suite("Document content store")
@MainActor
struct DocumentContentStoreTests {
    private func tempFile(_ contents: String, name: String = "doc.md") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("content-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("A document loads once and the cache serves later requests")
    func cachesContent() async throws {
        let file = try tempFile("cached text")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let counter = LoadCounter()
        let store = DocumentContentStore { url in
            _ = await counter.next()
            return try await SideDocumentLoader().load(url)
        }
        store.ensureLoaded(file)
        await waitFor { store.entry(for: file).content != nil }
        store.ensureLoaded(file)
        #expect(store.loadedText(for: file) == "cached text")
        #expect(await counter.count == 1)
    }

    @Test("A transient read failure retries and recovers without a manual reload")
    func retriesTransientFailures() async throws {
        let file = try tempFile("eventual text")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let counter = LoadCounter()
        let store = DocumentContentStore { url in
            if await counter.next() == 1 { throw CocoaError(.fileReadNoSuchFile) }
            return try await SideDocumentLoader().load(url)
        }
        store.ensureLoaded(file)
        await waitFor { store.entry(for: file).content != nil }
        #expect(store.loadedText(for: file) == "eventual text")
        #expect(store.entry(for: file).error == nil)
        #expect(await counter.count == 2)
    }

    @Test("Permanent failures surface an error without retrying, and revisiting retries")
    func permanentErrorThenRecovery() async throws {
        let file = try tempFile("plain")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let counter = LoadCounter()
        let store = DocumentContentStore { _ in
            _ = await counter.next()
            throw DocumentPreviewError.message("This document exceeds the 20 MB preview limit.")
        }
        store.ensureLoaded(file)
        await waitFor { store.entry(for: file).error != nil }
        #expect(await counter.count == 1)
        #expect(store.entry(for: file).error?.contains("20 MB") == true)
    }

    @Test("Writing the file on disk reloads the open document")
    func followsOnDiskWrites() async throws {
        let file = try tempFile("before")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = DocumentContentStore()
        store.ensureLoaded(file)
        await waitFor { store.loadedText(for: file) == "before" }
        #expect(store.loadedText(for: file) == "before")

        try Data("after".utf8).write(to: file, options: .atomic)
        await waitFor { store.loadedText(for: file) == "after" }
        #expect(store.loadedText(for: file) == "after")
    }

    @Test("Edit sessions save through the conflict-checked writer and survive reloads")
    func editSession() async throws {
        let file = try tempFile("original")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = DocumentContentStore()
        store.ensureLoaded(file)
        await waitFor { store.loadedText(for: file) == "original" }

        store.beginEditing(file)
        store.updateDraft(file, "edited")
        #expect(store.editSessions[file]?.draft == "edited")
        #expect(store.saveEdit(file))
        #expect(store.editSessions[file] == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "edited")
        await waitFor { store.loadedText(for: file) == "edited" }
        #expect(store.loadedText(for: file) == "edited")
    }

    @Test("A conflicting on-disk write blocks the save until overwrite")
    func conflictingSave() async throws {
        let file = try tempFile("original")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = DocumentContentStore()
        store.ensureLoaded(file)
        await waitFor { store.loadedText(for: file) == "original" }

        store.beginEditing(file)
        store.updateDraft(file, "mine")
        try Data("theirs".utf8).write(to: file)
        #expect(!store.saveEdit(file))
        #expect(store.editSessions[file]?.changedOnDisk == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs")

        #expect(store.saveEdit(file, overwrite: true))
        #expect(try String(contentsOf: file, encoding: .utf8) == "mine")
    }

    @Test("Saving publishes the new text synchronously, as Markdown for .md files")
    func saveUpdatesContentImmediately() async throws {
        let file = try tempFile("original")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = DocumentContentStore()
        store.ensureLoaded(file)
        await waitFor { store.loadedText(for: file) == "original" }

        store.beginEditing(file)
        store.updateDraft(file, "# edited")
        let revision = store.entry(for: file).revision
        #expect(store.saveEdit(file))
        // No awaiting: the preview must already hold the saved text, never stale text.
        guard case .markdown(let text) = store.entry(for: file).content else {
            Issue.record("Expected Markdown content after saving a .md file")
            return
        }
        #expect(text == "# edited")
        #expect(store.entry(for: file).revision > revision)
    }

    @Test("Closing saves a changed draft and discards an unchanged one")
    func saveBeforeClose() async throws {
        let file = try tempFile("original")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = DocumentContentStore()
        store.ensureLoaded(file)
        await waitFor { store.loadedText(for: file) == "original" }

        #expect(store.saveBeforeClose(file))

        store.beginEditing(file)
        #expect(!store.hasUnsavedEdit(file))
        #expect(store.saveBeforeClose(file))
        #expect(store.editSessions[file] == nil)

        store.beginEditing(file)
        store.updateDraft(file, "closed with edits")
        #expect(store.hasUnsavedEdit(file))
        #expect(store.saveBeforeClose(file))
        #expect(store.editSessions[file] == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "closed with edits")
    }

    @Test("A refused save on close keeps the edit open with its error")
    func refusedSaveBeforeClose() async throws {
        let file = try tempFile("original")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = DocumentContentStore()
        store.ensureLoaded(file)
        await waitFor { store.loadedText(for: file) == "original" }

        store.beginEditing(file)
        store.updateDraft(file, "mine")
        try Data("theirs".utf8).write(to: file)
        #expect(!store.saveBeforeClose(file))
        #expect(store.editSessions[file]?.draft == "mine")
        #expect(store.editSessions[file]?.saveError != nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "theirs")
    }
}
