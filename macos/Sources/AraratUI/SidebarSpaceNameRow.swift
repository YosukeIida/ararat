import AppKit
import AraratKit

// S1–S4: the space name row. The name rests at x 16, a chevron appears at x 16 on hover and
// while the pinned section is collapsed (the name then sits at x 40, D10), a … button opens
// the space menu on hover and a right-click opens the same menu (D12), and rename starts only
// from that menu.
@MainActor
public final class SidebarSpaceNameRow: NSView {
    var space: SpaceSnapshot? { didSet { update() } }
    // D1: the flag rides in the space snapshot, so every window shows the same chevron.
    var collapsed: Bool { space?.pinnedCollapsed ?? false }
    /// The space menu, built by the sidebar from the U22 items (rename, look, settings, folder,
    /// delete) and anchored to this row.
    var menuProvider: (() -> NSMenu?)? {
        didSet { moreButton.menuProvider = menuProvider }
    }
    var onToggle: (() -> Void)?
    var onRenameEnded: (() -> Void)?
    private(set) var renameField: SidebarRenameField?
    let moreButton = SidebarMenuButton()
    private let chevron = NSButton()
    private let name = NSTextField(labelWithString: "")
    private var nameLeading: NSLayoutConstraint!
    private var trackingPress = false
    // Check hook: the pointer is not moved by a check, so the hover state is driven directly.
    public var hovered = false { didSet { update() } }
    /// D5: the private window shows "Private" as a plain label: no chevron, no … menu, no toggle.
    public var interactive = true { didSet { update() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        chevron.isBordered = false
        chevron.imagePosition = .imageOnly
        chevron.imageScaling = .scaleNone
        chevron.target = self
        chevron.action = #selector(chevronPressed)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.isHidden = true
        addSubview(chevron)
        name.font = .systemFont(ofSize: 14, weight: .medium)
        name.textColor = .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        moreButton.isBordered = false
        moreButton.imagePosition = .imageOnly
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.isHidden = true
        addSubview(moreButton)
        nameLeading = name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.spaceNameLeading)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SidebarMetrics.spaceRowHeight),
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.spaceChevronLeading),
            chevron.centerYAnchor.constraint(equalTo: name.firstBaselineAnchor, constant: -name.font!.capHeight / 2),
            chevron.widthAnchor.constraint(equalToConstant: SidebarMetrics.spaceChevronSize),
            chevron.heightAnchor.constraint(equalToConstant: SidebarMetrics.spaceChevronSize),
            nameLeading,
            name.trailingAnchor.constraint(lessThanOrEqualTo: moreButton.leadingAnchor, constant: -8),
            // The 22 pt gap to the tiles is measured to the name's cap top (D10).
            name.firstBaselineAnchor.constraint(equalTo: topAnchor, constant: name.font!.capHeight),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.spaceMoreTrailing),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: SidebarMetrics.spaceMoreSize),
            moreButton.heightAnchor.constraint(equalToConstant: SidebarMetrics.spaceMoreSize),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refreshHover()
    }

    @objc func refreshHover() {
        let point = window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil
        let inside = point.map { bounds.contains(convert($0, from: nil)) } ?? false
        if hovered != inside { hovered = inside }
    }

    public override func mouseEntered(with event: NSEvent) { refreshHover() }
    public override func mouseExited(with event: NSEvent) { refreshHover() }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    private func update() {
        let title = [space?.icon, space?.title].compactMap { $0 }.joined(separator: " ")
        name.stringValue = title
        name.toolTip = title.isEmpty ? nil : title
        let showsChevron = (hovered || collapsed) && interactive
        chevron.isHidden = !showsChevron
        moreButton.isHidden = !hovered || !interactive
        nameLeading.constant = showsChevron ? SidebarMetrics.spaceNameIndented : SidebarMetrics.spaceNameLeading
        chevron.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.down",
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))
        chevron.setAccessibilityLabel(collapsed ? "Expand pinned tabs" : "Collapse pinned tabs")
        setAccessibilityLabel(title)
        setAccessibilityHelp(collapsed ? "Expand pinned tabs" : "Collapse pinned tabs")
    }

    // A click anywhere but the buttons toggles the section (S2), on release like a folder row.
    public override func mouseDown(with event: NSEvent) {
        trackingPress = true
    }

    public override func mouseUp(with event: NSEvent) {
        let inside = trackingPress && bounds.contains(convert(event.locationInWindow, from: nil))
        trackingPress = false
        if inside && interactive { onToggle?() }
    }

    public override func accessibilityPerformPress() -> Bool {
        guard interactive else { return false }
        onToggle?()
        return true
    }

    @objc private func chevronPressed() { onToggle?() }

    public override func menu(for event: NSEvent) -> NSMenu? { interactive ? menuProvider?() : nil }

    public var checkNameFrame: NSRect {
        // alignmentRect(forFrame:) already answers in the superview’s coordinates.
        name.alignmentRect(forFrame: name.frame)
    }
    public var checkName: String { name.stringValue }
    public var checkNameFontSize: CGFloat { name.font?.pointSize ?? 0 }
    public var checkChevronVisible: Bool { !chevron.isHidden }
    public var checkRenameFieldFrame: NSRect? { renameField?.frame }
    public func finishRenameForCheck(_ commit: Bool) { renameField?.finish(commit: commit) }
    /// p4checks: the field's text, before the same commit path Return runs.
    public func checkTypeRename(_ text: String) { renameField?.stringValue = text }

    func beginRename(save: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        guard renameField == nil else { return }
        let field = SidebarRenameField(title: space?.title ?? "", save: save, ended: { [weak self] in
            guard let self else { return }
            self.renameField = nil
            self.name.isHidden = false
            self.onRenameEnded?()
        })
        renameField = field
        name.isHidden = true
        addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            // S4: the space rename field is 24 pt tall.
            field.heightAnchor.constraint(equalToConstant: 24),
        ])
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func finishRename(commit: Bool) { renameField?.finish(commit: commit) }
}

// A button that opens the provider's menu on click; a right-click on its row asks the same
// provider through menu(for:).
@MainActor
public final class SidebarMenuButton: NSButton {
    var menuProvider: (() -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        target = self
        action = #selector(openMenu)
        setAccessibilityLabel("Space menu")
        toolTip = "Space menu"
        if let image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil) {
            self.image = image.withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func openMenu() {
        guard let menu = menuProvider?() else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
    }

    public override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}
