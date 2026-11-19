import AppKit
import AraratKit
import Darwin

@MainActor
public final class SidebarHeaderView: NSView {
    public var onCommand: ((String) -> Void)?
    public var siteDomain: (() -> String?)?
    var keyBindings: () -> [KeyBinding] = { defaultKeyBindings() }
    var mainMenu: () -> NSMenu? = { NSApp?.mainMenu }
    weak var menuDelegate: NSMenuDelegate?
    public var canGoBack = false { didSet { back.isEnabled = canGoBack } }
    public var canGoForward = false { didSet { forward.isEnabled = canGoForward } }
    public var loading = false { didSet { updateReload() } }
    public var hasTab = false { didSet { reload.isEnabled = hasTab } }
    /// U27d: the Appearance pane's Tooltips switch, applied to the header's controls. Off, the
    /// buttons keep their tooltips' accessibility help and show no tooltip.
    public var tooltipsShown = true { didSet { tooltip.isEnabled = tooltipsShown } }
    private let sidebar = NSButton()
    private let back = NSButton()
    private let forward = NSButton()
    private let reload = NSButton()
    private let more = NSButton()
    private let tooltip = SidebarTooltip()
    private weak var hoveredButton: NSButton?
    private var pressedCommands: Set<String> = []
    private let commands = ["toggle_sidebar", "back", "forward", "reload", "menu"]
    private var buttons: [NSButton] { [sidebar, back, forward, reload, more] }
    /// The press this view's drag area stored, from its `mouseDown` to its release. The header's
    /// own gaps are the drag area; its buttons keep their clicks.
    private var windowDrag: WindowDrag.Held?
    override public var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        let symbols = ["sidebar.left", "chevron.left", "chevron.right", "arrow.clockwise", "ellipsis"]
        let labels = ["Toggle Sidebar", "Go Back", "Go Forward", "Reload", "More"]
        for (index, button) in buttons.enumerated() {
            let command = commands[index], symbol = symbols[index], label = labels[index]
            button.isBordered = false
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.identifier = NSUserInterfaceItemIdentifier(command)
            button.target = self
            button.action = #selector(pressed(_:))
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            addSubview(button)
        }
        back.isEnabled = false; forward.isEnabled = false; reload.isEnabled = false
        tooltip.explicitCaps = { [weak self] view in
            switch view.identifier?.rawValue {
            case "toggle_sidebar": self?.currentToggleKey.map { SidebarTooltip.caps(for: $0) } ?? []
            case "back": ["⌘", "["]
            case "forward": ["⌘", "]"]
            case "reload": self?.loading == true ? [] : ["⌘", "R"]
            default: nil
            }
        }
        tooltip.capture(in: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    private var currentToggleKey: KeyCombination? {
        keyBindings().first { $0.command == "toggle_sidebar" }?.key
    }

    public var checkControls: [String] { buttons.filter { !$0.isHidden }.compactMap { $0.identifier?.rawValue } }
    public var checkEnabled: [String: Bool] { Dictionary(uniqueKeysWithValues: buttons.compactMap { button in button.identifier.map { ($0.rawValue, button.isEnabled) } }) }
    public var checkReloadLabel: String { reload.accessibilityLabel() ?? "" }
    public func checkTooltip(_ command: String, keep: Bool = false) -> (String?, [String]) {
        guard let button = buttons.first(where: { $0.identifier?.rawValue == command }), window != nil else { return (nil, []) }
        let savedClock = tooltip.clock
        var now: CFTimeInterval = 0
        tooltip.clock = { now }
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        tooltip.dismiss()
        tooltip.update(target: button, point: point)
        now = 2
        tooltip.update(target: button, point: point)
        let result = (tooltip.text, tooltip.keycaps.map(\.stringValue))
        if !keep { tooltip.dismiss() }
        tooltip.clock = savedClock
        return result
    }
    public func checkDismissTooltip() { tooltip.dismiss() }
    public var checkPressedCaps: [String] { tooltip.keycaps.filter(\.pressed).map(\.stringValue) }
    public func checkPressed(_ command: String) -> Bool {
        guard let button = buttons.first(where: { $0.identifier?.rawValue == command }),
              let color = button.layer?.backgroundColor else { return false }
        return color.alpha > 0
    }
    public func checkKeys(_ keys: Set<String>, event: NSEvent) { updateKeys(keys, event: event) }
    /// p4checks: presses one of the header's own buttons, the control the pointer clicks. `menu` is
    /// not a command here: the … button pops a menu, and a menu item is run by `checkPerformMenu`.
    public func checkPress(_ command: String) -> Bool {
        guard let button = buttons.first(where: { $0.identifier?.rawValue == command }),
              command != "menu", button.isEnabled else { return false }
        button.performClick(nil)
        return true
    }
    /// p4checks: runs a menu item's own action, what the open menu's click runs.
    public func checkPerformMenuItem(_ command: String) -> Bool {
        let menu = makeMenu()
        menu.update()
        guard let item = menu.items.first(where: { $0.representedObject as? String == command }), item.isEnabled, let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }
    func clearKeys() {
        tooltip.clearPressed()
        pressedCommands.removeAll()
        updateButtonFills()
    }

    func updateKeys(_ keys: Set<String>, event: NSEvent) {
        tooltip.pressedKeys = keys
        tooltip.flagsChanged(with: event)
        let command = event.modifierFlags.contains(.command)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let togglePressed = currentToggleKey.map {
            flags.contains(.command) == $0.command && flags.contains(.shift) == $0.shift &&
            flags.contains(.control) == $0.control && flags.contains(.option) == $0.option &&
            keys.contains(SidebarTooltip.caps(for: $0).last ?? "")
        } ?? false
        pressedCommands.removeAll()
        for button in buttons {
            let key: String = switch button.identifier?.rawValue {
            case "toggle_sidebar": ""
            case "back": "["
            case "forward": "]"
            case "reload": "R"
            case "menu": reload.isHidden ? "R" : ""
            default: ""
            }
            if let id = button.identifier?.rawValue,
               (id == "toggle_sidebar" && togglePressed || id == "menu" && sidebar.isHidden && togglePressed || command && keys.contains(key)) { pressedCommands.insert(id) }
        }
        updateButtonFills()
    }
    private func updateButtonFills() {
        for button in buttons {
            let pressed = button.identifier.map { pressedCommands.contains($0.rawValue) } ?? false
            button.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(pressed ? 0.18 : hoveredButton === button ? 0.08 : 0).cgColor
        }
    }

    override public func layout() {
        super.layout()
        sidebar.isHidden = bounds.width < 232
        reload.isHidden = bounds.width < 200
        let visible = buttons.filter { !$0.isHidden }
        let start: CGFloat = 80
        for (index, button) in visible.enumerated() {
            let x = button === more ? bounds.width - 28 : start + CGFloat(index) * (sidebar.isHidden ? 28 : 32)
            button.frame = NSRect(x: x, y: 0, width: 24, height: 24)
        }
    }
    private func updateReload() {
        let label = loading ? "Stop" : "Reload"
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: label)
        reload.setAccessibilityLabel(label)
        reload.setAccessibilityHelp(label)
        reload.toolTip = label
        tooltip.capture(in: reload)
    }
    @objc private func pressed(_ sender: NSButton) {
        tooltip.dismiss()
        guard let command = sender.identifier?.rawValue else { return }
        if command == "menu" { showMenu(makeMenu()) }
        else { onCommand?(command == "reload" && loading ? "stop" : command) }
    }
    public func showMenu(_ menu: NSMenu) {
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.minY), in: more)
    }
    public func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = menuDelegate
        let items: [(String, String)] = [("Reload", "reload"), ("Force Reload", "force_reload"), ("Find in Page…", "find"), ("", ""), ("Clear Cache", "clear_cache_site"), ("Clear Cookies", "clear_cookies_site"), ("", ""), ("Toggle Sidebar", "toggle_sidebar"), ("", ""), ("Zoom In", "zoom_in"), ("Zoom Out", "zoom_out"), ("", ""), ("Print…", "print"), ("Settings…", "settings")]
        for (title, command) in items {
            if title.isEmpty { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: title, action: #selector(menuPressed(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command
            if command == "clear_cookies_site", let domain = siteDomain?() {
                let address = domain.hasPrefix("[") && domain.hasSuffix("]") ? String(domain.dropFirst().dropLast()) : domain
                var v4 = in_addr(), v6 = in6_addr()
                let isIP = address.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
                item.toolTip = "Clears cookies for \(domain)" + (isIP ? "" : " and its subdomains")
            }
            if ["clear_cache_site", "clear_cookies_site"].contains(command) { item.isEnabled = hasTab && siteDomain?() != nil }
            else if !["toggle_sidebar", "settings"].contains(command) { item.isEnabled = hasTab }
            menu.addItem(item)
        }
        addShortcutLabels(to: menu)
        menu.autoenablesItems = false
        return menu
    }

    private func addShortcutLabels(to menu: NSMenu) {
        // Chromium's menu tags (chrome/app/chrome_command_ids.h) also work with localized titles.
        let chromeTags = ["reload": 33002, "find": 37000, "zoom_in": 38001, "zoom_out": 38003, "print": 35003]
        func chromeItem(_ tag: Int, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            if let item = menu.item(withTag: tag), !item.isHidden { return item }
            return menu.items.lazy.filter { !$0.isHidden }.compactMap { chromeItem(tag, in: $0.submenu) }.first
        }

        let appMenu = mainMenu()
        let bindings = keyBindings()
        let labels: [(NSMenuItem, String)] = menu.items.compactMap { item in
            guard let command = item.representedObject as? String else { return nil }
            let caps: [String]
            if let tag = chromeTags[command], let source = chromeItem(tag, in: appMenu) {
                caps = SidebarTooltip.keycaps(for: source).map(\.stringValue)
            } else if ["force_reload", "toggle_sidebar", "settings"].contains(command),
                      let key = bindings.first(where: { $0.command == command })?.key {
                caps = SidebarTooltip.caps(for: key)
            } else {
                return nil
            }
            return caps.isEmpty ? nil : (item, caps.joined().replacingOccurrences(of: "-", with: "−"))
        }
        guard !labels.isEmpty else { return }
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 0)]
        let titleWidth = menu.items.map { $0.title.size(withAttributes: font).width }.max() ?? 0
        let shortcutWidth = labels.map { $0.1.size(withAttributes: font).width }.max() ?? 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: ceil(titleWidth + shortcutWidth) + 20)]
        var attributes = font
        attributes[.paragraphStyle] = paragraph
        // A real keyEquivalent could invoke the popup's action while AppKit tracks it.
        for (item, shortcut) in labels {
            item.attributedTitle = NSAttributedString(string: "\(item.title)\t\(shortcut)", attributes: attributes)
        }
    }

    @objc private func menuPressed(_ sender: NSMenuItem) { if let command = sender.representedObject as? String { onCommand?(command) } }
    override public func mouseDown(with event: NSEvent) {
        windowDrag = WindowDrag.Held(in: self, with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        windowDrag?.dragged(to: WindowDrag.screenPoint(of: event, in: self))
    }

    override public func mouseUp(with event: NSEvent) {
        windowDrag?.released(at: WindowDrag.screenPoint(of: event, in: self))
        windowDrag = nil
    }

    /// The press that activates a background window drags it too, as a title bar's does; only the
    /// header's own gaps resolve to this view, never its buttons.
    override public func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // AppKit's title-strip drag must not run beside WindowDrag's stored-press drag.
    override public var mouseDownCanMoveWindow: Bool { false }

    override public func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    override public func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredButton = buttons.first { !$0.isHidden && $0.isEnabled && $0.frame.contains(point) }
        updateButtonFills()
        tooltip.update(target: buttons.first { !$0.isHidden && $0.frame.contains(point) }, point: event.locationInWindow)
    }
    override public func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override public func mouseExited(with event: NSEvent) { hoveredButton = nil; updateButtonFills(); tooltip.update(target: nil, point: nil) }
}
