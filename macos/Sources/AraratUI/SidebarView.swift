import AppKit
import AraratKit

@MainActor
public final class SidebarView: NSView {
    public var onSelect: ((Row) -> Void)?

    private let snapshot: WorkspaceSnapshot
    private var spaceIndex = 0
    private var selectedID: String?

    private let header = NSTextField(labelWithString: "")
    private let urlField = NSView()
    private let host = NSTextField(labelWithString: "")
    private let favorites = NSStackView()
    private var favoriteColumns = 0
    private var favoritesHeight: NSLayoutConstraint!
    private let rows = NSStackView()
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
        super.init(frame: .zero)
        build()
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public var spaceShown: Int { spaceIndex }
    public var selectedRowID: String? { selectedID }

    public func selectRow(id: String) -> Bool {
        guard snapshot.spaces.indices.contains(spaceIndex) else { return false }
        let space = snapshot.spaces[spaceIndex]
        guard let row = (space.favorites + space.pinned + space.today).first(where: { $0.id == id }) else { return false }
        select(row)
        return true
    }

    public func showSpace(at index: Int) {
        guard snapshot.spaces.indices.contains(index) else { return }
        clearScrollPresentation()
        spaceScroll = SpaceScrollState()
        spaceIndex = index
        reload()
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

    // shortcut: rebuilds every row on each change; switch to rows reused by id when the sidebar becomes live (architecture §7, Cra ledger 12).
    private func reload() {
        guard snapshot.spaces.indices.contains(spaceIndex) else { return }
        let space = snapshot.spaces[spaceIndex]
        header.stringValue = [space.icon, space.title].compactMap { $0 }.joined(separator: " ")
        let selected = (space.favorites + space.pinned + space.today).first { $0.id == selectedID }
        host.stringValue = selected?.url.flatMap { URL(string: $0)?.host } ?? ""

        reloadFavorites()

        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in space.pinned { addRow(row) }
        if !space.pinned.isEmpty && !space.today.isEmpty {
            let divider = NSBox()
            divider.boxType = .separator
            rows.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        for row in space.today { addRow(row) }

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
        guard snapshot.spaces.indices.contains(spaceIndex) else { return }
        let space = snapshot.spaces[spaceIndex]
        favorites.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let columns = max(1, favoriteColumns)
        let lineCount = (space.favorites.count + columns - 1) / columns
        favoritesHeight.constant = CGFloat(lineCount * 47 + max(0, lineCount - 1) * 8)
        for chunk in stride(from: 0, to: space.favorites.count, by: columns) {
            var tiles: [NSView] = space.favorites[chunk..<min(chunk + columns, space.favorites.count)].map { row in
                FavoriteTile(row: row) { [weak self] in self?.select(row) }
            }
            while tiles.count < columns { tiles.append(NSView()) }
            let line = NSStackView(views: tiles)
            line.distribution = .fillEqually
            line.spacing = 8
            line.heightAnchor.constraint(equalToConstant: 47).isActive = true
            favorites.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: favorites.widthAnchor).isActive = true
        }
    }

    private func addRow(_ row: Row) {
        let view = SidebarRowView(row: row, selected: row.id == selectedID) { [weak self] in
            self?.select(row)
        }
        rows.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    private func select(_ row: Row) {
        selectedID = row.id
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
        if phase == .began && event.momentumPhase.isEmpty { clearScrollPresentation() }
        let input = SpaceScrollEvent(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY, phase: phase,
                                     momentum: !event.momentumPhase.isEmpty,
                                     inverted: event.isDirectionInvertedFromDevice, time: event.timestamp)
        switch spaceScroll.handle(input, index: spaceIndex, count: snapshot.spaces.count, pitch: spacePagePitch) {
        case .vertical: return false
        case .ignored: return true
        case .switchTo(let index):
            scrollToSpace(at: index)
        case .follow(let offset):
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
        guard !spaceViewport.bounds.isEmpty else { return }
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
    }

    private func settleScroll(from offset: Double, switched: Bool) {
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
