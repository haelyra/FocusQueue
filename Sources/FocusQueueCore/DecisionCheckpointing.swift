import Foundation

/// Git side of decision nodes: snapshot a worktree into a commit under a
/// `refs/focus-queue/decisions/...` ref, push that ref, and restore a worktree
/// to a snapshot. Snapshots use a temporary index, so making one never touches
/// the branch, the index, or any file.
public struct DecisionCheckpointing: Sendable {
    public static let git = "/usr/bin/git"
    /// Commits are authored by Focus Queue so a missing user identity never blocks a checkpoint.
    static let identity = [
        "GIT_AUTHOR_NAME": "Focus Queue", "GIT_AUTHOR_EMAIL": "focus-queue@localhost",
        "GIT_COMMITTER_NAME": "Focus Queue", "GIT_COMMITTER_EMAIL": "focus-queue@localhost",
    ]
    /// Branches a rewind never moves: they belong to integration, not to one agent.
    static let integrationBranches: Set<String> = ["main", "master", "trunk", "develop"]

    let runner: any ProcessRunning

    public init(runner: any ProcessRunning = FoundationProcessRunner()) { self.runner = runner }

    public struct RestoreResult: Equatable, Sendable {
        /// The worktree as it stood before the rewind.
        public var saved: DecisionCheckpoint
        /// True when the branch moved back to the checkpoint's parent.
        public var movedBranch: Bool
        /// Why the branch stayed where it was, when it did.
        public var branchNote: String?
    }

    // MARK: Snapshot

    /// Commits the worktree under `ref` and, when `push` is set and a remote
    /// exists, pushes the ref. A failed push is recorded, not thrown: the local
    /// ref still restores the worktree, and `push(_:)` retries later.
    public func checkpoint(workspace: String, ref: String, message: String, push: Bool) async throws -> DecisionCheckpoint {
        let top = try await output(["rev-parse", "--show-toplevel"], in: workspace)
        let head = try? await output(["rev-parse", "--verify", "-q", "HEAD^{commit}"], in: top)
        let branch = try? await output(["symbolic-ref", "--short", "-q", "HEAD"], in: top)
        let gitDirectory = try await output(["rev-parse", "--absolute-git-dir"], in: top)
        let index = URL(fileURLWithPath: gitDirectory)
            .appendingPathComponent("focus-queue-decision-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        var environment = Self.identity
        environment["GIT_INDEX_FILE"] = index.path
        _ = try await output(head.map { ["read-tree", $0] } ?? ["read-tree", "--empty"], in: top,
                             environment: environment, timeout: 300)
        _ = try await output(["add", "--all", "--", "."], in: top, environment: environment, timeout: 300)
        let tree = try await output(["write-tree"], in: top, environment: environment, timeout: 300)
        var arguments = ["commit-tree", tree]
        if let head { arguments += ["-p", head] }
        arguments += ["-m", message]
        let commit = try await output(arguments, in: top, environment: Self.identity)
        _ = try await output(["update-ref", "-m", "focus-queue decision checkpoint", ref, commit], in: top)
        var checkpoint = DecisionCheckpoint(commit: commit, parent: head, branch: branch, ref: ref, workspace: top,
                                            remote: await remote(in: top, branch: branch))
        if push { checkpoint = await self.push(checkpoint) }
        return checkpoint
    }

    /// Pushes a checkpoint's ref to its remote; records the time or the error.
    public func push(_ checkpoint: DecisionCheckpoint) async -> DecisionCheckpoint {
        var result = checkpoint
        guard let remote = checkpoint.remote else {
            result.pushError = "The repository has no remote to push to."
            return result
        }
        do {
            let pushed = try await runner.run(.init(
                executable: Self.git,
                arguments: ["push", "--quiet", remote, "\(checkpoint.commit):\(checkpoint.ref)"],
                workingDirectory: checkpoint.workspace,
                environment: ["GIT_TERMINAL_PROMPT": "0", "GCM_INTERACTIVE": "never"],
                timeoutSeconds: 120))
            if pushed.succeeded {
                result.pushedAt = DecisionTreeStore.timestamp()
                result.pushError = nil
            } else {
                let reason = pushed.timedOut ? "timed out after 120 seconds" : Self.firstLines(pushed.standardError)
                result.pushError = "git push \(remote) \(checkpoint.ref) failed: \(reason)"
            }
        } catch {
            result.pushError = "git push failed: \(error.localizedDescription)"
        }
        return result
    }

    // MARK: Restore

    /// Saves the current worktree under `preserving`, then makes the worktree
    /// match `checkpoint`. The branch moves back to the checkpoint's parent only
    /// when every commit it drops is unpublished and the branch is not an
    /// integration branch; otherwise the restored files become uncommitted
    /// changes on the current head, so no published history is rewritten.
    public func restore(workspace: String, to checkpoint: DecisionCheckpoint, preserving ref: String,
                        message: String, push: Bool) async throws -> RestoreResult {
        let top = try await output(["rev-parse", "--show-toplevel"], in: workspace)
        let branch = try? await output(["symbolic-ref", "--short", "-q", "HEAD"], in: top)
        let integration = await defaultBranch(in: top)
        if let branch, Self.integrationBranches.contains(branch) || branch == integration {
            throw DecisionTreeError.notAllowed("\(top) has the integration branch \(branch) checked out. Rewinds run only in an agent's own worktree.")
        }
        try await ensureCommit(checkpoint, in: top)
        let saved = try await self.checkpoint(workspace: top, ref: ref, message: message, push: push)
        var movedBranch = false
        var note: String?
        if let parent = checkpoint.parent, let head = saved.parent, parent != head {
            if branch == nil {
                note = "The worktree has a detached head, so only its files were restored."
            } else if branch != checkpoint.branch {
                note = "The worktree is on \(branch ?? "?"), not \(checkpoint.branch ?? "the checkpoint's branch"), so only its files were restored."
            } else if !(await isAncestor(parent, of: head, in: top)) {
                note = "The branch no longer contains the checkpoint's commit, so only its files were restored."
            } else if let published = await firstPublishedCommit(after: parent, upTo: head, in: top) {
                note = "Commit \(published.prefix(10)) after the decision is already on a remote, so the branch kept its history and the restored files are uncommitted changes."
            } else {
                _ = try await output(["reset", "--soft", parent], in: top)
                movedBranch = true
            }
        }
        // Index and files to the checkpoint, untracked leftovers out, then the index back to HEAD.
        _ = try await output(["read-tree", "--reset", "-u", checkpoint.commit], in: top, timeout: 300)
        _ = try await output(["clean", "-f", "-d", "-q"], in: top, timeout: 300)
        _ = try await output(["reset", "-q"], in: top, timeout: 300)
        return RestoreResult(saved: saved, movedBranch: movedBranch, branchNote: note)
    }

    /// The checkpoint commit, fetched back from the remote when the local ref is gone.
    func ensureCommit(_ checkpoint: DecisionCheckpoint, in top: String) async throws {
        if (try? await output(["cat-file", "-e", "\(checkpoint.commit)^{commit}"], in: top)) != nil { return }
        if let remote = checkpoint.remote {
            _ = try? await output(["fetch", "--quiet", remote, "+\(checkpoint.ref):\(checkpoint.ref)"], in: top,
                                  environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: 120)
            if (try? await output(["cat-file", "-e", "\(checkpoint.commit)^{commit}"], in: top)) != nil { return }
        }
        throw DecisionTreeError.notAllowed("Checkpoint \(checkpoint.shortCommit) is missing locally and could not be fetched from \(checkpoint.remote ?? "a remote").")
    }

    // MARK: Queries

    public func status(workspace: String) async -> String? {
        try? await output(["status", "--porcelain"], in: workspace)
    }

    func remote(in top: String, branch: String?) async -> String? {
        if let branch, let configured = try? await output(["config", "--get", "branch.\(branch).remote"], in: top),
           !configured.isEmpty, configured != "." {
            return configured
        }
        let remotes = ((try? await output(["remote"], in: top)) ?? "")
            .split(separator: "\n").map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    func defaultBranch(in top: String) async -> String? {
        guard let remote = await remote(in: top, branch: nil),
              let symbolic = try? await output(["symbolic-ref", "-q", "--short", "refs/remotes/\(remote)/HEAD"], in: top)
        else { return nil }
        return symbolic.split(separator: "/", maxSplits: 1).last.map(String.init)
    }

    func isAncestor(_ ancestor: String, of descendant: String, in top: String) async -> Bool {
        guard let result = try? await runner.run(.init(executable: Self.git,
            arguments: ["merge-base", "--is-ancestor", ancestor, descendant], workingDirectory: top)) else { return false }
        return result.succeeded
    }

    /// The first commit in `parent..head` that any remote-tracking ref already contains.
    func firstPublishedCommit(after parent: String, upTo head: String, in top: String) async -> String? {
        let all = ((try? await output(["rev-list", "\(parent)..\(head)"], in: top)) ?? "")
            .split(separator: "\n").map(String.init)
        guard !all.isEmpty else { return nil }
        let unpublished = Set(((try? await output(["rev-list", head, "^\(parent)", "--not", "--remotes"], in: top)) ?? "")
            .split(separator: "\n").map(String.init))
        return all.first { !unpublished.contains($0) }
    }

    // MARK: Running git

    @discardableResult
    func output(_ arguments: [String], in directory: String, environment: [String: String]? = nil,
                timeout: Int = 60) async throws -> String {
        let result = try await runner.run(.init(executable: Self.git, arguments: arguments, workingDirectory: directory,
                                                environment: environment, timeoutSeconds: timeout,
                                                maximumOutputBytes: 4_000_000))
        guard result.succeeded else {
            let reason = result.timedOut ? "timed out" : Self.firstLines(result.standardError)
            throw TaskContextError.commandFailed("git \(arguments.prefix(2).joined(separator: " ")) failed in \(directory): \(reason)")
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func firstLines(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.prefix(3).joined(separator: " ")
    }
}
