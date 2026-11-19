import AraratKit
import Testing
@testable import Ararat

@Test @MainActor
func headerCheckWaitsForTheLoadedSeedHeader() {
    let check = HeaderCheck()
    check.id = "seed"
    let url = "https://seed.example/"
    let wait = "header showing the loaded seed tab"

    #expect(check.seedHeaderWait(loading: false, liveId: "live", url: url) == wait)
    check.headerTab = LiveTab(offTheRecord: false, profile: .default, liveId: "live", item: "other",
                              opener: nil, navigated: false, url: url, title: nil)
    #expect(check.seedHeaderWait(loading: false, liveId: "live", url: url) == wait)
    check.headerTab?.item = "seed"
    #expect(check.seedHeaderWait(loading: false, liveId: "other-live", url: url) == wait)
    #expect(check.seedHeaderWait(loading: false, liveId: "live", url: "https://other.example/") == wait)
    #expect(check.seedHeaderWait(loading: true, liveId: "live", url: url) == wait)
    #expect(check.seedHeaderWait(loading: false, liveId: "live", url: url) == nil)
}
