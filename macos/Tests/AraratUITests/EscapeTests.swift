import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor private final class EscapeReceiver: NSResponder {
    var calls = 0
    override func cancelOperation(_ sender: Any?) { calls += 1 }
}

@Test @MainActor
func escapeActionDispatchClosesOverlaysAndForwardsWhenNothingIsOpen() throws {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    sidebar.layoutSubtreeIfNeeded()
    let receiver = EscapeReceiver()
    func escape() throws {
        #expect(window.makeFirstResponder(sidebar))
        sidebar.nextResponder = receiver
        #expect(NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: try #require(window.firstResponder), from: nil))
    }
    sidebar.setLibraryOpen(true)
    try escape()
    #expect(!sidebar.libraryOpen && receiver.calls == 0)
    sidebar.setCreateSpaceOpen(true)
    try escape()
    #expect(!sidebar.createSpaceOpen && receiver.calls == 0)
    let frame = sidebar.frame
    try escape()
    #expect(receiver.calls == 1)
    #expect(!sidebar.libraryOpen && !sidebar.createSpaceOpen && sidebar.selectedRowID == nil)
    #expect(sidebar.frame == frame && window.firstResponder === sidebar)
    #expect(!window.isVisible && !window.isKeyWindow && NSApp.keyWindow == nil)
}
