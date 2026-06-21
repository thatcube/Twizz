import SwiftUI
import UIKit

extension Color {
  /// Initialize from a `#RRGGBB` (or `RRGGBB`) hex string.
  init?(twitchHex hex: String) {
    var s = hex
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    self.init(
      .sRGB,
      red: Double((v >> 16) & 0xFF) / 255,
      green: Double((v >> 8) & 0xFF) / 255,
      blue: Double(v & 0xFF) / 255
    )
  }

  private static func chatLinearize(_ c: CGFloat) -> CGFloat {
    c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
  }

  private static func chatRelativeLuminance(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGFloat {
    0.2126 * chatLinearize(r) + 0.7152 * chatLinearize(g) + 0.0722 * chatLinearize(b)
  }

  private static func chatContrastRatio(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
    let hi = max(a, b)
    let lo = min(a, b)
    return (hi + 0.05) / (lo + 0.05)
  }

  /// Twitch-style "readable colors": nudges this color's lightness until it meets
  /// at least `minRatio` WCAG contrast against `surface` — lightening toward white
  /// on dark surfaces, darkening toward black on light ones — so colored names,
  /// `/me` bodies and special-message accents stay legible whichever chat surface
  /// they're drawn on. Hue is broadly preserved and colors that already pass the
  /// ratio are returned unchanged. `minRatio` defaults to 3.0 (WCAG AA for the
  /// large, bold text used in chat) to keep colors as vivid as Twitch's.
  func chatReadable(onSurface surface: Color, minRatio: CGFloat = 3.0) -> Color {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else { return self }
    var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
    guard UIColor(surface).getRed(&sr, green: &sg, blue: &sb, alpha: &sa) else { return self }

    let surfaceLum = Color.chatRelativeLuminance(sr, sg, sb)
    if Color.chatContrastRatio(Color.chatRelativeLuminance(r, g, b), surfaceLum) >= minRatio {
      return self
    }

    // Blend toward white on a dark surface, toward black on a light one.
    let target: CGFloat = surfaceLum < 0.5 ? 1 : 0
    var best = (r: r, g: g, b: b)
    var step: CGFloat = 0
    while step < 1 {
      step += 0.04
      let nr = r + (target - r) * step
      let ng = g + (target - g) * step
      let nb = b + (target - b) * step
      best = (nr, ng, nb)
      if Color.chatContrastRatio(Color.chatRelativeLuminance(nr, ng, nb), surfaceLum) >= minRatio {
        break
      }
    }
    return Color(.sRGB, red: Double(best.r), green: Double(best.g), blue: Double(best.b), opacity: Double(a))
  }
}
