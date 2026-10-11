# Developing Tsukumo

The rules for anyone (person or agent) working here are in [AGENTS.md](AGENTS.md). How it's built is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and how every screen looks and behaves is in the [UI guide](design/UI-GUIDE.md). The product overview is the [README](README.md).

## Status · October 11, 2026

The repo is the Tsukumo iPhone app and nothing else (the owner, October 11, 2026: "it's just an iPhone app"). The history keeps the two Mac apps before it, in case a Mac version comes back: "Tsukumo - Mac - Coding Harness" (Tsukumo 77, the coding harness, with the shared sources it compiled) and "Tsukumo - Mac - Dock" (Tsukumo's Dock, its last release 2.11, no longer offered). The KemoSabe iPhone app and its Apple Watch app aren't kept.

| | Version | Delivered |
|---|---|---|
| Tsukumo iPhone app (`apps/ios`) | 1.0.0 (2) | Build 2 is on TestFlight (VALID), in the external group Public demo with the public link https://testflight.apple.com/join/1qvnEhZc, and attached to App Store version 1.0.0 (manual release). Not submitted to Beta App Review or App Review yet: both need the owner's contact phone, and App Privacy (Data Not Collected) is saved but waits for the owner to publish it. The listing (subtitle, promotional text, description, keywords, support and marketing URLs, categories, age rating, free price, five 6.3-inch screenshots) is filled in. |
| Tsukumo relay (`relay/`) | 1.0.0 | Not deployed, and not used by the iPhone app yet. Kept for bringing the KemoSabe gateway to the iPhone (Next, below). |

**What the app does:** one chat page, with your picture at the top right opening Settings. The chat (tags, `@name`, the bot last spoken to, System One picking who answers when nothing is tagged) with the composer's model chip (each bot's model, power, and, on Claude Opus 5.5, 5, and 4.8 through Anthropic's API, fast mode), Your chats as a bottom sheet from the composer (search, New chat, chats, Keep on This iPhone, Activity), See how KemoSabe works (the demo on sample chats), notifications when a bot replies or needs your OK while you're away (local only), KemoSabe on Apple's on-device model with its consent and share cards, bots on Apple on-device or the owner's Claude or OpenAI key (keys in the Keychain), Tsukumo's own characters on any bot (Lobster, Brain, Octopus, Fox, Cat, Penguin, Frog), voice (Apple's recognizer and voices, then Whisper and Kokoro after one download), and Settings: your picture and name, then Account, Bots, Models, Connections, Activity, and Notifications. The first run is Welcome, Connect your AIs, and Connect your life. Every screen is built from the design system in the [UI guide](design/UI-GUIDE.md#design-system). KemoSabe's sources: Reminders, Contacts, Messages given to it through the Shortcuts action, Photos metadata, files and folders the owner picks, Location, Music, and connected accounts (any MCP server). Calendar isn't offered (the owner, October 11, 2026).

**Last verified** (October 11, 2026): `scripts/build.sh --all` built the iPhone app for the simulator and typechecked the relay. The TsukumoGateway module also builds for the iPhone simulator, though nothing in the app uses it yet.

**Next, when the owner asks:** the KemoSabe gateway on the iPhone, so OpenClaw, Grok, Claude, ChatGPT, and other agents can ask KemoSabe from elsewhere. The plan: the iPhone holds the relay's socket while Tsukumo is open, and a request that arrives while it's closed becomes a notification ("Grok wants to know …") that opens Tsukumo to answer, since iOS doesn't let an app keep a server running in the background. It needs the relay deployed (the owner's Cloudflare sign-in), an APNs key, and the Push Notifications capability for `com.zlichtman.tsukumo`.

## Build

Xcode 26 or later. The app is an XcodeGen project: run `xcodegen generate` in `apps/ios/` after pulling; the generated `.xcodeproj` is never committed. Build one project at a time.

**There's no test suite** (October 8, 2026; the owner: "we're going to just ship stuff and I will find the errors"). Write the safest code you can, and when testing one thing by hand is what would catch an error, do that. **`scripts/build.sh`** builds what a change touched, against `origin/main` (or `main` on a branch), committed or not: the iPhone app for the simulator when `apps/ios` or TsukumoKit changed, the relay's typecheck, and `zsh -n` on changed scripts (`--all` builds everything). Builds go to one incremental cache per checkout in `~/Library/Caches/Tsukumo`. The first build compiles MLX and takes a while.

**TsukumoKit:** `swift build` (no xcodebuild). The app also adds `TsukumoKit/MLXVoice` (Whisper and Kokoro on MLX, with the part of mlx-audio-swift they need vendored, and Laya's tokenizer). Pass `--scratch-path` outside iCloud Drive to keep build products out of it.

**The iPhone app:**

```bash
xcodebuild build -project apps/ios/Tsukumo.xcodeproj -scheme Tsukumo -destination 'generic/platform=iOS Simulator'
```

**The demo:** launch with `--demo-fixture` to play the website demo (you ask Claude for a date spot, Claude asks KemoSabe when Sarah is free, KemoSabe answers "After 7 tonight" from sample chats, and Claude books a table). It reads none of the owner's data and needs no key. Other launch arguments (DEBUG and Release alike; none reads the owner's data): `--ui-testing` (fresh temporary storage, its own Keychain services, and a stand-in for Sign in with Apple), `--skip-onboarding` (straight to the chat), `--onboarding` (the first run again), `--appearance=light|dark`, `--demo-final` (the demo's last frame), `--consent-fixture` (the demo with the first-time consent card), `--demo-pace=<x>`, `--demo-activity`, `--open=drawer|settings|activity|connections|models` (Your chats, or Settings at that page).

**The relay (`relay/`):** Node 22 or later; `npm ci`, then `npm run typecheck`. `npm run dev` runs it locally with `wrangler dev`. Never `wrangler login` or `wrangler deploy` without the owner; the deploy steps are in [relay/README.md](relay/README.md).

**Pictures in `design/`** (light and dark) are screenshots of `--ui-testing` runs, redrawn by hand when a screen changes.

**iCloud and Sign in with Apple are behind one switch.** `TSUKUMO_CAPABILITIES` in `apps/ios/project.yml` is `Local` (the default): the app signs with `Config/Tsukumo-Local.entitlements` (empty), so no build registers anything in Apple's developer portal; sync says "Waiting for iCloud to be turned on for Tsukumo" and Sign in with Apple says it isn't ready. `iCloud` signs with `Config/Tsukumo-iCloud.entitlements` (the container `iCloud.com.zlichtman.tsukumo` with CloudKit, and Sign in with Apple). Set it only after the owner approves those capabilities in the portal (known issue 2).

## Release

`apps/ios`, `com.zlichtman.tsukumo`; the version stays 1.0.0 and the build goes up (AGENTS.md rule 2). Only when the owner approves that build:

1. Build: `scripts/build.sh`.
2. Run `scripts/upload-testflight.sh <N>` from the main checkout. It sets `CURRENT_PROJECT_VERSION` in `apps/ios/project.yml` to N, runs `xcodegen generate`, archives the `Tsukumo` scheme (Release, `generic/platform=iOS`), checks the archive's build and bundle ID, and uploads it with `apps/ios/ExportOptions.plist`, signing in with the App Store Connect API key in `~/.appstoreconnect` (never a password). `--no-upload` stops after the archive; `--out <folder>` keeps the archive and logs there.
3. Commit the bump and report Apple's real processing and TestFlight status.

## Where things are

| Area | Files |
|---|---|
| TsukumoKit | `TsukumoKit/Sources/<Module>/`; what each module holds is in [TsukumoKit/README.md](TsukumoKit/README.md) |
| The iPhone app | `apps/ios/Tsukumo/`: `TsukumoApp.swift` (the first run, then the chat with your picture opening Settings, Your chats, the demo, and the composer's actions), `Notifications.swift` (local notifications for replies and consent while you're away), `Onboarding.swift`, `Conversations.swift` (Your chats, Activity), `AppModel.swift` (storage, the account, sync, and the modules), `SettingsScreen.swift` (Settings: your picture and name, Notifications, Account, Bots, Models, KemoSabe), `VoiceSettings.swift`, `SystemOneSettings.swift`, `SourcesScreen.swift` (what KemoSabe may read, and Add a connector), `GiveMessageIntent.swift` (the Shortcuts action that gives KemoSabe a message) |
| Bots and characters | TsukumoCore's `BotSpec.swift`, `BotLook.swift`, `Services.swift`; TsukumoUI's `BotEditor.swift`, `BotCharacters.swift`, `CodexPets.swift` (Tsukumo's own characters, `CodexPets.tsukumo`), `KemoSabeArt.swift`, `CompanionArt.swift`, `BotCustomization.swift` |
| Design system | TsukumoUI's `Style.swift` (`TsukumoTheme`, type) and `DesignSystem.swift` (surfaces, metrics, buttons, `TsukumoSegmented`, `TsukumoEmptyState`, the screen, row, and sheet modifiers), `PowerControls.swift` (the power slider) |
| The chat | TsukumoUI's `ChatSession.swift`, `ChatView.swift`, `ChatComposer.swift`, `ModelSheet.swift` (the model chip's sheet, `ComposerActions`), `Avatars.swift`, `ActivityView.swift`, `Seams.swift` and `KitAdapters.swift`, `DemoFixture.swift`; art in `Resources/` (`ART-NOTICE.txt`) |
| KemoSabe | TsukumoGate (consent, policy, the sources, `SourceCatalog.swift`), TsukumoPolicy, TsukumoContext |
| Settings' catalog | TsukumoUI's `SettingsCatalog.swift`, read by `SettingsScreen.swift` |
| Account and sync | TsukumoUI's `Account.swift`, `Connections.swift`; TsukumoSync |
| Voice | TsukumoVoice, TsukumoUI's `VoiceViews.swift`, `TsukumoKit/MLXVoice/` |
| System One | TsukumoSystemOne, TsukumoUI's `SystemOneSetup.swift` |
| The KemoSabe gateway (not in the app yet) | TsukumoGateway, with `RelayConnection.swift` as the relay's client |
| The Tsukumo relay | `relay/src/` (the Worker, the device Durable Object, the registry, the protocol) |
| Scripts | `scripts/build.sh`, `scripts/upload-testflight.sh` |
| Design | `design/UI-GUIDE.md` and the pictures beside it |

## Known issues

1. **The app hasn't run on a real iPhone or reached TestFlight.** It's been run on simulators only, so KemoSabe's replies and on-device extraction from real data are unchecked on a real iPhone, and no real API turn has run. Apple's on-device model answers on an iOS 27 simulator; an iOS 26.2 simulator on a macOS 27 Mac fails generation with error -1. Not built yet: a consent request as a notification.
2. **iCloud sync and Sign in with Apple wait on the owner's approval in Apple's developer portal.** No build carries the entitlements (`TSUKUMO_CAPABILITIES = Local`), so no real CloudKit call or Apple sign-in has run. To turn them on, the owner approves, for `com.zlichtman.tsukumo`, the iCloud capability with CloudKit and the container `iCloud.com.zlichtman.tsukumo`, and Sign in with Apple; then `TSUKUMO_CAPABILITIES` goes to `iCloud`.
3. **Voice hasn't been heard on an iPhone by a person.** End-of-speech timing, the listening ring, and barge-in are unchecked with a real voice and microphone.
4. **System One hasn't decided for a real message yet.** No real Cloudflare, Jev, or custom call has been made, and Laya hasn't been downloaded by this app.
5. **KemoSabe's sources haven't been tried on real data.** `--ui-testing` uses stand-in permissions and sources that read nothing. Not checked yet: real system prompts and data for Contacts, Photos, Location, and Music, the "Give Message to KemoSabe" automation end to end, and a real MCP server.
6. **`read_reference` has little to read.** The app stores KemoSabe's answers as artifacts, but nothing else yet, and the artifact store's full-text search isn't built.
7. **Bots made on a Mac's coding agents can't run here.** Bots synced from the old Mac app that run on Claude Code, Codex, Cursor Agent, or Gemini CLI, or that stood for a gateway service, stay in the list with a note saying they can't run on iPhone.
8. **The relay isn't deployed and nothing real has gone through it.** It's been run locally with `wrangler dev` only.
9. **Service marks.** Only Claude's spark and OpenAI's blossom ship as official marks; other services show initials until the owner adds each company's mark from its press kit as `TsukumoKit/Sources/TsukumoUI/Resources/ServiceMark-<id>.png` (with its line in `ART-NOTICE.txt`).
