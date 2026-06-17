# Twizz

A free, open-source Apple TV app for watching Twitch with a fast, chat-first viewing experience and native external emote support.

## Current State

Twizz is now usable for the core experience:

- Live playback on real Apple TV hardware.
- Side-by-side layout: video on the left, chat pane on the right.
- Read-only anonymous chat via Twitch IRC over WebSocket (`justinfan` guest).
- Quality picker with persistence (`Auto` + explicit qualities), ordered highest-to-lowest.
- Custom bottom overlay controls with tvOS focus navigation.
- Chat composer UI in the chat pane (input UI only; sending not yet enabled).
- Twitch badges in chat (global + channel-specific).
- Emotes in chat:
	- Twitch native emotes (including channel/subscriber emotes from IRC `emotes` tags).
	- 7TV global + channel.
	- BTTV global + channel/shared.
	- FFZ global + channel.

## What Is Not Done Yet

- Sending chat messages.
- Followed-streams home experience (OAuth/device flow + followed channels UI).
- Animated emote playback polish (currently image-first rendering; first-time fetch may briefly delay).
- Broader player polish and settings UX.

## Tech Stack

- Swift / SwiftUI targeting tvOS.
- AVPlayer-backed playback with custom overlay controls.
- XcodeGen project generation (`project.yml` is source of truth).

## Build & Run

Prerequisites:

- macOS with Xcode installed.
- Homebrew tools:

```bash
brew install xcodegen xcbeautify xcode-build-server
```

Generate the project:

```bash
xcodegen generate
```

Build:

```bash
xcodebuild \
	-project Twizz.xcodeproj \
	-scheme Twizz \
	-configuration Debug \
	-destination 'generic/platform=tvOS Simulator' \
	build | xcbeautify
```

For real Apple TV deployment, use a valid signing team and a device destination.

## Twitch Auth Setup (No Committed Secrets)

Twitch device auth still needs a Twitch app `client_id`, but you do not need to commit it to this repo.

1. Copy [Config/TwitchSecrets.xcconfig.local.example](Config/TwitchSecrets.xcconfig.local.example) to `Config/TwitchSecrets.xcconfig.local`.
2. Set your value:

```xcconfig
TWITCH_CLIENT_ID = your_real_client_id
```

Important:

- Do not use Twitch's public web client ID (for example `kimne78kx3ncx6brgo4mv6wki5h1ko`).
- If you do, the consent page will show "Twilight" and followed-channel APIs may fail.
- Create your own Twitch app in the Twitch Developer Console and use that Client ID.

`Config/TwitchSecrets.xcconfig.local` is gitignored (`*.xcconfig.local`), so your ID stays local.

On Apple TV, sign-in uses Twitch Device Code flow: start sign-in on TV, then complete approval on your phone/browser (including the Twitch mobile app browser flow) using the shown code/link.

## How Playback Works

Apple TV has no official Twitch playback SDK. Twizz resolves playback via Twitch GraphQL PlaybackAccessToken and Usher HLS playlists, similar in spirit to open-source clients like Streamlink and Frosty.

This project is non-commercial and ad-respecting.

## Roadmap

See [Twizz-plan.md](Twizz-plan.md) for detailed phased planning.

## License

[MIT](LICENSE) © 2026 thatcube

Not affiliated with or endorsed by Twitch Interactive, Inc.
