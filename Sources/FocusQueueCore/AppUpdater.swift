import CryptoKit
import Darwin
import Foundation

/// Anonymous HTTP GET, so update checks can be faked in tests.
public protocol HTTPFetching: Sendable {
  /// Returns the body and status code. Never sends credentials or cookies.
  /// Throws `AppUpdateError.downloadTooLarge` instead of buffering more than
  /// `maximumBytes` of a successful response.
  func get(_ url: URL, accept: String?, maximumBytes: Int) async throws -> (data: Data, status: Int)
}

public struct URLSessionFetcher: HTTPFetching {
  private let configuration: @Sendable () -> URLSessionConfiguration

  /// The default ephemeral session keeps no cookies or cache, and nothing
  /// identifies the user; tests substitute a stubbed configuration.
  public init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) {
    self.configuration = configuration
  }

  public func get(_ url: URL, accept: String?, maximumBytes: Int) async throws -> (data: Data, status: Int) {
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.setValue("FocusQueue-Updater", forHTTPHeaderField: "User-Agent")
    if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
    let download = BoundedDownload(maximumBytes: maximumBytes)
    let session = URLSession(configuration: configuration(), delegate: download, delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { download.start(task, continuation: $0) }
    } onCancel: {
      task.cancel()
    }
  }
}

/// Collects one response body and cancels the transfer as soon as it would
/// pass its limit, so an oversized download never fills memory.
private final class BoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  typealias Body = (data: Data, status: Int)
  private enum Stop { case status, tooLarge }

  // URLSession calls a delegate on its own serial queue; the lock also orders `start`.
  private let lock = NSLock()
  private let maximumBytes: Int
  private var body = Data()
  private var status = 0
  private var stop: Stop?
  private var continuation: CheckedContinuation<Body, any Error>?

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Body, any Error>) {
    lock.withLock { self.continuation = continuation }
    task.resume()
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let disposition: URLSession.ResponseDisposition = lock.withLock {
      self.status = status
      // Callers read only the status of a failed request, never its body.
      if status != 200 {
        stop = .status
      } else if response.expectedContentLength > Int64(maximumBytes) {
        stop = .tooLarge
      }
      return stop == nil ? .allow : .cancel
    }
    completionHandler(disposition)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let exceeded = lock.withLock {
      guard stop == nil else { return false }
      guard body.count + data.count <= maximumBytes else {
        stop = .tooLarge
        body = Data()
        return true
      }
      body.append(data)
      return false
    }
    if exceeded { dataTask.cancel() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    let (continuation, result): (CheckedContinuation<Body, any Error>?, Result<Body, any Error>) = lock.withLock {
      defer { self.continuation = nil }
      switch stop {
      case .tooLarge: return (self.continuation, .failure(AppUpdateError.downloadTooLarge))
      case .status: return (self.continuation, .success((Data(), status)))
      case nil: return (self.continuation, error.map { .failure($0) } ?? .success((body, status)))
      }
    }
    continuation?.resume(with: result)
  }

  /// Follows GitHub's redirect to its download host, but never to plain HTTP.
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(request.url?.scheme?.lowercased() == "https" ? request : nil)
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
  /// Nil when the release has no `.sig` asset; installing it then fails with
  /// `AppUpdateError.signatureMissing` before anything is downloaded.
  public let signatureURL: URL?

  public init(tag: String, version: String, title: String, notes: String, pageURL: URL?,
              archiveName: String, archiveURL: URL, checksumURL: URL, signatureURL: URL? = nil) {
    self.tag = tag
    self.version = version
    self.title = title
    self.notes = notes
    self.pageURL = pageURL
    self.archiveName = archiveName
    self.archiveURL = archiveURL
    self.checksumURL = checksumURL
    self.signatureURL = signatureURL
  }
}

public enum AppUpdateError: Error, LocalizedError, Equatable {
  case rateLimited
  case unavailable(Int)
  case malformedResponse
  case checksumMissing
  case checksumMismatch
  case signatureMissing
  case signatureInvalid
  case publisherKeyMissing
  case downloadTooLarge
  case archiveRejected(String)
  case appSignatureInvalid(String)
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
    case .signatureMissing: "This release is not signed by the Focus Queue publisher, so it was not installed."
    case .signatureInvalid:
      "The release's signature does not match the Focus Queue publisher key, so it was not installed."
    case .publisherKeyMissing: "This build has no Focus Queue publisher key, so it cannot verify or install updates."
    case .downloadTooLarge: "An update download was larger than allowed, so it was stopped and nothing was installed."
    case .archiveRejected(let detail): "The update archive was rejected because \(detail), so it was not installed."
    case .appSignatureInvalid(let detail):
      "The updated app's code signature does not verify, so it was not installed: \(detail)"
    case .unpackFailed(let detail): "The update could not be unpacked: \(detail)"
    case .installerMissing: "The update does not contain Install.command."
    case .launchFailed(let detail): "The installer could not start: \(detail)"
    }
  }
}

/// Finds newer GitHub releases and installs them with the release's own
/// Install.command, which stops this app, replaces it, and starts it again.
/// Nothing from a release runs until its publisher signature, checksum,
/// archive layout, unpacked tree, and app code signature all check out.
public struct AppUpdater: Sendable {
  /// Size bounds for everything the updater downloads or unpacks.
  public struct Limits: Sendable, Equatable {
    public var releaseList: Int
    public var checksum: Int
    public var signature: Int
    public var archive: Int
    public var unpackedBytes: Int64
    public var archiveEntries: Int

    public init(releaseList: Int = 8 << 20, checksum: Int = 4 << 10, signature: Int = 1 << 10,
                archive: Int = 512 << 20, unpackedBytes: Int64 = 2 << 30, archiveEntries: Int = 20_000) {
      self.releaseList = releaseList
      self.checksum = checksum
      self.signature = signature
      self.archive = archive
      self.unpackedBytes = unpackedBytes
      self.archiveEntries = archiveEntries
    }

    public static let standard = Limits()
  }

  public static let releasesURL = URL(string: "https://api.github.com/repos/haelyra/FocusQueue/releases?per_page=20")!
  static let packageName = "Focus Queue Beta"
  static let appName = "Focus Queue.app"
  /// zipinfo output larger than this is treated as unreadable rather than truncated.
  static let listingOutputLimit = 8 << 20

  private let fetcher: any HTTPFetching
  private let runner: any ProcessRunning
  private let architecture: String
  private let temporaryRoot: URL
  private let trustedPublicKeys: [String]
  private let limits: Limits

  public init(
    fetcher: any HTTPFetching = URLSessionFetcher(),
    runner: any ProcessRunning = FoundationProcessRunner(),
    architecture: String = AppUpdater.machineArchitecture(),
    temporaryRoot: URL = FileManager.default.temporaryDirectory,
    trustedPublicKeys: [String] = ReleaseSigning.trustedPublicKeys,
    limits: Limits = .standard
  ) {
    self.fetcher = fetcher
    self.runner = runner
    self.architecture = architecture
    self.temporaryRoot = temporaryRoot
    self.trustedPublicKeys = trustedPublicKeys
    self.limits = limits
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

  /// `FocusQueue-<version>-<architecture>.zip`, spelled only with characters
  /// that are safe as a file name and on a manifest line.
  static func isArchiveName(_ name: String, architecture: String) -> Bool {
    name.hasPrefix("FocusQueue-") && name.hasSuffix("-\(architecture).zip")
      && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
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
    let (data, status) = try await fetcher.get(Self.releasesURL, accept: "application/vnd.github+json",
                                               maximumBytes: limits.releaseList)
    switch status {
    case 200: break
    case 403, 429: throw AppUpdateError.rateLimited
    default: throw AppUpdateError.unavailable(status)
    }
    guard data.count <= limits.releaseList else { throw AppUpdateError.downloadTooLarge }
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
    let assets = document.assets.filter { $0.browser_download_url.scheme?.lowercased() == "https" }
    guard let archive = assets.first(where: { Self.isArchiveName($0.name, architecture: architecture) }),
          let checksum = assets.first(where: { $0.name == archive.name + ".sha256" }) else { return nil }
    // An unsigned release is still offered, so trying to install it says why it cannot be.
    let signature = assets.first(where: { $0.name == archive.name + ".sig" })
    return AppRelease(
      tag: document.tag_name, version: parts.map(String.init).joined(separator: "."),
      title: document.name?.isEmpty == false ? document.name! : document.tag_name,
      notes: document.body ?? "", pageURL: document.html_url, archiveName: archive.name,
      archiveURL: archive.browser_download_url, checksumURL: checksum.browser_download_url,
      signatureURL: signature?.browser_download_url)
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
    // 1. Authenticate the publisher from two small files before fetching the archive.
    guard let signatureURL = release.signatureURL else { throw AppUpdateError.signatureMissing }
    let keys = ReleaseSigning.publicKeys(trustedPublicKeys)
    guard !keys.isEmpty else { throw AppUpdateError.publisherKeyMissing }
    guard Self.isArchiveName(release.archiveName, architecture: architecture) else {
      throw AppUpdateError.archiveRejected("its name is not a Focus Queue archive name")
    }
    let checksum = try await download(release.checksumURL, maximumBytes: limits.checksum)
    guard let expected = String(decoding: checksum, as: UTF8.self)
      .split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }),
      expected.count == 64, expected.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
      throw AppUpdateError.checksumMissing
    }
    let signature = try await download(signatureURL, maximumBytes: limits.signature)
    guard ReleaseSigning.isValid(signature: signature, archiveName: release.archiveName,
                                 sha256Hex: expected, keys: keys) else { throw AppUpdateError.signatureInvalid }

    // 2. The archive must be exactly the bytes the publisher signed.
    let archive = try await download(release.archiveURL, maximumBytes: limits.archive)
    let actual = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
    guard actual == expected else { throw AppUpdateError.checksumMismatch }
    let archiveFile = directory.appendingPathComponent(release.archiveName)
    try archive.write(to: archiveFile, options: .withoutOverwriting)

    // 3. Check every entry before ditto writes anything, then the tree it wrote.
    try await inspectArchive(archiveFile)
    let unpackedRoot = directory.appendingPathComponent("unpacked", isDirectory: true)
    try FileManager.default.createDirectory(at: unpackedRoot, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    let unpacked = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/ditto", arguments: ["-x", "-k", archiveFile.path, unpackedRoot.path], timeoutSeconds: 120))
    guard unpacked.succeeded else { throw AppUpdateError.unpackFailed(String(unpacked.standardError.prefix(400))) }
    let package = try Self.inspectUnpackedTree(unpackedRoot, limits: limits)

    // 4. An intact seal on the app bundle. Releases are ad hoc signed, so this
    // proves integrity, not identity; the publisher signature above is the identity.
    let app = package.appendingPathComponent(Self.appName, isDirectory: true)
    let sealed = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", app.path], timeoutSeconds: 120))
    guard sealed.succeeded else {
      throw AppUpdateError.appSignatureInvalid(String(sealed.standardError.prefix(400)))
    }

    // Downloads made here carry no quarantine flag, but clearing it keeps the
    // result identical to the README's manual steps.
    _ = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", package.path], timeoutSeconds: 60))
    let installer = package.appendingPathComponent("Install.command")
    guard Self.fileType(installer.path) == S_IFREG else { throw AppUpdateError.installerMissing }

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

  private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
    let (data, status) = try await fetcher.get(url, accept: "application/octet-stream", maximumBytes: maximumBytes)
    switch status {
    case 200:
      guard data.count <= maximumBytes else { throw AppUpdateError.downloadTooLarge }
      return data
    case 403, 429: throw AppUpdateError.rateLimited
    default: throw AppUpdateError.unavailable(status)
    }
  }

  // MARK: - Archive layout

  /// Lists the archive's entries with zipinfo and validates them before extraction.
  private func inspectArchive(_ archive: URL) async throws {
    let listing = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/zipinfo", arguments: ["-1", archive.path], timeoutSeconds: 60,
      maximumOutputBytes: Self.listingOutputLimit))
    let totals = try await runner.run(ProcessSpecification(
      executable: "/usr/bin/zipinfo", arguments: ["-t", archive.path], timeoutSeconds: 60))
    guard listing.succeeded, totals.succeeded, listing.standardOutput.utf8.count < Self.listingOutputLimit else {
      throw AppUpdateError.archiveRejected("its contents could not be listed")
    }
    var entries = listing.standardOutput.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if entries.last == "" { entries.removeLast() }
    try Self.validateArchive(entries: entries, totals: totals.standardOutput, limits: limits)
  }

  /// The rules for the names `zipinfo -1` prints. Every entry sits under
  /// `Focus Queue Beta/`, or is ditto's `__MACOSX/` metadata for such an entry.
  /// No entry is absolute, uses `.`, `..`, empty components or backslashes,
  /// repeats another entry, or sits beneath a file or symlink entry (which
  /// could redirect the write). Entry count and expanded size stay bounded.
  static func validateArchive(entries: [String], totals: String, limits: Limits) throws {
    guard !entries.isEmpty, entries.count <= limits.archiveEntries else {
      throw AppUpdateError.archiveRejected("it has \(entries.count) entries")
    }
    guard let match = totals.firstMatch(of: #/(\d+) files?, (\d+) bytes uncompressed/#),
          Int(match.1) == entries.count, let expanded = Int64(match.2) else {
      throw AppUpdateError.archiveRejected("its listing is inconsistent")
    }
    guard expanded <= limits.unpackedBytes else {
      throw AppUpdateError.archiveRejected("it expands to \(expanded) bytes")
    }
    var seen = Set<String>()
    var files = Set<String>()
    var targets: [[String]] = []
    for entry in entries {
      guard let placed = archiveEntryTarget(entry) else {
        throw AppUpdateError.archiveRejected("the entry \"\(entry.prefix(160))\" is outside Focus Queue Beta")
      }
      let isDirectory = entry.hasSuffix("/")
      guard seen.insert(folded(isDirectory ? String(entry.dropLast()) : entry)).inserted else {
        throw AppUpdateError.archiveRejected("the entry \"\(entry.prefix(160))\" appears twice")
      }
      if !placed.isMetadata, !isDirectory { files.insert(folded(placed.path.joined(separator: "/"))) }
      targets.append(placed.path)
    }
    for path in targets where path.count > 1 {
      for depth in 1..<path.count where files.contains(folded(path[..<depth].joined(separator: "/"))) {
        throw AppUpdateError.archiveRejected("an entry sits inside the file \"\(path[..<depth].joined(separator: "/"))\"")
      }
    }
  }

  /// The package path an entry writes or annotates, or nil when the entry is
  /// not allowed. ditto applies `__MACOSX/<dir>/._<name>` to `<dir>/<name>`.
  private static func archiveEntryTarget(_ entry: String) -> (path: [String], isMetadata: Bool)? {
    guard !entry.isEmpty, !entry.hasPrefix("/"), !entry.contains("\\") else { return nil }
    let isDirectory = entry.hasSuffix("/")
    var path = (isDirectory ? entry.dropLast() : Substring(entry))
      .split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !path.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
    var isMetadata = false
    if path.first == "__MACOSX" {
      isMetadata = true
      path.removeFirst()
      if path.isEmpty { return isDirectory ? ([packageName], true) : nil }
      if !isDirectory {
        guard let name = path.last, name.hasPrefix("._"), name.count > 2 else { return nil }
        path[path.count - 1] = String(name.dropFirst(2))
      }
    }
    guard path.first == packageName else { return nil }
    // The package root itself must be a folder, never a file or link.
    if path.count == 1, !isDirectory, !isMetadata { return nil }
    return (path, isMetadata)
  }

  /// APFS compares names without case or Unicode normalization differences.
  private static func folded(_ path: String) -> String {
    path.folding(options: .caseInsensitive, locale: nil).precomposedStringWithCanonicalMapping
  }

  /// After ditto: only the package at the top, no special files, no symlink
  /// resolving outside the package, a regular Install.command, and an app folder.
  static func inspectUnpackedTree(_ root: URL, limits: Limits) throws -> URL {
    guard (try? FileManager.default.contentsOfDirectory(atPath: root.path)) == [packageName] else {
      throw AppUpdateError.archiveRejected("it unpacked to unexpected items")
    }
    let package = root.appendingPathComponent(packageName, isDirectory: true)
    guard fileType(package.path) == S_IFDIR, let resolvedPackage = resolvedPath(package.path),
          let walker = FileManager.default.enumerator(atPath: package.path) else {
      throw AppUpdateError.archiveRejected("\(packageName) is not a folder")
    }
    var count = 0
    var bytes: Int64 = 0
    while let relative = walker.nextObject() as? String {
      count += 1
      guard count <= limits.archiveEntries else { throw AppUpdateError.archiveRejected("it unpacked too many files") }
      let path = package.path + "/" + relative
      var info = stat()
      guard lstat(path, &info) == 0 else { throw AppUpdateError.archiveRejected("\(relative) cannot be read") }
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        break
      case S_IFREG:
        bytes += Int64(info.st_size)
        guard bytes <= limits.unpackedBytes else { throw AppUpdateError.archiveRejected("it unpacked too many bytes") }
      case S_IFLNK:
        // realpath follows every link in a chain, so this catches indirect escapes too.
        guard let target = resolvedPath(path), target == resolvedPackage || target.hasPrefix(resolvedPackage + "/") else {
          throw AppUpdateError.archiveRejected("the link \(relative) points outside the package")
        }
      default:
        throw AppUpdateError.archiveRejected("\(relative) is not a file or folder")
      }
    }
    guard fileType(package.appendingPathComponent("Install.command").path) == S_IFREG else {
      throw AppUpdateError.installerMissing
    }
    guard fileType(package.appendingPathComponent(appName).path) == S_IFDIR else {
      throw AppUpdateError.archiveRejected("it does not contain \(appName)")
    }
    return package
  }

  /// The item's own type, without following a final symlink; nil when missing.
  static func fileType(_ path: String) -> mode_t? {
    var info = stat()
    return lstat(path, &info) == 0 ? info.st_mode & S_IFMT : nil
  }

  private static func resolvedPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}
