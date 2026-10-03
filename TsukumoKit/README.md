# TsukumoKit

The Swift package every Tsukumo surface shares: the iPhone app (`apps/ios`) and the Mac app (`apps/macos`, the side dock). The design is [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md).

- **Platforms:** iOS 26 and macOS 15. Anything that needs macOS 26 or iOS 26 (Foundation Models) is marked `@available`.
- **Dependencies:** none outside Apple's SDKs.
- **Concurrency:** Swift 6 language mode with strict concurrency.

## Modules

Dependencies point down this list only.

| Module | What it does |
|---|---|
| `TsukumoCore` | The shared vocabulary. `BotSpec` (name, engine, model, effort, role, look, personality, context scope, permissions; `normalized()` keeps KemoSabe standard, with only its color), `BotLook` (the clay character: body, palette and the owner's own colors, eyes, expression, topper, accessory, prop, cheeks, dock size and ring), `StarterBot`, `DefaultModel`, `ChatThread`, `Message` with its `Part`s (text, status, artifact references, KemoSabe's question and answer cards), tag-to-send `Routing` (chips, `@name`, a unique first word, the bot last spoken to), `PrivacyLevel`, `ArtifactRef`, bot names and clay characters, and the effort catalog. Saved data round-trips, and parts written by a newer build are kept as written. |
| `TsukumoPolicy` | One pure decision: may this item go to this recipient? `ContextPolicy.evaluate` works only from type labels (an item kind with its floor, plus a level), grants (always, once, expiry), and an optional bot ceiling. A classifier can only raise a label. |
| `TsukumoContext` | The never-ending context. `ArtifactStore` is an SQLite store of versioned artifacts. A revision is written once, never changed, and a database trigger refuses any change. Reads are pinned to a revision and its SHA-256, return exact lines, and fail rather than truncate. Labels flow down lineage. Revoking an artifact erases its content and everything derived from it. `ContextSelection` builds a turn's working set: pinned constraints first, then a chooser's bounded reads, and when the chooser abstains, everything authorized that fits. |
| `TsukumoGate` | KemoSabe. Its Calendar and Reminders sources for both apps (`PersonalSourceKind`, `CalendarSource`, `RemindersSource`). `Gate.ask` handles consent (Allow always, Allow once, Don't allow with a quiet period) and per-bot limits. It checks the policy before any read, so Device only, Secret, and anything above the bot's ceiling are never read for an agent. Each Sensitive item gets its own share card. Answers leave through single-use `DisclosureEnvelope`s and are kept as `personalAnswer` artifacts. `GateJournal` records what was sent, and only counts of what was left out. Extraction runs on Apple's on-device model (`AppleExtractionModel`), with `FixtureExtractionModel` for tests and the demo. |
| `TsukumoSystemOne` | Decisions with per-kind thresholds and abstention. `SystemOne.decide` asks the local provider first (Laya, with the owner's personal layer), then hosted services (Jev) in order, and each hosted call passes the policy first. `DecisionJournal` never holds the request's words. `SystemOne.route` picks the bot for an untagged message, falling back to the bot last spoken to. `SystemOneContextChooser` is `selectContext`. |
| `TsukumoEngines` | One `Engine` protocol that streams a turn: text, tool calls and results, approvals, and the reply. `APIEngine` speaks Claude's Messages API and OpenAI-compatible chat/completions, with keys kept in the Keychain. `OnDeviceEngine` runs Apple's on-device model (KemoSabe the bot). `CodingAgentEngine` (macOS) works through a backend protocol and applies the access gate before asking the owner. Every engine gets `read_reference` and `ask_kemosabe` through `TurnTools`. |
| `TsukumoSync` | `SyncEngine` syncs labeled items through a `CloudDatabase`, checking each against the policy for iCloud. Device only, Secret, KemoSabe's answers, and personal-source items never leave. `InMemoryCloudDatabase` is for tests. `CKCloudDatabase` is the CloudKit adapter. `LibraryMapping` and `LibrarySyncController` keep bots, chats, the default model, and connections (never keys) in step between Mac and iPhone: chats merge by message, deletes are tombstones, Device only chats and KemoSabe's shared answers never leave, and the status line says why sync is off. `CloudCapability` turns it on only in a build signed with the iCloud capability. |
| `TsukumoUI` | The chat as on the website demo, at iPhone sizes or at Mac sizes with `ChatDensity.compact` (`ChatSession`, `ChatScreen`, KemoSabe's card with its consent and share cards, the composer with bot chips and `@name`), bots as the dock's clay characters (`ClayCharacter`), make a bot (`BotEditor`: engine first, a fun name, a random character shown live, then closed Look, Personality, Brain, Context, Permissions, and Dock drawers; `KemoSabeEditor` is KemoSabe's color only; the pieces in `BotCustomization.swift` are shared with the dock), the first run (`OnboardingFlow` over an app's `OnboardingHost`), the account (`AccountStore`, Sign in with Apple, `AccountSummary`), API connections as both apps keep them (`ConnectionRecord`, `ModelCatalog`), Activity (`ActivityFeed`), and `DemoFixture`, which plays the website demo through the real Gate. The kit fills the chat's seams through `EngineRunner`, `GateAnswerer`, and `SystemOneRouter`. |
| `TsukumoDock` | The Mac's side dock (macOS), the Tsukumo Mac app's one face. `BotDock` is its model: the bots (`BotSpec`, KemoSabe first), one `ChatSession` per bot plus Together, each tile's state (thinking, talking, working, needs you, done, asleep), KemoSabe's questions waiting on the owner, callouts, chirps from Calendar and Reminders, and the default model new bots start on. `BotDockController` puts the side dock on screen, always (a Liquid Glass shelf beside the Dock that tucks to a sliver, characters as Core Animation loops drawn by TsukumoUI's `ClayPainter`, magnification, styles, a bubble with a bot's chat or its settings; `setHidden` puts it away for now). `BotDockSettingsView` is the app's Settings, Dock. `BotDock.standard` runs chats on TsukumoKit's engines and Gate; `BotDock.demo` plays the website demo. |

## Running the tests

From this folder:

```sh
swift build
swift test
```

Each module has its own test target. Tests use temporary directories and in-memory stores, never the owner's data. They use stubbed URL loading, never the network, and no real keys. Tests that use Apple's on-device model run only where it's available, and skip otherwise.

To keep build products out of iCloud Drive, pass a scratch path outside it, for example `swift test --scratch-path /tmp/tsukumokit-build`.

The bot editors and the first run at Mac sizes: `TSUKUMO_CUSTOMIZATION_SNAPSHOT_DIR=<repo>/design/bot-customization TSUKUMO_ONBOARDING_SNAPSHOT_DIR=<repo>/design/onboarding swift test --filter BotCustomizationTests`.

TsukumoDock's light and dark renders (the side dock with a bot's chat, and a bot's settings) go to `design/mac-preview/` with `TSUKUMO_MAC_SNAPSHOT_DIR=<repo>/design/mac-preview swift test --filter MacPreviewSnapshots`. The Mac app that runs the dock for real is `apps/macos/` (see DEVELOPMENT.md).
