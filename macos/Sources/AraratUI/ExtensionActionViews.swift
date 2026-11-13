import AppKit
import AraratKit

/// A toolbar action's button. Chromium renders the badge into the icon, so the button draws the
/// icon alone; the badge text and colours travel as accessibility information and for checks.
@MainActor
public final class ExtensionActionButton: NSButton {
    public private(set) var item: ExtensionActionItem
    public var menuProvider: ((ExtensionActionItem, ExtensionActionButton) -> NSMenu?)?
    /// Left click invokes the action; the context menu is only for a right click, as in Chrome.
    public var onOpen: ((ExtensionActionItem, ExtensionActionButton) -> Void)?

    public init(item: ExtensionActionItem, size: CGFloat) {
        self.item = item
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        focusRingType = .default
        target = self
        action = #selector(clicked(_:))
        update(item: item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func update(item: ExtensionActionItem) {
        self.item = item
        image = item.icon
        isEnabled = item.enabled
        toolTip = item.badgeText.isEmpty ? item.tooltip : "\(item.tooltip) — \(item.badgeText)"
        setAccessibilityLabel(item.name)
        setAccessibilityHelp(item.tooltip)
        setAccessibilityValue(item.badgeText.isEmpty ? "" : "Badge \(item.badgeText)")
        setAccessibilityIdentifier("extension-action-\(item.id)")
        needsDisplay = true
    }

    public var checkIconSize: NSSize { image?.size ?? .zero }

    /// The action-specific anchor the engine's popup uses, in window coordinates. Passed
    /// immediately before every menu command and action invocation.
    public var anchorInWindow: NSRect {
        guard let window, let root = window.contentView else { return .zero }
        return convert(bounds, to: root)
    }

    @objc private func clicked(_ sender: Any?) {
        onOpen?(item, self)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?(item, self) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(item, self)
    }
}

/// The pinned actions inside the URL field. A plain view with manual placement rather than a
/// stack: the URL field must not gain another stack the older screen tests treat as a space
/// viewport marker.
@MainActor
public final class ExtensionActionsStrip: NSView {
    public private(set) var items: [ExtensionActionItem] = []
    public var onOpen: ((ExtensionActionItem, ExtensionActionButton) -> Void)?
    public var onMenu: ((ExtensionActionItem, ExtensionActionButton) -> NSMenu?)?
    private var buttons: [String: ExtensionActionButton] = [:]

    public override var isFlipped: Bool { true }

    public var checkItems: [String] { items.map(\.id) }
    public var checkLabelsComplete: Bool {
        !buttons.isEmpty && buttons.values.allSatisfy {
            !(($0.accessibilityLabel() ?? "").isEmpty)
                && ($0.accessibilityValue() as? String ?? "") == ($0.item.badgeText.isEmpty ? "" : "Badge \($0.item.badgeText)")
        }
    }
    public func checkButton(_ id: String) -> ExtensionActionButton? { buttons[id] }
    public var checkFrames: [String: NSRect] { buttons.mapValues { $0.frame } }

    public func update(items: [ExtensionActionItem]) {
        let ids = Set(items.map(\.id))
        for id in Array(buttons.keys) where !ids.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in items {
            if let existing = buttons[item.id] {
                existing.update(item: item)
            } else {
                let button = ExtensionActionButton(item: item, size: 24)
                button.menuProvider = { [weak self] item, button in self?.onMenu?(item, button) }
                button.onOpen = { [weak self] item, button in self?.onOpen?(item, button) }
                addSubview(button)
                buttons[item.id] = button
            }
        }
        self.items = items
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        for (index, item) in items.enumerated() {
            guard let button = buttons[item.id] else { continue }
            button.frame = NSRect(x: CGFloat(index) * 28, y: 0, width: 24, height: 24)
        }
    }

    public static func width(for count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * 24 + CGFloat(count - 1) * 4
    }
}

/// The pinned actions when the URL field cannot keep them (the host would drop below 64 pt).
/// Tiles are 32 pt tall with 16 pt icons on the favourites' column pitch; when they do not fit
/// one line they wrap onto further 32 pt lines rather than dropping an action (D4: the
/// site-controls grid that would hold the rest is not built yet).
@MainActor
public final class ExtensionActionsRow: NSView {
    public private(set) var items: [ExtensionActionItem] = []
    public var onOpen: ((ExtensionActionItem, ExtensionActionButton) -> Void)?
    public var onMenu: ((ExtensionActionItem, ExtensionActionButton) -> NSMenu?)?
    public var columns = 4
    private var buttons: [String: ExtensionActionButton] = [:]

    public var checkLabelsComplete: Bool {
        !buttons.isEmpty && buttons.values.allSatisfy {
            !(($0.accessibilityLabel() ?? "").isEmpty)
                && ($0.accessibilityValue() as? String ?? "") == ($0.item.badgeText.isEmpty ? "" : "Badge \($0.item.badgeText)")
        }
    }
    public var checkFrames: [String: NSRect] { buttons.mapValues { convert($0.bounds, from: $0) } }
    public func checkButton(_ id: String) -> ExtensionActionButton? { buttons[id] }
    /// Wraps onto further 32 pt lines rather than hiding actions that do not fit one line.
    public var checkRowHeight: CGFloat { requiredHeight }
    public var requiredHeight: CGFloat {
        guard !items.isEmpty else { return 0 }
        let columns = max(1, min(4, self.columns))
        let lines = (items.count + columns - 1) / columns
        return 32 * CGFloat(lines)
    }

    public override var isFlipped: Bool { true }

    public func update(items: [ExtensionActionItem]) {
        let ids = Set(items.map(\.id))
        for id in Array(buttons.keys) where !ids.contains(id) {
            buttons.removeValue(forKey: id)?.removeFromSuperview()
        }
        for item in items {
            if let button = buttons[item.id] {
                button.update(item: item)
            } else {
                let button = ExtensionActionButton(item: item, size: 32)
                button.menuProvider = { [weak self] item, button in self?.onMenu?(item, button) }
                button.onOpen = { [weak self] item, button in self?.onOpen?(item, button) }
                addSubview(button)
                buttons[item.id] = button
            }
        }
        self.items = items
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: requiredHeight)
    }

    public override func layout() {
        super.layout()
        guard !items.isEmpty else { return }
        let columns = max(1, min(4, self.columns))
        let tile = (bounds.width + 8) / CGFloat(columns) - 8
        for (index, item) in items.enumerated() {
            guard let button = buttons[item.id] else { continue }
            let column = index % columns
            let line = index / columns
            button.frame = NSRect(x: (tile + 8) * CGFloat(column), y: 32 * CGFloat(line), width: tile, height: 32)
        }
    }

    public func tileFrame(for id: String) -> NSRect? {
        buttons[id].map { convert($0.bounds, from: $0) }
    }
}
