# Developing Tsukumo

The rules for anyone (person or agent) working here are in [AGENTS.md](AGENTS.md). How it's built is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), and how every screen looks and behaves is in the [UI guide](design/UI-GUIDE.md). The product overview is the [README](README.md).

## Status · October 3, 2026

| | Version | Delivered |
|---|---|---|
| Tsukumo Mac app, Tsukumo's Dock (`apps/macos`) | 2.00 (200) | A download on the owner's website (`Tsukumo-Dock-2.00.dmg`, notarized; [record](docs/releases/TSUKUMO-DOCK-2.00.md)). Not on Homebrew yet. iCloud and Sign in with Apple are off in this build. |
| Tsukumo iPhone app (`apps/ios`) | 1.0.0 (1) | Not uploaded yet: the App Store Connect record for `com.zlichtman.tsukumo` is the owner's to create; then `scripts/upload-testflight.sh <build>` (Release, below). |

**What's built,** shared through TsukumoKit and used by both apps:

- **The chat** as on the website demo: tags (chips and `@name`), the bot last spoken to when nothing is tagged, KemoSabe's consent and share cards inline, Activity. Engines: Apple on-device (KemoSabe) and API models (Claude, OpenAI-compatible) with keys in the Keychain.
- **KemoSabe** (TsukumoGate): consent, policy before any read, on-device extraction, single-use answers kept as artifacts, the journal; Calendar and Reminders as its first sources, each off until the owner turns it on, at a level the owner sets.
- **The first run, the account, and customization:** welcome, Sign in with Apple or continue without an account, connect what you use, and your bots; KemoSabe always standard (its color is the one setting); every other bot's look, personality, brain, context, permissions, and dock size and ring.
- **Mac-iPhone sync** of bots, chats, the default model, and connections without keys (`LibrarySyncController`), off until the owner approves the portal capabilities (known issue 3).
- **The iPhone app:** the chat as the whole app, the conversations drawer (New chat, chats, Keep on This iPhone, Activity), Settings (Account, bots, Models, KemoSabe).
- **The Mac app:** always the side dock (TsukumoDock), from the menu bar; Open at Login; a Settings window with Account, Bots, Models, KemoSabe, Dock, and General; its store in `~/Library/Application Support/Tsukumo`.

**Last verified** (October 3, 2026): `swift test` for TsukumoKit, 205 tests (165 Swift Testing, 40 XCTest), no failures; the Mac app builds in Debug. Earlier, on October 2: the Mac app in Release with no warnings, its first run and dock with `--ui-testing`, and its `--capture` pictures; the iPhone app's 15 unit tests and 12 UI tests on an iOS 27 simulator.

## Build and test

All three are built with Xcode 26 or later. The apps are XcodeGen projects: run `xcodegen generate` in `apps/macos/` or `apps/ios/` after pulling; the generated `.xcodeproj` is never committed. Build one project at a time, with parallel testing off; several builds at once saturate the Mac.

**TsukumoKit:** `swift build` and `swift test` (no xcodebuild). Pass `--scratch-path` outside iCloud Drive to keep build products out of it, for example `swift test --package-path TsukumoKit --scratch-path /tmp/tsukumokit-build`. Tests use temporary folders, in-memory stores, and stubbed URL loading; tests of Apple's on-device model skip where it isn't available. TsukumoUI's snapshots are written to `$TSUKUMO_SNAPSHOTS` (or a temporary folder). More in [TsukumoKit/README.md](TsukumoKit/README.md).

**The Mac app (`apps/macos`):** `xcodegen generate` in `apps/macos/`, then build and open it:

```bash
xcodebuild build -project apps/macos/Tsukumo.xcodeproj -scheme Tsukumo -configuration Debug -derivedDataPath /tmp/tsukumo-mac-dd -destination 'platform=macOS'
open -n "/tmp/tsukumo-mac-dd/Build/Products/Debug/Tsukumo.app" --args --ui-testing   # a fresh temporary store; nothing of yours is touched
open -n "/tmp/tsukumo-mac-dd/Build/Products/Debug/Tsukumo.app" --args --demo         # the website demo; saves nothing
```

It lives in the menu bar (no Dock icon). Its first run shows until it's done, then the side dock appears, always. Without `--ui-testing` it uses your own store, `~/Library/Application Support/Tsukumo`, and Open at Login turns on once for a copy in /Applications. `--ui-testing` starts from a fresh temporary folder with its own Keychain items (`com.zlichtman.tsukumo.mac.ui-testing.*`), the Sign in with Apple stand-in, and a stand-in login item; `--onboarding` starts the first run over. DEBUG builds also take `--capture <folder>` (with the first run showing: each step, a customized bot's editor and KemoSabe's, and every Settings page signed out and in, light and dark, as AppKit draws them, so no live glass; otherwise the dock's windows and Settings' Bots and Models), `--real-sign-in` (Apple's own button instead of the stand-in), and `--preview-folder <folder>` (with `--ui-testing`, moves that folder in as if it were the preview build's). Outside `--demo`, KemoSabe answers with Apple's on-device model (macOS 26 with Apple Intelligence), API bots run on your connections, and coding agents say they aren't connected yet. The Mac app has no test target of its own; its logic is in TsukumoKit.

**The iPhone app (`apps/ios`):** `xcodegen generate` in `apps/ios/`, then

```bash
xcodebuild test -project apps/ios/Tsukumo.xcodeproj -scheme Tsukumo -destination 'platform=iOS Simulator,name=<an iOS 26 or later iPhone simulator>' -parallel-testing-enabled NO
```

Launch arguments (DEBUG and Release alike; none reads the owner's data): `--ui-testing` (fresh temporary storage, its own Keychain services, and a stand-in for Sign in with Apple), `--skip-onboarding` (straight to the chat; most UI tests), `--onboarding` (the first run again), `--appearance=light|dark`, `--demo-fixture` (plays the website demo), `--demo-final` (its last frame), `--consent-fixture` (the demo with the first-time consent card), `--demo-pace=<x>`, `--demo-activity`, `--open=drawer|activity|settings`, `--create-bot`. `testTour` (only with `TEST_RUNNER_TSUKUMO_TOUR=1`) walks the app from the first run on the real on-device model, for a screen recording.

**Pictures in `design/`** (light and dark):

- iPhone first run, KemoSabe's settings, and a customized bot: `TEST_RUNNER_TSUKUMO_SCREENSHOT_DIR=<folder>` with `-only-testing:TsukumoUITests/TsukumoUITests/testScreenshots` (skipped without it), into `design/onboarding/` and `design/bot-customization/`.
- The bot editors and the first run at Mac sizes: `TSUKUMO_CUSTOMIZATION_SNAPSHOT_DIR=<repo>/design/bot-customization TSUKUMO_ONBOARDING_SNAPSHOT_DIR=<repo>/design/onboarding swift test --filter BotCustomizationTests`.
- The side dock: `TSUKUMO_MAC_SNAPSHOT_DIR=<repo>/design/mac-preview swift test --filter MacPreviewSnapshots`.
- Every Mac Settings page: the Mac app's DEBUG `--ui-testing --capture <folder>`, into `design/mac-settings/`.

**iCloud and Sign in with Apple are behind one switch.** `TSUKUMO_CAPABILITIES` in `apps/ios/project.yml` and `apps/macos/project.yml` is `Local` (the default): the app signs with `Config/*-Local.entitlements` (empty), so no build registers anything in Apple's developer portal; sync says "Waiting for iCloud to be turned on for Tsukumo" and Sign in with Apple says it isn't ready (UI tests use the stand-in). `iCloud` signs with `Config/*-iCloud.entitlements` (the container `iCloud.com.zlichtman.tsukumo` with CloudKit, and Sign in with Apple) and writes `TsukumoCapabilities = iCloud` into Info.plist, which turns `CKCloudDatabase` on (`CloudCapability`). Set it only after the owner approves those capabilities in the portal (known issue 3). Simulator builds sign to run locally and never contact the portal.

## Release

- **iPhone** (`apps/ios`, `com.zlichtman.tsukumo`; the version stays 1.0.0 and the build goes up, AGENTS.md rule 2):
  1. Test: TsukumoKit's `swift test` and the app's unit and UI tests (Build and test, above).
  2. Run `scripts/upload-testflight.sh <N>` from the main checkout. It sets `CURRENT_PROJECT_VERSION` in `apps/ios/project.yml` to N, runs `xcodegen generate`, archives the `Tsukumo` scheme (Release, `generic/platform=iOS`), checks the archive's build and bundle ID, and uploads it with `apps/ios/ExportOptions.plist` (app-store-connect, destination upload), signing in with the App Store Connect API key in `~/.appstoreconnect` (never a password). `--no-upload` stops after the archive; `--out <folder>` keeps the archive and logs there. It waits for any other xcodebuild first.
  3. Commit the bump, report Apple's real processing and TestFlight status, expire the previous build, and add `docs/releases/TSUKUMO-IOS-<N>.md`.
- **Mac** (`apps/macos`, `com.zlichtman.tsukumo.mac`; one notarized Developer ID build for everyone, installed with Homebrew, `brew install --cask zlichtman/tap/tsukumo`, or from the owner's website; only when the owner approves a release). The version is 2.<NN> (AGENTS.md rule 2): build 200 is version 2.00.
  1. From `main` in the main checkout, with the screen unlocked, run `scripts/release-mac.sh <N> [--notes "<one line>"]`. Try it first with `--dry-run --out <folder>`: that tests, builds, notarizes, and checks a real candidate, then prints the site, feed, cask, and bump changes without committing, pushing, deploying, or tagging.
  2. The script waits for other xcodebuild or notarytool runs and for an unlocked screen, runs TsukumoKit's `swift test` on a clean `git archive HEAD` export with the build number set, and builds the app:
     - **Default (no Developer ID profile installed):** archived with `TSUKUMO_CAPABILITIES=Local`, manual Developer ID signing, and no provisioning profile; the script checks that no iCloud or Sign in with Apple entitlement slipped in and that `TsukumoCapabilities` is `Local`.
     - **With iCloud and Sign in with Apple:** used automatically once a Developer ID profile for `com.zlichtman.tsukumo.mac` carrying the container `iCloud.com.zlichtman.tsukumo` and Sign in with Apple is installed (made in the developer portal with the Developer ID Application certificate), or forced with `--with-icloud`. It archives with `TSUKUMO_CAPABILITIES=iCloud` and automatic signing and exports `developer-id` with that profile, then checks the container, Production CloudKit, Sign in with Apple, and the embedded profile.
     - Either way: hardened runtime, no `get-task-allow`, the app notarized and stapled, then the themed DMG (`scripts/dmg`, dmgbuild in `~/.venvs/dmgbuild`) signed, notarized, and stapled.
  3. Website (the Portfolio site, deployed only with the Vercel CLI from a clean `git archive HEAD` export): `public/downloads/Tsukumo-2.<NN>.dmg` replaces the previous DMG in the same commit (Homebrew's audit refuses a fixed sha256 on an unversioned URL), `next.config.ts`'s `tsukumoDownload` makes `/downloads/Tsukumo.dmg` a temporary redirect to it, and `public/downloads/tsukumo.json` (`{version, build, url, sha256, minimumMacOS, notes}`) is what the cask's livecheck reads. Only those paths are committed, as the no-reply identity. The live DMG must answer 200 with the same SHA-256.
  4. Homebrew: `Casks/tsukumo.rb` in `zlichtman/homebrew-tap` gets `version "2.<NN>"`, the sha256, the url `Tsukumo-#{version}.dmg`, a livecheck returning the feed's `version`, `uninstall quit: "com.zlichtman.tsukumo.mac"`, and no `auto_updates` (this app has no updater of its own, so `brew upgrade` updates it); everything else stays (`depends_on macos: :tahoe`). `brew style` and `brew audit --cask --online` must pass before it's pushed, as the no-reply identity. Leave the tap's other casks alone.
  5. It checks the live DMG, the redirect, the feed, and `brew update` + `brew fetch --cask`, then commits and pushes the build number bump to `main` (or only pushes, when the bump is already committed). No git tag. Record the build in the status table above and in `docs/releases/`.
  6. Never a GitHub release; the tap holds casks only.

## Where things are

| Area | Files |
|---|---|
| TsukumoKit | `TsukumoKit/Sources/<Module>/`, tests in `TsukumoKit/Tests/<Module>Tests/`; what each module holds is in [TsukumoKit/README.md](TsukumoKit/README.md) |
| The chat (TsukumoUI) | `ChatSession.swift` (the chat's state, tags, turns, KemoSabe's cards), `ChatView.swift` (screen, header, transcript, KemoSabe's card, consent and share cards), `ChatComposer.swift`, `Avatars.swift` and `ClayCharacter.swift` (the clay characters, KemoSabe's artwork, engine marks), `BotEditor.swift` (make a bot), `ActivityView.swift`, `Seams.swift` and `KitAdapters.swift` (`EngineRunner`, `GateAnswerer`, `SystemOneRouter`), `DemoFixture.swift`; art in `Resources/` (`ART-NOTICE.txt`); tests `ChatSessionTests`, `DemoFixtureTests`, `KitAdapterTests`, `SnapshotTests` (reference: the website video's last frame) |
| First run, account, customization, sync | `TsukumoKit/Sources/TsukumoUI/Onboarding.swift` (`OnboardingFlow`, `OnboardingHost`), `Account.swift` (`AccountStore`, Keychain Apple user ID, `AccountSummary`, `AppleSignInButton`), `BotCustomization.swift` (`LookControls`, `DockLookControls`, `PersonalityControls`, `KemoSabeEditor`), `Connections.swift` (`ConnectionRecord`, `ModelCatalog`), `TsukumoCore/BotLook.swift` and `BotSpec.swift` (`BotTint`, `BotPersonality`, `StarterBot`, `DefaultModel`, `normalized()`), `TsukumoSync/LibrarySync.swift` (`LibraryMapping`, `LibrarySyncController`, `CloudCapability`); the capability switch in `apps/*/Config/` |
| The side dock (TsukumoDock) | `BotDock.swift` (the model), `DockShelfView.swift` (the shelf and tiles), `DockWindows.swift` (`BotDockController` and its panels), `DockChat.swift` (a bot's chat and Together), `DockBotForm.swift` (a bot's settings, and `BotDockSettingsView`: Settings, Dock), `DockSettings.swift` (`DockSettings`), `DockCharacters.swift` and `DockSprites.swift` (states and Core Animation loops), `DockChirps.swift`, `DockWork.swift` (`DockWorkCue`, `EditorFollower`), `DockStore.swift` (`BotDockStore`), `DockSessions.swift`; tests `BotDockTests`, `DockThemesTests`, `DockChatTests`, `DockWorkAndChirpTests`, `BotCustomizationTests`, `MacPreviewSnapshots` |
| The Mac app | `apps/macos/Tsukumo/`: `TsukumoApp.swift` (the menu bar item and menu, `TsukumoDelegate`: the store, the dock, the first run, engines, sync, connections, KemoSabe's sources), `SettingsWindow.swift` (the Settings window and its pages, `ConnectionEditor`), `Storage.swift` (the folder, `PreviewMigration`), `LaunchAtLogin.swift`, `Capture.swift` (DEBUG `--capture`); `apps/macos/project.yml`, `Config/` (Info.plist, entitlements) |
| The iPhone app | `apps/ios/Tsukumo/`: `TsukumoApp.swift` (the first run, then the chat as the whole app, the drawer, sheets), `Onboarding.swift` (the app as `OnboardingHost`), `ConversationsDrawer.swift` (chats, New chat, Keep on This iPhone, Activity), `AppModel.swift` (storage, the account, sync, and the modules), `SettingsScreen.swift` (Account, bots, Models with the default model, KemoSabe), `PersonalSources.swift` (the names it uses for TsukumoGate's Calendar and Reminders); tests `apps/ios/TsukumoTests/`, `apps/ios/TsukumoUITests/`; pictures `apps/ios/Screenshots/` |
| Scripts | `scripts/release-mac.sh` (the Mac release), `scripts/dmg/` (the DMG's window and background), `scripts/upload-testflight.sh` (the iPhone upload) |
| Design | `design/UI-GUIDE.md` and the pictures beside it |

## Known issues

1. **The iPhone app hasn't run on a real iPhone or reached TestFlight.** It's tested on simulators only, so KemoSabe's own replies on a real iPhone and on-device extraction from real Calendar and Reminders data are unchecked; no real API turn ran (no key in tests). Apple's on-device model answers on an iOS 27 simulator; an iOS 26.2 simulator on a macOS 27 Mac fails generation with error -1. Not built yet: a consent request as a notification, and Contacts, Location, and Messages as sources.
2. **Tsukumo's Dock hasn't been seen on screen with live glass.** Its windows were saved from inside the app (`--capture`), which can't draw Liquid Glass, the shelf's vibrant tiles, or the bubble's glass text. Not checked: a real Sign in with Apple, a real API key, Calendar access prompts, the login item on a copy in /Applications, and a real preview build's data and Keychain items. 2.00 went to the website by hand after `scripts/release-mac.sh 200 --dry-run`, since the script's publish step also updates Homebrew; the full script hasn't run for this app. When the cask moves to it, the old app's 1.80 updater will read 2.00 in `tsukumo.json` and refuse it (another bundle ID), so owners of the old app move with `brew upgrade --cask tsukumo` or a download; its data in `~/Library/Application Support/KemoSabe` isn't brought over. Not ported from the old dock: hold to talk and dictation, reading replies aloud, the ⌃⌥D hot key, the review panel, and chirps as lines in Together.
3. **iCloud sync and Sign in with Apple wait on the owner's approval in Apple's developer portal.** Built and tested against the in-memory database (`LibrarySyncTests`) and with the Sign in with Apple stand-in; no build carries the entitlements (`TSUKUMO_CAPABILITIES = Local`), so no real CloudKit call or Apple sign-in has run. To turn them on, the owner approves, for App IDs `com.zlichtman.tsukumo` (iPhone) and `com.zlichtman.tsukumo.mac` (the Mac app): the iCloud capability with CloudKit and the container `iCloud.com.zlichtman.tsukumo` (created once, shared by both), and Sign in with Apple (the iPhone as primary App ID, the Mac app grouped with it); then build with `TSUKUMO_CAPABILITIES=iCloud` and check two real devices. Website and Homebrew builds also need a Developer ID provisioning profile carrying both (`release-mac.sh` uses it once it's installed). Not built yet: CloudKit push subscriptions (sync runs on launch, on returning to the app, and after local changes).
4. **Coding agents aren't connected in the Mac app.** TsukumoEngines has a `CodingAgentBackend` protocol, tested with a fake; the real CLI adapters (Claude Code, Codex, Muse Code, Cursor Agent, ACP agents) aren't in TsukumoKit yet, so a coding bot says it isn't connected, and the dock's work cues and editor follow have nothing to drive them.
5. **System One abstains.** `route` and `selectContext` start at a 0.9 threshold and are unmeasured, so untagged messages go to the bot last spoken to and a turn gets every authorized reference that fits. Neither app downloads Laya or takes a Jev key yet.
6. **`read_reference` has little to read.** The apps store KemoSabe's answers as artifacts, but nothing else yet, and the artifact store's full-text search isn't built.
7. **Keychain prompts after switching signatures.** macOS ties each saved secret (API keys, the Apple user ID) to the signature that saved it. Moving between a development build and the Developer ID (website or Homebrew) build asks once per secret for the login keychain password; **Always Allow** adds the new signature, and later builds with the same signature match it.

## The old apps (legacy/)

`legacy/` holds the code of the two apps Tsukumo replaced, as they stood on September 30, 2026, for reference: the old Tsukumo coding harness for Mac (Tsukumo 77, `legacy/macos/`) and the KemoSabe iPhone app with its Apple Watch app and widgets (build 69, `legacy/ios/`, which also holds the sources the old Mac app compiled). Nothing in the current apps builds from it; the "ports from" notes in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) point into it. To build either, run `xcodegen generate` in `legacy/macos/` or `legacy/ios/` ([legacy/README.md](legacy/README.md)).
