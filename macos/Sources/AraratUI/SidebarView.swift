import AppKit
import AraratKit

// Sizes are Dia's measured values (research/arc-dia-components.md §5.2), not Arc's 328 pt
// layout, until the owner picks a target.
@MainActor
public final class SidebarView: NSView {
    public var onSelect: ((Row) -> Void)?

    private let snapshot: WorkspaceSnapshot
    private var spaceIndex = 0
    private var selectedID: String?

    private let header = NSTextField(labelWithString: "")
    private let favorites = NSStackView()
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

    public func showSpace(at index: Int) {
        guard snapshot.spaces.indices.contains(index) else { return }
        spaceIndex = index
        reload()
    }

    private func build() {
        header.font = .systemFont(ofSize: 13, weight: .semibold)
        header.textColor = .secondaryLabelColor

        favorites.orientation = .vertical
        favorites.spacing = 8
        favorites.alignment = .leading

        rows.orientation = .vertical
        rows.spacing = 3
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

        let column = NSStackView(views: [header, favorites, scroll, dock])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 10
        column.edgeInsets = NSEdgeInsets(top: 46, left: 6, bottom: 8, right: 6)
        addSubview(column)
        column.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            favorites.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -12),
            scroll.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -12),
            rows.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            rows.topAnchor.constraint(equalTo: document.topAnchor),
            rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: rows.heightAnchor),
        ])
    }

    // shortcut: rebuilds every row on each change; switch to rows reused by id when the sidebar becomes live (architecture §7, Cra ledger 12).
    private func reload() {
        guard snapshot.spaces.indices.contains(spaceIndex) else { return }
        let space = snapshot.spaces[spaceIndex]
        header.stringValue = [space.icon, space.title].compactMap { $0 }.joined(separator: " ")

        favorites.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for chunk in stride(from: 0, to: space.favorites.count, by: 4) {
            let tiles = space.favorites[chunk..<min(chunk + 4, space.favorites.count)].map { row in
                FavoriteTile(row: row) { [weak self] in self?.select(row) }
            }
            let line = NSStackView(views: tiles)
            line.distribution = .fillEqually
            line.spacing = 8
            favorites.addArrangedSubview(line)
            line.widthAnchor.constraint(equalTo: favorites.widthAnchor).isActive = true
        }

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
