import Foundation

/// One file in a project's module folder. Module design files (`m<N>-<slug>.md`)
/// hold each module's I/O contract; other files there, such as an amendment
/// register or a review log, are shared by every module.
public struct DevelopmentModuleFile: Equatable, Sendable, Identifiable {
    public enum Location: String, Equatable, Sendable {
        /// `docs/modules/` in the project's repository: the source of truth.
        case repository
        /// `modules/` in the project's Focus Queue folder.
        case project
    }

    public var url: URL
    public var location: Location
    /// `m6` for `m6-context-scoped-data.md`; nil for a shared file.
    public var moduleID: String?
    /// The first heading without its `M<n>:` prefix, or the file name.
    public var title: String
    /// The guideline's `**One line:**` text, when the file has one.
    public var oneLine: String
    /// The `**Status:**` line: the file's maturity.
    public var status: String
    /// The other location holds a file with the same name; this one wins.
    public var hasOtherCopy: Bool

    public var id: String { fileName }
    public var fileName: String { url.lastPathComponent }
    public var isModule: Bool { moduleID != nil }
    /// `M6 · Context and scoped data storage`, or the title of a shared file.
    public var displayTitle: String {
        moduleID.map { "\($0.uppercased()) · \(title)" } ?? title
    }

    public init(url: URL, location: Location, moduleID: String? = nil, title: String,
                oneLine: String = "", status: String = "", hasOtherCopy: Bool = false) {
        self.url = url; self.location = location; self.moduleID = moduleID; self.title = title
        self.oneLine = oneLine; self.status = status; self.hasOtherCopy = hasOtherCopy
    }
}

/// Finds a project's module design files wherever they were written, so the
/// Project tab can show them without registration or copies: the project
/// folder's `modules/` and the repository's `docs/modules/`. When both hold a
/// file with the same name, the repository copy wins, per the module guideline.
public enum DevelopmentModuleFiles {
    public static let projectFolderName = "modules"
    public static let repositoryFolderPath = "docs/modules"
    /// Folders are browsed, not crawled: the cap keeps a stray dump cheap.
    static let maximumFiles = 200
    static let headerBytes = 8_192

    /// The module folders, repository first, whether or not they exist yet.
    public static func folders(projectDirectory: URL, repositoryPath: String?)
        -> [(url: URL, location: DevelopmentModuleFile.Location)] {
        var folders: [(URL, DevelopmentModuleFile.Location)] = []
        if let repository = repositoryURL(repositoryPath) {
            folders.append((repository.appendingPathComponent(repositoryFolderPath, isDirectory: true), .repository))
        }
        folders.append((projectDirectory.appendingPathComponent(projectFolderName, isDirectory: true), .project))
        return folders.map { (url: $0.0, location: $0.1) }
    }

    /// The folder to show in Finder: the first that exists, else the project's.
    public static func primaryFolder(projectDirectory: URL, repositoryPath: String?) -> URL {
        let all = folders(projectDirectory: projectDirectory, repositoryPath: repositoryPath)
        return all.first { isDirectory($0.url) }?.url ?? all[all.count - 1].url
    }

    /// Every file in the module folders: modules by number, then shared files by name.
    public static func discover(projectDirectory: URL, repositoryPath: String?) -> [DevelopmentModuleFile] {
        var byName: [String: DevelopmentModuleFile] = [:]
        for folder in folders(projectDirectory: projectDirectory, repositoryPath: repositoryPath) {
            for url in fileURLs(in: folder.url) {
                let name = url.lastPathComponent
                if var existing = byName[name] {
                    existing.hasOtherCopy = true
                    byName[name] = existing
                    continue
                }
                guard byName.count < maximumFiles else { continue }
                byName[name] = file(at: url, location: folder.location)
            }
        }
        return byName.values.sorted(by: order)
    }

    /// Where a registered module's file lives. A relative `modules/<name>` path
    /// resolves to the repository copy first, then the project folder; nil when
    /// neither exists or the path leaves both folders.
    public static func resolve(_ file: String?, projectDirectory: URL, repositoryPath: String?) -> URL? {
        let trimmed = file?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"),
              !trimmed.split(separator: "/").contains("..") else { return nil }
        let name = (trimmed as NSString).lastPathComponent
        var candidates: [URL] = []
        if let repository = repositoryURL(repositoryPath) {
            candidates.append(repository.appendingPathComponent(repositoryFolderPath).appendingPathComponent(name))
        }
        candidates.append(projectDirectory.appendingPathComponent(trimmed))
        candidates.append(projectDirectory.appendingPathComponent(projectFolderName).appendingPathComponent(name))
        return candidates.first(where: isRegularFile)
    }

    /// The registered module a file belongs to: same file name, else same ID.
    public static func module(for file: DevelopmentModuleFile, in modules: [DevelopmentModule]) -> DevelopmentModule? {
        modules.first { ($0.file as NSString?)?.lastPathComponent == file.fileName }
            ?? file.moduleID.flatMap { id in
                modules.first { $0.id.caseInsensitiveCompare(id) == .orderedSame && ($0.file ?? "").isEmpty }
            }
    }

    /// `m6` from `m6-context-scoped-data.md` or `M6_Context.md`.
    public static func moduleID(fileName: String) -> String? {
        let lowered = fileName.lowercased()
        guard lowered.hasSuffix(".md") || lowered.hasSuffix(".markdown"), lowered.hasPrefix("m") else { return nil }
        let digits = lowered.dropFirst().prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let rest = lowered.dropFirst(1 + digits.count)
        guard let next = rest.first, next == "-" || next == "_" || next == "." else { return nil }
        return "m\(Int(digits) ?? 0)"
    }

    // MARK: - Private

    private static func repositoryURL(_ path: String?) -> URL? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    /// Regular, visible files only: symbolic links and lock files never show.
    private static func fileURLs(in folder: URL) -> [URL] {
        guard isDirectory(folder),
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().filter { !$0.hasPrefix(".") }
            .map { folder.appendingPathComponent($0) }
            .filter(isRegularFile)
    }

    private static func file(at url: URL, location: DevelopmentModuleFile.Location) -> DevelopmentModuleFile {
        let header = header(of: url)
        let id = moduleID(fileName: url.lastPathComponent) ?? header.moduleID
        let fallback = (url.lastPathComponent as NSString).deletingPathExtension
        return DevelopmentModuleFile(
            url: url, location: location, moduleID: id,
            title: header.title.isEmpty ? fallback : header.title,
            oneLine: header.oneLine, status: header.status)
    }

    /// The heading, one line, and status from the first 8 KB of a Markdown file.
    static func header(of url: URL) -> (title: String, moduleID: String?, oneLine: String, status: String) {
        let lowered = url.lastPathComponent.lowercased()
        guard lowered.hasSuffix(".md") || lowered.hasSuffix(".markdown"),
              let handle = try? FileHandle(forReadingFrom: url) else { return ("", nil, "", "") }
        defer { try? handle.close() }
        let text = String(decoding: (try? handle.read(upToCount: headerBytes)) ?? Data(), as: UTF8.self)
        var title = "", id: String?, oneLine = "", status = ""
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if title.isEmpty, line.hasPrefix("# ") {
                (title, id) = splitModuleHeading(String(line.dropFirst(2)))
            } else if oneLine.isEmpty, let value = labelValue(line, label: "One line") {
                oneLine = value
            } else if status.isEmpty, let value = labelValue(line, label: "Status") {
                status = value
            } else if line.hasPrefix("## ") {
                break
            }
        }
        return (title, id, oneLine, status)
    }

    /// `M6: Context and scoped data` → ("Context and scoped data", "m6").
    static func splitModuleHeading(_ heading: String) -> (String, String?) {
        let text = heading.trimmingCharacters(in: .whitespaces)
        guard let first = text.first, first == "M" || first == "m" else { return (text, nil) }
        let digits = text.dropFirst().prefix(while: \.isNumber)
        let rest = text.dropFirst(1 + digits.count)
        guard !digits.isEmpty, let separator = rest.first, ":·-–—".contains(separator) else { return (text, nil) }
        let title = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return (title.isEmpty ? text : title, "m\(Int(digits) ?? 0)")
    }

    /// `**Status:** draft` and `**Status.** draft` → "draft".
    private static func labelValue(_ line: String, label: String) -> String? {
        for form in ["**\(label):**", "**\(label).**", "**\(label)**:"] where line.hasPrefix(form) {
            let value = line.dropFirst(form.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func order(_ lhs: DevelopmentModuleFile, _ rhs: DevelopmentModuleFile) -> Bool {
        switch (number(lhs.moduleID), number(rhs.moduleID)) {
        case let (left?, right?) where left != right: return left < right
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }
    }

    private static func number(_ id: String?) -> Int? { id.flatMap { Int($0.dropFirst()) } }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }
}

extension DevelopmentProcessStore {
    /// Tracks a discovered module design file: appends it to the in-order
    /// criteria review under the file's own ID (`m6`) when that ID is free, and
    /// records `modules/<file>`, which resolves to the repository copy first.
    /// Tracking a file that is already tracked changes nothing.
    @discardableResult
    public func trackModuleFile(_ file: DevelopmentModuleFile, projectID: String) throws -> DevelopmentProcess {
        guard let fileID = file.moduleID else {
            throw TaskContextError.commandFailed("Only module design files (m<N>-<slug>.md) can be tracked; \(file.fileName) is a shared file.")
        }
        return try mutate(projectID: projectID) { process in
            guard DevelopmentModuleFiles.module(for: file, in: process.modules) == nil else { return }
            var id = fileID
            if process.modules.contains(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) {
                var number = process.modules.count + 1
                while process.modules.contains(where: { $0.id == "m\(number)" }) { number += 1 }
                id = "m\(number)"
            }
            let name = process.modules.contains { $0.name.caseInsensitiveCompare(file.title) == .orderedSame }
                ? file.displayTitle : file.title
            process.modules.append(DevelopmentModule(
                id: id, name: name, file: "\(DevelopmentModuleFiles.projectFolderName)/\(file.fileName)"))
        }
    }
}
