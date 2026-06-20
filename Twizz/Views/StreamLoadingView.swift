import SwiftUI

/// The shared loading state for every surface where a stream can be watched —
/// the full player, multiview tiles, and the clip player.
///
/// Instead of a bare spinner on a black screen, it shows the stream's own
/// thumbnail as a poster with a centered native cluster (channel avatar, name,
/// and the system `ProgressView`) on top.
///
/// The poster is **aspect-fit** (`scaledToFit`) so it lands in the *exact* same
/// letterboxed rectangle the video will once it starts — both the live video
/// (`VideoSurface`/`PreviewVideoSurface`) use `.resizeAspect`. The surrounding
/// bars use the theme's player backdrop, identical to the loaded state's
/// letterbox bars. That makes the hand-off a seamless sharpen-in-place instead
/// of the poster filling the frame and then "shrinking" into the video.
///
/// `compact` is for the small multiview tiles: it drops the avatar and the
/// pulse and uses a smaller spinner/type so the treatment isn't oversized in a
/// quadrant or filmstrip thumbnail.
///
/// Theme-aware per the repo conventions: over real stream art the foreground is
/// white (the scrim keeps it legible, matching over-video chrome), and when
/// there's no art it falls back to the active `ThemePalette` so the Light theme
/// stays legible instead of assuming a dark background.
struct StreamLoadingView: View {
  /// The stream's last frame, shown aspect-fit as the poster. `nil` falls back
  /// to a plain backdrop.
  var posterURL: URL? = nil
  /// Channel avatar shown above the name. Hidden in `compact` tiles.
  var avatarURL: URL? = nil
  /// Channel display name or content title.
  var title: String? = nil
  /// Tight layout for multiview tiles: no avatar/pulse, smaller spinner & type.
  var compact: Bool = false

  @Environment(\.themePalette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  private var hasArt: Bool { posterURL != nil }

  /// White over real art (the scrim keeps it legible, like over-video chrome);
  /// theme-derived otherwise so Light mode doesn't paint white-on-white.
  private var foreground: Color {
    hasArt ? .white : (palette.isLight ? .black.opacity(0.85) : .white)
  }

  var body: some View {
    ZStack {
      // Bars match the loaded state's letterbox. The full player letterboxes
      // over `playerBackdrop`; multiview tiles are always on a black wall (even
      // in Light theme), so compact lets the pane's own black show through.
      (compact ? Color.clear : palette.playerBackdrop)

      if let posterURL {
        CachedAsyncImage(url: posterURL) { image in
          image.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }
        .overlay(Color.black.opacity(0.28))
      }

      cluster
    }
    .clipped()
    .allowsHitTesting(false)
    .onAppear {
      guard !reduceMotion, avatarURL != nil else { return }
      withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
        pulse = true
      }
    }
  }

  private var cluster: some View {
    VStack(spacing: compact ? 12 : 18) {
      ProgressView()
        .tint(foreground)
        .scaleEffect(compact ? 1.0 : 1.3)

      // Icon + name sit side by side so the channel reads as one unit.
      if avatarURL != nil || (title.map { !$0.isEmpty } ?? false) {
        HStack(spacing: compact ? 8 : 12) {
          if let avatarURL {
            avatar(avatarURL)
          }
          if let title, !title.isEmpty {
            Text(title)
              .font(compact ? .headline : .title3.weight(.semibold))
              .foregroundStyle(foreground)
              .lineLimit(1)
              .shadow(color: hasArt ? .black.opacity(0.6) : .clear, radius: 6, y: 1)
          }
        }
      }
    }
    .padding(compact ? 12 : 24)
  }

  private func avatar(_ url: URL) -> some View {
    let size: CGFloat = compact ? 36 : 64
    return CachedAsyncImage(url: url) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Circle().fill(foreground.opacity(0.12))
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(foreground.opacity(0.3), lineWidth: 2))
    .shadow(color: .black.opacity(hasArt ? 0.4 : 0), radius: 10, y: 3)
    .scaleEffect(pulse ? 1.0 : 0.95)
    .opacity(pulse ? 1.0 : 0.88)
  }
}
