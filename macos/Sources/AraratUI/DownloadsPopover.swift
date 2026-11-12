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
            ring.removeAnimation(forKey: "spin"); ring.isHidden = false; ring.strokeEnd = fraction
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
    private let popover = NSPopover()
    private let model: DownloadsModel
    private let anchor: NSView
    private let stack = NSStackView()
    let library = NSButton(title: "Open Library", target: nil, action: nil)
    private(set) var rows: [String: DownloadRowView] = [:]
    var openLibrary: (() -> Void)?
    init(model: DownloadsModel, anchor: NSView) {
        self.model = model; self.anchor = anchor
        super.init()
        popover.behavior = .transient
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        library.target = self; library.action = #selector(open)
        library.bezelStyle = .inline; library.setAccessibilityLabel("Open Library")
        stack.addArrangedSubview(library)
        library.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let controller = NSViewController()
        controller.view = stack
        popover.contentViewController = controller
    }
    var isShown: Bool { popover.isShown }
    var checkWindow: NSWindow? { popover.contentViewController?.view.window }
    func close() { popover.performClose(nil) }
    func show(focus: Bool = false) {
        guard model.hasSessionDownloads, let window = anchor.window else { return }
        let point = window.convertPoint(toScreen: anchor.convert(NSPoint(x: 0, y: anchor.bounds.maxY), to: nil))
        let available = (window.screen?.visibleFrame.maxY ?? point.y + 400) - point.y
        let count = max(0, min(model.items.count, Int(max(0, available - 80) / 80)))
        refresh(limit: count)
        popover.contentSize = NSSize(width: 320, height: 40 + count * 80)
        if !popover.isShown { popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }
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
            }
        }
    }
    @objc private func open() { close(); openLibrary?() }
    func row(_ item: DownloadEntry) -> NSView {
        DownloadRowView(item: item, model: model)
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
        name.lineBreakMode = .byTruncatingMiddle
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        actions.orientation = .horizontal; actions.spacing = 4
        let text = NSStackView(views: [name, status, actions]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 4
        orientation = .horizontal; alignment = .centerY; spacing = 8
        addArrangedSubview(icon); addArrangedSubview(text)
        edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        heightAnchor.constraint(equalToConstant: 80).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
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
            guard let title = titles[action] else { continue }
            let button = DownloadActionButton(title: title, target: self, action: #selector(performDownload(_:)))
            button.downloadID = item.id; button.downloadAction = action; button.bezelStyle = .inline
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
