import AppKit
import UniformTypeIdentifiers

/// Whether Finder opens Markdown files in Focus Queue, and the switch that
/// makes it so. Launch Services keeps the choice per user; Focus Queue never
/// changes it without the user pressing the Settings button.
@MainActor
enum MarkdownDefaultApplication {
  static let contentType = UTType("net.daringfireball.markdown") ?? .plainText

  /// The app Finder opens Markdown files with today, if any.
  static var currentHandler: URL? { NSWorkspace.shared.urlForApplication(toOpen: contentType) }

  static var currentHandlerName: String? {
    currentHandler.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
  }

  /// The app that opened Markdown before Focus Queue took over; the viewer's
  /// "open in another app" button keeps using it.
  static let previousHandlerKey = "markdownPreviousHandler"

  /// True when the default handler is this app (matched by bundle ID, so
  /// a reinstall at the same identifier still counts).
  static var isFocusQueueDefault: Bool { currentHandler.map(isThisApp) ?? false }

  static func isThisApp(_ application: URL) -> Bool {
    guard let identifier = Bundle.main.bundleIdentifier else { return false }
    return Bundle(url: application)?.bundleIdentifier == identifier
  }

  /// Opens a file outside Focus Queue. When Focus Queue is that file's default
  /// app, plain `open` would loop back here, so it uses the previous default or
  /// the first other app that can open the file, else reveals it in Finder.
  static func openOutside(_ url: URL) {
    let workspace = NSWorkspace.shared
    guard let handler = workspace.urlForApplication(toOpen: url), isThisApp(handler) else {
      workspace.open(url); return
    }
    let previous = UserDefaults.standard.string(forKey: previousHandlerKey)
      .map { URL(fileURLWithPath: $0) }
      .flatMap { FileManager.default.fileExists(atPath: $0.path) && !isThisApp($0) ? $0 : nil }
    guard let application = previous ?? workspace.urlsForApplications(toOpen: url).first(where: { !isThisApp($0) }) else {
      workspace.activateFileViewerSelecting([url]); return
    }
    workspace.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
  }

  /// Only a bundled app can be a document handler; `swift run` builds cannot.
  static var canBecomeDefault: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

  static func makeFocusQueueDefault() async throws {
    if let handler = currentHandler, !isThisApp(handler) {
      UserDefaults.standard.set(handler.path, forKey: previousHandlerKey)
    }
    try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: contentType)
  }
}
