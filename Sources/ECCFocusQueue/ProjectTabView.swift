import AppKit
import FocusQueueCore
import SwiftUI

/// The Project tab: context files, the development process tracker, and live
/// progress for the selected project. Opened from the button beside the project
/// title; lives where Focus/Completed/QChat render.
struct ProjectTabView: View {
  let model: QueueViewModel
  @State private var newModuleName = ""
  @State private var showsModuleComposer = false
  @State private var showsModuleFiles = false
  @State private var showsStepModuleFiles = false

  private var project: ProjectDefinition? { model.selectedProject }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if let project {
          processSection(project)
          modulesSection(project)
          filesSection(project)
          progressSection(project)
        } else {
          ContentUnavailableView {
            Label("No project selected", systemImage: "folder.badge.questionmark")
          } description: {
            Text("Choose a project from the title menu to see its process, files, and progress.")
          }
          .frame(maxWidth: .infinity, minHeight: 240)
        }
      }
      .padding(.horizontal, 2).padding(.vertical, 2)
    }.scrollIndicators(.automatic)
  }

  // MARK: - Development process

  @ViewBuilder private func processSection(_ project: ProjectDefinition) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      ProjectTabHeading(title: "Development process",
                        detail: model.developmentProcess?.currentPhase.title ?? "off")
      if let process = model.developmentProcess {
        phaseStepper(process)
        stewardLine(process, projectID: project.id)
        VStack(alignment: .leading, spacing: 6) {
          ForEach(process.currentSteps) { step in
            stepRow(step, status: process.status(of: step), process: process)
          }
        }
        contractsRow(projectID: project.id)
        if let error = model.developmentProcessError {
          HStack(spacing: 6) {
            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
            Spacer()
            Button("Dismiss") { model.dismissDevelopmentProcessError() }.font(.caption)
          }
        }
        Text(DevelopmentProcessCatalog.brief(for: process.currentPhase))
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Track concept → planning → scaffolding → modules → QA → release for this project. The placement model links new tasks and files to steps in the background, task status moves linked steps, and you accept each step. Agents get one line naming their step.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button {
          model.setDevelopmentProcessEnabled(true)
        } label: {
          Label("Enable development process", systemImage: "checkmark.seal")
            .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
        .accessibilityLabel("Enable development process for \(project.name)")
      }
    }
    .padding(12)
    .notificationSurface(radius: 16)
  }

  private func phaseStepper(_ process: DevelopmentProcess) -> some View {
    HStack(spacing: 4) {
      ForEach(DevelopmentPhase.allCases, id: \.self) { phase in
        let isCurrent = phase == process.currentPhase
        Button {
          model.setDevelopmentPhase(phase)
        } label: {
          Text(phase.title)
            .font(.system(size: 10, weight: isCurrent ? .bold : .medium))
            .lineLimit(1).minimumScaleFactor(0.7)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(
              isCurrent ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
              in: Capsule())
            .overlay(Capsule().stroke(
              isCurrent ? Color.accentColor : Color.primary.opacity(0.12),
              lineWidth: isCurrent ? 1.2 : 0.6))
            .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Move to \(phase.title) phase"
          + (isCurrent ? " (current)" : ""))
        .help(phase == process.currentPhase
          ? "Current phase"
          : "Move the project to \(phase.title)")
      }
    }
  }

  /// Who keeps the tracker current, when it last ran, and a manual Sync.
  private func stewardLine(_ process: DevelopmentProcess, projectID: String) -> some View {
    let running = model.developmentStewardProjectID == projectID
    let run = process.steward
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Group {
        if running {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: run?.error == nil ? "wand.and.stars" : "exclamationmark.triangle")
            .foregroundStyle(run?.error == nil ? Color.secondary : Color.orange)
        }
      }
      .font(.system(size: 10)).frame(width: 14)
      Text(stewardCaption(run, running: running))
        .font(.caption).foregroundStyle(run?.error == nil ? Color.secondary : Color.orange)
        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 4)
      Button {
        model.syncDevelopmentProcess()
      } label: {
        Label("Sync", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold))
      }
      .buttonStyle(.borderless).controlSize(.small)
      .disabled(model.developmentStewardProjectID != nil)
      .help("Link new tasks and project files to steps now with the placement model")
      .accessibilityLabel("Sync development process from tasks and files")
    }
  }

  private func stewardCaption(_ run: DevelopmentStewardRun?, running: Bool) -> String {
    if running { return "Reviewing new tasks and files…" }
    guard let run else { return "Updates itself from task status and project files." }
    let when = run.ranAt.formatted(.relative(presentation: .named))
    if let error = run.error { return "Last sync failed \(when): \(error)" }
    let model = run.model.map { " · \($0)" } ?? ""
    return "Synced \(when)\(model). \(run.summary ?? "")"
  }

  private func stepRow(_ step: DevelopmentStep, status: DevelopmentStepStatus,
                       process: DevelopmentProcess) -> some View {
    let state = process.steps[step.id]
    return stepRowContent(step, status: status, state: state, process: process)
  }

  private func stepRowContent(_ step: DevelopmentStep, status: DevelopmentStepStatus,
                              state: DevelopmentStepState?, process: DevelopmentProcess) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Button {
        model.setDevelopmentStepStatus(status.completeAdvance, stepID: step.id)
      } label: {
        Image(systemName: status.systemImage)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(status == .accepted ? Color.green
            : status == .done ? Color.accentColor
            : status == .inProgress ? Color.orange : Color.secondary.opacity(0.5))
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .contextMenu {
        Button("Mark incomplete", systemImage: "arrow.uturn.backward") {
          model.setDevelopmentStepStatus(.pending, stepID: step.id)
        }
      }
      .accessibilityLabel("\(step.title): \(status.label). Activate to mark \(status.completeAdvance.label.lowercased()).")
      .help(status.help)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(step.title).font(.system(size: 12, weight: .semibold))
          if step.isExperimental {
            Text("EXPERIMENTAL · OPTIONAL")
              .font(.system(size: 8, weight: .bold)).tracking(0.4)
              .padding(.horizontal, 5).padding(.vertical, 1.5)
              .foregroundStyle(Color.purple)
              .background(Color.purple.opacity(0.12), in: Capsule())
              .help("Tracked but never required: the phase can be accepted while this step stays open.")
              .accessibilityLabel("Experimental, optional step")
          }
        }
        Text(step.summary).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if step.id == "contract" {
          Text("Generate, edit, and sign off both in Agent contracts below.")
            .font(.caption2).foregroundStyle(.secondary)
        } else if Self.moduleFolderSteps.contains(step.id) {
          moduleFolderChip()
        } else if !process.artifacts(of: step).isEmpty {
          artifactChips(step, state: state, process: process)
        }
        if process.usesPlanningGuidelines, !step.guidelines().isEmpty {
          guidelineChips(step)
        }
        if let note = state?.note, !note.isEmpty {
          Label(note, systemImage: state?.isAutomatic == true ? "wand.and.stars" : "person")
            .labelStyle(.titleAndIcon)
            .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            .help(state?.source == .steward ? "Evidence from the background steward"
              : state?.source == .tasks ? "Derived from linked task status" : "Your note")
        }
      }
      Spacer(minLength: 4)
      Text(status.label.uppercased())
        .font(.system(size: 9, weight: .bold)).tracking(0.5)
        .foregroundStyle(.secondary)
    }
  }

  /// One clickable chip per step document, stacked one per line so each file
  /// is easy to scan and find: opens the file in the document
  /// viewer, where the review toggle checks it off. Green once reviewed,
  /// accent while awaiting review, dimmed until the file exists.
  private func artifactChips(_ step: DevelopmentStep, state: DevelopmentStepState?,
                             process: DevelopmentProcess) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(process.artifacts(of: step), id: \.self) { artifact in
        let checked = state?.checkedArtifacts.contains(artifact) ?? false
        let url = model.developmentArtifactURL(artifact)
        let file = process.fileName(forArtifact: artifact)
        let exists = url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        Button {
          if let url, exists, let projectID = project?.id {
            model.openDocumentViewer(url, scope: .project(projectID))
          }
        } label: {
          Label(artifact, systemImage: checked ? "checkmark.circle.fill" : exists ? "doc.fill" : "doc")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(checked ? Color.green.opacity(0.14) : Color.primary.opacity(exists ? 0.08 : 0.03),
                        in: Capsule())
            .foregroundStyle(checked ? Color.green : exists ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!exists)
        .help((checked ? "Reviewed. Click to open."
              : exists ? "Click to open, then mark it reviewed in the viewer."
              : "Not created yet.") + (file == artifact ? "" : " This project keeps it as \(file)."))
        .accessibilityLabel("\(artifact), \(checked ? "reviewed" : exists ? "not reviewed" : "missing")")
      }
    }
  }

  /// Experimental: the planning guideline for each of the step's files, opened
  /// read-only in the document viewer. Shown only for projects that opt in.
  private func guidelineChips(_ step: DevelopmentStep) -> some View {
    let names = step.guidelines()
    return HStack(spacing: 6) {
      ForEach(names, id: \.self) { name in
        Button {
          model.openDevelopmentGuideline(name)
        } label: {
          Label(names.count == 1 ? "Guideline"
                  : name.replacingOccurrences(of: "-guideline.md", with: "").replacingOccurrences(of: "-", with: " ")
                    + " guideline",
                systemImage: "book.closed")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(Color.purple.opacity(0.10), in: Capsule())
            .foregroundStyle(Color.purple)
        }
        .buttonStyle(.plain)
        .help("Open \(name): the file's format, generator prompt, self-check, and your review checklist. Experimental.")
        .accessibilityLabel("Open \(name)")
      }
    }
  }

  /// The project's engineering and orchestrator contracts, in every phase. Only
  /// signed text reaches agents: engineering launches get agent-contract.md, task
  /// chat, project QChat, and orchestrator launches get orchestration.md.
  private func contractsRow(projectID: String) -> some View {
    let statuses = model.developmentContracts
    let generating = model.contractGenerationProjectID == projectID
    let anyFile = statuses.contains { $0.state != .missing || $0.hasDraft }
    return VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: "signature").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
        Text("Agent contracts").font(.system(size: 12, weight: .semibold))
        Spacer(minLength: 4)
        if generating {
          ProgressView().controlSize(.mini)
          Text("Drafting…").font(.caption).foregroundStyle(.secondary)
        } else {
          Button {
            model.generateAgentContracts()
          } label: {
            Label(anyFile ? "Regenerate" : "Generate", systemImage: "wand.and.stars")
              .font(.system(size: 11, weight: .semibold))
          }
          .buttonStyle(.borderless).controlSize(.small)
          .disabled(model.contractGenerationProjectID != nil)
          .help(anyFile
            ? "Draft new versions beside the current files with your QChat model. The live contracts change only when you sign off."
            : "Draft both contracts from the planning documents with your QChat model, then review and sign off.")
          .accessibilityLabel(anyFile ? "Regenerate agent contracts" : "Generate agent contracts")
        }
      }
      HStack(spacing: 6) {
        ForEach(statuses, id: \.role) { status in contractChip(status) }
        if let review = model.developmentArtifactURL(AgentContract.reviewFileName),
           FileManager.default.fileExists(atPath: review.path) {
          Button {
            model.openDocumentViewer(review, scope: .project(projectID))
          } label: {
            Label("Review notes", systemImage: "list.bullet.clipboard")
              .font(.system(size: 10, weight: .semibold))
          }
          .buttonStyle(.borderless)
          .help("Lint results and the generator's notes from the last generation")
        }
      }
      Text("Signed contracts reach agents by role: engineering launches get the engineering contract; task chat, project QChat, and orchestrator launches get the orchestrator contract. Saving one in the viewer signs it off.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(8)
    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
  }

  private func contractChip(_ status: AgentContractStatus) -> some View {
    let (label, image, color): (String, String, Color) = switch status.state {
    case .live: ("live", "checkmark.seal.fill", .green)
    case .pending: ("changes pending sign-off", "exclamationmark.circle.fill", .orange)
    case .unsigned: ("not signed off", "signature", .accentColor)
    case .missing: (status.hasDraft ? "draft only" : "missing", status.hasDraft ? "doc.badge.ellipsis" : "doc", .secondary)
    }
    let openable = status.hasDraft || FileManager.default.fileExists(atPath: status.fileURL.path)
    return Button {
      model.openAgentContract(status)
    } label: {
      HStack(spacing: 4) {
        Image(systemName: image)
        Text(status.role.fileName).font(.system(size: 10, weight: .semibold, design: .monospaced))
        Text("· \(label)").font(.system(size: 10, weight: .medium))
        if status.hasDraft, status.state != .missing {
          Text("· draft").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
        }
        if !status.lint.isEmpty {
          Text("· \(status.lint.count) lint").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
        }
      }
      .padding(.horizontal, 6).padding(.vertical, 3)
      .background(color.opacity(status.state == .missing ? 0.04 : 0.12), in: Capsule())
      .foregroundStyle(color)
    }
    .buttonStyle(.plain)
    .disabled(!openable)
    .contextMenu {
      if status.hasDraft {
        Button("Discard draft", systemImage: "trash") { model.discardAgentContractDraft(status) }
      }
      if status.signoff != nil {
        Button("Revoke sign-off", systemImage: "xmark.seal") { model.revokeAgentContract(status.role) }
      }
    }
    .help(contractHelp(status))
    .accessibilityLabel("\(status.role.title) contract, \(label)\(status.hasDraft ? ", draft waiting" : "")")
  }

  private func contractHelp(_ status: AgentContractStatus) -> String {
    var lines: [String] = []
    switch status.state {
    case .live: lines.append("Signed off\(status.signoff.map { " " + $0.signedAt.formatted(.relative(presentation: .named)) } ?? ""). \(status.role.title) agents get its Essentials.")
    case .pending: lines.append("Changed after sign-off; agents still get the signed version. Open it and sign off to make the change live.")
    case .unsigned: lines.append("No agent gets it until you sign it off. Open it, edit if needed, then sign off.")
    case .missing: lines.append(status.hasDraft ? "Only a draft exists. Open it and sign it off." : "Not written yet. Generate drafts both contracts.")
    }
    if status.hasDraft, status.state != .missing { lines.append("A draft waits beside it; opening shows both side by side.") }
    lines += status.lint.prefix(6).map { "Lint: \($0.text)" }
    if status.lint.count > 6 { lines.append("… \(status.lint.count - 6) more lint warnings") }
    return lines.joined(separator: "\n")
  }

  // MARK: - Modules

  @ViewBuilder private func modulesSection(_ project: ProjectDefinition) -> some View {
    if let process = model.developmentProcess {
      let files = model.developmentModuleFiles
      let untracked = files.filter { $0.isModule && DevelopmentModuleFiles.module(for: $0, in: process.modules) == nil }
      VStack(alignment: .leading, spacing: 8) {
        ProjectTabHeading(
          title: "Modules",
          detail: "\(process.modules.filter(\.criteriaAccepted).count)/\(process.modules.count) accepted")
        moduleFolderButton(files)
        if process.modules.isEmpty && untracked.isEmpty {
          Text("No modules yet. Optional and experimental: add a module when its design file starts, even as a stub. Success criteria are accepted in order and never block a phase.")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(process.modules) { module in
          moduleRow(module, modules: process.modules)
        }
        if !untracked.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            Text("Not tracked yet").font(.caption.bold()).foregroundStyle(.secondary)
            ForEach(untracked) { file in untrackedModuleRow(file) }
            Text("Track modules in dependency order: success criteria are accepted in the order tracked.")
              .font(.caption2).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          .padding(.top, process.modules.isEmpty ? 0 : 4)
        }
        if showsModuleComposer {
          HStack(spacing: 6) {
            TextField("Module name", text: $newModuleName)
              .textFieldStyle(.roundedBorder)
              .font(.system(size: 12))
              .onSubmit { addModule() }
            Button("Add") { addModule() }
              .buttonStyle(.bordered).controlSize(.small)
              .disabled(newModuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { showsModuleComposer = false; newModuleName = "" }
              .buttonStyle(.borderless).controlSize(.small)
          }
        } else {
          Button {
            showsModuleComposer = true
          } label: {
            Label("Add module", systemImage: "plus")
              .font(.system(size: 11, weight: .semibold))
          }
          .buttonStyle(.borderless).controlSize(.small)
          .accessibilityLabel("Add a module to \(project.name)")
        }
      }
      .padding(12)
      .notificationSurface(radius: 16)
    }
  }

  /// The module folder, browsed like a task's Context: every module's design
  /// (I/O) file plus shared files, from the repository and the project folder.
  private func moduleFolderButton(_ files: [DevelopmentModuleFile]) -> some View {
    let modules = files.filter(\.isModule).count
    let shared = files.count - modules
    return Button { showsModuleFiles.toggle() } label: {
      HStack(spacing: 6) {
        Label("View Module Files", systemImage: "folder")
        Spacer(minLength: 4)
        Text(files.isEmpty ? "empty"
             : "\(modules) \(modules == 1 ? "module" : "modules")" + (shared > 0 ? " · \(shared) shared" : ""))
          .font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.bordered).controlSize(.regular)
    .font(.system(size: 12, weight: .semibold))
    .help("Browse each module's design file: its I/O contract, success criteria, and debug logs")
    .accessibilityLabel("View module files, \(modules) modules, \(shared) shared files")
    .popover(isPresented: $showsModuleFiles, arrowEdge: .trailing) {
      ModuleFilesGridView(model: model) { showsModuleFiles = false }
        .frame(width: 360, height: 460)
    }
  }

  /// Steps whose work is the module files, at most one per phase, since the
  /// chips share one popover.
  static let moduleFolderSteps: Set<String> = ["modules", "phase0-qa", "build"]

  /// The module folder as a step chip, on the step that writes or builds modules.
  private func moduleFolderChip() -> some View {
    let count = model.developmentModuleFiles.count
    return Button { showsStepModuleFiles.toggle() } label: {
      Label(count == 0 ? "Module files" : "Module files · \(count)", systemImage: "folder")
        .labelStyle(.titleAndIcon)
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(Color.primary.opacity(count == 0 ? 0.03 : 0.08), in: Capsule())
        .foregroundStyle(count == 0 ? Color.secondary : Color.accentColor)
    }
    .buttonStyle(.plain)
    .help("Browse the module folder: each module's design (I/O) file.")
    .accessibilityLabel("Module files, \(count) items")
    .popover(isPresented: $showsStepModuleFiles, arrowEdge: .trailing) {
      ModuleFilesGridView(model: model) { showsStepModuleFiles = false }
        .frame(width: 360, height: 460)
    }
  }

  /// A module design file nobody tracks yet: opens on click; Track adds it to
  /// the end of the in-order review.
  private func untrackedModuleRow(_ file: DevelopmentModuleFile) -> some View {
    HStack(spacing: 8) {
      Button { model.openDevelopmentModuleFile(file.url) } label: {
        HStack(spacing: 6) {
          Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 14)
          Text(file.displayTitle.replacingOccurrences(of: "`", with: ""))
            .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
          Spacer(minLength: 4)
          Text(file.fileName).font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(file.url.path)
      .accessibilityLabel("Open \(file.displayTitle)")
      Button("Track") { model.trackDevelopmentModuleFile(file) }
        .buttonStyle(.bordered).controlSize(.mini)
        .help("Add \(file.displayTitle) to the in-order success-criteria review")
        .accessibilityLabel("Track \(file.displayTitle)")
    }
  }

  private func moduleRow(_ module: DevelopmentModule, modules: [DevelopmentModule]) -> some View {
    let blockedBy = modules.prefix(while: { $0.id != module.id }).first { !$0.criteriaAccepted }
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: module.criteriaAccepted ? "checkmark.seal.fill" : "seal")
          .foregroundStyle(module.criteriaAccepted ? Color.green : Color.secondary)
        Text(Self.moduleTitle(module)).font(.system(size: 12, weight: .semibold))
        Spacer()
        if !module.criteriaAccepted {
          Button("Accept criteria") {
            model.acceptDevelopmentModuleCriteria(moduleID: module.id)
          }
          .buttonStyle(.bordered).controlSize(.mini)
          .disabled(blockedBy != nil)
          .help(blockedBy.map { "Accept \($0.name) first; reviews are sequential." }
            ?? "Accept this module's success criteria")
          .accessibilityLabel("Accept success criteria for \(module.name)")
        }
      }
      HStack(spacing: 12) {
        Toggle("Implemented", isOn: Binding(
          get: { module.implemented },
          set: { model.setDevelopmentModuleImplemented($0, moduleID: module.id) }))
        Toggle("QA verified", isOn: Binding(
          get: { module.qaAccepted },
          set: { model.setDevelopmentModuleQAAccepted($0, moduleID: module.id) }))
        .disabled(!module.implemented)
      }
      .toggleStyle(.checkbox)
      .font(.caption)
      .controlSize(.small)
      if let file = module.file, !file.isEmpty {
        let url = model.developmentModuleFileURL(module)
        Button { url.map(model.openDevelopmentModuleFile) } label: {
          Label(url.map { (Self.moduleFileLabel($0)) } ?? file,
                systemImage: url == nil ? "doc" : "doc.text")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(url == nil ? Color.secondary.opacity(0.6) : Color.accentColor)
            .lineLimit(1).truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .disabled(url == nil)
        .help(url.map { "Open \($0.path)" } ?? "Not written yet: \(file)")
        .accessibilityLabel(url == nil ? "\(file), not written yet" : "Open \(file)")
      }
    }
    .padding(.vertical, 2)
  }

  /// `M6 · Context storage` for catalog IDs; app-added modules keep their name.
  static func moduleTitle(_ module: DevelopmentModule) -> String {
    let id = module.id.lowercased()
    guard id.hasPrefix("m"), id.count > 1, id.dropFirst().allSatisfy(\.isNumber) else { return module.name }
    return "\(id.uppercased()) · \(module.name.replacingOccurrences(of: "`", with: ""))"
  }

  /// `docs/modules/m6-context.md` or `modules/m6-context.md`.
  static func moduleFileLabel(_ url: URL) -> String {
    ModuleFilesGridView.folderLabel(url.deletingLastPathComponent()) + "/" + url.lastPathComponent
  }

  private func addModule() {
    let name = newModuleName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    model.addDevelopmentModule(name: name, file: nil)
    newModuleName = ""
    showsModuleComposer = false
  }

  // MARK: - Files

  private func filesSection(_ project: ProjectDefinition) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      ProjectTabHeading(title: "Context & files", detail: "")
      ProjectFilesSection(model: model, projectID: project.id)
    }
    .padding(12)
    .notificationSurface(radius: 16)
  }

  // MARK: - Progress

  private func progressSection(_ project: ProjectDefinition) -> some View {
    let open = model.openTickets
    let blocked = open.filter { $0.status.lowercased() == "blocked" }
    let agents = open.flatMap { model.subtasks(for: $0.id) }
    let working = agents.filter { $0.status == .working }
    let needingAttention = agents.filter { $0.attention != nil }
    return VStack(alignment: .leading, spacing: 8) {
      ProjectTabHeading(
        title: "Progress",
        detail: "\(model.completedTodayTickets.count) done today")
      HStack(spacing: 14) {
        progressMetric("\(open.count)", label: "open")
        progressMetric("\(working.count)", label: "working")
        progressMetric("\(blocked.count)", label: "blocked")
        progressMetric("\(needingAttention.count)", label: "attention")
        Spacer()
      }
      if !working.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(working.prefix(4)) { agent in
            HStack(spacing: 6) {
              Circle().fill(Color.green).frame(width: 6, height: 6)
              Text(agent.title).font(.caption).lineLimit(1)
              Spacer()
              if !agent.progressSummary.isEmpty {
                Text(agent.progressSummary).font(.caption2).foregroundStyle(.secondary)
                  .lineLimit(1).truncationMode(.tail)
                  .frame(maxWidth: 220, alignment: .trailing)
              }
            }
          }
          if working.count > 4 {
            Text("\(working.count - 4) more working")
              .font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(12)
    .notificationSurface(radius: 16)
  }

  private func progressMetric(_ value: String, label: String) -> some View {
    VStack(spacing: 1) {
      Text(value).font(.system(size: 16, weight: .bold).monospacedDigit())
      Text(label.uppercased()).font(.system(size: 8, weight: .bold)).tracking(0.5)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(value) \(label)")
  }
}

/// Matches the queue's SectionCapsule heading without sharing its private type.
private struct ProjectTabHeading: View {
  let title: String
  let detail: String
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    HStack {
      Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
      Spacer()
      Text(detail).font(.system(size: 11, weight: .semibold).monospacedDigit())
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, 11).frame(height: 27)
    .background(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05), in: Capsule())
    .overlay(Capsule().stroke(Color.primary.opacity(0.1), lineWidth: 0.6))
  }
}

extension DevelopmentStepStatus {
  /// Click moves toward complete: pending or active → done → accepted.
  /// Right-click on the marker offers "Mark incomplete".
  var completeAdvance: DevelopmentStepStatus {
    switch self {
    case .pending, .inProgress: .done
    case .done, .accepted: .accepted
    }
  }

  var label: String {
    switch self {
    case .pending: "Pending"
    case .inProgress: "Active"
    case .done: "Done"
    case .accepted: "Accepted"
    }
  }

  var systemImage: String {
    switch self {
    case .pending: "circle"
    case .inProgress: "circle.lefthalf.filled"
    case .done: "checkmark.circle.fill"
    case .accepted: "checkmark.seal.fill"
    }
  }

  var help: String {
    switch self {
    case .pending: "Pending. Click to mark complete; right-click keeps it pending."
    case .inProgress: "In progress. Click to mark complete; right-click to mark incomplete."
    case .done: "Done. Click to record human acceptance; right-click to mark incomplete."
    case .accepted: "Accepted by human review. Right-click to mark incomplete."
    }
  }
}
