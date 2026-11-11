import Foundation
import WebKit

/// Focus Queue previews local documents offline. The live HTML canvas and the
/// static document viewer never reach the network: every request that leaves
/// the machine (scripts, styles, fonts, images, media, frames, fetch/XHR,
/// WebSocket, EventSource, beacons, form posts, and loopback services) is
/// blocked by a WebKit content rule list before the load starts. Only `file:`,
/// `data:`, `blob:`, and `about:` URLs load, so self-contained mockups and their
/// local sibling assets still render and their inline scripts still run.
///
/// Content rules do not cover WebRTC, whose STUN/TURN traffic could carry page
/// data out, so pages that may run scripts also lose `RTCPeerConnection`.
/// A preview never loads until the rule list is installed on its web view.
@MainActor
enum OfflineWebContent {
  static let ruleListIdentifier = "focus-queue-offline-preview-v1"
  /// The only URL schemes an offline preview may load.
  nonisolated static let localSchemes: Set<String> = ["file", "data", "blob", "about"]

  /// Block everything, then exempt the local schemes. WebKit's rule regex has
  /// no alternation, so each exemption is its own rule.
  static let encodedRuleList: String = {
    var rules: [[String: Any]] = [["trigger": ["url-filter": ".*"], "action": ["type": "block"]]]
    for scheme in localSchemes.sorted() {
      rules.append(["trigger": ["url-filter": "^\(scheme):"], "action": ["type": "ignore-previous-rules"]])
    }
    let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }()

  /// Removes WebRTC from every frame before page scripts run. Frames created by
  /// script (about:blank, srcdoc, data:, blob:) receive it too.
  static let realtimeConnectionBlocker = """
    (() => {
      for (const name of ["RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCIceTransport"]) {
        try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
      }
    })();
    """

  private static var compiled: WKContentRuleList?
  private static var compiling: Task<WKContentRuleList, Error>?
  private static let installedControllers = NSHashTable<WKUserContentController>.weakObjects()

  enum Failure: LocalizedError {
    case unavailable
    var errorDescription: String? {
      "Focus Queue could not turn on offline mode for this preview, so it was not opened."
    }
  }

  /// Applies the offline policy to a configuration before its web view exists.
  /// The rule list joins synchronously when it is already compiled; otherwise
  /// `load(_:in:)` installs it before the first document load.
  static func configure(_ configuration: WKWebViewConfiguration, allowsPageScripts: Bool) {
    if let compiled { install(compiled, on: configuration.userContentController) }
    guard allowsPageScripts else { return }
    disablePeerConnections(configuration.preferences)
    configuration.userContentController.addUserScript(WKUserScript(
      source: realtimeConnectionBlocker, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
  }

  /// Loads a local file once the offline rule list is in place. Returns false
  /// without loading for any URL that is not a local file. `onFailure` reports
  /// a rule list that could not be compiled; the document then stays unloaded.
  @discardableResult
  static func load(_ fileURL: URL, readAccess: URL, in webView: WKWebView,
                   shouldLoad: @escaping @MainActor () -> Bool = { true },
                   onFailure: @escaping @MainActor (Error) -> Void = { _ in }) -> Bool {
    guard fileURL.isFileURL, readAccess.isFileURL else { return false }
    let controller = webView.configuration.userContentController
    if installedControllers.contains(controller) {
      webView.loadFileURL(fileURL, allowingReadAccessTo: readAccess)
      return true
    }
    Task { @MainActor [weak webView] in
      do {
        let list = try await ruleList()
        guard let webView, shouldLoad() else { return }
        install(list, on: webView.configuration.userContentController)
        webView.loadFileURL(fileURL, allowingReadAccessTo: readAccess)
      } catch {
        onFailure(error)
      }
    }
    return true
  }

  static func isInstalled(on controller: WKUserContentController) -> Bool {
    installedControllers.contains(controller)
  }

  /// Compiles the shared rule list once per process.
  static func ruleList() async throws -> WKContentRuleList {
    if let compiled { return compiled }
    if let compiling { return try await compiling.value }
    let task = Task { @MainActor () throws -> WKContentRuleList in
      guard let store = WKContentRuleListStore.default(),
            let list = try await store.compileContentRuleList(
              forIdentifier: ruleListIdentifier, encodedContentRuleList: encodedRuleList)
      else { throw Failure.unavailable }
      return list
    }
    compiling = task
    do {
      let list = try await task.value
      compiled = list
      compiling = nil
      return list
    } catch {
      compiling = nil
      throw error
    }
  }

  /// Starts compiling early so the first preview can load without waiting.
  static func warmUp() {
    guard compiled == nil, compiling == nil else { return }
    Task { @MainActor in _ = try? await ruleList() }
  }

  private static func install(_ list: WKContentRuleList, on controller: WKUserContentController) {
    guard !installedControllers.contains(controller) else { return }
    controller.add(list)
    installedControllers.add(controller)
  }

  /// WebKit's engine-level WebRTC switch. It is not public API, so it is used
  /// only when present; the page-world blocker above covers the rest.
  private static func disablePeerConnections(_ preferences: WKPreferences) {
    let selector = NSSelectorFromString("_setPeerConnectionEnabled:")
    guard preferences.responds(to: selector) else { return }
    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(preferences.method(for: selector), to: Setter.self)(preferences, selector, false)
  }
}
