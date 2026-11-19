import AppKit
import AraratKit

@MainActor
final class DownloadsPageView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let rowHeight: CGFloat = 56

    let search = NSSearchField()
    let clear = NSButton(title: "Clear All", target: nil, action: nil)
    private let title = NSTextField(labelWithString: "Downloads")
    private let scroll = DownloadsScroll()
    let table = DownloadsTable()
    private let empty = NSTextField(labelWithString: "No downloads")
    private let back = SidebarDockButton()
    private var model: DownloadsModel?
    private(set) var entries: [DownloadEntry] = []
    var onExit: (() -> Void)?
    var onScroll: ((NSEvent, NSScrollView?) -> Bool)?
    var previousFocus: NSView?
    var emptyVisible: Bool { !empty.isHidden }
    var actionButtonsFit: Bool {
        var rows = 0
        var fits = true
        table.enumerateAvailableRowViews { tableRow, _ in
            for row in tableRow.subviews.compactMap({ $0 as? DownloadRowView }) {
                rows += 1
                for button in row.actionButtons {
                    if !row.bounds.insetBy(dx: -1, dy: -1).contains(row.convert(button.bounds, from: button)) { fits = false }
                }
            }
        }
        return rows > 0 && fits
    }
    var rowsLeadingAndStatusFit: Bool {
        var rows = 0
        let clip = scroll.contentView
        let visible = clip.bounds
        var fits = visible.width > 0 && abs((table.tableColumns.first?.width ?? 0) - visible.width) <= 1
        table.enumerateAvailableRowViews { tableRow, _ in
            for row in tableRow.subviews.compactMap({ $0 as? DownloadRowView }) {
                rows += 1
                let frame = clip.convert(row.bounds, from: row)
                let status = row.statusFrame(in: clip)
                if frame.minX < visible.minX - 1 || frame.minX > visible.minX + 16 || frame.maxX > visible.maxX + 1 || status.minX < visible.minX - 1 || status.maxX > visible.maxX + 1 || !row.statusFits || !row.statusTruncates { fits = false }
            }
        }
        return rows > 0 && fits
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize, weight: .semibold)
        title.setAccessibilityLabel("Downloads")
        search.placeholderString = "Search Downloads"
        search.setAccessibilityLabel("Search Downloads")
        search.sendsSearchStringImmediately = true
        search.delegate = self
        search.target = self
        search.action = #selector(searchChanged)
        clear.target = self
        clear.action = #selector(clearAll)
        clear.bezelStyle = .inline
        clear.setAccessibilityLabel("Clear All Downloads")
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.onScroll = { [weak self] event in
            guard let self else { return false }
            return self.onScroll?(event, self.scroll) ?? false
        }
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("downloads"))
        column.resizingMask = .autoresizingMask
        column.minWidth = 0
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.navigate = { [weak self] event in self?.navigate(event) ?? false }
        scroll.documentView = table
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)
        back.imagePosition = .imageOnly
        back.isBordered = false
        back.setAccessibilityLabel("Exit Library")
        back.target = self
        back.action = #selector(exitLibrary)
        for view in [title, search, clear, scroll, empty, back] { addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            title.heightAnchor.constraint(equalToConstant: 32),
            clear.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            clear.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            search.heightAnchor.constraint(equalToConstant: 24),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: back.topAnchor, constant: -8),
            empty.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            empty.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            back.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            back.widthAnchor.constraint(equalToConstant: 32), back.heightAnchor.constraint(equalToConstant: 32),
        ])
        empty.isHidden = false
        scroll.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func layout() {
        super.layout()
        scroll.layoutSubtreeIfNeeded()
        let width = scroll.contentView.bounds.width
        if table.frame.width != width { table.setFrameSize(NSSize(width: width, height: table.frame.height)) }
        if table.tableColumns.first?.width != width { table.tableColumns.first?.width = width }
    }

    func setModel(_ model: DownloadsModel) { self.model = model; refresh() }
    func refresh() {
        guard let model else { return }
        clear.isEnabled = !model.clearableItems.isEmpty
        search.nextKeyView = clear
        clear.nextKeyView = table
        back.nextKeyView = previousFocus
        let newEntries = model.filteredItems(search.stringValue)
        empty.stringValue = model.items.isEmpty ? "No downloads" : "No matching downloads"
        guard entries != newEntries else { return }
        let focusedButton = window?.firstResponder as? DownloadActionButton
        let focusedRow = window?.firstResponder as? DownloadRowView
        let focusedID = focusedButton?.downloadID ?? focusedRow?.itemID
        let focusedAction = focusedButton?.downloadAction
        let oldEntries = entries
        let oldIndex = focusedID.flatMap { id in oldEntries.firstIndex { $0.id == id } } ?? 0
        let oldIDs = oldEntries.map(\.id)
        let newIDs = newEntries.map(\.id)
        entries = newEntries
        empty.isHidden = !entries.isEmpty
        scroll.isHidden = entries.isEmpty
        if oldIDs != newIDs {
            table.reloadData()
        } else {
            table.enumerateAvailableRowViews { row, index in
                guard self.entries.indices.contains(index) else { return }
                for view in row.subviews.compactMap({ $0 as? DownloadRowView }) { self.configure(view, index: index) }
            }
        }
        let focusedActionsChanged = focusedID.map { id in
            oldEntries.first(where: { $0.id == id })?.actions != entries.first(where: { $0.id == id })?.actions
        } ?? false
        if let focusedID, oldIDs != newIDs || focusedActionsChanged {
            if let index = entries.firstIndex(where: { $0.id == focusedID }) { focus(index, action: focusedAction) }
            else { focus(min(oldIndex, entries.count - 1)) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model, entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("download-row")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? DownloadRowView ?? DownloadRowView(item: entries[row], model: model)
        cell.identifier = identifier
        configure(cell, index: row)
        return cell
    }
    private func configure(_ row: DownloadRowView, index: Int) {
        row.update(item: entries[index])
        let id = entries[index].id
        row.moveRow = { [weak self] delta in self?.moveFocus(from: id, delta: delta) }
        row.tabRow = { [weak self] backwards in self?.tab(from: id, action: nil, backwards: backwards) }
        for button in row.actionButtons {
            button.moveRow = { [weak self] delta in self?.moveFocus(from: id, delta: delta) }
            let action = button.downloadAction
            button.tabRow = { [weak self] backwards in self?.tab(from: id, action: action, backwards: backwards) }
        }
        for (i, button) in row.actionButtons.enumerated() {
            button.nextKeyView = i + 1 < row.actionButtons.count ? row.actionButtons[i + 1] : table
        }
    }
    func controlTextDidChange(_ notification: Notification) { refresh() }
    @objc private func searchChanged() { refresh() }
    @objc private func clearAll() { model?.clearAll() }
    func focusSearch() { window?.makeFirstResponder(search) }
    func focusFirst() { focus(0) }
    private func focus(_ index: Int, action: String? = nil, last: Bool = false) {
        guard entries.indices.contains(index) else { window?.makeFirstResponder(back); return }
        table.scrollRowToVisible(index)
        table.layoutSubtreeIfNeeded()
        guard let row = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? DownloadRowView else { window?.makeFirstResponder(table); return }
        window?.makeFirstResponder(row.actionButtons.first(where: { $0.downloadAction == action }) ?? (last ? row.actionButtons.last : row.actionButtons.first) ?? row)
    }
    private func tab(from id: String, action: String?, backwards: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if let action, let position = entries[index].actions.firstIndex(of: action) {
            let next = position + (backwards ? -1 : 1)
            if entries[index].actions.indices.contains(next) { focus(index, action: entries[index].actions[next]); return }
        }
        let nextRow = index + (backwards ? -1 : 1)
        if entries.indices.contains(nextRow) { focus(nextRow, last: backwards) }
        else { window?.makeFirstResponder(backwards ? (clear.isEnabled ? clear : search) : back) }
    }
    private func moveFocus(from id: String, delta: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        focus(min(entries.count - 1, max(0, index + delta)))
    }
    private func navigate(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: focus(min(entries.count - 1, max(0, table.selectedRow + 1)))
        case 126: focus(max(0, table.selectedRow - 1))
        case 48: if event.modifierFlags.contains(.shift) { window?.makeFirstResponder(clear.isEnabled ? clear : search) } else { focusFirst() }
        default: return false
        }
        return true
    }
    @objc private func exitLibrary() { onExit?() }
    /// p4checks: the page's back arrow, pressed through its button.
    func checkPressBack() -> Bool {
        guard !back.isHidden else { return false }
        back.performClick(nil)
        return true
    }
}

@MainActor
private final class DownloadsScroll: NSScrollView {
    var onScroll: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) { if onScroll?(event) != true { super.scrollWheel(with: event) } }
}

@MainActor
final class DownloadsTable: NSTableView {
    var navigate: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) { if navigate?(event) != true { super.keyDown(with: event) } }
}
