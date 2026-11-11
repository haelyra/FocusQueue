import CryptoKit
import Darwin
import Foundation

// Native UI Canvas: the Focus Queue counterpart of ECC's `ecc-ui-canvas`.
// An agent writes one self-contained HTML mockup and opens it with
// `focus-queue-session canvas open`; the app shows it as a tab in the task's
// plan viewer, where the human edits it by hand, chats, applies edits, and
// clicks Save and Finish. `canvas await` hands those actions back to the agent
// as the same JSON items ECC's canvas returns, so the skill's loop is unchanged.
//
// Sessions live under tasks/<TASK-ID>/canvas/<key>.json, keyed like ECC by the
// canonical artifact path. The app and the CLI both read-modify-write a session
// under an exclusive flock on <key>.lock.

/// A JSON value that keeps editor records exactly as the in-page editor sent them.
public enum UICanvasJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([UICanvasJSON])
    case object([String: UICanvasJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([UICanvasJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: UICanvasJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 { try container.encode(Int64(value)) }
            else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Converts a Foundation object graph, such as a WebKit script message body.
    public init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map { UICanvasJSON(any: $0) })
        case let object as [String: Any]: self = .object(object.mapValues { UICanvasJSON(any: $0) })
        default: self = .null
        }
    }

    public subscript(key: String) -> UICanvasJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var array: [UICanvasJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isNull: Bool { self == .null }

    /// A Foundation object graph for `JSONSerialization` or WebKit.
    public var foundationValue: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let value): value.map(\.foundationValue)
        case .object(let value): value.mapValues(\.foundationValue)
        }
    }
}

public struct UICanvasViewport: Codable, Equatable, Sendable {
    public var preset: String
    public var width: Int
    public var height: Int

    public init(preset: String, width: Int, height: Int) {
        self.preset = preset
        self.width = width
        self.height = height
    }

    /// CSS pixel presets shared with ECC's canvas. Desktop fills the stage and
    /// uses these numbers only as a fallback.
    public static let mobile = UICanvasViewport(preset: "mobile", width: 393, height: 852)
    public static let desktop = UICanvasViewport(preset: "desktop", width: 1440, height: 900)
    public static let custom = UICanvasViewport(preset: "custom", width: 1280, height: 800)
    public static let dimensionRange = 100...20_000

    /// Parses `mobile`, `desktop`, `custom`, or exact `WxH`; nil for anything else.
    public static func parse(_ spec: String) -> UICanvasViewport? {
        let text = spec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "mobile": return .mobile
        case "desktop": return .desktop
        case "custom": return .custom
        default:
            let parts = text.split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  dimensionRange.contains(width), dimensionRange.contains(height) else { return nil }
            return UICanvasViewport(preset: "custom", width: width, height: height)
        }
    }
}

public struct UICanvasAnchor: Codable, Equatable, Sendable {
    public struct Size: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    public var selector: String
    public var tag: String
    public var snippet: String
    public var size: Size?

    public init(selector: String, tag: String, snippet: String, size: Size? = nil) {
        self.selector = String(selector.prefix(500))
        self.tag = String(tag.prefix(60))
        self.snippet = String(snippet.prefix(200))
        self.size = size
    }
}

/// One human action delivered to the agent: `chat`, `edits` (Apply to file), or `finish`.
public struct UICanvasFeedbackItem: Codable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var text: String
    public var at: String
    public var anchor: UICanvasAnchor?
    public var pendingEdits: [String]?
    public var editCount: Int?
    public var edits: [UICanvasJSON]?
    public var viewport: UICanvasViewport?
    public var exportPath: String?
    public var editsPath: String?

    public static let kinds: Set<String> = ["chat", "edits", "finish"]

    public init(kind: String, text: String = "", anchor: UICanvasAnchor? = nil,
                pendingEdits: [String]? = nil, edits: [UICanvasJSON]? = nil,
                viewport: UICanvasViewport? = nil, exportPath: String? = nil, editsPath: String? = nil) {
        id = ""
        self.kind = kind
        self.text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        at = UICanvasStore.timestamp()
        self.anchor = anchor
        self.pendingEdits = pendingEdits.map { Array($0.prefix(60).map { String($0.prefix(240)) }) }
        self.edits = edits.map { Array(UICanvasEditSummary.normalized($0).prefix(500)) }
        editCount = self.edits?.count
        self.viewport = viewport
        self.exportPath = exportPath
        self.editsPath = editsPath
    }
}

public struct UICanvasChatEntry: Codable, Equatable, Sendable {
    public var role: String
    public var kind: String
    public var text: String
    public var at: String

    public init(role: String, kind: String, text: String, at: String = UICanvasStore.timestamp()) {
        self.role = role
        self.kind = kind
        self.text = text
        self.at = at
    }
}

/// The agent process parked in `canvas await`.
public struct UICanvasListener: Codable, Equatable, Sendable {
    public var name: String
    public var pid: Int32
    public var seenAt: String

    public init(name: String, pid: Int32, seenAt: String) {
        self.name = name
        self.pid = pid
        self.seenAt = seenAt
    }
}

/// What the agent signalled with `canvas typing` or by taking feedback.
public struct UICanvasActivity: Codable, Equatable, Sendable {
    public var state: String
    public var at: String
}

public struct UICanvasSession: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var file: String
    public var taskID: String
    public var title: String
    public var viewport: String
    public var status: String
    public var endedBy: String?
    public var createdAt: String
    public var updatedAt: String
    public var chat: [UICanvasChatEntry]
    public var pendingFeedback: [UICanvasFeedbackItem]
    public var feedbackCounter: Int
    public var agentName: String?
    public var listener: UICanvasListener?
    public var activity: UICanvasActivity?
    /// Stamped by the app while the canvas tab is on screen.
    public var viewerSeenAt: String?

    public var id: String { key }
    public var isEnded: Bool { status == "ended" }
    public var displayTitle: String {
        title.isEmpty ? URL(fileURLWithPath: file).lastPathComponent : title
    }
}

public enum UICanvasPresence: String, Sendable {
    case waiting, listening, thinking, typing, queued, ended

    public func label(agent: String) -> String {
        switch self {
        case .waiting: "\(agent) not connected"
        case .listening: "\(agent) listening"
        case .thinking: "\(agent) is working…"
        case .typing: "\(agent) is typing…"
        case .queued: "queued for \(agent)"
        case .ended: "session ended"
        }
    }
}

public enum UICanvasError: Error, LocalizedError, Equatable {
    case notHTML(String)
    case missingArtifact(String)
    case notRegularFile(String)
    case unreadableArtifact(String)
    case artifactTooLarge(String)
    case noTask
    case invalidViewport(String)
    case invalidTyping(String)
    case noSession(String)
    case sessionEnded
    case snapshotTooLarge

    public var errorDescription: String? {
        switch self {
        case .notHTML(let file):
            "canvas opens self-contained .html mockups; write the component to an .html file first (got \(file))"
        case .missingArtifact(let file): "artifact not found: \(file)"
        case .notRegularFile(let file):
            "canvas opens regular .html files; \(file) is a named pipe, device, socket, or folder"
        case .unreadableArtifact(let file): "artifact cannot be read: \(file)"
        case .artifactTooLarge(let file):
            "\(file) is larger than the \(UICanvasArtifactValidation.maximumBytes / (1024 * 1024)) MB canvas limit"
        case .noTask:
            "No task: run inside a Focus Queue agent pane ($FOCUS_QUEUE_TASK_ID) or pass --task <TASK-ID>."
        case .invalidViewport(let value): "viewport must be mobile, desktop, custom, or WxH (got \(value))"
        case .invalidTyping(let value): "state must be thinking, typing, or idle (got \(value))"
        case .noSession(let file): "no canvas session for \(file); run `focus-queue-session canvas open` first"
        case .sessionEnded: "the canvas session already ended"
        case .snapshotTooLarge: "the HTML snapshot exceeds 6 MB"
        }
    }
}

public enum UICanvasOpenResult: Sendable {
    case opened(UICanvasSession)
    case refused(UICanvasSession)
}

/// Checks an artifact before the canvas registers or reloads it: an .html or
/// .htm path that resolves to a readable regular file within the size ceiling.
/// It never reads the content and never blocks, so the main thread may call it.
public enum UICanvasArtifactValidation {
    public static let maximumBytes = FileReadLimits.canvasArtifactBytes

    /// Throws a `UICanvasError` describing why `url` cannot be shown.
    public static func validate(_ url: URL) throws {
        try validate(path: url.path, reportedAs: url.path)
    }

    static func validate(path: String, reportedAs file: String) throws {
        let canonical = UICanvasStore.canonicalPath(path)
        guard ["html", "htm"].contains(URL(fileURLWithPath: canonical).pathExtension.lowercased()) else {
            throw UICanvasError.notHTML(file)
        }
        do {
            try SafeFileRead.validateRegularFile(at: URL(fileURLWithPath: canonical), limit: maximumBytes)
        } catch SafeFileReadError.notRegularFile {
            throw UICanvasError.notRegularFile(file)
        } catch SafeFileReadError.tooLarge {
            throw UICanvasError.artifactTooLarge(file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw UICanvasError.missingArtifact(file)
        } catch {
            throw UICanvasError.unreadableArtifact(file)
        }
    }
}

public struct UICanvasTakeResult: Equatable, Sendable {
    public enum Status: String, Sendable { case feedback, ended, waiting, missing }
    public var status: Status
    public var items: [UICanvasFeedbackItem] = []
    public var sessionEnded = false
    public var endedBy: String?
}

public struct UICanvasStore: Sendable {
    /// Posted (distributed) after the CLI changes a session; userInfo carries `task` and `key`.
    public static let notificationName = "com.ecc.focusqueue.ui-canvas.changed"
    public static let maximumSnapshotBytes = 6 * 1024 * 1024
    /// An `await` refreshes its heartbeat this often; a listener older than
    /// `listenerExpiry` is treated as gone even if its PID was reused.
    public static let heartbeatInterval: TimeInterval = 5
    public static let listenerExpiry: TimeInterval = 30
    public static let typingExpiry: TimeInterval = 10
    public static let thinkingExpiry: TimeInterval = 300
    /// How long queued feedback waits for an agent's `await` before the app
    /// delivers it to the reconnected agent itself.
    public static let relayGrace: TimeInterval = 3

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    // MARK: Paths and keys

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func key(forCanonicalPath path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    public func directory(taskID: String) throws -> URL {
        guard !taskID.isEmpty, taskID.unicodeScalars.allSatisfy({
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0)
        }) else { throw TaskContextError.invalidIdentifier }
        return root.appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(taskID.uppercased(), isDirectory: true)
            .appendingPathComponent("canvas", isDirectory: true)
    }

    private func sessionURL(taskID: String, key: String) throws -> URL {
        guard key.range(of: "^[a-f0-9]{12}$", options: .regularExpression) != nil else {
            throw TaskContextError.invalidIdentifier
        }
        return try directory(taskID: taskID).appendingPathComponent("\(key).json")
    }

    /// Edit exports sit next to the artifact, named like ECC's.
    public static func exportPaths(for artifact: URL) -> (html: URL, edits: URL) {
        let directory = artifact.deletingLastPathComponent()
        let base = artifact.deletingPathExtension().lastPathComponent
        let ext = artifact.pathExtension.isEmpty ? "html" : artifact.pathExtension
        return (directory.appendingPathComponent("\(base).edited.\(ext)"),
                directory.appendingPathComponent("\(base).edits.json"))
    }

    // MARK: Reading

    public func load(taskID: String, key: String) throws -> UICanvasSession? {
        let url = try sessionURL(taskID: taskID, key: key)
        guard let data = try sessionData(at: url) else { return nil }
        return try JSONDecoder().decode(UICanvasSession.self, from: data)
    }

    /// A session's bytes, or nil when it is absent or unreadable. An oversized
    /// or special file throws, so it is reported and never silently replaced.
    private func sessionData(at url: URL) throws -> Data? {
        do { return try SafeFileRead.data(at: url, limit: FileReadLimits.metadataBytes) }
        catch let error as SafeFileReadError { throw error }
        catch { return nil }
    }

    /// Every readable session for a task, newest first.
    public func sessions(taskID: String) -> [UICanvasSession] {
        guard let directory = try? directory(taskID: taskID),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url in
                (try? sessionData(at: url))?.flatMap { try? JSONDecoder().decode(UICanvasSession.self, from: $0) }
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// The session for an artifact: in `taskID` when given, else in any task.
    public func find(file: String, taskID: String?) -> UICanvasSession? {
        let key = Self.key(forCanonicalPath: Self.canonicalPath(file))
        if let taskID { return try? load(taskID: taskID, key: key) }
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: tasks.path)) ?? []
        return folders.compactMap { try? load(taskID: $0, key: key) }
            .max { $0.updatedAt < $1.updatedAt }
    }

    // MARK: Writing

    /// Reads, mutates, and atomically rewrites one session under its lock.
    @discardableResult
    public func update<T>(taskID: String, key: String,
                          _ body: (inout UICanvasSession?) throws -> T) throws -> T {
        let url = try sessionURL(taskID: taskID, key: key)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lockPath = url.deletingPathExtension().appendingPathExtension("lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        var session = try sessionData(at: url).flatMap { try? JSONDecoder().decode(UICanvasSession.self, from: $0) }
        let before = session
        let result = try body(&session)
        if let session, session != before {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(session).write(to: url, options: .atomic)
        }
        return result
    }

    /// Opens or resumes the session for an artifact. A session the human ended
    /// stays closed unless `reopen` is set, so agents never pop it back uninvited.
    public func open(file: String, taskID: String, title: String?, viewport: String?,
                     reopen: Bool, agentName: String?) throws -> UICanvasOpenResult {
        let canonical = Self.canonicalPath(file)
        try UICanvasArtifactValidation.validate(path: canonical, reportedAs: file)
        if let viewport, UICanvasViewport.parse(viewport) == nil { throw UICanvasError.invalidViewport(viewport) }
        let key = Self.key(forCanonicalPath: canonical)
        return try update(taskID: taskID, key: key) { session in
            if let existing = session, existing.isEnded, existing.endedBy == "user", !reopen {
                return .refused(existing)
            }
            let now = Self.timestamp()
            var next = session ?? UICanvasSession(
                key: key, file: canonical, taskID: taskID.uppercased(), title: "", viewport: "desktop",
                status: "open", createdAt: now, updatedAt: now, chat: [], pendingFeedback: [], feedbackCounter: 0)
            if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                next.title = String(title.prefix(120))
            }
            if let viewport { next.viewport = viewport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            if let agentName { next.agentName = agentName }
            next.status = "open"
            next.endedBy = nil
            next.updatedAt = now
            session = next
            return .opened(next)
        }
    }

    /// Queues human feedback for the agent and mirrors it into the transcript.
    @discardableResult
    public func queueFeedback(taskID: String, key: String, items: [UICanvasFeedbackItem],
                              endSession: Bool = false) throws -> UICanvasSession {
        try update(taskID: taskID, key: key) { session in
            guard var next = session else { throw UICanvasError.noSession(key) }
            guard !next.isEnded else { throw UICanvasError.sessionEnded }
            for var item in items where UICanvasFeedbackItem.kinds.contains(item.kind) {
                if item.kind == "chat", item.text.isEmpty { continue }
                next.feedbackCounter += 1
                item.id = "fb-\(next.feedbackCounter)"
                next.pendingFeedback.append(item)
                next.chat.append(UICanvasChatEntry(role: "user", kind: item.kind, text: UICanvasEditSummary.chatLine(item), at: item.at))
            }
            if endSession {
                next.status = "ended"
                next.endedBy = "user"
            } else if !next.pendingFeedback.isEmpty {
                next.status = "feedback"
            }
            next.updatedAt = Self.timestamp()
            session = next
            return next
        }
    }

    /// Hands queued feedback to exactly one `await`; the agent is then marked thinking.
    public func takeFeedback(taskID: String, key: String) throws -> UICanvasTakeResult {
        try update(taskID: taskID, key: key) { session in
            guard var next = session else { return UICanvasTakeResult(status: .missing) }
            if !next.pendingFeedback.isEmpty {
                var result = UICanvasTakeResult(status: .feedback, items: next.pendingFeedback)
                next.pendingFeedback = []
                if next.isEnded {
                    result.sessionEnded = true
                    result.endedBy = next.endedBy
                } else {
                    next.status = "open"
                    next.activity = UICanvasActivity(state: "thinking", at: Self.timestamp())
                }
                next.updatedAt = Self.timestamp()
                session = next
                return result
            }
            if next.isEnded { return UICanvasTakeResult(status: .ended, endedBy: next.endedBy) }
            return UICanvasTakeResult(status: .waiting)
        }
    }

    public func reply(taskID: String, key: String, text: String) throws {
        try update(taskID: taskID, key: key) { session in
            guard var next = session else { throw UICanvasError.noSession(key) }
            next.chat.append(UICanvasChatEntry(role: "agent", kind: "chat", text: String(text.prefix(4_000))))
            next.activity = nil
            next.updatedAt = Self.timestamp()
            session = next
        }
    }

    public func setActivity(taskID: String, key: String, state: String) throws {
        guard ["thinking", "typing", "idle"].contains(state) else { throw UICanvasError.invalidTyping(state) }
        try update(taskID: taskID, key: key) { session in
            guard var next = session else { throw UICanvasError.noSession(key) }
            next.activity = state == "idle" ? nil : UICanvasActivity(state: state, at: Self.timestamp())
            session = next
        }
    }

    /// Records (or clears, with nil) the process parked in `await`.
    public func setListener(taskID: String, key: String, listener: UICanvasListener?, clearingPID: Int32? = nil) throws {
        try update(taskID: taskID, key: key) { session in
            guard var next = session else { return }
            if listener == nil, let clearingPID, next.listener?.pid != clearingPID { return }
            next.listener = listener
            if let name = listener?.name { next.agentName = name }
            if listener != nil, next.activity?.state == "thinking" { next.activity = nil }
            session = next
        }
    }

    public func end(taskID: String, key: String, endedBy: String) throws {
        try update(taskID: taskID, key: key) { session in
            guard var next = session else { throw UICanvasError.noSession(key) }
            next.status = "ended"
            next.endedBy = endedBy == "user" ? "user" : "agent"
            next.activity = nil
            next.updatedAt = Self.timestamp()
            session = next
        }
    }

    /// Replaces the artifact itself with the human's snapshot. Atomic
    /// replacement creates a new file; keep the original's permissions.
    public static func writeArtifact(_ artifact: URL, html: String) throws {
        guard html.utf8.count <= maximumSnapshotBytes else { throw UICanvasError.snapshotTooLarge }
        let permissions = try? FileManager.default.attributesOfItem(atPath: artifact.path)[.posixPermissions]
        try Data(html.utf8).write(to: artifact, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: artifact.path)
        }
    }

    /// Writes the human's snapshot and edit log next to the artifact.
    public static func writeExport(artifact: URL, html: String, edits: [UICanvasJSON],
                                   viewport: UICanvasViewport?, kind: String) throws -> (html: URL, edits: URL) {
        guard html.utf8.count <= maximumSnapshotBytes else { throw UICanvasError.snapshotTooLarge }
        let paths = exportPaths(for: artifact)
        try Data(html.utf8).write(to: paths.html, options: .atomic)
        var record: [String: UICanvasJSON] = [
            "artifact": .string(artifact.path), "kind": .string(kind), "at": .string(timestamp()),
            "edits": .array(UICanvasEditSummary.normalized(edits)),
        ]
        if let viewport {
            record["viewport"] = .object(["preset": .string(viewport.preset),
                                          "width": .number(Double(viewport.width)),
                                          "height": .number(Double(viewport.height))])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(UICanvasJSON.object(record))
        data.append(Data("\n".utf8))
        try data.write(to: paths.edits, options: .atomic)
        return paths
    }

    /// Honest presence: a dead or silent listener is not listening.
    public static func presence(of session: UICanvasSession, now: Date = Date(),
                                isAlive: (Int32) -> Bool = UICanvasStore.processIsAlive) -> UICanvasPresence {
        if session.isEnded { return .ended }
        if let activity = session.activity, let at = date(activity.at) {
            let age = now.timeIntervalSince(at)
            if activity.state == "typing", age < typingExpiry { return .typing }
            if activity.state == "thinking", age < thinkingExpiry { return .thinking }
        }
        if let listener = session.listener, let seen = date(listener.seenAt),
           now.timeIntervalSince(seen) < listenerExpiry, isAlive(listener.pid) {
            return .listening
        }
        return session.pendingFeedback.isEmpty ? .waiting : .queued
    }

    /// Whether the app should deliver queued feedback itself: nothing is parked
    /// in `await`, no agent is working, and the oldest item waited out the
    /// grace period. A user-ended session relays only a Save and Finish.
    public static func needsRelay(_ session: UICanvasSession, now: Date = Date(),
                                  isAlive: (Int32) -> Bool = UICanvasStore.processIsAlive) -> Bool {
        guard let oldest = session.pendingFeedback.compactMap({ date($0.at) }).min(),
              now.timeIntervalSince(oldest) >= relayGrace else { return false }
        if session.isEnded, !session.pendingFeedback.contains(where: { $0.kind == "finish" }) { return false }
        if let listener = session.listener, let seen = date(listener.seenAt),
           now.timeIntervalSince(seen) < listenerExpiry, isAlive(listener.pid) { return false }
        if let activity = session.activity, let at = date(activity.at) {
            let age = now.timeIntervalSince(at)
            if activity.state == "typing", age < typingExpiry { return false }
            if activity.state == "thinking", age < thinkingExpiry { return false }
        }
        return true
    }

    /// Whether the human has this canvas on screen in Focus Queue right now.
    public static func isViewerVisible(_ session: UICanvasSession, now: Date = Date()) -> Bool {
        guard let seen = session.viewerSeenAt.flatMap(date) else { return false }
        return now.timeIntervalSince(seen) < heartbeatInterval * 3
    }

    public func markViewer(taskID: String, key: String, at date: Date = Date()) throws {
        try update(taskID: taskID, key: key) { session in
            guard var next = session, !next.isEnded else { return }
            next.viewerSeenAt = Self.timestamp(date)
            session = next
        }
    }

    public static func processIsAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}

/// One-line descriptions of edits and feedback, matching ECC's wording.
public enum UICanvasEditSummary {
    public static let editKinds: Set<String> = ["text", "resize", "move", "nudge", "remove", "style"]

    /// Keeps only well-formed edits of known kinds and strips editor-private keys.
    public static func normalized(_ edits: [UICanvasJSON]) -> [UICanvasJSON] {
        edits.compactMap { edit in
            guard case .object(let object) = edit, let kind = object["kind"]?.string, editKinds.contains(kind),
                  let selector = object["selector"]?.string, !selector.isEmpty else { return nil }
            return .object(object.filter { !$0.key.hasPrefix("_") })
        }
    }

    public static func summarize(_ edit: UICanvasJSON) -> String {
        let selector = edit["selector"]?.string ?? ""
        let tag = edit["tag"]?.string.map { "<\($0)>" } ?? ""
        let snippet = edit["snippet"]?.string ?? ""
        let label = snippet.isEmpty ? "" : "\"\(snippet.prefix(48))\(snippet.count > 48 ? "…" : "")\""
        let target = [selector, tag, label].filter { !$0.isEmpty }.joined(separator: " ")
        let stale = edit["stale"]?.bool == true ? " (could not be re-applied after the last reload)" : ""
        func number(_ value: UICanvasJSON?) -> String? { value?.number.map { String(Int($0)) } }
        switch edit["kind"]?.string {
        case "text":
            return "text of \(target): \"\(edit["before"]?.string ?? "")\" → \"\(edit["after"]?.string ?? "")\"\(stale)"
        case "resize":
            let size = [number(edit["width"]).map { "\($0)px wide" }, number(edit["height"]).map { "\($0)px tall" }]
                .compactMap { $0 }.joined(separator: ", ")
            let before = edit["before"].flatMap { before -> String? in
                guard before["width"] != nil || before["height"] != nil else { return nil }
                return " (was \(number(before["width"]) ?? "?")×\(number(before["height"]) ?? "?"))"
            } ?? ""
            return "resized \(target) to \(size)\(before)\(stale)"
        case "move":
            let from = edit["from"], to = edit["to"]
            return "moved \(target) from \(from?["parent"]?.string ?? "its parent")[\(number(from?["index"]) ?? "?")] to \(to?["parent"]?.string ?? "its parent")[\(number(to?["index"]) ?? "?")]\(stale)"
        case "nudge":
            return "nudged \(target) by \(number(edit["dx"]) ?? "0")px, \(number(edit["dy"]) ?? "0")px\(stale)"
        case "remove":
            return "removed \(target)\(stale)"
        case "style":
            let property = edit["property"]?.string ?? "style"
            let before = edit["before"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "unset"
            if let after = edit["after"]?.string {
                return "set \(property) on \(target) to \(after) (was \(before))\(stale)"
            }
            return "removed \(property) from \(target) (was \(before))\(stale)"
        default:
            return ""
        }
    }

    public static func chatLine(_ item: UICanvasFeedbackItem) -> String {
        if item.kind == "finish" || item.kind == "edits" {
            let count = item.editCount ?? 0
            let noun = "edit\(count == 1 ? "" : "s")"
            let base = item.kind == "finish" ? "Saved and finished with \(count) \(noun)" : "Applied \(count) \(noun) to the preview"
            return item.text.isEmpty ? base : "\(base): \(item.text)"
        }
        if let anchor = item.anchor { return "[\(anchor.snippet.isEmpty ? anchor.selector : anchor.snippet)] \(item.text)" }
        return item.text
    }
}

/// The turn the app sends a reconnected agent: queued canvas feedback plus the
/// next step, without the `await` loop a terminal agent runs.
public enum UICanvasRelayPrompt {
    /// `recap` adds recent canvas chat for an agent with no saved conversation.
    public static func build(session: UICanvasSession, items: [UICanvasFeedbackItem], recap: Bool) -> String {
        var lines = [
            "The user sent this from the Focus Queue UI canvas \"\(session.displayTitle)\" (\(session.file)). "
                + "Focus Queue delivers each canvas message to you as a turn, so do not run "
                + "`focus-queue-session canvas await` or `canvas open`.",
        ]
        let earlier = session.chat.dropLast(items.count).suffix(8)
        if recap, !earlier.isEmpty {
            lines.append("Recent canvas conversation:\n" + earlier.map {
                "\($0.role == "agent" ? "agent" : "user"): \($0.text.prefix(600))"
            }.joined(separator: "\n"))
        }
        // The full edit log stays in the export file the item names.
        let trimmed = items.map { item -> UICanvasFeedbackItem in
            var item = item
            item.edits = nil
            return item
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(trimmed), let json = String(data: data, encoding: .utf8) {
            lines.append("Feedback:\n" + json)
        }
        lines.append(nextStep(items) + " Reply in one to three sentences saying what you changed; "
            + "your reply appears in the canvas conversation.")
        return lines.joined(separator: "\n\n")
    }

    static func nextStep(_ items: [UICanvasFeedbackItem]) -> String {
        if let finish = items.first(where: { $0.kind == "finish" }) {
            return "The user clicked Save and Finish. Read the final markup at \(finish.exportPath ?? "the .edited.html export") "
                + "(edit log: \(finish.editsPath ?? "the .edits.json export")) and reproduce that exact look in the real "
                + "component with full functionality."
        }
        if let applied = items.first(where: { $0.kind == "edits" }) {
            return "The user applied \(applied.editCount ?? 0) edit(s) to the preview. Rewrite the mockup file from "
                + "\(applied.exportPath ?? "the .edited.html export") and keep it self-contained."
        }
        return "Make the requested change in the mockup file; the preview live-reloads and re-applies the user's "
            + "pending edits. If the user only asked a question, answer it without editing."
    }
}

/// Names the harness running the CLI, for the presence pill.
public enum UICanvasAgentIdentity {
    public static func name(environment: [String: String]) -> String {
        if let name = environment["ECC_CANVAS_AGENT"]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return String(name.prefix(60))
        }
        switch environment["FOCUS_QUEUE_PROVIDER"]?.lowercased() {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        case "kimi": return "Kimi"
        default: break
        }
        if environment["CLAUDECODE"] == "1" || environment["CLAUDE_CODE_SESSION_ID"] != nil { return "Claude Code" }
        if environment.keys.contains(where: { $0.hasPrefix("CODEX_") }) { return "Codex" }
        return "agent"
    }
}
