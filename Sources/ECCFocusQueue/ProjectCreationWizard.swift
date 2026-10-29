import AppKit
import FocusQueueCore
import SwiftUI
import UniformTypeIdentifiers

enum ProjectCreationStep: Int, CaseIterable {
  case folder, repository, purpose, documentation, review
  var title: String {
    switch self {
    case .folder: "Project"
    case .repository: "Repository"
    case .purpose: "Purpose"
    case .documentation: "Documents"
    case .review: "Review"
    }
  }
}

struct ProjectCreationWizard: View {
  let model: QueueViewModel
  @State private var draft = ProjectSetupDraft()
  @State private var step = ProjectCreationStep.folder
  @State private var discovery: ProjectFolderDiscovery?
  @State private var discoveredFolder: String?
  @State private var isDiscovering = false
  @State private var isSubmitting = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss
  private let service = ProjectSetupService()

  init(model: QueueViewModel, draft: ProjectSetupDraft = ProjectSetupDraft(),
       step: ProjectCreationStep = .folder, discovery: ProjectFolderDiscovery? = nil) {
    self.model = model
    _draft = State(initialValue: draft)
    _step = State(initialValue: step)
    _discovery = State(initialValue: discovery)
  }

  private var busy: Bool { isDiscovering || isSubmitting || model.isSavingProject }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Create a project").font(.title2.bold())
      HStack(spacing: 8) {
        ForEach(ProjectCreationStep.allCases, id: \.rawValue) { item in
          Text("\(item.rawValue + 1). \(item.title)")
            .font(.caption.weight(item == step ? .bold : .regular))
            .foregroundStyle(item == step ? Color.accentColor : .secondary)
          if item != .review { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Step \(step.rawValue + 1) of 5: \(step.title)")
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          switch step {
          case .folder: folderQuestions
          case .repository: repositoryQuestions
          case .purpose: purposeQuestions
          case .documentation: documentationQuestions
          case .review: review
          }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(2).disabled(busy)
      }
      if let error { Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
      if isDiscovering { ProgressView("Looking for repositories and documentation…").controlSize(.small) }
      if isSubmitting { ProgressView(draft.createRepository ? "Creating repository and project…" : "Saving project…").controlSize(.small) }
      Divider()
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if step != .folder {
          Button("Back") { error = nil; step = ProjectCreationStep(rawValue: step.rawValue - 1)! }
        }
        Button(step == .review ? "Create project" : "Continue") { advance() }
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(!canContinue)
      }.disabled(busy)
    }
    .textFieldStyle(.roundedBorder).padding(22).frame(width: 620, height: 590)
    .interactiveDismissDisabled(busy)
  }

  private var folderQuestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("What is your project called?").font(.headline)
      TextField("Project name", text: $draft.name)
        .onChange(of: draft.name) { old, new in
          if draft.taskPrefix.isEmpty || draft.taskPrefix == ProjectCatalog.suggestedPrefix(name: old, id: draft.id) {
            draft.taskPrefix = ProjectCatalog.suggestedPrefix(name: new, id: draft.id)
          }
        }
      TextField("Task prefix, e.g. APP", text: $draft.taskPrefix)
      Text("Tasks will use \(draft.taskPrefix.uppercased())-001, \(draft.taskPrefix.uppercased())-002, and so on.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Do you already have a project folder?").font(.headline).padding(.top, 8)
      Picker("Project folder", selection: $draft.folderMode) {
        Text("Start a new project").tag(ProjectSetupDraft.FolderMode.new)
        Text("Connect an existing folder").tag(ProjectSetupDraft.FolderMode.existing)
      }.pickerStyle(.radioGroup)
      if draft.folderMode == .existing {
        HStack {
          TextField("Existing project folder", text: $draft.folderPath)
          Button("Choose…") { chooseFolder() }
        }
        Text("We will look for Git remotes, a PRD, and other documentation in this folder.")
          .font(.caption).foregroundStyle(.secondary)
      } else {
        Text("Focus Queue will create a workspace for your project. To use a folder elsewhere, choose Connect an existing folder.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private var repositoryQuestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Which repository belongs to this project?").font(.headline)
      if let repository = discovery?.repositoryPath {
        Label("Git repository found", systemImage: "checkmark.circle").foregroundStyle(.green)
        Text(repository).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
      }
      if let remotes = discovery?.remotes, !remotes.isEmpty {
        Text("Suggested main repository").font(.subheadline.bold())
        ForEach(remotes, id: \.name) { remote in
          Button {
            draft.remote = remote.url
            draft.createRepository = false
          } label: {
            HStack(alignment: .top) {
              Image(systemName: draft.remote == remote.url ? "checkmark.circle.fill" : "circle")
              VStack(alignment: .leading) {
                Text(remote.name)
                Text(remote.url).font(.caption).lineLimit(2)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(.bordered)
        }
      } else {
        Text("No repository URL detected. Add one below, create a repository, or continue without one.")
          .foregroundStyle(.secondary)
      }
      TextField("Git repository URL (optional)", text: $draft.remote).disabled(draft.createRepository)
      if !draft.createRepository, !draft.remote.isEmpty, ProjectCatalog.normalizedRemote(draft.remote) == nil {
        Text("Enter a repository URL such as https://github.com/owner/repo or git@github.com:owner/repo.git.")
          .font(.caption).foregroundStyle(.orange)
      }
      if !draft.createRepository && !draft.remote.isEmpty {
        Button("Continue without a repository URL") { draft.remote = "" }.buttonStyle(.link)
      }
      Toggle("Create a new private GitHub repository", isOn: $draft.createRepository)
        .disabled(!(discovery?.remotes.isEmpty ?? true))
        .onChange(of: draft.createRepository) { _, enabled in
          if enabled {
            draft.remote = ""
            if draft.repositoryName.isEmpty {
              draft.repositoryName = draft.name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-")
            }
          }
        }
      if draft.createRepository {
        TextField("Repository name or owner/name", text: $draft.repositoryName)
        Text("Uses your GitHub CLI account. The repository will be private. Your files will stay local until you choose to commit and push them.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var purposeQuestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("What is the purpose of this project?").font(.headline)
      TextField("What are you building, and why?", text: $draft.purpose, axis: .vertical).lineLimit(3...5)
      Text("Who is it for? (optional)").font(.headline)
      TextField("Users, audience, or team", text: $draft.audience, axis: .vertical).lineLimit(2...3)
      Text("What would success look like? (optional)").font(.headline)
      TextField("Outcomes or acceptance criteria", text: $draft.successCriteria, axis: .vertical).lineLimit(2...4)
      Text("These answers become project guidance that your agents can read.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private var documentationQuestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Would you like to include a PRD or documentation?").font(.headline)
      Text("Select documents to copy into this project's Files. Original files stay in their current folder.")
        .font(.callout).foregroundStyle(.secondary)
      let candidates = Array(Set((discovery?.documents ?? []) + draft.documents)).sorted { $0.path < $1.path }
      if candidates.isEmpty { Text("No documentation found. Add files or start a PRD below.").foregroundStyle(.secondary) }
      ForEach(candidates, id: \.path) { url in
        Toggle(isOn: Binding(get: { draft.documents.contains(url) }, set: { selected in
          if selected { draft.documents.append(url) } else { draft.documents.removeAll { $0 == url } }
        })) {
          VStack(alignment: .leading, spacing: 2) {
            Text(url.lastPathComponent)
            Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
        }
      }
      Button("Add documents…") { chooseDocuments() }
      Toggle("Create a PRD starter from my answers", isOn: $draft.createPRD)
      Text("An imported Markdown PRD takes precedence over the starter. You can skip documentation and add it later.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var review: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Ready to create \(draft.name)?").font(.headline)
      LabeledContent("Task IDs", value: "\(draft.taskPrefix.uppercased())-###")
      LabeledContent("Folder", value: draft.folderMode == .existing ? draft.folderPath : "New workspace managed by Focus Queue")
      LabeledContent("Repository", value: draft.createRepository ? "Create \(draft.repositoryName) (private)" : (draft.remote.isEmpty ? "None" : draft.remote))
      Divider()
      Text(draft.purpose).textSelection(.enabled)
      if !draft.audience.isEmpty { LabeledContent("Audience", value: draft.audience) }
      if !draft.successCriteria.isEmpty { LabeledContent("Success", value: draft.successCriteria) }
      LabeledContent("Documentation", value: "\(draft.documents.count) selected file(s)\(draft.createPRD ? " + PRD starter if needed" : "")")
      Text("You can edit the project and its documents after setup.").font(.caption).foregroundStyle(.secondary)
    }
  }

  private var canContinue: Bool {
    switch step {
    case .folder:
      !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && draft.taskPrefix.range(of: "^[A-Za-z][A-Za-z0-9]{1,4}$", options: .regularExpression) != nil
        && (draft.folderMode == .new || draft.folderPath.hasPrefix("/"))
    case .repository:
      draft.createRepository ? !draft.repositoryName.isEmpty : (draft.remote.isEmpty || ProjectCatalog.normalizedRemote(draft.remote) != nil)
    case .purpose: !draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .documentation, .review: true
    }
  }

  private func advance() {
    error = nil
    if step == .folder {
      if model.config.projects.contains(where: {
        $0.name.caseInsensitiveCompare(draft.name.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
          || $0.taskPrefix == draft.taskPrefix.uppercased()
      }) {
        error = "This project name or task prefix is already in use. Choose a unique name and prefix."
        return
      }
      Task { await discoverFolderAndContinue() }
    } else if step == .documentation {
      do {
        // Validate before review as well as before final submission.
        try service.validate(draft, supportDirectory: model.projectContextStore.root, projects: model.config.projects)
        step = .review
      } catch { self.error = error.localizedDescription }
    } else if step == .review {
      isSubmitting = true
      Task {
        var submission = draft
        let saved = await model.createProject(&submission, service: service)
        draft = submission
        isSubmitting = false
        if saved { dismiss() } else { error = model.projectError }
      }
    } else { step = ProjectCreationStep(rawValue: step.rawValue + 1)! }
  }

  private func discoverFolderAndContinue() async {
    if draft.folderMode == .new {
      if discoveredFolder != nil { resetDiscovery() }
      step = .repository
      return
    }
    guard discoveredFolder != draft.folderPath else { step = .repository; return }
    isDiscovering = true
    defer { isDiscovering = false }
    do {
      let found = try await service.discover(folder: draft.folderPath)
      resetDiscovery()
      discovery = found
      discoveredFolder = draft.folderPath
      draft.repositoryPath = found.repositoryPath ?? ""
      draft.remote = found.suggestedRemote?.url ?? ""
      step = .repository
    } catch { self.error = error.localizedDescription }
  }

  private func resetDiscovery() {
    discovery = nil
    discoveredFolder = nil
    draft.repositoryPath = ""
    draft.remote = ""
    draft.createRepository = false
    draft.documents = []
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      draft.folderPath = url.path
      if draft.name.isEmpty { draft.name = url.lastPathComponent }
    }
  }

  private func chooseDocuments() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.pdf, .plainText, UTType(filenameExtension: "md") ?? .plainText,
      UTType(filenameExtension: "markdown") ?? .plainText]
    if panel.runModal() == .OK { draft.documents = Array(Set(draft.documents + panel.urls)).sorted { $0.path < $1.path } }
  }
}
