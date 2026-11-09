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
        VStack(alignment: .leading, spacing: 6) {
          ForEach(process.currentSteps) { step in
            stepRow(step, status: process.status(of: step))
          }
        }
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
        Text("Track concept → planning → scaffolding → modules → QA → release for this project. Agents see the current phase in their launch briefs; module success criteria are accepted in order.")
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

  private func stepRow(_ step: DevelopmentStep, status: DevelopmentStepStatus) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Button {
        model.setDevelopmentStepStatus(status.next, stepID: step.id)
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
      .accessibilityLabel("\(step.title): \(status.label). Activate to mark \(status.next.label.lowercased()).")
      .help(status.help)
      VStack(alignment: .leading, spacing: 2) {
        Text(step.title).font(.system(size: 12, weight: .semibold))
        Text(step.summary).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if !step.artifacts.isEmpty {
          Text(step.artifacts.joined(separator: " · "))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.tertiary).lineLimit(1)
        }
      }
      Spacer(minLength: 4)
      Text(status.label.uppercased())
        .font(.system(size: 9, weight: .bold)).tracking(0.5)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Modules

  @ViewBuilder private func modulesSection(_ project: ProjectDefinition) -> some View {
    if let process = model.developmentProcess {
      VStack(alignment: .leading, spacing: 8) {
        ProjectTabHeading(
          title: "Modules",
          detail: "\(process.modules.filter(\.criteriaAccepted).count)/\(process.modules.count) accepted")
        if process.modules.isEmpty {
          Text("No modules yet. Module design files land in Planning; success criteria are accepted in order.")
            .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(process.modules) { module in
          moduleRow(module, modules: process.modules)
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

  private func moduleRow(_ module: DevelopmentModule, modules: [DevelopmentModule]) -> some View {
    let blockedBy = modules.prefix(while: { $0.id != module.id }).first { !$0.criteriaAccepted }
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Image(systemName: module.criteriaAccepted ? "checkmark.seal.fill" : "seal")
          .foregroundStyle(module.criteriaAccepted ? Color.green : Color.secondary)
        Text(module.name).font(.system(size: 12, weight: .semibold))
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
        Text(file).font(.system(size: 10, design: .monospaced))
          .foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
      }
    }
    .padding(.vertical, 2)
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
  /// Tap cycles forward: pending → in progress → done → accepted.
  var next: DevelopmentStepStatus {
    switch self {
    case .pending: .inProgress
    case .inProgress: .done
    case .done: .accepted
    case .accepted: .accepted
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
    case .pending: "Pending. Click to mark active."
    case .inProgress: "In progress. Click to mark done."
    case .done: "Done. Click to record human acceptance."
    case .accepted: "Accepted by human review."
    }
  }
}
