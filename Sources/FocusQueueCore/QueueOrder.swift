import Darwin
import Foundation

public enum QueuePlacement: Sendable {
    case top, bottom, before(String), after(String)
}

/// Shared by the app and its agent helper. A separate file prevents unrelated
/// cached app state from overwriting an agent's queue changes.
public struct QueueOrderStore: Sendable {
    public let directory: URL
    private let projectID: String?
    private var legacyFile: URL { directory.appendingPathComponent("order.json") }
    private var file: URL {
        guard let projectID else { return legacyFile }
        let encoded = Data(projectID.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent("order-\(encoded).json")
    }

    public init(root: URL, projectID: String? = nil) {
        directory = root.appendingPathComponent("queue-order", isDirectory: true)
        self.projectID = projectID
    }

    public func load() throws -> [String]? {
        let source = FileManager.default.fileExists(atPath: file.path)
            ? file
            : (projectID != nil && FileManager.default.fileExists(atPath: legacyFile.path)
                ? legacyFile : nil)
        guard let source else { return nil }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: source))
    }

    /// Saved tasks retain their positions; new tasks append in priority order.
    /// Missing, completed, and duplicate IDs never produce phantom rows.
    public static func orderedTickets(_ tickets: [DashboardTicket], savedIDs: [String]) -> [DashboardTicket] {
        let canonical = DashboardOrdering.openTickets(in: tickets)
        var remaining = Dictionary(canonical.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let saved = savedIDs.compactMap { remaining.removeValue(forKey: $0) }
        return saved + canonical.filter { remaining.removeValue(forKey: $0.id) != nil }
    }

    @discardableResult
    public func move(_ ticketID: String, to placement: QueuePlacement,
                     tickets: [DashboardTicket], fallbackIDs: [String], visibleIDs: Set<String>? = nil) throws -> [String] {
        try locked {
            let allIDs = Self.orderedTickets(tickets, savedIDs: try load() ?? fallbackIDs).map(\.id)
            var ids = allIDs.filter { visibleIDs?.contains($0) ?? true }
            guard ids.contains(ticketID) else {
                throw TaskContextError.commandFailed("No open task named \(ticketID) exists in this queue.")
            }
            switch placement {
            case .before(let target), .after(let target):
                guard ids.contains(target) else {
                    throw TaskContextError.commandFailed("No open task named \(target) exists in this queue.")
                }
                if target == ticketID { return allIDs }
            default: break
            }
            ids.removeAll { $0 == ticketID }
            switch placement {
            case .top: ids.insert(ticketID, at: 0)
            case .bottom: ids.append(ticketID)
            case .before(let target): ids.insert(ticketID, at: ids.firstIndex(of: target)!)
            case .after(let target): ids.insert(ticketID, at: ids.firstIndex(of: target)! + 1)
            }
            var iterator = ids.makeIterator()
            let result = allIDs.map { id in
                (visibleIDs?.contains(id) ?? true) ? iterator.next()! : id
            }
            try write(result)
            return result
        }
    }

    /// An explicit empty order restores priority sorting and supersedes legacy deferrals.
    public func reset() throws {
        try locked { try write([]) }
    }

    public func reset(tickets: [DashboardTicket], visibleIDs: Set<String>, fallbackIDs: [String]) throws -> [String] {
        try locked {
            let all = Self.orderedTickets(tickets, savedIDs: try load() ?? fallbackIDs).map(\.id)
            var sorted = DashboardOrdering.openTickets(in: tickets).filter { visibleIDs.contains($0.id) }.map(\.id).makeIterator()
            let result = all.map { visibleIDs.contains($0) ? sorted.next()! : $0 }
            try write(result)
            return result
        }
    }

    private func write(_ ids: [String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(ids).write(to: file, options: .atomic)
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = Darwin.open(directory.appendingPathComponent("order.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
