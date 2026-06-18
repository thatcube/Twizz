import AVFoundation
import Foundation
import OSLog

/// Produces a real loudness contour for the audio-only visualizer by decoding
/// the stream ourselves.
///
/// AVPlayer + live HLS does not expose decompressed PCM to an
/// `MTAudioProcessingTap`, so we can't meter the playing item directly. Instead
/// we poll the audio-only media playlist, download the freshest **self-contained
/// MPEG-TS segment**, and run an `AVAssetReader` over that *local* file (which is
/// allowed) to compute a short RMS contour. Those samples are handed to
/// `AudioLevelMonitor`, which plays them out so the orb pulses with the audio.
///
/// Best effort by design: if a stream uses a container we can't decode in
/// isolation (e.g. fMP4 media segments that need a separate init segment), the
/// reader yields nothing and the monitor stays on its ambient animation.
actor AudioOnlyLevelDecoder {
  private let playlistURL: URL
  private let headers: [String: String]
  private weak var monitor: AudioLevelMonitor?
  private let log = Logger(subsystem: "com.thatcube.Twizz", category: "AudioOnlyLevelDecoder")

  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    config.urlCache = nil
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    config.waitsForConnectivity = false
    return URLSession(configuration: config)
  }()

  private var loop: Task<Void, Never>?
  private var processedSegments: Set<String> = []

  /// Target metering resolution: one RMS value per this many seconds of audio.
  private let windowSeconds: Double = 0.05
  private let fallbackSegmentDuration: Double = 2.0

  init(playlistURL: URL, headers: [String: String], monitor: AudioLevelMonitor) {
    self.playlistURL = playlistURL
    self.headers = headers
    self.monitor = monitor
  }

  func start() {
    guard loop == nil else { return }
    loop = Task { [weak self] in
      await self?.run()
    }
  }

  func stop() {
    loop?.cancel()
    loop = nil
  }

  // MARK: - Polling loop

  private func run() async {
    while !Task.isCancelled {
      let pace: Double
      do {
        pace = try await tick()
      } catch {
        pace = fallbackSegmentDuration
      }
      // Pace roughly to one segment of audio so we track the live edge without
      // racing ahead of what AVPlayer is actually playing.
      try? await Task.sleep(for: .seconds(min(max(pace, 0.5), 4.0)))
    }
  }

  /// Fetches the playlist, decodes every newly-seen segment in order, and returns
  /// how long (seconds) to wait before the next poll.
  private func tick() async throws -> Double {
    let playlist = try await fetchText(playlistURL)
    let segments = parseSegments(playlist, relativeTo: playlistURL)
    guard !segments.isEmpty else { return fallbackSegmentDuration }

    // Avoid unbounded growth of the seen-set while keeping recent identity.
    if processedSegments.count > 256 {
      processedSegments.removeAll(keepingCapacity: true)
    }

    // Decode every not-yet-seen segment in chronological order so the loudness
    // timeline stays continuous — gaps would break alignment with playback.
    // Bound the catch-up so the very first poll doesn't decode the whole window.
    let unseen = segments.filter { !processedSegments.contains($0.url.absoluteString) }
    for seg in unseen { processedSegments.insert(seg.url.absoluteString) }

    var lastDuration = segments.last?.duration ?? fallbackSegmentDuration
    for seg in unseen.suffix(6) {
      do {
        let data = try await fetchData(seg.url)
        let contour = try await decodeRMSContour(from: data, fallbackDuration: seg.duration)
        if !contour.isEmpty {
          let interval = seg.duration / Double(contour.count)
          await monitor?.enqueueRealLevels(contour, interval: interval, startDate: seg.startDate)
        }
        lastDuration = seg.duration
      } catch {
        continue
      }
    }
    return lastDuration
  }

  // MARK: - Networking

  private func fetchText(_ url: URL) async throws -> String {
    let data = try await fetchData(url)
    return String(decoding: data, as: UTF8.self)
  }

  private func fetchData(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    for (key, value) in headers {
      request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, _) = try await session.data(for: request)
    return data
  }

  // MARK: - Playlist parsing

  private struct Segment {
    let url: URL
    let duration: Double
    let startDate: Date?
  }

  private let dateParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private let plainDateParser: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  private func parseDate(_ string: String) -> Date? {
    dateParser.date(from: string) ?? plainDateParser.date(from: string)
  }

  private func parseSegments(_ text: String, relativeTo base: URL) -> [Segment] {
    var segments: [Segment] = []
    var pendingDuration = fallbackSegmentDuration
    // Program-date-time may be stated once and then implied per segment, so we
    // carry a running clock and advance it by each segment's duration.
    var runningDate: Date?
    var pendingDate: Date?
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:") {
        let value = String(line.dropFirst("#EXT-X-PROGRAM-DATE-TIME:".count))
        let date = parseDate(value)
        runningDate = date
        pendingDate = date
      } else if line.hasPrefix("#EXTINF:") {
        let value = line.dropFirst("#EXTINF:".count)
        let number = value.prefix { $0.isNumber || $0 == "." }
        pendingDuration = Double(number) ?? fallbackSegmentDuration
      } else if !line.isEmpty, !line.hasPrefix("#") {
        let url = URL(string: line, relativeTo: base)?.absoluteURL
        if let url {
          let start = pendingDate ?? runningDate
          segments.append(Segment(url: url, duration: pendingDuration, startDate: start))
          if let rd = runningDate {
            runningDate = rd.addingTimeInterval(pendingDuration)
          }
        }
        pendingDate = nil
        pendingDuration = fallbackSegmentDuration
      }
    }
    return segments
  }

  // MARK: - Decoding

  /// Decodes a single self-contained media segment into an RMS loudness contour.
  private func decodeRMSContour(from data: Data, fallbackDuration: Double) async throws -> [Double] {
    let sniffed = Self.containerExtension(for: data)

    // AVFoundation can't read tracks from a raw MPEG-TS file, but it *can* read a
    // raw ADTS `.aac` file. Twitch's audio-only segments are AAC inside MPEG-TS,
    // so when we see a `.ts` we demux the AAC elementary stream out first.
    let decodable: Data
    let ext: String
    if sniffed == "ts" {
      guard let adts = TSAudioExtractor.extractADTS(from: data), !adts.isEmpty else {
        log.info("Could not extract AAC from MPEG-TS segment; staying on ambient.")
        return []
      }
      decodable = adts
      ext = "aac"
    } else {
      decodable = data
      ext = sniffed
    }

    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("twizz-audio-\(UUID().uuidString).\(ext)")
    try decodable.write(to: tempURL)
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let asset = AVURLAsset(url: tempURL)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      log.info("Segment exposed no audio track; staying on ambient visualizer.")
      return []
    }

    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]

    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { return [] }
    reader.add(output)
    guard reader.startReading() else { return [] }

    var mono: [Float] = []
    mono.reserveCapacity(96_000)
    var sampleRate: Double = 48_000

    while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
      if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
      {
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : sampleRate
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        appendSamples(from: sampleBuffer, channels: channels, into: &mono)
      }
      CMSampleBufferInvalidate(sampleBuffer)
    }

    guard reader.status != .failed, !mono.isEmpty else { return [] }

    let duration = Double(mono.count) / sampleRate
    let effectiveDuration = duration > 0 ? duration : fallbackDuration
    let windowCount = max(1, Int((effectiveDuration / windowSeconds).rounded()))
    return Self.rmsContour(from: mono, windowCount: windowCount)
  }

  private func appendSamples(
    from sampleBuffer: CMSampleBuffer, channels: Int, into mono: inout [Float]
  ) {
    guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    var lengthAtOffset = 0
    var totalLength = 0
    var dataPointer: UnsafeMutablePointer<Int8>?
    let status = CMBlockBufferGetDataPointer(
      blockBuffer,
      atOffset: 0,
      lengthAtOffsetOut: &lengthAtOffset,
      totalLengthOut: &totalLength,
      dataPointerOut: &dataPointer
    )
    guard status == kCMBlockBufferNoErr, let dataPointer else { return }

    let floatCount = totalLength / MemoryLayout<Float>.size
    guard floatCount > 0 else { return }
    dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { floats in
      var i = 0
      while i < floatCount {
        if channels == 1 {
          mono.append(floats[i])
          i += 1
        } else {
          var sum: Float = 0
          var c = 0
          while c < channels, i + c < floatCount {
            sum += floats[i + c]
            c += 1
          }
          mono.append(sum / Float(channels))
          i += channels
        }
      }
    }
  }

  private static func rmsContour(from samples: [Float], windowCount: Int) -> [Double] {
    guard windowCount > 0, !samples.isEmpty else { return [] }
    let windowSize = max(1, samples.count / windowCount)
    var contour: [Double] = []
    contour.reserveCapacity(windowCount)
    var index = 0
    while index < samples.count {
      let end = min(index + windowSize, samples.count)
      var sumSquares: Double = 0
      var n = 0
      var j = index
      while j < end {
        let v = Double(samples[j])
        sumSquares += v * v
        n += 1
        j += 1
      }
      if n > 0 {
        contour.append((sumSquares / Double(n)).squareRoot())
      }
      index = end
    }
    return contour
  }

  /// Sniffs the container so the temp file gets an extension AVURLAsset trusts.
  private static func containerExtension(for data: Data) -> String {
    // MPEG-TS packets start with the 0x47 sync byte at 188-byte intervals.
    if data.first == 0x47 { return "ts" }
    // fMP4 / ISO-BMFF: 'ftyp' or 'styp' box type at bytes 4...8.
    if data.count >= 8 {
      let boxType = data.subdata(in: 4..<8)
      if boxType == Data("ftyp".utf8) || boxType == Data("styp".utf8) || boxType == Data("moof".utf8) {
        return "mp4"
      }
    }
    return "ts"
  }
}

/// Minimal MPEG-TS demuxer that pulls the AAC (ADTS) audio elementary stream out
/// of a Twitch `.ts` segment.
///
/// AVFoundation refuses to expose tracks from a raw MPEG-TS file, but it happily
/// decodes a raw ADTS `.aac` file. Twitch carries AAC audio (stream type 0x0F,
/// already ADTS-framed) inside its transport stream, so concatenating the audio
/// PID's PES payloads yields a valid `.aac` file we can hand to AVAssetReader.
private enum TSAudioExtractor {
  private static let packetSize = 188

  static func extractADTS(from data: Data) -> Data? {
    guard data.count >= packetSize else { return nil }

    var pmtPID: Int?
    var audioPID: Int?
    var es = Data()
    es.reserveCapacity(data.count / 2)

    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let base = raw.baseAddress else { return }
      let bytes = base.assumingMemoryBound(to: UInt8.self)
      let count = raw.count

      // Find the first TS sync byte (segments occasionally carry a few stray
      // leading bytes).
      var offset = 0
      while offset + packetSize <= count, bytes[offset] != 0x47 { offset += 1 }

      while offset + packetSize <= count {
        let packetEnd = offset + packetSize
        guard bytes[offset] == 0x47 else { offset += 1; continue }

        let b1 = bytes[offset + 1]
        let b2 = bytes[offset + 2]
        let b3 = bytes[offset + 3]
        let payloadStart = (b1 & 0x40) != 0
        let pid = (Int(b1 & 0x1F) << 8) | Int(b2)
        let adaptation = (b3 & 0x30) >> 4

        var p = offset + 4
        if adaptation == 2 { offset += packetSize; continue }  // adaptation only
        if adaptation == 3 {                                   // adaptation + payload
          let afLen = Int(bytes[p])
          p += 1 + afLen
        }
        guard p < packetEnd else { offset += packetSize; continue }

        if pid == 0 {
          parsePAT(bytes, p: p, packetEnd: packetEnd, payloadStart: payloadStart, pmtPID: &pmtPID)
        } else if let pmt = pmtPID, pid == pmt, audioPID == nil {
          parsePMT(bytes, p: p, packetEnd: packetEnd, payloadStart: payloadStart, audioPID: &audioPID)
        } else if let apid = audioPID, pid == apid {
          var q = p
          if payloadStart, q + 9 <= packetEnd,
            bytes[q] == 0x00, bytes[q + 1] == 0x00, bytes[q + 2] == 0x01
          {
            let pesHeaderDataLength = Int(bytes[q + 8])
            q = q + 9 + pesHeaderDataLength
          }
          if q < packetEnd {
            es.append(UnsafeBufferPointer(start: bytes + q, count: packetEnd - q))
          }
        }

        offset += packetSize
      }
    }

    return es.isEmpty ? nil : es
  }

  private static func parsePAT(
    _ bytes: UnsafePointer<UInt8>, p: Int, packetEnd: Int,
    payloadStart: Bool, pmtPID: inout Int?
  ) {
    var q = p
    if payloadStart { q += 1 + Int(bytes[q]) }  // skip pointer_field
    guard q + 8 <= packetEnd else { return }
    let sectionLength = (Int(bytes[q + 1] & 0x0F) << 8) | Int(bytes[q + 2])
    let sectionStart = q + 3
    let sectionEnd = min(sectionStart + sectionLength - 4, packetEnd)
    var e = sectionStart + 5  // skip transport_stream_id, version, section numbers
    while e + 4 <= sectionEnd {
      let programNumber = (Int(bytes[e]) << 8) | Int(bytes[e + 1])
      let pid = (Int(bytes[e + 2] & 0x1F) << 8) | Int(bytes[e + 3])
      if programNumber != 0 { pmtPID = pid }
      e += 4
    }
  }

  private static func parsePMT(
    _ bytes: UnsafePointer<UInt8>, p: Int, packetEnd: Int,
    payloadStart: Bool, audioPID: inout Int?
  ) {
    var q = p
    if payloadStart { q += 1 + Int(bytes[q]) }  // skip pointer_field
    guard q + 12 <= packetEnd else { return }
    let sectionLength = (Int(bytes[q + 1] & 0x0F) << 8) | Int(bytes[q + 2])
    let sectionStart = q + 3
    let sectionEnd = min(sectionStart + sectionLength - 4, packetEnd)
    guard sectionStart + 9 <= packetEnd else { return }
    let programInfoLength = (Int(bytes[sectionStart + 7] & 0x0F) << 8) | Int(bytes[sectionStart + 8])
    var e = sectionStart + 9 + programInfoLength
    while e + 5 <= sectionEnd {
      let streamType = bytes[e]
      let pid = (Int(bytes[e + 1] & 0x1F) << 8) | Int(bytes[e + 2])
      let esInfoLength = (Int(bytes[e + 3] & 0x0F) << 8) | Int(bytes[e + 4])
      // 0x0F = ADTS AAC, 0x11 = LATM AAC, 0x03/0x04 = MPEG audio.
      if streamType == 0x0F || streamType == 0x03 || streamType == 0x04 {
        audioPID = pid
        return
      }
      e += 5 + esInfoLength
    }
  }
}
