import AppKit

/// Coordinates with OpenSuperWhisper through distributed notifications the
/// patched OpenSuperWhisper build observes. Stock builds ignore them; the task
/// sheet still opens, so a missing recorder degrades gracefully.
enum SuperWhisperBridge {
  static let toggleNotification =
    Notification.Name("com.haelyra.ecc-focus-queue.osw.toggleRecord")
  static let recordingStateNotification =
    Notification.Name("com.haelyra.ecc-focus-queue.osw.recordingStateChanged")
  static let bundleID = "ru.starmel.OpenSuperWhisper"

  /// Brings OpenSuperWhisper up so its own hotkey can record. Only a
  /// cold-launched OSW gets the toggle notification: a running OSW already
  /// received the physical Right Option press, and toggling it would stop
  /// the recording it just started.
  static func prepareRecorder() async {
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    if running.isEmpty {
      guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      else { return }
      try? await NSWorkspace.shared.openApplication(
        at: url, configuration: NSWorkspace.OpenConfiguration())
      try? await Task.sleep(nanoseconds: 1_500_000_000)
      DistributedNotificationCenter.default().postNotificationName(
        toggleNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
  }
}
