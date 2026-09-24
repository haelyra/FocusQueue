import Darwin
import Foundation

/// Coordinates the app and resize-hook helper without blocking an executor thread.
struct TmuxOrganizerLock {
  let descriptor: Int32

  static func acquire(name: String, root: URL? = nil) async throws -> Self {
    try TmuxController.validateName(name)
    let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(
      "focus-queue-tmux-\(geteuid())", isDirectory: true)
    let fd = try withSecureTmuxTemporaryDirectory(at: root, purpose: "task layout lock") { directory in
      let leaf = "\(name).lock"
      var descriptor = Darwin.openat(directory, leaf,
        O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
      if descriptor < 0, errno == EEXIST {
        descriptor = Darwin.openat(directory, leaf, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else {
        throw TmuxError.unavailable(
          "Could not open the task layout lock securely: \(String(cString: strerror(errno))).")
      }
      do { try validateSecureTmuxFile(descriptor, purpose: "task layout lock") }
      catch { Darwin.close(descriptor); throw error }
      return descriptor
    }
    for _ in 0..<400 {
      if flock(fd, LOCK_EX | LOCK_NB) == 0 { return Self(descriptor: fd) }
      do { try await Task.sleep(for: .milliseconds(25)) }
      catch { Darwin.close(fd); throw error }
    }
    Darwin.close(fd)
    throw TmuxError.unavailable("The task layout is busy. Retry in a moment.")
  }

  func release() { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

private func withSecureTmuxTemporaryDirectory<T>(
  at root: URL, purpose: String, _ body: (Int32) throws -> T
) throws -> T {
  if Darwin.mkdir(root.path, mode_t(0o700)) != 0, errno != EEXIST {
    throw TmuxError.unavailable("Could not create the \(purpose) directory securely.")
  }
  let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
  guard descriptor >= 0 else {
    throw TmuxError.unavailable("Could not open the \(purpose) directory securely.")
  }
  defer { Darwin.close(descriptor) }
  var metadata = stat()
  guard Darwin.fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFDIR,
        metadata.st_uid == Darwin.geteuid(),
        metadata.st_mode & mode_t(0o777) == mode_t(0o700) else {
    throw TmuxError.unavailable("The \(purpose) directory has unsafe ownership, type, or permissions.")
  }
  return try body(descriptor)
}

@discardableResult
private func validateSecureTmuxFile(_ descriptor: Int32, purpose: String) throws -> stat {
  var metadata = stat()
  guard Darwin.fstat(descriptor, &metadata) == 0,
        metadata.st_mode & S_IFMT == S_IFREG,
        metadata.st_uid == Darwin.geteuid(),
        metadata.st_mode & mode_t(0o777) == mode_t(0o600),
        metadata.st_nlink == 1 else {
    throw TmuxError.unavailable("The \(purpose) file has unsafe ownership, type, permissions, or links.")
  }
  return metadata
}

public struct TmuxPaneSnapshot: Identifiable, Equatable, Sendable {
  public var id: String { reference.paneID }
  public let reference: TmuxSessionReference
  public let windowID: String
  public let windowIndex: Int
  public let windowWidth: Int
  public let windowHeight: Int
  public let left: Int
  public let top: Int
  public let width: Int
  public let height: Int
  public let subtaskID: String
  public let restoredSubtaskID: String
  public let isActive: Bool
  public let automatic: Bool

  static let format = TmuxController.format + "|#{window_id}|#{window_index}|#{window_width}|#{window_height}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{@focus-queue-agent}|#{@focus-queue-restored-agent}|#{pane_active}|#{@focus-queue-layout}"

  static func decode(_ output: String, executable: String) throws -> [Self] {
    try output.split(separator: "\n").map { line in
      let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard f.count == 19, f[7].range(of: "^@[0-9]+$", options: .regularExpression) != nil,
            let index = Int(f[8]), let ww = Int(f[9]), let wh = Int(f[10]),
            let x = Int(f[11]), let y = Int(f[12]), let w = Int(f[13]), let h = Int(f[14]),
            ww > 0, wh > 0, w > 0, h > 0,
            let reference = try TmuxController.decode(f.prefix(7).joined(separator: "|"), executable: executable).first else {
        throw TmuxError.unavailable("The pane layout changed while reading it. Refresh to retry.")
      }
      return Self(reference: reference, windowID: f[7], windowIndex: index,
        windowWidth: ww, windowHeight: wh, left: x, top: y, width: w, height: h,
        subtaskID: f[15], restoredSubtaskID: f[16], isActive: f[17] == "1",
        automatic: f[18] != "manual")
    }
  }
}

/// Terminal cells account for the user's font, zoom and actual window size.
public enum TmuxPaneLayout {
  public static let maximumPanes = 4

  public static func contentHeight(clientHeight: Int, status: String, controlMode: Bool) -> Int {
    // tmux control clients have no status display. Their dimensions already
    // describe the available pane area (status_line_size in upstream tmux).
    let rows = controlMode || status == "off" ? 0 : max(0, Int(status) ?? 1)
    return max(1, clientHeight - rows)
  }

  public static func capacity(width: Int, height: Int) -> Int {
    width > 0 && height > 0 ? maximumPanes : 0
  }

  public static func groups<T>(_ panes: [T], width: Int, height: Int) -> [[T]] {
    let count = max(1, capacity(width: width, height: height))
    return stride(from: 0, to: panes.count, by: count).map { Array(panes[$0..<min($0 + count, panes.count)]) }
  }

  /// Produces tmux's checksummed layout tree. Every cell is used, including split borders.
  public static func layout(paneIDs: [String], width: Int, height: Int) throws -> String {
    guard !paneIDs.isEmpty, paneIDs.count <= capacity(width: width, height: height),
      paneIDs.allSatisfy({ $0.range(of: "^%[0-9]+$", options: .regularExpression) != nil }),
      width > 0, height > 0 else { throw TmuxError.unavailable("The panes do not fit this window.") }
    let columns: Int
    switch paneIDs.count {
    case 1: columns = 1
    case 2: columns = width >= height * 2 ? 2 : 1
    default: columns = 2
    }
    let rows = (paneIDs.count + columns - 1) / columns
    guard width >= columns * 2 - 1, height >= rows * 2 - 1 else {
      throw TmuxError.unavailable("The panes do not fit this window.")
    }
    var offset = 0
    var y = 0
    var rowLayouts: [String] = []
    for row in 0..<rows {
      let count = min(columns, paneIDs.count - offset)
      let rowHeight = (height - rows + 1) / rows + (row < (height - rows + 1) % rows ? 1 : 0)
      var x = 0
      var cells: [String] = []
      for column in 0..<count {
        let cellWidth = (width - count + 1) / count + (column < (width - count + 1) % count ? 1 : 0)
        cells.append("\(cellWidth)x\(rowHeight),\(x),\(y),\(paneIDs[offset].dropFirst())")
        x += cellWidth + 1
        offset += 1
      }
      rowLayouts.append(count == 1 ? cells[0] : "\(width)x\(rowHeight),0,\(y){\(cells.joined(separator: ","))}")
      y += rowHeight + 1
    }
    let body = rows == 1 ? rowLayouts[0] : "\(width)x\(height),0,0[\(rowLayouts.joined(separator: ","))]"
    var checksum: UInt16 = 0
    for byte in body.utf8 { checksum = (checksum >> 1) | (checksum << 15); checksum = checksum &+ UInt16(byte) }
    return String(format: "%04x", checksum) + "," + body
  }
}

extension TmuxController {
  public static func taskSessionName(taskID: String) throws -> String {
    try validateName(taskID)
    let name = "fq-task-" + taskID.lowercased()
    try validateName(name)
    return name
  }

  public static func ownsSession(name: String, taskID: String, subtaskID: String) -> Bool {
    name == (try? taskSessionName(taskID: taskID)) || name == (try? sessionName(subtaskID: subtaskID))
  }

  public func panes(name: String? = nil, executable: String) async throws -> [TmuxPaneSnapshot] {
    if let name { try Self.validateName(name) }
    let arguments = ["list-panes"] + (name.map { ["-s", "-t", "=\($0):"] } ?? ["-a"])
      + ["-F", TmuxPaneSnapshot.format]
    let result = try await run(executable, arguments)
    if !result.succeeded {
      if !result.timedOut && ["no server running", "No such file or directory", "can't find session",
        "no sessions", "no current target"].contains(where: result.standardError.contains) { return [] }
      throw TmuxError.unavailable(String(result.standardError.prefix(800)))
    }
    // A retained dead pane should not hide the other running agents.
    let live = result.standardOutput.split(separator: "\n").filter {
      let fields = $0.split(separator: "|", omittingEmptySubsequences: false)
      return fields.count != 19 || fields[6] == "0"
    }.joined(separator: "\n")
    return try TmuxPaneSnapshot.decode(live, executable: executable)
  }

  public func inspectAgent(taskID: String, subtaskID: String, executable: String) async throws -> TmuxSessionReference {
    let name = try Self.taskSessionName(taskID: taskID)
    if try await taskSessionExists(name: name, executable: executable) {
      try await requireTaskSessionOwnership(name: name, taskID: taskID, executable: executable)
    }
    let all = try await panes(name: name, executable: executable)
    let matches = all.filter { $0.subtaskID == subtaskID }
    guard matches.count <= 1 else { throw TmuxError.unavailable("More than one pane claims this agent. Check the task panes before retrying.") }
    if let match = matches.first { return match.reference }
    if let pending = try pendingLaunch(taskID: taskID, subtaskID: subtaskID), !all.isEmpty {
      let result = try await run(executable, ["list-panes", "-s", "-t", "=\(name):", "-f",
        "#{==:#{window_name},\(pending)}", "-F", Self.format])
      guard result.succeeded else { throw TmuxError.unavailable("The previous launch is still unconfirmed. Refresh the task before retrying.") }
      if !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
         let recovered = try Self.decode(result.standardOutput, executable: executable).onlyElement {
        try await checked(executable, ["set-option", "-p", "-t", recovered.paneID, "@focus-queue-agent", subtaskID])
        return recovered
      }
      throw TmuxError.unavailable("The previous launch has an unresolved pane. Check the task session before starting another agent.")
    }
    // Existing per-agent sessions remain recallable during migration.
    return try await inspect(name: Self.sessionName(subtaskID: subtaskID), executable: executable)
  }

  /// Verifies the complete pane process identity and its exact task ownership
  /// immediately before an interactive client attaches.
  public func verifyAgent(
    _ saved: TmuxSessionReference, taskID: String, subtaskID: String, executable: String
  ) async throws -> TmuxSessionReference {
    let name = try Self.taskSessionName(taskID: taskID)
    try Self.validateName(subtaskID)
    guard saved.name == name, saved.executable == executable else { throw TmuxError.changed }
    try await requireTaskSessionOwnership(name: name, taskID: taskID, executable: executable)
    let matches = try await panes(name: name, executable: executable).filter {
      $0.subtaskID == subtaskID && $0.reference == saved
    }
    guard matches.count == 1 else { throw TmuxError.changed }
    return try await verify(saved)
  }

  public func startAgent(taskID: String, subtaskID: String, directory: String,
                         command: [String], executable: String) async throws -> TmuxSessionReference {
    let name = try Self.taskSessionName(taskID: taskID)
    try Self.validateName(subtaskID)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ProcessRunnerError.invalidWorkingDirectory(directory)
    }
    let lock = try await TmuxOrganizerLock.acquire(name: name)
    defer { lock.release() }
    try await configureManagedScrollback(executable: executable)
    let sessionExists = try await taskSessionExists(name: name, executable: executable)
    if sessionExists {
      try await requireTaskSessionOwnership(name: name, taskID: taskID, executable: executable)
    }
    let existing = try await panes(name: name, executable: executable)
    guard !existing.contains(where: { $0.subtaskID == subtaskID }) else {
      throw TmuxError.unavailable("This agent already has a pane. Open it from the task to continue.")
    }
    guard existing.count < TmuxPaneLayout.maximumPanes else {
      throw TmuxError.unavailable(
        "This task already has four agent panes. Complete or remove one before starting another.")
    }
    let restored = existing.filter { $0.restoredSubtaskID == subtaskID }
    guard restored.count <= 1 else {
      throw TmuxError.unavailable("More than one restored pane claims this agent. Resolve the task layout before retrying.")
    }
    if try pendingLaunch(taskID: taskID, subtaskID: subtaskID) != nil,
       !existing.isEmpty, restored.count != 1 {
      throw TmuxError.unavailable("A previous launch needs to be recalled from its task before retrying.")
    }
    let launchWindow = "fq-launch-" + UUID().uuidString.lowercased()
    try writeLaunchReceipt(launchWindow, taskID: taskID, subtaskID: subtaskID)
    let managedCommand = [
      "/usr/bin/env", "FOCUS_QUEUE_MANAGED_TMUX=1",
      "FOCUS_QUEUE_TASK_ID=\(taskID.uppercased())",
      "FOCUS_QUEUE_SUBTASK_ID=\(subtaskID)",
      "FOCUS_QUEUE_RUNTIME_MODE=tmux",
      "FOCUS_QUEUE_TMUX_SERVER=\(serverName)",
    ] + command
    let base = try Self.startArguments(name: name, directory: directory, command: managedCommand)
    let arguments: [String]
    if existing.isEmpty {
      arguments = Array(base.prefix(1)) + ["-n", launchWindow] + base.dropFirst()
    } else {
      let commandStart = try base.firstIndex(of: "--").unwrapTmux()
      arguments = ["new-window", "-d", "-P", "-F", Self.format, "-t", "=\(name):", "-n", launchWindow,
        "-c", directory.replacingOccurrences(of: "#", with: "##")] + base[commandStart...]
    }
    let result = try await run(executable, arguments)
    guard result.succeeded else {
      if result.timedOut {
        throw TmuxError.startedButUnconfirmed(
          name: name, executable: executable, attempts: 1,
          lastDetail: "The tmux launch command timed out; inspect the reserved session before retrying.")
      }
      throw TmuxError.unavailable(String(result.standardError.prefix(800)))
    }
    let fields = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: result.standardOutput.contains("|") ? "|" : "\t", omittingEmptySubsequences: false)
    guard fields.count == 7, fields[3].range(of: "^%[0-9]+$", options: .regularExpression) != nil else {
      throw TmuxError.startedButUnconfirmed(name: name, executable: executable, attempts: 1, lastDetail: "No pane ID in the launch receipt.")
    }
    let paneID = String(fields[3])
    // Claim the reserved session before tagging its first pane. If the pane
    // update response is lost, recovery can still prove task ownership.
    do {
      try await checked(executable, ["set-option", "-t", name, "@focus-queue-task", taskID.uppercased()])
    } catch {
      throw TmuxError.startedButUnconfirmed(name: name, executable: executable, attempts: 1,
        lastDetail: "The launch receipt is retained, but task ownership was not confirmed. \(error.localizedDescription)")
    }
    do {
      try await checked(executable, ["set-option", "-p", "-t", paneID, "@focus-queue-agent", subtaskID])
      try await checked(executable, ["set-option", "-p", "-u", "-t", paneID, "@focus-queue-restored-agent"])
      try await checked(executable, ["set-option", "-p", "-u", "-t", paneID, "@focus-queue-restored"])
    } catch {
      throw TmuxError.startedButUnconfirmed(name: name, executable: executable, attempts: 1,
        lastDetail: "The launch receipt is retained. Open this task to recover pane \(paneID). \(error.localizedDescription)")
    }
    try await checked(executable, ["set-option", "-t", name, "mouse", "on"])
    try await checked(executable, ["set-window-option", "-t", paneID, "window-size", "latest"])
    var previous: TmuxSessionReference?
    var stable = 0
    var detail = "The pane process kept changing."
    for _ in 0..<120 {
      do {
        let current = try await inspectTarget(paneID, name: name, executable: executable)
        stable = current == previous ? stable + 1 : 1
        previous = current
        if stable >= 3 {
          try? removeLaunchReceipt(taskID: taskID, subtaskID: subtaskID)
          // A restored shell may have been repurposed by the user after
          // restore. Never kill or respawn it. Once the provider is confirmed
          // in a fresh pane, retire only its assignment marker.
          if let placeholder = restored.first {
            try? await checked(executable, ["set-option", "-p", "-u", "-t",
              placeholder.id, "@focus-queue-restored-agent"])
          }
          // Layout failures never turn a successful process launch into a retryable launch.
          try? await reflowUnlocked(name: name, executable: executable, force: false)
          return current
        }
      } catch {
        stable = 0; previous = nil; detail = error.localizedDescription
      }
      try await Task.sleep(for: .milliseconds(250))
    }
    throw TmuxError.startedButUnconfirmed(name: name, executable: executable, attempts: 120, lastDetail: detail)
  }

  private func taskSessionExists(name: String, executable: String) async throws -> Bool {
    let result = try await run(executable, ["has-session", "-t", "=\(name)"])
    if result.succeeded { return true }
    if !result.timedOut,
       ["no server running", "No such file or directory", "can't find session", "no sessions",
        "no current target"]
        .contains(where: result.standardError.contains) { return false }
    throw TmuxError.unavailable("Could not verify ownership of the task session.")
  }

  private func requireTaskSessionOwnership(
    name: String, taskID: String, executable: String
  ) async throws {
    let result = try await run(executable, [
      "show-options", "-qv", "-t", "=\(name):", "@focus-queue-task",
    ])
    let owner = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.succeeded, owner == taskID.uppercased() else {
      throw TmuxError.unavailable(
        "The reserved task session already exists without matching Focus Queue ownership.")
    }
  }

  private func launchReceiptRoot() throws -> URL {
    try Self.validateName(serverName)
    return FileManager.default.temporaryDirectory.appendingPathComponent(
      "focus-queue-launches-\(serverName)", isDirectory: true)
  }

  private func launchReceiptLeaf(taskID: String, subtaskID: String) throws -> String {
    try Self.validateName(serverName); try Self.validateName(taskID); try Self.validateName(subtaskID)
    return "\(taskID.lowercased())-\(subtaskID).receipt"
  }

  private func writeLaunchReceipt(_ value: String, taskID: String, subtaskID: String) throws {
    let root = try launchReceiptRoot()
    let leaf = try launchReceiptLeaf(taskID: taskID, subtaskID: subtaskID)
    try withSecureTmuxTemporaryDirectory(at: root, purpose: "launch receipt") { directory in
      var descriptor = Darwin.openat(directory, leaf,
        O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
      if descriptor < 0, errno == EEXIST {
        descriptor = Darwin.openat(directory, leaf, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
      }
      guard descriptor >= 0 else {
        throw TmuxError.unavailable("Could not open the launch receipt securely.")
      }
      defer { Darwin.close(descriptor) }
      try validateSecureTmuxFile(descriptor, purpose: "launch receipt")
      guard Darwin.ftruncate(descriptor, 0) == 0 else {
        throw TmuxError.unavailable("Could not reset the launch receipt securely.")
      }
      let data = Data(value.utf8)
      try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
          let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else {
            throw TmuxError.unavailable("Could not write the launch receipt securely.")
          }
          offset += count
        }
      }
    }
  }

  private func pendingLaunch(taskID: String, subtaskID: String) throws -> String? {
    let root = try launchReceiptRoot()
    let leaf = try launchReceiptLeaf(taskID: taskID, subtaskID: subtaskID)
    return try withSecureTmuxTemporaryDirectory(at: root, purpose: "launch receipt") { directory in
      let descriptor = Darwin.openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      if descriptor < 0, errno == ENOENT { return nil }
      guard descriptor >= 0 else {
        throw TmuxError.unavailable("Could not read the launch receipt securely.")
      }
      defer { Darwin.close(descriptor) }
      let metadata = try validateSecureTmuxFile(descriptor, purpose: "launch receipt")
      guard metadata.st_size > 0, metadata.st_size <= 256 else {
        throw TmuxError.unavailable("The launch receipt has an invalid size.")
      }
      var data = Data(count: Int(metadata.st_size))
      let count = data.withUnsafeMutableBytes { raw in
        Darwin.read(descriptor, raw.baseAddress, raw.count)
      }
      guard count == data.count, let value = String(data: data, encoding: .utf8) else {
        throw TmuxError.unavailable("Could not decode the launch receipt securely.")
      }
      try Self.validateName(value)
      return value
    }
  }

  private func removeLaunchReceipt(taskID: String, subtaskID: String) throws {
    let root = try launchReceiptRoot()
    let leaf = try launchReceiptLeaf(taskID: taskID, subtaskID: subtaskID)
    try withSecureTmuxTemporaryDirectory(at: root, purpose: "launch receipt") { directory in
      let descriptor = Darwin.openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
      if descriptor < 0, errno == ENOENT { return }
      guard descriptor >= 0 else {
        throw TmuxError.unavailable("Could not remove the launch receipt securely.")
      }
      defer { Darwin.close(descriptor) }
      try validateSecureTmuxFile(descriptor, purpose: "launch receipt")
      guard Darwin.unlinkat(directory, leaf, 0) == 0 else {
        throw TmuxError.unavailable("Could not remove the launch receipt securely.")
      }
    }
  }

  func checked(_ executable: String, _ arguments: [String]) async throws {
    let result = try await run(executable, arguments)
    guard result.succeeded else { throw TmuxError.unavailable(String(result.standardError.prefix(800))) }
  }

  public func select(_ saved: TmuxSessionReference) async throws {
    _ = try await verify(saved)
    try await checked(saved.executable, ["select-window", "-t", saved.paneID])
    try await checked(saved.executable, ["select-pane", "-t", saved.paneID])
  }

  public func configureTask(name: String, executable: String, helper: String,
                            supportDirectory: URL) async throws {
    try Self.validateName(name)
    guard name.hasPrefix("fq-task-"), FileManager.default.isExecutableFile(atPath: helper) else { return }
    let shellQuote: (String) -> String = { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let command = ["/usr/bin/env", "FOCUS_QUEUE_SUPPORT_DIR=\(supportDirectory.path)", helper, "tmux", "reflow", name, "--server", serverName]
      .map(shellQuote).joined(separator: " ")
    let formattedCommand = shellQuote(command).replacingOccurrences(of: "#", with: "##")
    for hook in ["client-attached", "client-resized", "client-session-changed"] {
      try await checked(executable, ["set-hook", "-t", name, "\(hook)[35]", "run-shell -b \(formattedCommand)"])
    }
    // A deliberate border resize opts out of the next automatic rearrangement.
    try await checked(executable, ["set-hook", "-t", name, "after-resize-pane[35]",
      "set-option -t \(name) @focus-queue-layout manual"])
  }

  public func label(_ saved: TmuxSessionReference, title: String) async throws {
    _ = try await verify(saved)
    let readable = String(title.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(100))
    try await checked(saved.executable, ["set-option", "-p", "-t", saved.paneID, "@focus-queue-label", readable])
    // Keep tmux presentation plain while retaining internal labels for the app.
    // The managed usage adapter owns its rows, and tmux's native window list
    // remains the only other status-line content.
    try await resetPlainPresentation(
      name: saved.name, paneID: saved.paneID, executable: saved.executable)
  }

  public func setAutomatic(name: String, executable: String, enabled: Bool) async throws {
    try Self.validateName(name)
    guard name.hasPrefix("fq-task-") else { throw TmuxError.unavailable("Automatic layouts are available for task sessions.") }
    try await checked(executable, ["set-option", "-t", name, "@focus-queue-layout", enabled ? "auto" : "manual"])
    if enabled { try await reflow(name: name, executable: executable, force: true) }
  }

  public func swap(_ source: TmuxSessionReference, with target: TmuxSessionReference) async throws {
    guard source.name == target.name, source.executable == target.executable,
      source.serverPID == target.serverPID, source.paneID != target.paneID else { throw TmuxError.changed }
    let lock = try await TmuxOrganizerLock.acquire(name: source.name)
    defer { lock.release() }
    _ = try await verify(source); _ = try await verify(target)
    try await checked(source.executable, ["set-option", "-t", source.name, "@focus-queue-layout", "manual"])
    try await checked(source.executable, ["swap-pane", "-d", "-s", source.paneID, "-t", target.paneID])
  }

  public func reflow(name: String, executable: String, force: Bool = false) async throws {
    try Self.validateName(name)
    guard name.hasPrefix("fq-task-") else { return }
    let lock = try await TmuxOrganizerLock.acquire(name: name)
    defer { lock.release() }
    try await reflowUnlocked(name: name, executable: executable, force: force)
  }

  private func reflowUnlocked(name: String, executable: String, force: Bool) async throws {
    let all = try await panes(name: name, executable: executable)
    guard let first = all.first, force || first.automatic else { return }
    // Unregistered/restored shells remain under the user's control.
    guard all.allSatisfy({ !$0.subtaskID.isEmpty }) else { return }
    guard all.count <= TmuxPaneLayout.maximumPanes else {
      throw TmuxError.unavailable(
        "This legacy task session has more than four panes. Focus Queue left its layout unchanged.")
    }
    let focused = try await run(executable, ["display-message", "-p", "-t", "=\(name):", "#{pane_id}"])
    let activePane = focused.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let sizes = try await run(executable, ["list-clients", "-t", "=\(name)", "-F", "#{client_width}|#{client_height}|#{client_activity}|#{client_control_mode}"])
    guard sizes.succeeded else { throw TmuxError.unavailable("Could not read the task window size.") }
    let clients = sizes.standardOutput.split(separator: "\n").compactMap { line -> (Int, Int, Int, Int)? in
      let f = line.split(separator: "|").compactMap { Int($0) }
      return f.count == 4 ? (f[0], f[1], f[2], f[3]) : nil
    }
    let client = clients.max(by: { $0.2 < $1.2 })
    // User wrappers can reserve multiple status rows (for example a usage bar).
    // Respect that setting instead of sizing panes underneath those rows.
    let status = try await run(executable, ["show-options", "-Av", "-t", name, "status"])
    guard status.succeeded else { throw TmuxError.unavailable("Could not read the task status bar size.") }
    let statusValue = status.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let width = client?.0 ?? first.windowWidth
    let height = client.map { TmuxPaneLayout.contentHeight(clientHeight: $0.1, status: statusValue, controlMode: $0.3 == 1) } ?? first.windowHeight
    let ordered = all.sorted { (Int($0.id.dropFirst()) ?? 0) < (Int($1.id.dropFirst()) ?? 0) }
    let signature = "\(width)x\(height):" + ordered.map(\.id).joined(separator: ",")
    let previous = try await run(executable, ["show-options", "-qv", "-t", name, "@focus-queue-size"])
    if !force, previous.succeeded, previous.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == signature { return }
    let groups = [ordered]
    try await checked(executable, ["set-option", "-t", name, "status-left", ""])
    try await checked(executable, ["set-option", "-t", name, "status-right", ""])
    // Consolidate every managed agent into the task's one window.
    for group in groups {
      guard let anchor = group.first else { continue }
      let current = try await panes(name: name, executable: executable)
      guard let liveAnchor = current.first(where: { $0.id == anchor.id }) else { throw TmuxError.changed }
      let groupIDs = Set(group.map(\.id))
      if current.contains(where: { $0.windowID == liveAnchor.windowID && !groupIDs.contains($0.id) }) {
        try await checked(executable, ["break-pane", "-d", "-s", anchor.id, "-t", "=\(name):", "-n", "Agents"])
      }
      try await checked(executable, ["resize-window", "-t", anchor.id, "-x", String(width), "-y", String(height)])
      for member in group.dropFirst() {
        let latest = try await panes(name: name, executable: executable)
        if latest.first(where: { $0.id == member.id })?.windowID != latest.first(where: { $0.id == anchor.id })?.windowID {
          try await checked(executable, ["join-pane", "-d", "-s", member.id, "-t", anchor.id])
          // Make enough room before joining the next pane, including on short windows.
          try await checked(executable, ["select-layout", "-t", anchor.id, "tiled"])
        }
      }
      try await checked(executable, ["select-layout", "-t", anchor.id,
        TmuxPaneLayout.layout(paneIDs: group.map(\.id), width: width, height: height)])
      try await checked(executable, ["rename-window", "-t", anchor.id, "Agents"])
      try await checked(executable, ["set-window-option", "-t", anchor.id, "automatic-rename", "off"])
      try await checked(executable, ["set-window-option", "-t", anchor.id, "window-size", "latest"])
      try await checked(executable, ["set-window-option", "-t", anchor.id, "pane-border-status", "off"])
      try await checked(executable, ["set-window-option", "-u", "-t", anchor.id, "pane-border-format"])
    }
    try await checked(executable, ["set-option", "-t", name, "@focus-queue-size", signature])
    if all.contains(where: { $0.id == activePane }) {
      try await checked(executable, ["select-window", "-t", activePane])
      try await checked(executable, ["select-pane", "-t", activePane])
    }
  }

  private func resetPlainPresentation(
    name: String, paneID: String, executable: String
  ) async throws {
    try await checked(executable, ["set-option", "-t", name, "status-left", ""])
    try await checked(executable, ["set-option", "-t", name, "status-right", ""])
    try await checked(executable, ["set-window-option", "-t", paneID, "pane-border-status", "off"])
    try await checked(executable, ["set-window-option", "-u", "-t", paneID, "pane-border-format"])
  }
}

private extension Optional {
  func unwrapTmux() throws -> Wrapped {
    guard let value = self else { throw TmuxError.unavailable("Invalid launch arguments.") }
    return value
  }
}

private extension Array {
  var onlyElement: Element? { count == 1 ? first : nil }
}
