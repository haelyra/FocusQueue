import Foundation
import FocusQueueCore

public struct GitMapChange: Equatable, Sendable {
    public let path: String
    public let status: String
    public let originalPath: String?
}

public enum GitMapParser {
    /// Porcelain v1 -z emits destination, then source for renames and copies.
    public static func changes(_ output: String) throws -> [GitMapChange] {
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        var result: [GitMapChange] = [], i = 0
        while i < fields.count {
            let field = String(fields[i]); i += 1
            if field.isEmpty { continue }
            guard field.count >= 4, field[field.index(field.startIndex, offsetBy: 2)] == " " else {
                throw MapError.unavailable("Git returned an incomplete status record.")
            }
            let status = String(field.prefix(2))
            var original: String?
            if status.contains("R") || status.contains("C") {
                guard i < fields.count, !fields[i].isEmpty else {
                    throw MapError.unavailable("Git returned an incomplete rename record.")
                }
                original = String(fields[i]); i += 1
            }
            result.append(.init(path: String(field.dropFirst(3)), status: status, originalPath: original))
        }
        return result
    }

    public static func worktrees(_ output: String) -> [String: String] {
        var result: [String: String] = [:], path: String?
        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            if field.hasPrefix("worktree ") {
                path = String(field.dropFirst(9)); result[path!] = "Detached HEAD"
            } else if field.hasPrefix("branch "), let path {
                result[path] = String(field.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "")
            }
        }
        return result
    }
}

/// A read-only collector shared by the app and command-line helper. Git processes
/// run on this actor, away from the main actor. Caches are scoped to workspaces.
public actor WorkspaceCollector {
    private struct Observation {
        let root: String
        let identity: String
        let branch: String
        let paths: [String]
        let changes: [GitMapChange]
        let observedAt: Date
    }
    private let runner: any ProcessRunning
    private var previous: [String: Observation] = [:]
    private var trackedCache: [String: (Date, [String])] = [:]
    private let outputLimit = 2_000_000

    public init(runner: any ProcessRunning = FoundationProcessRunner()) { self.runner = runner }

    public func collect(context: TaskContext, sessions: [TaskAgentSession], now: Date = Date()) async throws -> MapSnapshot {
        try Task.checkCancellation()
        let relevant = sessions.filter { $0.ticketID.caseInsensitiveCompare(context.ticketID) == .orderedSame }
        let primary = context.worktreePath ?? context.repositoryPath
        let directories = Set(([primary].compactMap { $0 } + relevant.map(\.workingDirectory))
            .filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }).sorted()
        var nodes = [MapNode(id: "queue", parentID: nil, kind: .queue, label: "Focus Queue",
                             summary: "\(context.ticketID) · \(context.title)",
                             evidence: "Recorded task context", observedAt: context.updatedAt)]
        var warnings: [String] = [], omitted = 0
        var roots: [String: String] = [:]
        var collectedRoots = Set<String>()

        for directory in directories {
            try Task.checkCancellation()
            let observation: Observation?
            do {
                // Reuse within a refresh for registrations in nested directories.
                if let known = previous.values.first(where: {
                    Self.contains(directory, in: $0.root) && $0.observedAt == now
                }) { observation = known }
                else {
                    let fresh = try await observe(directory: directory, now: now)
                    previous[directory] = fresh; observation = fresh
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                observation = previous[directory]
                warnings.append("\(URL(fileURLWithPath: directory).lastPathComponent): \(error.localizedDescription)\(observation == nil ? "" : " Showing the last successful observation.")")
            }
            guard let observation else {
                let id = MapNode.identity("unavailable", directory)
                roots[directory] = id
                nodes.append(MapNode(id: id, parentID: "queue", kind: .workspace,
                    label: URL(fileURLWithPath: directory).lastPathComponent, path: directory, allowedRoot: directory,
                    summary: "Workspace unavailable. Check its saved location.", evidence: "Registered location; Git unavailable"))
                continue
            }
            roots[directory] = observation.identity
            guard collectedRoots.insert(observation.identity).inserted else { continue }
            let root = observation.root, id = observation.identity
            nodes.append(MapNode(id: id, parentID: "queue", kind: .workspace,
                label: URL(fileURLWithPath: root).lastPathComponent, path: root, allowedRoot: root,
                summary: "\(observation.branch) · \(observation.changes.count) changed paths",
                evidence: "Git worktree boundary and status", observedAt: observation.observedAt))
            let changes = Dictionary(observation.changes.map { ($0.path, $0) }, uniquingKeysWith: { _, last in last })
            // Changed paths take precedence over quiet tracked files. No file content
            // is read, and no file ownership is inferred from workspace association.
            let allPaths = Array(Set(observation.paths + observation.changes.map(\.path))).sorted {
                (changes[$0] == nil ? 1 : 0, $0) < (changes[$1] == nil ? 1 : 0, $1)
            }
            let bounded = allPaths.prefix(400)
            omitted += max(0, allPaths.count - bounded.count)
            var added = Set<String>()
            for path in bounded {
                let parts = path.split(separator: "/").map(String.init)
                guard !parts.isEmpty, !path.hasPrefix("/"), !parts.contains(".."), !parts.contains(".") else { continue }
                var parent = id
                for depth in parts.indices {
                    let relative = parts.prefix(depth + 1).joined(separator: "/")
                    let nodeID = MapNode.identity(id, relative)
                    if added.insert(nodeID).inserted {
                        let isFile = depth == parts.count - 1
                        let change = isFile ? changes[path] : nil
                        let detail = change.map { change in
                            "\(change.status.trimmingCharacters(in: .whitespaces)) · owner unknown" +
                                (change.originalPath.map { " · from \($0)" } ?? "")
                        } ?? (isFile ? "Tracked file · owner unknown" : "Expand to see files")
                        nodes.append(MapNode(id: nodeID, parentID: parent, kind: isFile ? .file : .folder,
                            label: parts[depth], path: URL(fileURLWithPath: root).appendingPathComponent(relative).path,
                            allowedRoot: root, summary: detail, evidence: "Git path; individual author unknown",
                            observedAt: observation.observedAt, gitStatus: change?.status))
                    }
                    parent = nodeID
                }
            }
        }
        if directories.isEmpty { warnings.append("No workspace is registered for this task. Attach an agent or choose a repository from the task.") }

        func parent(for directory: String?) -> String {
            guard let directory else { return "queue" }
            let standardized = URL(fileURLWithPath: directory).standardizedFileURL.path
            return roots[standardized] ?? roots.keys.sorted(by: { $0.count > $1.count })
                .first(where: { Self.contains(standardized, in: $0) }).flatMap { roots[$0] } ?? "queue"
        }
        var addedAgents = Set<String>()
        for subtask in context.subtasks {
            // A saved subtask may precede session registration. Preserve its identity
            // until the actual provider session becomes available.
            let session = relevant.first {
                guard $0.provider == subtask.provider else { return false }
                if let expected = subtask.sessionID {
                    return $0.sessionID.caseInsensitiveCompare(expected) == .orderedSame
                }
                return $0.subtaskID == subtask.id
            }
            let sessionID = session?.sessionID ?? subtask.sessionID
            let id = MapNode.identity("agent", subtask.provider.rawValue, sessionID?.lowercased() ?? "subtask:\(subtask.id)")
            guard addedAgents.insert(id).inserted else { continue }
            nodes.append(MapNode(id: id, parentID: parent(for: session?.workingDirectory ?? primary), kind: .agent,
                label: "\(subtask.provider.displayName) · \(subtask.title)", path: session?.workingDirectory ?? primary,
                summary: subtask.progressSummary.isEmpty ? "No progress summary reported." : subtask.progressSummary,
                evidence: "Recorded assignment and explicit progress report", observedAt: subtask.lastHeartbeatAt,
                reportedState: subtask.status.rawValue, provider: subtask.provider.rawValue,
                sessionID: sessionID, subtaskID: subtask.id))
        }
        for session in relevant {
            let id = MapNode.identity("agent", session.provider.rawValue, session.sessionID.lowercased())
            guard addedAgents.insert(id).inserted else { continue }
            nodes.append(MapNode(id: id, parentID: parent(for: session.workingDirectory), kind: .agent,
                label: "\(session.provider.displayName) · \(session.sessionID.suffix(6))", path: session.workingDirectory,
                summary: "Registered session. Current activity is unknown.", evidence: "Session registration only",
                reportedState: "unknown", provider: session.provider.rawValue, sessionID: session.sessionID))
        }
        // Canonical plans can live outside Git. Keep them out of worktree containment.
        if context.planPath.hasPrefix("/") {
            nodes.append(MapNode(id: MapNode.identity("document", context.planPath), parentID: "queue", kind: .document,
                label: "Central plan", path: context.planPath, allowedRoot: context.planPath,
                summary: "Task context retained outside the worktree", evidence: "Registered central plan",
                observedAt: context.updatedAt))
        }
        return try MapSnapshot(taskID: context.ticketID, generatedAt: now, nodes: nodes,
                               warnings: warnings, omittedPaths: omitted).validated()
    }

    private func observe(directory: String, now: Date) async throws -> Observation {
        let root = try await git(["rev-parse", "--show-toplevel"], at: directory)
            .trimmingCharacters(in: .newlines)
        let gitDirectory = try await git(["rev-parse", "--absolute-git-dir"], at: root)
            .trimmingCharacters(in: .newlines)
        let worktrees = GitMapParser.worktrees(try await git(["worktree", "list", "--porcelain", "-z"], at: root))
        let changes = try GitMapParser.changes(await git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], at: root))
        let paths: [String]
        if let cached = trackedCache[root], now.timeIntervalSince(cached.0) < 30 { paths = cached.1 }
        else {
            paths = try await git(["ls-files", "-z", "--cached"], at: root).split(separator: "\0").map(String.init)
            trackedCache[root] = (now, paths)
        }
        return Observation(root: root, identity: MapNode.identity("workspace", gitDirectory),
                           branch: worktrees[root] ?? "Workspace", paths: paths, changes: changes, observedAt: now)
    }

    private func git(_ arguments: [String], at directory: String) async throws -> String {
        let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: arguments,
            workingDirectory: directory, environment: ["GIT_OPTIONAL_LOCKS": "0"],
            timeoutSeconds: 5, maximumOutputBytes: outputLimit))
        try Task.checkCancellation()
        guard result.succeeded else {
            throw MapError.unavailable(result.timedOut ? "Git collection timed out." : "Git could not read this workspace.")
        }
        guard result.standardOutput.utf8.count < outputLimit - 4 else {
            throw MapError.unavailable("Git output exceeded the map collection limit.")
        }
        return result.standardOutput
    }

    public static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
