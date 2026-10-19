# PLAN.md

Status as of 2026-10-19. Time estimates assume work in the evenings and on weekends.

## 1. Decisions

Made:
- New, blank repos. The earlier private prototype stays where it is (see `CLAUDE.md`).
- Split into **backend** (still with a PWA UI) and **iOS app**.
- iOS app modelled on the Home Assistant companion app: a native shell around a web view, **first setup asks for the server address/domain**, linking, then login and normal operation.
- Third-party streaming services leave the core and become **separate plugins**. The core plays your own files (library).
- Apple developer account as a **private person** (99 $/year). The maintainer has no Swift experience.
- Open source under the **MIT licence**, copyright "NxtSound contributors" (all repos), on GitHub later; possibly donations to cover website, demo server and the Apple developer fee.
- A plugin store with community plugins (only the admin may install) is the goal, but **not for the first release**.

Open (ask, do not guess):
- The name is fixed: **NxtSound**, domain nxtsound.app (decided 2026-10-19). The bundle ID is `app.nxtsound.ios` (reverse of the project domain; it cannot be changed after the first App Store Connect record). The provider/store details stay open.
- GitHub account/organisation.
- A private person in the EU store: address and contact are publicly visible as the provider (DSA). Check whether that is wanted or whether a company should be the provider.
- Where the new repos are hosted (own Git server or GitHub).

## 2. Order (risk first, visible quickly)

The most important assumption of the whole project is that a native shell reliably solves **background audio and lock-screen control**. That is checked **first**.

| # | Milestone | What you see afterwards | Estimate |
|---|---|---|---|
| 0 | Apply for an Apple developer account (private person) | Confirmation from Apple | Apply at once, 1–3 days waiting, runs in the background |
| 1 | Xcode project, SwiftUI skeleton, simulator | App starts, "enter server" screen | Day 1 |
| 2 | Server linking: check URL, query `server-info`, login, web view loads the UI | Own server in the simulator, music selectable | Week 1 |
| 3 | **Background audio spike** on a real iPhone (free signing): audio session `.playback`, background mode "audio", test with locked device, pause 10+ minutes, play from the lock screen | Decision: is web audio in the web view enough, or must the player become native | Week 1–2 |
| 4 | Lock screen: now-playing info and remote control (play/pause/previous/next/position) | Lock screen shows title/cover, buttons work, even after a long pause | Week 2 |
| 5 | Backend rebuild in the new repo (see 3) | Play your own files, no third-party service | Week 2–5 |
| 6 | Streaming plugin as its own repo | As before, but installable | in parallel/after 5 |
| 7 | TestFlight (internal without review, external with a short Apple review) | App on the maintainer's iPhone via TestFlight | Week 3–5 |
| 8 | Store submission | Download in the App Store | 6–10 weeks overall |

Decision point after milestone 3:
- **A) Web audio is enough:** the shell stays thin, the web player is kept, only audio session and lock screen are connected natively.
- **B) Too unreliable:** the player becomes native (`AVQueuePlayer`), the web UI controls it via the bridge. More work, but robust.
(Outcome: B was chosen; the native player lives in `NativeAudio.swift`.)

## 3. Backend target picture

- **Core**: users/login, playlists, likes, history, queue, admin, dashboard, DJ analysis (`bpm.py`), lyrics, "What's new".
- **Library** (new, required for the app review): folder scan, tags (via `mutagen`), covers, duration, analysis (BPM, key, intro/outro), search and filters, metadata enrichment (MusicBrainz).
- **Plugins (decided, implemented)**: a plugin is its own process with an HTTP protocol, not code loaded into the core. The server manages it itself (`pluginhost.py`): folder `plugins/<id>/` with `plugin.json`, own venv, child process on 127.0.0.1 with a random token, no server secrets in its environment. Installation **by hand** (folder/`git clone` on the server) or **in the admin area via repository URL** (can be turned off with `PLUGIN_REPO_INSTALL=0`); remote plugins (separate service) stay possible. Protocol: `nxtsound-server/PLUGINS.md`, checker `plugincheck.py`. A store comes later.
- **API**: versioned, `GET /api/server-info` without login for linking the app. Cookie sessions work in the web view; keep token login in mind for later native parts.
- **Legal behaviour**: the core knows no streaming services. Everything service-specific lives in a plugin.
- **Languages**: UI and server messages in English and German (see the server README).

## 4. iOS app target picture

- SwiftUI skeleton: setup (enter address/domain, check reachability and `server-info`; the app only links to servers identifying as NxtSound), login, then `WKWebView` with the server UI limited to the linked server. Several servers would be possible later.
- Credentials and server address in the keychain. Log out/switch server in the settings.
- Native value (important against rejection under guideline 4.2 "Minimum functionality"): linking, keychain, background audio, lock screen/control center, later Siri/CarPlay/offline.
- Network: HTTPS preferred. For local servers (home network, `http://192.168…`) provide the ATS exceptions for local networks and `NSLocalNetworkUsageDescription`.
- Info.plist: `UIBackgroundModes: audio`.
- Not a word about streaming services in the app, store texts and screenshots.
- Languages: English and German (String catalogs in `App/en.lproj` and `App/de.lproj`); the web UI follows the device language.

## 5. Store checklist (later)

- Paid account active, app ID, certificates (Xcode "Automatically manage signing" is usually enough).
- Privacy policy (URL), support URL, app privacy details ("usage data, account").
- **Demo server and demo access for the reviewer** with a few freely usable music files (e.g. CC-licensed); a regular user, no plugin installed, `PLUGIN_REPO_INSTALL=0`; explain in the review notes how to connect.
- Screenshots, description, age rating, export compliance (standard encryption/HTTPS only).
- Provider details under the DSA (private person: address visible).
- Expect one or two rounds of rejection.

## 6. Risks

- **Background audio in a web view** does not work reliably → decision point B (native player). That is why the spike came first.
- **Rejection as a "mere website shell"** → show native value, provide a demo server.
- **Without a paid account**: the signature expires after 7 days, no TestFlight. Apply early.
- **Scope**: plugin store, isolation and further metadata sources are version 2, not version 1.
- **Maintenance** after release (issues, iOS updates, plugin compatibility) is a permanent effort.
