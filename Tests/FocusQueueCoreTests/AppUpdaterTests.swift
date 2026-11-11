import CryptoKit
import Darwin
import Foundation
import Testing
@testable import FocusQueueCore

private actor StubFetcher: HTTPFetching {
  private var responses: [URL: (Data, Int)]
  private(set) var requested: [URL] = []

  init(_ responses: [URL: (Data, Int)]) { self.responses = responses }

  /// Ignores `maximumBytes`, like a misbehaving fetcher; the updater must still refuse oversized bodies.
  func get(_ url: URL, accept: String?, maximumBytes: Int) async throws -> (data: Data, status: Int) {
    requested.append(url)
    guard let response = responses[url] else { return (Data(), 404) }
    return response
  }
}

/// Records commands and stands in for zipinfo, ditto and codesign. "Unpacking"
/// lays out the package the real ZIP holds, optionally with a planted link.
private actor RecordingInstallRunner: ProcessRunning {
  enum Plant: Sendable { case none, symlinkInstaller, escapingLink }

  static let packageListing = [
    "Focus Queue Beta/",
    "Focus Queue Beta/Install.command",
    "Focus Queue Beta/Focus Queue.app/",
    "Focus Queue Beta/Focus Queue.app/Contents/",
    "__MACOSX/",
    "__MACOSX/Focus Queue Beta/",
    "__MACOSX/Focus Queue Beta/._Install.command",
  ]

  private(set) var calls: [ProcessSpecification] = []
  private let listing: [String]
  private let plant: Plant
  private let codesignStatus: Int32

  init(listing: [String] = RecordingInstallRunner.packageListing, plant: Plant = .none, codesignStatus: Int32 = 0) {
    self.listing = listing
    self.plant = plant
    self.codesignStatus = codesignStatus
  }

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    calls.append(specification)
    var output = ""
    var status: Int32 = 0
    switch (specification.executable, specification.arguments.first) {
    case ("/usr/bin/zipinfo", "-1"): output = listing.map { $0 + "\n" }.joined()
    case ("/usr/bin/zipinfo", "-t"): output = "\(listing.count) files, 4096 bytes uncompressed, 2048 bytes compressed:  50.0%\n"
    case ("/usr/bin/ditto", _): try unpack(into: URL(fileURLWithPath: specification.arguments.last!))
    case ("/usr/bin/codesign", _): status = codesignStatus
    default: break
    }
    return ProcessResult(exitCode: status, standardOutput: output,
                         standardError: status == 0 ? "" : "a sealed resource is missing or invalid", timedOut: false)
  }

  private func unpack(into destination: URL) throws {
    let manager = FileManager.default
    let package = destination.appendingPathComponent("Focus Queue Beta")
    try manager.createDirectory(at: package.appendingPathComponent("Focus Queue.app/Contents"),
                                withIntermediateDirectories: true)
    try manager.createDirectory(at: package.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    let installer = package.appendingPathComponent("Install.command")
    switch plant {
    case .symlinkInstaller:
      try Data("#!/bin/zsh\n".utf8).write(to: package.appendingPathComponent("Resources/real.command"))
      try manager.createSymbolicLink(atPath: installer.path, withDestinationPath: "Resources/real.command")
    case .escapingLink:
      try Data("#!/bin/zsh\n".utf8).write(to: installer)
      // Resources/escape -> the temporary root above the update folder.
      try manager.createSymbolicLink(atPath: package.appendingPathComponent("Resources/escape").path,
                                     withDestinationPath: "../../../..")
    case .none:
      try Data("#!/bin/zsh\n".utf8).write(to: installer)
    }
  }
}

/// Runs the real archive tools but records, and never executes, the installer launch.
private actor InterceptingRunner: ProcessRunning {
  private let real = FoundationProcessRunner()
  private(set) var calls: [ProcessSpecification] = []

  func run(_ specification: ProcessSpecification) async throws -> ProcessResult {
    calls.append(specification)
    if specification.executable == "/bin/zsh" {
      return ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
    }
    return try await real.run(specification)
  }
}

/// Serves canned responses, in chunks, to a URLSession under test.
private final class ChunkedURLProtocol: URLProtocol, @unchecked Sendable {
  struct Plan { let status: Int; let contentLength: Int?; let chunks: [Data] }

  static let plans: [String: Plan] = [
    "/unknown-length": Plan(status: 200, contentLength: nil, chunks: Array(repeating: Data(count: 400), count: 5)),
    "/declared-length": Plan(status: 200, contentLength: 2_000, chunks: [Data(count: 2_000)]),
    "/small": Plan(status: 200, contentLength: nil, chunks: [Data("ok".utf8)]),
    "/missing": Plan(status: 404, contentLength: nil, chunks: [Data(count: 5_000)]),
  ]

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let url = request.url, let plan = Self.plans[url.path] else {
      client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
      return
    }
    let headers = plan.contentLength.map { ["Content-Length": String($0)] } ?? [:]
    let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

@Suite("App updater")
struct AppUpdaterTests {
  private let archive = Data("zip bytes".utf8)
  private let base = "https://github.com/haelyra/FocusQueue/releases/download"
  /// A throwaway publisher key; each test gets a fresh one.
  private let key = Curve25519.Signing.PrivateKey()
  private var trusted: [String] { [key.publicKey.rawRepresentation.base64EncodedString()] }

  private static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func archiveName(_ version: String) -> String { "FocusQueue-\(version)-beta-arm64.zip" }

  private func url(_ version: String, _ file: String) -> URL { URL(string: "\(base)/v\(version)-beta/\(file)")! }

  private func signature(_ name: String, _ digest: String, by signer: Curve25519.Signing.PrivateKey? = nil) -> Data {
    try! (signer ?? key).signature(for: ReleaseSigning.manifest(archiveName: name, sha256Hex: digest))
  }

  private func releasesJSON(latest: String, signed: Bool) -> Data {
    let name = Self.archiveName(latest)
    var assets = [
      ["name": name, "browser_download_url": url(latest, name).absoluteString],
      ["name": name + ".sha256", "browser_download_url": url(latest, name + ".sha256").absoluteString],
    ]
    if signed { assets.append(["name": name + ".sig", "browser_download_url": url(latest, name + ".sig").absoluteString]) }
    let releases: [[String: Any]] = [
      ["tag_name": "v\(latest)-beta", "name": "Focus Queue \(latest) beta", "body": "**Fixed**\n- Sign-in",
       "draft": false, "html_url": "https://github.com/haelyra/FocusQueue/releases/tag/v\(latest)-beta",
       "assets": assets],
      // A draft and a release missing its checksum are never offered.
      ["tag_name": "v0.4.0-beta", "draft": true, "assets": []],
      ["tag_name": "v0.3.5-beta", "draft": false, "assets": [
        ["name": "FocusQueue-0.3.5-beta-arm64.zip", "browser_download_url": "\(base)/v0.3.5-beta/FocusQueue-0.3.5-beta-arm64.zip"],
      ]],
      ["tag_name": "v0.3.0-beta", "draft": false, "assets": [
        ["name": "FocusQueue-0.3.0-beta-arm64.zip", "browser_download_url": "\(base)/v0.3.0-beta/FocusQueue-0.3.0-beta-arm64.zip"],
        ["name": "FocusQueue-0.3.0-beta-arm64.zip.sha256", "browser_download_url": "\(base)/v0.3.0-beta/FocusQueue-0.3.0-beta-arm64.zip.sha256"],
      ]],
    ]
    return try! JSONSerialization.data(withJSONObject: releases)
  }

  /// A release `latest` whose archive is `signed` (default: the fixture bytes),
  /// with its checksum and signature; any part can be overridden to tamper with it.
  private func responses(latest: String = "0.3.1", signed: Data? = nil, served: Data? = nil, checksum: String? = nil,
                         signature: Data? = nil, includeSignature: Bool = true) -> [URL: (Data, Int)] {
    let name = Self.archiveName(latest)
    let genuine = signed ?? archive
    let digest = Self.digest(genuine)
    var result: [URL: (Data, Int)] = [
      AppUpdater.releasesURL: (releasesJSON(latest: latest, signed: includeSignature), 200),
      url(latest, name + ".sha256"): (Data("\(checksum ?? digest)  \(name)\n".utf8), 200),
      url(latest, name): (served ?? genuine, 200),
    ]
    if includeSignature { result[url(latest, name + ".sig")] = (signature ?? self.signature(name, digest), 200) }
    return result
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func isEmpty(_ root: URL) throws -> Bool {
    try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty
  }

  @Test("Tags parse to numeric versions, and only a greater version is newer")
  func versions() {
    #expect(AppUpdater.versionComponents("v0.3.1-beta") == [0, 3, 1])
    #expect(AppUpdater.versionComponents("0.3.10") == [0, 3, 10])
    #expect(AppUpdater.versionComponents("beta") == nil)
    #expect(AppUpdater.isNewer("v0.3.10-beta", than: "0.3.9"))
    #expect(AppUpdater.isNewer("0.4", than: "0.3.9"))
    #expect(!AppUpdater.isNewer("v0.3.1-beta", than: "0.3.1"))
    #expect(!AppUpdater.isNewer("0.3.0", than: "0.3.1"))
    #expect(!AppUpdater.isNewer("garbage", than: "0.3.1"))
  }

  @Test("The newest complete release for this architecture is offered; drafts and checksum-less releases are not")
  func selection() async throws {
    let updater = AppUpdater(fetcher: StubFetcher(responses()), runner: RecordingInstallRunner(), architecture: "arm64")
    let release = try #require(try await updater.availableUpdate(currentVersion: "0.3.0"))
    #expect(release.version == "0.3.1")
    #expect(release.archiveName == "FocusQueue-0.3.1-beta-arm64.zip")
    #expect(release.signatureURL == url("0.3.1", "FocusQueue-0.3.1-beta-arm64.zip.sig"))
    #expect(try await updater.availableUpdate(currentVersion: "0.3.1") == nil)
    let intel = AppUpdater(fetcher: StubFetcher(responses()), runner: RecordingInstallRunner(), architecture: "x86_64")
    #expect(try await intel.latestRelease() == nil)
    // An unsigned release is still listed, so installing it can say why it is refused.
    let unsigned = AppUpdater(fetcher: StubFetcher(responses(includeSignature: false)),
                              runner: RecordingInstallRunner(), architecture: "arm64")
    let listed = try #require(try await unsigned.availableUpdate(currentVersion: "0.3.0"))
    #expect(listed.version == "0.3.1" && listed.signatureURL == nil)
  }

  @Test("A rate-limited check is an error, not a crash")
  func rateLimited() async {
    let updater = AppUpdater(fetcher: StubFetcher([AppUpdater.releasesURL: (Data(), 403)]),
                             runner: RecordingInstallRunner(), architecture: "arm64")
    await #expect(throws: AppUpdateError.rateLimited) { try await updater.latestRelease() }
  }

  @Test("A signed, intact release is verified, listed, unpacked, sealed, and then launched detached")
  func installSequence() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner()
    let updater = AppUpdater(fetcher: StubFetcher(responses()), runner: runner, architecture: "arm64",
                             temporaryRoot: root, trustedPublicKeys: trusted)
    let release = try #require(try await updater.latestRelease())
    let log = try await updater.install(release)

    let calls = await runner.calls
    #expect(calls.map(\.executable) == ["/usr/bin/zipinfo", "/usr/bin/zipinfo", "/usr/bin/ditto",
                                        "/usr/bin/codesign", "/usr/bin/xattr", "/bin/zsh"])
    let directory = log.deletingLastPathComponent()
    let archiveFile = directory.appendingPathComponent(release.archiveName).path
    #expect(calls[0].arguments == ["-1", archiveFile])
    #expect(calls[1].arguments == ["-t", archiveFile])
    #expect(calls[2].arguments == ["-x", "-k", archiveFile, directory.appendingPathComponent("unpacked").path])
    let package = directory.appendingPathComponent("unpacked/Focus Queue Beta").path
    #expect(calls[3].arguments == ["--verify", "--deep", "--strict", package + "/Focus Queue.app"])
    #expect(calls[4].arguments == ["-dr", "com.apple.quarantine", package])
    #expect(calls[5].arguments.contains(package + "/Install.command"))
    #expect(calls[5].arguments[1].contains("nohup") && calls[5].arguments[1].hasSuffix("&!"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: archiveFile)) == archive)
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o700)
  }

  @Test("A release without a .sig is refused before any download, unpack, or launch")
  func unsignedRelease() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fetcher = StubFetcher(responses(includeSignature: false))
    let runner = RecordingInstallRunner()
    let updater = AppUpdater(fetcher: fetcher, runner: runner, architecture: "arm64", temporaryRoot: root,
                             trustedPublicKeys: trusted)
    let release = try #require(try await updater.latestRelease())
    await #expect(throws: AppUpdateError.signatureMissing) { try await updater.install(release) }
    #expect(await fetcher.requested == [AppUpdater.releasesURL])
    #expect(await runner.calls.isEmpty)
    #expect(try isEmpty(root))
    #expect(AppUpdateError.signatureMissing.localizedDescription
      == "This release is not signed by the Focus Queue publisher, so it was not installed.")
  }

  @Test("A build whose embedded key is still the placeholder refuses every update")
  func placeholderKeyFailsClosed() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let fetcher = StubFetcher(responses())
    let runner = RecordingInstallRunner()
    let updater = AppUpdater(fetcher: fetcher, runner: runner, architecture: "arm64", temporaryRoot: root,
                             trustedPublicKeys: ["REPLACE_WITH_PUBLISHER_KEY"])
    let release = try #require(try await updater.latestRelease())
    await #expect(throws: AppUpdateError.publisherKeyMissing) { try await updater.install(release) }
    #expect(await fetcher.requested == [AppUpdater.releasesURL])
    #expect(await runner.calls.isEmpty)
  }

  @Test("A forged checksum, a renamed archive, or another key's signature stops before the archive is fetched")
  func signatureRefusals() async throws {
    let otherKey = Curve25519.Signing.PrivateKey()
    let oldName = Self.archiveName("0.3.1")
    let cases: [(String, [URL: (Data, Int)])] = [
      // The attacker swaps both archive and checksum but cannot re-sign.
      ("tampered checksum", responses(checksum: Self.digest(Data("evil".utf8)))),
      // A genuine 0.3.1 archive and signature republished as 0.3.2.
      ("renamed archive", responses(latest: "0.3.2", signature: signature(oldName, Self.digest(archive)))),
      ("wrong key", responses(signature: signature(oldName, Self.digest(archive), by: otherKey))),
      ("truncated signature", responses(signature: Data(count: 63))),
    ]
    for (label, served) in cases {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let fetcher = StubFetcher(served)
      let runner = RecordingInstallRunner()
      let updater = AppUpdater(fetcher: fetcher, runner: runner, architecture: "arm64", temporaryRoot: root,
                               trustedPublicKeys: trusted)
      let release = try #require(try await updater.latestRelease())
      await #expect(throws: AppUpdateError.signatureInvalid, "\(label)") { try await updater.install(release) }
      #expect(await !fetcher.requested.contains(release.archiveURL), "\(label)")
      #expect(await runner.calls.isEmpty, "\(label)")
      #expect(try isEmpty(root), "\(label)")
    }
  }

  @Test("An archive that does not match its signed checksum is never unpacked or run")
  func tamperedArchive() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner()
    let updater = AppUpdater(fetcher: StubFetcher(responses(served: Data("evil zip".utf8))), runner: runner,
                             architecture: "arm64", temporaryRoot: root, trustedPublicKeys: trusted)
    let release = try #require(try await updater.latestRelease())
    await #expect(throws: AppUpdateError.checksumMismatch) { try await updater.install(release) }
    #expect(await runner.calls.isEmpty)
    #expect(try isEmpty(root))
  }

  @Test("Oversized downloads are refused even when the fetcher ignores its limit")
  func oversizedDownloads() async throws {
    for (label, limits) in [
      ("archive", AppUpdater.Limits(archive: archive.count - 1)),
      ("checksum", AppUpdater.Limits(checksum: 16)),
      ("signature", AppUpdater.Limits(signature: 32)),
    ] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let runner = RecordingInstallRunner()
      let updater = AppUpdater(fetcher: StubFetcher(responses()), runner: runner, architecture: "arm64",
                               temporaryRoot: root, trustedPublicKeys: trusted, limits: limits)
      let release = try #require(try await updater.latestRelease())
      await #expect(throws: AppUpdateError.downloadTooLarge, "\(label)") { try await updater.install(release) }
      #expect(await runner.calls.isEmpty, "\(label)")
    }
    let list = AppUpdater(fetcher: StubFetcher(responses()), runner: RecordingInstallRunner(), architecture: "arm64",
                          limits: AppUpdater.Limits(releaseList: 64))
    await #expect(throws: AppUpdateError.downloadTooLarge) { try await list.latestRelease() }
  }

  @Test("The URLSession fetcher stops a body at its limit and never reads error bodies")
  func boundedFetcher() async throws {
    let fetcher = URLSessionFetcher {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.protocolClasses = [ChunkedURLProtocol.self]
      return configuration
    }
    let host = "https://updates.invalid"
    await #expect(throws: AppUpdateError.downloadTooLarge) {
      try await fetcher.get(URL(string: "\(host)/unknown-length")!, accept: nil, maximumBytes: 1_000)
    }
    await #expect(throws: AppUpdateError.downloadTooLarge) {
      try await fetcher.get(URL(string: "\(host)/declared-length")!, accept: nil, maximumBytes: 1_000)
    }
    let whole = try await fetcher.get(URL(string: "\(host)/unknown-length")!, accept: nil, maximumBytes: 2_000)
    #expect(whole.status == 200 && whole.data.count == 2_000)
    let small = try await fetcher.get(URL(string: "\(host)/small")!, accept: nil, maximumBytes: 2)
    #expect(small.status == 200 && small.data == Data("ok".utf8))
    let missing = try await fetcher.get(URL(string: "\(host)/missing")!, accept: nil, maximumBytes: 10)
    #expect(missing.status == 404 && missing.data.isEmpty)
  }

  @Test("Unsafe archive entries are refused before anything is unpacked or run", arguments: [
    ["Focus Queue Beta/", "Focus Queue Beta/Install.command", "Focus Queue Beta/../escape.txt"],
    ["Focus Queue Beta/", "Focus Queue Beta/Install.command", "/etc/evil"],
    ["Focus Queue Beta/", "Focus Queue Beta/Install.command", "Elsewhere/Install.command"],
    ["Focus Queue Beta/", "Focus Queue Beta/Install.command", "Focus Queue Beta\\..\\escape.txt"],
    ["Focus Queue Beta/", "Focus Queue Beta/Install.command", "Focus Queue Beta/./Install.command"],
    // A link entry followed by a write through it, differing only in case.
    ["Focus Queue Beta/", "Focus Queue Beta/link", "Focus Queue Beta/LINK/escape.txt"],
    ["Focus Queue Beta/", "Focus Queue Beta/link", "__MACOSX/Focus Queue Beta/link/._escape.txt"],
    ["Focus Queue Beta/", "Focus Queue Beta/Install.command", "__MACOSX/escape.txt"],
    ["Focus Queue Beta"],
    ["Focus Queue Beta/", "Focus Queue Beta/Install.command", "Focus Queue Beta/Install.command"],
  ])
  func unsafeEntries(_ listing: [String]) async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner(listing: listing)
    let updater = AppUpdater(fetcher: StubFetcher(responses()), runner: runner, architecture: "arm64",
                             temporaryRoot: root, trustedPublicKeys: trusted)
    let release = try #require(try await updater.latestRelease())
    let error = await #expect(throws: AppUpdateError.self) { try await updater.install(release) }
    guard case .archiveRejected = error else {
      Issue.record("Expected archiveRejected, got \(String(describing: error))")
      return
    }
    #expect(await runner.calls.map(\.executable) == ["/usr/bin/zipinfo", "/usr/bin/zipinfo"])
    #expect(try isEmpty(root))
  }

  @Test("Archive listing bounds: the real ditto layout passes; inconsistent, huge, or crowded archives do not")
  func listingRules() throws {
    // `zipinfo -1` of a ditto --sequesterRsrc --keepParent archive, as package-release.sh makes.
    let ditto = [
      "Focus Queue Beta/", "Focus Queue Beta/Install.command", "__MACOSX/", "__MACOSX/Focus Queue Beta/",
      "__MACOSX/Focus Queue Beta/._Install.command", "Focus Queue Beta/Resources/", "Focus Queue Beta/Resources/a b.txt",
      "__MACOSX/Focus Queue Beta/Resources/", "__MACOSX/Focus Queue Beta/Resources/._a b.txt",
      "Focus Queue Beta/Resources/link", "__MACOSX/Focus Queue Beta/Resources/._link",
      "__MACOSX/Focus Queue Beta/._Resources", "Focus Queue Beta/Focus Queue.app/",
      "Focus Queue Beta/Focus Queue.app/Contents/", "Focus Queue Beta/Focus Queue.app/Contents/MacOS/",
      "__MACOSX/Focus Queue Beta/Focus Queue.app/", "__MACOSX/Focus Queue Beta/Focus Queue.app/Contents/",
      "__MACOSX/Focus Queue Beta/Focus Queue.app/Contents/._MacOS", "__MACOSX/Focus Queue Beta/Focus Queue.app/._Contents",
      "__MACOSX/Focus Queue Beta/._Focus Queue.app",
    ]
    let totals = "20 files, 1213 bytes uncompressed, 674 bytes compressed:  44.4%"
    try AppUpdater.validateArchive(entries: ditto, totals: totals, limits: .standard)
    #expect(throws: AppUpdateError.self) {
      try AppUpdater.validateArchive(entries: ditto, totals: "21 files, 1213 bytes uncompressed", limits: .standard)
    }
    #expect(throws: AppUpdateError.self) {
      try AppUpdater.validateArchive(entries: ditto, totals: totals, limits: AppUpdater.Limits(unpackedBytes: 1_000))
    }
    #expect(throws: AppUpdateError.self) {
      try AppUpdater.validateArchive(entries: ditto, totals: totals, limits: AppUpdater.Limits(archiveEntries: 19))
    }
    #expect(throws: AppUpdateError.self) { try AppUpdater.validateArchive(entries: [], totals: "", limits: .standard) }
  }

  @Test("A symlinked Install.command or an escaping link is refused after unpacking, before launch")
  func unpackedTreeRefusals() async throws {
    for plant in [RecordingInstallRunner.Plant.symlinkInstaller, .escapingLink] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let runner = RecordingInstallRunner(plant: plant)
      let updater = AppUpdater(fetcher: StubFetcher(responses()), runner: runner, architecture: "arm64",
                               temporaryRoot: root, trustedPublicKeys: trusted)
      let release = try #require(try await updater.latestRelease())
      let error = await #expect(throws: AppUpdateError.self) { try await updater.install(release) }
      if plant == .symlinkInstaller {
        #expect(error == .installerMissing)
      } else if case .archiveRejected = error {} else {
        Issue.record("Expected archiveRejected for an escaping link, got \(String(describing: error))")
      }
      #expect(await runner.calls.map(\.executable) == ["/usr/bin/zipinfo", "/usr/bin/zipinfo", "/usr/bin/ditto"])
      #expect(try isEmpty(root))
    }
  }

  @Test("An app bundle whose code seal fails is never launched")
  func brokenSeal() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner(codesignStatus: 1)
    let updater = AppUpdater(fetcher: StubFetcher(responses()), runner: runner, architecture: "arm64",
                             temporaryRoot: root, trustedPublicKeys: trusted)
    let release = try #require(try await updater.latestRelease())
    await #expect(throws: AppUpdateError.appSignatureInvalid("a sealed resource is missing or invalid")) {
      try await updater.install(release)
    }
    #expect(await !runner.calls.contains { $0.executable == "/bin/zsh" || $0.executable == "/usr/bin/xattr" })
  }

  // MARK: - Real archive tools

  enum InstallerShape: Sendable { case regular, internalLink, escapingLink, tamperedApp }

  /// A ditto-made ZIP shaped like Scripts/package-release.sh output, holding an
  /// ad hoc signed stub app. Uses the real codesign and ditto.
  private func realArchive(in root: URL, shape: InstallerShape) async throws -> Data {
    let manager = FileManager.default
    let runner = FoundationProcessRunner()
    let package = root.appendingPathComponent("stage/Focus Queue Beta")
    let app = package.appendingPathComponent("Focus Queue.app")
    try manager.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try manager.createDirectory(at: package.appendingPathComponent("Resources"), withIntermediateDirectories: true)
    try manager.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/FocusQueueStub").path)
    let info: [String: Any] = ["CFBundleExecutable": "FocusQueueStub", "CFBundleIdentifier": "test.focus-queue.stub",
                               "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.3.1"]
    let plist = app.appendingPathComponent("Contents/Info.plist")
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
    let signed = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path], timeoutSeconds: 60))
    try #require(signed.succeeded, "\(signed.standardError)")
    let script = Data("#!/bin/zsh\nexit 0\n".utf8)
    let installer = package.appendingPathComponent("Install.command")
    switch shape {
    case .regular, .tamperedApp:
      try script.write(to: installer)
    case .internalLink:
      try script.write(to: package.appendingPathComponent("Resources/real.command"))
      try manager.createSymbolicLink(atPath: installer.path, withDestinationPath: "Resources/real.command")
    case .escapingLink:
      try script.write(to: installer)
      try manager.createSymbolicLink(atPath: package.appendingPathComponent("Resources/etc").path,
                                     withDestinationPath: "/etc")
    }
    if shape == .tamperedApp {
      try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/MacOS/added-after-signing"))
    }
    let zip = root.appendingPathComponent("release.zip")
    let packed = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", package.path, zip.path],
      timeoutSeconds: 60))
    try #require(packed.succeeded, "\(packed.standardError)")
    return try Data(contentsOf: zip)
  }

  @Test("Real tools: a signed ditto archive passes zipinfo, ditto, and codesign checks up to the launch")
  func realToolsInstall() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try await realArchive(in: root.appendingPathComponent("build"), shape: .regular)
    let updates = root.appendingPathComponent("updates")
    try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
    let runner = InterceptingRunner()
    let updater = AppUpdater(fetcher: StubFetcher(responses(signed: bytes)), runner: runner, architecture: "arm64",
                             temporaryRoot: updates, trustedPublicKeys: trusted)
    let release = try #require(try await updater.latestRelease())
    let log = try await updater.install(release)
    let calls = await runner.calls
    #expect(calls.map(\.executable) == ["/usr/bin/zipinfo", "/usr/bin/zipinfo", "/usr/bin/ditto",
                                        "/usr/bin/codesign", "/usr/bin/xattr", "/bin/zsh"])
    let installer = log.deletingLastPathComponent().appendingPathComponent("unpacked/Focus Queue Beta/Install.command")
    #expect(AppUpdater.fileType(installer.path) == S_IFREG)
    #expect(calls.last?.arguments.contains(installer.path) == true)
    #expect(!FileManager.default.fileExists(atPath: log.path), "The intercepted installer must not have run")
  }

  @Test("Real tools: link tricks and a broken app seal are refused before the launch",
        arguments: [InstallerShape.internalLink, .escapingLink, .tamperedApp])
  func realToolsRefusals(_ shape: InstallerShape) async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let bytes = try await realArchive(in: root.appendingPathComponent("build"), shape: shape)
    let updates = root.appendingPathComponent("updates")
    try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
    let runner = InterceptingRunner()
    let updater = AppUpdater(fetcher: StubFetcher(responses(signed: bytes)), runner: runner, architecture: "arm64",
                             temporaryRoot: updates, trustedPublicKeys: trusted)
    let release = try #require(try await updater.latestRelease())
    let error = await #expect(throws: AppUpdateError.self) { try await updater.install(release) }
    switch (shape, error) {
    case (.internalLink, .installerMissing?), (.escapingLink, .archiveRejected?), (.tamperedApp, .appSignatureInvalid?):
      break
    default:
      Issue.record("\(shape): unexpected \(String(describing: error))")
    }
    #expect(await !runner.calls.contains { $0.executable == "/bin/zsh" })
    #expect(try isEmpty(updates))
  }

  @Test("Real tools: zipinfo exposes .. and absolute entries, which are refused before ditto runs")
  func realToolsHostileZip() async throws {
    for hostile in ["Focus Queue Beta/../escape.txt", "/tmp/focus-queue-absolute.txt"] {
      let root = try temporaryRoot()
      defer { try? FileManager.default.removeItem(at: root) }
      let bytes = StoredZip.make([
        ("Focus Queue Beta/", Data()),
        ("Focus Queue Beta/Install.command", Data("#!/bin/zsh\n".utf8)),
        (hostile, Data("x".utf8)),
      ])
      let runner = InterceptingRunner()
      let updater = AppUpdater(fetcher: StubFetcher(responses(signed: bytes)), runner: runner, architecture: "arm64",
                               temporaryRoot: root, trustedPublicKeys: trusted)
      let release = try #require(try await updater.latestRelease())
      await #expect(throws: AppUpdateError.archiveRejected(
        "the entry \"\(hostile)\" is outside Focus Queue Beta")) { try await updater.install(release) }
      #expect(await runner.calls.map(\.executable) == ["/usr/bin/zipinfo", "/usr/bin/zipinfo"])
    }
  }

  /// Pre-flight for a real release before upload:
  /// FOCUS_QUEUE_RELEASE_ARCHIVE=dist/FocusQueue-….zip FOCUS_QUEUE_RELEASE_PUBLIC_KEY=<base64> swift test --filter localReleaseArchive
  @Test("Local: a packaged release archive passes every install check up to the launch",
        .enabled(if: ProcessInfo.processInfo.environment["FOCUS_QUEUE_RELEASE_ARCHIVE"] != nil))
  func localReleaseArchive() async throws {
    let environment = ProcessInfo.processInfo.environment
    let archiveFile = URL(fileURLWithPath: try #require(environment["FOCUS_QUEUE_RELEASE_ARCHIVE"]))
    let publicKey = try #require(environment["FOCUS_QUEUE_RELEASE_PUBLIC_KEY"])
    let name = archiveFile.lastPathComponent
    let remote = URL(string: "https://local.invalid/")!
    let release = AppRelease(
      tag: "local", version: "0", title: name, notes: "", pageURL: nil, archiveName: name,
      archiveURL: remote.appendingPathComponent(name), checksumURL: remote.appendingPathComponent(name + ".sha256"),
      signatureURL: remote.appendingPathComponent(name + ".sig"))
    let fetcher = StubFetcher([
      release.archiveURL: (try Data(contentsOf: archiveFile), 200),
      release.checksumURL: (try Data(contentsOf: URL(fileURLWithPath: archiveFile.path + ".sha256")), 200),
      release.signatureURL!: (try Data(contentsOf: URL(fileURLWithPath: archiveFile.path + ".sig")), 200),
    ])
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = InterceptingRunner()
    let log = try await AppUpdater(fetcher: fetcher, runner: runner, temporaryRoot: root,
                                   trustedPublicKeys: [publicKey]).install(release)
    #expect(await runner.calls.map(\.executable) == ["/usr/bin/zipinfo", "/usr/bin/zipinfo", "/usr/bin/ditto",
                                                     "/usr/bin/codesign", "/usr/bin/xattr", "/bin/zsh"])
    print("LOCAL verified and unpacked, installer launch intercepted:", log.deletingLastPathComponent().path)
  }

  @Test("The detached launch command returns at once and its job still runs")
  func detachedLaunch() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("Install.command")
    let marker = root.appendingPathComponent("ran")
    // The installer outlasts the check by a wide margin, so a launcher that
    // waited for it fails, while process start-up under a busy parallel run does not.
    try Data("#!/bin/zsh\nsleep 5\ntouch '\(marker.path)'\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let started = Date()
    let result = try await FoundationProcessRunner().run(ProcessSpecification(
      executable: "/bin/zsh",
      arguments: ["-fc", "/usr/bin/nohup \"$1\" >\"$2\" 2>&1 </dev/null &!", "focus-queue-update",
                  script.path, root.appendingPathComponent("install.log").path],
      timeoutSeconds: 15))
    #expect(result.succeeded)
    #expect(Date().timeIntervalSince(started) < 4, "The launcher must not wait for the installer")
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("Live: the published releases include a complete arm64 beta", .enabled(if: ProcessInfo.processInfo.environment["FOCUS_QUEUE_LIVE_UPDATE_CHECK"] == "1"))
  func liveCheck() async throws {
    let release = try #require(try await AppUpdater(architecture: "arm64").latestRelease())
    print("LIVE latest:", release.tag, release.archiveURL, release.checksumURL, release.signatureURL as Any)
    #expect(AppUpdater.isNewer(release.version, than: "0.3.0"))
    // Real downloads and checks with the embedded key; the recording runner keeps it from installing.
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner()
    do {
      let log = try await AppUpdater(runner: runner, architecture: "arm64", temporaryRoot: root).install(release)
      print("LIVE verified and unpacked:", log.deletingLastPathComponent().path)
    } catch let error as AppUpdateError {
      print("LIVE refused:", error.localizedDescription)
      #expect(await !runner.calls.contains { $0.executable == "/bin/zsh" })
    }
  }
}

/// Writes a stored (uncompressed) ZIP with exactly the given entry names, so
/// tests can build archives that ordinary tools refuse to create.
enum StoredZip {
  static func make(_ entries: [(name: String, data: Data)]) -> Data {
    var body = Data()
    var directory = Data()
    for entry in entries {
      let name = Data(entry.name.utf8)
      let crc = crc32(entry.data)
      let size = UInt32(entry.data.count)
      let mode: UInt32 = entry.name.hasSuffix("/") ? 0o040755 : 0o100644
      let offset = UInt32(body.count)
      put(&body, [0x0403_4b50, 20, 0, 0, 0, 0x21, crc, size, size, UInt32(name.count), 0],
          widths: [4, 2, 2, 2, 2, 2, 4, 4, 4, 2, 2])
      body.append(name)
      body.append(entry.data)
      put(&directory, [0x0201_4b50, 0x031E, 20, 0, 0, 0, 0x21, crc, size, size, UInt32(name.count), 0, 0, 0, 0,
                       mode << 16, offset],
          widths: [4, 2, 2, 2, 2, 2, 2, 4, 4, 4, 2, 2, 2, 2, 2, 4, 4])
      directory.append(name)
    }
    var end = Data()
    put(&end, [0x0605_4b50, 0, 0, UInt32(entries.count), UInt32(entries.count), UInt32(directory.count),
               UInt32(body.count), 0], widths: [4, 2, 2, 2, 2, 4, 4, 2])
    return body + directory + end
  }

  private static func put(_ data: inout Data, _ values: [UInt32], widths: [Int]) {
    for (value, width) in zip(values, widths) {
      for shift in stride(from: 0, to: width * 8, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift))) }
    }
  }

  private static func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
      crc ^= UInt32(byte)
      for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
    }
    return ~crc
  }
}
