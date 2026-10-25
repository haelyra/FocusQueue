import Darwin
import Foundation

/// `focus-queue-session canvas ...`: the agent side of the native UI Canvas.
/// Arguments and JSON mirror `ecc-ui-canvas`, so the ui-canvas skill works by
/// swapping the command name.
public enum UICanvasCommand {
    public static let usage = """
        Usage: focus-queue-session canvas open <file.html> [--viewport mobile|desktop|custom|WxH] [--title <text>] [--reopen] [--task <TASK-ID>]
               focus-queue-session canvas await <file.html> [--reply <message>] [--timeout-ms <n>]
               focus-queue-session canvas typing <file.html> [--state thinking|typing|idle]
               focus-queue-session canvas end <file.html>
               focus-queue-session canvas list | pending
        """

    public struct Output: Encodable {
        var status: String
        var key: String?
        var file: String?
        var task: String?
        var viewer: String?
        var viewport: String?
        var items: [UICanvasFeedbackItem]?
        var sessionEnded: Bool?
        var endedBy: String?
        var presence: String?
        var sessions: [Listing]?
        var nextStep: String?

        enum CodingKeys: String, CodingKey {
            case status, key, file, task, viewer, viewport, items, sessionEnded, endedBy, presence, sessions
            case nextStep = "next_step"
        }
    }

    public struct Listing: Encodable {
        var key: String
        var file: String
        var task: String
        var title: String
        var status: String
        var pending: Int
        var presence: String
        var viewer: String
    }

    public static func run(arguments: [String], root: URL, environment: [String: String]) async throws {
        let store = UICanvasStore(root: root)
        var args = Array(arguments.dropFirst())
        guard let verb = args.first else { throw CanvasUsageError() }
        args.removeFirst()
        let taskOption = try option("--task", in: &args)
        let taskID = (taskOption ?? environment["FOCUS_QUEUE_TASK_ID"]).flatMap { $0.isEmpty ? nil : $0.uppercased() }
        let agentName = UICanvasAgentIdentity.name(environment: environment)

        switch verb {
        case "open":
            let viewport = try option("--viewport", in: &args)
            let title = try option("--title", in: &args)
            let reopen = flag("--reopen", in: &args)
            _ = flag("--no-open", in: &args) // Accepted for ECC parity; the app shows the canvas.
            guard args.count == 1 else { throw CanvasUsageError() }
            guard let taskID else { throw UICanvasError.noTask }
            switch try store.open(file: args[0], taskID: taskID, title: title, viewport: viewport,
                                  reopen: reopen, agentName: agentName) {
            case .refused(let session):
                try emit(Output(status: "user-ended", key: session.key, file: session.file, task: session.taskID,
                    nextStep: "The user ended this canvas in Focus Queue. Do not reopen it unless they ask; pass --reopen when they do."))
            case .opened(let session):
                notify(store, session, event: "open")
                try emit(Output(status: "open", key: session.key, file: session.file, task: session.taskID,
                    viewer: "Focus Queue", viewport: session.viewport,
                    nextStep: "Run `focus-queue-session canvas await \(quoted(session.file))` in the background and leave it running; it returns when the human chats, applies edits, or clicks Save and Finish."))
            }

        case "await":
            let reply = try option("--reply", in: &args)
            let timeout = try option("--timeout-ms", in: &args).map { value -> Int in
                guard let milliseconds = Int(value), milliseconds >= 0 else { throw CanvasUsageError() }
                return milliseconds
            }
            guard args.count == 1 else { throw CanvasUsageError() }
            let session = try located(args[0], taskID: taskID, store: store)
            if let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try store.reply(taskID: session.taskID, key: session.key, text: reply)
                notify(store, session)
            }
            try emit(try await awaitFeedback(session: session, store: store, agentName: agentName, timeoutMilliseconds: timeout))

        case "typing":
            let state = try option("--state", in: &args) ?? "typing"
            guard args.count == 1 else { throw CanvasUsageError() }
            let session = try located(args[0], taskID: taskID, store: store)
            try store.setActivity(taskID: session.taskID, key: session.key, state: state)
            notify(store, session)
            let updated = try store.load(taskID: session.taskID, key: session.key) ?? session
            try emit(Output(status: "ok", presence: UICanvasStore.presence(of: updated).rawValue))

        case "end":
            guard args.count == 1 else { throw CanvasUsageError() }
            let session = try located(args[0], taskID: taskID, store: store)
            try store.end(taskID: session.taskID, key: session.key, endedBy: "agent")
            notify(store, session)
            try emit(Output(status: "ended", endedBy: "agent"))

        case "list", "pending":
            guard args.isEmpty else { throw CanvasUsageError() }
            let tasks: [String]
            if let taskID { tasks = [taskID] }
            else {
                let folder = root.appendingPathComponent("tasks", isDirectory: true)
                tasks = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            }
            let listings = tasks.flatMap { store.sessions(taskID: $0) }
                .filter { verb == "list" || !$0.pendingFeedback.isEmpty }
                .map { Listing(key: $0.key, file: $0.file, task: $0.taskID, title: $0.displayTitle, status: $0.status,
                               pending: $0.pendingFeedback.count, presence: UICanvasStore.presence(of: $0).rawValue,
                               viewer: UICanvasStore.isViewerVisible($0) ? "visible" : "hidden") }
            try emit(Output(status: "ok", sessions: listings,
                nextStep: verb == "pending" && !listings.isEmpty
                    ? "Feedback is waiting. Run `focus-queue-session canvas await <file>` for each session to receive it." : nil))

        default:
            throw CanvasUsageError()
        }
    }

    /// Long-polls the session file. The listener heartbeat lets the app show
    /// "listening" only while this process is actually parked here.
    static func awaitFeedback(session: UICanvasSession, store: UICanvasStore, agentName: String,
                              timeoutMilliseconds: Int?) async throws -> Output {
        let pid = getpid()
        let started = Date()
        var lastHeartbeat = Date.distantPast
        defer { try? store.setListener(taskID: session.taskID, key: session.key, listener: nil, clearingPID: pid) }
        while true {
            let result = try store.takeFeedback(taskID: session.taskID, key: session.key)
            switch result.status {
            case .missing:
                throw UICanvasError.noSession(session.file)
            case .feedback:
                notify(store, session)
                return Output(status: "feedback", items: result.items,
                              sessionEnded: result.sessionEnded ? true : nil, endedBy: result.endedBy,
                              nextStep: nextStep(for: result, file: session.file))
            case .ended:
                notify(store, session)
                return Output(status: "ended", endedBy: result.endedBy,
                    nextStep: result.endedBy == "user"
                        ? "The human ended the canvas without saving. Stop polling and report in chat; do not reopen uninvited."
                        : "Session ended. Stop polling.")
            case .waiting:
                break
            }
            if let timeoutMilliseconds, Date().timeIntervalSince(started) * 1_000 >= Double(timeoutMilliseconds) {
                return Output(status: "waiting")
            }
            if Date().timeIntervalSince(lastHeartbeat) >= UICanvasStore.heartbeatInterval {
                let first = lastHeartbeat == .distantPast
                lastHeartbeat = Date()
                try store.setListener(taskID: session.taskID, key: session.key, listener: UICanvasListener(
                    name: agentName, pid: pid, seenAt: UICanvasStore.timestamp()))
                if first { notify(store, session) }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    static func nextStep(for result: UICanvasTakeResult, file: String) -> String {
        if let finish = result.items.first(where: { $0.kind == "finish" }) {
            return "The human clicked Save and Finish. Read the final markup at \(finish.exportPath ?? "the .edited.html export") (edit log: \(finish.editsPath ?? "the .edits.json export")), reproduce that exact look in the real component with full functionality, and report in chat. Do not reopen the canvas."
        }
        if let applied = result.items.first(where: { $0.kind == "edits" }) {
            return "The human applied \(applied.editCount ?? 0) edit(s) to the preview. Rewrite the mockup file from \(applied.exportPath ?? "the .edited.html export") (keep it self-contained), then run `focus-queue-session canvas await \(quoted(file)) --reply \"<what you changed>\"` to keep listening."
        }
        if result.sessionEnded {
            return "The human sent this and ended the canvas. Address it and report in chat; do not reopen the canvas uninvited."
        }
        return "Make the requested change in the mockup file; the preview live-reloads and re-applies the human's pending edits. Then run `focus-queue-session canvas await \(quoted(file)) --reply \"<what you changed>\"` to answer and keep listening."
    }

    private static func located(_ file: String, taskID: String?, store: UICanvasStore) throws -> UICanvasSession {
        guard let session = store.find(file: file, taskID: taskID) ?? store.find(file: file, taskID: nil) else {
            throw UICanvasError.noSession(file)
        }
        return session
    }

    private static func option(_ name: String, in args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else { throw CanvasUsageError() }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    private static func flag(_ name: String, in args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: name) else { return false }
        args.remove(at: index)
        return true
    }

    private static func quoted(_ path: String) -> String {
        path.contains(" ") ? "\"\(path)\"" : path
    }

    private static func notify(_ store: UICanvasStore, _ session: UICanvasSession, event: String = "change") {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(UICanvasStore.notificationName), object: nil,
            userInfo: ["task": session.taskID, "key": session.key, "event": event, "root": store.root.path],
            deliverImmediately: true)
    }

    private static func emit(_ output: Output) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

public struct CanvasUsageError: Error, LocalizedError {
    public var errorDescription: String? { UICanvasCommand.usage }
}
