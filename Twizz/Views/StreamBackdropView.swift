import AVFoundation
import SwiftUI

/// Full-screen ambient backdrop driven by the currently focused stream card.
/// Shows a blurred thumbnail immediately, then swaps to a blurred live preview
/// after a short hover delay.
struct StreamBackdropView: View {
  let channel: FollowedChannel?

  @State private var player = AVPlayer()
  @State private var previewTask: Task<Void, Never>?
  @State private var activeChannelID: String?
  @State private var isShowingVideoPreview = false
  @State private var hasConfiguredPlayer = false

  var body: some View {
    ZStack {
      if let thumbnailURL = channel?.thumbnailURL {
        AsyncImage(url: thumbnailURL) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          Color.clear
        }
        .transition(.opacity)
      } else {
        Color.clear
      }

      if isShowingVideoPreview {
        VideoSurface(player: player)
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .scaleEffect(1.24)
    .saturation(1.16)
    .blur(radius: 66)
    .overlay {
      LinearGradient(
        colors: [Color.black.opacity(0.5), Color.black.opacity(0.8)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .animation(.easeOut(duration: 0.22), value: channel?.id)
    .animation(.easeOut(duration: 0.22), value: isShowingVideoPreview)
    .allowsHitTesting(false)
    .onAppear {
      configurePlayerIfNeeded()
      handleChannelChange(channel)
    }
    .onChange(of: channel?.id) { _, _ in
      handleChannelChange(channel)
    }
    .onDisappear {
      stopPreviewPlayback(clearItem: true)
    }
  }

  @MainActor
  private func configurePlayerIfNeeded() {
    guard !hasConfiguredPlayer else { return }
    player.isMuted = true
    player.actionAtItemEnd = .pause
    player.automaticallyWaitsToMinimizeStalling = true
    hasConfiguredPlayer = true
  }

  @MainActor
  private func handleChannelChange(_ channel: FollowedChannel?) {
    previewTask?.cancel()
    previewTask = nil
    isShowingVideoPreview = false
    player.pause()
    player.replaceCurrentItem(with: nil)

    guard let channel else {
      activeChannelID = nil
      return
    }

    activeChannelID = channel.id
    guard channel.isLive else { return }

    let channelID = channel.id
    let login = channel.login

    previewTask = Task { [channelID, login] in
      do {
        try await Task.sleep(for: .seconds(2))
        guard !Task.isCancelled else { return }
        let sourceURL = try await PlaybackService.hlsURL(for: login)
        guard !Task.isCancelled else { return }
        await MainActor.run {
          guard activeChannelID == channelID else { return }
          startPreviewPlayback(from: sourceURL)
          previewTask = nil
        }
      } catch is CancellationError {
        await MainActor.run {
          previewTask = nil
        }
      } catch {
        await MainActor.run {
          guard activeChannelID == channelID else { return }
          stopPreviewPlayback(clearItem: true)
          previewTask = nil
        }
      }
    }
  }

  @MainActor
  private func startPreviewPlayback(from sourceURL: URL) {
    configurePlayerIfNeeded()
    let asset = AVURLAsset(
      url: sourceURL,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
    )
    let item = AVPlayerItem(asset: asset)
    player.replaceCurrentItem(with: item)
    player.play()
    isShowingVideoPreview = true
  }

  @MainActor
  private func stopPreviewPlayback(clearItem: Bool) {
    previewTask?.cancel()
    previewTask = nil
    isShowingVideoPreview = false
    player.pause()
    if clearItem {
      player.replaceCurrentItem(with: nil)
    }
  }
}
