import Foundation

/// Emote/cheermote tokenization for `ChatService`: turns a message's raw text
/// into renderable `ChatLineSegment`s against the currently-loaded catalogs, and
/// re-tokenizes the visible buffer once a catalog finishes loading.
extension ChatService {
  /// Tokenize a message against the currently-loaded emote/cheermote catalogs.
  /// Live chat gates cheermote rendering on a real bits count. Used only as the
  /// main-actor safety net in `appendVisible`; the hot path tokenizes off the
  /// main actor in `ChatIngestPipeline`.
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

  /// Request a re-tokenization of the visible buffer after a catalog loads, so
  /// messages that arrived before the catalog resolve their emotes/cheers.
  ///
  /// Coalesces the emote-catalog and cheermote-catalog arrivals: each call
  /// refreshes the pipeline snapshot and (re)arms a single debounced pass, so
  /// when both catalogs resolve close together the buffer is re-tokenized once
  /// instead of twice. The tokenization runs off the main actor; only the
  /// changed lines are re-applied here, as one array mutation.
  func requestRetokenize() {
    retokenizeCoalesceTask?.cancel()
    let snapshot = ChatCatalogSnapshot(globalEmoteURLs: emoteURLs, cheermotes: cheermotes)
    let pipeline = ingestPipeline
    retokenizeCoalesceTask = Task { [weak self] in
      await pipeline.updateSnapshot(snapshot)
      // Brief debounce so an emote + cheermote load that resolve back-to-back
      // fold into a single retokenize pass.
      try? await Task.sleep(for: .milliseconds(80))
      guard !Task.isCancelled, let self else { return }
      self.retokenizeCoalesceTask = nil

      let current = self.messages
      guard !current.isEmpty else { return }
      let changes = await pipeline.retokenize(current)
      guard !Task.isCancelled, !changes.isEmpty else { return }

      var segmentsByID: [ChatMessage.ID: [ChatLineSegment]] =
        Dictionary(minimumCapacity: changes.count)
      for change in changes { segmentsByID[change.id] = change.segments }

      // Apply against the *live* buffer (it may have appended/trimmed while the
      // off-main pass ran) by id, then publish as one mutation.
      var updated = self.messages
      var didChange = false
      for index in updated.indices {
        if let segments = segmentsByID[updated[index].id] {
          updated[index].segments = segments
          didChange = true
        }
      }
      if didChange { self.messages = updated }
    }
  }
}
