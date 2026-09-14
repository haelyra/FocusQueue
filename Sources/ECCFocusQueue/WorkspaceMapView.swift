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
    @AppStorage("workspaceMapCodeViewer") private var codeViewer = "neovim"
    @State private var refreshID = 0

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
                    Text("Git changes show workspace activity; file owners are unknown.")
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
        .task(id: refreshID) {
            while !Task.isCancelled {
                if let context = queue.taskContexts[ticket.id] {
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
                Menu {
                    Picker("Code viewer", selection: $codeViewer) {
                        Text("Neovim · read only").tag("neovim")
                        Text("VS Code").tag("vscode")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                .help("Code viewer preference").accessibilityLabel("Map preferences")
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
        let layout = MapLayout(snapshot: snapshot, expanded: model.expanded, search: model.search,
                               attentionOnly: model.attentionOnly, changesOnly: model.changesOnly)
        let positions = Dictionary(uniqueKeysWithValues: layout.items.map { ($0.id, $0) })
        let width = CGFloat((layout.items.map(\.depth).max() ?? 0) + 1) * 225 + 24
        let height = CGFloat(max(layout.items.count, 1)) * 92 + 24
        return VStack(spacing: 3) {
            HStack {
                Text("Outer workspace → deeper path").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { model.expanded = Set(snapshot.nodes.filter { $0.kind == .workspace || $0.kind == .queue }.map(\.id)); model.zoom = 1; model.search = ""; model.attentionOnly = false; model.changesOnly = false }
                    .font(.system(size: 10))
            }
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { context, _ in
                        for item in layout.items {
                            guard let parentID = item.node.parentID, let parent = positions[parentID] else { continue }
                            let start = CGPoint(x: CGFloat(parent.depth) * 225 + 213, y: CGFloat(parent.row) * 92 + 51)
                            let end = CGPoint(x: CGFloat(item.depth) * 225 + 12, y: CGFloat(item.row) * 92 + 51)
                            var path = Path(); path.move(to: start)
                            let middle = (start.x + end.x) / 2
                            path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                            context.stroke(path, with: .color(.secondary.opacity(0.45)),
                                style: StrokeStyle(lineWidth: 1.3, dash: item.node.kind == .agent ? [4, 3] : []))
                        }
                    }.accessibilityHidden(true)
                    ForEach(layout.items) { item in
                        node(item.node, snapshot: snapshot)
                            .frame(width: 201, height: 78)
                            .offset(x: CGFloat(item.depth) * 225 + 12, y: CGFloat(item.row) * 92 + 12)
                    }
                }
                .frame(width: width, height: height)
                .scaleEffect(model.zoom, anchor: .topLeading)
                .frame(width: width * model.zoom, height: height * model.zoom, alignment: .topLeading)
            }
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)).allowsHitTesting(false))
            .frame(minHeight: 190, maxHeight: .infinity)
            if layout.items.count == 1 && (!model.search.isEmpty || model.attentionOnly || model.changesOnly) {
                Text("No matching items. Clear the filters to see this task’s workspaces.").font(.caption).foregroundStyle(.secondary)
            }
            if layout.hiddenCount > 0 || snapshot.omittedPaths > 0 {
                Text("\(layout.hiddenCount) items collapsed or filtered · \(snapshot.omittedPaths) paths outside the collection limit")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func node(_ node: MapNode, snapshot: MapSnapshot) -> some View {
        let children = snapshot.nodes.contains { $0.parentID == node.id }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon(node.kind)).foregroundStyle(color(node))
                Text(node.kind.rawValue.uppercased()).font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if children && node.kind != .queue {
                    Button {
                        if model.expanded.contains(node.id) { model.expanded.remove(node.id) }
                        else { model.expanded.insert(node.id) }
                    } label: { Image(systemName: model.expanded.contains(node.id) ? "chevron.down" : "chevron.right") }
                    .buttonStyle(.plain).accessibilityLabel("\(model.expanded.contains(node.id) ? "Collapse" : "Expand") \(node.label)")
                }
            }
            Text(node.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(node.state().map { $0.capitalized } ?? node.summary)
                .font(.system(size: 9)).foregroundStyle(node.state() == nil ? Color.secondary : color(node)).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(node.kind == .queue ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selection == node.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: model.selection == node.id ? 2 : 1).allowsHitTesting(false))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selection = node.id; open(node, snapshot: snapshot) }
        .onTapGesture { model.selection = node.id }
        .focusable()
        .onKeyPress(.return) { model.selection = node.id; return .handled }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(node.label), \(node.kind.rawValue), \(node.state() ?? node.summary)")
        .accessibilityAction(named: "Inspect") { model.selection = node.id }
        .accessibilityAction(named: "Open") { open(node, snapshot: snapshot) }
        .help(node.path ?? node.summary)
    }

    @ViewBuilder private func inspector(_ snapshot: MapSnapshot) -> some View {
        if let node = snapshot.nodes.first(where: { $0.id == model.selection }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(node.label).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if node.kind != .queue {
                        Button(node.kind == .agent ? "Open agent" : "Open") { open(node, snapshot: snapshot) }
                            .font(.caption)
                    }
                    Button("Discuss") { discuss("Map context: \(node.label)\n\(node.summary)\nLocation: \(node.path ?? "Task queue")\nEvidence: \(node.evidence)\n") }
                        .font(.caption)
                }
                Text(node.summary).font(.caption).lineLimit(3)
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
        guard node.kind != .queue else { return }
        Task {
            do {
                switch try MapOpenAction.resolve(nodeID: node.id, snapshot: snapshot) {
                case .markdown(let url): openDocument(url)
                case .folder(let url):
                    guard NSWorkspace.shared.open(url) else { throw MapError.unavailable("Finder could not open this folder.") }
                case .document(let url):
                    if ["html", "htm"].contains(url.pathExtension.lowercased()),
                       let browser = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.invalid")!) {
                        _ = try await NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: .init())
                    } else if !NSWorkspace.shared.open(url) { throw MapError.unavailable("No application could open this document.") }
                case .code(let url): try await model.openCode(url, viewer: codeViewer, configuration: queue.config.wezTerm)
                }
            } catch { model.actionError = error.localizedDescription }
        }
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
        case .agent: "terminal"
        }
    }
}
