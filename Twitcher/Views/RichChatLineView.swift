import SwiftUI
import SDWebImageSwiftUI

struct RichChatLineView: View {
    let message: ChatMessage
    let nameColor: Color
    let globalEmoteURLs: [String: URL]
    let badgeURLs: [String: URL]

    private struct BadgeDescriptor: Identifiable {
        let key: String
        let url: URL?
        let fallback: BadgeFallback?

        var id: String { key }
    }

    private enum BadgeFallback {
        case broadcaster
        case moderator
        case subscriber
        case vip
        case founder
        case staff
        case partner
        case turbo
        case premium
        case generic

        init?(badgeKey: String) {
            let setName = badgeKey.split(separator: "/", maxSplits: 1).first.map { String($0).lowercased() } ?? ""
            switch setName {
            case "broadcaster": self = .broadcaster
            case "moderator": self = .moderator
            case "subscriber": self = .subscriber
            case "vip": self = .vip
            case "founder": self = .founder
            case "staff": self = .staff
            case "partner": self = .partner
            case "turbo": self = .turbo
            case "premium": self = .premium
            default: self = .generic
            }
        }

        var symbolName: String {
            switch self {
            case .broadcaster: return "video.fill"
            case .moderator: return "checkmark.shield.fill"
            case .subscriber: return "star.fill"
            case .vip: return "diamond.fill"
            case .founder: return "sparkles"
            case .staff: return "person.crop.square.badge.checkmark"
            case .partner: return "checkmark.seal.fill"
            case .turbo: return "bolt.fill"
            case .premium: return "crown.fill"
            case .generic: return "bookmark.fill"
            }
        }

        var foreground: Color {
            switch self {
            case .subscriber, .premium:
                return .black
            default:
                return .white
            }
        }

        var background: Color {
            switch self {
            case .broadcaster: return Color(red: 0.86, green: 0.12, blue: 0.2)
            case .moderator: return Color(red: 0.0, green: 0.58, blue: 0.33)
            case .subscriber: return Color(red: 0.98, green: 0.78, blue: 0.2)
            case .vip: return Color(red: 0.85, green: 0.34, blue: 0.72)
            case .founder: return Color(red: 0.3, green: 0.55, blue: 0.95)
            case .staff: return Color(red: 0.43, green: 0.43, blue: 0.43)
            case .partner: return Color(red: 0.42, green: 0.21, blue: 0.68)
            case .turbo: return Color(red: 0.24, green: 0.62, blue: 0.98)
            case .premium: return Color(red: 0.8, green: 0.82, blue: 0.9)
            case .generic: return Color(red: 0.22, green: 0.45, blue: 0.75)
            }
        }
    }

    private enum Segment: Hashable {
        case text(String)
        case emote(name: String, url: URL)
    }

    private var bodyColor: Color {
        message.isAction ? nameColor : .white
    }

    private var badgeDescriptors: [BadgeDescriptor] {
        message.badgeKeys.compactMap { key in
            let fallback = BadgeFallback(badgeKey: key)
            if let url = badgeURLs[key] {
                return BadgeDescriptor(key: key, url: url, fallback: fallback)
            }
            return BadgeDescriptor(key: key, url: nil, fallback: fallback)
        }
    }

    var body: some View {
        ChatFlowLayout(itemSpacing: 0, rowSpacing: 4) {
            ForEach(badgeDescriptors) { badge in
                badgeView(for: badge)
                    .padding(.trailing, 4)
            }

            Text(message.isAction ? "\(message.username) " : "\(message.username): ")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(nameColor)

            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func badgeView(for badge: BadgeDescriptor) -> some View {
        Group {
            if let url = badge.url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                    default:
                        if let fallback = badge.fallback {
                            badgeFallbackView(fallback)
                        } else {
                            Color.white.opacity(0).frame(width: 22, height: 22)
                        }
                    }
                }
            } else if let fallback = badge.fallback {
                badgeFallbackView(fallback)
            } else {
                Color.white.opacity(0).frame(width: 22, height: 22)
            }
        }
        .frame(width: 22, height: 22)
    }

    private func badgeFallbackView(_ fallback: BadgeFallback) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(fallback.background)
            .overlay {
                Image(systemName: fallback.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(fallback.foreground)
            }
    }

    @ViewBuilder
    private func segmentView(_ segment: Segment) -> some View {
        switch segment {
        case .text(let text):
            Text(text)
                .font(.system(size: 26))
                .foregroundStyle(bodyColor)
        case .emote(let name, let url):
            EmoteView(name: name, url: url, fallbackColor: bodyColor)
        }
    }

    private var segments: [Segment] {
        let punctuation = CharacterSet(charactersIn: "()[]{}<>.,!?;:\"'`")
        let words = message.text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        var output: [Segment] = []

        for idx in words.indices {
            let token = words[idx]
            if token.isEmpty {
                if idx < words.count - 1 {
                    output.append(.text(" "))
                }
                continue
            }

            let leading = token.prefix { char in
                String(char).rangeOfCharacter(from: punctuation) != nil
            }
            let trailing = token.reversed().prefix { char in
                String(char).rangeOfCharacter(from: punctuation) != nil
            }

            let coreStart = token.index(token.startIndex, offsetBy: leading.count)
            let coreEnd = token.index(token.endIndex, offsetBy: -trailing.count)
            let core = coreStart <= coreEnd ? String(token[coreStart..<coreEnd]) : token

            if !leading.isEmpty {
                output.append(.text(String(leading)))
            }

            if let url = message.twitchEmoteURLs[core] ?? globalEmoteURLs[core] {
                output.append(.emote(name: core, url: url))
            } else {
                output.append(.text(core))
            }

            if !trailing.isEmpty {
                output.append(.text(String(trailing.reversed())))
            }

            if idx < words.count - 1 {
                output.append(.text(" "))
            }
        }

        return output
    }
}

private struct EmoteView: View {
    private static let emoteHeight: CGFloat = 34

    let name: String
    let url: URL
    let fallbackColor: Color

    @State private var loadFailed = false

    var body: some View {
        Group {
            if loadFailed {
                Text(name)
                    .font(.system(size: 26))
                    .foregroundStyle(fallbackColor)
            } else {
                AnimatedImage(url: url)
                    .onFailure { _ in
                        loadFailed = true
                    }
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: Self.emoteHeight)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

struct ChatFlowLayout: Layout {
    var itemSpacing: CGFloat = 0
    var rowSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            rowHeight = max(rowHeight, size.height)
            x += size.width + itemSpacing
        }

        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )

            rowHeight = max(rowHeight, size.height)
            x += size.width + itemSpacing
        }
    }
}
