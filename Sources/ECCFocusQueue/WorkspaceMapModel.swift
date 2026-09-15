import AppKit
import Foundation
import Observation
import FocusQueueCore
import FocusQueueMap

@MainActor
@Observable
final class WorkspaceMapModel {
    var snapshot: MapSnapshot?
    var expanded = Set<String>()
    var selection: String?
    var search = ""
    var attentionOnly = false
    var changesOnly = false
    var showOtherFiles = false
    var mode: WorkspaceMapMode = .typical
    var focusedAgentID: String?
    var expandedView = false
    var includeOlderScope = false
    var fitWidth = true
    var zoom = 1.0
    var options: WorkspaceMapOptions {
        var value = WorkspaceMapOptions()
        value.mode = mode; value.agentID = focusedAgentID; value.expanded = expanded
        value.expandedView = expandedView; value.includeOlderScope = includeOlderScope
        value.showOtherFiles = showOtherFiles; value.search = search
        value.attentionOnly = attentionOnly; value.changesOnly = changesOnly
        return value
    }
    func select(_ node: MapNode) {
        selection = node.id
        if node.kind == .agent { mode = .agent; focusedAgentID = node.id; zoom = 1 }
        if node.kind == .queue || node.kind == .context { mode = .context; zoom = 1 }
    }
    var message: String?
    var isRefreshing = false
    var actionError: String?
    @ObservationIgnored private let collector: WorkspaceCollector
    @ObservationIgnored private let cache = MapSnapshotCache()
    @ObservationIgnored private var loadedTask: String?

    init(collector: WorkspaceCollector = WorkspaceCollector()) { self.collector = collector }

    func refresh(context: TaskContext, sessions: [TaskAgentSession]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let cacheURL = context.contextDirectory.appendingPathComponent("workspace-map/snapshot.json")
        if loadedTask != context.ticketID {
            loadedTask = context.ticketID
            snapshot = nil; expanded = []; selection = nil; mode = .typical
            do { snapshot = try await cache.load(from: cacheURL, taskID: context.ticketID) }
            catch { message = "Saved map unavailable. Collecting a fresh map." }
            seedExpansion()
        }
        do {
            let fresh = try await collector.collect(context: context, sessions: sessions)
            try Task.checkCancellation()
            if !fresh.warnings.isEmpty, let snapshot, snapshot.warnings.isEmpty {
                message = "Showing the last successful map. " + fresh.warnings.joined(separator: " ")
            } else {
                snapshot = fresh
                message = fresh.warnings.isEmpty ? nil : fresh.warnings.joined(separator: " ")
                seedExpansion()
            }
            if fresh.warnings.isEmpty {
                do { try await cache.save(fresh, to: cacheURL) }
                catch { message = "Live map available; its cache could not be saved: \(error.localizedDescription)" }
            }
        } catch is CancellationError { }
        catch { message = "Map refresh failed: \(error.localizedDescription)" }
    }

    private func seedExpansion() {
        guard let snapshot else { return }
        if expanded.isEmpty {
            expanded = Set(snapshot.nodes.filter { $0.kind == .queue || $0.kind == .workspace }.map(\.id))
        }
        if mode == .agent && !snapshot.nodes.contains(where: { $0.id == focusedAgentID }) { mode = .typical; focusedAgentID = nil }
        if !snapshot.nodes.contains(where: { $0.id == selection }) {
            selection = snapshot.nodes.first(where: { $0.kind == .workspace })?.id ?? "queue"
        }
    }

    /// Retained for a future explicit external-editor action. Map file activation
    /// now opens the side document pane and does not call this method.
    func openCode(_ url: URL, viewer: String, configuration: WezTermConfiguration) async throws {
        let runner = FoundationProcessRunner()
        if viewer == "vscode" {
            let binary = SetupEnvironment.executable("code")
                ?? "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
            guard FileManager.default.isExecutableFile(atPath: binary) else {
                throw MapError.unavailable("VS Code was not found. Choose Neovim or install the code command.")
            }
            let result = try await runner.run(.init(executable: binary, arguments: ["--reuse-window", "--", url.path]))
            guard result.succeeded else { throw MapError.unavailable("VS Code could not open this file.") }
            return
        }
        guard let nvim = SetupEnvironment.executable("nvim") else {
            throw MapError.unavailable("Neovim was not found. Install nvim or choose VS Code from Code viewer.")
        }
        let connection = try await WezTermConnection.resolve(configuration: configuration, runner: runner)
        guard connection.result.succeeded else {
            throw MapError.unavailable("Open WezTerm, then retry opening this file in read-only Neovim.")
        }
        let result = try await runner.run(.init(executable: connection.configuration.executable,
            arguments: ["cli", "spawn", "--new-window", "--domain-name", "local", "--cwd",
                        url.deletingLastPathComponent().path, "--", nvim] + MapOpenAction.neovimArguments(path: url.path),
            environment: connection.configuration.cliEnvironment, timeoutSeconds: 15))
        guard result.succeeded else { throw MapError.unavailable("WezTerm could not open the read-only code viewer.") }
    }
}
