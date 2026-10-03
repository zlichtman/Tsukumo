import SwiftUI

// What the owner sees of agents' questions (design/UI-GUIDE.md#agents-asking-kemosabe), the same
// on iPhone and Mac: the consent prompt's words, Library → Requests, and Connections → Agents.

/// The consent prompt's words: who's asking, what first, and the rules it's allowed under.
enum AgentConsentText {
    static func message(_ prompt: AgentQuestionDesk.ConsentPrompt) -> String {
        let why = prompt.purpose.isEmpty ? "" : " (\(prompt.purpose))"
        return "\(prompt.requester.name) asks: “\(prompt.question)”\(why)\n\nKemo reads your data on this \(AgentDevice.name) and sends back only the answer. "
            + "Sensitive items still ask you first; Device only and Secret items never leave. You can remove it in Settings → Connections."
    }
}

// MARK: The transcript

/// Library → Requests: every agent request and every context packet given to a chat or agent, newest
/// first: who asked or received it, the question and why, exactly what was sent, where a packet came
/// from, and what was left out (counts, never content). Read from the journal on this device.
struct AgentRequestTranscript: View {
    let inbox: AgentRequestInbox
    var search = ""
    @State private var records: [AgentRequestRecord] = []
    @State private var loaded = false

    private var shown: [AgentRequestRecord] {
        records.reversed().filter { record in
            search.isEmpty || [record.requester, record.lookingFor, record.purpose ?? "", record.shared ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loaded && shown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "No agent requests yet" : "No matching requests").font(KemoType.font(.headline))
                    Text(search.isEmpty ? "When Muse, Claude Code, or Codex asks KemoSabe something, or you share a chat’s context, exactly what was sent appears here." : "Try another word.")
                        .font(KemoType.font(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 40).accessibilityIdentifier("agentTranscriptEmpty")
            }
            ForEach(shown) { record in AgentRequestTranscriptRow(record: record) }
        }
        .accessibilityIdentifier("agentTranscript")
        .task(id: inbox.journalRevision) {
            records = (try? await inbox.journal.snapshot()) ?? []
            loaded = true
        }
    }
}

struct AgentRequestTranscriptRow: View {
    let record: AgentRequestRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(record.requester).font(KemoType.font(.headline, weight: .semibold))
                Text(outcome).font(KemoType.font(.caption, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                Spacer(minLength: 0)
                Text(record.receivedAt, format: .dateTime.month(.abbreviated).day().hour().minute()).font(KemoType.font(.caption)).foregroundStyle(.secondary)
            }
            Text(record.lookingFor).font(KemoType.font(.body)).fixedSize(horizontal: false, vertical: true)
            if let purpose = record.purpose, !purpose.isEmpty { line("Why", purpose) }
            if let shared = record.shared { line("Sent", "“" + shared + "”").accessibilityIdentifier("agentTranscriptSent") }
            // A context packet names where it landed and where it came from; an agent's request, what was read.
            line(record.isPacket ? "To" : "Read", record.target)
            if let lineage = record.lineage { line("From", lineage).accessibilityIdentifier("agentTranscriptLineage") }
            if let withheld = record.withheld { line("Left out", withheld).accessibilityIdentifier("agentTranscriptWithheld") }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .textSelection(.enabled)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agentTranscriptRow")
    }
    private var outcome: String {
        switch record.outcome {
        case .shared: record.isPacket ? "Sent" : record.automatic == true ? "Answered" : "Shared"
        case .declined: "Declined"
        case .notFound: "Not found"
        case .refused: "Can’t share"
        case .failed: "Not sent"
        case .unanswered: "Waiting for you"
        }
    }
    private func line(_ label: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Text(text).font(KemoType.font(.subheadline)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Grants

/// Connections → Agents: each agent that may ask KemoSabe, with Remove.
struct AgentQuestionGrantsList: View {
    let store: AppStore
    var body: some View {
        let agents = store.state.agentQuestionAgents()
        VStack(alignment: .leading, spacing: 10) {
            if agents.isEmpty {
                Text("No agent can ask yet. The first time one asks, KemoSabe asks you.").font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
            }
            ForEach(agents) { grant in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(AgentIdentity.name(forKey: grant.recipient)).font(KemoType.font(.body, weight: .semibold))
                        Text(grant.singleUse ? "Allowed once" : "Allowed always · Sensitive items still ask you")
                            .font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button("Remove") { store.state.revokeAgentQuestions(grant.recipient); store.save() }
                        .accessibilityIdentifier("revokeAgent-" + grant.recipient)
                }
            }
        }.accessibilityIdentifier("agentQuestionGrants")
    }
}
