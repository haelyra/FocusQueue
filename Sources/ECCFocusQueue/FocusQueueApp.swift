import AppKit
import FocusQueueCore
import SwiftUI

@main
struct FocusQueueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = QueueViewModel()
    private var panel: FocusPanel?
    private var statusItem: NSStatusItem?
    private var currentPlacement: QueueWindowPlacement = .upperRight

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.placementHandler = { [weak self] placement in
            self?.positionPanel(placement, animated: true)
        }
        model.quitHandler = {
            NSApplication.shared.terminate(nil)
        }

        createPanel()
        createStatusItem()
        positionPanel(.upperRight, animated: false)
        panel?.orderFrontRegardless()

        Task { [weak self] in
            guard let self else { return }
            await model.bootstrap()
            if let snapshot = model.windowSnapshot, frameIsVisible(snapshot) {
                currentPlacement = snapshot.placement
                var restoredFrame = Self.rect(from: snapshot)
                restoredFrame.size.height = max(restoredFrame.height, 760)
                panel?.setFrame(restoredFrame, display: true)
            } else {
                positionPanel(model.config.defaultPlacement, animated: false)
            }
            panel?.orderFrontRegardless()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    @objc private func showPanel() {
        guard let panel else { return }
        if !panel.frame.intersects(activeScreen().visibleFrame) {
            positionPanel(currentPlacement, animated: false)
        }
        panel.orderFrontRegardless()
    }

    @objc private func centerPanel() {
        positionPanel(.center, animated: true)
        panel?.orderFrontRegardless()
    }

    @objc private func placeUpperLeft() {
        positionPanel(.upperLeft, animated: true)
        panel?.orderFrontRegardless()
    }

    @objc private func placeUpperRight() {
        positionPanel(.upperRight, animated: true)
        panel?.orderFrontRegardless()
    }

    @objc private func hidePanel() {
        panel?.orderOut(nil)
    }

    @objc private func openConfiguration() {
        model.openConfiguration()
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func createPanel() {
        let panel = FocusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 780),
            styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "ECC Focus Queue"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.minSize = NSSize(width: 400, height: 500)
        panel.maxSize = NSSize(width: 620, height: 1_100)
        panel.delegate = self
        let hostingView = NSHostingView(rootView: QueueView(model: model))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.panel = panel
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Focus Queue")

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show Focus Queue", action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let hideItem = NSMenuItem(title: "Hide Focus Queue", action: #selector(hidePanel), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        menu.addItem(.separator())
        let leftItem = NSMenuItem(title: "Place Upper Left", action: #selector(placeUpperLeft), keyEquivalent: "")
        leftItem.target = self
        menu.addItem(leftItem)
        let rightItem = NSMenuItem(title: "Place Upper Right", action: #selector(placeUpperRight), keyEquivalent: "")
        rightItem.target = self
        menu.addItem(rightItem)
        let centerItem = NSMenuItem(title: "Center on Active Display", action: #selector(centerPanel), keyEquivalent: "")
        centerItem.target = self
        menu.addItem(centerItem)
        menu.addItem(.separator())
        let configItem = NSMenuItem(title: "Open Config", action: #selector(openConfiguration), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func positionPanel(_ placement: QueueWindowPlacement, animated: Bool) {
        guard let panel else { return }
        let screenFrame = activeScreen().visibleFrame
        let margin: CGFloat = 16
        var origin = panel.frame.origin

        switch placement {
        case .upperLeft:
            origin = NSPoint(
                x: screenFrame.minX + margin,
                y: screenFrame.maxY - panel.frame.height - margin
            )
        case .upperRight:
            origin = NSPoint(
                x: screenFrame.maxX - panel.frame.width - margin,
                y: screenFrame.maxY - panel.frame.height - margin
            )
        case .center:
            origin = NSPoint(
                x: screenFrame.midX - panel.frame.width / 2,
                y: screenFrame.midY - panel.frame.height / 2
            )
        }

        currentPlacement = placement
        if animated {
            panel.animator().setFrameOrigin(origin)
        } else {
            panel.setFrameOrigin(origin)
        }
        saveWindowFrame()
    }

    private func activeScreen() -> NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? panel?.screen
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func saveWindowFrame() {
        guard let frame = panel?.frame else { return }
        model.saveWindow(WindowSnapshot(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height,
            placement: currentPlacement
        ))
    }

    private func frameIsVisible(_ snapshot: WindowSnapshot) -> Bool {
        let frame = Self.rect(from: snapshot)
        return NSScreen.screens.contains { $0.visibleFrame.intersection(frame).width >= 120 }
    }

    private static func rect(from snapshot: WindowSnapshot) -> NSRect {
        NSRect(x: snapshot.x, y: snapshot.y, width: snapshot.width, height: snapshot.height)
    }
}

final class FocusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
