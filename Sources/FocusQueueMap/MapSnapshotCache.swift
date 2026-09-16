import Foundation
import FocusQueueCore

public actor MapSnapshotCache {
    public init() {}

    public func load(from url: URL, taskID: String) throws -> MapSnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try MapSnapshot.decode(Data(contentsOf: url))
        guard snapshot.taskID == taskID else { throw MapError.invalidSnapshot("The saved map belongs to another task.") }
        return snapshot
    }

    public func save(_ snapshot: MapSnapshot, to url: URL) throws {
        // Partial scans must never replace the durable last successful snapshot.
        guard snapshot.warnings.isEmpty else { return }
        try SystemFileAccessor().write(snapshot.encoded(), to: url)
    }
}
