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
        Picker("Run placement on", selection: Binding(
          get: { model.config.placementProvider },
          set: { model.setPlacementProvider($0) }
        )) {
          Text("Launched provider").tag(AgentProvider?.none)
          ForEach(AgentProvider.allCases, id: \.self) { provider in
            Label(provider.displayName, systemImage: provider.symbolName)
              .tag(AgentProvider?.some(provider))
          }
        }

        ForEach(AgentProvider.allCases, id: \.self) { provider in
          VStack(alignment: .leading, spacing: 4) {
            Label(provider.displayName, systemImage: provider.symbolName)
              .font(.system(size: 12, weight: .semibold))
            HStack(spacing: 8) {
              modelPicker(for: provider)
              if provider != .kimi { effortPicker(for: provider) }
            }
          }
        }

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

  private func modelPicker(for provider: AgentProvider) -> some View {
    Picker("\(provider.displayName) placement model", selection: Binding(
      get: { model.config.placementModels[provider] ?? "" },
      set: { model.setPlacementModel($0, for: provider) }
    )) {
      let builtIn = AppConfiguration.defaultPlacementModels[provider]
      let choices = model.placementModelChoices(for: provider)
      Text("Default · \(choices.first { $0.model == builtIn }?.label ?? builtIn ?? "provider")").tag("")
      ForEach(choices) { choice in
        Text(choice.label).tag(choice.model ?? "")
      }
    }.labelsHidden()
  }

  private func effortPicker(for provider: AgentProvider) -> some View {
    Picker("\(provider.displayName) placement effort", selection: Binding(
      get: { model.config.placementEfforts[provider] ?? "" },
      set: { model.setPlacementEffort($0, for: provider) }
    )) {
      Text("Default · \(AppConfiguration.defaultPlacementEfforts[provider] ?? "none")").tag("")
      ForEach(AppConfiguration.agentEffortLevels, id: \.self) { effort in
        Text(effort).tag(effort)
      }
    }.labelsHidden().frame(maxWidth: 130)
  }
}
