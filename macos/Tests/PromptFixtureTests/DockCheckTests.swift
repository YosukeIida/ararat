import Testing
@testable import Ararat

@Test @MainActor
func dockCheckDiagnosticsReportMissingAndFailedConditions() {
    let result = DockScreenCheck.conditionResults(["seed": true, "menu": false], screen: false)
    #expect(result.values["seed"] == true)
    #expect(!result.failed.contains("seed"))
    #expect(result.failed.contains("menu") && result.failed.contains("follow_mid"))
    #expect(result.failed.contains("wheel_start") && result.failed.contains("tint_initial"))
    #expect(!result.failed.contains("capture_mid"))
    let screen = DockScreenCheck.conditionResults([:], screen: true)
    #expect(["capture_cells", "capture_mid", "capture_refused"].allSatisfy { screen.failed.contains($0) })
    #expect(screen.failed.contains("wheel_mid") && screen.failed.contains("wheel_start") && screen.failed.contains("tint_initial"))
    #expect(!screen.failed.contains("follow_mid"))
}

@Test @MainActor
func dockCheckMidBandAndReadingTellNoAnimationFromNoFrames() {
    #expect(DockScreenCheck.midBand([0.5, 0.5, 0]))
    #expect(!DockScreenCheck.midBand([1, 0]))
    #expect(!DockScreenCheck.midBand([0.02, 0.98]))
    #expect(!DockScreenCheck.midBand([]))

    let check = DockScreenCheck()
    #expect(check.midReading == "no samples")
    check.midTrace = [["animation": false, "presentation": 0, "offset": 0, "fractions": [1.0, 0.0]]]
    #expect(check.midReading.contains("the paging did not animate"))
    check.midTrace = [["animation": true, "presentation": 0, "offset": 0, "fractions": [1.0, 0.0]]]
    #expect(check.midReading.contains("presents no frames"))
    check.midTrace = [["animation": true, "presentation": 120, "offset": 120, "fractions": [0.5, 0.5]]]
    #expect(check.midReading.contains("animation and frames seen"))
}
