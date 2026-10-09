# Tsukumo's Dock 2.08 (build 208)

October 8, 2026. Settings, reorganized (the owner: "all the bots go into the bots section"): the sidebar is Account, Bots, Models, Connections, Gateway, Dock, and General. Bots is one list of KemoSabe, your bots, and Muse, each opening its page with all its settings (KemoSabe's page holds Character, Palette, Voice, Allowed bots, Chirps, and Journal; there's no separate KemoSabe page), then Connect and Agents. Connections is what KemoSabe may read. General has Appearance: System, Light, or Dark, as in MacSpaces. Tsukumo's own characters, Lobster and Brain, can be worn by any bot; an OpenClaw agent comes in as the lobster. iCloud and Sign in with Apple stay off (`TSUKUMO_CAPABILITIES=Local`).

- **Where:** `https://zlichtman.com/downloads/Tsukumo-2.08.dmg` (replaced on the site by 2.09 the same day). Homebrew: `brew install --cask zlichtman/tap/tsukumo`.
- **DMG:** 26,596,704 bytes, SHA-256 `83d77d6a283d067a0aaf50b4e86734d5ddecff80630d40b88e4e9fcf21a94c97`, notarized, stapled, accepted by Gatekeeper as Notarized Developer ID.
- **How:** the owner: "ship 2.08". `scripts/release-mac.sh 208` from `main` (no dry run: the script hadn't changed since 2.07), with the site deployed, the cask updated and audited, and the live download, redirect, feed, and `brew fetch` checked against the SHA-256.
- **Before it:** the Mac and iPhone apps build; every Settings page was captured and looked at, except KemoSabe's page sheet.
- **Not checked live:** KemoSabe's page in Settings with its new groups, Appearance on the live dock, Lobster and Brain on a bot.
