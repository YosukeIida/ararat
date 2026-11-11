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
    #expect(screen.failed.contains("wheel_mid") && screen.failed.contains("tint_initial"))
    #expect(!screen.failed.contains("follow_mid") && !screen.failed.contains("wheel_start"))
}
