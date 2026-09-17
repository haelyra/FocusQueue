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
                Button("All projects") { model.selectProject(nil) }
                ForEach(model.activeProjects) { project in
                    Button(project.name) { model.selectProject(project.id) }
                }
                if model.hasUnassignedTasks {
                    Button("Unassigned") { model.selectProject(ProjectCatalog.unassignedID) }
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
            Button("Unassigned") { Task { await model.assignProject(nil, to: ticket.id) } }
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
                        Text(project.repositoryPath).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        if project.archivedAt != nil { Text("Archived · history remains in All projects").font(.caption) }
                    }
                    Spacer()
                    Button("Edit") { editor = project }
                }
            }
            if model.config.projects.isEmpty { Text("Add a project to organize tasks by repository.").foregroundStyle(.secondary) }
            Button("Add project", systemImage: "folder.badge.plus") {
                editor = ProjectDefinition(name: "", repositoryPath: "")
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
            Text("Aliases let this project recognize another clone or fork. Existing agent workspaces stay in place.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = model.projectError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                if model.config.projects.contains(where: { $0.id == project.id }) {
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
                    let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
                    project.remote = url.isEmpty ? nil : url
                    project.remoteAliases = aliases.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    Task { if await model.saveProject(project) { dismiss() } }
                }.buttonStyle(.borderedProminent)
                    .disabled(project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !project.repositoryPath.hasPrefix("/"))
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
                Text("Unassigned").tag("")
                ForEach(model.activeProjects) { Text($0.name).tag($0.id) }
            }
            if let error = model.projectError { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create task") {
                    saving = true
                    Task {
                        if await model.createTask(title: title, summary: summary, projectID: projectID.isEmpty ? nil : projectID) { dismiss() }
                        saving = false
                    }
                }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.disabled(saving)
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 480)
            .onAppear { projectID = model.selectedProject?.id ?? "" }
    }
}
