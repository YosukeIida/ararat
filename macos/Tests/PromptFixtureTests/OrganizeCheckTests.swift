import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class OrganizeCheckHost: NSObject {}

@Test @MainActor
func organizeDockCheckFindsWorkByIDAfterTheFixtureChangesSpaceOrder() throws {
    _ = NSApplication.shared
    class_addProtocol(OrganizeCheckHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime = Runtime(windowID: "organize")
    let session = WorkspaceSession()
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
        windowID: runtime.windowID, card: NSView(), seedOrganize: true, session: session)
    let store = try #require(session.store)
    let initial = store.snapshot(windowId: runtime.windowID)
    let work = try #require(initial.spaces.first { $0.id == "organize-work" })
    let other = try #require(initial.spaces.first { $0.id == "organize-other" })
    let dock = try #require(work.pinned.first { $0.url == "about:blank?organize-dock" })
    let landed = try store.moveItem(windowId: runtime.windowID, id: dock.id, container: other.pinnedId, index: 0, openFolder: false)
    let index = try #require(landed.spaces.firstIndex { $0.id == work.id })
    #expect(index != 0)
    let sidebar = SidebarView(snapshot: landed)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [], backing: .buffered, defer: false)
    window.contentView = sidebar
    defer { window.contentView = nil }
    runtime.adapter = adapter
    runtime.sidebar = sidebar
    runtime.browserCheckPhase = 5
    runtime.organizeCheckTick(OrganizeCheckHost() as! any ARWindowHostAPI, screen: false)
    #expect(runtime.organizeConditions["dock_no_switch"] == true)
    #expect(sidebar.spaceShown == index)
    #expect(store.snapshot(windowId: runtime.windowID).shownSpaceId == work.id)
    sidebar.showSpace(at: try #require(landed.spaces.firstIndex { $0.id == other.id }))
    runtime.browserCheckPhase = 5
    runtime.organizeCheckTick(OrganizeCheckHost() as! any ARWindowHostAPI, screen: false)
    #expect(runtime.organizeConditions["dock_no_switch"] == false)
}
