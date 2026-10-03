import XCTest
import SwiftUI
import AppKit
@testable import KemoSabeMac

/// Coordination's system diagram (September 28, 2026): people in the first column, independent
/// tasks next, dependent tasks one column past what they wait on, cards never overlapping.
/// Renders a review PNG when `TSUKUMO_SNAPSHOT_DIR` is set.
@MainActor final class CollabDiagramTests: XCTestCase {
    private func task(_ id: String, agent: String?, title: String, state: CollabState, files: [String], plan: String? = nil, subtask: String? = nil, dependsOn: [String]? = nil) -> CollabTask {
        CollabTask(id: id, project: "p", owner: "zach", ownerName: "Zach", agent: agent, title: title, state: state, branch: nil,
                   files: files.map { CollabFileTouch(path: $0, kind: .changed) }, updated: Date(), plan: plan, subtask: subtask, dependsOn: dependsOn)
    }
    private var board: CollabBoard {
        CollabBoard(tasks: [
            task("me", agent: nil, title: "", state: .working, files: ["README.md", "App.swift"]),
            task("a", agent: "Claude Code", title: "Plan: Plan a small readme refresh", state: .paused, files: [], plan: "p1", subtask: "s1"),
            task("b", agent: "Claude Code", title: "Arrival estimates", state: .working, files: ["Route.swift", "ETA.swift", "Map.swift"], plan: "p1", subtask: "s2", dependsOn: ["s1"]),
            task("c", agent: "Codex", title: "Route changes", state: .needsYou, files: ["Route.swift", "Graph.swift", "Cost.swift"])
        ])
    }
    func testColumnsFollowDependencies() {
        let nodes = CollabField.nodes(board)
        let deps = CollabField.dependencies(board, nodes: nodes)
        let columns = CollabLayout.columns(nodes, dependencies: deps)
        XCTAssertEqual(columns["me"], 0); XCTAssertEqual(columns["a"], 1); XCTAssertEqual(columns["c"], 1); XCTAssertEqual(columns["b"], 2)
    }
    func testCardsNeverOverlap() {
        let nodes = CollabField.nodes(board)
        let placed = CollabLayout.place(nodes, dependencies: CollabField.dependencies(board, nodes: nodes), width: 1100)
        let rects = placed.points.values.map { CGRect(x: $0.x - CollabLayout.card.width / 2, y: $0.y - CollabLayout.card.height / 2, width: CollabLayout.card.width, height: CollabLayout.card.height) }
        for i in rects.indices { for j in rects.indices where j > i { XCTAssertFalse(rects[i].intersects(rects[j])) } }
        XCTAssertEqual(CollabField.wires(nodes, dependencies: CollabField.dependencies(board, nodes: nodes)).count, 3)
    }
    func testRendersForReview() throws {
        for scheme in [ColorScheme.dark, .light] {
            let preferences = DesktopPreferences(defaults: UserDefaults(suiteName: "CollabDiagram-" + UUID().uuidString)!)
            let palette = preferences.palette(scheme)
            let view = CollabField(board: board, palette: palette, focus: .constant(nil)) { _ in }
                .environment(\.colorScheme, scheme)
                .foregroundStyle(palette.foreground).tint(palette.accent)
                .padding(20).frame(width: 1100).background(palette.background)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage)
            if let path = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_DIR"], !path.isEmpty,
               let png = NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("collab-diagram-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
