import FocusQueueCore
import SwiftUI

/// The + task creator. The prompt is the only required field; the
/// placement model titles, summarizes, and prioritizes whatever is left blank,
/// and checks for an open task that already covers the work.
struct TaskCreatorSheet: View {
  let model: QueueViewModel
  let projectID: String?
  let autofocusPrompt: Bool
  @Environment(\.dismiss) private var dismiss
  @FocusState private var promptFocused: Bool
  @State private var description = ""
  @State private var title = ""
  @State private var displayDescription = ""
  @State private var priority: String?
  @State private var launchesAgent = true
  @State private var agent: AgentLaunchPreset
  @State private var plugins: [ProviderPlugin] = []
  @State private var doneWhen = ""
  @State private var includesDueDate = false
  @State private var dueDate = Date()
  @State private var showsAdvanced = false
  @State private var isSubmitting = false
  @State private var match: (ticket: DashboardTicket, suggestion: TaskPlacementSuggestion)?
  @State private var cachedSuggestion: TaskPlacementSuggestion?
  @State private var message: String?

  init(model: QueueViewModel, projectID: String?, autofocusPrompt: Bool = false) {
    self.model = model
    self.projectID = projectID
    self.autofocusPrompt = autofocusPrompt
    _agent = State(initialValue: model.taskCreatorLaunchDefaults)
  }

  private var project: ProjectConfiguration? { model.projects.first { $0.id == projectID } }
  private var trimmedDescription: String { description.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var startsAgent: Bool { launchesAgent && (agent.includePrompt ?? true) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("New task").font(.title2.bold())
        Text("Add to \(project?.name ?? "the selected project")")
          .font(.callout).foregroundStyle(.secondary)
      }

      Form {
        Section {
          ZStack(alignment: .topLeading) {
            if description.isEmpty {
              Text("Enter prompt").foregroundStyle(.tertiary)
                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
            }
            TextEditor(text: $description)
              .font(.body).frame(minHeight: 130)
              .scrollContentBackground(.hidden)
              .focused($promptFocused)
              .accessibilityLabel("Task prompt")
          }
          TextField("Title (optional)", text: $title,
                    prompt: Text("Leave blank for an agent-written title"))
          TextField("Card description (optional)", text: $displayDescription,
                    prompt: Text("Leave blank for an agent-written summary"), axis: .vertical)
            .lineLimit(1...3)
          Picker("Priority", selection: $priority) {
            Text("Automatic (Medium if unsure)").tag(String?.none)
            Text("Low").tag(String?.some("low"))
            Text("Medium").tag(String?.some("medium"))
            Text("High").tag(String?.some("high"))
            Text("Critical").tag(String?.some("critical"))
          }
        }

        Section {
          Toggle("Launch an agent now", isOn: $launchesAgent)
          if launchesAgent { AgentLaunchOptions(model: model, agent: $agent) }
        } footer: {
          Text(startsAgent
            ? "Each provider remembers the model and effort you last launched it with. The agent gets its own placement capsule, worktree, and tmux pane."
            : "The task is created without an agent, and the prompt is saved with it. New Agent on its card starts with that prompt.")
            .font(.caption).foregroundStyle(.secondary)
        }

        Section {
          DisclosureGroup("Advanced", isExpanded: $showsAdvanced) { advancedOptions }
        }
      }
      .formStyle(.grouped)

      // A match only redirects a launch; without one the button creates a task.
      if startsAgent, let match { matchBanner(match.ticket, match.suggestion) }
      if let message {
        Text(message).font(.caption).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }

      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(isSubmitting ? "Placing…" : startsAgent ? "Create and launch" : "Create task") {
          submit(.checkForMatch)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(isSubmitting || trimmedDescription.isEmpty || project == nil || (startsAgent && match != nil))
      }
    }
    .padding(22)
    .frame(width: 560, height: 680)
    .onChange(of: description) { _, _ in
      // A suggestion describes the text it saw; edits make it stale.
      cachedSuggestion = nil
      match = nil
    }
    .task(id: agent.provider) { plugins = ProviderPluginCatalog.installed(for: agent.provider) }
    .onAppear { if autofocusPrompt { promptFocused = true } }
  }

  @ViewBuilder private var advancedOptions: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Plugins for this launch").font(.system(size: 12, weight: .semibold))
      if startsAgent {
        AgentPluginOptions(agent: $agent, plugins: plugins)
      } else {
        Text("Plugins apply when an agent launches.").font(.caption).foregroundStyle(.secondary)
      }
      Divider()
      TextField("Done when", text: $doneWhen, axis: .vertical).lineLimit(1...3)
      Toggle("Set a hard due date", isOn: $includesDueDate)
      if includesDueDate {
        DatePicker("Hard due date", selection: $dueDate, displayedComponents: .date)
      }
    }.padding(.top, 6)
  }

  private func matchBanner(_ ticket: DashboardTicket, _ suggestion: TaskPlacementSuggestion) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("This looks like an open task", systemImage: "arrow.triangle.merge")
        .font(.system(size: 13, weight: .semibold))
      Text("\(ticket.id) · \(ticket.title)")
        .font(.callout).fixedSize(horizontal: false, vertical: true)
      if suggestion.confidence > 0 {
        Text("Placement confidence \(suggestion.confidence.formatted(.number.precision(.fractionLength(2))))")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button(startsAgent ? "Add agent to \(ticket.id)" : "Use \(ticket.id)") { submit(.join(ticket.id)) }
          .buttonStyle(.borderedProminent)
        Button("Create a new task anyway") { submit(.createNew) }.buttonStyle(.bordered)
      }.disabled(isSubmitting)
    }
    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.08)))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35)))
  }

  private func submit(_ choice: TaskDraftChoice) {
    let draft = TaskDraft(
      description: description, title: title, displayDescription: displayDescription,
      priority: priority, doneWhen: doneWhen, dueDate: includesDueDate ? dueDate : nil,
      projectID: projectID, launchesAgent: launchesAgent, agent: agent)
    isSubmitting = true
    message = nil
    Task {
      let result = await model.submitTaskDraft(draft, choice: choice, suggestion: cachedSuggestion)
      isSubmitting = false
      switch result {
      case .created, .joined:
        dismiss()
      case .matched(let ticket, let suggestion):
        cachedSuggestion = suggestion
        match = (ticket, suggestion)
      case .failed(let reason):
        message = reason
      }
    }
  }
}

/// The card's New Agent sheet: the + task creator's prompt and launch options
/// for one agent on a task that already exists, so placement is skipped.
struct TaskAgentCreatorSheet: View {
  let model: QueueViewModel
  let ticket: DashboardTicket
  @Environment(\.dismiss) private var dismiss
  @FocusState private var promptFocused: Bool
  @State private var prompt = ""
  @State private var title = ""
  @State private var agent: AgentLaunchPreset
  @State private var plugins: [ProviderPlugin] = []
  @State private var showsAdvanced = false

  init(model: QueueViewModel, ticket: DashboardTicket) {
    self.model = model
    self.ticket = ticket
    _agent = State(initialValue: model.taskCreatorLaunchDefaults)
  }

  private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespacesAndNewlines) }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text("New agent").font(.title2.bold())
        Text("Add to \(ticket.id) · \(ticket.title)")
          .font(.callout).foregroundStyle(.secondary).lineLimit(1)
      }

      Form {
        Section {
          ZStack(alignment: .topLeading) {
            if prompt.isEmpty {
              Text("Enter prompt").foregroundStyle(.tertiary)
                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
            }
            TextEditor(text: $prompt)
              .font(.body).frame(minHeight: 130)
              .scrollContentBackground(.hidden)
              .focused($promptFocused)
              .accessibilityLabel("Agent prompt")
          }
          TextField("Title (optional)", text: $title,
                    prompt: Text("Leave blank for a prompt-derived title"))
        }

        Section {
          AgentLaunchOptions(model: model, agent: $agent)
        } footer: {
          Text("Each provider remembers the model and effort you last launched it with. The agent gets its own worktree and a pane in this task's tmux session.")
            .font(.caption).foregroundStyle(.secondary)
        }

        Section {
          DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
            VStack(alignment: .leading, spacing: 10) {
              Text("Plugins for this launch").font(.system(size: 12, weight: .semibold))
              AgentPluginOptions(agent: $agent, plugins: plugins)
            }.padding(.top, 6)
          }
        }
      }
      .formStyle(.grouped)

      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Launch agent") {
          model.launchPromptedAgent(for: ticket, prompt: prompt, title: title, preset: agent)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(trimmedPrompt.isEmpty || ticket.isCompleted || model.launchingTaskIDs.contains(ticket.id))
      }
    }
    .padding(22)
    .frame(width: 560, height: 600)
    .task(id: agent.provider) { plugins = ProviderPluginCatalog.installed(for: agent.provider) }
    .onAppear {
      // A task created without an agent hands its saved prompt to the first one.
      if prompt.isEmpty, let saved = model.savedInitialPrompt(for: ticket) {
        prompt = saved
        agent.includePrompt = true
      }
      promptFocused = true
    }
  }
}

/// Provider, model, effort, workspace, and launch toggles for one agent.
/// Shared by the + task creator and the card's New Agent sheet.
struct AgentLaunchOptions: View {
  let model: QueueViewModel
  @Binding var agent: AgentLaunchPreset

  static func preset(
    selecting provider: AgentProvider, from current: AgentLaunchPreset,
    lastLaunch: AgentLaunchPreset
  ) -> AgentLaunchPreset {
    guard provider != current.provider else { return current }
    var selected = current
    selected.provider = provider
    selected.model = lastLaunch.model
    selected.effort = lastLaunch.effort
    selected.pluginOverrides = lastLaunch.pluginOverrides
    return selected
  }

  var body: some View {
    Picker("Provider", selection: Binding(
      get: { agent.provider },
      set: { provider in
        guard provider != agent.provider else { return }
        // Replace the preset once so a picker refresh cannot observe a new
        // provider with the previous provider's model and effort.
        agent = Self.preset(
          selecting: provider, from: agent, lastLaunch: model.lastAgentLaunch(for: provider))
      }
    )) {
      ForEach(AgentProvider.allCases, id: \.self) { provider in
        Label(provider.displayName, systemImage: provider.symbolName).tag(provider)
      }
    }.pickerStyle(.segmented)
    Picker("Model", selection: Binding(
      get: { agent.model ?? "" },
      set: { agent.model = $0.isEmpty ? nil : $0 }
    )) {
      ForEach(model.agentModelChoices(for: agent.provider)) { choice in
        Text(choice.label).tag(choice.model ?? "")
      }
      if let current = agent.model,
         !model.agentModelChoices(for: agent.provider).contains(where: { $0.model == current }) {
        Text(current).tag(current)
      }
    }
    Picker("Effort", selection: Binding(
      get: { agent.effort ?? "" },
      set: { agent.effort = $0.isEmpty ? nil : $0 }
    )) {
      Text("Default").tag("")
      ForEach(AppConfiguration.agentEffortLevels(for: agent.provider), id: \.self) { Text($0).tag($0) }
      if let current = agent.effort,
         !AppConfiguration.agentEffortLevels(for: agent.provider).contains(current) {
        Text(current).tag(current)
      }
    }
    Picker("Workspace", selection: Binding(
      get: { agent.workspacePolicy ?? .isolatedCommittedSnapshot },
      set: { agent.workspacePolicy = $0 }
    )) {
      Text("Isolated snapshot of the project").tag(AgentWorkspacePolicy.isolatedCommittedSnapshot)
      Text("Isolated clean checkout").tag(AgentWorkspacePolicy.isolatedCleanCheckout)
      Text("Existing checkout").tag(AgentWorkspacePolicy.existingCheckout)
    }
    Toggle("Open in tmux", isOn: Binding(
      get: { agent.useTmux ?? true }, set: { agent.useTmux = $0 }))
    Toggle("Start the agent with this prompt", isOn: Binding(
      get: { agent.includePrompt ?? true }, set: { agent.includePrompt = $0 }))
  }
}

/// Per-launch plugin toggles for the chosen provider.
struct AgentPluginOptions: View {
  @Binding var agent: AgentLaunchPreset
  let plugins: [ProviderPlugin]

  var body: some View {
    if agent.provider == .kimi {
      Text("Kimi has no plugin system.").font(.caption).foregroundStyle(.secondary)
    } else if plugins.isEmpty {
      Text("No \(agent.provider.displayName) plugins are installed.").font(.caption).foregroundStyle(.secondary)
    } else {
      ForEach(plugins) { plugin in
        Toggle(isOn: pluginBinding(plugin)) {
          HStack(spacing: 6) {
            Text(plugin.isECC ? "ECC" : plugin.name)
            Text(plugin.id).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Text("Changes apply to this agent only; your saved \(agent.provider.displayName) settings stay as they are.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  /// An override is stored only when it differs from the saved enablement.
  private func pluginBinding(_ plugin: ProviderPlugin) -> Binding<Bool> {
    Binding(
      get: { agent.pluginOverrides?[plugin.id] ?? plugin.enabled },
      set: { enabled in
        var overrides = agent.pluginOverrides ?? [:]
        overrides[plugin.id] = enabled == plugin.enabled ? nil : enabled
        agent.pluginOverrides = overrides.isEmpty ? nil : overrides
      })
  }
}
