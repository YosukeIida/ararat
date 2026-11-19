import AppKit
import AraratKit
import Testing
@testable import AraratUI

@Test @MainActor
func captureOverlayInstallsMonitorOnlyWhileAttached() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                          styleMask: [.titled], backing: .buffered, defer: false)
    let overlay = SiteCaptureOverlay(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    #expect(!overlay.checkEscapeMonitorInstalled)
    window.contentView?.addSubview(overlay)
    #expect(overlay.window === window)
    #expect(overlay.checkEscapeMonitorInstalled)
    overlay.removeFromSuperview()
    #expect(!overlay.checkEscapeMonitorInstalled)
}

private func permissionRow(type: String = "geolocation",
                           setting: Any? = ["kind": "geolocation", "approximate": "block", "precise": "block"],
                           mutable: Bool = true,
                           allowed: [[String: Any]] = [
                               ["kind": "content", "value": "allow"],
                               ["kind": "content", "value": "block"],
                               ["kind": "content", "value": "ask"],
                           ]) -> [String: Any] {
    [
        "type": type, "requestingOrigin": "", "embeddingOrigin": "https://127.0.0.1:4444",
        "setting": setting ?? NSNull(), "defaultSetting": ["kind": "geolocation", "approximate": "ask", "precise": "ask"],
        "source": "user", "mutable": mutable, "allowed": allowed, "siteSpecificBlock": true,
    ]
}

@Test @MainActor
func siteStateParsesSnapshotAndPermissionSettings() throws {
    let snapshot: [String: Any] = [
        "document": "7", "origin": "https://127.0.0.1:4444", "security": "secure",
        "certificateChain": [Data([1, 2, 3])], "permissions": [permissionRow()],
        "blocked": true, "internal": false,
    ]
    let state = try #require(SiteState(snapshot))
    #expect(state.document == "7")
    #expect(state.security == "secure")
    #expect(state.isSecure)
    #expect(state.certificateChain.count == 1)
    #expect(state.blocked)
    #expect(state.permissions.count == 1)
    let row = state.permissions[0]
    #expect(row.displayName == "Location")
    #expect(row.isExplicit)
    #expect(row.setting?.title == "Block")
    #expect(row.setting?.isBlock == true)
    #expect(row.mutable)
    #expect(row.allowed.map(\.title) == ["Allow", "Block", "Ask"])
    #expect(row.defaultSetting?.title == "Ask")
    #expect(row.current?.title == "Block")
}

@Test @MainActor
func siteStateTreatsMissingSettingAsDefaultAndReadOnly() throws {
    let state = try #require(SiteState([
        "document": "3", "origin": "http://127.0.0.1:5555", "security": "not_secure",
        "certificateChain": [Data](), "permissions": [permissionRow(setting: nil, mutable: false, allowed: [])],
        "blocked": false, "internal": false,
    ]))
    let row = state.permissions[0]
    #expect(row.setting == nil)
    #expect(!row.isExplicit)
    #expect(row.isReadOnly)
    #expect(row.current?.title == "Ask")
    #expect(state.certificateChain.isEmpty)
    #expect(!state.canShowCertificate)
}

@Test @MainActor
func internalSnapshotHasNoPermissions() throws {
    let state = try #require(SiteState([
        "document": "9", "origin": "chrome://version/", "security": "none",
        "certificateChain": [Data](), "permissions": [[String: Any]](), "blocked": false, "internal": true,
    ]))
    #expect(state.isInternal)
    #expect(state.permissions.isEmpty)
    #expect(state.security == "none")
    #expect(!state.canShowCertificate)
}

@Test @MainActor
func permissionMenuMapsMixedGeolocationPairsWithoutDuplicatingUniformTitles() {
    let allow = SiteState.PermissionSetting(dictionary: ["kind": "geolocation", "approximate": "allow", "precise": "block"])
    #expect(allow?.title == "Allow approximate, Block precise")
    let precise = SiteState.PermissionSetting(dictionary: ["kind": "geolocation", "approximate": "ask", "precise": "allow"])
    #expect(precise?.title == "Ask approximate, Allow precise")
    // Every mixed pair is distinct.
    let pairs = ["allow", "block", "ask"].flatMap { approximate in
        ["allow", "block", "ask"].map { precise in
            SiteState.PermissionSetting(dictionary: ["kind": "geolocation", "approximate": approximate, "precise": precise])?.title
        }
    }.compactMap { $0 }
    #expect(pairs.count == 9)
    #expect(Set(pairs).count == 9)
    #expect(SiteState.PermissionSetting(dictionary: ["kind": "content", "value": "session_only"])?.title == "Allow for session")
    #expect(SiteState.PermissionSetting(dictionary: ["kind": "unsupported"]) == nil)
}

@Test @MainActor
func extensionActionRowUsesFavouriteColumnsAndOneRow() throws {
    let icon = NSImage(size: NSSize(width: 16, height: 16))
    func item(_ index: Int) throws -> ExtensionActionItem {
        try #require(ExtensionActionItem([
            "id": "a\(index)", "name": "Probe \(index)", "tooltip": "Probe", "icon": icon,
            "enabled": true, "pinned": true, "pinMutable": true, "removable": true,
            "badgeText": "", "badgeBackgroundColor": 0, "badgeTextColor": 0,
        ]) as ExtensionActionItem?)
    }
    let row = ExtensionActionsRow(frame: NSRect(x: 0, y: 0, width: 224, height: 32))
    row.columns = 4
    row.update(items: try (0..<3).map(item))
    row.layoutSubtreeIfNeeded()
    #expect(row.checkRowHeight == 32)
    let frames = row.checkFrames
    #expect(frames.count == 3)
    #expect(abs((frames["a0"]?.width ?? 0) - ((224 + 8) / 4 - 8)) <= 0.5)
    #expect(frames.values.allSatisfy { $0.height == 32 })
    #expect(ExtensionActionsStrip.width(for: 0) == 0)
    #expect(ExtensionActionsStrip.width(for: 2) == 52)
}

@Test @MainActor
func extensionActionButtonsDrawTheEngineIconAtItsRequestedSize() throws {
    // The app asks the engine for 16 pt icons (main.swift refreshExtensionActions); the button
    // draws the item's image as delivered, so a regression of that request fails the check's
    // icons16 condition and this test's size.
    let icon = NSImage(size: NSSize(width: 16, height: 16))
    let item = try #require(ExtensionActionItem([
        "id": "a0", "name": "Probe", "tooltip": "Probe", "icon": icon,
        "enabled": true, "pinned": true, "pinMutable": true, "removable": true,
        "badgeText": "", "badgeBackgroundColor": 0, "badgeTextColor": 0,
    ]) as ExtensionActionItem?)
    let strip = ExtensionActionsStrip(frame: NSRect(x: 0, y: 0, width: 28, height: 24))
    strip.update(items: [item])
    strip.layoutSubtreeIfNeeded()
    #expect(strip.checkButton("a0")?.checkIconSize == NSSize(width: 16, height: 16))
    let row = ExtensionActionsRow(frame: NSRect(x: 0, y: 0, width: 224, height: 32))
    row.columns = 4
    row.update(items: [item])
    row.layoutSubtreeIfNeeded()
    #expect(row.checkButton("a0")?.checkIconSize == NSSize(width: 16, height: 16))
    #expect(row.checkButton("a0")?.image === item.icon)
    #expect(strip.checkButton("a0")?.layer?.backgroundColor == nil)
    let tile = try #require(row.checkButton("a0"))
    #expect(tile.layer?.cornerRadius == 8)
    tile.appearance = NSAppearance(named: .aqua)
    #expect(tile.layer?.backgroundColor?.alpha == 0.55)
    tile.appearance = NSAppearance(named: .darkAqua)
    #expect(tile.layer?.backgroundColor?.alpha == 0.08)
}

@Test @MainActor
func extensionActionRowsWrapRatherThanDroppingPinnedActions() throws {
    let icon = NSImage(size: NSSize(width: 16, height: 16))
    func item(_ index: Int) throws -> ExtensionActionItem {
        try #require(ExtensionActionItem([
            "id": "a\(index)", "name": "Probe \(index)", "tooltip": "Probe", "icon": icon,
            "enabled": true, "pinned": true, "pinMutable": true, "removable": true,
            "badgeText": "", "badgeBackgroundColor": 0, "badgeTextColor": 0,
        ]) as ExtensionActionItem?)
    }
    let row = ExtensionActionsRow(frame: NSRect(x: 0, y: 0, width: 148, height: 96))
    row.columns = 2
    row.update(items: try (0..<5).map(item))
    row.layoutSubtreeIfNeeded()
    #expect(row.checkRowHeight == 96)
    let frames = row.checkFrames
    #expect(frames.count == 5)
    #expect(Set(frames.values.map { $0.minY }).count == 3)
    #expect(frames.values.allSatisfy { $0.height == 32 })
}

@Test @MainActor
func permissionRowWithoutExplicitSettingShowsItsDefaultNotAllow() throws {
    let state = try #require(SiteState([
        "document": "4", "origin": "https://127.0.0.1:4444", "security": "secure",
        "certificateChain": [Data](),
        "permissions": [permissionRow(setting: nil, mutable: true)],
        "blocked": false, "internal": false,
    ]))
    let content = SiteControlsContent(model: state, includesFullPage: false)
    let rows = content.checkPermissionRows
    #expect(rows.count == 1)
    // The current value is the default, shown as its own selected line, never item 0 ("Allow").
    #expect(rows[0].current == "Ask (default)")
    #expect(rows[0].items == ["Allow", "Block", "Ask"])
}

@Test @MainActor
func refusedPermissionChoiceRestoresTheCurrentPopupValue() throws {
    let state = try #require(SiteState([
        "document": "4", "origin": "https://127.0.0.1:4444", "security": "secure",
        "certificateChain": [Data](), "permissions": [permissionRow(setting: nil)],
        "blocked": false, "internal": false,
    ]))
    let content = SiteControlsContent(model: state, includesFullPage: false)
    func popups(_ view: NSView) -> [NSPopUpButton] {
        view.subviews.flatMap { ($0 as? NSPopUpButton).map { [$0] } ?? popups($0) }
    }
    let popup = try #require(popups(content).first)
    let allow = try #require(popup.itemArray.first { $0.title == "Allow" })
    var requested = false
    content.onPermission = { _ in requested = true; return false }
    popup.select(allow)
    #expect(popup.titleOfSelectedItem == "Allow")
    let target = try #require(allow.target as? NSObject)
    target.perform(try #require(allow.action), with: allow)
    #expect(requested)
    #expect(content.checkPermissionRows[0].current == "Ask (default)")
}

@Test @MainActor
func extensionActionRowWrapsBeyondOneLine() throws {
    let icon = NSImage(size: NSSize(width: 16, height: 16))
    func item(_ index: Int) throws -> ExtensionActionItem {
        try #require(ExtensionActionItem([
            "id": "b\(index)", "name": "Probe \(index)", "tooltip": "Probe", "icon": icon,
            "enabled": true, "pinned": true, "pinMutable": true, "removable": true,
            "badgeText": "", "badgeBackgroundColor": 0, "badgeTextColor": 0,
        ]) as ExtensionActionItem?)
    }
    let row = ExtensionActionsRow(frame: NSRect(x: 0, y: 0, width: 148, height: 96))
    row.columns = 2
    row.update(items: try (0..<5).map(item))
    row.layoutSubtreeIfNeeded()
    // Five actions over two columns take three 32 pt lines; none is hidden.
    #expect(row.requiredHeight == 96)
    #expect(row.checkFrames.count == 5)
    #expect(row.checkFrames.values.allSatisfy { $0.maxY <= 96 })
}

@Test @MainActor
func extensionActionItemParsesEngineFields() throws {
    let icon = NSImage(size: NSSize(width: 16, height: 16))
    let item = try #require(ExtensionActionItem([
        "id": "abc", "name": "Probe", "tooltip": "Probe action", "icon": icon, "enabled": true,
        "pinned": true, "pinMutable": false, "removable": true, "badgeText": "3",
        "badgeBackgroundColor": 0xFFFF0000, "badgeTextColor": 0xFFFFFFFF,
    ]) as ExtensionActionItem?)
    #expect(item.badgeText == "3")
    #expect(item.pinned)
    #expect(!item.pinMutable)
    #expect(item.removable)
    #expect(item.icon.size == NSSize(width: 16, height: 16))
}

@Test @MainActor
func siteControlsContentKeepsArcGeometryAndWorkingRowsOnly() throws {
    let state = try #require(SiteState([
        "document": "1", "origin": "https://127.0.0.1:4444", "security": "secure",
        "certificateChain": [Data([0])], "permissions": [permissionRow(), permissionRow(type: "notifications", mutable: false, allowed: [])],
        "blocked": true, "internal": false,
    ]))
    let content = SiteControlsContent(model: state, includesFullPage: true)
    let size = content.preferredSize
    #expect(size.width == 262)
    #expect(size.height.truncatingRemainder(dividingBy: 8) == 0)
    #expect(content.actionTitles == ["Screenshot a region", "Capture the full page"])
    let rows = content.checkPermissionRows
    #expect(rows.count == 2)
    #expect(rows[0].items.contains("Reset"))
    #expect(rows[1].readOnly)
    #expect(rows[1].items.isEmpty)
}

@Test @MainActor
func siteControlsContentOmitsFullPageWhenTheConstantDropsIt() throws {
    let state = try #require(SiteState([
        "document": "1", "origin": "https://example.test", "security": "secure",
        "certificateChain": [Data](), "permissions": [[String: Any]](), "blocked": false, "internal": false,
    ]))
    let content = SiteControlsContent(model: state, includesFullPage: false)
    #expect(content.actionTitles == ["Screenshot a region"])
}
