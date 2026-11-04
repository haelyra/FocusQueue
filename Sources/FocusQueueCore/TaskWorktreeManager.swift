import Foundation
import Darwin

/// Raw values are the persisted spelling of each choice, shared by saved launch presets and `fq`.
/// Git is suggested, not required: the isolated policies fork a worktree when the
/// source is a Git checkout and otherwise run the agent directly in the folder.
public enum AgentWorkspacePolicy: String, Codable, CaseIterable, Sendable {
    case existingCheckout = "existing"
    case isolatedCleanCheckout = "isolated-clean"
    /// Fork the selected HEAD without copying, stashing, or changing local edits.
    case isolatedCommittedSnapshot = "isolated-snapshot"

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

    /// Repository identities embed the device number (`st_dev`), which macOS
    /// reassigns every time the volume mounts, so a stored identity from before
    /// a reboot never matches exactly. The canonical path and inode decide
    /// whether two identities name the same repository; the device is ignored.
    nonisolated static func sameRepositoryIdentity(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        func parse(_ value: String) -> (path: String, inode: Substring)? {
            guard let inodeSeparator = value.lastIndex(of: ":") else { return nil }
            let inode = value[value.index(after: inodeSeparator)...]
            let head = value[..<inodeSeparator]
            guard let deviceSeparator = head.lastIndex(of: ":") else { return nil }
            return (String(head[..<deviceSeparator]), inode)
        }
        guard let lhs = parse(left), let rhs = parse(right), lhs.inode == rhs.inode else {
            return false
        }
        return URL(fileURLWithPath: lhs.path).standardizedFileURL.resolvingSymlinksInPath().path
            == URL(fileURLWithPath: rhs.path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    nonisolated static func sameRepositoryIdentity(_ left: String?, _ right: String?) -> Bool {
        switch (left, right) {
        case (.none, .none): return true
        case let (.some(left), .some(right)): return sameRepositoryIdentity(left, right)
        default: return false
        }
    }

    public nonisolated static func managedRoot(repositoryPath: String) -> URL {
        let repository = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        return repository.appendingPathComponent(".worktrees", isDirectory: true)
    }

    private nonisolated static func legacyManagedRoot(repositoryPath: String) -> URL {
        let repository = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        return repository.deletingLastPathComponent()
            .appendingPathComponent(repository.lastPathComponent + "-worktrees", isDirectory: true)
    }

    private nonisolated static func managedRoot(
        repositoryPath: String,
        containing workspacePath: String
    ) throws -> URL {
        let workspace = URL(fileURLWithPath: workspacePath).standardizedFileURL
        for root in [managedRoot(repositoryPath: repositoryPath),
                     legacyManagedRoot(repositoryPath: repositoryPath)] {
            if workspace.path == root.path || workspace.path.hasPrefix(root.path + "/") {
                return root
            }
        }
        throw TaskContextError.unsafeWorktree(
            "Managed workspace path escapes its repository-owned root: \(workspace.path)")
    }

    public nonisolated static func agentDestination(
        repositoryPath: String, ticketID: String, subtaskID: String
    ) -> URL {
        agentDestination(root: managedRoot(repositoryPath: repositoryPath),
            ticketID: ticketID, subtaskID: subtaskID)
    }

    private nonisolated static func agentDestination(
        root: URL, ticketID: String, subtaskID: String
    ) -> URL {
        root
            .appendingPathComponent(ticketID.lowercased(), isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(subtaskID.lowercased(), isDirectory: true)
    }

    public nonisolated static func taskDestination(repositoryPath: String, ticketID: String) -> URL {
        taskDestination(root: managedRoot(repositoryPath: repositoryPath), ticketID: ticketID)
    }

    private nonisolated static func taskDestination(root: URL, ticketID: String) -> URL {
        root
            .appendingPathComponent(ticketID.lowercased(), isDirectory: true)
            .appendingPathComponent("task", isDirectory: true)
    }

    /// Existence and location safety shared by Git checkouts and plain directories.
    @discardableResult
    private func requireSafeAgentDirectory(at path: String) throws -> URL {
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
        return canonicalPath
    }

    /// Git checkout metadata, or nil for a plain directory. Git isolation is
    /// suggested, not required: a directory without a repository still hosts an
    /// agent directly.
    public func gitWorkspace(at path: String) async throws -> AgentWorkspace? {
        try requireSafeAgentDirectory(at: path)
        let probe = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["rev-parse", "--show-toplevel"], workingDirectory: path))
        guard probe.succeeded else { return nil }
        return try await workspace(at: path)
    }

    /// A plain directory workspace: no branch, no commit, never managed.
    public func plainWorkspace(at path: String) async throws -> AgentWorkspace {
        try requireSafeAgentDirectory(at: path)
        return AgentWorkspace(path: path, repositoryPath: path)
    }

    public func workspace(at path: String) async throws -> AgentWorkspace {
        try requireSafeAgentDirectory(at: path)
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
        // A plain directory has no checkout state to protect.
        let probe = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["rev-parse", "--show-toplevel"], workingDirectory: path))
        guard probe.succeeded else { return false }
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
        // Git is suggested, not required: without a repository no worktree can
        // be forked, so the agent runs directly in the selected directory.
        // This mirrors the shell entries' "non-git" policy, which keeps tracking
        // active while isolation is unavailable.
        guard let source = try await gitWorkspace(at: path) else {
            return try await plainWorkspace(at: path)
        }
        let repository = try await primaryRepository(at: path)
        try rejectApplicationSupport(repository.path, storeRoot: store.root)
        let destination = Self.agentDestination(repositoryPath: repository.path,
            ticketID: ticketID, subtaskID: subtaskID)
        let branch = "focus-queue/\(ticketID.lowercased())-\(subtaskID.lowercased())"
        // A failed provider launch may already own a provisioned workspace.
        // Retry that exact assignment instead of creating another branch.
        if let saved = try await store.load(ticketID: ticketID)?.subtasks.first(where: { $0.id == subtaskID })?.workspace {
            let sameSelection: Bool
            if createWorktree, saved.managed {
                let savedRoot = try Self.managedRoot(
                    repositoryPath: saved.repositoryPath, containing: saved.path)
                let savedDestination = Self.agentDestination(
                    root: savedRoot, ticketID: ticketID, subtaskID: subtaskID)
                sameSelection = saved.path == savedDestination.path && saved.branch == branch
            } else {
                sameSelection = !createWorktree && saved.path == path
            }
            guard sameSelection,
                  Self.sameRepositoryIdentity(saved.repositoryIdentity, source.repositoryIdentity) else {
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
        // A plain directory workspace carries no Git identity; only its location
        // is verified. Git metadata, when present, keeps the full identity check.
        guard let actual = try await gitWorkspace(at: saved.path) else { return }
        if saved.managed {
            let managedRoot = try await prepareManagedRoot(
                repositoryPath: saved.repositoryPath, containing: saved.path,
                createIfMissing: false)
            try ensureManagedAncestors(root: managedRoot,
                through: URL(fileURLWithPath: saved.path), createMissing: false)
        }
        let expectedRepository = try await repositoryIdentity(in: saved.repositoryPath)
        guard Self.sameRepositoryIdentity(actual.repositoryIdentity, expectedRepository),
              saved.repositoryIdentity.map({ Self.sameRepositoryIdentity(actual.repositoryIdentity, $0) }) ?? true,
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
        guard saved.managed, let branch = saved.branch else {
            throw TaskContextError.unsafeWorktree("The saved workspace is missing: \(saved.path)")
        }
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: saved.repositoryPath, containing: saved.path,
            createIfMissing: false)
        let expected = Self.agentDestination(root: managedRoot,
            ticketID: ticketID, subtaskID: subtaskID).standardizedFileURL
        let savedURL = URL(fileURLWithPath: saved.path).standardizedFileURL
        guard savedURL.path == expected.path else {
            throw TaskContextError.unsafeWorktree(
                "The saved workspace is outside its managed location: \(saved.path); expected \(expected.path)")
        }
        try ensureManagedAncestors(root: managedRoot,
            through: expected.deletingLastPathComponent(), createMissing: true)
        let retained = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            workingDirectory: saved.repositoryPath))
        if !retained.succeeded {
            // Task completion deletes agent branches. Recreate one from its
            // archived work, or from the base branch that absorbed it.
            var start: String?
            for candidate in [Self.archiveRef(forBranch: branch) + "-uncommitted",
                              Self.archiveRef(forBranch: branch)] + [saved.baseBranch].compactMap({ $0 }) {
                let resolved = try await runner.run(.init(executable: "/usr/bin/git",
                    arguments: ["rev-parse", "--verify", "--quiet", candidate + "^{commit}"],
                    workingDirectory: saved.repositoryPath))
                if resolved.succeeded {
                    start = resolved.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            guard let start else {
                throw TaskContextError.unsafeWorktree("The saved branch \(branch) and its archive are missing.")
            }
            _ = try await git(["branch", branch, start], in: saved.repositoryPath)
        }
        _ = try await git(["worktree", "add", saved.path, branch], in: saved.repositoryPath)
        try ensureManagedAncestors(root: managedRoot, through: expected, createMissing: false)
    }

    public func cleanupAgent(ticketID: String, subtask: TaskSubtask, store: TaskContextStore) async throws -> TaskWorktreeCleanupResult {
        guard subtask.completionTerminalRetained != true else {
            return .init(removed: false, message: "Workspace retained for the completed conversation and its resume command.")
        }
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
        try rejectApplicationSupport(workspace.path, storeRoot: store.root)
        try rejectApplicationSupport(workspace.repositoryPath, storeRoot: store.root)
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: workspace.repositoryPath, containing: workspace.path,
            createIfMissing: false)
        let expected = Self.agentDestination(root: managedRoot,
            ticketID: ticketID, subtaskID: subtask.id).standardizedFileURL
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
        if let saved = try await store.load(ticketID: ticketID), saved.subtasks.contains(where: { $0.completionTerminalRetained == true }) {
            return .init(removed: false, message: "Workspace retained for completed conversations and their resume commands.")
        }
        guard let context = try await store.load(ticketID: ticketID) else { throw TaskContextError.missingContext(ticketID) }
        guard context.managedWorktree, let path = context.worktreePath, let repository = context.repositoryPath,
              let branch = context.branch, let base = context.baseBranch else {
            try await store.archive(ticketID: ticketID)
            return .init(removed: false, message: "Context archived. This task uses an existing workspace; automatic cleanup only removes worktrees created by Focus Queue.")
        }
        try rejectApplicationSupport(path, storeRoot: store.root)
        try rejectApplicationSupport(repository, storeRoot: store.root)
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: repository, containing: path, createIfMissing: false)
        let expected = Self.taskDestination(root: managedRoot,
            ticketID: context.ticketID).standardizedFileURL
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
        containing workspacePath: String? = nil,
        createIfMissing: Bool = true
    ) async throws -> URL {
        let repository = try await primaryRepository(at: repositoryPath)
        let canonicalRepository = repository.standardizedFileURL.resolvingSymlinksInPath()
        try rejectApplicationSupport(canonicalRepository.path)
        let root = try workspacePath.map {
            try Self.managedRoot(repositoryPath: canonicalRepository.path, containing: $0)
        } ?? Self.managedRoot(repositoryPath: canonicalRepository.path)
        if root.path == Self.managedRoot(repositoryPath: canonicalRepository.path).path {
            try await ensureManagedRootExcluded(repositoryPath: canonicalRepository.path)
        }
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
        let storedMarker = try readMarker(at: marker)
        if storedMarker != expected {
            guard storedMarker.schemaVersion == expected.schemaVersion,
                  storedMarker.repositoryPath == expected.repositoryPath,
                  Self.sameRepositoryIdentity(storedMarker.repositoryIdentity, expected.repositoryIdentity) else {
                throw TaskContextError.unsafeWorktree(
                    "Managed worktree storage belongs to a different repository: \(root.path)")
            }
            // Only the device number drifted across a remount or reboot.
            // Refresh the marker so it carries the current identity again.
            try replaceMarker(expected, at: marker)
        }
        return root
    }

    private func ensureManagedRootExcluded(repositoryPath: String) async throws {
        let rawPath = try await git(
            ["rev-parse", "--git-path", "info/exclude"], in: repositoryPath)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let excludeURL = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath).standardizedFileURL
            : URL(fileURLWithPath: repositoryPath)
                .appendingPathComponent(rawPath).standardizedFileURL
        try FocusQueueFileLock.withLocks(for: [excludeURL]) {
            let previous = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
            guard !previous.split(separator: "\n").contains("/.worktrees/") else { return }
            let separator = previous.isEmpty || previous.hasSuffix("\n") ? "" : "\n"
            let updated = previous + separator
                + "# Local Focus Queue worktrees\n/.worktrees/\n"
            try Data(updated.utf8).write(to: excludeURL, options: .atomic)
        }
    }

    private struct POSIXMarkerError: Error {
        let code: Int32
    }

    /// Atomically replace an existing marker (used when only the unstable
    /// device number drifted). Writes a temporary sibling and renames over the
    /// marker so readers never observe a partial file.
    private func replaceMarker(_ marker: ManagedRootMarker, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(marker)
        data.append(0x0A)
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(Self.markerName).\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXMarkerError(code: errno) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    guard written > 0 else { throw POSIXMarkerError(code: errno) }
                    offset += written
                }
            }
            guard Darwin.fsync(descriptor) == 0 else { throw POSIXMarkerError(code: errno) }
            Darwin.close(descriptor)
        } catch {
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXMarkerError(code: code)
        }
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

    /// Whether a path lies in Focus Queue's own data folder, which holds queue
    /// files rather than source checkouts.
    public nonisolated static func isApplicationSupportPath(_ path: String, storeRoot: URL? = nil) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var roots = [FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ECC Focus Queue", isDirectory: true)]
        if let storeRoot { roots.append(storeRoot) }
        return roots.contains(where: {
            let root = $0.standardizedFileURL.resolvingSymlinksInPath()
            return candidate.path.caseInsensitiveCompare(root.path) == .orderedSame
                || candidate.path.lowercased().hasPrefix(root.path.lowercased() + "/")
        })
    }

    private func rejectApplicationSupport(_ path: String, storeRoot: URL? = nil) throws {
        guard !Self.isApplicationSupportPath(path, storeRoot: storeRoot) else {
            throw TaskContextError.unsafeWorktree(
                "Agents cannot work inside Focus Queue's data folder. Choose a project folder outside it, or leave the project without a folder to start in your home directory.")
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
            repositoryPath: repositoryPath, containing: expected.path,
            createIfMissing: false)
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
        referenceContext: TaskContext?,
        requireClean: Bool = true
    ) async throws -> RetainedManagedWorkspace {
        let repository = URL(fileURLWithPath: identity.commonDirectory, isDirectory: true)
            .deletingLastPathComponent()
        let managedRoot = try Self.managedRoot(
            repositoryPath: repository.path, containing: expected.path)
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
            if requireClean {
                try await requireCleanQuarantinedWorkspace(
                    quarantine, identity: identity, referenceContext: referenceContext)
            } else {
                // Completion already archived any uncommitted work; only the
                // exact checkout and its Git administration may move.
                guard try fileIdentity(at: quarantine.path) == identity.file,
                      try fileIdentity(at: identity.gitDirectory) == identity.gitAdminFile else {
                    throw TaskContextError.unsafeWorktree(
                        "Managed workspace identity changed after quarantine; no files were removed.")
                }
            }
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


    // MARK: - Completion retirement

    /// Regenerated build output, deleted before staging so a completed
    /// workspace frees its disk at once. Everything else is staged.
    public nonisolated static let disposableBuildDirectories = [
        ".build", ".swiftpm", "node_modules", "DerivedData", ".pytest_cache", "__pycache__",
    ]
    public nonisolated static let archiveRefPrefix = "refs/focus-queue/archive/"
    public nonisolated static let trashDirectoryName = ".trash"
    public nonisolated static let retainedPrefixes = [".focus-queue-retained-", ".focus-queue-removing-"]

    public nonisolated static func managedRoots(repositoryPath: String) -> [URL] {
        [managedRoot(repositoryPath: repositoryPath), legacyManagedRoot(repositoryPath: repositoryPath)]
    }

    /// The task branch and every agent branch of one ticket.
    public nonisolated static func ownsBranch(_ name: String, ticketID: String) -> Bool {
        let task = "focus-queue/" + ticketID.lowercased()
        return name == task || name.hasPrefix(task + "-")
    }

    /// Archive refs live outside refs/heads, so `git branch` stays short while
    /// the commits remain reachable for recovery.
    public nonisolated static func archiveRef(forBranch branch: String) -> String {
        let leaf = branch.hasPrefix("focus-queue/") ? String(branch.dropFirst("focus-queue/".count)) : branch
        return archiveRefPrefix + leaf
    }

    public func primaryRepositoryPath(of path: String) async throws -> String {
        try await primaryRepository(at: path).path
    }

    /// True when every change on `head` already exists in a target: an
    /// ancestor, rebased or cherry-picked commits, or a squash merge.
    public func isIntegrated(_ head: String, into targets: [String], repositoryPath: String) async throws -> Bool {
        for target in targets {
            let ancestor = try await runner.run(.init(executable: "/usr/bin/git",
                arguments: ["merge-base", "--is-ancestor", head, target], workingDirectory: repositoryPath))
            if ancestor.succeeded { return true }
            // Rebased or cherry-picked commits match by patch ID even when
            // later base commits edit the same lines.
            let cherry = try await runner.run(.init(executable: "/usr/bin/git",
                arguments: ["cherry", target, head], workingDirectory: repositoryPath, timeoutSeconds: 120))
            if cherry.succeeded, cherry.standardOutput.split(separator: "\n").allSatisfy({ $0.hasPrefix("-") }) {
                return true
            }
            let merged = try await runner.run(.init(executable: "/usr/bin/git",
                arguments: ["merge-tree", "--write-tree", "--no-messages", target, head],
                workingDirectory: repositoryPath, timeoutSeconds: 120))
            guard merged.succeeded,
                  let tree = merged.standardOutput.split(separator: "\n").first.map(String.init) else { continue }
            let targetTree = try await git(["rev-parse", target + "^{tree}"], in: repositoryPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if tree == targetTree { return true }
        }
        return false
    }

    /// Completion is authoritative. Uncommitted or unmerged work is kept under
    /// an archive ref, build output is deleted, and the checkout moves to the
    /// managed trash with its Git registration removed. Nothing is deleted here.
    public func retireWorktree(
        path: String, repositoryPath: String, ticketID: String,
        integrationTargets: [String], dryRun: Bool, now: Date = Date()
    ) async throws -> WorktreeRetirement {
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: repositoryPath, containing: pathURL.path, createIfMissing: false)
        let trash = managedRoot.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
        guard pathURL.path != managedRoot.path, !pathURL.path.hasPrefix(trash.path + "/") else {
            throw TaskContextError.unsafeWorktree("Only a managed task workspace can be retired: \(pathURL.path)")
        }
        try ensureManagedAncestors(root: managedRoot, through: pathURL, createMissing: false)
        let identity = try await managedWorkspaceIdentity(
            path: pathURL.path, expected: pathURL, repositoryPath: repositoryPath)
        var record = WorktreeRetirement(path: pathURL.path, repositoryPath: repositoryPath)
        let branch = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"], workingDirectory: pathURL.path))
        record.branch = branch.succeeded ? branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let head = try await git(["rev-parse", "HEAD"], in: pathURL.path).trimmingCharacters(in: .whitespacesAndNewlines)
        record.head = head
        record.integrated = try await isIntegrated(head, into: integrationTargets, repositoryPath: repositoryPath)
        let leafRef = record.branch.map(Self.archiveRef(forBranch:))
            ?? Self.archiveRefPrefix + ticketID.lowercased() + "-" + pathURL.lastPathComponent
        let buildOutput = try Self.disposableBuildDirectories.filter { name in
            guard let metadata = try nodeMetadata(at: pathURL.appendingPathComponent(name).path) else { return false }
            return metadata.mode & S_IFMT == S_IFDIR
        }
        if !dryRun {
            for name in buildOutput {
                let ignored = try await runner.run(.init(executable: "/usr/bin/git",
                    arguments: ["check-ignore", "--quiet", "--", name], workingDirectory: pathURL.path))
                guard ignored.succeeded else { continue }
                try FileManager.default.removeItem(at: pathURL.appendingPathComponent(name, isDirectory: true))
                record.removedBuildOutput.append(name)
            }
        }
        record.dirty = !(try await git(["status", "--porcelain", "--untracked-files=all"], in: pathURL.path))
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if record.dirty { record.archiveRef = leafRef + "-uncommitted" }
        else if !record.integrated { record.archiveRef = leafRef }
        let stagedName = Self.stagingName(ticketID: ticketID, leaf: pathURL.lastPathComponent, now: now)
        guard !dryRun else {
            record.removedBuildOutput = buildOutput
            record.outcome = "Would stage at \(trash.appendingPathComponent(stagedName).path)"
            return record
        }
        if let ref = record.archiveRef {
            let commit = record.dirty
                ? try await snapshotCommit(worktree: pathURL.path, gitDirectory: identity.gitDirectory, head: head)
                : head
            _ = try await git(["update-ref", "-m", "Focus Queue completion archive", ref, commit], in: repositoryPath)
            record.archivedCommit = commit
        }
        try await requireUnchangedManagedWorkspace(
            path: pathURL.path, expected: pathURL, repositoryPath: repositoryPath, baseline: identity)
        let retained = try await removeVerifiedManagedWorkspace(
            expected: pathURL, identity: identity, referenceContext: nil, requireClean: false)
        let staged = try moveIntoTrash(root: managedRoot, item: retained.files, name: stagedName)
        record.stagedPath = staged.path
        try writeStagingManifest(StagingManifest(kind: "worktree", ticketID: ticketID,
            originalPath: pathURL.path, stagedPath: staged.path, repositoryPath: repositoryPath,
            branch: record.branch, head: head, archiveRef: record.archiveRef,
            archivedCommit: record.archivedCommit, gitAdministration: retained.gitAdmin.path,
            stagedAt: now, purgeAfter: now.addingTimeInterval(TaskCompletionCleanup.stagingRetention)),
            beside: staged)
        removeEmptyAncestors(of: pathURL, root: managedRoot)
        record.outcome = "Staged"
        return record
    }

    /// Earlier cleanups left recoverable checkouts beside the workspace. Move
    /// them into the trash so the same retention window applies.
    public func stageRetainedCheckouts(
        under directory: URL, repositoryPath: String, ticketID: String, dryRun: Bool, now: Date = Date()
    ) async throws -> [String] {
        let directory = directory.standardizedFileURL
        guard try nodeMetadata(at: directory.path) != nil else { return [] }
        let managedRoot = try await prepareManagedRoot(
            repositoryPath: repositoryPath, containing: directory.path, createIfMissing: false)
        try ensureManagedAncestors(root: managedRoot, through: directory, createMissing: false)
        var candidates: [URL] = []
        for parent in [directory, directory.appendingPathComponent("agents", isDirectory: true)] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent.path) else { continue }
            for name in names.sorted() where Self.retainedPrefixes.contains(where: name.hasPrefix) {
                candidates.append(parent.appendingPathComponent(name, isDirectory: true))
            }
        }
        guard !dryRun else { return candidates.map(\.path) }
        var staged: [String] = []
        for candidate in candidates {
            try ensureManagedAncestors(root: managedRoot, through: candidate, createMissing: false)
            let destination = try moveIntoTrash(root: managedRoot, item: candidate,
                name: Self.stagingName(ticketID: ticketID, leaf: candidate.lastPathComponent, now: now))
            try writeStagingManifest(StagingManifest(kind: "retained-checkout", ticketID: ticketID,
                originalPath: candidate.path, stagedPath: destination.path, repositoryPath: repositoryPath,
                stagedAt: now, purgeAfter: now.addingTimeInterval(TaskCompletionCleanup.stagingRetention)),
                beside: destination)
            staged.append(destination.path)
        }
        removeEmptyAncestors(of: directory.appendingPathComponent("agents", isDirectory: true), root: managedRoot)
        return staged
    }

    /// Deletes a branch after its work is integrated or archived. A merged
    /// remote branch of the same name is deleted only when it holds no extra work.
    public func retireBranch(
        _ name: String, repositoryPath: String, integrationTargets: [String],
        remote: String?, remoteHead: String?, dryRun: Bool
    ) async throws -> BranchRetirement {
        var record = BranchRetirement(name: name, repositoryPath: repositoryPath, remoteHead: remoteHead)
        let local = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)^{commit}"],
            workingDirectory: repositoryPath))
        if local.succeeded {
            let head = local.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            record.head = head
            let worktrees = try await git(["worktree", "list", "--porcelain"], in: repositoryPath)
            guard !worktrees.split(separator: "\n").contains(where: { $0 == "branch refs/heads/\(name)" }) else {
                record.outcome = "Kept: still checked out in a worktree."
                return record
            }
            record.integrated = try await isIntegrated(head, into: integrationTargets, repositoryPath: repositoryPath)
            if !record.integrated { record.archiveRef = Self.archiveRef(forBranch: name) }
            if !dryRun {
                if let ref = record.archiveRef {
                    _ = try await git(["update-ref", "-m", "Focus Queue completion archive", ref, head], in: repositoryPath)
                }
                // The old value makes deletion fail if another writer moved the branch.
                _ = try await git(["update-ref", "-d", "refs/heads/\(name)", head], in: repositoryPath)
                record.localDeleted = true
            }
        }
        if let remote, let remoteHead {
            let present = try await runner.run(.init(executable: "/usr/bin/git",
                arguments: ["cat-file", "-e", remoteHead + "^{commit}"], workingDirectory: repositoryPath))
            if !present.succeeded {
                _ = try await runner.run(.init(executable: "/usr/bin/git",
                    arguments: ["fetch", "--quiet", "--no-tags", remote, "refs/heads/\(name)"],
                    workingDirectory: repositoryPath, timeoutSeconds: 120))
            }
            let remoteIntegrated = remoteHead == record.head && record.head != nil
                ? record.integrated
                : (try? await isIntegrated(remoteHead, into: integrationTargets, repositoryPath: repositoryPath)) ?? false
            if !remoteIntegrated {
                record.outcome = "Remote branch kept: it has work absent from the base branch."
            } else if !dryRun {
                let pushed = try await runner.run(.init(executable: "/usr/bin/git",
                    arguments: ["push", "--porcelain", "--force-with-lease=refs/heads/\(name):\(remoteHead)",
                                remote, ":refs/heads/\(name)"],
                    workingDirectory: repositoryPath, timeoutSeconds: 120))
                guard pushed.succeeded else {
                    throw TaskContextError.commandFailed("Could not delete \(remote)/\(name): "
                        + (pushed.standardError.isEmpty ? pushed.standardOutput : pushed.standardError))
                }
                record.remoteDeleted = true
            }
        }
        if record.outcome.isEmpty {
            record.outcome = dryRun ? "Would delete" + (record.archiveRef.map { " after archiving to \($0)" } ?? "")
                : "Deleted" + (record.archiveRef.map { "; work archived at \($0)" } ?? "")
        }
        return record
    }

    private nonisolated static func stagingName(ticketID: String, leaf: String, now: Date) -> String {
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        return "\(ticketID.lowercased())-\(leaf)-\(stamp)"
    }

    /// Records tracked and untracked changes in a commit without touching the
    /// checkout's index, branch, or files.
    private func snapshotCommit(worktree: String, gitDirectory: String, head: String) async throws -> String {
        let index = URL(fileURLWithPath: gitDirectory)
            .appendingPathComponent("focus-queue-snapshot-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = [
            "GIT_INDEX_FILE": index.path,
            "GIT_AUTHOR_NAME": "Focus Queue", "GIT_AUTHOR_EMAIL": "focus-queue@localhost",
            "GIT_COMMITTER_NAME": "Focus Queue", "GIT_COMMITTER_EMAIL": "focus-queue@localhost",
        ]
        var output = ""
        for arguments in [["read-tree", head], ["add", "--all", "--", "."], ["write-tree"]] {
            let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: arguments,
                workingDirectory: worktree, environment: environment, timeoutSeconds: 300))
            guard result.succeeded else {
                throw TaskContextError.commandFailed("Could not archive uncommitted work: \(result.standardError)")
            }
            output = result.standardOutput
        }
        let tree = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = try await runner.run(.init(executable: "/usr/bin/git",
            arguments: ["commit-tree", tree, "-p", head, "-m", "Focus Queue completion snapshot of uncommitted work"],
            workingDirectory: worktree, environment: environment))
        guard commit.succeeded else {
            throw TaskContextError.commandFailed("Could not archive uncommitted work: \(commit.standardError)")
        }
        return commit.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func moveIntoTrash(root: URL, item: URL, name: String) throws -> URL {
        let trash = root.appendingPathComponent(Self.trashDirectoryName, isDirectory: true)
        try ensureManagedAncestors(root: root, through: trash, createMissing: true)
        let parent = Darwin.open(item.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw TaskContextError.unsafeWorktree("Staging source could not be opened safely.") }
        defer { Darwin.close(parent) }
        let destination = Darwin.open(trash.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard destination >= 0 else { throw TaskContextError.unsafeWorktree("The managed trash could not be opened safely.") }
        defer { Darwin.close(destination) }
        try requireSafeDirectoryDescriptor(parent)
        try requireSafeDirectoryDescriptor(destination)
        var leaf = name
        for _ in 0..<16 {
            if Darwin.renameatx_np(parent, item.lastPathComponent, destination, leaf, UInt32(RENAME_EXCL)) == 0 {
                return trash.appendingPathComponent(leaf, isDirectory: true)
            }
            guard errno == EEXIST else {
                throw TaskContextError.unsafeWorktree("Could not stage \(item.path) in the managed trash.")
            }
            leaf = name + "-" + UUID().uuidString.lowercased().prefix(8)
        }
        throw TaskContextError.unsafeWorktree("The managed trash could not reserve a name for \(item.path).")
    }

    private func writeStagingManifest(_ manifest: StagingManifest, beside staged: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: staged.appendingPathExtension("json"), options: .atomic)
    }

    /// Ticket folders empty out once every workspace is staged. Only empty
    /// directories (or ones holding a lone .DS_Store) are removed.
    private func removeEmptyAncestors(of path: URL, root: URL) {
        var current = path.standardizedFileURL.deletingLastPathComponent()
        if (try? nodeMetadata(at: path.path)) != nil { current = path.standardizedFileURL }
        let normalizedRoot = root.standardizedFileURL.path
        while current.path.hasPrefix(normalizedRoot + "/") {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: current.path)) ?? ["?"]
            guard names.allSatisfy({ $0 == ".DS_Store" }) else { return }
            if !names.isEmpty { try? FileManager.default.removeItem(at: current.appendingPathComponent(".DS_Store")) }
            guard Darwin.rmdir(current.path) == 0 else { return }
            current.deleteLastPathComponent()
        }
    }
}
