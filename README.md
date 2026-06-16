# Twitcher

A free, open-source **Apple TV** app for watching Twitch — built to be faster and cleaner than the official app, with **native third-party emote support** (7TV, BTTV, FFZ) that Twitch's own app lacks.

> ⚠️ **Early development.** Not yet usable. See [twitcher-plan.md](twitcher-plan.md) for the full build plan and roadmap.

## Goals

- **Watch streams** smoothly on Apple TV (native `AVPlayer`).
- **Read chat** with proper rendering of 7TV / BTTV / FFZ emotes — including animated ones.
- **Fast and clean** — a better experience than the official Twitch tvOS app.
- **Free forever.** No ads, no paywalls. Optional donations only.

Sending chat messages is a planned secondary feature; watching and reading come first.

## Status

| Phase | Description | Status |
|---|---|---|
| 0 | Playback proof-of-concept (the make-or-break gate) | 🚧 Not started |
| 1 | Auth (Twitch device flow, minimal) | ⬜ |
| 2 | Home screen — followed live streams | ⬜ |
| 3 | Chat (read-only, anonymous) | ⬜ |
| 4 | Native third-party emotes | ⬜ |
| 5 | Player + chat layout | ⬜ |

## Tech

- **Swift / SwiftUI**, targeting tvOS.
- Developed in **VS Code** with the Swift + [SweetPad](https://sweetpad.hyzyla.dev) extensions; **Xcode** provides the SDKs/simulators/signing.

## Building

Requires macOS with Xcode installed.

```bash
brew install xcode-build-server xcbeautify
```

Open the project in VS Code with the Swift and SweetPad extensions, or open `Twitcher.xcodeproj` in Xcode. Detailed setup is in [twitcher-plan.md](twitcher-plan.md).

## A note on how this works

Apple TV has no official Twitch playback SDK, so Twitcher fetches stream playlists the same way open-source clients like [Streamlink](https://github.com/streamlink/streamlink) and [Frosty](https://github.com/tommyxchow/frosty) do. This is a non-commercial, ad-respecting hobby project in the same spirit as those tools.

## Funding

Twitcher is free and donation-supported. If it's useful to you, donations help cover the Apple Developer fee and development time. (Links coming once the project is usable.)

## License

[MIT](LICENSE) © 2026 thatcube

*Not affiliated with or endorsed by Twitch Interactive, Inc.*
