import FocusQueueCore
import Foundation

struct ConnectorDiagnostic: Decodable, Equatable, Identifiable, Sendable {
  let id: String
  let status: String
  let coverage: String
  let nextStep: String
  let personalInboxSupported: Bool?
  let activeArchiveConfigured: Bool?
  let accountSwitchSupported: Bool?

  var statusLabel: String {
    switch status {
    case "configured_unverified": "Configured, not verified"
    case "setup_required": "Setup required"
    case "limited": "Limited coverage"
    default: status.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}

struct ConnectorDiagnosticsSnapshot: Decodable, Equatable, Sendable {
  let version: Int
  let mode: String
  let authenticationVerified: Bool?
  /// False when ingestion.json does not exist yet, as on a new install.
  let configurationPresent: Bool?
  let connectors: [ConnectorDiagnostic]

  func diagnostic(for platform: DailyReportPlatform) -> ConnectorDiagnostic? {
    connectors.first { $0.id == platform.rawValue }
  }
}
