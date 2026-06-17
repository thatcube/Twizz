# Twizz — Apple TV Twitch Client (Build Plan v2)

A free, open-source tvOS app for Apple TV that watches Twitch streams and reads chat, with **native third-party emote support** (7TV, BTTV, FFZ) — the thing the official app does badly. Built in Swift/SwiftUI, developed in VS Code with GitHub Copilot + SweetPad.

**Primary goals:** watch streams + read chat (with real emotes), fast and clean.
**Secondary (later):** sending chat messages.
**Distribution:** sideload to your own Apple TV first → TestFlight when shareable → App Store only if/when it's polished.
**Funding:** donations (GitHub Sponsors / Ko-fi). Aim for **zero self-hosted infrastructure**.

---

## ⚠️ Read this first: the viability risk

The entire project lives or dies on **one question: can we reliably play a Twitch stream in a native player on Apple TV?** Everything else (browsing, chat, emotes) is the easy, low-risk part. So we test that first, before building anything else.

Why it's risky:

- **No official native playback.** Twitch provides no SDK to play live streams in a native tvOS app. The working method (used by Streamlink, Frosty, etc.) pulls the HLS (`.m3u8`) URL from Twitch's *undocumented* GraphQL endpoint. This **violates Twitch's Terms of Service** and **can break without warning** when Twitch changes things.
- **No web fallback on tvOS.** Unlike iOS, **tvOS has no WebKit/`WKWebView`**, so we can't embed Twitch's official web player as a safety net. The unofficial HLS route is effectively the *only* option.
- **App Store exposure.** Apple's review Guideline 5.0 requires compliance with third-party terms. This is the main reason we **defer the App Store** and sideload/TestFlight first.

This is a known, widely-used pattern in open-source Twitch clients — but you're going in with eyes open. The Phase 0 proof-of-concept below is the **go/no-go gate** for the whole project.

---

## Distribution & cost reality

| Stage | Cost | Who can install | Build lifetime |
|---|---|---|---|
| Dev on your own Apple TV | **Free** (just an Apple ID) | You | 7 days, then re-deploy |
| TestFlight | **$99/yr** Apple Developer | Up to 10,000 invited testers | 90 days per build |
| App Store | $99/yr + review | Anyone | Until you pull it |

- **"Free app"** means free to *users*. Your only cost is the **$99/yr** Apple fee, and only once you want TestFlight/App Store. Donations can cover it.
- **No-hosting goal:** achievable for browsing, chat, and emotes (all client-side calls to public APIs). The *one* thing that could force a small server is if Twitch starts requiring an "integrity token" for playback that's hard to generate on-device. We'll find out in Phase 0. If it happens, we decide then.

---

## Dev environment setup (1–2 hrs)

VS Code is the editor; Xcode is the backend (SDKs, simulators, signing, device pairing). You create the project in Xcode **once**, then live in VS Code + Copilot.

Two VS Code extensions:
- **Swift** (official) — autocomplete/diagnostics via SourceKit-LSP
- **SweetPad** — build/run/debug Xcode projects from VS Code, including tvOS simulators and devices

Homebrew tools:

```bash
brew install xcode-build-server   # lets SourceKit-LSP understand the Xcode project
brew install xcbeautify           # pretty build output
```

One-time setup in Xcode:
1. Create a new **tvOS App** project named `Twizz` (SwiftUI, Swift).
2. In **Signing & Capabilities**, sign in with your Apple ID and pick "Personal Team" (free).
3. **Pair your Apple TV:** on the Apple TV go to *Settings → Remote and Devices → Remote App and Devices*; in Xcode open *Window → Devices and Simulators* and pair. Both must be on the same network.
4. Do a test "Hello World" deploy to the Apple TV to confirm signing + pairing work.

After that, daily work happens in VS Code/SweetPad. Come back to Xcode only for signing or device issues.

> Optional, not now: tools like XcodeGen/Tuist generate the `.xcodeproj` from a config file, which avoids git merge conflicts on the project file. Only worth it if you get contributors. Start with a plain `.xcodeproj`.

---

## Phase 0 — Playback proof-of-concept ⭐ PARAMOUNT (do this first)

**Goal:** get one known-live Twitch channel playing video+audio in `AVPlayer` on Apple TV. Nothing else matters until this works.

**Approach (the unofficial method):**
1. POST to Twitch's GraphQL endpoint `https://gql.twitch.tv/gql` requesting a `PlaybackAccessToken` for the channel, using the public web Client-ID that Streamlink uses. This returns a signed `token` + `signature`.
2. Build the Usher HLS URL:
   `https://usher.ttvnw.net/api/channel/hls/{channel}.m3u8?sig={signature}&token={token}&allow_source=true&...`
3. That returns a master playlist with quality variants. Hand it to `AVPlayer` via SwiftUI `VideoPlayer` (or `AVPlayerViewController`).

**Source of truth — do not trust AI-generated code here:** the exact request shape (headers, persisted-query hash, whether a `Device-ID` is needed) changes. Copy the *current* method from Streamlink's actively-maintained Twitch plugin:
`streamlink/src/streamlink/plugins/twitch.py` on GitHub. Frosty (`tommyxchow/frosty`) is a second reference.

**Steps:**
1. Start in the **tvOS Simulator** for speed; a hardcoded channel name is fine.
2. Get the master `.m3u8` URL printing correctly first (test it in `ffplay`/VLC on your Mac before touching Swift).
3. Wire it into `AVPlayer` and get pixels on screen.
4. Confirm on the **real Apple TV** (simulator playback can differ).
5. Verify quality variant selection works and playback is stable for a few minutes.

**Go / No-Go decision:**
- ✅ **Works & stable** → continue to Phase 1.
- ⚠️ **Works but needs an integrity token / proxy** → decide whether a tiny serverless proxy is acceptable (breaks the strict no-hosting goal) before continuing.
- ❌ **Can't make it work reliably** → stop and re-scope (e.g., a browse + chat + emotes companion app) before investing more time.

> Note: we'll reference Streamlink's public method rather than build sophisticated anti-bot evasion. If Twitch hardens this aggressively, that's a signal to re-scope, not to escalate.

---

## Phase 1 — Auth (minimal) (1–3 hrs)

Because **reading is primary and sending is secondary**, we keep auth as small as possible.

- Use the **Device Code Grant Flow** (the right pattern for TVs — no typing, no client secret needed).
- **Only scope needed now:** `user:read:follows` (to fetch *your* followed/live channels).
- We **drop `chat:read`/`chat:edit`** for now — chat can be read anonymously (see Phase 3).
- Store the `access_token` in the **Keychain** (survives app restarts). Never embed a client secret.

**Flow:** POST `https://id.twitch.tv/oauth2/device` → show `verification_uri` + `user_code` on screen ("Go to twitch.tv/activate and enter ABC-DEF") → poll `https://id.twitch.tv/oauth2/token` every ~5s until login completes → save token.

> If you'd rather skip login entirely at first, you *can* browse Twitch's public top streams using an app token, but that needs a client secret (bad in a client app). Device flow is the clean path — keep it.

---

## Phase 2 — Home screen: followed live streams (3–5 hrs)

Fully ToS-compliant, low risk. This is your safe foundation.

```
GET https://api.twitch.tv/helix/streams/followed?user_id={id}
Headers: Authorization: Bearer {token}, Client-Id: {client_id}
```

Render as a focusable `LazyVGrid`. Each card: thumbnail (`thumbnail_url` with `{width}x{height}` → `320x180`), streamer name, game, viewer count.

**tvOS focus:** wrap each card in a `Button` (or `.focusable()`). The Siri Remote drives the **focus engine**, not a cursor — non-focusable views simply won't respond.

---

## Phase 3 — Chat (read-only) (3–5 hrs)

Twitch chat is IRC over WebSocket: `wss://irc-ws.chat.twitch.tv:443`. Use `URLSessionWebSocketTask`.

**Simplification:** to *read* chat you can connect **anonymously** — no login, no token:
1. `NICK justinfan12345` (any `justinfan` + random number; no `PASS` needed)
2. `CAP REQ :twitch.tv/tags` (gives emote metadata + user colors/badges)
3. `JOIN #{channel}`
4. Parse `PRIVMSG` lines → username, text, tags.

Keep a rolling `@Published` array of the last ~100 messages; render in a `ScrollView` that auto-scrolls to the bottom.

> Sending messages (secondary) is added later: it needs login + `chat:edit` scope and sending `PASS oauth:{token}` / `PRIVMSG`. Deferred on purpose.

---

## Phase 4 — Native third-party emotes (4–8 hrs) ⭐ your differentiator

All three APIs are public, no auth needed.

```
7TV global:    GET https://7tv.io/v3/emote-sets/global
7TV channel:   GET https://7tv.io/v3/users/twitch/{twitch_user_id}
BTTV global:   GET https://api.betterttv.net/3/cached/emotes/global
BTTV channel:  GET https://api.betterttv.net/3/cached/users/twitch/{twitch_user_id}
FFZ channel:   GET https://api.frankerfacez.com/v1/room/id/{twitch_user_id}
```

Build a unified `EmoteCache`:
1. On joining a channel, fetch global + channel emotes from all three.
2. Store a `[String: Emote]` dictionary keyed by emote code (these services match by **name**, not text position).
3. When a message arrives, split on spaces and swap any word that matches an emote for its image.
4. Invalidate + refetch when switching channels.

**⚠️ Animation gotcha (this is the real work):** 7TV emotes are frequently **animated WebP**. SwiftUI's `AsyncImage` shows only a **frozen frame** — it won't animate. To deliver the feature you actually care about, render emotes through a library that decodes animated WebP frames (e.g. **Nuke**, or a small custom decoder). Plan time for this; it's the difference between "looks like everyone else" and "looks right."

CDN: `https://cdn.7tv.app/emote/{emote_id}/2x.webp` (and BTTV/FFZ equivalents). Reference **Frosty's** source for battle-tested parsing logic.

---

## Phase 5 — Player + chat layout (3–5 hrs)

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

- `.ultraThinMaterial` for the chat panel — looks native, adapts to the video behind it.
- Keep chat **non-focusable during playback** so the remote controls video by default.
- Map the **Menu** button to toggle focus to chat / hide the overlay.

---

## Phase 6 — Polish (ongoing)

Loading states, error handling (especially "stream URL extraction failed" — it *will* happen), reconnect logic for chat, quality selector, remember last channel, empty/offline states.

---

## Project structure

```
Twizz/
├── Twizz.xcodeproj
└── Twizz/
    ├── App/        TwizzApp.swift
    ├── Auth/       AuthManager.swift            # device flow + Keychain
    ├── Models/     Stream.swift, ChatMessage.swift, Emote.swift
    ├── Services/
    │   ├── PlaybackService.swift                # ⭐ Phase 0: HLS URL extraction
    │   ├── TwitchAPIService.swift               # Helix
    │   ├── ChatService.swift                    # anonymous IRC WebSocket
    │   └── EmoteService.swift                   # 7TV / BTTV / FFZ + EmoteCache
    └── Views/      HomeView.swift, PlayerView.swift, ChatView.swift
```

---

## Funding (no hosting)

- **GitHub Sponsors** and/or **Ko-fi / Open Collective** — links live in the README and repo, **not** as an in-app purchase (keeps App Store rules simple).
- Public, MIT-licensed repo. Donations are optional and external.

---

## Revised timeline (first-time builder, with buffer)

| Phase | Estimate |
|---|---|
| Dev environment setup | 1–2 hrs |
| **Phase 0 — Playback POC (go/no-go)** | **3–8 hrs (the wildcard)** |
| Auth (device flow, minimal) | 1–3 hrs |
| Home screen / followed grid | 3–5 hrs |
| Chat (read-only, anonymous) | 3–5 hrs |
| Native emotes (incl. animation) | 4–8 hrs |
| Player + chat layout | 3–5 hrs |
| Polish | ongoing |

First app + the playback unknown means treat these as loose; Phase 0 dominates the risk.

---

## Key resources

| Resource | URL |
|---|---|
| Twitch Helix API | https://dev.twitch.tv/docs/api/ |
| Twitch IRC (chat) | https://dev.twitch.tv/docs/chat/irc/ |
| Twitch OAuth Device Flow | https://dev.twitch.tv/docs/authentication/getting-tokens-oauth/#device-code-grant-flow |
| Streamlink Twitch plugin (playback truth) | https://github.com/streamlink/streamlink/blob/master/src/streamlink/plugins/twitch.py |
| Frosty (open-source reference client) | https://github.com/tommyxchow/frosty |
| 7TV API | https://7tv.io/v3 |
| BTTV API | https://api.betterttv.net/3 |
| FFZ API | https://api.frankerfacez.com/v1 |
| SweetPad | https://sweetpad.hyzyla.dev |
| Nuke (image/animation loading) | https://github.com/kean/Nuke |

---

## Suggested build order (de-risked)

1. **Dev env + Hello World on real Apple TV** (proves your toolchain).
2. **Phase 0 playback POC** (proves the project is possible). ← stop and reassess here.
3. Auth → Home (real, useful screen).
4. Chat read → Emotes (the differentiator).
5. Combine into Player+Chat → Polish → TestFlight.
