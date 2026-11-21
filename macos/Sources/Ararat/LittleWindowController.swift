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
    private var pageTransferred = false
    private var archivedOnClose = false
    private var lastPageURL: String?
    private var lastPageTitle = ""
    /// U27i D8/D9: the stored settings this window applies. The pair is synced; "Remember its
    /// size and place" is this device's. They arrive asynchronously before the bar's label and the
    /// window's Open-in action use them.
    private(set) var openIn: LittleWindowOpenIn = .mostRecent
    private(set) var closeAfter = true
    private(set) var rememberFrame = true
    private var profilePopover: NSPopover?
    private var spacePopover: NSPopover?
    private var profilePanel: LittleWindowMenuPanel?
    private var spacePanel: LittleWindowMenuPanel?
    private var presenter: CommandBarPresenter?
    private let commandBarVisible: Bool
    private var keyMonitor: Any?
    private var closeObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []
    private var frameSaveGeneration = 0
    private var lastValidFrame: NSRect?
    private var lastShownSpace: String?
    private let toast = LittleWindowToastView()
    private var toastGeneration = 0
    // The check's record: which actions ran and how the bar looked at each step.
    private(set) var checkActions: [String: Int] = [:]
    private(set) var checkOpenedIn: (space: String, item: String)?
    private(set) var checkHandoffLive: String?
    private(set) var checkHandoffNavigationCount: UInt = 0

    init(popup: PopupHost, origin: Runtime, profile: String, frame: NSRect, url: String?, commandBarVisible: Bool = true) {
        self.popup = popup
        self.origin = origin
        self.profileName = profile
        self.initialURL = url
        self.commandBarVisible = commandBarVisible
        super.init()
        popup.littleWindow = self
        installBar(frame: frame)
        refreshModel()
        refreshDefaultDestination()
        loadSettings()
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
        lastPageURL = pageTab?.url ?? lastPageURL
        lastPageTitle = pageTab?.title ?? lastPageTitle
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
        // D9: a named destination wins when the window's profile can reach that space; a space of
        // another profile or a deleted one falls back to the profile's most recent space.
        if let id = LittleWindowBarModel.namedDestination(openIn, spaces: model.spaces) {
            defaultSpaceID = id
            refreshModel()
            return
        }
        origin?.workspace?.recentSpace(profile: profileName) { [weak self] result in
            guard let self else { return }
            if case .success(let space) = result { self.defaultSpaceID = space }
            self.refreshModel()
        }
    }

    /// Reads the two synced settings and the device record once, then rebuilds the label. A
    /// Little Window opened before the read lands shows the most recent space, which is the
    /// built-in value, and is corrected a moment later.
    private func loadSettings() {
        guard let adapter = origin?.workspace else { return }
        adapter.littleWindowOpenIn { [weak self] result in
            guard let self, case .success(let value) = result else { return }
            self.openIn = value
            self.refreshDefaultDestination()
        }
        adapter.littleWindowCloseAfter { [weak self] result in
            guard let self, case .success(let value) = result else { return }
            self.closeAfter = value
        }
        adapter.littleWindowDevice { [weak self] result in
            guard let self, case .success(let device) = result else { return }
            self.rememberFrame = device.rememberFrame
        }
    }

    /// The origin window's shown space changed: with Most Recent as the destination the default
    /// follows it when it is a space of this Little Window's profile. Every snapshot refreshes the
    /// model so a space created or deleted while the Little Window is open shows in the ⌄ menu.
    func originSnapshotChanged(_ snapshot: WorkspaceSnapshot) {
        if openIn == .mostRecent,
           let shown = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
           shown.id != lastShownSpace {
            lastShownSpace = shown.id
            if shown.profileName == profileName { defaultSpaceID = shown.id }
        }
        // L4: a named destination whose space was deleted while the window is open falls back the
        // way the setting's other misses do (the profile's most recent space), not to its first.
        if case .space = openIn, let id = defaultSpaceID,
           !snapshot.spaces.contains(where: { $0.id == id && $0.profileName == profileName }) {
            refreshDefaultDestination()
        }
        refreshModel()
    }

    /// The settings pane's switches, pushed to a window that is already open (U27i).
    func apply(openIn: LittleWindowOpenIn, rememberFrame: Bool, closeAfter: Bool) {
        let destinationChanged = self.openIn != openIn
        self.rememberFrame = rememberFrame
        self.closeAfter = closeAfter
        if destinationChanged {
            self.openIn = openIn
            refreshDefaultDestination()
        }
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
        popover.animates = origin.browserCheckMode != "screen-little-window"
        popover.appearance = panel.appearance
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
        popover.animates = origin?.browserCheckMode != "screen-little-window"
        popover.appearance = panel.appearance
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
        guard let id = sender.representedObject as? String else { return }
        origin?.manageExtension(id)
    }

    @objc private func menuRemoveExtension(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        popup.host?.removeExtension(id) { _, _ in }
    }

    /// Open in <space>: the page moves into that space as a Today tab with its contents (the
    /// §4.6 handoff, not a reload) and the Little Window closes.
    func performOpenIn(spaceID: String? = nil) {
        guard !opening, let origin, !origin.isPrivateWindow, origin.hasUsableHost,
              let workspace = origin.workspace, let engine = origin.adapter,
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
        func fail(reselectGeneration: Int? = nil) {
            @MainActor func finish() {
                engine.endLittleWindowHandoff(replayKeySelection: false)
                self.opening = false
            }
            FileHandle.standardError.write(Data("ararat-trace: little-window open-in failed space=\(space.id)\n".utf8))
            guard let reselectGeneration, let origin = self.origin, origin.hasUsableHost,
                  origin.selectionGeneration == reselectGeneration,
                  engine.session.queue.sync(execute: { engine.session.store?.snapshot(windowId: origin.windowID).shownSpaceId == space.id })
            else { finish(); return }
            origin.switchWorkspaceSpace(space.id, selectRow: true) { _ in finish() }
        }
        engine.beginLittleWindowHandoff()
        engine.invalidateSelection()
        origin.switchWorkspaceSpace(space.id, selectRow: false) { generation in
            guard let generation else { fail(); return }
            workspace.createTab(url: url, expectedSpace: space.id) { result in
                guard case .success(let created) = result, let row = created.id else {
                    if case .failure(let error) = result, !(error is CancellationError) {
                        fail(reselectGeneration: generation)
                    } else {
                        fail()
                    }
                    return
                }
                FileHandle.standardError.write(Data("ararat-trace: little-window row-created item=\(row) live=\(tab.liveId)\n".utf8))
                // The row exists; the tab takes it before the move so the destination's strip
                // reports the row instead of the core adopting the page elsewhere.
                tab.itemId = row
                self.handoff(tab: tab, row: row, space: space.id, previousItem: previousItem,
                             deadline: deadline, attempt: 0, generation: generation, workspace: workspace, engine: engine)
            }
        }
    }

    private func handoff(tab: any ARTabAPI, row: String, space: String, previousItem: String?,
                         deadline: DispatchTime, attempt: Int, generation: Int,
                         workspace: WorkspaceAdapter, engine: EngineAdapter) {
        func currentDestination() -> Runtime? {
            guard let origin, origin.hasUsableHost, origin.selectionGeneration == generation,
                  origin.host?.profileDirectory() == profileName,
                  engine.session.queue.sync(execute: { engine.session.store?.snapshot(windowId: origin.windowID).shownSpaceId == space })
            else { return nil }
            return origin
        }
        func refuse() {
            tab.itemId = previousItem
            workspace.close(id: row) { result in
                @MainActor func finish() {
                    engine.endLittleWindowHandoff(replayKeySelection: false)
                    self.opening = false
                }
                guard let origin = currentDestination() else { finish(); return }
                if case .failure(let error) = result { origin.report(error); finish(); return }
                origin.switchWorkspaceSpace(space, selectRow: true) { _ in finish() }
            }
        }
        guard let host = currentDestination()?.host,
              let source = popup.host, !source.isClosing(), !source.isClosingAll(),
              pageTab?.liveId == tab.liveId else {
            refuse()
            return
        }
        // The item is set on the tab before the move (see performOpenIn), so the destination's
        // strip reports the row and the core maps the live tab to it.
        if attempt == 0 {
            let mapped = engine.session.queue.sync { engine.session.store?.liveTab(item: row) }
            FileHandle.standardError.write(Data("ararat-trace: little-window handoff-before live=\(tab.liveId) mapped=\(mapped ?? "nil")\n".utf8))
        }
        let live = tab.liveId
        if host.handoffTab(tab, activate: true) {
            pageTransferred = true
            engine.awaitLittleWindowHandoff(item: row, live: live)
            checkOpenedIn = (space, row)
            checkActions["handoff", default: 0] += 1
            // D8: close-after decides the window's fate, not the handoff's. Chrome closes a popup
            // when its last tab leaves; with close-after off the window comes back as the empty
            // start (M3: the page moved, so nothing is requested twice).
            let closeAfter = self.closeAfter
            let frame = window?.frame
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if closeAfter { self.close() }
                else { self.reopenAfterOpenIn(frame: frame) }
            }
            return
        }
        guard DispatchTime.now() < deadline else {
            refuse()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.handoff(tab: tab, row: row, space: space, previousItem: previousItem,
                         deadline: deadline, attempt: attempt + 1, generation: generation, workspace: workspace, engine: engine)
        }
    }

    // MARK: - Command bar (⌘L)

    /// ⌘L opens the command bar at the bar's width, in Edit URL mode with the page's URL. The
    /// bar's store offers the typed row only: this window has no space to list.
    func openCommandBar() {
        guard let window, popup.host != nil, !opening else { return }
        presenter?.close(restoreFocus: false)
        let presenter = CommandBarPresenter(parent: window, visible: commandBarVisible, bindings: defaultKeyBindings(),
                                            highlight: SpaceAccent.teal,
                                            width: LittleWindowMetrics.commandBarWidth)
        presenter.onCommit = { [weak self, weak presenter] suggestion, mode, _ in
            FileHandle.standardError.write(Data("ararat-trace: little-window submit store_ready_at_submission=\(presenter?.controller.storeReadyAtSubmission == true)\n".utf8))
            self?.commit(suggestion, mode: mode)
        }
        self.presenter = presenter
        checkActions["command_bar", default: 0] += 1
        presenter.open(mode: .editURL, prefill: pageTab?.url)
        guard let adapter = origin?.workspace else { return }
        adapter.commandBarSession { [weak self, weak presenter] result in
            guard let self, let presenter, self.presenter === presenter else { return }
            switch result {
            case .success(let session): presenter.applyStore(LittleWindowCommandStore(session: session))
            case .failure(let error):
                self.origin?.report(error)
                presenter.close()
            }
        }
    }

    private func commit(_ suggestion: Suggestion?, mode: CommandBarMode) {
        guard let suggestion else {
            FileHandle.standardError.write(Data("ararat-trace: little-window submit target=none\n".utf8))
            return
        }
        switch suggestion.target {
        case .openUrl(let url):
            FileHandle.standardError.write(Data("ararat-trace: little-window submit target=open-url\n".utf8))
            navigate(to: url)
        case .search(let url):
            FileHandle.standardError.write(Data("ararat-trace: little-window submit target=search\n".utf8))
            navigate(to: url)
        default:
            FileHandle.standardError.write(Data("ararat-trace: little-window submit target=unsupported\n".utf8))
        }
    }

    func navigate(to url: String) {
        let host = popup.host
        let accepted = host?.navigateLittleWindow(url) == true
        FileHandle.standardError.write(Data("ararat-trace: little-window navigate popup_host=\(host != nil) accepted=\(accepted)\n".utf8))
        guard accepted else { return }
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
                self.archivePageOnClose()
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
        // D8: with remembering off this device keeps no frame, so nothing is written (the pane
        // also forgets the stored one when the switch goes off). Main's last-valid-frame guard
        // keeps a closing window whose frame reads invalid from overwriting a good record.
        guard rememberFrame, let window, let adapter = origin?.workspace else { return }
        let current = window.frame
        if current.origin.x.isFinite, current.origin.y.isFinite,
           current.width.isFinite, current.height.isFinite, current.width > 0, current.height > 0 {
            lastValidFrame = current
        }
        guard let frame = lastValidFrame else { return }
        frameSaveGeneration += 1
        let generation = frameSaveGeneration
        let write: () -> Void = { [weak self] in
            // L2: a switch turned off while the 0.5 s debounce runs must not store the frame the
            // pane just forgot.
            guard let self, self.frameSaveGeneration == generation, self.rememberFrame else { return }
            adapter.setLittleWindowFrame(LittleWindowFrame(x: frame.minX, y: frame.minY,
                                                           width: frame.width, height: frame.height))
        }
        if debounced { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: write) } else { write() }
    }

    /// D8 with close-after off, design's M3 decision: the page moves into the space and the Little
    /// Window comes back as a fresh empty one — the same about:blank start the menu command makes,
    /// placeholder address and Open disabled — so the page is not requested a second time. Its
    /// popup lost its last tab to the handoff and closed, so this is a new popup at the same frame.
    private func reopenAfterOpenIn(frame: NSRect?) {
        guard let origin, origin.hasUsableHost else { return }
        checkActions["reopen", default: 0] += 1
        origin.openLittleWindow(profile: profileName, frame: frame)
    }

    // MARK: - Closing

    private func archivePageOnClose() {
        guard !archivedOnClose, !pageTransferred, let origin, !origin.isPrivateWindow else { return }
        let url = pageTab?.url ?? lastPageURL ?? initialURL ?? ""
        guard !url.isEmpty, url != "about:blank" else { return }
        archivedOnClose = true
        origin.workspace?.archiveLittleWindow(profile: profileName, url: url, title: pageTab?.title ?? lastPageTitle) { [weak origin] result in
            origin?.showResult(result)
        }
    }

    func close(archive: Bool = true) {
        if !archive { pageTransferred = true }
        lastPageURL = pageTab?.url ?? lastPageURL
        lastPageTitle = pageTab?.title ?? lastPageTitle
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
