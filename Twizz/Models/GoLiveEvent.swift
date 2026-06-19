import Foundation

/// A followed channel that *just* transitioned from offline to live, surfaced as
/// an interactive toast so the viewer can jump straight into the broadcast.
struct GoLiveEvent: Equatable, Identifiable {
  /// Lowercased login, used both as the stable identity and as the navigation
  /// target when the viewer taps "Watch".
  let login: String
  let displayName: String
  let gameName: String

  var id: String { login }

  /// "DisplayName just went live" — the toast's primary line.
  var headline: String { "\(displayName) just went live" }

  /// Secondary line; the category when Twitch reports one.
  var subtitle: String? {
    let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
