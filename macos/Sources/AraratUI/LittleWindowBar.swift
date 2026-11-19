import AppKit
import AraratKit

/// U27h: the Little Window's bar and its two menus. Values from the D-LittleWindow board
/// (colours, radii, the 28 pt buttons, the 8 pt dot) with the design's structural step rule:
/// the bar is 48 pt tall (the board's 46 is not an Arc measurement) and the ⌘L command bar is
/// 504 pt wide (the board's 500).
@MainActor
public enum LittleWindowMetrics {
    public static let barHeight: CGFloat = 48
    public static let defaultSize = NSSize(width: 640, height: 400)
    public static let minimumSize = NSSize(width: 480, height: 320)
    public static let commandBarWidth: CGFloat = 504
    /// The traffic lights occupy the leading corner; the board starts the profile chip at 84
    /// after them, which the step rule rounds to 80.
    public static let profileInset: CGFloat = 80
    public static let addressGap: CGFloat = 10
    public static let trailingInset: CGFloat = 8
    public static let buttonSize: CGFloat = 28
    public static let buttonRadius: CGFloat = 8
    public static let openRadius: CGFloat = 7
    public static let barBackground = NSColor(srgbRed: 0x23 / 255, green: 0x23 / 255, blue: 0x27 / 255, alpha: 1)
    public static let barText = NSColor(srgbRed: 0xEB / 255, green: 0xEB / 255, blue: 0xEB / 255, alpha: 1)
    public static let barSecondaryText = NSColor(srgbRed: 0xEB / 255, green: 0xEB / 255, blue: 0xEB / 255, alpha: 0.7)
    public static let buttonFill = NSColor(white: 1, alpha: 0.12)
    public static let buttonHoverFill = NSColor(white: 1, alpha: 0.2)
    public static let buttonPressedFill = NSColor(white: 1, alpha: 0.3)
    public static let disabledFill = NSColor(white: 1, alpha: 0.07)
    public static let disabledText = NSColor(srgbRed: 235 / 255, green: 235 / 255, blue: 235 / 255, alpha: 0.4)
    public static let hairline = NSColor(white: 1, alpha: 0.08)
    public static let contentRadius: CGFloat = 10
    public static let toastHeight: CGFloat = 36
    public static let toastRadius: CGFloat = 11
    public static let toastBackground = NSColor(srgbRed: 0x2B / 255, green: 0x2B / 255, blue: 0x30 / 255, alpha: 1)
    public static let menuWidth: CGFloat = 210
    public static let profileMenuWidth: CGFloat = 200
    public static let menuRowHeight: CGFloat = 24
    public static let menuRowRadius: CGFloat = 5
    public static let menuInset: CGFloat = 5
    public static let menuSearchHeight: CGFloat = 26
    public static let menuBackground = NSColor(srgbRed: 0.172, green: 0.172, blue: 0.188, alpha: 1)
}

/// One destination in the Little Window's Open-in menus.
public struct LittleWindowDestination: Equatable, Identifiable {
    public let id: String
    public let title: String
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// The bar's state as one value: what the profile chip, the address, the buttons and the two
/// menus show. The controller builds it from the origin window's snapshot and the page's live
/// tab; the tests read it without a window.
public struct LittleWindowBarModel: Equatable {
    /// The profile the page opened in, by directory name ("Default" for the default profile).
    public var profileName: String = ""
    /// Every profile the workspace has, in snapshot order, for the chip's menu.
    public var profiles: [String] = []
    /// The profile's spaces, in sidebar order.
    public var spaces: [LittleWindowDestination] = []
    /// The most recent space of the profile: the default destination until U27i adds the setting.
    public var defaultSpaceID: String?
    /// The live tab's URL; nil when the Little Window has no page.
    public var pageURL: String?
    /// What is typed into the space menu's search field.
    public var search: String = ""

    public init() {}

    /// The destination ⌘O opens in: the stored default, else the profile's first space.
    public var destination: LittleWindowDestination? {
        spaces.first { $0.id == defaultSpaceID } ?? spaces.first
    }

    /// U27i D9: a stored default that names a space of this profile, or nil so the caller asks
    /// the core for the profile's most recent space (the built-in value and the fallback for a
    /// named space of another profile or a deleted one).
    public static func namedDestination(_ openIn: LittleWindowOpenIn, spaces: [LittleWindowDestination]) -> String? {
        guard case .space(let id) = openIn, spaces.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    public var openInTitle: String {
        destination.map { "Open in \($0.title)" } ?? "Open in"
    }

    /// No page, no space or no destination leaves Open disabled (the bar still shows it). A
    /// page that is the placeholder (about:blank, the new-tab page) has nothing to open yet.
    public var openEnabled: Bool {
        guard destination != nil else { return false }
        return !address.showsPlaceholder && !address.text.isEmpty
    }

    /// The space menu's rows after its search field: every space of the profile, no Most Recent.
    public var filteredSpaces: [LittleWindowDestination] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return spaces }
        return spaces.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    /// The address follows URLFieldContent's rule, the same one the sidebar's field uses.
    public var address: URLFieldContent {
        URLFieldContent(url: pageURL, hasTab: pageURL != nil)
    }

    public var addressText: String {
        address.showsPlaceholder ? URLFieldContent.placeholderText : address.text
    }

    public var copyEnabled: Bool { address.canCopy }
}

/// The profile chip: the board's 8 pt dot, the profile's name and a chevron, in one 28 pt
/// button with the bar's dark fills.
@MainActor
final class LittleWindowProfileChip: NSButton {
    private let dot = NSView()
    private let name = NSTextField(labelWithString: "Default")
    private let chevron = NSImageView()
    private var hovering = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = LittleWindowMetrics.buttonRadius
        target = self
        action = #selector(clicked(_:))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: LittleWindowMetrics.buttonSize).isActive = true

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(srgbRed: 0x5A / 255, green: 0xA7 / 255, blue: 0xE8 / 255, alpha: 1).cgColor
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.textColor = LittleWindowMetrics.barText
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.contentTintColor = LittleWindowMetrics.barSecondaryText
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            name.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 4),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setName(_ value: String) { name.stringValue = value }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
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

    @objc private func clicked(_ sender: Any?) {}

    private func updateFill() {
        layer?.backgroundColor = (pressed ? LittleWindowMetrics.buttonPressedFill
            : hovering ? LittleWindowMetrics.buttonHoverFill
            : LittleWindowMetrics.buttonFill).cgColor
    }
}

/// A bar button with the board's dark fills and hover/pressed states. Text buttons draw a
/// label (and a trailing keycap); icon buttons draw an SF Symbol.
@MainActor
final class LittleWindowBarButton: NSButton {
    enum Style { case icon, text, chevron }

    let style: Style
    private var hovering = false
    private(set) var pressed = false
    private var tracking: NSTrackingArea?
    private let label = NSTextField(labelWithString: "")
    private let caps = NSTextField(labelWithString: "⌘O")

    init(style: Style, symbol: String?, title: String = "", caps: String? = nil) {
        self.style = style
        super.init(frame: .zero)
        self.title = ""
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = style == .text ? LittleWindowMetrics.openRadius : LittleWindowMetrics.buttonRadius
        target = self
        action = #selector(clicked(_:))
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: LittleWindowMetrics.buttonSize).isActive = true
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title.isEmpty ? nil : title)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
            imagePosition = .imageOnly
        }
        if style == .text {
            label.stringValue = title
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = LittleWindowMetrics.barText
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            ])
            var trailing = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
            if let caps {
                self.caps.stringValue = caps
                self.caps.font = .systemFont(ofSize: 12, weight: .regular)
                self.caps.textColor = LittleWindowMetrics.barSecondaryText
                self.caps.translatesAutoresizingMaskIntoConstraints = false
                addSubview(self.caps)
                NSLayoutConstraint.activate([
                    self.caps.centerYAnchor.constraint(equalTo: centerYAnchor),
                    self.caps.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 5),
                ])
                trailing.isActive = false
                trailing = self.caps.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
            }
            trailing.isActive = true
        } else {
            widthAnchor.constraint(equalToConstant: style == .chevron ? 24 : LittleWindowMetrics.buttonSize).isActive = true
        }
        updateFill()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
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

    @objc private func clicked(_ sender: Any?) {}

    var checkPressed: Bool { pressed }

    func setTitle(_ title: String) {
        label.stringValue = title
    }

    func updateFill() {
        guard let layer else { return }
        if !isEnabled {
            layer.backgroundColor = LittleWindowMetrics.disabledFill.cgColor
            label.textColor = LittleWindowMetrics.disabledText
            caps.textColor = LittleWindowMetrics.disabledText
            return
        }
        layer.backgroundColor = (pressed ? LittleWindowMetrics.buttonPressedFill
            : hovering ? LittleWindowMetrics.buttonHoverFill
            : style == .icon ? NSColor.clear : LittleWindowMetrics.buttonFill).cgColor
        label.textColor = LittleWindowMetrics.barText
        caps.textColor = LittleWindowMetrics.barSecondaryText
    }

    override var isEnabled: Bool {
        didSet { updateFill() }
    }
}

/// The bar itself: the profile chip and its menu, the address, Copy Link, Extensions, and the
/// Open-in pair. It draws nothing outside its own 48 pt band.
@MainActor
public final class LittleWindowBarView: NSView {
    public var onProfile: (() -> Void)?
    public var onCopy: (() -> Void)?
    public var onExtensions: (() -> Void)?
    public var onOpen: (() -> Void)?
    public var onChooseSpace: (() -> Void)?

    public var model = LittleWindowBarModel() {
        didSet { if model != oldValue { apply() } }
    }

    private let profileButton = LittleWindowProfileChip()
    private let glyph = NSImageView()
    private let address = NSTextField(labelWithString: "")
    private let copyButton = LittleWindowBarButton(style: .icon, symbol: "link", title: "Copy Link")
    private let extensionsButton = LittleWindowBarButton(style: .icon, symbol: "square.grid.2x2", title: "Extensions")
    private let openButton = LittleWindowBarButton(style: .text, symbol: nil, title: "Open in", caps: "⌘O")
    private let chevronButton = LittleWindowBarButton(style: .chevron, symbol: "chevron.down", title: "Choose a space")
    private var windowDrag: WindowDrag.Held?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = LittleWindowMetrics.barBackground.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSView()
        hairline.wantsLayer = true
        hairline.layer?.backgroundColor = LittleWindowMetrics.hairline.cgColor
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        // The profile chip: the board's 8 pt dot, the profile's name and a chevron.
        profileButton.target = self
        profileButton.action = #selector(profileClicked(_:))
        profileButton.setAccessibilityLabel("Profile")
        addSubview(profileButton)

        address.font = .systemFont(ofSize: 13)
        address.textColor = LittleWindowMetrics.barText
        address.alignment = .left
        address.lineBreakMode = .byTruncatingTail
        address.translatesAutoresizingMaskIntoConstraints = false
        address.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        glyph.contentTintColor = LittleWindowMetrics.barSecondaryText
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(address)

        copyButton.target = self
        copyButton.action = #selector(copyClicked(_:))
        copyButton.setAccessibilityLabel("Copy Link")
        copyButton.toolTip = "Copy Link"
        addSubview(copyButton)
        extensionsButton.target = self
        extensionsButton.action = #selector(extensionsClicked(_:))
        extensionsButton.setAccessibilityLabel("Extensions")
        extensionsButton.toolTip = "Extensions"
        addSubview(extensionsButton)
        openButton.target = self
        openButton.action = #selector(openClicked(_:))
        openButton.setAccessibilityLabel("Open in")
        addSubview(openButton)
        chevronButton.target = self
        chevronButton.action = #selector(spaceClicked(_:))
        chevronButton.setAccessibilityLabel("Choose a space")
        chevronButton.toolTip = "Choose a space"
        addSubview(chevronButton)

        NSLayoutConstraint.activate([
            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),

            profileButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: LittleWindowMetrics.profileInset),
            profileButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -LittleWindowMetrics.trailingInset),
            chevronButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            openButton.trailingAnchor.constraint(equalTo: chevronButton.leadingAnchor, constant: -1),
            openButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            extensionsButton.trailingAnchor.constraint(equalTo: openButton.leadingAnchor, constant: -8),
            extensionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: extensionsButton.leadingAnchor, constant: -4),
            copyButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.heightAnchor.constraint(equalToConstant: 12),
            glyph.leadingAnchor.constraint(equalTo: profileButton.trailingAnchor, constant: LittleWindowMetrics.addressGap),
            address.centerYAnchor.constraint(equalTo: centerYAnchor),
            address.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -16),
            glyph.trailingAnchor.constraint(equalTo: address.leadingAnchor, constant: -6),
        ])
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === address || target === glyph ? self : target
    }

    public override func mouseDown(with event: NSEvent) {
        windowDrag = WindowDrag.Held(in: self, with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        windowDrag?.dragged(to: WindowDrag.screenPoint(of: event, in: self))
    }

    public override func mouseUp(with event: NSEvent) {
        windowDrag?.released(at: WindowDrag.screenPoint(of: event, in: self))
        windowDrag = nil
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // AppKit's title-strip drag must not run beside WindowDrag's stored-press drag.
    public override var mouseDownCanMoveWindow: Bool { false }

    public var checkBarFrame: NSRect { frame }
    public var checkProfileTitle: String { model.profileName }
    public var checkAddressText: String { address.stringValue }
    public var checkAddressPlaceholder: Bool { model.address.showsPlaceholder }
    public var checkOpenTitle: String { model.openInTitle }
    public var checkOpenEnabled: Bool { openButton.isEnabled }
    public var checkCopyEnabled: Bool { copyButton.isEnabled }
    public var checkExtensionsEnabled: Bool { extensionsButton.isEnabled }
    public var checkButtonFrames: [String: NSRect] {
        ["profile": profileButton.frame, "copy": copyButton.frame, "extensions": extensionsButton.frame,
         "open": openButton.frame, "chevron": chevronButton.frame, "address": address.frame, "glyph": glyph.frame]
    }
    public var checkOpenFrame: NSRect { openButton.frame }
    public var checkChevronFrame: NSRect { chevronButton.frame }
    public var checkProfileFrame: NSRect { profileButton.frame }
    public var checkCopyFrame: NSRect { copyButton.frame }
    public var checkExtensionsFrame: NSRect { extensionsButton.frame }

    public func checkClickProfile() { profileButton.performClick(nil) }
    public func checkClickCopy() { copyButton.performClick(nil) }
    public func checkClickExtensions() { extensionsButton.performClick(nil) }
    public func checkClickOpen() { openButton.performClick(nil) }
    public func checkClickChevron() { chevronButton.performClick(nil) }

    private func apply() {
        profileButton.setName(model.profileName)
        address.stringValue = model.addressText
        address.textColor = model.address.showsPlaceholder ? LittleWindowMetrics.barSecondaryText : LittleWindowMetrics.barText
        glyph.image = NSImage(systemSymbolName: model.address.showsGear ? "gearshape" : "lock",
                              accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 10, weight: .regular))
        openButton.setTitle(model.openInTitle)
        openButton.isEnabled = model.openEnabled
        copyButton.isEnabled = model.copyEnabled
        extensionsButton.isEnabled = true
        setAccessibilityLabel("Little Window bar")
        profileButton.setAccessibilityValue(model.profileName)
        address.setAccessibilityLabel("Address")
        address.setAccessibilityValue(model.addressText)
    }

    @objc private func profileClicked(_ sender: Any?) { onProfile?() }
    @objc private func copyClicked(_ sender: Any?) { onCopy?() }
    @objc private func extensionsClicked(_ sender: Any?) { onExtensions?() }
    @objc private func openClicked(_ sender: Any?) { onOpen?() }
    @objc private func spaceClicked(_ sender: Any?) { onChooseSpace?() }
}

@MainActor
private final class LittleWindowSearchField: NSSearchField {
    override var searchTextBounds: NSRect {
        var rect = super.searchTextBounds
        let trailing = rect.maxX
        rect.origin.x = max(rect.minX, searchButtonBounds.maxX + 4)
        rect.size.width = max(0, trailing - rect.minX)
        return rect
    }
}

/// One row of the profile or space menu: the board's 24 pt item, 5 pt radius, the accent fill
/// on hover, a check mark on the current profile.
@MainActor
public final class LittleWindowMenuPanel: NSView {
    public struct Row: Equatable {
        public let id: String
        public let title: String
        public let selected: Bool
        public init(id: String, title: String, selected: Bool = false) {
            self.id = id
            self.title = title
            self.selected = selected
        }
    }

    public var rows: [Row] = [] { didSet { rebuild() } }
    private let showsSearch: Bool
    public var onSelect: (String) -> Void = { _ in }
    public var onSearch: (String) -> Void = { _ in }
    public private(set) var searchText = ""
    private let stack = NSStackView()
    private let searchField = LittleWindowSearchField()
    private var rowViews: [NSButton] = []
    public override var isFlipped: Bool { true }

    public init(width: CGFloat, rows: [Row], showsSearch: Bool) {
        self.rows = rows
        self.showsSearch = showsSearch
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = LittleWindowMetrics.menuBackground.cgColor
        layer?.cornerRadius = 8

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search spaces"
        searchField.font = .systemFont(ofSize: 12)
        searchField.focusRingType = .none
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendsSearchStringImmediately = true
        searchField.setAccessibilityLabel("Search spaces")
        stack.orientation = .vertical
        stack.spacing = 2
        stack.alignment = .width
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let inset = LittleWindowMetrics.menuInset
        if showsSearch {
            addSubview(searchField)
            NSLayoutConstraint.activate([
                searchField.topAnchor.constraint(equalTo: topAnchor, constant: inset + 1),
                searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset + 1),
                searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset - 1),
                searchField.heightAnchor.constraint(equalToConstant: LittleWindowMetrics.menuSearchHeight),
                stack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 5),
            ])
        } else {
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
        ])
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public var checkRowTitles: [String] { rows.map(\.title) }
    public var checkWidth: CGFloat { frame.width }
    public var checkHeight: CGFloat { frame.height }
    public var checkSearchField: NSSearchField { searchField }

    public func checkTypeSearch(_ text: String) {
        searchText = text
        searchField.stringValue = text
        onSearch(text)
    }

    public func checkClickRow(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }), rowViews.indices.contains(index) else { return }
        rowViews[index].performClick(nil)
    }

    private func rebuild() {
        for view in rowViews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
        rowViews.removeAll()
        for row in rows {
            let button = LittleWindowMenuRowButton(row: row, showsSearch: showsSearch)
            button.target = self
            button.action = #selector(rowClicked(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rowViews.append(button)
        }
        let height = LittleWindowMetrics.menuInset * 2 + (showsSearch ? LittleWindowMetrics.menuSearchHeight + 6 : 0)
            + CGFloat(rows.count) * LittleWindowMetrics.menuRowHeight + CGFloat(max(0, rows.count - 1)) * stack.spacing
        setFrameSize(NSSize(width: frame.width, height: height))
    }

    @objc private func rowClicked(_ sender: LittleWindowMenuRowButton) { onSelect(sender.row.id) }

    @objc private func searchChanged(_ sender: NSSearchField) {
        searchText = sender.stringValue
        onSearch(sender.stringValue)
    }
}

/// A menu row: the check mark on the current profile, the title, the blue hover fill.
@MainActor
private final class LittleWindowMenuRowButton: NSButton {
    let row: LittleWindowMenuPanel.Row
    private let selectedFill: Bool
    private var tracking: NSTrackingArea?
    private static let blue = NSColor(srgbRed: 0x34 / 255, green: 0x78 / 255, blue: 0xF6 / 255, alpha: 1)
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    init(row: LittleWindowMenuPanel.Row, showsSearch: Bool) {
        self.row = row
        selectedFill = showsSearch && row.selected
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        wantsLayer = true
        layer?.cornerRadius = LittleWindowMetrics.menuRowRadius
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: LittleWindowMetrics.menuRowHeight).isActive = true
        title = ""
        let label = NSTextField(labelWithString: row.title)
        label.font = .systemFont(ofSize: 13)
        label.textColor = LittleWindowMetrics.barText
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityHidden(true)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let check = NSTextField(labelWithString: row.selected ? "✓" : "")
        check.textColor = LittleWindowMetrics.barText
        check.setAccessibilityHidden(true)
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateFill()
        setAccessibilityLabel(row.title)
        if row.selected { setAccessibilityValue("Selected") }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        updateFill(hovered: true)
    }

    override func mouseExited(with event: NSEvent) {
        updateFill()
    }

    private func updateFill(hovered: Bool = false) {
        layer?.backgroundColor = (hovered || selectedFill ? Self.blue : .clear).cgColor
    }
}
