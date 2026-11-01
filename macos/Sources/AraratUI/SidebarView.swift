import AppKit
import AraratKit

@MainActor
public final class SidebarView: NSView {
    public var onSelect: ((Row) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onShowSpace: ((String) -> Void)?

    private var snapshot: WorkspaceSnapshot
    private var spaceIndex = 0
    private var selectedID: String?

    private let header = NSTextField(labelWithString: "")
    private let urlField = NSView()
    private let host = NSTextField(labelWithString: "")
    private let favorites = NSStackView()
    private var favoriteColumns = 0
    private var favoritesHeight: NSLayoutConstraint!
    private let rows = NSStackView()
    private var rowViews: [String: SidebarRowView] = [:]
    private var retiringRows: [String: SidebarRowView] = [:]
    private var fadeFrame: (id: String, frame: NSRect)?
    private var favoriteTiles: [String: FavoriteTile] = [:]
    private var rowDivider: NSBox?
    private let dock = NSStackView()
    private let spaceViewport = NSView()
    private let spaceColumn = NSStackView()
    private var spaceScroll = SpaceScrollState()
    private var scrollPreviews: [SidebarView] = []
    private var showingScrollPages = false
    private var scrollGeneration = 0
    private var isScrollPreview = false
    private var laidOutSidebarWidth: CGFloat = 0
    private var spacePagePitch: Double { Double(bounds.width) }

    public init(snapshot: WorkspaceSnapshot) {
        self.snapshot = snapshot
        self.selectedID = snapshot.selectedId
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public var spaceShown: Int { spaceIndex }
    public var selectedRowID: String? { selectedID }

    public func update(snapshot: WorkspaceSnapshot) {
        finishRowMotion()
        replaceSnapshot(snapshot)
        layoutSubtreeIfNeeded()
        rowViews.values.forEach { $0.refreshHover() }
    }

    public func updateSelection(id: String?) {
        guard selectedID != id else { return }
        selectedID = id
        snapshot.selectedId = id
        reload()
    }

    public func applySelection(snapshot: WorkspaceSnapshot) {
        if self.snapshot.spaces == snapshot.spaces { updateSelection(id: snapshot.selectedId) }
        else { replaceSnapshot(snapshot) }
    }

    private func replaceSnapshot(_ snapshot: WorkspaceSnapshot) {
        let shownID = snapshotSpace?.id
        clearScrollPresentation()
        spaceScroll = SpaceScrollState()
        self.snapshot = snapshot
        spaceIndex = snapshot.spaces.firstIndex { $0.id == shownID } ?? min(spaceIndex, max(0, snapshot.spaces.count - 1))
        selectedID = snapshot.selectedId
        reload()
    }

    public func applyClose(id: String, snapshot: WorkspaceSnapshot) {
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
        onClose?(id)
    }

    public func showSpace(at index: Int) {
        guard snapshot.spaces.indices.contains(index) else { return }
        finishRowMotion()
        clearScrollPresentation()
        spaceScroll = SpaceScrollState()
        spaceIndex = index
        reload()
        onShowSpace?(snapshot.spaces[index].id)
    }

    private func build() {
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

        let scroll = SidebarScrollView()
        scroll.onScroll = { [weak self] event in self?.handleSpaceScroll(event) ?? false }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let document = FlippedView()
        document.addSubview(rows)
        scroll.documentView = document
        rows.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false

        dock.orientation = .horizontal
        dock.spacing = 0

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

        let column = NSStackView(views: [urlField, spaceViewport, dock])
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
            dock.widthAnchor.constraint(equalTo: urlField.widthAnchor),
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
        updateFill()
    }

    override public func layout() {
        super.layout()
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

        dock.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, space) in snapshot.spaces.enumerated() {
            let title = space.icon ?? String(space.title.prefix(1))
            let button = NSButton(title: title, target: self, action: #selector(dockClicked(_:)))
            button.tag = index
            button.isBordered = false
            button.toolTip = space.title
            button.font = .systemFont(ofSize: 15, weight: index == spaceIndex ? .bold : .regular)
            button.widthAnchor.constraint(equalToConstant: 34).isActive = true
            dock.addArrangedSubview(button)
        }
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
        onSelect?(row)
    }

    @objc private func dockClicked(_ sender: NSButton) {
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

    private func handleSpaceScroll(_ event: NSEvent) -> Bool {
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
        let layer = spaceColumn.layer
        let offset = layer?.animation(forKey: "space.scroll") == nil
            ? layer?.transform.m41 : (layer?.presentation()?.transform.m41 ?? layer?.transform.m41)
        let action = spaceScroll.handle(input, index: spaceIndex, count: snapshot.spaces.count,
                                        pitch: spacePagePitch, presentationOffset: Double(offset ?? 0))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        switch action {
        case .vertical: return false
        case .ignored: return true
        case .follow(let offset):
            scrollGeneration += 1
            for (view, _) in scrollPages { view.layer?.removeAnimation(forKey: "space.scroll") }
            prepareScrollPages(offset: offset)
            for (view, origin) in scrollPages { view.layer?.transform = CATransform3DMakeTranslation(origin + offset, 0, 0) }
        case .settle(let index, let offset, let switched):
            let from = offset + Double(index - spaceIndex) * spacePagePitch
            if switched { scrollToSpace(at: index) }
            prepareScrollPages(offset: from)
            settleScroll(from: from, switched: switched)
        }
        return true
    }

    private var scrollPages: [(NSView, Double)] {
        [(spaceColumn, 0)] + scrollPreviews.compactMap { preview in
            preview.superview.map { ($0, Double(preview.spaceIndex - spaceIndex) * spacePagePitch) }
        }
    }

    private func scrollToSpace(at index: Int) {
        let decision = spaceScroll
        showSpace(at: index)
        spaceScroll = decision
    }

    private func prepareScrollPages(offset: Double) {
        guard !spaceViewport.bounds.isEmpty, spacePagePitch > 0 else { return }
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
            preview.selectedID = selectedID
            preview.showSpace(at: index)
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

    private func settleScroll(from offset: Double, switched: Bool) {
        scrollGeneration += 1
        let response = switched ? SidebarMetrics.spaceSwitchResponse : SidebarMetrics.spaceReturnResponse
        let damping = switched ? SidebarMetrics.spaceSwitchDamping : SidebarMetrics.spaceReturnDamping
        let omega = 2 * CGFloat.pi / response
        let generation = scrollGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                guard let self, self.scrollGeneration == generation else { return }
                self.clearScrollPresentation()
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

    private func clearScrollPresentation() {
        scrollGeneration += 1
        for (view, _) in scrollPages {
            view.layer?.removeAnimation(forKey: "space.scroll")
            view.layer?.transform = CATransform3DIdentity
        }
        scrollPreviews.forEach { $0.superview?.removeFromSuperview() }
        scrollPreviews.removeAll()
        showingScrollPages = false
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class SidebarScrollView: NSScrollView {
    var onScroll: ((NSEvent) -> Bool)?

    override func scrollWheel(with event: NSEvent) {
        if onScroll?(event) != true { super.scrollWheel(with: event) }
    }
}
