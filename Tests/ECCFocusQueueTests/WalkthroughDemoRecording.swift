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
///   ffmpeg -framerate 15 -i /path/to/output/walkthrough/%05d.jpg -pix_fmt yuv420p walkthrough.mp4
///   (the UI Canvas clip is meant to play at 1.5x: -framerate 22.5)
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

    let recorder = FrameRecorder(model: model, directory: demo.frames,
      desktop: NSSize(width: 1200, height: 1000), scale: 1.5)
    model.providerAccounts = [.claude: .signedIn, .codex: .signedOut, .kimi: .notInstalled]

    await recorder.hold(3)                       // welcome
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
    model.setAppearance(.dark)
    let project = try await demo.addExampleProject()
    try await demo.seedExampleTasks(project: project)
    for _ in 0..<6 where model.openTickets.isEmpty {
      try await Task.sleep(for: .milliseconds(700))
      await model.refresh(userInitiated: true)
    }
    #expect(model.walkthroughTicket?.id == "HAB-1")

    // Encode at 22.5 fps (1.5x): holds below are recorded seconds.
    let recorder = FrameRecorder(model: model, directory: demo.frames,
      desktop: NSSize(width: 1920, height: 1080), scale: 1.25)
    await recorder.hold(0.6)
    model.openWalkthroughCanvasDemo()
    // The real panel widens beside the plan; it stays clear of the screen edge.
    await recorder.resizePanel(width: 1500, frames: 6)
    let session = try #require(model.visibleUICanvases(ticketID: "HAB-1").first)
    let canvas = model.uiCanvasModel(ticketID: "HAB-1", key: session.key)
    await recorder.hold(2.4)                     // the mockup opens beside the plan

    canvas.setMode(.interact)
    await recorder.hold(0.5)
    for index in [2, 3] {                        // the page's own scripts run
      _ = try? await canvas.webView?.evaluateJavaScript(
        "document.querySelectorAll('#habits li')[\(index)].click()")
      await recorder.hold(0.9)
    }

    canvas.setMode(.edit)
    canvas.select("h1")
    await recorder.hold(1.3)                     // select an element to edit it
    canvas.setStyle("color", "#5ad1a8")
    await recorder.hold(1.1)
    canvas.select("button.add")
    await recorder.hold(0.9)
    canvas.setStyle("border-radius", "999px")
    await recorder.hold(1.3)

    canvas.deselect()                            // gives the conversation room
    await recorder.hold(0.4)
    await recorder.type("Make Add a habit a floating button in the corner", into: canvas)
    await recorder.hold(0.6)
    canvas.sendChat()
    await recorder.hold(1.2)
    try model.uiCanvasStore.reply(taskID: "HAB-1", key: session.key,
      text: "Got it. I'll pin it bottom-right as a round floating button and keep your color change.")
    canvas.refresh()
    await recorder.hold(3)
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

/// Draws the hosted queue view onto an example desktop as JPEG frames at a
/// fixed rate. Web views render out of process, so their own snapshots are
/// drawn on top.
@MainActor
private final class FrameRecorder {
  static let framesPerSecond = 15.0
  private let window: NSWindow
  private let host: NSView
  private let directory: URL
  private let desktop: NSSize
  private let scale: CGFloat
  private let wallpaper: CGImage
  /// The panel's frame in desktop points, measured from the top-left corner.
  private var panel: CGRect
  private(set) var count = 0

  init(model: QueueViewModel, directory: URL, desktop: NSSize, scale: CGFloat) {
    self.directory = directory
    self.desktop = desktop
    self.scale = scale
    let menuBar: CGFloat = 25
    panel = CGRect(x: 10, y: menuBar + 6, width: 440, height: desktop.height - menuBar - 6 - 84)
    wallpaper = Self.drawDesktop(size: desktop, scale: scale, dark: model.appearance == .dark)
    window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: panel.width, height: panel.height),
      styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.backgroundColor = .clear
    window.isOpaque = false
    let hosting = NSHostingView(rootView: FullFramePanelContent { QueueView(model: model) })
    hosting.frame = NSRect(origin: .zero, size: panel.size)
    window.contentView = hosting
    host = hosting
  }

  func hold(_ seconds: Double) async {
    for _ in 0..<Int(seconds * Self.framesPerSecond) { await frame() }
  }

  /// Widens the panel the way the app does when the plan opens.
  func resizePanel(width: CGFloat, frames: Int) async {
    let start = panel.width
    for step in 1...frames {
      let progress = CGFloat(step) / CGFloat(frames)
      let eased = 1 - pow(1 - progress, 3)
      panel.size.width = start + (width - start) * eased
      window.setContentSize(panel.size)
      host.frame = NSRect(origin: .zero, size: panel.size)
      await frame()
    }
  }

  /// Types a chat draft a few characters per frame.
  func type(_ text: String, into canvas: UICanvasModel) async {
    var typed = ""
    for character in text {
      typed.append(character)
      canvas.draft = typed
      if typed.count % 3 == 0 { await frame() }
    }
    await frame()
  }

  private func frame() async {
    try? await Task.sleep(for: .milliseconds(Int(1000 / Self.framesPerSecond)))
    await capture()
  }

  private func capture() async {
    host.layoutSubtreeIfNeeded()
    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
    host.cacheDisplay(in: host.bounds, to: rep)
    guard let panelImage = rep.cgImage, let context = Self.context(size: desktop, scale: scale) else { return }
    context.interpolationQuality = .high
    context.draw(wallpaper, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
    // Desktop points are top-left based; Core Graphics draws from the bottom.
    let target = CGRect(x: panel.minX * scale, y: (desktop.height - panel.maxY) * scale,
      width: panel.width * scale, height: panel.height * scale)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 40 * scale,
      color: CGColor(gray: 0, alpha: 0.55))
    context.draw(panelImage, in: target)
    context.restoreGState()
    for webView in webViews(in: host) where !webView.isHiddenOrHasHiddenAncestor {
      guard let image = try? await webView.takeSnapshot(configuration: nil),
        let snapshot = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
      let frame = webView.convert(webView.bounds, to: host)
      let y = host.isFlipped ? panel.height - frame.maxY : frame.minY
      context.saveGState()
      context.clip(to: target)
      context.draw(snapshot, in: CGRect(x: target.minX + frame.minX * scale, y: target.minY + y * scale,
        width: frame.width * scale, height: frame.height * scale))
      context.restoreGState()
    }
    guard let image = context.makeImage() else { return }
    let url = directory.appendingPathComponent(String(format: "%05d.jpg", count))
    try? NSBitmapImageRep(cgImage: image)
      .representation(using: .jpeg, properties: [.compressionFactor: 0.9])?.write(to: url)
    count += 1
  }

  private func webViews(in view: NSView) -> [WKWebView] {
    if let webView = view as? WKWebView { return [webView] }
    return view.subviews.flatMap(webViews)
  }

  private static func context(size: NSSize, scale: CGFloat) -> CGContext? {
    let width = Int(size.width * scale) / 2 * 2
    let height = Int(size.height * scale) / 2 * 2
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  /// An example desktop: wallpaper, a menu bar, and a dock of plain tiles.
  private static func drawDesktop(size: NSSize, scale: CGFloat, dark: Bool) -> CGImage {
    let context = context(size: size, scale: scale)!
    let width = CGFloat(context.width), height = CGFloat(context.height)
    let base = dark
      ? [CGColor(srgbRed: 0.10, green: 0.08, blue: 0.20, alpha: 1), CGColor(srgbRed: 0.03, green: 0.05, blue: 0.10, alpha: 1)]
      : [CGColor(srgbRed: 0.42, green: 0.55, blue: 0.80, alpha: 1), CGColor(srgbRed: 0.20, green: 0.27, blue: 0.48, alpha: 1)]
    context.drawLinearGradient(CGGradient(colorsSpace: nil, colors: base as CFArray, locations: [0, 1])!,
      start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])
    for (x, y, radius, color) in [
      (0.78, 0.70, 0.55, CGColor(srgbRed: 0.20, green: 0.75, blue: 0.62, alpha: dark ? 0.35 : 0.45)),
      (0.30, 0.15, 0.50, CGColor(srgbRed: 0.45, green: 0.30, blue: 0.95, alpha: dark ? 0.30 : 0.40)),
    ] {
      let glow = CGGradient(colorsSpace: nil,
        colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
      let center = CGPoint(x: width * x, y: height * y)
      context.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center,
        endRadius: width * radius, options: [])
    }
    // Menu bar
    let bar = 25 * scale
    context.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: dark ? 0.35 : 0.3))
    context.fill(CGRect(x: 0, y: height - bar, width: width, height: bar))
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let ink = NSColor.white.withAlphaComponent(0.92)
    let bold: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13 * scale, weight: .bold), .foregroundColor: ink]
    let regular: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13 * scale), .foregroundColor: ink]
    let baseline = height - bar + 6 * scale
    ("Focus Queue" as NSString).draw(at: CGPoint(x: 18 * scale, y: baseline), withAttributes: bold)
    var x = 120 * scale
    for item in ["File", "Edit", "View", "Window", "Help"] {
      (item as NSString).draw(at: CGPoint(x: x, y: baseline), withAttributes: regular)
      x += (CGFloat(item.count) * 8 + 22) * scale
    }
    let clock = "Thu 9:41 AM" as NSString
    clock.draw(at: CGPoint(x: width - clock.size(withAttributes: regular).width - 18 * scale, y: baseline),
      withAttributes: regular)
    NSGraphicsContext.restoreGraphicsState()
    // Dock
    let tiles: [CGColor] = [
      CGColor(srgbRed: 0.30, green: 0.55, blue: 0.98, alpha: 1), CGColor(srgbRed: 0.20, green: 0.78, blue: 0.55, alpha: 1),
      CGColor(srgbRed: 0.98, green: 0.62, blue: 0.20, alpha: 1), CGColor(srgbRed: 0.15, green: 0.16, blue: 0.20, alpha: 1),
      CGColor(srgbRed: 0.85, green: 0.30, blue: 0.45, alpha: 1), CGColor(srgbRed: 0.55, green: 0.40, blue: 0.95, alpha: 1),
      CGColor(srgbRed: 0.92, green: 0.92, blue: 0.95, alpha: 1),
    ]
    let tile = 48 * scale, gap = 10 * scale, pad = 10 * scale
    let dockWidth = CGFloat(tiles.count) * tile + CGFloat(tiles.count - 1) * gap + pad * 2
    let dock = CGRect(x: (width - dockWidth) / 2, y: 8 * scale, width: dockWidth, height: tile + pad * 2)
    context.setFillColor(CGColor(gray: dark ? 0.15 : 1, alpha: dark ? 0.55 : 0.35))
    context.addPath(CGPath(roundedRect: dock, cornerWidth: 18 * scale, cornerHeight: 18 * scale, transform: nil))
    context.fillPath()
    for (index, color) in tiles.enumerated() {
      let rect = CGRect(x: dock.minX + pad + CGFloat(index) * (tile + gap), y: dock.minY + pad, width: tile, height: tile)
      context.setFillColor(color)
      context.addPath(CGPath(roundedRect: rect, cornerWidth: 11 * scale, cornerHeight: 11 * scale, transform: nil))
      context.fillPath()
    }
    return context.makeImage()!
  }
}
