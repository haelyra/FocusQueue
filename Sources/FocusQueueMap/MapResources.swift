import Foundation
import FocusQueueCore

/// Durable instances and explicit feedback/handoff relationships. This manifest
/// records declarations only; collecting it never contacts or starts an instance.
public struct MapResources: Codable, Sendable {
    public struct Resource: Codable, Sendable {
        public var id: String
        public var label: String
        public var workspace: String?
        public var document: String?
        public var summary: String
        public var updatedAt: Date?
    }
    public struct Connection: Codable, Sendable {
        /// Endpoints: resource:<id>, agent:<subtaskID>, or file:<absolute path>.
        public var from: String
        public var to: String
        public var kind: MapRelation.Kind
    }
    public var version: Int
    public var taskID: String
    public var resources: [Resource]
    public var connections: [Connection]

    public static func location(_ context: TaskContext) -> URL {
        context.contextDirectory.appendingPathComponent("workspace-map/resources.json")
    }
    public static func decode(_ data: Data, taskID: String) throws -> Self {
        guard data.count <= 256_000 else { throw MapError.invalidSnapshot("Resource manifest exceeds 256 KB.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(Self.self, from: data)
        guard value.version == 1, value.taskID == taskID, value.resources.count <= 100, value.connections.count <= 300,
              Set(value.resources.map(\.id)).count == value.resources.count,
              value.resources.allSatisfy({ !$0.id.isEmpty && !$0.label.isEmpty && ($0.workspace == nil || $0.workspace!.hasPrefix("/")) }) else {
            throw MapError.invalidSnapshot("Invalid resource manifest identity, paths, or limits.")
        }
        return value
    }
    public func applying(to snapshot: MapSnapshot) throws -> MapSnapshot {
        var result = snapshot
        func samePath(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b else { return false }
            return URL(fileURLWithPath: a).standardizedFileURL.resolvingSymlinksInPath() == URL(fileURLWithPath: b).standardizedFileURL.resolvingSymlinksInPath()
        }
        for resource in resources {
            let parent = snapshot.nodes.first { $0.kind == .workspace && samePath($0.path, resource.workspace) }?.id ?? "queue"
            if resource.workspace != nil && parent == "queue" { throw MapError.invalidSnapshot("Resource workspace is not registered.") }
            result.nodes.append(MapNode(id: MapNode.identity("resource", taskID, resource.id), parentID: parent,
                kind: .resource, label: resource.label, summary: resource.summary,
                evidence: "Declared durable instance; availability unverified", observedAt: resource.updatedAt,
                destination: resource.document, durable: true))
        }
        func endpoint(_ value: String) -> String? {
            if value.hasPrefix("resource:"), resources.contains(where: { $0.id == String(value.dropFirst(9)) }) {
                return MapNode.identity("resource", taskID, String(value.dropFirst(9)))
            }
            if value.hasPrefix("agent:") { return result.nodes.first { $0.kind == .agent && $0.subtaskID == String(value.dropFirst(6)) }?.id }
            if value.hasPrefix("file:/") { return result.nodes.first { [.file, .document, .folder].contains($0.kind) && samePath($0.path, String(value.dropFirst(5))) }?.id }
            return nil
        }
        for edge in connections {
            guard let from = endpoint(edge.from), let to = endpoint(edge.to) else {
                throw MapError.invalidSnapshot("A declared resource relationship has an unknown endpoint.")
            }
            result.relations.append(MapRelation(from: from, to: to, kind: edge.kind,
                evidence: "Explicit resource manifest", observedAt: nil))
        }
        return try result.validated()
    }
}
