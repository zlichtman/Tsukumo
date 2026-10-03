import Foundation

/// Stock app themes are named for their look, not for other companies' products. Saved
/// choices from before the September 25, 2026 rename are read through this map, so nobody's
/// theme changes. The Mac keeps its old IDs for storage and shows these names.
enum ThemeNames {
    static let renamed = ["Absolutely": "Clay", "Codex": "Slate", "GitHub": "Canvas", "Linear": "Vector", "Notion": "Notebook",
                          "Raycast": "Beam", "Sentry": "Aubergine", "Vercel": "Onyx", "VS Code Plus": "Classic", "Xcode": "Workbench"]
    static func current(_ name: String) -> String { renamed[name] ?? name }
}
