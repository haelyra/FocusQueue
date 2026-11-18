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

/// The bulletin board side panel: a dark gray board of pinned tasks, agents,
/// files, folders, and links. Drop items anywhere on it, drag cards to
/// rearrange them, and click a card to open its item.
struct BulletinBoardView: View {
  let model: QueueViewModel
  /// Where this copy of the board is showing, which shapes its header.
  var mode: BulletinBoardMode = .side
  @State private var dropIsTargeted = false
  @State private var dragOffsets: [String: CGSize] = [:]
  @State private var tearOffDistance: CGFloat = 0
  /// The card just clicked, pressed in and outlined for a moment.
  @State private var pressedPinID: String?

  private var scopeName: String { model.bulletinBoardProjectID == nil ? "All projects" : model.projectScopeName }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      header
      if let error = model.bulletinBoardError {
        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
      }
      board
    }
    .onAppear { model.loadBulletinPinsIfNeeded() }
  }

  /// A small title: the board itself is the content. Dragging the title out
  /// of the queue tears the board off into its own window.
  private var header: some View {
    HStack(spacing: 6) {
      titleHandle
      Spacer(minLength: 4)
      placementButtons
      if mode == .window { windowPinButton }
      optionsMenu
      Button { model.hideBulletinBoard() } label: {
        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
      }
      .buttonStyle(.plain)
      .frame(minWidth: 26, minHeight: 26).contentShape(Rectangle())
      .accessibilityLabel("Close bulletin board")
      .help("Close bulletin board (\(model.hotkeyShortcut(for: .bulletinBoard).displayString)). It reopens here for this project.")
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Bulletin board, \(scopeName)")
  }

  private var titleHandle: some View {
    HStack(spacing: 6) {
      PinHead(color: .red).frame(width: 9, height: 9)
      Text(tearOffDistance > 40 ? "RELEASE TO DETACH" : "BULLETIN BOARD")
        .font(.system(size: 10, weight: .heavy)).tracking(0.6)
        .foregroundStyle(tearOffDistance > 40 ? Color.accentColor : Color.secondary)
      Text(scopeName).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
    }
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .global)
      .onChanged { value in tearOffDistance = hypot(value.translation.width, value.translation.height) }
      .onEnded { _ in
        let detach = tearOffDistance > 40
        tearOffDistance = 0
        if detach { model.detachBulletinBoard(at: NSEvent.mouseLocation) }
      }, including: mode == .window ? .subviews : .all)
    .help(mode == .window ? "Bulletin board for \(scopeName)"
      : "Drag the title out to detach the board into its own window")
  }

  /// Beside the queue, the queue's Board tab, or its own window. The choice
  /// is remembered per project.
  private var placementButtons: some View {
    HStack(spacing: 0) {
      placementButton(.side, systemImage: "sidebar.right", label: "Beside the queue")
      placementButton(.tab, systemImage: "rectangle.stack", label: "In the queue's Board tab")
      placementButton(.window, systemImage: "macwindow.on.rectangle", label: "In its own window")
    }
    .padding(2)
    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
  }

  private func placementButton(_ target: BulletinBoardMode, systemImage: String, label: String) -> some View {
    let isCurrent = mode == target
    return Button { model.moveBulletinBoard(to: target) } label: {
      Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
        .frame(width: 22, height: 18)
        .background(isCurrent ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isCurrent)
    .accessibilityLabel("Show the board \(label.lowercased())")
    .accessibilityValue(isCurrent ? "Current" : "")
    .help(isCurrent ? "Showing \(label.lowercased())" : "Show the board \(label.lowercased()). This project reopens it there.")
  }

  private var windowPinButton: some View {
    let pinned = model.bulletinBoardPlacement.windowPinned
    return Button { model.setBulletinBoardWindowPinned(!pinned) } label: {
      Image(systemName: pinned ? "pin.fill" : "pin").font(.system(size: 11, weight: .semibold))
        .foregroundStyle(pinned ? Color.accentColor : Color.secondary)
    }
    .buttonStyle(.plain)
    .frame(minWidth: 26, minHeight: 26).contentShape(Rectangle())
    .accessibilityLabel("Pin board window")
    .accessibilityValue(pinned ? "On" : "Off")
    .help(pinned
      ? "Pinned: stays at this spot on this desktop. Click to float it above apps on every desktop."
      : "Floating above apps on every desktop. Click to pin it at this spot on this desktop.")
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
    .frame(minWidth: 26, minHeight: 26).contentShape(Rectangle())
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
        .onDrop(of: [.fileURL, .plainText, .utf8PlainText, .url], isTargeted: $dropIsTargeted) { providers, location in
          accept(providers, at: location)
        }
      }
      .scrollIndicators(.automatic)
      .background(BulletinBoardColors.board)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        RoundedRectangle(cornerRadius: 14)
          .stroke(dropIsTargeted ? Color.accentColor : Color.black.opacity(0.35),
                  lineWidth: dropIsTargeted ? 2 : 1)
          .allowsHitTesting(false)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Bulletin board, \(pins.count) pinned")
  }

  private var emptyState: some View {
    VStack(spacing: 8) {
      Image(systemName: "pin").font(.system(size: 22, weight: .semibold))
      Text("Drag tasks, agents, files, folders, or links here")
        .font(.callout.weight(.semibold))
      Text("Or use Pin to bulletin board in a task or agent menu.")
        .font(.caption)
    }
    .foregroundStyle(Color.white.opacity(0.55))
    .multilineTextAlignment(.center)
    .padding(24)
    .allowsHitTesting(false)
  }

  // MARK: - Cards

  private func card(_ pin: BulletinPin, boardWidth: Double) -> some View {
    let offset = dragOffsets[pin.id] ?? .zero
    let maxX = max(0, boardWidth - BulletinBoardMetrics.cardWidth - 4)
    let x = min(pin.x, maxX)
    let pressed = pressedPinID == pin.id
    return BulletinPinCard(model: model, pin: pin, isCleanedUp: model.isBulletinPinCleanedUp(pin),
                           feedback: model.bulletinPinFeedback[pin.id])
      .frame(width: BulletinBoardMetrics.cardWidth, height: BulletinBoardMetrics.cardHeight)
      .scaleEffect(pressed ? 0.94 : 1)
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
      .onTapGesture {
        withAnimation(.easeOut(duration: 0.08)) { pressedPinID = pin.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
          withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
            if pressedPinID == pin.id { pressedPinID = nil }
          }
        }
        model.openBulletinPin(pin)
      }
  }

  // MARK: - Dropping and choosing

  /// File URLs pin as files or folders; strings may be task IDs, agent drag
  /// tokens, file URLs, or links; web views drag plain URLs. The drag preview
  /// is a card centered on the pointer, so the card lands centered on the drop
  /// point. Several items fan out from there.
  private func accept(_ providers: [NSItemProvider], at location: CGPoint) -> Bool {
    let model = model
    var accepted = false
    for (index, provider) in providers.enumerated() {
      let point = CGPoint(
        x: location.x - BulletinBoardMetrics.cardWidth / 2 + Double(index) * 22,
        y: location.y - BulletinBoardMetrics.cardHeight / 2 + Double(index) * 22)
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
      } else if provider.canLoadObject(ofClass: URL.self) {
        accepted = true
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
          guard let url else { return }
          Task { @MainActor in model.pinLinkToBulletinBoard(url, at: point) }
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

enum BulletinBoardColors {
  /// A dark gray board in both appearances, so cards read as pinned paper.
  static let board = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.36, alpha: 1)
  })
  /// Cards sit lighter than the board in both appearances.
  static let card = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(white: 0.24, alpha: 1) : NSColor(white: 0.98, alpha: 1)
  })
}

extension BulletinPinKind {
  var pinColor: Color {
    switch self {
    case .task: .red
    case .agent: .blue
    case .file: .orange
    case .folder: .green
    case .link: .purple
    }
  }

  var systemImage: String {
    switch self {
    case .task: "checklist"
    case .agent: "terminal"
    case .file: "doc"
    case .folder: "folder"
    case .link: "link"
    }
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

/// The face every board card shares, also used as the drag preview so an item
/// shrinks to its card size as soon as a drag starts.
struct BulletinCardFace: View {
  let kind: BulletinPinKind
  let kindLabel: String
  let title: String
  let detail: String
  var isCleanedUp = false
  /// After a click: a spinner while opening, then the result in place of the detail.
  var feedback: BulletinPinFeedback?

  private var feedbackColor: Color {
    switch feedback?.state {
    case .failed: .orange
    case .done: .green
    default: .accentColor
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Image(systemName: kind.systemImage).font(.system(size: 9, weight: .semibold))
        Text(kindLabel).font(.system(size: 9, weight: .semibold)).lineLimit(1)
      }
      .foregroundStyle(.secondary)
      Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(feedback?.state == .failed ? 1 : 2)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
      if let feedback {
        HStack(spacing: 4) {
          switch feedback.state {
          case .opening: ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10)
          case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
          case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9))
          }
          Text(feedback.message).font(.system(size: 10, weight: .medium))
            .lineLimit(feedback.state == .failed ? 2 : 1).truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(feedbackColor)
        .help(feedback.message)
        .transition(.opacity)
      } else {
        Text(detail).font(.system(size: 10)).foregroundStyle(isCleanedUp ? Color.orange : Color.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
    }
    .padding(.horizontal, 10).padding(.top, 11).padding(.bottom, 7)
    .frame(width: BulletinBoardMetrics.cardWidth, height: BulletinBoardMetrics.cardHeight, alignment: .topLeading)
    // Cleaned-up cards stay opaque so overlapping cards never show through.
    .opacity(isCleanedUp ? 0.5 : 1)
    .background(BulletinBoardColors.card, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(
      isCleanedUp ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1),
      style: StrokeStyle(lineWidth: isCleanedUp ? 1 : 0.5, dash: isCleanedUp ? [4, 3] : [])))
    .overlay {
      if feedback != nil {
        RoundedRectangle(cornerRadius: 8).stroke(feedbackColor.opacity(0.85), lineWidth: 1.5)
      }
    }
    .animation(.easeInOut(duration: 0.2), value: feedback)
    .shadow(color: .black.opacity(0.35), radius: 3, y: 2)
    .overlay(alignment: .top) {
      PinHead(color: kind.pinColor)
        .frame(width: BulletinBoardMetrics.pinSize, height: BulletinBoardMetrics.pinSize)
        .offset(y: -BulletinBoardMetrics.pinSize / 2 + 1)
    }
  }
}

private struct BulletinPinCard: View {
  let model: QueueViewModel
  let pin: BulletinPin
  let isCleanedUp: Bool
  var feedback: BulletinPinFeedback?

  private var ticket: DashboardTicket? { model.bulletinTicket(for: pin) }
  private var agent: TaskSubtask? { model.bulletinAgent(for: pin) }

  private var kindLabel: String {
    switch pin.kind {
    case .task: pin.taskID ?? "Task"
    case .agent: "Agent · \(pin.taskID ?? "")"
    case .file: "File"
    case .folder: "Folder"
    case .link: "Link"
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
    case .link:
      return pin.url.flatMap { URL(string: $0)?.host } ?? pin.url ?? ""
    }
  }

  var body: some View {
    let title = model.bulletinPinTitle(pin)
    BulletinCardFace(kind: pin.kind, kindLabel: kindLabel, title: title, detail: detail, isCleanedUp: isCleanedUp,
                     feedback: feedback)
      .contentShape(RoundedRectangle(cornerRadius: 8))
      .contextMenu {
        Button(pin.kind == .task ? "Open agents" : "Open",
               systemImage: pin.kind == .task ? "terminal" : "arrow.up.forward.square") { model.openBulletinPin(pin) }
          .disabled(isCleanedUp && pin.kind != .file && pin.kind != .folder)
        if pin.kind == .task {
          Button("Show in queue", systemImage: "list.bullet") { model.revealBulletinTask(pin) }
            .disabled(ticket == nil)
        }
        if let path = pin.path {
          Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
          }
          .disabled(isCleanedUp)
        }
        if let url = pin.url {
          Button("Copy link", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url, forType: .string)
          }
        }
        Divider()
        Button("Unpin", systemImage: "pin.slash") { model.unpinBulletinPin(pin.id) }
      }
      .help(pin.kind == .task ? "\(title): click to open its agents" : pin.path ?? pin.url ?? title)
      .accessibilityElement(children: .combine)
      .accessibilityLabel("\(kindLabel), \(title), \(detail)")
      .accessibilityHint(pin.kind == .task
        ? "Opens the task's agents. Drag to move it on the board."
        : "Opens the pinned item. Drag to move it on the board.")
      .accessibilityAction(named: "Unpin") { model.unpinBulletinPin(pin.id) }
  }
}

/// What a dragged item becomes on the board: the string the board reads, plus
/// what its compact card preview shows.
struct BulletinDragItem {
  let value: String
  let kind: BulletinPinKind
  let kindLabel: String
  let title: String
  let detail: String

  static func task(_ ticket: DashboardTicket) -> Self {
    Self(value: ticket.id, kind: .task, kindLabel: ticket.id, title: ticket.title, detail: ticket.status)
  }

  static func agent(_ agent: TaskSubtask, ticketID: String) -> Self {
    Self(value: BulletinDragToken.agent(taskID: ticketID, subtaskID: agent.id), kind: .agent,
         kindLabel: "Agent · \(ticketID)", title: agent.title, detail: agent.status.rawValue)
  }

  static func file(_ url: URL, title: String? = nil) -> Self {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
    let folder = exists ? isDirectory.boolValue : url.hasDirectoryPath
    return Self(value: url.absoluteString, kind: folder ? .folder : .file, kindLabel: folder ? "Folder" : "File",
                title: title ?? url.lastPathComponent,
                detail: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
  }

  /// A file path or URL string as the app stores it in links and evidence.
  static func resource(_ raw: String, title: String? = nil) -> Self? {
    guard let url = ResourceLocator.url(for: raw) else { return nil }
    if url.isFileURL { return file(url, title: title) }
    guard url.scheme != nil else { return nil }
    return Self(value: url.absoluteString, kind: .link, kindLabel: "Link",
                title: title ?? QueueViewModel.linkTitle(url), detail: url.host ?? url.absoluteString)
  }
}

extension View {
  /// Lets the item be dragged onto the bulletin board. The drag shows the
  /// item's small board card, so placement is easy to judge.
  @ViewBuilder func bulletinDraggable(_ item: BulletinDragItem?) -> some View {
    if let item {
      draggable(item.value) {
        BulletinCardFace(kind: item.kind, kindLabel: item.kindLabel, title: item.title, detail: item.detail)
          .padding(8)
      }
    } else {
      self
    }
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
