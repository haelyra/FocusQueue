import Darwin
import Foundation

public struct ProjectDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var repositoryPath: String
    public var remote: String?
    public var remoteAliases: [String]
    public var archivedAt: Date?

    public init(id: String = UUID().uuidString.lowercased(), name: String, repositoryPath: String,
                remote: String? = nil, remoteAliases: [String] = [], archivedAt: Date? = nil) {
        self.id = id; self.name = name; self.repositoryPath = repositoryPath
        self.remote = remote; self.remoteAliases = remoteAliases; self.archivedAt = archivedAt
    }

    private enum CodingKeys: String, CodingKey { case id, name, repositoryPath, remote, remoteAliases, archivedAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        repositoryPath = try c.decode(String.self, forKey: .repositoryPath)
        remote = try c.decodeIfPresent(String.self, forKey: .remote)
        remoteAliases = try c.decodeIfPresent([String].self, forKey: .remoteAliases) ?? []
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
    }

    public var repositoryRemotes: Set<String> {
        Set(([remote].compactMap { $0 } + remoteAliases).compactMap(ProjectCatalog.normalizedRemote))
    }
}

public enum ProjectCatalog {
    public static let unassignedID = "__unassigned__"

    public static func normalizedRemote(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if !value.contains("://"), let colon = value.firstIndex(of: ":"), value[..<colon].contains("@") {
            value = "ssh://" + value[..<colon] + "/" + value[value.index(after: colon)...]
        }
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), let host = url.host, !host.isEmpty,
              ["https", "http", "ssh", "git"].contains(url.scheme?.lowercased() ?? ""),
              url.query == nil, url.fragment == nil else { return nil }
        var path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.split(separator: "/").count == 2, !path.contains(" ") else { return nil }
        return host.lowercased() + "/" + path.lowercased()
    }

    public static func validate(_ projects: [ProjectDefinition]) throws {
        var ids = Set<String>(), remotes = Set<String>()
        for project in projects {
            guard !project.id.isEmpty, project.id != unassignedID,
                  project.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  ids.insert(project.id).inserted,
                  !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  project.repositoryPath.hasPrefix("/") else {
                throw TaskContextError.commandFailed("Projects need unique IDs, a name and an absolute repository folder.")
            }
            for remote in [project.remote].compactMap({ $0 }) + project.remoteAliases {
                guard let normalized = normalizedRemote(remote) else {
                    throw TaskContextError.commandFailed("Invalid repository URL for \(project.name).")
                }
                guard !remotes.contains(normalized) else {
                    throw TaskContextError.commandFailed("A repository URL belongs to more than one project: \(normalized).")
                }
            }
            remotes.formUnion(project.repositoryRemotes)
        }
    }

    public static func project(for ticket: DashboardTicket, in projects: [ProjectDefinition]) -> ProjectDefinition? {
        projects.first { $0.id == ticket.projectID }
    }

    public static func normalizedSelection(_ id: String?, projects: [ProjectDefinition]) -> String? {
        guard let id else { return nil }
        return id == unassignedID || projects.contains(where: { $0.id == id && $0.archivedAt == nil }) ? id : nil
    }

    public static func includes(_ ticket: DashboardTicket, selection: String?, projects: [ProjectDefinition]) -> Bool {
        guard let selection else { return true }
        if selection == unassignedID { return project(for: ticket, in: projects) == nil }
        return ticket.projectID == selection
    }
}

/// Worktrees share their Git common directory. Explicit remote aliases also allow another clone.
public struct ProjectRepositoryResolver: Sendable {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = FoundationProcessRunner()) { self.runner = runner }
    public func matches(path: String, project: ProjectDefinition) async throws -> Bool {
        func git(_ args: [String], at path: String) async throws -> String? {
            let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: args, workingDirectory: path))
            guard result.succeeded else { return nil }
            return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let args = ["rev-parse", "--path-format=absolute", "--git-common-dir"]
        if let left = try await git(args, at: path), let right = try await git(args, at: project.repositoryPath),
           URL(fileURLWithPath: left).resolvingSymlinksInPath() == URL(fileURLWithPath: right).resolvingSymlinksInPath() { return true }
        guard let remote = try await git(["remote", "get-url", "origin"], at: path),
              let normalized = ProjectCatalog.normalizedRemote(remote) else { return false }
        return project.repositoryRemotes.contains(normalized)
    }
}

/// Shared with the daily-report writer and project migration script.
public enum ProjectFileLock {
    public static func withLock<T>(file: URL, _ operation: () throws -> T) throws -> T {
        let descriptor = Darwin.open(file.path + ".focus-queue.lock", O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }
}

/// Changes only requested fields in the raw document, preserving unknown canonical data.
public struct ProjectTaskStore: Sendable {
    public let dashboardURL: URL
    public let supportDirectory: URL
    public init(dashboardURL: URL, supportDirectory: URL) {
        self.dashboardURL = dashboardURL; self.supportDirectory = supportDirectory
    }

    public func assign(ticketID: String, projectID: String?) throws {
        try update { tickets in
            guard let index = tickets.firstIndex(where: { $0["id"] as? String == ticketID }) else {
                throw TaskContextError.commandFailed("The task no longer exists.")
            }
            if let projectID { tickets[index]["projectID"] = projectID }
            else { tickets[index].removeValue(forKey: "projectID") }
        }
    }

    public func create(title: String, summary: String, projectID: String?) throws -> String {
        var taskID = ""
        try update { tickets in
            let last = tickets.compactMap { ($0["id"] as? String).flatMap { $0.hasPrefix("ECC-") ? Int($0.dropFirst(4)) : nil } }.max() ?? 0
            taskID = String(format: "ECC-%03d", last + 1)
            var task: [String: Any] = ["id": taskID, "title": title, "summary": summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : summary,
                "status": "backlog", "priority": "medium", "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "links": [], "prs": [], "steps": []]
            if let projectID { task["projectID"] = projectID }
            tickets.append(task)
        }
        return taskID
    }

    private func update(_ edit: (inout [[String: Any]]) throws -> Void) throws {
        try ProjectFileLock.withLock(file: dashboardURL) {
            let original = try Data(contentsOf: dashboardURL)
            guard var document = try JSONSerialization.jsonObject(with: original) as? [String: Any],
                  var tickets = document["tickets"] as? [[String: Any]] else { throw CocoaError(.fileReadCorruptFile) }
            let ids = tickets.compactMap { $0["id"] as? String }
            guard ids.count == tickets.count, Set(ids).count == ids.count else {
                throw TaskContextError.commandFailed("Task IDs must be present and unique before editing projects.")
            }
            try edit(&tickets)
            document["tickets"] = tickets
            let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            let backup = supportDirectory.appendingPathComponent("backups/project-edits/\(UUID().uuidString)/dashboard.json")
            try SystemFileAccessor().write(original, to: backup)
            guard try Data(contentsOf: dashboardURL) == original else {
                throw TaskContextError.commandFailed("The dashboard changed during the edit. Refresh and retry.")
            }
            let mode = try FileManager.default.attributesOfItem(atPath: dashboardURL.path)[.posixPermissions]
            try data.write(to: dashboardURL, options: .atomic)
            if let mode { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: dashboardURL.path) }
        }
    }
}
