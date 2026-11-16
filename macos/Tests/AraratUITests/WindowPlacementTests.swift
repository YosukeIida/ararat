import AppKit
import Testing
import AraratKit
@testable import AraratUI

@Test func restoredFramesStayOnAnAvailableScreen() {
    let main = NSRect(x: 0, y: 24, width: 1440, height: 876)
    let left = NSRect(x: -1280, y: 0, width: 1280, height: 800)
    let frame = NSRect(x: -1200, y: 100, width: 1000, height: 650)
    #expect(WindowPlacement.clamped(frame, screens: [main, left], main: main) == frame)
    #expect(WindowPlacement.clamped(frame, screens: [main], main: main) == NSRect(x: 0, y: 100, width: 1000, height: 650))
    #expect(WindowPlacement.clamped(NSRect(x: 1300, y: -200, width: 2000, height: 1200), screens: [main], main: main) == main)
    #expect(!WindowPlacement.valid(.zero))
    #expect(!WindowPlacement.valid(NSRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)))
}

@Test @MainActor func sidebarRestoresEachPresentationMode() {
    var state = SidebarState()
    state.restore(hidden: true, floating: false)
    #expect(state.mode == .hidden)
    state.restore(hidden: false, floating: true)
    #expect(state.mode == .floating)
    state.restore(hidden: false, floating: false)
    #expect(state.mode == .docked)
}

@Test @MainActor func crashRecoveryWaitsForEveryRestoredWorkspace() {
    let session = WorkspaceSession()
    var completions = 0
    session.finishCrashRecovery = { completions += 1 }
    session.restoringWindows = ["first", "second", "third"]
    session.finishedRestoring(window: "second")
    session.finishedRestoring(window: "second")
    session.finishedRestoring(window: "unrelated")
    session.finishedRestoring(window: "first")
    #expect(completions == 0)
    session.finishedRestoring(window: "third")
    session.finishedRestoring(window: "third")
    #expect(completions == 1)
}
