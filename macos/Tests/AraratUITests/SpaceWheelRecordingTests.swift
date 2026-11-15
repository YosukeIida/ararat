import AraratKit
import Foundation
import Testing
@testable import AraratUI

/// Arc's counts on the owner's trackball (2026-11-16), recorded with `scrollrec` on the host and
/// replayed into Arc with `scrollplay` (docs/research/arc-ardia-observed.md section 5). The
/// fixtures hold the recorded deltas, phases and timing only.
private func recording(_ name: String) throws -> [SpaceScrollRecordedEvent] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).txt")
    return SpaceScrollRecording.parse(try String(contentsOf: url, encoding: .utf8))
}

@Test
func recordingParserReadsTheScrollrecFields() throws {
    let line = Substring("3276.2 cont=0 line=0,-1 pt=0,-1 fix=0.00,-0.10 phase=0 mom=0 inv=1")
    let event = try #require(SpaceScrollRecording.parse(line: line))
    #expect(abs(event.time - 3.2762) < 0.0001)
    #expect(event.dx == -0.10 && event.dy == 0)
    #expect(event.phase == .none && !event.momentum && event.inverted && !event.precise)
    // The phases are CGScrollPhase's bits: a trackpad recording carries them.
    let began = try #require(SpaceScrollRecording.parse(line: Substring("10.0 cont=1 line=0,0 pt=0,-4 fix=0.00,-4.00 phase=1 mom=0 inv=0")))
    #expect(began.phase == .began && began.precise)
    let momentum = try #require(SpaceScrollRecording.parse(line: Substring("20.0 cont=1 line=0,0 pt=0,-4 fix=0.00,-4.00 phase=0 mom=2 inv=0")))
    #expect(momentum.momentum)
}

/// The two quick spins: one space each way, which is what Arc did with the same recording. The
/// ball turned right (negative fixed-point deltas) moves the page left in both.
@Test @MainActor
func trackballQuickSpinsMoveOneSpaceEachWay() throws {
    let events = try recording("quick")
    #expect(events.count == 26)
    let first = events.filter { $0.time < 5.0 }
    let second = events.filter { $0.time >= 5.0 }
    #expect(first.count == 15 && second.count == 11)
    let left = SpaceScrollReplay.run(first, from: 2, count: 4)
    #expect(left.steps.map(\.direction) == ["left"])
    #expect(left.index == 1)
    let right = SpaceScrollReplay.run(second, from: 1, count: 4)
    #expect(right.steps.map(\.direction) == ["right"])
    #expect(right.index == 2)
}

/// The slow steady turn: Arc moved four spaces left. The fourth step is the 2.02 event at
/// 5380 ms, 926 ms after the third; the 8.21 event at 4454 ms is 236 ms after the previous switch
/// and is ignored by the 250 ms pause, which is section 5's measured "230 ms after the switch was
/// ignored" case. The default direction (Natural) is Arc's, so no direction change is needed.
@Test @MainActor
func trackballSlowTurnMovesFourSpacesLikeArc() throws {
    let events = try recording("slow")
    let replay = SpaceScrollReplay.run(events, from: 4, count: 6)
    #expect(replay.steps.map(\.direction) == ["left", "left", "left", "left"])
    #expect(replay.index == 0)
    let times = replay.steps.map { $0.time }
    #expect(abs(times[0] - 3.6815) < 0.0001)
    #expect(abs(times[2] - 4.2182) < 0.0001)
    #expect(abs(times[3] - 5.3804) < 0.0001)
    // The strong event inside the pause is the one that does not step.
    #expect(!replay.steps.contains { abs($0.time - 4.4543) < 0.0001 })
}

/// Reversed turns both recordings around and keeps the counts; the direction is the setting, not
/// the rule.
@Test @MainActor
func reversedDirectionTurnsTheRecordedTrackballGesturesAround() throws {
    let slow = try recording("slow")
    let replay = SpaceScrollReplay.run(slow, from: 1, count: 6, direction: .reversed)
    #expect(replay.steps.map(\.direction) == ["right", "right", "right", "right"])
    #expect(replay.index == 5)
}
