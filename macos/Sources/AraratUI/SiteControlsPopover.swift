import AppKit
import AraratKit
import SecurityInterface

/// The URL field's site-controls button. A blocked permission lights a red dot (the engine's
/// snapshot `blocked` flag, not a URL-scheme guess).
@MainActor
public final class SiteControlsButton: NSButton {
    public var showsBlockedDot = false {
        didSet { if showsBlockedDot != oldValue { needsDisplay = true } }
    }

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
    public var onClose: (() -> Void)?

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
        content.onCertificate = { [weak self] in self?.showCertificatePanel() }
        self.content = content
        let controller = NSViewController()
        controller.view = content
        popover.contentViewController = controller
        popover.contentSize = content.preferredSize
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
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
        guard let model, model.canShowCertificate, let window = content?.window,
              let panel = SFCertificatePanel.shared() else { return }
        let certificates = model.certificateChain.compactMap { data in
            SecCertificateCreateWithData(nil, data as CFData)
        }
        guard !certificates.isEmpty else { return }
        checkCertificatePanelOpen = true
        checkCertificatePanelEnded = false
        panel.beginSheet(for: window, modalDelegate: self,
                         didEnd: #selector(certificatePanelEnded(_:returnCode:contextInfo:)),
                         contextInfo: nil, certificates: certificates, showGroup: true)
    }

    @objc private func certificatePanelEnded(_ panel: Any?, returnCode: Int, contextInfo: UnsafeMutableRawPointer?) {
        checkCertificatePanelEnded = true
        checkCertificatePanelOpen = false
    }

    public var checkAttachedCertificateSheet: NSWindow? {
        content?.window?.attachedSheet
    }

    public func checkCloseCertificatePanel() {
        guard let window = content?.window, let sheet = window.attachedSheet else { return }
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
}

@MainActor
final class SiteControlsContent: NSView {
    static let width: CGFloat = 262
    static let padding: CGFloat = 16
    static let gap: CGFloat = 16
    static let actionHeight: CGFloat = 24
    static let rowHeight: CGFloat = 24

    var onCaptureRegion: (() -> Void)?
    var onCaptureFullPage: (() -> Void)?
    var onPermission: (([String: Any]) -> Bool)?
    var onCertificate: (() -> Void)?

    private let stack = NSStackView()
    private let includesFullPage: Bool
    private var model: SiteState
    private var actions: [NSButton] = []
    private var rows: [(button: NSButton?, icon: NSImageView, label: NSTextField, control: NSView, row: SiteState.Permission)] = []
    private var footer = NSButton()
    private var permissionPopups: [NSPopUpButton] = []

    var actionTitles: [String] { actions.map(\.title) }
    var actionFrames: [NSRect] { actions.map { convert($0.bounds, from: $0) } }
    var footerTitle: String { footer.title }
    var footerEnabled: Bool { footer.isEnabled }
    var footerFrame: NSRect { convert(footer.bounds, from: footer) }

    var checkPermissionRows: [(type: String, name: String, current: String, items: [String], readOnly: Bool, frame: NSRect)] {
        rows.map { entry in
            let popup = entry.control as? NSPopUpButton
            let items = popup?.itemArray.map(\.title) ?? []
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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -Self.padding),
        ])
        build()
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
        height += Self.padding * 2
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
        let actionsStack = NSStackView()
        actionsStack.orientation = .vertical
        actionsStack.alignment = .leading
        actionsStack.spacing = 8
        actionsStack.addArrangedSubview(actionButton(title: "Screenshot a region", symbol: "viewfinder",
                                                     action: #selector(captureRegion)))
        if includesFullPage {
            actionsStack.addArrangedSubview(actionButton(title: "Capture the full page", symbol: "rectangle.dashed",
                                                         action: #selector(captureFullPage)))
        }
        actionsStack.widthAnchor.constraint(equalToConstant: Self.width - Self.padding * 2).isActive = true
        stack.addArrangedSubview(actionsStack)

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

        footer = securityButton()
        let footerLine = NSStackView(views: [footer])
        footerLine.orientation = .vertical
        footerLine.alignment = .leading
        footerLine.widthAnchor.constraint(equalToConstant: Self.width - Self.padding * 2).isActive = true
        stack.addArrangedSubview(footerLine)
    }

    func rebuild(model: SiteState) {
        self.model = model
        build()
    }

    private var shortOrigin: String {
        let value = model.origin
        if let url = URL(string: value), let host = url.host { return host }
        return value.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    private func actionButton(title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage(), target: self, action: action)
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = .systemFont(ofSize: 13)
        button.imageHugsTitle = true
        button.setAccessibilityLabel(title)
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
            popup.selectItem(at: row.allowed.firstIndex(where: { $0 == row.current }) ?? 0)
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

    private func securityButton() -> NSButton {
        let button = NSButton(title: model.securityTitle, image: NSImage(systemSymbolName: model.securitySymbol, accessibilityDescription: model.securityTitle) ?? NSImage(), target: self, action: #selector(openCertificate))
        button.isBordered = false
        button.bezelStyle = .inline
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.font = .systemFont(ofSize: 12)
        button.imageHugsTitle = true
        button.isEnabled = model.canShowCertificate
        button.contentTintColor = model.security == "secure" ? .secondaryLabelColor : .systemOrange
        button.toolTip = model.canShowCertificate ? "Show certificate" : "No certificate for this page"
        button.setAccessibilityLabel(model.securityTitle)
        button.setAccessibilityHelp(button.toolTip ?? "")
        return button
    }

    @objc private func captureRegion() { onCaptureRegion?() }
    @objc private func captureFullPage() { onCaptureFullPage?() }
    @objc private func openCertificate() { onCertificate?() }

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
        return onPermission?(request) ?? false
    }

    func checkClickFooter() -> Bool {
        guard footer.isEnabled else { return false }
        footer.performClick(nil)
        return true
    }

    func checkClickAction(_ title: String) -> Bool {
        guard let button = actions.first(where: { $0.title == title }) else { return false }
        button.performClick(nil)
        return true
    }

    /// Every control a keyboard or screen reader reaches names itself and its value.
    var checkLabelsComplete: Bool {
        !actions.isEmpty && actions.allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty == false }
            && rows.allSatisfy { ($0.control.accessibilityLabel() ?? "").isEmpty == false }
            && (footer.accessibilityLabel() ?? "").isEmpty == false
    }

    override var isFlipped: Bool { true }
}
