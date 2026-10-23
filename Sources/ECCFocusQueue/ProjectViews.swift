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
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.name).font(.headline)
                        Text("Task IDs: \(project.taskPrefix)-###").font(.caption).foregroundStyle(.secondary)
                        Text(project.repositoryPath.isEmpty ? "No repository binding" : project.repositoryPath)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        if project.archivedAt != nil { Text("Archived · available in project settings").font(.caption) }
                    }
                    Spacer()
                    Button("Edit") { editor = project }
                }
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

struct ProjectFilesPanel: View {
    let model: QueueViewModel
    /// Offscreen snapshots cannot capture WebKit; tests render the list without the preview.
    var rendersPreview = true
    @State private var projectID = ""
    @State private var documents: [ProjectDocument] = []
    @State private var links: [DashboardLink] = []
    @State private var selection: URL?
    @State private var content: SideDocumentContent?
    @State private var error: String?
    @State private var revision = 0
    private let loader = SideDocumentLoader()

    private var project: ProjectDefinition? { model.activeProjects.first { $0.id == projectID } }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 210)
            Divider()
            if rendersPreview { preview.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .frame(width: 780, height: 540)
        .onAppear {
            guard projectID.isEmpty else { return }
            let preferred = model.showsAllProjects ? nil : model.selectedProject?.id
            projectID = model.activeProjects.first { $0.id == preferred }?.id ?? model.activeProjects.first?.id ?? ""
        }
        .onChange(of: projectID, initial: true) { reloadDocuments() }
        .task(id: "\(selection?.path ?? ""):\(revision)") {
            content = nil
            guard let selection else { return }
            do {
                let loaded = try await loader.load(selection)
                guard !Task.isCancelled else { return }
                content = loaded; error = nil
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Menu {
                ForEach(model.activeProjects) { project in
                    Button(project.name) { projectID = project.id }
                }
            } label: {
                Label(project?.name ?? "Choose project", systemImage: "folder")
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("Project: \(project?.name ?? "none")")
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(documents) { document in
                        Button { selection = document.url } label: {
                            Label {
                                Text(document.kind.title)
                            } icon: {
                                Image(systemName: document.kind.systemImage).frame(width: 16)
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background(selection == document.url ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(document.url.path)
                    }
                    if !links.isEmpty {
                        Text("Links").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 10)
                        ForEach(links) { link in
                            Button(link.label, systemImage: "link") { model.open(link.url) }
                                .buttonStyle(.link).multilineTextAlignment(.leading).help(link.url)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if let directory = documents.first?.url.deletingLastPathComponent() {
                Button("Open project folder", systemImage: "folder") { NSWorkspace.shared.open(directory) }
                    .buttonStyle(.link)
            }
        }
        .font(.system(size: 12))
        .padding(12)
    }

    @ViewBuilder private var preview: some View {
        if let selection {
            VStack(spacing: 8) {
                HStack {
                    Text(selection.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Button { revision += 1 } label: { Image(systemName: "arrow.clockwise") }.help("Reload document")
                    Button { NSWorkspace.shared.open(selection) } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Open in the default app to edit")
                }
                Group {
                    if let error {
                        ContentUnavailableView("Preview unavailable", systemImage: "doc", description: Text(error))
                    } else if let content {
                        switch content {
                        case .markdown(let text):
                            EmbeddedPlanDocument(markdown: text, sourceURL: selection, appearance: model.appearance,
                                accentStyle: model.accentStyle, canvasSelection: nil, open: open, select: { _ in })
                        case .text(let text):
                            FindableTextDocument(text: text, query: "", request: 0, searchesBackwards: false)
                        case .rendered(let resource):
                            ReadOnlyResourceDocument(url: resource, open: open)
                        }
                    } else { ProgressView("Loading document…") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }.padding(12)
        } else {
            ContentUnavailableView(error == nil ? "No project files" : "Project files unavailable",
                systemImage: "folder", description: Text(error ?? "Choose a project to see its documents."))
        }
    }

    private func reloadDocuments() {
        guard let project else { documents = []; links = []; selection = nil; return }
        do {
            let store = model.projectContextStore
            try store.ensurePlan(for: project)
            documents = try store.documents(projectID: project.id)
            links = try store.links(projectID: project.id)
            error = nil
            if selection.map({ url in !documents.contains { $0.url == url } }) ?? true {
                selection = documents.first?.url
            }
        } catch {
            documents = []; links = []; selection = nil
            self.error = error.localizedDescription
        }
    }

    /// Links inside a project document stay in this viewer when they point at
    /// another project document; everything else opens through the queue.
    private func open(_ url: URL) {
        let target = DocumentPaneLocation.normalized(url) ?? url
        if let document = documents.first(where: { $0.url.standardizedFileURL == target.standardizedFileURL }) {
            selection = document.url
        } else {
            model.open(target.absoluteString)
        }
    }
}
