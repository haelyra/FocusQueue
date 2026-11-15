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
            DecisionNodeDetail(model: model, tree: tree, node: selected)
              .frame(width: 320)
              .id(selected.id)
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

struct DecisionNodeDetail: View {
  let model: QueueViewModel
  let tree: DecisionTree
  let node: DecisionNode
  @State private var rewindOptionID: String = ""
  @State private var reason = ""
  @State private var confirmingRewind = false

  private var running: Bool { model.isDecisionActionRunning(ticketID: tree.taskID, agentID: tree.agentID) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(node.id) · departs from the \(node.divergence.label.lowercased())")
            .font(.caption).foregroundStyle(.secondary)
          Text(node.title).font(.headline).textSelection(.enabled)
          if let detail = node.detail, !detail.isEmpty {
            Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        optionsList
        if node.status == .pending { chooseSection }
        rewindSection
        recordSection
        if running { ProgressView().controlSize(.small) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(12)
    }
    .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.03)))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    .onAppear { rewindOptionID = node.nextUntriedOptionID ?? node.recommendedOptionID ?? "" }
    .confirmationDialog("Rewind \(model.decisionAgentTitle(tree)) to \(node.id)?", isPresented: $confirmingRewind) {
      Button("Rewind and take option \(rewindOptionID)", role: .destructive) {
        model.rewindDecision(ticketID: tree.taskID, agentID: tree.agentID, nodeID: node.id,
                             optionID: rewindOptionID, reason: reason)
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(rewindMessage)
    }
  }

  private var optionsList: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(node.options.enumerated()), id: \.element.id) { index, option in
        HStack(alignment: .top, spacing: 8) {
          Text(option.id).font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: 20, height: 20)
            .background(Circle().fill(node.activeAttempt?.optionID == option.id ? Color.accentColor : Color.primary.opacity(0.08)))
            .foregroundStyle(node.activeAttempt?.optionID == option.id ? Color.white : Color.primary)
          VStack(alignment: .leading, spacing: 2) {
            Text(option.label).font(.callout.weight(.medium)).textSelection(.enabled)
            if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            Text(badges(for: option, index: index)).font(.caption2).foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func badges(for option: DecisionOption, index: Int) -> String {
    var parts: [String] = []
    if index == 0 { parts.append("Recommended") } else if index == 1 { parts.append("Fallback") }
    let attempts = node.attempts.filter { $0.optionID == option.id }
    if attempts.contains(where: { $0.state == .active }) { parts.append("Current path") }
    if let abandoned = attempts.last(where: { $0.state == .abandoned }) {
      parts.append("Abandoned" + (abandoned.reason.map { ": \($0)" } ?? ""))
    }
    return parts.joined(separator: " · ")
  }

  private var chooseSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Choose").font(.subheadline.weight(.semibold))
      if let due = model.decisionAutomation.dueDate(for: node) {
        Text("With no choice by \(due.formatted(date: .omitted, time: .shortened)), Focus Queue takes option \(node.recommendedOptionID ?? "A").")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        ForEach(node.options) { option in
          Button(option.id == node.recommendedOptionID ? "Take \(option.id) (recommended)" : "Take \(option.id)") {
            model.chooseDecision(ticketID: tree.taskID, agentID: tree.agentID, nodeID: node.id, optionID: option.id)
          }
          .buttonStyle(.bordered)
          .tint(option.id == node.recommendedOptionID ? .accentColor : nil)
          .disabled(running)
          .help(option.label)
        }
      }
    }
  }

  @ViewBuilder private var rewindSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Rewind here").font(.subheadline.weight(.semibold))
      if node.checkpoint != nil {
        Picker("Then take", selection: $rewindOptionID) {
          ForEach(node.options) { option in Text("\(option.id): \(option.label)").tag(option.id) }
        }
        TextField("Why the current path is wrong (optional)", text: $reason, axis: .vertical)
          .lineLimit(1...3).textFieldStyle(.roundedBorder)
        Button("Rewind to \(node.id)…") { confirmingRewind = true }
          .disabled(running || rewindOptionID.isEmpty)
        Text(conversationLine).font(.caption).foregroundStyle(.secondary)
      } else {
        Text("No checkpoint was saved for this decision\(node.checkpointError.map { ": \($0)" } ?? ""), so its code cannot be restored.")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }

  @ViewBuilder private var recordSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Record").font(.subheadline.weight(.semibold))
      if let checkpoint = node.checkpoint {
        Text("Checkpoint \(checkpoint.shortCommit) on \(checkpoint.branch ?? "a detached head")")
          .font(.caption).textSelection(.enabled)
        Text(checkpoint.ref).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        if checkpoint.pushed {
          Label("Pushed to \(checkpoint.remote ?? "the remote")", systemImage: "checkmark.icloud")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Label(checkpoint.pushError ?? "Not pushed", systemImage: "icloud.slash")
            .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
          Button("Retry push") { model.retryDecisionPush(ticketID: tree.taskID, agentID: tree.agentID) }
            .disabled(running)
        }
      }
      ForEach(Array(node.attempts.enumerated()), id: \.offset) { _, attempt in
        Text("\(attempt.optionID) · \(attempt.state == .active ? "current" : "abandoned") · started by \(attempt.startedBy.label)"
             + (attempt.rewoundFrom.map { " · earlier work saved at \($0.shortCommit)" } ?? ""))
          .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var conversationLine: String {
    guard let conversation = node.conversation else { return "The conversation was not recorded." }
    if conversation.forkable {
      return "The agent restarts in the conversation saved at \(node.id)" + (conversation.entries.map { " (\($0) entries)" } ?? "") + "."
    }
    return conversation.note ?? "The conversation could not be saved."
  }

  private var rewindMessage: String {
    let checkpoint = node.checkpoint?.shortCommit ?? "?"
    return "The worktree returns to checkpoint \(checkpoint); its current state is committed and pushed first, so nothing is lost. "
      + (node.conversation?.forkable == true
        ? "The agent restarts in the conversation saved at \(node.id) and takes option \(rewindOptionID)."
        : "The agent's current conversation is told to drop the later turns and take option \(rewindOptionID).")
  }
}
