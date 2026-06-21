import AVKit
import GameController
import Observation
import SwiftUI
import UIKit

/// Small top-right chip showing the armed sleep timer: a `m:ss` countdown for
/// timed sleeps, or a short label (e.g. "End") when set to sleep at end of
/// stream.
struct SleepCountdownBadge: View {
  let text: String
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  private var chipForeground: Color {
    palette.chromeOnOpaque
  }

  static func format(seconds: Int) -> String {
    let clamped = max(0, seconds)
    return String(format: "%d:%02d", clamped / 60, clamped % 60)
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "moon.zzz.fill")
        .font(.caption)
        .foregroundStyle(chipForeground)

      Text(text)
        .font(.caption)
        .fontWeight(.semibold)
        .monospacedDigit()
        .foregroundStyle(chipForeground)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .modifier(HUDChipGlassStyle())
  }
}

// MARK: - Sleeping screen

/// Deterministic, seedable RNG so the star field is generated once and never
/// reshuffles between frames.
struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
  mutating func next() -> UInt64 {
    state = state &* 6364136223846793005 &+ 1442695040888963407
    var x = state
    x ^= x >> 33
    x = x &* 0xFF51AFD7ED558CCD
    x ^= x >> 33
    return x
  }
}

struct SleepStar {
  let x: Double
  let y: Double
  let size: Double
  let baseOpacity: Double
  let twinkleSpeed: Double
  let phase: Double
  let warmth: Double   // 0 = cool dim white, 1 = warm red
}

struct SleepShootingStar {
  let startX: Double
  let startY: Double
  let dx: Double
  let dy: Double
  let length: Double
  let period: Double
  let offset: Double
  let duration: Double
}

/// A cute, low-brightness starry-night scene for the post-sleep-timer state.
/// Warm reds + near-black keep it gentle on the eyes in a dark room, and the
/// palette is hard-coded (plus a forced dark color scheme) so it looks the same
/// whether the app is in light or dark mode.
struct SleepingScreen: View {
  private let stars: [SleepStar]
  private let shootingStars: [SleepShootingStar]

  init() {
    var rng = SeededGenerator(seed: 0x5_7A_84)
    stars = (0..<90).map { _ in
      SleepStar(
        x: Double.random(in: 0...1, using: &rng),
        y: Double.random(in: 0...1, using: &rng),
        size: Double.random(in: 1.5...3.8, using: &rng),
        baseOpacity: Double.random(in: 0.26...0.78, using: &rng),
        twinkleSpeed: Double.random(in: 0.4...1.5, using: &rng),
        phase: Double.random(in: 0...(2 * .pi), using: &rng),
        warmth: Double.random(in: 0...1, using: &rng)
      )
    }
    shootingStars = [
      SleepShootingStar(startX: 0.08, startY: 0.16, dx: 0.42, dy: 0.20,
                        length: 0.10, period: 9.0, offset: 1.5, duration: 1.1),
      SleepShootingStar(startX: 0.55, startY: 0.10, dx: 0.36, dy: 0.26,
                        length: 0.08, period: 14.0, offset: 6.0, duration: 1.3)
    ]
  }

  // Hard-coded, night-vision-friendly palette: warm reds blended with the
  // Twizz brand purple so it ties back to the logo while staying eye-friendly.
  private let skyTop = Color(red: 0.06, green: 0.01, blue: 0.04)
  private let skyBottom = Color(red: 0.08, green: 0.015, blue: 0.07)
  private let emberLow = Color(red: 0.30, green: 0.05, blue: 0.06)
  private let ember = Color(red: 0.62, green: 0.16, blue: 0.16)
  private let emberSoft = Color(red: 0.74, green: 0.28, blue: 0.24)
  private let brandPurple = Color(red: 0.569, green: 0.275, blue: 1.0)
  private let purpleGlow = Color(red: 0.42, green: 0.20, blue: 0.78)
  private let purpleSoft = Color(red: 0.66, green: 0.42, blue: 0.96)

  /// Dim white → warm red → brand purple as `warmth` rises, so the star field
  /// is a gentle blend of red and purple sparkle.
  private func starColor(_ warmth: Double, opacity: Double) -> Color {
    let cool = (r: 0.92, g: 0.82, b: 0.80)
    let red = (r: 0.86, g: 0.30, b: 0.28)
    let purple = (r: 0.64, g: 0.38, b: 0.96)
    let c: (r: Double, g: Double, b: Double)
    if warmth < 0.55 {
      let f = warmth / 0.55
      c = (cool.r + (red.r - cool.r) * f,
           cool.g + (red.g - cool.g) * f,
           cool.b + (red.b - cool.b) * f)
    } else {
      let f = (warmth - 0.55) / 0.45
      c = (red.r + (purple.r - red.r) * f,
           red.g + (purple.g - red.g) * f,
           red.b + (purple.b - red.b) * f)
    }
    return Color(red: c.r, green: c.g, blue: c.b).opacity(opacity)
  }

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Group {
      if reduceMotion {
        // Reduce Motion: render a single static frame — no twinkle, drift,
        // shooting stars, or logo pulse.
        scene(t: 0)
      } else {
        TimelineView(.animation) { timeline in
          scene(t: timeline.date.timeIntervalSinceReferenceDate)
        }
      }
    }
    .environment(\.colorScheme, .dark)
  }

  private func scene(t: Double) -> some View {
    // Slowly drifting glow centers give the scene a gentle, living motion.
    let driftA = UnitPoint(x: 0.30 + 0.14 * sin(t * 0.043),
                           y: 0.34 + 0.10 * cos(t * 0.037))
    let driftB = UnitPoint(x: 0.72 + 0.12 * cos(t * 0.031),
                           y: 0.64 + 0.13 * sin(t * 0.049))
    return ZStack {
        // Blur whatever is paused behind (stream frame + chat), then bank it
        // way down into a dark, warm night so it stays easy on the eyes.
        Rectangle()
          .fill(.ultraThinMaterial)
          .ignoresSafeArea()

        LinearGradient(
          colors: [skyTop.opacity(0.92), skyBottom.opacity(0.90), Color.black.opacity(0.92)],
          startPoint: .top,
          endPoint: .bottom
        )
        .ignoresSafeArea()

        RadialGradient(
          colors: [emberLow.opacity(0.30), .clear],
          center: driftA, startRadius: 10, endRadius: 620
        )
        .blendMode(.screen)
        .ignoresSafeArea()

        RadialGradient(
          colors: [purpleGlow.opacity(0.26), .clear],
          center: driftB, startRadius: 10, endRadius: 560
        )
        .blendMode(.screen)
        .ignoresSafeArea()

        Canvas { context, size in
          for star in stars {
            let twinkle = 0.5 + 0.5 * sin(t * star.twinkleSpeed + star.phase)
            let opacity = star.baseOpacity * (0.45 + 0.55 * twinkle)
            let d = star.size
            let cx = star.x * size.width
            let cy = star.y * size.height
            // Soft halo for a touch more presence without getting harsh.
            let halo = d * 3.0
            context.fill(
              Path(ellipseIn: CGRect(x: cx - halo / 2, y: cy - halo / 2,
                                     width: halo, height: halo)),
              with: .color(starColor(star.warmth, opacity: opacity * 0.22))
            )
            context.fill(
              Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2,
                                     width: d, height: d)),
              with: .color(starColor(star.warmth, opacity: opacity))
            )
          }

          for shot in shootingStars {
            let local = (t + shot.offset).truncatingRemainder(dividingBy: shot.period)
            guard local >= 0, local <= shot.duration else { continue }
            let p = local / shot.duration
            // Ease in/out so it streaks in and fades away.
            let fade = sin(p * .pi)
            let headX = (shot.startX + shot.dx * p) * size.width
            let headY = (shot.startY + shot.dy * p) * size.height
            let tailX = headX - shot.dx * shot.length * size.width
            let tailY = headY - shot.dy * shot.length * size.height
            var path = Path()
            path.move(to: CGPoint(x: tailX, y: tailY))
            path.addLine(to: CGPoint(x: headX, y: headY))
            context.stroke(
              path,
              with: .linearGradient(
                Gradient(colors: [
                  emberSoft.opacity(0.0),
                  emberSoft.opacity(0.55 * fade)
                ]),
                startPoint: CGPoint(x: tailX, y: tailY),
                endPoint: CGPoint(x: headX, y: headY)
              ),
              lineWidth: 2
            )
          }
        }
        .ignoresSafeArea()

        centerContent(pulse: 0.5 + 0.5 * sin(t * 0.6))
      }
      .ignoresSafeArea()
  }

  private func centerContent(pulse: Double) -> some View {
    VStack(spacing: 22) {
      Image("TwizzPixelLogo")
        .resizable()
        .interpolation(.none)
        .scaledToFit()
        .frame(width: 132, height: 132)
        .opacity(0.82 + 0.15 * pulse)
        .shadow(color: brandPurple.opacity(0.45), radius: 26)
        .shadow(color: ember.opacity(0.35), radius: 14)

      Text("Sleeping")
        .font(.system(size: 48, weight: .bold))
        .foregroundStyle(
          LinearGradient(
            colors: [emberSoft.opacity(0.85 + 0.15 * pulse),
                     purpleSoft.opacity(0.80 + 0.15 * pulse)],
            startPoint: .leading,
            endPoint: .trailing
          )
        )

      Text("Press to resume")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(emberSoft.opacity(0.5))
    }
  }
}

/// Its own `View` type so the per-second diagnostics refresh invalidates only
/// this panel. The parent computes `lines` (it owns the player state) and
/// passes them in; rendering lives here.
struct DiagnosticsPanel: View {
  let lines: [String]
  let events: [DiagnosticsEvent]
  @Environment(\.glassDisabled) private var glassDisabled
  @Environment(\.themePalette) private var palette

  private var fg: Color { palette.chromeOnOpaque }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      Text("DIAGNOSTICS")
        .font(.system(size: 13, weight: .heavy).monospaced())
        .foregroundStyle(fg.opacity(0.6))

      ForEach(lines, id: \.self) { line in
        Text(line)
          .font(.system(size: 14, weight: .semibold).monospaced())
          .foregroundStyle(fg)
      }

      if !events.isEmpty {
        Divider().overlay(fg.opacity(0.2)).padding(.vertical, 2)
        ForEach(events) { event in
          Text(Self.eventLine(event))
            .font(.system(size: 13, weight: .regular).monospaced())
            .foregroundStyle(fg.opacity(0.8))
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 520, alignment: .leading)
    .background(glassDisabled ? AnyShapeStyle(palette.chromeOpaqueSurface) : AnyShapeStyle(palette.chromeGlassTint(0.55)), in: shape)
    .overlay(shape.strokeBorder(glassDisabled ? palette.chromeOpaqueBorder : .white.opacity(0.12), lineWidth: 1))
    .clipShape(shape)
  }

  private static func eventLine(_ event: DiagnosticsEvent) -> String {
    let ago = max(0, Int(Date().timeIntervalSince(event.at).rounded()))
    return "• \(event.text)  (\(ago)s ago)"
  }
}

/// Reads the Siri Remote trackpad's absolute finger position so chat can be
/// scrolled by gesture (and held). tvOS only delivers discrete focus-move
/// events to SwiftUI, which makes scrolling feel like fixed little hops; for
/// continuous, gesture-following scrolling we read the remote's micro-gamepad
/// directly. `verticalValue` is +1 at the top of the trackpad, -1 at the
/// bottom, and 0 when the finger is centered or lifted.
final class RemoteTrackpadMonitor {
  private(set) var verticalValue: Float = 0
  private(set) var horizontalValue: Float = 0
  private(set) var hasController = false
  /// True while the touch surface is physically clicked (held down). Used to
  /// drive press-and-hold repeat, which tvOS won't deliver via discrete events.
  private(set) var clickPressed = false
  /// Directional click/press states reported by the micro-gamepad dpad buttons.
  /// These are what we probe to find a signal that distinguishes a *held*
  /// directional press from a mere finger rest.
  private(set) var dpadUpPressed = false
  private(set) var dpadDownPressed = false
  /// Direction (+1 up / -1 down / 0 none) captured at the instant of a click,
  /// while the finger position is still trustworthy. The live dpad/`y` reading
  /// flickers once the surface is clicked, so a held repeat keys off this latch
  /// plus `clickPressed` rather than the live position.
  private(set) var clickLatchedDirection = 0
  private var observers: [NSObjectProtocol] = []

  func start() {
    for controller in GCController.controllers() { configure(controller) }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .GCControllerDidConnect, object: nil, queue: .main
      ) { [weak self] note in
        if let controller = note.object as? GCController { self?.configure(controller) }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .GCControllerDidDisconnect, object: nil, queue: .main
      ) { [weak self] _ in
        self?.hasController = !GCController.controllers().isEmpty
        self?.verticalValue = 0
        self?.horizontalValue = 0
        self?.clickPressed = false
        self?.dpadUpPressed = false
        self?.dpadDownPressed = false
        self?.clickLatchedDirection = 0
      })
  }

  func stop() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    verticalValue = 0
    horizontalValue = 0
    clickPressed = false
    dpadUpPressed = false
    dpadDownPressed = false
    clickLatchedDirection = 0
  }

  private func configure(_ controller: GCController) {
    guard let micro = controller.microGamepad else { return }
    hasController = true
    // Absolute values report where the finger *is* on the pad. We use the change
    // in position (finger travel) to drive a swipe, and treat ~(0,0) as lifted.
    micro.reportsAbsoluteDpadValues = true
    micro.dpad.valueChangedHandler = { [weak self] _, x, y in
      self?.horizontalValue = x
      self?.verticalValue = y
    }
    // buttonA is the physical click of the touch surface. Holding it down (with
    // the finger over the up/down zone) is how we detect a held directional
    // press for auto-repeat.
    micro.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
      guard let self else { return }
      self.clickPressed = pressed
      if pressed {
        // Latch direction now, while the finger position is still reliable.
        if self.dpadUpPressed || self.verticalValue > 0.2 {
          self.clickLatchedDirection = 1
        } else if self.dpadDownPressed || self.verticalValue < -0.2 {
          self.clickLatchedDirection = -1
        } else {
          self.clickLatchedDirection = 0
        }
      } else {
        self.clickLatchedDirection = 0
      }
    }
    micro.dpad.up.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.dpadUpPressed = pressed
    }
    micro.dpad.down.pressedChangedHandler = { [weak self] _, _, pressed in
      self?.dpadDownPressed = pressed
    }
  }
}
