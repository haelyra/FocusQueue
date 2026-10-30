import Foundation

/// A queue control the walkthrough can spotlight.
public enum WalkthroughTarget: String, CaseIterable, Sendable {
  case projectSettings
  case newTask
  case planAndContext
  case completeTask
  case taskCard
  case qchat
  case minimize
  case search
  case help
}

/// What the queue must show for a step: a setup card, or the live queue with
/// one control spotlighted.
public enum WalkthroughPresentation: Equatable, Sendable {
  case card
  case spotlight(WalkthroughTarget)
}

/// The queue screen a step needs underneath its overlay.
public enum WalkthroughScreen: Equatable, Sendable {
  case queue
  case settings
}

public enum WalkthroughStep: String, CaseIterable, Codable, Sendable {
  case welcome
  case terminal
  case agents
  case signIn
  case project
  case launchAgent
  case planAndContext
  case uiCanvas
  case complete
  case qchat
  case minimize
  case rightClick
  case search
  case help

  public var presentation: WalkthroughPresentation {
    switch self {
    case .welcome, .terminal, .agents, .signIn: .card
    case .project: .spotlight(.projectSettings)
    case .launchAgent: .spotlight(.newTask)
    case .planAndContext, .uiCanvas: .spotlight(.planAndContext)
    case .complete: .spotlight(.completeTask)
    case .qchat: .spotlight(.qchat)
    case .minimize: .spotlight(.minimize)
    case .rightClick: .spotlight(.taskCard)
    case .search: .spotlight(.search)
    case .help: .spotlight(.help)
    }
  }

  public var screen: WalkthroughScreen { self == .project ? .settings : .queue }

  /// Short label above the title, such as "Terminals".
  public var kicker: String {
    switch self {
    case .welcome: "Welcome"
    case .terminal: "Terminals"
    case .agents: "Default agent"
    case .signIn: "Subscriptions"
    case .project: "Projects"
    case .launchAgent: "First agent"
    case .planAndContext: "Plan and context"
    case .uiCanvas: "UI Canvas"
    case .complete: "Finishing a task"
    case .qchat: "QChat"
    case .minimize: "Minimize"
    case .rightClick: "More options"
    case .search: "Search"
    case .help: "Help and feedback"
    }
  }

  public var title: String {
    switch self {
    case .welcome: "Welcome to Focus Queue"
    case .terminal: "Connect your terminal"
    case .agents: "Choose the agent for QChat and orchestrators"
    case .signIn: "Sign in with the subscriptions you have"
    case .project: "Create your first project"
    case .launchAgent: "Launch your first agent task"
    case .planAndContext: "The central plan keeps every agent on track"
    case .uiCanvas: "Prototype screens with UI Canvas"
    case .complete: "Mark the task complete when it's done"
    case .qchat: "Need to talk through tasks? Open QChat"
    case .minimize: "Click minimize"
    case .rightClick: "Right-click for more options"
    case .search: "Search every task"
    case .help: "Questions or feedback?"
    }
  }

  public var message: String {
    switch self {
    case .welcome:
      "One queue for every coding agent. Each task gets its own plan, workspace, and terminal, so several agents can work at once without colliding."
    case .terminal:
      "Agents run in tmux, and Focus Queue opens them in your terminal. Pick the one you use."
    case .agents:
      "QChat and each task's orchestrator use this provider. New agents start with it too, and you can change it per launch."
    case .signIn:
      "Focus Queue runs each provider's own CLI, so agents bill to the subscription you already pay for. Sign in only to the ones you want."
    case .project:
      "A project ties tasks to one repository. Click Add project and follow the setup."
    case .launchAgent:
      "Click + and describe the work. Focus Queue creates the task, makes it an isolated git worktree and a tmux session, and starts the agent there."
    case .planAndContext:
      "Every agent in this task receives the central plan, so they share one goal and next step. View Context holds the files, evidence, and links the agents save."
    case .uiCanvas:
      "Ask an agent to mock up a screen and it opens beside the plan as a live page. Edit it by hand or chat about it, then Save and Finish to send your changes back to the agent to build."
    case .complete:
      "Click the circle when the work is done. Focus Queue stops the task's tmux session, archives unmerged work, and cleans up its worktrees."
    case .qchat:
      "Use QChat to manage tasks and agents, ask questions about your queue, and make edits to the system. The side button keeps the queue visible beside it."
    case .minimize:
      "Minimize tucks the queue away. Click FQ to bring it back, and the tour continues."
    case .rightClick:
      "Task cards, agent rows, New Agent, and the minimize button all have extra actions on right-click."
    case .search:
      "Click Today's focus to search by words, a code such as FOC-12, a status, or a priority."
    case .help:
      "The info menu has documentation, the GitHub repository, this walkthrough, and a feedback form."
    }
  }

  /// A step with a goal finishes on its own when the user does it. Every
  /// step can still be skipped with Next.
  public var goal: WalkthroughGoal? {
    switch self {
    case .project: .projectCreated
    case .launchAgent: .agentLaunched
    case .minimize: .panelRestored
    default: nil
    }
  }
}

public enum WalkthroughGoal: Equatable, Sendable {
  case projectCreated
  case agentLaunched
  case panelRestored
}

/// Counters the walkthrough compares against the values from when a step began.
public struct WalkthroughSnapshot: Equatable, Sendable {
  public var projectCount: Int
  public var agentCount: Int
  public var panelRestoreCount: Int

  public init(projectCount: Int = 0, agentCount: Int = 0, panelRestoreCount: Int = 0) {
    self.projectCount = projectCount
    self.agentCount = agentCount
    self.panelRestoreCount = panelRestoreCount
  }
}

public struct WalkthroughProgress: Equatable, Sendable {
  public static let steps = WalkthroughStep.allCases

  public private(set) var index: Int
  /// Counters captured when the current step began.
  public private(set) var baseline: WalkthroughSnapshot

  public init(step: WalkthroughStep = .welcome, baseline: WalkthroughSnapshot = .init()) {
    index = Self.steps.firstIndex(of: step) ?? 0
    self.baseline = baseline
  }

  public var step: WalkthroughStep { Self.steps[index] }
  public var position: Int { index + 1 }
  public var count: Int { Self.steps.count }
  public var isFirst: Bool { index == 0 }
  public var isLast: Bool { index == Self.steps.count - 1 }

  public func isGoalMet(_ snapshot: WalkthroughSnapshot) -> Bool {
    switch step.goal {
    case .projectCreated: snapshot.projectCount > baseline.projectCount
    case .agentLaunched: snapshot.agentCount > baseline.agentCount
    case .panelRestored: snapshot.panelRestoreCount > baseline.panelRestoreCount
    case nil: false
    }
  }

  /// Returns false on the last step, where the walkthrough ends instead.
  public mutating func next(_ snapshot: WalkthroughSnapshot) -> Bool {
    guard !isLast else { return false }
    index += 1
    baseline = snapshot
    return true
  }

  public mutating func back(_ snapshot: WalkthroughSnapshot) {
    guard !isFirst else { return }
    index -= 1
    baseline = snapshot
  }
}
