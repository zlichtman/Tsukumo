# Thinking orbs (vendored)

Animated loading orbs from [Libraries.dev](https://libraries.dev/orbs) by Jakub Antalik, MIT License (see `LICENSE`).

- Source: `github.com/Jakubantalik/Libraries.dev`, `packages/thinking-orbs/ports/ios/ThinkingOrbsKit/Sources/ThinkingOrbsKit`, commit `f20116327f4e3b28d0fb70b04437dfd092bf88fe`, copied September 24, 2026.
- Reviewed before copying: pure math and SwiftUI `Canvas`/`TimelineView` drawing. No networking, file access, web views, processes, or install scripts. `Snapshot.swift` (a test-only renderer) was left out.
- Unmodified, so updates can be copied over. KemoSabe wraps it in `KemoOrb` (ios/KemoSabe/ArtworkCompanion.swift), which picks the state and tints it to the theme.
