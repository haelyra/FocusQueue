import FocusQueueCore
import SwiftUI

/// Settings for running agents in T3 Code: the runtime choice, the server, and
/// the connection. T3 Code is usable only when connected with Full access.
struct T3SettingsView: View {
  let model: QueueViewModel
  @State private var serverURL = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker("Run new agents in", selection: Binding(
        get: { model.config.agentRuntime ?? .terminal },
        set: { model.setAgentRuntime($0) }
      )) {
        Text("Terminal").tag(AgentRuntimeChoice.terminal)
        Text("T3 Code").tag(AgentRuntimeChoice.t3)
          .disabled(!model.t3RuntimeAvailable)
      }
      .pickerStyle(.segmented)
      Text("Agents already running keep their runtime. Only new launches use this choice.")
        .font(.caption).foregroundStyle(.secondary)

      HStack(spacing: 8) {
        TextField("Server", text: $serverURL, prompt: Text(T3Defaults.serverURL))
          .textFieldStyle(.roundedBorder)
          .onSubmit { Task { await model.setT3ServerURL(serverURL) } }
        Button("Save") { Task { await model.setT3ServerURL(serverURL) } }
          .disabled(serverURL == (model.config.t3ServerURL ?? ""))
      }
      if !serverURL.isEmpty, !T3StatusText.isAcceptableServerURL(serverURL) {
        Text(T3StatusText.insecureURLMessage).font(.caption).foregroundStyle(.red)
      }

      HStack(spacing: 8) {
        Circle().fill(statusColor).frame(width: 8, height: 8)
        Text(model.t3StatusText).font(.callout)
        Spacer()
        if model.isT3SigningIn {
          Button("Cancel") { model.cancelT3SignIn() }
        } else if model.t3Status.connectedEnvironmentId != nil || model.t3Status == .accessTooLow
                    || model.t3Status == .unreachable {
          Button("Disconnect") { model.disconnectT3() }
          if model.t3Status != .unreachable, model.t3Status.connectedEnvironmentId == nil {
            Button("Reconnect") { model.connectT3() }
          }
        } else {
          Button(model.t3Status == .unauthorized ? "Reconnect" : "Connect") { model.connectT3() }
        }
      }
      if case .otherServer = model.t3Status {
        HStack(spacing: 8) {
          Text("This server is not the one your existing T3 Code agents run on. Use it for new agents? Existing agents stay listed but can only be controlled from their own server.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button("Use this server") { model.useThisT3Server() }
        }
      }
      if model.t3Status.connectedEnvironmentId == nil {
        Text(T3StatusText.fullAccessNote).font(.caption).foregroundStyle(.secondary)
      }
      if let scope = model.t3ConnectionState?.grantedScope, !scope.isEmpty,
         model.t3Status.connectedEnvironmentId != nil || model.t3Status == .accessTooLow {
        Text("Granted access: \(scope)").font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
      }
      if let message = model.t3Message {
        Text(message).font(.caption).foregroundStyle(.secondary)
      }
      Text("Focus Queue cannot approve permission requests in T3 Code. Agents waiting on approval show Needs approval; open them in T3 Code.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .onAppear { serverURL = model.config.t3ServerURL ?? "" }
    .task { _ = await model.t3() }
  }

  private var statusColor: Color {
    switch model.t3Status {
    case .connected: model.t3RuntimeAvailable ? .green : .orange
    case .signingIn: .yellow
    case .disconnected: .secondary
    default: .red
    }
  }
}
