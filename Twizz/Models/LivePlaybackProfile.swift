import Foundation

/// User-selectable live playback profile, surfaced in the quality picker as the
/// two "Auto" options. Both keep prefetch promotion on (the real latency win) and
/// both must never stutter; they differ only in how they trade quality for
/// latency. An explicit rendition pick (e.g. "1080p60") is a third, fixed-quality
/// case that ignores the profile.
enum LivePlaybackProfile: String, CaseIterable, Identifiable {
  /// Latency priority: keep a shallow buffer near the live edge and let adaptive
  /// bitrate drop resolution to avoid a stall. Degraded quality is acceptable;
  /// stutter is not.
  case lowerLatency
  /// Quality priority: keep a deeper buffer so adaptive bitrate can settle on (and
  /// hold) the best stable resolution, accepting a little more latency. Never
  /// sacrifices quality on its own.
  case higherQuality

  var id: String { rawValue }

  /// Default for new installs. Matches the app's historical "low-latency on"
  /// stance — latency is the priority, with the no-stutter guarantee provided by
  /// ABR headroom plus the live-edge drift recovery.
  static let `default`: LivePlaybackProfile = .lowerLatency

  /// Short label used in the quality picker's two Auto rows and the button.
  var pickerLabel: String {
    switch self {
    case .lowerLatency: return "Auto · Low Latency"
    case .higherQuality: return "Auto · High Quality"
    }
  }

  /// Even shorter tag for the quality button (e.g. "Auto · LL (1080p60)").
  var shortTag: String {
    switch self {
    case .lowerLatency: return "Low Latency"
    case .higherQuality: return "Quality"
    }
  }
}

/// Concrete AVPlayer tuning derived from the active profile (and whether a single
/// rendition is hard-pinned). Centralizes the buffer / catch-up knobs that used to
/// be scattered as raw `let`s on `PlayerView`, so the latency-vs-quality tradeoff
/// lives in one place and is unit-testable.
struct LivePlaybackPolicy: Equatable {
  /// `AVPlayerItem.preferredForwardBufferDuration`. Shallower = closer to live but
  /// less jitter headroom; deeper = more stable, slightly more latency.
  var preferredForwardBufferDuration: Double
  /// Whether to nudge `player.rate` above 1.0 to drift back toward the edge when
  /// behind (imperceptible; never used to reduce quality).
  var enablesGentleCatchUp: Bool
  /// Catch-up target: the live-edge gap (seconds) to chase *down to*. Catch-up
  /// engages only while the edge gap exceeds this, and eases off as it approaches.
  var catchUpThresholdSeconds: Double
  /// Ceiling on the catch-up rate (e.g. 1.08 = at most 8% faster).
  var maxCatchUpRate: Float
  /// Proportional gain: extra rate per second of edge gap beyond the target. The
  /// further behind the edge, the faster it catches up — up to `maxCatchUpRate`.
  var catchUpRampPerSecond: Float
  /// Anti-stall floor: the slowest the player may run while easing the rate down
  /// to ride out a draining buffer. `1.0` disables the slow-down arm entirely.
  var minPlaybackRate: Float
  /// Begin easing the rate below 1.0 once the forward buffer drops under this many
  /// seconds; the rate ramps linearly from 1.0 here down to `minPlaybackRate` at an
  /// empty buffer.
  var slowdownBufferFloorSeconds: Double
  /// Only allow catch-up (speeding up) when the forward buffer is at least this
  /// healthy, so we never chase the edge while already starved.
  var catchUpHealthyBufferSeconds: Double

  /// Builds the policy for a live stream.
  /// - Parameters:
  ///   - profile: the active Auto profile.
  ///   - isPinned: true when the viewer pinned a specific rendition (not Auto).
  static func live(profile: LivePlaybackProfile, isPinned: Bool) -> LivePlaybackPolicy {
    // A pinned rendition is inherently "hold this exact quality"; it has no ABR
    // fallback, so give it a stable buffer and never fight it with catch-up.
    if isPinned {
      return LivePlaybackPolicy(
        preferredForwardBufferDuration: 8,
        enablesGentleCatchUp: false,
        catchUpThresholdSeconds: .greatestFiniteMagnitude,
        maxCatchUpRate: 1.0,
        catchUpRampPerSecond: 0,
        minPlaybackRate: 1.0,
        slowdownBufferFloorSeconds: 0,
        catchUpHealthyBufferSeconds: .greatestFiniteMagnitude
      )
    }

    switch profile {
    case .lowerLatency:
      return LivePlaybackPolicy(
        preferredForwardBufferDuration: 4,
        enablesGentleCatchUp: true,
        // Actively chase the live edge down to ~4s, scaling speed up to 1.08× the
        // further behind we are — this is what makes it a *low-latency* profile.
        catchUpThresholdSeconds: 4,
        maxCatchUpRate: 1.08,
        catchUpRampPerSecond: 0.02,
        // Ease down toward 0.90× as the buffer drains under 1.5s so a transient
        // dip is absorbed by playing slightly slow instead of a hard stall. The
        // slow-down arm is evaluated first, so it always overrides catch-up.
        minPlaybackRate: 0.90,
        slowdownBufferFloorSeconds: 1.5,
        // Catch up once the buffer clears the slow-down floor (small dead-band
        // above it to avoid flapping between the two arms).
        catchUpHealthyBufferSeconds: 2.5
      )
    case .higherQuality:
      return LivePlaybackPolicy(
        preferredForwardBufferDuration: 8,
        enablesGentleCatchUp: false,
        catchUpThresholdSeconds: .greatestFiniteMagnitude,
        maxCatchUpRate: 1.0,
        catchUpRampPerSecond: 0,
        minPlaybackRate: 1.0,
        slowdownBufferFloorSeconds: 0,
        catchUpHealthyBufferSeconds: .greatestFiniteMagnitude
      )
    }
  }
}
