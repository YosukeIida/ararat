import AppKit
import AraratKit

/// `--ararat-check=organize` or `--ararat-screen=organize`: the rename hint's arm, show and hide
/// lines. The hint is the organize check's one intermittent condition, so the lines say what
/// the row was and which state took the hint down.
enum PinHintTrace {
    static let enabled = CommandLine.arguments.contains("--ararat-check=organize")
        || CommandLine.arguments.contains("--ararat-screen=organize")
}

/// The U20 board's selected shadow (`--selsh`), drawn the way CSS draws `box-shadow`: outside the
/// fill alone. A layer's own shadow lands under its contents, so with a translucent fill it shows
/// through and darkens it; this casts the shadow on a layer of its own and masks that layer to
/// everything outside the fill's rounded path.
@MainActor
final class SelectedRowShadow {
    // The shadow reaches 1 pt down plus three sigma of its 1 pt blur radius.
    private static let margin: CGFloat = 4
    /// The layer that casts the shadow; its mask keeps only what lies outside the fill.
    let layer = CAShapeLayer()
    private let outside = CAShapeLayer()

    init(name: String) {
        layer.name = name
        // Why not a filled shape: the fill and the mask's hole would share one path, so an edge
        // pixel covered c by the fill and kept 1 - c by the mask gets black at c(1 - c), a ring of
        // up to a quarter at every corner. A clear fill draws nothing; only the shadow the window
        // server casts from `shadowPath` shows, and the even-odd mask keeps it outside the fill.
        layer.fillColor = NSColor.clear.cgColor
        outside.fillRule = .evenOdd
        layer.mask = outside
    }

    /// `rect` is the fill's frame in its superlayer and `path` its rounded path in the fill's own
    /// coordinates. `flipped` is the flip of the view whose layer holds the shadow layer, not the
    /// fill's: a flipped view's shape layer sits in y-down coordinates while its own flag is false.
    func apply(rect: CGRect, path: CGPath?, flipped: Bool, on: Bool, appearance: NSAppearance, scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let path, !path.isEmpty else { layer.shadowOpacity = 0; layer.isHidden = true; return }
        let box = path.boundingBoxOfPath
        layer.bounds = CGRect(origin: .zero, size: CGSize(width: box.width + 2 * Self.margin, height: box.height + 2 * Self.margin))
        layer.position = CGPoint(x: rect.midX, y: rect.midY)
        layer.contentsScale = scale
        outside.frame = layer.bounds
        let shaped = CGMutablePath()
        shaped.addPath(path, transform: CGAffineTransform(translationX: Self.margin - box.minX, y: Self.margin - box.minY))
        layer.shadowPath = shaped
        let masked = CGMutablePath()
        masked.addRect(layer.bounds)
        masked.addPath(shaped)
        outside.path = masked
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let alpha = on ? (dark ? SidebarMetrics.rowSelectedShadowAlphaDark : SidebarMetrics.rowSelectedShadowAlpha) : 0
        layer.shadowColor = NSColor.black.cgColor
        // The board draws 1 pt down; a y-up layer takes the negative offset and a flipped one the
        // positive.
        layer.shadowOffset = CGSize(width: 0, height: flipped ? SidebarMetrics.rowSelectedShadowY : -SidebarMetrics.rowSelectedShadowY)
        layer.shadowRadius = SidebarMetrics.rowSelectedShadowBlur / 2
        layer.shadowOpacity = Float(alpha)
        // An off shadow hides the layer rather than leaving one more thing to draw.
        layer.isHidden = alpha == 0
    }
}

/// U20 board: a split is one row with a segment per pane. The segment draws its pane's glyph,
/// its title and its own background, so a split row draws no row-level glyph, fill or title
/// (`updateSegments`). The board's `.split`: 36 pt tall with a 2 pt gap, the row's 11 pt radius on
/// the first and last segment's outer end and 4 pt inside, the glyph 16 pt at 10 pt from the
/// segment's left and the title 13 pt at 32 pt, truncated at the tail.
@MainActor
final class SplitSegmentButton: NSButton {
    weak var rowView: SidebarRowView?
    let pane: Row
    // The board's outer end carries the row radius and the inner one 4 pt; a lone segment is the
    // whole row.
    let leadingRadius: CGFloat
    let trailingRadius: CGFloat
    let fill = CAShapeLayer()
    let fillShadow = SelectedRowShadow(name: "split-segment-shadow")
    let iconView = NSImageView()
    let titleField = NSTextField(labelWithString: "")
    private(set) var active: Bool

    var paneTitle: String { titleField.stringValue }

    init(pane: Row, title: String, index: Int, count: Int, active: Bool) {
        self.pane = pane
        self.active = active
        let outer = SidebarMetrics.cornerRadius
        let inner = SidebarMetrics.splitSegmentRadius
        let radii: (leading: CGFloat, trailing: CGFloat) = count <= 1 ? (outer, outer)
            : index == 0 ? (outer, inner)
            : index == count - 1 ? (inner, outer)
            : (inner, inner)
        leadingRadius = radii.leading
        trailingRadius = radii.trailing
        super.init(frame: .zero)
        // The title is our own label so its 32 pt indent and tail truncation hold; the button's
        // own title stays empty and draws nothing.
        self.title = ""
        isBordered = false
        wantsLayer = true
        fill.name = "split-segment-fill"
        layer?.insertSublayer(fillShadow.layer, at: 0)
        layer?.insertSublayer(fill, at: 1)
        iconView.imageScaling = .scaleNone
        iconView.contentTintColor = .secondaryLabelColor
        iconView.setAccessibilityHidden(true)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: SidebarMetrics.splitSegmentTitleSize)
        titleField.maximumNumberOfLines = 1
        titleField.lineBreakMode = .byTruncatingTail
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.setAccessibilityElement(false)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        addSubview(titleField)
        let titleLeading = titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.splitSegmentTitleLeading)
        // A segment narrower than the indent drops the indent rather than break the layout.
        titleLeading.priority = .defaultHigh
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarMetrics.rowIconInset),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLeading,
            titleField.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SidebarMetrics.splitSegmentTitleTrailing),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyFill()
        setAccessibilityValue(active ? "Selected" : "")
        setAccessibilitySelected(active)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: SidebarMetrics.splitSegmentTitleLeading + 8, height: SidebarMetrics.rowFillHeight)
    }

    // The focused pane's segment takes the row's selected fill; every other segment keeps the
    // row's hover fill (the board's `.split span.on` and `.split span`), and the focused one the
    // board's selected-row shadow as well.
    func applyFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            fill.fillColor = active ? SidebarMetrics.rowSelectedFill(for: effectiveAppearance).cgColor
                : NSColor.labelColor.withAlphaComponent(SidebarMetrics.rowHoverFillAlpha(for: effectiveAppearance)).cgColor
        }
        applyShadow()
    }

    func applySelectedForeground(_ color: NSColor) {
        guard active else { return }
        titleField.textColor = color
        iconView.contentTintColor = color
    }

    // The shadow follows the segment's rounded path, on a layer behind the fill.
    private func applyShadow() {
        fillShadow.apply(rect: fill.frame, path: fill.path, flipped: isFlipped, on: active,
                         appearance: effectiveAppearance, scale: layer?.contentsScale ?? 1)
    }

    override func layout() {
        super.layout()
        fill.frame = bounds
        fill.path = Self.path(in: bounds, leading: leadingRadius, trailing: trailingRadius)
        applyShadow()
    }

    // One rounded rectangle with a radius per end; AppKit has no per-corner radius, and the
    // board's corners are plain arcs.
    static func path(in rect: CGRect, leading: CGFloat, trailing: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2
        let left = min(leading, limit)
        let right = min(trailing, limit)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + left, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - right, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: right)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: right)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: left)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: left)
        path.closeSubpath()
        return path
    }

    // The glyph and the title are decoration: a click anywhere on the segment belongs to the row.
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func mouseDown(with event: NSEvent) { rowView?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { rowView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { rowView?.mouseUp(with: event) }
    override func otherMouseUp(with event: NSEvent) { rowView?.otherMouseUp(with: event) }
    override func menu(for event: NSEvent) -> NSMenu? { rowView?.menu(for: event) }
}

@MainActor
final class SidebarRowView: NSView {
    private(set) var row: Row
    var acceptsKeyboardFocus = true { didSet { refreshHover() } }
    // The pane a split row's right-click landed on, so the segment menu acts on that pane; nil
    // for every other row and for a click outside the segments.
    var menuProvider: ((Row?) -> NSMenu?)?
    var onRename: ((Row) -> Void)?
    var onRenameCommit: ((Row, String, @escaping (Bool) -> Void) -> Void)?
    var onRenameEnd: (() -> Void)?
    private(set) var renameField: SidebarRenameField?
    private let renameHint = NSTextField(labelWithString: "Double-click to rename")
    var hintClock: () -> CFTimeInterval = CACurrentMediaTime
    var hintReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var hintStartedAt: CFTimeInterval?
    private(set) var hintTimer: Timer?
    private let action: (Row) -> Void
    var onClose: ((String) -> Void)?
    var onMute: ((String, Bool) -> Void)?
    var status: EngineAdapter.RowState? { didSet { updateStatus() } }
    private let spinner = NSProgressIndicator()
    private let audioButton = NSButton()
    private var audioTitleTrailing: NSLayoutConstraint!
    var loadingVisible: Bool { icon.isHidden }
    var audioLabel: String? { audioButton.isHidden ? nil : audioButton.accessibilityLabel() }
    func pressAudioForCheck() { audioButton.performClick(nil) }
    let closeButton = NSButton()
    // A dying renderer (R5) draws a warning glyph at 45 %, like an unloaded row.
    var crashed = false { didSet { updateStatus() } }
    // The unread dot (R7) is app state from the live strip, never stored in the row.
    var unread = false { didSet { updateStatus() } }
    var unreadDotVisible: Bool { !unreadDot.isHidden }
    var accent = SpaceAccent.teal { didSet { refreshUnreadAccent() } }
    var closeShortcutAction: Selector? { selected ? #selector(SidebarView.closeSelectedTab(_:)) : nil }
    // D11: the row’s ⌘W caps are explicit (the app menu’s item is not the lookup’s action), and
    // they follow the close_tab binding; R2 shows them on the current tab only.
    var closeCaps: [String] = ["⌘", "W"]
    var closeShortcutCaps: [String]? { selected ? closeCaps : nil }
    var pinned = false { didSet { updateCloseButton() } }
    // U26f: a private window's Today rows close (removal) and never archive; the hover words
    // say "Close Tab" while the glyph stays ✕.
    var privateWindow = false { didSet { updateCloseButton() } }
    // The words the hover button and its accessibility label carry, without asking AX.
    private(set) var closeLabel = "Archive Tab"
    var onDragPress: ((Row, NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragRelease: ((NSPoint) -> Bool)?
    var dragSource = false { didSet { updateFill() } }
    var dropHovered = false { didSet { updateFill() } }
    var dragCopy = false { didSet { updateCloseButton() } }
    var shortcutPressed = false {
        didSet {
            guard shortcutPressed != oldValue else { return }
            updateCloseButton()
            closeButton.wantsLayer = true
            closeButton.layer?.cornerRadius = 4
            closeButton.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(shortcutPressed ? 0.18 : 0).cgColor
        }
    }
    private var trackingPress = false
    private(set) var pressed = false { didSet { updateFill() } }
    private let titleMask = CAGradientLayer()
    private var selected: Bool
    private let fill = NSView()
    let fillShadow = SelectedRowShadow(name: "row-selected-shadow")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let segments = NSStackView()
    private var segmentRows: [Row] = []
    private let unreadDot = NSView()
    private var fillLeading: NSLayoutConstraint!
    private var hintCloseTrailing: NSLayoutConstraint!
    private var titleCenterY: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private(set) var hovered = false { didSet { updateFill(); updateCloseButton() } }
    var pointerLocation: (() -> NSPoint?)?

    init(row: Row, selected: Bool, action: @escaping (Row) -> Void) {
        self.row = row
        self.action = action
        self.selected = selected
        super.init(frame: .zero)
        postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshHover), name: NSView.frameDidChangeNotification, object: self)
        wantsLayer = true
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 11
        fill.layer?.cornerCurve = .continuous

        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 14)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byTruncatingTail
        for view in [fill, icon, title] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Keep the shadow outside the fill so the two layers can update independently.
        layer?.insertSublayer(fillShadow.layer, at: 0)
        segments.orientation = .horizontal
        segments.isHidden = true
        segments.distribution = .fillEqually
        segments.spacing = SidebarMetrics.splitSegmentGap
        segments.translatesAutoresizingMaskIntoConstraints = false
        addSubview(segments)
        NSLayoutConstraint.activate([
            // The board starts the segments at the row's own left inset and ends them at its
            // right inset, so they line up with the row fill (and its indent).
            segments.leadingAnchor.constraint(equalTo: fill.leadingAnchor),
            segments.trailingAnchor.constraint(equalTo: fill.trailingAnchor),
            segments.centerYAnchor.constraint(equalTo: centerYAnchor),
            segments.heightAnchor.constraint(equalToConstant: SidebarMetrics.rowFillHeight),
        ])
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = SidebarMetrics.unreadDotSize / 2
        unreadDot.layer?.backgroundColor = accent.cgColor
        unreadDot.isHidden = true
        unreadDot.setAccessibilityHidden(true)
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(unreadDot)
        fillLeading = fill.leadingAnchor.constraint(equalTo: leadingAnchor)
        iconLeading = icon.leadingAnchor.constraint(equalTo: leadingAnchor)
        titleCenterY = title.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 41),
            fillLeading,
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.centerYAnchor.constraint(equalTo: centerYAnchor),
            fill.heightAnchor.constraint(equalToConstant: SidebarMetrics.rowFillHeight),
            iconLeading,
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            titleCenterY,
        ])
        spinner.setAccessibilityHidden(true)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        audioButton.isBordered = false
        audioButton.imagePosition = .imageOnly
        audioButton.target = self
        audioButton.action = #selector(mutePressed)
        audioButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(audioButton)
        audioTitleTrailing = title.trailingAnchor.constraint(lessThanOrEqualTo: audioButton.leadingAnchor, constant: -4)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16), spinner.heightAnchor.constraint(equalToConstant: 16),
            audioButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -32), audioButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            audioButton.widthAnchor.constraint(equalToConstant: 24), audioButton.heightAnchor.constraint(equalToConstant: 24),
        ])
        renameHint.font = .systemFont(ofSize: 10)
        renameHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        renameHint.lineBreakMode = .byTruncatingTail
        renameHint.textColor = .secondaryLabelColor
        renameHint.isHidden = true
        renameHint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(renameHint)
        NSLayoutConstraint.activate([
            renameHint.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            renameHint.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            renameHint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
        ])
        title.wantsLayer = true
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.target = self
        closeButton.action = #selector(closePressed)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            unreadDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarMetrics.unreadDotTrailing),
            unreadDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: SidebarMetrics.unreadDotSize),
            unreadDot.heightAnchor.constraint(equalToConstant: SidebarMetrics.unreadDotSize),
        ])
        hintCloseTrailing = renameHint.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -renameHint.alignmentRectInsets.right - closeButton.alignmentRectInsets.left)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update(row: row, selected: selected)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(row: Row, selected: Bool) {
        self.row = row
        self.selected = selected
        title.stringValue = row.kind == .split && row.title.isEmpty ? "Split" : row.title
        toolTip = row.url ?? row.title
        icon.image = row.kind == .folder ? Self.folderSymbol(collapsed: row.collapsed)
            : crashed ? Self.tabIcon(crashed: true) : Self.symbol(for: row.kind)
        if !pinned || !selected || row.kind != .tab {
            hideRenameHint(!pinned ? "not-pinned" : !selected ? "not-selected" : "not-tab")
        }
        fillLeading.constant = CGFloat(row.depth) * 16
        iconLeading.constant = SidebarMetrics.rowIconInset + CGFloat(row.depth) * 16
        setAccessibilityLabel(title.stringValue)
        updateStatus()
        updateFill()
        updateCloseButton()
        noteFocusRingMaskChanged()
    }

    func updateSegments(_ members: [Row], active: String?, crashed: Set<String> = []) {
        segmentRows = members
        segments.arrangedSubviews.forEach { $0.removeFromSuperview() }
        // A split draws its panes' segments and nothing of its own: no row-level glyph, fill or
        // title (the U20 board's split row).
        let drawing = !members.isEmpty
        segments.isHidden = !drawing
        title.isHidden = drawing
        fill.isHidden = drawing
        for (index, member) in members.enumerated() {
            let name = Self.paneName(member)
            let button = SplitSegmentButton(pane: member, title: name, index: index, count: members.count, active: member.id == active)
            button.rowView = self
            button.tag = index
            button.target = self
            button.action = #selector(segmentClicked(_:))
            let paneCrashed = crashed.contains(member.id)
            button.iconView.image = Self.tabIcon(crashed: paneCrashed)
            button.alphaValue = member.unloaded || paneCrashed ? SidebarMetrics.unloadedOpacity : 1
            button.setAccessibilityLabel("Pane \(index + 1) of \(members.count): \(name)")
            segments.addArrangedSubview(button)
        }
        updateStatus()
        updateFill()
        setAccessibilityLabel(drawing ? "Split: " + members.map(Self.paneName).joined(separator: ", ") : title.stringValue)
    }

    // A pane with no title reads as its host, as the row's own name does.
    static func paneName(_ row: Row) -> String {
        row.title.isEmpty ? (row.url.flatMap { URL(string: $0)?.host } ?? "Untitled") : row.title
    }

    // The glyph a tab row draws, so a split's segment draws the same one: the globe, or the
    // warning when that pane's renderer died.
    static func tabIcon(crashed: Bool) -> NSImage {
        crashed ? symbol(for: .tab, name: "exclamationmark.triangle.fill", description: "Crashed") : symbol(for: .tab)
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard segmentRows.indices.contains(sender.tag) else { return }
        action(segmentRows[sender.tag])
    }

    // R5: crashed and unloaded rows draw at 45 %; R7: the dot marks a title change the window
    // has not shown. Both are view state, so the core's row never carries them.
    private func updateStatus() {
        let loading = status?.loading == true && row.kind == .tab && !crashed
        // A split's segments carry its panes' glyphs, so the row keeps its own one hidden.
        icon.isHidden = loading || !segmentRows.isEmpty
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let muted = status?.muted == true
        audioButton.isHidden = row.kind != .tab || !(muted || status?.audible == true)
        audioTitleTrailing.isActive = !audioButton.isHidden
        audioButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        audioButton.setAccessibilityLabel(muted ? "Unmute Tab" : "Mute Tab")
        audioButton.toolTip = muted ? "Unmute Tab" : "Mute Tab"
        let opacity = crashed || row.unloaded ? SidebarMetrics.unloadedOpacity : 1
        title.alphaValue = opacity
        icon.alphaValue = opacity
        if row.kind == .folder {
            icon.image = Self.folderSymbol(collapsed: row.collapsed)
        } else if crashed {
            icon.image = Self.tabIcon(crashed: true)
        } else {
            icon.image = Self.symbol(for: row.kind)
        }
        // The states a sighted reader sees, said in words (6b).
        let states = [crashed ? "Crashed" : nil, row.unloaded ? "Unloaded" : nil, unread ? "Unread" : nil, loading ? "Loading" : nil, !audioButton.isHidden && muted ? "Muted" : nil, !audioButton.isHidden && status?.audible == true && !muted ? "Playing audio" : nil].compactMap { $0 }
        setAccessibilityValue(states.isEmpty ? nil : states.joined(separator: ", "))
        updateCloseButton()
        unreadDot.isHidden = !unread || !closeButton.isHidden
    }

    func showRenameHint() {
        guard pinned, selected, row.kind == .tab, renameField == nil else { return }
        hideRenameHint("restart")
        hintStartedAt = hintClock()
        renameHint.isHidden = false
        renameHint.alphaValue = 1
        title.font = .systemFont(ofSize: 13)
        titleCenterY.constant = -6
        title.maximumNumberOfLines = 1
        scheduleHintTimer(after: 3)
        if PinHintTrace.enabled {
            FileHandle.standardError.write(Data("ararat-trace: pin-hint show id=\(row.id)\n".utf8))
        }
    }

    private func scheduleHintTimer(after interval: TimeInterval, repeats: Bool = false) {
        hintTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: repeats) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            MainActor.assumeIsolated { self.refreshRenameHint() }
        }
        hintTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func refreshRenameHint() {
        guard let start = hintStartedAt else { return }
        let elapsed = hintClock() - start
        if elapsed >= 3.2 || (elapsed >= 3 && hintReduceMotion()) { hideRenameHint("expiry") }
        else {
            renameHint.alphaValue = min(1, max(0, (3.2 - elapsed) / 0.2))
            if elapsed >= 3 && hintTimer?.timeInterval == 0 { scheduleHintTimer(after: 1.0 / 60, repeats: true) }
        }
    }

    func hideRenameHint(_ reason: String) {
        // Only an armed hint can be taken down; an unarmed row is every other row on every
        // reload, and saying so would bury the one line that matters.
        if PinHintTrace.enabled, hintTimer != nil {
            FileHandle.standardError.write(Data("ararat-trace: pin-hint hide id=\(row.id) reason=\(reason)\n".utf8))
        }
        hintTimer?.invalidate()
        hintTimer = nil
        hintStartedAt = nil
        renameHint.isHidden = true
        title.font = .systemFont(ofSize: 14)
        titleCenterY.constant = 0
        title.maximumNumberOfLines = 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
        refreshHover()
    }

    @objc func refreshHover() {
        let point: NSPoint?
        if let pointerLocation { point = pointerLocation() }
        else { point = window?.isKeyWindow == true ? window?.mouseLocationOutsideOfEventStream : nil }
        let inside = point.map { bounds.intersection(visibleRect).contains(convert($0, from: nil)) } ?? false
        let updated = acceptsKeyboardFocus && !isHiddenOrHasHiddenAncestor && inside
        if hovered != updated { hovered = updated }
        let nextPressed = trackingPress && updated
        if pressed != nextPressed { pressed = nextPressed }
    }

    func capturePointerState(pressed: Bool, capture: () -> Bool) -> Bool {
        let previousPointer = pointerLocation
        let previousPress = trackingPress
        let rect = bounds.intersection(visibleRect)
        guard !rect.isEmpty else { return false }
        let point = convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        pointerLocation = { point }
        trackingPress = pressed
        refreshHover()
        window?.displayIfNeeded()
        defer {
            pointerLocation = previousPointer
            trackingPress = previousPress
            refreshHover()
        }
        return hovered && self.pressed == pressed && capture()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshHover()
    }

    override func mouseEntered(with event: NSEvent) { refreshHover() }
    override func mouseExited(with event: NSEvent) { refreshHover() }
    override func mouseDown(with event: NSEvent) {
        guard acceptsKeyboardFocus else { return }
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
        if event.clickCount == 2 && pinned && row.kind == .tab { onRename?(row); return }
        trackingPress = true
        pressed = true
        let point = segments.convert(event.locationInWindow, from: nil)
        let index = segments.isHidden ? nil : segments.arrangedSubviews.firstIndex { $0.frame.contains(point) }
        onDragPress?(index.flatMap { segmentRows.indices.contains($0) ? segmentRows[$0] : nil } ?? row, event.locationInWindow)
    }
    override func mouseDragged(with event: NSEvent) {
        onDragMove?(event.locationInWindow)
        pressed = trackingPress && bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) {
        let activate = acceptsKeyboardFocus && trackingPress && bounds.intersection(visibleRect).contains(convert(event.locationInWindow, from: nil))
        trackingPress = false
        pressed = false
        let handled = onDragRelease?(event.locationInWindow) ?? false
        if activate && !handled {
            let point = segments.convert(event.locationInWindow, from: nil)
            if !segments.isHidden, let index = segments.arrangedSubviews.firstIndex(where: { $0.frame.contains(point) }), segmentRows.indices.contains(index) {
                action(segmentRows[index])
            } else { action(row) }
        }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 && acceptsKeyboardFocus && (row.kind == .tab || (row.kind == .split && !pinned)) { onClose?(row.id) }
    }

    @objc private func mutePressed() { if acceptsKeyboardFocus { onMute?(row.id, !(status?.muted ?? false)) } }

    @objc private func closePressed() { if acceptsKeyboardFocus { onClose?(row.id) } }

    private func updateCloseButton() {
        // R1/D2: the glyph and the words follow the load state, not the selection. A loaded
        // pin's − unloads it and keeps the row; everywhere else ✕ archives (a pin loses its
        // pin, a Today tab and an unloaded pin go to the Archive).
        let close = pinned && !row.unloaded
        closeButton.image = NSImage(systemSymbolName: close ? "minus" : "xmark", accessibilityDescription: nil)
        let label = (close || privateWindow) ? "Close Tab" : "Archive Tab"
        closeLabel = label
        let actions: [NSAccessibilityCustomAction] = row.kind == .tab && acceptsKeyboardFocus ? [
            NSAccessibilityCustomAction(name: label) { [weak self] in
                guard let self, self.acceptsKeyboardFocus else { return false }
                self.onClose?(self.row.id)
                return true
            },
        ] : []
        var rowActions = actions
        if !audioButton.isHidden && acceptsKeyboardFocus {
            rowActions.append(NSAccessibilityCustomAction(name: status?.muted == true ? "Unmute Tab" : "Mute Tab") { [weak self] in
                guard let self, self.acceptsKeyboardFocus, !self.audioButton.isHidden else { return false }
                self.mutePressed()
                return true
            })
        }
        if row.kind == .folder && acceptsKeyboardFocus {
            rowActions.append(NSAccessibilityCustomAction(name: row.collapsed ? "Expand" : "Collapse") { [weak self] in
                guard let self, self.acceptsKeyboardFocus else { return false }; self.action(self.row); return true
            })
        }
        setAccessibilityCustomActions(rowActions)
        if closeButton.accessibilityLabel() != label { closeButton.toolTip = label }
        closeButton.setAccessibilityLabel(label)
        closeButton.isHidden = row.kind != .tab || (!dragCopy && (!acceptsKeyboardFocus || (!hovered && !shortcutPressed)))
        hintCloseTrailing.isActive = !closeButton.isHidden
        unreadDot.isHidden = !unread || !closeButton.isHidden
        refreshUnreadAccent()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        refreshSelectedForeground()
        refreshUnreadAccent()
        renameField?.frame = NSRect(x: title.frame.minX, y: bounds.midY - 11, width: max(1, bounds.width - title.frame.minX - 8), height: 22)
        // The fill's shadow follows its rounded fill, not the alpha of its drawing.
        applySelectedShadow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !closeButton.isHidden && closeButton.frame.minX < title.frame.maxX {
            titleMask.frame = title.bounds
            titleMask.startPoint = CGPoint(x: 0, y: 0.5)
            titleMask.endPoint = CGPoint(x: 1, y: 0.5)
            let end = max(0, min(1, (closeButton.frame.minX - title.frame.minX) / max(1, title.bounds.width)))
            titleMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            titleMask.locations = [0, NSNumber(value: Double(max(0, end - 12 / max(1, title.bounds.width)))), NSNumber(value: Double(end)), 1]
            title.layer?.mask = titleMask
        } else { title.layer?.mask = nil }
        CATransaction.commit()
    }
    override func accessibilityPerformPress() -> Bool {
        guard acceptsKeyboardFocus else { return false }
        action(row)
        return true
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        acceptsKeyboardFocus ? super.hitTest(point) : nil
    }

    override var acceptsFirstResponder: Bool { acceptsKeyboardFocus }
    override var canBecomeKeyView: Bool { acceptsKeyboardFocus }
    override func becomeFirstResponder() -> Bool {
        guard acceptsKeyboardFocus else { return false }
        noteFocusRingMaskChanged()
        return true
    }
    override func resignFirstResponder() -> Bool { noteFocusRingMaskChanged(); return true }
    override var focusRingMaskBounds: NSRect { fill.frame }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: fill.frame, xRadius: 11, yRadius: 11).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case " ", "\r", "\u{3}": action(row)
        default: super.keyDown(with: event)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        let drawsSelection = dragSource || dragCopy || selected
        if !drawsSelection {
            title.textColor = .labelColor
            icon.contentTintColor = .secondaryLabelColor
            audioButton.contentTintColor = nil
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if drawsSelection {
                fill.layer?.backgroundColor = SidebarMetrics.rowSelectedFill(for: effectiveAppearance).cgColor
            } else {
                let alpha: CGFloat
                if pressed {
                    alpha = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? SidebarMetrics.rowPressedFillAlphaDark : SidebarMetrics.rowPressedFillAlphaLight
                } else {
                    alpha = hovered || dropHovered ? SidebarMetrics.rowHoverFillAlpha(for: effectiveAppearance) : 0
                }
                fill.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
            }
        }
        // The board applies `--selsh` only to the selected fill. A drag copy is built selected.
        applySelectedShadow()
        for case let segment as SplitSegmentButton in segments.arrangedSubviews { segment.applyFill() }
        refreshSelectedForeground()
        refreshUnreadAccent()
    }

    func refreshUnreadAccent() {
        guard !unreadDot.isHidden else { return }
        let backdrop = SidebarPanelView.backdrop(behind: unreadDot, overlaidBy: fill.layer?.backgroundColor)
        unreadDot.layer?.backgroundColor = (backdrop.map { SpaceAccent.visible(accent, on: $0) } ?? accent).cgColor
    }

    func refreshSelectedForeground() {
        let drawsSelection = dragSource || dragCopy || selected
        guard drawsSelection || !segmentRows.isEmpty else { return }
        let selectedFill = SidebarMetrics.rowSelectedFill(for: effectiveAppearance)
        let backdrop = SidebarPanelView.backdrop(behind: self) ?? SidebarPanelView.defaultDarkBackground
        let composite = SidebarPanelView.mix(selectedFill, selectedFill, fraction: 0, base: backdrop)
        let foreground = SpaceAccent.foreground(on: composite)
        if drawsSelection {
            title.textColor = foreground
            icon.contentTintColor = foreground
            audioButton.contentTintColor = foreground
        }
        for case let segment as SplitSegmentButton in segments.arrangedSubviews {
            segment.applySelectedForeground(foreground)
        }
    }

    // The board's selected-row shadow: `0 1px 2px rgba(0,0,0,.08)` in light, none in dark, on the
    // selected row's fill and on a split row's focused segment.
    private func applySelectedShadow() {
        let path = CGPath(roundedRect: fill.bounds, cornerWidth: SidebarMetrics.cornerRadius, cornerHeight: SidebarMetrics.cornerRadius, transform: nil)
        // A split row draws its own fill hidden and its segments instead, so the row-level shadow
        // goes with it. The shadow layer is a sublayer of the row's, so its y direction is the
        // row's.
        fillShadow.apply(rect: fill.frame, path: path, flipped: isFlipped, on: selected && !fill.isHidden,
                         appearance: effectiveAppearance, scale: layer?.contentsScale ?? 1)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        acceptsKeyboardFocus ? menuProvider?(paneUnder(event)) : nil
    }

    // U25d: which segment the event is over. A split draws one segment per pane, and its menu
    // acts on the pane that was right-clicked (the first pane otherwise).
    func paneUnder(_ event: NSEvent) -> Row? {
        guard !segments.isHidden, segments.arrangedSubviews.count == segmentRows.count else { return nil }
        let point = segments.convert(event.locationInWindow, from: nil)
        guard let index = segments.arrangedSubviews.firstIndex(where: { $0.frame.contains(point) }),
              segmentRows.indices.contains(index) else { return nil }
        return segmentRows[index]
    }

    func beginRename() {
        guard renameField == nil else { return }
        hideRenameHint("rename-started")
        let field = SidebarRenameField(title: row.title, save: { [weak self] title, done in
            guard let self, let save = self.onRenameCommit else { done(false); return }
            save(self.row, title, done)
        }, ended: { [weak self] in
            guard let self else { return }
            self.renameField = nil
            self.title.isHidden = false
            self.onRenameEnd?()
        })
        renameField = field
        addSubview(field)
        title.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func finishRename(commit: Bool) { renameField?.finish(commit: commit) }

    static func folderSymbol(collapsed: Bool) -> NSImage {
        if collapsed { return symbol(for: .folder) }
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor.labelColor.setFill()
            let back = NSBezierPath()
            back.move(to: NSPoint(x: 1, y: 3))
            back.line(to: NSPoint(x: 1, y: 13))
            back.line(to: NSPoint(x: 6, y: 13))
            back.line(to: NSPoint(x: 8, y: 11))
            back.line(to: NSPoint(x: 14, y: 11))
            back.line(to: NSPoint(x: 14, y: 9))
            back.line(to: NSPoint(x: 4, y: 9))
            back.close(); back.fill()
            let front = NSBezierPath()
            front.move(to: NSPoint(x: 1, y: 3))
            front.line(to: NSPoint(x: 4, y: 8))
            front.line(to: NSPoint(x: 16, y: 8))
            front.line(to: NSPoint(x: 13, y: 3))
            front.close(); front.fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    static func symbol(for kind: RowKind) -> NSImage {
        let name = switch kind {
        case .tab: "globe"
        case .folder: "folder.fill"
        case .split: "rectangle.split.2x1"
        // The open, empty folder's line is drawn by SidebarNoTabsRow, not this symbol.
        case .noTabs: "minus"
        }
        return symbol(for: kind, name: name)
    }

    static func symbol(for kind: RowKind, name: String, description: String? = nil) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) ?? NSImage()
    }
}

// F3: the row an open, empty folder shows at its child indent — a 24 pt "No tabs" line, not
// an item. It is a drop target for the empty folder (SidebarDrag resolves it there) and never
// selectable or draggable.
@MainActor
private final class SidebarHintLabel: NSTextField {
    // The label's alignment rect is its frame: a text field's default insets would pull the
    // "No tabs" text 2 pt left of the child indent the mock names.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
}

@MainActor
final class SidebarNoTabsRow: NSView {
    let row: Row
    // A-Folders: the open empty folder's "No tabs" text line at the child indent, in the
    // sidebar's secondary text. It is not a hit target; VoiceOver reads the row's label.
    private let label = SidebarHintLabel(labelWithString: "No tabs")
    private var labelLeading: NSLayoutConstraint!

    init(row: Row) {
        self.row = row
        super.init(frame: .zero)
        wantsLayer = true
        label.font = .systemFont(ofSize: SidebarMetrics.secondaryFontSize)
        label.textColor = .secondaryLabelColor
        label.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        labelLeading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10 + CGFloat(row.depth) * 16)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: SidebarMetrics.noTabsRowHeight),
            labelLeading,
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("No tabs")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            label.textColor = .secondaryLabelColor
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var textFrameInRow: NSRect { layoutSubtreeIfNeeded(); return label.frame }
    var textFontSize: CGFloat { label.font?.pointSize ?? 0 }
    var textLineHeight: CGFloat { label.font.map { NSLayoutManager().defaultLineHeight(for: $0) } ?? 0 }
    // The natural height of this string in this cell: the frame is compared with it (a field's
    // intrinsic height includes padding, and font metrics differ by a rounding point).
    var textCellHeight: CGFloat { label.cell?.cellSize.height ?? 0 }
    var parentIDForCheck: String { row.parentId }
}

@MainActor
final class FavoriteTile: NSButton {
    private(set) var row: Row
    var onDragPress: ((Row, NSPoint) -> Void)?
    var onDragMove: ((NSPoint) -> Void)?
    var onDragRelease: ((NSPoint) -> Bool)?
    var menuProvider: (() -> NSMenu?)?
    var onRenameEnd: (() -> Void)?
    private(set) var renameField: SidebarRenameField?
    private let onPress: (Row) -> Void
    private let icon = NSImageView()
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    init(row: Row, onPress: @escaping (Row) -> Void) {
        self.row = row
        self.onPress = onPress
        super.init(frame: .zero)
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .labelColor
        icon.setAccessibilityHidden(true)
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateFill()
        heightAnchor.constraint(equalToConstant: 47).isActive = true
        target = self
        action = #selector(pressed)
        update(row: row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(row: Row) {
        self.row = row
        icon.image = SidebarRowView.symbol(for: row.kind)
        icon.alphaValue = row.unloaded ? SidebarMetrics.unloadedOpacity : 1
        toolTip = row.title
        setAccessibilityLabel(row.title)
    }

    @objc private func pressed() { onPress(row) }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { super.mouseDown(with: event); return }
        guard let onDragPress else { super.mouseDown(with: event); return }
        onDragPress(row, event.locationInWindow)
    }
    override func mouseDragged(with event: NSEvent) { onDragMove?(event.locationInWindow) }
    override func mouseUp(with event: NSEvent) {
        if onDragRelease?(event.locationInWindow) != true && bounds.contains(convert(event.locationInWindow, from: nil)) { onPress(row) }
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }

    func beginRename(save: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        guard renameField == nil else { return }
        let field = SidebarRenameField(title: row.title, save: save, ended: { [weak self] in
            self?.renameField = nil; self?.onRenameEnd?()
        })
        renameField = field
        addSubview(field)
        field.frame = bounds.insetBy(dx: 2, dy: 10)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let renameField, renameField.frame.contains(convert(point, from: superview)) { return renameField }
        return super.hitTest(point) == nil ? nil : self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }

    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        }
    }
}
