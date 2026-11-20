import AppKit
import AraratKit

@MainActor
public final class TabSwitcher {
    public private(set) var rows: [Suggestion] = []
    public private(set) var selectedIndex = 0
    public private(set) var isOpen = true
    private(set) var isRevealed = false
    public var onSelect: (Suggestion) -> Void = { _ in }
    public var onClose: () -> Void = {}
    public var onPresentationForCheck: ((Bool, TimeInterval, Bool) -> Void)?
    private let started = ProcessInfo.processInfo.systemUptime
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    public var visibleWindow: NSWindow? { panel.isVisible ? panel : nil }
    private weak var parent: NSWindow?
    private var monitor: Any?
    private var deactivate: NSObjectProtocol?
    private var resignKey: NSObjectProtocol?
    private var offset: Int
    private var awaitingRows = true
    private var commitPending = false
    private var revealDelayElapsed = false
    private let favicon: (String) -> NSImage?
    private let thumbnail: (String) -> NSImage?
    private let accent: NSColor
    private let hints: [String]
    private struct TileImages {
        let preview: NSView
        let picture: NSImageView
        let favicon: NSImageView
    }
    private var tileImages: [String: TileImages] = [:]

    public convenience init(parent: NSWindow, backwards: Bool, bindings: [KeyBinding], accent: NSColor,
                            thumbnail: @escaping (String) -> NSImage? = { _ in nil },
                            favicon: @escaping (String) -> NSImage?) {
        self.init(parent: parent, backwards: backwards, bindings: bindings, accent: accent,
                  thumbnail: thumbnail, favicon: favicon, schedule: { delay, reveal in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: reveal)
        })
    }

    init(parent: NSWindow, backwards: Bool, bindings: [KeyBinding], accent: NSColor,
         thumbnail: @escaping (String) -> NSImage? = { _ in nil },
         favicon: @escaping (String) -> NSImage?,
         schedule: (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void) {
        self.parent = parent
        self.favicon = favicon
        self.thumbnail = thumbnail
        self.accent = accent
        let steps = [("cycle_tabs_next", "Next"), ("cycle_tabs_previous", "Previous")]
        hints = steps.compactMap { step -> String? in
            let (command, action) = step
            guard let key = bindings.first(where: { $0.command == command })?.key else { return nil }
            return "\(CommandBarRowView.keycap(key)) \(action)"
        } + ["Release ⌃ Switch", "Esc Cancel"]
        offset = backwards ? -1 : 0
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self, self.isOpen else { return event }
            if event.type == .flagsChanged && !event.modifierFlags.contains(.control) {
                self.commit()
                return event
            }
            if event.type == .keyDown && event.keyCode == 53 { self.cancel(); return nil }
            return event
        }
        resignKey = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        deactivate = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        }
        schedule(0.15) { [weak self] in
            guard let self else { return }
            self.revealDelayElapsed = true
            self.revealIfReady()
        }
    }

    public func load(_ rows: [Suggestion]) {
        guard isOpen else { return }
        awaitingRows = false
        self.rows = Array(rows.prefix(5))
        guard !self.rows.isEmpty else { cancel(); return }
        selectedIndex = ((offset % self.rows.count) + self.rows.count) % self.rows.count
        if commitPending { commit(); return }
        revealIfReady()
    }

    public func advance(backwards: Bool) {
        guard isOpen, !commitPending else { return }
        offset += backwards ? -1 : 1
        guard !rows.isEmpty else { return }
        selectedIndex = ((offset % rows.count) + rows.count) % rows.count
        if isRevealed { draw() }
    }

    public func commit() {
        guard isOpen else { return }
        if awaitingRows { commitPending = true; return }
        let selected = rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
        cancel()
        if let selected { onSelect(selected) }
    }

    public func cancel() {
        guard isOpen else { return }
        isOpen = false
        isRevealed = false
        tileImages.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let deactivate { NotificationCenter.default.removeObserver(deactivate); self.deactivate = nil }
        if let resignKey { NotificationCenter.default.removeObserver(resignKey); self.resignKey = nil }
        if panel.parent != nil { parent?.removeChildWindow(panel) }
        if panel.isVisible {
            panel.orderOut(nil)
            onPresentationForCheck?(false, ProcessInfo.processInfo.systemUptime - started, panel.animationBehavior == .none)
        }
        onClose()
    }

    private func revealIfReady() {
        guard isOpen, !isRevealed, !commitPending, revealDelayElapsed, !rows.isEmpty else { return }
        isRevealed = true
        draw()
    }

    public func refreshImages(_ items: Set<String>) {
        guard isOpen, isRevealed, panel.isVisible else { return }
        for item in items {
            if let tile = tileImages[item] { updateImages(for: item, tile: tile) }
        }
    }

    public func previewForCheck(item: String) -> (image: NSImage?, fillsPreview: Bool, size: NSSize)? {
        guard panel.isVisible, let tile = tileImages[item] else { return nil }
        return (tile.picture.image, tile.picture.frame == tile.preview.bounds, tile.picture.frame.size)
    }

    private func updateImages(for item: String?, tile: TileImages) {
        let icon = item.flatMap(favicon) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        let preview = item.flatMap(thumbnail)
        tile.favicon.image = icon
        let bounds = tile.preview.bounds
        let size = min(22, bounds.width, bounds.height)
        tile.picture.frame = preview == nil
            ? NSRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
            : bounds
        tile.picture.image = preview ?? icon
    }

    private func draw() {
        guard let parent else { cancel(); return }
        guard parent.isVisible, let overlay = makeOverlay() else { return }
        panel.contentView = overlay.content
        panel.setFrame(overlay.frame, display: true)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible {
            panel.orderFront(nil)
            if panel.isVisible {
                onPresentationForCheck?(true, ProcessInfo.processInfo.systemUptime - started, panel.animationBehavior == .none)
            }
        }
    }

    func makeOverlay() -> (content: NSView, frame: NSRect)? {
        guard let parent, !rows.isEmpty else { return nil }
        let window = parent.frame
        let hintGap = CommandBarMetrics.hintGap
        let pills = hints.map { title in
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: CommandBarMetrics.hintFontSize)
            label.textColor = .white
            label.sizeToFit()
            label.frame.origin = NSPoint(x: CommandBarMetrics.hintPaddingX, y: CommandBarMetrics.hintPaddingY)
            let pill = NSView(frame: label.frame.insetBy(dx: -CommandBarMetrics.hintPaddingX, dy: -CommandBarMetrics.hintPaddingY))
            pill.wantsLayer = true
            pill.layer?.backgroundColor = CommandBarMetrics.hintFill.cgColor
            pill.layer?.cornerRadius = CommandBarMetrics.hintRadius
            pill.addSubview(label)
            return pill
        }
        func hintWidth(_ row: [NSView]) -> CGFloat {
            row.reduce(0) { $0 + $1.frame.width } + CGFloat(row.count - 1) * hintGap
        }
        let split = (pills.count + 1) / 2
        let hintRows = hintWidth(pills) > window.width ? [Array(pills.prefix(split)), Array(pills.dropFirst(split))] : [pills]
        let hintHeight = pills[0].frame.height
        let hintRowGap = CommandBarMetrics.hintPaddingY
        let panelY = CGFloat(hintRows.count) * (hintHeight + hintRowGap) - hintRowGap + 12
        let tilePadding: CGFloat = 10
        let tileGap: CGFloat = 4
        let labelHeight: CGFloat = 16
        let previewGap: CGFloat = 13
        let tileSpacing = 2 * tilePadding + CGFloat(rows.count - 1) * tileGap
        let tileWidth = min(172, max(0, (window.width - tileSpacing) / CGFloat(rows.count)))
        let inset = min(8, tileWidth / 2)
        let previewWidth = tileWidth - 2 * inset
        let previewHeight = previewWidth * 104 / 156
        let tileHeight = 16 + labelHeight + previewGap + previewHeight
        let panelWidth = CGFloat(rows.count) * tileWidth + tileSpacing
        let width = max(panelWidth, hintRows.map(hintWidth).max() ?? 0)
        let panelHeight = tileHeight + 2 * tilePadding
        let frame = NSRect(x: window.midX - width / 2, y: window.midY - panelHeight / 2 - panelY,
                           width: width, height: panelHeight + panelY)
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        let background = NSVisualEffectView(frame: NSRect(x: (width - panelWidth) / 2, y: panelY,
                                                         width: panelWidth, height: panelHeight))
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        tileImages.removeAll(keepingCapacity: true)
        for (index, row) in rows.enumerated() {
            let tile = NSView(frame: NSRect(x: tilePadding + CGFloat(index) * (tileWidth + tileGap),
                                          y: tilePadding, width: tileWidth, height: tileHeight))
            tile.identifier = NSUserInterfaceItemIdentifier("tab-switcher-tile")
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 10
            tile.layer?.backgroundColor = (index == selectedIndex ? accent : NSColor.clear).cgColor
            let preview = NSView(frame: NSRect(x: inset, y: 8 + labelHeight + previewGap,
                                               width: previewWidth, height: previewHeight))
            preview.identifier = NSUserInterfaceItemIdentifier("tab-switcher-preview")
            preview.wantsLayer = true
            preview.layer?.cornerRadius = 6
            preview.layer?.masksToBounds = true
            preview.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            let picture = NSImageView()
            picture.imageScaling = .scaleProportionallyUpOrDown
            preview.addSubview(picture)
            let iconWidth = min(labelHeight, previewWidth)
            let icon = NSImageView(frame: NSRect(x: inset, y: 8, width: iconWidth, height: labelHeight))
            icon.imageScaling = .scaleProportionallyUpOrDown
            let images = TileImages(preview: preview, picture: picture, favicon: icon)
            var item: String?
            if case .tab(let id, _) = row.target {
                item = id
                tileImages[id] = images
            }
            updateImages(for: item, tile: images)
            let title = NSTextField(labelWithString: row.title)
            title.font = .systemFont(ofSize: 12)
            title.textColor = index == selectedIndex ? SpaceAccent.foreground(on: accent) : .labelColor
            title.lineBreakMode = .byTruncatingTail
            let titleOffset = min(previewWidth, iconWidth + 6)
            title.frame = NSRect(x: inset + titleOffset, y: 8, width: previewWidth - titleOffset, height: labelHeight)
            tile.addSubview(preview)
            tile.addSubview(icon)
            tile.addSubview(title)
            background.addSubview(tile)
        }
        content.addSubview(background)
        for (index, row) in hintRows.enumerated() {
            var x = (width - hintWidth(row)) / 2
            let y = CGFloat(hintRows.count - 1 - index) * (hintHeight + hintRowGap)
            for pill in row {
                pill.frame.origin = NSPoint(x: x, y: y)
                content.addSubview(pill)
                x += pill.frame.width + hintGap
            }
        }
        return (content, frame)
    }
}
