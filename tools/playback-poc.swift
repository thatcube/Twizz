#!/usr/bin/env swift  //
//  playback-poc.swift — Phase 0 proof-of-concept
//
//  Verifies that we can obtain a Twitch live HLS master playlist URL using only
//  on-device HTTP calls (no headless browser, no proxy server). This is the
//  riskiest assumption of the whole project; if this works, the app is viable.
//
//  Method mirrors the open-source Streamlink Twitch plugin (basic path only):
//    1. POST a PlaybackAccessToken persisted GraphQL query to gql.twitch.tv
//    2. Build the Usher HLS URL from the returned {value, signature}
//    3. GET the Usher URL and confirm a master playlist with quality variants
//
//  We intentionally do NOT implement ad-segment filtering or client-integrity
//  browser automation. This is a non-commercial, ad-respecting client.
//
//  Usage:  swift tools/playback-poc.swift <channel_login>
//

import Foundation

// Public web player Client-ID used by the Twitch web player / Streamlink.
let clientID = "kimne78kx3ncx6brgo4mv6wki5h1ko"
// Current persisted-query hash for PlaybackAccessToken (from Streamlink master).
let playbackAccessTokenHash = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
let userAgent =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

struct PlaybackToken {
  let value: String  // JSON token string
  let signature: String  // hex signature
}

enum POCError: Error, CustomStringConvertible {
  case http(Int, String)
  case integrityRequired
  case offline
  case badResponse(String)

  var description: String {
    switch self {
    case .http(let code, let body): return "HTTP \(code): \(body.prefix(300))"
    case .integrityRequired:
      return "Twitch requires a client-integrity token for this channel (basic path blocked)."
    case .offline: return "Channel appears offline or does not exist."
    case .badResponse(let s): return "Unexpected response: \(s)"
    }
  }
}

func fetchAccessToken(channel: String) async throws -> PlaybackToken {
  var req = URLRequest(url: URL(string: "https://gql.twitch.tv/gql")!)
  req.httpMethod = "POST"
  req.setValue(clientID, forHTTPHeaderField: "Client-ID")
  req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
  req.setValue("application/json", forHTTPHeaderField: "Content-Type")

  let body: [String: Any] = [
    "operationName": "PlaybackAccessToken",
    "extensions": [
      "persistedQuery": [
        "version": 1,
        "sha256Hash": playbackAccessTokenHash,
      ]
    ],
    "variables": [
      "isLive": true,
      "login": channel,
      "isVod": false,
      "vodID": "",
      "playerType": "embed",
      "platform": "site",
    ],
  ]
  req.httpBody = try JSONSerialization.data(withJSONObject: body)

  let (data, response) = try await URLSession.shared.data(for: req)
  let status = (response as? HTTPURLResponse)?.statusCode ?? -1
  let text = String(data: data, encoding: .utf8) ?? ""
  guard (200...299).contains(status) else { throw POCError.http(status, text) }

  guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw POCError.badResponse(text)
  }
  if let errors = json["errors"] as? [[String: Any]] {
    let msg = (errors.first?["message"] as? String) ?? "unknown"
    if msg.lowercased().contains("integrity") { throw POCError.integrityRequired }
    throw POCError.badResponse("GraphQL error: \(msg)")
  }
  guard let dataObj = json["data"] as? [String: Any] else { throw POCError.badResponse(text) }
  guard let tokenObj = dataObj["streamPlaybackAccessToken"] as? [String: Any] else {
    throw POCError.offline
  }
  guard let value = tokenObj["value"] as? String,
    let signature = tokenObj["signature"] as? String
  else {
    throw POCError.badResponse(text)
  }
  return PlaybackToken(value: value, signature: signature)
}

func buildUsherURL(channel: String, token: PlaybackToken) -> URL {
  var comps = URLComponents(
    string: "https://usher.ttvnw.net/api/v2/channel/hls/\(channel.lowercased()).m3u8")!
  comps.queryItems = [
    URLQueryItem(name: "platform", value: "web"),
    URLQueryItem(name: "p", value: String(Int.random(in: 0..<999999))),
    URLQueryItem(name: "allow_source", value: "true"),
    URLQueryItem(name: "allow_audio_only", value: "true"),
    URLQueryItem(name: "playlist_include_framerate", value: "true"),
    URLQueryItem(name: "supported_codecs", value: "h264"),
    URLQueryItem(name: "fast_bread", value: "true"),
    URLQueryItem(name: "sig", value: token.signature),
    URLQueryItem(name: "token", value: token.value),
  ]
  return comps.url!
}

func fetchPlaylist(url: URL) async throws -> String {
  var req = URLRequest(url: url)
  req.setValue("https://player.twitch.tv", forHTTPHeaderField: "Referer")
  req.setValue("https://player.twitch.tv", forHTTPHeaderField: "Origin")
  req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

  let (data, response) = try await URLSession.shared.data(for: req)
  let status = (response as? HTTPURLResponse)?.statusCode ?? -1
  let text = String(data: data, encoding: .utf8) ?? ""
  if status == 404 { throw POCError.offline }
  guard (200...299).contains(status) else { throw POCError.http(status, text) }
  return text
}

func run(channel: String) async {
  print("=== Twizz Phase 0 — playback POC ===")
  print("Channel: \(channel)\n")
  do {
    print("[1/3] Requesting PlaybackAccessToken (no integrity token)...")
    let token = try await fetchAccessToken(channel: channel)
    print(
      "      ✅ Got token (no client-integrity needed). signature=\(token.signature.prefix(12))…\n")

    print("[2/3] Building Usher HLS URL...")
    let usher = buildUsherURL(channel: channel, token: token)
    print("      ✅ \(usher.absoluteString.prefix(120))…\n")

    print("[3/3] Fetching master playlist...")
    let playlist = try await fetchPlaylist(url: usher)
    let variants = playlist.components(separatedBy: "\n").filter {
      $0.hasPrefix("#EXT-X-STREAM-INF")
    }
    let mediaURLs = playlist.components(separatedBy: "\n").filter { $0.hasPrefix("https://") }
    print("      ✅ Master playlist received: \(variants.count) quality variant(s).\n")

    print("Quality variants found:")
    for line in variants {
      if let r = line.range(of: "VIDEO=\"") {
        let rest = line[r.upperBound...]
        let name = rest.prefix(while: { $0 != "\"" })
        print("   • \(name)")
      }
    }
    if let first = mediaURLs.first {
      print("\nExample variant playlist URL:\n   \(first)")
    }
    print("\n🎉 PHASE 0 PASSED — on-device stream URL extraction works. No proxy/server required.")
  } catch let e as POCError {
    print("\n❌ FAILED: \(e)")
    switch e {
    case .integrityRequired:
      print("→ This channel needs an integrity token. Try another live channel; if ALL channels")
      print(
        "  require it, that's the signal to re-scope (integrity needs a browser, infeasible on tvOS)."
      )
    case .offline:
      print("→ Pick a channel that is currently LIVE and try again.")
    default: break
    }
  } catch {
    print("\n❌ Unexpected error: \(error)")
  }
}

let channel = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "twitch"
let sema = DispatchSemaphore(value: 0)
Task {
  await run(channel: channel)
  sema.signal()
}
sema.wait()
