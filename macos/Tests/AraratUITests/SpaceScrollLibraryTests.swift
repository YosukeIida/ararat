import AppKit
import AraratKit
import Testing
@testable import AraratUI

@MainActor
private struct LibraryScrollFixture {
    let window: NSWindow
    let sidebar: SidebarView
    let scroll: NSScrollView

    init(space: Int, floating: Bool) throws {
        _ = NSApplication.shared
        let spaces = (0..<4).map {
            SpaceSnapshot(id: "space-\($0)", title: "Space \($0)", icon: nil, favorites: [], pinned: [], today: [])
        }
        sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "space-\(space)", selectedId: nil, spaces: spaces))
        let container = SidebarContainerView(sidebar: sidebar, page: NSView())
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720), styleMask: [], backing: .buffered, defer: false)
        window.contentView = container
        if floating { container.toggleSidebar() }
        container.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        scroll = try #require(libraryScrollDescendants(sidebar).compactMap { $0 as? NSScrollView }.first)
        #expect(!window.isVisible)
    }

    func send(_ dx: Int32, phase: CGScrollPhase?, time: Double) {
        let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        cg.timestamp = UInt64(time * 1_000_000_000)
        scroll.scrollWheel(with: NSEvent(cgEvent: cg)!)
    }

    func expectLibraryAbsent() {
        #expect(libraryScrollDescendants(sidebar).allSatisfy { !($0 is LibraryView) })
        #expect(!sidebar.libraryOpen)
        #expect(!window.isVisible)
    }
}

@MainActor
private func libraryScrollDescendants(_ view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + libraryScrollDescendants($0) }
}

@MainActor
private func checkOrdinarySpaceSwitch(from source: Int, to target: Int, floating: Bool, wheel: Bool) async throws {
    let fixture = try LibraryScrollFixture(space: source, floating: floating)
    defer { fixture.window.contentView = nil }
    let direction: Int32 = target > source ? -1 : 1
    fixture.expectLibraryAbsent()
    if wheel { fixture.send(direction * 5, phase: nil, time: 100) }
    else {
        fixture.send(direction * 40, phase: .began, time: 100)
        fixture.expectLibraryAbsent()
        fixture.send(direction * 280, phase: .changed, time: 100.02)
        fixture.expectLibraryAbsent()
        fixture.send(0, phase: .ended, time: 100.04)
    }
    fixture.expectLibraryAbsent()
    #expect(fixture.sidebar.spaceShown == target)
    for _ in 0..<50 {
        try await Task.sleep(for: .milliseconds(10))
        fixture.window.displayIfNeeded()
        CATransaction.flush()
        fixture.expectLibraryAbsent()
        #expect(fixture.sidebar.spaceShown == target)
    }
}

@Test @MainActor
func ordinarySpaceSwitchesNeverAttachLibrary() async throws {
    for floating in [false, true] {
        for wheel in [false, true] {
            for (source, target) in [(0, 1), (1, 2), (1, 0)] {
                try await checkOrdinarySpaceSwitch(from: source, to: target, floating: floating, wheel: wheel)
            }
        }
    }
}

@Test @MainActor
func switchesBeyondFirstSpaceNeverAttachLibraryInEitherDirection() async throws {
    for floating in [false, true] {
        for wheel in [false, true] {
            for (source, target) in [(1, 2), (2, 1)] {
                try await checkOrdinarySpaceSwitch(from: source, to: target, floating: floating, wheel: wheel)
            }
        }
    }
}

@Test @MainActor
func longDragPlacesLibraryAtItsAbsolutePageIndex() throws {
    for floating in [false, true] {
        let fixture = try LibraryScrollFixture(space: 1, floating: floating)
        defer { fixture.window.contentView = nil }
        fixture.send(400, phase: .began, time: 100)
        fixture.expectLibraryAbsent()
        fixture.send(200, phase: .changed, time: 100.02)
        let library = try #require(libraryScrollDescendants(fixture.sidebar).compactMap { $0 as? LibraryView }.first)
        #expect(abs(try #require(library.layer).transform.m41 - (-180)) < 0.01)
        #expect(!fixture.sidebar.libraryOpen)
    }
}
