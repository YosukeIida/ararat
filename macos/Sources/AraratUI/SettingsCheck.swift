import AppKit
import AraratKit
import SwiftUI

/// One rail pane as the check reads it: the id the check names (`--ararat-screen=settings-<id>`)
/// and the title the rail and the header draw.
public struct SettingsRailPaneInfo: Sendable {
    public let id: String
    public let title: String
}

/// What a settings screen check reads from the running window. The VM's accessibility tree is
/// empty in process (as `SidebarChecks.swift` says), so the probe finds the views by the
/// identifiers `SettingsMarker` sets and reports frames, the model's state and pixels; the check
/// in the app drives it through the same functions the window's own controls call.
@MainActor
public final class SettingsCheckProbe {
    private let controller: SettingsWindowController
    private let window: NSWindow

    init(controller: SettingsWindowController, window: NSWindow) {
        self.controller = controller
        self.window = window
    }

    public var model: SettingsModel { controller.model }
    public var windowFrame: NSRect { window.frame }
    public var isVisible: Bool { window.isVisible }
    public var isKey: Bool { window.isKeyWindow }

    /// Lays the tree out before a frame read: SwiftUI updates a frame on the next layout pass.
    public func layout() { window.contentView?.layoutSubtreeIfNeeded() }

    public var title: String { model.title }
    public var subtitle: String { model.subtitle }
    public var paneID: String { model.page.paneID.rawValue }
    public var railPanes: [SettingsRailPaneInfo] {
        SettingsRegistry.built.map { SettingsRailPaneInfo(id: $0.id.rawValue, title: $0.title) }
    }

    public var query: String { model.query }
    public func setQuery(_ query: String) { model.query = query }
    public var resultTitles: [String] { model.results.map { model.resultTitle($0) } }
    public var groupPaneIDs: [String] { model.resultGroups.map { $0.pane.id.rawValue } }
    public var groupRowCounts: [Int] { model.resultGroups.map { $0.rows.count } }
    public var noResults: Bool { model.results.isEmpty }
    public var selectedIndex: Int { model.searchIndex }
    public var selectedResultTitle: String? { model.selectedResult.map { model.resultTitle($0) } }
    public var selectedResultID: String? { model.selectedResult?.id }
    /// The page the selected result opens: its own registry page (a space page for a space row),
    /// so a check asserts the navigation against the result it chose, not a fixed pane name.
    public var selectedResultPageID: String? { model.selectedResult.map { $0.pane.searchKey } }
    public var selectedResultMarker: String? { model.selectedResult.map { SettingsModel.resultMarker($0) } }
    public var highlightedRowID: String? { model.highlighted }
    public var highlightedMarker: String? { model.highlighted.map { SettingsModel.rowMarker($0) } }
    public var historyIndex: Int { model.historyIndex }
    public var canGoBack: Bool { model.historyIndex > 0 }
    public var spaceIDs: [String] { model.snapshot.spaces.map(\.id) }
    public func searchKey(_ key: SettingsSearchKey) -> Bool { model.handleSearchKey(key) }

    // MARK: U27c, the Spaces pane's scroll direction

    public var spaceScrollDirection: SpaceScrollDirection { model.spaceScrollDirection }
    public var spaceScrollDirectionLabel: String { model.spaceScrollDirectionLabel }
    public func setSpaceScrollDirection(_ value: SpaceScrollDirection) { model.setSpaceScrollDirection(value) }
    /// The Spaces pane itself, so the check can return to it after pushing a space page.
    public func openSpacesPane() { model.navigate(.spaces) }

    // MARK: U27d, the Appearance pane

    /// The two switches, and the Look row's page push, so the check drives the same setters the
    /// pane's bindings call.
    public var newTabRowShown: Bool { model.newTabRowShown }
    public var tooltipsShown: Bool { model.tooltipsShown }
    public func setNewTabRowShown(_ value: Bool) { model.setNewTabRowShown(value) }
    public func setTooltipsShown(_ value: Bool) { model.setTooltipsShown(value) }
    public func openLook() { model.openLook() }
    /// The New Tab row's height, which the Today rows close up by when it is hidden (T4).
    public var newTabRowHeight: CGFloat { SidebarMetrics.newTabRowHeight }

    // MARK: U27k, the Appearance pane's Theme

    /// The stored theme the pane draws, and the same setter its picker calls.
    public var theme: Theme { model.theme }
    public var themeLabel: String { model.theme.label }
    public func setTheme(_ value: Theme) { model.setTheme(value) }
    /// What the app and this window resolve to. `appAppearance` is what the theme set on
    /// `NSApp.appearance` (nil for System, the Mac's own).
    public var appAppearanceName: String? { NSApp.appearance?.name.rawValue }
    public var windowAppearanceName: String { window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])?.rawValue ?? window.effectiveAppearance.name.rawValue }

    // MARK: U27i, the Little Window pane

    /// The pane's five stored values and the same setters its controls call.
    public var littleWindowOpenIn: LittleWindowOpenIn { model.littleWindowOpenIn }
    public var littleWindowCloseAfter: Bool { model.littleWindowCloseAfter }
    public var littleWindowRememberFrame: Bool { model.littleWindowRememberFrame }
    public var littleWindowHotKey: LittleWindowHotKey? { model.littleWindowHotKey }
    public var littleWindowHotKeyMessage: String? { model.hotKeyMessage }
    public var littleWindowHotKeyRecording: Bool { model.hotKeyRecording }
    public var littleWindowHotKeyStatus: GlobalHotKeyStatus? { model.hotKeyCenter?.status }
    public var littleWindowOpenInLabel: String { model.littleWindowOpenInLabel }
    public func setLittleWindowOpenIn(_ value: LittleWindowOpenIn) { model.setLittleWindowOpenIn(value) }
    public func setLittleWindowCloseAfter(_ value: Bool) { model.setLittleWindowCloseAfter(value) }
    public func setLittleWindowRememberFrame(_ value: Bool) { model.setLittleWindowRememberFrame(value) }
    public func startLittleWindowHotKeyRecording() { model.toggleLittleWindowHotKeyRecording() }
    public func cancelLittleWindowHotKeyRecording() { model.cancelLittleWindowHotKeyRecording() }
    public func recordLittleWindowHotKey(_ event: NSEvent) { model.handleLittleWindowHotKeyEvent(event) }
    public func openAirTraffic() { model.openAirTraffic() }
    public func openLittleWindowPane() { model.navigate(.littleWindow) }
    /// The spaces the Open-in menu offers (the shown space's profile), so the check can pick one
    /// and name it in the bar's label.
    public var littleWindowSpaceIDs: [String] { model.littleWindowSpaces.map(\.id) }
    public func littleWindowSpaceTitle(_ id: String) -> String? { model.snapshot.spaces.first { $0.id == id }?.title }
    /// The keycaps the row shows, for the check's recorder condition.
    public var littleWindowHotKeyCaps: [String] { LittleWindowHotKeyRecorder.caps(model.littleWindowHotKey) }

    // MARK: U27w, the Websites pane

    /// The seven defaults the pane draws, read from the core, and the same setter its menus call.
    public var siteDefaults: SiteDefaults { model.siteDefaults }
    public func setSiteDefault(_ kind: SitePermissionKind, _ value: SitePermissionValue) { model.setSiteDefault(kind, value) }
    /// The engine is the source of the site rows: the check re-reads the list through the same
    /// call the window makes on every open.
    public func readWebsites() { model.readWebsites() }
    public func refreshSiteExceptions() { model.refreshSiteExceptions() }
    public var siteRows: [SettingsSiteRow] { model.siteRows }
    public var siteProfiles: [String] { model.siteProfiles }
    public func siteSummary(_ row: SettingsSiteRow) -> String {
        SettingsModel.siteSummary(row, profiles: model.siteProfiles)
    }
    public func openSite(_ origin: String, _ profile: String) { model.openSite(origin: origin, profile: profile) }
    public func openWebsitesPane() { model.navigate(.websites) }
    @discardableResult
    public func setSitePermission(origin: String, profile: String, kind: SitePermissionKind,
                                  setting: SiteState.PermissionSetting?) -> Bool {
        model.setSitePermission(origin: origin, profile: profile, kind: kind, setting: setting)
    }
    public func resetSitePermissions(origin: String, profile: String) {
        model.resetSitePermissions(origin: origin, profile: profile)
    }
    public func clearSiteData(origin: String, profile: String, completion: (() -> Void)? = nil) {
        model.clearSiteData(origin: origin, profile: profile, completion: completion)
    }

    // MARK: U27x, the Extensions pane

    /// The chooser, its list and the same setters the pane's switch, Review…, … menu and rows call.
    public var extensionProfiles: [String] { model.extensionProfiles }
    public var extensionProfile: String { model.extensionProfile }
    public var extensions: [SettingsExtension] { model.extensions }
    public var extensionsLoading: Bool { model.extensionsLoading }
    public func readExtensions(shownSpaceID: String?) { model.readExtensions(shownSpaceID: shownSpaceID) }
    public func refreshExtensions() { model.refreshExtensions() }
    public func selectExtensionProfile(_ profile: String) { model.selectExtensionProfile(profile) }
    @discardableResult
    public func setExtensionEnabled(_ id: String, _ enabled: Bool) -> Bool { model.setExtensionEnabled(id, enabled: enabled) }
    @discardableResult
    public func setExtensionSiteAccess(_ id: String, _ access: ExtensionSiteAccess) -> Bool {
        model.setExtensionSiteAccess(id, access: access)
    }
    @discardableResult
    public func toggleExtensionPin(_ id: String) -> Bool { model.toggleExtensionPin(id) }
    public func reviewExtension(_ id: String) { model.reviewExtension(id) }
    public func requestRemoveExtension(_ id: String) { model.requestRemoveExtension(id) }
    public var pendingRemoval: SettingsExtension? { model.pendingRemoval }
    public static func removeSheetTitle(for name: String) -> String {
        SettingsModel.removeSheetTitle(for: name)
    }
    public static let removeSheetText = SettingsModel.removeSheetText
    public func extensionMenuTitles(_ row: SettingsExtension) -> [String] {
        SettingsModel.extensionMenu(row).filter { $0 != .separator }.map(\.title)
    }
    public func extensionRow(id: String) -> SettingsExtension? { model.extensionRow(id: id) }

    // MARK: U27p, the Privacy pane

    /// The record the pane draws, read from the core, and the same setters its menu and switch call.
    public var privacy: PrivacySettings { model.privacy }
    public var privacyProfile: String { model.privacyProfile }
    public var privacyLoaded: Bool { model.privacyLoaded }
    public func readPrivacy(shownSpaceID: String?) { model.readPrivacy(shownSpaceID: shownSpaceID) }
    /// M4: puts a value the core does not hold in the model before a reopen, so the check's
    /// `reopen_reads_record` can only pass on a read that really answered.
    public func resetPrivacyForRead() { model.privacy = .board }
    public func setThirdPartyCookies(_ value: ThirdPartyCookies) { model.setThirdPartyCookies(value) }
    public func setGlobalPrivacyControl(_ value: Bool) { model.setGlobalPrivacyControl(value) }
    public func setHistoryRetention(_ value: HistoryRetention) { model.setHistoryRetention(value) }
    /// P4's sheet: the same open, choose, cancel and Clear the pane and the sheet call.
    public var clearSheetShown: Bool { model.clearSheetShown }
    public var clearSheetVisible: Bool { window.attachedSheet != nil }
    public var clearRange: ClearBrowsingRange { model.clearRange }
    public var clearTypes: ClearBrowsingTypes { model.clearTypes }
    public var clearing: Bool { model.clearing }
    public func openClearSheet() { model.openClearSheet() }
    public func cancelClearSheet() { model.cancelClearSheet() }
    public func confirmClearSheet() { model.confirmClearSheet() }
    public func setClearRange(_ value: ClearBrowsingRange) { model.clearRange = value }
    public func setClearTypes(_ value: ClearBrowsingTypes) { model.clearTypes = value }
    /// A marker inside the sheet the window presents, top-down in the sheet's own content.
    public func sheetMarker(_ id: String) -> NSRect? {
        guard let content = window.attachedSheet?.contentView else { return nil }
        guard let view = views(content).first(where: { $0.identifier?.rawValue == id }) else { return nil }
        return topDown(view.convert(view.bounds, to: content), in: content)
    }
    public var clearSheetTitle: String? {
        guard let content = window.attachedSheet?.contentView else { return nil }
        return views(content).compactMap { $0 as? NSTextField }.first { $0.stringValue == "Clear browsing data" }?.stringValue
    }

    // MARK: frames

    private var content: NSView? { window.contentView }

    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    /// Frames are reported top-down whatever the content view's own flip is: a smaller y is
    /// higher on screen, so a check can say "above", "below" and "gap" without knowing AppKit's
    /// convention. The greys read in the same space.
    private func topDown(_ rect: NSRect, in content: NSView) -> NSRect {
        guard !content.isFlipped else { return rect }
        return NSRect(x: rect.minX, y: content.bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The frame of a marker's view, top-down in the window content's coordinates.
    public func marker(_ id: String) -> NSRect? {
        guard let content else { return nil }
        guard let view = views(content).first(where: { $0.identifier?.rawValue == id }) else { return nil }
        return topDown(view.convert(view.bounds, to: content), in: content)
    }

    /// Every marker whose identifier starts with `prefix`, top to bottom.
    public func markers(prefix: String) -> [(id: String, frame: NSRect)] {
        guard let content else { return [] }
        return views(content).compactMap { view in
            guard let id = view.identifier?.rawValue, id.hasPrefix(prefix) else { return nil }
            return (id, topDown(view.convert(view.bounds, to: content), in: content))
        }.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// The rail's rows in rail order (their markers carry the pane ids).
    public var railRows: [(id: String, frame: NSRect)] { markers(prefix: "rail-") }
    public var railWidth: CGFloat? { marker(SettingsModel.railMarkerID)?.width }

    // MARK: pixels

    /// Reads the greys the content view's cached bitmap holds at `points`, top-down in the
    /// content's coordinates. `nil` entries mean the read failed, so the caller decides whether
    /// to retry.
    public func greys(at points: [NSPoint]) -> [Int?] {
        guard let content, !content.bounds.isEmpty,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            return points.map { _ in nil }
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / max(1, content.bounds.width)
        return points.map { point in
            let px = Int(point.x * scale)
            let py = Int(point.y * scale)
            guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh else { return nil }
            return bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceGray).map { Int(($0.whiteComponent * 255).rounded()) }
        }
    }

    // MARK: the detail pane

    /// The pane's scroll view: the detail split item's, not the rail's.
    public var detailScrollView: NSScrollView? {
        guard let split = window.contentViewController as? NSSplitViewController,
              split.splitViewItems.count > 1 else { return nil }
        let detail = split.splitViewItems[1].viewController.view
        return views(detail).compactMap { $0 as? NSScrollView }.first
    }

    public var detailScrollOffset: CGFloat? { detailScrollView?.contentView.bounds.minY }

    /// Scrolls the pane like a pointer would, so the header fade and the scroll-to-row paths run.
    @discardableResult
    public func scrollDetail(to y: CGFloat) -> Bool {
        guard let scroll = detailScrollView else { return false }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scroll.reflectScrolledClipView(scroll.contentView)
        return true
    }

    public var headerProgress: Double { model.headerProgress }
    public var pageID: String { model.page.searchKey }
}
