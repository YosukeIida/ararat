import AppKit
import AraratKit

@MainActor
final class LibraryView: NSView, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    enum Page: String { case archive = "Archive" }
    private(set) var page = Page.archive
    var onRestore: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onExit: (() -> Void)?
    var onScroll: ((NSEvent, NSScrollView?) -> Bool)?
    private(set) var filteredEntries: [ArchiveEntry] = []
    private enum ListRow: Equatable {
        enum ID: Hashable { case day(Date), entry(String) }
        case heading(Date, String), entry(ArchiveEntry)
        var id: ID {
            switch self {
            case .heading(let day, _): return .day(day)
            case .entry(let entry): return .entry(entry.id)
            }
        }
        var isEntry: Bool { if case .entry = self { return true }; return false }
    }
    let table = ArchiveTableView()
    private let scroll = LibraryScrollView()
    private let emptyState = ArchiveHeadingView()
    private var archiveRows: [ListRow] = []
    private var needsGrouping = true
    private var listRows: [ListRow] = []
    private var tableRows: [ListRow] = []
    private var entryRows: [Int] = []
    private var renderedDay: Date?
    private var needsReload = true
    private var focusedID: String?
    private var focusedPart = 0
    private(set) var rowCreationCount = 0
    private(set) var headingCreationCount = 0
    private(set) var listRevision = 0
    private let rail = NSView()
    private let search = ArchiveSearchField()
    private let back = SidebarDockButton()
    private let archiveButton = NSButton(title: Page.archive.rawValue, target: nil, action: nil)
    private let now: () -> Date
    private let calendar: Calendar
    private var archive: [ArchiveEntry] = []
    private var dayObserver: (any NSObjectProtocol)?

    init(frame: NSRect, now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
        self.now = now
        self.calendar = calendar
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        rail.wantsLayer = true
        archiveButton.target = self
        archiveButton.action = #selector(showArchive)
        archiveButton.isBordered = false
        archiveButton.alignment = .left
        archiveButton.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize, weight: .semibold)
        archiveButton.setAccessibilityLabel("Archive page")
        rail.addSubview(archiveButton)
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.setAccessibilityHidden(true)
        let list = NSView()
        let preferredWidth = list.widthAnchor.constraint(equalToConstant: SidebarMetrics.archiveListWidth)
        preferredWidth.priority = .defaultLow
        search.placeholderString = "Search Archived Tabs"
        search.setAccessibilityLabel("Search Archived Tabs")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(rebuild)
        scroll.drawsBackground = false
        scroll.onScroll = { [weak self] event in
            guard let self else { return false }
            return self.onScroll?(event, self.scroll) ?? false
        }
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        table.headerView = nil
        table.style = .plain
        table.floatsGroupRows = false
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.rowHeight = SidebarMetrics.archiveRowPitch
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("archive"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.navigate = { [weak self] event in self?.navigateTable(with: event) ?? false }
        table.didLayout = { [weak self] in self?.restoreVisibleFocus() }
        search.tabTarget = { [weak self] in self?.firstFocusTarget() }
        back.previousTarget = { [weak self] in self?.lastFocusTarget() }
        back.previousFocus = { [weak self] in
            guard let self else { return }
            if let entry = self.filteredEntries.last { self.focus(id: entry.id, part: 2) }
            else { self.window?.makeFirstResponder(self.search) }
        }
        table.autoresizingMask = [.width]
        scroll.documentView = table
        emptyState.isHidden = true
        emptyState.label.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize)
        emptyState.label.textColor = .secondaryLabelColor
        emptyState.label.alignment = .center
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.archiveIconSize, weight: .regular))
        back.imagePosition = .imageOnly
        back.isBordered = false
        back.toolTip = "Exit Library"
        back.setAccessibilityLabel("Exit Library")
        back.target = self
        back.action = #selector(exitLibrary)
        archiveButton.nextKeyView = search
        search.nextKeyView = table
        table.nextKeyView = back
        back.nextKeyView = archiveButton
        for view in [rail, divider, list] { addSubview(view) }
        for view in [search, scroll, back, emptyState] { list.addSubview(view) }
        for view in [rail, divider, list, archiveButton, search, scroll, back, emptyState] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.widthAnchor.constraint(equalToConstant: SidebarMetrics.archiveRailContentWidth),
            rail.topAnchor.constraint(equalTo: topAnchor), rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: SidebarMetrics.archiveRailDividerWidth),
            divider.topAnchor.constraint(equalTo: topAnchor), divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            list.leadingAnchor.constraint(equalTo: divider.trailingAnchor), list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: topAnchor), list.bottomAnchor.constraint(equalTo: bottomAnchor), preferredWidth,
            archiveButton.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: SidebarMetrics.libraryContentInset),
            archiveButton.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -SidebarMetrics.libraryContentInset),
            archiveButton.topAnchor.constraint(equalTo: rail.topAnchor, constant: SidebarMetrics.libraryContentTop),
            archiveButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.archiveHeadingHeight),
            search.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: SidebarMetrics.libraryContentInset),
            search.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -SidebarMetrics.libraryContentInset),
            search.topAnchor.constraint(equalTo: list.topAnchor, constant: SidebarMetrics.libraryContentTop),
            search.heightAnchor.constraint(equalToConstant: SidebarMetrics.archiveSearchHeight),
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: SidebarMetrics.libraryContentInset), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -SidebarMetrics.libraryContentInset),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: SidebarMetrics.archiveRowInset),
            scroll.bottomAnchor.constraint(equalTo: back.topAnchor, constant: -SidebarMetrics.archiveRowInset),
            emptyState.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            emptyState.heightAnchor.constraint(equalToConstant: SidebarMetrics.archiveHeadingHeight),
            back.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            back.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -SidebarMetrics.libraryContentInset),
            back.heightAnchor.constraint(equalToConstant: SidebarMetrics.archiveBackHeight),
            back.widthAnchor.constraint(equalToConstant: SidebarMetrics.archiveBackHeight),
        ])
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRowHover), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    isolated deinit {
        if let dayObserver { NotificationCenter.default.removeObserver(dayObserver) }
    }
    override var isFlipped: Bool { true }

    func isOverRail(_ event: NSEvent) -> Bool {
        rail.frame.contains(convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event, nil) != true { super.scrollWheel(with: event) }
    }

    override var isHidden: Bool {
        didSet {
            if isHidden && !oldValue {
                focusedID = nil
                focusedPart = 0
                if !search.stringValue.isEmpty { search.stringValue = ""; rebuild() }
            } else if oldValue && !isHidden { reloadIfVisible() }
        }
    }
    func update(archive: [ArchiveEntry]) {
        guard self.archive != archive || renderedDay != calendar.startOfDay(for: now()) else { return }
        self.archive = archive
        needsGrouping = true
        rebuild()
    }
    func focusSearch() { window?.makeFirstResponder(search) }
    func setSearchQuery(_ query: String) { search.stringValue = query; rebuild() }
    func controlTextDidChange(_ notification: Notification) { rebuild() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            if let entry = filteredEntries.first { focus(id: entry.id) } else { window?.makeFirstResponder(back) }
            return true
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) { window?.makeFirstResponder(archiveButton); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if search.stringValue.isEmpty { onExit?() } else { setSearchQuery("") }
            return true
        }
        return false
    }

    @objc private func rebuild() {
        let previousIndex = focusedID.flatMap { id in filteredEntries.firstIndex { $0.id == id } }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let today = calendar.startOfDay(for: now())
        if needsGrouping || renderedDay != today {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            archiveRows = []
            var previousDay: Date?
            for entry in archive.sorted(by: { $0.lifecycleChangedAt == $1.lifecycleChangedAt ? $0.id < $1.id : $0.lifecycleChangedAt > $1.lifecycleChangedAt }) {
                let date = Date(timeIntervalSince1970: Double(entry.lifecycleChangedAt) / 1000)
                let day = calendar.startOfDay(for: date)
                if day != previousDay {
                    archiveRows.append(.heading(day, day == today ? "Today" : day == yesterday ? "Yesterday" : formatter.string(from: date)))
                    previousDay = day
                }
                archiveRows.append(.entry(entry))
            }
            needsGrouping = false
            renderedDay = today
        }
        listRows = []; entryRows = []; filteredEntries = []
        var heading: ListRow?
        for row in archiveRows {
            switch row {
            case .heading: heading = row
            case .entry(let entry):
                guard query.isEmpty || entry.title.range(of: query, options: .caseInsensitive) != nil || entry.url.range(of: query, options: .caseInsensitive) != nil else { continue }
                if let pending = heading { listRows.append(pending); heading = nil }
                entryRows.append(listRows.count)
                listRows.append(row)
                filteredEntries.append(entry)
            }
        }
        if let previousIndex, !filteredEntries.contains(where: { $0.id == focusedID }) {
            focusedID = filteredEntries.isEmpty ? nil : filteredEntries[min(previousIndex, filteredEntries.count - 1)].id
            focusedPart = 0
        }
        needsReload = true
        reloadIfVisible()
    }

    private func reloadIfVisible() {
        guard !isHidden, needsReload else { return }
        if listRows.isEmpty {
            let hadFocus = (window?.firstResponder as? NSView).map { $0 === table || $0.isDescendant(of: table) } ?? false
            emptyState.label.stringValue = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No archived tabs" : "No matching tabs"
            emptyState.isHidden = false
            scroll.isHidden = true
            if hadFocus { window?.makeFirstResponder(back) }
            needsReload = false
            return
        }
        emptyState.isHidden = true
        scroll.isHidden = false
        guard tableRows != listRows else { needsReload = false; return }
        let hadFocus = (window?.firstResponder as? NSView).map { $0 === table || $0.isDescendant(of: table) } ?? false
        if hadFocus { window?.makeFirstResponder(table) }
        listRevision += 1
        let oldIDs = tableRows.map(\.id), newIDs = listRows.map(\.id)
        let oldSet = Set(oldIDs), newSet = Set(newIDs)
        var removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
        var inserted = IndexSet(newIDs.indices.filter { !oldSet.contains(newIDs[$0]) })
        if oldIDs.filter(newSet.contains) != newIDs.filter(oldSet.contains) {
            removed = []; inserted = []
            for change in newIDs.difference(from: oldIDs) {
                switch change {
                case .remove(let index, _, _): removed.insert(index)
                case .insert(let index, _, _): inserted.insert(index)
                }
            }
        }
        tableRows = listRows
        // Why not reloadData: AppKit drops all known views, including its reuse queue.
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        table.beginUpdates()
        table.removeRows(at: removed, withAnimation: [])
        table.insertRows(at: inserted, withAnimation: [])
        table.endUpdates()
        NSAnimationContext.endGrouping()
        table.enumerateAvailableRowViews { rowView, index in
            guard self.tableRows.indices.contains(index) else { return }
            rowView.isGroupRowStyle = !self.tableRows[index].isEntry
            for view in rowView.subviews { self.configure(view, at: index) }
        }
        needsReload = false
        if hadFocus {
            if let focusedID { focus(id: focusedID, part: focusedPart) } else { window?.makeFirstResponder(back) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableRows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .entry = tableRows[row] { return false }; return true
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry = tableRows[row] { return true }; return false
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .entry = tableRows[row] { return SidebarMetrics.archiveRowPitch }; return SidebarMetrics.archiveHeadingHeight
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch tableRows[row] {
        case .entry(let entry):
            let identifier = NSUserInterfaceItemIdentifier("archive-entry")
            let cell: ArchiveRowView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ArchiveRowView { cell = reused }
            else {
                cell = ArchiveRowView(entry: entry, restore: { [weak self] in self?.onRestore?($0) }, delete: { [weak self] in self?.onDelete?($0) })
                cell.identifier = identifier
                cell.moveFocus = { [weak self] cell, delta in self?.moveFocus(from: cell.entry.id, delta: delta) }
                cell.focusChanged = { [weak self, weak cell] part in
                    guard let self, let cell else { return }
                    self.focusedID = cell.entry.id; self.focusedPart = part
                }
                cell.tabTarget = { [weak self, weak cell] backwards in
                    guard let cell else { return nil }; return self?.tabTarget(from: cell.entry.id, backwards: backwards)
                }
                rowCreationCount += 1
            }
            cell.update(entry: entry)
            return cell
        case .heading:
            let identifier = NSUserInterfaceItemIdentifier("archive-heading")
            let cell: ArchiveHeadingView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ArchiveHeadingView { cell = reused }
            else { cell = ArchiveHeadingView(); cell.identifier = identifier; headingCreationCount += 1 }
            configure(cell, at: row)
            return cell
        }
    }
    private func configure(_ view: NSView, at row: Int) {
        switch tableRows[row] {
        case .entry(let entry): (view as? ArchiveRowView)?.update(entry: entry)
        case .heading(_, let title):
            guard let cell = view as? ArchiveHeadingView else { return }
            guard cell.label.stringValue != title else { return }
            cell.label.stringValue = title
            cell.label.identifier = NSUserInterfaceItemIdentifier("archive-day-heading")
        }
    }
    func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
        if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: rowView) { window?.makeFirstResponder(table) }
    }
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) { restoreVisibleFocus() }

    private func cell(id: String, scroll: Bool = false) -> ArchiveRowView? {
        guard !isHidden, let index = filteredEntries.firstIndex(where: { $0.id == id }) else { return nil }
        let row = entryRows[index]
        if scroll { table.scrollRowToVisible(row); table.layoutSubtreeIfNeeded() }
        return table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ArchiveRowView
    }
    private func focus(id: String, part: Int = 0) {
        focusedID = id; focusedPart = part
        if let cell = cell(id: id, scroll: true) { window?.makeFirstResponder(cell.focusTarget(part)) }
    }
    private func firstFocusTarget() -> NSView? { filteredEntries.first.flatMap { cell(id: $0.id) } ?? back }
    private func lastFocusTarget() -> NSView? { filteredEntries.last.flatMap { cell(id: $0.id)?.focusTarget(2) } ?? search }
    private func restoreVisibleFocus() {
        guard window?.firstResponder === table, let id = focusedID,
              let index = filteredEntries.firstIndex(where: { $0.id == id }),
              let cell = table.view(atColumn: 0, row: entryRows[index], makeIfNecessary: false) as? ArchiveRowView,
              cell.entry.id == id, cell.visibleRect.height > 0 else { return }
        window?.makeFirstResponder(cell.focusTarget(focusedPart))
    }
    private func moveFocus(from id: String?, delta: Int) {
        guard !filteredEntries.isEmpty else { return }
        let index = id.flatMap { id in filteredEntries.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : filteredEntries.count)
        focus(id: filteredEntries[min(filteredEntries.count - 1, max(0, index + delta))].id)
    }
    private func tabTarget(from id: String, backwards: Bool) -> NSView? {
        guard let index = filteredEntries.firstIndex(where: { $0.id == id }) else { return nil }
        let next = index + (backwards ? -1 : 1)
        if filteredEntries.indices.contains(next) { return cell(id: filteredEntries[next].id)?.focusTarget(backwards ? 2 : 0) }
        return backwards ? search : back
    }
    private func navigateTable(with event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: moveFocus(from: focusedID, delta: 1)
        case 126: moveFocus(from: focusedID, delta: -1)
        case 48:
            if let focusedID {
                let backwards = event.modifierFlags.contains(.shift)
                let part = focusedPart + (backwards ? -1 : 1)
                if (0...2).contains(part) { focus(id: focusedID, part: part) }
                else { window?.makeFirstResponder(tabTarget(from: focusedID, backwards: backwards)) }
            } else if event.modifierFlags.contains(.shift) { window?.makeFirstResponder(search) }
            else { moveFocus(from: nil, delta: 1) }
        case 123, 124:
            if let focusedID { focus(id: focusedID, part: event.keyCode == 124 ? min(2, focusedPart + 1) : max(0, focusedPart - 1)) }
        default:
            guard [" ", "\r", "\u{3}"].contains(event.charactersIgnoringModifiers ?? ""), let focusedID else { return false }
            if focusedPart == 1 { onDelete?(focusedID) } else { onRestore?(focusedID) }
        }
        return true
    }
    @objc private func refreshRowHover() {
        guard !isHidden else { return }
        table.enumerateAvailableRowViews { row, _ in row.subviews.compactMap { $0 as? ArchiveRowView }.forEach { $0.refreshHover() } }
        restoreVisibleFocus()
    }
    @objc private func showArchive() { page = .archive }
    @objc private func exitLibrary() { onExit?() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            rail.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

class SidebarDockButton: NSButton {
    var previousTarget: (() -> NSView?)?
    var previousFocus: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 && event.modifierFlags.contains(.shift), let previousFocus { previousFocus() }
        else { super.keyDown(with: event) }
    }
    override var previousValidKeyView: NSView? { previousTarget?() ?? super.previousValidKeyView }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

private final class ArchiveSearchField: NSSearchField {
    var tabTarget: (() -> NSView?)?
    override var nextValidKeyView: NSView? { tabTarget?() ?? super.nextValidKeyView }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
final class ArchiveTableView: NSTableView {
    var navigate: ((NSEvent) -> Bool)?
    var didLayout: (() -> Void)?
    override func keyDown(with event: NSEvent) { if navigate?(event) != true { super.keyDown(with: event) } }
    override func layout() { super.layout(); didLayout?() }
}
private final class ArchiveHeadingView: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize, weight: .semibold)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() { super.layout(); label.frame = NSRect(x: 0, y: (bounds.height - SidebarMetrics.archiveHeadingLabelHeight) / 2, width: bounds.width, height: SidebarMetrics.archiveHeadingLabelHeight) }
}
private final class LibraryScrollView: NSScrollView {
    var onScroll: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event) != true { super.scrollWheel(with: event) }
    }
}
