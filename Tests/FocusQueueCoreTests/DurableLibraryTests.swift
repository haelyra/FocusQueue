import Foundation
import Testing
@testable import FocusQueueCore

private func libraryFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("library-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeLibraryContext(_ root: URL, ticket: String = "ECC-901", session: String = "11111111-1111-4111-8111-111111111111") throws -> TaskContext {
    let folder = root.appendingPathComponent("tasks/\(ticket)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let plan = folder.appendingPathComponent("plan.md")
    try Data("# Original central plan\n".utf8).write(to: plan)
    let context = TaskContext(ticketID: ticket, title: "History", summary: "Keep the evidence", successCriteria: "Restore locally",
        planPath: plan.path, worktreePath: root.path, repositoryPath: root.path,
        subtasks: [TaskSubtask(id: "subtask-1", title: "Implementation", sessionID: session, status: .completed, progressSummary: "verified")], updatedAt: Date(timeIntervalSince1970: 100))
    try JSONEncoder().encode(context).write(to: folder.appendingPathComponent("context.json"))
    return context
}

@Suite("Durable local library")
struct DurableLibraryTests {
    @Test("Migration is repeatable, preserves original files, and separates stable identity from locators")
    func migration() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeLibraryContext(root)
        let source = root.appendingPathComponent("tasks/ECC-901/context.json")
        let before = try Data(contentsOf: source)
        let saved = TaskAgentSession(ticketID: context.ticketID, provider: .codex, sessionID: context.subtasks[0].sessionID!,
            tabTitle: "old", workingDirectory: "/saved/history", paneID: 12, subtaskID: "subtask-1")
        try JSONEncoder().encode(LocalState(agentSessions: [saved])).write(to: root.appendingPathComponent("state.json"))
        let store = DurableLibraryStore(root: root)
        let first = try await store.reconcile()
        let second = try await DurableLibraryStore(root: root).reconcile()
        #expect(first == second)
        #expect(try Data(contentsOf: source) == before)
        let library = try await store.snapshot()
        #expect(library.tasks.count == 1)
        #expect(library.sessions.count == 1)
        #expect(library.importWarnings.isEmpty, "\(library.importWarnings)")
        let entry = try #require(library.sessions.first)
        #expect(entry.providerAccountRef == nil)
        #expect(library.executionLocators[0].workingDirectory == "/saved/history")
        #expect(library.executionLocators[0].availability == "unverified")
        #expect(library.documents.contains { $0.kind == "central-plan" })
    }

    @Test("Kimi sessions migrate legacy provider identities without changing existing installations")
    func providerInstallationMigration() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let codexInstallation = UUID()
        let claudeInstallation = UUID()
        let deviceURL = root.appendingPathComponent("library-device.json")
        try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "providerInstallations": [
                "codex": codexInstallation.uuidString,
                "claude": claudeInstallation.uuidString,
            ],
        ]).write(to: deviceURL)
        let saved = TaskAgentSession(
            ticketID: "FOC-024", provider: .kimi, sessionID: UUID().uuidString,
            tabTitle: "Kimi", workingDirectory: root.path)
        let store = DurableLibraryStore(root: root)

        let first = try await store.reconcile(state: LocalState(agentSessions: [saved]), contexts: [])
        let second = try await store.reconcile(state: LocalState(agentSessions: [saved]), contexts: [])

        #expect(first == second)
        let library = try await store.snapshot()
        #expect(library.sessions.count == 1)
        let session = try #require(library.sessions.first { $0.provider == "kimi" })
        let device = try JSONSerialization.jsonObject(with: Data(contentsOf: deviceURL)) as? [String: Any]
        let installations = try #require(device?["providerInstallations"] as? [String: String])
        #expect(installations["codex"] == codexInstallation.uuidString)
        #expect(installations["claude"] == claudeInstallation.uuidString)
        #expect(Set(installations.keys) == Set(AgentProvider.allCases.map(\.rawValue)))
        #expect(session.providerInstallationID.uuidString == installations["kimi"])
    }

    @Test("Durable library retains output time independently from heartbeat")
    func outputTimestamp() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        var context = try makeLibraryContext(root)
        let outputAt = Date(timeIntervalSinceReferenceDate: 654)
        context.subtasks[0].lastOutputAt = outputAt
        context.subtasks[0].lastHeartbeatAt = outputAt.addingTimeInterval(30)
        let store = DurableLibraryStore(root: root)
        _ = try await store.reconcile(contexts: [context])
        let subtask = try #require(try await store.snapshot().tasks.first?.subtasks.first)
        #expect(subtask.lastOutputAt == outputAt)
        #expect(subtask.lastHeartbeatAt == context.subtasks[0].lastHeartbeatAt)
    }

    @Test("Reassignment and detachment retain previous task links")
    func assignmentHistory() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DurableLibraryStore(root: root)
        let native = UUID().uuidString
        let first = TaskAgentSession(ticketID: "ECC-901", provider: .codex, sessionID: native, tabTitle: "first", workingDirectory: root.path)
        let second = TaskAgentSession(ticketID: "ECC-902", provider: .codex, sessionID: native, tabTitle: "second", workingDirectory: root.path)
        _ = try await store.reconcile(state: LocalState(agentSessions: [first]), contexts: [])
        let identity = try await store.snapshot().sessions[0].id
        _ = try await store.reconcile(state: LocalState(agentSessions: [second]), contexts: [])
        var library = try await store.snapshot()
        #expect(library.sessions[0].id == identity)
        #expect(library.assignments.count == 2)
        #expect(library.assignments.filter { $0.endedAt != nil }.count == 1)
        _ = try await store.reconcile(state: LocalState(), contexts: [])
        library = try await store.snapshot()
        #expect(library.assignments.allSatisfy { $0.endedAt != nil })
        #expect(library.sessions.count == 1)
    }

    @Test("Old archive bindings survive and current task progress stays current")
    func archiveRecovery() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        var old = try makeLibraryContext(root)
        old.subtasks[0].sessionID = "22222222-2222-4222-8222-222222222222"
        old.subtasks[0].status = .working
        let folder = root.appendingPathComponent("tasks/ECC-901/archive/snapshot-old")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(old).write(to: folder.appendingPathComponent("context.json"))
        try Data("# old plan".utf8).write(to: folder.appendingPathComponent("plan.md"))
        let store = DurableLibraryStore(root: root)
        _ = try await store.reconcile()
        let library = try await store.snapshot()
        #expect(library.sessions.count == 2)
        #expect(library.importWarnings.isEmpty, "\(library.importWarnings)")
        let task = try #require(library.tasks.first)
        #expect(task.subtasks[0].status == "completed")
        #expect(library.documents.filter { $0.kind == "task-snapshot" }.count == 2)
        #expect(library.assignments.contains { $0.source == "historical-context" })
    }

    @Test("Conversation history retains messages outside the presentation window and deduplicates updates")
    func conversation() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DurableLibraryStore(root: root)
        let messages = (0..<505).map { ["id": "message-\($0)", "text": "text-\($0)"] }
        try await store.captureConversation(data: JSONSerialization.data(withJSONObject: messages), ticketID: nil)
        try await store.captureConversation(data: JSONSerialization.data(withJSONObject: [["id": "message-504", "text": "updated"], ["id": "message-505", "text": "next"]]), ticketID: nil)
        let library = try await store.snapshot()
        let doc = try #require(library.documents.first)
        #expect(doc.revisions.count == 2)
        let bytes = try Data(contentsOf: store.directory.appendingPathComponent(doc.revisions.last!.blobPath))
        let retained = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: String]])
        #expect(retained.count == 506)
        #expect(retained[0]["text"] == "text-0")
        #expect(retained[504]["text"] == "updated")
    }

    @Test("Export restore preserves workspace and blobs, assigns a new device, and refuses overwrite")
    func portability() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeLibraryContext(root)
        let store = DurableLibraryStore(root: root)
        let original = try await store.reconcile(contexts: [context])
        let exported = root.appendingPathComponent("export")
        try await store.export(to: exported)
        #expect(!FileManager.default.fileExists(atPath: exported.appendingPathComponent("library-device.json").path))
        let restored = root.appendingPathComponent("restored")
        try DurableLibraryStore.restore(from: exported, to: restored)
        let after = try await DurableLibraryStore(root: restored).summary()
        #expect(after.workspaceID == original.workspaceID)
        #expect(after.deviceID != original.deviceID)
        #expect(after.documents == original.documents)
        await #expect(throws: DurableLibraryError.self) { try await store.export(to: exported) }
        #expect(throws: DurableLibraryError.self) { try DurableLibraryStore.restore(from: exported, to: restored) }
    }

    @Test("Corrupt or future manifests are preserved instead of reset")
    func malformed() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DurableLibraryStore(root: root)
        _ = try await store.reconcile(state: LocalState(), contexts: [])
        let manifest = store.directory.appendingPathComponent("manifest.json")
        for data in [Data("{broken".utf8), Data("{\"schemaVersion\":999}".utf8)] {
            try data.write(to: manifest)
            await #expect(throws: (any Error).self) { try await store.reconcile() }
            #expect(try Data(contentsOf: manifest) == data)
        }
    }

    @Test("Restore rejects tampered blobs and symlink sources")
    func tampering() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = try makeLibraryContext(root)
        let store = DurableLibraryStore(root: root)
        _ = try await store.reconcile(contexts: [context])
        let exported = root.appendingPathComponent("export")
        try await store.export(to: exported)
        let library = try await store.snapshot()
        let blob = exported.appendingPathComponent(library.documents[0].revisions[0].blobPath)
        try Data("tampered".utf8).write(to: blob)
        #expect(throws: DurableLibraryError.self) { try DurableLibraryStore.restore(from: exported, to: root.appendingPathComponent("restore")) }
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("tasks/ECC-901/context.json"))
        await #expect(throws: DurableLibraryError.self) { try await store.captureDocument(at: link, kind: "context") }
    }

    @Test("Independent store instances serialize without lost documents")
    func concurrentWriters() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<12).map { i in
            let url = root.appendingPathComponent("guide-\(i).md")
            try Data("# Guide \(i)".utf8).write(to: url)
            return url
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for url in urls { group.addTask { try await DurableLibraryStore(root: root).captureDocument(at: url, kind: "guide") } }
            try await group.waitForAll()
        }
        let library = try await DurableLibraryStore(root: root).snapshot()
        #expect(library.documents.count == 12)
        #expect(library.changes.count == 12)
    }

    @Test("A store that already read the manifest sees another instance's writes")
    func cachedReaderFollowsOtherWriters() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let urls = try (0..<2).map { i in
            let url = root.appendingPathComponent("guide-\(i).md")
            try Data("# Guide \(i)".utf8).write(to: url)
            return url
        }
        let reader = DurableLibraryStore(root: root)
        _ = try await reader.reconcile(state: LocalState(), contexts: [])
        let initial = try await reader.snapshot().documents.count

        try await DurableLibraryStore(root: root).captureDocument(at: urls[0], kind: "guide")
        #expect(try await reader.snapshot().documents.count == initial + 1)
        // Building on a stale copy would drop the other instance's document.
        try await reader.captureDocument(at: urls[1], kind: "guide")
        #expect(try await DurableLibraryStore(root: root).snapshot().documents.count == initial + 2)
    }

    @Test("Unchanged captures reuse the decoded manifest instead of re-reading it")
    func unchangedCapturesSkipDecoding() async throws {
        let root = try libraryFixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = DurableLibraryStore(root: root)
        let taskID = UUID()
        var library = DurableLibrary(workspaceID: UUID(), name: "Large history")
        library.tasks = [LibraryTask(id: taskID, ticketID: "ECC-950", title: "Large", summary: "",
            successCriteria: "", subtasks: [])]
        let sha = String(repeating: "a", count: 64)
        // History this size made every capture spend most of its time decoding.
        library.documents = [LibraryDocument(id: UUID(), taskID: taskID, kind: "task-context",
            title: "context.json", sourcePath: root.appendingPathComponent("old/context.json").path,
            sourceDeviceID: UUID(), revisions: (0..<30_000).map { _ in
                LibraryDocumentRevision(id: UUID(), sha256: sha, blobPath: "blobs/\(sha).json",
                    byteCount: 1, recordedAt: Date())
            })]
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(library).write(to: store.directory.appendingPathComponent("manifest.json"))
        let guide = root.appendingPathComponent("guide.md")
        try Data("# Guide".utf8).write(to: guide)
        try await store.captureDocument(at: guide, kind: "guide")

        let clock = ContinuousClock()
        let repeated = try await clock.measure {
            for _ in 0..<20 { try await store.captureDocument(at: guide, kind: "guide") }
        }
        let coldReads = try await clock.measure {
            for _ in 0..<2 { _ = try await DurableLibraryStore(root: root).snapshot() }
        }
        #expect(repeated < coldReads, "20 unchanged captures took \(repeated); 2 cold reads took \(coldReads)")
        #expect(try await store.snapshot().documents.count == 2)
    }
}
