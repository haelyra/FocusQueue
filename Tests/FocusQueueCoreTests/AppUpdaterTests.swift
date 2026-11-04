import CryptoKit
import Foundation
import Testing
@testable import FocusQueueCore

private actor StubFetcher: HTTPFetching {
  private var responses: [URL: (Data, Int)]
  private(set) var requested: [URL] = []

  init(_ responses: [URL: (Data, Int)]) { self.responses = responses }

  func get(_ url: URL, accept: String?) async throws -> (data: Data, status: Int) {
    requested.append(url)
    guard let response = responses[url] else { return (Data(), 404) }
    return response
  }
}

/// Records commands; "unpacking" lays out the package the real ZIP holds.
private actor RecordingInstallRunner: ProcessRunning {
  private(set) var calls: [ProcessSpecification] = []

  func run(_ specification: ProcessSpecification) throws -> ProcessResult {
    calls.append(specification)
    if specification.executable == "/usr/bin/ditto", let destination = specification.arguments.last {
      let package = URL(fileURLWithPath: destination).appendingPathComponent("Focus Queue Beta")
      try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
      try Data("#!/bin/zsh\n".utf8).write(to: package.appendingPathComponent("Install.command"))
    }
    return ProcessResult(exitCode: 0, standardOutput: "", standardError: "", timedOut: false)
  }
}

@Suite("App updater")
struct AppUpdaterTests {
  private let archive = Data("zip bytes".utf8)
  private var digest: String { SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined() }
  private let base = "https://github.com/haelyra/FocusQueue/releases/download"

  private func releasesJSON() -> Data {
    let releases: [[String: Any]] = [
      ["tag_name": "v0.3.1-beta", "name": "Focus Queue 0.3.1 beta", "body": "**Fixed**\n- Sign-in", "draft": false,
       "html_url": "https://github.com/haelyra/FocusQueue/releases/tag/v0.3.1-beta",
       "assets": [
        ["name": "FocusQueue-0.3.1-beta-arm64.zip", "browser_download_url": "\(base)/v0.3.1-beta/FocusQueue-0.3.1-beta-arm64.zip"],
        ["name": "FocusQueue-0.3.1-beta-arm64.zip.sha256", "browser_download_url": "\(base)/v0.3.1-beta/FocusQueue-0.3.1-beta-arm64.zip.sha256"],
       ]],
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

  private func responses(checksum: String? = nil) -> [URL: (Data, Int)] {
    [
      AppUpdater.releasesURL: (releasesJSON(), 200),
      URL(string: "\(base)/v0.3.1-beta/FocusQueue-0.3.1-beta-arm64.zip.sha256")!:
        (Data("\(checksum ?? digest)  FocusQueue-0.3.1-beta-arm64.zip\n".utf8), 200),
      URL(string: "\(base)/v0.3.1-beta/FocusQueue-0.3.1-beta-arm64.zip")!: (archive, 200),
    ]
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
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
    #expect(try await updater.availableUpdate(currentVersion: "0.3.1") == nil)
    let intel = AppUpdater(fetcher: StubFetcher(responses()), runner: RecordingInstallRunner(), architecture: "x86_64")
    #expect(try await intel.latestRelease() == nil)
  }

  @Test("A rate-limited check is an error, not a crash")
  func rateLimited() async {
    let updater = AppUpdater(fetcher: StubFetcher([AppUpdater.releasesURL: (Data(), 403)]),
                             runner: RecordingInstallRunner(), architecture: "arm64")
    await #expect(throws: AppUpdateError.rateLimited) { try await updater.latestRelease() }
  }

  @Test("A download that does not match its checksum is never unpacked or run")
  func checksumMismatch() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner()
    let updater = AppUpdater(fetcher: StubFetcher(responses(checksum: String(repeating: "0", count: 64))),
                             runner: runner, architecture: "arm64", temporaryRoot: root)
    let release = try #require(try await updater.latestRelease())
    await #expect(throws: AppUpdateError.checksumMismatch) { try await updater.install(release) }
    #expect(await runner.calls.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
  }

  @Test("Install verifies, unpacks, clears quarantine, then starts Install.command detached")
  func installSequence() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner()
    let updater = AppUpdater(fetcher: StubFetcher(responses()), runner: runner, architecture: "arm64", temporaryRoot: root)
    let release = try #require(try await updater.latestRelease())
    let log = try await updater.install(release)

    let calls = await runner.calls
    #expect(calls.map(\.executable) == ["/usr/bin/ditto", "/usr/bin/xattr", "/bin/zsh"])
    let directory = log.deletingLastPathComponent()
    #expect(calls[0].arguments == ["-x", "-k", directory.appendingPathComponent(release.archiveName).path, directory.path])
    let package = directory.appendingPathComponent("Focus Queue Beta").path
    #expect(calls[1].arguments == ["-dr", "com.apple.quarantine", package])
    #expect(calls[2].arguments.contains(package + "/Install.command"))
    #expect(calls[2].arguments[1].contains("nohup") && calls[2].arguments[1].hasSuffix("&!"))
    #expect(try Data(contentsOf: directory.appendingPathComponent(release.archiveName)) == archive)
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o700)
  }

  @Test("The detached launch command returns at once and its job still runs")
  func detachedLaunch() async throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("Install.command")
    let marker = root.appendingPathComponent("ran")
    try Data("#!/bin/zsh\nsleep 1\ntouch '\(marker.path)'\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let started = Date()
    let result = try await FoundationProcessRunner().run(ProcessSpecification(
      executable: "/bin/zsh",
      arguments: ["-fc", "/usr/bin/nohup \"$1\" >\"$2\" 2>&1 </dev/null &!", "focus-queue-update",
                  script.path, root.appendingPathComponent("install.log").path],
      timeoutSeconds: 15))
    #expect(result.succeeded)
    #expect(Date().timeIntervalSince(started) < 1, "The launcher must not wait for the installer")
    for _ in 0..<40 where !FileManager.default.fileExists(atPath: marker.path) {
      try await Task.sleep(for: .milliseconds(100))
    }
    #expect(FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("Live: the published releases include a complete arm64 beta", .enabled(if: ProcessInfo.processInfo.environment["FOCUS_QUEUE_LIVE_UPDATE_CHECK"] == "1"))
  func liveCheck() async throws {
    let release = try #require(try await AppUpdater(architecture: "arm64").latestRelease())
    print("LIVE latest:", release.tag, release.archiveURL, release.checksumURL)
    #expect(AppUpdater.isNewer(release.version, than: "0.3.0"))
    // Real download and checksum; the recording runner keeps it from unpacking or installing.
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let runner = RecordingInstallRunner()
    let log = try await AppUpdater(runner: runner, architecture: "arm64", temporaryRoot: root).install(release)
    let size = try FileManager.default.attributesOfItem(
      atPath: log.deletingLastPathComponent().appendingPathComponent(release.archiveName).path)[.size] as? NSNumber
    print("LIVE verified archive bytes:", size ?? 0)
    #expect(await runner.calls.map(\.executable) == ["/usr/bin/ditto", "/usr/bin/xattr", "/bin/zsh"])
  }
}
