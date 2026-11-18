import AppKit
import FocusQueueCore
import SwiftUI

/// The detached bulletin board: its own window that can sit anywhere, on any
/// display. Each project reopens it at the frame it last had. Unpinned, it
/// floats above other apps on every desktop like the queue; pinned, it stays
/// where it was put on its own desktop.
@MainActor
final class BulletinBoardWindowController: NSObject, NSWindowDelegate {
  private let model: QueueViewModel
  private(set) var window: BulletinBoardPanel?
  private var shownKey: String?
  private var isApplying = false
  private var saveTask: Task<Void, Never>?

  static let defaultSize = NSSize(width: 520, height: 560)

  init(model: QueueViewModel) {
    self.model = model
  }

  /// Shows, updates, or closes the window to match the model's request.
  func apply(_ request: BulletinBoardWindowRequest?) {
    guard let request else {
      close()
      return
    }
    let window = window ?? makeWindow()
    self.window = window
    isApplying = true
    defer { isApplying = false }
    window.title = request.title
    applyPinning(request.pinned, to: window)
    // A new project, or a first show, moves the window to that project's spot.
    if shownKey != request.key || !window.isVisible {
      window.setFrame(Self.frame(for: request.frame, near: NSScreen.main), display: false)
      shownKey = request.key
    }
    window.orderFrontRegardless()
  }

  private func close() {
    saveTask?.cancel()
    guard let window, window.isVisible else { return }
    isApplying = true
    window.orderOut(nil)
    isApplying = false
  }

  private func makeWindow() -> BulletinBoardPanel {
    let window = BulletinBoardPanel(
      contentRect: NSRect(origin: .zero, size: Self.defaultSize),
      styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.hidesOnDeactivate = false
    window.becomesKeyOnlyIfNeeded = true
    window.minSize = NSSize(width: 320, height: 300)
    window.tabbingMode = .disallowed
    window.delegate = self
    window.contentView = NSHostingView(rootView: BulletinBoardWindowContent(model: model))
    return window
  }

  private func applyPinning(_ pinned: Bool, to window: NSPanel) {
    window.level = pinned ? .normal : .floating
    window.isFloatingPanel = !pinned
    window.collectionBehavior = pinned
      ? [.managed, .fullScreenAuxiliary]
      : [.canJoinAllSpaces, .fullScreenAuxiliary]
  }

  /// The saved frame when it is still on a connected display; otherwise the
  /// default size, centered on the main display.
  static func frame(for saved: BulletinBoardFrame?, near screen: NSScreen?, screens: [NSScreen] = NSScreen.screens) -> NSRect {
    if let saved {
      let rect = NSRect(x: saved.x, y: saved.y, width: max(320, saved.width), height: max(300, saved.height))
      let center = NSPoint(x: rect.midX, y: rect.maxY - 20)
      if screens.contains(where: { $0.visibleFrame.contains(center) }) { return rect }
    }
    let visible = (screen ?? screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return NSRect(x: visible.midX - defaultSize.width / 2, y: visible.midY - defaultSize.height / 2,
                  width: defaultSize.width, height: defaultSize.height)
  }

  // MARK: - NSWindowDelegate

  func windowDidMove(_ notification: Notification) { scheduleFrameSave() }
  func windowDidResize(_ notification: Notification) { scheduleFrameSave() }

  func windowWillClose(_ notification: Notification) {
    guard !isApplying else { return }
    saveFrameNow()
    model.bulletinBoardWindowDidClose()
  }

  private func scheduleFrameSave() {
    guard !isApplying, window?.isVisible == true else { return }
    saveTask?.cancel()
    saveTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled else { return }
      self?.saveFrameNow()
    }
  }

  private func saveFrameNow() {
    guard let window, let key = shownKey else { return }
    model.bulletinBoardWindowFrameChanged(window.frame, key: key)
  }
}

final class BulletinBoardPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

/// The window's content, styled like the queue.
private struct BulletinBoardWindowContent: View {
  let model: QueueViewModel

  var body: some View {
    BulletinBoardView(model: model, mode: .window)
      .padding(10)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(nsColor: .windowBackgroundColor))
      .preferredColorScheme(model.appearance == .dark ? .dark : .light)
  }
}
