import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// From the owner's iPhone on September 25, 2026: "Can you reuse a coffee filter that has been out"
/// came back as only "Prepared for review." The classifier had routed a plain question to a draft,
/// the validator dropped the unasked draft, and the reply was left as the note. Questions get
/// answers; only a message that asks for a change prepares one, and then the reply says what.
/// Shared by iPhone and Mac: every path (typed chat, the watch, Talk to Kemo, Tsukumo) routes here.
final class RoutingTests: XCTestCase {
    private typealias Choice = ConversationRouting.Choice
    private let changes: [ConversationRouting.Intent] = [.prepareDraft, .rememberInformation, .setAlarm, .planDay, .routinePreference]

    static let questions = [
        "Can you reuse a coffee filter that has been out",
        "Can you reuse a coffee filter that has been out?",
        "can you remind me what idempotent means",
        "Can you remind me what X means?",
        "Remind me again who wrote Dune?",
        "should I write a cover letter?",
        "Should I write to my landlord or call?",
        "What should I write in a birthday card?",
        "what time is it in Tokyo",
        "What time is it in Tokyo?",
        "Is it safe to leave rice out overnight?",
        "Do you remember what the capital of Australia is?",
        "Remember when phones had keyboards?",
        "How do I set an alarm on my Mac?",
        "Should I set an alarm for my flight?",
        "What's a good way to reply to a rude email?",
        "Can you dream",
        "Why do cats knead blankets",
        "How long does coffee keep after brewing?",
        "Hey Kemo, can you explain how noise cancelling works?",
        "Is a standup the same as a scrum?",
        "Can you reuse tea bags",
        "Who won the World Cup in 2014",
        "What's the best time to drink coffee?",
    ]
    static let requests: [(String, PlanAction)] = [
        ("remind me at 7 to call mom", .alarm),
        ("Remind me at 7 to call mom", .remember),
        ("Can you remind me to take out the trash at 8?", .alarm),
        ("remember that my sister's birthday is May 3", .remember),
        ("Please remember I'm allergic to peanuts", .remember),
        ("My locker code is 4512, remember that.", .remember),
        ("Don't forget my sister's birthday is May 3", .remember),
        ("draft an email to Sam about moving our meeting", .draft),
        ("Can you draft a thank-you note to Priya?", .draft),
        ("Hey Kemo, write a short reply to Jordan saying yes", .draft),
        ("Help me write a toast for my brother's wedding", .draft),
        ("I need an email to my landlord about the leak", .draft),
        ("Do my standup for today", .draft),
        ("Set an alarm for 6:30 tomorrow", .alarm),
        ("Wake me up at 7", .alarm),
        ("Could you set a timer for ten minutes?", .alarm),
        ("I'd like an alarm at 5 AM", .alarm),
    ]

    func testQuestionsNeverRouteToAChange() {
        for question in Self.questions {
            for intent in changes {
                let routed = ConversationRouting.guarded(Choice(intent: intent, contextUse: .newRequest), message: question)
                XCTAssertEqual(routed.intent, .answer, "\(intent) for “\(question)”")
                XCTAssertFalse(routed.preparesChange, question)
            }
            for kind in [PlanAction.draft, .remember, .alarm] {
                XCTAssertFalse(ExplicitRequest.allows(kind, in: question), "\(kind) for “\(question)”")
            }
        }
    }

    func testRealRequestsStillRoute() {
        for (message, kind) in Self.requests {
            XCTAssertTrue(ExplicitRequest.allows(kind, in: message), "\(kind) for “\(message)”")
            let intent: ConversationRouting.Intent = switch kind { case .draft: .prepareDraft; case .remember: .rememberInformation; case .alarm: .setAlarm }
            XCTAssertEqual(ConversationRouting.guarded(Choice(intent: intent, contextUse: .newRequest), message: message).intent, intent, message)
        }
        // Reminders and day plans go to the day planner when the classifier says so.
        for message in ["remind me at 7 to call mom", "Help me plan my day. Ask what you need to know first.", "Make time for the gym tomorrow",
                        "Move my focus block to the afternoon"] {
            XCTAssertEqual(ConversationRouting.guarded(Choice(intent: .planDay, contextUse: .newRequest), message: message).intent, .planDay, message)
        }
        for message in ["I usually work out in the evening", "Actually, mornings are better for writing", "I'd rather do email after 10"] {
            XCTAssertEqual(ConversationRouting.guarded(Choice(intent: .routinePreference, contextUse: .newRequest), message: message).intent,
                           .routinePreference, message)
        }
        XCTAssertEqual(ConversationRouting.guarded(Choice(intent: .routinePreference, contextUse: .newRequest),
                                                   message: "Do I usually wake up at 7?").intent, .answer)
        // A demoted change keeps whether it followed up on the conversation.
        XCTAssertEqual(ConversationRouting.guarded(Choice(intent: .prepareDraft, contextUse: .followUp), message: "Why?").contextUse, .followUp)
    }

    func testAnUnaskedDraftKeepsTheAnswerNotANote() throws {
        let now = Date()
        let request = PlanningRequest(message: "Can you reuse a coffee filter that has been out", history: [], memories: [], standupFormat: "", now: now)
        let plan = CompanionPlan(answer: "Paper filters aren't worth reusing: they hold oils and can grow mold.", actions: [
            .init(kind: .draft, title: "Coffee filter", content: "Paper filters aren't worth reusing.")])
        let proposals = try PlanValidator.proposals(plan, request: request, model: "test", currentNotes: [], now: now)
        XCTAssertTrue(proposals.isEmpty)
        let reply = PlanValidator.spokenReply(plan, proposals: proposals)
        XCTAssertEqual(reply, plan.answer)
        XCTAssertFalse(reply.contains("review"))
    }

    func testAPreparedChangeSaysWhatInOneLine() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let zone = TimeZone(identifier: "America/Chicago")!
        let draftRequest = PlanningRequest(message: "Draft an email to Sam about Friday", history: [], memories: [], standupFormat: "", now: now, timeZone: zone)
        let draft = CompanionPlan(answer: "Hi Sam, …", actions: [.init(kind: .draft, title: "Email to Sam", content: "Hi Sam, can we move Friday?")])
        let drafted = try PlanValidator.proposals(draft, request: draftRequest, model: "test", currentNotes: [], now: now)
        XCTAssertEqual(PlanValidator.spokenReply(draft, proposals: drafted), "I drafted “Email to Sam” for you to review in Day.")

        let memoryRequest = PlanningRequest(message: "Remember that my sister's birthday is May 3", history: [], memories: [], standupFormat: "", now: now)
        let memory = CompanionPlan(answer: "", actions: [.init(kind: .remember, title: "Memory suggestion", content: "Sister's birthday is May 3", memoryScope: "Personal")])
        let remembered = try PlanValidator.proposals(memory, request: memoryRequest, model: "test", currentNotes: [], now: now)
        XCTAssertEqual(PlanValidator.spokenReply(memory, proposals: remembered), "I’ll remember “Sister's birthday is May 3” once you approve it in Day.")

        let alarmRequest = PlanningRequest(message: "Wake me at 7", history: [], memories: [], standupFormat: "", now: now, timeZone: zone)
        let alarm = CompanionPlan(answer: "Done!", actions: [.init(kind: .alarm, title: "Alarm", content: "Requested alarm",
                                                                   alarmTime: ISO8601DateFormatter().string(from: now + 3600))])
        let alarms = try PlanValidator.proposals(alarm, request: alarmRequest, model: "test", currentNotes: [], now: now)
        let line = PlanValidator.spokenReply(alarm, proposals: alarms, timeZone: zone)
        XCTAssertTrue(line.hasPrefix("Your alarm for ") && line.hasSuffix(" is ready to approve in Day."), line)
        XCTAssertFalse(line.contains("Done!"))

        for reply in [PlanValidator.spokenReply(draft, proposals: drafted), PlanValidator.spokenReply(memory, proposals: remembered), line] {
            XCTAssertNotEqual(reply, "Prepared for review.")
            XCTAssertFalse(reply.contains("\n"))
        }
    }
}
