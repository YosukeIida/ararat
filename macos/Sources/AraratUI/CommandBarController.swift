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
    /// Pure query against the session's index; the ranking and the typed row come from the core,
    /// never derived here. History rows are the engine's answer to the same text (U23 D5).
    func query(_ text: String, history: [HistoryEntry]) -> CommandBarResult
    func searchURL(_ text: String) -> String
}

@MainActor
public final class CommandBarSessionStore: CommandBarStore {
    private let session: CommandBarSession

    public init(session: CommandBarSession) { self.session = session }
    public func query(_ text: String, history: [HistoryEntry] = []) -> CommandBarResult { session.query(text: text, history: history) }
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
    static let backdropFill = NSColor(srgbRed: 20 / 255, green: 20 / 255, blue: 24 / 255, alpha: 0.28)
    static let hintFill = backdropFill.withAlphaComponent(0.62)
    static let hintGap: CGFloat = 20
    static let topInset: CGFloat = 180
    static let hintOffset: CGFloat = 16
    static let hintRadius: CGFloat = 6
    static let hintFontSize: CGFloat = 12
    static let hintPaddingX: CGFloat = 10
    static let hintPaddingY: CGFloat = 4
    /// At most 5 rows [Cra, SuggestionEngine.swift:62].
    public static let maxRows = 5

    /// height = 60 + n·50 + (n−1)·2 + 20, 60 with no rows [Cra, CommandBarView.swift:10-12].
    public static func height(forRows rows: Int) -> CGFloat {
        fieldHeight + (rows == 0 ? 0 : CGFloat(rows) * rowHeight + CGFloat(rows - 1) * rowGap + 20)
    }

    /// Width capped at the window's width − 80 [Cra, Theme.swift:490].
    public static func cappedWidth(windowWidth: CGFloat) -> CGFloat {
        max(0, min(width, windowWidth - 80))
    }

    /// The field stays put while shorter lists hang down [Cra, MainWindowController.swift:1835-1843].
    static func panelFrame(windowFrame: NSRect, pageFrame: NSRect, rows: Int, privateWindow: Bool, hintHeight: CGFloat) -> NSRect {
        let noteHeight: CGFloat = privateWindow ? 32 : 0
        let barHeight = height(forRows: rows) + noteHeight
        let reserve = height(forRows: maxRows) + noteHeight + hintOffset + hintHeight
        let top = windowFrame.maxY - min(topInset, max(0, windowFrame.height - reserve))
        let width = min(cappedWidth(windowWidth: windowFrame.width), pageFrame.width)
        return NSRect(x: pageFrame.midX - width / 2, y: top - barHeight, width: width, height: barHeight)
    }

    /// U27h: a Little Window is short, so its ⌘L bar sits inside the window (the board puts it
    /// 78 pt below the top, which the step rule rounds to 80) rather than at the browser
    /// windows' mid-height.
    public static func littleWindowPanelFrame(windowFrame: NSRect, width: CGFloat, rows: Int) -> NSRect {
        let barHeight = height(forRows: rows)
        let top = windowFrame.maxY - 80
        let y = max(windowFrame.minY + 8, top - barHeight)
        return NSRect(x: windowFrame.midX - width / 2, y: y, width: width, height: barHeight)
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
    public private(set) var result = CommandBarResult(rows: [], privateWindow: false)
    public private(set) var selectedIndex = 0
    /// Text pushed into the field from outside (prefill); bump version to apply.
    public var fieldText = ""
    public var fieldTextVersion = 0
    /// Pushed text arrives selected (a prefill); false puts the caret after it.
    public var fieldTextSelected = true
    /// Text shown in the field while arrowing through rows; nil shows what was typed.
    public var previewText: String?
    public var previewVersion = 0
    public var highlight = SpaceAccent.teal {
        didSet { if oldValue != highlight { onChange() } }
    }
    public var onCommit: (Suggestion?, CommandBarMode, Bool) -> Void = { _, _, _ in }
    public var onClose: () -> Void = {}
    public static let passwordOfferCommand = "reopen_password_offer"
    public var passwordOfferTitle: String? {
        didSet {
            guard isOpen, passwordOfferTitle != oldValue else { return }
            relist(preserving: result.rows.indices.contains(selectedIndex) ? result.rows[selectedIndex].target : nil)
        }
    }
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
    public var privateWindow = false
    public var onQuery: (String, Int) -> Void = { _, _ in }
    public private(set) var queryGeneration = 0
    private var history: [HistoryEntry] = []
    /// Return (or ⌘Return) pressed while the store is pending: the bar stays open and the
    /// commit runs when `applyStore` lands, so the typed text is not dropped in the adapter
    /// round trip. nil when nothing is pending; the last key wins.
    private var pendingCommitForceNewTab: Bool?
    public private(set) var storeReadyAtSubmission = false

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
        storeReadyAtSubmission = false
        history = []
        self.mode = mode
        query = prefill ?? ""
        fieldText = query
        fieldTextSelected = true
        fieldTextVersion += 1
        selectedIndex = 0
        previewText = nil
        pendingCommitForceNewTab = nil
        isOpen = true
        openedAt = now()
        relist()
        queryGeneration += 1
        onQuery(query, queryGeneration)
    }

    /// The session that arrived after the open applies: the typed text replays as the query
    /// against the new index. A Return pressed while the session was pending commits here, with
    /// the typed text.
    public func applyStore(_ store: CommandBarStore) {
        self.store = store
        selectedIndex = 0
        relist()
        if let forceNewTab = pendingCommitForceNewTab {
            commit(forceNewTab: forceNewTab)
        }
    }

    public func update(query newQuery: String) {
        query = newQuery
        selectedIndex = 0
        previewText = nil
        relist()
        queryGeneration += 1
        onQuery(newQuery, queryGeneration)
    }

    public func updateHistory(_ entries: [HistoryEntry], for text: String) {
        guard isOpen, query == text, !privateWindow else { return }
        let selected = result.rows.indices.contains(selectedIndex) ? result.rows[selectedIndex].target : nil
        history = entries
        relist(preserving: selected)
    }

    private func relist(preserving selected: SuggestionTarget? = nil) {
        var result: CommandBarResult
        if mode == .search, let store, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // A query of nothing but control characters cleans to nothing in core, which answers
            // with no URL: no row, exactly like an empty field (review L2).
            let url = store.searchURL(query)
            result = url.isEmpty
                ? CommandBarResult(rows: [], privateWindow: privateWindow)
                : CommandBarResult(rows: [Suggestion(title: query, subtitle: "Search", url: nil, key: nil, target: .search(url: url), score: 0)], privateWindow: privateWindow)
        } else if mode == .search {
            result = CommandBarResult(rows: [], privateWindow: privateWindow)
        } else {
            result = store?.query(query, history: history) ?? CommandBarResult(rows: [], privateWindow: privateWindow)
        }
        if mode != .search, let title = passwordOfferTitle,
           query == fieldText && fieldTextSelected ||
           query.isEmpty || title.localizedStandardContains(query) {
            let row = Suggestion(title: title, subtitle: "Command", url: nil, key: nil,
                                 target: .command(id: Self.passwordOfferCommand), score: 0)
            result.rows.insert(row, at: min(1, result.rows.count))
        }
        result.rows = Array(result.rows.prefix(CommandBarMetrics.maxRows))
        self.result = result
        if let selected {
            if let index = result.rows.firstIndex(where: { $0.target == selected }) { selectedIndex = index }
            else { selectedIndex = 0; previewText = nil; previewVersion += 1 }
        }
        onChange()
        onRowsChange()
    }

    /// ↑ and ↓ wrap, and the field shows the selected row's text [Cra, C:121-140].
    public func moveSelection(by delta: Int) {
        guard !result.rows.isEmpty else { return }
        let count = result.rows.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
        // The top row is what was typed.
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
        case .tab, .history:
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
        storeReadyAtSubmission = pendingCommitForceNewTab == nil
        let selected = result.rows.indices.contains(selectedIndex) ? result.rows[selectedIndex] : nil
        close()
        onCommit(selected, mode, forceNewTab)
    }

    /// A click on a row commits it (Cra's commit(_ suggestion:)).
    public func commit(_ suggestion: Suggestion) {
        storeReadyAtSubmission = store != nil
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
