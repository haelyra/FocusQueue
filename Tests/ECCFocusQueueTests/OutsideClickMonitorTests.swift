import AppKit
import Testing

@testable import ECCFocusQueue

@Suite("Task search outside clicks")
@MainActor
struct OutsideClickMonitorTests {
  private func hostedMonitor() -> (NSPanel, OutsideClickMonitor.MonitorView) {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let monitor = OutsideClickMonitor.MonitorView(frame: NSRect(x: 20, y: 250, width: 300, height: 27))
    container.addSubview(monitor)
    panel.contentView = container
    return (panel, monitor)
  }

  @Test("A click outside the field ends editing; clicks inside or elsewhere do not")
  func outsideClickEndsEditing() {
    let (panel, monitor) = hostedMonitor()
    var outsideClicks = 0
    monitor.onOutsideClick = { outsideClicks += 1 }
    monitor.isActive = true
    #expect(monitor.isMonitoring)

    monitor.handleClick(at: NSPoint(x: 100, y: 260), in: panel)
    #expect(outsideClicks == 0, "a click on the field keeps the cursor")

    let otherPanel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.borderless],
      backing: .buffered, defer: false)
    monitor.handleClick(at: NSPoint(x: 100, y: 100), in: otherPanel)
    #expect(outsideClicks == 0, "another window's clicks are covered by the key-status observer")

    monitor.handleClick(at: NSPoint(x: 100, y: 100), in: panel)
    #expect(outsideClicks == 1)
  }

  @Test("The window losing key status ends editing")
  func resigningKeyEndsEditing() {
    let (panel, monitor) = hostedMonitor()
    var outsideClicks = 0
    monitor.onOutsideClick = { outsideClicks += 1 }
    monitor.isActive = true

    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
    #expect(outsideClicks == 1)
  }

  @Test("The monitor runs only while the field is focused and in a window")
  func monitorLifecycle() {
    let (panel, monitor) = hostedMonitor()
    var outsideClicks = 0
    monitor.onOutsideClick = { outsideClicks += 1 }
    #expect(!monitor.isMonitoring)

    monitor.isActive = true
    #expect(monitor.isMonitoring)
    monitor.isActive = false
    #expect(!monitor.isMonitoring)

    monitor.isActive = true
    monitor.removeFromSuperview()
    #expect(!monitor.isMonitoring)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
    #expect(outsideClicks == 0)
  }
}
