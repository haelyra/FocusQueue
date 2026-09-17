import AppKit
import FocusQueueCore
import SwiftUI

struct TerminalBrowserView: View {
  let model: QueueViewModel
  @State private var selectedView = 0
  var body: some View {
    VStack(spacing: 0) {
      Picker("Terminal view", selection: $selectedView) {
        Text("Task sessions").tag(0)
        Text("Agents to place (\(model.unassignedAgentRegistrations.count))").tag(1)
        Text("Other terminals").tag(2)
      }.pickerStyle(.segmented).padding([.top, .horizontal], 16)
      if selectedView == 1 { ExternalAgentsInboxView(model: model) }
      else if selectedView == 2 { WezTermBrowserView(model: model) }
      else { TaskSessionsView(model: model) }
    }.task {
      await model.refreshExternalAgentRegistrations()
      if !model.unassignedAgentRegistrations.isEmpty { selectedView = 1 }
    }
  }
}

/// Session identity is captured before optional task placement. Ambiguous
/// workspaces stay visible here instead of silently joining the wrong task.
private struct ExternalAgentsInboxView: View {
  let model: QueueViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var refreshing = false
  @State private var message: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Agents to place").font(.title2.bold())
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") {
          refreshing = true
          Task { await model.refreshExternalAgentRegistrations(); refreshing = false }
        }.disabled(refreshing)
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("These agents are tracked. Choose a task to place them in your queue.")
        .font(.callout).foregroundStyle(.secondary)
      if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
      if let error = model.externalAgentRegistrationError {
        Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(model.unassignedAgentRegistrations) { registration in
            VStack(alignment: .leading, spacing: 6) {
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(registration.title).font(.headline).lineLimit(3)
                  Text(registration.provider.displayName + " · " + String((registration.sessionID ?? registration.agentID ?? registration.id).suffix(8)))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Menu("Assign task") {
                  ForEach(model.openTickets) { ticket in
                    Button("\(ticket.id) · \(ticket.title)") { model.assignExternalAgent(registration, to: ticket) }
                  }
                }.disabled(model.openTickets.isEmpty || registration.sessionID == nil)
                  .accessibilityLabel("Assign \(registration.title) to a task")
              }
              Text(registration.cwd).font(.caption).foregroundStyle(.secondary)
                .lineLimit(2).textSelection(.enabled)
              if registration.sessionID == nil {
                Text("Waiting for a resumable provider session ID.").font(.caption).foregroundStyle(.secondary)
              }
              if registration.provider == .codex, let sessionID = registration.sessionID,
                UUID(uuidString: sessionID) != nil {
                Button(registration.tmux == nil ? "Copy resume command" : "Copy attach command") {
                  let command: String
                  if let tmux = registration.tmux,
                    (try? TmuxController.validateName(tmux.name)) != nil,
                    tmux.paneID.range(of: "^%[0-9]+$", options: .regularExpression) != nil {
                    command = "focus-queue-session tmux attach \(tmux.name) --pane \(tmux.paneID)"
                  } else {
                    // Load the integration explicitly. Missing setup must stop
                    // here instead of falling through to an unguarded alias.
                    let entry = model.configurationURL.deletingLastPathComponent()
                      .appendingPathComponent("shell/codex.zsh").path
                    let quoted = "'" + entry.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    command = "/bin/zsh -lc 'source \"$1\" && codex resume \"$2\"' focus-queue-resume \(quoted) \(sessionID)"
                  }
                  NSPasteboard.general.clearContents()
                  NSPasteboard.general.setString(command, forType: .string)
                  message = "Copied. Paste into a terminal to open this exact conversation."
                }.font(.caption)
              }
            }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
          }
          if model.unassignedAgentRegistrations.isEmpty, model.externalAgentRegistrationError == nil {
            ContentUnavailableView("All detected agents are placed", systemImage: "checkmark.circle",
              description: Text("New Codex sessions are detected automatically. Sessions without a clear task appear here."))
          }
        }
      }
      Text("Placement keeps the existing conversation. It does not start another agent or change your task order.")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(20).frame(width: 700, height: 620)
  }
}

struct TaskSessionsView: View {
  let model: QueueViewModel
  var initialTaskID: String? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var panes: [TmuxPaneSnapshot] = []
  @State private var selectedTask = ""
  @State private var message: String?
  @State private var busy = false
  @State private var groupingByWorktree = false
  @State private var persistenceStatus: TmuxPersistenceStatus?

  private var executable: String? { model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux") }
  private var names: [String] { Array(Set(panes.map { $0.reference.name })).sorted() }
  private var taskPanes: [TmuxPaneSnapshot] {
    panes.filter { $0.reference.name == selectedTask }.sorted {
      ($0.windowIndex, $0.top, $0.left) < ($1.windowIndex, $1.top, $1.left)
    }
  }
  private var windows: [String] {
    taskPanes.reduce(into: [String]()) { if !$0.contains($1.windowID) { $0.append($1.windowID) } }
  }
  private func assignment(_ pane: TmuxPaneSnapshot) -> (String, TaskSubtask)? {
    for (ticket, context) in model.taskContexts {
      if let subtask = context.subtasks.first(where: { $0.tmux == pane.reference }) { return (ticket, subtask) }
    }
    return nil
  }
  private func title(_ name: String) -> String {
    if let pane = panes.first(where: { $0.reference.name == name }), let (ticket, _) = assignment(pane) {
      return model.taskContexts[ticket].map { "\(ticket) · \($0.title)" } ?? ticket
    }
    return name.hasPrefix("fq-task-") ? String(name.dropFirst(8)).uppercased() : name
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Task sessions").font(.title2.bold())
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }.disabled(busy)
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("One task, one terminal window. Extra panes use tabs inside tmux.")
        .font(.callout).foregroundStyle(.secondary)
      if !names.isEmpty {
        Picker("Task", selection: $selectedTask) {
          ForEach(names, id: \.self) { Text(title($0)).tag($0) }
        }
        HStack {
          if selectedTask.hasPrefix("fq-task-") {
            Button(taskPanes.first?.automatic == false ? "Use automatic layout" : "Arrange to fit") {
              perform { controller, executable in
                try await controller.setAutomatic(name: selectedTask, executable: executable, enabled: true)
              }
            }.disabled(busy)
            if taskPanes.first?.automatic == true {
              Button("Keep my layout") {
                perform { controller, executable in
                  try await controller.setAutomatic(name: selectedTask, executable: executable, enabled: false)
                }
              }.disabled(busy)
            }
          }
          Button("Copy attach command") {
            let command = "focus-queue-session tmux attach \(selectedTask)"
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(command, forType: .string)
            message = "Copied. Paste into your terminal or IDE."
          }
          Spacer()
        }
        Toggle("Group list by worktree", isOn: $groupingByWorktree).font(.caption)
      }
      if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      HStack {
        if let saved = persistenceStatus?.lastSavedAt {
          Text("Layout saved \(saved, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
        } else {
          Text("Automatic saves every 5 minutes").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Save now") { persistenceAction(restore: false) }.disabled(busy || panes.isEmpty)
        Button("Restore saved layout") { persistenceAction(restore: true) }
          .disabled(busy || persistenceStatus?.canRestore != true)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(Array(windows.enumerated()), id: \.element) { index, window in
            let members = taskPanes.filter { $0.windowID == window }
            if let first = members.first {
              HStack {
                Text("Tab \(index + 1)").font(.headline)
                Text("\(first.windowWidth) × \(first.windowHeight) · \(members.count) panes")
                  .font(.caption).foregroundStyle(.secondary)
              }
              GeometryReader { geometry in
                ForEach(members) { pane in
                  paneTile(pane)
                    .frame(width: max(1, geometry.size.width * CGFloat(pane.width) / CGFloat(first.windowWidth) - 3),
                      height: max(1, geometry.size.height * CGFloat(pane.height) / CGFloat(first.windowHeight) - 3))
                    .position(x: geometry.size.width * CGFloat(pane.left * 2 + pane.width) / CGFloat(first.windowWidth * 2),
                      y: geometry.size.height * CGFloat(pane.top * 2 + pane.height) / CGFloat(first.windowHeight * 2))
                }
              }.frame(height: members.count > 2 ? 210 : 130)
            }
          }
          if !taskPanes.isEmpty {
            ForEach(Array(listPanes.enumerated()), id: \.element.id) { index, pane in
              if groupingByWorktree, index == 0 || assignment(listPanes[index - 1])?.1.workspace?.path != assignment(pane)?.1.workspace?.path {
                Text(assignment(pane)?.1.workspace?.path ?? "Task workspace")
                  .font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
              }
              HStack {
                VStack(alignment: .leading, spacing: 3) {
                  Text(assignment(pane)?.1.title ?? "Shell \(pane.id)").font(.callout)
                  if let (_, agent) = assignment(pane) {
                    Text(agent.workspace?.path ?? "Saved task workspace").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                Spacer()
                Button("Open") { open(pane) }.disabled(busy)
              }
            }
          }
          if names.isEmpty {
            ContentUnavailableView("No task sessions running", systemImage: "terminal",
              description: Text("Start New Agent with Open in tmux. Its panes will appear here."))
          }
        }
      }
      Text("Click a pane to open it. Drag a pane onto another to swap positions. Dragging or resizing keeps your layout until you choose automatic again.")
        .font(.caption).foregroundStyle(.secondary)
      Text("Closing a terminal view keeps tmux running. After a reboot, restore the saved layout and resume each agent from its task.")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(20).frame(width: 700, height: 620)
      .task {
        await reload()
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(3)) } catch { break }
          await reload(quiet: true)
        }
      }
  }

  private var listPanes: [TmuxPaneSnapshot] {
    groupingByWorktree ? taskPanes.sorted {
      (assignment($0)?.1.workspace?.path ?? "", $0.id) < (assignment($1)?.1.workspace?.path ?? "", $1.id)
    } : taskPanes
  }

  private func paneTile(_ pane: TmuxPaneSnapshot) -> some View {
    Button { open(pane) } label: {
      VStack(alignment: .leading, spacing: 4) {
        Label(assignment(pane)?.1.provider.displayName ?? "Terminal", systemImage: "terminal")
          .font(.caption).foregroundStyle(.secondary)
        Text(assignment(pane)?.1.title ?? "Shell \(pane.id)").font(.callout.bold()).lineLimit(3)
        Text(pane.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
      }.padding(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(pane.isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05),
          in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain).disabled(busy)
      .draggable(pane.id)
      .dropDestination(for: String.self) { values, _ in
        guard !busy, values.count == 1, let source = taskPanes.first(where: { $0.id == values[0] }), source.id != pane.id else { return false }
        perform { controller, _ in try await controller.swap(source.reference, with: pane.reference) }
        return true
      }
      .accessibilityLabel("Open \(assignment(pane)?.1.title ?? pane.id)")
      .contextMenu {
        ForEach(taskPanes.filter { $0.id != pane.id }) { other in
          Button("Swap with \(assignment(other)?.1.title ?? other.id)") {
            perform { controller, _ in try await controller.swap(pane.reference, with: other.reference) }
          }
        }
      }
  }

  private func open(_ pane: TmuxPaneSnapshot) {
    if let (ticketID, agent) = assignment(pane), let ticket = model.dashboard.tickets.first(where: { $0.id == ticketID }) {
      model.openSubtask(agent, for: ticket, showResult: false)
      message = "Opening \(agent.title)…"
    } else {
      message = "Copy the attach command to open this shell in your terminal."
    }
  }

  private func perform(_ action: @escaping (TmuxController, String) async throws -> Void) {
    guard !busy, let executable else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        try await action(TmuxController(), executable)
        panes = try await TmuxController().panes(executable: executable)
        message = "Layout updated."
      } catch { message = error.localizedDescription }
    }
  }

  private func persistenceAction(restore: Bool) {
    guard !busy, let executable else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        let persistence = try TmuxPersistence.prepare(executable: executable,
          supportDirectory: model.configurationURL.deletingLastPathComponent())
        if restore { try await persistence.restoreLayout() }
        else { try await persistence.enable(); try await persistence.save() }
        persistenceStatus = persistence.status()
        panes = try await TmuxController().panes(executable: executable)
        if !names.contains(selectedTask) { selectedTask = names.first ?? "" }
        message = restore ? "Layout restored. Open each agent from its task to resume its saved conversation." : "Layout saved."
      } catch { message = error.localizedDescription }
    }
  }

  private func reload(quiet: Bool = false) async {
    guard !busy else { return }
    guard let executable else { message = "Install tmux, then select its executable in Setup."; return }
    busy = true
    defer { busy = false }
    do {
      panes = try await TmuxController().panes(executable: executable)
      persistenceStatus = try TmuxPersistence.prepare(executable: executable,
        supportDirectory: model.configurationURL.deletingLastPathComponent()).status()
      if !names.contains(selectedTask) {
        let current = initialTaskID ?? model.presentedPlanTicketID ?? model.openTickets.first?.id
        selectedTask = current.flatMap { try? TmuxController.taskSessionName(taskID: $0) }
          .flatMap { names.contains($0) ? $0 : nil } ?? names.first ?? ""
      }
      if !quiet { message = nil }
    } catch { message = error.localizedDescription }
  }
}
