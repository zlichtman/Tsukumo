import XCTest
@testable import KemoSabeMac

/// Sign-in comes from each agent's own status command (September 27, 2026: Claude Code showed
/// "Uses its own sign-in" while `claude auth status` said it was logged in).
@MainActor final class AgentSignInTests: XCTestCase {
    func testClaudeReadsAuthStatusJSON() {
        let claude = ClaudeCodeAdapter()
        XCTAssertEqual(claude.statusArguments, ["auth", "status"])
        XCTAssertEqual(claude.parseStatus(#"{"loggedIn": true, "authMethod": "claude.ai"}"#, code: 0), .signedIn)
        XCTAssertEqual(claude.parseStatus(#"{"loggedIn": false}"#, code: 1), .signedOut)
        XCTAssertEqual(claude.parseStatus("Warning: something\n{\"loggedIn\": true}", code: 0), .signedIn)
        XCTAssertNil(claude.parseStatus("unexpected", code: 0))
    }
    func testCodexReadsLoginStatus() {
        let codex = CodexAdapter()
        XCTAssertEqual(codex.parseStatus("Logged in using ChatGPT", code: 0), .signedIn)
        XCTAssertEqual(codex.parseStatus("Not logged in", code: 1), .signedOut)
    }
    func testCursorReadsStatus() {
        let cursor = CursorAgentAdapter()
        XCTAssertEqual(cursor.parseStatus("✓ Login successful!\nLogged in (unable to fetch user details)", code: 0), .signedIn)
        XCTAssertEqual(cursor.parseStatus("Not logged in", code: 1), .signedOut)
        XCTAssertNil(cursor.parseStatus("", code: 0))
    }
    func testMuseHasNoStatusCommandAndKeepsItsFileCheck() {
        XCTAssertNil(MuseCodeAdapter().statusArguments)
    }
}
