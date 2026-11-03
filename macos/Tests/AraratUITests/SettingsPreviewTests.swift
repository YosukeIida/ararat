import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func captureSettingsWithoutOrderingWindow() async throws {
    _ = NSApplication.shared
    let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: nil, spaces: [SpaceSnapshot(archiveAfter: .hours12, profileName: "Default", id: "work", title: "Work", icon: "🔬", look: nil, favorites: [], pinned: [], today: [])])
    let directory = try testTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["light", "dark"] {
        let model = SettingsModel(snapshot: snapshot, adapter: WorkspaceAdapter(windowID: "preview"), publish: { _ in }, resetWidth: {})
        model.page = .space("work")
        let controller = SettingsWindowController(model: model)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: name == "light" ? .aqua : .darkAqua)
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        await Task.yield()
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("settings-\(name).png"))
        #expect(!window.isVisible)
        window.contentViewController = nil
    }
}
