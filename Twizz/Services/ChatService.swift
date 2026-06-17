import Foundation
import Observation

enum ChatReadabilityMode: String, CaseIterable {
  case comfortable
  case balanced
  case compact

  var title: String {
    switch self {
    case .comfortable: return "Comfortable"
    case .balanced: return "Balanced"
    case .compact: return "Compact"
    }
  }

  var renderRatePerSecond: Double {
    switch self {
    case .comfortable: return 0.9
    case .balanced: return 1.3
    case .compact: return 1.8
    }
  }

  var historyLimit: Int {
    switch self {
    case .comfortable: return 220
    case .balanced: return 280
    case .compact: return 340
    }
  }

  var pendingLimit: Int {
    switch self {
    case .comfortable: return 120
    case .balanced: return 180
    case .compact: return 240
    }
  }

  var busyThresholdPerSecond: Double {
    switch self {
    case .comfortable: return 1.2
    case .balanced: return 2.0
    case .compact: return 3.2
    }
  }

  var stormThresholdPerSecond: Double {
    switch self {
    case .comfortable: return 3.0
    case .balanced: return 4.8
    case .compact: return 8.0
    }
  }

  var stormSampleModulo: Int {
    switch self {
    case .comfortable: return 4
    case .balanced: return 3
    case .compact: return 2
    }
  }

  var busySampleModulo: Int {
    switch self {
    case .comfortable: return 2
    case .balanced: return 3
    case .compact: return 4
    }
  }
}

/// User-adjustable width of the docked chat panel.
enum ChatWidthMode: String, CaseIterable {
  case narrow
  case medium
  case wide
  case extraWide

  var title: String {
    switch self {
    case .narrow: return "Narrow"
    case .medium: return "Medium"
    case .wide: return "Wide"
    case .extraWide: return "Extra Wide"
    }
  }

  var width: CGFloat {
    switch self {
    case .narrow: return 380
    case .medium: return 460
    case .wide: return 560
    case .extraWide: return 680
    }
  }
}

/// Where the chat panel is positioned relative to the video.
enum ChatLayoutMode: String, CaseIterable {
  /// Chat docks beside the video; the video shrinks to make room.
  case side
  /// Chat floats translucently on top of a full-width video.
  case overlay
  /// Chat floats on top of a full-width video as a rounded Liquid Glass panel.
  case glass

  var title: String {
    switch self {
    case .side: return "Side"
    case .overlay: return "Overlay"
    case .glass: return "Glass"
    }
  }

  /// Whether the chat floats on top of a full-width video (vs. docking beside it).
  var isOverlay: Bool {
    switch self {
    case .side: return false
    case .overlay, .glass: return true
    }
  }
}

private struct ChatReadabilityConfig: Equatable {
  var mode: ChatReadabilityMode = .balanced
  var smartFilteringEnabled = true
  var collapseRepeatsEnabled = true
}

/// Reads a Twitch channel's chat anonymously over IRC-via-WebSocket.
///
/// No login or token required: we connect as a `justinfan` guest, request the
/// `twitch.tv/tags` capability (for display names + colors), and parse PRIVMSG
/// lines into `ChatMessage`s. Sending messages is intentionally out of scope.
@MainActor
@Observable
final class ChatService {
  /// Rolling buffer of the most recent messages (oldest first).
  private(set) var messages: [ChatMessage] = []
  private(set) var isConnected = false
  private(set) var emoteURLs: [String: URL] = [:]
  private(set) var badgeURLs: [String: URL] = [:]
  private(set) var condensedMessagesCount = 0
  private(set) var youtubeStatusMessage: String?

  private let endpoint = URL(string: "wss://irc-ws.chat.twitch.tv:443")!
  private let rateWindowSeconds: TimeInterval = 4
  private let repeatWindowSeconds: TimeInterval = 4

  private var socket: URLSessionWebSocketTask?
  private var receiveTask: Task<Void, Never>?
  private var renderTask: Task<Void, Never>?
  private var channel: String?
  private var hasSentJoin = false
  private var hasCapAck = false
  private var pendingMessages: [ChatMessage] = []
  private var ingressTimestamps: [Date] = []
  private var repeatTracker: [String: Date] = [:]
  private var readabilityConfig = ChatReadabilityConfig()
  private var lastRenderedAt = Date.distantPast
  private var samplingCounter = 0
  private var youtubeMergeEnabled = false
  private var youtubeChannelOrURL = ""
  private var youtubeReceiveTask: Task<Void, Never>?
  private var youtubeSeenMessageIDs: Set<String> = []
  private var youtubeSeenMessageOrder: [String] = []
  private let youtubePollFallbackDelayMs: UInt64 = 1800
  private let youtubePollMinDelayMs: UInt64 = 900
  private let youtubeUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"

  func configureExperimentalYouTubeMerge(enabled: Bool, channelOrURL: String) {
    youtubeMergeEnabled = enabled
    youtubeChannelOrURL = channelOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
    restartYouTubeLoopIfNeeded()
  }

  /// Update the user-preferred chat readability behavior.
  func applyReadabilitySettings(
    mode: ChatReadabilityMode,
    smartFilteringEnabled: Bool,
    collapseRepeatsEnabled: Bool
  ) {
    readabilityConfig.mode = mode
    readabilityConfig.smartFilteringEnabled = smartFilteringEnabled
    readabilityConfig.collapseRepeatsEnabled = collapseRepeatsEnabled
    trimRenderedBufferIfNeeded()
    trimPendingBufferIfNeeded()
  }

  /// Connect and join `channel` (case-insensitive). Replaces any existing connection.
  func connect(to channel: String) {
    disconnect()
    let normalized = channel.lowercased()
    self.channel = normalized
    hasSentJoin = false
    hasCapAck = false
    pendingMessages.removeAll()
    ingressTimestamps.removeAll()
    repeatTracker.removeAll()
    lastRenderedAt = .distantPast
    samplingCounter = 0
    condensedMessagesCount = 0
    emoteURLs = [:]
    badgeURLs = [:]
    youtubeSeenMessageIDs.removeAll()
    youtubeSeenMessageOrder.removeAll()
    youtubeStatusMessage = nil

    let task = URLSession(configuration: .default).webSocketTask(with: endpoint)
    socket = task
    task.resume()

    send("PASS SCHMOOPIIE")
    send("NICK justinfan\(Int.random(in: 10_000..<99_999))")
    send("CAP REQ :twitch.tv/tags twitch.tv/commands")

    Task { [weak self] in
      guard let self else { return }
      let catalog = await EmoteCatalogService.shared.catalog(for: normalized)
      guard self.channel == normalized else { return }
      self.emoteURLs = catalog
    }

    Task { [weak self] in
      guard let self else { return }
      let catalog = await BadgeCatalogService.shared.catalog(for: normalized)
      guard self.channel == normalized else { return }
      self.badgeURLs = catalog
    }

    receiveTask = Task { [weak self] in await self?.receiveLoop() }
    restartYouTubeLoopIfNeeded()
  }

  /// Tear down the connection and clear the buffer.
  func disconnect() {
    receiveTask?.cancel()
    receiveTask = nil
    renderTask?.cancel()
    renderTask = nil
    socket?.cancel(with: .goingAway, reason: nil)
    socket = nil
    stopYouTubeLoop(clearStatus: true)
    isConnected = false
    messages.removeAll()
    pendingMessages.removeAll()
    ingressTimestamps.removeAll()
    repeatTracker.removeAll()
    condensedMessagesCount = 0
    emoteURLs.removeAll()
    badgeURLs.removeAll()
    youtubeSeenMessageIDs.removeAll()
    youtubeSeenMessageOrder.removeAll()
    channel = nil
    hasSentJoin = false
    hasCapAck = false
  }

  private func sendJoinIfNeeded() {
    guard !hasSentJoin, let channel else { return }
    send("JOIN #\(channel)")
    hasSentJoin = true
  }

  private func send(_ command: String) {
    socket?.send(.string(command + "\r\n")) { _ in }
  }

  private func receiveLoop() async {
    guard let socket else { return }
    while !Task.isCancelled {
      do {
        let frame = try await socket.receive()
        switch frame {
        case .string(let text): handle(text)
        case .data(let data): handle(String(decoding: data, as: UTF8.self))
        @unknown default: break
        }
      } catch {
        isConnected = false
        break
      }
    }
  }

  private func handle(_ raw: String) {
    // A single frame can batch multiple IRC lines.
    var parsedMessages: [ChatMessage] = []
    for piece in raw.components(separatedBy: "\r\n") where !piece.isEmpty {
      if piece.hasPrefix("PING") {
        send("PONG :tmi.twitch.tv")
        continue
      }
      if piece.contains(" CAP ") && piece.contains(" ACK ") && piece.contains("twitch.tv/tags") {
        hasCapAck = true
        sendJoinIfNeeded()
        continue
      }
      if piece.contains(" 366 ") {  // end-of-NAMES => join confirmed
        isConnected = true
        continue
      }
      if let message = ChatMessage(ircLine: piece) {
        parsedMessages.append(message)
      }
    }

    guard !parsedMessages.isEmpty else { return }
    enqueue(parsedMessages)
  }

  private func restartYouTubeLoopIfNeeded() {
    stopYouTubeLoop(clearStatus: false)

    guard youtubeMergeEnabled else {
      youtubeStatusMessage = nil
      return
    }

    guard let videoID = Self.extractYouTubeVideoID(from: youtubeChannelOrURL) else {
      youtubeStatusMessage = "YouTube merge enabled. Paste a YouTube live URL or video ID."
      return
    }

    youtubeStatusMessage = "Connecting YouTube chat…"
    youtubeReceiveTask = Task { [weak self] in
      await self?.runYouTubeLoop(videoID: videoID)
    }
  }

  private func stopYouTubeLoop(clearStatus: Bool) {
    youtubeReceiveTask?.cancel()
    youtubeReceiveTask = nil
    if clearStatus {
      youtubeStatusMessage = nil
    }
  }

  private func runYouTubeLoop(videoID: String) async {
    var continuationToken: String?
    var apiKey: String?
    var clientVersion: String?

    while !Task.isCancelled {
      do {
        if continuationToken == nil || apiKey == nil || clientVersion == nil {
          let bootstrap = try await fetchYouTubeBootstrap(videoID: videoID)
          continuationToken = bootstrap.continuation
          apiKey = bootstrap.apiKey
          clientVersion = bootstrap.clientVersion
          youtubeStatusMessage = "YouTube chat connected (experimental)."
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
        if !freshMessages.isEmpty {
          enqueue(freshMessages)
        }

        let delay = pollResult.timeoutMs ?? youtubePollFallbackDelayMs
        let clampedDelay = max(youtubePollMinDelayMs, delay)
        try? await Task.sleep(for: .milliseconds(Int(clampedDelay)))
      } catch {
        if Task.isCancelled { break }
        youtubeStatusMessage = "YouTube chat unavailable right now (experimental)."

        // Re-bootstrap after failures because continuation tokens can expire.
        continuationToken = nil
        apiKey = nil
        clientVersion = nil
        try? await Task.sleep(for: .seconds(4))
      }
    }
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
        let text = Self.extractMessageText(from: renderer),
        !author.isEmpty,
        !text.isEmpty
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

      let message = ChatMessage(youtubeAuthor: author, text: text, timestamp: timestamp)
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

  private static func extractMessageText(from renderer: [String: Any]) -> String? {
    if let message = extractSimpleOrRunsText(from: renderer["message"]), !message.isEmpty {
      return message
    }
    if let amount = extractSimpleOrRunsText(from: renderer["purchaseAmountText"]), !amount.isEmpty {
      return amount
    }
    if let header = extractSimpleOrRunsText(from: renderer["headerSubtext"]), !header.isEmpty {
      return header
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
    guard (8...16).contains(trimmed.count) else { return nil }

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
    return trimmed
  }

  private func enqueue(_ incoming: [ChatMessage]) {
    for message in incoming {
      // Readability filters are intentionally disabled.
      // We keep all messages and only pace rendering by mode.
      trackIngress(now: message.timestamp)
      pendingMessages.append(message)
    }

    pendingMessages.sort { lhs, rhs in
      if lhs.timestamp == rhs.timestamp {
        return lhs.id.uuidString < rhs.id.uuidString
      }
      return lhs.timestamp < rhs.timestamp
    }

    trimPendingBufferIfNeeded()
    ensureRenderLoop()
  }

  private func ensureRenderLoop() {
    guard renderTask == nil else { return }

    renderTask = Task { [weak self] in
      await self?.runRenderLoop()
    }
  }

  private func runRenderLoop() async {
    while !Task.isCancelled {
      if pendingMessages.isEmpty {
        try? await Task.sleep(for: .milliseconds(120))
        continue
      }

      let minInterval = 1 / readabilityConfig.mode.renderRatePerSecond
      let elapsed = Date().timeIntervalSince(lastRenderedAt)
      if elapsed < minInterval {
        let remaining = max(0, minInterval - elapsed)
        try? await Task.sleep(for: .seconds(remaining))
        continue
      }

      let message = pendingMessages.removeFirst()
      messages.append(message)
      lastRenderedAt = Date()
      trimRenderedBufferIfNeeded()
    }
  }

  private func shouldSkipMessage(_ message: ChatMessage, at now: Date) -> Bool {
    // Intentionally disabled at user request.
    // Keep this implementation commented for future experiments.
    _ = message
    _ = now
    return false

    /*
    if readabilityConfig.collapseRepeatsEnabled,
       isRepeat(message, at: now) {
        return true
    }

    guard readabilityConfig.smartFilteringEnabled else {
        return false
    }

    guard !isPriority(message) else {
        return false
    }

    let load = currentLoadLevel

    switch load {
    case .calm:
        return false
    case .busy:
        if pendingMessages.count > Int(Double(readabilityConfig.mode.pendingLimit) * 0.55) {
            samplingCounter += 1
            return samplingCounter % readabilityConfig.mode.busySampleModulo == 0
        }
        return false
    case .storm:
        samplingCounter += 1
        return samplingCounter % readabilityConfig.mode.stormSampleModulo != 0
    }
    */
  }

  private func isRepeat(_ message: ChatMessage, at now: Date) -> Bool {
    let key = normalizedRepeatKey(for: message)
    guard !key.isEmpty else { return false }

    if let lastSeen = repeatTracker[key], now.timeIntervalSince(lastSeen) <= repeatWindowSeconds {
      repeatTracker[key] = now
      pruneRepeatTracker(now: now)
      return true
    }

    repeatTracker[key] = now
    pruneRepeatTracker(now: now)
    return false
  }

  private func normalizedRepeatKey(for message: ChatMessage) -> String {
    message.text
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func isPriority(_ message: ChatMessage) -> Bool {
    if message.isAction {
      return true
    }

    if message.badgeKeys.contains(where: { badge in
      badge.hasPrefix("broadcaster/")
        || badge.hasPrefix("moderator/")
        || badge.hasPrefix("staff/")
        || badge.hasPrefix("admin/")
        || badge.hasPrefix("global_mod/")
    }) {
      return true
    }

    if let channel,
      message.text.localizedCaseInsensitiveContains("@\(channel)")
    {
      return true
    }

    return false
  }

  private func trackIngress(now: Date) {
    ingressTimestamps.append(now)
    let cutoff = now.addingTimeInterval(-rateWindowSeconds)
    while let first = ingressTimestamps.first, first < cutoff {
      ingressTimestamps.removeFirst()
    }
  }

  private enum LoadLevel {
    case calm
    case busy
    case storm
  }

  private var currentLoadLevel: LoadLevel {
    let rate = Double(ingressTimestamps.count) / rateWindowSeconds
    if rate >= readabilityConfig.mode.stormThresholdPerSecond {
      return .storm
    }
    if rate >= readabilityConfig.mode.busyThresholdPerSecond {
      return .busy
    }
    return .calm
  }

  private func trimPendingBufferIfNeeded() {
    let limit = readabilityConfig.mode.pendingLimit
    guard pendingMessages.count > limit else { return }
    pendingMessages.removeFirst(pendingMessages.count - limit)
  }

  private func trimRenderedBufferIfNeeded() {
    let limit = readabilityConfig.mode.historyLimit
    guard messages.count > limit else { return }
    messages.removeFirst(messages.count - limit)
  }

  private func pruneRepeatTracker(now: Date) {
    let cutoff = now.addingTimeInterval(-repeatWindowSeconds)
    repeatTracker = repeatTracker.filter { _, timestamp in
      timestamp >= cutoff
    }
  }
}

actor BadgeCatalogService {
  static let shared = BadgeCatalogService()

  private let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
  private let userAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

  private var cache: [String: [String: URL]] = [:]

  func catalog(for channel: String) async -> [String: URL] {
    let key = channel.lowercased()
    if let cached = cache[key] { return cached }

    let userID = await twitchUserID(for: key)

    async let global = fetchGlobalBadges()
    async let channelBadges = fetchChannelBadges(twitchUserID: userID)

    let merged = (await global).merging(await channelBadges) { _, new in new }
    cache[key] = merged
    return merged
  }

  private func fetchGlobalBadges() async -> [String: URL] {
    guard let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/global") else { return [:] }
    guard let json = await fetchJSON(url: url) else { return [:] }
    return parseBadgeJSON(json)
  }

  private func fetchChannelBadges(twitchUserID: String?) async -> [String: URL] {
    guard let twitchUserID,
      let url = URL(string: "https://api.ivr.fi/v2/twitch/badges/channel?id=\(twitchUserID)")
    else {
      return [:]
    }
    guard let json = await fetchJSON(url: url) else { return [:] }
    return parseBadgeJSON(json)
  }

  private func parseBadgeJSON(_ json: Any) -> [String: URL] {
    if let dict = json as? [String: Any] {
      return parseLegacyBadgeDisplayJSON(dict)
    }
    if let array = json as? [[String: Any]] {
      return parseIVRBadgeArray(array)
    }
    return [:]
  }

  private func parseLegacyBadgeDisplayJSON(_ json: [String: Any]) -> [String: URL] {
    guard let sets = json["badge_sets"] as? [String: Any] else { return [:] }
    var out: [String: URL] = [:]

    for (setName, setValue) in sets {
      guard let set = setValue as? [String: Any],
        let versions = set["versions"] as? [String: Any]
      else { continue }

      for (version, versionValue) in versions {
        guard let meta = versionValue as? [String: Any] else { continue }
        let urlString =
          (meta["image_url_2x"] as? String)
          ?? (meta["image_url_4x"] as? String)
          ?? (meta["image_url_1x"] as? String)
        guard let urlString, let url = URL(string: urlString) else { continue }
        out["\(setName)/\(version)"] = url
      }
    }

    return out
  }

  private func parseIVRBadgeArray(_ sets: [[String: Any]]) -> [String: URL] {
    var out: [String: URL] = [:]

    for set in sets {
      guard let setID = set["set_id"] as? String,
        let versions = set["versions"] as? [[String: Any]]
      else { continue }

      for version in versions {
        guard let versionID = version["id"] as? String else { continue }
        let urlString =
          (version["image_url_2x"] as? String)
          ?? (version["image_url_4x"] as? String)
          ?? (version["image_url_1x"] as? String)
        guard let urlString, let url = URL(string: urlString) else { continue }
        out["\(setID)/\(versionID)"] = url
      }
    }

    return out
  }

  private func twitchUserID(for login: String) async -> String? {
    if let encoded = login.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
      let ivrURL = URL(string: "https://api.ivr.fi/v2/twitch/user?login=\(encoded)"),
      let payload = await fetchJSON(url: ivrURL) as? [[String: Any]],
      let id = payload.first?["id"] as? String,
      !id.isEmpty
    {
      return id
    }

    var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
    req.httpMethod = "POST"
    req.setValue(clientID, forHTTPHeaderField: "Client-ID")
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let query = "query UserID($login: String!) { user(login: $login) { id } }"
    let body: [String: Any] = [
      "query": query,
      "variables": ["login": login],
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    guard let json = await fetchJSON(request: req) as? [String: Any] else { return nil }
    guard let data = json["data"] as? [String: Any] else { return nil }
    guard let user = data["user"] as? [String: Any] else { return nil }
    return user["id"] as? String
  }

  private func fetchJSON(url: URL) async -> Any? {
    var req = URLRequest(url: url)
    req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession.shared.data(for: req) else { return nil }
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }

  private func fetchJSON(request: URLRequest) async -> Any? {
    guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    guard (200...299).contains(status) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
  }
}
