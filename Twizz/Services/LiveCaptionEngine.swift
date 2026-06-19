import AVFoundation
import Foundation
import OSLog
import Speech

/// A single recognized caption update. `isVolatile` marks an in-progress guess
/// that a later, more accurate result for the same time range will replace.
/// Declared outside the (tvOS 26-gated) engine so non-gated callers — the
/// `CaptionController` and the overlay — can pass it around freely.
struct CaptionLine: Sendable {
    let text: String
    let isVolatile: Bool
}

/// On-device live caption generation for Twitch streams ("Captions (beta)").
///
/// Twitch ships no caption tracks in its HLS (live or VOD), so the only way to
/// caption arbitrary streams is to transcribe the audio ourselves, on device.
/// This uses Apple's `SpeechAnalyzer` / `SpeechTranscriber` (tvOS 26+): fully
/// on-device, no network ASR, no quotas, no session limit, and no microphone or
/// speech-recognition permission (we transcribe the stream's own audio).
///
/// Audio feed: `AVPlayer` does not expose decompressed PCM for live HLS (see
/// `AudioOnlyLevelDecoder`), and `MTAudioProcessingTap` does not fire on it.
/// So — exactly like the audio visualizer — we side-channel the audio: poll the
/// audio-only media playlist, download each fresh self-contained MPEG-TS
/// segment, demux its AAC elementary stream (`TSAudioExtractor`), decode it to
/// PCM with `AVAudioFile`, convert to the analyzer's required format, and feed
/// it into the recognizer. Recognized text is surfaced via `onLine`.
///
/// Intentionally isolated from the player's playback path: it only consumes the
/// audio-only playlist URL the player already resolves, and never touches the
/// `AVPlayer` or its item.
@available(tvOS 26.0, *)
actor LiveCaptionEngine {
    private let playlistURL: URL
    private let headers: [String: String]
    private let onLine: @Sendable (CaptionLine) -> Void
    private let log = Logger(subsystem: "com.thatcube.Twizz", category: "LiveCaptionEngine")

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var pollLoop: Task<Void, Never>?
    private var processedSegments: Set<String> = []
    private let fallbackSegmentDuration: Double = 2.0

    init(
        playlistURL: URL,
        headers: [String: String],
        onLine: @escaping @Sendable (CaptionLine) -> Void
    ) {
        self.playlistURL = playlistURL
        self.headers = headers
        self.onLine = onLine
    }

    // MARK: - Lifecycle

    /// Reports whether the device can actually run on-device transcription for a
    /// usable locale (guards against OS/hardware that lack the Speech models —
    /// e.g. the tvOS Simulator).
    static func isSupported() async -> Bool {
        !(await SpeechTranscriber.supportedLocales).isEmpty
    }

    /// Prepares the on-device model (downloading it once if needed), wires up the
    /// analyzer, and starts polling the audio playlist. Throws if the device has
    /// no usable transcriber (e.g. unsupported hardware/locale).
    func start() async throws {
        guard pollLoop == nil else { return }

        let locale = await Self.preferredLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        try await Self.ensureModelInstalled(for: transcriber)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

        // Consume recognized results and forward them out. With the progressive
        // preset, the stream emits volatile guesses followed by finalized text.
        resultsTask = Task { [weak self, onLine, log] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isVolatile = await self.isVolatile(result)
                    if !text.isEmpty {
                        onLine(CaptionLine(text: text, isVolatile: isVolatile))
                    }
                }
            } catch {
                log.error("results stream ended: \(error.localizedDescription, privacy: .public)")
            }
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation
        try await analyzer.start(inputSequence: stream)

        pollLoop = Task { [weak self] in
            await self?.runPollLoop()
        }
    }

    func stop() async {
        pollLoop?.cancel()
        pollLoop = nil
        resultsTask?.cancel()
        resultsTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        analyzer = nil
        transcriber = nil
        processedSegments.removeAll()
    }

    /// A result is "volatile" while playback hasn't been finalized past its end —
    /// i.e. the analyzer may still revise it. Used to style pending vs. settled text.
    private func isVolatile(_ result: SpeechTranscriber.Result) -> Bool {
        result.resultsFinalizationTime < result.range.end
    }

    // MARK: - Model provisioning

    private static func preferredLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let current = Locale.current
        func matches(_ a: Locale, _ b: Locale) -> Bool {
            a.language.languageCode == b.language.languageCode
        }
        if let exact = supported.first(where: { $0.identifier == current.identifier }) {
            return exact
        }
        if let sameLanguage = supported.first(where: { matches($0, current) }) {
            return sameLanguage
        }
        return supported.first(where: { $0.identifier.hasPrefix("en") })
            ?? supported.first
            ?? Locale(identifier: "en-US")
    }

    private static func ensureModelInstalled(for transcriber: SpeechTranscriber) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    // MARK: - Audio polling + feeding

    private func runPollLoop() async {
        while !Task.isCancelled {
            let pace: Double
            do {
                pace = try await pollOnce()
            } catch {
                pace = fallbackSegmentDuration
            }
            try? await Task.sleep(for: .seconds(min(max(pace, 0.5), 4.0)))
        }
    }

    /// Fetches the playlist, feeds every newly-seen segment's audio into the
    /// recognizer in order, and returns how long to wait before the next poll.
    private func pollOnce() async throws -> Double {
        let text = try await fetchText(playlistURL)
        let segments = parseSegments(text, relativeTo: playlistURL)
        guard !segments.isEmpty else { return fallbackSegmentDuration }

        if processedSegments.count > 256 {
            processedSegments.removeAll(keepingCapacity: true)
        }

        let unseen = segments.filter { !processedSegments.contains($0.url.absoluteString) }
        for seg in unseen { processedSegments.insert(seg.url.absoluteString) }

        var lastDuration = segments.last?.duration ?? fallbackSegmentDuration
        // Bound catch-up so the first poll doesn't dump the whole window at once.
        for seg in unseen.suffix(4) {
            if Task.isCancelled { break }
            do {
                let data = try await fetchData(seg.url)
                if let buffer = try await pcmBuffer(from: data) {
                    feed(buffer)
                }
                lastDuration = seg.duration
            } catch {
                continue
            }
        }
        return lastDuration
    }

    /// Demuxes a Twitch audio segment to ADTS AAC, decodes it to PCM, converts it
    /// to the analyzer's required format, and returns it ready to feed.
    private func pcmBuffer(from data: Data) async throws -> AVAudioPCMBuffer? {
        // Twitch audio-only segments are AAC inside MPEG-TS; AVFoundation can read
        // a raw ADTS `.aac` file but not raw MPEG-TS, so demux first.
        let decodable: Data
        if data.first == 0x47, let adts = TSAudioExtractor.extractADTS(from: data) {
            decodable = adts
        } else {
            decodable = data
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("twizz-cap-\(UUID().uuidString).aac")
        try decodable.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forReading: tempURL)
        let inputFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount)
        else { return nil }
        try file.read(into: inputBuffer)

        guard let analyzerFormat else { return inputBuffer }
        return Self.convert(inputBuffer, to: analyzerFormat)
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        inputContinuation?.yield(AnalyzerInput(buffer: buffer))
    }

    /// Sample-rate / format conversion from the decoded segment format to the
    /// format the analyzer requires (the analyzer does not resample internally).
    private static func convert(
        _ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if input.format == outputFormat { return input }
        guard let converter = AVAudioConverter(from: input.format, to: outputFormat) else {
            return nil
        }
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        let statusValue = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        if statusValue == .error || output.frameLength == 0 { return nil }
        return output
    }

    // MARK: - Networking + playlist parsing

    private func fetchText(_ url: URL) async throws -> String {
        String(decoding: try await fetchData(url), as: UTF8.self)
    }

    private func fetchData(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, _) = try await session.data(for: request)
        return data
    }

    private struct Segment {
        let url: URL
        let duration: Double
    }

    private func parseSegments(_ text: String, relativeTo base: URL) -> [Segment] {
        var segments: [Segment] = []
        var pendingDuration = fallbackSegmentDuration
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count)
                let number = value.prefix { $0.isNumber || $0 == "." }
                pendingDuration = Double(number) ?? fallbackSegmentDuration
            } else if !line.isEmpty, !line.hasPrefix("#"),
                      let url = URL(string: line, relativeTo: base)?.absoluteURL {
                segments.append(Segment(url: url, duration: pendingDuration))
                pendingDuration = fallbackSegmentDuration
            }
        }
        return segments
    }
}
