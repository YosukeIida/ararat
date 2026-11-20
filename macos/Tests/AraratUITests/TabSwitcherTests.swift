import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func unloadedPrivateSwitcherRowUsesGlobeWithoutRequestingSavedFavicon() async throws {
    let session = WorkspaceSession()
    let windowID = "private-switcher"
    let previousURL = "https://previous.example/"
    let currentURL = "https://current.example/"
    let previous = try session.queue.sync {
        let store = WorkspaceStore.openPrivate(profile: .default)
        session.store = store
        let opened = try store.createTab(windowId: windowID, url: previousURL)
        let previous = try #require(opened.selectedId)
        #expect(opened.spaces.flatMap(\.today).first { $0.id == previous }?.unloaded == false)
        let selected = try store.createTab(windowId: windowID, url: currentURL)
        let current = try #require(selected.selectedId)
        let live = LiveTab(offTheRecord: true, profile: .default, liveId: "current-live", item: current,
                           opener: nil, navigated: true, url: currentURL, title: "Current")
        let outcome = try store.liveApply(transaction: LiveTransaction(offTheRecord: true, epoch: 1, rev: 0,
            cause: .chrome, strips: [LiveStrip(window: windowID, tabs: [live], active: live.liveId)]))
        #expect(outcome.applied)
        let snapshot = store.snapshot(windowId: windowID)
        #expect(snapshot.spaces.flatMap(\.today).first { $0.id == previous }?.unloaded == true)
        #expect(store.liveTab(item: previous) == nil)
        return previous
    }

    let workspace = WorkspaceAdapter(windowID: windowID, session: session, private: true)
    let recent: (rows: [Suggestion], unloaded: [String: String]) = try await withCheckedThrowingContinuation { continuation in
        workspace.recentTabs { continuation.resume(with: $0) }
    }
    #expect(recent.unloaded.isEmpty)
    let row = try #require(recent.rows.first {
        if case .tab(let id, _) = $0.target { return id == previous }
        return false
    })
    #expect(row.url == previousURL)

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                          styleMask: .titled, backing: .buffered, defer: false)
    let savedIcon = try #require(NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil))
    let switcher = TabSwitcher(parent: window, backwards: false, bindings: [], accent: .systemTeal,
                               favicon: { recent.unloaded[$0] == nil ? nil : savedIcon }, schedule: { _, _ in })
    defer { switcher.cancel() }
    switcher.load([row])
    let overlay = try #require(switcher.makeOverlay())
    let preview = try #require(overlay.content.subviews.first?.subviews.first?.subviews.first)
    let image = try #require(preview.subviews.first as? NSImageView)
    let globe = try #require(NSImage(systemSymbolName: "globe", accessibilityDescription: nil))
    let globePixels = try #require(globe.tiffRepresentation)
    #expect(image.frame.size == NSSize(width: 22, height: 22))
    #expect(image.image?.tiffRepresentation == globePixels)
}

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

    let tile = try #require(tiles.subviews.first)
    let preview = try #require(tile.subviews.first)
    let icon = try #require(tile.subviews[1] as? NSImageView)
    let title = try #require(tile.subviews.last as? NSTextField)
    #expect(preview.frame.size == NSSize(width: 156, height: 104))
    #expect(preview.frame.minY - title.frame.maxY == 13)
    #expect(preview.subviews.first?.frame.size == NSSize(width: 22, height: 22))
    #expect(icon.frame.size == NSSize(width: 16, height: 16))
    #expect(title.frame.minX - icon.frame.maxX == 6)
    #expect(title.font?.pointSize == 12)
    window.setContentSize(NSSize(width: 240, height: 700))
    let narrow = try #require(switcher.makeOverlay())
    #expect(narrow.frame.width <= window.frame.width)
    #expect(Set(narrow.content.subviews.dropFirst().map { $0.frame.minY }).count == 2)
}

@Test @MainActor
func tabSwitcherRevealsAfterTheHoldAndClearsOnReleaseOrCancel() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: .titled, backing: .buffered, defer: false)
    let row = Suggestion(title: "Previous", subtitle: "", url: "https://example.test/",
                         key: nil, target: .tab(id: "item", spaceId: "space"), score: 0)
    var reveal: (@MainActor @Sendable () -> Void)?
    var selected: [Suggestion] = []
    func makeSwitcher() -> TabSwitcher {
        let switcher = TabSwitcher(parent: window, backwards: false, bindings: defaultKeyBindings(),
                                   accent: .systemTeal, favicon: { _ in nil }, schedule: { delay, action in
            #expect(delay == 0.15)
            reveal = action
        })
        switcher.onSelect = { selected.append($0) }
        return switcher
    }
    let quick = makeSwitcher()
    quick.commit()
    quick.load([row])
    let revealQuick = try #require(reveal)
    revealQuick()
    #expect(!quick.isRevealed)
    #expect(selected.map(\.target) == [row.target])

    for commit in [true, false] {
        let held = makeSwitcher()
        held.load([row])
        #expect(!held.isRevealed)
        let revealHeld = try #require(reveal)
        revealHeld()
        #expect(held.isRevealed)
        if commit { held.commit() } else { held.cancel() }
        #expect(!held.isRevealed)
        #expect(!held.isOpen)
        #expect(held.visibleWindow == nil)
    }
    #expect(selected.map(\.target) == [row.target, row.target])
}
