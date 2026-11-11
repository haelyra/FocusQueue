import AppKit
import FocusQueueCore
import SwiftUI

/// A project's module folder as a Finder-style icon grid, like a task's
/// Context: each module's design (I/O) file, then the files every module
/// shares. One click selects; a double click opens the file in the document
/// viewer with the project chat.
struct ModuleFilesGridView: View {
  let model: QueueViewModel
  var onClose: (() -> Void)?
  @State private var selection: String?

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

  var body: some View {
    let files = model.developmentModuleFiles
    let groups = [("Modules", files.filter(\.isModule)), ("Shared files", files.filter { !$0.isModule })]
      .filter { !$0.1.isEmpty }
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text("Module files").font(.system(size: 13, weight: .semibold))
        if let name = model.selectedProject?.name {
          Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        if let onClose {
          Button(action: onClose) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("Close module files")
        }
      }
      .padding(.horizontal, 14).padding(.vertical, 10)
      Divider().opacity(0.5)
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(groups, id: \.0) { group in
            Text(group.0.uppercased())
              .font(.system(size: 10, weight: .bold)).tracking(0.4)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 4).padding(.top, 8)
            LazyVGrid(columns: columns, spacing: 2) {
              ForEach(group.1) { file in cell(file) }
            }
          }
          if files.isEmpty {
            Text(Self.emptyText)
              .font(.caption).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 4).padding(.top, 8)
          }
        }
        .padding(.horizontal, 10).padding(.bottom, 12)
      }
      Divider().opacity(0.5)
      HStack {
        Text("\(files.count) \(files.count == 1 ? "item" : "items")")
        if let folder = model.developmentModuleFolder {
          Text(Self.folderLabel(folder)).lineLimit(1).truncationMode(.head).help(folder.path)
        }
        Spacer()
        Button("Open in Finder") { model.showDevelopmentModuleFolder() }
          .controlSize(.small)
      }
      .font(.system(size: 11)).foregroundStyle(.secondary)
      .padding(.horizontal, 12).padding(.vertical, 8)
    }
    .task { model.reloadDevelopmentModuleFiles() }
  }

  static let emptyText = "No module files yet. Each module's design file (its I/O contract) appears here once written to docs/modules/ in the repository or modules/ in the project folder, named m<N>-<slug>.md."

  /// `docs/modules` for the repository folder, `modules` for the project's.
  static func folderLabel(_ folder: URL) -> String {
    folder.deletingLastPathComponent().lastPathComponent == "docs" ? "docs/modules" : "modules"
  }

  private func cell(_ file: DevelopmentModuleFile) -> some View {
    let tracked = model.developmentProcess.flatMap { DevelopmentModuleFiles.module(for: file, in: $0.modules) }
    let item = TaskContextItem(
      id: file.id, title: Self.cellTitle(file),
      target: .resource(file.url.path), fileURL: file.url, help: help(file, tracked: tracked))
    return ContextGridCell(item: item, isSelected: selection == file.id,
                           onSelect: { selection = file.id }, onOpen: { open(file) }) {
      Button("Open", systemImage: "arrow.up.forward.app") { open(file) }
      Button("Show in Finder", systemImage: "folder") {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
      }
      if file.isModule, tracked == nil, model.developmentProcess != nil {
        Button("Track module", systemImage: "plus.circle") { model.trackDevelopmentModuleFile(file) }
          .help("Add it to the in-order success-criteria review in the Modules list.")
      }
    }
  }

  /// `M2 Reminder scheduler`: no separator, so two lines wrap at a word.
  static func cellTitle(_ file: DevelopmentModuleFile) -> String {
    let title = file.title.replacingOccurrences(of: "`", with: "")
    return file.moduleID.map { "\($0.uppercased()) \(title)" } ?? title
  }

  private func open(_ file: DevelopmentModuleFile) {
    selection = file.id
    model.openDevelopmentModuleFile(file.url)
  }

  private func help(_ file: DevelopmentModuleFile, tracked: DevelopmentModule?) -> String {
    var lines = [file.url.path]
    if !file.oneLine.isEmpty { lines.append(file.oneLine) }
    if !file.status.isEmpty { lines.append("Status: " + file.status) }
    if file.isModule {
      lines.append(tracked.map { "Tracked as \($0.name)." } ?? "Not tracked yet. Right-click to track it.")
    }
    if file.hasOtherCopy { lines.append("The project folder also has a copy; this repository copy wins.") }
    return lines.joined(separator: "\n")
  }
}
