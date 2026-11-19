import AppKit
import AraratKit
import UniformTypeIdentifiers

@MainActor
final class DownloadsButton: SidebarDockButton {
    var onHover: (() -> Void)?
    private var hoverTask: DispatchWorkItem?
    var scheduleHover: (DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: $0) }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var libraryOpen = false { didSet { if progress == .none { updateRing() } } }
    var progress: DownloadsModel.Progress = .none { didSet { if progress != oldValue { updateRing() } } }
    let ring = CAShapeLayer()
    let libraryFill = CALayer()
    var accent = SpaceAccent.teal { didSet { refreshAccent() } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 2
        libraryFill.cornerRadius = 6
        layer?.addSublayer(libraryFill)
        layer?.addSublayer(ring)
        updateRing()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) {
        hoverTask?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.onHover?() }
        hoverTask = task
        scheduleHover(task)
    }
    override func mouseExited(with event: NSEvent) { hoverTask?.cancel(); hoverTask = nil }
    func checkHover(_ fired: @escaping () -> Void) {
        FileHandle.standardError.write(Data("ararat-trace: downloads hover seam: entered\n".utf8))
        scheduleHover(DispatchWorkItem { [weak self] in
            FileHandle.standardError.write(Data("ararat-trace: downloads hover seam: timer fired\n".utf8))
            self?.onHover?()
            fired()
        })
    }
    override func layout() { super.layout(); updateRing() }

    func refreshAccent() {
        let backdrop = SidebarPanelView.backdrop(behind: self, overlaidBy: libraryFill.backgroundColor)
        ring.strokeColor = (backdrop.map { SpaceAccent.visible(accent, on: $0) } ?? accent).cgColor
    }

    private func updateRing() {
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 4, dy: 4), transform: nil)
        refreshAccent()
        switch progress {
        case .none:
            ring.removeAnimation(forKey: "spin"); ring.isHidden = true; setAccessibilityValue(libraryOpen ? 1 : 0)
        case .paused(let fraction):
            ring.removeAnimation(forKey: "spin"); ring.isHidden = false; ring.strokeEnd = max(0.12, fraction)
            setAccessibilityValue("Paused, \(Int((fraction * 100).rounded())) %")
        case .fraction(let fraction):
            ring.removeAnimation(forKey: "spin"); ring.isHidden = false; ring.strokeEnd = max(0.12, fraction)
            setAccessibilityValue("Downloading, \(Int((fraction * 100).rounded())) %")
        case .indeterminate:
            ring.isHidden = false; ring.strokeEnd = 0.25
            setAccessibilityValue("Downloading")
            if !reduceMotion() && ring.animation(forKey: "spin") == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = 0; spin.toValue = 2 * Double.pi; spin.duration = 1; spin.repeatCount = .infinity
                spin.beginTime = CACurrentMediaTime()
                ring.add(spin, forKey: "spin")
            }
        }
    }
}

enum DownloadRowMetrics {
    static let inset: CGFloat = 8
    static let iconSize: CGFloat = 16
    static let gap: CGFloat = 4
    static let actionSize: CGFloat = 28
    static let actionSymbolSize: CGFloat = 13
    static let progressHeight: CGFloat = 3
    static let textLeading: CGFloat = inset + iconSize + gap
}

/// The popover opens on this view, not on a control: Arc shows no focus ring when the popover
/// appears. Being first responder, Tab still walks into the header's buttons.
@MainActor
final class DownloadsPopoverContentView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        window.makeFirstResponder(self)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor
final class DownloadsPopover: NSObject, NSPopoverDelegate {
    static let rowHeight: CGFloat = 48
    static let headerHeight: CGFloat = 40
    private let popover = NSPopover()
    private let model: DownloadsModel
    private let anchor: NSView
    private let stack = NSStackView()
    let title = NSTextField(labelWithString: "Downloads")
    let library = NSButton(title: "Open in Library", target: nil, action: nil)
    let clear = NSButton(title: "Clear All", target: nil, action: nil)
    var showsLibrary = true { didSet { library.isHidden = !showsLibrary; clear.isHidden = showsLibrary } }
    private(set) var rows: [String: DownloadRowView] = [:]
    /// True between the popover's did-show and did-close, which covers a transient dismissal.
    private(set) var isOpen = false
    /// The sidebar owns the anchor's tooltip: it dismisses or hides its own bubble while open.
    var onShow: (() -> Void)?
    var openLibrary: (() -> Void)?
    init(model: DownloadsModel, anchor: NSView) {
        self.model = model; self.anchor = anchor
        super.init()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 0
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.setAccessibilityLabel(title.stringValue)
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for button in [library, clear] {
            button.target = self
            button.bezelStyle = .inline
            button.isBordered = false
            button.font = .systemFont(ofSize: 12)
            button.contentTintColor = .secondaryLabelColor
            button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        library.action = #selector(open)
        library.setAccessibilityLabel(library.title)
        clear.action = #selector(clearAll)
        clear.setAccessibilityLabel("Clear All Downloads")
        clear.isHidden = true
        let header = NSStackView(views: [title, library, clear])
        header.alignment = .centerY
        header.edgeInsets = NSEdgeInsets(top: 0, left: DownloadRowMetrics.inset, bottom: 0, right: DownloadRowMetrics.inset)
        stack.addArrangedSubview(header)
        header.heightAnchor.constraint(equalToConstant: Self.headerHeight).isActive = true
        let controller = NSViewController()
        let content = DownloadsPopoverContentView(frame: NSRect(x: 0, y: 0, width: SidebarMetrics.defaultWidth, height: Self.headerHeight))
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        controller.view = content
        popover.contentViewController = controller
    }
    var isShown: Bool { popover.isShown }
    var checkWindow: NSWindow? { popover.contentViewController?.view.window }
    var checkContentView: NSView? { popover.contentViewController?.view }
    var checkMetrics: [String: Any] {
        let content = popover.contentViewController?.view
        content?.layoutSubtreeIfNeeded()
        let button = showsLibrary ? library : clear
        return ["window_frame": NSStringFromRect(checkWindow?.frame ?? .zero),
                "content_frame": NSStringFromRect(content?.frame ?? .zero), "content_bounds": NSStringFromRect(content?.bounds ?? .zero),
                "window_content_frame": NSStringFromRect(checkWindow?.contentView?.frame ?? .zero),
                "window_content_bounds": NSStringFromRect(checkWindow?.contentView?.bounds ?? .zero),
                "backing_scale": checkWindow?.backingScaleFactor ?? 0,
                "content_width": content?.bounds.width ?? 0, "content_alpha": content?.alphaValue ?? 0,
                "layer_transform": String(describing: content?.layer?.presentation()?.transform),
                "rows": rows.mapValues { NSStringFromRect($0.frame) },
                "rows_leading_and_status_fit": !rows.isEmpty && rows.values.allSatisfy { row in
                    let frame = stack.convert(row.bounds, from: row)
                    return abs(frame.minX - stack.bounds.minX) <= 16 && frame.width >= stack.bounds.width - 1 && row.statusFits
                },
                "header_title": title.stringValue,
                "header_layout": title.bounds.width >= title.intrinsicContentSize.width &&
                    stack.convert(title.bounds, from: title).maxX <= stack.convert(button.bounds, from: button).minX,
                "title_font": rows.values.first?.titleFontSize ?? 0, "title_height": rows.values.first?.titleHeight ?? 0]
    }
    /// The popover covers the anchor, so the anchor's tooltip must not show while it is open.
    func popoverDidShow(_ notification: Notification) {
        guard !isOpen else { return }
        isOpen = true
        // The popover reuses its window across showings, so reset the first responder here too:
        // no control is focused when it opens.
        if let content = popover.contentViewController?.view, let window = content.window {
            window.initialFirstResponder = content
            if window.firstResponder !== content { window.makeFirstResponder(content) }
        }
        onShow?()
    }
    /// Every close path lands here, a transient dismissal included.
    func popoverDidClose(_ notification: Notification) {
        isOpen = false
    }
    func close() { popover.performClose(nil) }
    static func edge(flipped: Bool) -> NSRectEdge { flipped ? .minY : .maxY }
    func show(present: Bool = true) {
        guard model.hasSessionDownloads, let window = anchor.window else { return }
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let available = max(0, window.frame.maxY - anchorRect.maxY - 16)
        let count = max(0, min(model.items.count, Int(max(0, available - Self.headerHeight) / Self.rowHeight)))
        refresh(limit: count)
        let size = NSSize(width: SidebarMetrics.defaultWidth, height: Self.headerHeight + CGFloat(count) * Self.rowHeight)
        popover.contentViewController?.view.setFrameSize(size)
        popover.contentSize = size
        if !present { return }
        if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: Self.edge(flipped: anchor.isFlipped)) }
        if let panel = popover.contentViewController?.view.window {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: min(max(frame.minX, window.frame.minX), window.frame.maxX - frame.width), y: frame.minY))
        }
    }
    func refresh(limit: Int) {
        clear.isEnabled = !model.clearableItems.isEmpty
        let items = Array(model.items.prefix(limit))
        let ids = items.map(\.id)
        for id in Array(rows.keys) where !ids.contains(id) {
            guard let row = rows.removeValue(forKey: id) else { continue }
            stack.removeArrangedSubview(row); row.removeFromSuperview()
        }
        for (index, item) in items.enumerated() {
            if let row = rows[item.id] {
                row.update(item: item)
                if stack.arrangedSubviews.firstIndex(of: row) != index + 1 {
                    stack.removeArrangedSubview(row); stack.insertArrangedSubview(row, at: index + 1)
                }
            } else {
                let row = DownloadRowView(item: item, model: model)
                rows[item.id] = row
                stack.insertArrangedSubview(row, at: index + 1)
                row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
                row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            }
        }
    }
    @objc private func open() { close(); openLibrary?() }
    @objc private func clearAll() { model.clearAll() }
    func row(_ item: DownloadEntry) -> NSView {
        DownloadRowView(item: item, model: model)
    }
    /// p4checks: the popover row's own action button (Open, Cancel, Remove, …), pressed through it.
    func checkPress(action: String, id: String) -> Bool {
        guard let row = rows[id] else { return false }
        return row.checkPress(action: action)
    }
}

@MainActor
final class DownloadRowView: NSView, NSDraggingSource {
    static let libraryCompactWidth: CGFloat = 264
    static let libraryActionCenterY: CGFloat = 16
    private var dragStart: NSPoint?
    func draggingItem() -> NSDraggingItem? {
        guard let url = model.dragFileURL(id: itemID) else { return nil }
        return NSDraggingItem(pasteboardWriter: url as NSURL)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStart = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) >= 4, let item = draggingItem() else { return }
        dragStart = nil
        item.setDraggingFrame(icon.convert(icon.bounds, to: self), contents: icon.image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    private(set) var itemID: String
    private let model: DownloadsModel
    private let libraryPage: Bool
    private(set) var actionButtons: [DownloadActionButton] = []
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    let status = NSTextField(labelWithString: "")
    let progress = NSView()
    private let progressFill = CALayer()
    private var progressFraction = 0.0
    var titleFontSize: CGFloat { name.font?.pointSize ?? 0 }
    var titleHeight: CGFloat { name.bounds.height }
    var statusFits: Bool {
        let frame = convert(status.bounds, from: status)
        return frame.width > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame)
    }
    func statusFrame(in view: NSView) -> NSRect { view.convert(status.bounds, from: status) }
    var statusTruncates: Bool {
        status.maximumNumberOfLines == 1 && status.lineBreakMode == .byTruncatingMiddle && status.cell?.isScrollable == false
    }
    /// p4checks: presses the row's own button for an action and answers whether one was there.
    func checkPress(action: String) -> Bool {
        guard let button = actionButtons.first(where: { $0.downloadAction == action }), button.isEnabled else { return false }
        button.performClick(nil)
        return true
    }
    var moveRow: ((Int) -> Void)?
    var tabRow: ((Bool) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125, let moveRow { moveRow(1) }
        else if event.keyCode == 126, let moveRow { moveRow(-1) }
        else if event.keyCode == 48, let tabRow { tabRow(event.modifierFlags.contains(.shift)) }
        else { super.keyDown(with: event) }
    }

    init(item: DownloadEntry, model: DownloadsModel, libraryPage: Bool = false) {
        itemID = item.id
        self.model = model
        self.libraryPage = libraryPage
        super.init(frame: .zero)
        icon.setAccessibilityHidden(true)
        name.font = .systemFont(ofSize: 13); name.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 1
        status.cell?.isScrollable = false
        status.lineBreakMode = .byTruncatingMiddle
        for view in [icon, name, status] { addSubview(view) }
        if !libraryPage {
            heightAnchor.constraint(equalToConstant: DownloadsPopover.rowHeight).isActive = true
            progress.setAccessibilityHidden(true)
            progress.wantsLayer = true
            progress.layer?.cornerRadius = DownloadRowMetrics.progressHeight / 2
            progressFill.cornerRadius = DownloadRowMetrics.progressHeight / 2
            progress.layer?.addSublayer(progressFill)
            addSubview(progress)
        }
        update(item: item)
    }
    /// The name and status take the width left of the action buttons; the buttons hug the row's
    /// trailing edge, centred on the row.
    override func layout() {
        super.layout()
        let inset = DownloadRowMetrics.inset
        let gap = DownloadRowMetrics.gap
        let size = DownloadRowMetrics.actionSize
        let compact = libraryPage && bounds.width < Self.libraryCompactWidth && !actionButtons.isEmpty
        let actionCenterY = compact ? Self.libraryActionCenterY : bounds.midY
        icon.frame = NSRect(x: inset, y: actionCenterY - DownloadRowMetrics.iconSize / 2,
                            width: DownloadRowMetrics.iconSize, height: DownloadRowMetrics.iconSize)
        var trailing = bounds.width - inset
        for button in actionButtons.reversed() {
            button.frame = NSRect(x: trailing - size, y: actionCenterY - size / 2, width: size, height: size)
            trailing -= size + gap
        }
        let leading = DownloadRowMetrics.textLeading
        let width = max(0, (actionButtons.isEmpty ? bounds.width - inset : trailing) - leading)
        let nameHeight = name.intrinsicContentSize.height
        let statusHeight = status.intrinsicContentSize.height
        let progressHeight = progress.isHidden ? 0 : DownloadRowMetrics.progressHeight
        let progressSpacing = progressHeight > 0 ? progressHeight + gap : 0
        let top = ((bounds.height - nameHeight - statusHeight - progressSpacing) / 2).rounded()
        let nameLeading = compact ? inset : leading
        let nameWidth = compact ? max(0, bounds.width - 2 * inset) : width
        let nameY = compact ? actionCenterY + size / 2 : top + statusHeight + progressSpacing
        name.frame = NSRect(x: nameLeading, y: nameY, width: nameWidth, height: nameHeight)
        status.frame = NSRect(x: leading, y: compact ? actionCenterY - statusHeight / 2 : top, width: width, height: statusHeight)
        if progressHeight > 0 {
            progress.frame = NSRect(x: leading, y: top + statusHeight + gap / 2, width: width, height: progressHeight)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            progressFill.frame = NSRect(x: 0, y: 0, width: width * progressFraction, height: progressHeight)
            effectiveAppearance.performAsCurrentDrawingAppearance {
                progress.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
                progressFill.backgroundColor = SpaceAccent.visible(SpaceAccent.teal, on: .controlBackgroundColor).cgColor
            }
            CATransaction.commit()
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
    func update(item: DownloadEntry) {
        itemID = item.id
        if icon.image == nil || name.stringValue != item.name { icon.image = downloadIcon(item.name) }
        name.stringValue = item.name
        let transferring = item.running || (item.state == 0 && item.paused && item.actions.contains("resume"))
        progress.isHidden = libraryPage || !transferring
        progressFraction = item.total > 0 ? Double(max(0, min(item.received, item.total))) / Double(item.total) : 0
        status.stringValue = item.status
        if !libraryPage && transferring {
            let received = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
            let size = item.total > 0 ? "\(received) of \(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))" : received
            if item.paused {
                status.stringValue = "Paused · \(size)"
            } else if let seconds = item.secondsRemaining {
                let remaining = seconds < 60 ? "\(seconds) s" : "\(1 + (seconds - 1) / 60) min"
                status.stringValue = "\(size) · \(remaining) left"
            } else {
                status.stringValue = size
            }
        } else if !libraryPage && item.state == 1 && item.actions.contains("open") {
            let size = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
            let host = URL(string: item.url)?.host
            status.stringValue = host.map { "\(size) · \($0)" } ?? size
        }
        for button in actionButtons { button.setAccessibilityLabel("\(button.title) \(item.name)") }
        guard actionButtons.map(\.downloadAction) != item.actions || actionButtons.contains(where: { $0.downloadID != item.id }) else {
            needsLayout = true
            return
        }
        actionButtons.forEach { $0.removeFromSuperview() }
        actionButtons.removeAll()
        for action in item.actions {
            let titles = ["open": "Open", "show": "Show in Finder", "cancel": "Cancel", "pause": "Pause", "resume": "Resume", "remove": "Remove", "keep": "Keep", "discard": "Discard"]
            let symbols = ["open": "arrow.up.forward.app", "show": "folder", "cancel": "xmark", "pause": "pause", "resume": "arrow.clockwise", "remove": "trash", "keep": "checkmark", "discard": "trash"]
            guard let title = titles[action], let symbol = symbols[action] else { continue }
            let button = DownloadActionButton(title: title, target: self, action: #selector(performDownload(_:)))
            button.downloadID = item.id; button.downloadAction = action
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: DownloadRowMetrics.actionSymbolSize, weight: .regular))
            button.imagePosition = .imageOnly; button.toolTip = title
            button.setAccessibilityLabel("\(title) \(item.name)")
            actionButtons.append(button)
            addSubview(button)
        }
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func performDownload(_ sender: DownloadActionButton) { model.perform(sender.downloadAction, id: sender.downloadID) }
}

@MainActor
func downloadIcon(_ name: String) -> NSImage {
    let ext = (name as NSString).pathExtension
    return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
}

/// A row's action button: the Little Window bar's icon button (a borderless 28 pt square with a
/// 13 pt SF Symbol) with the light UI's hover and pressed fills.
@MainActor
final class DownloadActionButton: NSButton {
    var downloadID = ""
    var downloadAction = ""
    var moveRow: ((Int) -> Void)?
    var tabRow: ((Bool) -> Void)?
    private var hovering = false
    private(set) var pressed = false
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        updateFill()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    /// The fill under the symbol: 0 at rest, the hover fill, and the pressed fill.
    var fillAlpha: CGFloat { pressed ? 0.18 : hovering ? 0.08 : 0 }
    var isHovering: Bool { hovering }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // A hover-opened popover is not key, so the fill must track in any window state.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        updateFill()
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateFill()
    }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        updateFill()
        super.mouseDown(with: event)
        pressed = false
        updateFill()
    }
    override var isEnabled: Bool { didSet { updateFill() } }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }
    private func updateFill() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(fillAlpha).cgColor
        }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125, let moveRow { moveRow(1) }
        else if event.keyCode == 126, let moveRow { moveRow(-1) }
        else if event.keyCode == 48, let tabRow { tabRow(event.modifierFlags.contains(.shift)) }
        else { super.keyDown(with: event) }
    }
}
