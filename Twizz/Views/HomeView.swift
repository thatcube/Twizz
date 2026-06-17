import SwiftUI

struct HomeView: View {
  private let pagePadding: CGFloat = 52
  private let channelRailVerticalPadding: CGFloat = 20
  private let targetVisibleCards: CGFloat = 4
  private let peekCardFraction: CGFloat = 0.3
  private let focusHorizontalInset: CGFloat = 12
  private let focusVerticalInset: CGFloat = 10
  private let cardCornerRadius: CGFloat = 22
  private let mediaCornerRadius: CGFloat = 18
  private let minMediaWidth: CGFloat = 220
  private let maxMediaWidth: CGFloat = 560
  private let focusedCardScale: CGFloat = 1.02

  @State private var selectedTopTab: TopTab = .home
  @State private var auth = TwitchAuthSession()
  @State private var follows = FollowedChannelsService()
  @State private var selectedChannel: FollowedChannel?
  @State private var firstFocusRequested = false

  @FocusState private var focusedChannelID: String?

  private enum TopTab: String, CaseIterable, Identifiable {
    case home = "Home"

    var id: String { rawValue }
  }

  private struct ChannelRailMetrics {
    let spacing: CGFloat
    let mediaWidth: CGFloat
    let mediaHeight: CGFloat
  }

  var body: some View {
    ZStack {
      LinearGradient(
        colors: [Color.black, Color(red: 0.09, green: 0.08, blue: 0.14)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()

      VStack(alignment: .leading, spacing: 30) {
        topTabs

        if selectedTopTab == .home {
          homeTab
        }
      }
      .padding(pagePadding)
    }
    .task {
      auth.restore()
      await follows.refresh(using: auth)
      requestFocusIfPossible(force: true)
    }
    .onChange(of: follows.channels) { _, _ in
      requestFocusIfPossible(force: false)
    }
    .onChange(of: auth.isAuthenticated) { _, _ in
      Task {
        await follows.refresh(using: auth)
        requestFocusIfPossible(force: true)
      }
    }
    .fullScreenCover(item: $selectedChannel) { channel in
      PlayerView(channel: channel.login)
    }
  }

  private var topTabs: some View {
    HStack(spacing: 16) {
      ForEach(TopTab.allCases) { tab in
        Button {
          selectedTopTab = tab
        } label: {
          Text(tab.rawValue)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 14)
                .fill(selectedTopTab == tab ? Color.white.opacity(0.2) : Color.white.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
      }

      Spacer()
    }
  }

  private var homeTab: some View {
    GeometryReader { proxy in
      let rail = channelRailMetrics(for: proxy.size.width)

      VStack(alignment: .leading, spacing: 24) {
        authBanner

        HStack {
          Text(follows.isUsingDemoData ? "Trending" : "Following")
            .font(.title.weight(.bold))

          if follows.isLoading {
            ProgressView()
              .scaleEffect(0.85)
          }

          Spacer()

          Button("Refresh") {
            Task {
              await follows.refresh(using: auth)
              requestFocusIfPossible(force: true)
            }
          }
        }

        if let errorMessage = follows.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: rail.spacing) {
            ForEach(follows.channels) { channel in
              let isFocused = focusedChannelID == channel.id

              FollowedChannelCard(
                channel: channel,
                isFocused: isFocused,
                mediaWidth: rail.mediaWidth,
                mediaHeight: rail.mediaHeight,
                focusHorizontalInset: focusHorizontalInset,
                focusVerticalInset: focusVerticalInset,
                cardCornerRadius: cardCornerRadius,
                mediaCornerRadius: mediaCornerRadius
              )
              .contentShape(RoundedRectangle(cornerRadius: cardCornerRadius))
              .focusable(true)
              .focused($focusedChannelID, equals: channel.id)
              .focusEffectDisabled()
              .onTapGesture {
                selectedChannel = channel
              }
              .accessibilityAddTraits(.isButton)
              .scaleEffect(isFocused ? focusedCardScale : 1)
              .animation(.easeOut(duration: 0.14), value: isFocused)
              .zIndex(isFocused ? 2 : 0)
            }
          }
          .padding(.vertical, channelRailVerticalPadding)
        }
        .scrollClipDisabled()

        if follows.channels.isEmpty {
          Text(follows.isUsingDemoData ? "No trending channels are available right now." : "No followed channels are available yet.")
            .foregroundStyle(.secondary)
        }

        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  private func channelRailMetrics(for availableWidth: CGFloat) -> ChannelRailMetrics {
    let width = max(availableWidth, 1)
    let spacing = max(18, min(32, width * 0.012))
    let rawOuterCardWidth = (width - ((targetVisibleCards - 1) * spacing)) / (targetVisibleCards + peekCardFraction)
    let minOuterCardWidth = minMediaWidth + (focusHorizontalInset * 2)
    let maxOuterCardWidth = maxMediaWidth + (focusHorizontalInset * 2)
    let outerCardWidth = min(max(rawOuterCardWidth, minOuterCardWidth), maxOuterCardWidth)
    let mediaWidth = outerCardWidth - (focusHorizontalInset * 2)
    let mediaHeight = mediaWidth * 9 / 16

    return ChannelRailMetrics(
      spacing: spacing,
      mediaWidth: mediaWidth,
      mediaHeight: mediaHeight
    )
  }

  private var authBanner: some View {
    VStack(alignment: .leading, spacing: 10) {
      if auth.isAuthenticated {
        HStack {
          Text("Signed in as \(auth.userDisplayName ?? auth.userLogin ?? "Twitch user")")
            .font(.headline)
          Spacer()
          Button("Sign Out") {
            auth.signOut()
            Task {
              await follows.refresh(using: auth)
              requestFocusIfPossible(force: true)
            }
          }
        }
      } else {
        HStack(spacing: 14) {
          Button(auth.isAuthenticating ? "Authenticating..." : "Sign In With Twitch") {
            Task {
              await auth.beginDeviceCodeSignIn()
              await follows.refresh(using: auth)
              requestFocusIfPossible(force: true)
            }
          }
          .disabled(auth.isAuthenticating)

          if auth.isAuthenticating {
            Button("Cancel") {
              auth.cancelSignIn()
            }
          }
        }

        if let code = auth.activationCode, let verification = auth.verificationURI {
          Text("Go to \(verification) and enter code \(code)")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if let message = auth.statusMessage {
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        if let errorMessage = auth.errorMessage {
          Text(errorMessage)
            .font(.footnote)
            .foregroundStyle(.orange)
        }

        if follows.isUsingDemoData {
          Text("Showing trending channels until you sign in with Twitch.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
  }

  private func requestFocusIfPossible(force: Bool) {
    guard let first = follows.channels.first else { return }
    if !force && firstFocusRequested { return }

    firstFocusRequested = true
    Task {
      try? await Task.sleep(for: .milliseconds(150))
      await MainActor.run {
        focusedChannelID = first.id
      }
    }
  }
}

private struct FollowedChannelCard: View {
  let channel: FollowedChannel
  let isFocused: Bool
  let mediaWidth: CGFloat
  let mediaHeight: CGFloat
  let focusHorizontalInset: CGFloat
  let focusVerticalInset: CGFloat
  let cardCornerRadius: CGFloat
  let mediaCornerRadius: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ZStack(alignment: .bottomLeading) {
        AsyncImage(url: channel.thumbnailURL) { image in
          image
            .resizable()
            .scaledToFill()
        } placeholder: {
          Color.white.opacity(0.08)
        }
        .frame(width: mediaWidth, height: mediaHeight)
        .clipShape(RoundedRectangle(cornerRadius: mediaCornerRadius))

        LinearGradient(
          colors: [Color.clear, Color.black.opacity(0.82)],
          startPoint: .top,
          endPoint: .bottom
        )
        .frame(width: mediaWidth, height: mediaHeight)
        .clipShape(RoundedRectangle(cornerRadius: mediaCornerRadius))

        HStack(spacing: 8) {
          Circle()
            .fill(channel.isLive ? Color.red : Color.gray)
            .frame(width: 8, height: 8)
          if let viewerCount = channel.viewerCount {
            Text("\(viewerCount) watching")
              .font(.caption2)
              .foregroundStyle(Color.white.opacity(0.78))
          }
        }
        .padding(12)
      }
      .frame(width: mediaWidth, alignment: .leading)

      Text(channel.displayName)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isFocused ? Color.black.opacity(0.92) : Color.primary)
        .lineLimit(1)

      Text(channel.title.isEmpty ? "No title" : channel.title)
        .font(.footnote)
        .foregroundStyle(isFocused ? Color.black.opacity(0.62) : Color.secondary)
        .lineLimit(2)
        .frame(height: 38, alignment: .topLeading)

      Text(channel.gameName)
        .font(.caption2)
        .foregroundStyle(isFocused ? Color.black.opacity(0.62) : Color.secondary)
        .lineLimit(1)
    }
    .padding(.horizontal, focusHorizontalInset)
    .padding(.vertical, focusVerticalInset)
    .frame(width: mediaWidth + (focusHorizontalInset * 2), alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: cardCornerRadius)
        .fill(isFocused ? Color.white.opacity(0.94) : Color.clear)
    }
    .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius))
    .shadow(color: Color.black.opacity(isFocused ? 0.36 : 0), radius: 20, y: 10)
  }
}

#Preview {
  HomeView()
}
