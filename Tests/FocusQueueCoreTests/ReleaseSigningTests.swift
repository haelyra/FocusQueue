import CryptoKit
import Foundation
import Testing
@testable import FocusQueueCore

@Suite("Release signing")
struct ReleaseSigningTests {
  private static let placeholder = "REPLACE_WITH_PUBLISHER_KEY"
  private let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Scripts/sign-release.swift")

  @Test("The manifest is the documented v1 text")
  func manifestFormat() {
    let manifest = ReleaseSigning.manifest(archiveName: "FocusQueue-0.3.6-beta-arm64.zip", sha256Hex: "AB" + String(repeating: "0", count: 62))
    #expect(String(decoding: manifest, as: UTF8.self)
      == "focus-queue-release-v1\nFocusQueue-0.3.6-beta-arm64.zip\nab\(String(repeating: "0", count: 62))\n")
  }

  @Test("Malformed keys, including the placeholder, are ignored, so an unconfigured build trusts nothing")
  func keyParsing() {
    let valid = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    #expect(ReleaseSigning.publicKeys([Self.placeholder, "", "AAAA", Data(count: 31).base64EncodedString()]).isEmpty)
    #expect(ReleaseSigning.publicKeys([Self.placeholder, " \(valid)\n"]).count == 1)
  }

  @Test("Every embedded publisher key parses, so a mistyped key cannot silently disable updates")
  func embeddedKeys() {
    let configured = ReleaseSigning.trustedPublicKeys.filter { $0 != Self.placeholder }
    #expect(ReleaseSigning.publicKeys(configured).count == configured.count)
  }

  @Test("Only the signed archive name and digest verify")
  func verification() {
    let key = Curve25519.Signing.PrivateKey()
    let digest = String(repeating: "a", count: 64)
    let name = "FocusQueue-0.3.6-beta-arm64.zip"
    let signature = try! key.signature(for: ReleaseSigning.manifest(archiveName: name, sha256Hex: digest))
    let keys = [key.publicKey]
    #expect(ReleaseSigning.isValid(signature: signature, archiveName: name, sha256Hex: digest, keys: keys))
    #expect(!ReleaseSigning.isValid(signature: signature, archiveName: "FocusQueue-0.3.7-beta-arm64.zip",
                                    sha256Hex: digest, keys: keys))
    #expect(!ReleaseSigning.isValid(signature: signature, archiveName: name,
                                    sha256Hex: String(repeating: "b", count: 64), keys: keys))
    #expect(!ReleaseSigning.isValid(signature: signature, archiveName: name, sha256Hex: digest,
                                    keys: [Curve25519.Signing.PrivateKey().publicKey]))
    #expect(!ReleaseSigning.isValid(signature: signature, archiveName: name, sha256Hex: digest, keys: []))
  }

  private func runScript(_ arguments: [String], keyFile: URL) async throws -> ProcessResult {
    try await FoundationProcessRunner().run(ProcessSpecification(
      executable: "/usr/bin/swift", arguments: [script.path] + arguments,
      environment: ["FOCUS_QUEUE_RELEASE_SIGNING_KEY_FILE": keyFile.path], timeoutSeconds: 180))
  }

  @Test("Scripts/sign-release.swift and ReleaseSigning build the same manifest", .timeLimit(.minutes(5)))
  func scriptAgreement() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("release-signing-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // A throwaway key in a file: the script never touches the Keychain in this mode.
    let key = Curve25519.Signing.PrivateKey()
    let keyFile = root.appendingPathComponent("signing-key")
    try Data((key.rawRepresentation.base64EncodedString() + "\n").utf8).write(to: keyFile)
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let name = "FocusQueue-0.3.6-beta-arm64.zip"
    let archive = root.appendingPathComponent(name)
    let bytes = Data("release archive bytes".utf8)
    try bytes.write(to: archive)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    try Data("\(digest)  \(name)\n".utf8).write(to: root.appendingPathComponent(name + ".sha256"))

    let printed = try await runScript(["public-key"], keyFile: keyFile)
    #expect(printed.succeeded, "\(printed.standardError)")
    #expect(printed.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines) == publicKey)

    // Script signs, core verifies.
    let signed = try await runScript(["sign", archive.path], keyFile: keyFile)
    #expect(signed.succeeded, "\(signed.standardError)")
    let signature = try Data(contentsOf: root.appendingPathComponent(name + ".sig"))
    #expect(ReleaseSigning.isValid(signature: signature, archiveName: name, sha256Hex: digest,
                                   keys: ReleaseSigning.publicKeys([publicKey])))

    // Core signs, script verifies; a different key does not.
    let coreSignature = try key.signature(for: ReleaseSigning.manifest(archiveName: name, sha256Hex: digest))
    try coreSignature.write(to: root.appendingPathComponent(name + ".sig"))
    let verified = try await runScript(["verify", archive.path, publicKey], keyFile: keyFile)
    #expect(verified.succeeded, "\(verified.standardError)")
    let otherKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
    let rejected = try await runScript(["verify", archive.path, otherKey], keyFile: keyFile)
    #expect(rejected.exitCode == 1)

    // keygen never overwrites an existing key.
    let keygen = try await runScript(["keygen"], keyFile: keyFile)
    #expect(keygen.exitCode == 1)
    #expect(try Data(contentsOf: keyFile) == Data((key.rawRepresentation.base64EncodedString() + "\n").utf8))
  }
}
