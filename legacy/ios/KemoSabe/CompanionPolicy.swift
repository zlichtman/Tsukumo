import Foundation

enum AgeBand: String, Codable, CaseIterable { case youngChild, olderChild, teen, adult }
struct PersonProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var ageBand: AgeBand
    // Explicitly entered relationship and consent, never inferred from audio.
    var voiceEnrollmentConsented = false
}
struct SocialRelationship: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case friend, coworker, guardianOf, collaborator }
    var id = UUID()
    var from: UUID
    var to: UUID
    var kind: Kind
    var mutuallyConfirmed = false
    // A relationship describes context. It is NEVER an access grant.
}
enum CompanionCapability: String, Codable {
    case generalAnswer, changeMusic, readPrivateMemory, sendEmail, changeSchedule, manageSharing
}
struct ResourceGrant: Codable, Equatable {
    var personID: UUID
    var capability: CompanionCapability
    var expiresAt: Date
}
struct GraphResource: Codable, Identifiable, Equatable {
    var id = UUID()
    var ownerID: UUID
    var name: String
    var grants: [ResourceGrant] = []
}
enum SpeakerEvidence: Equatable {
    case unknown, overlapping
    case voiceCandidate(UUID)
    case authenticated(UUID, expiresAt: Date)
}
enum SocialDecision: Equatable {
    case answer(AgeBand), allow, requireOwnerApproval, requireAuthentication, deny
}
enum SocialGraphPolicy {
    static func decide(_ capability: CompanionCapability, speaker: SpeakerEvidence,
                       profiles: [PersonProfile], resource: GraphResource?,
                       sharedAudience: AgeBand = .youngChild, now: Date) -> SocialDecision {
        let profile: PersonProfile?
        let authenticated: Bool
        switch speaker {
        case .voiceCandidate(let id):
            profile = profiles.first { $0.id == id && $0.voiceEnrollmentConsented }; authenticated = false
        case .authenticated(let id, let expires):
            profile = profiles.first { $0.id == id }; authenticated = expires > now
        default: profile = nil; authenticated = false
        }
        if capability == .generalAnswer {
            // Unknown speakers never inherit an adult's conversation context.
            if authenticated, let profile, resource?.ownerID == profile.id { return .answer(profile.ageBand) }
            return .answer(sharedAudience)
        }
        guard let profile else { return .requireAuthentication }
        guard authenticated else { return .requireAuthentication }
        guard let resource else { return .deny }
        if resource.ownerID == profile.id { return .allow }
        if capability != .manageSharing, resource.grants.contains(where: {
            $0.personID == profile.id && $0.capability == capability && $0.expiresAt > now
        }) { return .allow }
        return .requireOwnerApproval
    }
}

enum SpeechBackend: String, Codable, CaseIterable, Identifiable {
    case apple, kokoro, openAI, elevenLabs, cartesia
    var id: String { rawValue }
    var title: String {
        switch self { case .apple: return "Apple voices"; case .kokoro: return "Kokoro"; case .openAI: return "OpenAI"; case .elevenLabs: return "ElevenLabs"; case .cartesia: return "Cartesia" }
    }
    var isLocal: Bool { self == .apple || self == .kokoro }
    var detail: String {
        switch self {
        case .apple: return "Installed voices. Ready now."
        case .kokoro: return "Local neural voice. Model download and device testing still needed."
        case .openAI: return "Expressive speech or realtime conversation. Planned for a managed KemoSabe subscription; not connected yet."
        case .elevenLabs: return "Voice-focused streaming speech. Planned paid option; not connected yet."
        case .cartesia: return "Streaming speech with continuous prosody. Planned paid option; not connected yet."
        }
    }
}
/// Which reply voice may speak text of a given level. Each voice is a recipient (`RecipientID.voice`);
/// the person's cloud-voice opt-in is a grant for Personal text, never for Sensitive or beyond.
struct VoiceRoutingPolicy {
    var localOnly = true
    var cloudVoiceConsent = false
    func allows(_ backend: SpeechBackend, level: PrivacyLevel) -> Bool {
        let recipient = RecipientID.voice(backend: backend.rawValue, local: backend.isLocal)
        // A local voice speaks whatever the reply says; the reply itself already passed the policy.
        if backend.isLocal { return true }
        guard !localOnly, cloudVoiceConsent else { return false }
        let consent = RecipientGrant(recipient: recipient, kinds: [.message], purpose: "speech")
        return ContextPolicy.allows(.init(.init(.message, "reply"), level: level), to: recipient, purpose: "speech", grants: [consent])
    }
}

enum SpeechText {
    static func prepared(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"!\[([^\]]*)\]\(https?://[^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\(https?://[^)]+\)"#, with: "$1", options: .regularExpression)
        // Keep sentence punctuation outside a bare URL so the synthesizer still
        // receives the intended pause. Codes, decimals, and acronym punctuation
        // otherwise pass through untouched.
        value = value.replacingOccurrences(
            of: #"https?://[^\s<]*[^\s<.,!?;:)]"#,
            with: "the link",
            options: .regularExpression
        )
        value = value.replacingOccurrences(of: #"(?m)^[ \t]{0,3}(?:#{1,6}[ \t]+|>[ \t]?|[-+*•][ \t]+)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "")
            .replacingOccurrences(of: "`", with: "")
        value = value.replacingOccurrences(of: #"[ \t]*\n+[ \t]*"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
