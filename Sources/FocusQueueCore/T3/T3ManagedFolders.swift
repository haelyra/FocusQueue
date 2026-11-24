import Foundation

/// T3 Code's managed worktree folders. T3's storage cleanup deletes linked worktrees inside
/// them, so Focus Queue checkouts must stay outside. T3 exposes the location only in its
/// local settings file, never over MCP.
public enum T3ManagedFolders {
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "localhost"]

    /// The managed folders, symlinks resolved, or nil when they cannot be known: the server is
    /// not on this machine, or T3's settings file exists but cannot be read or parsed.
    public static func resolve(serverURL: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileAccessor: any FileAccessing = SystemFileAccessor(),
                               homeDirectory: String = NSHomeDirectory()) -> [String]? {
        guard let host = URL(string: serverURL)?.host?.lowercased(), loopbackHosts.contains(host) else {
            return nil
        }
        let home: String
        if let custom = environment["T3CODE_HOME"], !custom.isEmpty {
            home = T3Paths.expandingTilde(custom, homeDirectory: homeDirectory)
        } else {
            home = (homeDirectory as NSString).appendingPathComponent(".t3")
        }
        var folders = [(home as NSString).appendingPathComponent("worktrees")]

        let settingsURL = URL(fileURLWithPath: home).appendingPathComponent("userdata/settings.json")
        if fileAccessor.fileExists(at: settingsURL) {
            guard let data = try? fileAccessor.read(from: settingsURL),
                  let settings = (try? JSONValue.parse(data))?.objectValue else { return nil }
            switch settings["worktreesDirectory"] {
            case nil, .null?:
                break
            case .string(let raw)?:
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let expanded = T3Paths.expandingTilde(trimmed, homeDirectory: homeDirectory)
                    // A relative location has no known base; treat the folders as unknown.
                    guard expanded.hasPrefix("/") else { return nil }
                    folders.append(expanded)
                }
            default:
                return nil
            }
        }

        var seen = Set<String>()
        return folders.map(T3Paths.canonical).filter { seen.insert($0).inserted }
    }

    /// The folder in `folders` that contains `checkoutPath` (or is it), comparing whole
    /// path components after resolving symlinks; nil when the checkout is outside all of them.
    public static func violation(checkoutPath: String, folders: [String]) -> String? {
        let checkout = T3Paths.components(T3Paths.canonical(checkoutPath))
        return folders.first { folder in
            let prefix = T3Paths.components(T3Paths.canonical(folder))
            return prefix.count <= checkout.count && Array(checkout.prefix(prefix.count)) == prefix
        }
    }
}

/// Path normalization shared by the T3 runtime.
enum T3Paths {
    /// Standardized absolute path with symlinks resolved. When the path does not exist yet,
    /// the deepest existing ancestor is resolved and the remaining components are appended.
    static func canonical(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: expandingTilde(path, homeDirectory: NSHomeDirectory()))
            .standardizedFileURL.path
        var existing = standardized
        var remainder: [String] = []
        while existing != "/", realPath(existing) == nil {
            remainder.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
        var result = realPath(existing) ?? existing
        for component in remainder { result = (result as NSString).appendingPathComponent(component) }
        return result
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func expandingTilde(_ path: String, homeDirectory: String) -> String {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return (homeDirectory as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
