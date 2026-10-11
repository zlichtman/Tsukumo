# Tsukumo project rules

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first. The shape: the **Tsukumo iPhone app** in `apps/ios` (`com.zlichtman.tsukumo`, its own App Store record), built on **TsukumoKit**, its Swift package, with the **Tsukumo relay** in `relay/` kept for bringing the KemoSabe gateway to the iPhone. That's all this repo holds (the owner, October 11, 2026: "it's just an iPhone app"). The history keeps the two Mac apps before it, in case a Mac version comes back: "Tsukumo - Mac - Coding Harness" (Tsukumo 77, the coding harness, as released on September 30, 2026) and "Tsukumo - Mac - Dock" (Tsukumo's Dock 2.11). Nothing else older is kept.

1. A finished change goes to TestFlight only when the owner approves that build: build, bump the build number, upload, and report Apple's real status.
2. The version stays 1.0.0 and the build number goes up (`apps/ios/project.yml`; `scripts/upload-testflight.sh <build>` bumps it, archives, and uploads); tag `v1.0.0` only on the real public release, and never move a tag.
3. Uploads use the App Store Connect API key, never a password typed for the owner.
4. Agent rules live in AGENTS.md; never create CLAUDE.md.
5. Keep the UI guide (`design/UI-GUIDE.md`) and the code in step.
6. Fix foundations (data integrity, migration, deletion) before new features.
7. Stock theme names never use another company's name (one exception, the owner's word on October 8, 2026: KemoSabe's Finder character).
8. Settings come from one catalog (`SettingsCatalog`), with the groups Account, Bots, Models, Connections. Every bot, KemoSabe included, is in Bots, each with all its settings on its own page. Headings are one or two plain words (Palette, Voice, Character), never "Its …". Models is one page; Account covers identity and sign-in; there's no separate Profile page.
9. Tsukumo has no KemoSabe mode: KemoSabe is its local bot. Calendar isn't one of KemoSabe's sources (the owner, October 11, 2026).
10. Keep the documentation consolidated and current with every change, in the same commit, never later. `README.md` is public only, written for someone discovering the project: the story, the problem it solves, visuals, and how to get and use it. It never holds build numbers, status, in-progress notes, known issues, or developer instructions; change it only when what a user can get or do changes. `DEVELOPMENT.md` holds status, build and release steps, the code map, and known issues. One current doc per topic; superseded docs are removed, not left beside the new ones.
11. User-facing text never shortens KemoSabe to "Kemo" (it sounds like "chemo"): say KemoSabe, or the companion's own name when the person named it. A person's agent is "<Name>'s secure assistant". This covers the app, notices, demos, the website, README, and release notes; code identifiers may keep "Kemo". No em dashes in published copy.
12. There's no test suite (the owner, October 8, 2026: "we're going to just ship stuff and I will find the errors"): don't write test suites or rerun checks. Write the safest code you can; `scripts/build.sh` builds what changed, and it must build. Test one thing by hand only when that's what would catch an error. Live checks on the owner's own sign-ins (real Claude or OpenAI turns, voice) run only when that integration changed and leave no sessions behind.
13. The relay is never deployed, and `wrangler login` never run, without the owner.
14. This repo is public: commits are authored by Zach Lichtman with no co-author line, and there are never GitHub releases.
