import AppKit
import FocusQueueCore
import SwiftUI

// MARK: Anchors

enum WalkthroughAnchorID: Hashable {
  case target(WalkthroughTarget)
}

struct WalkthroughAnchorKey: PreferenceKey {
  static let defaultValue: [WalkthroughAnchorID: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [WalkthroughAnchorID: Anchor<CGRect>],
    nextValue: () -> [WalkthroughAnchorID: Anchor<CGRect>]
  ) {
    // The first view in layout order wins, such as the top task card.
    value.merge(nextValue()) { current, _ in current }
  }
}

extension View {
  /// Marks a control the walkthrough can spotlight. A disabled copy, such as
  /// another task's card, reports nothing.
  func walkthroughAnchor(_ target: WalkthroughTarget, isEnabled: Bool = true) -> some View {
    anchorPreference(key: WalkthroughAnchorKey.self, value: .bounds) {
      isEnabled ? [.target(target): $0] : [:]
    }
  }
}

private struct WalkthroughTicketKey: EnvironmentKey {
  static let defaultValue: String? = nil
}

extension EnvironmentValues {
  /// The task card whose controls the running walkthrough points at.
  var walkthroughTicketID: String? {
    get { self[WalkthroughTicketKey.self] }
    set { self[WalkthroughTicketKey.self] = newValue }
  }
}

// MARK: Controls

/// Progress, Skip, Back, and Next along the bottom of every tour card.
private struct WalkthroughControls: View {
  let model: QueueViewModel
  let progress: WalkthroughProgress

  /// Agents cannot run without a provider, so the tour waits on its sign-in step.
  private var waitsForSignIn: Bool {
    progress.step == .signIn && !model.hasSignedInProvider
      && !ProviderAccounts.canContinueUnverified(model.providerAccounts)
  }

  private var nextTitle: String {
    progress.isFirst ? "Start tour" : progress.isLast ? "Finish" : "Next"
  }

  var body: some View {
    VStack(spacing: 10) {
      Divider().opacity(0.6)
      HStack(spacing: 8) {
        ProgressView(value: Double(progress.position), total: Double(progress.count))
          .progressViewStyle(.linear).frame(width: 64)
          .accessibilityLabel("Step \(progress.position) of \(progress.count)")
        Text("\(progress.position)/\(progress.count)")
          .font(.system(size: 10, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
        Button("Skip") { model.finishWalkthrough() }
          .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
          .help("Skip the tour. Replay it any time from the info menu.")
        Spacer(minLength: 4)
        if !progress.isFirst {
          Button("Back") { withAnimation(.snappy) { model.retreatWalkthrough() } }
            .controlSize(.small).help("Previous step")
        }
        Button(nextTitle) { withAnimation(.snappy) { model.advanceWalkthrough() } }
          .buttonStyle(.borderedProminent).controlSize(.small)
          .keyboardShortcut(progress.step.presentation == .card ? .defaultAction : nil)
          .disabled(waitsForSignIn)
          .help(waitsForSignIn ? "Sign in to at least one provider to continue"
            : progress.isLast ? "End the tour" : "Next step")
      }
    }
    .padding(.top, 2)
  }
}

// MARK: Overlay

struct WalkthroughOverlay: View {
  let model: QueueViewModel
  let progress: WalkthroughProgress
  let anchors: [WalkthroughAnchorID: Anchor<CGRect>]

  var body: some View {
    GeometryReader { proxy in
      let size = proxy.size
      switch progress.step.presentation {
      case .card:
        ZStack {
          Rectangle()
            .fill(Color.black.opacity(0.6))
            .contentShape(Rectangle())
            .onTapGesture {}
          WalkthroughCard(model: model, progress: progress)
            .frame(maxWidth: min(size.width - 28, 430))
            .frame(maxHeight: max(size.height - 24, 200))
            .padding(.vertical, 12)
            .id(progress.step)
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
      case .spotlight(let target):
        let rect = anchors[.target(target)].map { proxy[$0] }
          .flatMap { visibleHole($0, size: size) }
        ZStack(alignment: .topLeading) {
          WalkthroughDimShape(hole: rect ?? .zero)
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
          if let rect {
            WalkthroughRing(rect: rect).allowsHitTesting(false)
          }
          WalkthroughCallout(model: model, progress: progress, hole: rect, size: size, top: 8)
        }
        .animation(.snappy(duration: 0.3), value: rect)
      }
    }
  }

  /// Pads the control and drops it when it sits off screen, such as a task
  /// card scrolled out of view, so the callout explains instead.
  private func visibleHole(_ rect: CGRect, size: CGSize) -> CGRect? {
    let padded = rect.insetBy(dx: -6, dy: -6)
    let visible = padded.intersection(CGRect(origin: .zero, size: size))
    guard !visible.isNull, visible.height >= 16, visible.width >= 16 else { return nil }
    return visible
  }
}

/// The dimmed layer with a hole for the spotlighted control.
private struct WalkthroughDimShape: Shape {
  var hole: CGRect

  var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
    get { .init(.init(hole.origin.x, hole.origin.y), .init(hole.size.width, hole.size.height)) }
    set {
      hole = CGRect(x: newValue.first.first, y: newValue.first.second,
        width: newValue.second.first, height: newValue.second.second)
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path(rect)
    if hole.width > 0, hole.height > 0 {
      path.addRoundedRect(in: hole, cornerSize: CGSize(width: 12, height: 12), style: .continuous)
    }
    return path
  }
}

private struct WalkthroughRing: View {
  let rect: CGRect
  @State private var pulse = false

  var body: some View {
    RoundedRectangle(cornerRadius: 12, style: .continuous)
      .stroke(.tint, lineWidth: 2)
      .shadow(color: .accentColor.opacity(0.7), radius: pulse ? 10 : 3)
      .frame(width: rect.width, height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
      .onAppear {
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
      }
  }
}

// MARK: Callout

private struct WalkthroughCallout: View {
  let model: QueueViewModel
  let progress: WalkthroughProgress
  let hole: CGRect?
  let size: CGSize
  let top: CGFloat

  private var width: CGFloat { min(size.width - 28, 360) }

  var body: some View {
    let card = WalkthroughCalloutContent(model: model, progress: progress, hasHole: hole != nil)
      .frame(width: width)
      .id(progress.step)
    if let hole {
      let below = size.height - hole.maxY
      let above = hole.minY - top
      let x = min(max(hole.midX, width / 2 + 14), size.width - width / 2 - 14)
      let arrowX = min(max(hole.midX - x, -width / 2 + 22), width / 2 - 22)
      VStack(spacing: 0) {
        if below >= above {
          Color.clear.frame(height: hole.maxY + 4).allowsHitTesting(false)
          WalkthroughArrow(pointsUp: true).offset(x: arrowX)
          card
          Spacer(minLength: 12).allowsHitTesting(false)
        } else {
          Spacer(minLength: top).allowsHitTesting(false)
          card
          WalkthroughArrow(pointsUp: false).offset(x: arrowX)
          Color.clear.frame(height: size.height - hole.minY + 4).allowsHitTesting(false)
        }
      }
      .frame(width: width)
      .offset(x: x - width / 2)
      .frame(width: size.width, height: size.height, alignment: .topLeading)
    } else {
      card.frame(width: size.width, height: size.height)
    }
  }
}

private struct WalkthroughArrow: View {
  let pointsUp: Bool
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Triangle()
      .fill(QueuePalette.component(for: colorScheme))
      .frame(width: 18, height: 9)
      .rotationEffect(pointsUp ? .zero : .degrees(180))
      .allowsHitTesting(false)
  }

  private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
      Path { path in
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
      }
    }
  }
}

private struct WalkthroughCalloutContent: View {
  let model: QueueViewModel
  let progress: WalkthroughProgress
  let hasHole: Bool

  private var step: WalkthroughStep { progress.step }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(step.kicker.uppercased())
        .font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.tint)
      Text(step.title).font(.system(size: 15, weight: .bold))
        .fixedSize(horizontal: false, vertical: true)
      Text(step.message).font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      extra
      if !hasHole, let fallback { WalkthroughNote(systemImage: "hand.point.up.left", text: fallback) }
      if let goal = goalText {
        HStack(spacing: 7) {
          ProgressView().controlSize(.mini)
          Text(goal).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(.top, 2)
      }
      WalkthroughControls(model: model, progress: progress)
    }
    .padding(14)
    .walkthroughSurface(radius: 16)
  }

  @ViewBuilder private var extra: some View {
    switch step {
    case .launchAgent:
      WalkthroughLifecycleDiagram(stages: WalkthroughLifecycleDiagram.taskLifecycle).padding(.vertical, 4)
      if model.walkthroughTicket != nil {
        WalkthroughNote(systemImage: "person.badge.plus",
          text: "Already have a task? New Agent on its card does the same.")
      }
    // The starter workspace has no repository, so it does not count here.
    case .project where model.config.projects.contains {
      $0.id != ProjectCatalog.otherID && !$0.repositoryPath.isEmpty
    }:
      WalkthroughNote(systemImage: "checkmark.circle",
        text: "You already have a project. Add another, or press Next.")
    case .planAndContext where model.walkthroughTicket != nil:
      WalkthroughNote(systemImage: "text.alignleft",
        text: "The card's description says what the task is, why it matters, and how it gets done.")
    case .uiCanvas:
      WalkthroughLifecycleDiagram(stages: WalkthroughLifecycleDiagram.canvasLoop).padding(.vertical, 4)
      HStack {
        Button("Try a demo canvas", systemImage: "wand.and.rays") { model.openWalkthroughCanvasDemo() }
          .buttonStyle(.borderedProminent).controlSize(.small)
          .disabled(model.walkthroughTicket == nil)
          .help("Opens an example habit-tracker mockup beside the plan. Click items, edit text, or chat.")
        Spacer()
      }
      if let message = model.walkthroughMessage {
        Text(message).font(.system(size: 11)).foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      WalkthroughNote(systemImage: "text.bubble",
        text: "Try it for real: ask an agent to \u{201C}mock up the settings screen in the UI canvas.\u{201D}")
    case .help:
      WalkthroughNote(systemImage: "play.circle", text: "Replay walkthrough in that menu brings this tour back.")
    default:
      EmptyView()
    }
  }

  /// Shown when the control is not on screen.
  private var fallback: String? {
    switch step {
    case .planAndContext, .complete, .rightClick:
      model.walkthroughTicket == nil
        ? "Create a task to see this on its card."
        : "Scroll to \(model.walkthroughTicket?.id ?? "the task") to see it."
    default:
      nil
    }
  }

  private var goalText: String? {
    switch step.goal {
    case .projectCreated: "Waiting for a new project…"
    case .agentLaunched: "Waiting for an agent to start…"
    case .panelRestored: "Waiting for you to minimize and bring the queue back…"
    case nil: nil
    }
  }
}

private struct WalkthroughNote: View {
  let systemImage: String
  let text: String

  var body: some View {
    Label {
      Text(text).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(.tint)
    }
    .font(.system(size: 11))
    .foregroundStyle(.secondary)
  }
}

/// A short loop of stages, highlighted in turn.
struct WalkthroughLifecycleDiagram: View {
  typealias Stage = (symbol: String, label: String)

  static let taskLifecycle: [Stage] = [
    ("checklist", "Task"),
    ("arrow.triangle.branch", "Worktree"),
    ("terminal", "tmux pane"),
    ("checkmark.seal", "Resolved"),
    ("archivebox", "Cleaned up"),
  ]
  static let canvasLoop: [Stage] = [
    ("text.bubble", "You ask"),
    ("rectangle.on.rectangle", "Mockup tab"),
    ("pencil.and.outline", "Edit, chat"),
    ("checkmark.circle", "Save, Finish"),
    ("hammer", "Agent builds"),
  ]

  let stages: [Stage]

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1.1)) { context in
      let active = Int(context.date.timeIntervalSinceReferenceDate / 1.1) % stages.count
      HStack(spacing: 2) {
        ForEach(stages.indices, id: \.self) { index in
          if index > 0 {
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
              .foregroundStyle(.tertiary)
          }
          VStack(spacing: 4) {
            Image(systemName: stages[index].symbol)
              .font(.system(size: 13, weight: .semibold))
              .frame(width: 30, height: 30)
              .background(Circle().fill(index == active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06)))
              .foregroundStyle(index == active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
              .scaleEffect(index == active ? 1.12 : 1)
            Text(stages[index].label).font(.system(size: 9, weight: .semibold))
              .foregroundStyle(index == active ? .primary : .secondary)
              .lineLimit(1).fixedSize()
          }
          .frame(maxWidth: .infinity)
        }
      }
      .animation(.easeInOut(duration: 0.35), value: active)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(stages.map(\.label).joined(separator: ", then "))
  }
}

// MARK: Cards

private struct WalkthroughCard: View {
  let model: QueueViewModel
  let progress: WalkthroughProgress

  private var step: WalkthroughStep { progress.step }

  var body: some View {
    // Short cards size to their content; a short window scrolls instead of clipping.
    ViewThatFits(in: .vertical) {
      content
      ScrollView { content }.scrollBounceBehavior(.basedOnSize)
    }
    .walkthroughSurface(radius: 20)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      if step == .welcome {
        Image(systemName: "square.stack.3d.up.fill")
          .font(.system(size: 30, weight: .semibold)).foregroundStyle(.tint)
      } else {
        Text(step.kicker.uppercased())
          .font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.tint)
      }
      Text(step.title).font(.system(size: step == .welcome ? 20 : 17, weight: .bold))
        .fixedSize(horizontal: false, vertical: true)
      Text(step.message).font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Group {
        switch step {
        case .welcome: WalkthroughWelcomeContent(model: model)
        case .terminal: WalkthroughTerminalContent(model: model)
        case .agents: WalkthroughAgentsContent(model: model)
        case .signIn: WalkthroughSignInContent(model: model)
        default: EmptyView()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      WalkthroughControls(model: model, progress: progress)
    }
    .padding(18)
  }
}

private struct WalkthroughWelcomeContent: View {
  let model: QueueViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      feature("arrow.triangle.branch", "Every agent gets its own git worktree and tmux pane, cleaned up when the task is resolved.")
      feature("doc.text", "Each task has one central plan that every agent in it receives.")
      feature("bubble.left.and.bubble.right", "QChat manages tasks and agents when you'd rather ask than click.")
      Picker("Appearance", selection: Binding(get: { model.appearance }, set: { model.setAppearance($0) })) {
        ForEach(QueueAppearance.allCases) { appearance in
          Label(appearance.displayName, systemImage: appearance == .dark ? "moon.fill" : "sun.max.fill")
            .tag(appearance)
        }
      }
      .pickerStyle(.segmented)
      .accessibilityLabel("Appearance")
      Text("About two minutes. Use Back and Next below, or skip and replay it later from the info menu.")
        .font(.system(size: 11)).foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.top, 2)
  }

  private func feature(_ symbol: String, _ text: String) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.tint)
        .frame(width: 20)
      Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct WalkthroughTerminalContent: View {
  let model: QueueViewModel
  @State private var installed: [ManagedTerminalApp: URL] = [:]

  private var selected: ManagedTerminalApp { model.config.wezTerm.terminalApp }
  private var tmuxPath: String? {
    let path = model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux")
    return path.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(ManagedTerminalApp.choices(wezTermInstalled: installed[.wezTerm] != nil)) { app in
        WalkthroughChoiceRow(isSelected: selected == app, isEnabled: installed[app] != nil) {
          model.setManagedTerminal(app)
        } icon: {
          if let url = installed[app] {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
          } else {
            Image(systemName: "terminal").font(.system(size: 18)).frame(width: 28, height: 28)
              .foregroundStyle(.tertiary)
          }
        } content: {
          HStack(spacing: 6) {
            Text(app.displayName).font(.system(size: 13, weight: .semibold))
            if app == .terminal { WalkthroughBadge(text: "Built in", tone: .accent) }
          }
          Text(app.summary).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } trailing: {
          if installed[app] == nil, let url = app.downloadURL {
            Link("Get it", destination: url).font(.system(size: 11, weight: .semibold))
          }
        }
      }
      if let tmuxPath {
        WalkthroughNote(systemImage: "checkmark.circle", text: "tmux found at \(tmuxPath). Agents keep running when you close their window.")
      } else {
        WalkthroughNote(systemImage: "exclamationmark.triangle",
          text: "Install tmux (brew install tmux). Agents run in it, so they keep running when their window closes.")
      }
    }
    .onAppear {
      installed = Dictionary(uniqueKeysWithValues: ManagedTerminalApp.allCases.compactMap { app in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier).map { (app, $0) }
      })
    }
  }
}

private struct WalkthroughAgentsContent: View {
  let model: QueueViewModel

  var body: some View {
    let provider = model.defaultAgentProvider
    VStack(alignment: .leading, spacing: 8) {
      Label("Connects to your existing subscriptions · no API keys", systemImage: "link")
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .foregroundStyle(.tint)
      ForEach(AgentProvider.allCases, id: \.self) { option in
        WalkthroughChoiceRow(isSelected: option == provider, isEnabled: true) {
          model.setDefaultAgentProvider(option)
        } icon: {
          Image(systemName: option.symbolName).font(.system(size: 16, weight: .semibold))
            .frame(width: 28, height: 28).foregroundStyle(.tint)
        } content: {
          Text(option.displayName).font(.system(size: 13, weight: .semibold))
          Text("Uses your \(ProviderAccounts.subscriptionName(for: option)) plan through the \(option.executableName) CLI")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } trailing: {
          WalkthroughAccountBadge(state: model.providerAccounts[option])
        }
      }
      Picker("QChat model", selection: Binding(
        get: { model.effectiveChatModel(for: provider) ?? "" },
        set: { model.setChatModel($0, for: provider) }
      )) {
        ForEach(model.agentModelChoices(for: provider)) { choice in
          Text(choice.label).tag(choice.model ?? "")
        }
      }
      .font(.system(size: 12))
      Text("Change this later in Settings → Agents or from the menus above any chat.")
        .font(.system(size: 11)).foregroundStyle(.tertiary)
    }
    .task { if model.providerAccounts.isEmpty { await model.refreshProviderAccounts() } }
  }
}

/// Covers the queue while no provider CLI is signed in: no agent can run
/// without one. It closes on its own once a sign-in is detected.
struct ProviderSignInGate: View {
  let model: QueueViewModel

  var body: some View {
    ZStack {
      Rectangle().fill(Color.black.opacity(0.6)).contentShape(Rectangle()).onTapGesture {}
      ViewThatFits(in: .vertical) {
        content
        ScrollView { content }.scrollBounceBehavior(.basedOnSize)
      }
      .walkthroughSurface(radius: 20)
      .frame(maxWidth: 430)
      .padding(14)
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("SUBSCRIPTIONS").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.tint)
      Text("Sign in to start using Focus Queue").font(.system(size: 17, weight: .bold))
        .fixedSize(horizontal: false, vertical: true)
      Text("Agents run through your own Claude, Codex, or Kimi subscription. Sign in to at least one. This screen closes by itself when a sign-in finishes.")
        .font(.system(size: 12)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      WalkthroughSignInContent(model: model)
      if ProviderAccounts.canContinueUnverified(model.providerAccounts) {
        Button("Continue without a verified sign-in") { model.continueWithoutVerifiedSignIn() }
          .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
          .help("A status check could not run. Continue if you know a provider is signed in.")
      }
    }
    .padding(18)
  }
}

/// Each provider's sign-in state with Sign in and Install actions. Used by the
/// tour, the sign-in gate, and Settings. Only Settings offers Sign out.
struct WalkthroughSignInContent: View {
  let model: QueueViewModel
  var allowsSignOut = false
  @State private var pending: Set<AgentProvider> = []
  @State private var refreshing = false
  @State private var signOutCandidate: AgentProvider?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(AgentProvider.allCases, id: \.self) { provider in
        let state = model.providerAccounts[provider]
        HStack(spacing: 10) {
          provider.iconImage(size: 16)
            .frame(width: 28, height: 28).foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(provider.displayName).font(.system(size: 13, weight: .semibold))
            Text(detail(provider, state)).font(.system(size: 11)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 6)
          action(provider, state)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
      }
      HStack {
        Button(refreshing ? "Checking…" : "Check again", systemImage: "arrow.clockwise") { refresh() }
          .controlSize(.small).disabled(refreshing)
        Spacer()
        Text(model.hasSignedInProvider ? "Skip any you don't use." : "Sign in to at least one.")
          .font(.system(size: 11)).foregroundStyle(.tertiary)
      }
      if let message = model.walkthroughMessage {
        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
    }
    .confirmationDialog(
      signOutCandidate.map { "Sign out of \($0.displayName)?" } ?? "",
      isPresented: Binding(get: { signOutCandidate != nil }, set: { if !$0 { signOutCandidate = nil } }),
      presenting: signOutCandidate
    ) { provider in
      Button("Sign out", role: .destructive) { Task { await model.signOut(from: provider) } }
      Button("Cancel", role: .cancel) {}
    } message: { provider in
      Text("This signs the \(provider.executableName) CLI out everywhere on this Mac, including your terminals. Agents using it stop working until you sign in again.")
    }
    .task { if model.providerAccounts.isEmpty { await model.refreshProviderAccounts() } }
    .task {
      // Re-check providers with an open sign-in window until they finish, and
      // every provider while none is signed in, so a sign-in or install done
      // anywhere shows up without pressing Check again.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(4))
        guard !Task.isCancelled else { return }
        let targets = model.hasSignedInProvider ? Array(pending) : AgentProvider.allCases
        guard !targets.isEmpty else { continue }
        await model.refreshProviderAccounts(targets)
        pending = pending.filter { model.providerAccounts[$0]?.isSignedIn != true }
      }
    }
  }

  private func detail(_ provider: AgentProvider, _ state: ProviderAccountState?) -> String {
    switch state {
    case .signedIn: "Connected to your \(ProviderAccounts.subscriptionName(for: provider)) plan"
    case .signedOut: pending.contains(provider) ? "Finish in the terminal window…" : "Not signed in"
    case .notInstalled: "The \(provider.executableName) CLI isn't installed"
    case .failed(let reason): reason
    case .checking, nil: "Checking…"
    }
  }

  @ViewBuilder private func action(_ provider: AgentProvider, _ state: ProviderAccountState?) -> some View {
    switch state {
    case .signedIn:
      if allowsSignOut {
        let signingOut = model.providersSigningOut.contains(provider)
        Button(signingOut ? "Signing out…" : "Sign out") { signOutCandidate = provider }
          .controlSize(.small).disabled(signingOut)
          .accessibilityLabel("Sign out of \(provider.displayName)")
          .help("Signs the \(provider.executableName) CLI out on this Mac")
      }
      Label("Signed in", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly)
        .font(.system(size: 18)).foregroundStyle(.green)
        .accessibilityLabel("\(provider.displayName) signed in")
    case .signedOut, .failed:
      let open = model.isSigningIn(provider)
      Button(open ? "Waiting…" : "Sign in") {
        pending.insert(provider)
        Task { await model.signIn(to: provider) }
      }
      .buttonStyle(.borderedProminent).controlSize(.small)
      .disabled(open)
      .help(open ? "Finish in the sign-in window that is already open"
        : "Opens \(model.config.wezTerm.terminalApp.displayName) on the \(provider.executableName) sign-in")
    case .notInstalled:
      if let url = ProviderAccounts.installURL(for: provider) {
        Link("Install", destination: url).font(.system(size: 12, weight: .semibold))
      }
    case .checking, nil:
      ProgressView().controlSize(.small)
    }
  }

  private func refresh() {
    refreshing = true
    Task {
      await model.refreshProviderAccounts()
      refreshing = false
    }
  }
}

private struct WalkthroughChoiceRow<Icon: View, Content: View, Trailing: View>: View {
  let isSelected: Bool
  let isEnabled: Bool
  let select: () -> Void
  @ViewBuilder let icon: Icon
  @ViewBuilder let content: Content
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(spacing: 10) {
      Button(action: select) {
        HStack(spacing: 10) {
          Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
            .font(.system(size: 14)).foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
          icon
          VStack(alignment: .leading, spacing: 2) { content }
          Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!isEnabled)
      .opacity(isEnabled ? 1 : 0.55)
      trailing
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

private struct WalkthroughAccountBadge: View {
  let state: ProviderAccountState?

  var body: some View {
    switch state {
    case .signedIn: WalkthroughBadge(text: "Signed in", tone: .success)
    case .signedOut: WalkthroughBadge(text: "Sign in next", tone: .warning)
    case .notInstalled: WalkthroughBadge(text: "Not installed", tone: .neutral)
    case .failed: WalkthroughBadge(text: "Unknown", tone: .neutral)
    case .checking, nil: ProgressView().controlSize(.mini)
    }
  }
}

private struct WalkthroughBadge: View {
  enum Tone { case accent, success, warning, neutral }
  let text: String
  let tone: Tone

  private var color: Color {
    switch tone {
    case .accent: .accentColor
    case .success: .green
    case .warning: .orange
    case .neutral: .secondary
    }
  }

  var body: some View {
    Text(text).font(.system(size: 10, weight: .semibold))
      .padding(.horizontal, 7).padding(.vertical, 3)
      .background(Capsule().fill(color.opacity(0.15)))
      .foregroundStyle(color)
      .fixedSize()
  }
}

private struct WalkthroughSurfaceModifier: ViewModifier {
  let radius: CGFloat
  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .fill(QueuePalette.component(for: colorScheme))
          .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.2), radius: 14, y: 5)
      }
      .overlay {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .stroke(QueuePalette.componentBorder(for: colorScheme), lineWidth: 0.75)
      }
  }
}

private extension View {
  func walkthroughSurface(radius: CGFloat) -> some View {
    modifier(WalkthroughSurfaceModifier(radius: radius))
  }
}
