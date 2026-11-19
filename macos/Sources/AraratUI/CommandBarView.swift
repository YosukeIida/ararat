import AppKit
import AraratKit

/// The command bar panel: a wide translucent panel with the input row on top and
/// up to five result rows below. Adapted from Cra's MIT
/// `Sources/Cra/UI/CommandBar/CommandBarView.swift` (favicons and Site Search are left out
/// until the engine brings them) and its CommandBarPanel.
@MainActor
public final class CommandBarView: NSView {
    private let controller: CommandBarController
    private let material = NSVisualEffectView()
    private let tint = NSView()
    private let border = CAShapeLayer()
    private let shape = CAShapeLayer()
    private let leadingIcon = NSImageView()
    private let text: CommandTextField
    private let divider = NSView()
    private let privateNote = NSTextField(labelWithString: "Nothing is added to history in a private window.")
    private var rows: [CommandBarRowView] = []

    public init(controller: CommandBarController) {
        self.controller = controller
        text = CommandTextField(controller: controller)
        super.init(frame: NSRect(x: 0, y: 0, width: CommandBarMetrics.width, height: CommandBarMetrics.height(forRows: 0)))
        wantsLayer = true
        material.blendingMode = .behindWindow
        material.state = .active
        tint.wantsLayer = true
        layer?.mask = shape
        border.fillColor = nil
        border.lineWidth = 2 // 2 pt border [Cra, V:46]
        leadingIcon.imageScaling = .scaleProportionallyUpOrDown
        leadingIcon.wantsLayer = true
        leadingIcon.layer?.cornerCurve = .continuous
        divider.wantsLayer = true
        privateNote.font = .systemFont(ofSize: 12)
        privateNote.textColor = .secondaryLabelColor
        privateNote.alignment = .center
        for view in [material, tint, leadingIcon, text.field, divider, privateNote] as [NSView] { addSubview(view) }
        layer?.addSublayer(border)
        border.zPosition = 10
        controller.onChange = { [weak self] in self?.sync() }
        sync()
    }

    /// The query field, for tests and focus handling.
    public var field: NSTextField { text.field }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override public var isFlipped: Bool { true }

    /// ⌘Return forces a new tab. The field editor's key bindings map a command-modified Return
    /// to `noop:`, so the bar takes it in the key-equivalent pass, which runs before them, and
    /// commits through the same completion step as Return does (Cra F:126-135).
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.characters == "\r", event.modifierFlags.contains(.command), controller.isOpen,
           (text.field.currentEditor() as? NSTextView)?.hasMarkedText() != true {
            text.commitReturn(forceNewTab: true)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    public func focusField() {
        window?.makeFirstResponder(text.field)
        text.update()
    }

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sync()
    }

    public func sync() {
        let items = controller.result.rows
        let dark = self.dark
        text.update()
        // `.hudWindow` (dark) or `.popover` (light) with a tint of black 0.74 / white 0.7
        // [Cra, V:102-105, compared against Arc pixel for pixel].
        material.material = dark ? .hudWindow : .popover
        tint.layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.74) : NSColor.white.withAlphaComponent(0.7)).cgColor
        border.strokeColor = NSColor.labelColor.withAlphaComponent(dark ? 0.12 : 0.08).cgColor // [Cra, V:106,177]
        divider.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        divider.isHidden = items.isEmpty
        privateNote.isHidden = !controller.result.privateWindow
        // The field's leading icon: a magnifying glass (favicon when the engine brings a cache) [Cra, F:35-41, V:138-145].
        leadingIcon.imageScaling = .scaleNone
        leadingIcon.image = NSImage(systemSymbolName: controller.mode == .editURL ? "info.circle" : "magnifyingglass", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        leadingIcon.contentTintColor = .secondaryLabelColor

        while rows.count < items.count {
            let row = CommandBarRowView()
            row.onHover = { [weak self, weak row] in
                guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }) else { return }
                if self.controller.selectedIndex != index { self.controller.moveSelection(by: index - self.controller.selectedIndex) }
            }
            row.onClick = { [weak self, weak row] in
                guard let self, let row, let index = self.rows.firstIndex(where: { $0 === row }), self.controller.result.rows.indices.contains(index) else { return }
                self.controller.commit(self.controller.result.rows[index])
            }
            rows.append(row)
            addSubview(row)
        }
        for (index, row) in rows.enumerated() {
            guard index < items.count else { row.isHidden = true; continue }
            row.isHidden = false
            row.show(items[index], selected: index == controller.selectedIndex, highlight: controller.highlight,
                     queryEmpty: controller.query.isEmpty, dark: dark)
        }
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        let bounds = self.bounds
        material.frame = bounds
        tint.frame = bounds
        let path = Self.path(bounds, radius: 14) // corner radius 14 [Cra, V:46]
        shape.frame = bounds
        shape.path = path
        border.frame = bounds
        border.path = path
        // Input row: 22 pt in, icon 22, 14 apart, the field 30 tall [Cra, V:183-186,201].
        let fieldHeight = CommandBarMetrics.fieldHeight
        let iconSize: CGFloat = 22
        leadingIcon.frame = NSRect(x: 22, y: (fieldHeight - iconSize) / 2, width: iconSize, height: iconSize)
        text.field.frame = NSRect(x: 22 + 22 + 14, y: (fieldHeight - 30) / 2 + 2, width: max(0, bounds.width - 22 - 22 - 14 - 22), height: 30)
        divider.frame = NSRect(x: 16, y: fieldHeight, width: max(0, bounds.width - 32), height: 1)
        privateNote.frame = NSRect(x: 10, y: bounds.height - 32, width: bounds.width - 20, height: 32)
        var y: CGFloat = fieldHeight + CommandBarMetrics.rowInset
        for row in rows where !row.isHidden {
            row.frame = NSRect(x: CommandBarMetrics.rowInset, y: y, width: bounds.width - 2 * CommandBarMetrics.rowInset, height: CommandBarMetrics.rowHeight)
            y += CommandBarMetrics.rowHeight + CommandBarMetrics.rowGap
        }
    }

    private static func path(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// One suggestion: icon, "Title — detail", and "Switch to Tab" + arrow for open tabs
/// [Cra, V:254-344]. Adapted from Cra's CommandBarRowView.
final class CommandBarRowView: NSView {
    var onHover: () -> Void = {}
    var onClick: () -> Void = {}
    private let iconBox = NSView()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let trailing = NSTextField(labelWithString: "")
    private let arrowBox = NSView()
    private let arrow = NSImageView()
    private var shown: (Suggestion, Bool, NSColor, Bool, Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10 // rows: radius 10 [Cra, V:254]
        layer?.cornerCurve = .continuous
        iconBox.wantsLayer = true
        iconBox.layer?.cornerRadius = 6 // a 26 pt icon box with radius 6 [Cra, V:257]
        iconBox.layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleProportionallyUpOrDown
        arrowBox.wantsLayer = true
        arrowBox.layer?.cornerRadius = 6
        arrowBox.layer?.cornerCurve = .continuous
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        arrow.imageScaling = .scaleNone
        label.lineBreakMode = .byTruncatingMiddle // middle truncation [Cra, V:265]
        trailing.textColor = .secondaryLabelColor
        icon.identifier = NSUserInterfaceItemIdentifier("command-result-icon")
        label.identifier = NSUserInterfaceItemIdentifier("command-result-title")
        trailing.identifier = NSUserInterfaceItemIdentifier("command-result-detail")
        for view in [iconBox, icon, label, trailing, arrowBox, arrow] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(_ suggestion: Suggestion, selected: Bool, highlight: NSColor, queryEmpty: Bool, dark: Bool) {
        if let shown, shown.0 == suggestion, shown.1 == selected, shown.2 == highlight, shown.3 == queryEmpty, shown.4 == dark { return }
        shown = (suggestion, selected, highlight, queryEmpty, dark)
        layer?.backgroundColor = (selected ? highlight : .clear).cgColor
        let foreground = selected ? SpaceAccent.foreground(on: highlight) : .labelColor
        let secondary = selected ? foreground : NSColor.secondaryLabelColor
        let isTab: Bool
        switch suggestion.target { case .tab: isTab = true; default: isTab = false }
        iconBox.layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.06)).cgColor
        if case .search = suggestion.target {
            icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        } else {
            icon.image = NSImage(systemSymbolName: Self.symbol(suggestion), accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        }
        icon.contentTintColor = secondary
        // The title is 15 pt semibold, followed by a regular " — url" tail [Cra, V:301-302].
        let title = NSMutableAttributedString(string: suggestion.title, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: foreground,
        ])
        title.append(NSAttributedString(string: Self.detail(suggestion), attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: secondary,
        ]))
        label.attributedStringValue = title
        trailing.textColor = secondary
        if isTab {
            // "Switch to Tab" is 14 pt medium, with an arrow [Cra, V:305-307].
            trailing.font = .systemFont(ofSize: 14, weight: .medium)
            trailing.stringValue = queryEmpty ? suggestion.subtitle : "Switch to Tab"
        } else if case .command = suggestion.target, let key = suggestion.key {
            trailing.font = .systemFont(ofSize: 14, weight: .medium)
            trailing.stringValue = Self.keycap(key)
        } else {
            trailing.font = .systemFont(ofSize: 14, weight: .medium)
            switch suggestion.target {
            case .openUrl: trailing.stringValue = "Open URL"
            case .search: trailing.stringValue = "Search"
            case .history: trailing.stringValue = "History"
            case .space: trailing.stringValue = "Switch to Space"
            case .folder: trailing.stringValue = "Open Folder"
            case .moveToSpace, .moveToFolder: trailing.stringValue = "Move Tab"
            default: trailing.stringValue = suggestion.subtitle
            }
        }
        arrowBox.isHidden = !isTab
        arrow.isHidden = !isTab
        arrow.contentTintColor = foreground
        arrowBox.layer?.backgroundColor = foreground.withAlphaComponent(0.1).cgColor
        setAccessibilityLabel("\(suggestion.title)\(suggestion.subtitle.isEmpty ? "" : ", \(suggestion.subtitle)")")
        needsLayout = true
    }

    /// [ours] No favicon cache yet, so every kind gets a symbol by target.
    private static func symbol(_ suggestion: Suggestion) -> String {
        switch suggestion.target {
        case .tab, .openUrl: return "globe"
        case .history: return "clock"
        case .search: return "magnifyingglass"
        case .command: return "command"
        case .space, .moveToSpace: return "square.grid.2x2"
        case .folder, .moveToFolder: return "folder"
        }
    }

    /// [ours] The effective key from the core's binding table.
    static func keycap(_ key: KeyCombination) -> String {
        var caps = SidebarTooltip.caps(for: key)
        if key.key == "\t" { caps[caps.count - 1] = "Tab" }
        return caps.joined()
    }

    private static func detail(_ suggestion: Suggestion) -> String {
        switch suggestion.target {
        case .openUrl, .search, .command, .space, .folder, .moveToSpace, .moveToFolder, .history:
            return "" // the trailing text names these rows (Cra's detail for the same kinds)
        case .tab:
            guard let url = suggestion.url else { return "" }
            let human = humanURL(url)
            return human.lowercased() == suggestion.title.lowercased() ? "" : " — \(human)" // [Cra, V:324-326]
        }
    }

    /// Cra's MIT SuggestionEngine.humanURL.
    static func humanURL(_ url: String) -> String {
        var text = url
        for prefix in ["https://www.", "http://www.", "https://", "http://"] where text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
        if text.hasSuffix("/") { text.removeLast() }
        if text.count > 70 { text = String(text.prefix(67)) + "…" }
        return text
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        // padding 14, icon 26, 14 apart, the title, 8 pt, trailing text, 14, arrow box 22 [Cra, V:333].
        iconBox.frame = NSRect(x: 14, y: (height - 26) / 2, width: 26, height: 26)
        icon.frame = iconBox.frame.insetBy(dx: 4, dy: 4)
        var right = bounds.width - 14
        if !arrowBox.isHidden {
            arrowBox.frame = NSRect(x: right - 22, y: (height - 22) / 2, width: 22, height: 22)
            arrow.frame = arrowBox.frame
            right -= 22 + 14
        }
        if !trailing.stringValue.isEmpty {
            let width = ceil(trailing.attributedStringValue.size().width)
            let textHeight = trailing.intrinsicContentSize.height
            trailing.frame = NSRect(x: right - width, y: (height - textHeight) / 2, width: width, height: textHeight)
            right -= width + 14
        } else if !arrowBox.isHidden {
            // The empty label still takes its spacing in the HStack.
            right -= 14
        }
        let x: CGFloat = 14 + 26 + 14
        let labelSize = label.intrinsicContentSize
        label.frame = NSRect(x: x, y: (height - labelSize.height) / 2, width: max(0, right - 8 - x), height: labelSize.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover() }
    override func mouseMoved(with event: NSEvent) { onHover() }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

/// Borderless floating panel that can take keyboard focus (Cra's MIT CommandBarPanel).
/// Show and hide in a single frame, with no fade [Arc, D:458].
@MainActor
public final class CommandBarPanel: NSPanel {
    /// A table command rebound without Command is typed into the field, never sunk at the
    /// menu pass while the panel is key. The harness sets the effective table on open; empty
    /// means nothing yields.
    public var menuCommandBindings: [KeyBinding] = []

    public init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: CommandBarMetrics.width, height: CommandBarMetrics.height(forRows: 0)),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true // the system panel shadow [Cra, M:205]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }

    override public var canBecomeKey: Bool { true }
    override public var canBecomeMain: Bool { false }

    /// The own-field gate, as BrowserWindow's and SettingsWindow's: the key is claimed here and
    /// typed into the field (AppKit's menu pass would sink or fire it).
    override public func performKeyEquivalent(with event: NSEvent) -> Bool {
        if WorkspaceCommands.yieldsToOwnField(menuCommandBindings, event: event, in: self) {
            firstResponder?.keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
