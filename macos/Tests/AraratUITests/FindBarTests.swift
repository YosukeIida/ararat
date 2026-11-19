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
func findResultsShowTheTrailingCountAndDisableButtonsOnlyForConfirmedZero() throws {
    let view = FindBarView(frame: NSRect(x: 0, y: 0, width: 380, height: 36))
    view.layoutSubtreeIfNeeded()
    let count = try #require(view.subviews.compactMap { $0 as? NSTextField }
        .first { $0.identifier?.rawValue == "find-match-count" })
    let spinner = try #require(view.subviews.compactMap { $0 as? NSProgressIndicator }.first)
    let buttons = view.subviews.compactMap { $0 as? NSButton }
    #expect(buttons.count == 3)
    #expect(buttons.allSatisfy { $0.image != nil && $0.imagePosition == .imageOnly })
    #expect(!view.field.isBezeled && !view.field.drawsBackground)
    #expect(count.alignment == .left)
    #expect(view.field.frame.maxX <= count.frame.minX)
    #expect(count.frame.maxX <= buttons[0].frame.minX)
    #expect(view.bounds.contains(count.frame))
    #expect(spinner.isHidden)
    view.update(state: ["visible": true, "text": "needle", "matches": 0, "request_id": 0, "final_update": false])
    #expect(spinner.isHidden)
    view.update(state: ["visible": true, "text": "needle", "matches": 0, "request_id": 7, "final_update": false])
    #expect(view.requestID == 7 && !view.finalUpdate)
    #expect(spinner.isHidden)
    #expect(count.stringValue.isEmpty && buttons.map(\.isEnabled) == [true, true, true])
    view.update(state: ["visible": true, "text": "needle", "matches": 0, "request_id": 7, "final_update": true])
    #expect(view.requestID == 7 && view.finalUpdate && view.matches == 0)
    #expect(spinner.isHidden)
    #expect(count.stringValue == "Not found" && count.textColor == .systemRed)
    #expect(buttons.map(\.isEnabled) == [false, false, true])
    view.field.stringValue = "need"
    view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.field))
    #expect(count.stringValue.isEmpty && count.textColor == .secondaryLabelColor)
    #expect(buttons.map(\.isEnabled) == [true, true, true])
    view.update(state: ["visible": true, "text": "need", "matches": 0, "request_id": 7, "final_update": true])
    #expect(count.stringValue.isEmpty && buttons.map(\.isEnabled) == [true, true, true])
    view.update(state: ["visible": true, "text": "need", "matches": 2, "request_id": 6, "final_update": false])
    #expect(spinner.isHidden && count.stringValue.isEmpty)
    view.update(state: ["visible": true, "text": "need", "matches": 2, "request_id": 8, "final_update": false])
    #expect(spinner.isHidden && count.stringValue.isEmpty)
    view.update(state: ["visible": true, "text": "need", "matches": 12, "ordinal": 3, "request_id": 8, "final_update": true])
    #expect(spinner.isHidden)
    #expect(count.stringValue == "3 of 12" && count.textColor == .secondaryLabelColor)
    #expect(buttons.map(\.isEnabled) == [true, true, true])
    view.update(state: ["visible": true, "text": "", "matches": 0, "request_id": 9, "final_update": true])
    #expect(count.stringValue.isEmpty && buttons.map(\.isEnabled) == [true, true, true])
}

@Test @MainActor
func findSpinnerWaitsForAnUnfinishedRequest() throws {
    let view = FindBarView()
    let spinner = try #require(view.subviews.compactMap { $0 as? NSProgressIndicator }.first)
    var starts: [DispatchWorkItem] = []
    view.scheduleSpinnerStart = { delay, work in
        #expect(delay == 0.25)
        starts.append(work)
    }
    func update(_ request: Int, final: Bool = false, visible: Bool = true) {
        view.update(state: ["visible": visible, "text": "needle", "request_id": request, "final_update": final])
    }
    func takeStart() throws -> DispatchWorkItem {
        let work = starts.popLast()
        return try #require(work)
    }

    update(7)
    #expect(spinner.isHidden)
    let fast = try takeStart()
    update(7, final: true)
    #expect(fast.isCancelled)
    fast.perform()
    #expect(spinner.isHidden)

    update(8)
    let first = try takeStart()
    update(8)
    #expect(first.isCancelled)
    first.perform()
    #expect(spinner.isHidden)
    try takeStart().perform()
    #expect(!spinner.isHidden)
    update(8, final: true)
    #expect(spinner.isHidden)

    update(9)
    let pending = try takeStart()
    update(9, visible: false)
    #expect(pending.isCancelled)
    pending.perform()
    #expect(spinner.isHidden)
    #expect(starts.isEmpty)
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
