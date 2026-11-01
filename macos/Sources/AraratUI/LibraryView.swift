import AppKit
import AraratKit

@MainActor
final class LibraryView: NSView, NSSearchFieldDelegate {
    enum Page: String { case archive = "Archive" }
    private(set) var page = Page.archive
    var onRestore: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onExit: (() -> Void)?
    private(set) var filteredEntries: [ArchiveEntry] = []
    private let document = LibraryDocumentView()
    private let scroll = LibraryScrollView()
    private let empty = NSTextField(labelWithString: "")
    private var rowViews: [String: ArchiveRowView] = [:]
    private var headings: [Date: NSTextField] = [:]
    private var displayed: [NSView] = []
    private var renderedArchive: [ArchiveEntry] = []
    private var renderedDay: Date?
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
    private var rows: [ArchiveRowView] = []

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
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize)
        empty.textColor = .secondaryLabelColor
        empty.lineBreakMode = .byTruncatingTail
        empty.isHidden = true
        document.addSubview(empty)
        scroll.documentView = document
        back.image = NSImage(systemSymbolName: "arrow.left", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.archiveIconSize, weight: .regular))
        back.imagePosition = .imageOnly
        back.isBordered = false
        back.toolTip = "Exit Library"
        back.setAccessibilityLabel("Exit Library")
        back.target = self
        back.action = #selector(exitLibrary)
        for view in [rail, divider, list] { addSubview(view) }
        for view in [search, scroll, back] { list.addSubview(view) }
        for view in [rail, divider, list, archiveButton, search, scroll, back] { view.translatesAutoresizingMaskIntoConstraints = false }
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
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: SidebarMetrics.archiveRowInset),
            scroll.bottomAnchor.constraint(equalTo: back.topAnchor, constant: -SidebarMetrics.archiveRowInset),
            back.leadingAnchor.constraint(equalTo: search.leadingAnchor),
            back.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -SidebarMetrics.libraryContentInset),
            back.heightAnchor.constraint(equalToConstant: SidebarMetrics.archiveBackHeight),
            back.widthAnchor.constraint(equalToConstant: SidebarMetrics.archiveBackHeight),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild), name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshRowHover), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(layoutEntries), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }

    override var isHidden: Bool { didSet { if oldValue && !isHidden { rebuild() } } }
    func update(archive: [ArchiveEntry]) {
        guard self.archive != archive || renderedDay != calendar.startOfDay(for: now()) else { return }
        self.archive = archive
        rebuild()
    }
    func setSearchQuery(_ query: String) { search.stringValue = query; rebuild() }
    func controlTextDidChange(_ notification: Notification) { rebuild() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if search.stringValue.isEmpty { onExit?() } else { setSearchQuery("") }
            return true
        }
        return false
    }

    @objc private func rebuild() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sorted = archive.sorted { $0.lifecycleChangedAt == $1.lifecycleChangedAt ? $0.id < $1.id : $0.lifecycleChangedAt > $1.lifecycleChangedAt }
        filteredEntries = sorted.filter { query.isEmpty || $0.title.range(of: query, options: .caseInsensitive) != nil || $0.url.range(of: query, options: .caseInsensitive) != nil }
        guard !isHidden else { return }
        listRevision += 1
        let responder = window?.firstResponder as? NSView
        let focusedIndex = rows.firstIndex { row in responder.map { $0 === row || $0.isDescendant(of: row) } ?? false }
        let focusedID = focusedIndex.map { rows[$0].entry.id }
        let today = calendar.startOfDay(for: now())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        if renderedArchive != archive || renderedDay != today {
            let ids = Set(sorted.map(\.id))
            for id in Array(rowViews.keys) where !ids.contains(id) { rowViews.removeValue(forKey: id)?.removeFromSuperview() }
            var days: Set<Date> = []
            for entry in sorted {
                let date = Date(timeIntervalSince1970: Double(entry.lifecycleChangedAt) / 1000)
                let day = calendar.startOfDay(for: date)
                days.insert(day)
                if headings[day] == nil {
                    let heading = NSTextField(labelWithString: "")
                    heading.translatesAutoresizingMaskIntoConstraints = false
                    heading.identifier = NSUserInterfaceItemIdentifier("archive-day-heading")
                    heading.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize, weight: .semibold)
                    heading.isHidden = true
                    headings[day] = heading
                    document.addSubview(heading)
                    headingCreationCount += 1
                }
                headings[day]?.stringValue = day == today ? "Today" : day == yesterday ? "Yesterday" : formatter.string(from: date)
                if let row = rowViews[entry.id] { row.update(entry: entry) }
                else {
                    let row = ArchiveRowView(entry: entry, restore: { [weak self] in self?.onRestore?($0) }, delete: { [weak self] in self?.onDelete?($0) })
                    row.moveFocus = { [weak self] row, direction in self?.moveFocus(from: row, direction: direction) }
                    row.isHidden = true
                    rowViews[entry.id] = row
                    document.addSubview(row)
                    rowCreationCount += 1
                }
            }
            for day in Array(headings.keys) where !days.contains(day) { headings.removeValue(forKey: day)?.removeFromSuperview() }
            renderedArchive = archive
            renderedDay = today
        }
        displayed.forEach { $0.isHidden = true }
        rows = []
        displayed = []
        var previousDay: Date?
        for entry in filteredEntries {
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: Double(entry.lifecycleChangedAt) / 1000))
            if day != previousDay, let heading = headings[day] { displayed.append(heading); previousDay = day }
            if let row = rowViews[entry.id] { rows.append(row); displayed.append(row) }
        }
        empty.stringValue = query.isEmpty ? "No archived tabs" : "No matching tabs"
        empty.isHidden = !filteredEntries.isEmpty
        if filteredEntries.isEmpty { displayed.append(empty) }
        for view in displayed { view.isHidden = false }
        layoutEntries()
        archiveButton.nextKeyView = search
        search.nextKeyView = (rows.first as NSView?) ?? back
        for (index, row) in rows.enumerated() { row.chainNext(to: index + 1 < rows.count ? rows[index + 1] : back) }
        back.nextKeyView = archiveButton
        if let focusedIndex {
            let target = rows.first { $0.entry.id == focusedID } ?? (rows.isEmpty ? nil : rows[min(focusedIndex, rows.count - 1)])
            window?.makeFirstResponder((target as NSView?) ?? back)
        }
    }

    private func moveFocus(from row: ArchiveRowView, direction: Int) {
        guard let index = rows.firstIndex(where: { $0 === row }), !rows.isEmpty else { return }
        let target = rows[min(rows.count - 1, max(0, index + direction))]
        window?.makeFirstResponder(target)
        target.scrollToVisible(target.bounds)
    }
    @objc private func layoutEntries() {
        guard !isHidden else { return }
        let inset = SidebarMetrics.libraryContentInset
        let width = scroll.contentView.bounds.width
        var y = inset
        for view in displayed {
            let height = view is ArchiveRowView ? SidebarMetrics.archiveRowPitch : SidebarMetrics.archiveHeadingHeight
            let frame = NSRect(x: inset, y: y, width: max(0, width - inset * 2), height: height)
            if view.frame != frame { view.frame = frame }
            y += height
        }
        let size = NSSize(width: width, height: max(scroll.contentView.bounds.height, y + inset))
        if document.frame.size != size { document.setFrameSize(size) }
        refreshRowHover()
    }
    @objc private func refreshRowHover() { if !isHidden { rows.forEach { $0.refreshHover() } } }
    @objc private func showArchive() { page = .archive }
    @objc private func exitLibrary() { onExit?() }
    override func layout() { super.layout(); layoutEntries() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            rail.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

final class SidebarDockButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

private final class ArchiveSearchField: NSSearchField {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}
private final class LibraryDocumentView: NSView { override var isFlipped: Bool { true } }
private final class LibraryScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}
