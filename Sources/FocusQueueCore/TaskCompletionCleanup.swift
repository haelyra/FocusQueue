import Darwin
import Foundation

public struct WorktreeRetirement: Codable, Equatable, Sendable {
    public var path: String
    public var repositoryPath: String
    public var branch: String?
    public var head: String?
    public var dirty = false
    public var integrated = false
    public var archiveRef: String?
    public var archivedCommit: String?
    public var removedBuildOutput: [String] = []
    public var stagedPath: String?
    public var outcome = ""

    public init(path: String, repositoryPath: String) {
        self.path = path; self.repositoryPath = repositoryPath
    }
}

public struct BranchRetirement: Codable, Equatable, Sendable {
    public var name: String
    public var repositoryPath: String
    public var head: String?
    public var integrated = false
    public var archiveRef: String?
    public var localDeleted = false
    public var remoteHead: String?
    public var remoteDeleted = false
    public var outcome = ""

    public init(name: String, repositoryPath: String, remoteHead: String? = nil) {
        self.name = name; self.repositoryPath = repositoryPath; self.remoteHead = remoteHead
    }
}

/// Written beside every staged item so purging and manual recovery need no
/// other record. `purgeAfter` decides deletion; directory dates never do.
public struct StagingManifest: Codable, Equatable, Sendable {
    public var kind: String
    public var ticketID: String
    public var originalPath: String
    public var stagedPath: String
    public var repositoryPath: String?
    public var branch: String?
    public var head: String?
    public var archiveRef: String?
    public var archivedCommit: String?
    public var gitAdministration: String?
    public var stagedAt: Date
    public var purgeAfter: Date

    public init(kind: String, ticketID: String, originalPath: String, stagedPath: String,
                repositoryPath: String? = nil, branch: String? = nil, head: String? = nil,
                archiveRef: String? = nil, archivedCommit: String? = nil, gitAdministration: String? = nil,
                stagedAt: Date, purgeAfter: Date) {
        self.kind = kind; self.ticketID = ticketID; self.originalPath = originalPath
        self.stagedPath = stagedPath; self.repositoryPath = repositoryPath; self.branch = branch
        self.head = head; self.archiveRef = archiveRef; self.archivedCommit = archivedCommit
        self.gitAdministration = gitAdministration; self.stagedAt = stagedAt; self.purgeAfter = purgeAfter
    }
}

public struct TaskCleanupReport: Codable, Equatable, Sendable {
    public var ticketID: String
    public var dryRun: Bool
    public var finishedAt: Date
    public var tmuxSessions: [String] = []
    public var worktrees: [WorktreeRetirement] = []
    public var stagedCheckouts: [String] = []
    public var branches: [BranchRetirement] = []
    public var stagedData: [String] = []
    public var notes: [String] = []
    public var problems: [String] = []

    public init(ticketID: String, dryRun: Bool, finishedAt: Date) {
        self.ticketID = ticketID; self.dryRun = dryRun; self.finishedAt = finishedAt
    }

    public var isClean: Bool { problems.isEmpty }

    public var summary: String {
        let verb = dryRun ? "Would clean" : "Cleaned"
        var parts: [String] = []
        if !tmuxSessions.isEmpty { parts.append("\(tmuxSessions.count) tmux session\(tmuxSessions.count == 1 ? "" : "s")") }
        let staged = worktrees.count + stagedCheckouts.count
        if staged > 0 { parts.append("\(staged) worktree\(staged == 1 ? "" : "s")") }
        let deleted = branches.filter { dryRun || $0.localDeleted || $0.remoteDeleted }.count
        if deleted > 0 { parts.append("\(deleted) branch\(deleted == 1 ? "" : "es")") }
        let archived = (worktrees.compactMap(\.archiveRef) + branches.compactMap(\.archiveRef)).count
        var text = parts.isEmpty ? "Nothing left to clean." : "\(verb) \(parts.joined(separator: ", "))."
        if archived > 0 { text += " Unmerged work archived under \(TaskWorktreeManager.archiveRefPrefix)." }
        if let problem = problems.first {
            text += " Needs attention: \(problem)" + (problems.count > 1 ? " (+\(problems.count - 1) more)" : "")
        }
        return text
    }
}

/// Marking a task complete authorizes removing its runtime: the tmux session
/// stops, worktrees move to a 7-day trash, branches are deleted after their work
/// is integrated or archived, and bulky task history is staged. Plans, logs, and
/// task data stay so the Completed tab keeps its details.
public actor TaskCompletionCleanup {
    public static let stagingRetention: TimeInterval = 7 * 24 * 60 * 60
    public static let reportName = "cleanup.json"
    public static let stagedTaskFolders = ["archive", "maintenance-history"]

    private let root: URL
    private let projectRepositories: [String]
    private let runner: any ProcessRunning
    private let worktrees: TaskWorktreeManager
    private let tmuxExecutable: String?
    private let tmuxServer: String
    private let remoteName: String
    private let environment: [String: String]

    public init(root: URL, projectRepositories: [String] = [], tmuxExecutable: String? = nil,
                runner: any ProcessRunning = FoundationProcessRunner(),
                tmuxServer: String = TmuxController.serverName, remoteName: String = "origin",
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.root = root
        self.projectRepositories = projectRepositories
        self.runner = runner
        self.worktrees = TaskWorktreeManager(runner: runner)
        self.tmuxExecutable = tmuxExecutable
        self.tmuxServer = tmuxServer
        self.remoteName = remoteName
        self.environment = environment
    }

    public static func savedReport(ticketID: String, root: URL) -> TaskCleanupReport? {
        let url = root.appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(ticketID.uppercased(), isDirectory: true)
            .appendingPathComponent(reportName)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode(TaskCleanupReport.self, from: $0) }
    }

    public func run(ticketID rawTicketID: String, dryRun: Bool = false, now: Date = Date()) async -> TaskCleanupReport {
        let ticketID = rawTicketID.uppercased()
        var report = TaskCleanupReport(ticketID: ticketID, dryRun: dryRun, finishedAt: now)
        let lease: TaskMaintenance.Lease
        do { lease = try await TaskMaintenance.lease(ticketID: ticketID, root: root) }
        catch { report.problems.append("Task lock: \(error.localizedDescription)"); return report }
        defer { lease.release() }
        let store = TaskContextStore(root: root)
        let context = (try? await store.load(ticketID: ticketID)) ?? nil

        // Stop agents first so nothing writes into a workspace being staged.
        let ownSession = await currentTmuxSession()
        var deferredSession: String?
        let liveSessions = await tmuxSessions()
        for name in Self.sessionNames(ticketID: ticketID, context: context) where liveSessions.contains(name) {
            report.tmuxSessions.append(name)
            guard !dryRun else { continue }
            if name == ownSession { deferredSession = name; continue }
            if let failure = await tmux(["kill-session", "-t", "=" + name]) {
                report.problems.append("tmux \(name): \(failure)")
            }
        }

        for repository in await repositories(for: context) {
            await retire(ticketID: ticketID, repository: repository, context: context, dryRun: dryRun, now: now, report: &report)
        }

        if let context {
            let folder = context.contextDirectory
            let present = Self.stagedTaskFolders.filter {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
            }
            if dryRun {
                report.stagedData = present.map { folder.appendingPathComponent($0).path }
            } else if !present.isEmpty {
                do { report.stagedData = try stageTaskFolders(present, of: folder, ticketID: ticketID, now: now) }
                catch { report.problems.append("Task history: \(error.localizedDescription)") }
            }
            if !dryRun {
                do { _ = try await store.recordCompletionCleanup(ticketID: ticketID) }
                catch { report.problems.append("Task record: \(error.localizedDescription)") }
            }
        }

        report.finishedAt = Date()
        if !dryRun { save(report, folder: context?.contextDirectory) }
        // A CLI run from inside the task's own session would end with it.
        if let deferredSession, let failure = await tmux(["run-shell", "-b", "-d", "2", "-C",
                                                          "kill-session -t =\(deferredSession)"]) {
            report.problems.append("tmux \(deferredSession): \(failure)")
        }
        return report
    }

    /// Worktrees and branches left by tasks that no open ticket owns. A
    /// worktree that is any live process's current directory is retained.
    public func sweepOrphans(openTicketIDs: Set<String>, dryRun: Bool, now: Date = Date()) async -> TaskCleanupReport {
        var report = TaskCleanupReport(ticketID: "ORPHANS", dryRun: dryRun, finishedAt: now)
        let open = Set(openTicketIDs.map { $0.lowercased() })
        let liveDirectories = await processDirectories()
        for repository in await repositories(for: nil) {
            let targets = await integrationTargets(repository: repository, context: nil, report: &report)
            let entries = await worktreeEntries(repository: repository)
            var retiredBranches = Set<String>()
            for managedRoot in TaskWorktreeManager.managedRoots(repositoryPath: repository) {
                let names = (try? FileManager.default.contentsOfDirectory(atPath: managedRoot.path)) ?? []
                for name in names.sorted() where !name.hasPrefix(".") && !open.contains(name.lowercased()) {
                    let folder = managedRoot.appendingPathComponent(name, isDirectory: true)
                    for entry in entries where !entry.prunable && (entry.path.hasPrefix(folder.path + "/") || entry.path == folder.path) {
                        if liveDirectories.contains(where: { $0 == entry.path || $0.hasPrefix(entry.path + "/") }) {
                            report.notes.append("Kept \(entry.path): a running process uses it.")
                            continue
                        }
                        do {
                            let record = try await worktrees.retireWorktree(path: entry.path, repositoryPath: repository,
                                ticketID: name, integrationTargets: targets, dryRun: dryRun, now: now)
                            report.worktrees.append(record)
                            if let branch = record.branch { retiredBranches.insert(branch) }
                        } catch { report.problems.append("Worktree \(entry.path): \(error.localizedDescription)") }
                    }
                    do {
                        report.stagedCheckouts += try await worktrees.stageRetainedCheckouts(
                            under: folder, repositoryPath: repository, ticketID: name, dryRun: dryRun, now: now)
                    } catch { report.problems.append("Retained checkouts in \(folder.path): \(error.localizedDescription)") }
                }
            }
            if entries.contains(where: \.prunable), !dryRun { _ = try? await git(["worktree", "prune"], in: repository) }
            let protected = await protectedBranches(repository: repository, context: nil)
            let remoteHeads = await remoteBranches(repository: repository, report: &report)
            let local = await localBranches(repository: repository)
            let candidates = Set((local + Array(remoteHeads.keys)).filter { name in
                guard !protected.contains(name) else { return false }
                if retiredBranches.contains(name) { return true }
                guard name.hasPrefix("focus-queue/") else { return false }
                let ticket = Self.ticketComponent(ofBranch: name)
                return ticket.map { !open.contains($0) } ?? false
            })
            for name in candidates.sorted() {
                do {
                    report.branches.append(try await worktrees.retireBranch(name, repositoryPath: repository,
                        integrationTargets: targets, remote: remoteHeads.isEmpty ? nil : remoteName,
                        remoteHead: remoteHeads[name], dryRun: dryRun))
                } catch { report.problems.append("Branch \(name): \(error.localizedDescription)") }
            }
        }
        report.finishedAt = Date()
        return report
    }

    /// Deletes staged items whose retention window has passed.
    public func purgeExpiredStaging(now: Date = Date()) async -> [String] {
        var folders = [root.appendingPathComponent("trash", isDirectory: true)]
        for repository in await repositories(for: nil) {
            folders += TaskWorktreeManager.managedRoots(repositoryPath: repository)
                .map { $0.appendingPathComponent(TaskWorktreeManager.trashDirectoryName, isDirectory: true) }
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var purged: [String] = []
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where name.hasSuffix(".json") {
                let manifestURL = folder.appendingPathComponent(name)
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? decoder.decode(StagingManifest.self, from: data),
                      manifest.purgeAfter <= now else { continue }
                let item = folder.appendingPathComponent(String(name.dropLast(".json".count)), isDirectory: true)
                // The manifest names its own item; never follow a path elsewhere.
                guard manifest.stagedPath == item.path else { continue }
                do {
                    if FileManager.default.fileExists(atPath: item.path) { try FileManager.default.removeItem(at: item) }
                    if let admin = manifest.gitAdministration,
                       URL(fileURLWithPath: admin).deletingLastPathComponent().lastPathComponent == "focus-queue-retired-worktrees" {
                        try? FileManager.default.removeItem(atPath: admin)
                    }
                    try FileManager.default.removeItem(at: manifestURL)
                    purged.append(item.path)
                } catch { continue }
            }
        }
        return purged
    }

    // MARK: - Per repository

    private func retire(ticketID: String, repository: String, context: TaskContext?, dryRun: Bool, now: Date,
                        report: inout TaskCleanupReport) async {
        let targets = await integrationTargets(repository: repository, context: context, report: &report)
        let entries = await worktreeEntries(repository: repository)
        let folders = TaskWorktreeManager.managedRoots(repositoryPath: repository)
            .map { $0.appendingPathComponent(ticketID.lowercased(), isDirectory: true).path }
        var retiredBranches = Set<String>()
        for entry in entries {
            let managed = folders.contains { entry.path.hasPrefix($0 + "/") }
            let owned = entry.branch.map { TaskWorktreeManager.ownsBranch($0, ticketID: ticketID) } ?? false
            guard managed || owned, !entry.prunable else { continue }
            guard managed else {
                report.problems.append("Branch \(entry.branch ?? "") is checked out at \(entry.path), outside Focus Queue's managed folder; left in place.")
                continue
            }
            do {
                let record = try await worktrees.retireWorktree(path: entry.path, repositoryPath: repository,
                    ticketID: ticketID, integrationTargets: targets, dryRun: dryRun, now: now)
                report.worktrees.append(record)
                if let branch = record.branch { retiredBranches.insert(branch) }
            } catch { report.problems.append("Worktree \(entry.path): \(error.localizedDescription)") }
        }
        if entries.contains(where: { $0.prunable && folders.contains(where: $0.path.hasPrefix) }), !dryRun {
            _ = try? await git(["worktree", "prune"], in: repository)
        }
        for folder in folders {
            do {
                report.stagedCheckouts += try await worktrees.stageRetainedCheckouts(
                    under: URL(fileURLWithPath: folder, isDirectory: true), repositoryPath: repository,
                    ticketID: ticketID, dryRun: dryRun, now: now)
            } catch { report.problems.append("Retained checkouts in \(folder): \(error.localizedDescription)") }
        }
        let protected = await protectedBranches(repository: repository, context: context)
        let remoteHeads = await remoteBranches(repository: repository, report: &report)
        let local = await localBranches(repository: repository)
        let candidates = Set((local + Array(remoteHeads.keys)).filter {
            !protected.contains($0) && (TaskWorktreeManager.ownsBranch($0, ticketID: ticketID) || retiredBranches.contains($0))
        })
        for name in candidates.sorted() {
            do {
                report.branches.append(try await worktrees.retireBranch(name, repositoryPath: repository,
                    integrationTargets: targets, remote: remoteHeads.isEmpty ? nil : remoteName,
                    remoteHead: remoteHeads[name], dryRun: dryRun))
            } catch { report.problems.append("Branch \(name): \(error.localizedDescription)") }
        }
    }

    private struct WorktreeEntry {
        var path: String
        var branch: String?
        var prunable = false
    }

    private func worktreeEntries(repository: String) async -> [WorktreeEntry] {
        guard let output = try? await git(["worktree", "list", "--porcelain"], in: repository) else { return [] }
        var entries: [WorktreeEntry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                entries.append(WorktreeEntry(path: URL(fileURLWithPath: String(line.dropFirst(9))).standardizedFileURL.path))
            } else if line.hasPrefix("branch refs/heads/"), !entries.isEmpty {
                entries[entries.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("prunable"), !entries.isEmpty {
                entries[entries.count - 1].prunable = true
            }
        }
        return entries
    }

    /// Fetching first lets work merged on the remote count as integrated even
    /// when the local base branch has not been pulled.
    private func integrationTargets(repository: String, context: TaskContext?,
                                    report: inout TaskCleanupReport) async -> [String] {
        let remotes = (try? await git(["remote"], in: repository))?.split(separator: "\n").map(String.init) ?? []
        if remotes.contains(remoteName) {
            let fetched = try? await runner.run(.init(executable: "/usr/bin/git",
                arguments: ["fetch", "--quiet", "--prune", "--no-tags", remoteName],
                workingDirectory: repository, timeoutSeconds: 120))
            if fetched?.succeeded != true {
                let note = "Could not fetch \(remoteName) for \(repository); merge checks used local refs."
                if !report.notes.contains(note) { report.notes.append(note) }
            }
        }
        var targets: [String] = []
        for base in await baseBranches(repository: repository, context: context) {
            for ref in ["refs/heads/\(base)", "refs/remotes/\(remoteName)/\(base)"] {
                let exists = try? await runner.run(.init(executable: "/usr/bin/git",
                    arguments: ["rev-parse", "--verify", "--quiet", ref + "^{commit}"], workingDirectory: repository))
                if exists?.succeeded == true { targets.append(ref) }
            }
        }
        return targets
    }

    private func baseBranches(repository: String, context: TaskContext?) async -> [String] {
        var bases: [String] = []
        if let base = context?.baseBranch { bases.append(base) }
        for subtask in context?.subtasks ?? [] {
            bases += ([subtask.workspace] + subtask.workspaceHistory).compactMap { $0?.baseBranch }
        }
        if let head = try? await git(["symbolic-ref", "--quiet", "--short", "refs/remotes/\(remoteName)/HEAD"], in: repository) {
            let name = head.trimmingCharacters(in: .whitespacesAndNewlines)
            bases.append(String(name.dropFirst(remoteName.count + 1)))
        }
        bases += ["main", "master"]
        var seen = Set<String>()
        return bases.filter { !$0.isEmpty && !$0.hasPrefix("focus-queue/") && seen.insert($0).inserted }
    }

    private func protectedBranches(repository: String, context: TaskContext?) async -> Set<String> {
        var names = Set(await baseBranches(repository: repository, context: context))
        if let current = try? await git(["symbolic-ref", "--quiet", "--short", "HEAD"], in: repository) {
            names.insert(current.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return names
    }

    private func localBranches(repository: String) async -> [String] {
        let output = (try? await git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: repository)) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    private func remoteBranches(repository: String, report: inout TaskCleanupReport) async -> [String: String] {
        let remotes = (try? await git(["remote"], in: repository))?.split(separator: "\n").map(String.init) ?? []
        guard remotes.contains(remoteName) else { return [:] }
        guard let result = try? await runner.run(.init(executable: "/usr/bin/git",
                arguments: ["ls-remote", "--heads", remoteName], workingDirectory: repository, timeoutSeconds: 60)),
              result.succeeded else {
            let note = "Could not list \(remoteName) branches for \(repository); remote branches were left in place."
            if !report.notes.contains(note) { report.notes.append(note) }
            return [:]
        }
        var heads: [String: String] = [:]
        for line in result.standardOutput.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[1].hasPrefix("refs/heads/") else { continue }
            heads[String(fields[1].dropFirst("refs/heads/".count))] = String(fields[0])
        }
        return heads
    }

    private func repositories(for context: TaskContext?) async -> [String] {
        var candidates = projectRepositories
        if let context {
            candidates += [context.repositoryPath, context.projectRepositoryPath].compactMap { $0 }
            for subtask in context.subtasks {
                candidates += ([subtask.workspace] + subtask.workspaceHistory).compactMap { $0?.repositoryPath }
            }
        }
        var seen = Set<String>()
        var repositories: [String] = []
        for candidate in candidates where !candidate.isEmpty && FileManager.default.fileExists(atPath: candidate) {
            guard let primary = try? await worktrees.primaryRepositoryPath(of: candidate),
                  seen.insert(primary).inserted else { continue }
            repositories.append(primary)
        }
        return repositories
    }

    // MARK: - tmux

    static func sessionNames(ticketID: String, context: TaskContext?) -> [String] {
        var names = [try? TmuxController.taskSessionName(taskID: ticketID)].compactMap { $0 }
        for subtask in context?.subtasks ?? [] {
            names += [try? TmuxController.sessionName(subtaskID: subtask.id), subtask.tmux?.name].compactMap { $0 }
        }
        var seen = Set<String>()
        return names.filter { $0.hasPrefix("fq-") && seen.insert($0).inserted }
    }

    private var resolvedTmux: String? {
        ([tmuxExecutable].compactMap { $0 } + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Returns an error description, or nil on success.
    private func tmux(_ arguments: [String]) async -> String? {
        guard let executable = resolvedTmux else { return "tmux is not installed." }
        do {
            let result = try await runner.run(.init(executable: executable,
                arguments: ["-f", "/dev/null", "-L", tmuxServer] + arguments,
                environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10))
            return result.succeeded ? nil : (result.standardError.isEmpty ? "tmux failed." : result.standardError)
        } catch { return error.localizedDescription }
    }

    private func tmuxSessions() async -> Set<String> {
        guard let executable = resolvedTmux,
              let result = try? await runner.run(.init(executable: executable,
                arguments: ["-f", "/dev/null", "-L", tmuxServer, "list-sessions", "-F", "#{session_name}"],
                environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10)),
              result.succeeded else { return [] }
        return Set(result.standardOutput.split(separator: "\n").map(String.init))
    }

    private func currentTmuxSession() async -> String? {
        guard let socket = environment["TMUX"], socket.split(separator: ",").first?.hasSuffix("/" + tmuxServer) == true,
              let pane = environment["TMUX_PANE"], let executable = resolvedTmux,
              let result = try? await runner.run(.init(executable: executable,
                arguments: ["-f", "/dev/null", "-L", tmuxServer, "display-message", "-p", "-t", pane, "#{session_name}"],
                environment: ["TMUX_TMPDIR": "/tmp"], timeoutSeconds: 10)),
              result.succeeded else { return nil }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func processDirectories() async -> [String] {
        guard let result = try? await runner.run(.init(executable: "/usr/sbin/lsof",
                arguments: ["-a", "-d", "cwd", "-u", String(getuid()), "-Fn"], timeoutSeconds: 30,
                maximumOutputBytes: 4_000_000)) else { return [] }
        return result.standardOutput.split(separator: "\n").filter { $0.hasPrefix("n/") }
            .map { URL(fileURLWithPath: String($0.dropFirst())).standardizedFileURL.path }
    }

    /// `focus-queue/foc-043-<agent>` → `foc-043`.
    static func ticketComponent(ofBranch name: String) -> String? {
        let leaf = name.dropFirst("focus-queue/".count).lowercased()
        guard let match = leaf.range(of: "^[a-z][a-z0-9]*-[0-9]+", options: .regularExpression) else { return nil }
        return String(leaf[match])
    }

    private func stageTaskFolders(_ names: [String], of folder: URL, ticketID: String, now: Date) throws -> [String] {
        let trash = root.appendingPathComponent("trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now)
            .replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "")
        var staged: [String] = []
        for name in names {
            let source = folder.appendingPathComponent(name, isDirectory: true)
            var destination = trash.appendingPathComponent("\(ticketID.lowercased())-\(name)-\(stamp)", isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                destination = trash.appendingPathComponent(destination.lastPathComponent + "-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            let manifest = StagingManifest(kind: "task-history", ticketID: ticketID, originalPath: source.path,
                stagedPath: destination.path, stagedAt: now, purgeAfter: now.addingTimeInterval(Self.stagingRetention))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(manifest).write(to: destination.appendingPathExtension("json"), options: .atomic)
            staged.append(destination.path)
        }
        return staged
    }

    private func save(_ report: TaskCleanupReport, folder: URL?) {
        let folder = folder ?? root.appendingPathComponent("tasks", isDirectory: true)
            .appendingPathComponent(report.ticketID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(report).write(to: folder.appendingPathComponent(Self.reportName), options: .atomic)
    }

    private func git(_ arguments: [String], in directory: String) async throws -> String {
        let result = try await runner.run(.init(executable: "/usr/bin/git", arguments: arguments, workingDirectory: directory))
        guard result.succeeded else { throw TaskContextError.commandFailed(result.standardError) }
        return result.standardOutput
    }
}
