import Foundation

/// Emote/cheermote tokenization for `ChatService`: turns a message's raw text
/// into renderable `ChatLineSegment`s against the currently-loaded catalogs, and
/// re-tokenizes the visible buffer once a catalog finishes loading.
extension ChatService {
  /// Tokenize a message against the currently-loaded emote/cheermote catalogs.
  /// Live chat gates cheermote rendering on a real bits count.
  func computeSegments(for message: ChatMessage) -> [ChatLineSegment] {
    let shouldRenderCheers = !cheermotes.isEmpty && message.bits > 0
    return ChatLineTokenizer.segments(
      text: message.text,
      twitchEmoteURLs: message.twitchEmoteURLs,
      youtubeEmoteURLs: message.youtubeEmoteURLs,
      kickEmoteURLs: message.kickEmoteURLs,
      globalEmoteURLs: emoteURLs,
      cheermotes: cheermotes,
      shouldRenderCheers: shouldRenderCheers
    )
  }

  /// Re-tokenize the visible buffer after an emote or cheermote catalog loads,
  /// so messages that arrived before the catalog resolve their emotes/cheers.
  func retokenizeVisibleBuffer() {
    guard !messages.isEmpty else { return }
    for index in messages.indices {
      messages[index].segments = computeSegments(for: messages[index])
    }
  }
}
