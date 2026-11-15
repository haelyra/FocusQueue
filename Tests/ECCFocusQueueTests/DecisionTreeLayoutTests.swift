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

    let renderer = ImageRenderer(content: DecisionTreeDiagram(
      tree: tree, selectedNodeID: "D3", settings: DecisionAutomationSettings(), select: { _ in })
      .padding(16).background(Color(nsColor: .windowBackgroundColor)))
    renderer.scale = 2
    let image = try #require(renderer.nsImage)
    #expect(image.size.width >= layout.size.width)
    if let output = ProcessInfo.processInfo.environment["FOCUS_QUEUE_RENDER_DIR"],
       let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
      try bitmap.representation(using: .png, properties: [:])?.write(to:
        URL(fileURLWithPath: output).appendingPathComponent("decision-tree.png"))
    }
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
