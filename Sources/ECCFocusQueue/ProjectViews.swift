import AppKit
import FocusQueueCore
import SwiftUI

struct ProjectSelectorView: View {
    let model: QueueViewModel
    @State private var showsNewTask = false
    @State private var showsProjects = false

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(model.activeProjects) { project in
                    Button(project.name) {
                        Task { _ = await model.selectProject(id: project.id) }
                    }
                }
                Divider()
                Button("Manage projects…") { showsProjects = true }
            } label: {
                Label(model.projectScopeName, systemImage: "folder")
                    .lineLimit(1).truncationMode(.middle)
            }.accessibilityLabel("Project: \(model.projectScopeName)")
            Spacer(minLength: 4)
            Button { showsNewTask = true } label: { Label("New task", systemImage: "plus") }
                .accessibilityLabel("Create task")
        }
        .font(.system(size: 12, weight: .medium))
        .sheet(isPresented: $showsNewTask) { ProjectTaskEditor(model: model) }
        .sheet(isPresented: $showsProjects) {
            ProjectManagementSheet(model: model)
        }
    }
}

struct TaskProjectMenu: View {
    let model: QueueViewModel
    let ticket: DashboardTicket
    var body: some View {
        Menu {
            ForEach(model.activeProjects) { project in
                Button(project.name) { Task { await model.assignProject(project.id, to: ticket.id) } }
            }
        } label: {
            Label(model.project(for: ticket)?.name ?? "Unassigned", systemImage: "folder")
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .accessibilityLabel("Project for \(ticket.id): \(model.project(for: ticket)?.name ?? "Unassigned")")
        .help("Assign this task to a project. Agent workspaces stay in place.")
    }
}

struct ProjectSettingsView: View {
    let model: QueueViewModel
    @State private var editor: ProjectDefinition?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(model.config.projects) { project in
                let isSelected = project.id == model.selectedProject?.id
                HStack(alignment: .top) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        .accessibilityLabel(isSelected ? "Selected project" : "Not selected")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.headline)
                        Text("Task IDs: \(project.taskPrefix)-###").font(.caption).foregroundStyle(.secondary)
                        Text(project.repositoryPath.isEmpty ? "No repository binding" : project.repositoryPath)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        if project.archivedAt != nil { Text("Archived · edit to restore").font(.caption) }
                    }
                    Spacer()
                    if !isSelected, project.archivedAt == nil {
                        Button("Select") { Task { _ = await model.selectProject(id: project.id) } }
                            .help("Use this project's dashboard and workspace")
                    }
                    Button("Edit") { editor = project }
                }.controlSize(.small)
            }
            if model.config.projects.isEmpty { Text("Add a project to organize tasks by repository.").foregroundStyle(.secondary) }
            Button("Add project", systemImage: "folder.badge.plus") {
                editor = ProjectDefinition(id: UUID().uuidString.lowercased(), name: "",
                    dashboardPath: "", workspacePath: "", taskPrefix: "PRJ", repositoryPath: "")
            }
            if let error = model.projectError { Text(error).font(.caption).foregroundStyle(.orange) }
        }.sheet(item: $editor) { ProjectEditor(model: model, project: $0) }
    }
}

private struct ProjectManagementSheet: View {
    let model: QueueViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Projects").font(.title2.bold())
            ScrollView { ProjectSettingsView(model: model) }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }.padding(22).frame(width: 540, height: 420)
    }
}

private struct ProjectEditor: View {
    let model: QueueViewModel
    @State private var project: ProjectDefinition
    @State private var remote: String
    @State private var aliases: String
    @Environment(\.dismiss) private var dismiss

    init(model: QueueViewModel, project: ProjectDefinition) {
        self.model = model
        _project = State(initialValue: project)
        _remote = State(initialValue: project.remote ?? "")
        _aliases = State(initialValue: project.remoteAliases.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project details").font(.title2.bold())
            TextField("Project name", text: $project.name)
            TextField("Task prefix", text: $project.taskPrefix)
            Text("Tasks use \(project.taskPrefix.uppercased())-001, \(project.taskPrefix.uppercased())-002, and so on. Use 2 to 5 uppercase letters or numbers.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Project workspace", text: $project.workspacePath)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        project.workspacePath = url.path
                        if project.repositoryPath.isEmpty { project.repositoryPath = url.path }
                        if project.dashboardPath.isEmpty {
                            project.dashboardPath = url.appendingPathComponent("dashboard.json").path
                        }
                    }
                }
            }
            TextField("Dashboard JSON", text: $project.dashboardPath)
            HStack {
                TextField("Repository folder", text: $project.repositoryPath)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { project.repositoryPath = url.path }
                }
            }
            TextField("GitHub repository URL (optional)", text: $remote)
            TextField("Repository aliases, one URL per line (optional)", text: $aliases, axis: .vertical).lineLimit(2...4)
            Text("The repository is optional. Aliases let this project recognize another clone or fork. Existing agent workspaces stay in place.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.projectError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                if project.id != ProjectCatalog.otherID,
                   model.config.projects.contains(where: { $0.id == project.id }) {
                    Button(project.archivedAt == nil ? "Archive project" : "Restore project") {
                        var updated = project
                        updated.archivedAt = project.archivedAt == nil ? Date() : nil
                        Task { if await model.saveProject(updated) { dismiss() } }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    project.name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    project.taskPrefix = project.taskPrefix.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                    let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
                    project.remote = url.isEmpty ? nil : url
                    project.remoteAliases = aliases.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    Task { if await model.saveProject(project) { dismiss() } }
                }.buttonStyle(.borderedProminent)
                    .disabled(project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || project.taskPrefix.range(of: "^[A-Za-z][A-Za-z0-9]{1,4}$", options: .regularExpression) == nil
                        || !project.workspacePath.hasPrefix("/")
                        || !project.dashboardPath.hasPrefix("/")
                        || (!project.repositoryPath.isEmpty && !project.repositoryPath.hasPrefix("/")))
            }.disabled(model.isSavingProject)
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 560)
    }
}

private struct ProjectTaskEditor: View {
    let model: QueueViewModel
    @State private var title = ""
    @State private var summary = ""
    @State private var projectID = ""
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New task").font(.title2.bold())
            TextField("Task title", text: $title)
            TextField("Description", text: $summary, axis: .vertical).lineLimit(3...6)
            Picker("Project", selection: $projectID) {
                ForEach(model.activeProjects) { Text($0.name).tag($0.id) }
            }
            if let error = model.projectError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create task") {
                    saving = true
                    Task {
                        if await model.createTask(title: title, summary: summary, projectID: projectID) { dismiss() }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(saving)
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 480)
            .onAppear { projectID = model.selectedProject?.id ?? ProjectCatalog.otherID }
    }
}

/// Settings section for project-level documents. Choosing a file opens it in
/// the side document viewer with its project chat, like a central plan.
struct ProjectFilesSection: View {
    let model: QueueViewModel
    @State private var projectID = ""
    @State private var documents: [ProjectDocument] = []
    @State private var links: [DashboardLink] = []
    @State private var error: String?

    private var project: ProjectDefinition? { model.activeProjects.first { $0.id == projectID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Project", selection: $projectID) {
                    ForEach(model.activeProjects) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("Project for files: \(project?.name ?? "none")")
                Spacer()
                if let directory = documents.first?.url.deletingLastPathComponent() {
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.open(directory) }
                        .buttonStyle(.link).font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(documents) { document in
                    let isOpen = model.isDocumentViewerPresented && model.documentViewer.selected == document.url
                    Button {
                        model.openDocumentViewer(document.url, scope: .project(projectID))
                    } label: {
                        HStack {
                            Image(systemName: document.systemImage).frame(width: 16)
                            Text(document.title)
                            Spacer()
                            Text(document.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(isOpen ? Color.accentColor.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(document.url.path)
                    .accessibilityLabel("Open \(document.title)")
                }
            }
            .font(.system(size: 12))
            if !links.isEmpty {
                Text("Links").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
                ForEach(links) { link in
                    Button(link.label, systemImage: "link") { model.open(link.url) }
                        .buttonStyle(.link).font(.system(size: 12)).multilineTextAlignment(.leading).help(link.url)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .onAppear {
            guard projectID.isEmpty else { return }
            let preferred = model.showsAllProjects ? nil : model.selectedProject?.id
            projectID = model.activeProjects.first { $0.id == preferred }?.id ?? model.activeProjects.first?.id ?? ""
        }
        .onChange(of: projectID, initial: true) { reloadDocuments() }
    }

    private func reloadDocuments() {
        guard let project else { documents = []; links = []; return }
        do {
            let store = model.projectContextStore
            try store.ensurePlan(for: project)
            documents = try store.documents(projectID: project.id)
            links = try store.links(projectID: project.id)
            error = nil
        } catch {
            documents = []; links = []
            self.error = error.localizedDescription
        }
    }
}

/// The side document viewer: tabs, the selected document, and its chat. Links
/// inside a document open beside it, matching the task plan's document panes.
struct DocumentViewerInspector: View {
    let model: QueueViewModel

    @State private var draggedTab: URL?
    @State private var isSplitTargeted = false

    private var panes: DocumentPaneState { model.documentViewer }

    /// A dragged tab is over the viewer and could open beside the document in front.
    private var previewsSplit: Bool {
        guard isSplitTargeted, !panes.hasSecondaryViewer, let draggedTab else { return false }
        return panes.canSplit(draggedTab, hasCentralContent: false)
    }

    private var scopeLabel: String {
        switch model.documentViewerScope {
        case .task(let id): id
        case .project(let id): model.config.projects.first { $0.id == id }?.name ?? id
        case nil: "Document"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(panes.primaryDocument?.lastPathComponent ?? panes.selected?.lastPathComponent ?? "Document")
                        .font(.system(size: 20, weight: .bold, design: .rounded)).lineLimit(1)
                    Text(scopeLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.closeDocumentViewer() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).frame(width: 40, height: 40)
                    .help("Close the document viewer").accessibilityLabel("Close document viewer")
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false))
            if let error = panes.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Button("Dismiss") { panes.error = nil }.font(.caption)
                }
            }
            tabBar
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    if let secondary = panes.secondaryDocument, let primary = panes.primaryDocument {
                        PlanPaneSplit(initialFraction: 0.5, minimumPrimary: 500, minimumSecondary: 460) {
                            pane(primary)
                        } secondary: {
                            pane(secondary).padding(.horizontal, 4)
                        }
                        .frame(width: max(geometry.size.width, QueueInspectorLayout.documentPairMinimumWidth),
                               height: geometry.size.height)
                    } else if let document = panes.selected {
                        // One layout for resting and drag-preview, so the open
                        // document slides left to make room for the dragged tab.
                        let previewing = previewsSplit
                        let companion = previewing
                            ? draggedTab.flatMap { panes.splitCompanion(for: $0, hasCentralContent: false) } : nil
                        PlanPaneSplit(initialFraction: previewing ? 0.5 : 0.74,
                                      minimumPrimary: QueueInspectorLayout.documentMinimumWidth,
                                      minimumSecondary: previewing ? 460 : QueueInspectorLayout.chatMinimumWidth) {
                            if case .document(let leftDocument) = companion, leftDocument != document {
                                pane(leftDocument).padding(.horizontal, 4)
                            } else {
                                pane(document).padding(.horizontal, 4)
                            }
                        } secondary: {
                            if previewing {
                                SplitDropPlaceholder()
                            } else {
                                DocumentConversationPane(queue: model, scope: model.documentViewerScope, document: document)
                            }
                        }
                        .frame(width: max(geometry.size.width, previewing
                                ? QueueInspectorLayout.documentPairMinimumWidth : QueueInspectorLayout.inspectorMinimumWidth),
                               height: geometry.size.height)
                    }
                }.scrollIndicators(.automatic)
                    .animation(.snappy(duration: 0.22), value: previewsSplit)
            }
            .splitDropTarget(tabs: panes.tabs, dragged: $draggedTab, isTargeted: $isSplitTargeted) {
                panes.split($0, hasCentralContent: false)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pane(_ document: URL) -> some View {
        SideDocumentPane(
            queue: model, scopeLabel: scopeLabel, document: document,
            open: { panes.openLinkedDocument($0) },
            close: { model.closeDocumentViewerTab(document) },
            discuss: { action in
                guard let scope = model.documentViewerScope,
                      let conversation = model.documentConversation(for: document, scope: scope) else { return }
                conversation.discuss(action)
            },
            dragStarted: { draggedTab = $0 })
    }

    private var tabBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(panes.tabs, id: \.self) { url in
                    let isSelected = panes.primaryDocument == url || panes.secondaryDocument == url
                    HStack(spacing: 4) {
                        Button(url.isFileURL ? url.lastPathComponent : (url.host ?? url.absoluteString)) {
                            panes.select(url)
                        }.lineLimit(1)
                        Button { model.closeDocumentViewerTab(url) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        }
                        .accessibilityLabel("Close \(url.lastPathComponent)")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(isSelected ? 0.98 : 0.94),
                        in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.18), lineWidth: 1)
                        .allowsHitTesting(false))
                    .documentDrag(url) { draggedTab = $0 }
                    .help(url.absoluteString)
                    .contextMenu {
                        if panes.secondaryDocument == url {
                            Button("Close Split View", systemImage: "rectangle") { panes.endSplit() }
                        } else if panes.canSplit(url, hasCentralContent: false) {
                            Button("Open in Split View", systemImage: "rectangle.split.2x1") {
                                panes.split(url, hasCentralContent: false)
                            }
                        }
                        Button("Close Tab", systemImage: "xmark") { model.closeDocumentViewerTab(url) }
                    }
                }
            }
            .padding(.vertical, 2)
            .dropDestination(for: String.self) { identifiers, _ in
                draggedTab = nil
                guard let identifier = identifiers.last,
                      let url = panes.tabs.first(where: { $0.absoluteString == identifier }) else { return false }
                panes.select(url)
                return true
            }
        }.accessibilityLabel("Open documents")
    }
}
