# Tsukumo's Dock 2.01 (build 201)

October 3, 2026. A new bot starts by choosing its AI model, then its name, character, and job, with Brain first among its settings; no starter presets anywhere; KemoSabe's only customization is its companion palette, which recolors the cloud everywhere it appears; and the Settings window follows MacSpaces' design. iCloud and Sign in with Apple stay off in this build (`TSUKUMO_CAPABILITIES=Local`).

- **Where:** the owner's website only: `https://zlichtman.com/downloads/Tsukumo-Dock-2.01.dmg`, with `/downloads/Tsukumo.dmg` and the old 2.00 link redirecting to it. 2.00 was taken down. Homebrew wasn't updated; the `tsukumo` cask stays disabled.
- **DMG:** 5,404,138 bytes, SHA-256 `09341251e4af58cac029316222a346205e25c09bd1d9f3071e1a5ace6cc52154`, notarized (app: a4505e16-fa03-4bcc-bdd8-bc554611b9b4, DMG: 548f9631-11ae-40be-aa62-2406a7d08181), accepted by Gatekeeper as Notarized Developer ID.
- **How:** `scripts/release-mac.sh 201 --dry-run` built, tested (210 TsukumoKit tests), notarized, and checked it; the DMG was placed on the site by hand, since the script's publish step also updates Homebrew.
