import FocusQueueCore
import SwiftUI

struct TerminalBrowserView: View {
  let model: QueueViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var panes: [WezTermPane] = []
  @State private var search = ""
  @State private var isLoading = false
  @State private var error: String?
  @State private var selectedPaneID: Int?
  @State private var openingPaneID: Int?

  private var visiblePanes: [WezTermPane] {
    panes.filter { pane in
      search.isEmpty || [pane.tabTitle, pane.windowTitle, pane.title, pane.cwd]
        .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Open terminals").font(.title2.bold())
        Spacer()
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await reload() } }
          .disabled(isLoading)
        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
      }
      Text("Browse WezTerm windows and panes. Choose View to bring that exact terminal forward.")
        .font(.callout).foregroundStyle(.secondary)
      TextField("Filter by task, title, or directory", text: $search).textFieldStyle(.roundedBorder)
      if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
      if isLoading { ProgressView("Reading open terminals…") }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(visiblePanes, id: \.paneID) { pane in
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: selectedPaneID == pane.paneID ? "arrow.up.right.square.fill" : "terminal")
              VStack(alignment: .leading, spacing: 4) {
                Text(pane.tabTitle ?? pane.title ?? "Terminal \(pane.paneID)").font(.headline)
                Text("Window \(pane.windowID) · Tab \(pane.tabID.map(String.init) ?? "?") · Pane \(pane.paneID)")
                  .font(.caption).foregroundStyle(.secondary)
                Text(pane.cwd).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let session = model.localState.agentSessions.first(where: { $0.paneID == pane.paneID }) {
                  Text("Saved association: \(session.ticketID) · \(session.provider.displayName)").font(.caption)
                }
              }.frame(maxWidth: .infinity, alignment: .leading)
              Button {
                openingPaneID = pane.paneID
                Task {
                  defer { openingPaneID = nil }
                  do { try await model.focusTerminalPane(pane); selectedPaneID = pane.paneID; error = nil }
                  catch { self.error = error.localizedDescription }
                }
              } label: {
                if openingPaneID == pane.paneID {
                  HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Opening…")
                  }
                } else {
                  Text("View")
                }
              }.buttonStyle(.bordered).disabled(openingPaneID != nil)
                .accessibilityLabel("View window \(pane.windowID), pane \(pane.paneID)")
            }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
          }
          if visiblePanes.isEmpty && !isLoading && error == nil {
            Text(search.isEmpty ? "No open WezTerm panes were found." : "No terminals match this filter.")
              .foregroundStyle(.secondary).padding()
          }
        }
      }
      Text("Saved Codex and Claude conversations can usually be resumed from their task. Closing a terminal can still stop running work or lose unsaved shell state.")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(20).frame(width: 620, height: 520).task { await reload() }
  }

  private func reload() async {
    guard !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      panes = try await model.availableTerminals().sorted {
        ($0.windowID, $0.tabID ?? 0, $0.paneID) < ($1.windowID, $1.tabID ?? 0, $1.paneID)
      }
      error = nil
    } catch { self.error = error.localizedDescription }
  }
}
