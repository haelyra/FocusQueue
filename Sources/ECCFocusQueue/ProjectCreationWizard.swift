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
  @State private var githubAccount: String?
  @State private var githubCheck: ProjectGitHubRepositoryCheck?
  @State private var githubError: String?
  @State private var checkingGitHub = false
  @State private var checkedGitHubInput: GitHubCheckInput?
  @State private var checkRequest = 0
  @Environment(\.dismiss) private var dismiss
  private let service: ProjectSetupService

  private struct GitHubCheckInput: Equatable {
    let directory: String
    let repository: String
    let create: Bool
    let refresh: Int
  }

  init(model: QueueViewModel, draft: ProjectSetupDraft = ProjectSetupDraft(),
       step: ProjectCreationStep = .folder, discovery: ProjectFolderDiscovery? = nil,
       service: ProjectSetupService = ProjectSetupService()) {
    self.model = model
    self.service = service
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
          .help(canContinue ? "" : "Fill in the fields marked Required")
      }.disabled(busy)
    }
    .textFieldStyle(.roundedBorder).padding(22).frame(width: 620, height: 590)
    .interactiveDismissDisabled(busy)
    .task(id: githubCheckInput) { await checkGitHub() }
  }

  private var folderQuestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("What is your project called?").font(.headline)
      TextField("Project name", text: $draft.name)
        .requiredField(missing: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Text("Task prefix").font(.headline)
      TextField("Choose 2 to 5 letters, e.g. APP", text: $draft.taskPrefix)
        .requiredField(missing: !draft.hasValidTaskPrefix)
      Text("The letters before each task number. For example, APP creates APP-001 and APP-002. Use letters only, without spaces or numbers.")
        .font(.caption).foregroundStyle(.secondary)
      if !draft.taskPrefix.isEmpty && !draft.hasValidTaskPrefix {
        Text("Enter 2 to 5 letters. Spaces, numbers, and punctuation are not accepted.").font(.caption).foregroundStyle(.orange)
      }
      Text("Working folder").font(.headline).padding(.top, 8)
      Toggle("Create new folder", isOn: Binding(get: { draft.folderMode == .new }, set: {
        draft.folderMode = $0 ? .new : .existing
      }))
      HStack {
        TextField(draft.folderMode == .new ? "Parent folder for the new project" : "Existing project folder", text: $draft.folderPath)
          .requiredField(missing: !draft.folderPath.hasPrefix("/"))
        Button("Choose…") { chooseFolder() }
      }
      if draft.folderMode == .new {
        TextField("New folder name", text: $draft.newFolderName)
          .requiredField(missing: draft.newFolderName.isEmpty)
        if !draft.folderPath.isEmpty && !draft.newFolderName.isEmpty {
          Text("Create: \(draft.workingFolder(supportDirectory: model.projectContextStore.root).path)")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      Text(draft.folderMode == .new ? "The folder is created when you submit the final review."
        : "We will look for Git remotes, a PRD, and other documentation in this folder.")
        .font(.caption).foregroundStyle(.secondary)
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
      Toggle("Create new GitHub repository (private)", isOn: $draft.createRepository)
        .disabled(!(discovery?.remotes.isEmpty ?? true))
        .onChange(of: draft.createRepository) { _, enabled in
          if enabled && draft.repositoryName.isEmpty {
            draft.repositoryName = draft.remote.isEmpty
              ? draft.name.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: "-") : draft.remote
          }
          if enabled { draft.remote = "" }
        }
      if !(discovery?.remotes.isEmpty ?? true) {
        Text("This folder already has a Git remote. Choose a separate folder to create a new repository.")
          .font(.caption).foregroundStyle(.secondary)
      }
      TextField(draft.createRepository ? "Repository name, owner/name, or GitHub URL" : "Git repository URL (optional)",
        text: Binding(get: { draft.createRepository ? draft.repositoryName : draft.remote }, set: {
          if draft.createRepository { draft.repositoryName = $0 } else { draft.remote = $0 }
        }))
      if !draft.createRepository, !draft.remote.isEmpty, ProjectCatalog.normalizedRemote(draft.remote) == nil {
        Text("Enter a repository URL such as https://github.com/owner/repo or git@github.com:owner/repo.git.")
          .font(.caption).foregroundStyle(.orange)
      }
      if !draft.createRepository && !draft.remote.isEmpty {
        Button("Continue without a repository URL") { draft.remote = "" }.buttonStyle(.link)
      }
      if draft.createRepository {
        if ProjectSetupService.githubRepositoryName(draft.repositoryName) == nil {
          Text("Use a repository name, owner/name, or a GitHub repository URL. Spaces are not accepted.")
            .font(.caption).foregroundStyle(.orange)
        }
        Text("Uses your GitHub CLI account. The repository will be private. Your files will stay local until you choose to commit and push them.")
          .font(.caption).foregroundStyle(.secondary)
      }
      githubStatus
    }
  }

  private var purposeQuestions: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("What is the purpose of this project?").font(.headline)
      TextField("What are you building, and why?", text: $draft.purpose, axis: .vertical).lineLimit(3...5)
        .requiredField(missing: draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
      LabeledContent("Folder", value: draft.workingFolder(supportDirectory: model.projectContextStore.root).path)
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
        && draft.hasValidTaskPrefix && draft.folderPath.hasPrefix("/")
        && (draft.folderMode == .existing || !draft.newFolderName.isEmpty)
    case .repository:
      draft.createRepository ? (githubCheck?.isAvailable == true && checkedGitHubInput == githubCheckInput)
        : (draft.remote.isEmpty || ProjectCatalog.normalizedRemote(draft.remote) != nil)
    case .purpose: !draft.purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .documentation, .review: true
    }
  }

  private func advance() {
    error = nil
    if step == .folder {
      do { try service.validateWorkingFolder(draft, supportDirectory: model.projectContextStore.root) }
      catch { self.error = error.localizedDescription; return }
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
    panel.title = draft.folderMode == .new ? "Choose a parent folder" : "Choose a working folder"
    if panel.runModal() == .OK, let url = panel.url {
      draft.folderPath = url.path
      if draft.name.isEmpty { draft.name = url.lastPathComponent }
    }
  }

  private var githubCheckInput: GitHubCheckInput? {
    guard step == .repository else { return nil }
    return .init(directory: draft.folderPath.isEmpty ? model.projectContextStore.root.path : draft.folderPath,
      repository: draft.createRepository ? draft.repositoryName : draft.remote,
      create: draft.createRepository, refresh: checkRequest)
  }

  private var githubStatus: some View {
    VStack(alignment: .leading, spacing: 8) {
      if checkingGitHub { ProgressView("Checking GitHub account and repository…").controlSize(.small) }
      if let githubAccount {
        Label("Signed in to GitHub as \(githubAccount)", systemImage: "person.crop.circle.badge.checkmark")
          .font(.callout).foregroundStyle(.green)
      }
      if let githubError { Text(githubError).font(.callout).foregroundStyle(.orange) }
      if checkedGitHubInput == githubCheckInput, let githubCheck {
        if draft.createRepository && !githubCheck.isAvailable {
          Text("\(githubCheck.fullName) already exists. Choose another name or use the existing repository.")
            .font(.callout).foregroundStyle(.orange)
          Button("Use existing repository") {
            draft.remote = githubCheck.url
            draft.createRepository = false
          }
        } else {
          Text(githubCheck.isAvailable
            ? (draft.createRepository ? "No repository found: \(githubCheck.fullName). GitHub confirms availability during creation."
              : "Repository not found or not accessible to this account. Check the URL and permissions.")
            : "Repository found: \(githubCheck.fullName)")
            .font(.caption).foregroundStyle(githubCheck.isAvailable && !draft.createRepository ? .orange : .secondary)
        }
      }
      HStack {
        Button("Check again") { checkRequest += 1 }
        if githubAccount == nil {
          Button("Copy sign-in command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ProjectSetupService.githubSignInCommand(
              at: githubCheckInput?.directory ?? draft.folderPath), forType: .string)
          }
        }
      }.controlSize(.small)
      if githubAccount == nil && !checkingGitHub {
        Text("Run the copied command in your terminal to sign in from the selected folder, then Check again.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func checkGitHub() async {
    guard let input = githubCheckInput else { return }
    githubAccount = nil
    githubCheck = nil
    githubError = nil
    checkedGitHubInput = nil
    checkingGitHub = true
    defer { if githubCheckInput == input { checkingGitHub = false } }
    do {
      try await Task.sleep(for: .milliseconds(350))
      let account = try await service.githubAccount(at: input.directory)
      guard !Task.isCancelled, githubCheckInput == input else { return }
      githubAccount = account
      let isGitHubURL = ProjectCatalog.normalizedRemote(input.repository)?.hasPrefix("github.com/") == true
      if !input.repository.isEmpty, (input.create || isGitHubURL),
        ProjectSetupService.githubRepositoryName(input.repository) != nil {
        let result = try await service.checkGitHubRepository(input.repository, account: account, at: input.directory)
        guard !Task.isCancelled, githubCheckInput == input else { return }
        githubCheck = result
      }
      checkedGitHubInput = input
    } catch is CancellationError {
      // The next input owns the status after an edit or Back.
    } catch {
      guard !Task.isCancelled, githubCheckInput == input else { return }
      if error as? ProjectGitHubError == .signInRequired { githubAccount = nil }
      githubError = error.localizedDescription
      checkedGitHubInput = input
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

extension View {
  /// Outlines a required field that is still empty or invalid, so the reason
  /// Continue is unavailable is visible where it needs fixing.
  func requiredField(missing: Bool) -> some View {
    overlay(alignment: .topTrailing) {
      if missing {
        Text("Required").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
          .padding(.horizontal, 5).offset(y: -14)
          .accessibilityHidden(true)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 6).stroke(.orange, lineWidth: missing ? 1.5 : 0)
        .allowsHitTesting(false)
    }
    .accessibilityHint(missing ? "Required" : "")
  }
}
