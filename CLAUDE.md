# CLAUDE.md – NxtSound for iOS

Guidance for AI coding tools (and a good summary for human contributors). Personal preferences belong in `CLAUDE.local.md` (not committed).

## Project
Native iOS app for the NxtSound server (`../nxtsound-server`), modelled on the Home Assistant companion app: it asks for the server address on first start, links to it, then shows the server's web UI in a web view with a native player. Do not scatter the display name: it lives in `AppConfig.appName` (and `ios/project.yml`). Roadmap and decisions: `PLAN.md`.

## Conventions
- Code, comments, docs and commit messages are **English**. App texts are English and German: `ios/App/en.lproj` and `ios/App/de.lproj` (`Localizable.strings`, keys are the English source strings).
- Build: `cd ios && xcodegen generate && xcodebuild -project NxtSound.xcodeproj -scheme NxtSound -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`. The app must build before every commit. Personal signing settings go into `ios/Local.xcconfig` (not committed).
- No secrets in the repo; never log user data or credentials.

## Rules
1. **No third-party streaming service in this repo or the app** (code, tests, docs, UI texts, store texts, screenshots). Plugins live in their own repos.
2. The app links **only** to servers whose `GET /api/server-info` identifies as `"server": "nxtsound"` with a supported `api_version`; otherwise it would be a browser for arbitrary pages. The web view stays limited to the origin of the linked server; foreign links open in Safari.
3. Background audio and lock-screen control can only be checked on a real iPhone, not in the simulator.

## Lessons from the web player on iOS
- A PWA has no background execution: once playback pauses iOS freezes the page and ends it after minutes; lock-screen play then goes nowhere. This is the main reason for the native player (`NativeAudio.swift`, AVPlayer).
- A gap between two tracks lets iOS freeze the page; the web player preloads the next track as a blob (~20 s in) to start it without network.
- A dead audio session (another app took it over) makes the audio element report "playing" without sound; the web player self-heals in stages (request again, reset the element, reload the page).
- DJ crossfades via Web Audio are turned off on iOS (`AudioContext` is unreliable in the background).
