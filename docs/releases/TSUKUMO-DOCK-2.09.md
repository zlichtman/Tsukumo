# Tsukumo's Dock 2.09 (build 209)

October 8, 2026. Muse can find your Mac. macOS gives a Bluetooth peripheral 28 bytes of advertisement; Muse's 128-bit service UUID took 18, which cut the gadget's name, MuseGadgetXXXXXX, to "MuseGadg", and the Muse app, which finds gadgets by that name, never listed the Mac (the Mac's log showed it advertising and no phone ever connecting). The Mac now advertises the name only; the service is still there once the phone connects.

- **Where:** `https://zlichtman.com/downloads/Tsukumo-2.09.dmg`, with `/downloads/Tsukumo.dmg` redirecting to it, and the update feed `https://zlichtman.com/downloads/tsukumo.json` (version 2.09, build 209). Copies of 2.04 and later update themselves. Homebrew: `brew install --cask zlichtman/tap/tsukumo`.
- **DMG:** 26,596,278 bytes, SHA-256 `2f442155292ed9c28b059e727589f80794900fc8f1976003594d16a4445bbe36`, notarized, stapled, accepted by Gatekeeper as Notarized Developer ID.
- **How:** the owner: "just push a new copy with the fix always". `scripts/release-mac.sh 209` from `main` (no dry run), with the site deployed, the cask updated and audited, and the live download, redirect, feed, and `brew fetch` checked against the SHA-256.
- **Not checked live:** the Muse app listing and pairing with the Mac; the cause is read from the advertisement's size, not seen on the phone.
