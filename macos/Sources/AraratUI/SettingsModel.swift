import AppKit
import AraratKit
import SwiftUI

@MainActor
public final class SettingsModel: ObservableObject {
    enum Page: Hashable { case tabs, shortcuts, spaces, space(String) }
    struct Row: Identifiable {
        let id: String
        let pane: Page
        let title: String
        let subtitle: String
        var keys: [String] = []
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
    let adapter: WorkspaceAdapter
    var publish: (WorkspaceSnapshot) -> Void
    var resetWidth: () -> Void
    @Published var shortcuts: [Row] = []
    @Published var spaceKeys: [Int: [String]] = [:]

    public init(snapshot: WorkspaceSnapshot, adapter: WorkspaceAdapter, publish: @escaping (WorkspaceSnapshot) -> Void, resetWidth: @escaping () -> Void) {
        self.snapshot = snapshot
        self.adapter = adapter
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
        switch page { case .tabs: "Tabs"; case .shortcuts: "Shortcuts"; case .spaces: "Spaces"; case .space: space?.title ?? "Spaces" }
    }
    var rows: [Row] {
        var result = [Row(id: "width", pane: .tabs, title: "Sidebar width", subtitle: "Reset the sidebar to its default width of 240 pt.")] + shortcuts
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
    func tabCount(_ space: SpaceSnapshot) -> Int { (space.pinned + space.today).filter { $0.kind == .tab || $0.kind == .split }.count }
    func resultTitle(_ row: Row) -> String {
        guard case .space(let id) = row.pane, let space = snapshot.spaces.first(where: { $0.id == id }) else { return row.title }
        return row.title + " — " + space.title
    }
    static func iconDraft(_ value: String) -> String { value.last.map(String.init) ?? "" }
    static func settingsOffset(_ offset: Double, index: Int) -> Double {
        index == 0 && offset > 0 ? SpaceScrollState.rubberBand(offset) : offset
    }
    func slide(_ delta: Int) {
        guard let space, let index = snapshot.spaces.firstIndex(where: { $0.id == space.id }), snapshot.spaces.indices.contains(index + delta) else { return }
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : .spring(response: SidebarMetrics.spaceSwitchResponse, dampingFraction: SidebarMetrics.spaceSwitchDamping)) {
            navigate(.space(snapshot.spaces[index + delta].id))
        }
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
    func readShortcuts(_ menu: NSMenu) {
        spaceKeys = [:]
        shortcuts = menu.items.flatMap { item -> [Row] in
            if let submenu = item.submenu { return shortcutRows(submenu) }
            return []
        }
    }
    private func shortcutRows(_ menu: NSMenu) -> [Row] {
        menu.items.flatMap { item -> [Row] in
            if let submenu = item.submenu { return shortcutRows(submenu) }
            guard !item.keyEquivalent.isEmpty else { return [] }
            let keys = SidebarTooltip.keycaps(for: item).map(\.stringValue)
            if item.action == NSSelectorFromString("showSpace:"), item.keyEquivalentModifierMask == [.control] { spaceKeys[item.tag] = keys }
            return [Row(id: "shortcut-\(item.title)", pane: .shortcuts, title: item.title, subtitle: item.toolTip ?? "Perform this menu command.", keys: keys)]
        }
    }
}
