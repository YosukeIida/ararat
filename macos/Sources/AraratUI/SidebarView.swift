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

        let scroll = NSScrollView()
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

        let column = NSStackView(views: [urlField, favorites, heading, scroll, dock])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(8, after: urlField)
        column.setCustomSpacing(22, after: favorites)
        column.setCustomSpacing(10, after: scroll)
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
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
