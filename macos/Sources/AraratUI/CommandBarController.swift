import AppKit
import AraratKit

/// ⌘T opens the bar for a new tab, ⌘L edits the current tab's URL (design note, behaviour).
public enum CommandBarMode: Equatable {
    case newTab
    case editURL
    case search
}

/// Answered by the per-open core session (built once per open, dropped on close).
@MainActor
public protocol CommandBarStore: AnyObject {
    /// Pure query against the session's index; the ranking and the inline completion come
    /// from the core, never derived here.
    func query(_ text: String) -> CommandBarResult
    func searchURL(_ text: String) -> String
}

@MainActor
public final class CommandBarSessionStore: CommandBarStore {
    private let session: CommandBarSession

    public init(session: CommandBarSession) { self.session = session }
    public func query(_ text: String) -> CommandBarResult { session.query(text: text) }
    public func searchURL(_ text: String) -> String { session.searchUrl(text: text) }
}

/// Values from the design note; each is labelled where it is used.
public enum CommandBarMetrics {
    /// 766 pt [Arc, Cra docs/arc-reverse-engineering.md D:121], capped at window width − 80
    /// [Cra, Theme.swift:490].
    public static let width: CGFloat = 766
    /// Input row 60 pt, result rows 50 pt, 2 pt apart, inset 10 pt [Arc, D:121].
    public static let fieldHeight: CGFloat = 60
    public static let rowHeight: CGFloat = 50
    public static let rowGap: CGFloat = 2
    public static let rowInset: CGFloat = 10
    /// At most 5 rows [Cra, SuggestionEngine.swift:62].
    public static let maxRows = 5

    /// height = 60 + n·50 + (n−1)·2 + 20, 60 with no rows [Cra, CommandBarView.swift:10-12].
    public static func height(forRows rows: Int) -> CGFloat {
        fieldHeight + (rows == 0 ? 0 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap + 20)
    }

    /// Width capped at the window's width − 80 [Cra, Theme.swift:490].
    public static func cappedWidth(windowWidth: CGFloat) -> CGFloat {
        min(width, windowWidth - 80)
    }

    /// Centred horizontally; the field stays put and shorter lists hang down: the top edge sits
    /// at the window's midY + full-height/2 + 40 [Cra, MainWindowController.swift:1835-1843].
    public static func panelFrame(windowFrame: NSRect, width: CGFloat, rows: Int) -> NSRect {
        let barHeight = height(forRows: rows)
        let top = windowFrame.midY + height(forRows: maxRows) / 2 + 40
        return NSRect(x: windowFrame.midX - width / 2, y: top - barHeight, width: width, height: barHeight)
    }
}

/// State + behaviour of the ⌘T / ⌘L bar, adapted from Cra's MIT
/// `Sources/Cra/UI/CommandBar/CommandBarController.swift` (the site search is left out).
/// The panel and view read from here; the host owns commits.
@MainActor
public final class CommandBarController {
    public private(set) var isOpen = false
    public private(set) var mode: CommandBarMode = .newTab
    public private(set) var query = ""
    public private(set) var result = CommandBarResult(rows: [], inlineCompletion: nil)
    public private(set) var selectedIndex = 0
    /// Text pushed into the field from outside (prefill); bump version to apply.
    public var fieldText = ""
    public var fieldTextVersion = 0
    /// Pushed text arrives selected (a prefill); false puts the caret after it.
    public var fieldTextSelected = true
    public var allowCompletion = true
    /// Text shown in the field while arrowing through rows; nil shows what was typed.
    public var previewText: String?
    public var previewVersion = 0
    /// Layout hints set before opening.
    public var panelWidth: CGFloat = CommandBarMetrics.width
    /// Selection fill: the shown space's colour, or the selection grey with no look [ours].
    public var highlight = NSColor.selectedContentBackgroundColor
    public var onCommit: (Suggestion?, CommandBarMode, Bool) -> Void = { _, _, _ in }
    public var onClose: () -> Void = {}
    /// Fires on every state change; the view syncs in here.
    public var onChange: () -> Void = {}
    /// Fires after every query with the row list settled; the harness positions the panel in
    /// it, since the panel's height follows the row count on every query (not only at open).
    public var onRowsChange: () -> Void = {}
    /// Click-away: the bar closes when its panel resigns key, unless the resign lands within
    /// this many seconds of opening — a focus fight on open re-keys the panel then
    /// (Cra M:2055-2065).
    public static let resignGrace: TimeInterval = 0.6
    /// The clock, injectable for tests.
    public var now: () -> Date = { Date() }
    public private(set) var openedAt: Date?
    private var store: CommandBarStore?
    /// Return (or ⌘Return) pressed while the store is pending: the bar stays open and the
    /// commit runs when `applyStore` lands, so the typed text is not dropped in the adapter
    /// round trip. nil when nothing is pending; the last key wins.
    private var pendingCommitForceNewTab: Bool?

    public init() {}

    /// ⌘L prefills the current tab's URL all selected; with no tab it falls back to a new tab
    /// [Cra, MainWindowController.swift:1799-1801].
    public static func openSpec(mode: CommandBarMode, selectedTabURL: String?) -> (mode: CommandBarMode, prefill: String?) {
        if mode == .search { return (.search, nil) }
        return mode == .editURL && selectedTabURL != nil ? (.editURL, selectedTabURL) : (.newTab, nil)
    }

    public var placeholder: String {
        switch mode {
        case .newTab: return "Search or enter URL…" // [Cra, CommandBarController.swift:51-52]
        case .editURL: return "Edit URL or search…"
        case .search: return "Search…"
        }
    }

    /// Builds the session's first list (an empty query shows the recent tabs) and opens. The
    /// store may be nil while the session is still on its way to the adapter queue; the panel
    /// and field key at once and `applyStore` replays the typed text when it arrives.
    public func open(mode: CommandBarMode, prefill: String?, store: CommandBarStore?) {
        self.store = store
        self.mode = mode
        query = prefill ?? ""
        fieldText = query
        fieldTextSelected = true
        fieldTextVersion += 1
        allowCompletion = false
        selectedIndex = 0
        previewText = nil
        pendingCommitForceNewTab = nil
        isOpen = true
        openedAt = now()
        relist(allowCompletion: false)
    }

    /// The session that arrived after the open applies: the typed text replays as the query
    /// against the new index (no completion until the user types again, as at open). A Return
    /// pressed while the session was pending commits here, with the typed text.
    public func applyStore(_ store: CommandBarStore) {
        self.store = store
        selectedIndex = 0
        relist(allowCompletion: false)
        if let forceNewTab = pendingCommitForceNewTab {
            pendingCommitForceNewTab = nil
            commit(forceNewTab: forceNewTab)
        }
    }

    public func update(query newQuery: String, allowCompletion: Bool) {
        query = newQuery
        self.allowCompletion = allowCompletion
        selectedIndex = 0
        previewText = nil
        relist(allowCompletion: allowCompletion)
    }

    private func relist(allowCompletion: Bool) {
        var result: CommandBarResult
        if mode == .search, let store, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = store.searchURL(query)
            result = CommandBarResult(rows: [Suggestion(title: query, subtitle: "Search", url: nil, key: nil, target: .search(url: url), score: 0)], inlineCompletion: nil)
        } else if mode == .search {
            result = CommandBarResult(rows: [], inlineCompletion: nil)
        } else {
            result = store?.query(query) ?? CommandBarResult(rows: [], inlineCompletion: nil)
        }
        if !allowCompletion { result.inlineCompletion = nil }
        result.rows = Array(result.rows.prefix(CommandBarMetrics.maxRows))
        self.result = result
        onChange()
        onRowsChange()
    }

    /// ↑ and ↓ wrap, and the field shows the selected row's text [Cra, C:121-140].
    public func moveSelection(by delta: Int) {
        guard !result.rows.isEmpty else { return }
        let count = result.rows.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        // The top row is what was typed (plus its inline completion).
        previewText = selectedIndex == 0 ? nil : fillText(for: result.rows[selectedIndex])
        previewVersion += 1
        onChange()
    }

    /// What the field shows for a selected row: the address for pages, the query for the typed
    /// row, the name for commands and travel rows (Cra's fillText).
    private func fillText(for suggestion: Suggestion) -> String {
        switch suggestion.target {
        case .openUrl, .search:
            return query
        case .command, .space, .folder, .moveToSpace, .moveToFolder:
            return suggestion.title
        case .tab, .archive:
            guard let url = suggestion.url else { return suggestion.title }
            var text = url
            for prefix in ["https://www.", "http://www.", "https://", "http://"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
            if text.hasSuffix("/") { text.removeLast() }
            return text
        }
    }

    public func commit(forceNewTab: Bool) {
        guard store != nil else {
            // The session is still on its way, so there is no row to commit yet: keep the bar
            // open and commit when `applyStore` lands.
            pendingCommitForceNewTab = forceNewTab
            return
        }
        let selected = result.rows.indices.contains(selectedIndex) ? result.rows[selectedIndex] : nil
        close()
        onCommit(selected, mode, forceNewTab)
    }

    /// Commits with a shown inline completion applied first, as Return does: the completion is
    /// re-queried before the commit, so the selected row targets the full text (Cra F:126-135).
    /// ⌘Return shares this step and then forces a new tab.
    public func commit(forceNewTab: Bool, applyingCompletion completion: String?) {
        if mode == .search { return commit(forceNewTab: forceNewTab) }
        guard let completion else { return commit(forceNewTab: forceNewTab) }
        update(query: completion, allowCompletion: false)
        commit(forceNewTab: forceNewTab)
    }

    /// A click on a row commits it (Cra's commit(_ suggestion:)).
    public func commit(_ suggestion: Suggestion) {
        close()
        onCommit(suggestion, mode, false)
    }

    public func close() {
        guard isOpen else { return }
        isOpen = false
        // A close in the gap (Esc, click-away) cancels the pending commit.
        pendingCommitForceNewTab = nil
        // Dropping the store drops the session's index (built once per open).
        store = nil
        onClose()
    }

    /// The panel's key-resign step (Cra M:2055-2065). Returns true when the bar stays open —
    /// within the grace of opening the host re-keys the panel on the next turn — and false when
    /// the bar closed.
    @discardableResult
    public func panelDidResignKey() -> Bool {
        guard isOpen else { return false }
        guard let openedAt, now().timeIntervalSince(openedAt) < Self.resignGrace else {
            close()
            return false
        }
        return true
    }
}
