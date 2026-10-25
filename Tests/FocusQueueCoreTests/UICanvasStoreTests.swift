import Foundation
import Testing

@testable import FocusQueueCore

@Suite("Native UI Canvas session store and CLI protocol")
struct UICanvasStoreTests {
    private struct Fixture {
        let root: URL
        let store: UICanvasStore
        let mockup: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ui-canvas-\(UUID().uuidString)", isDirectory: true)
            store = UICanvasStore(root: root)
            let previews = root.appendingPathComponent("previews", isDirectory: true)
            try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
            mockup = previews.appendingPathComponent("pricing card.html")
            try Data("<!doctype html><body><article id=\"card\">Team</article></body>".utf8).write(to: mockup)
        }

        func open(reopen: Bool = false) throws -> UICanvasSession {
            guard case .opened(let session) = try store.open(
                file: mockup.path, taskID: "foc-070", title: "Pricing card", viewport: "mobile",
                reopen: reopen, agentName: "Claude Code") else {
                throw UICanvasError.sessionEnded
            }
            return session
        }
    }

    @Test("Open keys the session like ECC and stores it under the task")
    func openKeysByCanonicalPath() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.open()
        let canonical = UICanvasStore.canonicalPath(fixture.mockup.path)
        #expect(session.key == UICanvasStore.key(forCanonicalPath: canonical))
        #expect(session.key.count == 12)
        #expect(session.taskID == "FOC-070")
        #expect(session.viewport == "mobile")
        #expect(session.displayTitle == "Pricing card")
        let file = fixture.root.appendingPathComponent("tasks/FOC-070/canvas/\(session.key).json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(fixture.store.find(file: fixture.mockup.path, taskID: nil)?.key == session.key)
        #expect(fixture.store.sessions(taskID: "FOC-070").map(\.key) == [session.key])
    }

    @Test("Open rejects Markdown, missing files, and unknown viewports")
    func openValidates() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let markdown = fixture.root.appendingPathComponent("plan.md")
        try Data("# Plan".utf8).write(to: markdown)
        #expect(throws: UICanvasError.notHTML(markdown.path)) {
            _ = try fixture.store.open(file: markdown.path, taskID: "FOC-070", title: nil, viewport: nil,
                                       reopen: false, agentName: nil)
        }
        let missing = fixture.root.appendingPathComponent("missing.html").path
        #expect(throws: UICanvasError.missingArtifact(missing)) {
            _ = try fixture.store.open(file: missing, taskID: "FOC-070", title: nil, viewport: nil,
                                       reopen: false, agentName: nil)
        }
        #expect(throws: UICanvasError.invalidViewport("tablet")) {
            _ = try fixture.store.open(file: fixture.mockup.path, taskID: "FOC-070", title: nil, viewport: "tablet",
                                       reopen: false, agentName: nil)
        }
        #expect(UICanvasViewport.parse("1024x768") == UICanvasViewport(preset: "custom", width: 1024, height: 768))
        #expect(UICanvasViewport.parse("50x50") == nil)
    }

    @Test("Feedback is delivered exactly once and marks the agent thinking")
    func feedbackDeliveredOnce() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.open()
        let item = UICanvasFeedbackItem(
            kind: "chat", text: "  change this to dark gray  ",
            anchor: UICanvasAnchor(selector: "#card", tag: "article", snippet: "Team", size: .init(width: 720, height: 388)),
            pendingEdits: ["resized img.art to 220px wide"])
        let queued = try fixture.store.queueFeedback(taskID: "FOC-070", key: session.key, items: [item])
        #expect(queued.status == "feedback")
        #expect(queued.chat.last?.text == "[Team] change this to dark gray")
        #expect(UICanvasStore.presence(of: queued, isAlive: { _ in false }) == .queued)

        let first = try fixture.store.takeFeedback(taskID: "FOC-070", key: session.key)
        #expect(first.status == .feedback)
        #expect(first.items.map(\.id) == ["fb-1"])
        #expect(first.items.first?.text == "change this to dark gray")
        #expect(first.items.first?.anchor?.selector == "#card")
        #expect(first.items.first?.pendingEdits == ["resized img.art to 220px wide"])
        #expect(try fixture.store.takeFeedback(taskID: "FOC-070", key: session.key).status == .waiting)
        let after = try #require(try fixture.store.load(taskID: "FOC-070", key: session.key))
        #expect(after.status == "open")
        #expect(UICanvasStore.presence(of: after) == .thinking)

        try fixture.store.reply(taskID: "FOC-070", key: session.key, text: "Background is now --gray-800.")
        let replied = try #require(try fixture.store.load(taskID: "FOC-070", key: session.key))
        #expect(replied.chat.last?.role == "agent")
        #expect(replied.activity == nil)
    }

    @Test("Save and Finish ends the session and survives into the next await")
    func finishEndsSession() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.open()
        let edits: [UICanvasJSON] = [
            .object(["kind": .string("resize"), "selector": .string("img.art"), "tag": .string("img"),
                     "width": .number(220), "height": .number(220), "_el": .string("private"),
                     "before": .object(["width": .number(260), "height": .number(260)])]),
            .object(["kind": .string("bogus"), "selector": .string("div")]),
        ]
        let paths = try UICanvasStore.writeExport(
            artifact: fixture.mockup, html: "<!DOCTYPE html><html></html>\n", edits: edits,
            viewport: .mobile, kind: "finish")
        #expect(paths.html.lastPathComponent == "pricing card.edited.html")
        #expect(paths.edits.lastPathComponent == "pricing card.edits.json")
        let record = try JSONDecoder().decode(UICanvasJSON.self, from: Data(contentsOf: paths.edits))
        #expect(record["edits"]?.array?.count == 1)
        #expect(record["edits"]?.array?.first?["_el"] == nil)
        #expect(String(decoding: try Data(contentsOf: paths.edits), as: UTF8.self).contains("\"width\" : 220\n"))

        let finish = UICanvasFeedbackItem(kind: "finish", edits: edits, viewport: .mobile,
                                          exportPath: paths.html.path, editsPath: paths.edits.path)
        #expect(finish.editCount == 1)
        try fixture.store.queueFeedback(taskID: "FOC-070", key: session.key, items: [finish], endSession: true)
        let result = try fixture.store.takeFeedback(taskID: "FOC-070", key: session.key)
        #expect(result.status == .feedback)
        #expect(result.sessionEnded)
        #expect(result.endedBy == "user")
        #expect(result.items.first?.exportPath == paths.html.path)
        #expect(try fixture.store.takeFeedback(taskID: "FOC-070", key: session.key)
            == UICanvasTakeResult(status: .ended, endedBy: "user"))
        #expect(throws: UICanvasError.sessionEnded) {
            try fixture.store.queueFeedback(taskID: "FOC-070", key: session.key, items: [UICanvasFeedbackItem(kind: "chat", text: "late")])
        }
        guard case .refused = try fixture.store.open(file: fixture.mockup.path, taskID: "FOC-070", title: nil,
                                                     viewport: nil, reopen: false, agentName: nil) else {
            Issue.record("A user-ended canvas reopened without --reopen")
            return
        }
        #expect(try fixture.open(reopen: true).status == "open")
    }

    @Test("Presence is honest about dead, silent, and typing agents")
    func presence() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var session = try fixture.open()
        let now = Date()
        #expect(UICanvasStore.presence(of: session, now: now) == .waiting)
        session.listener = UICanvasListener(name: "Codex", pid: 42, seenAt: UICanvasStore.timestamp(now))
        #expect(UICanvasStore.presence(of: session, now: now, isAlive: { _ in true }) == .listening)
        #expect(UICanvasStore.presence(of: session, now: now, isAlive: { _ in false }) == .waiting)
        #expect(UICanvasStore.presence(of: session, now: now.addingTimeInterval(60), isAlive: { _ in true }) == .waiting)
        session.activity = UICanvasActivity(state: "typing", at: UICanvasStore.timestamp(now))
        #expect(UICanvasStore.presence(of: session, now: now.addingTimeInterval(2), isAlive: { _ in true }) == .typing)
        // Typing expires after 10 s; the listener heartbeat is still fresh.
        #expect(UICanvasStore.presence(of: session, now: now.addingTimeInterval(20), isAlive: { _ in true }) == .listening)
        session.status = "ended"
        #expect(UICanvasStore.presence(of: session) == .ended)
        #expect(UICanvasPresence.listening.label(agent: "Codex") == "Codex listening")
    }

    @Test("The app's viewer heartbeat reports whether the human has the canvas open")
    func viewerHeartbeat() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.open()
        #expect(!UICanvasStore.isViewerVisible(session))
        let now = Date()
        try fixture.store.markViewer(taskID: "FOC-070", key: session.key, at: now)
        let seen = try #require(try fixture.store.load(taskID: "FOC-070", key: session.key))
        #expect(UICanvasStore.isViewerVisible(seen, now: now.addingTimeInterval(5)))
        #expect(!UICanvasStore.isViewerVisible(seen, now: now.addingTimeInterval(30)))
    }

    @Test("Edit summaries match ECC's wording")
    func summaries() {
        func edit(_ fields: [String: UICanvasJSON]) -> UICanvasJSON {
            .object(fields.merging(["selector": .string("#cta"), "tag": .string("button"), "snippet": .string("Start")]) { a, _ in a })
        }
        #expect(UICanvasEditSummary.summarize(edit(["kind": .string("style"), "property": .string("color"),
            "before": .string("rgb(0, 0, 0)"), "after": .string("#ffffff")]))
            == "set color on #cta <button> \"Start\" to #ffffff (was rgb(0, 0, 0))")
        #expect(UICanvasEditSummary.summarize(edit(["kind": .string("style"), "property": .string("border"),
            "before": .string("1px solid red"), "after": .null]))
            == "removed border from #cta <button> \"Start\" (was 1px solid red)")
        #expect(UICanvasEditSummary.summarize(edit(["kind": .string("nudge"), "dx": .number(4), "dy": .number(-2), "stale": .bool(true)]))
            == "nudged #cta <button> \"Start\" by 4px, -2px (could not be re-applied after the last reload)")
        #expect(UICanvasEditSummary.summarize(edit(["kind": .string("resize"), "width": .number(220),
            "before": .object(["width": .number(260), "height": .number(40)])]))
            == "resized #cta <button> \"Start\" to 220px wide (was 260×40)")
        #expect(UICanvasEditSummary.chatLine(UICanvasFeedbackItem(kind: "edits", text: "tighter", edits: [edit(["kind": .string("remove")])]))
            == "Applied 1 edit to the preview: tighter")
    }

    @Test("Agent identity follows the Focus Queue provider and the ECC override")
    func identity() {
        #expect(UICanvasAgentIdentity.name(environment: ["FOCUS_QUEUE_PROVIDER": "codex"]) == "Codex")
        #expect(UICanvasAgentIdentity.name(environment: ["FOCUS_QUEUE_PROVIDER": "claude", "ECC_CANVAS_AGENT": "Pi"]) == "Pi")
        #expect(UICanvasAgentIdentity.name(environment: [:]) == "agent")
    }

    @Test("Await times out as waiting, returns queued feedback, and clears its listener")
    func awaitLoop() async throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try fixture.open()
        let waiting = try await UICanvasCommand.awaitFeedback(
            session: session, store: fixture.store, agentName: "Claude Code", timeoutMilliseconds: 300)
        #expect(waiting.status == "waiting")
        let idle = try #require(try fixture.store.load(taskID: "FOC-070", key: session.key))
        #expect(idle.listener == nil)
        #expect(idle.agentName == "Claude Code")

        let store = fixture.store
        let key = session.key
        Task.detached {
            try? await Task.sleep(nanoseconds: 400_000_000)
            try? store.queueFeedback(taskID: "FOC-070", key: key, items: [UICanvasFeedbackItem(kind: "chat", text: "Lose the border")])
        }
        let delivered = try await UICanvasCommand.awaitFeedback(
            session: session, store: fixture.store, agentName: "Claude Code", timeoutMilliseconds: 5_000)
        #expect(delivered.status == "feedback")
        #expect(delivered.items?.first?.text == "Lose the border")
        #expect(delivered.nextStep?.contains("canvas await") == true)
    }
}
