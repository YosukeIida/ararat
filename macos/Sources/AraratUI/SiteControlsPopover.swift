import AppKit
import AraratKit
import SecurityInterface

/// The URL field's site-controls button. A blocked permission lights a red dot (the engine's
/// snapshot `blocked` flag, not a URL-scheme guess).
@MainActor
public final class SiteControlsButton: URLFieldButton {
    public var showsBlockedDot = false {
        didSet { if showsBlockedDot != oldValue { needsDisplay = true } }
    }

    public init() { super.init(role: .siteControls) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsBlockedDot else { return }
        NSColor.systemRed.setFill()
        let dot = NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 8, y: bounds.maxY - 8, width: 6, height: 6))
        dot.fill()
    }
}

/// The site controls popover (architecture §7): the capture actions, the focused site's
/// permission rows from the engine's snapshot, and a footer security indicator that opens the
/// certificate panel for the page's DER chain. No inert rows: a row that cannot act is not built.
@MainActor
public final class SiteControlsPopover: NSObject, NSPopoverDelegate {
    /// Whether the full-page row ships. Design's pass-2 decision: the row stays behind one
    /// named constant until the VM proves capture beyond the viewport; when it cannot, design
    /// drops the row rather than shipping a cropped image.
    public static let includesFullPageCapture = true

    public var onCaptureRegion: ((SiteState) -> Void)?
    public var onCaptureFullPage: ((SiteState) -> Void)?
    /// Returns false when the engine rejected the request (stale document, read-only row).
    public var onPermissionChange: ((SiteState, [String: Any]) -> Bool)?
    /// U27w W4: the popover's last row opens Settings › Websites on this site's page.
    public var onAllSiteSettings: ((SiteState) -> Void)?
    public var onClose: (() -> Void)?

    /// The window the certificate sheet attaches to (the host window, not the popover).
    public var hostWindow: (() -> NSWindow?)?
    private weak var certificateParentWindow: NSWindow?
    private let popover = NSPopover()
    private var content: SiteControlsContent?
    private var model: SiteState?
    public private(set) var checkCertificatePanelOpen = false
    public private(set) var checkCertificatePanelEnded = false

    public override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    public var isShown: Bool { popover.isShown }
    public var checkContentSize: NSSize { popover.contentSize }

    public func present(relativeTo rect: NSRect, of view: NSView, model: SiteState) {
        self.model = model
        let content = SiteControlsContent(model: model, includesFullPage: Self.includesFullPageCapture)
        content.onCaptureRegion = { [weak self] in
            guard let self, let model = self.model else { return }
            self.close()
            self.onCaptureRegion?(model)
        }
        content.onCaptureFullPage = { [weak self] in
            guard let self, let model = self.model else { return }
            self.close()
            self.onCaptureFullPage?(model)
        }
        content.onPermission = { [weak self] request in
            guard let self, let model = self.model else { return false }
            return self.onPermissionChange?(model, request) ?? false
        }
        content.onAllSiteSettings = { [weak self] in
            guard let self, let model = self.model else { return }
            self.close()
            self.onAllSiteSettings?(model)
        }
        content.onCertificate = { [weak self] in self?.showCertificatePanel() }
        self.content = content
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.preferredSize
        popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    /// Keeps an open popover in step with a changed snapshot (a permission decision, a
    /// navigation): rows are rebuilt in place, so the popover never shows a stale setting.
    public func reload(model: SiteState) {
        guard popover.isShown, let content else { return }
        self.model = model
        content.rebuild(model: model)
        popover.contentSize = content.preferredSize
    }

    public func close() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    public func popoverDidClose(_ notification: Notification) {
        content = nil
        onClose?()
    }

    // MARK: Certificate panel

    private func showCertificatePanel() {
        guard let model, model.canShowCertificate,
              let parent = hostWindow?() ?? content?.window?.parent ?? content?.window,
              let panel = SFCertificatePanel.shared() else { return }
        let certificates = model.certificateChain.compactMap { data in
            SecCertificateCreateWithData(nil, data as CFData)
        }
        guard !certificates.isEmpty else { return }
        // S4: evaluate the SSL policy and hostname for this chain, without network fetches.
        // The panel still shows macOS's verdict, not Chromium's; the footer carries Chromium's.
        var trust: SecTrust?
        let host = URL(string: model.origin)?.host ?? ""
        let policy = SecPolicyCreateSSL(true, host as CFString)
        if SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
           let trust {
            SecTrustSetNetworkFetchAllowed(trust, false)
        }
        certificateParentWindow = parent
        checkCertificatePanelOpen = true
        checkCertificatePanelEnded = false
        // The panel is wider than the popover and outlives a transient popover's close.
        close()
        if let trust {
            panel.beginSheet(for: parent, modalDelegate: self,
                             didEnd: #selector(certificatePanelEnded(_:returnCode:contextInfo:)),
                             contextInfo: nil, trust: trust, showGroup: false)
        } else {
            panel.beginSheet(for: parent, modalDelegate: self,
                             didEnd: #selector(certificatePanelEnded(_:returnCode:contextInfo:)),
                             contextInfo: nil, certificates: certificates, showGroup: true)
        }
    }

    @objc private func certificatePanelEnded(_ panel: Any?, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        checkCertificatePanelEnded = true
        checkCertificatePanelOpen = false
    }

    public var checkAttachedCertificateSheet: NSWindow? {
        certificateParentWindow?.attachedSheet
    }

    public func checkCloseCertificatePanel() {
        guard let window = certificateParentWindow, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet)
    }

    // MARK: Check seams

    public var checkActionTitles: [String] { content?.actionTitles ?? [] }
    public var checkPermissionRows: [(type: String, name: String, current: String, items: [String], readOnly: Bool, frame: NSRect)] {
        content?.checkPermissionRows ?? []
    }
    public var checkFooterTitle: String { content?.footerTitle ?? "" }
    public var checkFooterEnabled: Bool { content?.footerEnabled ?? false }
    public var checkFooterFrame: NSRect { content?.footerFrame ?? .zero }
    public var checkActionFrames: [NSRect] { content?.actionFrames ?? [] }
    public var checkPadding: CGFloat { SiteControlsContent.padding }
    public var checkGap: CGFloat { SiteControlsContent.gap }

    public func checkChoosePermission(row: Int, item: Int) -> Bool {
        content?.checkChoosePermission(row: row, item: item) ?? false
    }

    public func checkClickFooter() -> Bool {
        content?.checkClickFooter() ?? false
    }

    public func checkClickAction(_ title: String) -> Bool {
        content?.checkClickAction(title) ?? false
    }

    public var checkLabelsComplete: Bool { content?.checkLabelsComplete ?? false }
    public var checkAllSiteSettingsTitle: String { content?.allSiteSettingsTitle ?? "" }
    public func checkClickAllSiteSettings() -> Bool { content?.checkClickAllSiteSettings() ?? false }
    public var checkPillStyle: SiteState.SecurityPill? { content?.pillStyle }
    public var checkActionRow: (sameRow: Bool, height: CGFloat, equalWidth: Bool, iconOnly: Bool, tooltipsMatch: Bool) {
        content?.checkActionRow ?? (false, 0, false, false, false)
    }
    public var checkAllSiteSettingsFrame: NSRect { content?.allSiteSettingsFrame ?? .zero }
}

@MainActor
final class SiteControlsContent: NSView {
    static let width: CGFloat = 262
    static let padding: CGFloat = 16
    static let gap: CGFloat = 16
    /// The board's action row: one row of 48 pt icon buttons, 8 pt apart, radius 8 (P4,
    /// 2026-11-15: the owner asked for icons with their names as tooltips, not two text rows).
    static let actionHeight: CGFloat = 48
    static let actionGap: CGFloat = 8
    static let actionRadius: CGFloat = 8
    static let rowHeight: CGFloat = 24
    /// The footer is the popover's bottom band: 8 pt above and below the pill and the link.
    static let footerHeight: CGFloat = 40
    static let pillHeight: CGFloat = 24
    static let pillRadius: CGFloat = 8
    static let linkHeight: CGFloat = 24

    var onCaptureRegion: (() -> Void)?
    var onCaptureFullPage: (() -> Void)?
    var onPermission: (([String: Any]) -> Bool)?
    var onAllSiteSettings: (() -> Void)?
    var onCertificate: (() -> Void)?

    private let stack = NSStackView()
    private let includesFullPage: Bool
    private var model: SiteState
    private var actions: [SiteControlActionButton] = []
    private var rows: [(button: NSButton?, icon: NSImageView, label: NSTextField, control: NSView, row: SiteState.Permission)] = []
    private let footer = NSView()
    private let footerLine = NSView()
    private let pill = SiteControlPillButton()
    private let allSiteSettings = SiteControlLinkButton()
    private var permissionPopups: [NSPopUpButton] = []

    var actionTitles: [String] { actions.compactMap { $0.accessibilityLabel() } }
    var actionFrames: [NSRect] { actions.map { convert($0.bounds, from: $0) }.sorted { $0.minX < $1.minX } }
    var actionTooltips: [String?] { actions.map(\.toolTip) }
    var footerTitle: String { pill.title }
    var footerEnabled: Bool { pill.isEnabled }
    var footerFrame: NSRect { convert(pill.bounds, from: pill) }
    var allSiteSettingsTitle: String { allSiteSettings.title }
    var allSiteSettingsFrame: NSRect { convert(allSiteSettings.bounds, from: allSiteSettings) }
    var pillStyle: SiteState.SecurityPill { pill.style }

    /// One row: every action shares a baseline and a height, the two tiles share the width, and
    /// each tile is an icon with its name as a tooltip.
    var checkActionRow: (sameRow: Bool, height: CGFloat, equalWidth: Bool, iconOnly: Bool, tooltipsMatch: Bool) {
        let frames = actionFrames
        return (Set(frames.map { $0.minY }).count <= 1 && Set(frames.map { $0.height }).count == 1,
                frames.first?.height ?? 0,
                frames.count < 2 || abs(frames[0].width - frames[1].width) < 0.5,
                actions.allSatisfy { $0.title.isEmpty && $0.image != nil },
                zip(actions, actions.map { $0.accessibilityLabel() }).allSatisfy { $0.toolTip == $1 })
    }

    var checkPermissionRows: [(type: String, name: String, current: String, items: [String], readOnly: Bool, frame: NSRect)] {
        rows.map { entry in
            let popup = entry.control as? NSPopUpButton
            // Only the engine's allowed values are actionable; a placeholder for the current
            // value is not one of them.
            let items = popup?.itemArray.filter { $0.representedObject != nil }.map(\.title) ?? []
            let current = popup?.titleOfSelectedItem ?? (entry.control as? NSTextField)?.stringValue ?? ""
            return (entry.row.type, entry.row.displayName, current, items,
                    popup == nil, convert(entry.control.bounds, from: entry.control))
        }
    }

    init(model: SiteState, includesFullPage: Bool) {
        self.model = model
        self.includesFullPage = includesFullPage
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 200))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.gap
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        footerLine.wantsLayer = true
        footerLine.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerLine)
        pill.target = self
        pill.action = #selector(openCertificate)
        pill.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(pill)
        allSiteSettings.target = self
        allSiteSettings.action = #selector(openAllSiteSettings)
        allSiteSettings.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(allSiteSettings)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: footer.topAnchor, constant: -Self.gap),
            footer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
            footerLine.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerLine.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerLine.topAnchor.constraint(equalTo: footer.topAnchor),
            footerLine.heightAnchor.constraint(equalToConstant: 1),
            pill.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: Self.padding),
            pill.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            pill.heightAnchor.constraint(equalToConstant: Self.pillHeight),
            allSiteSettings.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -Self.padding),
            allSiteSettings.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            allSiteSettings.heightAnchor.constraint(equalToConstant: Self.linkHeight),
            allSiteSettings.leadingAnchor.constraint(greaterThanOrEqualTo: pill.trailingAnchor, constant: 8),
        ])
        build()
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var preferredSize: NSSize {
        let views = stack.arrangedSubviews
        var height: CGFloat = 0
        for (index, view) in views.enumerated() {
            if index > 0 { height += Self.gap }
            height += view.fittingSize.height
        }
        height += Self.padding + Self.gap + Self.footerHeight
        return NSSize(width: Self.width, height: ceil(height / 8) * 8)
    }

    private func clearStack() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        actions.removeAll()
        rows.removeAll()
        permissionPopups.removeAll()
    }

    private func build() {
        clearStack()
        // P4: the action row is one row of icon buttons; the names live in their tooltips and
        // accessibility labels.
        let actionsRow = SiteActionRow(frame: .zero)
        actionsRow.add(actionButton(title: "Screenshot a region", symbol: "viewfinder",
                                    action: #selector(captureRegion)))
        if includesFullPage {
            actionsRow.add(actionButton(title: "Capture the full page", symbol: "rectangle.dashed",
                                        action: #selector(captureFullPage)))
        }
        actionsRow.heightAnchor.constraint(equalToConstant: Self.actionHeight).isActive = true
        actionsRow.widthAnchor.constraint(equalToConstant: Self.width - Self.padding * 2).isActive = true
        stack.addArrangedSubview(actionsRow)

        if !model.permissions.isEmpty {
            let permissionStack = NSStackView()
            permissionStack.orientation = .vertical
            permissionStack.alignment = .leading
            permissionStack.spacing = 8
            let heading = NSTextField(labelWithString: "Permissions for \(shortOrigin)")
            heading.font = .systemFont(ofSize: 11, weight: .medium)
            heading.textColor = .secondaryLabelColor
            permissionStack.addArrangedSubview(heading)
            for (index, row) in model.permissions.enumerated() {
                permissionStack.addArrangedSubview(permissionRow(row, index: index))
            }
            permissionStack.widthAnchor.constraint(equalToConstant: Self.width - Self.padding * 2).isActive = true
            stack.addArrangedSubview(permissionStack)
        }

        // The footer's pill is the page's own verdict; the button opens the certificate panel
        // when Chromium gave us a chain.
        pill.update(model: model)
        pill.isEnabled = model.canShowCertificate
        allSiteSettings.title = "All Site Settings…"
    }

    func rebuild(model: SiteState) {
        self.model = model
        build()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        footerLine.layer?.backgroundColor = Self.overlay(0.12, appearance: effectiveAppearance)
        allSiteSettings.updateFill(appearance: effectiveAppearance)
    }

    /// The board's translucent fills: black over the light material, white over the dark one.
    static func overlay(_ alpha: CGFloat, appearance: NSAppearance) -> CGColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(alpha).cgColor
    }

    private var shortOrigin: String {
        let value = model.origin
        if let url = URL(string: value), let host = url.host { return host }
        return value.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    private func actionButton(title: String, symbol: String, action: Selector) -> SiteControlActionButton {
        let button = SiteControlActionButton(title: title, symbol: symbol)
        button.target = self
        button.action = action
        button.heightAnchor.constraint(equalToConstant: Self.actionHeight).isActive = true
        actions.append(button)
        return button
    }

    private func permissionRow(_ row: SiteState.Permission, index: Int) -> NSView {
        let line = NSView()
        let icon = NSImageView(image: NSImage(systemSymbolName: row.iconName, accessibilityDescription: row.displayName) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: row.displayName)
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        let control: NSView
        if row.isReadOnly || row.allowed.isEmpty {
            let value = NSTextField(labelWithString: row.current?.title ?? "Unsupported")
            value.font = .systemFont(ofSize: 12)
            value.textColor = .secondaryLabelColor
            value.alignment = .right
            value.setAccessibilityLabel("\(row.displayName) permission")
            value.setAccessibilityValue(row.current?.title ?? "Unsupported")
            control = value
        } else {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.isBordered = false
            popup.font = .systemFont(ofSize: 12)
            popup.alignment = .right
            popup.setAccessibilityLabel("\(row.displayName) permission")
            var menuItems: [NSMenuItem] = []
            let currentIndex = row.allowed.firstIndex(where: { $0 == row.current })
            var hasPlaceholder = false
            if currentIndex == nil {
                hasPlaceholder = true
                // S5: never show "Allow" for a value the row does not hold. A current value the
                // engine does not list (no explicit setting, or a mixed pair it omits) gets its
                // own selected, disabled line.
                let title = row.setting == nil
                    ? "\(row.current?.title ?? "Unsupported") (default)"
                    : (row.current?.title ?? "Unsupported")
                let placeholder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                placeholder.isEnabled = false
                placeholder.state = .on
                menuItems.append(placeholder)
            }
            for (itemIndex, setting) in row.allowed.enumerated() {
                let item = NSMenuItem(title: setting.title, action: #selector(permissionChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["row": index, "item": itemIndex]
                item.state = setting == row.current ? .on : .off
                menuItems.append(item)
            }
            if row.isExplicit {
                menuItems.append(.separator())
                let reset = NSMenuItem(title: "Reset", action: #selector(permissionChosen(_:)), keyEquivalent: "")
                reset.target = self
                reset.representedObject = ["row": index, "item": -1]
                menuItems.append(reset)
            }
            for item in menuItems { popup.menu?.addItem(item) }
            if let currentIndex {
                popup.selectItem(at: currentIndex + (hasPlaceholder ? 1 : 0))
            } else {
                popup.selectItem(at: 0)
            }
            popup.widthAnchor.constraint(equalToConstant: 108).isActive = true
            popup.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            permissionPopups.append(popup)
            control = popup
        }
        control.translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(icon)
        line.addSubview(label)
        line.addSubview(control)
        NSLayoutConstraint.activate([
            line.heightAnchor.constraint(equalToConstant: Self.rowHeight),
            icon.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: line.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -8),
        ])
        rows.append((control as? NSPopUpButton, icon, label, control, row))
        return line
    }

    @objc private func captureRegion() { onCaptureRegion?() }
    @objc private func captureFullPage() { onCaptureFullPage?() }
    @objc private func openCertificate() { onCertificate?() }
    @objc private func openAllSiteSettings() { onAllSiteSettings?() }

    @objc private func permissionChosen(_ item: NSMenuItem) {
        guard let info = item.representedObject as? [String: Int] else { return }
        _ = choose(row: info["row"] ?? -1, item: info["item"] ?? -2)
    }

    func checkChoosePermission(row: Int, item: Int) -> Bool {
        choose(row: row, item: item)
    }

    private func choose(row: Int, item: Int) -> Bool {
        guard row >= 0, row < rows.count else { return false }
        let permission = rows[row].row
        let request: [String: Any]
        if item == -1 {
            request = ["document": model.document, "type": permission.type,
                       "requestingOrigin": permission.requestingOrigin, "setting": NSNull()]
        } else {
            guard item >= 0, item < permission.allowed.count else { return false }
            request = ["document": model.document, "type": permission.type,
                       "requestingOrigin": permission.requestingOrigin,
                       "setting": permission.allowed[item].request]
        }
        let accepted = onPermission?(request) ?? false
        if !accepted { rebuild(model: model) }
        return accepted
    }

    func checkClickFooter() -> Bool {
        guard pill.isEnabled else { return false }
        pill.performClick(nil)
        return true
    }

    func checkClickAction(_ title: String) -> Bool {
        guard let button = actions.first(where: { $0.accessibilityLabel() == title }) else { return false }
        button.performClick(nil)
        return true
    }

    func checkClickAllSiteSettings() -> Bool {
        guard allSiteSettings.isEnabled else { return false }
        allSiteSettings.performClick(nil)
        return true
    }

    /// Every control a keyboard or screen reader reaches names itself and its value.
    var checkLabelsComplete: Bool {
        !actions.isEmpty && actions.allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty == false }
            && rows.allSatisfy { ($0.control.accessibilityLabel() ?? "").isEmpty == false }
            && (pill.accessibilityLabel() ?? "").isEmpty == false
            && (allSiteSettings.accessibilityLabel() ?? "").isEmpty == false
    }

    override var isFlipped: Bool { true }
}

/// The action row: equal tiles edge to edge with an 8 pt gap (P4). Laid out by hand so the tiles
/// keep the row's height; a stack view centres an NSButton at its own intrinsic height.
@MainActor
final class SiteActionRow: NSView {
    private(set) var tiles: [SiteControlActionButton] = []
    override var isFlipped: Bool { true }

    func add(_ tile: SiteControlActionButton) {
        tiles.append(tile)
        addSubview(tile)
    }

    static func tileFrames(count: Int, bounds: NSRect, gap: CGFloat) -> [NSRect] {
        guard count > 0 else { return [] }
        let width = max(0, (bounds.width - gap * CGFloat(count - 1)) / CGFloat(count))
        return (0..<count).map { NSRect(x: CGFloat($0) * (width + gap), y: 0, width: width, height: bounds.height) }
    }

    override func layout() {
        super.layout()
        for (tile, frame) in zip(tiles, Self.tileFrames(count: tiles.count, bounds: bounds, gap: SiteControlsContent.actionGap)) {
            tile.frame = frame
        }
    }
}

/// The capture action: an icon tile with its name in the tooltip (P4).
@MainActor
final class SiteControlActionButton: NSButton {
    private var hovered = false { didSet { updateFill() } }
    private var pressed = false { didSet { updateFill() } }

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        self.title = ""
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        isBordered = false
        bezelStyle = .inline
        focusRingType = .none
        toolTip = title
        setAccessibilityLabel(title)
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = SiteControlsContent.actionRadius
        layer?.cornerCurve = .continuous
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { pressed = true; super.mouseDown(with: event); pressed = false }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateFill() }

    private func updateFill() {
        let alpha: CGFloat = pressed ? 0.14 : hovered ? 0.07 : 0.055
        layer?.backgroundColor = SiteControlsContent.overlay(alpha, appearance: effectiveAppearance)
    }
}

/// The footer's security pill: the page's verdict, opens the certificate viewer (P4). A page
/// with no connection information keeps the quiet fill and prints that text.
@MainActor
final class SiteControlPillButton: NSButton {
    private(set) var style: SiteState.SecurityPill = .neutral
    /// The drawn box: the button's frame carries the board's padding (7 pt leading, 10 trailing)
    /// so the fill and the text both start where the board puts them.
    private let box = NSView()

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        imagePosition = .imageLeading
        imageHugsTitle = true
        alignment = .left
        font = .systemFont(ofSize: 12)
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel("Security")
        box.wantsLayer = true
        box.layer?.cornerRadius = SiteControlsContent.pillRadius
        box.layer?.cornerCurve = .continuous
        addSubview(box, positioned: .below, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 10)
    }

    override func layout() {
        super.layout()
        box.frame = NSRect(x: 7, y: 0, width: max(0, bounds.width - 17), height: bounds.height)
    }

    func update(model: SiteState) {
        style = model.securityPill
        title = model.securityPillTitle
        image = NSImage(systemSymbolName: model.securitySymbol, accessibilityDescription: model.securityPillTitle)
        imageScaling = .scaleProportionallyDown
        let tint: NSColor = switch style {
        case .secure, .neutral: .secondaryLabelColor
        case .warn: .systemOrange
        case .bad: .systemRed
        }
        contentTintColor = tint
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: tint,
        ])
        updateFill()
        toolTip = model.canShowCertificate ? "Show certificate" : "No certificate for this page"
        setAccessibilityLabel(model.securityPillTitle)
        setAccessibilityHelp(toolTip ?? "")
    }

    private func updateFill() {
        box.layer?.backgroundColor = switch style {
        case .secure, .neutral: SiteControlsContent.overlay(0.055, appearance: effectiveAppearance)
        case .warn: NSColor.systemOrange.withAlphaComponent(0.22).cgColor
        case .bad: NSColor.systemRed.withAlphaComponent(0.22).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateFill()
    }
}

/// The footer's quiet link: All Site Settings… (P4).
@MainActor
final class SiteControlLinkButton: NSButton {
    private var hovered = false { didSet { updateFill() } }
    private let box = NSView()

    init() {
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        alignment = .center
        font = .systemFont(ofSize: 12)
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel("All Site Settings…")
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.cornerCurve = .continuous
        addSubview(box, positioned: .below, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    }

    override func layout() {
        super.layout()
        box.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: bounds.height)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    func updateFill(appearance: NSAppearance) {
        box.layer?.backgroundColor = hovered ? SiteControlsContent.overlay(0.07, appearance: appearance) : nil
        contentTintColor = hovered ? .labelColor : .secondaryLabelColor
    }

    private func updateFill() { updateFill(appearance: effectiveAppearance) }
}
