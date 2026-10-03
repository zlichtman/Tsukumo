import XCTest
@testable import KemoSabe

final class ArtworkMotionTests: XCTestCase {
    func testWritingFacesKemoAndUsesSeparatedPhrases() {
        let phrases = WritingMotion.strokes(for: .writing)
        XCTAssertEqual(phrases.count, 6)
        for stroke in phrases {
            XCTAssertGreaterThan(stroke.point(0).x, stroke.point(1).x)
        }
        for time in [1.3, 2.4, 3.9, 5.2, 6.35] {
            XCTAssertFalse(WritingMotion.pose(at:time).penDown)
        }
        XCTAssertGreaterThan(WritingMotion.pagePoint(CGPoint(x:0.5,y:0.70)).y,
                             WritingMotion.pagePoint(CGPoint(x:0.5,y:0.78)).y)
    }
    func testAcknowledgmentsDoNotRestartAndListeningHasNoProps() {
        XCTAssertEqual(ArtworkPerformance.listening.prop, .none)
        XCTAssertEqual(ArtworkPerformance.remembering.prop, .none)
        for action in ArtworkPerformance.allCases where action.isReaction {
            let pose = action.pose(at:13)
            XCTAssertEqual(pose.left, .zero, action.rawValue)
            XCTAssertEqual(pose.right, .zero, action.rawValue)
            XCTAssertEqual(pose.y, 0, action.rawValue)
        }
    }
    func testEveryPoseIsFiniteAndPawsStayWithinChoreographyEnvelope() {
        for p in ArtworkPerformance.allCases {
            for t in stride(from:0.0,through:24.0,by:1.0/60) {
                let pose=p.pose(at:t,bpm:180,level:1)
                for value in [pose.x,pose.y,pose.tilt,pose.stretch,pose.left.x,pose.left.y,pose.right.x,pose.right.y,pose.eyelids] {
                    XCTAssertTrue(value.isFinite,p.rawValue)
                }
                XCTAssertLessThanOrEqual(abs(pose.left.x),0.20,p.rawValue)
                XCTAssertLessThanOrEqual(abs(pose.right.x),0.20,p.rawValue)
                XCTAssertTrue((-0.30...0.10).contains(pose.left.y),p.rawValue)
                XCTAssertTrue((-0.30...0.10).contains(pose.right.y),p.rawValue)
            }
        }
    }
    func testReactionsSettleAtTheLoopBoundary() {
        for p in ArtworkPerformance.allCases where p.isReaction {
            let a=p.pose(at:11.9999),b=p.pose(at:12.0001)
            XCTAssertEqual(a.left.x,b.left.x,accuracy:0.0001,p.rawValue)
            XCTAssertEqual(a.right.y,b.right.y,accuracy:0.0001,p.rawValue)
            XCTAssertEqual(a.eyelids,b.eyelids,accuracy:0.0001,p.rawValue)
        }
        XCTAssertEqual(ArtworkPerformance.musicPause.pose(at:12.2).y,0,accuracy:0.000001)
    }
    func testWritingLiftsBetweenWordsAndWristFollowsContact() {
        for time in [3.9, 8.0] {
            XCTAssertFalse(WritingMotion.pose(at: time).penDown)
        }
        for time in stride(from: 0.5, to: 7.8, by: 0.05) {
            let pose = WritingMotion.pose(at: time)
            if pose.penDown {
                XCTAssertEqual(pose.rotation, WritingMotion.wristAngle(at: pose.tip), accuracy: 0.000001)
            }
        }
    }
    func testAllNotebookActionsKeepInkAtContactAndOnPaper() throws {
        for item in ArtworkPerformance.allCases where item.rig == .notebook {
            for t in stride(from: 0.0, to: WritingMotion.duration, by: 0.04) {
                let p = WritingMotion.pose(at: t, performance: item)
                if p.penDown {
                    let last = try XCTUnwrap(p.ink.last(where: { !$0.isEmpty })?.last)
                    XCTAssertEqual(p.tip.x, last.x, accuracy: 0.000001, item.rawValue)
                    XCTAssertEqual(p.tip.y, last.y, accuracy: 0.000001, item.rawValue)
                    XCTAssertTrue((0.425...0.625).contains(last.x), item.rawValue)
                    XCTAssertTrue((0.740...0.789).contains(last.y), item.rawValue)
                }
            }
        }
    }
    func testMusicUsesTempoNotArbitraryWallClock() {
        let slow = ArtworkPerformance.beat.pose(at: 0.13, bpm: 60)
        let fast = ArtworkPerformance.beat.pose(at: 0.065, bpm: 120)
        XCTAssertEqual(slow.y, fast.y, accuracy: 0.000001)
        XCTAssertNotEqual(slow.y, ArtworkPerformance.beat.pose(at: 0.13, bpm: 120).y)
    }
    func testReadingReducedMotionAndLoop() {
        XCTAssertEqual(ReadingMotion.turn(at: 7, performance: .reading, reducedMotion: true), 0)
        XCTAssertEqual(ReadingMotion.turn(at: ReadingMotion.duration, performance: .reading, reducedMotion: false), 0)
        XCTAssertGreaterThan(ReadingMotion.turn(at: 6.6, performance: .reading, reducedMotion: false), 0)
    }
    func testLibraryHasExplicitRigsAndProps() {
        XCTAssertEqual(ArtworkPerformance.dj.rig, .musicDesk)
        XCTAssertEqual(ArtworkPerformance.piano.rig, .musicDesk)
        XCTAssertEqual(Set(Performance.all.map(\.id)), ArtworkCompanion.previewIDs)
        for p in [ArtworkPerformance.coding, .debugging, .testing, .codeReview, .deploying] { XCTAssertEqual(p.rig, .computer) }
        for p in [ArtworkPerformance.beat, .headphoneListen, .dance, .conducting] { XCTAssertEqual(p.prop, .headphones) }
        XCTAssertEqual(ArtworkPerformance.filing.prop, .files)
        XCTAssertEqual(ArtworkPerformance.sipping.prop, .mug)
        XCTAssertEqual(ArtworkPerformance.countdown.prop, .timer)
    }
    func testInstrumentContactUsesTempoAndStaysWithinDesk() {
        XCTAssertEqual(MusicDeskMotion.beats(2,bpm:60),MusicDeskMotion.beats(1,bpm:120))
        for p in [ArtworkPerformance.dj,.piano] {
            for beat in stride(from:0.0,to:32,by:0.05) {
                for right in [false,true] {
                    let hand = MusicDeskMotion.hand(p,beat:beat,right:right)
                    XCTAssertTrue((0.23...0.77).contains(hand.x))
                    XCTAssertTrue((0.65...0.79).contains(hand.y))
                }
            }
        }
    }
    func testTypingAndWatchingAreNotTheSameGesture() {
        XCTAssertGreaterThan(DeskMotion.typing(.coding, at: 3), 0)
        XCTAssertEqual(DeskMotion.typing(.testing, at: 3), 0)
        XCTAssertEqual(DeskMotion.typing(.codeReview, at: 3), 0)
        XCTAssertEqual(DeskMotion.typing(.debugging, at: 3), 0)
        XCTAssertGreaterThan(DeskMotion.typing(.debugging, at: 8), 0)
        for t in stride(from: 0.0, to: 12.0, by: 0.04) {
            XCTAssertTrue((0...0.013).contains(DeskMotion.keyLift(.coding, at: t, right: true)))
        }
    }
    func testReducedMotionDisablesChoreography() {
        for performance in ArtworkPerformance.allCases {
            let pose = performance.pose(at: 4, reducedMotion: true)
            XCTAssertEqual(pose.left, .zero); XCTAssertEqual(pose.right, .zero); XCTAssertEqual(pose.stretch, 0)
        }
    }
    func testTurningLeafStaysBelowFaceAndAttachedToGutter() {
        for turn in stride(from: 0.0, through: 1.0, by: 0.02) {
            let hinge = ReadingMotion.pagePoint(u: 0, v: 0, turn: turn)
            XCTAssertEqual(hinge.x, 0.5, accuracy: 0.000001)
            XCTAssertEqual(hinge.y, 0.706, accuracy: 0.000001)
            for u in stride(from: 0.0, through: 1.0, by: 0.02) {
                XCTAssertGreaterThan(ReadingMotion.pagePoint(u: u, v: 0, turn: turn).y, 0.60)
            }
        }
    }
}
