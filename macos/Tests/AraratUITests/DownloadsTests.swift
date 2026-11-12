import AppKit
import Testing
import AraratKit
@testable import AraratUI

private func download(_ id: String, start: Double = 0, running: Bool = false, received: Int64 = 0, total: Int64 = 0, actions: [String] = [], restored: Bool = false, state: Int? = nil) -> [String: Any] {
    ["id": id, "profile": "Default", "name": id, "state": state ?? (running ? 0 : 1), "running": running, "restored": restored,
     "start": start, "received": received, "total": total, "status": "", "actions": actions]
}

@Test @MainActor func restoredHistoryOnlyActivatesTheListWhenResumable() {
    let model = DownloadsModel()
    model.update([download("history", restored: true)])
    #expect(!model.hasSessionDownloads)
    model.update([download("interrupted", actions: ["resume"], restored: true, state: 3)])
    #expect(model.hasSessionDownloads)
}

@Test @MainActor func downloadsSortAndWeightOnlyRunningItems() {
    let model = DownloadsModel()
    #expect(model.progress == .none)
    model.update([download("old", start: 1, running: true, received: 20, total: 100),
                  download("new", start: 2, running: true, received: 150, total: 300),
                  download("done", start: 3, received: 1000, total: 1000)])
    #expect(model.items.map(\.id) == ["done", "new", "old"])
    #expect(model.progress == .fraction(0.425))
    model.update([download("unknown", running: true, total: 0)])
    #expect(model.progress == .indeterminate)
    model.update([download("done")])
    #expect(model.progress == .none)
}

@Test @MainActor func downloadActionsRequireAnAvailableCurrentItem() {
    let model = DownloadsModel()
    var received: [String] = []
    model.onAction = { action, id in received.append("\(id):\(action)"); return true }
    model.update([download("one", actions: ["show", "cancel"])])
    #expect(model.perform("cancel", id: "one"))
    #expect(!model.perform("keep", id: "one"))
    model.update([])
    #expect(!model.perform("show", id: "one"))
    #expect(received == ["one:cancel"])
}

@Test @MainActor func downloadRowButtonsSendTheirActionAndIdentifier() throws {
    let model = DownloadsModel()
    var received: [String] = []
    model.onAction = { action, id in received.append("\(id):\(action)"); return true }
    model.update([download("one", actions: ["show", "cancel"])])
    let popover = DownloadsPopover(model: model, anchor: NSView())
    let row = popover.row(try #require(model.items.first))
    func buttons(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons) }
    let cancel = try #require(buttons(row).first { $0.title == "Cancel" })
    cancel.performClick(nil)
    #expect(received == ["one:cancel"])
}

@Test @MainActor func libraryButtonOpensLibraryOnlyWhenTheListIsEmpty() {
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let model = DownloadsModel()
    sidebar.setDownloadsModel(model)
    model.update([download("item", running: true, received: 1, total: 2)])
    #expect(sidebar.libraryButton.progress == .fraction(0.5))
    sidebar.libraryButton.performClick(nil)
    #expect(!sidebar.libraryOpen)
    model.update([])
    #expect(sidebar.libraryButton.progress == .none)
    sidebar.libraryButton.performClick(nil)
    #expect(sidebar.libraryOpen)
}

@Test @MainActor func downloadHoverWaitsAndExitCancels() {
    let button = DownloadsButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    var tasks: [DispatchWorkItem] = []
    var opened = 0
    button.scheduleHover = { tasks.append($0) }
    button.onHover = { opened += 1 }
    let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
    button.mouseEntered(with: event)
    #expect(opened == 0)
    button.mouseExited(with: event)
    tasks[0].perform()
    #expect(opened == 0)
    button.mouseEntered(with: event)
    tasks[1].perform()
    #expect(opened == 1)
}

@Test @MainActor func popoverKeepsRowsAndActionsDuringProgressUpdates() throws {
    let model = DownloadsModel()
    model.update([download("a", running: true, received: 1, total: 100, actions: ["cancel"])])
    let popover = DownloadsPopover(model: model, anchor: NSView())
    popover.refresh(limit: 10)
    let row = try #require(popover.rows["a"])
    let button = try #require(row.actionButtons.first)
    model.update([download("a", running: true, received: 2, total: 100, actions: ["cancel"])])
    popover.refresh(limit: 10)
    #expect(popover.rows["a"] === row)
    #expect(row.actionButtons.first === button)
    model.update([download("b", start: 2), download("a", running: true, received: 3, total: 100, actions: ["cancel"])])
    popover.refresh(limit: 10)
    #expect(popover.rows["a"] === row)
}

@Test @MainActor func indeterminateRingKeepsItsAnimationAcrossUpdatesAndLayout() throws {
    let button = DownloadsButton(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
    button.reduceMotion = { false }
    button.progress = .indeterminate
    let initial = try #require(button.ring.animation(forKey: "spin")).beginTime
    button.progress = .indeterminate
    button.layout()
    #expect(button.ring.animation(forKey: "spin")?.beginTime == initial)
    #expect(button.accessibilityValue() as? String == "Downloading")
    button.progress = .fraction(0.42)
    #expect(button.ring.animation(forKey: "spin") == nil)
    #expect(button.accessibilityValue() as? String == "Downloading, 42 %")
}

