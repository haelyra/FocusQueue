import FocusQueueCore
import SwiftUI

/// One agent's decision tree beside the task's plan: a top-down diagram of the
/// divergences it recorded, and a detail panel to choose a pending option or
/// rewind code and conversation to any node.
struct DecisionTreeView: View {
  let model: QueueViewModel
  let ticket: DashboardTicket
  @Binding var agentID: String?
  @State private var selectedNodeID: String?

  private var trees: [DecisionTree] { model.decisionTrees(ticketID: ticket.id) }

  private var tree: DecisionTree? {
    trees.first { $0.agentID.caseInsensitiveCompare(agentID ?? "") == .orderedSame } ?? trees.first
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if let tree {
        let selected = selectedNode(in: tree)
        HStack(alignment: .top, spacing: 12) {
          ScrollView([.horizontal, .vertical]) {
            DecisionTreeDiagram(tree: tree, selectedNodeID: selected?.id,
                                settings: model.decisionAutomation) { selectedNodeID = $0 }
              .padding(16)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
          .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
          if let selected {
            ScrollView {
              DecisionNodeDetail(node: selected, settings: model.decisionAutomation,
                                 running: model.isDecisionActionRunning(ticketID: tree.taskID, agentID: tree.agentID),
                                 actions: actions(tree: tree, node: selected))
                .padding(12)
            }
            .frame(width: 320)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .id("\(tree.agentID)/\(selected.id)")
          }
        }
        if let message = model.decisionMessage(ticketID: tree.taskID, agentID: tree.agentID) {
          Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.caption).foregroundStyle(message.isError ? Color.orange : Color.secondary)
            .textSelection(.enabled)
        }
      } else {
        ContentUnavailableView {
          Label("No decisions yet", systemImage: "arrow.triangle.branch")
        } description: {
          Text("An agent records a decision when its work must depart from your instruction, the master plan, or the task plan. Each decision keeps a pushed git checkpoint and the conversation, so you can rewind to it here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .padding(.horizontal, 4)
    .frame(minWidth: QueueInspectorLayout.documentMinimumWidth, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
    .onAppear { model.refreshDecisionTrees(ticketID: ticket.id) }
  }

  private var header: some View {
    HStack(spacing: 10) {
      if trees.count > 1 {
        Picker("Agent", selection: Binding(get: { tree?.agentID ?? "" }, set: { agentID = $0; selectedNodeID = nil })) {
          ForEach(trees, id: \.agentID) { tree in
            Text(model.decisionAgentTitle(tree)).tag(tree.agentID)
          }
        }
        .labelsHidden().fixedSize()
      } else if let tree {
        Text(model.decisionAgentTitle(tree)).font(.headline)
      }
      Spacer()
      let settings = model.decisionAutomation
      Text(settings.autoDecide ? "Auto-decide after \(settings.windowDescription)" : "Auto-decide off")
        .font(.caption).foregroundStyle(.secondary)
      Text(settings.autoRewind ? "· Agents may rewind" : "· Rewinds need you")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private func actions(tree: DecisionTree, node: DecisionNode) -> DecisionNodeActions {
    let (taskID, agentID, nodeID) = (tree.taskID, tree.agentID, node.id)
    return DecisionNodeActions(
      choose: { model.chooseDecision(ticketID: taskID, agentID: agentID, nodeID: nodeID, optionID: $0) },
      rewind: { model.rewindDecision(ticketID: taskID, agentID: agentID, nodeID: nodeID, optionID: $0, reason: $1) },
      retryPush: { model.retryDecisionPush(ticketID: taskID, agentID: agentID) })
  }

  private func selectedNode(in tree: DecisionTree) -> DecisionNode? {
    if let selectedNodeID, let node = tree.node(selectedNodeID) { return node }
    return tree.latestPending ?? tree.head.flatMap { tree.node($0.nodeID) } ?? tree.nodes.last
  }
}

// MARK: - Diagram

/// A tidy top-down layout: each decision sits centred over the paths taken from it.
struct DecisionTreeLayout {
  enum Item: Hashable {
    case start
    case decision(String)
    /// A path from a decision with no later decision on it.
    case path(String, String)
  }

  struct Placed {
    var item: Item
    var center: CGPoint
  }

  struct Edge: Hashable {
    var from: Item
    var to: Item
    var optionID: String?
    var active: Bool
  }

  static let slotWidth: CGFloat = 236
  static let rowHeight: CGFloat = 150
  static let cardSize = CGSize(width: 208, height: 104)
  static let pathSize = CGSize(width: 150, height: 34)

  var placed: [Placed] = []
  var edges: [Edge] = []
  var size: CGSize = .zero

  init(tree: DecisionTree) {
    let activePath = Set(tree.head.map { tree.ancestry(of: $0.nodeID) } ?? [])
    var slot: CGFloat = 0
    var depthMax = 0
    var placedItems: [Placed] = []
    var edgeList: [Edge] = []

    func children(of item: Item) -> [(Item, String?)] {
      switch item {
      case .start:
        return tree.nodes.filter { $0.parentID == nil }.map { (.decision($0.id), nil) }
      case .path:
        return []
      case .decision(let id):
        guard let node = tree.node(id) else { return [] }
        var result: [(Item, String?)] = tree.nodes
          .filter { $0.parentID == id && $0.parentOptionID == nil }.map { (.decision($0.id), nil) }
        for option in node.options {
          let below = tree.children(of: id, option: option.id)
          if !below.isEmpty {
            result += below.map { (.decision($0.id), option.id) }
          } else if node.attempts.contains(where: { $0.optionID == option.id }) {
            result.append((.path(id, option.id), option.id))
          }
        }
        return result
      }
    }

    func isActive(_ item: Item, option: String?) -> Bool {
      switch item {
      case .start: return true
      case .decision(let id): return activePath.contains(id)
      case .path(let id, let option): return tree.node(id)?.activeAttempt?.optionID == option && activePath.contains(id)
      }
    }

    @discardableResult
    func place(_ item: Item, depth: Int) -> CGFloat {
      depthMax = max(depthMax, depth)
      let kids = children(of: item)
      let x: CGFloat
      if kids.isEmpty {
        x = slot * Self.slotWidth + Self.slotWidth / 2
        slot += 1
      } else {
        let centers = kids.map { place($0.0, depth: depth + 1) }
        x = (centers.first! + centers.last!) / 2
        for (kid, option) in kids {
          edgeList.append(Edge(from: item, to: kid, optionID: option,
                               active: isActive(item, option: nil) && isActive(kid, option: option)))
        }
      }
      placedItems.append(Placed(item: item, center: CGPoint(x: x, y: CGFloat(depth) * Self.rowHeight + Self.cardSize.height / 2)))
      return x
    }

    place(.start, depth: 0)
    placed = placedItems
    edges = edgeList
    size = CGSize(width: max(slot, 1) * Self.slotWidth,
                  height: CGFloat(depthMax) * Self.rowHeight + Self.cardSize.height)
  }

  func center(of item: Item) -> CGPoint? { placed.first { $0.item == item }?.center }

  static func height(of item: Item) -> CGFloat {
    switch item {
    case .start, .path: pathSize.height
    case .decision: cardSize.height
    }
  }
}

struct DecisionTreeDiagram: View {
  let tree: DecisionTree
  let selectedNodeID: String?
  let settings: DecisionAutomationSettings
  let select: (String) -> Void

  var body: some View {
    let layout = DecisionTreeLayout(tree: tree)
    ZStack(alignment: .topLeading) {
      ForEach(layout.edges, id: \.self) { edge in
        if let from = layout.center(of: edge.from), let to = layout.center(of: edge.to) {
          DecisionEdgeShape(
            from: CGPoint(x: from.x, y: from.y + DecisionTreeLayout.height(of: edge.from) / 2),
            to: CGPoint(x: to.x, y: to.y - DecisionTreeLayout.height(of: edge.to) / 2))
            .stroke(edge.active ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: edge.active ? 2 : 1.2, dash: edge.active ? [] : [4, 3]))
          if let option = edge.optionID {
            Text(option)
              .font(.system(size: 10, weight: .bold, design: .rounded))
              .padding(.horizontal, 6).padding(.vertical, 2)
              .background(Capsule().fill(edge.active ? Color.accentColor : Color.secondary.opacity(0.25)))
              .foregroundStyle(edge.active ? Color.white : Color.primary)
              .position(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 + 6)
          }
        }
      }
      ForEach(layout.placed, id: \.item) { placed in
        item(placed.item).position(placed.center)
      }
    }
    .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
  }

  @ViewBuilder private func item(_ item: DecisionTreeLayout.Item) -> some View {
    switch item {
    case .start:
      Label("Start", systemImage: "flag")
        .font(.caption.weight(.semibold))
        .frame(width: DecisionTreeLayout.pathSize.width, height: DecisionTreeLayout.pathSize.height)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .accessibilityLabel("Agent start")
    case .decision(let id):
      if let node = tree.node(id) {
        DecisionCard(node: node, isHead: tree.head?.nodeID == id, isSelected: selectedNodeID == id,
                     dueAt: settings.dueDate(for: node)) { select(id) }
      }
    case .path(let id, let optionID):
      DecisionPathPill(node: tree.node(id), optionID: optionID, isCurrent: tree.head == DecisionHead(nodeID: id, optionID: optionID))
        .onTapGesture { select(id) }
    }
  }
}

struct DecisionEdgeShape: Shape {
  let from: CGPoint
  let to: CGPoint

  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: from)
    let middle = (from.y + to.y) / 2
    path.addCurve(to: to, control1: CGPoint(x: from.x, y: middle), control2: CGPoint(x: to.x, y: middle))
    return path
  }
}

struct DecisionCard: View {
  let node: DecisionNode
  let isHead: Bool
  let isSelected: Bool
  let dueAt: Date?
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 4) {
          Text(node.id).font(.system(size: 11, weight: .bold, design: .rounded))
          Text("· \(node.divergence.label)").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
          Spacer(minLength: 0)
          if node.checkpoint?.pushed == false {
            Image(systemName: "icloud.slash").font(.system(size: 10)).foregroundStyle(.orange)
              .help("Checkpoint not pushed")
          }
          Image(systemName: node.status == .pending ? "questionmark.circle.fill" : "checkmark.circle")
            .font(.system(size: 11)).foregroundStyle(node.status == .pending ? Color.orange : Color.secondary)
        }
        Text(node.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
          .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        Spacer(minLength: 0)
        Text(statusLine).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
      }
      .padding(9)
      .frame(width: DecisionTreeLayout.cardSize.width, height: DecisionTreeLayout.cardSize.height, alignment: .topLeading)
      .background(RoundedRectangle(cornerRadius: 10).fill(isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
      .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: isHead || node.status == .pending ? 2 : 1))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Decision \(node.id): \(node.title). \(statusLine)")
  }

  private var borderColor: Color {
    if node.status == .pending { return .orange }
    return isHead ? .accentColor : Color.primary.opacity(0.12)
  }

  private var statusLine: String {
    if node.status == .pending {
      guard let dueAt else { return "Waiting for you" }
      return "Waiting · auto at " + dueAt.formatted(date: .omitted, time: .shortened)
    }
    let chosen = node.option(node.chosenOptionID)
    let rewinds = node.attempts.count - 1
    return "\(chosen?.id ?? "?") by \(node.decidedBy?.label ?? "?")" + (rewinds > 0 ? " · \(rewinds) rewind\(rewinds == 1 ? "" : "s")" : "")
  }
}

struct DecisionPathPill: View {
  let node: DecisionNode?
  let optionID: String
  let isCurrent: Bool

  var body: some View {
    let attempt = node?.attempts.last { $0.optionID == optionID }
    let abandoned = attempt?.state == .abandoned
    HStack(spacing: 4) {
      Image(systemName: isCurrent ? "location.fill" : (abandoned ? "arrow.uturn.backward" : "circle"))
        .font(.system(size: 9))
      Text(isCurrent ? "Working here" : (abandoned ? "Abandoned" : "Taken"))
        .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
        .strikethrough(abandoned)
    }
    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
    .frame(width: DecisionTreeLayout.pathSize.width, height: DecisionTreeLayout.pathSize.height)
    .background(Capsule().fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
    .help(node?.option(optionID).map { "\($0.id): \($0.label)" + (attempt?.reason.map { " — abandoned: \($0)" } ?? "") } ?? optionID)
  }
}

// MARK: - Detail

/// What the decision panel asks the app to do.
struct DecisionNodeActions {
  var choose: @MainActor (_ optionID: String) -> Void = { _ in }
  var rewind: @MainActor (_ optionID: String, _ reason: String) -> Void = { _, _ in }
  var retryPush: @MainActor () -> Void = {}
}

/// The side panel's content for one decision. The decision, its options, and
/// the choose and rewind actions stay in view; the agent's reasoning, the
/// checkpoint, and earlier attempts sit in collapsed sections.
struct DecisionNodeDetail: View {
  let node: DecisionNode
  let settings: DecisionAutomationSettings
  let running: Bool
  let actions: DecisionNodeActions
  @State private var showsWhy: Bool
  @State private var showsCheckpoint: Bool
  @State private var showsHistory: Bool
  @State private var rewinding = false
  @State private var rewindOptionID: String
  @State private var reason = ""

  /// `expanded` opens or closes every section. When nil, only the reasoning
  /// of a decision that still waits for an answer starts open.
  init(node: DecisionNode, settings: DecisionAutomationSettings, running: Bool = false,
       actions: DecisionNodeActions = DecisionNodeActions(), expanded: Bool? = nil) {
    self.node = node
    self.settings = settings
    self.running = running
    self.actions = actions
    _showsWhy = State(initialValue: expanded ?? (node.status == .pending))
    _showsCheckpoint = State(initialValue: expanded ?? false)
    _showsHistory = State(initialValue: expanded ?? false)
    _rewindOptionID = State(initialValue: node.nextUntriedOptionID ?? node.recommendedOptionID ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      Text(node.title).font(.headline).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
      if hasReasoning { reasoning }
      options
      rewindButton
      checkpointSection
      if node.attempts.count > 1 { historySection }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var header: some View {
    HStack(spacing: 6) {
      Text(node.id).font(.system(size: 11, weight: .bold, design: .rounded))
      Text(node.divergence.label).font(.caption).foregroundStyle(.secondary)
        .help(node.divergence == .other ? "A divergence" : "Departs from the \(node.divergence.label.lowercased())")
      Spacer(minLength: 4)
      if running { ProgressView().controlSize(.mini) }
      if node.status == .pending {
        Label("Waiting for you", systemImage: "questionmark.circle.fill")
          .font(.caption.weight(.semibold)).foregroundStyle(.orange)
      } else {
        Label("Decided by \(node.decidedBy?.label ?? "?")", systemImage: "checkmark.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Reasoning

  private var optionNotes: [DecisionOption] { node.options.filter { !($0.detail ?? "").isEmpty } }

  private var hasReasoning: Bool { !(node.detail ?? "").isEmpty || !optionNotes.isEmpty }

  private var reasoning: some View {
    DisclosureGroup(isExpanded: $showsWhy) {
      VStack(alignment: .leading, spacing: 6) {
        if let detail = node.detail, !detail.isEmpty { Text(detail) }
        ForEach(optionNotes) { option in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(option.id).fontWeight(.semibold)
            Text(option.detail ?? "")
          }
        }
      }
      .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    } label: {
      Text("Why").font(.subheadline.weight(.semibold))
    }
  }

  // MARK: Options

  private var options: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(node.options) { option in optionRow(option) }
      if node.status == .pending, let due = settings.dueDate(for: node), let recommended = node.recommendedOptionID {
        Label("Auto-picks \(recommended) at \(due.formatted(date: .omitted, time: .shortened))", systemImage: "clock")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func optionRow(_ option: DecisionOption) -> some View {
    let attempts = node.attempts.filter { $0.optionID == option.id }
    let current = attempts.contains { $0.state == .active }
    let abandoned = !current && attempts.contains { $0.state == .abandoned }
    let recommended = option.id == node.recommendedOptionID
    let tags = [recommended ? "Recommended" : nil, current ? "Current" : nil, abandoned ? "Abandoned" : nil]
      .compactMap { $0 }
    return HStack(alignment: .top, spacing: 8) {
      Text(option.id).font(.system(size: 11, weight: .bold, design: .rounded))
        .frame(width: 20, height: 20)
        .background(Circle().fill(current ? Color.accentColor : Color.primary.opacity(0.08)))
        .foregroundStyle(current ? Color.white : Color.primary)
      VStack(alignment: .leading, spacing: 2) {
        Text(option.label).font(.callout).strikethrough(abandoned)
          .foregroundStyle(abandoned ? Color.secondary : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
        if !tags.isEmpty {
          Text(tags.joined(separator: " · ")).font(.caption2)
            .foregroundStyle(current ? Color.accentColor : Color.secondary)
        }
      }
      .padding(.top, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      if node.status == .pending {
        Button("Take") { actions.choose(option.id) }
          .buttonStyle(.bordered)
          .tint(recommended ? .accentColor : nil)
          .disabled(running)
          .help("Take option \(option.id): \(option.label)")
      }
    }
  }

  // MARK: Rewind

  @ViewBuilder private var rewindButton: some View {
    if node.checkpoint != nil {
      Button { rewinding = true } label: {
        Label("Rewind to \(node.id)…", systemImage: "arrow.uturn.backward")
      }
      .disabled(running || node.options.isEmpty)
      .help("Restore the code and conversation saved at \(node.id), then take an option")
      .popover(isPresented: $rewinding, arrowEdge: .bottom) { rewindForm }
    } else {
      Label("No checkpoint, so this decision can't be rewound", systemImage: "exclamationmark.triangle")
        .font(.caption).foregroundStyle(.orange)
    }
  }

  private var rewindForm: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Rewind to \(node.id)").font(.headline)
      Picker("Then take", selection: $rewindOptionID) {
        ForEach(node.options) { option in Text("\(option.id): \(option.label)").tag(option.id) }
      }
      TextField("Reason for the agent (optional)", text: $reason, axis: .vertical)
        .lineLimit(1...3).textFieldStyle(.roundedBorder)
      Text(rewindConsequence).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button("Cancel") { rewinding = false }.keyboardShortcut(.cancelAction)
        Button("Rewind", role: .destructive) {
          rewinding = false
          actions.rewind(rewindOptionID, reason)
        }
        .buttonStyle(.borderedProminent).tint(.red)
        .disabled(running || rewindOptionID.isEmpty)
      }
    }
    .padding(14)
    .frame(width: 300)
  }

  private var rewindConsequence: String {
    let restore = "Saves current work, restores the code from \(node.id),"
    return node.conversation?.forkable == true
      ? "\(restore) and restarts the agent in the conversation saved there."
      : "\(restore) and tells the agent's current session to drop the later turns."
  }

  // MARK: Checkpoint and history

  private var checkpointSection: some View {
    DisclosureGroup(isExpanded: $showsCheckpoint) {
      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
        if let checkpoint = node.checkpoint {
          GridRow {
            fieldName("Commit")
            Text("\(Text(checkpoint.shortCommit).monospaced())\(pushNote(checkpoint))")
          }
          if !checkpoint.pushed {
            GridRow {
              fieldName("Push")
              VStack(alignment: .leading, spacing: 4) {
                Text(checkpoint.pushError ?? "Not pushed").foregroundStyle(.orange)
                  .fixedSize(horizontal: false, vertical: true)
                Button("Retry push") { actions.retryPush() }.controlSize(.small).disabled(running)
              }
            }
          }
          GridRow {
            fieldName("Branch")
            Text(checkpoint.branch ?? "Detached head").lineLimit(1).truncationMode(.middle)
              .help(checkpoint.branch ?? "")
          }
          GridRow {
            fieldName("Ref")
            Text(checkpoint.ref).monospaced().lineLimit(1).truncationMode(.middle).help(checkpoint.ref)
          }
        } else {
          GridRow {
            fieldName("Commit")
            Text("None" + (node.checkpointError.map { ": \($0)" } ?? "")).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        GridRow {
          fieldName("Conversation")
          Text(conversationSummary).fixedSize(horizontal: false, vertical: true)
        }
      }
      .font(.caption).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        Text("Checkpoint").font(.subheadline.weight(.semibold))
        if node.checkpoint?.pushed != true {
          Label(node.checkpoint == nil ? "Missing" : "Not pushed", systemImage: "icloud.slash")
            .font(.caption).foregroundStyle(.orange)
        }
      }
    }
  }

  private func pushNote(_ checkpoint: DecisionCheckpoint) -> String {
    checkpoint.pushed ? ", pushed to \(checkpoint.remote ?? "the remote")" : ""
  }

  private func fieldName(_ name: String) -> some View {
    Text(name).foregroundStyle(.secondary)
  }

  private var conversationSummary: String {
    guard let conversation = node.conversation else { return "Not recorded" }
    if conversation.forkable {
      return "Saved" + (conversation.entries.map { ", \($0.formatted()) entries" } ?? "")
    }
    return conversation.note ?? "Not saved"
  }

  private var historySection: some View {
    let rewinds = node.attempts.count - 1
    return DisclosureGroup(isExpanded: $showsHistory) {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(node.attempts.enumerated()), id: \.offset) { _, attempt in
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(attempt.optionID).fontWeight(.semibold)
            Text(historyLine(attempt)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .font(.caption).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 4)
    } label: {
      HStack(spacing: 6) {
        Text("History").font(.subheadline.weight(.semibold))
        Text("\(rewinds) rewind\(rewinds == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func historyLine(_ attempt: DecisionAttempt) -> String {
    var line = attempt.state == .active ? "Current" : "Abandoned"
    if let reason = attempt.reason, !reason.isEmpty { line += ": \(reason)" }
    line += " · started by \(attempt.startedBy.label)"
    if let earlier = attempt.rewoundFrom { line += " · earlier work saved at \(earlier.shortCommit)" }
    return line
  }
}
