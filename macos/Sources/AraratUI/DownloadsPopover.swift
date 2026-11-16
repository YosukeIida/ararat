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
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        ring.fillColor = NSColor.clear.cgColor
        ring.lineWidth = 2
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
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateRing() }
    private func updateRing() {
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: 4, dy: 4), transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance { ring.strokeColor = NSColor.controlAccentColor.cgColor }
        switch progress {
        case .none:
            ring.removeAnimation(forKey: "spin"); ring.isHidden = true; setAccessibilityValue(libraryOpen ? 1 : 0)
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

@MainActor
final class DownloadsPopover: NSObject {
    static let rowHeight: CGFloat = 56
    static let headerHeight: CGFloat = 40
    private let popover = NSPopover()
    private let model: DownloadsModel
    private let anchor: NSView
    private let stack = NSStackView()
    let library = NSButton(title: "Open Library", target: nil, action: nil)
    // U26f: a private workspace has no Library page, so its download list hides this row.
    var showsLibrary = true { didSet { library.isHidden = !showsLibrary } }
    private(set) var rows: [String: DownloadRowView] = [:]
    var openLibrary: (() -> Void)?
    init(model: DownloadsModel, anchor: NSView) {
        self.model = model; self.anchor = anchor
        super.init()
        popover.behavior = .transient
        popover.animates = false
        stack.orientation = .vertical; stack.alignment = .width; stack.spacing = 0
        library.target = self; library.action = #selector(open)
        library.bezelStyle = .inline; library.isBordered = false; library.alignment = .left; library.setAccessibilityLabel("Open Library")
        library.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(library)
        library.heightAnchor.constraint(equalToConstant: 40).isActive = true
        library.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        library.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        let controller = NSViewController()
        let content = NSView(frame: NSRect(x: 0, y: 0, width: SidebarMetrics.defaultWidth, height: Self.headerHeight))
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor), stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        controller.view = content
        popover.contentViewController = controller
    }
    var isShown: Bool { popover.isShown }
    var checkWindow: NSWindow? { popover.contentViewController?.view.window }
    var checkMetrics: [String: Any] {
        let content = popover.contentViewController?.view
        content?.layoutSubtreeIfNeeded()
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
                "library_fills": abs(stack.convert(library.bounds, from: library).minX - stack.bounds.minX) <= 1 && library.bounds.width >= stack.bounds.width - 1,
                "title_font": rows.values.first?.titleFontSize ?? 0, "title_height": rows.values.first?.titleHeight ?? 0]
    }
    func close() { popover.performClose(nil) }
    static func edge(flipped: Bool) -> NSRectEdge { flipped ? .minY : .maxY }
    func show(focus: Bool = false, present: Bool = true) {
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
        if focus { popover.contentViewController?.view.window?.makeFirstResponder(library) }
    }
    func refresh(limit: Int) {
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
final class DownloadRowView: NSStackView {
    private(set) var itemID: String
    private let model: DownloadsModel
    private(set) var actionButtons: [DownloadActionButton] = []
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let actions = NSStackView()
    var titleFontSize: CGFloat { name.font?.pointSize ?? 0 }
    var titleHeight: CGFloat { name.bounds.height }
    var statusFits: Bool {
        let frame = convert(status.bounds, from: status)
        return frame.width > 0 && bounds.insetBy(dx: -1, dy: -1).contains(frame)
    }
    func statusFrame(in view: NSView) -> NSRect { view.convert(status.bounds, from: status) }
    var statusTruncates: Bool { status.maximumNumberOfLines == 1 && status.lineBreakMode == .byTruncatingTail && status.cell?.isScrollable == false && status.cell?.usesSingleLineMode == true }
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

    init(item: DownloadEntry, model: DownloadsModel) {
        itemID = item.id
        self.model = model
        super.init(frame: .zero)
        icon.setAccessibilityHidden(true)
        name.font = .systemFont(ofSize: 13); name.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 1; status.lineBreakMode = .byTruncatingTail
        status.cell?.usesSingleLineMode = true; status.cell?.isScrollable = false; status.cell?.wraps = false; status.cell?.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actions.orientation = .horizontal; actions.spacing = 4
        let text = NSStackView(views: [name, status, actions]); text.orientation = .vertical; text.alignment = .width; text.spacing = 0
        orientation = .horizontal; alignment = .centerY; spacing = 4
        addArrangedSubview(icon); addArrangedSubview(text)
        edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        text.widthAnchor.constraint(equalTo: widthAnchor, constant: -36).isActive = true
        name.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        heightAnchor.constraint(equalToConstant: DownloadsPopover.rowHeight).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        update(item: item)
    }
    func update(item: DownloadEntry) {
        itemID = item.id
        if icon.image == nil || name.stringValue != item.name { icon.image = downloadIcon(item.name) }
        name.stringValue = item.name
        status.stringValue = item.status
        for button in actionButtons { button.setAccessibilityLabel("\(button.title) \(item.name)") }
        guard actionButtons.map(\.downloadAction) != item.actions || actionButtons.contains(where: { $0.downloadID != item.id }) else { return }
        actionButtons.forEach { actions.removeArrangedSubview($0); $0.removeFromSuperview() }
        actionButtons.removeAll()
        for action in item.actions {
            let titles = ["open": "Open", "show": "Show in Finder", "cancel": "Cancel", "resume": "Resume", "remove": "Remove", "keep": "Keep", "discard": "Discard"]
            let symbols = ["open": "arrow.up.forward.app", "show": "folder", "cancel": "xmark", "resume": "arrow.clockwise", "remove": "trash", "keep": "checkmark", "discard": "trash"]
            guard let title = titles[action], let symbol = symbols[action] else { continue }
            let button = DownloadActionButton(title: title, target: self, action: #selector(performDownload(_:)))
            button.downloadID = item.id; button.downloadAction = action; button.bezelStyle = .inline
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly; button.toolTip = title
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.setAccessibilityLabel("\(title) \(item.name)")
            actionButtons.append(button)
            actions.addArrangedSubview(button)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func performDownload(_ sender: DownloadActionButton) { model.perform(sender.downloadAction, id: sender.downloadID) }
}

@MainActor
func downloadIcon(_ name: String) -> NSImage {
    let ext = (name as NSString).pathExtension
    return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
}

final class DownloadActionButton: NSButton {
    var downloadID = ""
    var downloadAction = ""
    var moveRow: ((Int) -> Void)?
    var tabRow: ((Bool) -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 125, let moveRow { moveRow(1) }
        else if event.keyCode == 126, let moveRow { moveRow(-1) }
        else if event.keyCode == 48, let tabRow { tabRow(event.modifierFlags.contains(.shift)) }
        else { super.keyDown(with: event) }
    }
}
