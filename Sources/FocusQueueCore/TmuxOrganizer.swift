import Darwin
import Foundation

/// Coordinates the app and resize-hook helper without blocking an executor thread.
struct TmuxOrganizerLock {
  let descriptor: Int32

  static func acquire(name: String) async throws -> Self {
    try TmuxController.validateName(name)
    let path = "/tmp/focus-queue-tmux-\(getuid())-\(name).lock"
    let fd = Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw TmuxError.unavailable("Could not lock the task layout.") }
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
  public let isActive: Bool
  public let automatic: Bool

  static let format = TmuxController.format + "|#{window_id}|#{window_index}|#{window_width}|#{window_height}|#{pane_left}|#{pane_top}|#{pane_width}|#{pane_height}|#{@focus-queue-agent}|#{pane_active}|#{@focus-queue-layout}"

  static func decode(_ output: String, executable: String) throws -> [Self] {
    try output.split(separator: "\n").map { line in
      let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
      guard f.count == 18, f[7].range(of: "^@[0-9]+$", options: .regularExpression) != nil,
            let index = Int(f[8]), let ww = Int(f[9]), let wh = Int(f[10]),
            let x = Int(f[11]), let y = Int(f[12]), let w = Int(f[13]), let h = Int(f[14]),
            ww > 0, wh > 0, w > 0, h > 0,
            let reference = try TmuxController.decode(f.prefix(7).joined(separator: "|"), executable: executable).first else {
        throw TmuxError.unavailable("The pane layout changed while reading it. Refresh to retry.")
      }
      return Self(reference: reference, windowID: f[7], windowIndex: index,
        windowWidth: ww, windowHeight: wh, left: x, top: y, width: w, height: h,
        subtaskID: f[15], isActive: f[16] == "1", automatic: f[17] != "manual")
    }
  }
}

/// Terminal cells account for the user's font, zoom and actual window size.
public enum TmuxPaneLayout {
  public static let minimumColumns = 72
  public static let minimumRows = 20

  public static func capacity(width: Int, height: Int) -> Int {
    min(4, max(1, (width + 1) / (minimumColumns + 1)) * max(1, (height + 1) / (minimumRows + 1)))
  }

  public static func groups<T>(_ panes: [T], width: Int, height: Int) -> [[T]] {
    let count = capacity(width: width, height: height)
    return stride(from: 0, to: panes.count, by: count).map { Array(panes[$0..<min($0 + count, panes.count)]) }
  }

  /// Produces tmux's checksummed layout tree. Every cell is used, including split borders.
  public static func layout(paneIDs: [String], width: Int, height: Int) throws -> String {
    guard !paneIDs.isEmpty, paneIDs.count <= capacity(width: width, height: height),
      paneIDs.allSatisfy({ $0.range(of: "^%[0-9]+$", options: .regularExpression) != nil }),
      width > 0, height > 0 else { throw TmuxError.unavailable("The panes do not fit this window.") }
    let columns = min(paneIDs.count, max(1, (width + 1) / (minimumColumns + 1)))
    let rows = (paneIDs.count + columns - 1) / columns
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
    let arguments = ["list-panes"] + (name.map { ["-s", "-t", "=\($0)"] } ?? ["-a"])
      + ["-F", TmuxPaneSnapshot.format]
    let result = try await run(executable, arguments)
    if !result.succeeded {
      if !result.timedOut && ["no server running", "No such file or directory", "can't find session", "no sessions"].contains(where: result.standardError.contains) { return [] }
      throw TmuxError.unavailable(String(result.standardError.prefix(800)))
    }
    // A retained dead pane should not hide the other running agents.
    let live = result.standardOutput.split(separator: "\n").filter {
      let fields = $0.split(separator: "|", omittingEmptySubsequences: false)
      return fields.count != 18 || fields[6] == "0"
    }.joined(separator: "\n")
    return try TmuxPaneSnapshot.decode(live, executable: executable)
  }

  public func inspectAgent(taskID: String, subtaskID: String, executable: String) async throws -> TmuxSessionReference {
    let name = try Self.taskSessionName(taskID: taskID)
    let all = try await panes(name: name, executable: executable)
    let matches = all.filter { $0.subtaskID == subtaskID }
    guard matches.count <= 1 else { throw TmuxError.unavailable("More than one pane claims this agent. Check the task panes before retrying.") }
    if let match = matches.first { return match.reference }
    if let pending = try pendingLaunch(taskID: taskID, subtaskID: subtaskID), !all.isEmpty {
      let result = try await run(executable, ["list-panes", "-s", "-t", "=\(name)", "-f",
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
    let existing = try await panes(name: name, executable: executable)
    guard !existing.contains(where: { $0.subtaskID == subtaskID }) else {
      throw TmuxError.unavailable("This agent already has a pane. Open it from the task to continue.")
    }
    if try pendingLaunch(taskID: taskID, subtaskID: subtaskID) != nil, !existing.isEmpty {
      throw TmuxError.unavailable("A previous launch needs to be recalled from its task before retrying.")
    }
    let launchWindow = "fq-launch-" + UUID().uuidString.lowercased()
    let receipt = try launchReceiptURL(taskID: taskID, subtaskID: subtaskID)
    try Data(launchWindow.utf8).write(to: receipt, options: .atomic)
    let base = try Self.startArguments(name: name, directory: directory, command: command)
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
      throw TmuxError.unavailable(result.timedOut ? "Launch is still unconfirmed. Open the task before retrying." : String(result.standardError.prefix(800)))
    }
    let fields = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: result.standardOutput.contains("|") ? "|" : "\t", omittingEmptySubsequences: false)
    guard fields.count == 7, fields[3].range(of: "^%[0-9]+$", options: .regularExpression) != nil else {
      throw TmuxError.startedButUnconfirmed(name: name, executable: executable, attempts: 1, lastDetail: "No pane ID in the launch receipt.")
    }
    let paneID = String(fields[3])
    do {
      try await checked(executable, ["set-option", "-p", "-t", paneID, "@focus-queue-agent", subtaskID])
    } catch {
      throw TmuxError.startedButUnconfirmed(name: name, executable: executable, attempts: 1,
        lastDetail: "The launch receipt is retained. Open this task to recover pane \(paneID). \(error.localizedDescription)")
    }
    try await checked(executable, ["set-option", "-t", name, "@focus-queue-task", taskID.uppercased()])
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
          try? FileManager.default.removeItem(at: receipt)
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

  private func launchReceiptURL(taskID: String, subtaskID: String) throws -> URL {
    try Self.validateName(serverName); try Self.validateName(taskID); try Self.validateName(subtaskID)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("focus-queue-launches-\(serverName)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return root.appendingPathComponent("\(taskID.lowercased())-\(subtaskID).receipt")
  }

  private func pendingLaunch(taskID: String, subtaskID: String) throws -> String? {
    let url = try launchReceiptURL(taskID: taskID, subtaskID: subtaskID)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let value = try String(contentsOf: url, encoding: .utf8)
    try Self.validateName(value)
    return value
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
    let command = ["/usr/bin/env", "FOCUS_QUEUE_SUPPORT_DIR=\(supportDirectory.path)", helper, "tmux", "reflow", name]
      .map(shellQuote).joined(separator: " ")
    for hook in ["client-attached", "client-resized", "client-session-changed"] {
      try await checked(executable, ["set-hook", "-t", name, "\(hook)[35]", "run-shell -b \(shellQuote(command))"])
    }
    // A deliberate border resize opts out of the next automatic rearrangement.
    try await checked(executable, ["set-hook", "-t", name, "after-resize-pane[35]",
      "set-option -t \(name) @focus-queue-layout manual"])
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
    let focused = try await run(executable, ["display-message", "-p", "-t", "=\(name):", "#{pane_id}"])
    let activePane = focused.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let sizes = try await run(executable, ["list-clients", "-t", "=\(name)", "-F", "#{client_width}|#{client_height}|#{client_activity}"])
    guard sizes.succeeded else { throw TmuxError.unavailable("Could not read the task window size.") }
    let clients = sizes.standardOutput.split(separator: "\n").compactMap { line -> (Int, Int, Int)? in
      let f = line.split(separator: "|").compactMap { Int($0) }
      return f.count == 3 ? (f[0], f[1], f[2]) : nil
    }
    let client = clients.max(by: { $0.2 < $1.2 })
    let width = client?.0 ?? first.windowWidth
    let height = client.map { max(1, $0.1 - 1) } ?? first.windowHeight
    let ordered = all.sorted { (Int($0.id.dropFirst()) ?? 0) < (Int($1.id.dropFirst()) ?? 0) }
    let signature = "\(width)x\(height):" + ordered.map(\.id).joined(separator: ",")
    let previous = try await run(executable, ["show-options", "-qv", "-t", name, "@focus-queue-size"])
    if !force, previous.succeeded, previous.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == signature { return }
    let groups = TmuxPaneLayout.groups(ordered, width: width, height: height)
    // Give every group a distinct window, preserving pane IDs and processes.
    for (index, group) in groups.enumerated() {
      guard let anchor = group.first else { continue }
      let current = try await panes(name: name, executable: executable)
      guard let liveAnchor = current.first(where: { $0.id == anchor.id }) else { throw TmuxError.changed }
      let groupIDs = Set(group.map(\.id))
      if current.contains(where: { $0.windowID == liveAnchor.windowID && !groupIDs.contains($0.id) }) {
        try await checked(executable, ["break-pane", "-d", "-s", anchor.id, "-t", "=\(name):", "-n", "Agents \(index + 1)"])
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
      try await checked(executable, ["rename-window", "-t", anchor.id, "Agents \(index + 1)"])
      try await checked(executable, ["set-window-option", "-t", anchor.id, "automatic-rename", "off"])
      try await checked(executable, ["set-window-option", "-t", anchor.id, "window-size", "latest"])
    }
    try await checked(executable, ["set-option", "-t", name, "@focus-queue-size", signature])
    if all.contains(where: { $0.id == activePane }) {
      try await checked(executable, ["select-window", "-t", activePane])
      try await checked(executable, ["select-pane", "-t", activePane])
    }
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
