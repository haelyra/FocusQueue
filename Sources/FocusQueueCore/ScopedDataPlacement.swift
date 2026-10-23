import Foundation

public struct ScopedDataPlacementReceipt: Codable, Equatable, Sendable {
    public let scope: String
    public let targetID: String
    public let path: String
    public let added: Bool
}

public struct ScopedDataEnsureReceipt: Codable, Equatable, Sendable {
    public let created: [String]
    public let existing: [String]
}

/// The only write boundary for durable user, project, and task facts.
public enum ScopedDataPlacement {
    /// Creates empty data files for the user and every active project without changing existing facts.
    public static func ensure(root: URL, configuration: AppConfiguration) throws -> ScopedDataEnsureReceipt {
        let projects = ProjectCatalog.ensuringOther(in: configuration.projects, supportDirectory: root)
        try ProjectCatalog.validate(projects)
        let paths = [root.appendingPathComponent("user/data.md")]
            + projects.filter { $0.archivedAt == nil }.sorted { $0.id < $1.id }.map {
                root.appendingPathComponent("projects/\($0.id)/data.md")
            }
        for path in paths { try validateDestination(path, root: root) }
        return try FocusQueueFileLock.withLocks(for: paths) {
            var created: [String] = []
            var existing: [String] = []
            for path in paths {
                try validateDestination(path, root: root)
                if FileManager.default.fileExists(atPath: path.path) {
                    guard (try path.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else {
                        throw TaskContextError.commandFailed("Data destination is not a regular file.")
                    }
                    existing.append(path.path)
                } else {
                    try Data().write(to: path, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                    created.append(path.path)
                }
            }
            return ScopedDataEnsureReceipt(created: created, existing: existing)
        }
    }

    public static func place(scope: String, targetID: String, text: String,
                             root: URL, configuration: AppConfiguration) async throws -> ScopedDataPlacementReceipt {
        let fact = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fact.isEmpty, fact.count <= 200, !fact.contains("\n"), !fact.contains("\r"),
              sentenceCount(fact) <= 2 else {
            throw TaskContextError.commandFailed("Data must be one or two short sentences on one line (up to 200 characters).")
        }
        let projects = ProjectCatalog.ensuringOther(in: configuration.projects, supportDirectory: root)
        try ProjectCatalog.validate(projects)
        let active = projects.filter { $0.archivedAt == nil }
        let path: URL
        let limit: Int
        switch scope {
        case "user":
            guard targetID == "user" else { throw TaskContextError.commandFailed("User data target must be user.") }
            path = root.appendingPathComponent("user/data.md")
            limit = 2_000
        case "project":
            guard active.contains(where: { $0.id == targetID }) else {
                throw TaskContextError.commandFailed("Unknown or archived project \(targetID).")
            }
            path = root.appendingPathComponent("projects/\(targetID)/data.md")
            limit = 3_000
        case "task":
            guard targetID.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil else {
                throw TaskContextError.invalidIdentifier
            }
            var owners: [String] = []
            for project in active {
                let dashboard = URL(fileURLWithPath: project.dashboardPath)
                guard FileManager.default.fileExists(atPath: dashboard.path) else { continue }
                let document = try JSONDecoder().decode(DashboardDocument.self, from: Data(contentsOf: dashboard))
                if document.tickets.contains(where: {
                    $0.id.caseInsensitiveCompare(targetID) == .orderedSame && $0.isOpen
                }) { owners.append(project.id) }
            }
            guard owners.count == 1 else {
                throw TaskContextError.commandFailed("Task \(targetID) must exist in exactly one active project dashboard.")
            }
            path = root.appendingPathComponent("tasks/\(targetID.uppercased())/data.md")
            limit = 2_000
        default:
            throw TaskContextError.commandFailed("Data scope must be user, project, or task.")
        }

        try validateDestination(path, root: root)
        let line = "- \(fact)"
        let added = try FocusQueueFileLock.withLocks(for: [path]) {
            guard (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw TaskContextError.commandFailed("Data destination is a symbolic link.")
            }
            let old = FileManager.default.fileExists(atPath: path.path)
                ? try String(contentsOf: path, encoding: .utf8) : ""
            if old.components(separatedBy: .newlines).contains(line) { return false }
            let separator = old.isEmpty || old.hasSuffix("\n") ? "" : "\n"
            let updated = old + separator + line + "\n"
            guard updated.utf8.count <= limit else {
                throw TaskContextError.commandFailed("Data file exceeds its \(limit)-byte limit.")
            }
            try Data(updated.utf8).write(to: path, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
            return true
        }
        return ScopedDataPlacementReceipt(scope: scope, targetID: targetID,
                                          path: path.path, added: added)
    }

    private static func validateDestination(_ path: URL, root: URL) throws {
        var candidate = path
        while candidate.path.hasPrefix(root.path) {
            if (try? candidate.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw TaskContextError.commandFailed("Data destination is a symbolic link.")
            }
            if candidate.path == root.path { break }
            candidate.deleteLastPathComponent()
        }
    }

    private static func sentenceCount(_ text: String) -> Int {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let boundary = try! NSRegularExpression(pattern: "(?<=[.!?])\\s+")
        return boundary.numberOfMatches(in: text, range: range) + 1
    }
}
