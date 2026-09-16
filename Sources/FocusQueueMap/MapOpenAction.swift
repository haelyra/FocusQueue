import Foundation

public enum MapOpenAction: Equatable, Sendable {
    case folder(URL), markdown(URL), document(URL), code(URL)

    public static func resolve(nodeID: String, snapshot: MapSnapshot) throws -> Self {
        _ = try snapshot.validated()
        guard let node = snapshot.nodes.first(where: { $0.id == nodeID }),
              let path = node.path, path.hasPrefix("/"), let root = node.allowedRoot,
              root.hasPrefix("/"), [.workspace, .folder, .file, .document].contains(node.kind) else {
            throw MapError.unsafePath("This item has no registered file location.")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let allowed = URL(fileURLWithPath: root).standardizedFileURL
        // A symlink must remain inside the originally registered root. Resolving
        // the root itself allows legitimate symlinked workspace registration.
        guard WorkspaceCollector.contains(url.path, in: allowed.path),
              WorkspaceCollector.contains(url.resolvingSymlinksInPath().path,
                  in: allowed.resolvingSymlinksInPath().path) else {
            throw MapError.unsafePath("This path resolves outside its registered workspace.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw MapError.unavailable("This file or folder has moved or was deleted. Refresh the map.")
        }
        if isDirectory.boolValue { return .folder(url) }
        switch url.pathExtension.lowercased() {
        case "md", "markdown": return .markdown(url)
        case "pdf", "html", "htm", "png", "jpg", "jpeg", "gif", "svg": return .document(url)
        default: return .code(url)
        }
    }

    public static func neovimArguments(path: String) -> [String] { ["-R", "-M", "--", path] }
}
