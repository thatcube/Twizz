import Foundation
import Observation

/// Powers the Home tab's "Recommended for you" rail with *genuinely personalized*
/// suggestions, not a top-streamers list.
///
/// It blends the viewer's signals — the categories of the channels they **follow**
/// and the categories they actually **watch** (recency-weighted, on-device) — into
/// a single "taste profile", then runs that profile through the same multi-signal
/// `SimilarChannelsEngine` used for "More like this". The result is live channels
/// similar to what the viewer already enjoys, with channels they already follow
/// removed (those have their own rail) and similarly-sized peers favored over the
/// few mega-streamers that top every directory.
@MainActor
@Observable
final class PersonalizedRecommendationsService {
  private(set) var channels: [FollowedChannel] = []
  private(set) var isLoading = false
  private(set) var lastUpdatedAt: Date?

  /// A watch counts for more than a follow: actively choosing to watch a category
  /// is a stronger taste signal than following a channel (which can go stale).
  private static let followWeight = 1.0
  private static let watchWeight = 2.0
  /// Generic catch-all categories ("Just Chatting", etc.) say little about taste,
  /// so they're heavily discounted — same rationale as the channel-DNA engine.
  private static let genericWeight = 0.15

  /// Rebuilds recommendations from the current follows and watch history. Clears
  /// the rail when personalization is disabled or there isn't enough signal yet.
  func refresh(follows: [FollowedChannel], history: WatchHistoryService) async {
    guard history.isEnabled else {
      channels = []
      lastUpdatedAt = Date()
      return
    }

    isLoading = true
    defer {
      isLoading = false
      lastUpdatedAt = Date()
    }

    let profile = Self.buildProfile(follows: follows, history: history)
    guard !profile.categoryWeights.isEmpty else {
      channels = []
      return
    }

    let signals = ChannelSignals(
      login: "",
      categoryWeights: profile.categoryWeights,
      language: nil,
      tags: [],
      viewerTier: profile.viewerTier
    )

    let recommended = await SimilarChannelsEngine.recommend(using: signals)

    // Don't recommend channels the viewer already follows or is currently being
    // shown elsewhere on Home — those live in the Following rail.
    let exclude = Set(follows.map { $0.login.lowercased() })
    channels = recommended.filter { !exclude.contains($0.login.lowercased()) }
  }

  // MARK: - Taste profile

  private struct Profile {
    let categoryWeights: [String: Double]
    let viewerTier: Int?
  }

  private static func buildProfile(
    follows: [FollowedChannel],
    history: WatchHistoryService
  ) -> Profile {
    var raw: [String: Double] = [:]

    for channel in follows {
      let game = channel.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !game.isEmpty, game.caseInsensitiveCompare("live") != .orderedSame else { continue }
      raw[game, default: 0] += followWeight
    }

    for (game, weight) in history.categoryAffinities() {
      raw[game, default: 0] += watchWeight * weight
    }

    // Down-weight generic directories so a viewer's *specific* niches drive the
    // recommendations, then normalize so the strongest signal is 1.0.
    var weighted: [String: Double] = [:]
    for (name, count) in raw {
      weighted[name] = count * (ChannelContentService.isGeneric(name) ? genericWeight : 1.0)
    }
    let maxWeight = weighted.values.max() ?? 0
    let normalized: [String: Double] =
      maxWeight > 0 ? weighted.mapValues { $0 / maxWeight } : [:]

    return Profile(categoryWeights: normalized, viewerTier: medianTier(follows: follows, history: history))
  }

  /// Median concurrent-viewer count across the channels the viewer follows and
  /// watches — the audience size their recommendations should gravitate toward.
  private static func medianTier(follows: [FollowedChannel], history: WatchHistoryService) -> Int? {
    var counts = follows.compactMap(\.viewerCount).filter { $0 > 0 }
    counts.append(contentsOf: history.entries.compactMap(\.viewerCount).filter { $0 > 0 })
    guard !counts.isEmpty else { return history.medianViewerTier }
    counts.sort()
    let mid = counts.count / 2
    return counts.count.isMultiple(of: 2) ? (counts[mid - 1] + counts[mid]) / 2 : counts[mid]
  }
}
