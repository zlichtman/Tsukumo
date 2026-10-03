import SwiftUI

/// Signing in to a coding agent with a Claude or ChatGPT subscription happens in the agent's own
/// sign-in, which Tsukumo opens in Terminal. Tsukumo never sees the account or its tokens.
enum AgentSignIn {
    static func command(for agent: CodingAgentCommand) -> String? {
        switch agent.id {
        case "codex": "codex login"
        case "claude": "claude"          // Claude Code asks to sign in on first run; /login switches accounts.
        case "gemini": "gemini"          // Gemini CLI offers Google sign-in on first run.
        case "opencode": "opencode auth login"
        default: nil
        }
    }
    /// Opens Terminal running the agent's sign-in, in a login shell so the person's PATH applies.
    static func open(_ agent: CodingAgentCommand) {
        guard let command = command(for: agent) else { return }
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-sign-in-\(agent.id).command")
        let body = "#!/bin/zsh -l\nclear\necho 'Signing in to \(agent.name). Choose your subscription account when asked.'\n\(command)\n"
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {}
    }
}
