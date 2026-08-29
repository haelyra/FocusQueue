import AppKit
import Darwin
import FocusQueueCore
import SwiftUI

@main struct FocusQueueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = QueueViewModel()
    private var panel: FocusPanel?
    private var statusItem: NSStatusItem?
    private var currentPlacement: QueueWindowPlacement = .upperRight

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        model.placementHandler = { [weak self] placement in self?.positionPanel(placement, animated: true) }
        model.quitHandler = { NSApplication.shared.terminate(nil) }

        createPanel()
        createStatusItem()
        positionPanel(.upperRight, animated: false)
        panel?.orderFrontRegardless()

        Task { [weak self] in
            guard let self else { return }
            await model.bootstrap()
            if let snapshot = model.windowSnapshot, let savedScreen = screen(containing: snapshot) {
                currentPlacement = snapshot.placement
                if var restoredFrame = panel?.frame {
                    restoredFrame.size.width = snapshot.width
                    panel?.setFrame(restoredFrame, display: false)
                }
                positionPanel(snapshot.placement, on: savedScreen, animated: false)
            } else {
                positionPanel(model.config.defaultPlacement, animated: false)
            }
            panel?.orderFrontRegardless()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func windowDidMove(_ notification: Notification) { saveWindowFrame() }

    func windowDidResize(_ notification: Notification) { saveWindowFrame() }

    @objc private func showPanel() {
        guard let panel else { return }
        if !panel.frame.intersects(activeScreen().visibleFrame) { positionPanel(currentPlacement, animated: false) }
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

    @objc private func hidePanel() { panel?.orderOut(nil) }

    @objc private func openConfiguration() { model.openConfiguration() }

    @objc private func restartApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "gui/\(getuid())/com.haelyra.ecc-focus-queue"]
        do { try process.run() } catch {
            let alert = NSAlert()
            alert.messageText = "Could not restart ECC Focus Queue"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quitApplication() { NSApplication.shared.terminate(nil) }

    private func createPanel() {
        let panel = FocusPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 780), styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
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
        panel.maxSize = NSSize(width: 620, height: 10_000)
        panel.delegate = self
        let hostingView = NSHostingView(rootView: QueueView(model: model))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.panel = panel
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "ECC Focus Queue")
        item.button?.toolTip = "ECC Focus Queue"

        let menu = NSMenu()
        let showItem = NSMenuItem(title: "Show ECC Focus Queue", action: #selector(showPanel), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        let hideItem = NSMenuItem(title: "Hide ECC Focus Queue", action: #selector(hidePanel), keyEquivalent: "")
        hideItem.target = self
        menu.addItem(hideItem)
        let restartItem = NSMenuItem(title: "Restart ECC Focus Queue", action: #selector(restartApplication), keyEquivalent: "")
        restartItem.target = self
        menu.addItem(restartItem)
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
        let quitItem = NSMenuItem(title: "Quit ECC Focus Queue", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    private func positionPanel(_ placement: QueueWindowPlacement, on requestedScreen: NSScreen? = nil, animated: Bool) {
        guard let panel else { return }
        let screenFrame = (requestedScreen ?? activeScreen()).visibleFrame
        let margin: CGFloat = 12
        let availableWidth = max(400, screenFrame.width - (margin * 2))
        let width = min(max(panel.frame.width, 400), min(620, availableWidth))
        let height = max(480, screenFrame.height - (margin * 2))
        var frame = NSRect(x: screenFrame.minX + margin, y: screenFrame.minY + margin, width: width, height: height)

        switch placement {
        case .upperLeft: frame.origin.x = screenFrame.minX + margin
        case .upperRight: frame.origin.x = screenFrame.maxX - width - margin
        case .center: frame.origin.x = screenFrame.midX - (width / 2)
        }

        currentPlacement = placement
        panel.setFrame(frame, display: true, animate: animated)
        saveWindowFrame()
    }

    private func activeScreen() -> NSScreen {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? panel?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func saveWindowFrame() {
        guard let frame = panel?.frame else { return }
        model.saveWindow(WindowSnapshot(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height, placement: currentPlacement))
    }

    private func screen(containing snapshot: WindowSnapshot) -> NSScreen? {
        let frame = Self.rect(from: snapshot)
        return NSScreen.screens.map { ($0, $0.visibleFrame.intersection(frame).width) }.filter { $0.1 >= 120 }.max { $0.1 < $1.1 }?.0
    }

    private static func rect(from snapshot: WindowSnapshot) -> NSRect { NSRect(x: snapshot.x, y: snapshot.y, width: snapshot.width, height: snapshot.height) }
}

final class FocusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
