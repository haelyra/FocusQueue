import Foundation

/// Lists the files task search matches by name: everything in a task's
/// context folder, and, as a fallback, the files a task's own worktrees added
/// or changed.
public enum TaskSearchFiles {
  /// Files listed per context folder or worktree; the newest are kept.
  public static let scanLimit = 2_000

  /// Snapshot copies of files already listed, plus dependency caches.
  static let skippedDirectories: Set<String> = [
    "archive", "maintenance-history", "node_modules", "__pycache__", ".git",
  ]

  /// Every regular file in a context folder, newest first: plans, logs, and
  /// outputs alike. Lock files and archived snapshots are skipped.
  public static func contextFiles(
    _ directory: URL, limit: Int = scanLimit, files: FileManager = .default
  ) -> [TaskOutputFile] {
    let base = directory.standardizedFileURL.path
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
    guard let enumerator = files.enumerator(
      at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else { return [] }
    var found: [TaskOutputFile] = []
    for case let url as URL in enumerator {
      guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
      let name = url.lastPathComponent
      if values.isDirectory == true {
        if skippedDirectories.contains(name) || enumerator.level > 6 { enumerator.skipDescendants() }
        continue
      }
      let path = url.standardizedFileURL.path
      guard values.isRegularFile == true, !name.hasSuffix(".lock"), path.hasPrefix(base + "/") else { continue }
      found.append(TaskOutputFile(relativePath: String(path.dropFirst(base.count + 1)),
        url: URL(fileURLWithPath: path), modifiedAt: values.contentModificationDate ?? .distantPast))
      if found.count >= limit { break }
    }
    return found.sorted { ($0.modifiedAt, $1.relativePath) > ($1.modifiedAt, $0.relativePath) }
  }

  /// A checkout that belongs to one task, with what it branched from.
  public struct Worktree: Equatable, Sendable {
    public let path: String
    public let baseCommit: String?
    public let baseBranch: String?

    public init(path: String, baseCommit: String? = nil, baseBranch: String? = nil) {
      self.path = path
      self.baseCommit = baseCommit
      self.baseBranch = baseBranch
    }
  }

  /// Worktrees used by exactly one task, by task ID. A checkout shared by
  /// several tasks, or a project's own repository, would match every task
  /// that touched it, so it is left out.
  public static func uniqueWorktrees(_ contexts: [TaskContext]) -> [String: [Worktree]] {
    var byPath: [String: (owners: Set<String>, worktree: Worktree)] = [:]
    var repositories = Set<String>()
    // An empty path would resolve to the current directory, so it is skipped.
    func addRepository(_ path: String?) {
      guard let path, !path.isEmpty else { return }
      repositories.insert(URL(fileURLWithPath: path).standardizedFileURL.path)
    }
    func add(_ path: String?, _ ticketID: String, base: String?, branch: String?) {
      guard let path, !path.isEmpty else { return }
      let key = URL(fileURLWithPath: path).standardizedFileURL.path
      var entry = byPath[key] ?? ([], Worktree(path: key, baseCommit: base, baseBranch: branch))
      entry.owners.insert(ticketID)
      if entry.worktree.baseCommit == nil, base != nil {
        entry.worktree = Worktree(path: key, baseCommit: base, baseBranch: branch ?? entry.worktree.baseBranch)
      }
      byPath[key] = entry
    }
    for context in contexts {
      addRepository(context.projectRepositoryPath)
      addRepository(context.repositoryPath)
      add(context.worktreePath, context.ticketID, base: nil, branch: context.baseBranch)
      for subtask in context.subtasks {
        for workspace in [subtask.workspace].compactMap({ $0 }) + subtask.workspaceHistory {
          // A workspace may name itself as its repository; that is not a shared checkout.
          if workspace.repositoryPath != workspace.path { addRepository(workspace.repositoryPath) }
          add(workspace.path, context.ticketID, base: workspace.baseCommit, branch: workspace.baseBranch)
        }
      }
    }
    var result: [String: [Worktree]] = [:]
    for (path, entry) in byPath.sorted(by: { $0.key < $1.key })
    where entry.owners.count == 1 && !repositories.contains(path) {
      result[entry.owners.first!, default: []].append(entry.worktree)
    }
    return result
  }

  /// Files a worktree added or changed since its base, plus untracked files
  /// git does not ignore. Without a base, only uncommitted work is listed.
  public static func worktreeFiles(
    _ worktree: Worktree, runner: any ProcessRunning = FoundationProcessRunner(), limit: Int = scanLimit
  ) async -> [TaskOutputFile] {
    let path = worktree.path
    guard FileManager.default.fileExists(atPath: path + "/.git") else { return [] }
    func git(_ arguments: [String]) async -> String? {
      let result = try? await runner.run(.init(executable: "/usr/bin/git", arguments: ["-C", path] + arguments,
        timeoutSeconds: 15, maximumOutputBytes: 4_000_000))
      return result?.succeeded == true ? result?.standardOutput : nil
    }
    var base: String?
    if let commit = worktree.baseCommit, await git(["cat-file", "-e", commit + "^{commit}"]) != nil {
      base = commit
    } else if let branch = worktree.baseBranch {
      for candidate in [branch, "origin/" + branch] {
        if let found = await git(["merge-base", "HEAD", candidate]) {
          base = found.trimmingCharacters(in: .whitespacesAndNewlines)
          break
        }
      }
    }
    let changed = await git(["diff", "--name-only", "--diff-filter=d", base ?? "HEAD", "--"]) ?? ""
    let untracked = await git(["ls-files", "--others", "--exclude-standard"]) ?? ""
    var seen = Set<String>()
    var found: [TaskOutputFile] = []
    for relative in (changed + "\n" + untracked).split(separator: "\n").map(String.init)
    where !relative.isEmpty && seen.insert(relative).inserted {
      let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
      guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
        values.isRegularFile == true else { continue }
      found.append(TaskOutputFile(relativePath: relative, url: url,
        modifiedAt: values.contentModificationDate ?? .distantPast))
    }
    return Array(found.sorted { ($0.modifiedAt, $1.relativePath) > ($1.modifiedAt, $0.relativePath) }.prefix(limit))
  }
}

/// Files outside a task's context folder that the user viewed in the task's
/// plan viewer, such as a worktree file opened from search. Kept in the
/// context folder so search finds them there next time.
public enum TaskLinkedFiles {
  public static let fileName = "linked-files.json"
  /// The most recently viewed files kept per task.
  public static let limit = 200

  public struct Entry: Codable, Equatable, Sendable {
    /// Absolute path of the file.
    public var path: String
    /// What search matches and shows: the path inside its worktree when known.
    public var displayPath: String
    public var viewedAt: Date

    public init(path: String, displayPath: String, viewedAt: Date) {
      self.path = path
      self.displayPath = displayPath
      self.viewedAt = viewedAt
    }
  }

  private struct Record: Codable {
    var schemaVersion = 1
    var files: [Entry]
  }

  public static func url(in contextDirectory: URL) -> URL {
    contextDirectory.appendingPathComponent(fileName)
  }

  /// Linked files, most recently viewed first. A damaged record reads as empty.
  public static func load(_ contextDirectory: URL) -> [Entry] {
    guard let data = try? Data(contentsOf: url(in: contextDirectory)),
      let record = try? JSONDecoder().decode(Record.self, from: data) else { return [] }
    return record.files
  }

  /// Records a view, moving a known file to the front. Returns false when
  /// the file was already first, so callers can skip a rescan.
  @discardableResult
  public static func record(
    _ file: URL, displayPath: String, in contextDirectory: URL, at date: Date = Date()
  ) throws -> Bool {
    let path = file.standardizedFileURL.path
    var files = load(contextDirectory)
    if files.first?.path == path, files.first?.displayPath == displayPath { return false }
    files.removeAll { $0.path == path }
    files.insert(Entry(path: path, displayPath: displayPath, viewedAt: date), at: 0)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Record(files: Array(files.prefix(limit)))).write(to: url(in: contextDirectory), options: .atomic)
    return true
  }

  /// Linked files that still exist, as search entries keyed by display path.
  public static func searchFiles(_ contextDirectory: URL) -> [TaskOutputFile] {
    load(contextDirectory).compactMap { entry in
      guard FileManager.default.fileExists(atPath: entry.path) else { return nil }
      return TaskOutputFile(relativePath: entry.displayPath, url: URL(fileURLWithPath: entry.path),
        modifiedAt: entry.viewedAt)
    }
  }
}
