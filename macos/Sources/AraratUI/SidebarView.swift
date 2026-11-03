import AppKit
import AraratKit

@MainActor
public final class SidebarView: NSView {
    public var onCreateSpace: ((String) -> Void)?
    public var onCreatePageChanged: (() -> Void)?
    private(set) public var createSpaceOpen = false
    private let creation = CreateSpaceView(frame: .zero)
    private let plusButton = SidebarDockButton()
    let newSpaceMenu = NSMenu()
    private var scrollPageIndex: Int { libraryOpen ? -1 : createSpaceOpen ? snapshot.spaces.count : spaceIndex }
    public var onSelect: ((Row) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onCloseSelected: (() -> Void)?
    public var onArchive: ((String) -> Void)?
    let tooltip = SidebarTooltip()
    private var clickMonitor: Any?
    var removeClickMonitor: (Any) -> Void = NSEvent.removeMonitor
    public var onRestore: ((String) -> Void)?
    public var onArchiveDelete: ((String) -> Void)?
    var onLibraryChanged: ((Bool, Bool) -> Void)?
    private(set) public var libraryOpen = false
    private var libraryNeedsFocus = false
    private let library = LibraryView(frame: .zero)
    private let libraryButton = SidebarDockButton()
    private var mainColumn: NSStackView!
    var libraryPage: String { library.page.rawValue }
    public var onShowSpace: ((String) -> Void)?

    var onLookChanged: ((Look?, Look?, Double) -> Void)?
    private(set) var lookSampling: CADisplayLink?
    private var libraryLookSpaceID: String?
    private var creationLookSpaceID: String?

    private var lookPreview: (spaceID: String, look: Look?)?
    private var snapshot: WorkspaceSnapshot
    private var spaceIndex = 0
    private var spaceListOrigins: [String: CGFloat] = [:]
    private var selectedID: String?

    private let header = NSTextField(labelWithString: "")
    private let urlField = NSView()
    private let host = NSTextField(labelWithString: "")
    private let favorites = NSStackView()
    private var favoriteColumns = 0
    private var favoritesHeight: NSLayoutConstraint!
    private let listScroll = SidebarScrollView()
    private let rows = NSStackView()
    private var rowViews: [String: SidebarRowView] = [:]
    private var retiringRows: [String: SidebarRowView] = [:]
    private var fadeFrame: (id: String, frame: NSRect)?
    private var favoriteTiles: [String: FavoriteTile] = [:]
    private var rowDivider: NSBox?
    private let dock = SpaceDockView()
    private let spaceViewport = NSView()
    private let spaceColumn = NSStackView()
    private var spaceScroll = SpaceScrollState()
    private let pullIndicator = SpacePullIndicator(frame: .zero)
    private var pullTimer: Timer?
    var pullClock: () -> CFTimeInterval = CACurrentMediaTime
    private var pullStep: (() -> Void)?
    private var wheelPullPlaying = false
    private enum ScrollOrigin { case page, rail, list }
    private enum ScrollAxis { case horizontal, vertical }
    private var scrollOrigin: ScrollOrigin?
    private var scrollAxis: ScrollAxis?
    private weak var gestureScroll: NSScrollView?
    private var scrollPreviews: [SidebarView] = []
    private var showingScrollPages = false
    private var scrollGeneration = 0
    private var isScrollPreview = false
    private var laidOutSidebarWidth: CGFloat = 0
    private var spacePagePitch: Double { Double(bounds.width) }

    public init(snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        self.selectedID = snapshot.selectedId
        self.spaceIndex = snapshot.spaces.firstIndex { $0.id == snapshot.shownSpaceId } ?? 0
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc public func showCreateSpace(_ sender: Any? = nil) { setCreateSpaceOpen(true) }

    public func setCreateSpaceOpen(_ open: Bool, scrolling: Bool = false) {
        guard open != createSpaceOpen else { return }
        if open && libraryOpen { setLibraryOpen(false, scrolling: scrolling) }
        finishRowMotion()
        if !scrolling { clearScrollPresentation(); spaceScroll = SpaceScrollState() }
        if open { creationLookSpaceID = snapshotSpace?.id }
        createSpaceOpen = open
        if open && creation.superview == nil { addSubview(creation, positioned: .below, relativeTo: libraryButton); creation.frame = bounds }
        if !open && !scrolling { creation.removeFromSuperview() }
        creation.isHidden = !open
        creation.active = open
        mainColumn.isHidden = open || libraryOpen
        if open { creation.begin(profileName: snapshotSpace?.profileName ?? "Default") }
        refreshLook()
        onCreatePageChanged?()
    }

    public func applyCreatedSpace(snapshot: WorkspaceSnapshot) {
        creation.finish(error: nil)
        applySelection(snapshot: snapshot)
        if let index = snapshot.spaces.firstIndex(where: { $0.id == snapshot.shownSpaceId }) { showSpace(at: index) }
        setCreateSpaceOpen(false)
    }

    public func creationFailed(_ message: String) { creation.finish(error: message) }

    @objc private func showNewSpaceMenu(_ sender: NSButton) {
        tooltip.dismiss()
        newSpaceMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc public func toggleLibrary(_ sender: Any? = nil) { setLibraryOpen(!libraryOpen) }

    public func searchArchive(_ query: String) -> Int {
        library.setSearchQuery(query)
        return library.filteredEntries.count
    }

    public func setLibraryOpen(_ open: Bool, scrolling: Bool = false) {
        guard open != libraryOpen else { return }
        if open && createSpaceOpen { setCreateSpaceOpen(false, scrolling: scrolling) }
        finishRowMotion()
        if !scrolling { clearScrollPresentation(); spaceScroll = SpaceScrollState() }
        if open { libraryLookSpaceID = snapshotSpace?.id }
        libraryOpen = open
        libraryNeedsFocus = open
        if open && library.superview == nil { addSubview(library, positioned: .below, relativeTo: libraryButton) }
        if !open && !scrolling { library.removeFromSuperview() }
        library.isHidden = !open
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        mainColumn.isHidden = open || createSpaceOpen
        libraryButton.setAccessibilityValue(open ? 1 : 0)
        if open { window?.makeFirstResponder(self) }
        refreshLook()
        onLibraryChanged?(open, scrolling)
    }

    func libraryDidLand() {
        if libraryOpen && libraryNeedsFocus && !showingScrollPages {
            libraryNeedsFocus = false
            library.focusSearch()
        }
    }

    public func applyRestore(snapshot: WorkspaceSnapshot) {
        applySelection(snapshot: snapshot)
        if let index = snapshot.spaces.firstIndex(where: { $0.id == snapshot.shownSpaceId }) { showSpace(at: index) }
        setLibraryOpen(false)
    }

    override public var acceptsFirstResponder: Bool { true }
    override public func cancelOperation(_ sender: Any?) {
        if createSpaceOpen { if !creation.submitting { setCreateSpaceOpen(false) } }
        else if libraryOpen { setLibraryOpen(false) } else { _ = nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender) }
    }

    public var spaceShown: Int { spaceIndex }
    public var selectedRowID: String? { selectedID }

    public func update(snapshot: WorkspaceSnapshot) {
        finishRowMotion()
        replaceSnapshot(snapshot)
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        layoutSubtreeIfNeeded()
        rowViews.values.forEach { $0.refreshHover() }
    }

    public func updateSelection(id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        snapshot.selectedId = id
        reload()
        revealSelection()
    }

    public func previewLook(spaceID: String, look: Look?, active: Bool = true) {
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == spaceID }) else { return }
        if active { lookPreview = (spaceID, look) }
        else if lookPreview?.spaceID == spaceID { lookPreview = nil }
        snapshot.spaces[index].look = look
        refreshLook()
    }

    private func keepingLookPreview(_ snapshot: WorkspaceSnapshot) -> WorkspaceSnapshot {
        guard let preview = lookPreview else { return snapshot }
        var snapshot = snapshot
        guard let index = snapshot.spaces.firstIndex(where: { $0.id == preview.spaceID }) else {
            lookPreview = nil
            return snapshot
        }
        snapshot.spaces[index].look = preview.look
        return snapshot
    }

    public func applySelection(snapshot: WorkspaceSnapshot) {
        let snapshot = keepingLookPreview(snapshot)
        let selectionChanged = selectedID != snapshot.selectedId
        if self.snapshot.spaces == snapshot.spaces { self.snapshot = snapshot; updateSelection(id: snapshot.selectedId) }
        else { replaceSnapshot(snapshot) }
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        if selectionChanged { revealSelection() }
    }

    private func replaceSnapshot(_ snapshot: WorkspaceSnapshot) {
        let snapshot = keepingLookPreview(snapshot)
        layoutSubtreeIfNeeded()
        listScroll.stopReveal()
        let wasScrolled = listScroll.contentView.bounds.minY > 0.5
        let anchors = rowViews.values.map { ($0.row.id, listScroll.documentView!.convert($0.bounds, from: $0)) }
            .filter { $0.1.intersects(listScroll.contentView.bounds) }
            .sorted { $0.1.minY < $1.1.minY }
            .map { ($0.0, $0.1.minY - listScroll.contentView.bounds.minY) }
        let shownID = snapshotSpace?.id
        clearScrollPresentation()
        spaceScroll = SpaceScrollState()
        self.snapshot = snapshot
        spaceListOrigins = spaceListOrigins.filter { id, _ in snapshot.spaces.contains { $0.id == id } }
        spaceIndex = snapshot.spaces.firstIndex { $0.id == shownID } ?? min(spaceIndex, max(0, snapshot.spaces.count - 1))
        selectedID = snapshot.selectedId
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        reload()
        layoutSubtreeIfNeeded()
        if wasScrolled, let anchor = anchors.first(where: { rowViews[$0.0] != nil }), let row = rowViews[anchor.0] {
            listScroll.move(to: listScroll.documentView!.convert(row.bounds, from: row).minY - anchor.1)
        }
        refreshPointer()
    }

    public func applyClose(id: String, snapshot: WorkspaceSnapshot) {
        let selectionChanged = selectedID != snapshot.selectedId
        clearScrollPresentation()
        layoutSubtreeIfNeeded()
        let oldFrames = rowViews.mapValues { presentedFrame($0) }
        if let last = snapshotSpace?.today.last,
           snapshotSpace?.today.contains(where: { $0.id == id }) == true,
           !(snapshot.spaces.first { $0.id == snapshotSpace?.id }?.today.contains { $0.id == last.id } ?? false),
           let frame = oldFrames[last.id] {
            fadeFrame = (last.id, frame)
        }
        for view in rowViews.values { view.layer?.removeAnimation(forKey: "row.close.move") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        replaceSnapshot(snapshot)
        fadeFrame = nil
        layoutSubtreeIfNeeded()
        for (id, view) in rowViews {
            view.refreshHover()
            guard let old = oldFrames[id], let parent = view.superview else { continue }
            let offset = parent.convert(old, from: self).minY - view.frame.minY
            guard abs(offset) > 0.01 else { continue }
            let animation = CABasicAnimation(keyPath: "transform.translation.y")
            animation.fromValue = offset
            animation.toValue = 0
            animation.duration = SidebarMetrics.rowCloseMoveDuration
            animation.timingFunction = SidebarMetrics.easeOutCubic
            view.layer?.add(animation, forKey: "row.close.move")
        }
        CATransaction.commit()
        if selectionChanged { revealSelection() }
    }

    private func presentedFrame(_ view: NSView) -> NSRect {
        let frame = view.layer?.animation(forKey: "row.close.move") == nil
            ? view.frame : (view.layer?.presentation()?.frame ?? view.frame)
        return convert(frame, from: view.superview)
    }

    private func finishRowMotion() {
        for view in rowViews.values { view.layer?.removeAnimation(forKey: "row.close.move") }
        for id in Array(retiringRows.keys) { removeRow(id: id) }
    }

    private var snapshotSpace: SpaceSnapshot? {
        snapshot.spaces.indices.contains(spaceIndex) ? snapshot.spaces[spaceIndex] : nil
    }

    public func selectRow(id: String) -> Bool {
        guard snapshot.spaces.indices.contains(spaceIndex) else { return false }
        let space = snapshot.spaces[spaceIndex]
        guard let row = (space.favorites + space.pinned + space.today).first(where: { $0.id == id }) else { return false }
        select(row)
        return true
    }

    @objc public func closeSelectedTab(_ sender: Any?) {
        guard let id = selectedID,
              snapshot.spaces.contains(where: { ($0.favorites + $0.pinned + $0.today).contains { $0.id == id && ($0.kind == .tab || $0.kind == .split) } }) else { return }
        onCloseSelected?()
    }

    public func showSpace(at index: Int) {
        showSpace(at: index, animatedReveal: true)
    }

    private func showSpace(at index: Int, animatedReveal: Bool) {
        guard snapshot.spaces.indices.contains(index) else { return }
        listScroll.stopReveal()
        if !isScrollPreview, let id = snapshotSpace?.id { spaceListOrigins[id] = listScroll.contentView.bounds.minY }
        finishRowMotion()
        clearScrollPresentation()
        spaceScroll = SpaceScrollState()
        spaceIndex = index
        reload()
        layoutSubtreeIfNeeded()
        listScroll.move(to: spaceListOrigins[snapshot.spaces[index].id] ?? 0)
        revealSelection(animated: animatedReveal)
        refreshPointer()
        onShowSpace?(snapshot.spaces[index].id)
    }

    private func build() {
        wantsLayer = true
        layer?.masksToBounds = true
        library.onScroll = { [weak self] event, scroll in self?.handleSpaceScroll(event, from: scroll) ?? false }
        urlField.wantsLayer = true
        urlField.layer?.cornerRadius = 11
        urlField.layer?.cornerCurve = .continuous
        host.font = .systemFont(ofSize: 13)
        host.lineBreakMode = .byTruncatingTail
        host.setAccessibilityLabel("Selected tab host")
        host.translatesAutoresizingMaskIntoConstraints = false
        urlField.addSubview(host)
        header.font = .systemFont(ofSize: 14, weight: .medium)
        header.textColor = .secondaryLabelColor
        let heading = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        heading.addSubview(header)

        favorites.orientation = .vertical
        favorites.spacing = 8
        favorites.alignment = .leading

        rows.orientation = .vertical
        rows.spacing = 0
        rows.alignment = .leading

        let scroll = listScroll
        scroll.onBoundsChanged = { [weak self] in self?.refreshPointer() }
        scroll.onScroll = { [weak self, weak scroll] event in self?.handleSpaceScroll(event, from: scroll) ?? false }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.addSubview(rows)
        scroll.documentView = document
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false


        spaceViewport.wantsLayer = true
        spaceViewport.layer?.masksToBounds = true
        spaceColumn.wantsLayer = true
        spaceColumn.orientation = .vertical
        spaceColumn.alignment = .leading
        spaceColumn.spacing = 0
        for view in [favorites, heading, scroll] { spaceColumn.addArrangedSubview(view) }
        spaceColumn.setCustomSpacing(22, after: favorites)
        spaceColumn.translatesAutoresizingMaskIntoConstraints = false
        spaceViewport.addSubview(spaceColumn)

        dock.translatesAutoresizingMaskIntoConstraints = false
        let bottomBar = NSView()
        bottomBar.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.topAnchor.constraint(equalTo: bottomBar.topAnchor), dock.bottomAnchor.constraint(equalTo: bottomBar.bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
        ])
        let column = NSStackView(views: [urlField, spaceViewport, bottomBar])
        mainColumn = column
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(8, after: urlField)
        column.setCustomSpacing(10, after: spaceViewport)
        column.edgeInsets = NSEdgeInsets(top: 46, left: 8, bottom: 8, right: 8)
        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        favoritesHeight = favorites.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            urlField.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -16),
            bottomBar.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            urlField.heightAnchor.constraint(equalToConstant: 36),
            host.leadingAnchor.constraint(equalTo: urlField.leadingAnchor, constant: 12),
            host.trailingAnchor.constraint(equalTo: urlField.trailingAnchor, constant: -12),
            host.centerYAnchor.constraint(equalTo: urlField.centerYAnchor),
            spaceViewport.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            spaceColumn.leadingAnchor.constraint(equalTo: spaceViewport.leadingAnchor),
            spaceColumn.trailingAnchor.constraint(equalTo: spaceViewport.trailingAnchor),
            spaceColumn.topAnchor.constraint(equalTo: spaceViewport.topAnchor),
            spaceColumn.bottomAnchor.constraint(equalTo: spaceViewport.bottomAnchor),
            favorites.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            favoritesHeight,
            heading.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            heading.heightAnchor.constraint(equalToConstant: 31),
            header.leadingAnchor.constraint(equalTo: heading.leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(lessThanOrEqualTo: heading.trailingAnchor, constant: -8),
            header.firstBaselineAnchor.constraint(equalTo: heading.topAnchor, constant: header.font!.capHeight),
            scroll.widthAnchor.constraint(equalTo: urlField.widthAnchor),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: rows.heightAnchor),
        ])
        library.isHidden = true
        library.update(archive: snapshot.archive)
        tooltip.capture(in: library)
        library.autoresizingMask = [.width, .height]
        library.onRestore = { [weak self] id in self?.onRestore?(id) }
        library.onDelete = { [weak self] id in self?.onArchiveDelete?(id) }
        library.onExit = { [weak self] in self?.setLibraryOpen(false) }
        libraryButton.image = NSImage(systemSymbolName: "books.vertical", accessibilityDescription: "Library")?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.libraryIconSize, weight: .regular))
        libraryButton.imagePosition = .imageOnly
        libraryButton.isBordered = false
        libraryButton.target = self
        libraryButton.action = #selector(toggleLibrary(_:))
        libraryButton.toolTip = "Library"
        libraryButton.setAccessibilityLabel("Library")
        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(libraryButton)
        NSLayoutConstraint.activate([
            libraryButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.libraryButtonLeading),
            libraryButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SidebarMetrics.libraryButtonBottom),
            libraryButton.widthAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
            libraryButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
        ])
        creation.autoresizingMask = [.width, .height]
        creation.onCreate = { [weak self] name in self?.onCreateSpace?(name) }
        creation.onCancel = { [weak self] in self?.setCreateSpaceOpen(false) }
        creation.active = false
        let newSpace = newSpaceMenu.addItem(withTitle: "New Space", action: #selector(showCreateSpace(_:)), keyEquivalent: "")
        newSpace.target = self
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Space")?.withSymbolConfiguration(.init(pointSize: SidebarMetrics.libraryIconSize, weight: .regular))
        plusButton.imagePosition = .imageOnly
        plusButton.isBordered = false
        plusButton.target = self
        plusButton.action = #selector(showNewSpaceMenu(_:))
        plusButton.toolTip = "New Space"
        plusButton.setAccessibilityLabel("New Space menu")
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusButton)
        NSLayoutConstraint.activate([
            plusButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.createSpacePlusTrailing),
            plusButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SidebarMetrics.libraryButtonBottom),
            plusButton.widthAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
            plusButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryButtonSize),
            dock.leadingAnchor.constraint(equalTo: libraryButton.trailingAnchor),
            dock.trailingAnchor.constraint(equalTo: plusButton.leadingAnchor),
        ])
        updateFill()
        addSubview(pullIndicator)
    }

    isolated deinit {
        if let clickMonitor { removeClickMonitor(clickMonitor) }
        tooltip.dismiss()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let clickMonitor { removeClickMonitor(clickMonitor); self.clickMonitor = nil }
        tooltip.dismiss()
        guard window != nil && !isScrollPreview else {
            lookSampling?.invalidate()
            lookSampling = nil
            return
        }
        tooltip.capture(in: self)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.window === self?.window {
                    if event.type == .flagsChanged { self?.tooltip.flagsChanged(with: event) }
                    else { self?.tooltip.dismiss() }
                }
            }
            return event
        }
    }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override public func mouseMoved(with event: NSEvent) { refreshPointer() }
    override public func mouseEntered(with event: NSEvent) { refreshPointer() }
    override public func mouseExited(with event: NSEvent) { tooltip.update(target: nil, point: nil) }

    func refreshPointer() {
        for row in rowViews.values { row.refreshHover() }
        let point = window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil
        let hit = point.flatMap { point in
            guard let root = window?.contentView else { return nil as NSView? }
            return root.hitTest(root.superview?.convert(point, from: nil) ?? point)
        }
        tooltip.update(target: tooltip.target(at: hit), point: point)
    }

    override public func layout() {
        super.layout()
        library.frame = bounds
        creation.frame = bounds
        pullIndicator.frame = bounds
        dock.layoutSubtreeIfNeeded()
        if bounds.width != laidOutSidebarWidth {
            finishRowMotion()
            if showingScrollPages { spaceScroll.cancelGesture() }
            clearScrollPresentation()
            laidOutSidebarWidth = bounds.width
        }
        let width = bounds.width - 16
        let columns = width >= 4 * 47 + 3 * 8 ? 4 : width >= 2 * 47 + 8 ? 2 : 1
        if columns != favoriteColumns {
            favoriteColumns = columns
            reloadFavorites()
        }
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            urlField.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }

    private func reload() {
        defer { refreshLook() }
        let space = snapshotSpace
        header.stringValue = [space?.icon, space?.title].compactMap { $0 }.joined(separator: " ")
        let pinned = space?.pinned ?? []
        let today = space?.today ?? []
        let selected = ((space?.favorites ?? []) + pinned + today).first { $0.id == selectedID }
        host.stringValue = selected?.url.flatMap { URL(string: $0)?.host } ?? ""

        reloadFavorites()

        let ids = Set((pinned + today).map(\.id))
        for id in Array(rowViews.keys) where !ids.contains(id) { removeRow(id: id) }
        var ordered: [NSView] = (pinned + today).map { rowView(for: $0) }
        if !pinned.isEmpty && !today.isEmpty {
            if rowDivider == nil {
                let divider = NSBox()
                divider.boxType = .separator
                rows.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
                rowDivider = divider
            }
            ordered.insert(rowDivider!, at: pinned.count)
        } else {
            rowDivider?.removeFromSuperview()
            rowDivider = nil
        }
        arrange(ordered, in: rows)

        dock.subviews.forEach { $0.removeFromSuperview() }
        for (index, space) in snapshot.spaces.enumerated() {
            let title = space.icon ?? String(space.title.prefix(1))
            let button = SpaceDockButton(title: title, target: self, action: #selector(dockClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.toolTip = space.title
            button.setAccessibilityLabel(space.title)
            button.font = .systemFont(ofSize: 15, weight: index == spaceIndex ? .bold : .regular)
            dock.addSubview(button)
        }
        dock.selectedIndex = spaceIndex
        dock.layoutSubtreeIfNeeded()
        tooltip.capture(in: self)
    }

    private func reloadFavorites() {
        let models = snapshotSpace?.favorites ?? []
        let ids = Set(models.map(\.id))
        let focused = window?.firstResponder as? FavoriteTile
        for id in Array(favoriteTiles.keys) where !ids.contains(id) {
            favoriteTiles.removeValue(forKey: id)?.removeFromSuperview()
        }
        let columns = max(1, favoriteColumns)
        let lineCount = (models.count + columns - 1) / columns
        favoritesHeight.constant = CGFloat(lineCount * 47 + max(0, lineCount - 1) * 8)
        var lines = favorites.arrangedSubviews.compactMap { $0 as? NSStackView }
        while lines.count < lineCount {
            let line = NSStackView()
            line.distribution = .fillEqually
            line.spacing = 8
            favorites.addArrangedSubview(line)
            NSLayoutConstraint.activate([
                line.heightAnchor.constraint(equalToConstant: 47),
                line.widthAnchor.constraint(equalTo: favorites.widthAnchor),
            ])
            lines.append(line)
        }
        for index in 0..<lineCount {
            let line = lines[index]
            line.arrangedSubviews.filter { !($0 is FavoriteTile) }.forEach { $0.removeFromSuperview() }
            let start = index * columns
            var tiles: [NSView] = models[start..<min(start + columns, models.count)].map { row in
                let tile = favoriteTiles[row.id] ?? FavoriteTile(row: row) { [weak self] row in self?.select(row) }
                favoriteTiles[row.id] = tile
                tile.update(row: row)
                tile.refusesFirstResponder = isScrollPreview
                return tile
            }
            while tiles.count < columns { tiles.append(NSView()) }
            arrange(tiles, in: line)
        }
        lines.dropFirst(lineCount).forEach { $0.removeFromSuperview() }
        if let focused, favoriteTiles[focused.row.id] === focused, window?.firstResponder !== focused {
            window?.makeFirstResponder(focused)
        }
        tooltip.capture(in: favorites)
    }

    private func rowView(for row: Row) -> SidebarRowView {
        let view: SidebarRowView
        if let existing = rowViews[row.id] {
            view = existing
        } else {
            view = SidebarRowView(row: row, selected: row.id == selectedID) { [weak self] row in self?.select(row) }
            rowViews[row.id] = view
            rows.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        view.pinned = snapshotSpace?.pinned.contains { $0.id == row.id } == true
        view.onClose = { [weak self, weak view] id in
            guard let self, let view else { return }
            if view.pinned && id != self.selectedID { self.onArchive?(id) }
            else { self.onClose?(id) }
        }
        view.update(row: row, selected: row.id == selectedID)
        view.acceptsKeyboardFocus = !isScrollPreview
        return view
    }

    private func removeRow(id: String) {
        if let retired = retiringRows.removeValue(forKey: id) {
            retired.layer?.removeAnimation(forKey: "row.close.fade")
            retired.removeFromSuperview()
            return
        }
        guard let view = rowViews.removeValue(forKey: id) else { return }
        guard let fadeFrame, fadeFrame.id == id else { view.removeFromSuperview(); return }
        rows.removeArrangedSubview(view)
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view)
        view.frame = fadeFrame.frame
        view.acceptsKeyboardFocus = false
        view.setAccessibilityHidden(true)
        retiringRows[id] = view
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak view] in
            Task { @MainActor in
                guard let self, let view, self.retiringRows[id] === view else { return }
                self.removeRow(id: id)
            }
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = SidebarMetrics.rowCloseFadeDuration
        animation.timingFunction = SidebarMetrics.easeOutCubic
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        view.layer?.add(animation, forKey: "row.close.fade")
        CATransaction.commit()
    }

    private func arrange(_ views: [NSView], in stack: NSStackView) {
        for (index, view) in views.enumerated() {
            if index >= stack.arrangedSubviews.count || stack.arrangedSubviews[index] !== view {
                stack.insertArrangedSubview(view, at: index)
            }
        }
    }

    private func select(_ row: Row) {
        selectedID = row.id
        snapshot.selectedId = row.id
        reload()
        revealSelection()
        onSelect?(row)
    }

    public func revealSelection(animated: Bool = true) {
        guard let id = selectedID, let row = rowViews[id] else { return }
        layoutSubtreeIfNeeded()
        listScroll.reveal(listScroll.documentView!.convert(row.bounds, from: row), animated: animated)
    }

    @objc private func dockClicked(_ sender: NSButton) {
        setLibraryOpen(false)
        setCreateSpaceOpen(false)
        showSpace(at: sender.tag)
    }

    override public func scrollWheel(with event: NSEvent) {
        if !handleSpaceScroll(event) { super.scrollWheel(with: event) }
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        isScrollPreview ? nil : super.hitTest(point)
    }

    override public func accessibilityChildren() -> [Any]? {
        isScrollPreview ? [] : super.accessibilityChildren()
    }

    private func handleSpaceScroll(_ event: NSEvent, from source: NSScrollView? = nil) -> Bool {
        guard !isScrollPreview else { return false }
        layoutSubtreeIfNeeded()
        let phase: SpaceScrollEvent.Phase
        if event.phase.contains(.began) { phase = .began }
        else if event.phase.contains(.ended) { phase = .ended }
        else if event.phase.contains(.cancelled) { phase = .cancelled }
        else if event.phase.contains(.mayBegin) { phase = .mayBegin }
        else if event.phase.isEmpty { phase = .none }
        else { phase = .changed }
        let input = SpaceScrollEvent(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, phase: phase,
                                     momentum: !event.momentumPhase.isEmpty,
                                     inverted: event.isDirectionInvertedFromDevice, time: event.timestamp)
        if input.kind == .wheel && wheelPullPlaying { return true }
        let origin: ScrollOrigin = libraryOpen ? (library.isOverRail(event) ? .rail : .list) : .page
        if phase == .began {
            scrollOrigin = origin
            scrollAxis = nil
            gestureScroll = source
        }
        let owner = input.kind == .wheel ? origin : (scrollOrigin ?? origin)
        let axis: ScrollAxis?
        if input.kind == .wheel {
            axis = abs(input.dx) > abs(input.dy) ? .horizontal : .vertical
        } else {
            if scrollAxis == nil && (input.dx != 0 || input.dy != 0) {
                scrollAxis = abs(input.dx) > abs(input.dy) ? .horizontal : .vertical
            }
            axis = scrollAxis
        }
        if owner == .list || axis == .vertical {
            if axis == .horizontal { return true }
            if input.kind == .trackpad, let scroll = gestureScroll, scroll !== source {
                scroll.scrollWheel(with: event)
                return true
            }
            return false
        }
        let layer = libraryOpen ? library.layer : createSpaceOpen ? creation.layer : spaceColumn.layer
        let offset = layer?.animation(forKey: "space.scroll") == nil
            ? layer?.transform.m41 : (layer?.presentation()?.transform.m41 ?? layer?.transform.m41)
        let logicalIndex = scrollPageIndex
        let action = spaceScroll.handle(input, index: logicalIndex, count: snapshot.spaces.count,
                                        pitch: spacePagePitch, presentationOffset: Double(offset ?? 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch action {
        case .vertical: return false
        case .ignored: return true
        case .pull:
            playWheelPull(from: Double(offset ?? 0))
        case .follow(let offset):
            lookSampling?.invalidate()
            lookSampling = nil
            listScroll.stopReveal()
            stopPullAnimation()
            scrollGeneration += 1
            for (view, _) in scrollPages { view.layer?.removeAnimation(forKey: "space.scroll") }
            prepareScrollPages(offset: offset)
            refreshLook(offset: offset)
            for (view, origin) in scrollPages { view.layer?.transform = CATransform3DMakeTranslation(origin + offset, 0, 0) }
            pullIndicator.update(excess: spaceScroll.followedExcess)
        case .settle(let index, let offset, let switched):
            if index == snapshot.spaces.count && switched {
                openCreationAfterPull()
                return true
            }
            let excess = pullIndicator.excess
            let from = offset + Double(index - logicalIndex) * spacePagePitch
            if switched {
                if index == -1 { setLibraryOpen(true, scrolling: true) }
                else { setLibraryOpen(false, scrolling: true); setCreateSpaceOpen(false, scrolling: true); scrollToSpace(at: index) }
            }
            prepareScrollPages(offset: from, departingIndex: logicalIndex)
            settleScroll(from: from, switched: switched)
            if excess > 0 { returnPullIndicator(excess: excess) }
        }
        return true
    }

    private var libraryPageOrigin: Double { Double(-1 - scrollPageIndex) * spacePagePitch }

    private var scrollPages: [(NSView, Double)] {
        [(spaceColumn, Double(spaceIndex - scrollPageIndex) * spacePagePitch), (library, libraryPageOrigin),
         (creation, Double(snapshot.spaces.count - scrollPageIndex) * spacePagePitch)] + scrollPreviews.compactMap { preview in
            preview.superview.map { ($0, Double(preview.spaceIndex - scrollPageIndex) * spacePagePitch) }
        }
    }

    private func scrollToSpace(at index: Int) {
        let decision = spaceScroll
        showSpace(at: index, animatedReveal: false)
        spaceScroll = decision
    }

    private func prepareScrollPages(offset: Double, departingIndex: Int? = nil) {
        guard !spaceViewport.bounds.isEmpty, spacePagePitch > 0 else { return }
        let libraryX = libraryPageOrigin + offset
        if !libraryOpen && libraryX > -spacePagePitch && libraryX < spacePagePitch {
            if library.isHidden || library.superview == nil { libraryLookSpaceID = snapshotSpace?.id }
            if library.superview == nil { addSubview(library, positioned: .below, relativeTo: libraryButton); library.frame = bounds }
            library.isHidden = false
            library.update(archive: snapshot.archive)
            tooltip.capture(in: library)
        }
        if (libraryOpen && offset < 0) || (createSpaceOpen && offset > 0) { mainColumn.isHidden = false }
        let center = min(snapshot.spaces.count - 1, max(0, spaceIndex - Int((offset / spacePagePitch).rounded())))
        let indices = Set((center - 1...center + 1).filter { snapshot.spaces.indices.contains($0) && $0 != spaceIndex })
        guard !showingScrollPages || Set(scrollPreviews.map(\.spaceIndex)) != indices else { return }
        showingScrollPages = true
        layoutSubtreeIfNeeded()
        for preview in scrollPreviews where !indices.contains(preview.spaceIndex) { preview.superview?.removeFromSuperview() }
        scrollPreviews.removeAll { !indices.contains($0.spaceIndex) }
        for index in indices.sorted() {
            guard !scrollPreviews.contains(where: { $0.spaceIndex == index }) else { continue }
            let preview = SidebarView(snapshot: snapshot)
            preview.isScrollPreview = true
            preview.spaceListOrigins = spaceListOrigins
            preview.selectedID = selectedID
            preview.showSpace(at: index, animatedReveal: false)
            preview.wantsLayer = true
            preview.setAccessibilityHidden(true)
            let page = NSView(frame: spaceViewport.bounds)
            page.wantsLayer = true
            page.layer?.masksToBounds = true
            page.setAccessibilityHidden(true)
            preview.frame = spaceViewport.convert(bounds, from: self)
            page.addSubview(preview)
            spaceViewport.addSubview(page, positioned: .below, relativeTo: spaceColumn)
            preview.layoutSubtreeIfNeeded()
            preview.listScroll.move(to: spaceListOrigins[snapshot.spaces[index].id] ?? 0)
            if index != departingIndex { preview.revealSelection(animated: false) }
            var descendants = preview.subviews
            while let view = descendants.popLast() {
                (view as? NSControl)?.refusesFirstResponder = true
                (view as? SidebarRowView)?.acceptsKeyboardFocus = false
                descendants.append(contentsOf: view.subviews)
            }
            scrollPreviews.append(preview)
        }
        // Don't translate fresh backing layers before AppKit synchronizes their view geometry.
        window?.displayIfNeeded()
    }

    func refreshLook(offset: Double = 0) {
        guard let onLookChanged else { return }
        let position = Double(scrollPageIndex) - (spacePagePitch > 0 ? offset / spacePagePitch : 0)
        let lower = Int(floor(position))
        func look(at index: Int) -> Look? {
            if snapshot.spaces.indices.contains(index) { return snapshot.spaces[index].look }
            let id = index < 0 ? libraryLookSpaceID : creationLookSpaceID
            return (snapshot.spaces.first { $0.id == id } ?? snapshotSpace)?.look
        }
        let fraction = position - Double(lower)
        onLookChanged(look(at: lower), look(at: fraction == 0 ? lower : lower + 1), fraction)
    }

    @objc private func sampleLook() {
        let view: NSView = libraryOpen ? library : createSpaceOpen ? creation : spaceColumn
        refreshLook(offset: Double(view.layer?.presentation()?.transform.m41 ?? view.layer?.transform.m41 ?? 0))
    }

    private func settleScroll(from offset: Double, switched: Bool) {
        refreshLook(offset: offset)
        lookSampling?.invalidate()
        if onLookChanged != nil, window != nil {
            lookSampling = displayLink(target: self, selector: #selector(sampleLook))
            lookSampling?.add(to: .main, forMode: .common)
        }
        scrollGeneration += 1
        let response = switched ? SidebarMetrics.spaceSwitchResponse : SidebarMetrics.spaceReturnResponse
        let damping = switched ? SidebarMetrics.spaceSwitchDamping : SidebarMetrics.spaceReturnDamping
        let omega = 2 * CGFloat.pi / response
        let generation = scrollGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.scrollGeneration == generation else { return }
                self.finishScrollPresentation()
            }
        }
        for (view, origin) in scrollPages {
            let spring = CASpringAnimation(keyPath: "transform.translation.x")
            spring.mass = 1
            spring.stiffness = omega * omega
            spring.damping = 2 * damping * omega
            spring.duration = spring.settlingDuration
            spring.fillMode = .forwards
            spring.isRemovedOnCompletion = false
            spring.fromValue = origin + offset
            spring.toValue = origin
            view.layer?.transform = CATransform3DMakeTranslation(origin, 0, 0)
            view.layer?.add(spring, forKey: "space.scroll")
        }
        CATransaction.commit()
    }

    func finishScrollPresentation() {
        clearScrollPresentation()
        libraryDidLand()
        refreshPointer()
    }

    private func clearScrollPresentation() {
        lookSampling?.invalidate()
        lookSampling = nil
        refreshLook()
        stopPullAnimation()
        pullIndicator.update(excess: 0)
        scrollGeneration += 1
        for (view, _) in scrollPages {
            view.layer?.removeAnimation(forKey: "space.scroll")
            view.layer?.transform = CATransform3DIdentity
        }
        scrollPreviews.forEach { $0.superview?.removeFromSuperview() }
        scrollPreviews.removeAll()
        showingScrollPages = false
        library.isHidden = !libraryOpen
        if !libraryOpen { library.removeFromSuperview() }
        creation.isHidden = !createSpaceOpen
        if !createSpaceOpen { creation.removeFromSuperview() }
        creation.layer?.transform = CATransform3DIdentity
        mainColumn.isHidden = libraryOpen || createSpaceOpen
        library.layer?.transform = CATransform3DIdentity
    }

    private func stopPullAnimation() {
        pullTimer?.invalidate()
        pullTimer = nil
        pullStep = nil
        wheelPullPlaying = false
    }

    private func animatePull(duration: Double, frame: @escaping @MainActor (Double) -> Void,
                             completion: @escaping @MainActor () -> Void) {
        stopPullAnimation()
        let start = pullClock()
        pullStep = { [weak self] in
            guard let self else { return }
            let elapsed = min(duration, self.pullClock() - start)
            frame(elapsed)
            if elapsed >= duration { self.stopPullAnimation(); completion() }
        }
        let timer = Timer(timeInterval: 1 / 120, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.stepPull() }
        }
        pullTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stepPull() { pullStep?() }

    private func pullSpring(switched: Bool) -> CASpringAnimation {
        let spring = CASpringAnimation()
        let omega = 2 * Double.pi / (switched ? SidebarMetrics.spaceSwitchResponse : SidebarMetrics.spaceReturnResponse)
        spring.mass = 1
        spring.stiffness = omega * omega
        spring.damping = 2 * (switched ? SidebarMetrics.spaceSwitchDamping : SidebarMetrics.spaceReturnDamping) * omega
        return spring
    }

    private func springProgress(_ time: Double, spring: CASpringAnimation) -> Double {
        let omega = sqrt(spring.stiffness)
        let decay = spring.damping / 2
        let frequency = sqrt(omega * omega - decay * decay)
        return 1 - exp(-decay * time) * (cos(frequency * time) + decay / frequency * sin(frequency * time))
    }

    private func playWheelPull(from offset: Double) {
        let spring = pullSpring(switched: true)
        scrollGeneration += 1
        for (view, _) in scrollPages { view.layer?.removeAnimation(forKey: "space.scroll") }
        prepareScrollPages(offset: offset)
        animatePull(duration: spring.settlingDuration, frame: { [weak self] time in
            guard let self else { return }
            let raw = offset + (-SidebarMetrics.spaceCreateThreshold - offset) * self.springProgress(time, spring: spring)
            let followed = min(0, raw)
            let position = raw < 0 ? SpaceScrollState.rubberBand(raw) : raw
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.refreshLook(offset: position)
            for (view, origin) in self.scrollPages { view.layer?.transform = CATransform3DMakeTranslation(origin + position, 0, 0) }
            self.pullIndicator.update(excess: -followed)
            CATransaction.commit()
        }, completion: { [weak self] in
            self?.pullIndicator.update(excess: SidebarMetrics.spaceCreateThreshold)
            self?.openCreationAfterPull()
        })
        wheelPullPlaying = true
    }

    private func returnPullIndicator(excess: Double) {
        let spring = pullSpring(switched: false)
        let offset = abs(SpaceScrollState.rubberBand(excess))
        animatePull(duration: spring.settlingDuration, frame: { [weak self] time in
            guard let self else { return }
            let shown = max(0, offset * (1 - self.springProgress(time, spring: spring)))
            let raw = shown / (SidebarMetrics.spaceRubberCoefficient * (1 - shown / SidebarMetrics.spaceRubberDistance))
            self.pullIndicator.update(excess: raw)
        }, completion: { [weak self] in self?.pullIndicator.update(excess: 0) })
    }

    private func openCreationAfterPull() {
        let excess = max(SidebarMetrics.spaceCreateThreshold, pullIndicator.excess)
        clearScrollPresentation()
        setCreateSpaceOpen(true, scrolling: true)
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        pullIndicator.update(excess: excess)
        animatePull(duration: SidebarMetrics.spaceCreateExitDuration, frame: { [weak self] time in
            self?.pullIndicator.update(excess: excess, exit: 48 * time / SidebarMetrics.spaceCreateExitDuration)
        }, completion: { [weak self] in self?.pullIndicator.update(excess: 0) })
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
