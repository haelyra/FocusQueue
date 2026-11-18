import AppKit
import FocusQueueCore
import SwiftUI
import UniformTypeIdentifiers

enum BulletinBoardMetrics {
  static let cardWidth: Double = 168
  static let cardHeight: Double = 78
  static let spacing: Double = 14
  static let pinSize: CGFloat = 13
}

/// The bulletin board side panel: a gray board of pinned tasks, agents, files,
/// and folders. Drop items anywhere on it, drag cards to rearrange them, and
/// click a card to open its item.
struct BulletinBoardView: View {
  let model: QueueViewModel
  @State private var dropIsTargeted = false
  @State private var dragOffsets: [String: CGSize] = [:]

  private var scopeName: String { model.bulletinBoardProjectID == nil ? "All projects" : model.projectScopeName }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      if let error = model.bulletinBoardError {
        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
      }
      board
    }
    .onAppear { model.loadBulletinPinsIfNeeded() }
  }

  private var header: some View {
    HStack(spacing: 8) {
      PinHead(color: .red).frame(width: BulletinBoardMetrics.pinSize, height: BulletinBoardMetrics.pinSize)
      VStack(alignment: .leading, spacing: 0) {
        Text("Bulletin board").font(.headline)
        Text(scopeName).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      optionsMenu
      Button { model.setBulletinBoardPresented(false) } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.plain)
      .frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
      .accessibilityLabel("Close bulletin board")
      .help("Close bulletin board (\(model.hotkeyShortcut(for: .bulletinBoard).displayString))")
    }
  }

  private var optionsMenu: some View {
    let cleaned = model.cleanedBulletinPinCount
    return Menu {
      Toggle(isOn: Binding(
        get: { model.showsCleanedBulletinPins },
        set: { model.setShowsCleanedBulletinPins($0) })
      ) {
        Text(cleaned > 0 ? "Show cleaned-up items (\(cleaned))" : "Show cleaned-up items")
      }
      Button("Pin file or folder…", systemImage: "doc.badge.plus") { chooseFiles() }
      Divider()
      Button("Remove cleaned-up pins", systemImage: "trash") { model.removeCleanedBulletinPins() }
        .disabled(cleaned == 0)
    } label: {
      VerticalOverflowIcon()
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .frame(minWidth: 30, minHeight: 30).contentShape(Rectangle())
    .accessibilityLabel("Bulletin board options")
    .help("Show cleaned-up items, pin a file or folder, or remove cleaned-up pins")
  }

  private var board: some View {
    let pins = model.visibleBulletinPins
    return GeometryReader { geometry in
      let width = max(geometry.size.width, BulletinBoardMetrics.cardWidth + 2 * BulletinBoardMetrics.spacing)
      let contentHeight = pins.map { $0.y + BulletinBoardMetrics.cardHeight + BulletinBoardMetrics.spacing }.max() ?? 0
      ScrollView(.vertical) {
        ZStack(alignment: .topLeading) {
          Color.clear
          if pins.isEmpty { emptyState.frame(width: width, height: geometry.size.height) }
          ForEach(pins) { pin in
            card(pin, boardWidth: width)
          }
        }
        .frame(width: width, height: max(geometry.size.height, contentHeight), alignment: .topLeading)
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .plainText, .utf8PlainText], isTargeted: $dropIsTargeted) { providers, location in
          accept(providers, at: location)
        }
      }
      .scrollIndicators(.automatic)
      .background(boardBackground)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(dropIsTargeted ? Color.accentColor : Color.primary.opacity(0.12),
                  lineWidth: dropIsTargeted ? 2 : 1)
          .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Bulletin board, \(pins.count) pinned")
  }

  private var boardBackground: some View {
    Color(nsColor: NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.82, alpha: 1)
    })
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "pin").font(.system(size: 22, weight: .semibold)).foregroundStyle(.secondary)
      Text("Drag tasks, agents, files, or folders here")
        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
      Text("Or use Pin to bulletin board in a task or agent menu.")
        .font(.caption).foregroundStyle(.secondary)
    }
    .multilineTextAlignment(.center)
    .padding(24)
    .allowsHitTesting(false)
  }

  // MARK: - Cards

  private func card(_ pin: BulletinPin, boardWidth: Double) -> some View {
    let offset = dragOffsets[pin.id] ?? .zero
    let maxX = max(0, boardWidth - BulletinBoardMetrics.cardWidth - 4)
    let x = min(pin.x, maxX)
    return BulletinPinCard(model: model, pin: pin, isCleanedUp: model.isBulletinPinCleanedUp(pin))
      .frame(width: BulletinBoardMetrics.cardWidth, height: BulletinBoardMetrics.cardHeight)
      .offset(x: x + offset.width, y: pin.y + offset.height)
      .zIndex(dragOffsets[pin.id] == nil ? 0 : 1)
      .gesture(
        DragGesture(minimumDistance: 4)
          .onChanged { value in dragOffsets[pin.id] = value.translation }
          .onEnded { value in
            dragOffsets[pin.id] = nil
            let newX = min(max(0, x + value.translation.width), maxX)
            let newY = max(0, pin.y + value.translation.height)
            model.moveBulletinPin(pin.id, to: CGPoint(x: newX, y: newY))
          })
      .onTapGesture { model.openBulletinPin(pin) }
  }

  // MARK: - Dropping and choosing

  /// File URLs pin as files or folders; strings may be task IDs, agent drag
  /// tokens, or file URLs. Several items fan out from the drop point.
  private func accept(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
    let model = model
    var accepted = false
    for (index, provider) in providers.enumerated() {
      let point = CGPoint(
        x: location.x - BulletinBoardMetrics.cardWidth / 2 + Double(index) * 22,
        y: location.y - 18 + Double(index) * 22)
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        accepted = true
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in model.pinFileToBulletinBoard(url, at: point) }
        }
      } else if provider.canLoadObject(ofClass: String.self) {
        accepted = true
        _ = provider.loadObject(ofClass: String.self) { value, _ in
          guard let value else { return }
          Task { @MainActor in model.pinDroppedItem(value, at: point) }
        }
      }
    }
    return accepted
  }

  private func chooseFiles() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.prompt = "Pin"
    panel.message = "Choose files or folders to pin to the bulletin board."
    guard panel.runModal() == .OK else { return }
    for url in panel.urls { model.pinFileToBulletinBoard(url) }
  }
}

/// A small round push pin, drawn at the top of each card.
private struct PinHead: View {
  let color: Color

  var body: some View {
    Circle()
      .fill(RadialGradient(colors: [color.opacity(0.75), color], center: .init(x: 0.35, y: 0.3),
                           startRadius: 0, endRadius: 8))
      .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
  }
}

private struct BulletinPinCard: View {
  let model: QueueViewModel
  let pin: BulletinPin
  let isCleanedUp: Bool

  private var ticket: DashboardTicket? { model.bulletinTicket(for: pin) }
  private var agent: TaskSubtask? { model.bulletinAgent(for: pin) }

  private var pinColor: Color {
    switch pin.kind {
    case .task: .red
    case .agent: .blue
    case .file: .orange
    case .folder: .green
    }
  }

  private var systemImage: String {
    switch pin.kind {
    case .task: "checklist"
    case .agent: "terminal"
    case .file: "doc"
    case .folder: "folder"
    }
  }

  private var kindLabel: String {
    switch pin.kind {
    case .task: pin.taskID ?? "Task"
    case .agent: "Agent · \(pin.taskID ?? "")"
    case .file: "File"
    case .folder: "Folder"
    }
  }

  private var detail: String {
    if isCleanedUp { return "Cleaned up" }
    switch pin.kind {
    case .task: return ticket?.status ?? ""
    case .agent:
      guard let agent else { return "" }
      return agent.attention?.label ?? model.effectiveStatus(for: agent).rawValue
    case .file, .folder:
      guard let path = pin.path else { return "" }
      return (URL(fileURLWithPath: path).deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }
  }

  var body: some View {
    let title = model.bulletinPinTitle(pin)
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
        Text(kindLabel).font(.system(size: 9, weight: .semibold)).lineLimit(1)
      }
      .foregroundStyle(.secondary)
      Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      Text(detail).font(.system(size: 10)).foregroundStyle(isCleanedUp ? Color.orange : Color.secondary)
        .lineLimit(1).truncationMode(.middle)
    }
    .padding(.horizontal, 10).padding(.top, 11).padding(.bottom, 7)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    // Cleaned-up cards stay opaque so overlapping cards never show through.
    .opacity(isCleanedUp ? 0.5 : 1)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
      isCleanedUp ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1),
      style: StrokeStyle(lineWidth: isCleanedUp ? 1 : 0.5, dash: isCleanedUp ? [4, 3] : [])))
    .shadow(color: .black.opacity(0.22), radius: 3, y: 2)
    .overlay(alignment: .top) {
      PinHead(color: pinColor)
        .frame(width: BulletinBoardMetrics.pinSize, height: BulletinBoardMetrics.pinSize)
        .offset(y: -BulletinBoardMetrics.pinSize / 2 + 1)
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .contextMenu {
      Button("Open", systemImage: "arrow.up.forward.square") { model.openBulletinPin(pin) }
        .disabled(isCleanedUp && pin.kind != .file && pin.kind != .folder)
      if let path = pin.path {
        Button("Show in Finder", systemImage: "folder") {
          NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        .disabled(isCleanedUp)
      }
      Divider()
      Button("Unpin", systemImage: "pin.slash") { model.unpinBulletinPin(pin.id) }
    }
    .help(pin.path ?? title)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(kindLabel), \(title), \(detail)")
    .accessibilityHint("Opens the pinned item. Drag to move it on the board.")
    .accessibilityAction(named: "Unpin") { model.unpinBulletinPin(pin.id) }
  }
}

/// "Pin to bulletin board" for task and agent menus; unpins when already pinned.
struct BulletinBoardMenuButton: View {
  let model: QueueViewModel
  let taskID: String
  var subtaskID: String? = nil

  var body: some View {
    let pinned = model.isPinnedToBulletinBoard(taskID: taskID, subtaskID: subtaskID)
    Button(pinned ? "Unpin from bulletin board" : "Pin to bulletin board",
           systemImage: pinned ? "pin.slash" : "pin.circle") {
      if pinned {
        model.unpinTaskFromBulletinBoard(taskID: taskID, subtaskID: subtaskID)
      } else if let subtaskID {
        model.pinAgentToBulletinBoard(taskID: taskID, subtaskID: subtaskID)
      } else {
        model.pinTaskToBulletinBoard(taskID)
      }
    }
  }
}
