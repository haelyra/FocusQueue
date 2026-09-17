import Foundation
import Darwin

public struct TaskWorktreeCleanupResult: Equatable, Sendable {
    public let removed: Bool
    public let message: String
    public init(removed: Bool, message: String) { self.removed = removed; self.message = message }
}

/// Git operations are injectable and use argument arrays, never shell interpolation.
public actor TaskWorktreeManager {
    private let runner: any ProcessRunning
    public init(runner: any ProcessRunning = FoundationProcessRunner()) { self.runner = runner }

    public func workspace(at path: String) async throws -> AgentWorkspace {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TaskContextError.unsafeWorktree("The saved workspace is missing: \(path)")
        }
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard !canonicalPath.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
            throw TaskContextError.unsafeWorktree("Choose a source checkout. An application bundle cannot be an agent workspace.")
        }
        let root = try await git(["rev-parse", "--show-toplevel"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        let branchResult = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: path))
        guard branchResult.succeeded || (!branchResult.timedOut && branchResult.exitCode == 1) else {
            throw TaskContextError.commandFailed(branchResult.standardError.isEmpty
                ? "Could not read the workspace branch." : branchResult.standardError)
        }
        let branch = branchResult.succeeded
            ? branchResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let commit = try await git(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirectory = try await git(["rev-parse", "--absolute-git-dir"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentWorkspace(path: path, repositoryPath: root, branch: branch,
            baseBranch: branch, baseCommit: commit, managed: false,
            gitDirectory: URL(fileURLWithPath: gitDirectory).standardizedFileURL.resolvingSymlinksInPath().path,
            repositoryIdentity: try await repositoryIdentity(in: path))
    }

    public func provisionAgent(ticketID: String, subtaskID: String, path: String,
                               createWorktree: Bool, store: TaskContextStore) async throws -> AgentWorkspace {
        let source = try await workspace(at: path)
        let destination = store.root.appendingPathComponent("worktrees/agents/\(subtaskID)")
        let branch = "focus-queue/\(ticketID.lowercased())-\(subtaskID.lowercased())"
        // A failed provider launch may already own a provisioned workspace.
        // Retry that exact assignment instead of creating another branch.
        if let saved = try await store.load(ticketID: ticketID)?.subtasks.first(where: { $0.id == subtaskID })?.workspace {
            let sameSelection = createWorktree
                ? saved.managed && saved.path == destination.path && saved.branch == branch
                : saved.path == path
            guard sameSelection,
                  saved.repositoryIdentity == source.repositoryIdentity else {
                throw TaskContextError.unsafeWorktree("This agent already has a different assigned workspace. Reopen it from the task, or start a new agent to choose another workspace.")
            }
            try await restoreIfNeeded(saved, subtaskID: subtaskID, store: store)
            try await validate(saved)
            return saved
        }
        guard createWorktree else { return source }
        guard UUID(uuidString: subtaskID) != nil else { throw TaskContextError.invalidIdentifier }
        let status = try await git(["status", "--porcelain", "--untracked-files=all"], in: path)
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskContextError.unsafeWorktree("The selected checkout has uncommitted changes. Commit them first, or turn off Create worktree to use this checkout with those changes.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await git(["worktree", "add", "-b", branch, destination.path, source.baseCommit!], in: path)
        var workspace = try await self.workspace(at: destination.path)
        workspace.repositoryPath = source.repositoryPath
        workspace.baseBranch = source.branch
        workspace.baseCommit = source.baseCommit
        workspace.managed = true
        return workspace
    }

    /// Never change branches underneath another agent to make a resume succeed.
    public func validate(_ saved: AgentWorkspace) async throws {
        let actual = try await workspace(at: saved.path)
        let expectedRepository = try await repositoryIdentity(in: saved.repositoryPath)
        guard actual.repositoryIdentity == expectedRepository,
              saved.repositoryIdentity == nil || actual.repositoryIdentity == saved.repositoryIdentity,
              saved.gitDirectory == nil || actual.gitDirectory == saved.gitDirectory else {
            throw TaskContextError.unsafeWorktree("Workspace identity changed. Restore the assigned checkout or record an approved workspace change before reopening.")
        }
        if saved.managed {
            let commonDirectory = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: saved.path)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let common = URL(fileURLWithPath: commonDirectory).standardizedFileURL.resolvingSymlinksInPath().path
            let root = URL(fileURLWithPath: actual.repositoryPath).standardizedFileURL.resolvingSymlinksInPath()
            guard actual.gitDirectory?.hasPrefix(common + "/worktrees/") == true,
                  URL(fileURLWithPath: saved.path).standardizedFileURL.resolvingSymlinksInPath() == root else {
                throw TaskContextError.unsafeWorktree("The managed workspace no longer points to its assigned worktree.")
            }
        }
        guard saved.branch == nil || actual.branch == saved.branch else {
            throw TaskContextError.unsafeWorktree("Workspace branch changed from \(saved.branch ?? "unknown") to \(actual.branch ?? "detached"). Restore the assigned branch or record an approved workspace change before reopening.")
        }
        if saved.branch == nil, saved.repositoryIdentity != nil,
           actual.branch != nil || actual.baseCommit != saved.baseCommit {
            throw TaskContextError.unsafeWorktree("The assigned detached checkout changed. Restore its saved commit or record an approved workspace change before reopening.")
        }
    }

    /// Completed worktrees may have been safely cleaned up. Recreate only the owned
    /// location from its retained branch; never switch an existing checkout's branch.
    public func restoreIfNeeded(_ saved: AgentWorkspace, subtaskID: String, store: TaskContextStore) async throws {
        guard !FileManager.default.fileExists(atPath: saved.path) else { return }
        let expected = store.root.appendingPathComponent("worktrees/agents/\(subtaskID)").standardizedFileURL
        guard saved.managed, let branch = saved.branch,
              URL(fileURLWithPath: saved.path).standardizedFileURL == expected,
              expected.resolvingSymlinksInPath() == expected else {
            throw TaskContextError.unsafeWorktree("The saved workspace is missing: \(saved.path)")
        }
        _ = try await git(["show-ref", "--verify", "refs/heads/\(branch)"], in: saved.repositoryPath)
        _ = try await git(["worktree", "add", saved.path, branch], in: saved.repositoryPath)
    }

    public func cleanupAgent(ticketID: String, subtask: TaskSubtask, store: TaskContextStore) async throws -> TaskWorktreeCleanupResult {
        let workspaces = (subtask.workspaceHistory + [subtask.workspace].compactMap { $0 }).filter(\.managed)
        var result = TaskWorktreeCleanupResult(removed: false, message: "Existing workspace retained.")
        var cleanedPaths = Set<String>()
        for workspace in workspaces.reversed() where cleanedPaths.insert(workspace.path).inserted {
            var historical = subtask
            historical.workspace = workspace
            result = try await cleanupManagedAgent(ticketID: ticketID, subtask: historical, store: store)
            if !result.removed { return result }
        }
        return result
    }

    private func cleanupManagedAgent(ticketID: String, subtask: TaskSubtask, store: TaskContextStore) async throws -> TaskWorktreeCleanupResult {
        guard let workspace = subtask.workspace, workspace.managed else {
            return .init(removed: false, message: "Existing workspace retained.")
        }
        let expected = store.root.appendingPathComponent("worktrees/agents/\(subtask.id)").standardizedFileURL
        guard URL(fileURLWithPath: workspace.path).standardizedFileURL == expected,
              expected.resolvingSymlinksInPath() == expected else {
            throw TaskContextError.unsafeWorktree("Agent worktree is outside its managed location.")
        }
        guard FileManager.default.fileExists(atPath: workspace.path) else {
            return .init(removed: true, message: "Agent worktree already removed; branch and context retained.")
        }
        let workspaceIdentity = try await managedWorkspaceIdentity(
            path: workspace.path,
            expected: expected,
            repositoryPath: workspace.repositoryPath)
        let contexts = try await store.loadAll()
        if contexts.contains(where: { context in
            context.subtasks.contains { other in
                (context.ticketID != ticketID || other.id != subtask.id)
                    && !other.isAssignmentOnly
                    && other.isAgentVisible && other.workspace?.path == workspace.path
            }
        }) {
            return .init(removed: false, message: "Agent worktree retained: another active agent uses it.")
        }
        try await validate(workspace)
        let changes = try await git(["status", "--porcelain", "--untracked-files=all"], in: workspace.path)
        let ignored = try await git(["ls-files", "--others", "--ignored", "--exclude-standard"], in: workspace.path)
        guard changes.isEmpty && ignored.isEmpty else {
            return .init(removed: false, message: "Agent worktree retained: it contains uncommitted, untracked, or ignored files.")
        }
        guard let base = workspace.baseBranch else { throw TaskContextError.unsafeWorktree("Missing base branch.") }
        let merged = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["merge-base", "--is-ancestor", "HEAD", base], workingDirectory: workspace.path))
        guard merged.succeeded else {
            return .init(removed: false, message: "Agent worktree retained: its commits have not been merged into \(base).")
        }
        try await store.archive(ticketID: ticketID)
        try await requireUnchangedManagedWorkspace(
            path: workspace.path,
            expected: expected,
            repositoryPath: workspace.repositoryPath,
            baseline: workspaceIdentity)
        _ = try await git(["worktree", "remove", workspace.path], in: workspace.repositoryPath)
        return .init(removed: true, message: "Clean, merged agent worktree removed; branch and context retained.")
    }

    public func provision(ticket: DashboardTicket, repositoryPath: String, store: TaskContextStore) async throws -> TaskContext {
        let initial = try await store.ensureContext(ticket: ticket)
        let repository = try await git(["rev-parse", "--show-toplevel"], in: repositoryPath).trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = initial.worktreePath, FileManager.default.fileExists(atPath: existing) {
            let gitDirectory = try await git(["rev-parse", "--absolute-git-dir"], in: existing).trimmingCharacters(in: .whitespacesAndNewlines)
            let commonDirectory = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: existing).trimmingCharacters(in: .whitespacesAndNewlines)
            if gitDirectory != commonDirectory, try await !store.isWorktreeAssigned(existing, excluding: initial.ticketID) {
                // An existing linked worktree is a deliberate task workspace. Main checkouts get isolated below.
                try await installReference(context: initial, store: store)
                return initial
            }
        }
        let base = try await git(["symbolic-ref", "--short", "HEAD"], in: repository).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw TaskContextError.unsafeWorktree("Select a repository on a named branch before creating a task worktree.") }
        let root = store.root
        let destination = root.resolvingSymlinksInPath().appendingPathComponent("worktrees", isDirectory: true).appendingPathComponent(initial.ticketID, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TaskContextError.unsafeWorktree("The task worktree path already exists and is not registered. Inspect it before retrying: \(destination.path)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let branch = "focus-queue/\(initial.ticketID.lowercased())"
        if initial.branch == branch {
            let retained = try await runner.run(.init(executable: "/usr/bin/git", arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], workingDirectory: repository))
            if retained.succeeded { _ = try await git(["worktree", "add", destination.path, branch], in: repository) }
            else { _ = try await git(["worktree", "add", "-b", branch, destination.path, base], in: repository) }
        } else {
            _ = try await git(["worktree", "add", "-b", branch, destination.path, base], in: repository)
        }
        let context = try await store.setWorktree(ticketID: initial.ticketID, path: destination.path, branch: branch,
                                                  baseBranch: base, managed: true, repositoryPath: repository)
        try await installReference(context: context, store: store)
        return context
    }

    public func cleanup(ticketID: String, store: TaskContextStore) async throws -> TaskWorktreeCleanupResult {
        guard let context = try await store.load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
        guard context.managedWorktree, let path = context.worktreePath, let repository = context.repositoryPath,
              let branch = context.branch, let base = context.baseBranch else {
            try await store.archive(ticketID: ticketID)
            return .init(removed: false, message: "Context archived. This task uses an existing workspace; automatic cleanup only removes worktrees created by Focus Queue.")
        }
        let root = store.root
        let expected = root.resolvingSymlinksInPath().appendingPathComponent("worktrees").appendingPathComponent(context.ticketID).standardizedFileURL
        guard URL(fileURLWithPath: path).standardizedFileURL == expected,
              expected.resolvingSymlinksInPath() == expected else {
            throw TaskContextError.unsafeWorktree("Cleanup refused because the registered worktree is outside the managed location or resolves through a symbolic link.")
        }
        guard context.subtasks.filter(\.tracksCompletion).allSatisfy({ $0.status == .completed }) else {
            return .init(removed: false, message: "Some subtasks are still open. Complete or review them before closing the task.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            try await store.archive(ticketID: ticketID)
            _ = try await store.setWorktree(ticketID: ticketID, path: nil, branch: branch, baseBranch: base, managed: false)
            return .init(removed: true, message: "The managed worktree was already removed. Its context and archive remain available.")
        }
        let workspaceIdentity = try await managedWorkspaceIdentity(
            path: path,
            expected: expected,
            repositoryPath: repository)
        let actualRoot = try await git(["rev-parse", "--show-toplevel"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: actualRoot).standardizedFileURL == expected else {
            throw TaskContextError.unsafeWorktree("Cleanup refused because the registered path is not the worktree root.")
        }
        let actualBranch = try await git(["symbolic-ref", "--short", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualBranch == branch else {
            return .init(removed: false, message: "The worktree branch changed. Review it before cleanup.")
        }
        let status = try await git(["status", "--porcelain", "--untracked-files=all"], in: path)
        guard status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(removed: false, message: "The worktree contains uncommitted or untracked changes. Commit or preserve them before cleanup.")
        }
        let ignored = try await git(["ls-files", "--others", "--ignored", "--exclude-standard", "-z"], in: path)
            .split(separator: "\0").map(String.init)
        let referencePrefix = ".focus-queue/\(context.ticketID)/"
        for relativePath in ignored {
            let referenceURL = URL(fileURLWithPath: path).appendingPathComponent(relativePath)
            let owned: Bool
            if relativePath == referencePrefix + "plan.md" {
                owned = (try? FileManager.default.destinationOfSymbolicLink(atPath: referenceURL.path)) == context.planPath
            } else if relativePath == referencePrefix + "context.json",
                      let data = try? Data(contentsOf: referenceURL),
                      let pointer = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                owned = pointer["taskID"] == context.ticketID && pointer["canonicalPlan"] == context.planPath
                    && pointer["canonicalContext"] == context.contextDirectory.appendingPathComponent("context.json").path
            } else { owned = false }
            guard owned else {
                return .init(removed: false, message: "The worktree contains ignored files (\(relativePath)). Preserve or remove them before cleanup.")
            }
        }
        let merged = try await runner.run(.init(executable: "/usr/bin/git", arguments: ["merge-base", "--is-ancestor", "HEAD", base], workingDirectory: path))
        guard merged.succeeded else {
            return .init(removed: false, message: "The task branch has commits absent from \(base). Merge through the normal review process before cleanup.")
        }
        // Archive first. A failed archival write must leave the worktree intact.
        try await store.archive(ticketID: ticketID)
        try await requireUnchangedManagedWorkspace(
            path: path,
            expected: expected,
            repositoryPath: repository,
            baseline: workspaceIdentity)
        _ = try await git(["worktree", "remove", path], in: repository)
        _ = try await store.setWorktree(ticketID: ticketID, path: nil, branch: branch, baseBranch: base, managed: false)
        // Branch deletion is intentionally separate from successful workspace cleanup.
        // Keeping the branch preserves a recoverable Git reference for retrospective review.
        return .init(removed: true, message: "Clean, merged worktree removed. The central plan, archive, and Git branch remain available.")
    }

    private func installReference(context: TaskContext, store: TaskContextStore) async throws {
        guard let path = context.worktreePath else { return }
        let excludePath = try await git(["rev-parse", "--git-path", "info/exclude"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        let excludeURL = excludePath.hasPrefix("/") ? URL(fileURLWithPath: excludePath) : URL(fileURLWithPath: path).appendingPathComponent(excludePath)
        let previous = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        if !previous.split(separator: "\n").contains("/.focus-queue/") {
            try FileManager.default.createDirectory(at: excludeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((previous + "\n# Local Focus Queue task context\n/.focus-queue/\n").utf8).write(to: excludeURL, options: .atomic)
        }
        try await store.installWorktreeReference(ticketID: context.ticketID)
    }

    private func git(_ arguments: [String], in directory: String) async throws -> String {
        let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: arguments, workingDirectory: directory))
        guard result.succeeded else {
            throw TaskContextError.commandFailed(result.standardError.isEmpty ? "Git failed: \(arguments.joined(separator: " "))" : result.standardError)
        }
        return result.standardOutput
    }

    private func repositoryIdentity(in directory: String) async throws -> String {
        let commonDirectory = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let common = URL(fileURLWithPath: commonDirectory).standardizedFileURL.resolvingSymlinksInPath().path
        let identity = try fileIdentity(at: common)
        return "\(common):\(identity.device):\(identity.inode)"
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct ManagedWorkspaceIdentity: Equatable, Sendable {
        let file: FileIdentity
        let gitDirectory: String
        let commonDirectory: String
    }

    private func fileIdentity(at path: String) throws -> FileIdentity {
        var metadata = stat()
        guard Darwin.lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity is unavailable or is not a directory.")
        }
        return FileIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino))
    }

    private func managedWorkspaceIdentity(
        path: String,
        expected: URL,
        repositoryPath: String
    ) async throws -> ManagedWorkspaceIdentity {
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        guard pathURL == expected,
              expected.resolvingSymlinksInPath() == expected else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed or resolves through a symbolic link.")
        }
        let file = try fileIdentity(at: path)
        let root = try await git(
            ["rev-parse", "--show-toplevel"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: root).standardizedFileURL == expected else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed from its registered root.")
        }
        let gitDirectory = try await git(
            ["rev-parse", "--path-format=absolute", "--absolute-git-dir"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDirectory = try await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let repositoryCommonDirectory = try await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            in: repositoryPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedGitDirectory = URL(fileURLWithPath: gitDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedCommonDirectory = URL(fileURLWithPath: commonDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedRepositoryCommon = URL(fileURLWithPath: repositoryCommonDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard normalizedCommonDirectory == normalizedRepositoryCommon,
              normalizedGitDirectory.hasPrefix(normalizedCommonDirectory + "/worktrees/") else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace Git registration does not match its repository.")
        }
        return ManagedWorkspaceIdentity(
            file: file,
            gitDirectory: normalizedGitDirectory,
            commonDirectory: normalizedCommonDirectory)
    }

    private func requireUnchangedManagedWorkspace(
        path: String,
        expected: URL,
        repositoryPath: String,
        baseline: ManagedWorkspaceIdentity
    ) async throws {
        guard (try? fileIdentity(at: path)) == baseline.file else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed during cleanup; no files were removed.")
        }
        let current: ManagedWorkspaceIdentity
        do {
            current = try await managedWorkspaceIdentity(
                path: path,
                expected: expected,
                repositoryPath: repositoryPath)
        } catch {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed during cleanup; no files were removed.")
        }
        guard current == baseline else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed during cleanup; no files were removed.")
        }
    }
}
