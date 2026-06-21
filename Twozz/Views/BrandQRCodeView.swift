import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// A scan-to-sign-in QR code inset with the service's brand logo, framed by a
/// theme-aware card. Shared by the Twitch and YouTube sign-in screens so both
/// pages render an identical, on-brand code.
///
/// Both the card and the QR's own background follow the active `ThemePalette`
/// (white in Light, dark in Dark/OLED), so the code blends into the page
/// instead of sitting on a hardcoded white tile. The brand-color modules stay
/// fully saturated against that background, and the code keeps "H" error
/// correction so it remains scannable.
struct BrandQRCodeView: View {
  /// The URL the QR encodes (the activation link to open on a phone).
  let payload: String
  /// Asset catalog name of the brand logo to inset (e.g. `"twitch-logo"`).
  let logoName: String
  /// Color applied to the dark QR modules, matching the inset logo's brand
  /// color (e.g. Twitch purple, YouTube red). Defaults to black.
  var moduleColor: Color = .black
  /// Side length of the QR image inside the card.
  var size: CGFloat = 500

  @Environment(\.themePalette) private var palette

  /// Theme surface painted behind the code (and as the QR's own background),
  /// so the card respects the active theme instead of always being white.
  private var surface: Color { palette.cardOpaqueSurface }

  var body: some View {
    qrContent
      .frame(width: size, height: size)
      .padding(40)
      .background(surface, in: RoundedRectangle(cornerRadius: 44))
      .overlay {
        RoundedRectangle(cornerRadius: 44)
          .strokeBorder(palette.cardOpaqueBorder, lineWidth: 1)
      }
  }

  @ViewBuilder
  private var qrContent: some View {
    if let image = Self.makeQRCode(from: payload, moduleColor: moduleColor, backgroundColor: surface) {
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
        .overlay { logoBadge }
    } else {
      RoundedRectangle(cornerRadius: 16)
        .fill(Color.primary.opacity(0.05))
        .overlay(ProgressView())
    }
  }

  private var logoBadge: some View {
    Image(logoName)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size * 0.2, height: size * 0.2)
      .padding(size * 0.03)
      .background(surface)
  }

  // MARK: - QR generation

  private static let ciContext = CIContext()

  static func makeQRCode(
    from string: String,
    moduleColor: Color = .black,
    backgroundColor: Color = .white
  ) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "H"

    guard let output = filter.outputImage else { return nil }

    let falseColor = CIFilter.falseColor()
    falseColor.inputImage = output
    falseColor.color0 = CIColor(color: UIColor(moduleColor))
    falseColor.color1 = CIColor(color: UIColor(backgroundColor))

    guard let tinted = falseColor.outputImage else { return nil }
    let scaled = tinted.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
