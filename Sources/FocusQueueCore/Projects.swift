import Foundation

public typealias ProjectDefinition = ProjectConfiguration

public extension ProjectConfiguration {
    init(id: String = UUID().uuidString.lowercased(), name: String, taskPrefix: String? = nil,
         repositoryPath: String, remote: String? = nil,
         remoteAliases: [String] = [], archivedAt: Date? = nil) {
        let workspace = repositoryPath.isEmpty
            ? FileManager.default.temporaryDirectory.appendingPathComponent("focus-queue-project-\(id)").path
            : repositoryPath
        self.init(id: id, name: name,
            dashboardPath: URL(fileURLWithPath: workspace).appendingPathComponent("dashboard.json").path,
            workspacePath: workspace, taskPrefix: taskPrefix, repositoryPath: repositoryPath,
            remote: remote, remoteAliases: remoteAliases, archivedAt: archivedAt)
    }

    var repositoryRemotes: Set<String> {
        Set(([remote].compactMap { $0 } + remoteAliases).compactMap(ProjectCatalog.normalizedRemote))
    }
}

public enum ProjectCatalog {
    public static let unassignedID = "__unassigned__"
    public static let otherID = "other"

    public static var other: ProjectDefinition {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ECC Focus Queue/projects/other", isDirectory: true)
        return ProjectDefinition(id: otherID, name: "Other",
            dashboardPath: root.appendingPathComponent("dashboard.json").path,
            workspacePath: root.appendingPathComponent("workspace", isDirectory: true).path,
            taskPrefix: "OTH", repositoryPath: "")
    }

    public static func suggestedPrefix(name: String, id: String = "") -> String {
        let words = name.uppercased().split { !$0.isLetter && !$0.isNumber }
        if name.localizedCaseInsensitiveContains("focus queue") { return "FOC" }
        if words.count == 1, let word = words.first, word.count >= 2 { return String(word.prefix(3)) }
        let initials = words.compactMap(\.first)
        if initials.count >= 2 { return String(initials.prefix(5)) }
        if let first = words.first, first.count >= 3 { return String(first.prefix(3)) }
        var fallback = id.uppercased().filter { $0.isLetter || $0.isNumber }
        if fallback.first?.isLetter != true { fallback = "P" + fallback }
        if fallback.isEmpty { fallback = "PRJ" }
        return String(fallback.prefix(5)).padding(toLength: 2, withPad: "X", startingAt: 0)
    }

    public static func ensuringOther(
        in projects: [ProjectDefinition], supportDirectory: URL? = nil
    ) -> [ProjectDefinition] {
        guard !projects.contains(where: { $0.id == otherID }) else { return projects }
        guard let supportDirectory else { return projects + [other] }
        let root = supportDirectory.appendingPathComponent("projects/other", isDirectory: true)
        return projects + [ProjectDefinition(id: otherID, name: "Other",
            dashboardPath: root.appendingPathComponent("dashboard.json").path,
            workspacePath: root.appendingPathComponent("workspace", isDirectory: true).path,
            taskPrefix: "OTH", repositoryPath: "")]
    }

    public static func prepareFallbackStorage(for project: ProjectDefinition) throws {
        guard project.id == otherID else { return }
        let workspace = URL(fileURLWithPath: project.workspacePath, isDirectory: true)
        let dashboard = URL(fileURLWithPath: project.dashboardPath)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: dashboard.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: dashboard.path) {
            try Data("{\"tickets\":[]}\n".utf8).write(to: dashboard, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                ofItemAtPath: dashboard.path)
        }
    }

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
        var ids = Set<String>(), prefixes = Set<String>(), remotes = Set<String>()
        for project in projects {
            guard !project.id.isEmpty, project.id != unassignedID,
                  project.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  ids.insert(project.id).inserted,
                  !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  project.taskPrefix.range(of: "^[A-Z][A-Z0-9]{1,4}$", options: .regularExpression) != nil,
                  prefixes.insert(project.taskPrefix).inserted,
                  project.repositoryPath.isEmpty || project.repositoryPath.hasPrefix("/") else {
                throw TaskContextError.commandFailed("Projects need unique IDs and task prefixes, a name, and an optional absolute repository folder.")
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
            ?? projects.first { $0.id == otherID && $0.archivedAt == nil }
    }

    public static func project(forTaskID taskID: String, in projects: [ProjectDefinition]) -> ProjectDefinition? {
        let prefix = taskID.uppercased().split(separator: "-", maxSplits: 1).first.map(String.init)
        return projects.first { $0.archivedAt == nil && $0.taskPrefix == prefix }
    }

    public static func normalizedSelection(_ id: String?, projects: [ProjectDefinition]) -> String? {
        guard let id else { return nil }
        return id == unassignedID || projects.contains(where: { $0.id == id && $0.archivedAt == nil }) ? id : nil
    }

    public static func includes(_ ticket: DashboardTicket, selection: String?, projects: [ProjectDefinition]) -> Bool {
        guard let selection else { return true }
        if selection == unassignedID { return project(for: ticket, in: projects) == nil }
        return project(for: ticket, in: projects)?.id == selection
    }

    /// Queue-order scope shared by the app and its agent helper while the
    /// all-projects view is active.
    public static let allProjectsScopeID = "all-projects"

    /// Distinct dashboard files for every unarchived project, Other included.
    public static func mergedDashboardURLs(in projects: [ProjectDefinition]) -> [URL] {
        var seen = Set<String>()
        return projects.filter { $0.archivedAt == nil }
            .map { $0.dashboardPath.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }
}

/// Worktrees share their Git common directory. Explicit remote aliases also allow another clone.
public struct ProjectRepositoryResolver: Sendable {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = FoundationProcessRunner()) { self.runner = runner }
    public func matches(path: String, project: ProjectDefinition) async throws -> Bool {
        guard !project.repositoryPath.isEmpty else { return false }
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
        try FocusQueueFileLock.withLocks(for: [file], operation)
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

    public func create(title: String, summary: String, project: ProjectDefinition) throws -> String {
        var taskID = ""
        try update { tickets in
            let prefix = project.taskPrefix + "-"
            let last = tickets.compactMap { ($0["id"] as? String).flatMap {
                $0.uppercased().hasPrefix(prefix) ? Int($0.dropFirst(prefix.count)) : nil
            } }.max() ?? 0
            taskID = String(format: "%@-%03d", project.taskPrefix, last + 1)
            tickets.append(["id": taskID, "title": title, "summary": summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title : summary,
                "status": "backlog", "priority": "medium", "updatedAt": ISO8601DateFormatter().string(from: Date()),
                "links": [], "prs": [], "steps": [], "projectID": project.id])
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

public struct ProjectContextStore: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }

    public func planURL(projectID: String) throws -> URL {
        guard !projectID.isEmpty,
              projectID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw TaskContextError.invalidIdentifier
        }
        return root.appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent("plan.md")
    }

    @discardableResult public func ensurePlan(for project: ProjectDefinition) throws -> URL {
        let url = try planURL(projectID: project.id)
        let directory = url.deletingLastPathComponent()
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
              (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw TaskContextError.commandFailed("Project guidance storage is redirected.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            let repository = project.repositoryPath.isEmpty ? "not configured" : project.repositoryPath
            // A project plan is a one-to-three-line description inlined into every agent brief.
            // Durable practices and architecture live in separate on-demand documents.
            let markdown = """
            # \(project.name)

            Tasks use `\(project.taskPrefix)-###` IDs. Repository: \(repository).
            """
            try Data((markdown + "\n").utf8).write(to: url, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        return url
    }

    /// Known project documents in reading order. Only files that exist are listed, so a
    /// project that never received practices or a PRD shows just its plan.
    public func documents(projectID: String) throws -> [ProjectDocument] {
        let directory = try planURL(projectID: projectID).deletingLastPathComponent()
        return ProjectDocument.Kind.allCases.compactMap { kind in
            let url = directory.appendingPathComponent(kind.fileName)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return ProjectDocument(kind: kind, url: url)
        }
    }

    /// External links recorded in the project's context.json (repository, deployments, databases).
    public func links(projectID: String) throws -> [DashboardLink] {
        let url = try planURL(projectID: projectID).deletingLastPathComponent()
            .appendingPathComponent(ProjectDocument.Kind.context.fileName)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return ["links", "deployments", "databases"].flatMap { key in
            (object[key] as? [[String: Any]] ?? []).compactMap { entry -> DashboardLink? in
                guard let target = entry["url"] as? String, !target.isEmpty else { return nil }
                let label = (entry["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? target
                return DashboardLink(label: label, url: target, type: entry["kind"] as? String)
            }
        }
    }
}

public struct ProjectDocument: Identifiable, Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case plan, practices, prd, architecture, evidence, data, context

        public var fileName: String { self == .context ? "context.json" : "\(rawValue).md" }

        public var title: String {
            switch self {
            case .plan: "Project plan"
            case .practices: "Practices"
            case .prd: "Product requirements"
            case .architecture: "Architecture"
            case .evidence: "Evidence index"
            case .data: "Project data"
            case .context: "Project context"
            }
        }

        public var systemImage: String {
            switch self {
            case .plan: "doc.text"
            case .practices: "checklist"
            case .prd: "list.bullet.rectangle"
            case .architecture: "square.stack.3d.up"
            case .evidence: "checkmark.seal"
            case .data: "tablecells"
            case .context: "curlybraces"
            }
        }
    }

    public var id: String { kind.rawValue }
    public let kind: Kind
    public let url: URL
}
