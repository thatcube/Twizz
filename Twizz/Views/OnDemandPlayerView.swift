import AVKit
import SwiftUI

/// A piece of on-demand content opened from the channel page.
enum OnDemandItem: Identifiable, Hashable {
  case clip(slug: String, title: String)
  case vod(id: String, title: String)

  var id: String {
    switch self {
    case .clip(let slug, _): return "clip:\(slug)"
    case .vod(let id, _): return "vod:\(id)"
    }
  }

  var title: String {
    switch self {
    case .clip(_, let title), .vod(_, let title): return title
    }
  }

  var kindNoun: String {
    switch self {
    case .clip: return "clip"
    case .vod: return "broadcast"
    }
  }
}

/// Full-screen player for clips and VODs. Unlike the live `PlayerView` (which
/// suppresses native transport for its side-by-side chat layout), this uses
/// SwiftUI's `VideoPlayer` so the Siri Remote gets Apple's native scrub / skip /
/// play-pause controls for free — exactly what on-demand content wants.
struct OnDemandPlayerView: View {
  let item: OnDemandItem

  @Environment(\.dismiss) private var dismiss
  @State private var player = AVPlayer()
  @State private var phase: Phase = .loading
  @FocusState private var backFocused: Bool

  private enum Phase { case loading, playing, failed }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      switch phase {
      case .loading:
        VStack(spacing: 18) {
          ProgressView()
          Text("Loading \(item.title)…")
            .font(.title3)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      case .failed:
        VStack(spacing: 20) {
          Text("Couldn't play this \(item.kindNoun) right now.")
            .font(.title2)
          Button("Back") { dismiss() }
            .focused($backFocused)
        }
        .padding(40)
      case .playing:
        VideoPlayer(player: player)
          .ignoresSafeArea()
      }
    }
    .onExitCommand { dismiss() }
    .task(id: item.id) { await start() }
    .onChange(of: phase) { _, newPhase in
      if newPhase == .failed { backFocused = true }
    }
    .onDisappear {
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }

  private func start() async {
    phase = .loading
    do {
      let url: URL
      let headers: [String: String]
      switch item {
      case .clip(let slug, _):
        url = try await PlaybackService.clipSourceURL(slug: slug)
        headers = [:]
      case .vod(let id, _):
        url = try await PlaybackService.vodMasterURL(id: id)
        headers = PlaybackService.streamHeaders
      }

      let asset = headers.isEmpty
        ? AVURLAsset(url: url)
        : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
      let playerItem = AVPlayerItem(asset: asset)
      player.replaceCurrentItem(with: playerItem)
      player.play()
      phase = .playing
    } catch {
      phase = .failed
    }
  }
}
