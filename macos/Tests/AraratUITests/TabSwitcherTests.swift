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
    let first = TabSwitcher(parent: window, backwards: false, favicon: { _ in nil })
    var selected: Suggestion?
    first.onSelect = { selected = $0 }
    first.commit()
    first.load(rows)
    #expect(selected?.target == rows[0].target)
    let second = TabSwitcher(parent: window, backwards: false, favicon: { _ in nil })
    second.onSelect = { selected = $0 }
    second.load(rows)
    second.advance(backwards: false)
    #expect(second.selectedIndex == 1)
    second.cancel()
    #expect(selected?.target == rows[0].target)
    #expect(!second.isOpen)
    let third = TabSwitcher(parent: window, backwards: true, favicon: { _ in nil })
    third.load(rows)
    #expect(third.selectedIndex == 2)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(!third.isOpen)
}
