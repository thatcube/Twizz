import AVKit
import SwiftUI

// Playback diagnostics: formatting helpers and the sampling loop that powers the
// optional on-screen diagnostics overlay (stalls, jumps, reloads, freeze state).
extension PlayerView {
  func diagFormat(_ value: Double, decimals: Int) -> String {
    String(format: "%.\(decimals)f", value)
  }

  func diagBitrate(_ bitsPerSecond: Double) -> String {
    guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "—" }
    return "\(diagFormat(bitsPerSecond / 1_000_000, decimals: 1)) Mbps"
  }

  func diagBufferAheadDescription(_ item: AVPlayerItem) -> String {
    guard let ahead = bufferAheadSeconds(item) else { return "—" }
    return "\(diagFormat(ahead, decimals: 1))s"
  }

  func diagWaitingReasonDescription() -> String {
    if player.timeControlStatus == .playing { return "none" }
    if let reason = player.reasonForWaitingToPlay {
      if reason == .toMinimizeStalls { return "toMinimizeStalls" }
      if reason == .evaluatingBufferingRate { return "evaluatingBufferingRate" }
      if reason == .noItemToPlay { return "noItemToPlay" }
      return String(describing: reason)
    }
    if player.currentItem?.isPlaybackBufferEmpty == true { return "bufferEmpty" }
    if player.currentItem?.isPlaybackLikelyToKeepUp == false { return "notLikelyToKeepUp" }
    return "unknown"
  }

  /// Records a diagnostics event, keeping only the most recent few (newest first).
  func logDiagnosticsEvent(_ text: String) {
    diagEvents.insert(DiagnosticsEvent(at: Date(), text: text), at: 0)
    if diagEvents.count > 6 {
      diagEvents.removeLast(diagEvents.count - 6)
    }
  }

  func markDiagnosticsStall(reason: String) {
    if !diagIsFrozen {
      diagIsFrozen = true
      diagFrozenSince = Date()
    }
    if !diagWasStalled {
      diagWasStalled = true
      diagStallCount += 1
      if showLatencyDiagnostics {
        logDiagnosticsEvent("stall (\(reason))")
      }
      recordStallForStability()
    }
  }

  /// Stream-stability watchdog: track stall density and, once a stream stalls
  /// repeatedly in a short window, switch to deep-buffer stability mode. This is
  /// the "detect a problematic stream and change strategy" fallback — most streams
  /// never trip it, but a struggling broadcaster encoder (lots of stalls despite
  /// ample bandwidth) does, and chasing the live edge there only makes it worse.
  func recordStallForStability() {
    guard !isVOD else { return }
    let now = Date()
    lastStallAt = now
    var recent = recentStallTimes
    recent.append(now)
    recent.removeAll { now.timeIntervalSince($0) > unstableStallWindowSeconds }
    recentStallTimes = recent

    if !isStreamUnstable, recent.count >= unstableStallCountThreshold {
      enterStreamStabilityMode()
    }
  }

  /// Switch into deep-buffer stability mode: stop chasing the live edge, deepen the
  /// forward buffer, and seek back to a cushion of already-produced segments so the
  /// source's jitter is absorbed instead of causing a stall/rewind loop.
  func enterStreamStabilityMode() {
    streamUnstableSince = Date()
    if showLatencyDiagnostics {
      logDiagnosticsEvent("stream unstable -> stability mode")
    }
    // activeLivePlaybackPolicy now returns the deep-buffer fallback; apply it.
    applyActiveLivePlaybackPolicy()
    // Build a cushion (and skip a stuck near-edge segment) by riding well back.
    guard !isUserPaused, !isScrubbing, pinnedToLive,
      let item = player.currentItem, let edge = liveSeekableEdgeSeconds(item)
    else { return }
    let start = item.seekableTimeRanges.first?.timeRangeValue.start
    let startSeconds = start.map { CMTimeGetSeconds($0) } ?? 0
    let target = max(edge - stabilityTargetBehindEdgeSeconds, startSeconds)
    let tolerance = CMTime(seconds: 1.0, preferredTimescale: 600)
    item.seek(
      to: CMTime(seconds: target, preferredTimescale: 600),
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    ) { [self] _ in
      player.playImmediately(atRate: 1.0)
    }
  }

  /// Leave stability mode after a sustained stall-free streak, returning the stream
  /// to the normal low-latency strategy (catch-up re-engages to pull back to live).
  func clearStreamStabilityIfRecovered() {
    guard isStreamUnstable, let lastStall = lastStallAt else { return }
    guard Date().timeIntervalSince(lastStall) >= streamStabilityRecoverySeconds else { return }
    streamUnstableSince = nil
    recentStallTimes = []
    if showLatencyDiagnostics {
      logDiagnosticsEvent("stream recovered -> low latency")
    }
    applyActiveLivePlaybackPolicy()
  }

  /// Detects forward/backward playhead jumps by comparing actual playhead
  /// advance against wall-clock × rate between 1s samples. A genuine AVPlayer
  /// skip-to-live shows up as several seconds of unexplained forward advance.
  func sampleDiagnostics() {
    guard showLatencyDiagnostics else {
      // Diagnostics is off by default; only write when there's something to
      // clear so this per-second call doesn't invalidate the player each tick.
      if diagLastPlayheadSeconds != nil { diagLastPlayheadSeconds = nil }
      if diagLastSampleAt != nil { diagLastSampleAt = nil }
      return
    }
    guard isPlaybackActive, let item = player.currentItem else {
      if diagLastPlayheadSeconds != nil { diagLastPlayheadSeconds = nil }
      if diagLastSampleAt != nil { diagLastSampleAt = nil }
      return
    }

    let now = Date()
    let playhead = CMTimeGetSeconds(item.currentTime())
    guard playhead.isFinite else { return }

    if let lastPlayhead = diagLastPlayheadSeconds, let lastAt = diagLastSampleAt {
      let wall = now.timeIntervalSince(lastAt)
      let advanced = playhead - lastPlayhead
      let expected = wall * Double(max(player.rate, 0))
      let forwardDrift = advanced - expected

      if forwardDrift >= diagJumpForwardThresholdSeconds {
        diagJumpCount += 1
        logDiagnosticsEvent("jump +\(diagFormat(forwardDrift, decimals: 1))s forward")
      } else if advanced <= -diagJumpBackwardThresholdSeconds {
        diagJumpCount += 1
        logDiagnosticsEvent("jump \(diagFormat(advanced, decimals: 1))s back")
      }

      if advanced >= 0.05 {
        diagIsFrozen = false
        diagFrozenSince = nil
        diagWasStalled = false
      }
    }

    diagLastPlayheadSeconds = playhead
    diagLastSampleAt = now
  }

  func resetDiagnostics() {
    diagStallCount = 0
    diagJumpCount = 0
    diagReloadCount = 0
    diagEvents = []
    diagLastPlayheadSeconds = nil
    diagLastSampleAt = nil
    diagWasStalled = false
    diagIsFrozen = false
    diagFrozenSince = nil
    diagSessionStartedAt = Date()
    lastRecoveryAttemptAt = Date.distantPast
    lastStallNotificationAt = Date.distantPast
    // New stream: forget any prior instability so we start in low-latency mode.
    streamUnstableSince = nil
    recentStallTimes = []
    lastStallAt = nil
  }
}
