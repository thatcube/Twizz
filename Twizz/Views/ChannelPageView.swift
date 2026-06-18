import SwiftUI

/// Full-screen, info-only channel page. Opened from the player's avatar button
/// and from the press-and-hold "Go to Channel" action on channel cards.
///
/// Content is intentionally a single screenful (no scrolling) so the Siri Remote
/// always has a reachable focus target — tvOS has no browser, so social links
/// are shown as plain text rather than tappable links.
struct ChannelPageView: View {
  let target: ChannelPageTarget
  /// When non-nil and the channel is live, a "Watch Live" button is shown.
  /// Left nil when opened from inside the player (already watching).
  var onWatch: (() -> Void)?

  @Environment(\.dismiss) private var dismiss
  @Environment(\.themePalette) private var palette

  @State private var profile: ChannelProfile?
  @State private var isLoading = true
  @State private var loadFailed = false

  @FocusState private var focus: Field?
  private enum Field: Hashable { case close, watch }

  private let bannerHeight: CGFloat = 320
  private let avatarSize: CGFloat = 148

  private var showsWatchButton: Bool {
    onWatch != nil && (profile?.isLive ?? false)
  }

  private var headerName: String {
    profile?.displayName ?? target.displayName ?? target.login
  }

  private var headerAvatarURL: URL? {
    profile?.profileImageURL ?? target.profileImageURL
  }

  var body: some View {
    ZStack(alignment: .top) {
      LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 0) {
        hero
        content
        Spacer(minLength: 0)
      }
    }
    .overlay(alignment: .topTrailing) { actionBar }
    .onExitCommand { dismiss() }
    .task(id: target.id) { await loadProfile() }
    .onAppear { focus = showsWatchButton ? .watch : .close }
    .onChange(of: showsWatchButton) { _, hasWatch in
      if hasWatch, focus == nil { focus = .watch }
    }
  }

  // MARK: - Action bar (Close / Watch)

  private var actionBar: some View {
    HStack(spacing: 16) {
      if showsWatchButton {
        Button {
          onWatch?()
        } label: {
          Label("Watch Live", systemImage: "play.fill")
            .font(.headline)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .focused($focus, equals: .watch)
      }

      Button {
        dismiss()
      } label: {
        Label("Close", systemImage: "xmark")
          .font(.headline)
          .padding(.horizontal, 22)
          .padding(.vertical, 12)
      }
      .focused($focus, equals: .close)
    }
    .padding(.top, 28)
    .padding(.trailing, AppLayout.horizontalPadding)
  }

  // MARK: - Hero (banner + avatar + identity)

  private var hero: some View {
    ZStack(alignment: .bottomLeading) {
      banner

      LinearGradient(
        colors: [.clear, palette.backgroundColors.last ?? .black],
        startPoint: .center,
        endPoint: .bottom
      )

      HStack(alignment: .bottom, spacing: 24) {
        avatar
        identity
        Spacer(minLength: 0)
      }
      .padding(.horizontal, AppLayout.horizontalPadding)
      .padding(.bottom, 8)
    }
    .frame(height: bannerHeight)
    .frame(maxWidth: .infinity)
  }

  private var banner: some View {
    Group {
      if let bannerURL = profile?.bannerImageURL {
        AsyncImage(url: bannerURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          bannerFallback
        }
      } else {
        bannerFallback
      }
    }
    .frame(maxWidth: .infinity, maxHeight: bannerHeight)
    .clipped()
  }

  private var bannerFallback: some View {
    LinearGradient(
      colors: [
        Color(red: 0.36, green: 0.25, blue: 0.66),
        Color(red: 0.20, green: 0.14, blue: 0.42),
      ],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  private var avatar: some View {
    Group {
      if let headerAvatarURL {
        AsyncImage(url: headerAvatarURL) { image in
          image.resizable().scaledToFill()
        } placeholder: {
          avatarPlaceholder
        }
      } else {
        avatarPlaceholder
      }
    }
    .frame(width: avatarSize, height: avatarSize)
    .clipShape(Circle())
    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 4))
    .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
  }

  private var avatarPlaceholder: some View {
    ZStack {
      Circle().fill(.white.opacity(0.16))
      Icon(glyph: .userCircle, size: avatarSize * 0.6)
        .foregroundStyle(.white.opacity(0.85))
    }
  }

  private var identity: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        Text(headerName)
          .font(.system(size: 46, weight: .bold))
          .foregroundStyle(.white)
          .lineLimit(1)
          .shadow(color: .black.opacity(0.5), radius: 4, y: 1)

        roleBadge
      }

      HStack(spacing: 18) {
        if let followers = profile?.followerCount {
          statLabel(
            text: "\(Self.compactCount(followers)) followers",
            systemImage: "heart.fill"
          )
        }
        if let joined = profile?.createdAt {
          statLabel(
            text: "Joined \(Self.monthYear(joined))",
            systemImage: "calendar"
          )
        }
      }
      .foregroundStyle(.white.opacity(0.92))
    }
    .padding(.bottom, 6)
  }

  @ViewBuilder
  private var roleBadge: some View {
    if let profile {
      if profile.isPartner {
        badge(text: "Partner", systemImage: "checkmark.seal.fill", tint: Color(red: 0.58, green: 0.41, blue: 0.96))
      } else if profile.isAffiliate {
        badge(text: "Affiliate", systemImage: "rosette", tint: Color(red: 0.30, green: 0.55, blue: 0.95))
      }
    }
  }

  private func badge(text: String, systemImage: String, tint: Color) -> some View {
    Label(text, systemImage: systemImage)
      .font(.callout.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
      .background(Capsule().fill(tint.opacity(0.9)))
  }

  private func statLabel(text: String, systemImage: String) -> some View {
    Label(text, systemImage: systemImage)
      .font(.title3.weight(.medium))
      .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
  }

  // MARK: - Content (summary, about, socials)

  private var content: some View {
    VStack(alignment: .leading, spacing: 26) {
      broadcastSummary

      if isLoading && profile == nil {
        HStack(spacing: 14) {
          ProgressView()
          Text("Loading channel…")
            .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
      } else if loadFailed && profile == nil {
        Text("Couldn't load this channel's details right now.")
          .foregroundStyle(.secondary)
      }

      about
      socials
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, AppLayout.horizontalPadding)
    .padding(.top, 24)
  }

  @ViewBuilder
  private var broadcastSummary: some View {
    if let profile {
      if profile.isLive {
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 12) {
            liveBadge
            if let viewers = profile.liveViewerCount {
              Text("\(Self.plainCount(viewers)) watching")
                .font(.headline)
                .foregroundStyle(.secondary)
            }
            if let uptime = Self.uptime(since: profile.liveStartedAt) {
              Text("· \(uptime)")
                .font(.headline)
                .foregroundStyle(.secondary)
            }
          }
          summaryTitleGame(title: profile.liveTitle, game: profile.liveGame)
        }
      } else if profile.lastBroadcastTitle != nil || profile.lastBroadcastGame != nil {
        VStack(alignment: .leading, spacing: 8) {
          Text(lastSeenLabel(profile.lastBroadcastStartedAt))
            .font(.headline)
            .foregroundStyle(.secondary)
          summaryTitleGame(
            title: profile.lastBroadcastTitle,
            game: profile.lastBroadcastGame
          )
        }
      }
    }
  }

  private var liveBadge: some View {
    HStack(spacing: 8) {
      Circle().fill(.red).frame(width: 12, height: 12)
      Text("LIVE")
        .font(.headline.weight(.bold))
        .foregroundStyle(.red)
    }
  }

  @ViewBuilder
  private func summaryTitleGame(title: String?, game: String?) -> some View {
    if let title, !title.isEmpty {
      Text(title)
        .font(.title2.weight(.semibold))
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    if let game, !game.isEmpty {
      Label(game, systemImage: "gamecontroller.fill")
        .font(.title3)
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var about: some View {
    if let description = profile?.description, !description.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("About")
          .font(.title3.weight(.bold))
        Text(description)
          .font(.title3)
          .foregroundStyle(.secondary)
          .lineLimit(4)
          .frame(maxWidth: 1100, alignment: .leading)
      }
    }
  }

  @ViewBuilder
  private var socials: some View {
    if let links = profile?.socialLinks, !links.isEmpty {
      VStack(alignment: .leading, spacing: 10) {
        Text("Links")
          .font(.title3.weight(.bold))
        HStack(spacing: 14) {
          ForEach(links.prefix(5)) { link in
            VStack(alignment: .leading, spacing: 2) {
              Text(link.title)
                .font(.callout.weight(.semibold))
              Text(Self.prettyURL(link.url))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.08))
            )
          }
        }
      }
    }
  }

  // MARK: - Loading

  private func loadProfile() async {
    isLoading = true
    loadFailed = false
    let loaded = await ChannelProfileService.fetch(login: target.login)
    profile = loaded
    loadFailed = loaded == nil
    isLoading = false
  }

  // MARK: - Formatting helpers

  private func lastSeenLabel(_ date: Date?) -> String {
    guard let date else { return "Offline" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Last live \(formatter.localizedString(for: date, relativeTo: Date()))"
  }

  static func compactCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    switch value {
    case 1_000_000...:
      return trimmed(Double(value) / 1_000_000) + "M"
    case 1_000...:
      return trimmed(Double(value) / 1_000) + "K"
    default:
      return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
  }

  static func plainCount(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  private static func trimmed(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded.truncatingRemainder(dividingBy: 1) == 0 {
      return String(Int(rounded))
    }
    return String(format: "%.1f", rounded)
  }

  static func monthYear(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM yyyy"
    return formatter.string(from: date)
  }

  static func uptime(since start: Date?) -> String? {
    guard let start else { return nil }
    let seconds = max(0, Date().timeIntervalSince(start))
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    if hours > 0 {
      return "\(hours)h \(minutes)m"
    }
    return "\(minutes)m"
  }

  static func prettyURL(_ url: String) -> String {
    var result = url
    for prefix in ["https://", "http://", "www."] {
      if result.hasPrefix(prefix) {
        result = String(result.dropFirst(prefix.count))
      }
    }
    if result.hasSuffix("/") {
      result = String(result.dropLast())
    }
    return result
  }
}
