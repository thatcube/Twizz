import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

/// Shape of an opaque player-control pill in the glass-disabled path.
enum TwizzControlShape: Equatable {
  case capsule
  case circle
}

extension View {
  @ViewBuilder
  func TwizzControlButtonStyle(shape: TwizzControlShape = .capsule) -> some View {
    modifier(TwizzControlButtonStyleModifier(shape: shape))
  }

  /// Removes the view from the focus engine while `removed` is true, leaving it
  /// completely untouched otherwise. Used to lift the control row out of focus
  /// while the viewer scrolls chat. Unlike an always-on `.focusable(true)` this
  /// doesn't suppress a Button's own focus styling (which reads the environment
  /// `isFocused` / the system focus effect), and unlike `.disabled` it never
  /// dims the native-glass buttons.
  @ViewBuilder
  func focusRemoved(_ removed: Bool) -> some View {
    if removed {
      self.focusable(false)
    } else {
      self
    }
  }

  /// Native Liquid Glass for the compact chat-settings controls: the exact same
  /// `.glass` / `.glassProminent` button styles the app's main SettingsView
  /// uses, so these pills/rows look and focus identically to the rest of the
  /// app (and to the playback controls on the player bar) instead of a custom
  /// imitation. Selected options render prominent; everything else is plain
  /// glass. Falls back to bordered styles before tvOS 26.
  @ViewBuilder
  func chatSettingsGlassButton(isSelected: Bool = false, shape: TwizzControlShape = .capsule) -> some View {
    modifier(ChatSettingsGlassButtonModifier(isSelected: isSelected, shape: shape))
  }
}

/// Chat-settings popover pills: native Liquid Glass when glass is enabled, or a
/// theme-aware opaque pill when glass is disabled — so the popover stays legible
/// and on-theme (light pills + dark text in Light mode) once its surface goes
/// opaque, matching the player's control pills.
struct ChatSettingsGlassButtonModifier: ViewModifier {
  var isSelected: Bool
  var shape: TwizzControlShape
  @Environment(\.glassDisabled) private var glassDisabled

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .buttonStyle(TwizzOpaquePillButtonStyle(isSelected: isSelected, shape: shape))
        .focusEffectDisabled()
    } else if #available(tvOS 26.0, *) {
      if isSelected {
        // Active state mirrors the main SettingsView pills: native prominent
        // glass plus a trailing checkmark (added by the caller). No tint — the
        // prominent fill + checkmark is the established app pattern.
        content.buttonStyle(.glassProminent)
      } else {
        content.buttonStyle(.glass)
      }
    } else {
      if isSelected {
        content.buttonStyle(.borderedProminent)
      } else {
        content.buttonStyle(.bordered)
      }
    }
  }
}

/// Opaque, theme-aware pill for the chat-settings popover. Like the control-pill
/// style it flips to the standard tvOS focused look (white fill + dark label),
/// and marks the selected option with a prominent brand fill + light label
/// (the caller still adds the trailing checkmark) so selection reads in both
/// light and dark themes.
struct TwizzOpaquePillButtonStyle: ButtonStyle {
  var isSelected: Bool
  var shape: TwizzControlShape

  func makeBody(configuration: Configuration) -> some View {
    PillBody(configuration: configuration, isSelected: isSelected, shape: shape)
  }

  private struct PillBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    let shape: TwizzControlShape
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    private var fill: Color {
      if isFocused { return .white }
      if isSelected { return ThemePalette.brandPurple }
      return palette.chromeOpaqueSurface
    }
    private var foreground: Color {
      if isFocused { return .black }
      if isSelected { return .white }
      return palette.chromeOnOpaque
    }
    private var border: Color {
      (isFocused || isSelected) ? .clear : palette.chromeOpaqueBorder
    }

    var body: some View {
      Group {
        switch shape {
        case .capsule:
          styled(Capsule(style: .continuous))
        case .circle:
          styled(Circle())
        }
      }
      .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.06 : 1.0))
      .shadow(
        color: .black.opacity(isFocused ? 0.28 : 0.0),
        radius: isFocused ? 12 : 0, x: 0, y: isFocused ? 6 : 0)
      .animation(.easeOut(duration: 0.16), value: isFocused)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styled<S: InsettableShape>(_ s: S) -> some View {
      let isCircle = (shape == .circle)
      configuration.label
        .foregroundStyle(foreground)
        .padding(.horizontal, isCircle ? 12 : 22)
        .padding(.vertical, isCircle ? 12 : 14)
        .background(fill, in: s)
        .overlay(s.strokeBorder(border, lineWidth: 1))
        .clipShape(s)
    }
  }
}

/// Player control buttons: native Liquid Glass when glass is enabled, or a
/// theme-aware opaque pill when glass is disabled (OS Reduce Transparency or the
/// in-app Disable Liquid Glass toggle). The opaque pill mirrors the card/chrome
/// surfaces — an opaque themed fill with a contrasting foreground (light fill +
/// dark glyph in Light theme, near-black + light glyph in dark/oled) — and
/// follows the tvOS focus convention of a bright white fill + dark glyph when
/// focused. The native glass path is left untouched when glass is enabled.
struct TwizzControlButtonStyleModifier: ViewModifier {
  var shape: TwizzControlShape
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .buttonStyle(TwizzOpaqueControlButtonStyle(shape: shape))
        // We draw our own focus treatment (white fill + lift), so suppress the
        // system focus effect that would otherwise layer on top of a custom
        // button style.
        .focusEffectDisabled()
    } else if #available(tvOS 26.0, *) {
      if palette.isLight {
        // Native `.buttonStyle(.glass)` samples the dark video and renders dark,
        // which fights the Light theme. Swap in a light frosted-glass pill (a
        // light wash under real `.glassEffect`) that mirrors the native focus
        // behavior. Dark/OLED keep the untouched native glass below.
        content
          .buttonStyle(TwizzLightGlassControlButtonStyle(shape: shape))
          .focusEffectDisabled()
      } else {
        content.buttonStyle(.glass)
      }
    } else {
      content.buttonStyle(.automatic)
    }
  }
}

/// Opaque, theme-aware control pill used when glass is disabled. Reads the
/// button's own focus state via `@Environment(\.isFocused)` (valid inside a
/// button style's body) so it can flip to the standard tvOS focused look —
/// bright white fill + dark glyph, scaled and shadowed — while the resting state
/// stays an opaque themed surface with the theme's on-opaque foreground.
struct TwizzOpaqueControlButtonStyle: ButtonStyle {
  var shape: TwizzControlShape

  func makeBody(configuration: Configuration) -> some View {
    OpaqueControlButtonBody(configuration: configuration, shape: shape)
  }

  private struct OpaqueControlButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shape: TwizzControlShape
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    private var fill: Color { isFocused ? .white : palette.chromeOpaqueSurface }
    private var foreground: Color { isFocused ? .black : palette.chromeOnOpaque }
    private var border: Color { isFocused ? .clear : palette.chromeOpaqueBorder }

    var body: some View {
      Group {
        switch shape {
        case .capsule:
          styled(Capsule(style: .continuous))
        case .circle:
          styled(Circle())
        }
      }
      .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1.0))
      .shadow(
        color: .black.opacity(isFocused ? 0.28 : 0.0),
        radius: isFocused ? 12 : 0, x: 0, y: isFocused ? 6 : 0)
      .animation(.easeOut(duration: 0.16), value: isFocused)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styled<S: InsettableShape>(_ s: S) -> some View {
      let isCircle = (shape == .circle)
      configuration.label
        .foregroundStyle(foreground)
        .padding(.horizontal, isCircle ? 10 : 22)
        .padding(.vertical, isCircle ? 10 : 14)
        .background(fill, in: s)
        .overlay(s.strokeBorder(border, lineWidth: 1))
        .clipShape(s)
    }
  }
}

/// Light-theme control pill for the *glass-enabled* path. Native
/// `.buttonStyle(.glass)` samples the dark video frame underneath and renders
/// dark, which clashes with the Light theme's light chrome. This paints the exact
/// same material as the Glass chat pane — a light `chromeGlassTint` wash under a
/// real, refractive `.glassEffect(.regular)` (brightening to white on focus) —
/// while keeping the native focus lift (scale + shadow). Used only for the
/// `.light` palette; dark/OLED keep the untouched native glass. Like the opaque
/// style it reads the button's own focus state via `@Environment(\.isFocused)`.
@available(tvOS 26.0, *)
struct TwizzLightGlassControlButtonStyle: ButtonStyle {
  var shape: TwizzControlShape

  func makeBody(configuration: Configuration) -> some View {
    LightGlassControlButtonBody(configuration: configuration, shape: shape)
  }

  private struct LightGlassControlButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let shape: TwizzControlShape
    @Environment(\.isFocused) private var isFocused
    @Environment(\.themePalette) private var palette

    var body: some View {
      Group {
        switch shape {
        case .capsule:
          styled(Capsule(style: .continuous))
        case .circle:
          styled(Circle())
        }
      }
      .scaleEffect(configuration.isPressed ? 0.96 : (isFocused ? 1.08 : 1.0))
      .shadow(
        color: .black.opacity(isFocused ? 0.28 : 0.0),
        radius: isFocused ? 12 : 0, x: 0, y: isFocused ? 6 : 0)
      .animation(.easeOut(duration: 0.16), value: isFocused)
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder
    private func styled<S: InsettableShape>(_ s: S) -> some View {
      let isCircle = (shape == .circle)
      configuration.label
        .foregroundStyle(isFocused ? .black : palette.chromeOnOpaque)
        .padding(.horizontal, isCircle ? 10 : 22)
        .padding(.vertical, isCircle ? 10 : 14)
        // Same translucent material as the Glass chat pane, but with the
        // stronger over-video wash so the pill reads as light as the chat even
        // though only dark video (not light chat content) sits behind it.
        .background(palette.chromeOverVideoTint(), in: s)
        .glassEffect(isFocused ? .regular.tint(.white) : .regular, in: s)
        .overlay(s.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.12), lineWidth: 1))
        .clipShape(s)
    }
  }
}
struct ChatSettingsHeightKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Reports the measured height of the player's right-side control buttons row so
/// the stream title can be capped to it (keeping the buttons at a fixed position
/// regardless of title length).
struct ControlButtonsHeightKey: PreferenceKey {
  static var defaultValue: CGFloat { 0 }
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// A completely passthrough button style for the chat input surface.
/// Suppresses all platform button visuals (hover, scale, ring) so only
/// the SwiftUI glass shell controls the appearance.
struct ChatInputButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
  }
}

/// Gives the chat composer field a single Liquid Glass capsule that is the *same*
/// element at rest and when focused — it simply brightens (white-tinted glass) and
/// lifts slightly on focus, the way native tvOS controls do, instead of swapping in
/// a separate opaque card on top. Keeping one view subtree (only the parameters
/// change with `isFocused`) preserves view identity so SwiftUI animates it as one
/// element growing. Falls back to `.ultraThinMaterial` on systems older than tvOS 26.
struct ChatGlassFieldStyle: ViewModifier {
  let isFocused: Bool
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  private var shape: Capsule {
    Capsule(style: .continuous)
  }

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .background(isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(palette.chromeOpaqueSurface), in: shape)
        .overlay(shape.strokeBorder(palette.chromeOpaqueBorder.opacity(isFocused ? 0.0 : 1.0), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
          color: .black.opacity(isFocused ? 0.22 : 0.18),
          radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    } else if #available(tvOS 26.0, *) {
      content
        .glassEffect(isFocused ? .regular.tint(.white) : .regular, in: shape)
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.10), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
          color: .black.opacity(isFocused ? 0.22 : 0.18),
          radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    } else {
      content
        .background(
          isFocused ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial), in: shape
        )
        .overlay(shape.strokeBorder(.white.opacity(isFocused ? 0.0 : 0.10), lineWidth: 0.75))
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
          color: .black.opacity(isFocused ? 0.22 : 0.18),
          radius: isFocused ? 10 : 5, x: 0, y: isFocused ? 4 : 2)
    }
  }
}

