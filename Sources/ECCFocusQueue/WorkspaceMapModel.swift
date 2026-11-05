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
    var collapsed = Set<String>()
    var focusedBranchID: String?
    var retrospective = false
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
        value.collapsed = collapsed; value.focusedBranchID = focusedBranchID; value.retrospective = retrospective
        value.expandedView = expandedView; value.includeOlderScope = includeOlderScope
        value.showOtherFiles = showOtherFiles; value.search = search
        value.attentionOnly = attentionOnly; value.changesOnly = changesOnly
        return value
    }
    func select(_ node: MapNode) {
        selection = node.id
        if node.kind == .agent { mode = .agent; focusedAgentID = node.id; focusedBranchID = nil; zoom = 1 }
        if node.kind == .queue || node.kind == .context { mode = .context; focusedBranchID = nil; zoom = 1 }
    }
    func normalView() {
        mode = .typical; focusedAgentID = nil; focusedBranchID = nil
        selection = nil; retrospective = false; zoom = 1
    }
    func toggle(_ item: MapDiagram.Item) {
        guard let id = item.expansionID else { return }
        if item.isExpanded == true { collapsed.insert(id); expanded.remove(id) }
        else {
            collapsed.remove(id); expanded.insert(id)
            if item.focusOnExpand == true { focusedBranchID = id }
        }
    }
    var message: String?
    var isRefreshing = false
    var actionError: String?
    @ObservationIgnored private let collector: WorkspaceCollector
    @ObservationIgnored private let cache = MapSnapshotCache()
    @ObservationIgnored private var loadedTask: String?
    @ObservationIgnored private var lastSuccessfulSnapshot: MapSnapshot?

    init(collector: WorkspaceCollector = WorkspaceCollector()) { self.collector = collector }

    func refresh(context: TaskContext, sessions: [TaskAgentSession]) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let cacheURL = context.contextDirectory.appendingPathComponent("workspace-map/snapshot.json")
        if loadedTask != context.ticketID {
            loadedTask = context.ticketID
            lastSuccessfulSnapshot = nil
            snapshot = nil; expanded = []; collapsed = []; focusedBranchID = nil; selection = nil; mode = .typical
            do {
                snapshot = try await cache.load(from: cacheURL, taskID: context.ticketID)
                if snapshot?.warnings.isEmpty == true { lastSuccessfulSnapshot = snapshot }
            }
            catch { message = "Saved map unavailable. Collecting a fresh map." }
            seedExpansion()
        }
        do {
            let fresh = try await collector.collect(context: context, sessions: sessions)
            try Task.checkCancellation()
            let hasLiveWorkspace = fresh.nodes.contains {
                $0.kind == .workspace && $0.observedAt == fresh.generatedAt
            }
            if !fresh.warnings.isEmpty, !hasLiveWorkspace, let lastSuccessfulSnapshot {
                snapshot = lastSuccessfulSnapshot
                message = "Showing the last successful map. " + fresh.warnings.joined(separator: " ")
                seedExpansion()
            } else {
                snapshot = fresh
                message = fresh.warnings.isEmpty ? nil : fresh.warnings.joined(separator: " ")
                seedExpansion()
            }
            if fresh.warnings.isEmpty {
                lastSuccessfulSnapshot = fresh
                do { try await cache.save(fresh, to: cacheURL) }
                catch { message = "Live map available; its cache could not be saved: \(error.localizedDescription)" }
            }
        } catch is CancellationError { }
        catch { message = "Map refresh failed: \(error.localizedDescription)" }
    }

    private func seedExpansion() {
        guard let snapshot else { return }
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
        guard configuration.terminalApp.usesWezTermCLI else {
            try await TerminalCommandLauncher.open(
                [nvim] + MapOpenAction.neovimArguments(path: url.path),
                configuration: configuration, runner: runner)
            return
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
