import SwiftUI

/// Maps a channel's social link to a recognizable brand glyph, accent color, and
/// label. Twitch lets streamers name links freely, so detection is driven by the
/// URL host first (reliable) with the link's `name` as a fallback hint.
enum SocialPlatform {
  case youtube, instagram, x, tiktok, facebook, discord, twitch
  case github, reddit, patreon, spotify, bluesky, website

  static func detect(url: String, name: String?) -> SocialPlatform {
    let host = (URLComponents(string: url)?.host ?? "").lowercased()
    let hint = (name ?? "").lowercased()

    func hostIs(_ domains: String...) -> Bool {
      domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    if hostIs("youtube.com", "youtu.be") || hint == "youtube" { return .youtube }
    if hostIs("instagram.com", "instagr.am") || hint == "instagram" { return .instagram }
    if hostIs("twitter.com", "x.com") || hint == "twitter" || hint == "x" { return .x }
    if hostIs("tiktok.com") || hint == "tiktok" { return .tiktok }
    if hostIs("facebook.com", "fb.com", "fb.me") || hint == "facebook" { return .facebook }
    if hostIs("discord.gg", "discord.com", "discordapp.com") || hint == "discord" { return .discord }
    if hostIs("twitch.tv") || hint == "twitch" { return .twitch }
    if hostIs("github.com") || hint == "github" { return .github }
    if hostIs("reddit.com") || hint == "reddit" { return .reddit }
    if hostIs("patreon.com") || hint == "patreon" { return .patreon }
    if hostIs("spotify.com", "open.spotify.com") || hint == "spotify" { return .spotify }
    if hostIs("bsky.app") || hint == "bluesky" { return .bluesky }
    return .website
  }

  var glyph: Glyph {
    switch self {
    case .youtube: return .brandYoutube
    case .instagram: return .brandInstagram
    case .x: return .brandX
    case .tiktok: return .brandTiktok
    case .facebook: return .brandFacebook
    case .discord: return .brandDiscord
    case .twitch: return .brandTwitch
    case .github: return .brandGithub
    case .reddit: return .brandReddit
    case .patreon: return .brandPatreon
    case .spotify: return .brandSpotify
    case .bluesky: return .brandBluesky
    case .website: return .world
    }
  }

  var tint: Color {
    switch self {
    case .youtube: return Color(red: 1.00, green: 0.00, blue: 0.00)
    case .instagram: return Color(red: 0.88, green: 0.19, blue: 0.42)
    case .x: return .primary
    case .tiktok: return .primary
    case .facebook: return Color(red: 0.09, green: 0.47, blue: 0.95)
    case .discord: return Color(red: 0.35, green: 0.40, blue: 0.95)
    case .twitch: return Color(red: 0.57, green: 0.27, blue: 1.00)
    case .github: return .primary
    case .reddit: return Color(red: 1.00, green: 0.27, blue: 0.00)
    case .patreon: return Color(red: 0.96, green: 0.26, blue: 0.30)
    case .spotify: return Color(red: 0.11, green: 0.73, blue: 0.33)
    case .bluesky: return Color(red: 0.00, green: 0.52, blue: 1.00)
    case .website: return .secondary
    }
  }
}
