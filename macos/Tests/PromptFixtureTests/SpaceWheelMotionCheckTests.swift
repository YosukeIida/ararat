import AppKit
import Testing
import AraratKit
import AraratUI
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

@Test @MainActor
func wheelMotionCheckContinuesAfterDrawnFailuresAndGatesOnlyPresentationAndReplay() async throws {
    let check = SpaceWheelMotionCheck()
    let presentation = ["first_frame_full_offset": true, "monotone_approach": true, "no_late_jump": true, "landed": true]
    for message in ["drawn_pattern_baseline", "drawn_capture_frames count=0", "capture start denied"] {
        await check.prepareCapture { throw SpaceWheelMotionCheck.Failure(description: message) }
        #expect(check.captureError == message)
        check.sent = 26
        check.expected = 26
        check.switches = [.init(time: 1, source: 4, target: 3, pitch: 260)]
        let report: [String: Any] = ["capture_error": check.captureError!, "conditions": ["first_frame_full_offset": false]]
        let result = check.result(presentation: presentation, drawnReport: report)
        #expect(result.ok)
        #expect((result.values["failed_conditions"] as? [String])?.isEmpty == true)
        #expect((result.values["drawn_report_only"] as? [String: Any])?["capture_error"] as? String == message)
        _ = try JSONSerialization.data(withJSONObject: result.values)
        for name in presentation.keys {
            var failed = presentation
            failed[name] = false
            let result = check.result(presentation: failed, drawnReport: [:])
            #expect(!result.ok)
            #expect(result.values["failed_conditions"] as? [String] == [name])
        }
    }
    check.sent -= 1
    #expect(!check.result(presentation: presentation, drawnReport: [:]).ok)
    check.sent = check.expected
    check.failed = true
    #expect(!check.result(presentation: presentation, drawnReport: [:]).ok)
    check.failed = false
    check.switches = []
    #expect(!check.result(presentation: presentation, drawnReport: [:]).ok)
    #expect(!check.result(presentation: [:], drawnReport: [:]).ok)
}

@Test(arguments: ["start", "stop"], [true, false])
@MainActor
func wheelMotionCheckFinishesOnPresentationWhileCaptureIsSuspended(stage: String, landed: Bool) async throws {
    let check = SpaceWheelMotionCheck()
    let presentation = ["first_frame_full_offset": true, "monotone_approach": true, "no_late_jump": true, "landed": landed]
    var suspended: CheckedContinuation<Void, Never>?
    var releaseCapture = false
    var result: (ok: Bool, values: [String: Any])?
    var readDrawnReport = false
    let run = Task { @MainActor in
        await check.prepareCapture(timeout: .milliseconds(20)) {
            if stage == "start", !releaseCapture { await withCheckedContinuation { suspended = $0 } }
        }
        check.sent = 1
        check.expected = 1
        check.switches = [.init(time: 1, source: 4, target: 3, pitch: 260)]
        result = await check.finish(presentation: presentation, timeout: .milliseconds(20), stopCapture: {
            if stage == "stop", !releaseCapture { await withCheckedContinuation { suspended = $0 } }
        }, drawnReport: {
            readDrawnReport = true
            return [:]
        })
    }

    let deadline = ContinuousClock.now + .seconds(1)
    while result == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    let finishedWhileSuspended = result
    let pendingCapture = suspended
    releaseCapture = true
    pendingCapture?.resume()
    await run.value

    #expect(pendingCapture != nil)
    let finished = try #require(finishedWhileSuspended)
    #expect(finished.ok == landed)
    #expect(finished.values["failed_conditions"] as? [String] == (landed ? [] : ["landed"]))
    #expect(finished.values["capture_stage"] as? String == stage)
    #expect(finished.values["capture_timeout"] as? Bool == true)
    #expect(finished.values["drawn_report_only"] is NSNull)
    #expect(!readDrawnReport)
    _ = try JSONSerialization.data(withJSONObject: finished.values)
}

@Test @MainActor
func presentationGateRejectsTheEarlyStartCurveEvenWhenDrawnResultsAreAbsent() {
    let check = SpaceWheelMotionCheck()
    check.sent = 1
    check.expected = 1
    check.switches = [.init(time: 0, source: 4, target: 3, pitch: 260)]
    let partial = [(0.1, 100.0), (0.18, 60.0), (0.25, 0.0)].map { SpaceWheelMotionCurve.Frame(t: $0, offset: $1) }
    let conditions = SpaceWheelMotionCurve.conditions(frames: partial, from: 260, pitch: 260)
    let result = check.result(presentation: conditions, drawnReport: [:])
    #expect(!result.ok)
    #expect((result.values["failed_conditions"] as? [String])?.contains("first_frame_full_offset") == true)
}
