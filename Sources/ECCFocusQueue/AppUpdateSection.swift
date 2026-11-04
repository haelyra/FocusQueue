import AppKit
import FocusQueueCore
import Observation
import SwiftUI

/// Checks GitHub for a newer beta release and installs it on request.
@MainActor
@Observable
final class AppUpdateModel {
  enum Status: Equatable {
    case idle
    case checking
    case upToDate
    case available(AppRelease)
    case installing
    case failed(String)
  }

  /// One model for the app's lifetime, so the hourly limit holds across Settings visits.
  static let shared = AppUpdateModel()
  static let automaticCheckInterval: TimeInterval = 3_600

  /// Nil for a development build, which has no installed release to replace.
  let currentVersion: String?
  private(set) var status = Status.idle
  private(set) var lastCheck: Date?
  /// Drives the "is available" popup.
  var promptedRelease: AppRelease?
  /// "Later" hides the popup for that version until the app restarts.
  private var dismissedVersion: String?
  @ObservationIgnored private let updater: AppUpdater

  init(
    currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
    updater: AppUpdater = AppUpdater()
  ) {
    self.currentVersion = currentVersion
    self.updater = updater
  }

  var availableRelease: AppRelease? {
    if case .available(let release) = status { return release }
    return nil
  }

  /// Runs when Settings appears; skips if the last check was under an hour ago.
  func checkIfDue(now: Date = Date()) async {
    if let lastCheck, now.timeIntervalSince(lastCheck) < Self.automaticCheckInterval { return }
    await check(now: now)
  }

  func check(now: Date = Date()) async {
    guard let currentVersion, status != .checking, status != .installing else { return }
    status = .checking
    lastCheck = now
    do {
      if let release = try await updater.availableUpdate(currentVersion: currentVersion) {
        status = .available(release)
        if release.version != dismissedVersion { promptedRelease = release }
      } else {
        status = .upToDate
      }
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  func later() {
    dismissedVersion = promptedRelease?.version
    promptedRelease = nil
  }

  /// The installer quits and reopens Focus Queue, so success ends this process.
  func install() async {
    guard let release = availableRelease ?? promptedRelease else { return }
    promptedRelease = nil
    status = .installing
    do {
      try await updater.install(release)
    } catch {
      status = .failed(error.localizedDescription)
    }
  }

  /// A short plain-text excerpt of the release notes for the popup.
  static func excerpt(_ notes: String, limit: Int = 420) -> String {
    let plain = notes
      .replacingOccurrences(of: "**", with: "")
      .replacingOccurrences(of: "`", with: "")
      .split(separator: "\n", omittingEmptySubsequences: true)
      .prefix { !$0.hasPrefix("```") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .joined(separator: "\n")
    return plain.count > limit ? String(plain.prefix(limit)) + "…" : plain
  }
}

/// Settings content: version, update status, Check for updates, and the
/// install popup. Wrap it in the Settings section chrome where it is mounted.
struct AppUpdateSection: View {
  @Bindable var model: AppUpdateModel

  init(model: AppUpdateModel = .shared) {
    self.model = model
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Text(model.currentVersion.map { "Version \($0)" } ?? "Development build")
          .font(.system(size: 13, weight: .semibold))
        Spacer()
        if let release = model.availableRelease {
          Button("Install \(release.version)", systemImage: "arrow.down.circle.fill") {
            Task { await model.install() }
          }
          .buttonStyle(.borderedProminent).controlSize(.small)
        }
        Button(model.status == .checking ? "Checking…" : "Check for updates", systemImage: "arrow.clockwise") {
          Task { await model.check() }
        }
        .controlSize(.small)
        .disabled(model.currentVersion == nil || model.status == .checking || model.status == .installing)
      }
      if model.status == .installing { ProgressView().controlSize(.small) }
      Text(statusText).font(.system(size: 11)).foregroundStyle(statusIsError ? .orange : .secondary)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
    .task { await model.checkIfDue() }
    .alert(
      model.promptedRelease.map { "Focus Queue \($0.version) is available" } ?? "",
      isPresented: Binding(get: { model.promptedRelease != nil }, set: { if !$0 { model.later() } }),
      presenting: model.promptedRelease
    ) { _ in
      Button("Install update") { Task { await model.install() } }
      Button("Later", role: .cancel) { model.later() }
    } message: { release in
      Text(AppUpdateModel.excerpt(release.notes)
        + "\n\nFocus Queue quits, installs the update, and opens again. Your projects and settings are kept.")
    }
  }

  private var statusIsError: Bool {
    if case .failed = model.status { return true }
    return false
  }

  private var statusText: String {
    switch model.status {
    case .idle:
      model.currentVersion == nil ? "Updates apply to installed releases only." : "Checks GitHub for new beta releases."
    case .checking: "Checking GitHub for a newer release…"
    case .upToDate: "Focus Queue is up to date."
    case .available(let release): "\(release.title) is available."
    case .installing: "Installing. Focus Queue will quit and open again in a few seconds."
    case .failed(let reason): reason
    }
  }
}
