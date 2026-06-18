# Fastlane — App Store / TestFlight automation

Automates building Twizz (tvOS) and shipping to TestFlight and the App Store,
including text metadata. Auth uses an **App Store Connect API key** (no Apple ID
or 2FA), so it runs unattended and in CI.

## One-time setup (manual — Apple-side)

1. **Create the API key**
   App Store Connect → *Users and Access* → *Integrations* → *App Store Connect API* →
   generate a key with **App Manager** access. Download the `AuthKey_XXXXXX.p8`
   (you can only download it once). Note the **Key ID** and **Issuer ID**.

2. **Create the app record** (first time only)
   App Store Connect → *Apps* → **+** → *New App*. Platform: **tvOS**,
   Bundle ID: `com.thatcube.Twizz`, SKU: e.g. `twizz-tvos`, primary language: English.
   Fastlane uploads builds/metadata but does not create the app record itself.

3. **Provide credentials** — copy `.env.fastlane.example` to `.env.fastlane`
   and fill it in (it's git-ignored), or export the vars in your shell / CI:
   - `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH`

4. **Install Fastlane** (bundles its own Ruby; the macOS system Ruby can't
   compile Fastlane's native gems):
   ```bash
   brew install fastlane
   ```

## Commands

```bash
# Load creds if using the env file:
set -a && source .env.fastlane && set +a

fastlane beta       # build + upload to TestFlight
fastlane metadata   # push text metadata only (no binary)
fastlane release    # build + upload to App Store + metadata (no auto-submit)
fastlane build      # archive a signed .ipa locally, no upload
```

## Metadata

Editable text lives in `fastlane/metadata/`. App-name, subtitle, description,
keywords, and URLs are under `en-US/`. Add more locales by creating sibling
folders (e.g. `de-DE/`).

Screenshots are **not** automated here — add 1920×1080 (or 3840×2160) tvOS
screenshots under `fastlane/screenshots/en-US/` if you want `deliver` to upload
them, or upload them manually in App Store Connect.

## Notes

- Build numbers auto-increment from git commit count (see `project.yml`
  post-build script), so no manual bumping is needed.
- `privacy_url.txt` points at `PRIVACY.md` in the repo — make sure that page
  exists before submitting for review, or update the URL.
