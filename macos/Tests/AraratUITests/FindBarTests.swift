import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func findOverlayTracksThePageRectWhenItResizes() {
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [])
    let page = NSView()
    let container = SidebarContainerView(sidebar: SidebarView(snapshot: snapshot), page: page)
    container.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    container.layoutSubtreeIfNeeded()
    let first = NSRect(x: 0, y: 0, width: 600, height: 500)
    container.setFindPageRect(first)
    let firstFrame = container.findBar.convert(container.findBar.bounds, to: page)
    #expect(firstFrame.maxX == first.maxX && firstFrame.width == 380)
    let second = NSRect(x: 0, y: 0, width: 220, height: 300)
    container.setFindPageRect(second)
    let secondFrame = container.findBar.convert(container.findBar.bounds, to: page)
    #expect(secondFrame.maxX == second.maxX && secondFrame.width == 220)
}

@Test @MainActor
func findOverlayRemainsAboveASeparateHostedPage() {
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: [])
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let page = NSView()
    let container = SidebarContainerView(sidebar: SidebarView(snapshot: snapshot), page: page)
    container.frame = root.bounds
    root.addSubview(container)
    container.layoutSubtreeIfNeeded()
    container.setFindPageRect(NSRect(x: 0, y: 0, width: 150, height: 580))
    let hostedPage = NSView(frame: container.convert(page.bounds, from: page))
    root.addSubview(hostedPage)
    container.placeFindBarAbovePage(in: root)
    container.findBar.isHidden = false
    let frame = container.findBar.frame
    let hit = root.hitTest(NSPoint(x: frame.midX, y: frame.midY))
    #expect(hit?.isDescendant(of: container.findBar) == true)
    #expect(container.findBar.convert(container.findBar.bounds, to: page).width == 150)
    container.setFindPageRect(NSRect(x: 0, y: 0, width: 100, height: 400))
    #expect(container.findBar.convert(container.findBar.bounds, to: page).width == 100)
}

@Test @MainActor
func findResultsExposeRequestAndFinalUpdate() {
    let view = FindBarView()
    view.update(state: ["visible": true, "text": "needle", "matches": 0, "request_id": 7, "final_update": false])
    #expect(view.requestID == 7 && !view.finalUpdate)
    view.update(state: ["visible": true, "text": "needle", "matches": 0, "request_id": 7, "final_update": true])
    #expect(view.requestID == 7 && view.finalUpdate && view.matches == 0)
}

@Test @MainActor
func findFieldPreservesMarkedTextDuringUpdates() throws {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
    let view = FindBarView(frame: NSRect(x: 0, y: 0, width: 380, height: 36))
    window.contentView = view
    let field = try #require(view.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(window.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.setMarkedText("こん", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(editor.hasMarkedText())
    view.update(state: ["visible": true, "text": "old result", "matches": 1])
    #expect(editor.hasMarkedText())
    #expect(field.stringValue != "old result")
    #expect(view.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) == false)
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    #expect(!view.performKeyEquivalent(with: event))
}
