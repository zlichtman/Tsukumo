# Tsukumo's Dock 2.00 (build 200)

October 2, 2026. The first release of the new Tsukumo Mac app (`apps/macos`, `com.zlichtman.tsukumo.mac`): the side dock of your bots, Open at Login, and a Settings window. iCloud and Sign in with Apple are off in this build (`TSUKUMO_CAPABILITIES=Local`).

- **Where:** the owner's website only, as a demo download: `https://zlichtman.com/downloads/Tsukumo-Dock-2.00.dmg` (`/downloads/Tsukumo.dmg` redirects to it). Homebrew wasn't updated; the `tsukumo` cask stays disabled.
- **DMG:** 5,311,392 bytes, SHA-256 `6576fe407bb5eb75f679c6685f5d09959ee446cdd6dc5c67d238a091bd9347d0`, notarized (app: c7e67696-6036-48ac-be85-4e07d5f6eb4b, DMG: a94b3d62-1e01-4b6e-b751-6e98bad94152), accepted by Gatekeeper as Notarized Developer ID.
- **How:** `scripts/release-mac.sh 200 --dry-run` built, tested (205 TsukumoKit tests), notarized, and checked it; the DMG was then placed on the site by hand, since the script's publish step also updates Homebrew and removes other Tsukumo downloads.
- **Beside it:** Harness 1.77, the September 30 Tsukumo coding harness (`legacy/macos/`), re-packaged as "Tsukumo Harness" in `Tsukumo-Harness-1.77.dmg` (SHA-256 `6519915cfedb635b98a72772c480ff49a9d21a96439af3195a88bd2e523f8499`); the app inside is the original notarized build, unchanged except for its folder name.
