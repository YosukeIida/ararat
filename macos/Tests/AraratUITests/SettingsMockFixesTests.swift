import AppKit
import AraratKit
import SwiftUI
import Testing
@testable import AraratUI

// setpolish: the five settings fixes the ledger asks for. The colours are read from the rendered
// window (a label's colour is what a pixel says it is), and the sizes and columns from the markers
// the panes already carry, so none of these tests drives an event or orders a window front.

@MainActor
private func mockFixModel(spaces: [SpaceSnapshot]) -> SettingsModel {
    SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: spaces.first?.id, selectedId: nil, spaces: spaces),
                  adapter: WorkspaceAdapter(windowID: "setpolish-settings"), publish: { _ in }, resetWidth: {},
                  keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "setpolish-defaults")),
                  airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "setpolish-atc")))
}

@MainActor
private func mockFixSpace(_ id: String, title: String) -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "\(id)-pin", todayId: "\(id)-today",
                  favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .`default`, id: id,
                  title: title, icon: nil, look: nil, favorites: [], pinned: [], today: [])
}

/// The window's cached bitmap as sRGB colours, top-down in the content view's coordinates, as
/// `SettingsCheckProbe.greys` reads it.
@MainActor
private func mockFixPixels(in window: NSWindow, rect: NSRect) throws -> [NSColor] {
    let content = try #require(window.contentView)
    let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
    content.cacheDisplay(in: content.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / max(1, content.bounds.width)
    let x0 = max(0, Int((rect.minX * scale).rounded(.down)))
    let x1 = min(bitmap.pixelsWide, Int((rect.maxX * scale).rounded(.up)))
    let y0 = max(0, Int((rect.minY * scale).rounded(.down)))
    let y1 = min(bitmap.pixelsHigh, Int((rect.maxY * scale).rounded(.up)))
    guard x0 < x1, y0 < y1 else { return [] }
    return (y0..<y1).flatMap { y in
        (x0..<x1).compactMap { x in bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) }
    }
}

/// True for the system red the boards draw a destructive label in, false for the label grey: the
/// test compares channels, so it does not depend on the bitmap's colour profile.
private func isRed(_ color: NSColor) -> Bool {
    color.redComponent - color.greenComponent > 0.12 && color.redComponent - color.blueComponent > 0.12
        && color.redComponent > 0.4
}

@Test @MainActor
func theSpacePageDeleteSpaceIsDrawnInTheSystemsRed() async throws {
    _ = NSApplication.shared
    let spaces = [mockFixSpace("a", title: "Alpha"), mockFixSpace("b", title: "Beta")]
    let model = mockFixModel(spaces: spaces)
    model.navigate(.space("a"))
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil { probe.layout(); return probe.marker(SettingsModel.spaceDeleteButtonMarker) != nil }
    let button = try #require(probe.marker(SettingsModel.spaceDeleteButtonMarker))
    #expect(button.width > 40 && button.height > 10)
    let pixels = try mockFixPixels(in: window, rect: button)
    #expect(pixels.contains(where: isRed), "Delete Space's label is red, not the label colour")
}

@Test @MainActor
func theSitePagesClearIsDrawnInTheSystemsRed() async throws {
    _ = NSApplication.shared
    let meet = "https://meet.example.com"
    let model = mockFixModel(spaces: [mockFixSpace("default", title: "Work")])
    model.siteHost = MockFixSiteHost(exceptions: [
        SiteException(profile: "Default", origin: meet, kind: .camera, setting: .content("block")),
    ])
    model.refreshSiteExceptions()
    model.openSite(origin: meet, profile: "Default")
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil { probe.layout(); return probe.marker(SettingsModel.siteClearButtonMarker) != nil }
    let button = try #require(probe.marker(SettingsModel.siteClearButtonMarker))
    let pixels = try mockFixPixels(in: window, rect: button)
    #expect(pixels.contains(where: isRed), "Clear…'s label is red, not the label colour")
}

@Test @MainActor
func theAutoArchivePopupSizesToItsContentAndSitsAtTheRowsTrailingEdge() async throws {
    _ = NSApplication.shared
    let model = mockFixModel(spaces: [mockFixSpace("a", title: "Alpha")])
    model.navigate(.tabs)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil { probe.layout(); return probe.marker(SettingsModel.archiveMenuMarker) != nil }
    let menu = try #require(probe.marker(SettingsModel.archiveMenuMarker))
    let row = try #require(probe.marker(SettingsModel.rowMarker("archive-after")))
    // E-Tabs draws a 110 pt pop-up; the product's stretched one measured about 310. Fixed to its
    // content it is compact, and the row's HStack puts it at the card's trailing 12 pt inset.
    #expect(menu.width < 150 && menu.width > 40)
    #expect(abs((row.maxX - 12) - menu.maxX) <= 1.5, "pop-up maxX \(menu.maxX), row maxX \(row.maxX)")
    #expect(menu.width < row.width / 2)
}

@Test @MainActor
func theSpacesRowsPutCountsAndKeycapsInTrailingColumnsOnATile() async throws {
    _ = NSApplication.shared
    let spaces = [mockFixSpace("a", title: "Alpha"), mockFixSpace("b", title: "Be")]
    let model = mockFixModel(spaces: spaces)
    // Only the first space has ⌃N; the second must still keep its count in the same column.
    model.spaceKeys = [0: ["⌃", "1"]]
    model.navigate(.spaces)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil {
        probe.layout()
        return probe.marker(SettingsModel.spaceCountMarker("a")) != nil
            && probe.marker(SettingsModel.spaceCountMarker("b")) != nil
            && probe.marker(SettingsModel.spaceKeysMarker("a")) != nil
            && probe.marker(SettingsModel.spaceKeysMarker("b")) != nil
    }
    let counts = ["a", "b"].map { probe.marker(SettingsModel.spaceCountMarker($0))! }
    let keys = ["a", "b"].map { probe.marker(SettingsModel.spaceKeysMarker($0))! }
    let icons = ["a", "b"].map { probe.marker(SettingsModel.spaceIconMarker($0))! }
    // One column per trailing control: the two names differ in length and only one row has ⌃N,
    // yet neither count moves with the name or with the keycaps.
    #expect(counts.allSatisfy { abs($0.width - SettingsMetrics.spaceCountColumn) <= 1 })
    #expect(abs(counts[0].minX - counts[1].minX) <= 1 && abs(counts[0].maxX - counts[1].maxX) <= 1)
    #expect(abs(keys[0].maxX - keys[1].maxX) <= 1)
    #expect(counts[0].maxX + 4 <= keys[0].minX, "the count column ends before the keycaps")
    // The icon letter sits on the board's 24 pt tile, away from the name.
    #expect(icons.allSatisfy { abs($0.width - 24) <= 1 && abs($0.height - 24) <= 1 })
    let tile = try #require(probe.marker(SettingsModel.spaceIconMarker("a")))
    let row = try #require(probe.marker(SettingsModel.rowMarker("space-a")))
    let pixels = try mockFixPixels(in: window, rect: tile.insetBy(dx: 4, dy: 10))
    let card = try mockFixPixels(in: window, rect: NSRect(x: row.minX + 4, y: row.midY, width: 1, height: 1))
    let tileGrey = try #require(pixels.first?.usingColorSpace(.deviceGray)?.whiteComponent)
    let cardGrey = try #require(card.first?.usingColorSpace(.deviceGray)?.whiteComponent)
    #expect(abs(tileGrey - cardGrey) > 0.03, "the tile's grey is drawn under the letter: \(tileGrey) vs \(cardGrey)")
}

@MainActor
private final class MockFixSiteHost: SiteSettingsHost {
    var exceptions: [SiteException]
    init(exceptions: [SiteException]) { self.exceptions = exceptions }
    func siteExceptions() -> [SiteException] { exceptions }
    func setSiteException(profile: String, origin: String, kind: String,
                          setting: SiteState.PermissionSetting?) -> Bool { true }
    func clearSiteData(profile: String, origin: String, completion: @escaping (UInt64) -> Void) { completion(0) }
}
