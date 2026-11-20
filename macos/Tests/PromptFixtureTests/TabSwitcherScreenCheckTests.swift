import Testing
@testable import Ararat

@Test @MainActor func closeReadbackPendingOnFirstAttemptExercisesOrder() {
    #expect(TabSwitcherScreenCheck.CloseReadbackOrder(attempt: 1, statusAtClose: nil) == .exercised)
}

@Test @MainActor func closeReadbackPendingAfterFailureExercisesOrder() {
    #expect(TabSwitcherScreenCheck.CloseReadbackOrder(attempt: 1, statusAtClose: "failed") == .retry)
    #expect(TabSwitcherScreenCheck.CloseReadbackOrder(attempt: 2, statusAtClose: nil) == .exercised)
}

@Test @MainActor func closeReadbackFailingBeforeEveryCloseLeavesOrderUnverified() {
    #expect(TabSwitcherScreenCheck.CloseReadbackOrder(attempt: 1, statusAtClose: "failed") == .retry)
    #expect(TabSwitcherScreenCheck.CloseReadbackOrder(attempt: 2, statusAtClose: "failed") == .retry)
    #expect(TabSwitcherScreenCheck.CloseReadbackOrder(attempt: 3, statusAtClose: "failed") == .unverified)
}
