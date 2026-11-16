import AppKit
import AraratKit
import SwiftUI

@MainActor
public final class SettingsModel: ObservableObject {
    enum Page: Hashable { case general, websites, tabs, shortcuts, airTraffic, appearance, spaces, littleWindow, privacy, extensions, space(String), site(String, String) }
    struct Row: Identifiable, Equatable {
        let id: String
        let pane: Page
        let title: String
        let subtitle: String
        var keys: [String] = []
        var command: String? = nil
        var customized = false
        var conflicting = false
    }
    @Published var snapshot: WorkspaceSnapshot
    @Published var page: Page = .spaces
    @Published var query = "" { didSet { if query != oldValue { searchIndex = 0 } } }
    /// The result the search's arrows move and Return opens: the first one until an arrow moves
    /// it (D7). It is an index into `results`, which is why a new query starts it over.
    @Published var searchIndex = 0
    @Published var highlighted: String?
    @Published var error: String?
    @Published var pendingDelete: String?
    @Published var headerProgress = 0.0
    @Published private(set) var history: [Page] = [.spaces]
    @Published private(set) var historyIndex = 0
    @Published var shortcutQuery = "" { didSet { keyBindings.clearError() } }
    @Published var customizedOnly = false { didSet { keyBindings.clearError() } }
    @Published var conflictingOnly = false { didSet { keyBindings.clearError() } }
    var adapter: WorkspaceAdapter
    var keyBindings: KeyBindingsModel
    var airTraffic: AirTrafficModel
    var preview: (String, Look?, Bool) -> Void
    var publish: (WorkspaceSnapshot) -> Void
    private(set) var contextGeneration = 0
    private var lookPreviewOwners: [String: UUID] = [:]
    var checkEditCompletion: ((@escaping () -> Void) -> Void)?
    var resetWidth: () -> Void
    @Published var shortcuts: [Row] = []
    @Published var spaceKeys: [Int: [String]] = [:]
    /// The Spaces pane's scroll direction (U27c): read from the workspace's settings record, so
    /// a reopen shows the stored value, and written through the same record the sidebar reads.
    @Published var spaceScrollDirection: SpaceScrollDirection = .natural
    /// Hands a written direction to the browser windows' sidebars; the app sets it, the pane and
    /// the settings window read `spaceScrollDirection` and the paging pipeline directly.
    var spaceScroll: (SpaceScrollDirection) -> Void = { _ in }
    /// U27d, the Appearance pane: the New Tab row switch and the Tooltips switch, both read from
    /// the workspace's settings record on open and written through it. The app hands each written
    /// value to every window that shows the workspace, as it does the scroll direction.
    @Published var newTabRowShown = true
    @Published var tooltipsShown = true
    var newTabRow: (Bool) -> Void = { _ in }
    var tooltips: (Bool) -> Void = { _ in }
    /// U27k: the Theme, in the same synced record. The app applies a written value to
    /// `NSApp.appearance`, so every window, the settings window, popovers and menus follow it.
    @Published var theme: Theme = .system
    var themeApplied: (Theme) -> Void = { _ in }
    /// U27i: the Little Window pane. The Open-in destination and close-after are the synced
    /// settings; "Remember its size and place" and the global shortcut are the device record.
    /// The shortcut's registration is the app-wide center, which the app hands in.
    @Published var littleWindowOpenIn: LittleWindowOpenIn = .mostRecent
    @Published var littleWindowCloseAfter = true
    @Published var littleWindowRememberFrame = true
    @Published var littleWindowHotKey: LittleWindowHotKey? = LittleWindowHotKeyRecorder.defaultHotKey
    @Published var hotKeyRecording = false
    @Published var hotKeyMessage: String?
    var hotKeyCenter: LittleWindowHotKeyCenter?
    /// Hands the written values to the Little Windows already open, so a change applies there
    /// too (the bar's label, the next Open in and the frame the close writes).
    var littleWindowSettings: (LittleWindowOpenIn, Bool, Bool) -> Void = { _, _, _ in }
    /// U27w W1/W2: the Websites pane. The seven defaults are the synced core record; the engine
    /// is the source of the per-site exceptions, read on every open. The host is the app's
    /// engine bridge (a fake in the model tests), and a written default goes to Chromium's
    /// profiles through the app's handler.
    @Published var siteDefaults: SiteDefaults = .board
    @Published private(set) var siteExceptions: [SiteException] = []
    /// The regular profiles the workspace names, in the order the snapshot lists them: a site
    /// row names its profile only when there is more than one (W2).
    @Published private(set) var siteProfiles: [String] = []
    var siteHost: SiteSettingsHost?
    var siteDefaultsApplied: (SiteDefaults) -> Void = { _ in }
    /// P5b: the General pane. The default-browser status is read through LaunchServices and
    /// refreshed when the app becomes active (the user may change it in System Settings), Make
    /// Default asks the same setter onboarding's screen 4 uses, and When Ararat opens and the
    /// downloads pair are the synced core record — the app pushes the downloads record into
    /// Chromium's prefs on every write and at every window start. The folder panel is the
    /// window's, so no model test opens one.
    @Published private(set) var defaultBrowserIsDefault = false
    @Published var startup: StartupBehavior = .restoreWindows
    @Published var downloads: DownloadDevice = .board
    /// Whether the last `readGeneral` answered both core reads. The check waits for it before
    /// comparing the rows, so its conditions cannot pass on the model's initial values.
    @Published private(set) var generalLoaded = false
    var defaultBrowserStatus: DefaultBrowserStatus = LaunchServicesDefaultBrowserStatus()
    var defaultBrowserSetter: DefaultBrowserSetter = LaunchServicesDefaultBrowser()
    var downloadsApplied: (DownloadDevice) -> Void = { _ in }
    /// The window's folder chooser: it presents the panel and calls `setDownloadDirectory` with
    /// the answer. A check injects the URL instead, so no panel is shown under a check.
    var chooseDownloadFolder: (() -> Void)?
    private var startupRead = false
    private var downloadsRead = false
    /// U27p P2/P3: the Privacy pane. The cookie choice, GPC signal and history retention are the
    /// synced core record, read on every open; a write goes to the core and then to every regular
    /// profile through the engine. `privacyProfile` is the profile of the window that opened
    /// Settings, which the clear sheet names and clears.
    @Published var privacy: PrivacySettings = .board
    @Published private(set) var privacyProfile = "Default"
    /// Whether the last `readPrivacy` answered. The check waits for it before comparing the rows,
    /// so its `rows`/`reopen_reads_record` conditions cannot pass on the model's initial value.
    @Published private(set) var privacyLoaded = false
    var privacyHost: PrivacySettingsHost?
    /// P4: the Clear browsing data sheet's state. The window presents it; its range and types are
    /// the model's, so the pane, the sheet and the check agree about what Clear sends.
    @Published var clearSheetShown = false
    @Published var clearRange: ClearBrowsingRange = .lastHour
    @Published var clearTypes: ClearBrowsingTypes = .all
    @Published private(set) var clearing = false
    /// U27x: the Extensions pane. The profile chooser lists the regular profiles the workspace
    /// names (X1) and defaults to the profile of the window that opened Settings; the rows are the
    /// engine's list for the chosen profile (X2, X3), re-read after every write and whenever the
    /// engine reports an install, removal, enable or disable elsewhere (X5).
    @Published var extensionProfiles: [String] = []
    @Published var extensionProfile = ""
    @Published private(set) var extensions: [SettingsExtension] = []
    /// X1: a profile that exists but whose space has not been shown is loaded on demand; while the
    /// engine answers "loading", the pane keeps its rows and does not draw the empty state.
    @Published private(set) var extensionsLoading = false
    var extensionHost: ExtensionSettingsHost?
    /// Opens chrome://extensions/?id= in a tab of the extension's profile, as the action's menu
    /// does; the app supplies it because it owns the tab.
    var extensionManage: (String, String) -> Void = { _, _ in }
    /// The settings window: the parent of Chromium's review prompt and of the pane's own Remove sheet.
    var extensionWindow: () -> NSWindow? = { nil }
    /// U27x (design decision B): Remove… asks in the pane's own AppKit sheet on the settings window.
    /// The model asks for it and the window presents it; the engine uninstalls through the registrar
    /// only after the sheet's Remove button. A removal reported elsewhere ends the sheet.
    @Published var pendingRemoval: SettingsExtension?
    var presentRemoveSheet: ((SettingsExtension) -> Void)?
    var dismissRemoveSheet: (() -> Void)?

    public init(snapshot: WorkspaceSnapshot, adapter: WorkspaceAdapter, publish: @escaping (WorkspaceSnapshot) -> Void, resetWidth: @escaping () -> Void, preview: @escaping (String, Look?, Bool) -> Void = { _, _, _ in }, keyBindings: KeyBindingsModel, airTraffic: AirTrafficModel) {
        self.snapshot = snapshot
        self.adapter = adapter
        self.keyBindings = keyBindings
        self.airTraffic = airTraffic
        self.preview = preview
        self.publish = publish
        self.resetWidth = resetWidth
    }

    public func update(snapshot: WorkspaceSnapshot) {
        let spaceIds = self.snapshot.spaces.map(\.id)
        self.snapshot = snapshot
        if case .space(let id) = page, !snapshot.spaces.contains(where: { $0.id == id }) { navigate(.spaces) }
        // A space deleted while the window is open moves its destination into the pane's
        // "Deleted space" set: the set is the core's answer, so it reloads with the spaces
        // instead of waiting for the next routing answer the pane triggers.
        if spaceIds != snapshot.spaces.map(\.id) { airTraffic.reloadDeletedSpaces() }
        siteProfiles = Self.profileOrder(snapshot, exceptions: siteExceptions)
        extensionProfiles = Self.extensionProfileOrder(snapshot)
        if !extensionProfiles.isEmpty, !extensionProfiles.contains(extensionProfile) {
            extensionProfile = extensionProfiles[0]
            refreshExtensions()
        }
    }

    public func retarget(snapshot: WorkspaceSnapshot, adapter: WorkspaceAdapter, publish: @escaping (WorkspaceSnapshot) -> Void,
                         resetWidth: @escaping () -> Void, preview: @escaping (String, Look?, Bool) -> Void,
                         keyBindings: KeyBindingsModel, airTraffic: AirTrafficModel) {
        for id in lookPreviewOwners.keys {
            preview(id, self.snapshot.spaces.first(where: { $0.id == id })?.look, false)
        }
        lookPreviewOwners.removeAll()
        contextGeneration += 1
        self.adapter = adapter
        self.publish = publish
        self.resetWidth = resetWidth
        self.preview = preview
        self.keyBindings = keyBindings
        self.airTraffic = airTraffic
        update(snapshot: snapshot)
    }

    func navigate(_ target: Page, highlight: String? = nil) {
        // A recording does not survive leaving the pane (L8); with L1 it also re-registers the key.
        cancelLittleWindowHotKeyRecording()
        error = nil
        highlighted = highlight
        headerProgress = 0
        if target != page {
            history = Array(history.prefix(historyIndex + 1)) + [target]
            historyIndex = history.count - 1
            page = target
        }
    }

    func go(_ delta: Int) {
        let index = historyIndex + delta
        guard history.indices.contains(index) else { return }
        error = nil
        historyIndex = index
        highlighted = nil
        headerProgress = 0
        let target = history[index]
        if case .space(let id) = target, !snapshot.spaces.contains(where: { $0.id == id }) { page = .spaces }
        else { page = target }
    }

    var space: SpaceSnapshot? {
        guard case .space(let id) = page else { return nil }
        return snapshot.spaces.first { $0.id == id }
    }
    /// The rail's panes, in the boards' order with only the built ones (D1).
    var panes: [SettingsPane] { SettingsRegistry.built }
    var title: String {
        if case .space = page, let space { return space.title }
        if case .site(let origin, _) = page { return SiteOrigin.display(origin) }
        return SettingsRegistry.pane(page: page).title
    }
    /// The header's icon, from the pane the page belongs to (a space page shows the space's own).
    var icon: String { SettingsRegistry.pane(page: page).icon }
    /// The header's one line: a space page names its tabs and profile, a site page its profile
    /// when there is more than one, a pane its own subtitle.
    var subtitle: String {
        if let space { return "\(tabCountLabel(space)) · \(space.profileName)" }
        if case .site(_, let profile) = page {
            return siteProfiles.count > 1 ? "Site settings · \(profile)" : "Site settings"
        }
        return SettingsRegistry.pane(page: page).subtitle
    }
    /// The pane says in plain words that the routing arrives with the engine.
    static let airTrafficSubtitle = "Links other apps hand to Ararat follow these routes once the browser engine arrives."
    /// The id the search result for the Air Traffic Control pane carries, and the id the pane's
    /// default destination card carries: a result scrolls to and fills the same row (§7).
    public static let airTrafficCardId = "air-traffic"
    /// U27c's card in the Spaces pane: the search result and the card share this id.
    public static let spaceScrollDirectionCardId = "space-scroll-direction"
    /// U27d's rows in the Appearance pane: the Theme card, the Look link, and the two switches in
    /// the board's "Sidebar" card. The search result and the row share each id.
    public static let themeRowId = "theme"
    public static let lookRowId = "look"
    public static let newTabRowId = "new-tab-row"
    public static let tooltipsRowId = "tooltips"
    /// The switches themselves, so a check can find the pair the board draws.
    public static let themeControlMarker = "theme-control"
    public static let newTabRowSwitchMarker = "new-tab-row-switch"
    public static let tooltipsSwitchMarker = "tooltips-switch"
    /// U27i's Little Window rows: the Air Traffic Control link, the global shortcut's recorder, the
    /// Open-in destination and the two switches. The search result and the row share each id.
    public static let littleWindowLinkRowId = "little-window-links"
    public static let littleWindowShortcutRowId = "little-window-shortcut"
    public static let littleWindowOpenInRowId = "little-window-open-in"
    public static let littleWindowCloseAfterRowId = "little-window-close-after"
    public static let littleWindowRememberRowId = "little-window-remember"
    public static let littleWindowShortcutRecorderMarker = "little-window-shortcut-recorder"
    public static let littleWindowOpenInMenuMarker = "little-window-open-in-menu"
    public static let littleWindowCloseAfterSwitchMarker = "little-window-close-after-switch"
    public static let littleWindowRememberSwitchMarker = "little-window-remember-switch"
    /// U27w's Websites pane: the two grouped cards, the seven defaults rows and their menus, the
    /// site rows and the empty state, then the site page's permission rows and its two buttons.
    /// A search result and its row share the row id, as the other panes' do.
    public static let websitesDefaultsCardID = "website-defaults"
    public static let websitesSitesCardID = "website-sites"
    public static let websitesEmptyMarker = "website-sites-empty"
    public static let siteResetRowID = "site-reset"
    public static let siteClearRowID = "site-clear"
    public static let siteResetButtonMarker = "site-reset-button"
    public static let siteClearButtonMarker = "site-clear-button"
    public static func websiteRowID(_ kind: SitePermissionKind) -> String { "website-" + kind.rawValue }
    public static func websiteMenuMarker(_ kind: SitePermissionKind) -> String { "website-menu-" + kind.rawValue }
    public static func websiteSiteRowID(_ row: SettingsSiteRow) -> String { "website-site-" + row.id }
    public static func sitePermissionRowID(_ kind: SitePermissionKind) -> String { "site-permission-" + kind.rawValue }
    public static func sitePermissionMenuMarker(_ kind: SitePermissionKind) -> String { "site-permission-menu-" + kind.rawValue }
    /// U27x's Extensions pane (X1–X3): the profile chooser row and its menu, the Installed card and
    /// its empty state, then one row per extension with its switch, Review… button and … menu.
    public static let extensionsProfileRowID = "extensions-profile"
    public static let extensionsListCardID = "extensions-installed"
    public static let extensionsEmptyMarker = "extensions-empty"
    public static let extensionsLoadingMarker = "extensions-loading"
    public static let extensionsProfileMenuMarker = "extensions-profile-menu"
    public static func extensionRowID(_ id: String) -> String { "extension-" + id }
    public static func extensionSwitchMarker(_ id: String) -> String { "extension-switch-" + id }
    public static func extensionReviewMarker(_ id: String) -> String { "extension-review-" + id }
    public static func extensionMenuMarker(_ id: String) -> String { "extension-menu-" + id }
    /// P5b's General pane: the default-browser row and its two faces, When Ararat opens and its
    /// menu, then the download folder row, its Choose… button and the ask-each-file switch. A
    /// search result and its row share the row id, as the other panes' do.
    public static let defaultBrowserRowID = "default-browser"
    public static let defaultBrowserStatusMarker = "default-browser-status"
    public static let makeDefaultButtonMarker = "make-default-button"
    public static let startupRowID = "startup"
    public static let startupMenuMarker = "startup-menu"
    public static let downloadsFolderRowID = "downloads-folder"
    public static let downloadsFolderMarker = "downloads-folder-name"
    public static let downloadsChooseButtonMarker = "downloads-choose-button"
    public static let downloadsAskRowID = "downloads-ask"
    public static let downloadsAskSwitchMarker = "downloads-ask-switch"
    /// U27p's Privacy pane: the Clear row and its button, the cookie menu, the GPC switch and the
    /// history menu, then the clear sheet's title, range, profile, type rows and two buttons.
    public static let privacyClearRowID = "privacy-clear"
    public static let privacyCookiesRowID = "privacy-cookies"
    public static let privacyGPCRowID = "privacy-gpc"
    public static let privacyHistoryRowID = "privacy-history"
    public static let privacyHistoryCardID = "privacy-history-card"
    public static let privacyClearButtonMarker = "privacy-clear-button"
    public static let privacyCookiesMenuMarker = "privacy-cookies-menu"
    public static let privacyGPCSwitchMarker = "privacy-gpc-switch"
    public static let privacyHistoryMenuMarker = "privacy-history-menu"
    public static let privacySheetTitleMarker = "privacy-sheet-title"
    public static let privacySheetRangeMenuMarker = "privacy-sheet-range"
    public static let privacySheetProfileMarker = "privacy-sheet-profile"
    public static let privacySheetClearMarker = "privacy-sheet-clear"
    public static let privacySheetCancelMarker = "privacy-sheet-cancel"
    public static let privacySheetNoteMarker = "privacy-sheet-note"
    public static func privacySheetTypeMarker(_ index: Int) -> String { "privacy-sheet-type-\(index)" }
    var rows: [Row] { SettingsRegistry.rows(self) }
    var results: [Row] { rows.filter { ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query) } }
    /// The results grouped under their pane, in the rail's order: only panes with a hit get a
    /// heading, and the flat `results` order is these groups' rows in order.
    var resultGroups: [(pane: SettingsPane, rows: [Row])] {
        let results = results
        return SettingsRegistry.built.compactMap { pane in
            let hits = results.filter { $0.pane.paneID == pane.id }
            return hits.isEmpty ? nil : (pane, hits)
        }
    }
    var selectedResult: Row? { results.indices.contains(searchIndex) ? results[searchIndex] : nil }
    func moveSearchSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else { searchIndex = 0; return }
        searchIndex = min(max(0, searchIndex + delta), count - 1)
    }
    /// Opens the selected result. Return in the search field calls this and so does the check.
    @discardableResult
    func openSelectedResult() -> Bool {
        guard let row = selectedResult else { return false }
        select(row)
        return true
    }
    func handleSearchKey(_ key: SettingsSearchKey) -> Bool {
        switch key {
        case .up: guard !results.isEmpty else { return false }; moveSearchSelection(-1); return true
        case .down: guard !results.isEmpty else { return false }; moveSearchSelection(1); return true
        case .return: return openSelectedResult()
        }
    }
    func select(_ row: Row) { navigate(row.pane, highlight: row.id) }
    func tabCount(_ space: SpaceSnapshot) -> Int { space.today.filter { $0.kind == .tab || $0.kind == .split }.count }
    func tabCountLabel(_ space: SpaceSnapshot) -> String {
        "\(tabCount(space)) tab\(tabCount(space) == 1 ? "" : "s")"
    }
    static func routeUrlAccessibilityLabel(_ position: Int) -> String { "URL text of route \(position)" }
    static func routeDeleteAccessibilityLabel(_ position: Int) -> String { "Delete route \(position)" }
    func resultTitle(_ row: Row) -> String {
        guard case .space(let id) = row.pane, let space = snapshot.spaces.first(where: { $0.id == id }) else { return row.title }
        return row.title + " — " + space.title
    }
    /// The identifiers the rail, the detail and the screen check share. The check finds views
    /// by these in the window's view tree; nothing here is drawn.
    static func railMarker(_ pane: SettingsPaneID) -> String { railMarker(id: pane.rawValue) }
    public static func railMarker(id: String) -> String { "rail-\(id)" }
    static func groupMarker(_ pane: SettingsPaneID) -> String { groupMarker(id: pane.rawValue) }
    public static func groupMarker(id: String) -> String { "group-\(id)" }
    static func resultMarker(_ row: Row) -> String { "result-\(row.pane.searchKey)-\(row.id)" }
    public static func rowMarker(_ id: String) -> String { "row-\(id)" }
    public static let selectedResultMarker = "result-selected"
    public static let noResultsMarker = "no-results"
    /// The Spaces pane's segmented control, found by the screen check through its marker.
    public static let spaceScrollControlMarker = "space-scroll-control"
    public static let headerIconMarker = "header-icon"
    public static let headerTitleMarker = "header-title"
    public static let headerSubtitleMarker = "header-subtitle"
    public static let railMarkerID = "rail"
    static func iconDraft(_ value: String, stored: String = "") -> String {
        if value.count == 2, stored.count == 1, value.contains(where: { String($0) == stored }), value != stored + stored {
            return value.filter { String($0) != stored }
        }
        return value.last.map(String.init) ?? ""
    }
    static func settingsOffset(_ offset: Double, index: Int) -> Double {
        index == 0 && offset > 0 ? SpaceScrollState.rubberBand(offset) : offset
    }
    func slide(_ delta: Int) {
        guard let space, let index = snapshot.spaces.firstIndex(where: { $0.id == space.id }), snapshot.spaces.indices.contains(index + delta) else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: SidebarMetrics.spaceSwitchResponse, dampingFraction: SidebarMetrics.spaceSwitchDamping)) {
            navigate(.space(snapshot.spaces[index + delta].id))
        }
    }
    func previewLook(id: String, look: Look?, active: Bool, owner: UUID, generation: Int) {
        guard contextGeneration == generation else { return }
        if active { lookPreviewOwners[id] = owner }
        else {
            guard lookPreviewOwners[id] == nil || lookPreviewOwners[id] == owner else { return }
            lookPreviewOwners.removeValue(forKey: id)
        }
        preview(id, look, active)
    }
    func ownsLookPreview(id: String, owner: UUID, generation: Int) -> Bool {
        contextGeneration == generation && lookPreviewOwners[id] == owner
    }
    var archiveSpace: SpaceSnapshot? { snapshot.spaces.first { $0.id == snapshot.shownSpaceId } ?? snapshot.spaces.first }
    var archiveSubtitle: String { "Idle tabs in \(archiveSpace?.profileName ?? "Default") move to the Archive." }
    /// The chosen scroll direction in the pane's own words.
    var spaceScrollDirectionLabel: String {
        switch spaceScrollDirection {
        case .natural: "Natural"
        case .reversed: "Reversed"
        }
    }
    /// The profile the default destination's and the New Route's fresh Little-window picks
    /// write — the only picks that name no rule: the shown space's own `Profile` from the
    /// FFI snapshot, not the display name mapped back, which a named profile called
    /// "Default" would read as the built-in one.
    var airTrafficLittleWindowProfile: Profile? {
        archiveSpace?.profile
    }
    /// The default destination read as one of the destination menus' choices (a lost space
    /// id reads as the disabled deleted-space item): the default card selects it and New
    /// Route starts from it.
    var defaultChoice: DestinationChoice {
        DestinationChoice(airTraffic.routing?.default, deletedSpaces: airTraffic.deletedSpaces)
    }
    /// Where a New Route rule starts: the default's destination — but when that names a
    /// space of another profile than the rule would ride in (the shown space's), the most
    /// recent space instead, and when it names a deleted space, the shown profile's Little
    /// window. The core refuses a cross-profile space on a rule, while the default itself
    /// is judged on existence only.
    func newRouteDestination() -> Destination {
        let destination = defaultChoice.destination(littleWindowProfile: airTrafficLittleWindowProfile)
        if case .space(.space(let id))? = destination,
           snapshot.spaces.first(where: { $0.id == id })?.profile != (airTrafficLittleWindowProfile ?? .`default`) {
            return .space(.mostRecent)
        }
        return destination ?? .littleWindow(airTrafficLittleWindowProfile ?? .`default`)
    }
    var archiveAfter: ArchiveAfter { archiveSpace?.archiveAfter ?? .hours12 }
    func setArchiveAfter(_ value: ArchiveAfter) {
        guard let space = archiveSpace else { return }
        adapter.setArchiveAfter(spaceID: space.id, value: value, completion: editCompletion())
    }
    /// Reads the stored direction. The window calls this on every open, so the control shows the
    /// record's value rather than the model's last one.
    func readSpaceScrollDirection() {
        let generation = contextGeneration
        adapter.spaceScrollDirection { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let direction) = result else { return }
            self.spaceScrollDirection = direction
        }
    }

    // MARK: U27d, the Appearance pane

    /// Reads the New Tab row switch and the Tooltips switch. The window calls both on every open,
    /// so the pane shows the record's values rather than the model's last ones.
    func readAppearance() {
        let generation = contextGeneration
        adapter.newTabRowShown { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let shown) = result else { return }
            self.newTabRowShown = shown
        }
        adapter.tooltipsShown { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let shown) = result else { return }
            self.tooltipsShown = shown
        }
        adapter.theme { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let theme) = result else { return }
            self.theme = theme
        }
    }

    /// Writes the New Tab row switch and hands the stored value to the sidebars. A refused write
    /// leaves the switch where it was and shows the reason.
    func setNewTabRowShown(_ value: Bool) {
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setNewTabRowShown(value) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.newTabRowShown = value
            self.newTabRow(value)
        }
    }

    /// Writes the Tooltips switch the same way: the stored value reaches every window's sidebar
    /// and header at once, so a tooltip already waiting is dropped.
    func setTooltipsShown(_ value: Bool) {
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setTooltipsShown(value) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.tooltipsShown = value
            self.tooltips(value)
        }
    }

    /// Writes the Theme and hands the stored value to the app, which sets `NSApp.appearance`. A
    /// refused write leaves the control where it was and shows the reason.
    func setTheme(_ value: Theme) {
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setTheme(value) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.theme = value
            self.themeApplied(value)
        }
    }

    /// The Appearance pane's Look row: it opens the shown space's page in the Spaces pane, where
    /// the Look card's popover sits (the board's link row, E-Appearance).
    func openLook() {
        guard let space = archiveSpace else { navigate(.spaces); return }
        navigate(.space(space.id), highlight: "look")
    }

    /// Writes the direction and, once the core has it, shows it in the control and hands it to
    /// the sidebars. A refused write leaves the control where it was and shows the reason.
    func setSpaceScrollDirection(_ value: SpaceScrollDirection) {
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setSpaceScrollDirection(value) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.spaceScrollDirection = value
            self.spaceScroll(value)
        }
    }

    // MARK: U27i, the Little Window pane

    /// The Open-in row's own words: the most recent space of the Little Window's profile, or the
    /// named space. A named space the workspace no longer has reads as a deleted one — the pane's
    /// menu draws it disabled, and the Little Window itself falls back to the most recent space.
    var littleWindowOpenInLabel: String {
        switch littleWindowOpenIn {
        case .mostRecent: return "Most Recent Space"
        case .space(let id): return snapshot.spaces.first { $0.id == id }?.title ?? "Deleted space"
        }
    }

    /// The spaces the Open-in menu offers: the shown space's profile, in sidebar order. A Little
    /// Window opened in another profile falls back to that profile's most recent space.
    var littleWindowSpaces: [SpaceSnapshot] {
        let profile = archiveSpace?.profile
        return snapshot.spaces.filter { $0.profile == profile }
    }

    /// Reads the pane's four stored values on every open: the synced pair from the settings
    /// record and the device record's switch and shortcut.
    func readLittleWindow() {
        let generation = contextGeneration
        adapter.littleWindowOpenIn { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let value) = result else { return }
            self.littleWindowOpenIn = value
        }
        adapter.littleWindowCloseAfter { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let value) = result else { return }
            self.littleWindowCloseAfter = value
        }
        adapter.littleWindowDevice { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let device) = result else { return }
            self.littleWindowRememberFrame = device.rememberFrame
            self.littleWindowHotKey = device.hotKey
            self.registerHotKey(device.hotKey, generation: generation)
        }
    }

    /// Hands the stored shortcut to the app-wide registration and shows its answer under the row.
    private func registerHotKey(_ hotKey: LittleWindowHotKey?, generation: Int) {
        guard contextGeneration == generation, let hotKeyCenter else { return }
        applyHotKeyStatus(hotKeyCenter.apply(hotKey))
    }

    private func applyHotKeyStatus(_ status: GlobalHotKeyStatus?) {
        hotKeyMessage = SettingsModel.hotKeyMessage(for: status)
    }

    /// The sentence the row shows under the shortcut for a registration answer, nil when the
    /// system took the key.
    static func hotKeyMessage(for status: GlobalHotKeyStatus?) -> String? {
        switch status {
        case .registered, nil: return nil
        case .taken: return "Another app is already using this shortcut."
        case .failed(let message): return message
        }
    }

    /// The Air Traffic Control link row (E-LittleWindow): which links open in a Little Window is
    /// ATC's default destination and routes, so the row pushes that pane.
    func openAirTraffic() { navigate(.airTraffic, highlight: SettingsModel.airTrafficCardId) }

    func setLittleWindowOpenIn(_ value: LittleWindowOpenIn) {
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setLittleWindowOpenIn(value) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.littleWindowOpenIn = value
            self.littleWindowSettings(value, self.littleWindowRememberFrame, self.littleWindowCloseAfter)
        }
    }

    func setLittleWindowCloseAfter(_ value: Bool) {
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setLittleWindowCloseAfter(value) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.littleWindowCloseAfter = value
            self.littleWindowSettings(self.littleWindowOpenIn, self.littleWindowRememberFrame, value)
        }
    }

    /// Remembering off also forgets this device's frame, so turning it back on starts from the
    /// default window rather than a size the user had already asked to forget.
    func setLittleWindowRememberFrame(_ value: Bool) {
        let generation = contextGeneration
        adapter.setLittleWindowRememberFrame(value) { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success = result else {
                if case .failure(let error) = result { self?.report(error) }
                return
            }
            self.littleWindowRememberFrame = value
            if !value { self.adapter.setLittleWindowFrame(nil) }
            self.littleWindowSettings(self.littleWindowOpenIn, value, self.littleWindowCloseAfter)
        }
    }

    /// Starts or stops the recorder. While it records, the registration is paused, so pressing the
    /// current shortcut is recorded rather than opening a Little Window (L1).
    func toggleLittleWindowHotKeyRecording() {
        hotKeyMessage = nil
        if hotKeyRecording {
            hotKeyRecording = false
            resumeHotKeyRegistration()
        } else {
            hotKeyRecording = true
            hotKeyCenter?.registrar.unregister()
        }
    }

    /// Esc, leaving the pane or closing the window: stop and give the stored shortcut back (L1,
    /// L8). A recording left open would otherwise keep the key unregistered.
    func cancelLittleWindowHotKeyRecording() {
        guard hotKeyRecording else { return }
        hotKeyRecording = false
        resumeHotKeyRegistration()
    }

    /// Re-registers the stored key after a pause; `apply` records the answer the row shows.
    private func resumeHotKeyRegistration() {
        guard let hotKeyCenter else { return }
        applyHotKeyStatus(hotKeyCenter.apply(littleWindowHotKey))
    }

    /// One key event from the recorder: Esc cancels, ⌫ turns the shortcut off, a combination is
    /// stored on this device and registered at once. A combination Ararat's own key-binding table
    /// uses is refused, because a Carbon hot key is seen before any app's menus and would run
    /// both (M2).
    func handleLittleWindowHotKeyEvent(_ event: NSEvent) {
        switch LittleWindowHotKeyRecorder.entry(for: event) {
        case .cancelled: cancelLittleWindowHotKeyRecording()
        case .cleared: hotKeyRecording = false; setLittleWindowHotKey(nil)
        case .refused(let message):
            hotKeyRecording = false
            hotKeyMessage = message
            resumeHotKeyRegistration()
        case .ignored: break
        case .key(let hotKey):
            hotKeyRecording = false
            if let holder = keyBindingHolder(hotKey) {
                hotKeyMessage = SettingsModel.keyBindingConflictMessage(hotKey, holder: holder)
                resumeHotKeyRegistration()
            } else {
                setLittleWindowHotKey(hotKey)
            }
        }
    }

    /// The command whose effective key is the combination, if any. A conflicting row's lost key is
    /// not in `key`, so only a working binding answers.
    private func keyBindingHolder(_ hotKey: LittleWindowHotKey) -> KeyBinding? {
        let candidate = KeyCombination(key: hotKey.key, command: hotKey.command, control: hotKey.control,
                                       option: hotKey.option, shift: hotKey.shift)
        return keyBindings.bindings.first { $0.key == candidate }
    }

    /// "⌘T is New Tab in Ararat": the sentence the row shows for a combination the table holds.
    static func keyBindingConflictMessage(_ hotKey: LittleWindowHotKey, holder: KeyBinding) -> String {
        "\(LittleWindowHotKeyRecorder.caps(hotKey).joined()) is \(holder.title) in Ararat"
    }

    func setLittleWindowHotKey(_ value: LittleWindowHotKey?) {
        let generation = contextGeneration
        let previous = littleWindowHotKey
        adapter.setLittleWindowHotKey(value) { [weak self] result in
            guard let self else { return }
            // A retarget replaced this model's context while the write was in flight; the pause
            // from the recording still belongs to this model, so give the stored key back (the
            // next open reads the stored value again).
            guard self.contextGeneration == generation else {
                self.resumeHotKeyRegistration()
                return
            }
            switch result {
            case .success:
                self.littleWindowHotKey = value
                self.registerHotKey(value, generation: generation)
            case .failure(let error):
                self.littleWindowHotKey = previous
                self.report(error)
                // The recording paused the old key; a failed write must give it back.
                self.resumeHotKeyRegistration()
            }
        }
    }

    private func report(_ error: Error) {
        if let core = error as? CoreError {
            switch core {
            case .Edit(let message), .Import(let message), .Store(let message), .Live(let message): self.error = message
            }
        } else {
            self.error = error.localizedDescription
        }
    }

    // MARK: U27w, the Websites pane

    /// Every profile the workspace or the engine's exceptions name, in the snapshot's order with
    /// any extra exception profile appended: a site row names its profile when this holds more
    /// than one (W2). The workspace's own order keeps the names stable across opens.
    static func profileOrder(_ snapshot: WorkspaceSnapshot, exceptions: [SiteException]) -> [String] {
        var names: [String] = []
        for name in snapshot.spaces.map(\.profileName) + exceptions.map(\.profile) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    /// Reads the seven defaults from the core and the per-site exceptions from the engine. The
    /// window calls this on every open, so the pane never shows another session's values.
    func readWebsites() {
        let generation = contextGeneration
        adapter.siteDefaults { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let defaults) = result else { return }
            self.siteDefaults = defaults
        }
        refreshSiteExceptions()
    }

    /// The engine is the source of the rows: the list is read again after every write and after a
    /// popover change, so a row never restates a value Chromium no longer holds.
    func refreshSiteExceptions() {
        siteExceptions = siteHost?.siteExceptions() ?? []
        siteProfiles = Self.profileOrder(snapshot, exceptions: siteExceptions)
    }

    /// The rows of "Sites with their own settings": one per site and profile, in origin order,
    /// kinds in the board's order, no row for a site whose exceptions are all gone (W2).
    var siteRows: [SettingsSiteRow] {
        var rows: [SettingsSiteRow] = []
        for exception in siteExceptions {
            if let index = rows.firstIndex(where: { $0.origin == exception.origin && $0.profile == exception.profile }) {
                rows[index].settings[exception.kind] = exception.setting
            } else {
                rows.append(SettingsSiteRow(origin: exception.origin, profile: exception.profile,
                                            settings: [exception.kind: exception.setting]))
            }
        }
        return rows.filter { !$0.settings.isEmpty }
            .sorted { ($0.origin, $0.profile) < ($1.origin, $1.profile) }
    }

    func siteRow(origin: String, profile: String) -> SettingsSiteRow? {
        siteRows.first { $0.origin == origin && $0.profile == profile }
    }

    /// The summary a site row draws, with the profile named only when the workspace has more
    /// than one (W2): "Camera: Allow · Microphone: Allow".
    static func siteSummary(_ row: SettingsSiteRow, profiles: [String]) -> String {
        let parts = SitePermissionKind.allCases.compactMap { kind in
            row.settings[kind].map { "\(kind.title): \($0.title)" }
        }
        var text = parts.joined(separator: " · ")
        if profiles.count > 1 { text += " · " + row.profile }
        return text
    }

    /// Writes one of the seven defaults as the whole synced record and hands it to Chromium. The
    /// value must be one Chromium accepts as a default for that kind (the core refuses the rest
    /// too); a refused write leaves the menu where it was and shows the reason.
    func setSiteDefault(_ kind: SitePermissionKind, _ value: SitePermissionValue) {
        guard kind.acceptsDefault(value) else { return }
        guard siteDefaults.value(for: kind) != value else { return }
        let generation = contextGeneration
        let completion = editCompletion()
        let defaults = siteDefaults.replacing(kind, with: value)
        adapter.setSiteDefaults(defaults) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.siteDefaults = defaults
            self.siteDefaultsApplied(defaults)
        }
    }

    /// Writes one origin's exception of one kind in one profile through the engine (W3), then
    /// reads the list back. False when the engine refused the write.
    @discardableResult
    func setSitePermission(origin: String, profile: String, kind: SitePermissionKind,
                           setting: SiteState.PermissionSetting?) -> Bool {
        guard let host = siteHost,
              host.setSiteException(profile: profile, origin: origin, kind: kind.rawValue, setting: setting) else {
            return false
        }
        refreshSiteExceptions()
        return true
    }

    /// W3's Reset permissions: every exception the site holds of the seven kinds, removed.
    func resetSitePermissions(origin: String, profile: String) {
        guard let row = siteRow(origin: origin, profile: profile) else { return }
        for kind in SitePermissionKind.allCases where row.settings[kind] != nil {
            _ = siteHost?.setSiteException(profile: profile, origin: origin, kind: kind.rawValue, setting: nil)
        }
        refreshSiteExceptions()
    }

    /// W3's Clear cookies and site data: the engine clears the site's registrable domain's
    /// cookies, storage and cache in one removal, so a subdomain's data goes too and another
    /// domain's stays.
    func clearSiteData(origin: String, profile: String, completion: (() -> Void)? = nil) {
        guard let host = siteHost else { completion?(); return }
        host.clearSiteData(profile: profile, origin: origin) { [weak self] _ in
            self?.refreshSiteExceptions()
            completion?()
        }
    }

    /// The site page the board draws (W3), pushed like a space page.
    func openSite(origin: String, profile: String) {
        refreshSiteExceptions()
        if siteRow(origin: origin, profile: profile) != nil {
            navigate(.site(origin, profile))
        } else {
            navigate(.websites)
        }
    }

    // MARK: U27x, the Extensions pane

    /// The regular profiles the chooser offers, in the snapshot's order (X1). A private profile
    /// is never among them: the settings window acts on the regular workspace only.
    static func extensionProfileOrder(_ snapshot: WorkspaceSnapshot) -> [String] {
        var names: [String] = []
        for name in snapshot.spaces.map(\.profileName) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    /// Reads the pane on every open: the chooser's list, the chosen profile (the one the window
    /// that opened Settings shows, X1) and its rows. The window calls this from `prepare`.
    func readExtensions(shownSpaceID: String?) {
        extensionProfiles = Self.extensionProfileOrder(snapshot)
        guard !extensionProfiles.isEmpty else {
            extensionProfile = ""
            extensions = []
            extensionsLoading = false
            return
        }
        let shown = shownSpaceID.flatMap { id in snapshot.spaces.first { $0.id == id }?.profileName }
        let chosen = shown.flatMap { extensionProfiles.contains($0) ? $0 : nil } ?? extensionProfiles[0]
        if chosen != extensionProfile {
            extensionProfile = chosen
            extensions = []
        }
        refreshExtensions()
    }

    /// The engine is the source of the rows, as it is for the site rows: the list is read again
    /// after every write and after every registry change (X2, X5). A loading answer (X1) keeps the
    /// rows the pane has and marks the list as loading, so it never draws "no extensions" for a
    /// profile that is still loading.
    func refreshExtensions() {
        guard !extensionProfile.isEmpty else {
            extensions = []
            extensionsLoading = false
            return
        }
        let list = extensionHost?.extensions(profile: extensionProfile) ?? .empty
        extensionsLoading = list.loading
        if !list.loading { extensions = list.rows }
        // A removal reported elsewhere (X5) ends a sheet asking about that extension.
        if !list.loading, let pending = pendingRemoval,
           !extensions.contains(where: { $0.id == pending.id }) {
            pendingRemoval = nil
            dismissRemoveSheet?()
        }
    }

    /// X5: an extension changed somewhere; the pane follows without reopening Settings.
    func extensionsChanged() {
        refreshExtensions()
    }

    /// The profile chooser: the list switches to the chosen profile's extensions (X1). The rows of
    /// the previous profile are dropped at once, so a loading answer cannot show the wrong list.
    func selectExtensionProfile(_ profile: String) {
        guard extensionProfiles.contains(profile), profile != extensionProfile else { return }
        extensionProfile = profile
        extensions = []
        refreshExtensions()
    }

    func extensionRow(id: String) -> SettingsExtension? {
        extensions.first { $0.id == id }
    }

    /// The switch: written through the engine, then read back, so the row never restates a state
    /// Chromium no longer holds. A "review" answer leaves the row disabled (X3) and names why; an
    /// extension Chromium does not let the user switch offers no switch (X2, design).
    @discardableResult
    func setExtensionEnabled(_ id: String, enabled: Bool) -> Bool {
        guard let host = extensionHost, !extensionProfile.isEmpty,
              extensionRow(id: id)?.canDisable == true else { return false }
        let result = host.setEnabled(profile: extensionProfile, identifier: id, enabled: enabled)
        refreshExtensions()
        switch result {
        case "done", "unchanged": return true
        case "review": error = "Chromium disabled this extension for new permissions. Use Review…"
        case "policy": error = "Chromium does not allow changing this extension."
        default: error = "The extension could not be found."
        }
        return false
    }

    /// One of the menu's writable site-access choices (X2). "specific" is Chromium's own state and
    /// never sent; choosing it would need the site picker that Manage Extension opens, and an
    /// extension with no site access offers no choice at all.
    @discardableResult
    func setExtensionSiteAccess(_ id: String, access: ExtensionSiteAccess) -> Bool {
        guard let host = extensionHost, !extensionProfile.isEmpty,
              access == .onAllSites || access == .onClick,
              let row = extensionRow(id: id), row.siteAccess != .noSiteAccess else { return false }
        let result = host.setSiteAccess(profile: extensionProfile, identifier: id, access: access)
        refreshExtensions()
        guard result == "done" else {
            error = result == "unsupported"
                ? "This extension has no site access to change." : "The extension could not be found."
            return false
        }
        return true
    }

    /// Pin/Unpin (X2): the profile's toolbar pin prefs, the same path the action's menu uses.
    @discardableResult
    func toggleExtensionPin(_ id: String) -> Bool {
        guard let host = extensionHost, let row = extensionRow(id: id), row.canPin else { return false }
        let result = host.setPinned(profile: extensionProfile, identifier: id, pinned: !row.pinned)
        refreshExtensions()
        guard result == "done" || result == "unchanged" else {
            error = result == "forced" ? "Chromium pins this extension." : "The extension could not be found."
            return false
        }
        return true
    }

    /// Review… (X3): Chromium's re-enable prompt; accepting grants the permissions and enables
    /// the extension, so the row is read again when the prompt reports.
    func reviewExtension(_ id: String) {
        guard let host = extensionHost, !extensionProfile.isEmpty else { return }
        host.review(profile: extensionProfile, identifier: id, window: extensionWindow()) { [weak self] _ in
            self?.refreshExtensions()
        }
    }

    /// Remove… (X2): Chromium's uninstall dialog; a cancelled dialog keeps the extension.
    /// The sheet's copy (design's wording), shared by the pane, the check and the tests.
    static func removeSheetTitle(for name: String) -> String { "Remove \"\(name)\"?" }
    static let removeSheetText = "This removes the extension and its data from this profile."

    /// Remove… (X2, design decision B): ask in the AppKit sheet the window presents. Nothing is
    /// removed until its Remove button.
    func requestRemoveExtension(_ id: String) {
        guard let row = extensionRow(id: id) else { return }
        pendingRemoval = row
        presentRemoveSheet?(row)
    }

    func cancelRemoveExtension() {
        pendingRemoval = nil
    }

    /// The sheet's Remove button: the engine uninstalls (the registrar re-checks the policy), then
    /// the list is read again. A refusal or failure shows the engine's answer.
    func confirmRemoveExtension(_ id: String) {
        guard let host = extensionHost, !extensionProfile.isEmpty else { return }
        pendingRemoval = nil
        let result = host.uninstall(profile: extensionProfile, identifier: id)
        if !result.isEmpty {
            error = result == "forced" ? "Chromium does not allow removing this extension." : result
        }
        refreshExtensions()
    }

    /// Manage Extension (X2): chrome://extensions/?id= in a tab of the extension's profile.
    func manageExtension(_ id: String) {
        guard !extensionProfile.isEmpty else { return }
        extensionManage(extensionProfile, id)
    }

    // MARK: P5b, the General pane

    /// Reads the pane on every open: the LaunchServices status now, then the two core records.
    /// The pane counts as loaded only once both have answered, so the check cannot read the
    /// model's initial values as the stored ones.
    func readGeneral() {
        generalLoaded = false
        startupRead = false
        downloadsRead = false
        defaultBrowserIsDefault = defaultBrowserStatus.isDefaultBrowser()
        let generation = contextGeneration
        adapter.startupBehavior { [weak self] result in
            guard let self, self.contextGeneration == generation else { return }
            guard case .success(let value) = result else { return }
            self.startup = value
            self.startupRead = true
            self.generalLoaded = self.startupRead && self.downloadsRead
        }
        adapter.downloadDevice { [weak self] result in
            guard let self, self.contextGeneration == generation else { return }
            guard case .success(let value) = result else { return }
            self.downloads = value
            self.downloadsRead = true
            self.generalLoaded = self.startupRead && self.downloadsRead
        }
    }

    /// Reads the status again. The window calls this when the app becomes active, because the
    /// user may have changed the default browser in System Settings while Ararat was away.
    func refreshDefaultBrowser() {
        defaultBrowserIsDefault = defaultBrowserStatus.isDefaultBrowser()
    }

    /// Make Default asks the system. macOS shows its own confirmation, and the answer arrives when
    /// the app becomes active next, so the row reads the status again then rather than guessing.
    func makeDefaultBrowser() {
        defaultBrowserSetter.requestDefaultBrowser()
    }

    /// When Ararat opens: the synced record. The launch site reads it at the next window start.
    func setStartup(_ value: StartupBehavior) {
        guard startup != value else { return }
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setStartupBehavior(value) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.startup = value
        }
    }

    /// Save downloads to: the folder the chooser answered, as the whole device record. The app
    /// pushes the record into Chromium's prefs for every regular profile.
    func setDownloadDirectory(_ url: URL) {
        var value = downloads
        value.directory = url.path
        setDownloads(value)
    }

    /// Ask where to save each file: the same record, so the folder and the switch never disagree.
    func setAskWhereToSave(_ value: Bool) {
        var settings = downloads
        settings.askWhereToSave = value
        setDownloads(settings)
    }

    /// F3: the pair is a device record, so a write does not produce a workspace snapshot; a refusal
    /// (a relative folder) leaves the pane where it was and shows the reason.
    func setDownloads(_ value: DownloadDevice) {
        guard downloads != value else { return }
        let generation = contextGeneration
        adapter.setDownloadDevice(value) { [weak self] result in
            guard let self else { return }
            guard case .success = result else {
                if case .failure(let error) = result { self.report(error) }
                return
            }
            guard self.contextGeneration == generation else { return }
            self.downloads = value
            self.downloadsApplied(value)
        }
    }

    /// The folder the row names, with Chromium's own default standing in for an empty record.
    var downloadFolderName: String { downloads.folderName }

    /// The board's two startup choices (E-General), in the pane's words.
    static func startupLabel(_ value: StartupBehavior) -> String {
        switch value {
        case .restoreWindows: "Restore windows and tabs"
        case .newWindow: "Open a new window"
        }
    }

    var startupLabel: String { Self.startupLabel(startup) }

    // MARK: U27p, the Privacy pane

    /// Reads the record on every open and names the profile of the window that opened Settings,
    /// which the clear sheet clears and shows. The pane never shows another session's values.
    func readPrivacy(shownSpaceID: String?) {
        if let shownSpaceID, let space = snapshot.spaces.first(where: { $0.id == shownSpaceID }) {
            privacyProfile = space.profileName
        } else if let space = snapshot.spaces.first {
            privacyProfile = space.profileName
        }
        privacyLoaded = false
        let generation = contextGeneration
        adapter.privacySettings { [weak self] result in
            guard let self, self.contextGeneration == generation, case .success(let settings) = result else { return }
            self.privacy = settings
            self.privacyLoaded = true
        }
    }

    /// P2/P3: writes the whole synced record, then hands it to every regular profile. A refused
    /// write leaves the pane where it was and shows the reason.
    func setPrivacy(_ settings: PrivacySettings) {
        guard privacy != settings else { return }
        let generation = contextGeneration
        let completion = editCompletion()
        adapter.setPrivacySettings(settings) { [weak self] result in
            completion(result)
            guard let self, self.contextGeneration == generation, case .success = result else { return }
            self.privacy = settings
            self.privacyHost?.applyPrivacy(settings)
        }
    }

    func setThirdPartyCookies(_ value: ThirdPartyCookies) {
        var settings = privacy
        settings.thirdPartyCookies = value
        setPrivacy(settings)
    }

    func setGlobalPrivacyControl(_ value: Bool) {
        var settings = privacy
        settings.globalPrivacyControl = value
        setPrivacy(settings)
    }

    func setHistoryRetention(_ value: HistoryRetention) {
        var settings = privacy
        settings.historyRetention = value
        setPrivacy(settings)
    }

    /// P4: Clear… opens the sheet over the settings window. A sheet already clearing ignores a
    /// second open, so Clear cannot run twice.
    func openClearSheet() {
        guard !clearing else { return }
        clearSheetShown = true
    }

    func cancelClearSheet() {
        guard !clearing else { return }
        clearSheetShown = false
    }

    /// P4: Clear sends the range and types for the profile the sheet names. A failed type bitmask
    /// is shown as the pane's error after the sheet closes; clearing history keeps the U26d
    /// banner path (the deletion reaches the same history observer), with no new surface.
    func confirmClearSheet() {
        guard !clearing, !clearTypes.isEmpty else { return }
        guard let host = privacyHost else {
            error = "Clearing browsing data is unavailable."
            return
        }
        let profile = privacyProfile
        let range = clearRange
        let types = clearTypes
        clearing = true
        clearSheetShown = false
        host.clearBrowsingData(profile: profile, range: range, types: types) { [weak self] failed in
            guard let self else { return }
            self.clearing = false
            if failed != 0 {
                self.error = "Some data could not be cleared."
            }
        }
    }

    /// The sheet's description of what stays, in the board's words.
    static let clearSheetNote = "The Archive and your tabs stay."

    /// The entries a row's … menu draws, in the board's order: the site access (only when the
    /// extension has any to change), a divider, the pin when the extension has an action, Manage
    /// Extension, and Remove… when Chromium allows it.
    static func extensionMenu(_ row: SettingsExtension) -> [ExtensionMenuEntry] {
        var entries: [ExtensionMenuEntry] = []
        if row.siteAccess != .noSiteAccess {
            entries += ExtensionSiteAccess.writable.map { ExtensionMenuEntry.siteAccess($0) }
            // "On specific sites" is shown only while Chromium reports it, as a state the menu
            // cannot write without its site picker.
            if row.siteAccess == .onSpecificSites { entries.append(.siteAccess(.onSpecificSites)) }
            entries.append(.separator)
        }
        if row.canPin { entries.append(row.pinned ? .unpin : .pin) }
        entries.append(.manage)
        if row.removable {
            entries.append(.separator)
            entries.append(.remove)
        }
        return entries
    }

    func rename(_ id: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Enter a space name."; return }
        adapter.renameSpace(id: id, name: name, completion: editCompletion())
    }
    func icon(_ id: String, value: String) {
        guard value.isEmpty || value.count == 1 else { error = "Choose exactly one character."; return }
        adapter.setSpaceIcon(id: id, icon: value.isEmpty ? nil : value, completion: editCompletion())
    }
    func move(_ id: String, to index: Int) {
        guard snapshot.spaces.indices.contains(index), snapshot.spaces.contains(where: { $0.id == id }) else { return }
        adapter.moveSpace(id: id, index: index, completion: editCompletion())
    }
    func requestDelete(_ id: String) { if snapshot.spaces.count > 1 { pendingDelete = id } }
    func confirmDelete() {
        guard let id = pendingDelete else { return }
        pendingDelete = nil
        adapter.deleteSpace(id: id, completion: editCompletion())
    }
    func editCompletion() -> WorkspaceAdapter.Completion<WorkspaceSnapshot> {
        let generation = contextGeneration
        let originPublish = publish
        return { [weak self] result in
            let deliver = { [weak self] in
                if case .success(let snapshot) = result { originPublish(snapshot) }
                guard let self else { return }
                guard self.contextGeneration == generation else {
                    if case .success = result { self.refreshCurrentContext() }
                    return
                }
                self.receive(result)
            }
            if let hold = self?.checkEditCompletion { hold(deliver) } else { deliver() }
        }
    }
    private func refreshCurrentContext() {
        let generation = contextGeneration
        adapter.snapshot { [weak self] result in
            guard let self else { return }
            guard self.contextGeneration == generation else { self.refreshCurrentContext(); return }
            guard case .success(let snapshot) = result else { return }
            self.update(snapshot: snapshot)
            self.publish(snapshot)
        }
    }
    private func receive(_ result: Result<WorkspaceSnapshot, Error>) {
        switch result {
        case .success(let snapshot): error = nil; update(snapshot: snapshot)
        case .failure(let error):
            if let core = error as? CoreError {
                switch core {
                case .Edit(let message), .Import(let message), .Store(let message), .Live(let message): self.error = message
                }
            } else { self.error = error.localizedDescription }
        }
    }
    func readShortcuts() {
        shortcuts = Self.shortcutRows(keyBindings.bindings)
        spaceKeys = Self.spaceKeys(keyBindings.bindings)
    }

    /// Rows for the Shortcuts pane built from the effective table: an untouched row shows its description,
    /// a conflicting row keeps the key it lost and names its holder.
    /// The display (key caps, "None", right-click Reset/Remove, click-to-record) is reused from Cra's MIT
    /// `Sources/Cra/UI/Settings/ShortcutsPane.swift`. Internal so tests can build rows from synthesized tables.
    static func shortcutRows(_ table: [KeyBinding]) -> [Row] {
        let holder = { (key: KeyCombination, loser: String) -> String? in
            table.first { $0.key == key && $0.command != loser && $0.conflicting == false }?.title
        }
        return table.map { binding in
            var subtitle = binding.description
            if binding.conflicting, let assigned = binding.assignedKey, let holder = holder(assigned, binding.command) {
                subtitle += " Conflicting: \(SidebarTooltip.display(for: assigned)) is held by \(holder)."
            }
            return Row(id: "shortcut-\(binding.command)", pane: .shortcuts, title: binding.title, subtitle: subtitle,
                       keys: binding.key.map { SidebarTooltip.caps(for: $0) } ?? binding.assignedKey.map { SidebarTooltip.caps(for: $0) } ?? [],
                       command: binding.command, customized: binding.customized, conflicting: binding.conflicting)
        }
    }

    static func spaceKeys(_ table: [KeyBinding]) -> [Int: [String]] {
        var keys: [Int: [String]] = [:]
        for binding in table {
            guard binding.command.hasPrefix("show_space_"), let index = Int(binding.command.dropFirst("show_space_".count)) else { continue }
            if let key = binding.key { keys[index - 1] = SidebarTooltip.caps(for: key) }
        }
        return keys
    }

    /// Pane search matches the action name, its description and the keys (Yab's manual: "finds shortcuts
    /// by action or by keys"), combined with the Customized and Conflicting toggles.
    static func shortcutHit(_ row: Row, query: String, customized: Bool, conflicting: Bool, customizedOnly: Bool, conflictingOnly: Bool) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        let matches = query.isEmpty || (row.title + " " + row.subtitle + " " + row.keys.joined()).localizedCaseInsensitiveContains(query)
        return matches && (!customizedOnly || customized) && (!conflictingOnly || conflicting)
    }

    var filteredShortcuts: [Row] {
        shortcuts.filter { row in
            Self.shortcutHit(row, query: shortcutQuery,
                             customized: row.customized, conflicting: row.conflicting,
                             customizedOnly: customizedOnly, conflictingOnly: conflictingOnly)
        }
    }

    func binding(for command: String) -> KeyBinding? { keyBindings.binding(command: command) }
    func toggleRecording(_ command: String) { keyBindings.toggleRecording(command) }
    func resetShortcut(_ command: String) { keyBindings.reset(command: command) }
    func removeShortcut(_ command: String) { keyBindings.set(command: command, key: nil) }
    func resetAllShortcuts() { keyBindings.resetAll() }
}

/// U27k D5: the Appearance pane's Theme in AppKit's terms. System leaves `NSApp.appearance` nil,
/// so every window keeps following the Mac; Light and Dark force one appearance for the whole
/// app, which is how the browser windows, the settings window, popovers, menus and the command
/// bar follow together. A space's Look still colours only the sidebar.
extension Theme {
    public var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The board's three segment labels (E-Appearance).
    public var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
