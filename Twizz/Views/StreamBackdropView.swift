import AVFoundation
import SDWebImage
import SwiftUI

/// Full-screen ambient backdrop driven by the currently focused stream card.
/// Shows a blurred thumbnail immediately, then swaps to a blurred live preview
/// after a short hover delay.
struct StreamBackdropView: View {
  let channel: FollowedChannel?

  @State private var player = AVPlayer()
  @State private var previewTask: Task<Void, Never>?
  @State private var revealVideoTask: Task<Void, Never>?
  @State private var thumbnailLoadTask: Task<Void, Never>?
  @State private var thumbnailCleanupTask: Task<Void, Never>?
  @State private var videoTeardownTask: Task<Void, Never>?
  @State private var activeChannelID: String?
  @State private var activeThumbnailURL: URL?
  @State private var activeThumbnailImage: UIImage?
  @State private var fallbackThumbnailImage: UIImage?
  @State private var persistentBackdropImage: UIImage?
  @State private var activeThumbnailOpacity = 0.0
  @State private var activeThumbnailDidLoad = false
  @State private var isShowingVideoPreview = false
  @State private var videoOpacity = 0.0
  @State private var shouldFadeOutCurrentVideoOnThumbnailReady = false
  @State private var hasConfiguredPlayer = false

  private let channelFade = Animation.easeInOut(duration: 0.32)
  private let videoFade = Animation.easeInOut(duration: 0.24)

  var body: some View {
    ZStack {
      if let persistentBackdropImage {
        Image(uiImage: persistentBackdropImage)
          .resizable()
          .scaledToFill()
      }

      if let fallbackThumbnailImage {
        Image(uiImage: fallbackThumbnailImage)
          .resizable()
          .scaledToFill()
      }

      if let activeThumbnailImage {
        Image(uiImage: activeThumbnailImage)
          .resizable()
          .scaledToFill()
          .opacity(activeThumbnailOpacity)
      }

      if isShowingVideoPreview {
        VideoSurface(player: player)
          .opacity(videoOpacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .scaleEffect(1.2)
    .saturation(1.08)
    .blur(radius: 56, opaque: true)
    .overlay {
      LinearGradient(
        colors: [Color.black.opacity(0.35), Color.black.opacity(0.62)],
        startPoint: .top,
        endPoint: .bottom
      )
    }
    .animation(channelFade, value: activeThumbnailOpacity)
    .animation(videoFade, value: videoOpacity)
    .allowsHitTesting(false)
    .onAppear {
      configurePlayerIfNeeded()
      primeThumbnailState(channel)
      handleChannelChange(channel)
    }
    .onChange(of: channel?.id) { _, _ in
      handleChannelChange(channel)
    }
    .onDisappear {
      stopPreviewPlayback(clearItem: true)
      thumbnailLoadTask?.cancel()
      thumbnailLoadTask = nil
      thumbnailCleanupTask?.cancel()
      thumbnailCleanupTask = nil
      videoTeardownTask?.cancel()
      videoTeardownTask = nil
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
  private func primeThumbnailState(_ channel: FollowedChannel?) {
    let initialThumbnailURL = channel?.thumbnailURL
    activeThumbnailURL = initialThumbnailURL
    activeThumbnailImage = nil
    fallbackThumbnailImage = nil
    activeThumbnailDidLoad = initialThumbnailURL == nil
    activeThumbnailOpacity = initialThumbnailURL == nil ? 0 : 1
    if let initialThumbnailURL {
      startThumbnailLoad(for: initialThumbnailURL, animateWhenReady: false)
    }
  }

  @MainActor
  private func transitionToThumbnail(_ thumbnailURL: URL?) {
    guard activeThumbnailURL != thumbnailURL else { return }
    thumbnailLoadTask?.cancel()
    thumbnailLoadTask = nil
    thumbnailCleanupTask?.cancel()
    thumbnailCleanupTask = nil

    if let activeThumbnailImage {
      fallbackThumbnailImage = activeThumbnailImage
    }
    activeThumbnailURL = thumbnailURL
    activeThumbnailImage = nil
    activeThumbnailDidLoad = false
    activeThumbnailOpacity = 0

    if let thumbnailURL {
      startThumbnailLoad(for: thumbnailURL, animateWhenReady: true)
    }
  }

  @MainActor
  private func startThumbnailLoad(for url: URL, animateWhenReady: Bool) {
    thumbnailLoadTask?.cancel()
    thumbnailLoadTask = Task { [url] in
      guard let image = await loadThumbnailImage(from: url) else { return }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard activeThumbnailURL == url else { return }
        activeThumbnailImage = image
        persistentBackdropImage = image
        activeThumbnailDidLoad = true
        if animateWhenReady {
          withAnimation(channelFade) {
            activeThumbnailOpacity = 1
          }
        } else {
          activeThumbnailOpacity = 1
        }
        scheduleFallbackCleanup()

        if shouldFadeOutCurrentVideoOnThumbnailReady {
          shouldFadeOutCurrentVideoOnThumbnailReady = false
          fadeOutAndTearDownCurrentVideo()
        }
      }
    }
  }

  private func loadThumbnailImage(from url: URL) async -> UIImage? {
    await withCheckedContinuation { continuation in
      SDWebImageManager.shared.loadImage(
        with: url,
        options: [.highPriority, .scaleDownLargeImages],
        progress: nil
      ) { image, _, _, _, _, _ in
        continuation.resume(returning: image)
      }
    }
  }

  @MainActor
  private func scheduleFallbackCleanup() {
    guard fallbackThumbnailImage != nil else { return }
    thumbnailCleanupTask?.cancel()
    thumbnailCleanupTask = Task {
      try? await Task.sleep(for: .milliseconds(260))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard activeThumbnailDidLoad else { return }
        guard activeThumbnailOpacity >= 0.99 else { return }
        fallbackThumbnailImage = nil
        thumbnailCleanupTask = nil
      }
    }
  }

  @MainActor
  private func handleChannelChange(_ channel: FollowedChannel?) {
    previewTask?.cancel()
    previewTask = nil
    revealVideoTask?.cancel()
    revealVideoTask = nil
    videoTeardownTask?.cancel()
    videoTeardownTask = nil

    guard let channel else {
      activeChannelID = nil
      shouldFadeOutCurrentVideoOnThumbnailReady = false
      fadeOutAndTearDownCurrentVideo(clearItem: true)
      transitionToThumbnail(nil)
      return
    }

    let hasVisibleVideo = isShowingVideoPreview && videoOpacity > 0.01
    if hasVisibleVideo {
      shouldFadeOutCurrentVideoOnThumbnailReady = true
    } else {
      shouldFadeOutCurrentVideoOnThumbnailReady = false
      tearDownVideoImmediately(clearItem: true)
    }

    activeChannelID = channel.id
    transitionToThumbnail(channel.thumbnailURL)
    guard channel.isLive else { return }

    let channelID = channel.id
    let login = channel.login
    previewTask = Task { [channelID, login] in
      do {
        async let hoverDelay: Void = Task.sleep(for: .seconds(2))
        async let sourceURLTask: URL = PlaybackService.previewHLSURL(for: login)
        try await hoverDelay
        guard !Task.isCancelled else { return }
        let sourceURL = try await sourceURLTask
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
    videoTeardownTask?.cancel()
    videoTeardownTask = nil
    let asset = AVURLAsset(
      url: sourceURL,
      options: ["AVURLAssetHTTPHeaderFieldsKey": PlaybackService.streamHeaders]
    )
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 0.8
    item.preferredPeakBitRate = 2_200_000
    player.replaceCurrentItem(with: item)
    videoOpacity = 0
    isShowingVideoPreview = true
    player.playImmediately(atRate: 1.0)
    beginVideoRevealWhenReady(item: item)
  }

  @MainActor
  private func beginVideoRevealWhenReady(item: AVPlayerItem) {
    revealVideoTask?.cancel()
    let channelID = activeChannelID
    revealVideoTask = Task { [channelID] in
      var isReadyToReveal = false
      for _ in 0..<24 {
        try? await Task.sleep(for: .milliseconds(75))
        guard !Task.isCancelled else { return }

        let readiness = await MainActor.run {
          (
            activeChannelID == channelID && player.currentItem === item,
            item.status == .readyToPlay,
            item.isPlaybackLikelyToKeepUp || !item.loadedTimeRanges.isEmpty,
            player.timeControlStatus == .playing
          )
        }

        let (isCurrentItem, isReady, hasBuffer, isPlaying) = readiness
        guard isCurrentItem else { return }
        if isReady && hasBuffer && isPlaying {
          isReadyToReveal = true
          break
        }
      }
      guard isReadyToReveal else { return }
      try? await Task.sleep(for: .milliseconds(120))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard activeChannelID == channelID, player.currentItem === item else { return }
        withAnimation(videoFade) {
          videoOpacity = 1
        }
        revealVideoTask = nil
      }
    }
  }

  @MainActor
  private func stopPreviewPlayback(clearItem: Bool) {
    previewTask?.cancel()
    previewTask = nil
    revealVideoTask?.cancel()
    revealVideoTask = nil
    videoTeardownTask?.cancel()
    videoTeardownTask = nil
    shouldFadeOutCurrentVideoOnThumbnailReady = false
    if clearItem {
      tearDownVideoImmediately(clearItem: true)
      return
    }
    fadeOutAndTearDownCurrentVideo(clearItem: clearItem)
  }

  @MainActor
  private func fadeOutAndTearDownCurrentVideo(clearItem: Bool = true) {
    guard isShowingVideoPreview else {
      tearDownVideoImmediately(clearItem: clearItem)
      return
    }
    withAnimation(videoFade) {
      videoOpacity = 0
    }
    videoTeardownTask = Task {
      try? await Task.sleep(for: .milliseconds(260))
      guard !Task.isCancelled else { return }
      await MainActor.run {
        tearDownVideoImmediately(clearItem: clearItem)
        videoTeardownTask = nil
      }
    }
  }

  @MainActor
  private func tearDownVideoImmediately(clearItem: Bool = true) {
    videoOpacity = 0
    isShowingVideoPreview = false
    player.pause()
    if clearItem {
      player.replaceCurrentItem(with: nil)
    }
  }
}
