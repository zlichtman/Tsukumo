import Foundation
import Testing
import TsukumoCore
@testable import TsukumoPolicy

/// The one policy (ported from the app's `ContextPolicyTests`): every level by every locality by
/// every kind of grant, grants spent and expired, labels a classifier can only raise, and metadata
/// filtered like content.
struct ContextPolicyTests {
    let now = Date(timeIntervalSince1970: 1_900_000_000)
    let profile = UUID()
    var api: RecipientID { .apiModel(profile: profile, host: "api.example.invalid") }
    var everyRecipient: [RecipientID] {
        [.appleOnDevice, .applePrivateCloud, api, .codingAgent("claude-code"), .acpAgent("gemini"),
         .externalAgent("com.example.agent"), .localModel("laya"), .iCloudSync, .systemOne("jev")]
    }

    func decide(_ item: PolicyItem, _ recipient: RecipientID, grants: [RecipientGrant], ceiling: PrivacyLevel? = nil) -> PolicyDenial? {
        ContextPolicy.evaluate([item], to: recipient, purpose: .conversation, grants: grants, ceiling: ceiling, now: now).denied[item]
    }

    @Test func everyRecipientHasALocalityAHostAndAStableKey() throws {
        let expected: [RecipientLocality] = [.onDevice, .appleCloud, .thirdPartyCloud, .thirdPartyCloud, .thirdPartyCloud,
                                             .thirdPartyCloud, .onDevice, .appleCloud, .thirdPartyCloud]
        #expect(everyRecipient.map(\.locality) == expected)
        #expect(Set(everyRecipient.map(\.key)).count == everyRecipient.count)
        #expect(everyRecipient.allSatisfy { !$0.host.isEmpty })
        for recipient in everyRecipient {
            #expect(RecipientID(key: recipient.key) == recipient)
            let data = try JSONEncoder().encode(recipient)
            #expect(try JSONDecoder().decode(RecipientID.self, from: data) == recipient)
        }
        #expect(RecipientID(key: "something-new") == nil)
        #expect(RecipientID(key: "coding:") == nil)
    }

    @Test func tableForEveryLevelLocalityAndGrant() {
        for recipient in everyRecipient {
            for level in PrivacyLevel.allCases {
                let item = PolicyItem(.note, UUID().uuidString, level: level)
                let plain = decide(item, recipient, grants: [])
                let itemGrant = decide(item, recipient, grants: [RecipientGrant(recipient: recipient, items: [item], purpose: .conversation)])
                let kindGrant = decide(item, recipient, grants: [RecipientGrant(recipient: recipient, kinds: [.note], purpose: .conversation)])
                let label = "\(level) to \(recipient.key)"
                switch (level, recipient.locality) {
                case (.secret, _):
                    #expect(plain == .secret, "\(label)"); #expect(itemGrant == .secret); #expect(kindGrant == .secret)
                case (.deviceOnly, .onDevice):
                    #expect(plain == nil, "\(label)")
                case (.deviceOnly, _):
                    #expect(plain == .staysOnDevice, "\(label)"); #expect(itemGrant == .staysOnDevice, "\(label): no grant opens it")
                case (.open, _), (_, .onDevice), (_, .appleCloud):
                    #expect(plain == nil, "\(label)")
                case (.personal, .thirdPartyCloud):
                    #expect(plain == .needsGrant, "\(label)"); #expect(itemGrant == nil); #expect(kindGrant == nil)
                case (.sensitive, .thirdPartyCloud):
                    #expect(plain == .needsGrant, "\(label)"); #expect(itemGrant == nil)
                    #expect(kindGrant == .needsGrant, "\(label): only a grant for the item itself")
                }
            }
        }
    }

    @Test func iCloudKeepsOnlyWhatMayLeaveTheDevice() {
        #expect(decide(PolicyItem(.note, "a", level: .sensitive), .iCloudSync, grants: []) == nil)
        #expect(decide(PolicyItem(.note, "b", level: .deviceOnly), .iCloudSync, grants: []) == .staysOnDevice)
        #expect(decide(PolicyItem(.note, "c", level: .secret), .iCloudSync, grants: []) == .secret)
    }

    @Test func grantsAreScopedToRecipientPurposeAndItems() {
        let item = PolicyItem(.file, "plans", level: .personal)
        let other = PolicyItem(.file, "other", level: .personal)
        let grant = RecipientGrant(recipient: api, items: [item], purpose: .conversation)
        let decision = ContextPolicy.evaluate([item, other], to: api, purpose: .conversation, grants: [grant], now: now)
        #expect(decision.allowed == [item])
        #expect(decision.denied == [other: .needsGrant])
        #expect(decision.grantsUsed == [grant.id])
        #expect(!ContextPolicy.allows(item, to: .externalAgent("someone-else"), grants: [grant], now: now))
        #expect(!ContextPolicy.allows(item, to: api, purpose: "speech", grants: [grant], now: now))
        // An API model's grant follows its profile even if its host is written differently.
        #expect(ContextPolicy.allows(item, to: .apiModel(profile: profile, host: ""), grants: [grant], now: now))
    }

    @Test func alwaysOnceAndExpiry() {
        let item = PolicyItem(.health, "m1", level: .sensitive)
        let expiring = RecipientGrant(recipient: api, items: [item], purpose: .conversation, expiresAt: now.addingTimeInterval(60))
        #expect(ContextPolicy.allows(item, to: api, grants: [expiring], now: now))
        #expect(!ContextPolicy.allows(item, to: api, grants: [expiring], now: now.addingTimeInterval(61)))
        #expect(RecipientGrants.pruned([expiring], now: now.addingTimeInterval(61)).isEmpty)

        var once = [RecipientGrant(recipient: api, items: [item], purpose: .conversation, singleUse: true)]
        let decision = ContextPolicy.evaluate([item], to: api, purpose: .conversation, grants: once, now: now)
        #expect(decision.permitsAll)
        RecipientGrants.spend(decision.grantsUsed, in: &once)
        #expect(once[0].used)
        #expect(!ContextPolicy.allows(item, to: api, grants: once, now: now), "Once covers one disclosure")
        #expect(RecipientGrants.pruned(once, now: now).isEmpty)

        var always = [RecipientGrant(recipient: api, items: [item], purpose: .conversation)]
        RecipientGrants.spend(always.map(\.id), in: &always)
        #expect(ContextPolicy.allows(item, to: api, grants: always, now: now), "Spending never touches a standing grant")
    }

    @Test func aCeilingOnlyTakesAway() {
        let personal = PolicyItem(.note, "p", level: .personal), sensitive = PolicyItem(.note, "s", level: .sensitive)
        #expect(decide(sensitive, .appleOnDevice, grants: [], ceiling: .personal) == .aboveCeiling)
        #expect(decide(personal, .appleOnDevice, grants: [], ceiling: .personal) == nil)
        // A generous ceiling never opens what the table closes.
        #expect(decide(PolicyItem(.note, "d", level: .deviceOnly), api, grants: [], ceiling: .secret) == .staysOnDevice)
        #expect(decide(personal, api, grants: [], ceiling: .secret) == .needsGrant)
    }

    @Test func kindFloorsAndAClassifierThatCanOnlyRaise() {
        #expect(TypeLabel(kind: .credential, level: .open).level == .deviceOnly)
        #expect(TypeLabel(kind: .textMessage, level: .open).level == .personal)
        #expect(TypeLabel(kind: .location, level: .open).level == .sensitive)
        #expect(TypeLabel(kind: .file, level: .open).level == .open)
        let label = TypeLabel(kind: .file, level: .personal)
        #expect(label.raised(by: .sensitive).level == .sensitive)
        #expect(label.raised(by: .open).level == .personal, "Never lowered")
        #expect(label.raised(by: nil) == label)
        #expect(TypeLabel.combining([label, TypeLabel(kind: .health, level: .open)], as: .personalAnswer).level == .sensitive)
    }

    @Test func savedLabelsBelowTheirFloorAreRaisedWhenRead() throws {
        let label = try JSONDecoder().decode(TypeLabel.self, from: Data(#"{"kind":"credential","level":"open"}"#.utf8))
        #expect(label.level == .deviceOnly)
        let future = try JSONDecoder().decode(TypeLabel.self, from: Data(#"{"kind":"hologram","level":"ultra"}"#.utf8))
        #expect(future.level == .secret && future.kind == "hologram")
    }

    @Test func metadataIsFilteredLikeContent() {
        struct Title { let item: PolicyItem; let text: String }
        let titles = [Title(item: PolicyItem(.file, "1", level: .open), text: "Roadmap"),
                      Title(item: PolicyItem(.file, "2", level: .deviceOnly), text: "Door codes"),
                      Title(item: PolicyItem(.file, "3", level: .personal), text: "Therapy notes")]
        #expect(ContextPolicy.filter(titles, item: \.item, to: api, now: now).map(\.text) == ["Roadmap"])
        #expect(ContextPolicy.filter(titles, item: \.item, to: .appleOnDevice, now: now).map(\.text) == ["Roadmap", "Door codes", "Therapy notes"])
    }

    @Test func grantsFromANewerBuildLoadAndMatchNothing() throws {
        let json = #"{"id":"8A3E6A1C-0B8B-4B7C-9E3E-4C3A8F0F0A11","recipient":"future:thing","kinds":["hologram"],"purpose":"conversation","extra":1}"#
        let grant = try JSONDecoder().decode(RecipientGrant.self, from: Data(json.utf8))
        #expect(!grant.singleUse && !grant.used && grant.items.isEmpty)
        #expect(!ContextPolicy.allows(PolicyItem(.note, "x", level: .personal), to: api, grants: [grant], now: now))
    }

    @Test func theLockShowsOnlyWhenNothingLeavesTheDevice() {
        #expect(everyRecipient.filter(ContextPolicy.keepsEverythingOnDevice).map(\.key) == ["apple-on-device", "local:laya"])
    }

    @Test func enginesMapToRecipients() {
        #expect(RecipientID.engine(.appleOnDevice) == .appleOnDevice)
        #expect(RecipientID.engine(.codingAgent("codex")) == .codingAgent("codex"))
        #expect(RecipientID.engine(.api(profile: profile), apiHost: "api.anthropic.com") == .apiModel(profile: profile, host: "api.anthropic.com"))
        #expect(RecipientID.engine(.mlx("qwen")) == .localModel("qwen"))
        #expect(RecipientID.engine(.unknown("?")) == nil)
    }
}
