import Foundation

/// Experimental YouTube live-chat merge path for `ChatService`: resolves a live
/// video, bootstraps the Innertube live-chat endpoint, polls for new messages,
/// and converts them into `ChatMessage`s. Entirely separate from the Twitch IRC
/// path; failures degrade gracefully via `youtubeStatusMessage`.
extension ChatService {
  func restartYouTubeLoopIfNeeded() {
    stopYouTubeLoop(clearStatus: false)

    guard youtubeMergeEnabled else {
      youtubeStatusMessage = nil
      return
    }

    let target = youtubeChannelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !target.isEmpty else {
      youtubeStatusMessage = "Enter a YouTube handle, URL, or video ID."
      return
    }

    youtubeStatusMessage = "Resolving YouTube live stream…"
    youtubeReceiveTask = Task { [weak self] in
      await self?.runYouTubeLoop(target: target)
    }
  }

  func stopYouTubeLoop(clearStatus: Bool) {
    youtubeReceiveTask?.cancel()
    youtubeReceiveTask = nil
    if clearStatus {
      youtubeStatusMessage = nil
    }
  }

  private func runYouTubeLoop(target: String) async {
    var videoID: String?
    var continuationToken: String?
    var apiKey: String?
    var clientVersion: String?
    var isFirstPoll = true

    while !Task.isCancelled {
      do {
        if videoID == nil {
          videoID = await resolveYouTubeVideoID(from: target)
          guard let currentVideoID = videoID else {
            youtubeStatusMessage = "No live YouTube stream found for \(target)."
            try? await Task.sleep(for: .seconds(10))
            continue
          }
          youtubeStatusMessage = "Connecting YouTube chat…"
          continuationToken = nil
          apiKey = nil
          clientVersion = nil
          _ = currentVideoID
        }

        if continuationToken == nil || apiKey == nil || clientVersion == nil {
          guard let currentVideoID = videoID else {
            throw YouTubeScrapeError.bootstrapUnavailable
          }

          let bootstrap = try await fetchYouTubeBootstrap(videoID: currentVideoID)
          continuationToken = bootstrap.continuation
          apiKey = bootstrap.apiKey
          clientVersion = bootstrap.clientVersion
          youtubeStatusMessage = "YouTube chat connected."
        }

        guard let currentContinuation = continuationToken,
          let currentAPIKey = apiKey,
          let currentClientVersion = clientVersion
        else {
          throw YouTubeScrapeError.bootstrapUnavailable
        }

        let pollResult = try await fetchYouTubeChatBatch(
          continuation: currentContinuation,
          apiKey: currentAPIKey,
          clientVersion: currentClientVersion
        )

        continuationToken = pollResult.continuation ?? continuationToken
        let freshMessages = filterAndRememberYouTubeMessages(pollResult.entries)

        let delay = pollResult.timeoutMs ?? youtubePollFallbackDelayMs
        let clampedDelay = max(youtubePollMinDelayMs, delay)

        if isFirstPoll {
          // First load: enqueue normally. The playhead + warm-up rule shows
          // recent backlog right away (capped) and eases live messages in,
          // so the panel fills instantly instead of waiting out the full delay.
          if !freshMessages.isEmpty { await enqueueTokenized(freshMessages) }
          isFirstPoll = false
          try? await Task.sleep(for: .milliseconds(Int(clampedDelay)))
        } else if freshMessages.count > 1 {
          // Trickle messages evenly across the polling interval so they arrive
          // one-by-one rather than all at once.
          let perMs = clampedDelay / UInt64(freshMessages.count)
          for msg in freshMessages {
            await enqueueTokenized([msg])
            try? await Task.sleep(for: .milliseconds(Int(perMs)))
          }
        } else {
          if !freshMessages.isEmpty { await enqueueTokenized(freshMessages) }
          try? await Task.sleep(for: .milliseconds(Int(clampedDelay)))
        }
      } catch {
        if Task.isCancelled { break }
        youtubeStatusMessage = "YouTube chat unavailable right now."

        // Re-bootstrap after failures because continuation tokens can expire.
        videoID = nil
        continuationToken = nil
        apiKey = nil
        clientVersion = nil
        try? await Task.sleep(for: .seconds(4))
      }
    }
  }

  private func resolveYouTubeVideoID(from input: String) async -> String? {
    if let direct = Self.extractYouTubeVideoID(from: input) {
      return direct
    }

    guard let liveURL = Self.makeYouTubeLiveLookupURL(from: input) else {
      return nil
    }

    var request = URLRequest(url: liveURL)
    request.timeoutInterval = 20
    request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse,
        (200...299).contains(http.statusCode)
      else {
        return nil
      }

      if let finalURL = http.url?.absoluteString,
        let id = Self.extractYouTubeVideoID(from: finalURL)
      {
        return id
      }

      let html = String(decoding: data, as: UTF8.self)
      if let canonical = Self.extractQuotedValue(after: "\"canonicalUrl\":\"", in: html) {
        let decodedCanonical = Self.decodeEscapedJSONString(canonical)
        if let id = Self.extractYouTubeVideoID(from: decodedCanonical) {
          return id
        }
      }

      if let id = Self.extractQuotedValue(after: "\"videoId\":\"", in: html)
        .flatMap(Self.sanitizedYouTubeVideoID)
      {
        return id
      }
    } catch {
      return nil
    }

    return nil
  }

  private func filterAndRememberYouTubeMessages(_ entries: [YouTubePollEntry]) -> [ChatMessage] {
    guard !entries.isEmpty else { return [] }

    var out: [ChatMessage] = []
    for entry in entries {
      guard !youtubeSeenMessageIDs.contains(entry.id) else { continue }
      youtubeSeenMessageIDs.insert(entry.id)
      youtubeSeenMessageOrder.append(entry.id)
      out.append(entry.message)
    }

    let maxSeen = 4000
    if youtubeSeenMessageOrder.count > maxSeen {
      let overflow = youtubeSeenMessageOrder.count - maxSeen
      let toRemove = youtubeSeenMessageOrder.prefix(overflow)
      for id in toRemove {
        youtubeSeenMessageIDs.remove(id)
      }
      youtubeSeenMessageOrder.removeFirst(overflow)
    }

    return out
  }

  private struct YouTubeBootstrap {
    let apiKey: String
    let clientVersion: String
    let continuation: String
  }

  private struct YouTubePollEntry {
    let id: String
    let message: ChatMessage
  }

  private struct YouTubePollResult {
    let entries: [YouTubePollEntry]
    let continuation: String?
    let timeoutMs: UInt64?
  }

  private enum YouTubeScrapeError: LocalizedError {
    case bootstrapUnavailable
    case invalidResponse
    case httpFailure(Int)

    var errorDescription: String? {
      switch self {
      case .bootstrapUnavailable:
        return "Could not initialize YouTube live chat."
      case .invalidResponse:
        return "YouTube live chat response could not be parsed."
      case .httpFailure(let statusCode):
        return "YouTube request failed (HTTP \(statusCode))."
      }
    }
  }

  private func fetchYouTubeBootstrap(videoID: String) async throws -> YouTubeBootstrap {
    guard let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") else {
      throw YouTubeScrapeError.bootstrapUnavailable
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 20
    request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw YouTubeScrapeError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      throw YouTubeScrapeError.httpFailure(http.statusCode)
    }

    let html = String(decoding: data, as: UTF8.self)
    guard
      let apiKey = Self.extractQuotedValue(after: "\"INNERTUBE_API_KEY\":\"", in: html),
      let clientVersion = Self.extractQuotedValue(after: "\"INNERTUBE_CLIENT_VERSION\":\"", in: html),
      let continuation = Self.extractInitialYouTubeContinuation(in: html)
    else {
      throw YouTubeScrapeError.bootstrapUnavailable
    }

    return YouTubeBootstrap(
      apiKey: Self.decodeEscapedJSONString(apiKey),
      clientVersion: Self.decodeEscapedJSONString(clientVersion),
      continuation: Self.decodeEscapedJSONString(continuation)
    )
  }

  private func fetchYouTubeChatBatch(
    continuation: String,
    apiKey: String,
    clientVersion: String
  ) async throws -> YouTubePollResult {
    guard
      let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let endpoint = URL(
        string: "https://www.youtube.com/youtubei/v1/live_chat/get_live_chat?key=\(encodedKey)")
    else {
      throw YouTubeScrapeError.invalidResponse
    }

    let payload: [String: Any] = [
      "context": [
        "client": [
          "clientName": "WEB",
          "clientVersion": clientVersion,
        ]
      ],
      "continuation": continuation,
      "webClientInfo": [
        "isDocumentHidden": false,
      ],
    ]

    let body = try JSONSerialization.data(withJSONObject: payload, options: [])

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(youtubeUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
    request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw YouTubeScrapeError.invalidResponse
    }
    guard (200...299).contains(http.statusCode) else {
      throw YouTubeScrapeError.httpFailure(http.statusCode)
    }

    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let continuationContents = root["continuationContents"] as? [String: Any],
      let liveChatContinuation = continuationContents["liveChatContinuation"] as? [String: Any]
    else {
      throw YouTubeScrapeError.invalidResponse
    }

    let entries = parseYouTubeEntries(from: liveChatContinuation)
    let (nextContinuation, timeoutMs) = parseYouTubeContinuation(from: liveChatContinuation)
    return YouTubePollResult(entries: entries, continuation: nextContinuation, timeoutMs: timeoutMs)
  }

  private func parseYouTubeEntries(from liveChatContinuation: [String: Any]) -> [YouTubePollEntry] {
    guard let actions = liveChatContinuation["actions"] as? [[String: Any]] else { return [] }
    var out: [YouTubePollEntry] = []

    for action in actions {
      guard
        let addChatItem = action["addChatItemAction"] as? [String: Any],
        let item = addChatItem["item"] as? [String: Any],
        let renderer = Self.findLiveChatRenderer(in: item)
      else {
        continue
      }

      guard
        let id = renderer["id"] as? String,
        let author = Self.extractSimpleOrRunsText(from: renderer["authorName"]),
        let payload = Self.extractMessagePayload(from: renderer),
        !author.isEmpty,
        !payload.text.isEmpty
      else {
        continue
      }

      let timestamp: Date
      if let tsUsec = renderer["timestampUsec"] as? String,
        let tsInt = Double(tsUsec)
      {
        timestamp = Date(timeIntervalSince1970: tsInt / 1_000_000)
      } else {
        timestamp = Date()
      }

      let message = ChatMessage(
        youtubeAuthor: author,
        text: payload.text,
        youtubeEmoteURLs: payload.emotes,
        timestamp: timestamp
      )
      out.append(YouTubePollEntry(id: id, message: message))
    }

    return out
  }

  private func parseYouTubeContinuation(from liveChatContinuation: [String: Any]) -> (
    continuation: String?, timeoutMs: UInt64?
  ) {
    guard let continuations = liveChatContinuation["continuations"] as? [[String: Any]] else {
      return (nil, nil)
    }

    for candidate in continuations {
      if let timed = candidate["timedContinuationData"] as? [String: Any] {
        let token = timed["continuation"] as? String
        let timeout = timed["timeoutMs"] as? UInt64
        return (token, timeout)
      }
      if let invalidation = candidate["invalidationContinuationData"] as? [String: Any] {
        let token = invalidation["continuation"] as? String
        let timeout = invalidation["timeoutMs"] as? UInt64
        return (token, timeout)
      }
      if let reload = candidate["reloadContinuationData"] as? [String: Any] {
        let token = reload["continuation"] as? String
        return (token, youtubePollFallbackDelayMs)
      }
    }

    return (nil, nil)
  }

  private static func findLiveChatRenderer(in item: [String: Any]) -> [String: Any]? {
    let keys = [
      "liveChatTextMessageRenderer",
      "liveChatPaidMessageRenderer",
      "liveChatMembershipItemRenderer",
    ]
    for key in keys {
      if let renderer = item[key] as? [String: Any] {
        return renderer
      }
    }
    return nil
  }

  private static func extractMessagePayload(from renderer: [String: Any]) -> (
    text: String, emotes: [String: URL]
  )? {
    if let message = extractMessageAndEmotes(from: renderer["message"]), !message.text.isEmpty {
      return message
    }

    if let amount = extractSimpleOrRunsText(from: renderer["purchaseAmountText"]), !amount.isEmpty {
      return (amount, [:])
    }

    if let header = extractSimpleOrRunsText(from: renderer["headerSubtext"]), !header.isEmpty {
      return (header, [:])
    }

    return nil
  }

  private static func extractMessageAndEmotes(from value: Any?) -> (text: String, emotes: [String: URL])? {
    guard let dictionary = value as? [String: Any] else { return nil }

    if let simple = dictionary["simpleText"] as? String {
      return simple.isEmpty ? nil : (simple, [:])
    }

    guard let runs = dictionary["runs"] as? [[String: Any]] else { return nil }

    var parts: [String] = []
    var emotes: [String: URL] = [:]

    for run in runs {
      if let runText = run["text"] as? String {
        parts.append(runText)
        continue
      }

      guard let emoji = run["emoji"] as? [String: Any] else { continue }
      let token = (emoji["shortcuts"] as? [String])?.first(where: { !$0.isEmpty })
        ?? (emoji["emojiId"] as? String)
        ?? ""
      guard !token.isEmpty else { continue }

      parts.append(token)
      if let url = extractYouTubeEmojiURL(from: emoji) {
        emotes[token] = url
      }
    }

    let text = parts.joined()
    return text.isEmpty ? nil : (text, emotes)
  }

  private static func extractYouTubeEmojiURL(from emoji: [String: Any]) -> URL? {
    guard
      let image = emoji["image"] as? [String: Any],
      let thumbnails = image["thumbnails"] as? [[String: Any]],
      !thumbnails.isEmpty
    else {
      return nil
    }

    let best = thumbnails.max { lhs, rhs in
      let lw = lhs["width"] as? Int ?? 0
      let rw = rhs["width"] as? Int ?? 0
      return lw < rw
    }

    if let bestURL = best?["url"] as? String, let url = URL(string: bestURL) {
      return url
    }

    if let firstURL = thumbnails.first?["url"] as? String, let url = URL(string: firstURL) {
      return url
    }

    return nil
  }

  private static func extractSimpleOrRunsText(from value: Any?) -> String? {
    guard let dictionary = value as? [String: Any] else { return nil }

    if let simple = dictionary["simpleText"] as? String {
      return simple
    }

    if let runs = dictionary["runs"] as? [[String: Any]] {
      let text = runs.compactMap { run -> String? in
        if let runText = run["text"] as? String {
          return runText
        }
        if let emoji = run["emoji"] as? [String: Any],
          let shortcuts = emoji["shortcuts"] as? [String],
          let first = shortcuts.first
        {
          return first
        }
        return nil
      }
      .joined()
      return text.isEmpty ? nil : text
    }

    return nil
  }

  private static func extractInitialYouTubeContinuation(in html: String) -> String? {
    if let liveIndex = html.range(of: "\"liveChatRenderer\"") {
      let tail = String(html[liveIndex.lowerBound...])
      if let continuation = extractQuotedValue(after: "\"continuation\":\"", in: tail) {
        return continuation
      }
    }
    return extractQuotedValue(after: "\"continuation\":\"", in: html)
  }

  private static func extractQuotedValue(after marker: String, in text: String) -> String? {
    guard let markerRange = text.range(of: marker) else { return nil }

    var index = markerRange.upperBound
    var out = ""
    var escaped = false

    while index < text.endIndex {
      let char = text[index]
      text.formIndex(after: &index)

      if escaped {
        out.append(char)
        escaped = false
        continue
      }

      if char == "\\" {
        escaped = true
        continue
      }

      if char == "\"" {
        return out
      }

      out.append(char)
    }

    return nil
  }

  private static func decodeEscapedJSONString(_ input: String) -> String {
    input
      .replacingOccurrences(of: "\\u0026", with: "&")
      .replacingOccurrences(of: "\\u003d", with: "=")
      .replacingOccurrences(of: "\\/", with: "/")
  }

  private static func makeYouTubeLiveLookupURL(from input: String) -> URL? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("@") {
      return URL(string: "https://www.youtube.com/\(trimmed)/live")
    }

    if !trimmed.contains("://") && !trimmed.contains("/") && !trimmed.contains("?") {
      return URL(string: "https://www.youtube.com/@\(trimmed)/live")
    }

    let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
    guard let components = URLComponents(string: normalized),
      let host = components.host?.lowercased(),
      host.contains("youtube.com")
    else {
      return nil
    }

    let parts = components.path.split(separator: "/")
    if let handle = parts.first(where: { $0.hasPrefix("@") }) {
      return URL(string: "https://www.youtube.com/\(handle)/live")
    }

    if parts.count >= 2 {
      let root = parts[0]
      if root == "channel" || root == "c" || root == "user" {
        return URL(string: "https://www.youtube.com/\(root)/\(parts[1])/live")
      }
    }

    return nil
  }

  private static func extractYouTubeVideoID(from input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if let direct = Self.sanitizedYouTubeVideoID(trimmed) {
      return direct
    }

    let normalized: String
    if trimmed.contains("://") {
      normalized = trimmed
    } else {
      normalized = "https://\(trimmed)"
    }

    guard let components = URLComponents(string: normalized),
      let host = components.host?.lowercased()
    else {
      return nil
    }

    if host.contains("youtu.be") {
      let pathComponent = components.path.split(separator: "/").first.map(String.init) ?? ""
      return sanitizedYouTubeVideoID(pathComponent)
    }

    if host.contains("youtube.com") {
      if let v = components.queryItems?.first(where: { $0.name == "v" })?.value,
        let id = sanitizedYouTubeVideoID(v)
      {
        return id
      }

      let parts = components.path.split(separator: "/")
      if parts.count >= 2 {
        if parts[0] == "live" {
          return sanitizedYouTubeVideoID(String(parts[1]))
        }
        if parts[0] == "embed" {
          return sanitizedYouTubeVideoID(String(parts[1]))
        }
      }
    }

    return nil
  }

  private static func sanitizedYouTubeVideoID(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 11 else { return nil }

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return trimmed
  }
}
