import SwiftUI

/// A read-only chat panel that auto-scrolls to the newest message.
/// Designed as a translucent overlay on top of the video player.
struct ChatView: View {
    let channel: String
    let messages: [ChatMessage]
    var readabilityMode: ChatReadabilityMode = .balanced
    var isConnected: Bool = false
    var emoteURLs: [String: URL] = [:]
    var badgeURLs: [String: URL] = [:]
    var condensedMessagesCount: Int = 0
    @State private var pendingScrollWork: DispatchWorkItem?

    private var lineSpacing: CGFloat {
        switch readabilityMode {
        case .comfortable: return 14
        case .balanced: return 10
        case .compact: return 6
        }
    }

    private var horizontalPadding: CGFloat {
        switch readabilityMode {
        case .comfortable: return 28
        case .balanced: return 24
        case .compact: return 18
        }
    }

    private var verticalPadding: CGFloat {
        switch readabilityMode {
        case .comfortable: return 18
        case .balanced: return 16
        case .compact: return 12
        }
    }

    var body: some View {
        messageList
        .background(Color(white: 0.07).opacity(0.96))
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: lineSpacing) {
                    ForEach(messages) { message in
                        line(for: message)
                            .id(message.id)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
            .scrollIndicators(.hidden)
            .onChange(of: messages.count) {
                guard let last = messages.last else { return }
                pendingScrollWork?.cancel()
                let work = DispatchWorkItem {
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                pendingScrollWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
            }
            .onDisappear {
                pendingScrollWork?.cancel()
                pendingScrollWork = nil
            }
            .overlay {
                if messages.isEmpty {
                    Text(isConnected ? "Waiting for messages…" : "Connecting to chat…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if condensedMessagesCount > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("Condensed \(condensedMessagesCount)")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.45), in: Capsule())
                                .foregroundStyle(.white.opacity(0.86))
                        }
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                }
            }
        }
    }

    private func line(for message: ChatMessage) -> some View {
        return RichChatLineView(
            message: message,
            nameColor: color(for: message),
            globalEmoteURLs: emoteURLs,
            badgeURLs: badgeURLs,
            readabilityMode: readabilityMode
        )
    }

    /// Use the user's Twitch color, or a stable color derived from their name.
    private func color(for message: ChatMessage) -> Color {
        if let hex = message.colorHex, let c = Color(twitchHex: hex) {
            return c
        }
        return Self.fallbackPalette[message.username.deterministicIndex(Self.fallbackPalette.count)]
    }

    /// Bright, readable defaults (Twitch-style) for users with no color set.
    private static let fallbackPalette: [Color] = [
        Color(twitchHex: "#FF4500")!, Color(twitchHex: "#1E90FF")!, Color(twitchHex: "#00C896")!,
        Color(twitchHex: "#FF69B4")!, Color(twitchHex: "#9ACD32")!, Color(twitchHex: "#FFB000")!,
        Color(twitchHex: "#00CED1")!, Color(twitchHex: "#FF7F50")!, Color(twitchHex: "#BA8AFF")!,
        Color(twitchHex: "#5CD65C")!,
    ]
}

extension Color {
    /// Initialize from a `#RRGGBB` (or `RRGGBB`) hex string.
    init?(twitchHex hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(
            .sRGB,
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}

private extension String {
    /// A stable index in `0..<count` derived from the string's contents.
    func deterministicIndex(_ count: Int) -> Int {
        guard count > 0 else { return 0 }
        let sum = unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return sum % count
    }
}
