// Ed25519 release signing for the Focus Queue in-app updater (CryptoKit only).
//
//   swift Scripts/sign-release.swift keygen
//   swift Scripts/sign-release.swift public-key
//   swift Scripts/sign-release.swift sign <archive.zip>
//   swift Scripts/sign-release.swift verify <archive.zip> <public-key-base64>
//
// The private key is base64 of a raw 32-byte Curve25519 signing key, kept in
// the login Keychain as a generic password (service "Focus Queue Release
// Signing", account "ed25519"). When FOCUS_QUEUE_RELEASE_SIGNING_KEY_FILE is
// set, that file holds the key instead and the Keychain is never touched.
//
// `sign` confirms <archive>.sha256 matches the archive, then writes
// <archive>.sig: a raw 64-byte signature over the release manifest below.

import CryptoKit
import Foundation

// MARK: Release manifest, version 1
// Must stay byte-identical to ReleaseSigning.manifest in
// Sources/FocusQueueCore/ReleaseSigning.swift; ReleaseSigningTests checks that they agree.
func releaseManifest(archiveName: String, sha256Hex: String) -> Data {
  Data("focus-queue-release-v1\n\(archiveName)\n\(sha256Hex.lowercased())\n".utf8)
}

let keychainService = "Focus Queue Release Signing"
let keychainAccount = "ed25519"
let keyFileVariable = "FOCUS_QUEUE_RELEASE_SIGNING_KEY_FILE"
let usage = """
  usage: swift Scripts/sign-release.swift keygen
         swift Scripts/sign-release.swift public-key
         swift Scripts/sign-release.swift sign <archive.zip>
         swift Scripts/sign-release.swift verify <archive.zip> <public-key-base64>
  """

func fail(_ message: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write(Data("sign-release: \(message)\n".utf8))
  exit(code)
}

/// Runs /usr/bin/security. Secrets travel on stdin (`security -i`), never in argv.
func security(_ arguments: [String], input: String? = nil) -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
  process.arguments = arguments
  let output = Pipe()
  let commands = Pipe()
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  process.standardInput = input == nil ? FileHandle.nullDevice : commands
  do { try process.run() } catch { fail("cannot run /usr/bin/security: \(error.localizedDescription)") }
  if let input {
    commands.fileHandleForWriting.write(Data(input.utf8))
    try? commands.fileHandleForWriting.close()
  }
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

var keyFile: String? {
  guard let path = ProcessInfo.processInfo.environment[keyFileVariable], !path.isEmpty else { return nil }
  return path
}

func decodeKey(_ text: String, source: String) -> Curve25519.Signing.PrivateKey {
  guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
        let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    fail("\(source) does not hold a base64 32-byte Ed25519 private key")
  }
  return key
}

func storedKey() -> Curve25519.Signing.PrivateKey {
  if let path = keyFile {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      fail("no signing key at \(path) (\(keyFileVariable))")
    }
    return decodeKey(text, source: path)
  }
  let found = security(["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"])
  guard found.status == 0 else {
    fail("no signing key in the login Keychain (service \"\(keychainService)\", account \"\(keychainAccount)\"); "
      + "run `swift Scripts/sign-release.swift keygen` once")
  }
  return decodeKey(found.output, source: "the Keychain item")
}

func keygen() {
  let key = Curve25519.Signing.PrivateKey()
  let secret = key.rawRepresentation.base64EncodedString()
  if let path = keyFile {
    guard !FileManager.default.fileExists(atPath: path) else { fail("\(path) already exists; refusing to overwrite it") }
    guard FileManager.default.createFile(atPath: path, contents: Data((secret + "\n").utf8),
                                         attributes: [.posixPermissions: 0o600]) else {
      fail("cannot write \(path)")
    }
  } else {
    guard security(["find-generic-password", "-s", keychainService, "-a", keychainAccount]).status != 0 else {
      fail("the login Keychain already has a \"\(keychainService)\" key; refusing to overwrite it")
    }
    // Without -U, add-generic-password also refuses to replace an existing item.
    let command = "add-generic-password -s \"\(keychainService)\" -a \(keychainAccount)"
      + " -l \"\(keychainService) (Ed25519 private key)\" -w \"\(secret)\"\n"
    guard security(["-i"], input: command).status == 0,
          security(["find-generic-password", "-s", keychainService, "-a", keychainAccount, "-w"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines) == secret else {
      fail("could not store the key in the login Keychain")
    }
  }
  print(key.publicKey.rawRepresentation.base64EncodedString())
}

/// The archive's SHA-256, read in chunks so large archives are not loaded whole.
func digest(of path: String) -> String {
  guard let handle = FileHandle(forReadingAtPath: path) else { fail("cannot read \(path)") }
  defer { try? handle.close() }
  var hash = SHA256()
  while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
  return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// The digest in <archive>.sha256, after checking it matches the archive itself.
func publishedDigest(archive: String) -> String {
  let checksumFile = archive + ".sha256"
  guard let text = try? String(contentsOfFile: checksumFile, encoding: .utf8),
        let first = text.split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }),
        first.count == 64, first.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
    fail("\(checksumFile) is missing or has no SHA-256 digest")
  }
  guard digest(of: archive) == first else { fail("\(checksumFile) does not match \(archive)") }
  return first
}

func sign(archive: String) {
  let key = storedKey()
  let manifest = releaseManifest(archiveName: (archive as NSString).lastPathComponent,
                                 sha256Hex: publishedDigest(archive: archive))
  guard let signature = try? key.signature(for: manifest), signature.count == 64,
        key.publicKey.isValidSignature(signature, for: manifest) else { fail("signing failed") }
  do {
    try signature.write(to: URL(fileURLWithPath: archive + ".sig"), options: .atomic)
  } catch {
    fail("cannot write \(archive).sig: \(error.localizedDescription)")
  }
  print(archive + ".sig")
}

func verify(archive: String, publicKey: String) {
  guard let raw = Data(base64Encoded: publicKey.trimmingCharacters(in: .whitespacesAndNewlines)), raw.count == 32,
        let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
    fail("the public key is not base64 of 32 bytes")
  }
  let manifest = releaseManifest(archiveName: (archive as NSString).lastPathComponent,
                                 sha256Hex: publishedDigest(archive: archive))
  guard let signature = FileManager.default.contents(atPath: archive + ".sig"), signature.count == 64 else {
    fail("\(archive).sig is missing or is not 64 bytes")
  }
  guard key.isValidSignature(signature, for: manifest) else { fail("the signature does not verify with that key") }
  print("verified \((archive as NSString).lastPathComponent)")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("keygen", 1): keygen()
case ("public-key", 1): print(storedKey().publicKey.rawRepresentation.base64EncodedString())
case ("sign", 2): sign(archive: arguments[1])
case ("verify", 3): verify(archive: arguments[1], publicKey: arguments[2])
default: fail(usage, code: 2)
}
