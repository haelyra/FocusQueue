import Foundation
import FocusQueueCore

public struct MapRelation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case input, output, context, dependency, feedback, handoff }
    public var from: String
    public var to: String
    public var kind: Kind
    public var evidence: String
    public var observedAt: Date?
    public var importance: Int? = nil
    public var id: String { MapNode.identity(from, to, kind.rawValue) }
}

public struct MapScope: Codable, Equatable, Sendable {
    public var taskID: String
    public var subtaskID: String
    public var provider: String
    public var sessionID: String?
    public var inputs: [String]
    public var outputs: [String]
    public var updatedAt: Date

    public init(context: TaskContext, subtask: TaskSubtask, inputs: [String], outputs: [String], now: Date = Date()) {
        taskID = context.ticketID; subtaskID = subtask.id; provider = subtask.provider.rawValue
        sessionID = subtask.sessionID; updatedAt = now
        let base = context.worktreePath ?? context.repositoryPath ?? context.contextDirectory.path
        func paths(_ values: [String]) -> [String] {
            Array(Set(values.map { URL(fileURLWithPath: $0, relativeTo: URL(fileURLWithPath: base, isDirectory: true)).standardizedFileURL.path })).sorted()
        }
        self.inputs = paths(inputs); self.outputs = paths(outputs)
    }

    public static func directory(_ context: TaskContext) -> URL {
        context.contextDirectory.appendingPathComponent("workspace-map/scopes")
    }

    public func save(context: TaskContext) throws {
        guard taskID == context.ticketID, inputs.count + outputs.count <= 200 else {
            throw MapError.invalidSnapshot("A scope must belong to this task and contain at most 200 paths.")
        }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SystemFileAccessor().write(encoder.encode(self), to: Self.directory(context)
            .appendingPathComponent(MapNode.identity(subtaskID) + ".json"))
    }

    public static func load(context: TaskContext) throws -> [MapScope] {
        let directory = directory(context)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }.prefix(200).map { url in
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256_000 else {
                    throw MapError.invalidSnapshot("A map scope is too large to read.")
                }
                let scope = try decoder.decode(Self.self, from: Data(contentsOf: url))
                guard scope.taskID == context.ticketID, scope.inputs.count + scope.outputs.count <= 200,
                      (scope.inputs + scope.outputs).allSatisfy({ $0.hasPrefix("/") }) else {
                    throw MapError.invalidSnapshot("Invalid task or paths in map scope.")
                }
                return scope
            }
    }
}

public enum MapInstructionFiles {
    /// Only named instruction files on the document's ancestor chain are inspected.
    public static func ancestors(of path: String) -> [String] {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        var result: [String] = []
        for _ in 0..<40 {
            let file = directory.appendingPathComponent("AGENTS.md")
            if FileManager.default.fileExists(atPath: file.path) { result.append(file.path) }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { break }
            directory = parent
        }
        return result.reversed()
    }
}
