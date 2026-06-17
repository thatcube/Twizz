import AVFoundation
import Foundation

/// Experimental low-latency shim for Twitch HLS playback.
///
/// AVPlayer's HLS parser only understands RFC 8216 (+ Apple LL-HLS) tags, so it
/// silently ignores Twitch's proprietary `#EXT-X-TWITCH-PREFETCH:` lines — the
/// very segments that make Twitch "low latency" mode low latency. As a result a
/// plain AVPlayer client sits ~1-2 segments behind the true live edge no matter
/// how aggressively buffering is tuned.
///
/// This proxy fixes that the same way the open-source Streamlink plugin does:
/// it rewrites the media playlist on the fly, promoting each advertised
/// `#EXT-X-TWITCH-PREFETCH` URL into a normal `#EXTINF` segment so AVPlayer will
/// actually fetch it. Twitch only advertises prefetch URLs that are ready (or
/// near-ready) on its CDN, and each prefetch URL becomes the regular segment URL
/// on the next playlist refresh, so segment/media-sequence identity stays stable
/// across reloads (which is what keeps AVPlayer from stalling).
///
/// Implementation notes:
/// - Uses an `AVAssetResourceLoaderDelegate` with a custom URL scheme rather than
///   a localhost socket server. On tvOS this avoids App Transport Security
///   exceptions and the local-network privacy prompt entirely, and keeps
///   everything in-process.
/// - Only playlist requests (master + media) flow through the delegate. Media
///   segments keep their absolute `https` URLs, so AVPlayer fetches them
///   directly using the asset's `AVURLAssetHTTPHeaderFieldsKey` identity.
/// - This is intentionally ad-respecting: prefetch ad segments are promoted just
///   like any other segment. We do not strip or skip ad content.
final class LowLatencyHLSProxy: NSObject, AVAssetResourceLoaderDelegate {
    /// Custom scheme AVPlayer cannot handle natively, which forces every playlist
    /// request onto this delegate.
    static let scheme = "twizz-ll"

    /// `@AppStorage`/`UserDefaults` key for the experimental toggle.
    static let settingsKey = "lowLatencyProxyEnabled"

    private static let prefetchTag = "#EXT-X-TWITCH-PREFETCH:"
    private static let streamInfTag = "#EXT-X-STREAM-INF"
    private static let extinfTag = "#EXTINF:"
    private static let targetDurationTag = "#EXT-X-TARGETDURATION:"

    /// UTI for an HLS playlist on Apple platforms (both `.m3u8` and the Apple
    /// mpegurl MIME type resolve to this). Required on the content-information
    /// request or AVPlayer rejects the synthesized response.
    private static let playlistContentType = "public.m3u-playlist"

    private let upstreamHeaders: [String: String]
    private let delegateQueue = DispatchQueue(label: "com.twizz.lowlatencyhls.proxy")

    /// No-cache session: live media playlists must never be served stale.
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]

    init(headers: [String: String]) {
        self.upstreamHeaders = headers
        super.init()
    }

    /// Serial queue AVFoundation should deliver resource-loader callbacks on.
    var callbackQueue: DispatchQueue { delegateQueue }

    /// Rewrites an `https` master-playlist URL onto the custom scheme so AVPlayer
    /// routes it (and, after rewriting, its child media playlists) through this
    /// delegate. Returns the original URL unchanged if the scheme swap fails.
    func proxyURL(for masterURL: URL) -> URL {
        guard var comps = URLComponents(url: masterURL, resolvingAgainstBaseURL: false) else {
            return masterURL
        }
        comps.scheme = Self.scheme
        return comps.url ?? masterURL
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let requestURL = loadingRequest.request.url,
              requestURL.scheme == Self.scheme,
              let realURL = httpsURL(from: requestURL) else {
            return false
        }

        var req = URLRequest(url: realURL)
        for (key, value) in upstreamHeaders { req.setValue(value, forHTTPHeaderField: key) }

        let key = ObjectIdentifier(loadingRequest)
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }
            self.delegateQueue.async {
                self.tasks[key] = nil
                if loadingRequest.isFinished || loadingRequest.isCancelled { return }

                guard let data, error == nil else {
                    loadingRequest.finishLoading(with: error)
                    return
                }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200...299).contains(status) else {
                    loadingRequest.finishLoading(with: PlaybackError.http(status))
                    return
                }

                let text = String(decoding: data, as: UTF8.self)
                let rewritten = self.rewrite(playlist: text)
                self.fulfill(loadingRequest, with: rewritten)
            }
        }
        delegateQueue.async { [weak self] in
            self?.tasks[key] = task
        }
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        delegateQueue.async { [weak self] in
            self?.tasks[key]?.cancel()
            self?.tasks[key] = nil
        }
    }

    // MARK: - Playlist rewriting

    /// Dispatches to the master- or media-playlist rewriter based on content.
    private func rewrite(playlist text: String) -> Data {
        if text.contains(Self.streamInfTag) {
            return rewriteMasterPlaylist(text)
        }
        return rewriteMediaPlaylist(text)
    }

    /// Reroutes variant + alternate-media (`URI="..."`) playlist URLs onto the
    /// custom scheme so child media playlists are also proxied. Segment lines do
    /// not appear in a master playlist, so nothing else changes.
    private func rewriteMasterPlaylist(_ text: String) -> Data {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count)

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                out.append(raw)
            } else if trimmed.hasPrefix("#") {
                out.append(rewriteURIAttribute(in: raw))
            } else {
                out.append(disguiseScheme(of: trimmed))
            }
        }
        return Data(out.joined(separator: "\n").utf8)
    }

    /// Promotes each `#EXT-X-TWITCH-PREFETCH:<url>` line into a real
    /// `#EXTINF:<dur>,` + `<url>` segment so AVPlayer fetches it. Prefetch
    /// segment duration is taken from the most recent regular `#EXTINF` (falling
    /// back to `#EXT-X-TARGETDURATION`, then 2s) — matching Streamlink's heuristic
    /// closely enough for stable playback.
    private func rewriteMediaPlaylist(_ text: String) -> Data {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        out.reserveCapacity(lines.count + 8)

        var lastDuration = fallbackSegmentDuration(in: lines)

        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(Self.extinfTag) {
                if let dur = duration(fromExtinf: trimmed) { lastDuration = dur }
                out.append(raw)
            } else if trimmed.hasPrefix(Self.prefetchTag) {
                let urlString = String(trimmed.dropFirst(Self.prefetchTag.count))
                    .trimmingCharacters(in: .whitespaces)
                guard !urlString.isEmpty else { continue }
                out.append("\(Self.extinfTag)\(lastDuration),")
                out.append(urlString)
            } else {
                out.append(raw)
            }
        }
        return Data(out.joined(separator: "\n").utf8)
    }

    // MARK: - Helpers

    private func fulfill(_ loadingRequest: AVAssetResourceLoadingRequest, with data: Data) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.playlistContentType
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return
        }

        let offset = Int(dataRequest.requestedOffset)
        guard offset <= data.count else {
            loadingRequest.finishLoading(with: PlaybackError.badResponse)
            return
        }

        let end: Int
        if dataRequest.requestsAllDataToEndOfResource {
            end = data.count
        } else {
            end = min(data.count, offset + dataRequest.requestedLength)
        }
        dataRequest.respond(with: data.subdata(in: offset..<end))
        loadingRequest.finishLoading()
    }

    private func httpsURL(from url: URL) -> URL? {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = "https"
        return comps.url
    }

    private func disguiseScheme(of urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || scheme == "http" else { return urlString }
        return proxyURL(for: url).absoluteString
    }

    /// Rewrites the `URI="..."` value of an HLS tag (e.g. `#EXT-X-MEDIA`) onto the
    /// custom scheme, leaving the rest of the line untouched.
    private func rewriteURIAttribute(in line: String) -> String {
        let marker = "URI=\""
        guard let start = line.range(of: marker) else { return line }
        let afterQuote = start.upperBound
        guard let closing = line[afterQuote...].firstIndex(of: "\"") else { return line }
        let value = String(line[afterQuote..<closing])
        let replacement = disguiseScheme(of: value)
        return line.replacingCharacters(in: afterQuote..<closing, with: replacement)
    }

    private func duration(fromExtinf line: String) -> String? {
        let rest = line.dropFirst(Self.extinfTag.count)
        let durPart = rest.prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
        return durPart.isEmpty ? nil : durPart
    }

    private func fallbackSegmentDuration(in lines: [String]) -> String {
        for raw in lines {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(Self.targetDurationTag) {
                let value = trimmed.dropFirst(Self.targetDurationTag.count)
                    .trimmingCharacters(in: .whitespaces)
                if let seconds = Double(value) {
                    return String(format: "%.3f", seconds)
                }
            }
        }
        return "2.000"
    }
}
