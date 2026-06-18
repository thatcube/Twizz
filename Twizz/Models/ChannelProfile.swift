import Foundation

/// A social link surfaced on a channel page (Discord, Twitter, YouTube, …).
/// Rendered as display-only text on tvOS since the platform has no browser.
struct ChannelSocialLink: Identifiable, Hashable {
  let id: String
  let name: String
  let title: String
  let url: String
}

/// Lightweight handle used to present a channel page. Carries just enough seed
/// data (login + optional name/avatar) to render the header instantly while the
/// full `ChannelProfile` loads.
struct ChannelPageTarget: Identifiable, Hashable {
  let login: String
  let displayName: String?
  let profileImageURL: URL?

  var id: String { login.lowercased() }

  init(login: String, displayName: String? = nil, profileImageURL: URL? = nil) {
    self.login = login
    self.displayName = displayName
    self.profileImageURL = profileImageURL
  }

  init(channel: FollowedChannel) {
    self.login = channel.login
    self.displayName = channel.displayName
    self.profileImageURL = channel.profileImageURL
  }
}

/// Full channel detail shown on the channel page. Fetched anonymously from
/// Twitch GQL, so every field is best-effort and may be missing.
struct ChannelProfile: Hashable {
  let login: String
  let displayName: String
  let description: String?
  let profileImageURL: URL?
  let bannerImageURL: URL?
  let createdAt: Date?
  let isPartner: Bool
  let isAffiliate: Bool
  let followerCount: Int?

  let isLive: Bool
  let liveTitle: String?
  let liveGame: String?
  let liveViewerCount: Int?
  let liveStartedAt: Date?

  let lastBroadcastTitle: String?
  let lastBroadcastGame: String?
  let lastBroadcastStartedAt: Date?

  let socialLinks: [ChannelSocialLink]
}
