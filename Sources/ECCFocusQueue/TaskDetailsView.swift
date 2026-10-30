import FocusQueueCore
import Foundation
import SwiftUI

struct NewTaskBadge: View {
  var body: some View {
    Label("NEW", systemImage: "sparkles")
      .font(.system(size: 8, weight: .heavy))
      .tracking(0.45)
      .foregroundStyle(Color.accentColor)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.14), in: Capsule())
      .fixedSize()
      .accessibilityLabel("New unviewed task")
  }
}

struct TaskDeadlinePill: View {
  let ticket: DashboardTicket

  private var isOverdue: Bool {
    TaskTriagePolicy.hardDeadlineIsOverdue(for: ticket)
  }

  private var label: String {
    if let deadline = TaskTriagePolicy.hardDeadline(for: ticket) {
      return "Due \(deadline.formatted(date: .abbreviated, time: .omitted))"
    }
    return "Due \(ticket.dueDate ?? "")"
  }

  var body: some View {
    Label(label, systemImage: "calendar")
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(isOverdue ? Color.red : Color.orange)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background((isOverdue ? Color.red : Color.orange).opacity(0.12), in: Capsule())
      .fixedSize()
      .accessibilityLabel(isOverdue ? "Hard deadline overdue: \(label)" : "Hard deadline: \(label)")
  }
}

struct TaskDetailsView: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  let onClose: () -> Void

  @State private var includesDueDate: Bool
  @State private var draftDueDate: Date
  @State private var isSaving = false
  @State private var saveError: String?

  init(ticket: DashboardTicket, model: QueueViewModel, onClose: @escaping () -> Void) {
    self.ticket = ticket
    self.model = model
    self.onClose = onClose
    _includesDueDate = State(initialValue: TaskTriagePolicy.hasHardDeadline(ticket))
    _draftDueDate = State(initialValue: TaskTriagePolicy.hardDeadline(for: ticket) ?? Date())
  }

  private var agents: [TaskSubtask] {
    model.subtasks(for: ticket.id).filter { $0.hasAgent && $0.agentRemovedAt == nil }
  }

  private var activeAgentCount: Int {
    agents.filter { $0.status != .completed }.count
  }

  private var lastPromptAt: Date? {
    model.taskContexts[ticket.id]?.lastPromptAt
  }

  private var lastOutputAt: Date? {
    model.latestAgentOutput(for: ticket.id)
  }

  private var relativeDeadline: Date? {
    TaskTriagePolicy.relativeDeadline(
      for: ticket,
      lastPromptAt: lastPromptAt,
      lastOutputAt: lastOutputAt)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        header
        VStack(alignment: .leading, spacing: 10) {
          detailRow("Start date", value: dateText(TaskTriagePolicy.date(from: ticket.createdAt)))
          detailRow("Hard due date", value: hardDeadlineText)
          if TaskTriagePolicy.hasHardDeadline(ticket) {
            detailRow("Deadline source", value: ticket.dueDateSource ?? "External dashboard")
          }
          detailRow("Agents", value: "\(agents.count) total · \(activeAgentCount) active")
          detailRow("Tokens spent", value: "Not recorded")
          detailRow("Last interaction", value: relativeTime(model.taskContexts[ticket.id]?.latestInteractionAt))
          detailRow("Latest output", value: relativeTime(lastOutputAt))
        }
        triageCallout
        deadlineEditor
      }
      .padding(16)
    }
    .frame(width: 400, height: 560)
    .onChange(of: ticket.dueDate) { _, _ in
      includesDueDate = TaskTriagePolicy.hasHardDeadline(ticket)
      if let deadline = TaskTriagePolicy.hardDeadline(for: ticket) {
        draftDueDate = deadline
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("\(ticket.id) · TASK DETAILS")
          .font(.system(size: 10, weight: .bold, design: .monospaced))
          .foregroundStyle(Color.accentColor)
        Text(ticket.title)
          .font(.system(size: 17, weight: .bold))
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: onClose) {
        Image(systemName: "xmark")
          .font(.system(size: 12, weight: .bold))
          .frame(width: 32, height: 32)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Close task details")
    }
  }

  private var hardDeadlineText: String {
    guard TaskTriagePolicy.hasHardDeadline(ticket) else { return "Not set" }
    if let deadline = TaskTriagePolicy.hardDeadline(for: ticket) {
      return deadline.formatted(date: .abbreviated, time: .omitted)
    }
    return ticket.dueDate ?? "Not set"
  }

  private var triageCallout: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("ROUGH TRIAGE TARGET", systemImage: "info.circle")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.accentColor)
      Text(relativeTitle)
        .font(.system(size: 13, weight: .semibold))
      Text(relativeNote)
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
    )
  }

  private var relativeTitle: String {
    if ticket.queueTaskKind == .longRunning {
      return "Not assigned for long-running tasks"
    }
    if TaskTriagePolicy.hasHardDeadline(ticket) {
      return "Not assigned while a hard deadline is active"
    }
    return relativeDeadline.map(dateText) ?? "Not enough activity data"
  }

  private var relativeNote: String {
    if ticket.queueTaskKind == .longRunning {
      return "Recurring work keeps its own cadence instead of receiving a synthetic due date."
    }
    if TaskTriagePolicy.hasHardDeadline(ticket) {
      return "The named deadline is authoritative. Focus Queue does not replace it with a heuristic."
    }
    return "For daily triage only, not a committed due date. Recalculated from priority and the latest task activity."
  }

  private var deadlineEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Divider()
      Toggle("Hard due date", isOn: $includesDueDate)
        .font(.system(size: 12, weight: .bold))
      if includesDueDate {
        DatePicker("Date", selection: $draftDueDate, displayedComponents: .date)
          .labelsHidden()
      }
      HStack(spacing: 8) {
        Button("Set") { saveDeadline() }
          .buttonStyle(.borderedProminent)
          .disabled(!includesDueDate || isSaving)
        Button("Clear") { clearDeadline() }
          .buttonStyle(.bordered)
          .disabled(!TaskTriagePolicy.hasHardDeadline(ticket) || isSaving)
        if isSaving {
          ProgressView().controlSize(.small)
        }
      }
      Text("A user-specified or external date. It stays visible on the card and overrides rough triage.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let saveError {
        Text(saveError)
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func detailRow(_ label: String, value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .leading)
      Text(value)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func dateText(_ date: Date?) -> String {
    date?.formatted(date: .abbreviated, time: .omitted) ?? "Not recorded"
  }

  private func relativeTime(_ date: Date?) -> String {
    guard let date else { return "Not recorded" }
    return AgentOutputAgeFormatter.string(from: date, relativeTo: Date())
  }

  private func saveDeadline() {
    isSaving = true
    saveError = nil
    Task { @MainActor in
      let saved = await model.setTaskHardDeadline(ticket, to: draftDueDate)
      isSaving = false
      if !saved { saveError = model.actionMessages[ticket.id] ?? "Could not save the hard due date." }
    }
  }

  private func clearDeadline() {
    isSaving = true
    saveError = nil
    Task { @MainActor in
      let saved = await model.setTaskHardDeadline(ticket, to: nil)
      isSaving = false
      if !saved { saveError = model.actionMessages[ticket.id] ?? "Could not clear the hard due date." }
    }
  }
}
