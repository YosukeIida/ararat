import Testing
@testable import Ararat

@Test
func profileCloseWaitsForRestoration() {
    #expect(!ProfileCloseCheck.restorationReady(selected: "item", active: "other", request: nil))
    #expect(!ProfileCloseCheck.restorationReady(selected: nil, active: nil, request: nil))
    #expect(!ProfileCloseCheck.restorationReady(selected: "item", active: "item",
        request: (nil, false, false)))
    #expect(!ProfileCloseCheck.restorationReady(selected: "item", active: "item",
        request: ("command", false, false)))
    #expect(!ProfileCloseCheck.restorationReady(selected: "item", active: "item",
        request: ("command", true, false)))
    #expect(ProfileCloseCheck.restorationReady(selected: "item", active: "item",
        request: ("command", true, true)))
    #expect(ProfileCloseCheck.restorationReady(selected: "item", active: "item", request: nil))
}
