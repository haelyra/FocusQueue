import FocusQueueCore
import Foundation
import Network
import Testing
import WebKit

@testable import ECCFocusQueue

/// Counts every TCP connection and UDP datagram a page sends to loopback.
private final class LoopbackRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var tcp = 0
  private var udp = 0
  private let queue = DispatchQueue(label: "offline-web-loopback")
  private var listeners: [NWListener] = []
  private(set) var tcpPort: UInt16 = 0
  private(set) var udpPort: UInt16 = 0

  var counts: (tcp: Int, udp: Int) { lock.withLock { (tcp, udp) } }
  private func countTCP() { lock.withLock { tcp += 1 } }
  private func countUDP() { lock.withLock { udp += 1 } }

  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }
    func resume() { lock.withLock { continuation?.resume(); continuation = nil } }
  }

  func start() async throws {
    let tcpListener = try NWListener(using: .tcp, on: .any)
    let udpListener = try NWListener(using: .udp, on: .any)
    let queue = self.queue
    tcpListener.newConnectionHandler = { [self] connection in
      countTCP()
      connection.start(queue: queue)
      connection.cancel()
    }
    udpListener.newConnectionHandler = { [self] connection in
      connection.start(queue: queue)
      connection.receiveMessage { [self] _, _, _, _ in countUDP() }
    }
    listeners = [tcpListener, udpListener]
    for listener in listeners {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let once = Once(continuation)
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready, .failed, .cancelled: once.resume()
          default: break
          }
        }
        listener.start(queue: queue)
      }
    }
    tcpPort = tcpListener.port?.rawValue ?? 0
    udpPort = udpListener.port?.rawValue ?? 0
  }

  func stop() { listeners.forEach { $0.cancel() } }
}

@Suite("Offline previews: no network requests from canvases or static documents")
@MainActor
struct OfflineWebContentTests {
  /// A page that tries every common way to reach the network.
  private func hostilePage(tcp: UInt16, udp: UInt16) -> String {
    let base = "http://127.0.0.1:\(tcp)"
    return """
      <!doctype html><html><head>
      <link rel="stylesheet" href="\(base)/style.css">
      <script src="\(base)/remote.js"></script>
      <style>@font-face{font-family:x;src:url(\(base)/font.woff)} body{font-family:x}</style>
      </head><body>
      <img src="\(base)/pixel.png"><iframe src="\(base)/frame"></iframe>
      <img id="local" src="sibling.png">
      <form id="f" action="\(base)/form" method="post"><input name="q" value="secret"></form>
      <script>
      const probe = window.__probe = { inline: 'ran' };
      document.getElementById('local').addEventListener('load', () => probe.sibling = 'loaded');
      fetch('\(base)/fetch?d=secret').catch(() => probe.fetch = 'blocked');
      const xhr = new XMLHttpRequest(); xhr.open('GET', '\(base)/xhr'); xhr.onerror = () => probe.xhr = 'blocked'; xhr.send();
      try { const ws = new WebSocket('ws://127.0.0.1:\(tcp)/ws'); ws.onerror = () => probe.ws = 'blocked'; } catch (e) { probe.ws = 'blocked'; }
      try { probe.beacon = navigator.sendBeacon('\(base)/beacon', 'secret'); } catch (e) { probe.beacon = false; }
      try { new EventSource('\(base)/events'); } catch (e) {}
      try { new Worker('\(base)/worker.js'); } catch (e) {}
      probe.rtc = typeof RTCPeerConnection;
      const frame = document.createElement('iframe'); document.body.appendChild(frame);
      probe.frameRTC = typeof frame.contentWindow.RTCPeerConnection;
      try {
        const pc = new frame.contentWindow.RTCPeerConnection({ iceServers: [{ urls: 'stun:127.0.0.1:\(udp)' }] });
        pc.createDataChannel('x'); pc.createOffer().then(o => pc.setLocalDescription(o));
      } catch (e) {}
      try { document.getElementById('f').submit(); } catch (e) {}
      </script></body></html>
      """
  }

  private func fixture(_ html: String) throws -> (root: URL, page: URL) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("offline-web-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let page = root.appendingPathComponent("preview.html")
    try Data(html.utf8).write(to: page)
    // 1x1 transparent PNG beside the page: local assets must keep working.
    let png = Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!
    try png.write(to: root.appendingPathComponent("sibling.png"))
    return (root, page)
  }

  @Test("The live canvas blocks every network channel but keeps inline scripts and local assets")
  func canvasIsOffline() async throws {
    let recorder = LoopbackRecorder()
    try await recorder.start()
    defer { recorder.stop() }
    let (root, page) = try fixture(hostilePage(tcp: recorder.tcpPort, udp: recorder.udpPort))
    defer { try? FileManager.default.removeItem(at: root) }

    let store = UICanvasStore(root: root.appendingPathComponent("store", isDirectory: true))
    guard case .opened(let session) = try store.open(
      file: page.path, taskID: "FOC-119", title: "Offline", viewport: "desktop", reopen: false, agentName: "Claude Code")
    else { Issue.record("open refused"); return }
    let model = UICanvasModel(store: store, taskID: "FOC-119", key: session.key)
    let coordinator = UICanvasWebStage.Coordinator(model: model)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                         configuration: UICanvasWebStage.configuration(coordinator: coordinator))
    view.navigationDelegate = coordinator
    view.uiDelegate = coordinator
    defer { UICanvasWebStage.dismantleNSView(view, coordinator: coordinator) }
    model.attach(view)

    try await eventually {
      (try? await view.evaluateJavaScript("window.__probe && window.__probe.sibling") as? String) == "loaded"
    }
    #expect(OfflineWebContent.isInstalled(on: view.configuration.userContentController))
    #expect(try await view.evaluateJavaScript("window.__probe.inline") as? String == "ran")
    #expect(try await view.evaluateJavaScript("window.__probe.rtc") as? String == "undefined")
    #expect(try await view.evaluateJavaScript("window.__probe.frameRTC") as? String == "undefined")
    // Give stray loads time to arrive before asserting none did.
    try await Task.sleep(for: .seconds(2))
    #expect(recorder.counts.tcp == 0, "No HTTP, WebSocket, beacon, font, frame, or form request may leave the canvas")
    #expect(recorder.counts.udp == 0, "No WebRTC STUN traffic may leave the canvas")
    #expect(model.loadError == nil)
  }

  @Test("The static document viewer loads local HTML offline")
  func staticViewerIsOffline() async throws {
    let recorder = LoopbackRecorder()
    try await recorder.start()
    defer { recorder.stop() }
    let (root, page) = try fixture(hostilePage(tcp: recorder.tcpPort, udp: recorder.udpPort))
    defer { try? FileManager.default.removeItem(at: root) }

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    OfflineWebContent.configure(configuration, allowsPageScripts: false)
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    #expect(OfflineWebContent.load(page, readAccess: root, in: view))
    #expect(!OfflineWebContent.load(URL(string: "https://example.com")!, readAccess: root, in: view),
            "Only local files may be loaded")
    try await eventually {
      (try? await view.evaluateJavaScript("document.getElementById('local').naturalWidth") as? Int) == 1
    }
    try await Task.sleep(for: .seconds(2))
    #expect(recorder.counts.tcp == 0)
  }

  @Test("Control: without the offline policy the same page does reach loopback")
  func controlWithoutPolicy() async throws {
    let recorder = LoopbackRecorder()
    try await recorder.start()
    defer { recorder.stop() }
    let (root, page) = try fixture(hostilePage(tcp: recorder.tcpPort, udp: recorder.udpPort))
    defer { try? FileManager.default.removeItem(at: root) }
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
    view.loadFileURL(page, allowingReadAccessTo: root)
    try await eventually { recorder.counts.tcp > 0 }
  }

  @Test("Subframes may only show local content")
  func subframePolicy() {
    let artifact = URL(fileURLWithPath: "/tmp/previews/card.html")
    #expect(!UICanvasNavigationPolicy.allows(URL(string: "https://example.com/frame")!, isMainFrame: false, isLink: false, artifact: artifact))
    #expect(!UICanvasNavigationPolicy.allows(URL(string: "http://127.0.0.1:8080/")!, isMainFrame: false, isLink: false, artifact: artifact))
    #expect(UICanvasNavigationPolicy.allows(URL(string: "about:srcdoc")!, isMainFrame: false, isLink: false, artifact: artifact))
    #expect(UICanvasNavigationPolicy.allows(URL(string: "data:text/html,hi")!, isMainFrame: false, isLink: false, artifact: artifact))
    #expect(UICanvasNavigationPolicy.allows(URL(fileURLWithPath: "/tmp/previews/part.html"), isMainFrame: false, isLink: false, artifact: artifact))
  }

  @Test("Web links open in the browser instead of a document tab, and the loader refuses them")
  func webLinksLeaveTheApp() async throws {
    let panes = DocumentPaneState()
    var opened: [URL] = []
    panes.openWebPage = { opened.append($0) }
    panes.open(URL(string: "https://example.com/guide#intro")!)
    #expect(opened == [URL(string: "https://example.com/guide#intro")!])
    #expect(panes.tabs.isEmpty && !panes.isPresented)
    let local = URL(fileURLWithPath: "/tmp/notes.md")
    panes.open(local)
    #expect(panes.tabs == [local])
    await #expect(throws: DocumentPreviewError.self) {
      _ = try await SideDocumentLoader().load(URL(string: "https://example.com")!)
    }
  }

  @Test("The rule list blocks everything except local schemes")
  func ruleListShape() throws {
    let rules = try #require(
      JSONSerialization.jsonObject(with: Data(OfflineWebContent.encodedRuleList.utf8)) as? [[String: [String: String]]])
    #expect(rules.first?["trigger"]?["url-filter"] == ".*")
    #expect(rules.first?["action"]?["type"] == "block")
    let exempt = Set(rules.dropFirst().compactMap { $0["trigger"]?["url-filter"] })
    #expect(exempt == ["^about:", "^blob:", "^data:", "^file:"])
  }

  private func eventually(timeout: Duration = .seconds(10), _ condition: @MainActor () async -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("Timed out waiting for WebKit")
    throw CancellationError()
  }
}
