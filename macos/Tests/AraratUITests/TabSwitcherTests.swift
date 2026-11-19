import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func tabSwitcherCommitsThePreviousTabAndEscapeCanCancel() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: .titled, backing: .buffered, defer: false)
    let rows = (0..<3).map { index in
        Suggestion(title: "Tab \(index)", subtitle: "", url: "https://example.test/\(index)", key: nil,
                   target: .tab(id: "\(index)", spaceId: "space"), score: 0)
    }
    let first = TabSwitcher(parent: window, backwards: false, bindings: defaultKeyBindings(), accent: .systemTeal, favicon: { _ in nil })
    var selected: Suggestion?
    first.onSelect = { selected = $0 }
    first.commit()
    first.load(rows)
    #expect(selected?.target == rows[0].target)
    let second = TabSwitcher(parent: window, backwards: false, bindings: defaultKeyBindings(), accent: .systemTeal, favicon: { _ in nil })
    second.onSelect = { selected = $0 }
    second.load(rows)
    second.advance(backwards: false)
    #expect(second.selectedIndex == 1)
    second.cancel()
    #expect(selected?.target == rows[0].target)
    #expect(!second.isOpen)
    let third = TabSwitcher(parent: window, backwards: true, bindings: defaultKeyBindings(), accent: .systemTeal, favicon: { _ in nil })
    third.load(rows)
    #expect(third.selectedIndex == 2)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(!third.isOpen)
}

@Test @MainActor
func tabSwitcherCentersTheTilesOnTheWindowAndShowsReboundHintsBelow() throws {
    let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 1000, height: 700),
                          styleMask: .titled, backing: .buffered, defer: false)
    let page = NSView(frame: NSRect(x: 280, y: 30, width: 700, height: 620))
    window.contentView?.addSubview(page)
    var bindings = defaultKeyBindings()
    let next = try #require(bindings.firstIndex { $0.command == "cycle_tabs_next" })
    bindings[next].key = KeyCombination(key: "j", command: false, control: true, option: false, shift: false)
    let switcher = TabSwitcher(parent: window, backwards: false, bindings: bindings, accent: .systemTeal, favicon: { _ in nil })
    defer { switcher.cancel() }
    switcher.load((0..<6).map { index in
        Suggestion(title: "Tab \(index)", subtitle: "", url: nil, key: nil,
                   target: .tab(id: "\(index)", spaceId: "space"), score: 0)
    })
    let overlay = try #require(switcher.makeOverlay())
    let tiles = try #require(overlay.content.subviews.first)
    #expect(overlay.frame.minX + tiles.frame.midX == window.frame.midX)
    #expect(overlay.frame.minY + tiles.frame.midY == window.frame.midY)
    #expect(tiles.subviews.count == 5)
    let pills = Array(overlay.content.subviews.dropFirst())
    let hints = pills.flatMap(\.subviews).compactMap { $0 as? NSTextField }
    #expect(hints.map(\.stringValue) == ["⌃J Next", "⌃⇧Tab Previous", "Release ⌃ Switch", "Esc Cancel"])
    #expect(pills.allSatisfy { $0.frame.maxY < tiles.frame.minY })
    window.setContentSize(NSSize(width: 240, height: 700))
    let narrow = try #require(switcher.makeOverlay())
    #expect(narrow.frame.width <= window.frame.width)
    #expect(Set(narrow.content.subviews.dropFirst().map { $0.frame.minY }).count == 2)
}
