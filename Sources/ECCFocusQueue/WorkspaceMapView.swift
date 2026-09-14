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
        let layout = MapFlowLayout(snapshot: snapshot, showOtherFiles: model.showOtherFiles,
            expanded: model.expanded, search: model.search, attentionOnly: model.attentionOnly,
            changesOnly: model.changesOnly)
        let positions = Dictionary(uniqueKeysWithValues: layout.items.map { ($0.id, $0) })
        let selectedAgent = snapshot.nodes.first { $0.id == model.selection && $0.kind == .agent }
        let highlighted = selectedAgent.map { MapFlowLayout.highlightedNodes(agentID: $0.id, snapshot: snapshot) }
        return VStack(spacing: 4) {
            HStack {
                Text("Context → Agent → Output").font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Other files", isOn: $model.showOtherFiles).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: 10)).help("Browse files outside the agents’ reported context")
                Button("Reset") { model.zoom = 1; model.search = ""; model.attentionOnly = false; model.changesOnly = false; model.showOtherFiles = false }
                    .font(.system(size: 10))
            }
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(layout.sections) { section in
                        VStack(alignment: .leading) {
                            Text(section.label).font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(1).padding(.leading, 10).padding(.top, 5)
                            Spacer()
                        }
                        .frame(width: layout.width, height: section.height, alignment: .topLeading)
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.16)))
                        .offset(y: section.y).allowsHitTesting(false)
                    }
                    Canvas { context, _ in
                        for line in layout.lines {
                            guard let parent = positions[line.from], let item = positions[line.to] else { continue }
                            let start = CGPoint(x: parent.x + MapFlowLayout.nodeWidth, y: parent.y + MapFlowLayout.nodeHeight / 2)
                            let end = CGPoint(x: item.x, y: item.y + MapFlowLayout.nodeHeight / 2)
                            let active = selectedAgent == nil || line.agentID == selectedAgent?.id ||
                                (line.kind == "hierarchy" && highlighted?.contains(parent.node.id) == true && highlighted?.contains(item.node.id) == true)
                            let tint: Color = line.kind == "input" ? .accentColor : line.kind == "output" ? .green : .secondary
                            var path = Path(); path.move(to: start)
                            let middle = (start.x + end.x) / 2
                            path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                            context.stroke(path, with: .color(tint.opacity(active ? 0.7 : 0.12)),
                                style: StrokeStyle(lineWidth: line.kind == "hierarchy" ? 1 : 1.7, dash: line.kind == "input" ? [4, 3] : []))
                            if line.kind != "hierarchy" {
                                var arrow = Path(); arrow.move(to: end); arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y - 4))
                                arrow.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4)); arrow.closeSubpath()
                                context.fill(arrow, with: .color(tint.opacity(active ? 0.85 : 0.12)))
                            }
                        }
                    }.accessibilityHidden(true)
                    ForEach(layout.items) { item in
                        node(item.node, snapshot: snapshot, role: item.role)
                            .frame(width: MapFlowLayout.nodeWidth, height: MapFlowLayout.nodeHeight)
                            .opacity(highlighted == nil || highlighted!.contains(item.node.id) ? 1 : 0.27)
                            .offset(x: item.x, y: item.y)
                    }
                }
                .frame(width: layout.width, height: layout.height)
                .scaleEffect(model.zoom, anchor: .topLeading)
                .frame(width: layout.width * model.zoom, height: layout.height * model.zoom, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)).allowsHitTesting(false))
            .frame(minHeight: 190, maxHeight: .infinity)
            Text("\(layout.hiddenCount) other items hidden · dashed: provided / declared context · green: declared output")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func node(_ node: MapNode, snapshot: MapSnapshot, role: String) -> some View {
        let children = snapshot.nodes.contains { $0.parentID == node.id }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon(node.kind)).foregroundStyle(color(node))
                Text((role + " · " + node.kind.rawValue).uppercased()).font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if children && node.kind != .queue {
                    Button {
                        if model.showOtherFiles && model.expanded.contains(node.id) { model.expanded.remove(node.id) }
                        else { model.expanded.insert(node.id); model.showOtherFiles = true }
                    } label: { Image(systemName: model.showOtherFiles && model.expanded.contains(node.id) ? "minus.circle" : "plus.circle") }
                    .buttonStyle(.plain).accessibilityLabel("Toggle other files in \(node.label)")
                }
            }
            Text(node.label).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(node.state().map { $0.capitalized } ?? node.summary)
                .font(.system(size: 9)).foregroundStyle(node.state() == nil ? Color.secondary : color(node)).lineLimit(1)
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(node.kind == .queue ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selection == node.id ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: model.selection == node.id ? 2 : 1).allowsHitTesting(false))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.selection = node.id; open(node, snapshot: snapshot) }
        .onTapGesture {
            model.selection = node.id
            if [.file, .document].contains(node.kind) { open(node, snapshot: snapshot) }
        }
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
                    if ![.queue, .folder, .workspace].contains(node.kind) {
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
        guard node.kind != .queue else { return }
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
        case .agent: "terminal"
        }
    }
}
