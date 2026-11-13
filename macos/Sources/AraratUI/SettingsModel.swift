import AppKit
import AraratKit
import SwiftUI

@MainActor
public final class SettingsModel: ObservableObject {
    enum Page: Hashable { case tabs, shortcuts, airTraffic, appearance, spaces, littleWindow, space(String) }
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
        return SettingsRegistry.pane(page: page).title
    }
    /// The header's icon, from the pane the page belongs to (a space page shows the space's own).
    var icon: String { SettingsRegistry.pane(page: page).icon }
    /// The header's one line: a space page names its tabs and profile, a pane its own subtitle.
    var subtitle: String {
        if let space { return "\(tabCountLabel(space)) · \(space.profileName)" }
        return SettingsRegistry.pane(page: page).subtitle
    }
    /// The pane says in plain words that the routing arrives with the engine.
    static let airTrafficSubtitle = "Links other apps hand to Ararat follow these routes once the browser engine arrives."
    /// The id the search result for the Air Traffic Control pane carries, and the id the pane's
    /// default destination card carries: a result scrolls to and fills the same row (§7).
    public static let airTrafficCardId = "air-traffic"
    /// U27c's card in the Spaces pane: the search result and the card share this id.
    public static let spaceScrollDirectionCardId = "space-scroll-direction"
    /// U27d's rows in the Appearance pane: the Look link, and the two switches in the board's
    /// "Sidebar" card. The search result and the row share each id.
    public static let lookRowId = "look"
    public static let newTabRowId = "new-tab-row"
    public static let tooltipsRowId = "tooltips"
    /// The switches themselves, so a check can find the pair the board draws.
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

    func toggleLittleWindowHotKeyRecording() {
        hotKeyMessage = nil
        hotKeyRecording.toggle()
    }

    func cancelLittleWindowHotKeyRecording() { hotKeyRecording = false }

    /// One key event from the recorder: Esc cancels, ⌫ turns the shortcut off, a combination is
    /// stored on this device and registered at once.
    func handleLittleWindowHotKeyEvent(_ event: NSEvent) {
        switch LittleWindowHotKeyRecorder.entry(for: event) {
        case .cancelled: hotKeyRecording = false
        case .cleared: hotKeyRecording = false; setLittleWindowHotKey(nil)
        case .refused(let message): hotKeyRecording = false; hotKeyMessage = message
        case .ignored: break
        case .key(let hotKey): hotKeyRecording = false; setLittleWindowHotKey(hotKey)
        }
    }

    func setLittleWindowHotKey(_ value: LittleWindowHotKey?) {
        let generation = contextGeneration
        let previous = littleWindowHotKey
        adapter.setLittleWindowHotKey(value) { [weak self] result in
            guard let self, self.contextGeneration == generation else { return }
            switch result {
            case .success:
                self.littleWindowHotKey = value
                self.registerHotKey(value, generation: generation)
            case .failure(let error):
                self.littleWindowHotKey = previous
                self.report(error)
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
