import Foundation

/// Immutable, by-value catalog snapshot the background ingest stage tokenizes
/// against. Capturing the catalogs by value lets `ChatIngestPipeline` run off
/// the main actor without ever touching `ChatService`'s `@MainActor` state; the
/// snapshot is refreshed (via `updateSnapshot`) whenever a catalog loads.
struct ChatCatalogSnapshot: Sendable {
  let globalEmoteURLs: [String: URL]
  let cheermotes: [Cheermote]

  static let empty = ChatCatalogSnapshot(globalEmoteURLs: [:], cheermotes: [])
}

/// Serial background stage that parses raw IRC frames into `ChatMessage`s and
/// computes their render-ready `segments` off the main actor, against an
/// immutable catalog snapshot.
///
/// Being an `actor` keeps the stage strictly serial, so message order — both
/// within a frame and across frames awaited in sequence by the receive loop —
/// is preserved exactly. The main actor only ever receives finished,
/// segment-attached batches, so the heavy per-message tag parsing + tokenization
/// never runs on the thread that drives chat scrolling.
actor ChatIngestPipeline {
  private var snapshot: ChatCatalogSnapshot

  init(snapshot: ChatCatalogSnapshot = .empty) {
    self.snapshot = snapshot
  }

  func updateSnapshot(_ snapshot: ChatCatalogSnapshot) {
    self.snapshot = snapshot
  }

  /// Parse PRIVMSG/USERNOTICE IRC line pieces into segment-attached messages.
  /// Preserves the original precedence from `ChatService.handle`: a highlighted
  /// USERNOTICE is tried first, then a plain PRIVMSG.
  func parseAndTokenize(_ pieces: [String]) -> [ChatMessage] {
    var out: [ChatMessage] = []
    out.reserveCapacity(pieces.count)
    for piece in pieces {
      if var message = ChatMessage(highlightedUSERNOTICE: piece) {
        message.segments = segments(for: message)
        out.append(message)
      } else if var message = ChatMessage(ircLine: piece) {
        message.segments = segments(for: message)
        out.append(message)
      }
    }
    return out
  }

  /// Attach segments to already-parsed messages (YouTube/Kick) off the main
  /// actor, so their tokenization doesn't run on the scroll thread either.
  func tokenize(_ messages: [ChatMessage]) -> [ChatMessage] {
    guard !messages.isEmpty else { return messages }
    var out = messages
    for index in out.indices {
      out[index].segments = segments(for: out[index])
    }
    return out
  }

  /// Recompute segments for the supplied buffer after a catalog loads and return
  /// `(id, segments)` pairs for only the lines whose segments actually changed.
  /// Inert lines that cannot gain an emote/cheer are skipped before tokenizing,
  /// and unchanged lines are filtered out, so the main actor only re-applies the
  /// minimum.
  func retokenize(
    _ messages: [ChatMessage]
  ) -> [(id: ChatMessage.ID, segments: [ChatLineSegment])] {
    var out: [(id: ChatMessage.ID, segments: [ChatLineSegment])] = []
    for message in messages {
      guard mightGainEmoteOrCheer(message) else { continue }
      let recomputed = segments(for: message)
      if message.segments != recomputed {
        out.append((message.id, recomputed))
      }
    }
    return out
  }

  /// Whether a line could newly resolve an emote/cheer once the current catalog
  /// snapshot is applied. Skips lines that demonstrably can't: a line only gains
  /// a cheer when it carries bits, gains a scoped/YouTube emote when it has emote
  /// tags or a `:` shortcode, or gains a global (7TV/BTTV/FFZ) emote when the
  /// global catalog is non-empty (those match plain word tokens with no `:`).
  private func mightGainEmoteOrCheer(_ message: ChatMessage) -> Bool {
    if message.text.isEmpty { return false }
    if message.bits > 0 { return true }
    if !message.twitchEmoteURLs.isEmpty
      || !message.youtubeEmoteURLs.isEmpty
      || !message.kickEmoteURLs.isEmpty {
      return true
    }
    if message.text.contains(":") { return true }
    // A loaded global catalog can resolve bare word tokens, so any non-empty
    // line is a candidate; with no global catalog there's nothing left to match.
    return !snapshot.globalEmoteURLs.isEmpty
  }

  private func segments(for message: ChatMessage) -> [ChatLineSegment] {
    let shouldRenderCheers = !snapshot.cheermotes.isEmpty && message.bits > 0
    return ChatLineTokenizer.segments(
      text: message.text,
      twitchEmoteURLs: message.twitchEmoteURLs,
      youtubeEmoteURLs: message.youtubeEmoteURLs,
      kickEmoteURLs: message.kickEmoteURLs,
      globalEmoteURLs: snapshot.globalEmoteURLs,
      cheermotes: snapshot.cheermotes,
      shouldRenderCheers: shouldRenderCheers
    )
  }
}
