import Testing
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
