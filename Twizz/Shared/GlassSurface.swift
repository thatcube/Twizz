import SwiftUI

/// Global "Disable Liquid Glass" / Reduce Transparency state.
///
/// When `true`, every translucent Liquid Glass / material surface should render
/// as an opaque, high-contrast fill instead. It is driven by the union of an
/// in-app toggle (`AppStorageKey.disableLiquidGlass`) and the OS
/// `accessibilityReduceTransparency` setting, resolved once at the app root via
/// `resolveGlassDisabled()` and read through `@Environment(\.glassDisabled)`.
private struct GlassDisabledKey: EnvironmentKey {
  static let defaultValue: Bool = false
}

extension EnvironmentValues {
  var glassDisabled: Bool {
    get { self[GlassDisabledKey.self] }
    set { self[GlassDisabledKey.self] = newValue }
  }
}

extension ShapeStyle where Self == Color {
  /// Opaque, high-contrast fill that replaces translucent glass/material panels
  /// when Disable Liquid Glass / Reduce Transparency is on. A solid near-black
  /// keeps the existing white-on-dark panel text fully legible.
  static var twizzOpaqueGlass: Color { Color(red: 0.10, green: 0.10, blue: 0.12) }
}

extension View {
  /// Resolve the effective glass-disabled flag from the app toggle OR the OS
  /// Reduce Transparency setting and publish it into the environment. Apply once
  /// near the app root; child surfaces read `@Environment(\.glassDisabled)`.
  func resolveGlassDisabled() -> some View {
    modifier(GlassDisabledResolver())
  }
}

private struct GlassDisabledResolver: ViewModifier {
  @AppStorage("disableLiquidGlass") private var disableLiquidGlass = false
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

  func body(content: Content) -> some View {
    content.environment(\.glassDisabled, disableLiquidGlass || reduceTransparency)
  }
}
