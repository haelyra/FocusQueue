import AppKit
import FocusQueueCore
import QuickLookThumbnailing
import SwiftUI

/// A task's context, evidence, and links as a Finder-style icon grid: one
/// click selects an item, a double click opens it the usual way.
struct TaskContextGridView: View {
  let ticket: DashboardTicket
  let model: QueueViewModel
  var onClose: (() -> Void)?
  @State private var selection: String?

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

  var body: some View {
    let groups = itemGroups
    let count = groups.reduce(0) { $0 + $1.items.count }
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text("Context").font(.system(size: 13, weight: .semibold))
        Text(ticket.id).font(.system(size: 11, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary)
        Spacer()
        if let onClose {
          Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Close context")
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      Divider().opacity(0.5)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(groups, id: \.title) { group in
            Text(group.title.uppercased())
              .font(.system(size: 10, weight: .bold)).tracking(0.4)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4).padding(.top, 8)
            LazyVGrid(columns: columns, spacing: 2) {
              ForEach(group.items) { item in cell(item) }
            }
          }
          if groups.allSatisfy({ $0.title == "Task files" }) {
            Text("No evidence or links have been attached yet.")
              .font(.caption).foregroundStyle(.secondary)
              .padding(.horizontal, 4).padding(.top, 8)
          }
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
      }
      Divider().opacity(0.5)
      HStack {
        Text("\(count) \(count == 1 ? "item" : "items")")
        Spacer()
        if let context = model.taskContexts[ticket.id] {
          Button("Open in Finder") { model.open(context.contextDirectory.path) }
            .controlSize(.small)
        }
      }
      .font(.system(size: 11)).foregroundStyle(.secondary)
      .padding(.horizontal, 12).padding(.vertical, 8)
    }
  }

  private func cell(_ item: TaskContextItem) -> some View {
    let isSelected = selection == item.id
    return VStack(spacing: 4) {
      TaskContextThumbnail(item: item).frame(width: 52, height: 52)
      Text(item.title)
        .font(.system(size: 11))
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 4))
    }
    .frame(maxWidth: .infinity, minHeight: 92, alignment: .top)
    .padding(.vertical, 6).padding(.horizontal, 3)
    .background(
      isSelected ? Color.accentColor.opacity(0.22) : .clear,
      in: RoundedRectangle(cornerRadius: 7))
    .contentShape(RoundedRectangle(cornerRadius: 7))
    .onTapGesture(count: 2) { open(item) }
    .simultaneousGesture(TapGesture().onEnded { selection = item.id })
    .contextMenu {
      Button("Open", systemImage: "arrow.up.forward.app") { open(item) }
      if let url = item.fileURL {
        Button("Show in Finder", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
      }
    }
    .help(item.help)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityAction { open(item) }
    .accessibilityHint("Double-click to open.")
  }

  private func open(_ item: TaskContextItem) {
    selection = item.id
    switch item.target {
    case .plan: model.openPlan(for: ticket)
    case .resource(let value): model.open(value, ticketID: ticket.id)
    case .folder(let url): model.open(url.path)
    case .web(let url): model.open(url)
    }
  }

  private var itemGroups: [(title: String, items: [TaskContextItem])] {
    var files: [TaskContextItem] = []
    if let context = model.taskContexts[ticket.id] {
      let planURL = URL(fileURLWithPath: context.planPath)
      files.append(TaskContextItem(
        id: "plan", title: planURL.lastPathComponent, target: .plan, fileURL: planURL,
        help: "Central plan"))
      for url in [context.dataURL, context.agentLogURL] {
        files.append(TaskContextItem(
          id: url.path, title: url.lastPathComponent, target: .resource(url.path), fileURL: url,
          help: url.path))
      }
      files.append(TaskContextItem(
        id: "folder", title: "Context folder", target: .folder(context.contextDirectory),
        fileURL: context.contextDirectory, help: context.contextDirectory.path))
    }
    let evidence = Array(Set(ticket.steps.flatMap(\.evidence))).sorted().map { value in
      let url = ResourceLocator.url(for: value)
      return TaskContextItem(
        id: "evidence:\(value)", title: url?.lastPathComponent ?? value, target: .resource(value),
        fileURL: url?.isFileURL == true ? url : nil, symbol: url?.isFileURL == true ? nil : "globe",
        help: value)
    }
    let links = ticket.links.map { link in
      let url = ResourceLocator.url(for: link.url)
      return TaskContextItem(
        id: "link:\(link.id)", title: link.label, target: .resource(link.url),
        fileURL: url?.isFileURL == true ? url : nil, symbol: url?.isFileURL == true ? nil : "link",
        help: link.url)
    } + ticket.prs.map { pr in
      TaskContextItem(
        id: "pr:\(pr.number)", title: "PR #\(pr.number): \(pr.title)", target: .web(pr.url),
        symbol: "arrow.triangle.branch", help: pr.url)
    }
    return [("Task files", files), ("Evidence", evidence), ("Links & PRs", links)]
      .filter { !$0.items.isEmpty }
  }
}

struct TaskContextItem: Identifiable {
  enum Target {
    case plan
    case resource(String)
    case folder(URL)
    case web(String)
  }

  let id: String
  let title: String
  let target: Target
  var fileURL: URL?
  var symbol: String?
  var help: String
}

/// Quick Look's thumbnail for a local file, over its Finder icon while it
/// renders; a symbol tile for web links.
private struct TaskContextThumbnail: View {
  let item: TaskContextItem
  @Environment(\.displayScale) private var displayScale
  @State private var preview: NSImage?

  var body: some View {
    if let url = item.fileURL {
      Image(nsImage: preview ?? NSWorkspace.shared.icon(forFile: url.path))
        .resizable().scaledToFit()
        .task(id: url) { preview = await Self.thumbnail(for: url, scale: displayScale) }
    } else {
      Image(systemName: item.symbol ?? "link")
        .font(.system(size: 19, weight: .medium))
        .frame(width: 44, height: 44)
        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }
  }

  private static func thumbnail(for url: URL, scale: CGFloat) async -> NSImage? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let request = QLThumbnailGenerator.Request(
      fileAt: url, size: CGSize(width: 52, height: 52), scale: scale,
      representationTypes: .thumbnail)
    let image: CGImage? = await withCheckedContinuation { continuation in
      QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
        continuation.resume(returning: representation?.cgImage)
      }
    }
    return image.map { NSImage(cgImage: $0, size: NSSize(width: 52, height: 52)) }
  }
}
