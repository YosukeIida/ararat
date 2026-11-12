import Testing
@testable import Ararat

@Test @MainActor func splitFocusCheckReportsMissingAndFailedConditions() {
    let check = SplitFocusCheck()
    check.mark("seed")
    check.mark("ring_a", false)
    let ordinary = check.diagnostics(screen: false)
    let failed = ordinary["failed_conditions"] as? [String] ?? []
    #expect(!failed.contains("seed"))
    #expect(failed.contains("ring_a"))
    #expect(failed.contains("divider_drag_frozen"))
    #expect(!failed.contains("capture_a"))
    let screen = check.diagnostics(screen: true)
    #expect((screen["failed_conditions"] as? [String] ?? []).contains("capture_a"))
}
