import XCTest

@testable import Twizz

final class LowLatencyHLSProxyTests: XCTestCase {
  private func makeProxy() -> LowLatencyHLSProxy {
    LowLatencyHLSProxy(headers: [:])
  }

  private let source = URL(string: "https://video.example/chunked.m3u8")!

  /// A minimal Twitch-style live media playlist with two real segments and one
  /// prefetch tag. `durations` sets each real segment's `#EXTINF`.
  private func mediaPlaylist(
    mediaSequence: Int,
    segments: [(name: String, duration: Double)],
    prefetch: [String]
  ) -> String {
    var lines = [
      "#EXTM3U",
      "#EXT-X-VERSION:3",
      "#EXT-X-TARGETDURATION:2",
      "#EXT-X-MEDIA-SEQUENCE:\(mediaSequence)",
    ]
    for seg in segments {
      lines.append("#EXTINF:\(String(format: "%.3f", seg.duration)),")
      lines.append("https://video.example/\(seg.name).ts")
    }
    for url in prefetch {
      lines.append("#EXT-X-TWITCH-PREFETCH:https://video.example/\(url).ts")
    }
    return lines.joined(separator: "\n")
  }

  // MARK: - Prefetch promotion

  func testPromotesPrefetchIntoRealSegment() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(
      mediaSequence: 100,
      segments: [("seg100", 2), ("seg101", 2)],
      prefetch: ["seg102"]
    )
    let out = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: true, retainHistory: false)

    XCTAssertFalse(out.contains("#EXT-X-TWITCH-PREFETCH"), "prefetch tag should be rewritten")
    XCTAssertTrue(out.contains("https://video.example/seg102.ts"), "prefetch URL should be promoted")
    XCTAssertTrue(out.contains("https://video.example/seg100.ts"))
  }

  func testPrefetchOmittedWhenPromotionDisabled() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(
      mediaSequence: 100,
      segments: [("seg100", 2), ("seg101", 2)],
      prefetch: ["seg102"]
    )
    let out = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: false, retainHistory: false)

    XCTAssertFalse(out.contains("seg102.ts"), "prefetch should not appear when promotion is off")
    XCTAssertTrue(out.contains("seg101.ts"), "real segments still pass through")
  }

  /// Twitch prefetch tags carry no duration, so the proxy synthesizes one from
  /// the AVERAGE of the real segments (Streamlink's heuristic) — not the last one.
  func testPromotedPrefetchUsesAverageSegmentDuration() {
    let proxy = makeProxy()
    let playlist = mediaPlaylist(
      mediaSequence: 100,
      segments: [("a", 2), ("b", 4)],
      prefetch: ["c"]
    )
    let out = proxy.rewriteMediaPlaylistForTesting(
      playlist, sourceURL: source, promotePrefetch: true, retainHistory: false)

    // (2 + 4) / 2 == 3.000; the naive "last segment" heuristic would give 4.000.
    XCTAssertTrue(
      out.contains("#EXTINF:3.000,\nhttps://video.example/c.ts"),
      "expected averaged 3.000s prefetch duration, got:\n\(out)")
  }

  // MARK: - DVR (Stream Rewind) retention

  func testRetentionGrowsThenSlidesWindow() {
    let proxy = makeProxy()
    let window: Double = 5  // seconds; each segment is 2s

    // First refresh: two 2s segments (4s total) fit under the 5s window.
    _ = proxy.rewriteMediaPlaylistForTesting(
      mediaPlaylist(mediaSequence: 100, segments: [("seg100", 2), ("seg101", 2)], prefetch: []),
      sourceURL: source, promotePrefetch: false, retainHistory: true, windowSeconds: window)

    // Second refresh advances by one segment; total would be 6s, so the oldest
    // (seg100) is evicted and the media sequence advances with it.
    let out = proxy.rewriteMediaPlaylistForTesting(
      mediaPlaylist(mediaSequence: 101, segments: [("seg101", 2), ("seg102", 2)], prefetch: []),
      sourceURL: source, promotePrefetch: false, retainHistory: true, windowSeconds: window)

    XCTAssertFalse(out.contains("seg100.ts"), "oldest segment should be evicted past the window")
    XCTAssertTrue(out.contains("seg101.ts"))
    XCTAssertTrue(out.contains("seg102.ts"))
    XCTAssertTrue(out.contains("#EXT-X-MEDIA-SEQUENCE:101"), "media sequence should advance:\n\(out)")
  }

  // MARK: - Master playlist rewriting

  func testMasterRewriteReroutesVariantAndMediaURIsOntoCustomScheme() {
    let proxy = makeProxy()
    let master = [
      "#EXTM3U",
      "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aac\",URI=\"https://video.example/audio.m3u8\"",
      "#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080",
      "https://video.example/chunked.m3u8",
    ].joined(separator: "\n")

    let out = proxy.rewriteMasterPlaylistForTesting(master)

    XCTAssertTrue(out.contains("twizz-ll://video.example/chunked.m3u8"))
    XCTAssertTrue(out.contains("URI=\"twizz-ll://video.example/audio.m3u8\""))
    XCTAssertFalse(out.contains("https://video.example/chunked.m3u8"))
  }
}
