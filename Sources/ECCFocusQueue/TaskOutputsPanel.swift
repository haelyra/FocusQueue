import AppKit
import FocusQueueCore
import SwiftUI

/// Files an agent just saved in the task's context folder. Opening or
/// dismissing one removes it here; it stays under View Context.
struct NewOutputsPanel: View {
  let ticketID: String
  let outputs: [TaskOutputFile]
  let model: QueueViewModel
  let showAll: () -> Void

  private static let visibleLimit = 3

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
        Text(outputs.count == 1 ? "New file from agent" : "\(outputs.count) new files from agent")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
        Button("Dismiss all") {
          Task { await model.markOutputsReviewed(outputs, ticketID: ticketID) }
        }
        .buttonStyle(.borderless).font(.system(size: 11))
        .help("Stop announcing these files. They stay in the task's context folder.")
      }
      ForEach(outputs.prefix(Self.visibleLimit)) { output in row(output) }
      if outputs.count > Self.visibleLimit {
        Button("\(outputs.count - Self.visibleLimit) more in Context", action: showAll)
          .buttonStyle(.link).font(.system(size: 11))
      }
    }
    .padding(9)
    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.35)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("New files from agent")
  }

  private func row(_ output: TaskOutputFile) -> some View {
    HStack(spacing: 8) {
      Button { model.openOutput(output, ticketID: ticketID) } label: {
        HStack(spacing: 8) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: output.url.path))
            .resizable().frame(width: 22, height: 22)
          VStack(alignment: .leading, spacing: 1) {
            Text(output.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(Self.caption(output)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer(minLength: 4)
          Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open \(output.relativePath)")
      .accessibilityLabel("Open new file \(output.url.lastPathComponent)")
      Button {
        Task { await model.markOutputsReviewed([output], ticketID: ticketID) }
      } label: {
        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Dismiss. The file stays in the task's context folder.")
      .accessibilityLabel("Dismiss \(output.url.lastPathComponent)")
    }
    .contextMenu {
      Button("Show in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([output.url])
      }
    }
  }

  /// "evidence/ · 4 min ago": the folder inside the context folder, then age.
  static func caption(_ output: TaskOutputFile, now: Date = Date()) -> String {
    let folder = (output.relativePath as NSString).deletingLastPathComponent
    let age = RelativeDateTimeFormatter().localizedString(for: output.modifiedAt, relativeTo: now)
    return folder.isEmpty ? "Saved \(age)" : "\(folder)/ · saved \(age)"
  }
}

/// Shown beside a collapsed task's title so new files are not hidden.
struct NewOutputsBadge: View {
  let count: Int

  var body: some View {
    Label("\(count) NEW \(count == 1 ? "FILE" : "FILES")", systemImage: "doc.badge.plus")
      .font(.system(size: 8, weight: .heavy))
      .tracking(0.45)
      .foregroundStyle(Color.accentColor)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.accentColor.opacity(0.14), in: Capsule())
      .fixedSize()
      .accessibilityLabel("\(count) new \(count == 1 ? "file" : "files") from agent")
  }
}
