import Foundation

/// A file an agent saved in a task's context folder for the user to read.
public struct TaskOutputFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: String { relativePath }
    /// Path inside the context folder, the key the user's review is saved under.
    public let relativePath: String
    public let url: URL
    public let modifiedAt: Date

    public init(relativePath: String, url: URL, modifiedAt: Date) {
        self.relativePath = relativePath
        self.url = url
        self.modifiedAt = modifiedAt
    }
}

/// Finds the files in a context folder that agents wrote for the user. Every
/// such file is shown, linked or not; Focus Queue's own records are skipped.
public enum TaskOutputs {
    /// An unopened output stops counting as new after this long.
    public static let freshness: TimeInterval = 3 * 24 * 60 * 60
    public static let scanLimit = 200

    /// Task records, history, and app-generated folders.
    static let ignoredDirectories: Set<String> = [
        "archive", "maintenance-history", "push-reviews", "workspace-map", "architecture",
        "node_modules", "__pycache__",
        // App runtime state: canvas sessions, document chat routes, harness runs.
        "canvas", "document-agents", "documents",
    ]
    /// The walkthrough's demo mockup at the context root. A deeper folder with
    /// this name is an agent's.
    static let ignoredTopLevelDirectories: Set<String> = ["walkthrough"]
    static let ignoredFiles: Set<String> = [
        "plan.md", "data.md", "agent-log.md", TaskContext.initialPromptFileName, "context.json",
        "maintenance.json", TaskCompletionCleanup.reportName, "conversation.json", "plan-draft.json",
    ]

    static func isIgnored(fileName name: String) -> Bool {
        ignoredFiles.contains(name) || name.hasPrefix("context.json.") || name.hasPrefix("completion-review-")
            || name.hasSuffix(".lock") || name.hasSuffix(".pyc")
            // Canvas export sidecars an agent consumes; the artifact itself stays visible.
            || name.hasSuffix(".edits.json") || name.contains(".edited.")
    }

    /// Regular files under `directory`, newest first, at most `limit` of them.
    public static func scan(_ directory: URL, limit: Int = scanLimit, files: FileManager = .default) -> [TaskOutputFile] {
        let base = directory.standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = files.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var outputs: [TaskOutputFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let name = url.lastPathComponent
            if values.isDirectory == true {
                if ignoredDirectories.contains(name) || enumerator.level > 4
                    || (enumerator.level == 1 && ignoredTopLevelDirectories.contains(name)) {
                    enumerator.skipDescendants()
                }
                continue
            }
            let path = url.standardizedFileURL.path
            guard values.isRegularFile == true, !isIgnored(fileName: name), path.hasPrefix(base + "/") else { continue }
            outputs.append(TaskOutputFile(relativePath: String(path.dropFirst(base.count + 1)),
                url: URL(fileURLWithPath: path), modifiedAt: values.contentModificationDate ?? .distantPast))
            if outputs.count >= limit { break }
        }
        return outputs.sorted { ($0.modifiedAt, $1.relativePath) > ($1.modifiedAt, $0.relativePath) }
    }

    /// New means changed after the user last opened or dismissed it, and recently.
    public static func isNew(_ output: TaskOutputFile, reviewed: [String: Date]?, now: Date = Date()) -> Bool {
        guard now.timeIntervalSince(output.modifiedAt) < freshness else { return false }
        guard let seen = reviewed?[output.relativePath] else { return true }
        // Saved dates lose sub-microsecond precision; an edit moves a file by more.
        return output.modifiedAt.timeIntervalSince(seen) > 1
    }
}

extension TaskContext {
    /// Outputs the user has not opened or dismissed since they last changed.
    public func newOutputs(_ outputs: [TaskOutputFile], now: Date = Date()) -> [TaskOutputFile] {
        outputs.filter { TaskOutputs.isNew($0, reviewed: reviewedOutputs, now: now) }
    }
}
