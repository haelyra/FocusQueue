import Foundation

/// `focus-queue-session review ...`: propose, approve, and settle priority
/// human reviews. <TASK-ID> <AGENT-ID> may be omitted to use
/// $FOCUS_QUEUE_TASK_ID and $FOCUS_QUEUE_SUBTASK_ID.
public enum PriorityReviewCommand {
    public static let usage = """
        Usage: focus-queue-session review propose [<TASK-ID> <AGENT-ID>] <file> "<why a human must read it>" [--priority critical|high|medium|low] [--title "<text>"] [--approve]
               focus-queue-session review approve [<TASK-ID>] <REVIEW-ID> [--priority critical|high|medium|low]
               focus-queue-session review done|dismiss [<TASK-ID>] <REVIEW-ID>
               focus-queue-session review list [<TASK-ID>] [--all]
        Agents propose; an orchestrator approves (--approve on propose is for orchestrators only).
        The queue shows at most 5 approved reviews, highest priority first; the rest wait their turn.
        """

    public struct ListOutput: Encodable {
        public let visible: [PriorityReview]
        public let waiting: [PriorityReview]
        public let proposed: [PriorityReview]
        public var resolved: [PriorityReview]?
    }

    public static func run(arguments: [String], root: URL, environment: [String: String]) async throws {
        var args = Array(arguments.dropFirst())
        guard let verb = args.first else { throw PriorityReviewError(usage) }
        args.removeFirst()
        let store = PriorityReviewStore(root: root)
        let envTask = environment["FOCUS_QUEUE_TASK_ID"].flatMap { $0.isEmpty ? nil : $0.uppercased() }
        let envAgent = environment["FOCUS_QUEUE_SUBTASK_ID"].flatMap { $0.isEmpty ? nil : $0 }

        switch verb {
        case "propose", "add":
            let priority = try level(try option("--priority", in: &args)) ?? .high
            let title = try option("--title", in: &args)
            let approve = flag("--approve", in: &args)
            let taskID: String, agentID: String, file: String, reason: String
            switch args.count {
            case 4: (taskID, agentID, file, reason) = (args[0].uppercased(), args[1], args[2], args[3])
            case 2:
                guard let envTask else { throw PriorityReviewError(usage) }
                (taskID, agentID, file, reason) = (envTask, envAgent ?? "", args[0], args[1])
            default: throw PriorityReviewError(usage)
            }
            let review = try store.propose(
                taskID: taskID, agentID: agentID, document: resolve(file), title: title, reason: reason,
                priority: priority, approved: approve, approvedBy: approve ? approver(envAgent) : nil)
            store.notify(taskID: taskID)
            try emit(review)
        case "approve":
            let priority = try level(try option("--priority", in: &args))
            let (taskID, reviewID) = try target(args, store: store, envTask: envTask)
            let review = try store.approve(taskID: taskID, reviewID: reviewID, by: approver(envAgent), priority: priority)
            store.notify(taskID: taskID)
            try emit(review)
        case "done", "dismiss":
            let (taskID, reviewID) = try target(args, store: store, envTask: envTask)
            let review = try store.resolve(taskID: taskID, reviewID: reviewID,
                                           as: verb == "done" ? .done : .dismissed)
            store.notify(taskID: taskID)
            try emit(review)
        case "list":
            let all = flag("--all", in: &args)
            guard args.count <= 1 else { throw PriorityReviewError(usage) }
            let reviews = args.first.map { store.reviews(taskID: $0) } ?? store.allReviews()
            let open = Set(reviews.map { $0.taskID.uppercased() })
            let split = PriorityReviewStore.partition(reviews, openTaskIDs: open)
            var output = ListOutput(visible: split.visible, waiting: split.waiting, proposed: split.proposed)
            if all { output.resolved = reviews.filter { !$0.status.isOpen } }
            try emit(output)
        default:
            throw PriorityReviewError(usage)
        }
    }

    /// `<TASK-ID> <REVIEW-ID>`, or a bare review ID found in this agent's task
    /// or, failing that, the one task that has it.
    static func target(_ args: [String], store: PriorityReviewStore, envTask: String?) throws -> (String, String) {
        if args.count == 2 { return (args[0].uppercased(), args[1].uppercased()) }
        guard args.count == 1 else { throw PriorityReviewError(usage) }
        let reviewID = args[0].uppercased()
        if let envTask, store.reviews(taskID: envTask).contains(where: { $0.id == reviewID }) {
            return (envTask, reviewID)
        }
        let owners = Set(store.allReviews().filter { $0.id == reviewID }.map(\.taskID))
        guard owners.count == 1, let owner = owners.first else {
            throw PriorityReviewError(owners.isEmpty ? "No review \(reviewID)."
                : "Review \(reviewID) exists on \(owners.sorted().joined(separator: ", ")); name the task.")
        }
        return (owner, reviewID)
    }

    static func approver(_ agentID: String?) -> String { agentID.map { "agent:\($0)" } ?? "human" }

    static func level(_ raw: String?) throws -> PriorityReviewLevel? {
        guard let raw else { return nil }
        guard let level = PriorityReviewLevel(rawValue: raw.lowercased()) else {
            throw PriorityReviewError("Priority is critical, high, medium, or low.")
        }
        return level
    }

    static func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
    }

    static func option(_ name: String, in args: inout [String]) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        guard index + 1 < args.count else { throw PriorityReviewError(usage) }
        let value = args[index + 1]
        args.removeSubrange(index...(index + 1))
        return value
    }

    static func flag(_ name: String, in args: inout [String]) -> Bool {
        guard let index = args.firstIndex(of: name) else { return false }
        args.remove(at: index)
        return true
    }

    static func emit<T: Encodable>(_ value: T) throws {
        let data = try PriorityReviewStore.encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
    }
}
