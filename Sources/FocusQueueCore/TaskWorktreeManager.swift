import Foundation
import Darwin

public enum AgentWorkspacePolicy: Sendable {
    case existingCheckout
    case isolatedCleanCheckout
    /// Fork the selected HEAD without copying, stashing, or changing local edits.
    case isolatedCommittedSnapshot

    public var createsWorktree: Bool { self != .existingCheckout }
}

public struct TaskWorktreeCleanupResult: Equatable, Sendable {
    public let removed: Bool
    public let message: String
    public init(removed: Bool, message: String) { self.removed = removed; self.message = message }
}

/// Git operations are injectable and use argument arrays, never shell interpolation.
public actor TaskWorktreeManager {
    private static let markerName = ".focus-queue-worktrees.json"
    private let runner: any ProcessRunning
    private let beforeCleanupQuarantine: @Sendable (URL) throws -> Void
    public init(runner: any ProcessRunning = FoundationProcessRunner()) {
        self.runner = runner
        self.beforeCleanupQuarantine = { _ in }
    }

    init(
        runner: any ProcessRunning = FoundationProcessRunner(),
        beforeCleanupQuarantine: @escaping @Sendable (URL) throws -> Void
    ) {
        self.runner = runner
        self.beforeCleanupQuarantine = beforeCleanupQuarantine
    }

    private struct ManagedRootMarker: Codable, Equatable {
        let schemaVersion: Int
        let repositoryPath: String
        let repositoryIdentity: String
    }

    public nonisolated static func managedRoot(repositoryPath: String) -> URL {
        let repository = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        return repository.deletingLastPathComponent()
            .appendingPathComponent(repository.lastPathComponent + "-worktrees", isDirectory: true)
    }

    public nonisolated static func agentDestination(
        repositoryPath: String, ticketID: String, subtaskID: String
    ) -> URL {
        managedRoot(repositoryPath: repositoryPath)
            .appendingPathComponent(ticketID.lowercased(), isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(subtaskID.lowercased(), isDirectory: true)
    }

    public nonisolated static func taskDestination(repositoryPath: String, ticketID: String) -> URL {
        managedRoot(repositoryPath: repositoryPath)
            .appendingPathComponent(ticketID.lowercased(), isDirectory: true)
            .appendingPathComponent("task", isDirectory: true)
    }

    public func workspace(at path: String) async throws -> AgentWorkspace {
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TaskContextError.unsafeWorktree("The saved workspace is missing: \(path)")
        }
        let canonicalPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        try rejectApplicationSupport(canonicalPath.path)
        guard !canonicalPath.pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) else {
            throw TaskContextError.unsafeWorktree("Choose a source checkout. An application bundle cannot be an agent workspace.")
        }
        let root = try await git(["rev-parse", "--show-toplevel"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        try rejectApplicationSupport(root)
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

    public func hasUncommittedChanges(at path: String) async throws -> Bool {
        let status = try await git(["status", "--porcelain", "--untracked-files=all"], in: path)
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func provisionAgent(ticketID: String, subtaskID: String, path: String,
                               createWorktree: Bool, store: TaskContextStore) async throws -> AgentWorkspace {
        try await provisionAgent(ticketID: ticketID, subtaskID: subtaskID, path: path,
            policy: createWorktree ? .isolatedCleanCheckout : .existingCheckout, store: store)
    }

    public func provisionAgent(ticketID: String, subtaskID: String, path: String,
                               policy: AgentWorkspacePolicy, store: TaskContextStore) async throws -> AgentWorkspace {
        let createWorktree = policy.createsWorktree
        try rejectApplicationSupport(path, storeRoot: store.root)
        let source = try await workspace(at: path)
        let repository = try await primaryRepository(at: path)
        try rejectApplicationSupport(repository.path, storeRoot: store.root)
        let destination = Self.agentDestination(repositoryPath: repository.path,
            ticketID: ticketID, subtaskID: subtaskID)
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
            try await restoreIfNeeded(saved, ticketID: ticketID, subtaskID: subtaskID, store: store)
            try await validate(saved)
            return saved
        }
        guard createWorktree else { return source }
        guard UUID(uuidString: subtaskID) != nil else { throw TaskContextError.invalidIdentifier }
        if policy == .isolatedCleanCheckout, try await hasUncommittedChanges(at: path) {
            throw TaskContextError.unsafeWorktree("The selected checkout has uncommitted changes. Commit them first or explicitly choose isolation from its committed snapshot.")
        }
        let managedRoot = try await prepareManagedRoot(repositoryPath: repository.path)
        try ensureManagedAncestors(root: managedRoot,
            through: destination.deletingLastPathComponent(), createMissing: true)
        _ = try await git(["worktree", "add", "-b", branch, destination.path, source.baseCommit!], in: path)
        try ensureManagedAncestors(root: managedRoot, through: destination, createMissing: false)
        var workspace = try await self.workspace(at: destination.path)
        workspace.repositoryPath = repository.path
        workspace.baseBranch = source.branch
        workspace.baseCommit = source.baseCommit
        workspace.managed = true
        return workspace
    }

    /// Never change branches underneath another agent to make a resume succeed.
    public func validate(_ saved: AgentWorkspace) async throws {
        try rejectApplicationSupport(saved.path)
        try rejectApplicationSupport(saved.repositoryPath)
        if saved.managed {
            let managedRoot = try await prepareManagedRoot(
                repositoryPath: saved.repositoryPath, createIfMissing: false)
            try ensureManagedAncestors(root: managedRoot,
                through: URL(fileURLWithPath: saved.path), createMissing: false)
        }
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
    public func restoreIfNeeded(_ saved: AgentWorkspace, ticketID: String,
                                subtaskID: String, store: TaskContextStore) async throws {
        try rejectApplicationSupport(saved.path, storeRoot: store.root)
        try rejectApplicationSupport(saved.repositoryPath, storeRoot: store.root)
        if FileManager.default.fileExists(atPath: saved.path) {
            try await validate(saved)
            return
        }
        let expected = Self.agentDestination(repositoryPath: saved.repositoryPath,
            ticketID: ticketID,
            subtaskID: subtaskID).standardizedFileURL
        guard saved.managed, let branch = saved.branch else {
            throw TaskContextError.unsafeWorktree("The saved workspace is missing: \(saved.path)")
        }
        let savedURL = URL(fileURLWithPath: saved.path).standardizedFileURL
        guard savedURL.path == expected.path else {
            throw TaskContextError.unsafeWorktree(
                "The saved workspace is outside its managed location: \(saved.path); expected \(expected.path)")
        }
        let managedRoot = try await prepareManagedRoot(repositoryPath: saved.repositoryPath)
        try ensureManagedAncestors(root: managedRoot,
            through: expected.deletingLastPathComponent(), createMissing: true)
        _ = try await git(["show-ref", "--verify", "refs/heads/\(branch)"], in: saved.repositoryPath)
        _ = try await git(["worktree", "add", saved.path, branch], in: saved.repositoryPath)
        try ensureManagedAncestors(root: managedRoot, through: expected, createMissing: false)
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
        let expected = Self.agentDestination(repositoryPath: workspace.repositoryPath,
            ticketID: ticketID, subtaskID: subtask.id).standardizedFileURL
        try rejectApplicationSupport(workspace.path, storeRoot: store.root)
        try rejectApplicationSupport(workspace.repositoryPath, storeRoot: store.root)
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: workspace.repositoryPath, createIfMissing: false)
        try ensureManagedAncestors(root: managedRoot, through: expected, createMissing: false)
        guard URL(fileURLWithPath: workspace.path).standardizedFileURL.path == expected.path else {
            throw TaskContextError.unsafeWorktree("Agent worktree is outside its managed location.")
        }
        guard FileManager.default.fileExists(atPath: workspace.path) else {
            let registration = try await git(["worktree", "list", "--porcelain"],
                in: workspace.repositoryPath)
            let branch = workspace.branch.map { "branch refs/heads/\($0)" }
            let adminRemains = try workspace.gitDirectory.map {
                try nodeMetadata(at: $0) != nil
            } ?? false
            if registration.contains("worktree \(workspace.path)")
                || branch.map(registration.contains) == true
                || adminRemains {
                return .init(removed: false,
                    message: "Agent worktree cleanup is incomplete: its exact Git registration remains. Context was retained for recovery.")
            }
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
        try beforeCleanupQuarantine(expected)
        let retained = try await removeVerifiedManagedWorkspace(
            expected: expected, identity: workspaceIdentity, referenceContext: nil)
        return .init(removed: true,
            message: "Git registration removed. Recoverable agent files retained at \(retained.files.path), with recovery metadata at \(retained.gitAdmin.path); branch and context retained.")
    }

    public func provision(ticket: DashboardTicket, repositoryPath: String, store: TaskContextStore) async throws -> TaskContext {
        try rejectApplicationSupport(repositoryPath, storeRoot: store.root)
        let initial = try await store.ensureContext(ticket: ticket)
        let sourceRepository = try await git(["rev-parse", "--show-toplevel"], in: repositoryPath).trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = (try await primaryRepository(at: repositoryPath)).path
        try rejectApplicationSupport(sourceRepository, storeRoot: store.root)
        try rejectApplicationSupport(repository, storeRoot: store.root)
        if let existing = initial.worktreePath, FileManager.default.fileExists(atPath: existing) {
            let gitDirectory = try await git(["rev-parse", "--absolute-git-dir"], in: existing).trimmingCharacters(in: .whitespacesAndNewlines)
            let commonDirectory = try await git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: existing).trimmingCharacters(in: .whitespacesAndNewlines)
            if gitDirectory != commonDirectory, try await !store.isWorktreeAssigned(existing, excluding: initial.ticketID) {
                // An existing linked worktree is a deliberate task workspace. Main checkouts get isolated below.
                try await installReference(context: initial, store: store)
                return initial
            }
        }
        let base = try await git(["symbolic-ref", "--short", "HEAD"], in: sourceRepository).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw TaskContextError.unsafeWorktree("Select a repository on a named branch before creating a task worktree.") }
        let destination = Self.taskDestination(repositoryPath: repository, ticketID: initial.ticketID)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TaskContextError.unsafeWorktree("The task worktree path already exists and is not registered. Inspect it before retrying: \(destination.path)")
        }
        let managedRoot = try await prepareManagedRoot(repositoryPath: repository)
        try ensureManagedAncestors(root: managedRoot,
            through: destination.deletingLastPathComponent(), createMissing: true)
        let branch = "focus-queue/\(initial.ticketID.lowercased())"
        if initial.branch == branch {
            let retained = try await runner.run(.init(executable: "/usr/bin/git", arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], workingDirectory: repository))
            if retained.succeeded { _ = try await git(["worktree", "add", destination.path, branch], in: sourceRepository) }
            else { _ = try await git(["worktree", "add", "-b", branch, destination.path, base], in: sourceRepository) }
        } else {
            _ = try await git(["worktree", "add", "-b", branch, destination.path, base], in: sourceRepository)
        }
        try ensureManagedAncestors(root: managedRoot, through: destination, createMissing: false)
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
        let expected = Self.taskDestination(repositoryPath: repository,
            ticketID: context.ticketID).standardizedFileURL
        try rejectApplicationSupport(path, storeRoot: store.root)
        try rejectApplicationSupport(repository, storeRoot: store.root)
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: repository, createIfMissing: false)
        try ensureManagedAncestors(root: managedRoot, through: expected, createMissing: false)
        guard URL(fileURLWithPath: path).standardizedFileURL.path == expected.path else {
            throw TaskContextError.unsafeWorktree("Cleanup refused because the registered worktree is outside the managed location or resolves through a symbolic link.")
        }
        guard context.subtasks.filter(\.tracksCompletion).allSatisfy({ $0.status == .completed }) else {
            return .init(removed: false, message: "Some subtasks are still open. Complete or review them before closing the task.")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            let registration = try await git(["worktree", "list", "--porcelain"], in: repository)
            if registration.contains("worktree \(path)")
                || registration.contains("branch refs/heads/\(branch)") {
                return .init(removed: false,
                    message: "Managed worktree cleanup is incomplete: its exact Git registration remains. Context was retained for recovery.")
            }
            try await store.archive(ticketID: ticketID)
            _ = try await store.setWorktree(ticketID: ticketID, path: nil, branch: branch, baseBranch: base, managed: false)
            return .init(removed: true, message: "The managed worktree was already removed. Its context and archive remain available.")
        }
        let workspaceIdentity = try await managedWorkspaceIdentity(
            path: path,
            expected: expected,
            repositoryPath: repository)
        let actualRoot = try await git(["rev-parse", "--show-toplevel"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: actualRoot).standardizedFileURL.path == expected.path else {
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
        try beforeCleanupQuarantine(expected)
        let retained = try await removeVerifiedManagedWorkspace(
            expected: expected, identity: workspaceIdentity, referenceContext: context)
        _ = try await store.setWorktree(ticketID: ticketID, path: nil, branch: branch, baseBranch: base, managed: false)
        // Branch deletion is intentionally separate from successful workspace cleanup.
        // Keeping the branch preserves a recoverable Git reference for retrospective review.
        return .init(removed: true,
            message: "Git registration removed. Recoverable worktree files retained at \(retained.files.path), with recovery metadata at \(retained.gitAdmin.path). The central plan, archive, and Git branch remain available.")
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

    private func prepareManagedRoot(
        repositoryPath: String,
        createIfMissing: Bool = true
    ) async throws -> URL {
        let repository = try await primaryRepository(at: repositoryPath)
        let canonicalRepository = repository.standardizedFileURL.resolvingSymlinksInPath()
        try rejectApplicationSupport(canonicalRepository.path)
        let root = Self.managedRoot(repositoryPath: canonicalRepository.path).standardizedFileURL
        let expected = ManagedRootMarker(schemaVersion: 1,
            repositoryPath: canonicalRepository.path,
            repositoryIdentity: try await repositoryIdentity(in: canonicalRepository.path))

        if try nodeMetadata(at: root.path) == nil {
            guard createIfMissing else {
                throw TaskContextError.unsafeWorktree(
                    "Managed worktree storage is missing: \(root.path)")
            }
            guard Darwin.mkdir(root.path, 0o700) == 0 || errno == EEXIST else {
                throw TaskContextError.unsafeWorktree(
                    "Managed worktree storage could not be created: \(root.path)")
            }
        }
        guard let rootMetadata = try nodeMetadata(at: root.path),
              rootMetadata.mode & S_IFMT == S_IFDIR,
              rootMetadata.owner == Darwin.geteuid(),
              rootMetadata.mode & 0o022 == 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed worktree storage must be owned by the current user, not writable by other users, and not redirected: \(root.path)")
        }
        let resolvedRoot = root.resolvingSymlinksInPath()
        guard resolvedRoot.path == root.path else {
            throw TaskContextError.unsafeWorktree(
                "Managed worktree storage resolves through a symbolic link: \(root.path)")
        }

        let marker = root.appendingPathComponent(Self.markerName)
        if try nodeMetadata(at: marker.path) == nil {
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            guard entries.isEmpty else {
                throw TaskContextError.unsafeWorktree(
                    "Managed worktree storage is nonempty but has no ownership marker: \(root.path)")
            }
            guard createIfMissing else {
                throw TaskContextError.unsafeWorktree(
                    "Managed worktree storage has no ownership marker: \(root.path)")
            }
            do {
                try writeMarker(expected, to: marker)
            } catch let error as POSIXMarkerError where error.code == EEXIST {
                // Another process may have claimed this empty root for the same repository.
            }
        }
        guard try readMarker(at: marker) == expected else {
            throw TaskContextError.unsafeWorktree(
                "Managed worktree storage belongs to a different repository: \(root.path)")
        }
        return root
    }

    private struct POSIXMarkerError: Error {
        let code: Int32
    }

    private func writeMarker(_ marker: ManagedRootMarker, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(marker)
        data.append(0x0A)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXMarkerError(code: errno) }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard written > 0 else { throw POSIXMarkerError(code: errno) }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else { throw POSIXMarkerError(code: errno) }
    }

    private func readMarker(at url: URL) throws -> ManagedRootMarker {
        guard let markerMetadata = try nodeMetadata(at: url.path),
              markerMetadata.mode & S_IFMT == S_IFREG,
              markerMetadata.owner == Darwin.geteuid(),
              markerMetadata.mode & 0o022 == 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed worktree ownership marker is missing, writable by other users, redirected, or not a regular file: \(url.path)")
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed worktree ownership marker could not be opened safely: \(url.path)")
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o022 == 0,
              metadata.st_size >= 0,
              metadata.st_size <= 65_536 else {
            throw TaskContextError.unsafeWorktree(
                "Managed worktree ownership marker is invalid: \(url.path)")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else {
                throw TaskContextError.unsafeWorktree(
                    "Managed worktree ownership marker could not be read: \(url.path)")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 65_536 else {
                throw TaskContextError.unsafeWorktree(
                    "Managed worktree ownership marker is too large: \(url.path)")
            }
        }
        do { return try JSONDecoder().decode(ManagedRootMarker.self, from: data) }
        catch {
            throw TaskContextError.unsafeWorktree(
                "Managed worktree ownership marker is unreadable: \(url.path)")
        }
    }

    private func ensureManagedAncestors(root: URL, through candidate: URL,
                                        createMissing: Bool) throws {
        let normalizedRoot = root.standardizedFileURL
        let normalizedCandidate = candidate.standardizedFileURL
        guard normalizedCandidate.path == normalizedRoot.path
                || normalizedCandidate.path.hasPrefix(normalizedRoot.path + "/") else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace path escapes its repository-owned root: \(normalizedCandidate.path)")
        }
        let suffix = normalizedCandidate.path == normalizedRoot.path ? ""
            : String(normalizedCandidate.path.dropFirst(normalizedRoot.path.count + 1))
        var current = normalizedRoot
        let components = suffix.isEmpty ? [] : suffix.split(separator: "/").map(String.init)
        for component in [""] + components {
            if !component.isEmpty { current.appendPathComponent(component, isDirectory: true) }
            var metadata = try nodeMetadata(at: current.path)
            if metadata == nil, createMissing {
                guard Darwin.mkdir(current.path, 0o700) == 0 || errno == EEXIST else {
                    throw TaskContextError.unsafeWorktree(
                        "Managed workspace directory could not be created safely: \(current.path)")
                }
                metadata = try nodeMetadata(at: current.path)
            }
            guard let metadata else { break }
            guard metadata.mode & S_IFMT == S_IFDIR,
                  metadata.owner == Darwin.geteuid(),
                  metadata.mode & 0o022 == 0 else {
                throw TaskContextError.unsafeWorktree(
                    "Managed workspace ancestor is redirected, writable by other users, or is not owned by the current user: \(current.path)")
            }
            let resolved = current.resolvingSymlinksInPath()
            guard resolved.path == normalizedRoot.path
                    || resolved.path.hasPrefix(normalizedRoot.path + "/") else {
                throw TaskContextError.unsafeWorktree(
                    "Managed workspace ancestor resolves outside its repository-owned root: \(current.path)")
            }
        }
    }

    private struct NodeMetadata {
        let mode: mode_t
        let owner: uid_t
    }

    private func nodeMetadata(at path: String) throws -> NodeMetadata? {
        var metadata = stat()
        if Darwin.lstat(path, &metadata) == 0 {
            return NodeMetadata(mode: metadata.st_mode, owner: metadata.st_uid)
        }
        if errno == ENOENT { return nil }
        throw TaskContextError.unsafeWorktree(
            "Managed workspace metadata could not be inspected safely: \(path)")
    }

    private func rejectApplicationSupport(_ path: String, storeRoot: URL? = nil) throws {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var roots = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ECC Focus Queue", isDirectory: true)]
        if let storeRoot { roots.append(storeRoot) }
        guard !roots.contains(where: {
            let root = $0.standardizedFileURL.resolvingSymlinksInPath()
            return candidate.path.caseInsensitiveCompare(root.path) == .orderedSame
                || candidate.path.lowercased().hasPrefix(root.path.lowercased() + "/")
        }) else {
            throw TaskContextError.unsafeWorktree(
                "Coding workspaces cannot be stored in ECC Focus Queue Application Support. Choose a source checkout under Documents or another project directory.")
        }
    }

    private struct FileIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct ManagedWorkspaceIdentity: Equatable, Sendable {
        let file: FileIdentity
        let gitAdminFile: FileIdentity
        let gitDirectory: String
        let commonDirectory: String
    }

    private struct RetainedManagedWorkspace {
        let files: URL
        let gitAdmin: URL
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
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: repositoryPath, createIfMissing: false)
        try ensureManagedAncestors(root: managedRoot, through: expected, createMissing: false)
        guard pathURL.path == expected.path else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed or resolves through a symbolic link.")
        }
        let file = try fileIdentity(at: path)
        let root = try await git(
            ["rev-parse", "--show-toplevel"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard URL(fileURLWithPath: root).standardizedFileURL.path == expected.path else {
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
            gitAdminFile: try fileIdentity(at: normalizedGitDirectory),
            gitDirectory: normalizedGitDirectory,
            commonDirectory: normalizedCommonDirectory)
    }

    /// Never recursively delete a checkout because another process may write after
    /// the final Git scan. Move the verified inode to a recoverable sibling and move
    /// only its exact Git admin directory outside Git's active worktree registry.
    private func removeVerifiedManagedWorkspace(
        expected: URL,
        identity: ManagedWorkspaceIdentity,
        referenceContext: TaskContext?
    ) async throws -> RetainedManagedWorkspace {
        let repository = URL(fileURLWithPath: identity.commonDirectory, isDirectory: true)
            .deletingLastPathComponent()
        let managedRoot = Self.managedRoot(repositoryPath: repository.path)
        let common = URL(fileURLWithPath: identity.commonDirectory, isDirectory: true)
            .standardizedFileURL
        let admin = URL(fileURLWithPath: identity.gitDirectory, isDirectory: true)
            .standardizedFileURL
        guard admin.deletingLastPathComponent().path == common
                .appendingPathComponent("worktrees", isDirectory: true).path,
              try fileIdentity(at: admin.path) == identity.gitAdminFile else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace Git administration changed before cleanup; no files were removed.")
        }
        guard try nodeMetadata(at: admin.appendingPathComponent("locked").path) == nil else {
            throw TaskContextError.unsafeWorktree(
                "The managed worktree is locked. Unlock it explicitly before cleanup.")
        }

        let quarantine = try quarantineDirectoryByDescriptor(
            root: managedRoot, target: expected, expectedIdentity: identity.file,
            prefix: ".focus-queue-retained-")
        do {
            try await requireCleanQuarantinedWorkspace(
                quarantine, identity: identity, referenceContext: referenceContext)
            let retainedAdmin = try retainGitAdminDirectory(
                common: common, admin: admin,
                expectedIdentity: identity.gitAdminFile)
            return RetainedManagedWorkspace(files: quarantine, gitAdmin: retainedAdmin)
        } catch {
            if (try? nodeMetadata(at: quarantine.path)) != nil {
                do {
                    try restoreQuarantinedDirectory(
                        root: managedRoot, quarantine: quarantine,
                        original: expected, expectedIdentity: identity.file)
                } catch let recoveryError {
                    throw TaskContextError.unsafeWorktree(
                        "Managed cleanup stopped. Recoverable worktree retained at \(quarantine.path). \(error.localizedDescription) Recovery also failed: \(recoveryError.localizedDescription)")
                }
            }
            throw error
        }
    }

    private func requireCleanQuarantinedWorkspace(
        _ quarantine: URL,
        identity: ManagedWorkspaceIdentity,
        referenceContext: TaskContext?
    ) async throws {
        guard try fileIdentity(at: quarantine.path) == identity.file,
              try fileIdentity(at: identity.gitDirectory) == identity.gitAdminFile else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed after quarantine; no files were removed.")
        }
        let prefix = ["--git-dir", identity.gitDirectory, "--work-tree", quarantine.path]
        let status = try await runner.run(.init(
            executable: "/usr/bin/git",
            arguments: prefix + ["status", "--porcelain", "--untracked-files=all", "--ignore-submodules=none"],
            workingDirectory: quarantine.path))
        guard status.succeeded else {
            throw TaskContextError.commandFailed(status.standardError.isEmpty
                ? "Git could not verify the cleanup quarantine."
                : status.standardError)
        }
        guard status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TaskContextError.unsafeWorktree(
                "The managed worktree changed during cleanup. It was restored without deleting the new work.")
        }
        guard try nodeMetadata(at: quarantine.appendingPathComponent(".gitmodules").path) == nil else {
            throw TaskContextError.unsafeWorktree(
                "The managed worktree contains submodule metadata. Preserve and remove its submodules explicitly before cleanup.")
        }
        let ignored = try await runner.run(.init(
            executable: "/usr/bin/git",
            arguments: prefix + ["ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
            workingDirectory: quarantine.path))
        guard ignored.succeeded else {
            throw TaskContextError.commandFailed(ignored.standardError.isEmpty
                ? "Git could not inspect ignored files in the cleanup quarantine."
                : ignored.standardError)
        }
        let ignoredPaths = ignored.standardOutput.split(separator: "\0").map(String.init)
        guard let context = referenceContext else {
            guard ignoredPaths.isEmpty else {
                throw TaskContextError.unsafeWorktree(
                    "The managed worktree gained ignored files during cleanup. It was restored without deleting them.")
            }
            return
        }
        let referencePrefix = ".focus-queue/\(context.ticketID)/"
        for relativePath in ignoredPaths {
            let referenceURL = quarantine.appendingPathComponent(relativePath)
            let owned: Bool
            if relativePath == referencePrefix + "plan.md" {
                owned = (try? FileManager.default.destinationOfSymbolicLink(
                    atPath: referenceURL.path)) == context.planPath
            } else if relativePath == referencePrefix + "context.json",
                      let data = try? Data(contentsOf: referenceURL),
                      let pointer = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                owned = pointer["taskID"] == context.ticketID
                    && pointer["canonicalPlan"] == context.planPath
                    && pointer["canonicalContext"] == context.contextDirectory
                        .appendingPathComponent("context.json").path
            } else { owned = false }
            guard owned else {
                throw TaskContextError.unsafeWorktree(
                    "The managed worktree gained ignored files during cleanup. It was restored without deleting them.")
            }
        }
    }

    private func quarantineDirectoryByDescriptor(
        root: URL,
        target: URL,
        expectedIdentity: FileIdentity,
        prefix: String = ".focus-queue-removing-"
    ) throws -> URL {
        let normalizedRoot = root.standardizedFileURL
        let normalizedTarget = target.standardizedFileURL
        guard normalizedTarget.path.hasPrefix(normalizedRoot.path + "/") else {
            throw TaskContextError.unsafeWorktree(
                "Managed cleanup target escaped its verified root.")
        }
        let relative = String(normalizedTarget.path.dropFirst(normalizedRoot.path.count + 1))
            .split(separator: "/").map(String.init)
        guard let leaf = relative.last, !leaf.isEmpty else {
            throw TaskContextError.unsafeWorktree("Managed cleanup target is invalid.")
        }

        var parentDescriptor = Darwin.open(
            normalizedRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed cleanup root could not be opened safely.")
        }
        defer { Darwin.close(parentDescriptor) }
        try requireSafeDirectoryDescriptor(parentDescriptor)
        for component in relative.dropLast() {
            let next = Darwin.openat(
                parentDescriptor, component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                throw TaskContextError.unsafeWorktree(
                    "Managed cleanup parent changed before removal; no files were removed.")
            }
            do { try requireSafeDirectoryDescriptor(next) }
            catch { Darwin.close(next); throw error }
            Darwin.close(parentDescriptor)
            parentDescriptor = next
        }

        let sourceDescriptor = Darwin.openat(
            parentDescriptor, leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed before cleanup; no files were removed.")
        }
        defer { Darwin.close(sourceDescriptor) }
        let sourceMetadata = try directoryMetadata(descriptor: sourceDescriptor)
        guard sourceMetadata.identity == expectedIdentity else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace identity changed before cleanup; no files were removed.")
        }

        var quarantine = ""
        for _ in 0..<16 {
            quarantine = prefix + UUID().uuidString.lowercased()
            if Darwin.renameatx_np(
                parentDescriptor, leaf, parentDescriptor, quarantine,
                UInt32(RENAME_EXCL)) == 0 { break }
            if errno != EEXIST {
                throw TaskContextError.unsafeWorktree(
                    "Managed workspace could not be quarantined safely; no files were removed.")
            }
            quarantine = ""
        }
        guard !quarantine.isEmpty else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace could not reserve a cleanup quarantine.")
        }

        let quarantineDescriptor = Darwin.openat(
            parentDescriptor, quarantine,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        do {
            guard quarantineDescriptor >= 0 else {
                throw TaskContextError.unsafeWorktree(
                    "Managed workspace quarantine could not be opened safely.")
            }
            defer { Darwin.close(quarantineDescriptor) }
            let quarantineMetadata = try directoryMetadata(descriptor: quarantineDescriptor)
            guard quarantineMetadata.identity == sourceMetadata.identity else {
                throw TaskContextError.unsafeWorktree(
                    "Managed workspace identity changed during quarantine.")
            }
            return normalizedTarget.deletingLastPathComponent()
                .appendingPathComponent(quarantine, isDirectory: true)
        } catch {
            do {
                try restoreQuarantine(
                    parentDescriptor: parentDescriptor, quarantine: quarantine, leaf: leaf)
            } catch let recoveryError {
                let retained = normalizedTarget.deletingLastPathComponent()
                    .appendingPathComponent(quarantine).path
                throw TaskContextError.unsafeWorktree(
                    "Managed workspace verification stopped. Recoverable quarantine retained at \(retained). \(recoveryError.localizedDescription)")
            }
            throw error
        }
    }

    private func restoreQuarantinedDirectory(
        root: URL,
        quarantine: URL,
        original: URL,
        expectedIdentity: FileIdentity
    ) throws {
        let normalizedRoot = root.standardizedFileURL
        let normalizedQuarantine = quarantine.standardizedFileURL
        let normalizedOriginal = original.standardizedFileURL
        guard normalizedQuarantine.deletingLastPathComponent().path
                == normalizedOriginal.deletingLastPathComponent().path,
              normalizedOriginal.path.hasPrefix(normalizedRoot.path + "/") else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace quarantine cannot be restored outside its verified parent.")
        }
        let parent = normalizedOriginal.deletingLastPathComponent()
        let descriptor = Darwin.open(
            parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace quarantine parent could not be reopened safely.")
        }
        defer { Darwin.close(descriptor) }
        try requireSafeDirectoryDescriptor(descriptor)
        let quarantineName = normalizedQuarantine.lastPathComponent
        let originalName = normalizedOriginal.lastPathComponent
        let source = Darwin.openat(
            descriptor, quarantineName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace quarantine is unavailable for recovery.")
        }
        defer { Darwin.close(source) }
        guard try directoryMetadata(descriptor: source).identity == expectedIdentity,
              try nodeMetadata(at: normalizedOriginal.path) == nil,
              Darwin.renameatx_np(
                descriptor, quarantineName, descriptor, originalName,
                UInt32(RENAME_EXCL)) == 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace quarantine could not be restored automatically.")
        }
    }

    private func restoreQuarantine(
        parentDescriptor: Int32,
        quarantine: String,
        leaf: String
    ) throws {
        guard Darwin.renameatx_np(
            parentDescriptor, quarantine, parentDescriptor, leaf,
            UInt32(RENAME_EXCL)) == 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace quarantine was retained for recovery.")
        }
    }

    private struct DirectoryMetadata {
        let identity: FileIdentity
        let device: dev_t
    }

    private func directoryMetadata(descriptor: Int32) throws -> DirectoryMetadata {
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == Darwin.geteuid(),
              metadata.st_mode & 0o022 == 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed cleanup directory is redirected, writable by other users, or not owned by the current user.")
        }
        return DirectoryMetadata(
            identity: FileIdentity(
                device: UInt64(metadata.st_dev),
                inode: UInt64(metadata.st_ino)),
            device: metadata.st_dev)
    }

    private func requireSafeDirectoryDescriptor(_ descriptor: Int32) throws {
        _ = try directoryMetadata(descriptor: descriptor)
    }

    private func retainGitAdminDirectory(
        common: URL,
        admin: URL,
        expectedIdentity: FileIdentity
    ) throws -> URL {
        let normalizedCommon = common.standardizedFileURL
        let normalizedAdmin = admin.standardizedFileURL
        let activeParent = normalizedCommon.appendingPathComponent("worktrees", isDirectory: true)
        guard normalizedAdmin.deletingLastPathComponent().path == activeParent.path,
              !normalizedAdmin.lastPathComponent.isEmpty else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace Git administration escaped its verified parent.")
        }

        let commonDescriptor = Darwin.open(
            normalizedCommon.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard commonDescriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed Git directory could not be opened safely.")
        }
        defer { Darwin.close(commonDescriptor) }
        try requireSafeDirectoryDescriptor(commonDescriptor)

        let activeDescriptor = Darwin.openat(
            commonDescriptor, "worktrees",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard activeDescriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed Git worktree registry could not be opened safely.")
        }
        defer { Darwin.close(activeDescriptor) }
        try requireSafeDirectoryDescriptor(activeDescriptor)

        let retainedRootName = "focus-queue-retired-worktrees"
        if Darwin.mkdirat(commonDescriptor, retainedRootName, 0o700) != 0,
           errno != EEXIST {
            throw TaskContextError.unsafeWorktree(
                "Recoverable Git metadata storage could not be created safely.")
        }
        let retainedDescriptor = Darwin.openat(
            commonDescriptor, retainedRootName,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard retainedDescriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Recoverable Git metadata storage could not be opened safely.")
        }
        defer { Darwin.close(retainedDescriptor) }
        try requireSafeDirectoryDescriptor(retainedDescriptor)

        let leaf = normalizedAdmin.lastPathComponent
        let sourceDescriptor = Darwin.openat(
            activeDescriptor, leaf,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace Git administration changed before unregistering.")
        }
        defer { Darwin.close(sourceDescriptor) }
        guard try directoryMetadata(descriptor: sourceDescriptor).identity == expectedIdentity else {
            throw TaskContextError.unsafeWorktree(
                "Managed workspace Git administration changed before unregistering.")
        }
        guard try !descriptorEntryExists(sourceDescriptor, name: "locked") else {
            throw TaskContextError.unsafeWorktree(
                "The managed worktree is locked. Unlock it explicitly before cleanup.")
        }

        var retainedName = ""
        for _ in 0..<16 {
            retainedName = leaf + "-" + UUID().uuidString.lowercased()
            if Darwin.renameatx_np(
                activeDescriptor, leaf, retainedDescriptor, retainedName,
                UInt32(RENAME_EXCL)) == 0 { break }
            if errno != EEXIST {
                throw TaskContextError.unsafeWorktree(
                    "Managed Git registration could not be moved to recoverable storage.")
            }
            retainedName = ""
        }
        guard !retainedName.isEmpty else {
            throw TaskContextError.unsafeWorktree(
                "Managed Git registration could not reserve recoverable storage.")
        }

        let retainedURL = normalizedCommon
            .appendingPathComponent(retainedRootName, isDirectory: true)
            .appendingPathComponent(retainedName, isDirectory: true)
        do {
            let movedDescriptor = Darwin.openat(
                retainedDescriptor, retainedName,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard movedDescriptor >= 0 else {
                throw TaskContextError.unsafeWorktree(
                    "Recoverable Git registration could not be verified after its move.")
            }
            defer { Darwin.close(movedDescriptor) }
            guard try directoryMetadata(descriptor: movedDescriptor).identity == expectedIdentity else {
                throw TaskContextError.unsafeWorktree(
                    "Recoverable Git registration identity changed after its move.")
            }
            guard try !descriptorEntryExists(movedDescriptor, name: "locked") else {
                throw TaskContextError.unsafeWorktree(
                    "The managed worktree became locked during cleanup.")
            }
            return retainedURL
        } catch {
            if Darwin.renameatx_np(
                retainedDescriptor, retainedName, activeDescriptor, leaf,
                UInt32(RENAME_EXCL)) != 0 {
                throw TaskContextError.unsafeWorktree(
                    "Git cleanup stopped. Recoverable administration was retained at \(retainedURL.path). \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func descriptorEntryExists(_ descriptor: Int32, name: String) throws -> Bool {
        var metadata = stat()
        if Darwin.fstatat(descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            return true
        }
        if errno == ENOENT { return false }
        throw TaskContextError.unsafeWorktree(
            "Managed Git registration could not be inspected safely.")
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

    private func primaryRepository(at path: String) async throws -> URL {
        let value = try await git(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let common = URL(fileURLWithPath: value).standardizedFileURL.resolvingSymlinksInPath()
        guard common.lastPathComponent == ".git" else {
            throw TaskContextError.unsafeWorktree(
                "Focus Queue needs a non-bare Git repository before it can create an isolated workspace.")
        }
        return common.deletingLastPathComponent()
    }

}
