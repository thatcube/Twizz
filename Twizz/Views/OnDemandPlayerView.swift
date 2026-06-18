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

  /// The VOD id for broadcasts (used to fetch chat replay); nil for clips.
  var vodID: String? {
    if case .vod(let id, _) = self { return id }
    return nil
  }
}

/// Full-screen player for clips and VODs. Unlike the live `PlayerView` (which
/// suppresses native transport for its side-by-side chat layout), this uses
/// SwiftUI's `VideoPlayer` so the Siri Remote gets Apple's native scrub / skip /
/// play-pause controls for free — exactly what on-demand content wants.
///
/// VODs additionally get a Twitch-style **chat replay**: the live player's
/// `ChatView` docked beside / over the video, fed by `VODChatReplayService` and
/// kept in sync with the playback offset. It reuses the same global chat
/// appearance settings as the live player, and is read-only.
struct OnDemandPlayerView: View {
  let item: OnDemandItem
  /// Login of the channel that owns this content, used to resolve the right
  /// emote/badge catalogs for chat replay. Optional; replay still works without
  /// it (global emotes/badges only).
  var channelLogin: String? = nil

  @Environment(\.dismiss) private var dismiss
  @State private var player = AVPlayer()
  @State private var replay = VODChatReplayService()
  @State private var phase: Phase = .loading
  @State private var timeObserver: Any?
  @State private var showChat = UserDefaults.standard.object(forKey: "showChatByDefault") as? Bool
    ?? true
  @FocusState private var backFocused: Bool

  @AppStorage("chatTextSizeValue") private var chatTextSizeValue = Double(
    ChatAppearance.defaultTextSize)
  @AppStorage("chatEmoteAuto") private var chatEmoteAuto = ChatAppearance.defaultEmoteAuto
  @AppStorage("chatEmoteSizeValue") private var chatEmoteSizeValue = Double(
    ChatAppearance.defaultEmoteSize)
  @AppStorage("chatLineHeightValue") private var chatLineHeightValue = Double(
    ChatAppearance.defaultLineHeight)
  @AppStorage("chatMessageSpacingValue") private var chatMessageSpacingValue = Double(
    ChatAppearance.defaultMessageSpacing)
  @AppStorage("chatWidthValue") private var chatWidthValue = Double(ChatAppearance.defaultWidth)
  @AppStorage("chatAnimatedEmotes") private var chatAnimatedEmotes = ChatAppearance
    .defaultAnimatedEmotes
  @AppStorage("chatFontStyle") private var chatFontStyleRaw = ChatAppearance.defaultFontStyle
    .rawValue
  @AppStorage("chatShowBadges") private var chatShowBadges = ChatAppearance.defaultShowBadges
  @AppStorage("chatLayoutMode") private var chatLayoutModeRaw = ChatLayoutMode.side.rawValue

  private enum Phase { case loading, playing, failed }

  private var isVOD: Bool { item.vodID != nil }
  private var chatActive: Bool { isVOD && showChat && phase == .playing }

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
        playingLayout
      }
    }
    .onExitCommand { dismiss() }
    .task(id: item.id) { await start() }
    .onChange(of: phase) { _, newPhase in
      if newPhase == .failed { backFocused = true }
    }
    .onDisappear {
      removeTimeObserver()
      replay.stop()
      player.pause()
      player.replaceCurrentItem(with: nil)
    }
  }

  @ViewBuilder
  private var playingLayout: some View {
    if chatActive {
      switch chatLayoutMode {
      case .side:
        HStack(spacing: 0) {
          VideoPlayer(player: player)
          chatPane
            .frame(width: chatWidth)
        }
        .ignoresSafeArea()
      case .overlay, .glass:
        ZStack(alignment: .topTrailing) {
          VideoPlayer(player: player)
            .ignoresSafeArea()
          chatPane
            .frame(width: chatWidth)
            .frame(maxHeight: .infinity)
            .modifier(VODChatGlassStyle(enabled: chatLayoutMode == .glass))
        }
      }
    } else {
      VideoPlayer(player: player)
        .ignoresSafeArea()
    }
  }

  private var chatPane: some View {
    ChatView(
      channel: channelLogin ?? "",
      messages: replay.messages,
      textSize: chatTextSize,
      emoteSize: chatEmoteSize,
      messageSpacing: chatMessageSpacing,
      lineHeight: chatLineHeight,
      animatedEmotes: chatAnimatedEmotes,
      fontDesign: chatFontStyle.design,
      showBadges: chatShowBadges,
      isConnected: replay.isReady,
      emoteURLs: replay.emoteURLs,
      badgeURLs: replay.badgeURLs,
      useGlassBackground: chatLayoutMode == .glass,
      useLighterOverlayBackground: chatLayoutMode == .overlay
    )
    .frame(maxHeight: .infinity)
  }

  // MARK: - Chat appearance (mirrors the live player's global settings)

  private var chatTextSize: CGFloat { CGFloat(chatTextSizeValue) }
  private var chatLineHeight: CGFloat { CGFloat(chatLineHeightValue) }
  private var chatMessageSpacing: CGFloat { CGFloat(chatMessageSpacingValue) }
  private var chatWidth: CGFloat { CGFloat(chatWidthValue) }

  private var chatEmoteSize: CGFloat {
    chatEmoteAuto
      ? ChatAppearance.autoEmoteHeight(forTextSize: chatTextSize)
      : CGFloat(chatEmoteSizeValue)
  }

  private var chatLayoutMode: ChatLayoutMode {
    ChatLayoutMode(rawValue: chatLayoutModeRaw) ?? .side
  }

  private var chatFontStyle: ChatFontStyle {
    ChatFontStyle(rawValue: chatFontStyleRaw) ?? .standard
  }

  // MARK: - Playback

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
        replay.start(vodID: id, channelLogin: channelLogin)
      }

      let asset = headers.isEmpty
        ? AVURLAsset(url: url)
        : AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
      let playerItem = AVPlayerItem(asset: asset)
      player.replaceCurrentItem(with: playerItem)
      player.play()
      if isVOD { installTimeObserver() }
      phase = .playing
    } catch {
      phase = .failed
    }
  }

  private func installTimeObserver() {
    removeTimeObserver()
    let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
    timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      replay.update(toOffset: time.seconds)
    }
  }

  private func removeTimeObserver() {
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
    }
    timeObserver = nil
  }
}

/// Lightweight rounded "glass" container for the VOD chat overlay so the glass
/// layout mode reads similarly to the live player without depending on that
/// file's private styling.
private struct VODChatGlassStyle: ViewModifier {
  let enabled: Bool
  private let edgeInset: CGFloat = 24
  private let corner: CGFloat = 28

  func body(content: Content) -> some View {
    if enabled {
      content
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .background(
          RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(.ultraThinMaterial)
        )
        .overlay(
          RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        )
        .padding(.vertical, edgeInset)
        .padding(.trailing, edgeInset)
    } else {
      content
    }
  }
}
