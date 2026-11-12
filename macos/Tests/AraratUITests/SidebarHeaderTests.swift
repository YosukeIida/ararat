import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func headerControlsFollowPanelWidthAndMenuOrder() {
    let header = SidebarHeaderView(frame: .zero)
    let widths: [(CGFloat, [String])] = [
        (240, ["toggle_sidebar", "back", "forward", "reload", "menu"]),
        (232, ["toggle_sidebar", "back", "forward", "reload", "menu"]),
        (231, ["back", "forward", "reload", "menu"]),
        (200, ["back", "forward", "reload", "menu"]),
        (199, ["back", "forward", "menu"]),
        (164, ["back", "forward", "menu"]),
    ]
    for (width, expected) in widths {
        header.frame = NSRect(x: 0, y: 0, width: width, height: 24)
        header.layout()
        let buttons = header.subviews.compactMap { $0 as? NSButton }.filter { !$0.isHidden }
        #expect(buttons.compactMap { $0.identifier?.rawValue } == expected)
        for (left, right) in zip(buttons, buttons.dropFirst()) { #expect(left.frame.maxX <= right.frame.minX) }
    }
    header.siteDomain = { "example.com" }
    header.hasTab = true
    let items = header.makeMenu().items.filter { !$0.isSeparatorItem }
    #expect(items.map(\.title) == ["Reload", "Force Reload", "Find in Page…", "Clear Cache", "Clear Cookies", "Toggle Sidebar", "Zoom In", "Zoom Out", "Print…", "Settings…"])
    #expect(items[4].toolTip == "Clears cookies for example.com and its subdomains")
    for (domain, help) in [("127.0.0.1", "Clears cookies for 127.0.0.1"), ("[::1]", "Clears cookies for [::1]"), ("localhost", "Clears cookies for localhost and its subdomains"), ("intranet", "Clears cookies for intranet and its subdomains")] {
        header.siteDomain = { domain }
        let site = header.makeMenu().items.filter { !$0.isSeparatorItem }
        #expect(site[3].isEnabled && site[4].isEnabled && site[4].toolTip == help)
    }
    header.siteDomain = { nil }
    let noSite = header.makeMenu().items.filter { !$0.isSeparatorItem }
    #expect(!noSite[3].isEnabled && !noSite[4].isEnabled && noSite[4].toolTip == nil)
    header.siteDomain = { "127.0.0.1" }
    header.hasTab = false
    let noTab = header.makeMenu().items.filter { !$0.isSeparatorItem }
    #expect(!noTab[3].isEnabled && !noTab[4].isEnabled)
}

@Test @MainActor
func headerFollowsNavigationLoadingAndShortcutState() throws {
    let header = SidebarHeaderView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(header)
    header.layout()
    #expect(header.checkEnabled["back"] == false)
    #expect(header.checkEnabled["forward"] == false)
    header.hasTab = true
    header.canGoBack = true
    header.canGoForward = true
    #expect(header.checkEnabled["back"] == true)
    #expect(header.checkEnabled["forward"] == true)
    header.loading = true
    #expect(header.checkReloadLabel == "Stop")
    #expect(header.checkTooltip("reload").1.isEmpty)
    #expect(header.subviews.compactMap { $0 as? NSButton }.first { $0.identifier?.rawValue == "reload" }?.accessibilityHelp() == "Stop")
    header.loading = false
    #expect(header.checkReloadLabel == "Reload")
    #expect(header.checkTooltip("back").1 == ["⌘", "["])
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15))
    header.checkKeys(["R"], event: event)
    #expect(header.checkPressed("reload"))
    header.frame.size.width = 199
    header.layout()
    header.checkKeys(["R"], event: event)
    #expect(header.checkPressed("menu"))
    header.checkKeys([], event: event)
    #expect(!header.checkPressed("menu"))
}

@Test @MainActor
func headerToggleCapsAndPressedStateFollowRebinding() throws {
    let header = SidebarHeaderView(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView?.addSubview(header)
    header.layout()
    header.toggleBinding = { KeyCombination(key: "q", command: true, control: true, option: false, shift: false) }
    #expect(header.checkTooltip("toggle_sidebar").1 == ["⌃", "⌘", "Q"])
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12))
    header.checkKeys(["Q"], event: event)
    #expect(header.checkPressed("toggle_sidebar"))
    header.checkKeys(["S"], event: event)
    #expect(!header.checkPressed("toggle_sidebar"))
    header.toggleBinding = { nil }
    #expect(header.checkTooltip("toggle_sidebar").1.isEmpty)
}
