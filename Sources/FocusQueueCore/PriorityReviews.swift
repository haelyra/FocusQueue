import Darwin
import Foundation

/// Priority human reviews: the few documents that most need a person.
///
/// An agent proposes a document with a priority and the reason a human must
/// read it; an orchestrator (or the human) approves it. Approved reviews show
/// at the top of the Focus queue, at most `PriorityReviewStore.visibleLimit`
/// at a time, so a person running many agents reads what matters first.
/// Each task keeps its own `tasks/<TASK-ID>/reviews.json`, rewritten under an
/// exclusive flock on `reviews.lock`, so tasks never contend with each other.
public enum PriorityReviewStatus: String, Codable, CaseIterable, Sendable {
    /// An agent asked for a human; waits for orchestrator approval.
    case proposed
    /// Approved; eligible for the queue's priority list.
    case approved
    /// The human read it.
    case done
    /// Withdrawn or declined; never shown.
    case dismissed

    public var isOpen: Bool { self == .proposed || self == .approved }
}

public enum PriorityReviewLevel: String, Codable, CaseIterable, Sendable, Comparable {
    case critical, high, medium, low

    public var rank: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
}

public struct PriorityReview: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var taskID: String
    /// The agent that proposed it; empty when a human added it.
    public var agentID: String
    /// Absolute path of the document to review.
    public var document: String
    public var title: String
    /// Why a human, and not an agent, must read it.
    public var reason: String
    public var priority: PriorityReviewLevel
    public var status: PriorityReviewStatus
    public var proposedAt: Date
    public var approvedAt: Date?
    public var approvedBy: String?
    public var resolvedAt: Date?

    public init(id: String = PriorityReview.makeID(), taskID: String, agentID: String, document: String,
                title: String, reason: String, priority: PriorityReviewLevel,
                status: PriorityReviewStatus = .proposed, proposedAt: Date = Date(),
                approvedAt: Date? = nil, approvedBy: String? = nil, resolvedAt: Date? = nil) {
        self.id = id; self.taskID = taskID; self.agentID = agentID; self.document = document
        self.title = title; self.reason = reason; self.priority = priority; self.status = status
        self.proposedAt = proposedAt; self.approvedAt = approvedAt; self.approvedBy = approvedBy
        self.resolvedAt = resolvedAt
    }

    /// Short, typeable IDs such as `R7K2Q`.
    public static func makeID() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return "R" + String((0..<4).map { _ in alphabet.randomElement()! })
    }

    public var documentURL: URL { URL(fileURLWithPath: document) }

    /// Highest priority first, then the longest-approved, then the oldest proposal.
    public static func queueOrder(_ lhs: PriorityReview, _ rhs: PriorityReview) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        let left = lhs.approvedAt ?? lhs.proposedAt, right = rhs.approvedAt ?? rhs.proposedAt
        if left != right { return left < right }
        return lhs.id < rhs.id
    }
}

public struct PriorityReviewError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PriorityReviewStore: Sendable {
    public static let fileName = "reviews.json"
    public static let notificationName = "com.ecc.focusqueue.priority-reviews.changed"
    /// The most reviews the queue shows at once; more wait their turn.
    public static let visibleLimit = 5

    public let root: URL

    public init(root: URL) { self.root = root }

    private func taskFolder(_ taskID: String) throws -> URL {
        let id = taskID.uppercased()
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else {
            throw PriorityReviewError("\(taskID) is not a task ID.")
        }
        return root.appendingPathComponent("tasks", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }

    public func fileURL(taskID: String) throws -> URL {
        try taskFolder(taskID).appendingPathComponent(Self.fileName)
    }

    // MARK: Reading

    public func reviews(taskID: String) -> [PriorityReview] {
        guard let url = try? fileURL(taskID: taskID), let data = try? Data(contentsOf: url) else { return [] }
        return (try? Self.decoder.decode([PriorityReview].self, from: data)) ?? []
    }

    /// Every task's reviews. Only folders with a reviews file are read.
    public func allReviews() -> [PriorityReview] {
        let tasks = root.appendingPathComponent("tasks", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: tasks.path)) ?? []
        return folders.sorted().flatMap { folder -> [PriorityReview] in
            let url = tasks.appendingPathComponent(folder).appendingPathComponent(Self.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            return reviews(taskID: folder)
        }
    }

    /// The queue's split of open reviews among `openTaskIDs`: the approved
    /// reviews shown now (at most `limit`), approved ones waiting their turn,
    /// and proposals still awaiting approval.
    public static func partition(_ reviews: [PriorityReview], openTaskIDs: Set<String>,
                                 limit: Int = visibleLimit)
        -> (visible: [PriorityReview], waiting: [PriorityReview], proposed: [PriorityReview]) {
        let open = reviews.filter { $0.status.isOpen && openTaskIDs.contains($0.taskID.uppercased()) }
        let approved = open.filter { $0.status == .approved }.sorted(by: PriorityReview.queueOrder)
        let proposed = open.filter { $0.status == .proposed }.sorted(by: PriorityReview.queueOrder)
        return (Array(approved.prefix(limit)), Array(approved.dropFirst(limit)), proposed)
    }

    // MARK: Writing

    @discardableResult
    public func propose(taskID: String, agentID: String, document: URL, title: String?, reason: String,
                        priority: PriorityReviewLevel, approved: Bool = false, approvedBy: String? = nil,
                        now: Date = Date()) throws -> PriorityReview {
        let path = document.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw PriorityReviewError("No document at \(path).")
        }
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { throw PriorityReviewError("Say why a human must review it.") }
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? document.deletingPathExtension().lastPathComponent
        return try update(taskID: taskID) { reviews in
            // One open review per document: a repeat proposal refreshes it.
            if let index = reviews.firstIndex(where: { $0.document == path && $0.status.isOpen }) {
                reviews[index].title = title
                reviews[index].reason = reason
                reviews[index].priority = priority
                if approved, reviews[index].status == .proposed {
                    reviews[index].status = .approved
                    reviews[index].approvedAt = now
                    reviews[index].approvedBy = approvedBy
                }
                return reviews[index]
            }
            var ids = Set(reviews.map(\.id))
            var id = PriorityReview.makeID()
            while ids.contains(id) { id = PriorityReview.makeID() }
            ids.insert(id)
            let review = PriorityReview(
                id: id, taskID: taskID.uppercased(), agentID: agentID, document: path, title: title,
                reason: reason, priority: priority, status: approved ? .approved : .proposed, proposedAt: now,
                approvedAt: approved ? now : nil, approvedBy: approved ? approvedBy : nil)
            reviews.append(review)
            return review
        }
    }

    /// Approves a proposal, optionally re-ranking it. Approving an approved
    /// review only re-ranks it.
    @discardableResult
    public func approve(taskID: String, reviewID: String, by approver: String,
                        priority: PriorityReviewLevel? = nil, now: Date = Date()) throws -> PriorityReview {
        try mutate(taskID: taskID, reviewID: reviewID) { review in
            guard review.status.isOpen else {
                throw PriorityReviewError("Review \(review.id) is \(review.status.rawValue); propose it again to reopen it.")
            }
            if let priority { review.priority = priority }
            if review.status == .proposed {
                review.status = .approved
                review.approvedAt = now
                review.approvedBy = approver
            }
        }
    }

    @discardableResult
    public func resolve(taskID: String, reviewID: String, as status: PriorityReviewStatus,
                        now: Date = Date()) throws -> PriorityReview {
        guard status == .done || status == .dismissed else {
            throw PriorityReviewError("A review resolves as done or dismissed.")
        }
        return try mutate(taskID: taskID, reviewID: reviewID) { review in
            review.status = status
            review.resolvedAt = now
        }
    }

    private func mutate(taskID: String, reviewID: String,
                        _ body: (inout PriorityReview) throws -> Void) throws -> PriorityReview {
        try update(taskID: taskID) { reviews in
            guard let index = reviews.firstIndex(where: { $0.id.caseInsensitiveCompare(reviewID) == .orderedSame })
            else { throw PriorityReviewError("No review \(reviewID) on \(taskID.uppercased()).") }
            try body(&reviews[index])
            return reviews[index]
        }
    }

    /// Reads, mutates, and atomically rewrites one task's reviews under its lock.
    private func update<T>(taskID: String, _ body: (inout [PriorityReview]) throws -> T) throws -> T {
        let folder = try taskFolder(taskID)
        guard FileManager.default.fileExists(atPath: folder.path) else {
            throw PriorityReviewError("No task \(taskID.uppercased()) in \(root.path).")
        }
        let url = folder.appendingPathComponent(Self.fileName)
        let lockPath = folder.appendingPathComponent("reviews.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        var reviews: [PriorityReview] = []
        if let data = try? Data(contentsOf: url) {
            do { reviews = try Self.decoder.decode([PriorityReview].self, from: data) } catch {
                throw PriorityReviewError("\(url.path) is not valid review JSON; fix or remove it first.")
            }
        }
        let before = reviews
        let result = try body(&reviews)
        if reviews != before {
            try Self.encoder.encode(reviews).write(to: url, options: .atomic)
        }
        return result
    }

    public func notify(taskID: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.notificationName), object: nil,
            userInfo: ["task": taskID.uppercased(), "root": root.standardizedFileURL.path],
            deliverImmediately: true)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
