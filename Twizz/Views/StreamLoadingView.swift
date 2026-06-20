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
/// There is **one** visual treatment for every surface — the cluster simply
/// *scales to its container* via the available geometry, so a small multiview
/// tile gets the same proportions as the full-screen player, just smaller. No
/// per-surface style fork.
///
/// Theme-aware per the repo conventions: over real stream art the foreground is
/// white (the scrim keeps it legible, matching over-video chrome), and when
/// there's no art it falls back to the active `ThemePalette` so the Light theme
/// stays legible instead of assuming a dark background.
struct StreamLoadingView: View {
  /// The stream's last frame, shown aspect-fit as the poster. `nil` falls back
  /// to a plain backdrop.
  var posterURL: URL? = nil
  /// Channel avatar shown beside the name.
  var avatarURL: URL? = nil
  /// Channel display name or content title.
  var title: String? = nil
  /// Whether to paint the theme's letterbox backdrop behind the poster. The
  /// full player and clip player letterbox over `playerBackdrop`; multiview
  /// tiles sit on their own black pane wall, so they pass `false` and let it
  /// show through. This is a surface-match, not a different style.
  var drawsBackdrop: Bool = true

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
    GeometryReader { geo in
      let scale = clusterScale(for: geo.size)

      ZStack {
        // Bars match the loaded state's letterbox. The full player letterboxes
        // over `playerBackdrop`; multiview tiles are on a black wall (even in
        // Light theme), so they skip the backdrop and let the pane's own black
        // show through.
        if drawsBackdrop {
          palette.playerBackdrop
        }

        if let posterURL {
          CachedAsyncImage(url: posterURL) { image in
            image.resizable().scaledToFit()
          } placeholder: {
            Color.clear
          }
          .overlay(Color.black.opacity(0.28))
        }

        cluster(scale: scale)
      }
      .frame(width: geo.size.width, height: geo.size.height)
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

  /// One scale factor derived from the container, relative to a full-screen
  /// tvOS player (1920×1080). A quadrant or filmstrip thumbnail scales the same
  /// cluster down proportionally rather than switching to a different layout.
  private func clusterScale(for size: CGSize) -> CGFloat {
    guard size.width > 0, size.height > 0 else { return 1.25 }
    let ratio = min(size.width / 1920, size.height / 1080)
    // Bumped ~25% overall so the cluster doesn't read as undersized in a tile.
    return min(max(ratio, 0.5), 1) * 1.25
  }

  private func cluster(scale: CGFloat) -> some View {
    VStack(spacing: 18 * scale) {
      ProgressView()
        .tint(foreground)
        .scaleEffect(1.3 * scale)

      // Icon + name sit side by side so the channel reads as one unit.
      if avatarURL != nil || (title.map { !$0.isEmpty } ?? false) {
        HStack(spacing: 12 * scale) {
          if let avatarURL {
            avatar(avatarURL, scale: scale)
          }
          if let title, !title.isEmpty {
            Text(title)
              .font(.system(size: 32 * scale, weight: .semibold))
              .foregroundStyle(foreground)
              .lineLimit(1)
              .minimumScaleFactor(0.6)
              .shadow(color: hasArt ? .black.opacity(0.6) : .clear, radius: 6, y: 1)
          }
        }
      }
    }
    .padding(24 * scale)
  }

  private func avatar(_ url: URL, scale: CGFloat) -> some View {
    let size: CGFloat = 64 * scale
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
