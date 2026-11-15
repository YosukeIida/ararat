import AraratKit
import Foundation
@testable import AraratUI

/// One recorded scroll event, reduced to what the space classifier reads. The source format is
/// `scrollrec` (docs/research/yab/scrollrec.swift): a millisecond stamp and the CGEvent fields.
struct SpaceScrollRecordedEvent: Equatable {
    var time: TimeInterval
    /// The fixed-point deltas, axis 2 (horizontal) and axis 1 (vertical): the values
    /// `NSEvent.scrollingDeltaX/Y` return for a line-based wheel event.
    var dx: Double
    var dy: Double
    var phase: SpaceScrollEvent.Phase
    var momentum: Bool
    var inverted: Bool
}

/// Reads `scrollrec` output, so a recorded gesture can be fed to `SpaceScrollState` without the
/// event loop (Arc's counts on the owner's trackball, 2026-11-16). Test-only: the product never
/// parses a recording.
enum SpaceScrollRecording {
    static func parse(_ text: String) -> [SpaceScrollRecordedEvent] {
        text.split(separator: "\n").compactMap(parse(line:))
    }

    static func parse(line: Substring) -> SpaceScrollRecordedEvent? {
        var fields: [String: String] = [:]
        var stamp: Double?
        for token in line.split(separator: " ") {
            guard let equals = token.firstIndex(of: "=") else {
                stamp = Double(token)
                continue
            }
            fields[String(token[..<equals])] = String(token[token.index(after: equals)...])
        }
        guard let stamp, let fix = pair(fields["fix"]), let phase = Int(fields["phase"] ?? ""),
              let momentumPhase = Int(fields["mom"] ?? "") else { return nil }
        // Why the fixed-point pair: scrollplay re-posts every field, and NSEvent turns a
        // line-based event's fixed-point delta into scrollingDelta, which is what the classifier
        // and Arc both read. Axis 1 is vertical and axis 2 horizontal, as scrollrec prints them.
        return SpaceScrollRecordedEvent(
            time: stamp / 1000,
            dx: fix.1, dy: fix.0,
            phase: self.phase(phase),
            momentum: momentumPhase != 0,
            inverted: (fields["inv"] ?? "0") == "1")
    }

    private static func pair(_ value: String?) -> (Double, Double)? {
        guard let parts = value?.split(separator: ","), parts.count == 2,
              let first = Double(parts[0]), let second = Double(parts[1]) else { return nil }
        return (first, second)
    }

    /// CGScrollPhase's raw values, as `scrollrec` prints them.
    private static func phase(_ raw: Int) -> SpaceScrollEvent.Phase {
        if raw & 1 != 0 { return .began }
        if raw & 2 != 0 { return .changed }
        if raw & 4 != 0 { return .ended }
        if raw & 8 != 0 { return .cancelled }
        if raw & 128 != 0 { return .mayBegin }
        return .none
    }
}

extension SpaceScrollRecordedEvent {
    var event: SpaceScrollEvent {
        SpaceScrollEvent(dx: dx, dy: dy, phase: phase, momentum: momentum, inverted: inverted, time: time)
    }
}

/// The classifier's answer for a whole recorded sequence: the page it ends on, and the steps it
/// took, so a test can name Arc's counts and directions.
struct SpaceScrollReplay {
    struct Step: Equatable {
        var time: TimeInterval
        var from: Int
        var to: Int
        var direction: String { to > from ? "right" : to < from ? "left" : "none" }
    }

    var index: Int
    var steps: [Step]

    /// Feeds the sequence through `SpaceScrollState` the way the sidebar does: the state's answer
    /// moves the shown page, and the next event is classified against it.
    @MainActor
    static func run(_ events: [SpaceScrollRecordedEvent], from index: Int, count: Int,
                    pitch: Double = 180,
                    direction: SpaceScrollDirection = .natural) -> SpaceScrollReplay {
        var state = SpaceScrollState()
        var current = index
        var steps: [SpaceScrollReplay.Step] = []
        for event in events {
            let action = state.handle(event.event, index: current, count: count, pitch: pitch,
                                      direction: direction)
            if case .settle(let target, _, let switched) = action, switched,
               (0..<count).contains(target) {
                // The pull past either end targets -1 or count; keep the page for the next event.
                steps.append(Step(time: event.time, from: current, to: target))
                current = target
            }
        }
        return SpaceScrollReplay(index: current, steps: steps)
    }
}
