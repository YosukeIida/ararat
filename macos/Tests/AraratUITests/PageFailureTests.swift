import AppKit
import Testing
@testable import AraratKit

@MainActor
@Test func failurePageOffersTheActionsForTheTab() throws {
    let view = PageFailureView(frame: NSRect(x: 0, y: 0, width: 680, height: 380))
    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    let buttons = descendants(view).compactMap { $0 as? NSButton }
    let reload = try #require(buttons.first)
    let close = try #require(buttons.last)
    let defaultTint = reload.contentTintColor
    view.accent = NSColor(srgbRed: 0.95, green: 0.9, blue: 0.85, alpha: 1)
    #expect(defaultTint == .white && reload.contentTintColor == .black)
    var reloaded = false
    var closed = false
    view.onReload = { reloaded = true }
    view.onClose = { closed = true }
    view.update(crashed: true, error: 0, host: "example.test", archive: true)
    #expect(reload.title == "Reload")
    #expect(close.title == "Archive Tab" && !close.isHidden)
    reload.performClick(nil)
    close.performClick(nil)
    #expect(reloaded && closed)
    view.update(crashed: true, error: 0, host: "", archive: true)
    let fields = descendants(view).compactMap { $0 as? NSTextField }
    #expect(fields.contains { $0.stringValue == "This page crashed" && $0.accessibilityRole() == NSAccessibility.Role(rawValue: "AXHeading") })
    #expect(fields.contains { $0.stringValue.contains("showing this page.") })
    view.update(crashed: true, error: 0, host: "example.test", archive: false)
    #expect(close.title == "Close Tab")
    view.update(crashed: false, error: -106, host: "example.test", archive: false)
    #expect(reload.title == "Try Again" && close.isHidden)
    for (error, expected) in [(-105, "ERR_NAME_NOT_RESOLVED"), (-137, "ERR_NAME_RESOLUTION_FAILED")] {
        view.update(crashed: false, error: error, host: "example.test", archive: false)
        let labels = descendants(view).compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains("This site can’t be reached"))
        #expect(labels.contains(expected))
    }
    #expect(reload.keyEquivalent == "\r")
}

@MainActor
@Test func failurePageHidesAndRestoresTheCoveredPage() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
    let page = NSView(frame: window.contentView!.bounds)
    let overlay = PageFailureView(frame: page.bounds)
    window.contentView?.addSubview(page)
    window.contentView?.addSubview(overlay)
    let originallyHidden = page.isAccessibilityHidden()
    let originallyElement = page.isAccessibilityElement()
    var restored = false
    overlay.cover(page, focus: true) { restored = true }
    #expect(page.isAccessibilityHidden())
    #expect(page.isAccessibilityElement())
    overlay.uncover(restoreFocus: true)
    #expect(page.isAccessibilityHidden() == originallyHidden)
    #expect(page.isAccessibilityElement() == originallyElement)
    #expect(restored)
    restored = false
    func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }
    let primary = try #require(descendants(overlay).compactMap { $0 as? NSButton }.first)
    overlay.cover(page, focus: false) { restored = true }
    #expect(primary.keyEquivalent.isEmpty)
    overlay.cover(page, focus: true) { restored = true }
    #expect(primary.keyEquivalent == "\r")
    overlay.removeFromSuperview()
    overlay.uncover(restoreFocus: true)
    #expect(restored)
}
