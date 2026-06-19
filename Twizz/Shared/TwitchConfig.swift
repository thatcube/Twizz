import Foundation

/// Shared Twitch client configuration. Centralizes values that were previously
/// duplicated across every service so there is a single source of truth.
enum TwitchConfig {
  /// Twitch's public web ("Twilight") GraphQL client id. Used as the `Client-Id`
  /// for the unauthenticated GraphQL/scraping endpoints the app relies on, and
  /// listed in services' `disallowedClientIDs` blocklists because it can't
  /// reliably authorize the Helix followed-channel endpoints during device flow.
  static let webPublicClientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"

  /// User-Agent sent on the app's own Twitch API requests (non-scraping).
  static let apiUserAgent = "Twizz/0.1 tvOS"
}
