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
    // Drag a new file onto the bulletin board to pin it.
    .bulletinDraggable(.file(output.url))
    .contextMenu {
      PinFileMenuItem(url: output.url, ticketID: ticketID, model: model)
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

/// "Pin to Task" or "Unpin from Task" for one file, for any context menu.
struct PinFileMenuItem: View {
  let url: URL
  let ticketID: String
  let model: QueueViewModel

  var body: some View {
    let pinned = model.isFilePinned(url, ticketID: ticketID)
    Button(pinned ? "Unpin from Task" : "Pin to Task", systemImage: pinned ? "pin.slash" : "pin") {
      Task { await model.setFilePinned(url, ticketID: ticketID, pinned: !pinned) }
    }
  }
}

/// Files the user pinned to the task. They stay here, under the new-files
/// panel, until unpinned or deleted. Same layout as new files, in the
/// queue's own surface colors instead of the accent blue.
struct PinnedFilesPanel: View {
  let ticketID: String
  let files: [URL]
  let model: QueueViewModel
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Image(systemName: "pin.fill").foregroundStyle(.secondary)
        Text(files.count == 1 ? "Pinned file" : "\(files.count) pinned files")
          .font(.system(size: 12, weight: .semibold))
        Spacer()
      }
      ForEach(files, id: \.path) { row($0) }
    }
    .padding(9)
    .background(QueuePalette.component(for: colorScheme), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(QueuePalette.panelBorder(for: colorScheme)))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Pinned files")
  }

  private func row(_ url: URL) -> some View {
    HStack(spacing: 8) {
      Button { model.openPinnedFile(url, ticketID: ticketID) } label: {
        HStack(spacing: 8) {
          Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable().frame(width: 22, height: 22)
          VStack(alignment: .leading, spacing: 1) {
            Text(url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text(Self.caption(url, context: model.taskContexts[ticketID]?.contextDirectory))
              .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 4)
          Image(systemName: "arrow.up.forward.square").foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help("Open \(url.path)")
      .accessibilityLabel("Open pinned file \(url.lastPathComponent)")
      Button {
        Task { await model.setFilePinned(url, ticketID: ticketID, pinned: false) }
      } label: {
        Image(systemName: "pin.slash").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .help("Unpin from this task. The file is not deleted.")
      .accessibilityLabel("Unpin \(url.lastPathComponent)")
    }
    .bulletinDraggable(.file(url))
    .contextMenu {
      PinFileMenuItem(url: url, ticketID: ticketID, model: model)
      Button("Show in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
    }
  }

  /// "evidence/" for a context-folder file, otherwise its abbreviated folder.
  static func caption(_ url: URL, context: URL?) -> String {
    let folder = url.deletingLastPathComponent().standardizedFileURL.path
    if let base = context?.standardizedFileURL.path {
      if folder == base { return "Task context" }
      if folder.hasPrefix(base + "/") { return String(folder.dropFirst(base.count + 1)) + "/" }
    }
    return (folder as NSString).abbreviatingWithTildeInPath + "/"
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
