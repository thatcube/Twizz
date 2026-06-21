import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// A scan-to-sign-in QR code inset with the service's brand logo, framed by a
/// theme-aware card. Shared by the Twitch and YouTube sign-in screens so both
/// pages render an identical, on-brand code.
///
/// The outer card follows the active `ThemePalette` (white in Light, dark in
/// Dark/OLED) so it sits naturally on every background. The QR itself stays on
/// an opaque white tile that supplies the light quiet zone scanners need —
/// brand-color modules on white — so it never inverts to a hard-to-scan
/// light-on-dark code regardless of theme.
///
/// The center logo occludes part of the code, so the QR is generated at the
/// highest error-correction level ("H", ~30% recoverable) to stay scannable.
struct BrandQRCodeView: View {
  /// The URL the QR encodes (the activation link to open on a phone).
  let payload: String
  /// Asset catalog name of the brand logo to inset (e.g. `"twitch-logo"`).
  let logoName: String
  /// Color applied to the dark QR modules, matching the inset logo's brand
  /// color (e.g. Twitch purple, YouTube red). Defaults to black.
  var moduleColor: Color = .black
  /// Side length of the QR image inside the white card.
  var size: CGFloat = 500

  @Environment(\.themePalette) private var palette

  var body: some View {
    qrTile
      .padding(24)
      .background(palette.cardOpaqueSurface, in: RoundedRectangle(cornerRadius: 52))
      .overlay {
        RoundedRectangle(cornerRadius: 52)
          .strokeBorder(palette.cardOpaqueBorder, lineWidth: 1)
      }
  }

  /// The scannable code on its required white quiet-zone tile. White here is
  /// intentional (the QR background scanners expect), not a themed surface.
  private var qrTile: some View {
    Group {
      if let image = Self.makeQRCode(from: payload, moduleColor: moduleColor) {
        Image(uiImage: image)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .overlay { logoBadge }
      } else {
        RoundedRectangle(cornerRadius: 16)
          .fill(Color.black.opacity(0.05))
          .overlay(ProgressView())
      }
    }
    .frame(width: size, height: size)
    .padding(32)
    .background(Color.white, in: RoundedRectangle(cornerRadius: 36))
  }

  private var logoBadge: some View {
    Image(logoName)
      .resizable()
      .aspectRatio(contentMode: .fit)
      .frame(width: size * 0.2, height: size * 0.2)
      .padding(size * 0.03)
      .background(Color.white)
  }

  // MARK: - QR generation

  private static let ciContext = CIContext()

  static func makeQRCode(from string: String, moduleColor: Color = .black) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "H"

    guard let output = filter.outputImage else { return nil }

    let falseColor = CIFilter.falseColor()
    falseColor.inputImage = output
    falseColor.color0 = CIColor(color: UIColor(moduleColor))
    falseColor.color1 = CIColor(color: .white)

    guard let tinted = falseColor.outputImage else { return nil }
    let scaled = tinted.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
    guard let cgImage = ciContext.createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
