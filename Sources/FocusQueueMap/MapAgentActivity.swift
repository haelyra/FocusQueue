import Foundation
import Darwin
import FocusQueueCore

/// Small, producer-neutral records for exact-session attribution and retrospective
/// views. No transcript scanning, process probing, file-content reads, or model calls.
public struct MapAgentActivity: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public enum Operation: String, Codable, Sendable { case read, write }
        public var path: String
        public var operation: Operation
        public var at: Date
        public var importance: Int?
    }
    public var version: Int
    public var taskID: String
    public var provider: String
    public var sessionID: String
    public var parentSessionID: String?
    public var parentProvider: String?
    public var label: String
    public var workingDirectory: String
    public var state: String
    public var updatedAt: Date
    public var entries: [Entry]

    public static func directory(_ context: TaskContext) -> URL { context.contextDirectory.appendingPathComponent("workspace-map/activity") }
    public static func decode(_ data: Data, taskID: String, now: Date = Date()) throws -> Self {
        guard data.count <= 256_000 else { throw MapError.invalidSnapshot("Activity record exceeds 256 KB.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(Self.self, from: data)
        guard report.version == 1, report.taskID == taskID, ["codex", "claude"].contains(report.provider),
              !report.sessionID.isEmpty, !(report.parentSessionID?.lowercased() == report.sessionID.lowercased() && (report.parentProvider ?? report.provider) == report.provider),
              (report.parentProvider == nil || ["codex", "claude"].contains(report.parentProvider!)),
              !report.label.isEmpty, report.workingDirectory.hasPrefix("/"), report.entries.count <= 500,
              ["working", "idle", "blocked", "completed", "unknown"].contains(report.state),
              report.updatedAt <= now.addingTimeInterval(60),
              report.entries.allSatisfy({ $0.path.hasPrefix("/") && $0.at <= now.addingTimeInterval(60) && (0...100).contains($0.importance ?? 0) }) else {
            throw MapError.invalidSnapshot("Invalid activity task, session, timestamps, or paths.")
        }
        return report
    }
    public func save(context: TaskContext) throws {
        let target = Self.directory(context).appendingPathComponent(MapNode.identity(provider, sessionID.lowercased()) + ".json")
        try FileManager.default.createDirectory(at: Self.directory(context), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(Self.directory(context).appendingPathComponent("writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MapError.unavailable("Could not lock activity records.") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw MapError.unavailable("Activity writer is busy; retry this report.") }
        defer { flock(descriptor, LOCK_UN) }
        var result = self
        if FileManager.default.fileExists(atPath: target.path) {
            let previous = try Self.read(target, taskID: taskID)
            if previous.updatedAt > updatedAt { result = previous }
            var records: [String: Entry] = [:]
            for entry in previous.entries + entries {
                let key = entry.operation.rawValue + "\0" + entry.path
                if entry.at >= (records[key]?.at ?? .distantPast) { records[key] = entry }
            }
            result.entries = Array(records.values.sorted { ($0.at, $0.path) > ($1.at, $1.path) }.prefix(500))
        }
        var reports = try Self.load(context: context).filter { !($0.provider == provider && $0.sessionID.lowercased() == sessionID.lowercased()) }
        guard reports.count < 100 else { throw MapError.invalidSnapshot("This task already has 100 recorded agent instances.") }
        reports.append(result)
        let parents = Dictionary(reports.compactMap { report -> (String, String)? in
            report.parentSessionID.map { (report.provider + ":" + report.sessionID.lowercased(), (report.parentProvider ?? report.provider) + ":" + $0.lowercased()) }
        }, uniquingKeysWith: { _, b in b })
        for key in parents.keys {
            var seen = Set<String>(), current: String? = key
            while let id = current {
                guard seen.insert(id).inserted else { throw MapError.invalidSnapshot("Subagent ancestry contains a cycle.") }
                current = parents[id]
            }
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(result)
        _ = try Self.decode(data, taskID: context.ticketID)
        try SystemFileAccessor().write(data, to: target)
    }
    private static func read(_ url: URL, taskID: String) throws -> Self {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256_000 else { throw MapError.invalidSnapshot("Activity record exceeds 256 KB.") }
        return try decode(Data(contentsOf: url), taskID: taskID)
    }
    public static func load(context: TaskContext) throws -> [Self] {
        let folder = directory(context)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.prefix(100).map { try read($0, taskID: context.ticketID) }
    }
}
