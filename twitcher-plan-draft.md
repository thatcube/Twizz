# Twitcher tvOS App — Draft Build Plan

A native tvOS app for Apple TV that streams Twitch with full chat support and third-party emotes (7TV, BTTV, FFZ). Built in Swift/SwiftUI using VS Code with GitHub Copilot.

---

## Dev Environment Setup

VS Code is a viable primary editor for Swift/tvOS development using two extensions[cite:44][cite:46]:

- **Swift** (official Swift Language extension) — syntax highlighting, autocomplete via SourceKit-LSP
- **SweetPad** — builds, runs, and debugs Xcode projects from inside VS Code; supports tvOS simulators and device deployment

### Required tools (install via Homebrew)

```bash
brew install xcode-build-server
brew install xcbeautify
```

**Important:** Xcode must still be installed — it provides the SDKs, simulators, and the build toolchain. VS Code + SweetPad is the editor frontend; Xcode is the backend[cite:44]. You do not need to work inside Xcode day-to-day. Create the initial project in Xcode once, then do all editing in VS Code with Copilot.

GitHub Copilot works well for Swift in VS Code — you get autocomplete, inline suggestions, and the Copilot Chat panel to ask questions about your codebase[cite:44]. It handles Swift idioms and SwiftUI patterns reliably.

---

## Project Structure

```
Twitcher/
├── Twitcher.xcodeproj
└── Twitcher/
    ├── App/
    │   └── TwitchTVApp.swift        # App entry point
    ├── Auth/
    │   └── AuthManager.swift        # Twitch OAuth device flow
    ├── Models/
    │   ├── Stream.swift
    │   ├── ChatMessage.swift
    │   └── Emote.swift
    ├── Services/
    │   ├── TwitchAPIService.swift    # Helix API calls
    │   ├── ChatService.swift         # IRC WebSocket
    │   └── EmoteService.swift        # 7TV, BTTV, FFZ fetching
    └── Views/
        ├── HomeView.swift            # Followed streams grid
        ├── PlayerView.swift          # Stream + chat overlay
        └── ChatView.swift            # Chat message list
```

---

## Phase 1 — Auth (Twitch Login)

Use the **Device Code Grant Flow** — the standard OAuth pattern for TV apps where typing is painful[cite:22].

**Flow:**
1. POST to `https://id.twitch.tv/oauth2/device` with your `client_id` and desired `scopes`
2. Display the returned `verification_uri` and `user_code` on screen (e.g. "Go to twitch.tv/activate and enter: ABC-DEF")
3. Poll `https://id.twitch.tv/oauth2/token` every few seconds until the user completes login on their phone/browser
4. Store the returned `access_token` securely in **Keychain** (persistent across app launches)

**Required scopes:**
- `user:read:follows` — fetch followed streams
- `chat:read` + `chat:edit` — read and send chat messages

**Copilot prompt to get started:**
> "Write a Swift async/await function that implements the Twitch Device Code Grant OAuth flow. It should POST to the device endpoint, display the user code, then poll for the token every 5 seconds with exponential backoff."

---

## Phase 2 — Followed Streams (Home Screen)

Call the Twitch Helix API to fetch live streams from channels the user follows[cite:22]:

```
GET https://api.twitch.tv/helix/streams/followed
Headers: Authorization: Bearer {token}, Client-Id: {client_id}
```

Display results as a **focusable grid** using SwiftUI's `LazyVGrid`. Each card shows:
- Stream thumbnail (`thumbnail_url` — replace `{width}x{height}` with `320x180`)
- Streamer name, game, viewer count

**tvOS focus note:** Wrap cards in `Button` or use `.focusable()` — the Siri Remote navigates via the focus engine, not touch. Cards must be explicitly focusable or they won't respond to the remote[cite:41].

---

## Phase 3 — Video Playback

Twitch streams are HLS. Getting the M3U8 URL requires exchanging your access token for a stream-specific token via the API, then constructing the HLS URL.

Use `AVPlayer` wrapped in a SwiftUI `VideoPlayer` view for playback. This is native, performant, and well-supported on tvOS.

**Heads up:** Twitch periodically changes how stream URLs are constructed. Check the Frosty or Streamlink source code on GitHub for the current working method — AI-generated code here is sometimes outdated.

---

## Phase 4 — Chat (IRC over WebSocket)

Twitch chat is IRC over WebSocket[cite:51][cite:45]:

```
wss://irc-ws.chat.twitch.tv:443
```

**Connection flow:**
1. Send `PASS oauth:{token}`
2. Send `NICK {username}`
3. Request tags capability: `CAP REQ :twitch.tv/tags` (gives you emote positions in messages)
4. Join channel: `JOIN #{channel_name}`
5. Listen for `PRIVMSG` events — parse username, message text, and emote metadata from tags

Use Swift's `URLSessionWebSocketTask` for the WebSocket connection. Keep a rolling array of the last ~50 messages in a `@Published` array and render them in a `ScrollView` that auto-scrolls to the bottom.

**Copilot prompt:**
> "Write a Swift class using URLSessionWebSocketTask that connects to Twitch IRC over WebSocket, authenticates with an OAuth token, joins a channel, and publishes incoming PRIVMSG events as parsed ChatMessage objects using Combine or async/await."

---

## Phase 5 — Third-Party Emotes (7TV, BTTV, FFZ)

All three services have public APIs that require no authentication for emote fetching.

### 7TV

```
# Global emotes
GET https://7tv.io/v3/emote-sets/global

# Channel emotes (by Twitch user ID)
GET https://7tv.io/v3/users/twitch/{twitch_user_id}
```

Emote image CDN: `https://cdn.7tv.app/emote/{emote_id}/2x.webp`

### BetterTTV (BTTV)

```
# Global
GET https://api.betterttv.net/3/cached/emotes/global

# Channel (by Twitch user ID)
GET https://api.betterttv.net/3/cached/users/twitch/{twitch_user_id}
```

### FrankerFaceZ (FFZ)

```
# Channel
GET https://api.frankerfacez.com/v1/room/id/{twitch_user_id}
```

### Emote Rendering

When a chat message arrives, split the text by spaces and check each word against your emote dictionary (built from the API responses above). Replace matches with `AsyncImage` views loading from the CDN URLs.

Build a unified `EmoteCache` that:
1. Fetches global + channel emotes when joining a stream
2. Stores emotes in a `[String: URL]` dictionary keyed by emote code
3. Invalidates and refetches when switching channels

---

## Phase 6 — Player + Chat Layout

The final view combines `AVPlayer` fullscreen with a semi-transparent chat overlay on the right side.

```swift
ZStack {
    VideoPlayer(player: avPlayer)
        .ignoresSafeArea()
    HStack {
        Spacer()
        ChatView(messages: chatService.messages)
            .frame(width: 400)
            .background(.ultraThinMaterial)
    }
}
```

Use `.ultraThinMaterial` for the chat background — it looks native on tvOS and adapts to the video content behind it. Keep chat non-focusable during playback so the remote controls the video by default. Add a toggle (Menu button on Siri Remote) to switch focus to chat for typing.

---

## Key APIs & Resources

| Resource | URL |
|---|---|
| Twitch Helix API docs | https://dev.twitch.tv/docs/api/ |
| Twitch IRC docs | https://dev.twitch.tv/docs/chat/irc/ |
| Twitch OAuth Device Flow | https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#device-code-grant-flow |
| 7TV API | https://7tv.io/v3 |
| BTTV API | https://api.betterttv.net/3 |
| FFZ API | https://api.frankerfacez.com/v1 |
| Frosty (open source reference) | https://github.com/tommyxchow/frosty |
| Apple tvOS SwiftUI sample | https://developer.apple.com/documentation/SampleCode |
| SweetPad VS Code extension | https://sweetpad.hyzyla.dev |

---

## Rough Timeline (Solo, Vibe Coding)

| Phase | Estimated Time |
|---|---|
| Dev environment setup | 1–2 hours |
| Auth (Device Flow) | 2–4 hours |
| Home screen / stream grid | 3–5 hours |
| Video playback | 3–6 hours (stream URL extraction is the wildcard) |
| Chat WebSocket | 4–6 hours |
| Emote rendering | 4–8 hours |
| Polish / layout | 3–5 hours |
| **Total** | **~20–36 hours** |

---

## Tips

- **Start with Auth + Home screen** before touching video or chat — getting login and the stream list working first gives you a testable foundation early.
- **Run on a real Apple TV early** — the tvOS simulator has focus engine quirks that don't match real hardware. Plug your Apple TV into the same network and use Xcode's wireless device pairing.
- **Reference Frosty's source** for emote parsing logic — it's the most complete open-source implementation of 7TV/BTTV/FFZ parsing available[cite:28].
- **Stream URL extraction:** if Copilot generates outdated code for this step, check the current working method in Streamlink's Twitch plugin (`streamlink/src/streamlink/plugins/twitch.py`) — it's actively maintained.
