import SwiftUI

enum OpaqueBackgroundsPreference {
  static let defaultsKey = "opaqueBackgroundsEnabled"
}

private struct OpaqueBackgroundsEnabledKey: EnvironmentKey {
  static let defaultValue = false
}

extension EnvironmentValues {
  var opaqueBackgroundsEnabled: Bool {
    get { self[OpaqueBackgroundsEnabledKey.self] }
    set { self[OpaqueBackgroundsEnabledKey.self] = newValue }
  }
}

enum OpaqueBackgroundPalette {
  static let darkSurface = Color(red: 15 / 255, green: 17 / 255, blue: 21 / 255)
  static let lightSurface = Color.white

  static func replacementSurface(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? darkSurface : lightSurface
  }
}

private struct OpaqueAwareMaterialBackground<BackgroundShape: Shape>: ViewModifier {
  let shape: BackgroundShape

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.opaqueBackgroundsEnabled) private var opaqueBackgroundsEnabled

  func body(content: Content) -> some View {
    content.background {
      shape.fill(
        opaqueBackgroundsEnabled
          ? AnyShapeStyle(OpaqueBackgroundPalette.replacementSurface(for: colorScheme))
          : AnyShapeStyle(.regularMaterial)
      )
    }
  }
}

extension View {
  func opaqueAwareMaterialBackground<BackgroundShape: Shape>(
    in shape: BackgroundShape
  ) -> some View {
    modifier(OpaqueAwareMaterialBackground(shape: shape))
  }
}
