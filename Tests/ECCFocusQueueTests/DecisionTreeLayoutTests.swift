import AppKit
import FocusQueueCore
import Foundation
import SwiftUI
import Testing

@testable import ECCFocusQueue

@Suite("Decision tree layout")
@MainActor
struct DecisionTreeLayoutTests {
  /// D1 chose A, which failed and was rewound to B; D2 hangs off the abandoned
  /// A path; D3 waits for the user on the current B path.
  static func sampleTree() throws -> DecisionTree {
    var tree = DecisionTree(taskID: "FOC-1", agentID: "AGENT", agentTitle: "Decision tree agent",
                            provider: "claude", now: DecisionTreeStore.timestamp())
    let pair = [DecisionOption(id: "A", label: "JSON tree file", detail: "The app draws it"),
                DecisionOption(id: "B", label: "Markdown tree file")]
    tree.addNode(title: "Store each agent's tree as JSON instead of Markdown", divergence: .taskPlan,
                 detail: "The plan named a Markdown file.", options: pair, now: DecisionTreeStore.timestamp())
    try tree.choose(nodeID: "D1", optionID: "A", by: .auto, now: DecisionTreeStore.timestamp())
    tree.addNode(title: "Push checkpoints to a custom ref", divergence: .userInstruction, detail: nil,
                 options: pair, now: DecisionTreeStore.timestamp())
    try tree.choose(nodeID: "D2", optionID: "A", by: .agent, now: DecisionTreeStore.timestamp())
    try tree.rewind(to: "D1", optionID: "B", by: .user, reason: "JSON did not render", rewoundFrom: nil,
                    sessionID: nil, now: DecisionTreeStore.timestamp())
    tree.addNode(title: "Rename the settings section", divergence: .masterPlan, detail: nil,
                 options: pair, now: DecisionTreeStore.timestamp())
    return tree
  }

  @Test("Branches spread out without overlapping, and the current path is highlighted")
  func layoutSpreadsBranches() throws {
    let tree = try Self.sampleTree()
    let layout = DecisionTreeLayout(tree: tree)
    let decisions = layout.placed.filter { if case .decision = $0.item { true } else { false } }
    #expect(decisions.count == 3)
    // Start → D1; D1 → D2 (A, abandoned) and → D3 (B, current); D2 → its A path pill.
    #expect(layout.edges.count == 4)
    let active = layout.edges.filter(\.active).map(\.to)
    #expect(active.contains(.decision("D1")) && active.contains(.decision("D3")) && !active.contains(.decision("D2")))
    let d2 = try #require(layout.center(of: .decision("D2")))
    let d3 = try #require(layout.center(of: .decision("D3")))
    let d1 = try #require(layout.center(of: .decision("D1")))
    #expect(abs(d2.x - d3.x) >= DecisionTreeLayout.cardSize.width)
    #expect(d2.y == d3.y && d1.y < d2.y)
    #expect(d1.x > min(d2.x, d3.x) && d1.x < max(d2.x, d3.x))
    #expect(layout.size.width >= 2 * DecisionTreeLayout.slotWidth)

    // The diagram uses semantic colors, so it follows the app's light or dark appearance.
    for scheme in [ColorScheme.light, .dark] {
      let renderer = ImageRenderer(content: DecisionTreeDiagram(
        tree: tree, selectedNodeID: "D3", settings: DecisionAutomationSettings(), select: { _ in })
        .padding(16).background(scheme == .dark ? Color(white: 0.11) : Color.white)
        .environment(\.colorScheme, scheme))
      renderer.scale = 2
      let image = try #require(renderer.nsImage)
      #expect(image.size.width >= layout.size.width)
      if let output = ProcessInfo.processInfo.environment["FOCUS_QUEUE_RENDER_DIR"],
         let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
        try bitmap.representation(using: .png, properties: [:])?.write(to:
          URL(fileURLWithPath: output).appendingPathComponent("decision-tree-\(scheme == .dark ? "dark" : "light").png"))
      }
    }
  }

  /// A decision with long reasoning, an option note, a pushed checkpoint, and
  /// a saved conversation: the side panel's wordiest case.
  static func detailedNode(decided: Bool) throws -> DecisionNode {
    var tree = DecisionTree(taskID: "FOC-1", agentID: "AGENT", agentTitle: nil, provider: "claude",
                            now: DecisionTreeStore.timestamp())
    tree.addNode(title: "Rewind Codex and Kimi agents in their same session instead of forking",
                 divergence: .userInstruction,
                 detail: "The request asked for a conversation fork for every agent. Codex only forks from the end of a session and Kimi not at all, so their rewinds restore the code and tell the same session to drop the later turns.",
                 options: [DecisionOption(id: "A", label: "Same-session rewind for Codex and Kimi now",
                                          detail: "Claude forks fully from a transcript copy; managed Codex and Kimi panes cannot resume mid-conversation yet"),
                           DecisionOption(id: "B", label: "Build mid-conversation forks for Codex and Kimi before shipping")],
                 now: DecisionTreeStore.timestamp())
    tree.nodes[0].checkpoint = DecisionCheckpoint(
      commit: "2d7239903578a5c3a6821771e8323cc5a7bcc154", parent: nil,
      branch: "focus-queue/foc-1-0f1e2d3c-4b5a-6978-8695-a4b3c2d1e0f9",
      ref: "refs/focus-queue/decisions/FOC-1/AGENT/D1", workspace: "/tmp/repo", remote: "origin",
      pushedAt: DecisionTreeStore.timestamp())
    tree.nodes[0].conversation = DecisionConversation(provider: "claude", sessionID: "SESSION",
                                                      snapshotPath: "/tmp/D1.jsonl", entries: 1574)
    if decided { try tree.choose(nodeID: "D1", optionID: "A", by: .agent, now: DecisionTreeStore.timestamp()) }
    return try #require(tree.node("D1"))
  }

  @Test("The side panel keeps the reasoning, checkpoint, and history collapsed until asked")
  func sidePanelCollapsesDetails() throws {
    let settings = DecisionAutomationSettings()
    let decided = try Self.detailedNode(decided: true)
    let pending = try Self.detailedNode(decided: false)
    let rewound = try #require(try Self.sampleTree().node("D1"))

    let compact = Self.panelHeight(DecisionNodeDetail(node: decided, settings: settings), render: "decision-panel-decided")
    let open = Self.panelHeight(DecisionNodeDetail(node: decided, settings: settings, expanded: true),
                                render: "decision-panel-decided-open")
    // The commit, ref, branch, conversation, and reasoning only show when opened.
    #expect(compact < open * 0.75)

    // A decision that still waits for an answer opens its reasoning by default.
    let waiting = Self.panelHeight(DecisionNodeDetail(node: pending, settings: settings), render: "decision-panel-pending")
    let waitingClosed = Self.panelHeight(DecisionNodeDetail(node: pending, settings: settings, expanded: false))
    #expect(waiting > waitingClosed)

    // History appears only after a rewind, collapsed.
    let history = Self.panelHeight(DecisionNodeDetail(node: rewound, settings: settings, expanded: true))
    let historyClosed = Self.panelHeight(DecisionNodeDetail(node: rewound, settings: settings))
    #expect(history > historyClosed)

    for dark in [false, true] {
      _ = Self.panelHeight(DecisionNodeDetail(node: decided, settings: settings),
                           render: "decision-panel-\(dark ? "dark" : "light")", dark: dark)
    }
  }

  /// Lays the panel out at the side panel's width and returns its height. With
  /// `FOCUS_QUEUE_RENDER_DIR` set, it also writes `<render>.png`.
  static func panelHeight<Panel: View>(_ panel: Panel, render name: String? = nil, dark: Bool = false) -> CGFloat {
    let hosting = NSHostingView(rootView: panel.padding(12).frame(width: 320)
      .background(dark ? Color(white: 0.11) : Color.white))
    let size = hosting.fittingSize
    guard let name, let output = ProcessInfo.processInfo.environment["FOCUS_QUEUE_RENDER_DIR"] else { return size.height }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    hosting.frame = NSRect(origin: .zero, size: size)
    window.contentView = hosting
    for _ in 0..<10 {
      RunLoop.main.run(until: Date().addingTimeInterval(0.03))
      hosting.layoutSubtreeIfNeeded()
    }
    if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
      hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
      try? bitmap.representation(using: .png, properties: [:])?
        .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
    }
    return size.height
  }

  @Test("A single pending decision shows under the start marker")
  func singlePendingDecision() {
    var tree = DecisionTree(taskID: "FOC-1", agentID: "AGENT", agentTitle: nil, provider: "codex", now: "t")
    tree.addNode(title: "Only one", divergence: .other, detail: nil,
                 options: [DecisionOption(id: "A", label: "Go")], now: DecisionTreeStore.timestamp())
    let layout = DecisionTreeLayout(tree: tree)
    #expect(layout.placed.count == 2 && layout.edges.count == 1)
    #expect(layout.center(of: .start)?.x == layout.center(of: .decision("D1"))?.x)
  }
}
