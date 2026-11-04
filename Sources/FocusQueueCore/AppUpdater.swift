import CryptoKit
import Darwin
import Foundation

/// Anonymous HTTP GET, so update checks can be faked in tests.
public protocol HTTPFetching: Sendable {
  /// Returns the body and status code. Never sends credentials or cookies.
  func get(_ url: URL, accept: String?) async throws -> (data: Data, status: Int)
}

public struct URLSessionFetcher: HTTPFetching {
  public init() {}

  public func get(_ url: URL, accept: String?) async throws -> (data: Data, status: Int) {
    // An ephemeral session keeps no cookies or cache, and nothing identifies the user.
    let session = URLSession(configuration: .ephemeral)
    defer { session.finishTasksAndInvalidate() }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue("FocusQueue-Updater", forHTTPHeaderField: "User-Agent")
    if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
    let (data, response) = try await session.data(for: request)
    return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
  }
}

/// A published beta build this Mac can install.
public struct AppRelease: Equatable, Sendable {
  public let tag: String
  public let version: String
  public let title: String
  public let notes: String
  public let pageURL: URL?
  public let archiveName: String
  public let archiveURL: URL
  public let checksumURL: URL

  public init(tag: String, version: String, title: String, notes: String, pageURL: URL?,
              archiveName: String, archiveURL: URL, checksumURL: URL) {
    self.tag = tag
    self.version = version
    self.title = title
    self.notes = notes
    self.pageURL = pageURL
    self.archiveName = archiveName
    self.archiveURL = archiveURL
    self.checksumURL = checksumURL
  }
}

public enum AppUpdateError: Error, LocalizedError, Equatable {
  case rateLimited
  case unavailable(Int)
  case malformedResponse
  case checksumMissing
  case checksumMismatch
  case unpackFailed(String)
  case installerMissing
  case launchFailed(String)

  public var errorDescription: String? {
    switch self {
    case .rateLimited: "GitHub is limiting update checks right now. Try again in an hour."
    case .unavailable(let status): "GitHub did not answer the update check (HTTP \(status))."
    case .malformedResponse: "GitHub's release list could not be read."
    case .checksumMissing: "The release has no readable checksum, so it was not installed."
    case .checksumMismatch: "The download does not match its published checksum, so it was not installed."
    case .unpackFailed(let detail): "The update could not be unpacked: \(detail)"
    case .installerMissing: "The update does not contain Install.command."
    case .launchFailed(let detail): "The installer could not start: \(detail)"
    }
  }
}

/// Finds newer GitHub releases and installs them with the release's own
/// Install.command, which stops this app, replaces it, and starts it again.
public struct AppUpdater: Sendable {
  public static let releasesURL = URL(string: "https://api.github.com/repos/haelyra/FocusQueue/releases?per_page=20")!

  private let fetcher: any HTTPFetching
  private let runner: any ProcessRunning
  private let architecture: String
  private let temporaryRoot: URL

  public init(
    fetcher: any HTTPFetching = URLSessionFetcher(),
    runner: any ProcessRunning = FoundationProcessRunner(),
    architecture: String = AppUpdater.machineArchitecture(),
    temporaryRoot: URL = FileManager.default.temporaryDirectory
  ) {
    self.fetcher = fetcher
    self.runner = runner
    self.architecture = architecture
    self.temporaryRoot = temporaryRoot
  }

  public static func machineArchitecture() -> String {
    var system = utsname()
    uname(&system)
    return withUnsafeBytes(of: &system.machine) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// `v0.3.1-beta` and `0.3.1` both give [0, 3, 1]; anything else gives nil.
  public static func versionComponents(_ text: String) -> [Int]? {
    var core = Substring(text.trimmingCharacters(in: .whitespaces))
    if core.first == "v" || core.first == "V" { core = core.dropFirst() }
    if let suffix = core.firstIndex(where: { $0 == "-" || $0 == "+" }) { core = core[..<suffix] }
    let parts = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    return parts.compactMap { $0 }
  }

  public static func isNewer(_ candidate: String, than current: String) -> Bool {
    guard let left = versionComponents(candidate), let right = versionComponents(current) else { return false }
    let count = max(left.count, right.count)
    let padded = { (parts: [Int]) in parts + Array(repeating: 0, count: count - parts.count) }
    return padded(right).lexicographicallyPrecedes(padded(left))
  }

  private struct ReleaseDocument: Decodable {
    struct Asset: Decodable {
      let name: String
      let browser_download_url: URL
    }
    let tag_name: String
    let name: String?
    let body: String?
    let draft: Bool
    let html_url: URL?
    let assets: [Asset]
  }

  /// The newest published release for this architecture, newer or not.
  public func latestRelease() async throws -> AppRelease? {
    let (data, status) = try await fetcher.get(Self.releasesURL, accept: "application/vnd.github+json")
    switch status {
    case 200: break
    case 403, 429: throw AppUpdateError.rateLimited
    default: throw AppUpdateError.unavailable(status)
    }
    guard let documents = try? JSONDecoder().decode([ReleaseDocument].self, from: data) else {
      throw AppUpdateError.malformedResponse
    }
    let releases = documents.compactMap(release)
    return releases.max { left, right in Self.isNewer(right.version, than: left.version) }
  }

  /// A newer release than `currentVersion`, or nil when this build is current.
  public func availableUpdate(currentVersion: String) async throws -> AppRelease? {
    guard let latest = try await latestRelease(), Self.isNewer(latest.version, than: currentVersion) else {
      return nil
    }
    return latest
  }

  private func release(_ document: ReleaseDocument) -> AppRelease? {
    guard !document.draft, let parts = Self.versionComponents(document.tag_name) else { return nil }
    guard let archive = document.assets.first(where: {
      $0.name.hasPrefix("FocusQueue-") && $0.name.hasSuffix("-\(architecture).zip")
    }), let checksum = document.assets.first(where: { $0.name == archive.name + ".sha256" }) else { return nil }
    return AppRelease(
      tag: document.tag_name, version: parts.map(String.init).joined(separator: "."),
      title: document.name?.isEmpty == false ? document.name! : document.tag_name,
      notes: document.body ?? "", pageURL: document.html_url, archiveName: archive.name,
      archiveURL: archive.browser_download_url, checksumURL: checksum.browser_download_url)
  }

  /// Downloads, verifies, and unpacks the release, then starts its installer
  /// detached so it outlives this app. Returns the installer's log file.
  @discardableResult
  public func install(_ release: AppRelease) async throws -> URL {
    let directory = temporaryRoot.appendingPathComponent("focus-queue-update-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    do {
      return try await install(release, in: directory)
    } catch {
      try? FileManager.default.removeItem(at: directory)
      throw error
    }
  }

  private func install(_ release: AppRelease, in directory: URL) async throws -> URL {
    let checksum = try await download(release.checksumURL)
    guard let expected = String(decoding: checksum, as: UTF8.self)
      .split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }),
      expected.count == 64, expected.allSatisfy(\.isHexDigit) else { throw AppUpdateError.checksumMissing }
    let archive = try await download(release.archiveURL)
    let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else { throw AppUpdateError.checksumMismatch }

    let archiveFile = directory.appendingPathComponent(release.archiveName)
    try archive.write(to: archiveFile, options: .withoutOverwriting)
    let unpacked = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/ditto", arguments: ["-x", "-k", archiveFile.path, directory.path], timeoutSeconds: 120))
    guard unpacked.succeeded else { throw AppUpdateError.unpackFailed(String(unpacked.standardError.prefix(400))) }

    let package = directory.appendingPathComponent("Focus Queue Beta", isDirectory: true)
    // Downloads made here carry no quarantine flag, but clearing it keeps the
    // result identical to the README's manual steps.
    _ = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", package.path], timeoutSeconds: 60))
    let installer = package.appendingPathComponent("Install.command")
    let values = try? installer.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { throw AppUpdateError.installerMissing }

    // The installer stops this app, so it must not be our child: nohup in a
    // disowned background job, with no pipes back to us.
    let log = directory.appendingPathComponent("install.log")
    let launched = try await runner.run(ProcessSpecification(
      executable: "/bin/zsh",
      arguments: ["-fc", "/usr/bin/nohup \"$1\" >\"$2\" 2>&1 </dev/null &!", "focus-queue-update",
                  installer.path, log.path],
      timeoutSeconds: 15))
    guard launched.succeeded else { throw AppUpdateError.launchFailed(String(launched.standardError.prefix(400))) }
    return log
  }

  private func download(_ url: URL) async throws -> Data {
    let (data, status) = try await fetcher.get(url, accept: "application/octet-stream")
    switch status {
    case 200: return data
    case 403, 429: throw AppUpdateError.rateLimited
    default: throw AppUpdateError.unavailable(status)
    }
  }
}
