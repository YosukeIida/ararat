import AppKit
import AraratKit
import AraratUI
import AraratEngineAPI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class ClearUndoKeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}

@MainActor private final class ClearUndoHost: NSObject {
    let value = ClearUndoKeyWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [], backing: .buffered, defer: false)
    @objc(window) func window() -> NSWindow { value }
}

@Test @MainActor
func clearUndoMenuSurvivesToastReplacementAndExpires() {
    _ = NSApplication.shared
    let runtime = Runtime(windowID: "undo-menu")
    class_addProtocol(ClearUndoHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = ClearUndoHost()
    runtime.host = host as? any ARWindowHostAPI
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    var timers: [() -> Void] = []
    runtime.clearUndo.schedule = { delay, action in
        #expect(delay == 5)
        timers.append(action)
    }
    var calls = 0
    let item = NSMenuItem(title: "Undo Clear Tabs", action: #selector(Runtime.undoClearTabs(_:)), keyEquivalent: "")
    #expect(!Runtime.clearUndoMenuEnabled(runtime))
    #expect(!runtime.validateMenuItem(item))
    runtime.clearUndo.offer { calls += 1 }
    container.showTabsCleared { runtime.clearUndo.run() }
    #expect(Runtime.clearUndoMenuEnabled(runtime))
    #expect(runtime.validateMenuItem(item))
    container.showLinkCopied()
    #expect(Runtime.clearUndoMenuEnabled(runtime))
    runtime.clearUndo.offer { calls += 10 }
    timers[0]()
    #expect(Runtime.clearUndoMenuEnabled(runtime))
    runtime.undoClearTabs(item)
    #expect(calls == 10)
    #expect(!Runtime.clearUndoMenuEnabled(runtime))
    #expect(!runtime.validateMenuItem(item))
    runtime.clearUndo.offer { calls += 100 }
    timers[2]()
    #expect(!Runtime.clearUndoMenuEnabled(runtime))
    runtime.clearUndo.run()
    #expect(calls == 10)
    #expect(!Runtime.clearUndoMenuEnabled(nil))
}

@Test @MainActor
func clearUndoFindsTheSelectedSplitMember() {
    func row(_ id: String, parent: String, kind: RowKind, unloaded: Bool) -> Row {
        Row(folderHasTabs: false, parentId: parent, siblingIndex: 0, collapsed: false, id: id, title: id, url: kind == .tab ? "https://example.test" : nil, depth: 0, kind: kind, unloaded: unloaded, lastSelectedAt: nil)
    }
    let split = row("split", parent: "today", kind: .split, unloaded: true)
    let member = row("member", parent: "split", kind: .tab, unloaded: true)
    let space = SpaceSnapshot(pinnedCount: 0, todayCount: 1, profileKey: "default", pinnedId: "pin", todayId: "today", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .default, id: "work", title: "Work", icon: nil, look: nil, pinnedCollapsed: false, favorites: [], pinned: [], today: [split, member])
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: "member", spaces: [space])
    #expect(clearUndoSelection(snapshot)?.id == "member")
    #expect(splitOwner("member", rows: space.today) == "split")
}
