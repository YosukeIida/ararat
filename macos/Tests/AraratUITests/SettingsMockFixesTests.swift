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

/// True for a destructive label's red, false for the label grey: the test compares channels, so
/// it does not depend on the bitmap's colour profile.
private func isRed(_ color: NSColor) -> Bool {
    color.redComponent - color.greenComponent > 0.12 && color.redComponent - color.blueComponent > 0.12
        && color.redComponent > 0.4
}

/// How red the reddest pixel in `rect` is: 0 for a grey label, about 0.55 for the boards' #B3261E
/// at full coverage, and lower when the label is drawn dimmed.
@MainActor
private func reddestPixel(in window: NSWindow, rect: NSRect) throws -> CGFloat {
    try mockFixPixels(in: window, rect: rect)
        .map { $0.redComponent - $0.greenComponent }
        .max() ?? 0
}

/// The space page with `spaces` on it, its Delete Space marker measured, and the window it was
/// read from (the caller clears the content view).
@MainActor
private func mockFixDeleteButton(spaces: [SpaceSnapshot]) async throws -> (window: NSWindow, button: NSRect) {
    let model = mockFixModel(spaces: spaces)
    model.navigate(.space("a"))
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    let probe = try #require(controller.checkProbe())
    try await waitUntil { probe.layout(); return probe.marker(SettingsModel.spaceDeleteButtonMarker) != nil }
    return (window, try #require(probe.marker(SettingsModel.spaceDeleteButtonMarker)))
}

@Test @MainActor
func theDestructiveRedIsTheBoardsDynamicColour() throws {
    func resolved(_ name: NSAppearance.Name) throws -> NSColor {
        let appearance = try #require(NSAppearance(named: name))
        var value: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            value = SettingsColor.destructiveColor.usingColorSpace(.sRGB)
        }
        return try #require(value)
    }
    // `--red` on the boards: #B3261E in light and #FF8A80 in dark, not systemRed (#FF3B30).
    let light = try resolved(.aqua)
    #expect(abs(light.redComponent - 0xB3 / 255) < 0.002)
    #expect(abs(light.greenComponent - 0x26 / 255) < 0.002)
    #expect(abs(light.blueComponent - 0x1E / 255) < 0.002)
    let dark = try resolved(.darkAqua)
    #expect(abs(dark.redComponent - 0xFF / 255) < 0.002)
    #expect(abs(dark.greenComponent - 0x8A / 255) < 0.002)
    #expect(abs(dark.blueComponent - 0x80 / 255) < 0.002)
}

@Test @MainActor
func theSpacePageDeleteSpaceIsDrawnInTheBoardsRed() async throws {
    _ = NSApplication.shared
    let (window, button) = try await mockFixDeleteButton(spaces: [mockFixSpace("a", title: "Alpha"),
                                                                 mockFixSpace("b", title: "Beta")])
    defer { window.contentViewController = nil }
    #expect(button.width > 40 && button.height > 10)
    let pixels = try mockFixPixels(in: window, rect: button)
    #expect(pixels.contains(where: isRed), "Delete Space's label is red, not the label colour")
    let reddest = try reddestPixel(in: window, rect: button)
    #expect(reddest > 0.25, "the label reaches the board's red: \(reddest)")
}

@Test @MainActor
func theDisabledDeleteSpaceFadesLikeTheBoardsDisabledState() async throws {
    _ = NSApplication.shared
    // Two spaces: the button is enabled. One space: it is disabled and the board draws `.dis`,
    // 40 % opacity. An explicit label colour could keep it at full strength, so the rendered
    // pixels are the test: SwiftUI's own disabled dimming takes the label to about 0.37 of the
    // enabled one here, so no extra opacity is applied (a second 0.4 would double-dim it).
    let (enabledWindow, enabled) = try await mockFixDeleteButton(spaces: [mockFixSpace("a", title: "Alpha"),
                                                                       mockFixSpace("b", title: "Beta")])
    defer { enabledWindow.contentViewController = nil }
    let (disabledWindow, disabled) = try await mockFixDeleteButton(spaces: [mockFixSpace("a", title: "Alpha")])
    defer { disabledWindow.contentViewController = nil }
    let lit = try reddestPixel(in: enabledWindow, rect: enabled)
    let faded = try reddestPixel(in: disabledWindow, rect: disabled)
    #expect(lit > 0.25, "the enabled label is red: \(lit)")
    #expect(faded < lit - 0.15, "the disabled label is dimmed: \(faded) vs \(lit)")
    #expect(faded > lit * 0.2, "the disabled label is not dimmed twice: \(faded) vs \(lit)")
}

@Test @MainActor
func theSitePagesClearIsDrawnInTheBoardsRed() async throws {
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
    let spaces = [mockFixSpace("a", title: "Alpha"), mockFixSpace("b", title: "Be"), mockFixSpace("c", title: "C")]
    let model = mockFixModel(spaces: spaces)
    // "Be" has no ⌃N; its count must still sit in the same column as the others'.
    model.spaceKeys = [0: ["⌃", "1"], 2: ["⌃", "3"]]
    model.navigate(.spaces)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let probe = try #require(controller.checkProbe())
    try await waitUntil {
        probe.layout()
        return ["a", "b", "c"].allSatisfy {
            probe.marker(SettingsModel.spaceCountMarker($0)) != nil && probe.marker(SettingsModel.spaceIconMarker($0)) != nil
        } && probe.marker(SettingsModel.spaceKeysMarker("a")) != nil
    }
    let ids = ["a", "b", "c"]
    let counts = ids.map { probe.marker(SettingsModel.spaceCountMarker($0))! }
    let icons = ids.map { probe.marker(SettingsModel.spaceIconMarker($0))! }
    // One column per trailing control: the names differ in length and one row has no ⌃N, yet no
    // count moves with either.
    #expect(counts.allSatisfy { abs($0.width - SettingsMetrics.spaceCountColumn) <= 1 })
    #expect(counts.allSatisfy { abs($0.minX - counts[0].minX) <= 1 && abs($0.maxX - counts[0].maxX) <= 1 })
    let defaultKeys = try #require(probe.marker(SettingsModel.spaceKeysMarker("a")))
    #expect(abs(defaultKeys.width - SettingsMetrics.spaceKeysColumn) <= 1)
    #expect(counts[0].maxX + 4 <= defaultKeys.minX, "the count column ends before the keycaps")
    // The icon letter sits on the board's 24 pt tile, away from the name.
    #expect(icons.allSatisfy { abs($0.width - 24) <= 1 && abs($0.height - 24) <= 1 })
    let tile = try #require(probe.marker(SettingsModel.spaceIconMarker("a")))
    let row = try #require(probe.marker(SettingsModel.rowMarker("space-a")))
    let pixels = try mockFixPixels(in: window, rect: tile.insetBy(dx: 4, dy: 10))
    let card = try mockFixPixels(in: window, rect: NSRect(x: row.minX + 4, y: row.midY, width: 1, height: 1))
    let tileGrey = try #require(pixels.first?.usingColorSpace(.deviceGray)?.whiteComponent)
    let cardGrey = try #require(card.first?.usingColorSpace(.deviceGray)?.whiteComponent)
    #expect(abs(tileGrey - cardGrey) > 0.03, "the tile's grey is drawn under the letter: \(tileGrey) vs \(cardGrey)")

    // A custom binding wider than the default column grows the keycaps and pushes only that row's
    // count left, so the caps never overlap the count (F3).
    model.spaceKeys = [0: ["⌃", "⌥", "⇧", "1"], 2: ["⌃", "3"]]
    try await waitUntil {
        probe.layout()
        return (probe.marker(SettingsModel.spaceKeysMarker("a"))?.width ?? 0) > SettingsMetrics.spaceKeysColumn + 20
    }
    let longKeys = try #require(probe.marker(SettingsModel.spaceKeysMarker("a")))
    let shortKeys = try #require(probe.marker(SettingsModel.spaceKeysMarker("c")))
    let pushed = try #require(probe.marker(SettingsModel.spaceCountMarker("a")))
    let other = try #require(probe.marker(SettingsModel.spaceCountMarker("c")))
    #expect(longKeys.width > SettingsMetrics.spaceKeysColumn + 20)
    #expect(abs(longKeys.maxX - shortKeys.maxX) <= 1, "the column ends at the same trailing edge")
    #expect(pushed.maxX + 4 <= longKeys.minX, "the long caps push the count left, not over it")
    #expect(pushed.maxX < other.maxX - 20)
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
