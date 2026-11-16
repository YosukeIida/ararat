import AppKit
import Testing
import AraratKit
@testable import Ararat

@Test @MainActor
func wheelMotionReplayKeepsTheOwnersEventFieldsAndTiming() throws {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("AraratUITests/Fixtures")
    for name in ["quick", "slow"] {
        let text = try String(contentsOf: fixtures.appendingPathComponent("\(name).txt"), encoding: .utf8)
        let inputs = try SpaceWheelMotionCheck.recording(text)
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
        #expect(inputs.last!.time - inputs.first!.time < 3)
    }
}

@Test @MainActor
func wheelMotionCheckSeedsCoreEvenWhenRuntimeHasNoPublishedSnapshot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = Runtime(windowID: "wheel-start")
    let session = WorkspaceSession()
    session.queue.sync { session.store = try? WorkspaceStore.open(path: directory.appendingPathComponent("wheel.sqlite").path) }
    #expect(runtime.snapshot.spaces.count == 0)
    let seeded = try SpaceWheelMotionCheck.seed(session, windowID: runtime.windowID)
    #expect(seeded.spaces.count == 6)
    #expect(runtime.snapshot.spaces.count == 0)
    let again = try SpaceWheelMotionCheck.seed(session, windowID: runtime.windowID)
    #expect(again.spaces.map(\.id) == seeded.spaces.map(\.id))
    runtime.show(seeded)
    #expect(runtime.snapshot.spaces.count == 6)
}

@Test @MainActor
func wheelMotionRecordingGuardsNameTheirObservedValues() throws {
    let line = "1 cont=0 line=0,-1 pt=0,-1 fix=0,-1 phase=0 mom=0 inv=1"
    for (text, name) in [("", "recording_empty count=0"),
                         (line + "\n" + line.replacingOccurrences(of: "1 cont", with: "21002 cont"), "recording_span_seconds"),
                         (line + "\n" + line.replacingOccurrences(of: "1 cont", with: "0 cont"), "recording_order"),
                         (line.replacingOccurrences(of: "fix=0,-1", with: "fix=0,nan"), "recording_delta") ] {
        do {
            _ = try SpaceWheelMotionCheck.recording(text)
            Issue.record("Accepted \(name)")
        } catch {
            #expect(String(describing: error).contains(name))
        }
    }
}

@Test @MainActor
func wheelMotionReplayRejectsMalformedFields() {
    for text in ["nan cont=0", "1 cont=0", "1 cont=0 cont=1", "-1 cont=0"] {
        #expect(throws: (any Error).self) { try SpaceWheelMotionCheck.Input.parse(text) }
    }
}
