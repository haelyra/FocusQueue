import FocusQueueCore
import SwiftUI

/// Settings for the small-model placement call `fq` makes before launching an
/// agent: whether it runs, which provider runs it, and each provider's model
/// and effort. Blank selections keep the built-in defaults.
struct PlacementSettingsView: View {
  let model: QueueViewModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Toggle("Place fq launches with a small model", isOn: Binding(
        get: { model.placementModelEnabled },
        set: { model.setPlacementModelEnabled($0) }))

      Group {
        CoreAgentProviderPicker(
          title: "Run placement on",
          followTitle: "Launched agent's provider",
          selection: Binding(
            get: { model.config.placementProvider },
            set: { model.setPlacementProvider($0) }))

        CoreAgentModelRows(
          model: model,
          purpose: "placement",
          provider: model.config.placementProvider,
          storedModel: { model.config.placementModels[$0] },
          defaultModel: { AppConfiguration.defaultPlacementModels[$0] },
          storedEffort: { model.config.placementEfforts[$0] },
          defaultEffort: { AppConfiguration.defaultPlacementEfforts[$0] },
          setModel: { model.setPlacementModel($0, for: $1) },
          setEffort: { model.setPlacementEffort($0, for: $1) })

        Stepper(value: Binding(
          get: { model.placementConfidenceThreshold },
          set: { model.setPlacementConfidenceThreshold($0) }
        ), in: 0.5...0.95, step: 0.05) {
          HStack {
            Text("Join an existing task at confidence")
            Spacer()
            Text(model.placementConfidenceThreshold.formatted(.number.precision(.fractionLength(2))))
              .monospacedDigit().foregroundStyle(.secondary)
          }
        }

        Stepper(value: Binding(
          get: { model.placementTimeoutSeconds },
          set: { model.setPlacementTimeoutSeconds($0) }
        ), in: 5...60, step: 5) {
          HStack {
            Text("Fall back to heuristics after")
            Spacer()
            Text("\(model.placementTimeoutSeconds) s").monospacedDigit().foregroundStyle(.secondary)
          }
        }
      }.disabled(!model.placementModelEnabled)

      Text("Below the confidence threshold, fq creates a new titled task instead of joining. Kimi has no effort flag.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

/// "Which provider runs this core agent": a follow-another-setting choice plus
/// each provider.
struct CoreAgentProviderPicker: View {
  let title: String
  let followTitle: String
  @Binding var selection: AgentProvider?

  var body: some View {
    Picker(title, selection: $selection) {
      Text(followTitle).tag(AgentProvider?.none)
      ForEach(AgentProvider.allCases, id: \.self) { provider in
        provider.label().tag(AgentProvider?.some(provider))
      }
    }
  }
}

/// Model and effort pickers for a core agent's small model call. A chosen
/// provider shows only its own row; following another provider shows every
/// provider, since any of them may run the call.
struct CoreAgentModelRows: View {
  let model: QueueViewModel
  /// Lowercase noun for accessibility labels, such as "placement".
  let purpose: String
  let provider: AgentProvider?
  let storedModel: (AgentProvider) -> String?
  let defaultModel: (AgentProvider) -> String?
  let storedEffort: (AgentProvider) -> String?
  let defaultEffort: (AgentProvider) -> String?
  let setModel: (String, AgentProvider) -> Void
  let setEffort: (String, AgentProvider) -> Void

  var body: some View {
    ForEach(provider.map { [$0] } ?? AgentProvider.allCases, id: \.self) { provider in
      VStack(alignment: .leading, spacing: 4) {
        provider.label()
          .font(.system(size: 12, weight: .semibold))
        HStack(spacing: 8) {
          modelPicker(for: provider)
          if provider != .kimi { effortPicker(for: provider) }
        }
      }
    }
  }

  private func modelPicker(for provider: AgentProvider) -> some View {
    Picker("\(provider.displayName) \(purpose) model", selection: Binding(
      get: { storedModel(provider) ?? "" },
      set: { setModel($0, provider) }
    )) {
      let builtIn = defaultModel(provider)
      let choices = choices(for: provider)
      Text("Default · \(choices.first { $0.model == builtIn }?.label ?? builtIn ?? "provider")").tag("")
      ForEach(choices) { choice in
        Text(choice.label).tag(choice.model ?? "")
      }
    }.labelsHidden()
  }

  private func effortPicker(for provider: AgentProvider) -> some View {
    Picker("\(provider.displayName) \(purpose) effort", selection: Binding(
      get: { storedEffort(provider) ?? "" },
      set: { setEffort($0, provider) }
    )) {
      Text("Default · \(defaultEffort(provider) ?? "none")").tag("")
      ForEach(AppConfiguration.agentEffortLevels, id: \.self) { effort in
        Text(effort).tag(effort)
      }
    }.labelsHidden().frame(maxWidth: 130)
  }

  /// Placement's small-model list plus any saved model it lacks, so a saved
  /// choice always shows as selected.
  private func choices(for provider: AgentProvider) -> [AgentModelChoice] {
    var choices = model.placementModelChoices(for: provider)
    for saved in [defaultModel(provider), storedModel(provider)] {
      if let saved, !choices.contains(where: { $0.model == saved }) {
        choices.append(AgentModelChoice(provider: provider, label: saved, model: saved))
      }
    }
    return choices
  }
}
