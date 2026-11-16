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
    let straddling = NSRect(x: -100, y: 100, width: 1000, height: 650)
    #expect(WindowPlacement.clamped(straddling, screens: [left, main], main: left) == NSRect(x: 0, y: 100, width: 1000, height: 650))
    #expect(!WindowPlacement.valid(.zero))
    #expect(!WindowPlacement.valid(NSRect(x: CGFloat.infinity, y: 0, width: 100, height: 100)))
}

@Test @MainActor func sidebarPersistsHiddenThroughTransientRevealAndFullscreen() {
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    var saves = 0
    container.onPresentationChanged = { saves += 1 }
    container.resizeHandle.sidebarWidth = 280
    #expect(saves > 0)
    #expect(container.savedPresentation.sidebarWidth == 280)
    container.toggleSidebar()
    #expect(container.sidebarState == "floating")
    #expect(container.savedPresentation.sidebarHidden)
    container.windowFullscreen = true
    #expect(container.savedPresentation.sidebarHidden)
    container.windowFullscreen = false
    container.restorePresentation(WindowPresentation(frame: nil, sidebarWidth: 250, sidebarHidden: true))
    #expect(container.sidebarState == "hidden")
    container.restorePresentation(WindowPresentation(frame: nil, sidebarWidth: 250, sidebarHidden: false))
    #expect(container.sidebarState == "docked")
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

@Test @MainActor func failedRestoredChildDoesNotBlockCrashRecovery() {
    let session = WorkspaceSession()
    var completions = 0
    session.finishCrashRecovery = { completions += 1 }
    session.restoringWindows = ["root", "failed-child", "last-child"]
    session.finishedRestoring(window: "failed-child")
    session.finishedRestoring(window: "root")
    #expect(completions == 0)
    session.finishedRestoring(window: "last-child")
    session.finishedRestoring(window: "failed-child")
    #expect(completions == 1)
}
