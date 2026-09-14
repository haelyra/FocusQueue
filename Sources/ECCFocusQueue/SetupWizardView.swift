import AppKit
import FocusQueueCore
import SwiftUI
import UniformTypeIdentifiers

struct SetupWizardView: View {
  let model: QueueViewModel
  @State private var draft: AppConfiguration
  @State private var step = 0
  @State private var saving = false
  @State private var sshHost = ""
  @State private var sessions: [TmuxSessionReference] = []
  @State private var terminalMessage: String?
  @State private var inspecting = false

  init(model: QueueViewModel) {
    self.model = model
    _draft = State(initialValue: model.config)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Set up Focus Queue").font(.title2.bold())
      Text(["1 of 3 · Your workspace", "2 of 3 · Terminals and remote access", "3 of 3 · Review setup"][step])
        .foregroundStyle(.secondary)
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if step == 0 { workspace }
          else if step == 1 { terminals }
          else { review }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if let error = model.setupError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("Close") { model.isSetupPresented = false }.keyboardShortcut(.cancelAction)
        Spacer()
        if step > 0 { Button("Back") { step -= 1 } }
        Button(step == 2 ? "Save setup" : "Continue") {
          if step < 2 { step += 1 }
          else {
            saving = true
            Task { _ = await model.finishSetup(draft); saving = false }
          }
        }.buttonStyle(.borderedProminent).disabled(saving).keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 610, height: 600)
  }

  private var workspace: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Start with the empty local queue, or choose an existing workspace and JSON dashboard. Existing task data is preserved.")
      TextField("Workspace folder", text: $draft.workspacePath)
      Button("Choose workspace…") {
        choose(directory: true) { url in
          draft.workspacePath = url.path
          draft.dashboardPath = url.appendingPathComponent("dashboard.json").path
        }
      }
      TextField("Dashboard JSON", text: $draft.dashboardPath)
      Button("Choose existing dashboard…") { choose(directory: false) { draft.dashboardPath = $0.path } }
      Text("A missing dashboard.json directly in the chosen workspace is created as an empty queue. Other missing paths require a correction.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  private var terminals: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(SetupEnvironment.terminalCapabilities, id: \.name) { item in
        VStack(alignment: .leading, spacing: 3) {
          Text(item.name).font(.headline)
          Text(item.support).font(.callout).foregroundStyle(.secondary)
        }
      }
      TextField("WezTerm executable", text: $draft.wezTerm.executable)
      Button("Install command-line helper") {
        do {
          guard let executable = Bundle.main.executableURL else { return }
          let source = executable.deletingLastPathComponent().appendingPathComponent("focus-queue-session")
          let destination = try SetupEnvironment.installSessionHelper(source: source)
          terminalMessage = "Helper available at \(destination.path). Add $HOME/.local/bin to PATH in your terminal, or use the full path below."
        } catch { terminalMessage = error.localizedDescription }
      }
      Text(FileManager.default.isExecutableFile(atPath: draft.wezTerm.executable)
        ? "WezTerm executable detected. Live connection is checked when used."
        : "WezTerm is optional for viewing your queue. Install it to use desktop agent controls.")
        .font(.caption).foregroundStyle(.secondary)
      Label("Optional tmux persistence", systemImage: "rectangle.stack.badge.play")
        .font(.headline)
      TextField("tmux executable", text: Binding(
        get: { draft.tmuxExecutable ?? SetupEnvironment.executable("tmux") ?? "" },
        set: { draft.tmuxExecutable = $0; draft.persistentTerminals = true }))
      Text("New Agent uses tmux by default when this executable is available. Each launch can turn it off. With tmux enabled, closing the terminal view leaves the process running and clicking the named subtask reattaches that exact session. Reboot ends running processes.")
        .font(.callout)
      DisclosureGroup("Connect from another location") {
        VStack(alignment: .leading, spacing: 10) {
          Text("Connect both devices to your tailnet. On the host Mac, configure Remote Login for your account and verify its SSH host key from your other device. The standard Tailscale macOS app uses ordinary SSH over the private network.")
          Text("Then use an SSH terminal to connect to this Mac and run focus-queue-session tmux list followed by focus-queue-session tmux attach <session-name>.")
          Text("Tailscale: \(SetupEnvironment.executable("tailscale") == nil ? "CLI not detected; app or network status unverified" : "executable detected; login and reachability unverified")")
          Link("Tailscale SSH requirements", destination: URL(string: "https://tailscale.com/docs/features/tailscale-ssh")!)
          TextField("SSH alias or user@host", text: $sshHost)
          Button(inspecting ? "Checking sessions…" : "List running tmux sessions") {
            inspecting = true
            Task {
              defer { inspecting = false }
              do {
                guard let executable = draft.tmuxExecutable ?? SetupEnvironment.executable("tmux") else {
                  throw TmuxError.unavailable("Install tmux on this Mac first.")
                }
                sessions = try await TmuxController().list(executable: executable)
                terminalMessage = sessions.isEmpty ? "No persistent sessions are running. Save setup and launch a new agent with tmux checked." : nil
              } catch { terminalMessage = error.localizedDescription }
            }
          }.disabled(inspecting)
          ForEach(sessions, id: \.name) { session in
            VStack(alignment: .leading, spacing: 6) {
              Text(session.name).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
              HStack {
                Button("Copy local attach") {
                  copy("\"$HOME/.local/bin/focus-queue-session\" tmux attach \(session.name)")
                }
                Button("Copy SSH command") {
                  do { copy(try TmuxController.sshCommand(host: sshHost, name: session.name)) }
                  catch { terminalMessage = error.localizedDescription }
                }.disabled(sshHost.isEmpty)
              }
            }
          }
        }.font(.callout).padding(.top, 8)
      }
      if let terminalMessage { Text(terminalMessage).font(.callout).textSelection(.enabled) }
    }
  }

  private var review: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Workspace: \(draft.workspacePath)").textSelection(.enabled)
      Text("Dashboard: \(draft.dashboardPath)").textSelection(.enabled)
      Text("New Agent defaults to tmux when available; each launch can run directly instead.")
      Text("Saving validates your dashboard and updates the app configuration. Basic queue setup uses zero model tokens.")
      Text("Mail, scheduled reports, provider authentication, SSH access and Tailscale enrollment require their own configuration. This wizard leaves those services under your control.")
        .foregroundStyle(.secondary)
    }
  }

  private func choose(directory: Bool, selection: (URL) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directory
    panel.canChooseFiles = !directory
    panel.allowsMultipleSelection = false
    if !directory { panel.allowedContentTypes = [.json] }
    if panel.runModal() == .OK, let url = panel.url { selection(url) }
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
    terminalMessage = "Command copied. SSH connection and authentication are checked when you run it in your terminal."
  }
}
