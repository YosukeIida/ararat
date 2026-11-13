import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U27h: one Little Window: a page-only popup host with our bar above the page, the profile
/// menu, the address, Copy Link, Extensions, and Open in <space> ⌘O. The page is not a
/// workspace row; Open in moves it into a space as a Today tab with its contents (the §4.6
/// handoff) and closes this window.
@MainActor
final class LittleWindowController: NSObject, NSPopoverDelegate {
    let popup: PopupHost
    weak var origin: Runtime?
    let profileName: String
    let initialURL: String?
    let bar = LittleWindowBarView()
    private(set) var model = LittleWindowBarModel()
    private var defaultSpaceID: String?
    private var opening = false
    private var profilePopover: NSPopover?
    private var spacePopover: NSPopover?
    private var profilePanel: LittleWindowMenuPanel?
    private var spacePanel: LittleWindowMenuPanel?
    private var presenter: CommandBarPresenter?
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []
    private var frameSaveGeneration = 0
    private var lastShownSpace: String?
    private let toast = LittleWindowToastView()
    private var toastGeneration = 0
    // The check's record: which actions ran and how the bar looked at each step.
    private(set) var checkActions: [String: Int] = [:]
    private(set) var checkOpenedIn: (space: String, item: String)?
    private(set) var checkHandoffLive: String?
    private(set) var checkHandoffNavigationCount: UInt = 0

    init(popup: PopupHost, origin: Runtime, profile: String, frame: NSRect, url: String?) {
        self.popup = popup
        self.origin = origin
        self.profileName = profile
        self.initialURL = url
        super.init()
        popup.littleWindow = self
        installBar(frame: frame)
        refreshModel()
        refreshDefaultDestination()
        installKeyMonitor()
        observeWindow()
    }

    var window: NSWindow? { popup.host?.window() }
    private var pageTab: (any ARTabAPI)? { (popup.host?.tabs() as? [any ARTabAPI])?.first }

    // MARK: - Layout

    private func installBar(frame: NSRect) {
        guard let host = popup.host else { return }
        let window = host.window()
        popup.rootView.addSubview(bar)
        popup.card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: popup.rootView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: popup.rootView.trailingAnchor),
            bar.topAnchor.constraint(equalTo: popup.rootView.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: LittleWindowMetrics.barHeight),
            popup.card.leadingAnchor.constraint(equalTo: popup.rootView.leadingAnchor),
            popup.card.trailingAnchor.constraint(equalTo: popup.rootView.trailingAnchor),
            popup.card.bottomAnchor.constraint(equalTo: popup.rootView.bottomAnchor),
            popup.card.topAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        popup.rootView.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: popup.card.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: popup.card.bottomAnchor, constant: -16),
            toast.widthAnchor.constraint(lessThanOrEqualTo: popup.card.widthAnchor, constant: -32),
        ])
        toast.isHidden = true

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Little Window"
        window.minSize = LittleWindowMetrics.minimumSize
        popup.rootView.wantsLayer = true
        popup.rootView.layer?.cornerRadius = LittleWindowMetrics.contentRadius
        popup.rootView.layer?.masksToBounds = true
        let target = Self.clampedFrame(frame.size.width > 0 && frame.size.height > 0 ? frame : Self.defaultFrame())
        window.setFrame(target, display: false)

        bar.onProfile = { [weak self] in self?.showProfileMenu() }
        bar.onCopy = { [weak self] in self?.copyLink() }
        bar.onExtensions = { [weak self] in self?.showExtensions() }
        bar.onOpen = { [weak self] in self?.performOpenIn() }
        bar.onChooseSpace = { [weak self] in self?.showSpaceMenu() }
        bar.model = model
    }

    static func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = LittleWindowMetrics.defaultSize
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func clampedFrame(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        let screen = screens.first(where: { $0.visibleFrame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(frame.width, LittleWindowMetrics.minimumSize.width), screen.width)
        let height = min(max(frame.height, LittleWindowMetrics.minimumSize.height), screen.height)
        let x = min(max(frame.minX, screen.minX), screen.maxX - width)
        let y = min(max(frame.minY, screen.minY), screen.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - State

    /// Rebuilds the bar's model from the origin window's snapshot and the page's live tab.
    func refreshModel() {
        guard let origin, origin.hasUsableHost, popup.host != nil else { return }
        let snapshot = origin.snapshot
        var profiles: [String] = []
        for space in snapshot.spaces where !profiles.contains(space.profileName) { profiles.append(space.profileName) }
        if !profiles.contains(profileName) { profiles.append(profileName) }
        let spaces = snapshot.spaces.filter { $0.profileName == profileName }
            .map { LittleWindowDestination(id: $0.id, title: $0.title) }
        var next = model
        next.profileName = profileName
        next.profiles = profiles
        next.spaces = spaces
        next.defaultSpaceID = defaultSpaceID
        next.pageURL = pageTab?.url
        model = next
        bar.model = next
    }

    func refreshDefaultDestination() {
        origin?.workspace?.recentSpace(profile: profileName) { [weak self] result in
            guard let self else { return }
            if case .success(let space) = result { self.defaultSpaceID = space }
            self.refreshModel()
        }
    }

    /// The origin window's shown space changed: the default destination follows it when it is
    /// a space of this Little Window's profile. Every snapshot refreshes the model so a space
    /// created or deleted while the Little Window is open shows in the ⌄ menu.
    func originSnapshotChanged(_ snapshot: WorkspaceSnapshot) {
        if let shown = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
           shown.id != lastShownSpace {
            lastShownSpace = shown.id
            if shown.profileName == profileName { defaultSpaceID = shown.id }
        }
        refreshModel()
    }

    func update() {
        refreshModel()
    }

    // MARK: - Actions

    private func copyLink() {
        guard let url = pageTab?.url, !url.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        checkActions["copy", default: 0] += 1
        showToast("Link copied")
    }

    func showToast(_ message: String) {
        toastGeneration += 1
        let generation = toastGeneration
        toast.show(message)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.toastGeneration == generation else { return }
            self.toast.hide()
        }
    }

    var checkToastVisible: Bool { !toast.isHidden }
    var checkToastMessage: String { toast.message }

    /// The profile menu: every profile of the workspace, the current one checked. Choosing
    /// another profile reopens the page in it, because a popup hosts one profile's Browser.
    func showProfileMenu() {
        guard let origin, origin.hasUsableHost else { return }
        profilePopover?.performClose(nil)
        let panel = LittleWindowMenuPanel(width: LittleWindowMetrics.profileMenuWidth,
                                          rows: model.profiles.map { .init(id: $0, title: $0, selected: $0 == profileName) },
                                          showsSearch: false)
        panel.onSelect = { [weak self] name in
            self?.profilePopover?.performClose(nil)
            self?.checkActions["profile_select", default: 0] += 1
            guard let self, name != self.profileName else { return }
            self.reopenInProfile(name)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = Self.panelController(panel)
        popover.contentSize = NSSize(width: LittleWindowMetrics.profileMenuWidth, height: panel.checkHeight)
        let frame = bar.checkProfileFrame
        popover.show(relativeTo: bar.convert(frame, to: popup.rootView), of: popup.rootView, preferredEdge: .minY)
        profilePopover = popover
        profilePanel = panel
    }

    /// The space menu: a search field and every space of the profile (no Most Recent item).
    /// Choosing a row opens this page in that space for this page only.
    func showSpaceMenu() {
        spacePopover?.performClose(nil)
        model.search = ""
        let panel = LittleWindowMenuPanel(width: LittleWindowMetrics.menuWidth,
                                          rows: model.filteredSpaces.map { .init(id: $0.id, title: $0.title, selected: $0.id == model.destination?.id) },
                                          showsSearch: true)
        panel.onSearch = { [weak self] text in
            guard let self else { return }
            self.model.search = text
            self.spacePanel?.rows = self.model.filteredSpaces.map { .init(id: $0.id, title: $0.title, selected: $0.id == self.model.destination?.id) }
            if let spacePanel = self.spacePanel, let popover = self.spacePopover {
                popover.contentSize = NSSize(width: LittleWindowMetrics.menuWidth, height: spacePanel.checkHeight)
            }
        }
        panel.onSelect = { [weak self] id in
            self?.spacePopover?.performClose(nil)
            self?.checkActions["space_select", default: 0] += 1
            self?.performOpenIn(spaceID: id)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = Self.panelController(panel)
        popover.contentSize = NSSize(width: LittleWindowMetrics.menuWidth, height: panel.checkHeight)
        let frame = bar.checkChevronFrame
        popover.show(relativeTo: bar.convert(frame, to: popup.rootView), of: popup.rootView, preferredEdge: .minY)
        spacePopover = popover
        spacePanel = panel
    }

    private static func panelController(_ view: NSView) -> NSViewController {
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    var checkProfilePanel: LittleWindowMenuPanel? { profilePopover?.isShown == true ? profilePanel : nil }
    var checkSpacePanel: LittleWindowMenuPanel? { spacePopover?.isShown == true ? spacePanel : nil }

    func closeMenus() {
        profilePopover?.performClose(nil)
        spacePopover?.performClose(nil)
        extensionPopover?.performClose(nil)
    }

    /// Copy Link's Extensions button opens the sidebar's extension-action overflow (O2): the
    /// same 32 pt tiles with the same Pin/Manage/Remove menu, in a popover anchored here.
    func showExtensions() {
        guard let host = popup.host else { return }
        let items = host.extensionActions(withIconSize: 16).compactMap(ExtensionActionItem.init)
        let panel = LittleWindowExtensionsPanel(items: items)
        panel.onOpen = { [weak self] item, button in
            guard let self else { return }
            let anchor = button.anchorInWindow
            host.setExtensionAnchor(anchor)
            host.runExtensionAction(item.id)
            self.checkActions["extension_action", default: 0] += 1
        }
        panel.onMenu = { [weak self] item, button in
            host.setExtensionAnchor(button.anchorInWindow)
            return self?.extensionMenu(item)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = Self.panelController(panel)
        popover.contentSize = NSSize(width: panel.checkWidth, height: panel.checkHeight)
        popover.show(relativeTo: bar.convert(bar.checkExtensionsFrame, to: popup.rootView), of: popup.rootView, preferredEdge: .minY)
        extensionPopover = popover
        extensionPanel = panel
        checkActions["extensions", default: 0] += 1
    }

    private var extensionPopover: NSPopover?
    private var extensionPanel: LittleWindowExtensionsPanel?
    var checkExtensionPanel: LittleWindowExtensionsPanel? { extensionPopover?.isShown == true ? extensionPanel : nil }

    private func extensionMenu(_ item: ExtensionActionItem) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let pin = NSMenuItem(title: item.pinned ? "Unpin" : "Pin", action: #selector(menuPinExtension(_:)), keyEquivalent: "")
        pin.target = self
        pin.representedObject = item.id
        pin.isEnabled = item.pinMutable
        menu.addItem(pin)
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Extension", action: #selector(menuManageExtension(_:)), keyEquivalent: "")
        manage.target = self
        manage.representedObject = item.id
        manage.isEnabled = popup.host?.extensionManagementURL(item.id) != nil
        menu.addItem(manage)
        let remove = NSMenuItem(title: "Remove…", action: #selector(menuRemoveExtension(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = item.id
        remove.isEnabled = item.removable
        menu.addItem(remove)
        return menu
    }

    @objc private func menuPinExtension(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let item = (popup.host?.extensionActions(withIconSize: 16).compactMap(ExtensionActionItem.init) ?? []).first(where: { $0.id == id }) else { return }
        _ = popup.host?.setExtensionPinned(id, pinned: !item.pinned)
    }

    @objc private func menuManageExtension(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let url = popup.host?.extensionManagementURL(id) else { return }
        navigate(to: url)
    }

    @objc private func menuRemoveExtension(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        popup.host?.removeExtension(id) { _, _ in }
    }

    /// Open in <space>: the page moves into that space as a Today tab with its contents (the
    /// §4.6 handoff, not a reload) and the Little Window closes.
    func performOpenIn(spaceID: String? = nil) {
        guard !opening, let origin, origin.hasUsableHost,
              let space = spaceID.flatMap({ id in model.spaces.first { $0.id == id } }) ?? model.destination,
              let tab = pageTab, model.openEnabled else { return }
        let url = tab.url
        guard !url.isEmpty else { return }
        opening = true
        checkActions["open", default: 0] += 1
        checkHandoffLive = tab.liveId
        checkHandoffNavigationCount = tab.navigationCount
        let deadline = DispatchTime.now() + 10
        // L1: a refused handoff leaves the Little Window open, so the tab must go back to the
        // item id it had (a page-only tab has none) rather than report the closed row.
        let previousItem = tab.itemId
        func fail() {
            opening = false
            FileHandle.standardError.write(Data("ararat-trace: little-window open-in failed space=\(space.id)\n".utf8))
        }
        origin.switchWorkspaceSpace(space.id) { [weak self, weak origin] in
            guard let self, let origin, origin.hasUsableHost, let adapter = origin.workspace else { fail(); return }
            adapter.createTab(url: url) { [weak self] result in
                guard let self, case .success(let snapshot) = result, let row = snapshot.selectedId else { fail(); return }
                // The row exists; the tab takes it before the move so the destination's strip
                // reports the row instead of the core adopting the page elsewhere.
                tab.itemId = row
                self.handoff(tab: tab, row: row, space: space.id, previousItem: previousItem,
                             deadline: deadline, attempt: 0)
            }
        }
    }

    private func handoff(tab: any ARTabAPI, row: String, space: String, previousItem: String?,
                         deadline: DispatchTime, attempt: Int) {
        guard let origin, origin.hasUsableHost, let host = origin.host else {
            tab.itemId = previousItem
            closeRow(row)
            return
        }
        // The item is set on the tab before the move (see performOpenIn), so the destination's
        // strip reports the row and the core maps the live tab to it.
        if host.handoffTab(tab, activate: true) {
            checkOpenedIn = (space, row)
            checkActions["handoff", default: 0] += 1
            // The popup has no tabs left; Chrome closes it. Closing here makes the order the
            // check sees deterministic.
            DispatchQueue.main.async { [weak self] in self?.close() }
            return
        }
        guard DispatchTime.now() < deadline else {
            tab.itemId = previousItem
            closeRow(row)
            opening = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.handoff(tab: tab, row: row, space: space, previousItem: previousItem,
                          deadline: deadline, attempt: attempt + 1)
        }
    }

    private func closeRow(_ row: String) {
        origin?.workspace?.close(id: row) { _ in }
    }

    // MARK: - Command bar (⌘L)

    /// ⌘L opens the command bar at the bar's width, in Edit URL mode with the page's URL. The
    /// bar's store offers the typed row only: this window has no space to list.
    func openCommandBar() {
        guard let window, popup.host != nil, !opening else { return }
        presenter?.close(restoreFocus: false)
        let presenter = CommandBarPresenter(parent: window, visible: true, bindings: defaultKeyBindings(),
                                            highlight: .selectedContentBackgroundColor,
                                            width: LittleWindowMetrics.commandBarWidth)
        presenter.controller.onCommit = { [weak self] suggestion, mode, _ in
            self?.commit(suggestion, mode: mode)
        }
        self.presenter = presenter
        checkActions["command_bar", default: 0] += 1
        presenter.open(mode: .editURL, prefill: pageTab?.url)
        guard let adapter = origin?.workspace else { return }
        adapter.commandBarSession { result in
            guard case .success(let session) = result else { return }
            presenter.applyStore(LittleWindowCommandStore(session: session))
        }
    }

    private func commit(_ suggestion: Suggestion?, mode: CommandBarMode) {
        guard let suggestion else { return }
        switch suggestion.target {
        case .openUrl(let url), .search(let url): navigate(to: url)
        default: break
        }
    }

    private func navigate(to url: String) {
        guard let host = popup.host, let target = host.navigationTarget() else { return }
        _ = host.navigateURL(url, target: target)
        checkActions["navigate", default: 0] += 1
    }

    var checkCommandBarWidth: CGFloat? { presenter?.panel.frame.width }
    var checkCommandBarOpen: Bool { presenter?.controller.isOpen == true }
    var checkCommandBarFieldText: String? {
        (presenter?.view.field.currentEditor() as? NSTextView)?.string ?? presenter?.view.field.stringValue
    }
    func checkTypeCommandBar(_ text: String) {
        presenter?.controller.update(query: text)
    }
    func checkCommitCommandBar() {
        presenter?.controller.commit(forceNewTab: false)
    }
    var checkCommandBar: CommandBarPresenter? { presenter }

    // MARK: - Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window,
                  event.window === window || event.window === self.presenter?.panel else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), !flags.contains(.control) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "o":
                self.performOpenIn()
                return nil
            case "l":
                self.openCommandBar()
                return nil
            default:
                return event
            }
        }
    }

    // MARK: - Frame

    private func observeWindow() {
        guard let window else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveFrame()
                self.removeKeyMonitor()
                self.origin?.littleWindows.removeAll { $0 === self }
            }
        }
        for name in [NSWindow.didEndLiveResizeNotification, NSWindow.didMoveNotification] {
            moveObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveFrame(debounced: true) }
            })
        }
    }

    func saveFrame(debounced: Bool = false) {
        guard let window, let adapter = origin?.workspace else { return }
        frameSaveGeneration += 1
        let generation = frameSaveGeneration
        let frame = window.frame
        let write: () -> Void = { [weak self] in
            guard let self, self.frameSaveGeneration == generation else { return }
            adapter.setLittleWindowFrame(LittleWindowFrame(x: frame.minX, y: frame.minY,
                                                           width: frame.width, height: frame.height))
        }
        if debounced { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: write) } else { write() }
    }

    // MARK: - Closing

    func close() {
        saveFrame()
        removeKeyMonitor()
        if let host = popup.host, !host.isClosing(), !host.isClosingAll() { host.close() }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        presenter?.close(restoreFocus: false)
        profilePopover?.performClose(nil)
        spacePopover?.performClose(nil)
        extensionPopover?.performClose(nil)
    }

    /// The profile menu's switch: a popup hosts one profile's Browser, so the page reopens in
    /// the chosen profile at the same frame and URL. The old window stays until the new one
    /// exists (M1): `openLittleWindow` hands this controller to the create_host callback as the
    /// one to close, so a refused open loses nothing.
    private func reopenInProfile(_ name: String) {
        guard let origin, origin.hasUsableHost, let window else { return }
        let frame = window.frame
        let url = pageTab?.url ?? initialURL
        saveFrame()
        origin.openLittleWindow(url: url, profile: name, frame: frame, replacing: self)
    }
}

/// The typed row only: a Little Window has no space, so its command bar offers no tabs,
/// history or commands, just the address or the search for what was typed.
@MainActor
final class LittleWindowCommandStore: CommandBarStore {
    private let session: CommandBarSession
    init(session: CommandBarSession) { self.session = session }
    func query(_ text: String, history: [HistoryEntry]) -> CommandBarResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CommandBarResult(rows: [], privateWindow: false)
        }
        var result = session.query(text: text, history: [])
        result.rows = Array(result.rows.prefix(1))
        return result
    }
    func searchURL(_ text: String) -> String { session.searchUrl(text: text) }
}

/// The Link copied toast: the board's 36 pt dark bar at the bottom centre of the page.
@MainActor
final class LittleWindowToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private(set) var message = ""

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = LittleWindowMetrics.toastBackground.cgColor
        layer?.cornerRadius = LittleWindowMetrics.toastRadius
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: LittleWindowMetrics.toastHeight).isActive = true
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("Toast")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ text: String) {
        message = text
        label.stringValue = text
        setAccessibilityValue(text)
        isHidden = false
        alphaValue = 1
    }

    func hide() {
        isHidden = true
    }
}

/// The Extensions button's overflow: the sidebar's 32 pt action tiles in a popover (O2).
@MainActor
final class LittleWindowExtensionsPanel: NSView {
    private let row = ExtensionActionsRow()
    var onOpen: ((ExtensionActionItem, ExtensionActionButton) -> Void)? {
        didSet { row.onOpen = { [weak self] item, button in self?.onOpen?(item, button) } }
    }
    var onMenu: ((ExtensionActionItem, ExtensionActionButton) -> NSMenu?)? {
        didSet { row.onMenu = { [weak self] item, button in self?.onMenu?(item, button) } }
    }

    init(items: [ExtensionActionItem]) {
        super.init(frame: NSRect(x: 0, y: 0, width: 152, height: 44))
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            row.heightAnchor.constraint(equalToConstant: 32),
        ])
        row.update(items: items)
        row.columns = 4
        setAccessibilityLabel("Extensions")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var checkWidth: CGFloat { 152 }
    var checkHeight: CGFloat { 44 }
    var checkItems: [String] { row.items.map(\.id) }
    func checkClick(_ id: String) {
        guard let button = row.checkButton(id), let item = row.items.first(where: { $0.id == id }) else { return }
        onOpen?(item, button)
    }
}
