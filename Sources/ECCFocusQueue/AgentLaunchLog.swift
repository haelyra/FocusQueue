import Foundation

struct LaunchDiagnosticsPresentation: Identifiable {
  let id = UUID()
  let title: String
  let text: String
}

struct AgentLaunchLogEvent: Codable, Equatable, Sendable {
  let timestamp: Date
  let taskID: String
  let subtaskID: String
  let provider: String
  let runtime: String
  let phase: String
  let outcome: String
  let message: String
  let details: [String: String]
}

actor AgentLaunchLogger {
  nonisolated let directory: URL
  private let files = FileManager.default
  private let maximumBytes = 1_000_000

  init(supportDirectory: URL) {
    directory = supportDirectory.appendingPathComponent(
      "logs/agent-launches", isDirectory: true)
  }

  nonisolated func url(subtaskID: String) -> URL {
    let safe = subtaskID.replacingOccurrences(
      of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    return directory.appendingPathComponent("\(safe).jsonl")
  }

  func record(_ event: AgentLaunchLogEvent) throws {
    try files.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let destination = url(subtaskID: event.subtaskID)
    if ((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      >= maximumBytes
    {
      let previous = destination.deletingPathExtension()
        .appendingPathExtension("previous.jsonl")
      try? files.removeItem(at: previous)
      try files.moveItem(at: destination, to: previous)
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var line = try encoder.encode(event)
    line.append(0x0A)
    if !files.fileExists(atPath: destination.path) {
      try line.write(to: destination, options: .atomic)
      try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
      return
    }
    let handle = try FileHandle(forWritingTo: destination)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
  }
}
