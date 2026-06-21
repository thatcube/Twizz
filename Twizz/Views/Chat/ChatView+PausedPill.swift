import SwiftUI

extension ChatView {
  /// Shown while the list is frozen. In the soft-pause "read" mode it shows the
  /// "Chat paused" countdown with a wide, bouncing up-chevron hint (the native
  /// "swipe/press up" affordance) floating just above it; once you actually
  /// scroll it collapses to a minimal "Scrolling" tag.
  var pausedPill: some View {
    VStack(spacing: 6) {
      // Wide, shallow chevron — the conventional "swipe up to go up" hint, like
      // an iOS sheet grabber — floating bare above the pill. Only on the
      // read-pause state, where an up press is the next action. It fades in and
      // performs a single subtle upward drift a beat *after* the pill arrives,
      // and is reset on disappear so it replays on every reopen.
      if softPauseRemaining != nil {
        Image(systemName: "chevron.compact.up")
          .font(.system(size: 30, weight: .semibold))
          .foregroundStyle(.white.opacity(0.9))
          .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
          .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
          .opacity(hintShown ? 1 : 0)
          .blur(radius: hintShown ? 0 : 6)
          .offset(y: hintShown ? -3 : 7)
          .onAppear {
            hintShown = false
            withAnimation(.easeOut(duration: 0.7).delay(0.35)) { hintShown = true }
          }
          .onDisappear { hintShown = false }
      }

      HStack(spacing: 8) {
        if let remaining = softPauseRemaining {
          // Twitch-style countdown: a large ring on the left that depletes each
          // second with the number animating inside it. Fixed width, so the pill
          // never resizes as the count ticks down.
          countdownRing(remaining: remaining)
          Text("Chat paused")
            .font(.caption.weight(.semibold))
        } else {
          Image(systemName: "arrow.up.and.down")
            .font(.caption.weight(.bold))
          Text("Scrolling")
            .font(.caption.weight(.semibold))
        }
      }
      .lineLimit(1)
      .fixedSize()
      // Floor both states to the ring's layout height so the "Scrolling" pill is
      // exactly as tall as the "Chat paused" one.
      .frame(minHeight: 28)
      // Dark content to read against the white-tinted "focused" glass, mirroring
      // the chat composer field when it is the focused element.
      .foregroundStyle(.black.opacity(0.8))
      // Tuck the countdown ring into the capsule's left cap so its gap from the
      // left edge matches its (small) gap from the top/bottom.
      .padding(.leading, softPauseRemaining != nil ? 9 : 26)
      .padding(.trailing, 26)
      .padding(.vertical, 14)
      .modifier(PausedPillGlassStyle())
    }
    .padding(.bottom, 12)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  /// A small depleting countdown ring with the remaining seconds animating in
  /// its center. The ring shrinks one step per second (linear over the 1s tick)
  /// and the number uses a numeric content transition. Fixed size so it never
  /// changes the pill's width.
  private func countdownRing(remaining: Int) -> some View {
    let progress = softPauseTotal > 0
      ? max(0, min(1, Double(remaining) / Double(softPauseTotal)))
      : 0
    return ZStack {
      Circle()
        .stroke(.black.opacity(0.16), lineWidth: 4)
      Circle()
        .trim(from: 0, to: progress)
        .stroke(.black.opacity(0.7), style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.linear(duration: 1), value: remaining)
      Text("\(remaining)")
        .font(.system(size: 20, weight: .bold))
        .monospacedDigit()
        .contentTransition(.numericText())
    }
    .frame(width: 40, height: 40)
    // Let the ring read larger than the label without making the pill taller:
    // the extra height overlaps the pill's own vertical padding instead of
    // pushing the capsule open.
    .padding(.vertical, -8)
  }
}

/// Liquid Glass surface for the paused/scroll indicator pill. These pills are
/// shown only while the viewer is actively holding chat (reading or scrolling),
/// so they *are* the focused element — render them with the same white-tinted,
/// lifted glass the chat composer uses when focused so they read as interactive.
/// Falls back to a solid white capsule on tvOS versions before Liquid Glass.
private struct PausedPillGlassStyle: ViewModifier {
  @Environment(\.glassDisabled) private var glassDisabled
  private var shape: Capsule { Capsule(style: .continuous) }

  @ViewBuilder
  func body(content: Content) -> some View {
    if glassDisabled {
      content
        .background(.white, in: shape)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    } else if #available(tvOS 26.0, *) {
      content
        .glassEffect(.regular.tint(.white), in: shape)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    } else {
      content
        .background(.white, in: shape)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 4)
    }
  }
}
