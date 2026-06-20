import SwiftUI

/// Picks up to ``multiviewPaneLimit`` live channels to watch together, then
/// hands the ordered selection to the multiview grid.
///
/// Each option is a real ``StreamChannelCard`` — the same card the Home grid
/// uses, so it brings the thumbnail, hover-preview video, LIVE/viewer badge,
/// avatar, and title for free — wrapped in a selection overlay that shows the
/// pick order, a purple ring when selected, and dims unselected cards once the
/// four-pick limit is reached.
struct MultiviewSetupView: View {
  let channels: [FollowedChannel]
  var onStart: ([FollowedChannel]) -> Void
  var onCancel: () -> Void

  @Environment(\.themePalette) private var palette
  /// Selected channel ids, in pick order — that order drives grid placement.
  @State private var selectedIDs: [String] = []
  @FocusState private var focusedID: String?

  private let columns = [GridItem(.adaptive(minimum: 360, maximum: 480), spacing: 28)]

  private var liveChannels: [FollowedChannel] { channels.filter(\.isLive) }
  private var isAtLimit: Bool { selectedIDs.count >= multiviewPaneLimit }
  private var canStart: Bool { selectedIDs.count >= 2 }

  private var orderedSelection: [FollowedChannel] {
    selectedIDs.compactMap { id in liveChannels.first { $0.id == id } }
  }

  var body: some View {
    ZStack {
      AppBackground(palette: palette).ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        header

        if liveChannels.count < 2 {
          emptyState
        } else {
          ScrollView {
            LazyVGrid(columns: columns, spacing: 28) {
              ForEach(liveChannels) { channel in
                tile(channel)
              }
            }
            .padding(.horizontal, AppLayout.horizontalPadding)
            .padding(.vertical, 28)
          }
        }
      }
    }
    .onExitCommand(perform: onCancel)
  }

  // MARK: Header

  private var header: some View {
    HStack(alignment: .center) {
      VStack(alignment: .leading, spacing: 6) {
        Label {
          Text("Multiview")
            .font(.system(size: 40, weight: .bold))
        } icon: {
          Icon(glyph: .layoutGrid, size: 34)
        }
        Text("Choose up to \(multiviewPaneLimit) live channels to watch together.")
          .font(.title3)
          .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        onStart(orderedSelection)
      } label: {
        Text(canStart ? "Start Multiview (\(selectedIDs.count))" : "Pick 2+ channels")
          .font(.headline)
          .padding(.horizontal, 12)
      }
      .disabled(!canStart)
      .tint(ThemePalette.brandPurple)
    }
    .padding(.horizontal, AppLayout.horizontalPadding)
    .padding(.top, 48)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Text("Not enough live channels")
        .font(.title2.weight(.semibold))
      Text("Multiview needs at least two channels that are live right now.")
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Tile

  private func tile(_ channel: FollowedChannel) -> some View {
    let order = selectedIDs.firstIndex(of: channel.id)
    let isSelected = order != nil
    let isFocused = focusedID == channel.id
    let dimmed = isAtLimit && !isSelected

    return StreamChannelCard(
      channel: channel,
      isFocused: isFocused,
      layout: .grid(),
      showsGameName: true
    )
    .overlay(alignment: .topTrailing) {
      if let order {
        selectionBadge(order: order + 1)
          .padding(26)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(
          isSelected ? ThemePalette.brandPurple : Color.clear,
          lineWidth: 5
        )
    }
    .opacity(dimmed ? 0.4 : 1)
    .scaleEffect(isFocused ? 1.04 : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .animation(.easeOut(duration: 0.18), value: isSelected)
    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .focusable(true)
    .focused($focusedID, equals: channel.id)
    .focusEffectDisabled()
    .onTapGesture { toggle(channel) }
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityHint(
      dimmed
        ? "Limit of \(multiviewPaneLimit) reached"
        : (isSelected
            ? "Selected, position \((order ?? 0) + 1). Click to remove."
            : "Click to add to multiview")
    )
  }

  /// Numbered pick-order badge. White on the brand fill reads against any
  /// thumbnail; the brand purple keeps it consistent with the selection ring.
  private func selectionBadge(order: Int) -> some View {
    Text("\(order)")
      .font(.title3.weight(.bold))
      .foregroundStyle(.white)
      .frame(width: 46, height: 46)
      .background(ThemePalette.brandPurple, in: Circle())
      .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
      .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
  }

  private func toggle(_ channel: FollowedChannel) {
    if let idx = selectedIDs.firstIndex(of: channel.id) {
      selectedIDs.remove(at: idx)
    } else if !isAtLimit {
      selectedIDs.append(channel.id)
    }
  }
}
