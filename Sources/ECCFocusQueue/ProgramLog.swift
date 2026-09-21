import AppKit
import Foundation
import Observation
import SwiftUI

enum ProgramLogLevel: String, CaseIterable, Sendable {
  case info
  case warning
  case error

  var title: String { rawValue.capitalized }

  var symbolName: String {
    switch self {
    case .info: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    case .error: "xmark.octagon.fill"
    }
  }

  var color: Color {
    switch self {
    case .info: .secondary
    case .warning: .orange
    case .error: .red
    }
  }
}

struct ProgramLogEntry: Identifiable, Equatable, Sendable {
  let id: UUID
  let timestamp: Date
  let level: ProgramLogLevel
  let category: String
  let message: String

  init(
    id: UUID = UUID(), timestamp: Date = Date(), level: ProgramLogLevel,
    category: String, message: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.level = level
    self.category = category
    self.message = message
  }
}

@MainActor
@Observable
final class ProgramLogStore {
  private(set) var entries: [ProgramLogEntry] = []
  private let capacity: Int

  init(capacity: Int = 2_000) {
    self.capacity = max(capacity, 1)
  }

  func record(
    _ message: String, level: ProgramLogLevel = .info,
    category: String = "Application", timestamp: Date = Date()
  ) {
    let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty else { return }
    entries.append(ProgramLogEntry(
      timestamp: timestamp,
      level: level,
      category: category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Application" : category,
      message: message
    ))
    if entries.count > capacity {
      entries.removeFirst(entries.count - capacity)
    }
  }

  func clear() {
    entries.removeAll(keepingCapacity: true)
  }

  var renderedText: String {
    entries.map { entry in
      "[\(Self.timestampFormatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
    }.joined(separator: "\n")
  }

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
  }()
}

struct ProgramLogView: View {
  let store: ProgramLogStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Program Log").font(.headline)
          Text("Current app session · \(store.entries.count) event\(store.entries.count == 1 ? "" : "s")")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Copy All", systemImage: "doc.on.doc") { copyAll() }
          .disabled(store.entries.isEmpty)
        Button("Clear", systemImage: "trash") { store.clear() }
          .disabled(store.entries.isEmpty)
      }
      .padding(12)

      Divider()

      if store.entries.isEmpty {
        ContentUnavailableView(
          "No log events yet",
          systemImage: "text.alignleft",
          description: Text("Errors and diagnostic events from this app session will appear here live.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ScrollViewReader { proxy in
          ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0) {
              ForEach(store.entries) { entry in
                ProgramLogEntryView(entry: entry).id(entry.id)
                Divider()
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .onChange(of: store.entries.last?.id) { _, identifier in
            guard let identifier else { return }
            proxy.scrollTo(identifier, anchor: .bottom)
          }
        }
      }
    }
    .frame(minWidth: 640, minHeight: 360)
  }

  private func copyAll() {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(store.renderedText, forType: .string)
  }
}

private struct ProgramLogEntryView: View {
  let entry: ProgramLogEntry

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Text(entry.timestamp, format: .dateTime.hour().minute().second())
        .foregroundStyle(.secondary)
        .frame(width: 72, alignment: .leading)
      Label(entry.level.title, systemImage: entry.level.symbolName)
        .foregroundStyle(entry.level.color)
        .frame(width: 82, alignment: .leading)
      Text(entry.category)
        .foregroundStyle(.secondary)
        .frame(width: 110, alignment: .leading)
      Text(entry.message)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .font(.system(size: 12, design: .monospaced))
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
