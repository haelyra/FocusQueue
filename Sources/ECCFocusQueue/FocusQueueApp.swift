import AppKit
import Darwin
import FocusQueueCore
import SwiftUI
import UserNotifications

@main struct FocusQueueApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
  UNUserNotificationCenterDelegate
{
  private let paths = AppPaths.live()
  private lazy var model = QueueViewModel(paths: paths)
  private lazy var dailyReportApprovalRepository = JSONDailyReportApprovalRepository(
    url: paths.dailyReportApprovalFile
  )
  private var panel: FocusPanel?
  private var statusItem: NSStatusItem?
  private var exitTerminalFocusItem: NSMenuItem?
  private var terminalFocusController: TerminalFocusModeController?
  private var focusChromeRefreshTask: Task<Void, Never>?
  private var screenReconciliationTask: Task<Void, Never>?
  private var morningReconciliationTask: Task<Void, Never>?
  private var lastMorningAttempt: Date?
  private var lastFailedDailyReportAttempt: Date?
  private let morningRunner = FoundationProcessRunner()
  private var isDailyReportProcessRunning = false
  private var expandedPanelFrame: NSRect?
  private var compactPanelWidth: CGFloat = 440
  private var currentPlacement: QueueWindowPlacement = .upperRight
  private var preferredDisplayIdentifier: String?
  private var isApplyingPanelFrame = false
  private var isModelReady = false
  private var pendingDailyReportDecision: (shouldRun: Bool, approvalID: UUID?)?
  private var isResolvingDailyReportApproval = false
  private var availabilityResumedAt = Date()

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
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
    model.minimizeHandler = { [weak self] in self?.panel?.miniaturize(nil) }
    model.reportVisibilityHandler = { [weak self] visible in
      self?.setDailyReportVisible(visible)
    }
    model.dailyReportRunHandler = { [weak self] request in
      await self?.runDailyReport(request)
    }
    model.dailyReportApprovalHandler = { [weak self] shouldRun in
      await self?.respondToDailyReportApproval(shouldRun: shouldRun)
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
    model.quitHandler = { NSApplication.shared.terminate(nil) }
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
    positionPanel(.upperRight, on: defaultScreen(), animated: false, persist: false)
    panel?.orderFrontRegardless()

    Task { [weak self] in
      guard let self else { return }
      await model.bootstrap()
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

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  func applicationWillTerminate(_ notification: Notification) {
    morningReconciliationTask?.cancel()
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
  }

  func windowDidResize(_ notification: Notification) {
    if !isApplyingPanelFrame, !model.isPanelCollapsed, !model.isInspectorPresented, let panel {
      compactPanelWidth = min(max(panel.frame.width, 400), 620)
    }
    saveWindowFrame()
    scheduleFocusChromeRefresh()
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
    model.setDailyReportRunState(isRunning: true, message: "Checking new messages…")
    guard await model.persistDailyReportConfiguration() else {
      model.setDailyReportRunState(
        isRunning: false,
        message: "Daily report settings could not be saved before the run.",
        isError: true
      )
      isDailyReportProcessRunning = false
      return nil
    }
    do {
      let result = try await morningRunner.run(ProcessSpecification(
        executable: "/usr/bin/python3",
        arguments: DailyReportAutomation.arguments(
          scriptPath: script.path,
          configurationPath: paths.ingestionConfigurationFile.path,
          runtimePath: paths.ingestionRuntimeDirectory.path,
          request: request
        ),
        workingDirectory: model.config.workspacePath,
        environment: [
          "PATH": [
            "/Users/hira/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
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
      isDailyReportProcessRunning = false
      return [0, 2].contains(result.exitCode) ? report : nil
    } catch {
      let message = "Daily report failed to launch: \(error.localizedDescription)"
      appendMorningLog("\(message)\n", error: true)
      model.setDailyReportRunState(isRunning: false, message: message, isError: true)
    }
    isDailyReportProcessRunning = false
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
    panel.title = "ECC Focus Queue"
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

  private func setPanelCollapsed(_ collapsed: Bool) {
    guard let panel else { return }
    isApplyingPanelFrame = true
    if collapsed {
      expandedPanelFrame = panel.frame
      panel.styleMask.remove([.titled, .resizable, .fullSizeContentView])
      panel.minSize = CollapsedQueueGeometry.size
      panel.maxSize = CollapsedQueueGeometry.size
      panel.setFrame(
        CollapsedQueueGeometry.frame(
          visibleFrame: currentPanelScreen().visibleFrame, placement: currentPlacement),
        display: true, animate: true)
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
    isApplyingPanelFrame = false
    if !collapsed { positionPanelOnCurrentDisplay(currentPlacement, animated: true) }
    scheduleFocusChromeRefresh()
  }

  private var inspectorLayout: QueueInspectorLayout {
    if model.presentedPlanTicketID != nil { return .plan }
    if model.isQueueChatInspectorPresented { return .chat }
    return model.isDailyReportPresented || model.presentedAgentUpdate != nil ? .report : .closed
  }

  private func setDailyReportVisible(_ visible: Bool) {
    guard let panel else { return }
    if visible, model.isPanelCollapsed {
      model.setPanelCollapsed(false)
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
    guard !isApplyingPanelFrame, !model.isPanelCollapsed, let panel else { return }
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
