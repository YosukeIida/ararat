import AppKit
import AraratKit

@MainActor
final class LibraryView: NSView {
    enum Page: String { case archive = "Archive" }
    private(set) var page = Page.archive
    var onRestore: ((String) -> Void)?
    private let entries = NSStackView()
    private let rail = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        rail.wantsLayer = true
        let archive = NSButton(title: Page.archive.rawValue, target: self, action: #selector(showArchive))
        archive.isBordered = false
        archive.alignment = .left
        archive.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize, weight: .semibold)
        archive.setAccessibilityLabel("Archive page")
        rail.addSubview(archive)
        let scroll = LibraryScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        entries.orientation = .vertical
        entries.alignment = .leading
        entries.spacing = SidebarMetrics.libraryRowSpacing
        let document = LibraryDocumentView()
        document.addSubview(entries)
        scroll.documentView = document
        for view in [rail, scroll] { addSubview(view) }
        for view in [rail, scroll, archive, entries, document] { view.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.widthAnchor.constraint(equalToConstant: SidebarMetrics.libraryRailWidth),
            rail.topAnchor.constraint(equalTo: topAnchor), rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            archive.leadingAnchor.constraint(equalTo: rail.leadingAnchor, constant: SidebarMetrics.libraryContentInset),
            archive.trailingAnchor.constraint(equalTo: rail.trailingAnchor, constant: -SidebarMetrics.libraryContentInset),
            archive.topAnchor.constraint(equalTo: rail.topAnchor, constant: SidebarMetrics.libraryContentTop),
            archive.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryRowHeight),
            scroll.leadingAnchor.constraint(equalTo: rail.trailingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: SidebarMetrics.libraryContentTop),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SidebarMetrics.libraryContentTop),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: entries.heightAnchor, constant: SidebarMetrics.libraryContentInset * 2),
            entries.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: SidebarMetrics.libraryContentInset),
            entries.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -SidebarMetrics.libraryContentInset),
            entries.topAnchor.constraint(equalTo: document.topAnchor, constant: SidebarMetrics.libraryContentInset),
        ])
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }

    func update(archive: [Row]) {
        entries.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if archive.isEmpty {
            let empty = NSTextField(labelWithString: "No archived tabs")
            empty.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize)
            empty.textColor = .secondaryLabelColor
            empty.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            empty.lineBreakMode = .byTruncatingTail
            entries.addArrangedSubview(empty)
        }
        for row in archive {
            let button = NSButton(title: row.title, image: SidebarRowView.symbol(for: .tab), target: self, action: #selector(restore(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(row.id)
            button.imagePosition = .imageLeading
            button.imageScaling = .scaleProportionallyDown
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: SidebarMetrics.libraryFontSize)
            button.toolTip = row.url
            button.setAccessibilityLabel("Restore \(row.title)")
            entries.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: entries.widthAnchor).isActive = true
            button.heightAnchor.constraint(equalToConstant: SidebarMetrics.libraryRowHeight).isActive = true
        }
    }

    @objc private func showArchive() { page = .archive }
    @objc private func restore(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue { onRestore?(id) }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            rail.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        }
    }
}

final class LibraryButton: NSButton {
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

private final class LibraryDocumentView: NSView { override var isFlipped: Bool { true } }
private final class LibraryScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }
}
