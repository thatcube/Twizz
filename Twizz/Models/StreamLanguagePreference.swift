import Foundation

/// App-wide preference for which broadcast language live streams should be shown
/// in, applied across Home's "Top streams" and "Recommended for you" rails and the
/// "More like this" engine.
///
/// Stored values are either `allValue` ("all" — no filtering) or a Twitch
/// broadcaster-language **enum token** (e.g. "EN", "ES"). Twitch returns
/// `broadcastSettings.language` in exactly this uppercase token form, so values can
/// be compared directly and safely inlined into GQL `broadcasterLanguages` options.
enum StreamLanguagePreference {
  static let storageKey = PersistenceKey.streamLanguageFilter
  static let allValue = "all"

  /// Curated, ordered list for the Settings picker: (stored value, display name).
  static let options: [(value: String, name: String)] = [
    (allValue, "All languages"),
    ("EN", "English"),
    ("ES", "Spanish"),
    ("PT", "Portuguese"),
    ("FR", "French"),
    ("DE", "German"),
    ("IT", "Italian"),
    ("RU", "Russian"),
    ("JA", "Japanese"),
    ("KO", "Korean"),
    ("ZH", "Chinese"),
    ("TR", "Turkish"),
    ("PL", "Polish"),
    ("NL", "Dutch"),
    ("AR", "Arabic"),
    ("TH", "Thai"),
  ]

  /// The active preference, defaulting to the device language on first launch.
  static func current() -> String {
    if let stored = UserDefaults.standard.string(forKey: storageKey),
       !stored.isEmpty,
       options.contains(where: { $0.value == stored }) {
      return stored
    }
    return deviceDefault()
  }

  /// Device language mapped to a supported token, falling back to English.
  static func deviceDefault() -> String {
    let primary = Locale.preferredLanguages.first ?? "en"
    let code = String(primary.prefix(2)).uppercased()
    return options.contains(where: { $0.value == code }) ? code : "EN"
  }

  /// The broadcaster-language enum token to filter on, or `nil` when set to "All".
  static func token(_ value: String) -> String? {
    value == allValue ? nil : value
  }

  /// The currently-active enum token to filter on, or `nil` when set to "All".
  static func currentToken() -> String? {
    token(current())
  }

  static func displayName(_ value: String) -> String {
    options.first(where: { $0.value == value })?.name ?? value
  }
}
