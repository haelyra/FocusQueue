import CryptoKit
import Foundation

/// Publisher authentication for app updates.
///
/// Each release publishes `<archive>.sig` next to `<archive>.sha256`: a raw
/// 64-byte Ed25519 signature over `manifest(archiveName:sha256Hex:)`. The
/// updater runs nothing from a release unless one of `trustedPublicKeys`
/// verifies that signature. `Scripts/sign-release.swift` builds the same
/// manifest; `ReleaseSigningTests` checks that the two agree.
public enum ReleaseSigning {
  /// Base64 of each trusted publisher's raw 32-byte Curve25519 signing public
  /// key, as printed by `swift Scripts/sign-release.swift public-key`. Keep the
  /// old key listed while rotating to a new one. Entries that do not parse are
  /// ignored, so this placeholder trusts nothing and every update fails closed.
  public static let trustedPublicKeys: [String] = [
    "REPLACE_WITH_PUBLISHER_KEY",
  ]

  public static let signatureLength = 64

  /// The signed bytes, version 1: a format line, the archive's file name
  /// (which carries the version and architecture), and its lowercase SHA-256
  /// hex digest, each ending in a newline. Naming the archive stops an older
  /// genuine archive from being republished under a newer release's name.
  public static func manifest(archiveName: String, sha256Hex: String) -> Data {
    Data("focus-queue-release-v1\n\(archiveName)\n\(sha256Hex.lowercased())\n".utf8)
  }

  /// The keys that parse; malformed entries such as the placeholder are dropped.
  public static func publicKeys(_ encoded: [String]) -> [Curve25519.Signing.PublicKey] {
    encoded.compactMap { text in
      guard let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            raw.count == 32 else { return nil }
      return try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
    }
  }

  /// True when any of `keys` signed this archive name and digest.
  public static func isValid(signature: Data, archiveName: String, sha256Hex: String,
                             keys: [Curve25519.Signing.PublicKey]) -> Bool {
    guard signature.count == signatureLength else { return false }
    let message = manifest(archiveName: archiveName, sha256Hex: sha256Hex)
    return keys.contains { $0.isValidSignature(signature, for: message) }
  }
}
