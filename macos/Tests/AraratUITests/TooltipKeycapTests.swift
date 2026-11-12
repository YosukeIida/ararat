import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func tooltipReadsMenuKeysAndTracksModifierPressAndRelease() throws {
    _ = NSApplication.shared
    let oldMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = oldMenu }
    let menu = NSMenu()
    let item = menu.addItem(withTitle: "Toggle Library", action: #selector(SidebarView.toggleLibrary(_:)), keyEquivalent: "l")
    item.keyEquivalentModifierMask = [.shift, .command]
    NSApp.mainMenu = menu
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [], backing: .buffered, defer: false)
    defer { window.contentView = nil }
    let button = NSButton(title: "Library", target: nil, action: #selector(SidebarView.toggleLibrary(_:)))
    button.toolTip = "Library"
    window.contentView?.addSubview(button)
    let tooltip = SidebarTooltip()
    tooltip.modifierFlags = { [] }
    var now = 0.0
    tooltip.clock = { now }
    tooltip.capture(in: button)
    tooltip.update(target: button, point: NSPoint(x: 20, y: 200))
    now = 1.6
    tooltip.update(target: button, point: NSPoint(x: 20, y: 200))
    #expect(tooltip.text == "Library")
    #expect(tooltip.keycaps.map(\.stringValue) == ["⇧", "⌘", "L"])
    let command = try #require(tooltip.keycaps.first { $0.modifier == .command })
    for flags: NSEvent.ModifierFlags in [.command, []] {
        let event = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
        tooltip.flagsChanged(with: event)
        #expect(command.pressed == flags.contains(.command))
        #expect(command.frame.minY == (flags.isEmpty ? 5 : 4))
        #expect(tooltip.text == "Library")
    }
    item.keyEquivalent = "]"
    item.keyEquivalentModifierMask = .option
    tooltip.update(target: button, point: NSPoint(x: 20, y: 200))
    #expect(tooltip.keycaps.map(\.stringValue) == ["⌥", "]"])
    let row = SidebarRowView(row: Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false, id: "pin", title: "Pin", url: nil, depth: 0, kind: .tab, unloaded: false, lastSelectedAt: nil), selected: true, action: { _ in })
    row.pinned = true
    window.contentView?.addSubview(row)
    menu.addItem(withTitle: "Close Tab", action: #selector(SidebarView.closeSelectedTab(_:)), keyEquivalent: "w")
    tooltip.capture(in: row)
    tooltip.update(target: row.closeButton, point: NSPoint(x: 25, y: 200))
    #expect(tooltip.text == "Close Tab")
    #expect(tooltip.keycaps.map(\.stringValue) == ["⌘", "W"])
    let down = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 55))
    tooltip.flagsChanged(with: down)
    #expect(tooltip.keycaps.first?.pressed == true)
    tooltip.dismiss()
    tooltip.update(target: row.closeButton, point: NSPoint(x: 25, y: 200))
    now += 1.6
    tooltip.update(target: row.closeButton, point: NSPoint(x: 25, y: 200))
    #expect(tooltip.keycaps.allSatisfy { !$0.pressed })
    tooltip.modifierFlags = { .command }
    tooltip.update(target: row.closeButton, point: NSPoint(x: 25, y: 200))
    #expect(tooltip.keycaps.first?.pressed == true)
    #expect(!window.isVisible)
}

@Test @MainActor
func tooltipMapsSpecialMenuKeysAndImplicitShift() throws {
    _ = NSApplication.shared
    let oldMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = oldMenu }
    let menu = NSMenu()
    let item = menu.addItem(withTitle: "Library", action: #selector(SidebarView.toggleLibrary(_:)), keyEquivalent: "l")
    item.keyEquivalentModifierMask = .command
    NSApp.mainMenu = menu
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 400), styleMask: [], backing: .buffered, defer: false)
    defer { window.contentView = nil }
    let button = NSButton(title: "Library", target: nil, action: item.action)
    button.toolTip = "Library"
    window.contentView?.addSubview(button)
    let tooltip = SidebarTooltip()
    var now = 0.0
    tooltip.clock = { now }
    tooltip.modifierFlags = { [] }
    tooltip.capture(in: button)
    tooltip.update(target: button, point: .zero)
    now = 1.6
    let cases: [(String, String)] = [
        ("\r", "↩"), ("\u{3}", "↩"), ("\u{7f}", "⌫"), ("\u{8}", "⌫"), ("\t", "⇥"), ("\u{1b}", "⎋"), (" ", "␣"),
        (String(UnicodeScalar(NSDeleteFunctionKey)!), "⌦"),
        (String(UnicodeScalar(NSUpArrowFunctionKey)!), "↑"), (String(UnicodeScalar(NSDownArrowFunctionKey)!), "↓"),
        (String(UnicodeScalar(NSLeftArrowFunctionKey)!), "←"), (String(UnicodeScalar(NSRightArrowFunctionKey)!), "→"),
        (String(UnicodeScalar(NSPageUpFunctionKey)!), "⇞"), (String(UnicodeScalar(NSPageDownFunctionKey)!), "⇟"),
        (String(UnicodeScalar(NSHomeFunctionKey)!), "↖"), (String(UnicodeScalar(NSEndFunctionKey)!), "↘"),
        ("l", "L"), ("]", "]")
    ]
    for (key, glyph) in cases {
        item.keyEquivalent = key
        tooltip.update(target: button, point: .zero)
        #expect(tooltip.keycaps.map(\.stringValue) == ["⌘", glyph], "key \(key.debugDescription)")
    }
    for mask: NSEvent.ModifierFlags in [.command, [.command, .shift]] {
        item.keyEquivalent = "L"
        item.keyEquivalentModifierMask = mask
        tooltip.update(target: button, point: .zero)
        #expect(tooltip.keycaps.map(\.stringValue) == ["⇧", "⌘", "L"])
    }
    #expect(!window.isVisible)
}
