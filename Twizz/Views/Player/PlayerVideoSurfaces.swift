import AVKit
import SwiftUI
import UIKit

/// AVPlayer host that is intentionally non-interactive: Twizz handles all remote
/// input in SwiftUI and never lets AVKit consume transport/scrub commands.
private final class PassivePlayerViewController: AVPlayerViewController {
  override var canBecomeFirstResponder: Bool { false }
}

/// Hosts an embedded `AVPlayerViewController` with native controls disabled.
/// This keeps custom Twizz UI while preserving Apple's media rendering paths
/// better than a raw `AVPlayerLayer`.
struct VideoSurface: UIViewControllerRepresentable {
  let player: AVPlayer

  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let controller = PassivePlayerViewController()
    controller.player = player
    controller.showsPlaybackControls = false
    controller.requiresLinearPlayback = true
    controller.allowsPictureInPicturePlayback = false
    controller.videoGravity = .resizeAspect
    // Keep output mode stable while toggling in-app layouts (chat on/off).
    controller.appliesPreferredDisplayCriteriaAutomatically = false
    // Prevent AVKit's internal gesture/press recognizers from handling Siri
    // Remote input (seek/scrub/skip). Twizz UI remains fully interactive.
    controller.view.isUserInteractionEnabled = false
    controller.view.backgroundColor = .black
    return controller
  }

  func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
    if controller.player !== player {
      controller.player = player
    }
    controller.showsPlaybackControls = false
    controller.requiresLinearPlayback = true
    controller.allowsPictureInPicturePlayback = false
    controller.videoGravity = .resizeAspect
    controller.appliesPreferredDisplayCriteriaAutomatically = false
    controller.view.isUserInteractionEnabled = false
  }
}

/// A `UIView` whose backing layer *is* an `AVPlayerLayer`, so corner rounding is
/// applied on the exact layer that composites the video.
final class PlayerLayerHostView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Lightweight, controls-free video surface for rounded preview tiles.
///
/// Rounding an *ancestor* of the video — SwiftUI's `.clipShape` or an enclosing
/// `AVPlayerViewController` view layer — leaves a sub-pixel "bleed" at the
/// corners on tvOS, because the video composites in its own pass and isn't
/// affected by the ancestor's mask. Applying `cornerRadius` + `masksToBounds`
/// directly on the `AVPlayerLayer` clips the video at the layer that actually
/// renders it, which removes the fringe.
struct PreviewVideoSurface: UIViewRepresentable {
  let player: AVPlayer
  var cornerRadius: CGFloat = 0

  func makeUIView(context: Context) -> PlayerLayerHostView {
    let view = PlayerLayerHostView()
    view.backgroundColor = .black
    view.isUserInteractionEnabled = false
    view.playerLayer.player = player
    view.playerLayer.videoGravity = .resizeAspect
    apply(to: view)
    return view
  }

  func updateUIView(_ view: PlayerLayerHostView, context: Context) {
    if view.playerLayer.player !== player {
      view.playerLayer.player = player
    }
    view.playerLayer.videoGravity = .resizeAspect
    apply(to: view)
  }

  private func apply(to view: PlayerLayerHostView) {
    let layer = view.playerLayer
    layer.cornerRadius = cornerRadius
    layer.cornerCurve = .continuous
    layer.masksToBounds = cornerRadius > 0
  }
}
