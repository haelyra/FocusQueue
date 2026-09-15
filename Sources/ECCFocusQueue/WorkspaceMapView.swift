import AppKit
import SwiftUI
import FocusQueueCore
import FocusQueueMap

struct WorkspaceMapView: View {
    let queue: QueueViewModel
    let ticket: DashboardTicket
    @Bindable var model: WorkspaceMapModel
    let openDocument: (URL) -> Void
    let discuss: (String) -> Void
    @State private var refreshID = 0
    @State private var visibility = MapVisibilityHandle()

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if let snapshot = model.snapshot {
                map(snapshot)
                inspector(snapshot)
                HStack {
                    Text("Snapshot \(snapshot.generatedAt, style: .relative) ago")
                    Spacer()
                    if model.isRefreshing { ProgressView().controlSize(.mini) }
                    Text(model.includeOlderScope ? "Including older declared scope" : "Declared scope · last 30 min")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            } else if queue.taskContexts[ticket.id] == nil {
                ContentUnavailableView("Task context unavailable", systemImage: "map",
                    description: Text("The map will load when this task’s central context is available."))
            } else {
                ProgressView("Reading workspaces…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .alert("Could not open map item", isPresented: Binding(
            get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } }
        )) { Button("OK") { model.actionError = nil } } message: { Text(model.actionError ?? "") }
        .background(MapVisibilityProbe(handle: visibility).frame(width: 0, height: 0))
        .task(id: refreshID) {
            while !Task.isCancelled {
                if visibility.isVisible, let context = queue.taskContexts[ticket.id] {
                    await model.refresh(context: context, sessions: queue.agentSessions(for: ticket.id))
                }
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    private var toolbar: some View {
        VStack(spacing: 7) {
            HStack {
                Label("Workspace", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.isRefreshing).help("Refresh workspace map").accessibilityLabel("Refresh map")

            }
            HStack {
                TextField("Find agent, folder, or file", text: $model.search)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Search workspace map")
                Toggle(isOn: $model.attentionOnly) { Image(systemName: "exclamationmark.circle") }
                    .toggleStyle(.button).help("Show agents needing attention and their workspace")
                    .accessibilityLabel("Needs attention")
                    .onChange(of: model.attentionOnly) { _, value in if value { model.changesOnly = false } }
                Toggle(isOn: $model.changesOnly) { Image(systemName: "pencil.line") }
                    .toggleStyle(.button).help("Show changed paths and their parent folders")
                    .accessibilityLabel("Changed files")
                    .onChange(of: model.changesOnly) { _, value in if value { model.attentionOnly = false } }
                Button { model.zoom = max(0.6, model.zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("Zoom out")
                Button { model.zoom = min(1.4, model.zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("Zoom in")
            }.font(.caption)
        }
    }

    private func map(_ snapshot: MapSnapshot) -> some View {
        let diagram = WorkspaceMapProjection.diagram(snapshot: snapshot, options: model.options)
        return VStack(spacing: 5) {
            HStack(spacing: 7) {
                Button("Typical") { model.mode = .typical; model.selection = nil; model.zoom = 1 }
                    .tint(model.mode == .typical ? .accentColor : .secondary)
                Button("Context") { model.mode = .context; model.zoom = 1 }
                    .tint(model.mode == .context ? .accentColor : .secondary)
                if model.mode == .agent {
                    Text("Agent focus").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Expanded", isOn: $model.expandedView).toggleStyle(.switch).controlSize(.mini)
                Menu {
                    Toggle("Other files", isOn: $model.showOtherFiles)
                    Toggle("Include older scope", isOn: $model.includeOlderScope)
                    Toggle("Fit width", isOn: $model.fitWidth)
                    Button("Reset view") {
                        model.mode = .typical; model.expanded = []; model.expandedView = false
                        model.search = ""; model.attentionOnly = false; model.changesOnly = false
                        model.zoom = 1; model.includeOlderScope = false; model.showOtherFiles = false
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }.font(.system(size: 10)).buttonStyle(.bordered)
            InteractiveMapCanvas(diagram: diagram, zoom: model.zoom, fitWidth: model.fitWidth, card: { item in
                node(item, snapshot: snapshot)
            }, selectContainer: { id in
                if let node = snapshot.nodes.first(where: { $0.id == id }) { model.select(node) }
            })
            Text("Click an agent to isolate it · + expands a group · dashed: context · green: output · orange: feedback")
                .font(.system(size: 9)).foregroundStyle(.secondary)
            if diagram.items.count >= diagram.limit {
                Text("Showing \(diagram.limit) items. Focus an agent or search to narrow the map.").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func node(_ item: MapDiagram.Item, snapshot: MapSnapshot) -> some View {
        let node = item.node
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon(node.kind)).foregroundStyle(color(node))
                Text(item.role.uppercased()).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let expansion = item.expansionID {
                    Button {
                        if model.expanded.contains(expansion) { model.expanded.remove(expansion) }
                        else { model.expanded.insert(expansion) }
                    } label: { Image(systemName: model.expanded.contains(expansion) ? "minus.circle" : "plus.circle") }
                        .buttonStyle(.plain).accessibilityLabel("Expand or collapse \(node.label)")
                }
            }
            Text(node.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(item.hiddenChildren > 0 ? "\(item.hiddenChildren) items · expand +" : node.state().map { $0.capitalized } ?? node.summary)
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(7).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(node.kind == .queue ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selection == node.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: model.selection == node.id ? 2 : 1).allowsHitTesting(false))
            .contentShape(Rectangle())
            .onTapGesture { activate(node, snapshot: snapshot) }
            .focusable().onKeyPress(.return) { activate(node, snapshot: snapshot); return .handled }
            .contextMenu {
                if let location = node.path ?? node.destination {
                    Text(location)
                    Button("Copy path or URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(location, forType: .string) }
                }
                if node.kind == .section { Button("Open source document") { open(node, snapshot: snapshot) } }
                if node.kind == .agent { Button("Open agent") { open(node, snapshot: snapshot) } }
            }
            .mapPathTooltip(node.path ?? node.destination)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(node.label), \(node.kind.rawValue), \(node.summary)")
            .accessibilityAction(named: "Open") { activate(node, snapshot: snapshot) }
    }

    private func activate(_ node: MapNode, snapshot: MapSnapshot) {
        model.select(node)
        if node.kind == .section || node.kind == .folder {
            if model.expanded.contains(node.id) { model.expanded.remove(node.id) }
            else { model.expanded.insert(node.id) }
        } else if [.file, .document, .link, .resource].contains(node.kind) { open(node, snapshot: snapshot) }
    }

    @ViewBuilder private func inspector(_ snapshot: MapSnapshot) -> some View {
        if let node = snapshot.nodes.first(where: { $0.id == model.selection }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(node.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if ![.queue, .folder, .workspace, .context].contains(node.kind) {
                        Button(node.kind == .agent ? "Open agent" : "Open") { open(node, snapshot: snapshot) }
                            .font(.caption)
                    }
                    Button("Discuss") { discuss("Map context: \(node.label)\n\(node.summary)\nLocation: \(node.path ?? "Task queue")\nEvidence: \(node.evidence)\n") }
                        .font(.caption)
                }
                Text(node.summary).font(.caption).lineLimit(3)
                if node.kind == .agent {
                    let inputs = snapshot.relations.filter { $0.to == node.id && $0.kind == .input }.count
                    let outputs = snapshot.relations.filter { $0.from == node.id && $0.kind == .output }.count
                    Text("\(inputs) context files · \(outputs == 0 ? "No output paths reported" : "\(outputs) declared outputs")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let path = node.path { Text(path).font(.system(size: 10, design: .monospaced)).lineLimit(2).textSelection(.enabled) }
                HStack {
                    Text(node.evidence)
                    if let date = node.observedAt { Text("· \(date, style: .relative) ago") }
                    else if node.kind == .agent { Text("· no heartbeat") }
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func open(_ node: MapNode, snapshot: MapSnapshot) {
        if node.kind == .agent {
            if let id = node.subtaskID, let subtask = queue.subtasks(for: ticket.id).first(where: { $0.id == id }) {
                let currentSession = subtask.sessionID ?? queue.agentSessions(for: ticket.id)
                    .first(where: { $0.subtaskID == id && $0.provider == subtask.provider })?.sessionID
                guard subtask.provider.rawValue == node.provider,
                      currentSession?.lowercased() == node.sessionID?.lowercased() else {
                    model.actionError = "This assignment changed since the map was collected. Refresh before opening its agent."
                    return
                }
                queue.openSubtask(subtask, for: ticket)
            } else if let session = queue.agentSessions(for: ticket.id).first(where: {
                $0.provider.rawValue == node.provider && $0.sessionID.caseInsensitiveCompare(node.sessionID ?? "") == .orderedSame
            }) { queue.viewAgent(session, for: ticket) }
            else { model.actionError = "This agent is no longer registered to this task. Refresh the map." }
            return
        }
        guard node.kind != .queue && node.kind != .context else { return }
        if [.link, .section, .resource].contains(node.kind) {
            if let target = node.destination, let url = ResourceLocator.url(for: target) { openDocument(url) }
            else if node.kind == .resource { model.actionError = "No document is linked to this instance yet." }
            return
        }
        // Folder opening is deliberately disconnected. Folder clicks are for
        // expanding the hierarchy; the dormant Finder helper below is retained.
        if [.folder, .workspace].contains(node.kind) {
            model.expanded.insert(node.id); model.showOtherFiles = true
            return
        }
        do {
            switch try MapOpenAction.resolve(nodeID: node.id, snapshot: snapshot) {
            case .folder: return
            case .markdown(let url), .document(let url), .code(let url): openDocument(url)
            }
        } catch { model.actionError = error.localizedDescription }
    }

    /// Intentionally unreachable from the map's actions. Retained for a future
    /// explicit “Open in Finder” command if folder launching is wanted again.
    private func openFolderInFinderForFutureUse(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw MapError.unavailable("Finder could not open this folder.") }
    }

    private func color(_ node: MapNode) -> Color {
        switch node.state() {
        case "blocked": .red
        case "stale", "unknown": .orange
        case "working", "completed": .green
        default: .accentColor
        }
    }
    private func icon(_ kind: MapNodeKind) -> String {
        switch kind {
        case .queue: "list.bullet.rectangle"
        case .workspace: "square.dashed"
        case .folder: "folder"
        case .file, .document: "doc.text"
        case .context: "square.stack.3d.up"
        case .section: "text.below.photo"
        case .link: "link"
        case .resource: "externaldrive.connected.to.line.below"
        case .agent: "terminal"
        }
    }
}
