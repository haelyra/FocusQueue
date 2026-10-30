import AppKit
import Foundation
import FocusQueueCore
import SwiftUI
import Testing
import WebKit
@testable import ECCFocusQueue

/// Records demo videos as PNG frames from the real queue view, driven on an
/// example project in a scratch support directory. It draws the view's own
/// pixels offscreen, so it needs no screen recording and never takes focus.
///
///   FOCUS_QUEUE_RECORD_WALKTHROUGH=/path/to/output swift test --filter WalkthroughDemoRecording
///   ffmpeg -framerate 15 -i /path/to/output/walkthrough/%05d.png -pix_fmt yuv420p walkthrough.mp4
@Suite("Walkthrough demo recording", .serialized)
@MainActor
struct WalkthroughDemoRecording {
  nonisolated static let output = ProcessInfo.processInfo.environment["FOCUS_QUEUE_RECORD_WALKTHROUGH"]

  @Test("Record the walkthrough on an example project", .enabled(if: output != nil))
  func recordWalkthrough() async throws {
    let demo = try await DemoEnvironment(name: "walkthrough")
    defer { demo.cleanUp() }
    let model = demo.model
    #expect(model.walkthrough?.step == .welcome)

    let recorder = FrameRecorder(model: model, directory: demo.frames, size: NSSize(width: 470, height: 820))
    model.providerAccounts = [.claude: .signedIn, .codex: .signedOut, .kimi: .notInstalled]

    await recorder.hold(4)                       // welcome
    model.advanceWalkthrough()
    await recorder.hold(2.5)                     // terminal
    model.setManagedTerminal(.wezTerm)
    await recorder.hold(2)
    model.advanceWalkthrough()
    await recorder.hold(2.5)                     // default agent
    model.setDefaultAgentProvider(.claude)
    await recorder.hold(2)
    model.advanceWalkthrough()
    await recorder.hold(3)                       // sign-in
    model.providerAccounts[.codex] = .signedIn
    await recorder.hold(2.5)
    model.advanceWalkthrough()
    await recorder.hold(3.5)                     // project, in Settings

    let project = try await demo.addExampleProject()
    model.checkWalkthroughGoal()
    #expect(model.walkthrough?.step == .launchAgent)
    await recorder.hold(5)                       // launch an agent

    try await demo.seedExampleTasks(project: project)
    // Refresh rereads task contexts at most every two seconds.
    for _ in 0..<6 where model.walkthrough?.step == .launchAgent {
      await model.refresh(userInitiated: true)
      model.checkWalkthroughGoal()
      if model.walkthrough?.step == .launchAgent { await recorder.hold(0.8) }
    }
    #expect(model.walkthrough?.step == .planAndContext)
    await recorder.hold(5)                       // plan and context
    model.advanceWalkthrough()
    await recorder.hold(5)                       // UI Canvas
    model.advanceWalkthrough()
    await recorder.hold(4)                       // complete
    model.advanceWalkthrough()
    await recorder.hold(4)                       // QChat
    model.advanceWalkthrough()
    await recorder.hold(3)                       // minimize
    model.setPanelMode(.collapsed)
    await recorder.hold(1.5)
    model.setPanelMode(.expanded)
    model.checkWalkthroughGoal()
    #expect(model.walkthrough?.step == .rightClick)
    await recorder.hold(3.5)                     // right-click
    model.advanceWalkthrough()
    await recorder.hold(3.5)                     // search
    model.advanceWalkthrough()
    await recorder.hold(4)                       // help
    model.advanceWalkthrough()
    await recorder.hold(2)                       // the queue after the tour
    #expect(model.walkthrough == nil)
    #expect(recorder.count > 300)
  }

  @Test("Record the UI Canvas demo on an example project", .enabled(if: output != nil))
  func recordUICanvas() async throws {
    let demo = try await DemoEnvironment(name: "ui-canvas")
    defer { demo.cleanUp() }
    let model = demo.model
    model.finishWalkthrough()
    let project = try await demo.addExampleProject()
    try await demo.seedExampleTasks(project: project)
    for _ in 0..<6 where model.openTickets.isEmpty {
      try await Task.sleep(for: .milliseconds(700))
      await model.refresh(userInitiated: true)
    }
    #expect(model.walkthroughTicket?.id == "HAB-1")

    let recorder = FrameRecorder(model: model, directory: demo.frames, size: NSSize(width: 1240, height: 820))
    await recorder.hold(1.5)
    model.openWalkthroughCanvasDemo()
    let session = try #require(model.visibleUICanvases(ticketID: "HAB-1").first)
    let canvas = model.uiCanvasModel(ticketID: "HAB-1", key: session.key)
    await recorder.hold(4)                       // the mockup opens beside the plan

    canvas.setMode(.interact)
    await recorder.hold(1)
    for index in [2, 3] {                        // the mockup's own scripts run
      _ = try? await canvas.webView?.evaluateJavaScript(
        "document.querySelectorAll('#habits li')[\(index)].click()")
      await recorder.hold(1.6)
    }

    canvas.setMode(.edit)
    canvas.select("h1")
    await recorder.hold(2.5)                     // select an element to edit it
    canvas.setStyle("color", "#2f7d6d")
    await recorder.hold(2)
    canvas.select("button.add")
    await recorder.hold(1.5)
    canvas.setStyle("border-radius", "999px")
    await recorder.hold(2.5)

    canvas.deselect()                            // gives the conversation room
    await recorder.hold(1)
    canvas.draft = "Make Add a habit a floating button above the list"
    await recorder.hold(2)
    canvas.sendChat()
    await recorder.hold(2.5)
    try model.uiCanvasStore.reply(taskID: "HAB-1", key: session.key,
      text: "Got it. I'll pin it bottom-right as a round floating button and keep your color change.")
    canvas.refresh()
    await recorder.hold(5)
    #expect(recorder.count > 150)
  }
}

/// A scratch support directory with a booted queue and its frame folder.
@MainActor
private struct DemoEnvironment {
  let root: URL
  let frames: URL
  let model: QueueViewModel

  init(name: String) async throws {
    let output = URL(fileURLWithPath: try #require(WalkthroughDemoRecording.output))
    frames = output.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.removeItem(at: frames)
    try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    root = output.appendingPathComponent("support-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    let paths = AppPaths.live(environment: ["FOCUS_QUEUE_SUPPORT_DIR": root.path])
    model = QueueViewModel(paths: paths)
    await model.bootstrap()
    await model.bootstrapTail?.value
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }

  func addExampleProject() async throws -> ProjectDefinition {
    let repository = root.appendingPathComponent("habit-app", isDirectory: true)
    let workspace = root.appendingPathComponent("projects-data/habit-app", isDirectory: true)
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let project = ProjectDefinition(id: "habit-app", name: "Habit App",
      dashboardPath: workspace.appendingPathComponent("dashboard.json").path,
      workspacePath: workspace.path, taskPrefix: "HAB", repositoryPath: repository.path)
    #expect(await model.saveProject(project))
    _ = await model.selectProject(id: project.id)
    await model.refresh()
    return project
  }

  /// Example tasks and one running agent, as a launch would leave them.
  func seedExampleTasks(project: ProjectDefinition) async throws {
    let now = ISO8601DateFormatter().string(from: Date())
    let tickets = [
      DashboardTicket(id: "HAB-1", title: "Streak reminders", projectID: project.id, priority: "high",
        status: "in-progress",
        summary: "What: a daily nudge before a streak breaks. Why: missed days end most streaks. How: local notifications scheduled from each habit's usual time.",
        updatedAt: now, createdAt: now),
      DashboardTicket(id: "HAB-2", title: "Onboarding screens", projectID: project.id, status: "backlog",
        summary: "Three screens that set up a first habit.", updatedAt: now, createdAt: now),
      DashboardTicket(id: "HAB-3", title: "Weekly progress chart", projectID: project.id, priority: "low",
        status: "backlog", summary: "A seven-day chart on the home screen.", updatedAt: now, createdAt: now),
    ]
    let data = try JSONEncoder().encode(DashboardDocument(updatedAt: now, tickets: tickets))
    try data.write(to: URL(fileURLWithPath: project.dashboardPath))
    let contexts = TaskContextStore(root: root)
    try await contexts.ensureContext(ticket: tickets[0], project: project)
    var agent = TaskSubtask(id: "agent-1", title: "Schedule reminder notifications", provider: .claude)
    agent.lastHeartbeatAt = Date()
    try await contexts.upsertSubtask(ticketID: "HAB-1", subtask: agent)
  }
}

/// Draws the hosted queue view into PNG frames at a fixed rate over a backdrop.
/// Web views render out of process, so their own snapshots are drawn on top.
@MainActor
private final class FrameRecorder {
  static let framesPerSecond = 15.0
  private let window: NSWindow
  private let host: NSView
  private let directory: URL
  private let size: NSSize
  private let margin: CGFloat = 40
  private(set) var count = 0

  init(model: QueueViewModel, directory: URL, size: NSSize) {
    self.directory = directory
    self.size = size
    window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: size.width, height: size.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.isOpaque = false
    let hosting = NSHostingView(rootView: FullFramePanelContent { QueueView(model: model) }
      .frame(width: size.width, height: size.height))
    hosting.frame = NSRect(origin: .zero, size: size)
    window.contentView = hosting
    host = hosting
  }

  func hold(_ seconds: Double) async {
    for _ in 0..<Int(seconds * Self.framesPerSecond) {
      try? await Task.sleep(for: .milliseconds(Int(1000 / Self.framesPerSecond)))
      await capture()
    }
  }

  private func capture() async {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let panel = rep.cgImage else { return }
    let scale = CGFloat(panel.width) / size.width
    let width = Int((size.width + margin * 2) * scale)
    let height = Int((size.height + margin * 2) * scale)
    guard let context = CGContext(data: nil, width: width - width % 2, height: height - height % 2,
      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    let colors = [CGColor(srgbRed: 0.20, green: 0.24, blue: 0.33, alpha: 1),
      CGColor(srgbRed: 0.08, green: 0.09, blue: 0.13, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    context.draw(panel, in: CGRect(x: margin * scale, y: margin * scale,
      width: CGFloat(panel.width), height: CGFloat(panel.height)))
    for webView in webViews(in: host) where !webView.isHiddenOrHasHiddenAncestor {
      guard let image = try? await webView.takeSnapshot(configuration: nil),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
      let frame = webView.convert(webView.bounds, to: host)
      let y = host.isFlipped ? size.height - frame.maxY : frame.minY
      context.saveGState()
      context.clip(to: CGRect(x: margin * scale, y: margin * scale,
        width: size.width * scale, height: size.height * scale))
      context.draw(cgImage, in: CGRect(x: (frame.minX + margin) * scale, y: (y + margin) * scale,
        width: frame.width * scale, height: frame.height * scale))
      context.restoreGState()
    }
    guard let image = context.makeImage() else { return }
    let url = directory.appendingPathComponent(String(format: "%05d.png", count))
    try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    count += 1
  }

  private func webViews(in view: NSView) -> [WKWebView] {
    if let webView = view as? WKWebView { return [webView] }
    return view.subviews.flatMap(webViews)
  }
}
