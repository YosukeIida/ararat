import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func libraryHistoryKeepsPageWheelAndCorrectedDeltaSwipeWorking() async throws {
    _ = NSApplication.shared
    let spaces = (0..<2).map { SpaceSnapshot(profileName: "Default", id: "s\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: []) }
    let archive = (0..<100).map { ArchiveEntry(id: "a\($0)", title: "Entry \($0)", url: "https://example.com", lifecycleChangedAt: UInt64($0)) }
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: archive, shownSpaceId: "s0", selectedId: nil, spaces: spaces))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [], backing: .buffered, defer: false)
    window.contentView = container
    defer { window.contentView = nil }
    container.resizeHandle.sidebarWidth = 332
    container.layoutSubtreeIfNeeded()
    var time = 100.0
    func send(x: CGFloat, dx: Int32, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase? = nil) async throws {
        time += 0.01
        let point = sidebar.convert(NSPoint(x: x, y: 350), to: nil)
        let event = CGEvent(scrollWheelEvent2Source: nil, units: phase == nil ? .line : .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        let screen = window.convertPoint(toScreen: point)
        event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        if phase != nil {
            event.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1)
            event.setDoubleValueField(CGEventField(rawValue: 94)!, value: Double(dx))
            event.setIntegerValueField(CGEventField(rawValue: 12)!, value: Int64(dx))
            event.setDoubleValueField(CGEventField(rawValue: 97)!, value: Double(dx))
        }
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum?.rawValue ?? 0))
        event.timestamp = UInt64(time * 1_000_000_000)
        let hit = try #require(window.contentView?.hitTest(point))
        let nsEvent = try #require(NSEvent(cgEvent: event))
        #expect(nsEvent.scrollingDeltaX == CGFloat(dx))
        hit.scrollWheel(with: nsEvent)
        try await Task.sleep(for: .milliseconds(16))
    }
    func swipe(x: CGFloat, dx: Int32, count: Int) async throws {
        try await send(x: x, dx: 0, phase: .began)
        for _ in 0..<count { try await send(x: x, dx: dx, phase: .changed) }
        try await send(x: x, dx: 0, phase: .ended)
    }
    try await swipe(x: 150, dx: 15, count: 20)
    let library = try #require(sidebar.subviews.compactMap { $0 as? LibraryView }.first)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    #expect(sidebar.libraryOpen)
    try await send(x: 150, dx: -3)
    try await send(x: 20, dx: 3)
    time += 1
    try await send(x: 20, dx: -3)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    try await swipe(x: 150, dx: 15, count: 20)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    try await swipe(x: 20, dx: 10, count: 4)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    try await swipe(x: 20, dx: -10, count: 3)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    #expect(!sidebar.libraryOpen && sidebar.spaceShown == 0)
    try await swipe(x: 150, dx: 15, count: 20)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    try await swipe(x: 200, dx: -15, count: 20)
    try await send(x: 200, dx: -7, momentum: .begin)
    for _ in 0..<3 { try await send(x: 200, dx: -5, momentum: CGMomentumScrollPhase(rawValue: 2)!) }
    try await send(x: 200, dx: 0, momentum: .end)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    try await send(x: 20, dx: 0, phase: .began)
    for i in 0..<12 { try await send(x: i == 0 ? 20 : 200, dx: -15, phase: .changed) }
    try await send(x: 200, dx: 0, phase: .ended)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    time += 1
    try await send(x: 150, dx: -3)
    #expect(sidebar.spaceShown == 1)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    sidebar.showSpace(at: 1)
    try await swipe(x: 150, dx: 15, count: 20)
    try await waitUntil { library.layer?.animation(forKey: "space.scroll") == nil }
    #expect(sidebar.spaceShown == 0 && !sidebar.libraryOpen)
    #expect(!window.isVisible)
}
