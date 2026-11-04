import AppKit
import AraratKit
import SwiftUI

@MainActor
public final class SettingsModel: ObservableObject {
    enum Page: Hashable { case tabs, shortcuts, airTraffic, spaces, space(String) }
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
    @Published var query = ""
    @Published var highlighted: String?
    @Published var error: String?
    @Published var pendingDelete: String?
    @Published var headerProgress = 0.0
    @Published private(set) var history: [Page] = [.spaces]
    @Published private(set) var historyIndex = 0
    @Published var shortcutQuery = "" { didSet { keyBindings.clearError() } }
    @Published var customizedOnly = false { didSet { keyBindings.clearError() } }
    @Published var conflictingOnly = false { didSet { keyBindings.clearError() } }
    let adapter: WorkspaceAdapter
    let keyBindings: KeyBindingsModel
    let airTraffic: AirTrafficModel
    var preview: (String, Look?, Bool) -> Void
    var publish: (WorkspaceSnapshot) -> Void
    var resetWidth: () -> Void
    @Published var shortcuts: [Row] = []
    @Published var spaceKeys: [Int: [String]] = [:]

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
        self.snapshot = snapshot
        if case .space(let id) = page, !snapshot.spaces.contains(where: { $0.id == id }) { navigate(.spaces) }
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
    var title: String {
        switch page { case .tabs: "Tabs"; case .shortcuts: "Shortcuts"; case .airTraffic: "Air Traffic Control"; case .spaces: "Spaces"; case .space: space?.title ?? "Spaces" }
    }
    /// The pane says in plain words that the routing arrives with the engine (unit 29).
    static let airTrafficSubtitle = "Links other apps hand to Ararat follow these rules once the browser engine arrives."
    /// The id the search result for the Air Traffic Control pane carries, and the id the pane's
    /// default destination card carries: a result scrolls to and fills the same row (§7).
    static let airTrafficCardId = "air-traffic"
    var rows: [Row] {
        var result = [Row(id: "width", pane: .tabs, title: "Sidebar width", subtitle: "Reset the sidebar to its default width of 240 pt."), Row(id: "archive-after", pane: .tabs, title: "Archive Today's tabs after", subtitle: archiveSubtitle)] + shortcuts
        result.append(Row(id: Self.airTrafficCardId, pane: .airTraffic, title: "Air Traffic Control", subtitle: Self.airTrafficSubtitle))
        for space in snapshot.spaces {
            result.append(Row(id: space.id, pane: .spaces, title: space.title, subtitle: "\(tabCount(space)) tabs · \(space.profileName)"))
            result += [
                Row(id: "name", pane: .space(space.id), title: "Name", subtitle: "\(space.title) · This space"),
                Row(id: "icon", pane: .space(space.id), title: "Icon", subtitle: "Choose one character · \(space.title) · This space"),
                Row(id: "look", pane: .space(space.id), title: "Look", subtitle: "Colour and texture · \(space.title) · This space"),
                Row(id: "profile", pane: .space(space.id), title: "Profile", subtitle: "Read-only · \(space.title) · This space · \(space.profileName)"),
                Row(id: "delete", pane: .space(space.id), title: "Delete Space", subtitle: "\(space.title) · " + (snapshot.spaces.count == 1 ? "The last space cannot be deleted." : "Move pinned and Today tabs to the Archive."))
            ]
        }
        return result
    }
    var results: [Row] { rows.filter { ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(query) } }
    func select(_ row: Row) { navigate(row.pane, highlight: row.id) }
    func tabCount(_ space: SpaceSnapshot) -> Int { space.today.filter { $0.kind == .tab || $0.kind == .split }.count }
    func resultTitle(_ row: Row) -> String {
        guard case .space(let id) = row.pane, let space = snapshot.spaces.first(where: { $0.id == id }) else { return row.title }
        return row.title + " — " + space.title
    }
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
    func previewLook(id: String, look: Look?, active: Bool) { preview(id, look, active) }
    var archiveSpace: SpaceSnapshot? { snapshot.spaces.first { $0.id == snapshot.shownSpaceId } ?? snapshot.spaces.first }
    var archiveSubtitle: String { "Idle tabs in \(archiveSpace?.profileName ?? "Default") move to the Archive." }
    /// The profile the pane's fresh Little-window picks write (nit 2): the shown space's own
    /// `Profile` from the FFI snapshot — the way the import takes the first space's when the
    /// routing file carries no profile. Round 2 mapped the display name back to a profile,
    /// which a named profile called "Default" would have read as the built-in one.
    var airTrafficLittleWindowProfile: Profile? {
        archiveSpace?.profile
    }
    var archiveAfter: ArchiveAfter { archiveSpace?.archiveAfter ?? .hours12 }
    func setArchiveAfter(_ value: ArchiveAfter) {
        guard let space = archiveSpace else { return }
        adapter.setArchiveAfter(spaceID: space.id, value: value, completion: receive)
    }
    func rename(_ id: String, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { error = "Enter a space name."; return }
        adapter.renameSpace(id: id, name: name, completion: receive)
    }
    func icon(_ id: String, value: String) {
        guard value.isEmpty || value.count == 1 else { error = "Choose exactly one character."; return }
        adapter.setSpaceIcon(id: id, icon: value.isEmpty ? nil : value, completion: receive)
    }
    func move(_ id: String, to index: Int) {
        guard snapshot.spaces.indices.contains(index), snapshot.spaces.contains(where: { $0.id == id }) else { return }
        adapter.moveSpace(id: id, index: index, completion: receive)
    }
    func requestDelete(_ id: String) { if snapshot.spaces.count > 1 { pendingDelete = id } }
    func confirmDelete() {
        guard let id = pendingDelete else { return }
        pendingDelete = nil
        adapter.deleteSpace(id: id, completion: receive)
    }
    func receive(_ result: Result<WorkspaceSnapshot, Error>) {
        switch result {
        case .success(let snapshot): error = nil; update(snapshot: snapshot); publish(snapshot)
        case .failure(let error):
            if let core = error as? CoreError {
                switch core {
                case .Edit(let message), .Import(let message), .Store(let message): self.error = message
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
