import AppKit

/// Triggers OpenSuperWhisper recording through a distributed notification the
/// patched OpenSuperWhisper build observes. Stock builds ignore it; the task
/// sheet still opens, so a missing recorder degrades gracefully.
enum SuperWhisperBridge {
  static let toggleNotification =
    Notification.Name("com.haelyra.ecc-focus-queue.osw.toggleRecord")
  static let bundleID = "ru.starmel.OpenSuperWhisper"

  static func toggleRecording() async {
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      else { return }
      try? await NSWorkspace.shared.openApplication(
        at: url, configuration: NSWorkspace.OpenConfiguration())
      try? await Task.sleep(nanoseconds: 1_500_000_000)
    }
    DistributedNotificationCenter.default().postNotificationName(
      toggleNotification, object: nil, userInfo: nil, deliverImmediately: true)
  }
}
