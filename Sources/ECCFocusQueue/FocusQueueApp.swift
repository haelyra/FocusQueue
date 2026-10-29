import AppKit
import Darwin
import FocusQueueCore
import SwiftUI
import UserNotifications

@main struct FocusQueueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class DailyReportRunCoordinator {
  private var activeRun: (id: UUID, task: Task<DailyReportDocument?, Never>)?

  var hasActiveRun: Bool { activeRun != nil }

  func run(
    _ operation: @escaping @MainActor () async -> DailyReportDocument?
  ) async -> DailyReportDocument? {
    guard activeRun == nil else { return nil }
    let id = UUID()
    let task = Task { @MainActor in await operation() }
    activeRun = (id, task)
    let result = await task.value
    if activeRun?.id == id { activeRun = nil }
    return result
  }

  func cancel() {
    activeRun?.task.cancel()
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  UNUserNotificationCenterDelegate
{
  private let paths = AppPaths.live()
  private let programLog = ProgramLogStore()
  private lazy var model = QueueViewModel(paths: paths, programLog: programLog)
  private lazy var dailyReportApprovalRepository = JSONDailyReportApprovalRepository(
    url: paths.dailyReportApprovalFile
  )
  private var panel: FocusPanel?
  private var programLogWindow: NSWindow?
  private var statusItem: NSStatusItem?
  private var exitTerminalFocusItem: NSMenuItem?
  private var terminalFocusController: TerminalFocusModeController?
  private var newTaskHotkeyMonitor: NewTaskHotkeyMonitor?
  private var qchatHotkeyMonitor: QChatHotkeyMonitor?
  private var focusChromeRefreshTask: Task<Void, Never>?
  private var screenReconciliationTask: Task<Void, Never>?
  private var movePersistTask: Task<Void, Never>?
  private var morningReconciliationTask: Task<Void, Never>?
  private var lastMorningAttempt: Date?
  private var lastFailedDailyReportAttempt: Date?
  private let morningRunner = FoundationProcessRunner()
  private let dailyReportRunCoordinator = DailyReportRunCoordinator()
  private var isDailyReportProcessRunning = false
  private var expandedPanelFrame: NSRect?
  private var compactPanelWidth: CGFloat = 440
  private var currentPlacement: QueueWindowPlacement = .upperLeft
  private var preferredDisplayIdentifier: String?
  private var isApplyingPanelFrame = false
  private var appliedPanelMode: QueuePanelMode = .expanded
  private var isModelReady = false
  private var pendingDailyReportDecision: (shouldRun: Bool, approvalID: UUID?)?
  private var isResolvingDailyReportApproval = false
  private var availabilityResumedAt = Date()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    programLog.record("Focus Queue launched.", category: "Lifecycle")
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(importAgentRegistration(_:)),
      name: Notification.Name(AgentRegistrationInbox.notificationName),
      object: nil
    )
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(reloadProjectCatalog(_:)),
      name: Notification.Name(ProjectCatalogChangeNotification.name),
      object: nil
    )
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(uiCanvasChanged(_:)),
      name: Notification.Name(UICanvasStore.notificationName),
      object: nil
    )
    DistributedNotificationCenter.default().addObserver(
      self,
      selector: #selector(reloadQueueOrder(_:)),
      name: Notification.Name(QueueOrderStore.changeNotificationName),
      object: nil
    )
    model.placementHandler = { [weak self] placement in
      self?.positionPanelOnCurrentDisplay(placement, animated: true)
    }
    model.monitorSwitchHandler = { [weak self] in self?.switchPanelMonitor() }
    model.panelModeHandler = { [weak self] mode in self?.setPanelMode(mode) }
    model.minimizeHandler = { [weak self] in self?.panel?.miniaturize(nil) }
    model.reportVisibilityHandler = { [weak self] visible in
      self?.setDailyReportVisible(visible)
    }
    model.dailyReportRunHandler = { [weak self] request in
      await self?.runDailyReport(request)
    }
    model.dailyReportCancelHandler = { [weak self] in
      self?.dailyReportRunCoordinator.cancel()
    }
    model.dailyReportApprovalHandler = { [weak self] shouldRun in
      await self?.respondToDailyReportApproval(shouldRun: shouldRun)
    }
    model.dailyReportsEnabledHandler = { [weak self] enabled in
      guard !enabled else { return }
      self?.disableAutomaticDailyReports()
    }
    model.programLogVisibilityHandler = { [weak self] visible in
      self?.setProgramLogWindowVisible(visible)
    }
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
    model.agentTerminalFocusHandler = { [weak self] applicationName, taskID in
      guard let self, let terminalFocusController else {
        throw TerminalFocusModeError.applicationUnavailable(applicationName)
      }
      try await terminalFocusController.begin(applicationName: applicationName, windowTitleHint: taskID,
        targetScreen: panel?.screen, requiresActivatedWindow: true)
    }
    model.quitHandler = { NSApplication.shared.terminate(nil) }
    model.newTaskHotkeyEnabledHandler = { [weak self] _ in self?.applyHotkeys(promptForAccess: false) }
    model.qchatHotkeyEnabledHandler = { [weak self] _ in self?.applyHotkeys(promptForAccess: true) }
    model.hotkeyConfigurationHandler = { [weak self] in self?.applyHotkeys(promptForAccess: false) }
    model.setCanSwitchMonitor(NSScreen.screens.count > 1)
    configureDailyReportNotifications()
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(computerDidWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    createPanel()
    createStatusItem()
    applyHotkeys(promptForAccess: false)
    positionPanel(.upperLeft, on: defaultScreen(), animated: false, persist: false)
    panel?.orderFrontRegardless()

    Task { [weak self] in
      guard let self else { return }
      await model.bootstrap()
      if !model.config.dailyReport.enabled {
        disableAutomaticDailyReports()
      }
      Task {
        if let executable = model.config.tmuxExecutable ?? SetupEnvironment.executable("tmux") {
          do {
            if !(try await TmuxController().panes(executable: executable)).isEmpty {
              let persistence = try TmuxPersistence.prepare(executable: executable,
                supportDirectory: model.configurationURL.deletingLastPathComponent())
              try await persistence.enable()
            }
          } catch {
            let message = "Managed tmux persistence: \(error.localizedDescription)"
            programLog.record(message, level: .warning, category: "Terminals")
            NSLog("%@", message)
          }
        }
      }
      if let snapshot = model.windowSnapshot {
        currentPlacement = snapshot.placement
        preferredDisplayIdentifier = snapshot.displayIdentifier
        if var restoredFrame = panel?.frame {
          compactPanelWidth = min(max(snapshot.width, 400), 620)
          restoredFrame.size.width = compactPanelWidth
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
      isModelReady = model.configurationIsLoaded
      setProgramLogWindowVisible(model.isProgramLogWindowVisible)
      if isModelReady, let decision = pendingDailyReportDecision {
        pendingDailyReportDecision = nil
        await respondToDailyReportApproval(
          shouldRun: decision.shouldRun,
          expectedApprovalID: decision.approvalID
        )
      }
      if isModelReady {
        startMorningReconciliationLoop()
      }
    }
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    // Returning from System Settings is the usual moment Accessibility was just granted.
    if usesDefaultGesture(.qchat) { qchatHotkeyMonitor?.start() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    programLog.record("Focus Queue is terminating.", category: "Lifecycle")
    newTaskHotkeyMonitor?.stop()
    qchatHotkeyMonitor?.stop()
    for action in HotkeyAction.allCases { GlobalHotKeyCenter.shared.unregister(action) }
    morningReconciliationTask?.cancel()
    _ = try? DailyReportWorkerControl.requestCancellation(
      runtimeDirectory: paths.ingestionRuntimeDirectory)
    dailyReportRunCoordinator.cancel()
    DistributedNotificationCenter.default().removeObserver(self)
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    revealPanelOnPointerDisplay()
    return true
  }

  func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
    revealPanelOnPointerDisplay()
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
    guard notification.object as? NSWindow === panel, !isApplyingPanelFrame else { return }
    movePersistTask?.cancel()
    movePersistTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, let self, !self.isApplyingPanelFrame else { return }
      self.persistDraggedPlacement()
    }
  }

  private func persistDraggedPlacement() {
    guard let panel else { return }
    let screen = panel.screen ?? defaultScreen()
    let visible = screen.visibleFrame
    let midX = panel.frame.midX
    let third = visible.width / 3
    if midX < visible.minX + third {
      currentPlacement = .upperLeft
    } else if midX > visible.maxX - third {
      currentPlacement = .upperRight
    } else {
      currentPlacement = .center
    }
    preferredDisplayIdentifier = displayIdentifier(for: screen)
    saveWindowFrame()
  }

  func windowDidResize(_ notification: Notification) {
    if !isApplyingPanelFrame, model.panelMode == .expanded, !model.isInspectorPresented, let panel {
      compactPanelWidth = min(max(panel.frame.width, 400), 620)
    }
    saveWindowFrame()
    scheduleFocusChromeRefresh()
  }

  func windowWillClose(_ notification: Notification) {
    guard notification.object as? NSWindow === programLogWindow,
      model.isProgramLogWindowVisible
    else { return }
    model.setProgramLogWindowVisible(false)
  }

  func windowDidMiniaturize(_ notification: Notification) {
    guard notification.object as? NSWindow === panel else { return }
    model.setPanelVisible(false)
  }

  func windowDidDeminiaturize(_ notification: Notification) {
    guard notification.object as? NSWindow === panel else { return }
    model.setPanelVisible(true)
  }

  func applicationDidHide(_ notification: Notification) {
    model.setPanelVisible(false)
  }

  func applicationDidUnhide(_ notification: Notification) {
    model.setPanelVisible(panel?.isVisible ?? false)
  }

  @objc private func showPanel() {
    revealPanelOnPointerDisplay()
  }

  private func revealPanelOnPointerDisplay() {
    guard let panel else { return }
    let screens = NSScreen.screens
    let frames = screens.map(\.frame)
    let pointer = NSEvent.mouseLocation
    let pointerScreen = DisplayGeometry.screenIndex(
      containing: pointer,
      screenFrames: frames
    ).map { screens[$0] }
    positionPanel(
      currentPlacement,
      on: pointerScreen ?? defaultScreen(),
      animated: false
    )
    NSApp.unhide(nil)
    panel.deminiaturize(nil)
    panel.orderFrontRegardless()
    NSApp.activate(ignoringOtherApps: true)
    model.setPanelVisible(true)
  }

  /// An enabled action uses its recorded combo when it has one, otherwise its
  /// built-in gesture monitor. Everything pauses while a shortcut field records.
  private func applyHotkeys(promptForAccess: Bool) {
    for action in HotkeyAction.allCases {
      GlobalHotKeyCenter.shared.unregister(action)
      let active = model.isHotkeyEnabled(action) && !model.isRecordingHotkey
      let shortcut = active ? model.hotkeyShortcut(for: action) : nil
      let gesture = active && shortcut == nil
      switch action {
      case .newTask:
        if gesture { if newTaskHotkeyMonitor == nil { startNewTaskHotkeyMonitor() } } else { stopNewTaskHotkeyMonitor() }
      case .qchat:
        if gesture { if qchatHotkeyMonitor?.isRunning != true { startQChatHotkeyMonitor(promptForAccess: promptForAccess) } }
        else { stopQChatHotkeyMonitor() }
      }
      guard let shortcut else {
        if !model.isRecordingHotkey { model.setHotkeyError(nil, for: action) }
        continue
      }
      let error = GlobalHotKeyCenter.shared.register(shortcut, for: action) { [weak self] in
        self?.handleHotkey(action)
      }
      model.setHotkeyError(error, for: action)
    }
  }

  private func usesDefaultGesture(_ action: HotkeyAction) -> Bool {
    model.isHotkeyEnabled(action) && !model.isRecordingHotkey && model.hotkeyShortcut(for: action) == nil
  }

  private func handleHotkey(_ action: HotkeyAction) {
    guard !model.isRecordingHotkey else { return }
    switch action {
    case .newTask: handleNewTaskHotkey()
    case .qchat: handleQChatHotkey()
    }
  }

  private func startNewTaskHotkeyMonitor() {
    let monitor = NewTaskHotkeyMonitor()
    monitor.onTrigger = { [weak self] in self?.handleHotkey(.newTask) }
    monitor.start()
    newTaskHotkeyMonitor = monitor
  }

  private func stopNewTaskHotkeyMonitor() {
    newTaskHotkeyMonitor?.stop()
    newTaskHotkeyMonitor = nil
  }

  /// Plain toggle. Gating the cancel on key-window state failed: a sheet on the
  /// non-activating panel did not report key while it was open.
  private func handleNewTaskHotkey() {
    let isOpen = model.newTaskRequest != nil
    NSLog("New task hotkey: %@, panel key=%d, sheet key=%d, app active=%d",
      isOpen ? "cancel" : "open", panel?.isKeyWindow == true,
      panel?.attachedSheet?.isKeyWindow == true, NSApp.isActive)
    if !isOpen { revealPanelOnPointerDisplay() }
    model.toggleNewTaskRequest()
  }

  private func startQChatHotkeyMonitor(promptForAccess: Bool) {
    let monitor = qchatHotkeyMonitor ?? QChatHotkeyMonitor()
    monitor.onTrigger = { [weak self] in self?.handleHotkey(.qchat) }
    qchatHotkeyMonitor = monitor
    guard !monitor.start() else { return }
    programLog.record(
      "QChat hotkey (Right Option + /) needs Accessibility access in System Settings > Privacy & Security.",
      level: .warning, category: "Hotkeys")
    if promptForAccess {
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }
  }

  private func stopQChatHotkeyMonitor() {
    qchatHotkeyMonitor?.stop()
    qchatHotkeyMonitor = nil
  }

  /// Toggles like the side-panel button, but a press while another app has the
  /// keyboard brings the open chat back into focus instead of closing it.
  private func handleQChatHotkey() {
    if model.isQueueChatInspectorPresented, model.panelMode == .expanded,
      panel?.isKeyWindow == true, model.newTaskRequest == nil
    {
      model.setQueueChatInspectorPresented(false)
      return
    }
    revealPanelOnPointerDisplay()
    // A non-activating panel only takes typing once it is key; ordering it front is not enough.
    panel?.makeKey()
    model.requestQueueChatFocus()
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(600))
      guard let self, let panel else { return }
      let focused = panel.isKeyWindow && panel.firstResponder is QueueChatComposerNSTextView
      NSLog("QChat hotkey: panel key=%d, composer focused=%d", panel.isKeyWindow, focused)
      if !focused {
        programLog.record("QChat hotkey could not focus the message box.", level: .warning,
          category: "Hotkeys")
      }
    }
  }

  @objc private func importAgentRegistration(_ notification: Notification) {
    Task { await model.refreshExternalAgentRegistrations(force: true) }
  }

  @objc private func uiCanvasChanged(_ notification: Notification) {
    guard let ticketID = notification.userInfo?["task"] as? String,
          let key = notification.userInfo?["key"] as? String else { return }
    model.handleUICanvasChange(ticketID: ticketID, key: key, event: notification.userInfo?["event"] as? String,
                               root: notification.userInfo?["root"] as? String)
  }

  @objc private func reloadQueueOrder(_ notification: Notification) {
    model.reloadQueueOrder()
  }

  @objc private func reloadProjectCatalog(_ notification: Notification) {
    Task {
      if await model.reloadConfigurationFromDisk() {
        await model.refresh(forceRecurringPRProgress: true, userInitiated: true)
      }
    }
  }

  @objc private func centerPanel() {
    positionPanelOnCurrentDisplay(.center, animated: true)
    panel?.orderFrontRegardless()
    model.setPanelVisible(true)
  }

  @objc private func placeUpperLeft() {
    positionPanelOnCurrentDisplay(.upperLeft, animated: true)
    panel?.orderFrontRegardless()
    model.setPanelVisible(true)
  }

  @objc private func placeUpperRight() {
    positionPanelOnCurrentDisplay(.upperRight, animated: true)
    panel?.orderFrontRegardless()
    model.setPanelVisible(true)
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
    model.setPanelVisible(true)
  }

  @objc private func hidePanel() {
    panel?.orderOut(nil)
    model.setPanelVisible(false)
  }

  @objc private func exitTerminalFocus() { terminalFocusController?.dismiss() }

  @objc private func openConfiguration() { model.openConfiguration() }

  @objc private func restartApplication() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.haelyra.ecc-focus-queue"]
    do { try process.run() } catch {
      let alert = NSAlert()
      alert.messageText = "Could not restart Focus Queue"
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
    guard model.config.dailyReport.enabled else { return }
    guard FileManager.default.fileExists(atPath: paths.ingestionConfigurationFile.path),
      FileManager.default.isReadableFile(atPath: paths.dailyReportScript.path) else { return }
    let now = Date()
    let stateURL = paths.ingestionRuntimeDirectory.appendingPathComponent("state.json")
    let settings = model.config.dailyReport
    let lastSuccessfulAt = [
      Self.lastComprehensiveDailyReport(
        at: stateURL,
        covering: settings.enabledPlatforms
      ),
      Self.lastGeneratedDailyReport(
        at: paths.latestDailyReportFile,
        covering: settings.enabledPlatforms
      ),
    ].compactMap { $0 }.max()
    let lastUnsuccessfulAttemptAt = [
      Self.lastUnsuccessfulComprehensiveAttempt(
        at: stateURL,
        covering: settings.enabledPlatforms
      ),
      Self.lastUnsuccessfulGeneratedDailyReport(
        at: paths.latestDailyReportFile,
        covering: settings.enabledPlatforms
      ),
      lastFailedDailyReportAttempt,
    ].compactMap { $0 }.max()
    let retryInterval: TimeInterval = lastUnsuccessfulAttemptAt == nil ? 3_600 : 15 * 60
    if let lastMorningAttempt, now.timeIntervalSince(lastMorningAttempt) < retryInterval { return }
    let disposition = MorningRunPolicy.disposition(
      now: now,
      lastSuccessfulAt: lastSuccessfulAt,
      lastUnsuccessfulAttemptAt: lastUnsuccessfulAttemptAt,
      hour: settings.scheduleHour,
      minute: settings.scheduleMinute,
      automaticGraceMinutes: 10,
      availabilityResumedAt: availabilityResumedAt
    )
    guard disposition != .notDue else { return }
    guard !model.isQueueAgentResponding, !isDailyReportProcessRunning else { return }
    lastMorningAttempt = now

    switch disposition {
    case .notDue:
      return
    case .runAutomatically:
      let report = await runDailyReport(DailyReportRunRequest(
        trigger: .scheduled,
        platforms: settings.enabledPlatforms,
        comprehensive: true,
        recheck: false
      ))
      lastFailedDailyReportAttempt = report?.status == .success ? nil : Date()
    case .requestApproval:
      await requestMissedDailyReportApproval(now: now)
    }
  }

  @objc private func computerDidWake() {
    availabilityResumedAt = Date()
    Task { @MainActor [weak self] in
      await self?.runMorningReconciliationIfDue()
    }
  }

  private func runDailyReport(
    _ request: DailyReportRunRequest
  ) async -> DailyReportDocument? {
    await dailyReportRunCoordinator.run { [weak self] in
      await self?.performDailyReport(request)
    }
  }

  private func performDailyReport(
    _ request: DailyReportRunRequest
  ) async -> DailyReportDocument? {
    guard !model.reportIsRunning else {
      model.setDailyReportRunState(
        isRunning: false,
        message: "A daily report is already running."
      )
      return nil
    }
    guard !isDailyReportProcessRunning else {
      model.setDailyReportRunState(
        isRunning: true,
        message: "A daily report is already running."
      )
      return nil
    }
    guard request.trigger == .chat || !model.isQueueAgentResponding else {
      model.setDailyReportRunState(
        isRunning: false,
        message: "Wait for the queue agent to finish before running the daily report."
      )
      return nil
    }
    let script = paths.dailyReportScript
    guard FileManager.default.fileExists(atPath: script.path) else {
      let message = "Daily report automation is unavailable because \(script.path) is missing."
      appendMorningLog("\(message)\n", error: true)
      model.setDailyReportRunState(isRunning: false, message: message, isError: true)
      return nil
    }

    isDailyReportProcessRunning = true
    defer { isDailyReportProcessRunning = false }
    model.setDailyReportRunState(isRunning: true, message: "Checking new messages…")
    guard await model.persistDailyReportConfiguration() else {
      model.setDailyReportRunState(
        isRunning: false,
        message: "Daily report settings could not be saved before the run.",
        isError: true
      )
      return nil
    }
    do {
      try Task.checkCancellation()
      let sweepProvider = request.agentProvider ?? model.dailyReportAgentProvider
      let result = try await morningRunner.run(ProcessSpecification(
        executable: "/usr/bin/python3",
        arguments: DailyReportAutomation.arguments(
          scriptPath: script.path,
          configurationPath: paths.ingestionConfigurationFile.path,
          runtimePath: paths.ingestionRuntimeDirectory.path,
          request: request,
          agentProvider: sweepProvider,
          agentModel: request.agentModel
            ?? model.config.dailyReport.agentModel
            ?? model.defaultAgentModel(for: sweepProvider),
          agentEffort: request.agentEffort
            ?? model.config.dailyReport.agentEffort
            ?? model.defaultAgentEffort(for: sweepProvider)
        ),
        workingDirectory: model.config.workspacePath,
        environment: [
          "PATH": [
            NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
          ].joined(separator: ":")
        ],
        timeoutSeconds: 900,
        maximumOutputBytes: 512_000,
        terminationGraceSeconds: 3
      ))
      appendMorningLog(result.standardOutput, error: false)
      appendMorningLog(result.standardError, error: true)
      if result.timedOut {
        appendMorningLog("Daily report exceeded its 900-second budget.\n", error: true)
      }
      await model.refresh(forceRecurringPRProgress: true)
      let decodedReport = Self.reportFromRunOutput(
        result.standardOutput,
        runtime: paths.ingestionRuntimeDirectory
      )
      let report = decodedReport.flatMap {
        Self.report($0, matches: request) ? $0 : nil
      }
      if let report {
        model.displayDailyReport(report)
        if [0, 2].contains(result.exitCode) {
          await resolveMissedApprovalIfSatisfied(by: report)
        }
      } else if decodedReport != nil {
        appendMorningLog("Daily report receipt did not match the requested scope.\n", error: true)
      }
      let presentation = DailyReportAutomation.presentation(
        for: result,
        hasMatchingReport: report != nil
      )
      model.setDailyReportRunState(
        isRunning: false,
        message: presentation.message,
        isError: presentation.isError,
        reportID: report?.runID
      )
      if request.trigger == .manual, [0, 2].contains(result.exitCode) {
        model.setDailyReportPresented(true)
      }
      return [0, 2].contains(result.exitCode) ? report : nil
    } catch is CancellationError {
      let message = "Daily report cancelled."
      appendMorningLog("\(message)\n", error: false)
      model.setDailyReportRunState(
        isRunning: false,
        message: message,
        finalPhase: .interrupted
      )
    } catch {
      let message = "Daily report failed to launch: \(error.localizedDescription)"
      appendMorningLog("\(message)\n", error: true)
      model.setDailyReportRunState(isRunning: false, message: message, isError: true)
    }
    return nil
  }

  private func resolveMissedApprovalIfSatisfied(by report: DailyReportDocument) async {
    let enabled = Set(model.config.dailyReport.enabledPlatforms.map(\.rawValue))
    let covered = Set(report.platforms.map { $0.platform.rawValue })
    guard report.comprehensive == true,
      report.reportDate == Self.reportDayFormatter.string(from: Date()),
      enabled.isSubset(of: covered),
      var approval = try? await dailyReportApprovalRepository.load(),
      approval.status == .pending,
      approval.reportDate == report.reportDate
    else { return }
    approval.status = .approved
    do {
      try await dailyReportApprovalRepository.save(approval)
      model.setPendingDailyReportApproval(nil)
      clearDailyReportNotification(for: approval)
    } catch {
      appendMorningLog(
        "Could not resolve the satisfied missed-report approval: \(error.localizedDescription)\n",
        error: true
      )
    }
  }

  private func requestMissedDailyReportApproval(now: Date) async {
    guard model.config.dailyReport.enabled else { return }
    let reportDate = Self.reportDayFormatter.string(from: now)
    if let existing = try? await dailyReportApprovalRepository.load(),
      existing.reportDate == reportDate
    {
      switch existing.status {
      case .approved:
        _ = await runDailyReport(DailyReportRunRequest(
          trigger: .scheduled,
          platforms: model.config.dailyReport.enabledPlatforms,
          comprehensive: true,
          recheck: false
        ))
      case .declined:
        model.setPendingDailyReportApproval(nil)
      case .pending:
        model.setPendingDailyReportApproval(existing)
      }
      return
    }

    let request = DailyReportApprovalRequest(
      reportDate: reportDate,
      requestedAt: ISO8601DateFormatter().string(from: now)
    )
    do {
      try await dailyReportApprovalRepository.save(request)
      model.setPendingDailyReportApproval(request)
      await postMissedDailyReportNotification(request: request)
    } catch {
      appendMorningLog(
        "Could not persist missed-report approval: \(error.localizedDescription)\n",
        error: true
      )
    }
  }

  private func respondToDailyReportApproval(
    shouldRun: Bool,
    expectedApprovalID: UUID? = nil
  ) async {
    guard isModelReady else {
      pendingDailyReportDecision = (shouldRun, expectedApprovalID)
      return
    }
    guard model.config.dailyReport.enabled else {
      disableAutomaticDailyReports()
      return
    }
    guard !isResolvingDailyReportApproval else { return }
    isResolvingDailyReportApproval = true
    defer { isResolvingDailyReportApproval = false }
    var persistedRequest = model.pendingDailyReportApproval
    if persistedRequest == nil {
      persistedRequest = try? await dailyReportApprovalRepository.load()
    }
    guard var request = persistedRequest, request.status == .pending else { return }
    let currentReportDate = Self.reportDayFormatter.string(from: Date())
    guard request.isCurrent(reportDate: currentReportDate) else {
      request.status = .declined
      try? await dailyReportApprovalRepository.save(request)
      model.setPendingDailyReportApproval(nil)
      clearDailyReportNotification(for: request)
      model.setDailyReportRunState(
        isRunning: false,
        message: "That missed-report approval expired because it was for a prior day."
      )
      return
    }
    if let expectedApprovalID, request.id != expectedApprovalID {
      model.setDailyReportRunState(
        isRunning: false,
        message: "That report approval is no longer current."
      )
      return
    }
    request.status = shouldRun ? .approved : .declined
    do {
      try await dailyReportApprovalRepository.save(request)
      model.setPendingDailyReportApproval(nil)
      clearDailyReportNotification(for: request)
      if shouldRun {
        _ = await runDailyReport(DailyReportRunRequest(
          trigger: .scheduled,
          platforms: model.config.dailyReport.enabledPlatforms,
          comprehensive: true,
          recheck: false
        ))
      } else {
        model.setDailyReportRunState(
          isRunning: false,
          message: "Today’s missed report was skipped."
        )
      }
    } catch {
      model.setDailyReportRunState(
        isRunning: false,
        message: "Could not save your report decision: \(error.localizedDescription)"
      )
    }
  }

  private static func lastComprehensiveDailyReport(
    at url: URL,
    covering requiredPlatforms: [DailyReportPlatform]
  ) -> Date? {
    guard let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let value = object["lastComprehensiveReportAt"] as? String,
          let platformValues = object["lastComprehensivePlatforms"] as? [String],
          object["lastComprehensiveStatus"] as? String == "success",
          Set(requiredPlatforms.map(\.rawValue)).isSubset(of: Set(platformValues)) else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func lastGeneratedDailyReport(
    at url: URL,
    covering requiredPlatforms: [DailyReportPlatform]
  ) -> Date? {
    guard let data = try? Data(contentsOf: url),
      let report = try? JSONDecoder().decode(DailyReportDocument.self, from: data),
      report.status.satisfiesDailySchedule,
      report.comprehensive == true,
      report.covers(requiredPlatforms)
    else {
      return nil
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: report.finishedAt)
      ?? ISO8601DateFormatter().date(from: report.finishedAt)
  }

  private static func lastUnsuccessfulComprehensiveAttempt(
    at url: URL,
    covering requiredPlatforms: [DailyReportPlatform]
  ) -> Date? {
    guard let data = try? Data(contentsOf: url),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let value = object["lastComprehensiveAttemptAt"] as? String,
      let status = object["lastComprehensiveAttemptStatus"] as? String,
      status != "success",
      let platformValues = object["lastComprehensiveAttemptPlatforms"] as? [String],
      Set(requiredPlatforms.map(\.rawValue)).isSubset(of: Set(platformValues))
    else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func lastUnsuccessfulGeneratedDailyReport(
    at url: URL,
    covering requiredPlatforms: [DailyReportPlatform]
  ) -> Date? {
    guard let data = try? Data(contentsOf: url),
      let report = try? JSONDecoder().decode(DailyReportDocument.self, from: data),
      !report.status.satisfiesDailySchedule,
      report.comprehensive == true,
      report.covers(requiredPlatforms)
    else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: report.finishedAt)
      ?? ISO8601DateFormatter().date(from: report.finishedAt)
  }

  private static func reportFromRunOutput(
    _ output: String,
    runtime: URL
  ) -> DailyReportDocument? {
    let lines = output.components(separatedBy: .newlines)
    let idPrefix = "REPORT_ID:"
    let datePrefix = "REPORT_DATE:"
    guard let idLine = lines.last(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix(idPrefix)
    }), let dateLine = lines.last(where: {
      $0.trimmingCharacters(in: .whitespaces).hasPrefix(datePrefix)
    }) else {
      return nil
    }
    let runID = idLine.trimmingCharacters(in: .whitespaces)
      .dropFirst(idPrefix.count)
      .trimmingCharacters(in: .whitespaces)
    guard UUID(uuidString: runID) != nil else { return nil }
    let reportDate = dateLine.trimmingCharacters(in: .whitespaces)
      .dropFirst(datePrefix.count)
      .trimmingCharacters(in: .whitespaces)
    guard reportDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    else { return nil }
    let reportURL = runtime
      .appendingPathComponent("reports", isDirectory: true)
      .appendingPathComponent(reportDate, isDirectory: true)
      .appendingPathComponent("\(runID).json")
    guard let data = try? Data(contentsOf: reportURL),
      let report = try? JSONDecoder().decode(DailyReportDocument.self, from: data),
      report.runID == runID,
      report.reportDate == reportDate
    else {
      return nil
    }
    return report
  }

  private static func report(
    _ report: DailyReportDocument,
    matches request: DailyReportRunRequest
  ) -> Bool {
    let expectedPlatforms = Set(request.platforms.map(\.rawValue))
    let actualPlatforms = Set(report.platforms.map { $0.platform.rawValue })
    return report.trigger == request.trigger
      && report.comprehensive == request.comprehensive
      && report.mode == (request.recheck ? .recheck : .unseenOnly)
      && actualPlatforms == expectedPlatforms
  }

  private func appendMorningLog(_ text: String, error: Bool) {
    guard !text.isEmpty else { return }
    let name = error ? "morning.stderr.log" : "morning.stdout.log"
    let url = paths.supportDirectory.appendingPathComponent(name)
    try? FileManager.default.createDirectory(
      at: paths.supportDirectory,
      withIntermediateDirectories: true
    )
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: paths.supportDirectory.path
    )
    if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
      size.intValue >= 1_000_000
    {
      let archiveURL = url.appendingPathExtension("previous")
      try? FileManager.default.removeItem(at: archiveURL)
      try? FileManager.default.moveItem(at: url, to: archiveURL)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: archiveURL.path
      )
    }
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    try? FileManager.default.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: url.path
    )
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
      styleMask: [.titled, .resizable, .miniaturizable, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false)
    panel.title = "Focus Queue"
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
    panel.isExcludedFromWindowsMenu = false
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
    let hostingView = NSHostingView(rootView: FullFramePanelContent {
      QueueView(model: model)
    })
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

  private func setProgramLogWindowVisible(_ visible: Bool) {
    if visible {
      let window = programLogWindow ?? createProgramLogWindow()
      programLogWindow = window
      window.makeKeyAndOrderFront(nil)
    } else {
      programLogWindow?.orderOut(nil)
    }
  }

  private func createProgramLogWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 820, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Focus Queue Program Log"
    window.minSize = NSSize(width: 640, height: 360)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .disallowed
    window.delegate = self
    window.contentView = NSHostingView(rootView: ProgramLogView(store: programLog))
    if !window.setFrameUsingName("ECCFocusQueue.ProgramLog") {
      window.center()
    }
    window.setFrameAutosaveName("ECCFocusQueue.ProgramLog")
    return window
  }

  private func createStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "checklist", accessibilityDescription: "Focus Queue")
    item.button?.toolTip = "Focus Queue"

    let menu = NSMenu()
    let showItem = NSMenuItem(
      title: "Show Focus Queue", action: #selector(showPanel), keyEquivalent: "")
    showItem.target = self
    menu.addItem(showItem)
    let hideItem = NSMenuItem(
      title: "Hide Focus Queue", action: #selector(hidePanel), keyEquivalent: "")
    hideItem.target = self
    menu.addItem(hideItem)
    let exitFocusItem = NSMenuItem(
      title: "Exit Terminal Focus", action: #selector(exitTerminalFocus), keyEquivalent: "")
    exitFocusItem.target = self
    exitFocusItem.isHidden = true
    menu.addItem(exitFocusItem)
    exitTerminalFocusItem = exitFocusItem
    let restartItem = NSMenuItem(
      title: "Restart Focus Queue", action: #selector(restartApplication), keyEquivalent: "")
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
      title: "Quit Focus Queue", action: #selector(quitApplication), keyEquivalent: "q")
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
    if model.isPanelCollapsed {
      currentPlacement = placement
      let frame = CollapsedQueueGeometry.frame(
        visibleFrame: targetScreen.visibleFrame, placement: placement)
      isApplyingPanelFrame = true
      panel.setFrame(frame, display: true, animate: animated)
      isApplyingPanelFrame = false
      if persist { preferredDisplayIdentifier = displayIdentifier(for: targetScreen) }
      scheduleFocusChromeRefresh()
      return
    }
    if model.isTopTaskOnly {
      currentPlacement = placement
      let frame = TopTaskQueueGeometry.frame(
        preferredWidth: compactPanelWidth,
        visibleFrame: targetScreen.visibleFrame,
        placement: placement
      )
      isApplyingPanelFrame = true
      panel.setFrame(frame, display: true, animate: animated)
      isApplyingPanelFrame = false
      if persist { preferredDisplayIdentifier = displayIdentifier(for: targetScreen) }
      scheduleFocusChromeRefresh()
      return
    }
    let minimumWidth = inspectorLayout.minimumWidth
    let clampedMinimumWidth = min(
      minimumWidth,
      max(0, targetScreen.visibleFrame.width - 24)
    )
    panel.minSize = NSSize(
      width: clampedMinimumWidth,
      height: 500
    )
    let frame = DisplayGeometry.panelFrame(
      preferredWidth: panel.frame.width,
      visibleFrame: targetScreen.visibleFrame,
      placement: placement,
      topMargin: 4,
      minimumWidth: minimumWidth,
      maximumWidth: inspectorLayout.maximumWidth
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

  private func setPanelMode(_ mode: QueuePanelMode) {
    guard let panel else { return }
    let previousMode = appliedPanelMode
    isApplyingPanelFrame = true
    if previousMode == .expanded, mode != .expanded {
      expandedPanelFrame = panel.frame
    }
    if mode == .collapsed {
      panel.styleMask.remove([.titled, .resizable, .fullSizeContentView])
      panel.minSize = CollapsedQueueGeometry.size
      panel.maxSize = CollapsedQueueGeometry.size
      panel.setFrame(
        CollapsedQueueGeometry.frame(
          visibleFrame: currentPanelScreen().visibleFrame, placement: currentPlacement),
        display: true, animate: true)
    } else if mode == .topTask {
      let size = TopTaskQueueGeometry.size(preferredWidth: compactPanelWidth)
      panel.styleMask.remove([.titled, .resizable, .fullSizeContentView])
      panel.minSize = size
      panel.maxSize = size
      panel.setFrame(
        TopTaskQueueGeometry.frame(
          preferredWidth: compactPanelWidth,
          visibleFrame: currentPanelScreen().visibleFrame,
          placement: currentPlacement
        ),
        display: true,
        animate: true
      )
    } else {
      panel.styleMask.insert([.titled, .resizable, .fullSizeContentView])
      panel.titleVisibility = .hidden
      panel.titlebarAppearsTransparent = true
      panel.standardWindowButton(.closeButton)?.isHidden = true
      panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
      panel.standardWindowButton(.zoomButton)?.isHidden = true
      panel.minSize = NSSize(width: inspectorLayout.minimumWidth, height: 500)
      panel.maxSize = NSSize(width: inspectorLayout.maximumWidth, height: 10_000)
      if let expandedPanelFrame { panel.setFrame(expandedPanelFrame, display: false) }
      self.expandedPanelFrame = nil
    }
    appliedPanelMode = mode
    isApplyingPanelFrame = false
    if mode == .expanded { positionPanelOnCurrentDisplay(currentPlacement, animated: true) }
    scheduleFocusChromeRefresh()
  }

  private var inspectorLayout: QueueInspectorLayout {
    if model.presentedPlanTicketID != nil || model.isDocumentViewerPresented { return .plan }
    if model.isQueueChatInspectorPresented { return .chat }
    if model.isTokenAnalyticsPresented { return .analytics }
    return model.isDailyReportPresented || model.presentedAgentUpdate != nil ? .report : .closed
  }

  private func setDailyReportVisible(_ visible: Bool) {
    guard let panel else { return }
    if visible, model.panelMode != .expanded {
      model.setPanelMode(.expanded)
    }
    let screen = currentPanelScreen()
    let layout = inspectorLayout
    let minimumWidth = layout.minimumWidth
    let clampedMinimumWidth = min(minimumWidth, max(0, screen.visibleFrame.width - 24))
    panel.minSize = NSSize(width: clampedMinimumWidth, height: 500)
    let preferredWidth = layout.preferredWidth(compactWidth: compactPanelWidth)
    panel.maxSize = NSSize(width: layout.maximumWidth, height: 10_000)
    let frame = DisplayGeometry.panelFrame(
      preferredWidth: preferredWidth,
      visibleFrame: screen.visibleFrame,
      placement: currentPlacement,
      topMargin: 4,
      minimumWidth: minimumWidth,
      maximumWidth: layout.maximumWidth
    )
    isApplyingPanelFrame = true
    panel.setFrame(frame, display: true, animate: true)
    isApplyingPanelFrame = false
    scheduleFocusChromeRefresh()
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
    guard !isApplyingPanelFrame, model.panelMode == .expanded, let panel else { return }
    let frame = panel.frame
    if preferredDisplayIdentifier == nil {
      preferredDisplayIdentifier = displayIdentifier(for: panel.screen)
    }
    model.saveWindow(
      WindowSnapshot(
        x: frame.origin.x, y: frame.origin.y,
        width: model.isInspectorPresented ? compactPanelWidth : frame.width,
        height: frame.height,
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

  private func configureDailyReportNotifications() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    let run = UNNotificationAction(
      identifier: Self.runMissedReportAction,
      title: "Run report",
      options: [.foreground]
    )
    let skip = UNNotificationAction(
      identifier: Self.skipMissedReportAction,
      title: "Not today",
      options: []
    )
    center.setNotificationCategories([
      UNNotificationCategory(
        identifier: Self.missedReportCategory,
        actions: [run, skip],
        intentIdentifiers: [],
        options: []
      )
    ])
    if FileManager.default.fileExists(atPath: paths.ingestionConfigurationFile.path) {
      Task { _ = try? await center.requestAuthorization(options: [.alert, .sound]) }
    }
  }

  private func postMissedDailyReportNotification(
    request: DailyReportApprovalRequest
  ) async {
    let content = UNMutableNotificationContent()
    content.title = "Daily report was missed"
    content.body = "Your Mac was unavailable at the scheduled time. Run today’s report now?"
    content.sound = .default
    content.categoryIdentifier = Self.missedReportCategory
    content.userInfo = ["approvalID": request.id.uuidString]
    let notification = UNNotificationRequest(
      identifier: "daily-report-\(request.reportDate)",
      content: content,
      trigger: nil
    )
    try? await UNUserNotificationCenter.current().add(notification)
  }

  private func clearDailyReportNotification(for request: DailyReportApprovalRequest) {
    let identifier = "daily-report-\(request.reportDate)"
    let center = UNUserNotificationCenter.current()
    center.removeDeliveredNotifications(withIdentifiers: [identifier])
    center.removePendingNotificationRequests(withIdentifiers: [identifier])
  }

  private func disableAutomaticDailyReports() {
    pendingDailyReportDecision = nil
    model.setPendingDailyReportApproval(nil)
    let center = UNUserNotificationCenter.current()
    center.removeAllDeliveredNotifications()
    center.removeAllPendingNotificationRequests()
    Task { [dailyReportApprovalRepository] in
      guard var request = try? await dailyReportApprovalRepository.load(),
        request.status == .pending
      else { return }
      request.status = .declined
      try? await dailyReportApprovalRepository.save(request)
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let shouldRun: Bool?
    switch response.actionIdentifier {
    case Self.runMissedReportAction:
      shouldRun = true
    case Self.skipMissedReportAction:
      shouldRun = false
    default:
      shouldRun = nil
    }
    let approvalID = (response.notification.request.content.userInfo["approvalID"] as? String)
      .flatMap(UUID.init(uuidString:))
    completionHandler()
    Task { @MainActor [weak self] in
      if let shouldRun, let approvalID {
        await self?.respondToDailyReportApproval(
          shouldRun: shouldRun,
          expectedApprovalID: approvalID
        )
      } else {
        self?.showPanel()
      }
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  private static let missedReportCategory = "ECC_DAILY_REPORT_MISSED"
  private static let runMissedReportAction = "ECC_DAILY_REPORT_RUN"
  private static let skipMissedReportAction = "ECC_DAILY_REPORT_SKIP"
  private static let reportDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = .current
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

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

struct FullFramePanelContent<Content: View>: View {
  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content.ignoresSafeArea(.container, edges: .top)
  }
}
