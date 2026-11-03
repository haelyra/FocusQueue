import CryptoKit
import Foundation

/// Decides when a user prompt goes to background data extraction.
///
/// A prompt can reach Focus Queue through two hooks: the optional global
/// registration hook and the status hook every app launch carries. Both call
/// `claim`, so each prompt is extracted once.
public enum PromptExtraction {
    public static let promptLimit = 4_000
    static let claimLifetime: TimeInterval = 86_400

    /// Claims one provider session's prompt. Returns false when another hook already claimed it.
    public static func claim(provider: String, sessionID: String?, prompt: String,
                             root: URL, now: Date = Date()) -> Bool {
        let directory = root.appendingPathComponent("extraction-claims", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let key = Data("\(provider)\n\((sessionID ?? "").lowercased())\n\(prompt)".utf8)
        let name = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        let descriptor = open(directory.appendingPathComponent(name).path,
                              O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        prune(directory, keeping: name, now: now)
        return true
    }

    /// The agent's project: its placement capsule first, then the one active dashboard that owns its open task.
    public static func projectID(environment: [String: String], taskID: String?,
                                 configuration: AppConfiguration, root: URL) -> String? {
        let projects = ProjectCatalog.ensuringOther(in: configuration.projects, supportDirectory: root)
            .filter { $0.archivedAt == nil }
        if let path = environment["FOCUS_QUEUE_AGENT_CONTEXT"], !path.isEmpty,
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let capsule = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let id = capsule["projectID"] as? String, projects.contains(where: { $0.id == id }) {
            return id
        }
        guard let taskID, !taskID.isEmpty else { return nil }
        let owners = projects.filter { project in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: project.dashboardPath)),
                  let document = try? JSONDecoder().decode(DashboardDocument.self, from: data) else { return false }
            return document.tickets.contains { $0.id.caseInsensitiveCompare(taskID) == .orderedSame && $0.isOpen }
        }
        return owners.count == 1 ? owners[0].id : nil
    }

    private static func prune(_ directory: URL, keeping current: String, now: Date) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        for entry in entries where entry.lastPathComponent != current {
            if let modified = try? entry.resourceValues(forKeys: keys).contentModificationDate,
               now.timeIntervalSince(modified) > claimLifetime {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }
}
