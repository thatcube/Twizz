import AVFoundation
import Foundation
import OSLog
import Speech

/// EXPERIMENTAL SPIKE — on-device live caption generation for Twitch streams.
///
/// Feasibility proof for Accessibility Chunk F: Twitch ships no caption tracks in
/// its HLS (live or VOD), so the only way to caption arbitrary streams is to
/// transcribe the audio ourselves, on device. This spike does exactly that using
/// Apple's WWDC25 `SpeechAnalyzer` / `SpeechTranscriber` (fully on-device, no
/// quotas, no session limit), which is available on tvOS 26+ — verified to
/// compile and run on the test Apple TV 4K (A15, tvOS 27).
///
/// Audio feed: AVPlayer does not expose decompressed PCM for live HLS (see
/// `AudioOnlyLevelDecoder`), so — exactly like the audio visualizer — we run a
/// side-channel: poll the audio-only media playlist, download each fresh
/// self-contained MPEG-TS segment, demux its AAC elementary stream
/// (`TSAudioExtractor`), decode it to PCM with `AVAudioFile`, convert to the
/// analyzer's required format, and feed it into the recognizer. Recognized text
/// is surfaced via `onTranscript` and logged.
///
/// This type is intentionally isolated and self-contained: it touches no player
/// internals and makes no destructive change to `PlayerView`. It is the minimal
/// proof that real-time on-device captioning is achievable on Apple TV.
@available(tvOS 26.0, *)
actor LiveCaptionSpike {
    /// A recognized caption update. `isVolatile` marks an in-progress guess that
    /// will be replaced by a later, more accurate result for the same time range.
    struct Transcript: Sendable {
        let text: String
        let isVolatile: Bool
    }

    private let playlistURL: URL
    private let headers: [String: String]
    private let onTranscript: @Sendable (Transcript) -> Void
    private let log = Logger(subsystem: "com.thatcube.Twizz", category: "LiveCaptionSpike")

    /// Append-only evidence log written to the app container so a headless
    /// (no on-screen navigation) device run can be inspected by pulling the file
    /// with `devicectl device copy`. Spike-only; not used by shipping code.
    static let evidenceLogURL: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("caption_spike.log")
    }()

    static func fileLog(_ message: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = evidenceLogURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

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
        onTranscript: @escaping @Sendable (Transcript) -> Void
    ) {
        self.playlistURL = playlistURL
        self.headers = headers
        self.onTranscript = onTranscript
    }

    // MARK: - Lifecycle

    /// Prepares the on-device model (downloading it once if needed), wires up the
    /// analyzer, and starts polling the audio playlist. Throws if the device has
    /// no usable transcriber (e.g. unsupported hardware/locale).
    func start() async throws {
        guard pollLoop == nil else { return }

        let locale = await Self.preferredLocale()
        log.info("Starting caption spike with locale \(locale.identifier, privacy: .public)")
        print("[caption] starting locale=\(locale.identifier)")
        Self.fileLog("starting locale=\(locale.identifier)")
        let supported = await SpeechTranscriber.supportedLocales
        Self.fileLog("supportedLocales count=\(supported.count): \(supported.map(\.identifier).joined(separator: ","))")
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        self.transcriber = transcriber

        try await Self.ensureModelInstalled(for: transcriber, log: log)
        print("[caption] model ready, wiring analyzer")
        Self.fileLog("model ready, wiring analyzer")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        log.info("Analyzer format: \(String(describing: self.analyzerFormat), privacy: .public)")
        Self.fileLog("bestAvailableAudioFormat=\(String(describing: self.analyzerFormat))")

        // Consume recognized results and forward them out. With the progressive
        // preset, the stream emits volatile guesses followed by finalized text.
        resultsTask = Task { [weak self, onTranscript, log] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isVolatile = await self.isVolatile(result)
                    if !text.isEmpty {
                        log.info("[caption]\(isVolatile ? "~" : " ", privacy: .public) \(text, privacy: .public)")
                        print("[caption]\(isVolatile ? "~" : " ") \(text)")
                        Self.fileLog("caption\(isVolatile ? "~" : " ") \(text)")
                        onTranscript(Transcript(text: text, isVolatile: isVolatile))
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
            print("[caption] listening — polling audio segments")
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
    /// i.e. the analyzer may still revise it. Used only to style/log pending text.
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

    private static func ensureModelInstalled(
        for transcriber: SpeechTranscriber, log: Logger
    ) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        log.info("Model status: \(String(describing: status), privacy: .public)")
        Self.fileLog("model status=\(String(describing: status))")
        if status == .installed { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log.info("Downloading on-device speech model…")
            Self.fileLog("downloading model…")
            try await request.downloadAndInstall()
            log.info("Speech model installed.")
            Self.fileLog("model installed")
        } else {
            Self.fileLog("no installation request available (model may be unsupported here)")
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
