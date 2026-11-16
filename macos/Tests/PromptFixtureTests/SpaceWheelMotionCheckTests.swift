import AppKit
import Testing
@testable import Ararat

@Test @MainActor
func wheelMotionReplayKeepsTheOwnersEventFieldsAndTiming() throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AraratUITests/Fixtures")
    for name in ["quick", "slow"] {
        let text = try String(contentsOf: fixtures.appendingPathComponent("\(name).txt"), encoding: .utf8)
        let inputs = try SpaceWheelMotionCheck.Input.parse(text)
        #expect(!inputs.isEmpty)
        for input in inputs {
            let event = try #require(input.event(at: 100 + input.time))
            #expect(abs(event.timestamp - (100 + input.time)) < 0.000001)
            #expect(abs(event.scrollingDeltaX - input.fields[.scrollWheelEventFixedPtDeltaAxis2]!) < 0.001)
            #expect(abs(event.scrollingDeltaY - input.fields[.scrollWheelEventFixedPtDeltaAxis1]!) < 0.001)
            #expect(!event.hasPreciseScrollingDeltas && event.phase.isEmpty && event.momentumPhase.isEmpty)
            #expect(event.isDirectionInvertedFromDevice == (input.fields[CGEventField(rawValue: 137)!] == 1))
        }
        if name == "quick" {
            #expect(inputs.count == 26)
            #expect(abs(inputs[15].time - inputs[0].time - 1.8508) < 0.000001)
        }
    }
}

@Test @MainActor
func wheelMotionReplayRejectsMalformedFields() {
    for text in ["nan cont=0", "1 cont=0", "1 cont=0 cont=1", "-1 cont=0"] {
        #expect(throws: (any Error).self) { try SpaceWheelMotionCheck.Input.parse(text) }
    }
}
