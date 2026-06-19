import SwiftUI

/// Interactive "just went live" toast. Presentational only: the caller positions
/// it (top-trailing) and wires the closures, so the same view serves both Home
/// and the player without depending on either's focus model.
///
/// The toast never steals focus (it shouldn't interrupt what you're doing), but
/// its `Watch` button is reachable by the focus engine. Focusing it pauses the
/// auto-dismiss countdown via `onFocusChange`, so the toast can't disappear while
/// you're deciding whether to jump in.
struct GoLiveToastView: View {
  let event: GoLiveEvent
  /// Invoked when the viewer presses `Watch`.
  let onWatch: () -> Void
  /// Reports the `Watch` button's focus state so the owner can pause/resume the
  /// auto-dismiss countdown.
  var onFocusChange: (Bool) -> Void = { _ in }

  @FocusState private var watchFocused: Bool

  var body: some View {
    HStack(spacing: 18) {
      Icon(glyph: .broadcast, size: 34)
        .foregroundStyle(.red)

      VStack(alignment: .leading, spacing: 2) {
        Text(event.headline)
          .font(.headline).bold()
          .foregroundStyle(.primary)
        if let subtitle = event.subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }

      Button(action: onWatch) {
        HStack(spacing: 10) {
          Icon(glyph: .playerPlayFilled, size: 22)
          Text("Watch")
        }
        .font(.headline)
      }
      .buttonStyle(.borderedProminent)
      .focused($watchFocused)
    }
    .padding(.leading, 28)
    .padding(.trailing, 18)
    .padding(.vertical, 16)
    .background {
      if #available(tvOS 26.0, *) {
        Capsule().glassEffect(.regular, in: Capsule())
      } else {
        Capsule().fill(.ultraThinMaterial)
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    .onChange(of: watchFocused) { _, focused in
      onFocusChange(focused)
    }
  }
}
