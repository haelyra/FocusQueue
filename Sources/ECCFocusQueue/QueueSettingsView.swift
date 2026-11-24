import AppKit
import FocusQueueCore
import SwiftUI

/// The tabs across the top of Settings. The last one chosen reopens next time.
enum QueueSettingsTab: String, CaseIterable, Identifiable {
  case agents, appearance, general, harness

  static let defaultsKey = "settingsTab"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .agents: "Agent Configs"
    case .appearance: "Appearance"
    case .general: "General"
    case .harness: "Harness Configs"
    }
  }

  var symbolName: String {
    switch self {
    case .agents: "person.2.fill"
    case .appearance: "paintpalette.fill"
    case .general: "gearshape.fill"
    case .harness: "slider.horizontal.3"
    }
  }

  var help: String {
    switch self {
    case .agents: "Sign-in, permissions, T3 Code, lifecycle, and decisions for the agents you launch"
    case .appearance: "Light or dark, accent colors, and where the queue sits on screen"
    case .general: "Updates, projects, shortcuts, the bulletin board, terminals, capacity, reports, and diagnostics"
    case .harness: "The default agent and Focus Queue's own core agents: QChat, task placement, and data placement"
    }
  }
}

struct QueueSettingsView: View {
  let model: QueueViewModel
  let focusedSection: QueueSettingsTarget?
  let openSessions: () -> Void
  let openAnalytics: () -> Void
  let close: () -> Void
  @AppStorage(OpaqueBackgroundsPreference.defaultsKey) private var opaqueBackgroundsEnabled = false
  @AppStorage(QueueSettingsTab.defaultsKey) private var selectedTabID = QueueSettingsTab.general.rawValue

  private var selectedTab: QueueSettingsTab { QueueSettingsTab(rawValue: selectedTabID) ?? .general }

  var body: some View {
    VStack(spacing: 10) {
      HStack(spacing: 10) {
        Button(action: close) {
          Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold))
        }.buttonStyle(.plain).minimumHitTarget(width: 46, height: 46).accessibilityLabel(
          "Back to Focus Queue").help("Return to the task queue")
        Text("Settings").font(.system(size: 21, weight: .bold, design: .rounded))
        Spacer()
        Text("Focus Queue").font(.system(size: 12, weight: .semibold)).foregroundStyle(
          .secondary)
      }.padding(.horizontal, 14).padding(.vertical, 10).notificationSurface(radius: 18)

      tabBar

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          switch selectedTab {
          case .agents: agentConfigsTab
          case .appearance: appearanceTab
          case .general: generalTab
          case .harness: harnessConfigsTab
          }
        }.padding(.horizontal, 2).padding(.vertical, 2)
      }
      .scrollIndicators(.automatic)
      // Each tab starts at its top instead of the previous tab's offset.
      .id(selectedTab)

      Spacer(minLength: 0)
    }
    .onAppear { showFocusedSection() }
    .onChange(of: focusedSection) { _, _ in showFocusedSection() }
  }

  /// A deep link to connector diagnostics opens the tab that holds it.
  private func showFocusedSection() {
    if focusedSection == .connectors { selectedTabID = QueueSettingsTab.general.rawValue }
  }

  private var tabBar: some View {
    HStack(spacing: 4) {
      ForEach(QueueSettingsTab.allCases) { tab in
        let isSelected = tab == selectedTab
        Button {
          withAnimation(.easeInOut(duration: 0.15)) { selectedTabID = tab.rawValue }
        } label: {
          VStack(spacing: 3) {
            Image(systemName: tab.symbolName).font(.system(size: 14, weight: .semibold))
            Text(tab.title).font(.system(size: 11, weight: .semibold))
              .lineLimit(1).minimumScaleFactor(0.75)
          }
          .frame(maxWidth: .infinity)
          .padding(.vertical, 7)
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
              .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .help(tab.help)
      }
    }
    .padding(5)
    .notificationSurface(radius: 16)
  }

  // MARK: Agent Configs

  @ViewBuilder private var agentConfigsTab: some View {
    settingsSection(
      title: "Sign-in",
      detail: "Agents run through each provider's own CLI and your subscription. Check who is signed in, sign in to another provider, or sign out."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        WalkthroughSignInContent(model: model, allowsSignOut: true)
        Toggle("Report failed sign-ins to the beta tracker", isOn: Binding(
          get: { model.reportsSignInFailures }, set: { model.setReportsSignInFailures($0) }))
        Text("When a sign-in fails, Focus Queue files a GitHub issue with the error, the CLI version, and your Mac and app versions. Paths, emails and tokens are removed. Issues on this repository are public.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    settingsSection(
      title: "Permissions",
      detail: "Bypass lets agents and chat turns that Focus Queue starts edit files and run commands without asking first. Turn it off to have agents ask. Each task can override this in its details."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(AgentProvider.allCases, id: \.self) { provider in
          Toggle("Bypass permissions for \(provider.displayName)", isOn: Binding(
            get: { model.config.bypassesPermissions(for: provider) },
            set: { model.setPermissionBypass($0, for: provider) }))
        }
        Text("With bypass off, agent panes use your provider's own permission settings, and chat turns, which cannot stop to ask, are limited: Claude uses only tools your rules allow, Codex runs sandboxed without network, and Kimi can read and search but not edit. Shell aliases that add bypass flags still apply.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    settingsSection(
      title: "T3 Code",
      detail: "Run agents in T3 Code threads instead of terminal panes. Focus Queue keeps tasks, plans, and checkouts; T3 Code runs the conversations. Requires T3 Code 0.1.12 or later on this Mac."
    ) {
      T3SettingsView(model: model)
    }
    settingsSection(
      title: "Agent lifecycle",
      detail: "Automatic steps Focus Queue takes as agents go stale or are escalated."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        settingToggle(
          "Automatically archive stale agents",
          detail: "Once a day, archive interrupted or idle agents with no live process, no unseen output, and no activity in 5 days. They stay recallable under Archived agents.",
          isOn: Binding(
            get: { model.config.autoArchiveStaleAgents },
            set: { model.setAutoArchiveStaleAgents($0) }))
        settingToggle(
          "Launch agents for escalated messages",
          detail: "When message ingestion escalates a task with no live agent, start one automatically. When off, requests wait until this is turned back on.",
          isOn: Binding(
            get: { model.config.agentEscalationAutoLaunch },
            set: { model.setAgentEscalationAutoLaunch($0) }))
      }
    }
    settingsSection(
      title: "Decisions",
      detail: "When an orchestrator or agent departs from your instruction, the master plan, or the task plan, it records a decision with a pushed checkpoint. View decision tree, in an agent's ⋮ menu, shows them."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        settingToggle(
          "Decide automatically when you do not reply",
          detail: "After the wait below, Focus Queue takes the recommended option and resumes the agent. Replying \"continue\" to an agent does the same right away.",
          isOn: Binding(
            get: { model.decisionAutomation.autoDecide },
            set: { model.setDecisionAutoDecide($0) }))
        Stepper(value: Binding(
          get: { model.decisionAutomation.autoDecideMinutes },
          set: { model.setDecisionAutoDecideMinutes($0) }
        ), in: DecisionAutomationSettings.minutesRange, step: 15) {
          HStack {
            Text("Wait before deciding")
            Spacer()
            Text(model.decisionAutomation.windowDescription).monospacedDigit().foregroundStyle(.secondary)
          }
        }
        .disabled(!model.decisionAutomation.autoDecide)
        settingToggle(
          "Rewind automatically when a chosen option fails",
          detail: "Agents may restore the code and conversation to the decision and take the next recommended option. When off, they ask you first.",
          isOn: Binding(
            get: { model.decisionAutomation.autoRewind },
            set: { model.setDecisionAutoRewind($0) }))
      }
    }
  }

  // MARK: Appearance

  @ViewBuilder private var appearanceTab: some View {
    settingsSection(
      title: "Appearance",
      detail: "Dark uses a #1A1D23 background color. Accent colors change status, priority, sync, and review colors."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Appearance", selection: appearanceBinding) {
          Label("Light", systemImage: "sun.max.fill").tag(QueueAppearance.light)
          Label("Dark", systemImage: "moon.stars.fill").tag(QueueAppearance.dark)
        }.pickerStyle(.segmented).labelsHidden()
        Picker("Accent colors", selection: accentStyleBinding) {
          ForEach(QueueAccentStyle.allCases) { style in
            Text(style.displayName).tag(style)
          }
        }.pickerStyle(.segmented).labelsHidden()
        DisclosureGroup("Advanced") {
          settingToggle(
            "Opaque backgrounds",
            detail: "Replace translucent and blurred surfaces with solid dark gray or white backgrounds.",
            isOn: $opaqueBackgroundsEnabled
          )
          .padding(.top, 8)
        }
      }
    }
    settingsSection(
      title: "Screen location",
      detail: "Choose the queue's horizontal position or move it to the next display."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Screen location", selection: placementBinding) {
          Text("Left").tag(QueueWindowPlacement.upperLeft)
          Text("Center").tag(QueueWindowPlacement.center)
          Text("Right").tag(QueueWindowPlacement.upperRight)
        }.pickerStyle(.segmented).labelsHidden()

        Button("Move queue to next display", systemImage: "display.2") {
          model.switchMonitor()
        }.buttonStyle(.bordered).disabled(!model.canSwitchMonitor)
          .help(
            model.canSwitchMonitor
              ? "Move queue to next display"
              : "Connect another display to move the queue"
          )
      }
    }
  }

  // MARK: General

  @ViewBuilder private var generalTab: some View {
    if focusedSection == .connectors { connectorDiagnosticsSection }

    settingsSection(title: "Updates", detail: "Install new Focus Queue beta releases from GitHub.") {
      AppUpdateSection()
    }

    settingsSection(
      title: "Projects",
      detail: "Choose a project to see its settings and files. Open a file to read it beside settings with its project chat."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        ProjectSettingsSection(model: model)
        Button("Open setup wizard", systemImage: "wand.and.stars") {
          model.isSetupPresented = true
        }.buttonStyle(.bordered)
      }
      .walkthroughAnchor(.projectSettings)
    }

    settingsSection(
      title: "Keyboard shortcuts",
      detail: "Global hotkeys that work from any app. Click a shortcut, then press a new combo with ⌘, ⌥, or ⌃. Reset returns to the default shortcut."
    ) {
      VStack(alignment: .leading, spacing: 14) {
        hotkeyRow(.newTask,
          detail: "Opens a new task with the prompt focused. Press again to cancel it.",
          isOn: Binding(
            get: { model.newTaskHotkeyEnabled },
            set: { model.setNewTaskHotkeyEnabled($0) }))
        hotkeyRow(.qchat,
          detail: "Opens QChat beside the queue with the message box focused for voice typing. Press again to close it.",
          isOn: Binding(
            get: { model.qchatHotkeyEnabled },
            set: { model.setQChatHotkeyEnabled($0) }))
        hotkeyRow(.toggleMinimization,
          detail: "Toggles the full queue and your preferred minimized view (FQ, top task, or Dock).",
          isOn: Binding(
            get: { model.toggleMinimizationHotkeyEnabled },
            set: { model.setToggleMinimizationHotkeyEnabled($0) }))
        hotkeyRow(.bulletinBoard,
          detail: "Opens the bulletin board of pinned tasks, agents, files, and folders beside the queue. Press again to close it.",
          isOn: Binding(
            get: { model.bulletinBoardHotkeyEnabled },
            set: { model.setBulletinBoardHotkeyEnabled($0) }))
      }
    }

    settingsSection(
      title: "Bulletin board",
      detail: "Pinned tasks, agents, files, folders, and links. Each project reopens its board where you last had it: beside the queue, in the Board tab, or in its own window."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        settingToggle("Board tab beside Focus, Completed, and QChat",
          detail: "Shows the board under the queue's header, like the other tabs. Choosing the tab makes it that project's board location.",
          isOn: Binding(
            get: { model.bulletinBoardTabEnabled },
            set: { model.setBulletinBoardTabEnabled($0) }))
      }
    }

    settingsSection(
      title: "Terminals",
      detail: "Each task runs its agents as panes in one shared tmux session."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        TerminalAppSetting(model: model)
        Divider()
        Stepper(value: Binding(
          get: { model.agentsPerWindow },
          set: { model.setAgentsPerWindow($0) }
        ), in: 1...12) {
          HStack {
            Text("Agent panes per window tab")
            Spacer()
            Text("\(model.agentsPerWindow)").monospacedDigit().foregroundStyle(.secondary)
          }
        }
        VStack(alignment: .leading, spacing: 3) {
          HStack {
            Text("Agent usage bar")
            Spacer()
            featureBadge("Coming soon")
          }
          Text("Live quota and context rows below each managed task window.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button(action: openSessions) {
          Label("Browse sessions", systemImage: "rectangle.stack")
        }
        .buttonStyle(.bordered)
        .help("Active task sessions and saved sessions you can recall")
      }
    }
    settingsSection(
      title: "Capacity and scheduling",
      detail: "A live read of this Mac's CPU, memory, and token use above the queue and in the new task window, with a rough launch recommendation. It is an estimate for orientation only and never blocks a launch."
    ) {
      settingToggle(
        "Capacity panel",
        detail: "Show live CPU, memory, and 5-hour token estimates plus a cycling launch recommendation above the queue and in the new task window.",
        isOn: Binding(
          get: { model.config.capacityPanelEnabled },
          set: { model.setCapacityPanelEnabled($0) }))
    }

    groupHeading("Daily reports")
    dailyReportSection

    if focusedSection != .connectors { connectorDiagnosticsSection }

    groupHeading("Tools")
    settingsSection(
      title: "Diagnostics",
      detail: "Inspect token use and live app activity, or open the configuration file for options that have no control here."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Button(action: openAnalytics) {
          Label("Token analytics", systemImage: "chart.bar.xaxis")
        }
        .buttonStyle(.bordered)
        .help("Local prompt and agent token measurements")
        settingToggle(
          "Show Program Log window",
          detail: "A separate live debugging window. Its contents start fresh each time Focus Queue launches.",
          isOn: Binding(
            get: { model.isProgramLogWindowVisible },
            set: { model.setProgramLogWindowVisible($0) }))
        Button("Open advanced configuration", systemImage: "doc.badge.gearshape") {
          model.openConfiguration()
        }.buttonStyle(.bordered)
      }
    }
  }

  private var dailyReportSection: some View {
    settingsSection(
      title: "Daily message report",
      badge: "Experimental",
      detail:
        "Summarizes your messages across connected platforms. Off by default; when on, it runs once a day. Manual reports and history remain available."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle(
          "Run a report every day",
          isOn: Binding(
            get: { model.config.dailyReport.enabled },
            set: { model.setDailyReportsEnabled($0) }
          )
        )

        DatePicker(
          "Run time",
          selection: dailyReportTimeBinding,
          displayedComponents: .hourAndMinute
        ).disabled(!model.config.dailyReport.enabled)

        Stepper(
          value: dailyReportTokenBinding,
          in: 10_000...1_000_000,
          step: 5_000
        ) {
          HStack {
            Text("Token consumption target")
            Spacer()
            Text(model.config.dailyReport.maximumTokens.formatted())
              .monospacedDigit().foregroundStyle(.secondary)
          }
        }

        Picker("Agent", selection: Binding(
          get: { model.config.dailyReport.agentProvider },
          set: { model.setDailyReportAgentProvider($0) }
        )) {
          Text("Follow default provider").tag(AgentProvider?.none)
          ForEach(AgentProvider.allCases, id: \.self) { provider in
            provider.label()
              .tag(AgentProvider?.some(provider))
          }
        }
        if let sweepProvider = model.config.dailyReport.agentProvider {
          Picker("Model", selection: Binding(
            get: { model.config.dailyReport.agentModel ?? "" },
            set: { model.setDailyReportAgentModel($0) }
          )) {
            ForEach(model.agentModelChoices(for: sweepProvider)) { choice in
              Text(choice.label).tag(choice.model ?? "")
            }
          }
          Picker("Effort", selection: Binding(
            get: { model.config.dailyReport.agentEffort ?? "" },
            set: { model.setDailyReportAgentEffort($0) }
          )) {
            Text("Default").tag("")
            ForEach(AppConfiguration.agentEffortLevels(for: sweepProvider), id: \.self) { effort in
              Text(effort).tag(effort)
            }
          }
        }

        VStack(alignment: .leading, spacing: 7) {
          Text("Platforms").font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
          ForEach(DailyReportPlatform.allCases) { platform in
            Toggle(
              platform.displayName,
              isOn: Binding(
                get: { model.config.dailyReport.enabledPlatforms.contains(platform) },
                set: { model.setDailyReportPlatform(platform, enabled: $0) }
              )
            )
          }
        }

        Button("Run comprehensive report", systemImage: "arrow.triangle.2.circlepath") {
          model.runComprehensiveDailyReport()
        }.buttonStyle(.borderedProminent).disabled(model.reportIsRunning)

        DisclosureGroup("Past reports and logs") {
          DailyReportHistoryView(snapshot: model.reportHistory) { report in
            model.selectHistoricalReport(report)
          }.padding(.top, 10)
        }.task { await model.reloadReportHistory() }

        if model.reportIsRunning {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking enabled platforms…")
            Spacer()
            Button(
              model.isDailyReportCancellationRequested ? "Cancelling…" : "Cancel",
              action: model.cancelDailyReport
            )
            .buttonStyle(.bordered)
            .disabled(model.isDailyReportCancellationRequested)
          }.font(.system(size: 12)).foregroundStyle(.secondary)
        } else if let message = model.dailyReportRunMessage {
          Text(message).font(.system(size: 12))
            .foregroundStyle(model.dailyReportRunFailed ? Color.orange : Color.secondary)
        }
      }
    }
  }

  // MARK: Harness Configs

  @ViewBuilder private var harnessConfigsTab: some View {
    settingsSection(
      title: "Default agent",
      detail: "New agents and quick launches start with this provider and its default model unless you pick another one. The + task creator uses it when no agent has been launched yet."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        Picker("Provider", selection: Binding(
          get: { model.defaultAgentProvider },
          set: { model.setDefaultAgentProvider($0) }
        )) {
          ForEach(AgentProvider.allCases, id: \.self) { provider in
            provider.label().tag(provider)
          }
        }.pickerStyle(.segmented).labelsHidden()
        Picker("Default model", selection: Binding(
          get: { model.defaultAgentModel(for: model.defaultAgentProvider) ?? "" },
          set: { model.setDefaultAgentModel($0, for: model.defaultAgentProvider) }
        )) {
          ForEach(model.agentModelChoices(for: model.defaultAgentProvider)) { choice in
            Text(choice.label).tag(choice.model ?? "")
          }
        }
        Picker("Default effort", selection: Binding(
          get: { model.defaultAgentEffort(for: model.defaultAgentProvider) ?? "" },
          set: { model.setDefaultAgentEffort($0, for: model.defaultAgentProvider) }
        )) {
          ForEach(AppConfiguration.agentEffortLevels(for: model.defaultAgentProvider), id: \.self) { effort in
            Text(effort).tag(effort)
          }
        }
        Text("New agents start with this model and effort. You can change both for each launch.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }

    groupHeading("Core agents")
    Text("Focus Queue runs three agents of its own through your subscription CLIs: QChat answers you, task placement files each new agent under a task, and data placement saves lasting facts from your prompts.")
      .font(.system(size: 12)).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 4)

    qchatSection

    settingsSection(
      title: "Task placement agent",
      detail: "fq places each new agent with one small model call through your own subscription CLI: it joins a matching open task or creates a titled one. A ticket ID in the prompt skips the call."
    ) {
      PlacementSettingsView(model: model)
    }

    settingsSection(
      title: "Data placement agent",
      detail: "After each agent prompt, a background model call saves lasting preferences and deferred requirements to user, project, or task data."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        Toggle("Save durable facts from prompts", isOn: Binding(
          get: { model.dataPlacementEnabled },
          set: { model.setDataPlacementEnabled($0) }))
        Group {
          CoreAgentProviderPicker(
            title: "Run extraction on",
            followTitle: "Prompting agent's provider",
            selection: Binding(
              get: { model.config.extractorProvider },
              set: { model.setExtractorProvider($0) }))
          CoreAgentModelRows(
            model: model,
            purpose: "data placement",
            provider: model.config.extractorProvider,
            storedModel: { model.config.extractorModels[$0] },
            defaultModel: { model.config.placementModel(for: $0) },
            storedEffort: { model.config.extractorEfforts[$0] },
            defaultEffort: { model.config.placementEffort(for: $0) },
            setModel: { model.setExtractorModel($0, for: $1) },
            setEffort: { model.setExtractorEffort($0, for: $1) })
        }.disabled(!model.dataPlacementEnabled)
        Text("Default uses the task placement model and effort.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }

    settingsSection(
      title: "Agent contracts",
      detail: "The rules Focus Queue itself gives agents, immutable and the same in every project: each provider's global contract, plus the orchestrator rules that ride beside a project's signed orchestration contract. Orchestrators, including QChat, get those rules. A project's own signed contracts (agent-contract.md, orchestration.md) are in its Project tab and add to these."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        builtInContractRow("Global contract", contracts: [.claude, .codex, .kimi])
        builtInContractRow("Orchestrator rules", contracts: [.orchestrator])
        if let error = model.builtInContractError {
          Text(error).font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }

    settingsSection(
      title: "Built-in agent prompts",
      detail: "Build-owned prompts for task placement, extraction, chat, document editing, daily reports, reviews, canvas feedback, and planning. Open a prompt to read its instructions and when it runs. Runtime fields use placeholders."
    ) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Project creation saves your project settings directly; it does not send a model prompt.")
          .font(.caption).foregroundStyle(.secondary)
        ForEach(BuiltInAgentPrompt.allCases) { prompt in
          builtInPromptRow(prompt)
        }
        if let error = model.builtInContractError {
          Text(error).font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var qchatSection: some View {
    let provider = model.chatAgentProvider
    let autoClear = model.chatAutoClear
    return settingsSection(
      title: "QChat agent",
      detail: "Answers in QChat and in each task's chat, and edits tasks, projects, and settings for you. The menus above any chat change the same choice."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        CoreAgentProviderPicker(
          title: "Agent",
          followTitle: "Default agent (\(model.defaultAgentProvider.displayName))",
          selection: Binding(
            get: { model.config.chatProvider },
            set: { model.setChatProvider($0) }))
        let chatModel = model.effectiveChatModel(for: provider)
        let modelChoices = model.agentModelChoices(for: provider)
        Picker("Model", selection: Binding(
          get: { chatModel ?? "" },
          set: { model.setChatModel($0, for: provider) }
        )) {
          // An empty choice runs the CLI without --model, on the account's own default.
          Text("Provider default").tag("")
          if let chatModel, !modelChoices.contains(where: { $0.model == chatModel }) {
            Text(chatModel).tag(chatModel)
          }
          ForEach(modelChoices) { choice in
            Text(choice.label).tag(choice.model ?? "")
          }
        }
        if provider != .kimi {
          Picker("Effort", selection: Binding(
            get: { model.config.chatEffort(for: provider) ?? "" },
            set: { model.setChatEffort($0, for: provider) }
          )) {
            Text("Provider default").tag("")
            ForEach(AppConfiguration.agentEffortLevels(for: provider), id: \.self) { effort in
              Text(effort).tag(effort)
            }
          }
        }
        Divider()
        HStack(spacing: 8) {
          Text("Auto-clear idle chats")
          Spacer(minLength: 8)
          if autoClear.unit != .never {
            Stepper(value: Binding(
              get: { autoClear.amount },
              set: { model.setChatAutoClear(QueueChatAutoClear(unit: autoClear.unit, amount: $0)) }
            ), in: autoClear.unit.amountRange) {
              Text("\(autoClear.amount)").monospacedDigit().foregroundStyle(.secondary)
            }
            .fixedSize()
            .accessibilityLabel("Auto-clear after")
            .accessibilityValue(autoClear.summary)
          }
          Picker("Auto-clear unit", selection: Binding(
            get: { autoClear.unit },
            set: { model.setChatAutoClear(autoClear.switching(to: $0)) }
          )) {
            ForEach(QueueChatAutoClear.Unit.allCases) { unit in
              Text(unit.title).tag(unit)
            }
          }
          .labelsHidden()
          .fixedSize()
        }
        Text(autoClear.unit == .never
          ? "QChat tabs keep their history until you clear them."
          : "A QChat tab with no new message for \(autoClear.summary) is cleared: its transcript is erased and its session closes. Task chats are never cleared automatically.")
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var appearanceBinding: Binding<QueueAppearance> {
    Binding(get: { model.appearance }, set: { model.setAppearance($0) })
  }

  private var placementBinding: Binding<QueueWindowPlacement> {
    Binding(get: { model.windowPlacement }, set: { model.placeWindow($0) })
  }

  private var accentStyleBinding: Binding<QueueAccentStyle> {
    Binding(get: { model.accentStyle }, set: { model.setAccentStyle($0) })
  }

  private var dailyReportTimeBinding: Binding<Date> {
    Binding(
      get: {
        Calendar.current.date(
          bySettingHour: model.config.dailyReport.scheduleHour,
          minute: model.config.dailyReport.scheduleMinute,
          second: 0,
          of: Date()
        ) ?? Date()
      },
      set: { date in
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        model.setDailyReportSchedule(
          hour: components.hour ?? 8,
          minute: components.minute ?? 0
        )
      }
    )
  }

  private var dailyReportTokenBinding: Binding<Int> {
    Binding(
      get: { model.config.dailyReport.maximumTokens },
      set: { model.setDailyReportMaximumTokens($0) }
    )
  }

  private var connectorDiagnosticsSection: some View {
    settingsSection(
      title: "Connector diagnostics",
      detail:
        "Check each report platform's local setup without reading messages. Authentication and live access are not tested."
    ) {
      VStack(alignment: .leading, spacing: 10) {
        if model.reportHasFailure {
          Label(model.reportAttentionMessage, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(
              horizontal: false, vertical: true)
        }

        Button(
          model.connectorDiagnostics == nil ? "Check connector setup" : "Check again",
          systemImage: "stethoscope"
        ) {
          model.runConnectorDiagnostics()
        }
        .buttonStyle(.borderedProminent)
        .disabled(model.isDiagnosingConnectors)

        if model.isDiagnosingConnectors {
          HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking local connector configuration…")
          }.font(.system(size: 12)).foregroundStyle(.secondary)
        }

        if let error = model.connectorDiagnosticsError {
          Label(error, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 12)).foregroundStyle(.orange).fixedSize(
              horizontal: false, vertical: true)
        }

        if let snapshot = model.connectorDiagnostics {
          if snapshot.configurationPresent == false {
            Label("No ingestion.json yet, so every source needs setup. Each row lists its next step.",
              systemImage: "info.circle")
              .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Create ingestion.json", systemImage: "doc.badge.plus") {
              if model.createStarterIngestionConfiguration() { model.runConnectorDiagnostics() }
            }
            .buttonStyle(.bordered)
            .help("Write a starter file with your dashboard and blank source settings")
          }
          VStack(spacing: 8) {
            ForEach(DailyReportPlatform.allCases) { platform in
              ConnectorDiagnosticRow(
                platform: platform,
                diagnostic: snapshot.diagnostic(for: platform)
              )
            }
          }
          if let checkedAt = model.connectorDiagnosticsCheckedAt {
            Text("Checked \(checkedAt.formatted(date: .omitted, time: .shortened)) · configuration only")
              .font(.system(size: 10)).foregroundStyle(.secondary)
          }
        }

        if !model.reportHistory.standardError.isEmpty {
          DisclosureGroup("Latest report error log") {
            Text(model.reportHistory.standardError)
              .font(.system(size: 10, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.top, 7)
          }
          .font(.system(size: 12, weight: .semibold))
        }
      }
    }
    .id(QueueSettingsTarget.connectors)
  }

  private func groupHeading(_ title: String) -> some View {
    Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.7)
      .foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 6)
      .accessibilityAddTraits(.isHeader)
  }

  /// A toggle with its explanation underneath, for cards that hold several toggles.
  private func settingToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Toggle(title, isOn: isOn)
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func hotkeyRow(_ action: HotkeyAction, detail: String, isOn: Binding<Bool>) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(alignment: .firstTextBaseline) {
        Toggle(action.title, isOn: isOn)
        Spacer()
        HotkeyRecorderField(model: model, action: action).disabled(!isOn.wrappedValue)
      }
      Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  /// Buttons that open a built-in contract in full in the document viewer.
  private func builtInContractRow(_ title: String, contracts: [BuiltInAgentContract]) -> some View {
    HStack(spacing: 6) {
      Text(title)
      Spacer(minLength: 8)
      ForEach(contracts) { contract in
        let available = model.builtInContractAvailable(contract)
        Button(contracts.count == 1 ? "Open" : contract.title) { model.openBuiltInContract(contract) }
          .buttonStyle(.bordered).controlSize(.small)
          .disabled(!available)
          .help(available ? "Read the full file. \(contract.delivery)" : "Only the installed app includes this contract.")
          .accessibilityLabel(contract == .orchestrator ? "Open the orchestrator rules" : "Open the \(contract.title) agent contract")
      }
    }
  }

  /// One built-in prompt: title, when it runs, and a button that opens the full
  /// text in the document viewer.
  private func builtInPromptRow(_ prompt: BuiltInAgentPrompt) -> some View {
    let available = model.builtInPromptAvailable(prompt)
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(prompt.title).font(.system(size: 12, weight: .semibold))
        Text(prompt.delivery).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Button("Open") { model.openBuiltInPrompt(prompt) }
        .buttonStyle(.bordered).controlSize(.small)
        .disabled(!available)
        .help(available ? "Read the full prompt. \(prompt.delivery)" : "Only the installed app includes this prompt.")
        .accessibilityLabel("Open the \(prompt.title)")
    }
  }

  private func featureBadge(_ text: String) -> some View {
    Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      .padding(.horizontal, 7).padding(.vertical, 2)
      .background(.primary.opacity(0.07), in: Capsule())
  }

  private func settingsSection<Content: View>(
    title: String, badge: String? = nil, detail: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 11) {
      HStack(spacing: 8) {
        Text(title).font(.system(size: 16, weight: .bold))
        if let badge { featureBadge(badge) }
      }
      Text(detail).font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      content()
    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).notificationSurface(radius: 18)
  }
}

/// Which desktop terminal opens agent panes. The choice applies to the next
/// agent opened; windows already open stay where they are.
private struct TerminalAppSetting: View {
  let model: QueueViewModel
  @State private var installed: Set<ManagedTerminalApp> = []

  private var selected: ManagedTerminalApp { model.config.wezTerm.terminalApp }
  private var hasTmux: Bool {
    (model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux"))
      .map { FileManager.default.isExecutableFile(atPath: $0) } ?? false
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Terminal app")
      Picker("Terminal app", selection: Binding(
        get: { selected },
        set: { model.setManagedTerminal($0) }
      )) {
        ForEach(ManagedTerminalApp.choices(wezTermInstalled: installed.contains(.wezTerm) || selected == .wezTerm)) {
          Text($0.displayName).tag($0)
        }
      }.pickerStyle(.segmented).labelsHidden()
      Text("\(selected.summary) Your own \(selected.displayName) settings apply. Takes effect the next time you open an agent.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if !installed.contains(selected) {
        HStack(spacing: 6) {
          Label("\(selected.displayName) is not installed.", systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange)
          if let url = selected.downloadURL {
            Link("Get it", destination: url).font(.caption.weight(.semibold))
          }
        }
      } else if selected.requiresTmux && !hasTmux {
        Label("\(selected.displayName) needs tmux. Install it with brew install tmux.",
          systemImage: "exclamationmark.triangle")
          .font(.caption).foregroundStyle(.orange)
      }
    }
    .onAppear {
      installed = Set(ManagedTerminalApp.allCases.filter {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil
      })
    }
  }
}

