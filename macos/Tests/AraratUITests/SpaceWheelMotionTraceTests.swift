import Testing
import AppKit
@testable import AraratUI

@Test @MainActor
func wheelMotionTraceKeepsSamplesAndMarksOnTheSameSwitchClock() throws {
    let trace = SpaceWheelMotionTrace()
    trace.begin("settle 4->3")
    trace.mark("settleScroll", detail: "from=240 to=0")
    trace.sample([["page": "space-column", "offset": 240.0]], source: "display-link")
    trace.sample([["page": "space-column", "offset": 100.0]], source: "check-timer")
    #expect(trace.switches == 1)
    #expect(trace.marks.compactMap { $0["name"] as? String } == ["switch", "settleScroll"])
    #expect(trace.sampleCounts == ["display-link": 1, "check-timer": 1])
    let samples = trace.samples.compactMap { $0["t"] as? Double }
    #expect(samples.count == 2 && samples[0] >= 0 && samples[1] >= samples[0])
    trace.finish("test-complete")
    #expect(trace.start == nil)
    trace.mark("outside-switch")
    #expect(trace.marks.count == 3)
    trace.begin("next switch")
    #expect(trace.switches == 2 && trace.samples.isEmpty && trace.marks.count == 1)
    trace.finish("test-complete")
}

@Test @MainActor
func wheelMotionConditionsRejectTheMeasuredMissingStartAndRestarts() {
    typealias Frame = SpaceWheelMotionCurve.Frame
    let old = [Frame(t: 0.15, offset: 112), Frame(t: 0.18, offset: 60), Frame(t: 0.25, offset: 0)]
    #expect(SpaceWheelMotionCurve.conditions(frames: old, from: 260, pitch: 260)["first_frame_full_offset"] == false)
    let jump = [Frame(t: 0.01, offset: 260), Frame(t: 0.065, offset: 190), Frame(t: 0.1, offset: 0)]
    #expect(SpaceWheelMotionCurve.conditions(frames: jump, from: 260, pitch: 260)["no_late_jump"] == false)
    let restart = [Frame(t: 0.01, offset: 260), Frame(t: 0.03, offset: 200), Frame(t: 0.05, offset: 250), Frame(t: 0.3, offset: 0)]
    #expect(SpaceWheelMotionCurve.conditions(frames: restart, from: 260, pitch: 260)["monotone_approach"] == false)
    #expect(SpaceWheelMotionCurve.conditions(frames: [], from: 260, pitch: 260).values.allSatisfy { !$0 })
    let omega = 2 * Double.pi / SidebarMetrics.spaceSwitchResponse
    let decay = SidebarMetrics.spaceSwitchDamping * omega
    let frequency = sqrt(omega * omega - decay * decay)
    let frames = (0...36).map { index in
        let time = Double(index) / 60
        return Frame(t: time, offset: 260 * exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time)))
    }
    #expect(SpaceWheelMotionCurve.conditions(frames: frames, from: 260, pitch: 260).values.allSatisfy { $0 })
}

@Test @MainActor
func interruptedSwitchesDoNotHaveToLandButCompletedSwitchesDo() throws {
    let trace = SpaceWheelMotionTrace()
    trace.begin("first")
    trace.animationStarted(from: 240, pitch: 240, at: try #require(trace.start))
    trace.sample([["active": true, "animation": true, "offset": 240.0]], source: "check-timer")
    trace.finish("interrupted-by-next-switch")
    #expect(trace.conditions["first_frame_full_offset"] == true)
    #expect(trace.conditions["landed"] == nil)
    trace.begin("second")
    trace.animationStarted(from: 240, pitch: 240, at: try #require(trace.start))
    trace.sample([["active": true, "animation": true, "offset": 240.0]], source: "check-timer")
    trace.finish("check-complete")
    #expect(trace.conditions["landed"] == false)
}
