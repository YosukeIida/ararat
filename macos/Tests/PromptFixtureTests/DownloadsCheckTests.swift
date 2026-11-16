import Testing
@testable import Ararat

@Test @MainActor func downloadsCheckReportsEveryMissingConditionAndUnverifiedPath() {
    let check = DownloadsCheck()
    check.mark("seed")
    let ordinary = check.diagnostics(screen: false)
    let conditions = ordinary["conditions"] as? [String: Bool] ?? [:]
    let failed = ordinary["failed_conditions"] as? [String] ?? []
    #expect(conditions["seed"] == true)
    #expect(!failed.contains("seed"))
    #expect(failed.contains("resume"))
    for name in ["pause", "paused_bytes_stopped", "paused_completion", "search_name", "search_url", "search_empty", "clear_keeps_running", "private_clear_isolated", "drag_popover", "drag_page"] {
        #expect(failed.contains(name))
    }
    #expect(!failed.contains("capture_ring"))
    let screen = check.diagnostics(screen: true)
    #expect((screen["failed_conditions"] as? [String] ?? []).contains("capture_ring"))
    #expect(!(screen["unverified"] as? [String] ?? []).isEmpty)
}
