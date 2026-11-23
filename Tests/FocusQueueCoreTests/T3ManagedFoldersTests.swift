import Foundation
import Testing
@testable import FocusQueueCore

/// A temporary directory used as both the fake user home and the T3 home parent.
private struct TempHome {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("t3-folders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    var path: String { root.path }
    /// realpath(3); Foundation's `resolvingSymlinksInPath` strips `/private` back off.
    var resolved: String {
        guard let pointer = realpath(root.path, nil) else { return root.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Writes `<t3Home>/userdata/settings.json`.
    func writeSettings(_ text: String, t3Home: String) throws {
        let dir = URL(fileURLWithPath: t3Home).appendingPathComponent("userdata")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("settings.json"))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private let loopback = "http://127.0.0.1:3773"

@Suite("T3 managed folders")
struct T3ManagedFoldersTests {
    @Test("Checkouts inside worktreesDirectory are violations; whole components only")
    func acceptance() throws {
        let home = try TempHome(); defer { home.cleanup() }
        let t3Home = home.path + "/.t3"
        try home.writeSettings(#"{"worktreesDirectory": "/tmp/x/worktrees", "other": 1}"#, t3Home: t3Home)
        let folders = try #require(T3ManagedFolders.resolve(serverURL: loopback, environment: [:],
                                                           fileAccessor: SystemFileAccessor(),
                                                           homeDirectory: home.path))
        // `/tmp` is a symlink to `/private/tmp` on macOS; the folder comes back resolved.
        #expect(folders == [home.resolved + "/.t3/worktrees", "/private/tmp/x/worktrees"])
        #expect(T3ManagedFolders.violation(checkoutPath: "/tmp/x/worktrees/repo/a", folders: folders)
            == "/private/tmp/x/worktrees")
        #expect(T3ManagedFolders.violation(checkoutPath: "/tmp/x/repo/.worktrees/a", folders: folders) == nil)
        #expect(T3ManagedFolders.violation(checkoutPath: "/tmp/x/worktrees-other/a", folders: folders) == nil)
        #expect(T3ManagedFolders.violation(checkoutPath: "/tmp/x/worktrees", folders: folders) != nil)
        #expect(T3ManagedFolders.violation(checkoutPath: "/tmp/x", folders: folders) == nil)
    }

    @Test("The default folder is always managed, and a missing settings file is fine")
    func defaultFolder() throws {
        let home = try TempHome(); defer { home.cleanup() }
        let folders = try #require(T3ManagedFolders.resolve(serverURL: "http://localhost:3773/mcp", environment: [:],
                                                           fileAccessor: SystemFileAccessor(),
                                                           homeDirectory: home.path))
        #expect(folders == [home.resolved + "/.t3/worktrees"])
        #expect(T3ManagedFolders.violation(checkoutPath: home.path + "/.t3/worktrees/repo/feature",
                                           folders: folders) != nil)
        #expect(T3ManagedFolders.violation(checkoutPath: home.path + "/code/repo/.worktrees/a", folders: folders) == nil)
    }

    @Test("Non-loopback servers give nil")
    func nonLoopback() throws {
        let home = try TempHome(); defer { home.cleanup() }
        for url in ["https://t3.example.com", "http://192.168.1.4:3773", "not a url", ""] {
            #expect(T3ManagedFolders.resolve(serverURL: url, environment: [:], fileAccessor: SystemFileAccessor(),
                                             homeDirectory: home.path) == nil)
        }
    }

    @Test("An unparsable settings file gives nil")
    func unparsable() throws {
        let home = try TempHome(); defer { home.cleanup() }
        let t3Home = home.path + "/.t3"
        for text in ["{not json", "[1, 2]", #"{"worktreesDirectory": 42}"#, #"{"worktreesDirectory": "relative/dir"}"#] {
            try home.writeSettings(text, t3Home: t3Home)
            #expect(T3ManagedFolders.resolve(serverURL: loopback, environment: [:], fileAccessor: SystemFileAccessor(),
                                             homeDirectory: home.path) == nil, "\(text)")
        }
    }

    @Test("T3CODE_HOME overrides ~/.t3")
    func t3HomeOverride() throws {
        let home = try TempHome(); defer { home.cleanup() }
        let custom = home.path + "/custom-t3"
        try home.writeSettings(#"{"worktreesDirectory": "/tmp/from-custom"}"#, t3Home: custom)
        try home.writeSettings(#"{"worktreesDirectory": "/tmp/from-default"}"#, t3Home: home.path + "/.t3")
        let folders = try #require(T3ManagedFolders.resolve(serverURL: loopback, environment: ["T3CODE_HOME": custom],
                                                           fileAccessor: SystemFileAccessor(),
                                                           homeDirectory: home.path))
        #expect(folders == [home.resolved + "/custom-t3/worktrees", "/private/tmp/from-custom"])
    }

    @Test("A ~/ location expands against the home directory and symlinks resolve")
    func tildeAndSymlinks() throws {
        let home = try TempHome(); defer { home.cleanup() }
        let real = home.root.appendingPathComponent("real-worktrees")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.root.appendingPathComponent("wt-link"),
                                                   withDestinationURL: real)
        try home.writeSettings(#"{"worktreesDirectory": "~/wt-link"}"#, t3Home: home.path + "/.t3")
        let folders = try #require(T3ManagedFolders.resolve(serverURL: loopback, environment: [:],
                                                           fileAccessor: SystemFileAccessor(),
                                                           homeDirectory: home.path))
        #expect(folders.last == home.resolved + "/real-worktrees")
        // A not-yet-created checkout reached through the symlink is still caught.
        #expect(T3ManagedFolders.violation(checkoutPath: home.path + "/wt-link/repo/new-branch", folders: folders)
            == home.resolved + "/real-worktrees")
        // A repository symlinked into the managed folder is caught too.
        let repoLink = home.root.appendingPathComponent("repo-link")
        try FileManager.default.createSymbolicLink(at: repoLink, withDestinationURL: real)
        #expect(T3ManagedFolders.violation(checkoutPath: repoLink.path + "/.worktrees/a", folders: folders) != nil)
    }

    @Test("A null worktreesDirectory leaves just the default folder")
    func nullLocation() throws {
        let home = try TempHome(); defer { home.cleanup() }
        try home.writeSettings(#"{"worktreesDirectory": null}"#, t3Home: home.path + "/.t3")
        let folders = T3ManagedFolders.resolve(serverURL: loopback, environment: [:], fileAccessor: SystemFileAccessor(),
                                               homeDirectory: home.path)
        #expect(folders == [home.resolved + "/.t3/worktrees"])
    }
}
