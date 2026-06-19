import XCTest

@testable import Twizz

final class LivePlaybackPolicyTests: XCTestCase {
  func testDefaultProfileIsLowerLatency() {
    XCTAssertEqual(LivePlaybackProfile.default, .lowerLatency)
  }

  func testProfileRawValuesAreStable() {
    // Persisted via @AppStorage — changing these would silently reset users.
    XCTAssertEqual(LivePlaybackProfile.lowerLatency.rawValue, "lowerLatency")
    XCTAssertEqual(LivePlaybackProfile.higherQuality.rawValue, "higherQuality")
  }

  func testPickerLabels() {
    XCTAssertEqual(LivePlaybackProfile.lowerLatency.pickerLabel, "Auto · Low Latency")
    XCTAssertEqual(LivePlaybackProfile.higherQuality.pickerLabel, "Auto · High Quality")
  }

  func testLowerLatencyPolicyIsShallowAndCatchesUp() {
    let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
    XCTAssertEqual(policy.preferredForwardBufferDuration, 4)
    XCTAssertTrue(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.catchUpRate, 1.04, accuracy: 0.0001)
    XCTAssertEqual(policy.catchUpThresholdSeconds, 8)
  }

  func testLowerLatencyEnablesAntiStallSlowdown() {
    let policy = LivePlaybackPolicy.live(profile: .lowerLatency, isPinned: false)
    XCTAssertEqual(policy.minPlaybackRate, 0.90, accuracy: 0.0001)
    XCTAssertEqual(policy.slowdownBufferFloorSeconds, 1.5)
    XCTAssertEqual(policy.catchUpHealthyBufferSeconds, 3)
  }

  func testHigherQualityDisablesRateGames() {
    let policy = LivePlaybackPolicy.live(profile: .higherQuality, isPinned: false)
    XCTAssertFalse(policy.enablesGentleCatchUp)
    // minPlaybackRate of 1.0 disables the anti-stall slow-down arm.
    XCTAssertEqual(policy.minPlaybackRate, 1.0, accuracy: 0.0001)
  }

  func testPinnedRenditionDisablesRateGames() {
    for profile in LivePlaybackProfile.allCases {
      let policy = LivePlaybackPolicy.live(profile: profile, isPinned: true)
      XCTAssertEqual(policy.minPlaybackRate, 1.0, accuracy: 0.0001)
    }
  }

  func testHigherQualityPolicyIsDeepAndDoesNotCatchUp() {
    let policy = LivePlaybackPolicy.live(profile: .higherQuality, isPinned: false)
    XCTAssertEqual(policy.preferredForwardBufferDuration, 8)
    XCTAssertFalse(policy.enablesGentleCatchUp)
    XCTAssertEqual(policy.catchUpRate, 1.0, accuracy: 0.0001)
  }

  func testPinnedRenditionIgnoresProfileAndNeverCatchesUp() {
    for profile in LivePlaybackProfile.allCases {
      let policy = LivePlaybackPolicy.live(profile: profile, isPinned: true)
      XCTAssertEqual(policy.preferredForwardBufferDuration, 8)
      XCTAssertFalse(policy.enablesGentleCatchUp)
      XCTAssertEqual(policy.catchUpThresholdSeconds, .greatestFiniteMagnitude)
    }
  }
}
