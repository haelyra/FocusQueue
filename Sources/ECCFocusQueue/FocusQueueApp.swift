import AppKit
import Darwin
import FocusQueueCore
import SwiftUI

@main struct FocusQueueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private let model = QueueViewModel()
  private var panel: FocusPanel?
  private var statusItem: NSStatusItem?
  private var exitTerminalFocusItem: NSMenuItem?
  private var terminalFocusController: TerminalFocusModeController?
  private var focusChromeRefreshTask: Task<Void, Never>?
  private var screenReconciliationTask: Task<Void, Never>?
  private var morningReconciliationTask: Task<Void, Never>?
  private var lastMorningAttempt: Date?
  private let morningRunner = FoundationProcessRunner()
  private var currentPlacement: QueueWindowPlacement = .upperRight
  private var preferredDisplayIdentifier: String?
  private var isApplyingPanelFrame = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(importAgentRegistration(_:)),
      name: Notification.Name(AgentRegistrationInbox.notificationName),
      object: nil
    )
    model.placementHandler = { [weak self] placement in
      self?.positionPanelOnCurrentDisplay(placement, animated: true)
    }
    model.monitorSwitchHandler = { [weak self] in self?.switchPanelMonitor() }
    model.collapseHandler = { [weak self] collapsed in self?.setPanelCollapsed(collapsed) }
    model.terminalFocusHandler = { [weak self] applicationName, windowTitleHint in
      guard let self, let terminalFocusController else {
        throw TerminalFocusModeError.applicationUnavailable(applicationName)
      }
      try await terminalFocusController.begin(
        applicationName: applicationName,
        windowTitleHint: windowTitleHint,
        targetScreen: panel?.screen
      )
    }
    model.quitHandler = { NSApplication.shared.terminate(nil) }
    model.setCanSwitchMonitor(NSScreen.screens.count > 1)

    createPanel()
    createStatusItem()
    positionPanel(.upperRight, on: defaultScreen(), animated: false, persist: false)
    panel?.orderFrontRegardless()

    Task { [weak self] in
      guard let self else { return }
      await model.bootstrap()
      if let snapshot = model.windowSnapshot {
        currentPlacement = snapshot.placement
        preferredDisplayIdentifier = snapshot.displayIdentifier
        if var restoredFrame = panel?.frame {
          restoredFrame.size.width = snapshot.width
          isApplyingPanelFrame = true
          panel?.setFrame(restoredFrame, display: false)
          isApplyingPanelFrame = false
        }
        let savedScreen = restoredScreen(for: snapshot)
        let targetScreen = savedScreen ?? defaultScreen()
        let shouldPersistFallback = snapshot.displayIdentifier == nil
        positionPanel(
          snapshot.placement,
          on: targetScreen,
          animated: false,
          persist: savedScreen != nil || shouldPersistFallback
        )
      } else {
        positionPanel(
          model.config.defaultPlacement,
          on: defaultScreen(),
          animated: false,
          persist: true
        )
      }
      panel?.orderFrontRegardless()
      startMorningReconciliationLoop()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    morningReconciliationTask?.cancel()
    DistributedNotificationCenter.default().removeObserver(self)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showPanel()
    return true
  }

  func applicationDidChangeScreenParameters(_ notification: Notification) {
    model.setCanSwitchMonitor(NSScreen.screens.count > 1)
    screenReconciliationTask?.cancel()
    screenReconciliationTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(350))
      guard !Task.isCancelled else { return }
      self?.reconcilePanelWithAvailableScreens(animated: false)
    }
  }

  func windowDidMove(_ notification: Notification) {
    scheduleFocusChromeRefresh()
  }

  func windowDidResize(_ notification: Notification) {
    saveWindowFrame()
    scheduleFocusChromeRefresh()
  }

  @objc private func showPanel() {
    guard let panel else { return }
    reconcilePanelWithAvailableScreens(animated: false)
    panel.orderFrontRegardless()
  }

  @objc private func importAgentRegistration(_ notification: Notification) {
    Task { await model.importAgentRegistrations() }
  }

  @objc private func centerPanel() {
    positionPanelOnCurrentDisplay(.center, animated: true)
    panel?.orderFrontRegardless()
  }

  @objc private func placeUpperLeft() {
    positionPanelOnCurrentDisplay(.upperLeft, animated: true)
    panel?.orderFrontRegardless()
  }

  @objc private func placeUpperRight() {
    positionPanelOnCurrentDisplay(.upperRight, animated: true)
    panel?.orderFrontRegardless()
  }

  @objc private func switchPanelMonitor() {
    guard let panel else { return }
    let screens = orderedScreens
    guard screens.count > 1 else {
      NSSound.beep()
      return
    }
    let currentScreen = currentPanelScreen()
    guard
      let nextIndex = DisplayGeometry.nextScreenIndex(
        currentScreenFrame: currentScreen.frame,
        orderedScreenFrames: screens.map(\.frame)
      )
    else {
      NSSound.beep()
      return
    }
    positionPanel(currentPlacement, on: screens[nextIndex], animated: true)
    panel.orderFrontRegardless()
  }

  @objc private func hidePanel() { panel?.orderOut(nil) }

  @objc private func exitTerminalFocus() { terminalFocusController?.dismiss() }

  @objc private func openConfiguration() { model.openConfiguration() }

  @objc private func restartApplication() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.haelyra.ecc-focus-queue"]
    do { try process.run() } catch {
      let alert = NSAlert()
      alert.messageText = "Could not restart ECC Focus Queue"
      alert.informativeText = error.localizedDescription
      alert.runModal()
    }
  }

  @objc private func quitApplication() { NSApplication.shared.terminate(nil) }

  private func startMorningReconciliationLoop() {
    guard morningReconciliationTask == nil else { return }
    morningReconciliationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        await self?.runMorningReconciliationIfDue()
        try? await Task.sleep(for: .seconds(300))
      }
    }
  }

  private func runMorningReconciliationIfDue() async {
    let now = Date()
    if let lastMorningAttempt, now.timeIntervalSince(lastMorningAttempt) < 3_600 { return }

    let support = URL(
      fileURLWithPath: "/Users/hira/Library/Application Support/ECC Focus Queue",
      isDirectory: true
    )
    let runtime = support.appendingPathComponent("ingestion", isDirectory: true)
    let stateURL = runtime.appendingPathComponent("state.json")
    let lastSuccessfulAt = Self.lastSuccessfulMorningRun(at: stateURL)
    guard MorningRunPolicy.isDue(now: now, lastSuccessfulAt: lastSuccessfulAt) else { return }

    lastMorningAttempt = now
    let script = support.appendingPathComponent(
      "automation/Scripts/focus_queue_morning.py"
    )
    guard FileManager.default.isExecutableFile(atPath: script.path) else {
      appendMorningLog(
        "Scheduled reconciliation unavailable: \(script.path) is missing.\n",
        error: true
      )
      return
    }

    do {
      let result = try await morningRunner.run(ProcessSpecification(
        executable: "/usr/bin/python3",
        arguments: [
          script.path, "run",
          "--config", support.appendingPathComponent("ingestion.json").path,
          "--runtime", runtime.path,
        ],
        workingDirectory: model.config.workspacePath,
        environment: [
          "PATH": [
            "/Users/hira/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
          ].joined(separator: ":")
        ],
        timeoutSeconds: 900,
        maximumOutputBytes: 512_000
      ))
      appendMorningLog(result.standardOutput, error: false)
      appendMorningLog(result.standardError, error: true)
      if result.timedOut {
        appendMorningLog("Scheduled reconciliation exceeded its 900-second budget.\n", error: true)
      }
      await model.refresh(forceRecurringPRProgress: true)
    } catch {
      appendMorningLog("Scheduled reconciliation failed to launch: \(error.localizedDescription)\n", error: true)
    }
  }

  private static func lastSuccessfulMorningRun(at url: URL) -> Date? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = object["lastSuccessfulAt"] as? String else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private func appendMorningLog(_ text: String, error: Bool) {
    guard !text.isEmpty else { return }
    let name = error ? "morning.stderr.log" : "morning.stdout.log"
    let url = URL(
      fileURLWithPath: "/Users/hira/Library/Application Support/ECC Focus Queue"
    ).appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    do {
      try handle.seekToEnd()
      try handle.write(contentsOf: Data(text.utf8))
    } catch {}
  }

  private func createPanel() {
    let panel = FocusPanel(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 780),
      styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.title = "ECC Focus Queue"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isMovable = false
    panel.isMovableByWindowBackground = false
    panel.minSize = NSSize(width: 400, height: 500)
    panel.maxSize = NSSize(width: 620, height: 10_000)
    panel.delegate = self
    let hostingView = NSHostingView(rootView: QueueView(model: model))
    // The panel owns its compact and expanded sizes. Prevent SwiftUI's
    // intrinsic-size updates from trying to resize the NSWindow during the
    // transition, which can otherwise create an AppKit constraint cycle.
    hostingView.sizingOptions = []
    hostingView.wantsLayer = true
    hostingView.layer?.backgroundColor = NSColor.clear.cgColor
    panel.contentView = hostingView
    self.panel = panel
    let terminalFocusController = TerminalFocusModeController(queuePanel: panel)
    terminalFocusController.stateDidChange = { [weak self] isActive in
      self?.exitTerminalFocusItem?.isHidden = !isActive
    }
    self.terminalFocusController = terminalFocusController
  }

  private func createStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "checklist", accessibilityDescription: "ECC Focus Queue")
    item.button?.toolTip = "ECC Focus Queue"

    let menu = NSMenu()
    let showItem = NSMenuItem(
      title: "Show ECC Focus Queue", action: #selector(showPanel), keyEquivalent: "")
    showItem.target = self
    menu.addItem(showItem)
    let hideItem = NSMenuItem(
      title: "Hide ECC Focus Queue", action: #selector(hidePanel), keyEquivalent: "")
    hideItem.target = self
    menu.addItem(hideItem)
    let exitFocusItem = NSMenuItem(
      title: "Exit Terminal Focus", action: #selector(exitTerminalFocus), keyEquivalent: "")
    exitFocusItem.target = self
    exitFocusItem.isHidden = true
    menu.addItem(exitFocusItem)
    exitTerminalFocusItem = exitFocusItem
    let restartItem = NSMenuItem(
      title: "Restart ECC Focus Queue", action: #selector(restartApplication), keyEquivalent: "")
    restartItem.target = self
    menu.addItem(restartItem)
    menu.addItem(.separator())
    let leftItem = NSMenuItem(
      title: "Place Upper Left", action: #selector(placeUpperLeft), keyEquivalent: "")
    leftItem.target = self
    menu.addItem(leftItem)
    let rightItem = NSMenuItem(
      title: "Place Upper Right", action: #selector(placeUpperRight), keyEquivalent: "")
    rightItem.target = self
    menu.addItem(rightItem)
    let centerItem = NSMenuItem(
      title: "Center on Current Display", action: #selector(centerPanel), keyEquivalent: "")
    centerItem.target = self
    menu.addItem(centerItem)
    let nextDisplayItem = NSMenuItem(
      title: "Move Queue to Next Display", action: #selector(switchPanelMonitor), keyEquivalent: "")
    nextDisplayItem.target = self
    menu.addItem(nextDisplayItem)
    menu.addItem(.separator())
    let configItem = NSMenuItem(
      title: "Open Config", action: #selector(openConfiguration), keyEquivalent: "")
    configItem.target = self
    menu.addItem(configItem)
    menu.addItem(.separator())
    let quitItem = NSMenuItem(
      title: "Quit ECC Focus Queue", action: #selector(quitApplication), keyEquivalent: "q")
    quitItem.target = self
    menu.addItem(quitItem)
    item.menu = menu
    statusItem = item
  }

  private func positionPanel(
    _ placement: QueueWindowPlacement,
    on targetScreen: NSScreen,
    animated: Bool,
    persist: Bool = true
  ) {
    guard let panel else { return }
    let frame = DisplayGeometry.panelFrame(
      preferredWidth: panel.frame.width,
      visibleFrame: targetScreen.visibleFrame,
      placement: placement
    )

    currentPlacement = placement
    isApplyingPanelFrame = true
    panel.setFrame(frame, display: true, animate: animated)
    isApplyingPanelFrame = false
    if persist {
      preferredDisplayIdentifier = displayIdentifier(for: targetScreen)
      saveWindowFrame()
    }
    scheduleFocusChromeRefresh()
  }

  private func positionPanelOnCurrentDisplay(
    _ placement: QueueWindowPlacement,
    animated: Bool
  ) {
    positionPanel(placement, on: currentPanelScreen(), animated: animated)
  }

  private func setPanelCollapsed(_ collapsed: Bool) {
    guard let panel else { return }
    if collapsed {
      let topEdge = panel.frame.maxY
      panel.minSize = NSSize(width: 400, height: 112)
      let compactContent = NSRect(x: 0, y: 0, width: panel.frame.width, height: 82)
      var compactFrame = panel.frameRect(forContentRect: compactContent)
      compactFrame.origin.x = panel.frame.origin.x
      compactFrame.origin.y = topEdge - compactFrame.height
      isApplyingPanelFrame = true
      panel.setFrame(compactFrame, display: true, animate: true)
      isApplyingPanelFrame = false
      saveWindowFrame()
      scheduleFocusChromeRefresh()
      return
    }

    panel.minSize = NSSize(width: 400, height: 500)
    positionPanelOnCurrentDisplay(currentPlacement, animated: true)
  }

  private func currentPanelScreen() -> NSScreen {
    if let identifier = preferredDisplayIdentifier,
      let preferredScreen = screen(matching: identifier)
    {
      return preferredScreen
    }
    return panel?.screen ?? defaultScreen()
  }

  private func defaultScreen() -> NSScreen {
    NSScreen.main ?? NSScreen.screens.first(where: { $0.frame.origin == .zero })
      ?? NSScreen.screens[0]
  }

  private var orderedScreens: [NSScreen] {
    NSScreen.screens.sorted { left, right in
      if left.frame.minX == right.frame.minX {
        return left.frame.minY < right.frame.minY
      }
      return left.frame.minX < right.frame.minX
    }
  }

  private func scheduleFocusChromeRefresh() {
    focusChromeRefreshTask?.cancel()
    focusChromeRefreshTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(100))
      guard !Task.isCancelled else { return }
      self?.terminalFocusController?.queuePanelFrameDidChange()
    }
  }

  private func saveWindowFrame() {
    guard !isApplyingPanelFrame, let panel else { return }
    let frame = panel.frame
    if preferredDisplayIdentifier == nil {
      preferredDisplayIdentifier = displayIdentifier(for: panel.screen)
    }
    model.saveWindow(
      WindowSnapshot(
        x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height,
        placement: currentPlacement,
        displayIdentifier: preferredDisplayIdentifier))
  }

  private func restoredScreen(for snapshot: WindowSnapshot) -> NSScreen? {
    if let identifier = snapshot.displayIdentifier {
      return screen(matching: identifier)
    }
    return screen(containing: snapshot)
  }

  private func screen(containing snapshot: WindowSnapshot) -> NSScreen? {
    let frame = Self.rect(from: snapshot)
    var bestMatch: NSScreen?
    var bestArea: CGFloat = 0
    for screen in NSScreen.screens {
      let intersection = screen.visibleFrame.intersection(frame)
      guard !intersection.isNull else { continue }
      let area: CGFloat = intersection.width * intersection.height
      if area > bestArea {
        bestArea = area
        bestMatch = screen
      }
    }
    return bestMatch
  }

  private func reconcilePanelWithAvailableScreens(animated: Bool) {
    let preferredScreen = preferredDisplayIdentifier.flatMap(screen(matching:))
    let targetScreen = preferredScreen ?? defaultScreen()
    positionPanel(
      currentPlacement,
      on: targetScreen,
      animated: animated,
      persist: preferredScreen != nil || preferredDisplayIdentifier == nil
    )
  }

  private func screen(matching identifier: String) -> NSScreen? {
    NSScreen.screens.first { displayIdentifier(for: $0) == identifier }
  }

  private func displayIdentifier(for screen: NSScreen?) -> String? {
    guard let screen else { return nil }
    let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")
    guard let number = screen.deviceDescription[screenNumberKey] as? NSNumber,
      let unmanagedUUID = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)
    else {
      return "name:\(screen.localizedName)"
    }
    let uuid = unmanagedUUID.takeRetainedValue()
    return CFUUIDCreateString(nil, uuid) as String
  }

  private static func rect(from snapshot: WindowSnapshot) -> NSRect {
    NSRect(x: snapshot.x, y: snapshot.y, width: snapshot.width, height: snapshot.height)
  }
}

final class FocusPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}
