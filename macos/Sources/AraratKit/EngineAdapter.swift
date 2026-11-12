import AppKit
import AraratEngineAPI

public final class EngineAdapter: NSObject, ARWindowHostDelegate {
    private struct SelectionContext {
        let generation: Int
        let space: String?
        let profile: String?
        let restoring: RestorationCandidate?
    }
    public let session: WorkspaceSession
    private var queue: DispatchQueue { session.queue }
    private var store: WorkspaceStore? {
        get { session.store }
        set { session.store = newValue }
    }
    let windowID: String
    private let card: NSView
    private let permissionDim = PermissionDim()
    weak var host: (any ARWindowHostAPI)?
    private var selectionGeneration = 0
    private var restoringSelection = false
    private var recoveryDispatched = false
    private var openingSelections: [String: SelectionContext] = [:]
    private var pendingSelectionCommands: Set<String> = []
    private var pendingSplitOpens: [String: (item: String, context: SelectionContext, panes: [SplitPane])] = [:]
    private var restoringSplitCommands: Set<String> = []
    private var restoringSplitMoves: Set<String> = []
    private var restoringTargetCommand: String?
    private var restoringSplitPreparing = false
    private var displayedSplit: SplitPane?
    private var cardResizeObserver: NSObjectProtocol?
    private var keyWindowObserver: NSObjectProtocol?
    private var handoffGeneration = 0
    private var splitHandles: [String: SplitDividerView] = [:]
    private var splitPlaceholders: [String: RemotePlaceholderView] = [:]
    private var failureViews: [String: PageFailureView] = [:]
    private var displayedSelection: String?
    private var dragBaseline: SplitPane?
    private var dragFactors: [SplitFactor]?
    private var dragSplit: String?
    private var appliedSplitFrames: [String: NSRect] = [:]
    private var measurementDragOrigin: NSPoint?
    public private(set) var crashedItems: Set<String> = []
    public var onSnapshot: (@MainActor (WorkspaceSnapshot) -> Void)?
    public var onTransaction: (@MainActor (LiveTransaction, Bool) -> Void)?
    public var onWorkspaceChange: (@MainActor () -> Void)?
    public var onQuitProfileSwitch: (@MainActor () -> Void)?
    public var onCloseStarted: (@MainActor () -> Void)?
    public var onPageFullscreenChanged: (@MainActor (Bool) -> Void)?
    public var onWindowFullscreenChanged: (@MainActor (Bool) -> Void)?
    public var onWorkspaceCommand: (@MainActor (String) -> Void)?
    public var onFindBar: (@MainActor ([String: Any]) -> Void)?
    public var findBarHasFocus: (@MainActor () -> Bool)?
    public var onFindPageRect: (@MainActor (NSRect) -> Void)?
    public var onDownloads: (@MainActor ([[String: Any]], String?, Bool) -> Void)?

    public func downloads() -> [[String: Any]] { host?.downloads() ?? [] }
    public func performDownloadAction(_ action: String, identifier: String) -> Bool {
        host?.performDownloadAction(action, identifier: identifier) ?? false
    }

    public func windowHost(_ host: any ARWindowHostAPI, downloadsChanged items: [[String: Any]], newDownload identifier: String?, flight: Bool) {
        MainActor.assumeIsolated { onDownloads?(items, identifier, flight) }
    }

    // U26e pass 4: the focused site snapshot, permission changes and captures. The engine
    // creates and rebinds its own PageInfo, so the app only reads and forwards.
    public var onSiteStateChanged: (@MainActor () -> Void)?
    public var onExtensionActionsChanged: (@MainActor () -> Void)?

    public func siteStateChanged(forWindowHost host: any ARWindowHostAPI) {
        MainActor.assumeIsolated { onSiteStateChanged?() }
    }

    public func extensionActionsChanged(forWindowHost host: any ARWindowHostAPI) {
        MainActor.assumeIsolated { onExtensionActionsChanged?() }
    }

    public func siteState() -> SiteState? {
        precondition(Thread.isMainThread)
        guard let host else { return nil }
        return SiteState(host.siteState())
    }

    public func changeSitePermission(_ request: [String: Any]) -> Bool {
        precondition(Thread.isMainThread)
        return host?.changeSitePermission(request) ?? false
    }

    public func closeSiteControls() {
        precondition(Thread.isMainThread)
        host?.closeSiteControls()
    }

    public func captureFullPage(document: String, completion: @escaping (Data?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard let host else { completion(nil, "tabGone"); return }
        host.captureFullPage(forDocument: document) { png, error in
            MainActor.assumeIsolated { completion(png, error) }
        }
    }

    public func captureRegion(_ rect: NSRect, document: String, completion: @escaping (Data?, String?) -> Void) {
        precondition(Thread.isMainThread)
        guard let host else { completion(nil, "tabGone"); return }
        host.captureRegion(rect, document: document) { png, error in
            MainActor.assumeIsolated { completion(png, error) }
        }
    }

    public func extensionActions(iconSize: Int = 20) -> [ExtensionActionItem] {
        precondition(Thread.isMainThread)
        guard let host else { return [] }
        return host.extensionActions(withIconSize: UInt(iconSize)).compactMap(ExtensionActionItem.init)
    }

    public func setExtensionPinned(_ identifier: String, pinned: Bool) -> String {
        precondition(Thread.isMainThread)
        return host?.setExtensionPinned(identifier, pinned: pinned) ?? "unknown"
    }

    public func extensionManagementURL(_ identifier: String) -> String? {
        precondition(Thread.isMainThread)
        return host?.extensionManagementURL(identifier)
    }

    public func removeExtension(_ identifier: String, completion: @escaping (String, String) -> Void) {
        precondition(Thread.isMainThread)
        guard let host else { completion("unknown", ""); return }
        host.removeExtension(identifier) { result, detail in
            MainActor.assumeIsolated { completion(result, detail) }
        }
    }

    public func setExtensionAnchor(_ rect: NSRect) {
        precondition(Thread.isMainThread)
        host?.setExtensionAnchor(rect)
    }

    public func runExtensionAction(_ identifier: String) {
        precondition(Thread.isMainThread)
        host?.runExtensionAction(identifier)
    }

    public var checkSelectionDispatch: ((String, String, @escaping () -> Void) -> Void)?
    public var checkSelectionActivated: ((String) -> Void)?
    public var checkSelectionCommand: ((String, String, Bool) -> Void)?

    public init(path: String, windowID: String, card: NSView, seedCheck: Bool = false, seedSingleCheck: Bool = false, seedLinkCheck: Bool = false, seedProfiles: Bool = false, seedSplitCheck: Bool = false, seedToastSplit: Bool = false, seedOrganize: Bool = false, seedDock: Bool = false, seedSidebar: Bool = false, profileCheckURL: String = "about:blank", singleCheckURL: String? = nil, requireExisting: Bool = false, session: WorkspaceSession = WorkspaceSession()) throws {
        self.session = session
        self.windowID = windowID
        self.card = card
        super.init()
        try queue.sync {
            let opened = try store ?? WorkspaceStore.open(path: path)
            let empty = opened.snapshot(windowId: windowID).spaces.isEmpty
            if requireExisting && empty { throw NSError(domain: "Ararat.relaunch", code: 1) }
            if (seedCheck || seedSingleCheck || seedLinkCheck || seedProfiles || seedOrganize || seedDock || seedSidebar) && !empty {
                throw NSError(domain: "Ararat.slice", code: 1)
            }
            if seedOrganize {
                _ = try opened.createSpace(windowId: windowID, name: "Work", spaceId: "organize-work")
                _ = try opened.createSpace(windowId: windowID, name: "Other", spaceId: "organize-other")
                try opened.showSpace(windowId: windowID, spaceId: "organize-work")
                _ = try opened.ensureFavorites(windowId: windowID, spaceId: "organize-work", containerId: "organize-favorites")
                _ = try opened.createFolder(windowId: windowID, id: "organize-outer", name: "Outer", container: "organize-work:pinned", index: 0, wrapping: [])
                _ = try opened.createFolder(windowId: windowID, id: "organize-inner", name: "Inner", container: "organize-outer", index: 0, wrapping: [])
                _ = try opened.setFolderCollapsed(windowId: windowID, id: "organize-inner", collapsed: true)
                for (index, name) in ["folder", "favorite", "dock", "cancel", "fav1", "fav2", "today"].enumerated() {
                    let snapshot = try opened.createTab(windowId: windowID, url: "about:blank?organize-\(name)")
                    guard let id = snapshot.selectedId else { throw NSError(domain: "Ararat.organize", code: 1) }
                    if index < 4 { _ = try opened.moveItem(windowId: windowID, id: id, container: "organize-work:pinned", index: UInt32(index + 1), openFolder: false) }
                    if index == 4 || index == 5 { _ = try opened.moveItem(windowId: windowID, id: id, container: "organize-favorites", index: UInt32(index - 4), openFolder: false) }
                }
            } else if seedSidebar {
                _ = try opened.createSpace(windowId: windowID, name: "Sidebar", spaceId: "sidebar-work")
                try opened.showSpace(windowId: windowID, spaceId: "sidebar-work")
                _ = try opened.ensureFavorites(windowId: windowID, spaceId: "sidebar-work", containerId: "sidebar-favorites")
                _ = try opened.createFolder(windowId: windowID, id: "sidebar-folder", name: "Folder", container: "sidebar-work:pinned", index: 0, wrapping: [])
                _ = try opened.createFolder(windowId: windowID, id: "sidebar-empty", name: "Empty", container: "sidebar-work:pinned", index: 1, wrapping: [])
                func sidebarTab(_ name: String) throws -> String {
                    let snapshot = try opened.createTab(windowId: windowID, url: "about:blank?sidebar-\(name)")
                    guard let id = snapshot.selectedId else { throw NSError(domain: "Ararat.sidebar", code: 1) }
                    return id
                }
                let todayA = try sidebarTab("today-a")
                _ = try sidebarTab("today-b")
                _ = try sidebarTab("today-c")
                let folderTab = try sidebarTab("folder-tab")
                _ = try opened.moveItem(windowId: windowID, id: folderTab, container: "sidebar-folder", index: 0, openFolder: false)
                let loadedPin = try sidebarTab("pin")
                _ = try opened.moveItem(windowId: windowID, id: loadedPin, container: "sidebar-work:pinned", index: 2, openFolder: false)
                let unloadedPin = try sidebarTab("pin-off")
                _ = try opened.moveItem(windowId: windowID, id: unloadedPin, container: "sidebar-work:pinned", index: 3, openFolder: false)
                _ = try opened.closeItem(windowId: windowID, id: unloadedPin)
                _ = try opened.selectItem(windowId: windowID, id: todayA)
            } else if seedProfiles || seedDock {
                var json = """
                {"sidebar":{"containers":[{"global":{}},{"spaces":["default",{"id":"default","title":"Default","profile":{"default":true},"containerIDs":["pinned","pin-default","unpinned","today-default"]},"named",{"id":"named","title":"Profile 1","profile":{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"containerIDs":["pinned","pin-named","unpinned","today-named"]}],"topAppsContainerIDs":[],"items":["pin-default",{"id":"pin-default","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"default"}}}}},"today-default",{"id":"today-default","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"default"}}}}},"pin-named",{"id":"pin-named","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"named"}}}}},"today-named",{"id":"today-named","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"named"}}}}}]}]}}
                """
                if seedSplitCheck || seedToastSplit {
                    let parent = seedToastSplit ? "pin-default" : "pin-named"
                    let old = "\"\(parent)\",{\"id\":\"\(parent)\",\"parentID\":null,\"childrenIds\":[]"
                    let replacement = "\"\(parent)\",{\"id\":\"\(parent)\",\"parentID\":null,\"childrenIds\":[\"close-split\"]"
                    guard json.contains(old) else { throw NSError(domain: "Ararat.split-check", code: 1) }
                    json = json.replacingOccurrences(of: old, with: replacement)
                    let marker = "\"today-named\",{\"id\":\"today-named\""
                    let split = """
                    "close-split",{"id":"close-split","parentID":"\(parent)","childrenIds":["close-split-a","close-split-b"],"data":{"splitView":{"layoutOrientation":"horizontal","itemWidthFactors":["close-split-a",0.5,"close-split-b",0.5]}}},"close-split-a",{"id":"close-split-a","parentID":"close-split","childrenIds":[],"data":{"tab":{"savedURL":"about:blank","savedTitle":"A"}}},"close-split-b",{"id":"close-split-b","parentID":"close-split","childrenIds":[],"data":{"tab":{"savedURL":"about:blank","savedTitle":"B"}}},
                    """
                    guard json.contains(marker) else { throw NSError(domain: "Ararat.split-check", code: 2) }
                    json = json.replacingOccurrences(of: marker, with: split + marker)
                }
                _ = try opened.importArcSidebar(windowId: windowID, json: json, windowsJson: nil, keyBindingsJson: nil, linkRoutingJson: nil, ownerProfile: nil)
                for space in ["default", "named"] {
                    try opened.showSpace(windowId: windowID, spaceId: space)
                    _ = try opened.createTab(windowId: windowID, url: profileCheckURL)
                }
                try opened.showSpace(windowId: windowID, spaceId: "default")
                if seedDock {
                    let look = Look(colors: [LookColor(red: 0.4, green: 0.3, blue: 0.8, x: 0.7, y: 0.5)], opacity: 0.5, grain: 0, glass: false, appearance: .auto)
                    _ = try opened.setSpaceLook(windowId: windowID, spaceId: "default", look: look)
                    for index in 0..<11 {
                        let id = "dock-\(index)"
                        _ = try opened.createSpace(windowId: windowID, name: "Space \(index + 1)", spaceId: id)
                        _ = try opened.setSpaceLook(windowId: windowID, spaceId: id, look: look)
                        if index == 0 { _ = try opened.createTab(windowId: windowID, url: "about:blank?dock-drag") }
                    }
                    _ = try opened.moveSpace(windowId: windowID, spaceId: "named", index: 12)
                    try opened.showSpace(windowId: windowID, spaceId: "default")
                }
            } else if empty {
                _ = try opened.createSpace(windowId: windowID, name: "Space", spaceId: UUID().uuidString)
            }
            if seedCheck || seedSingleCheck {
                for name in seedSingleCheck ? ["One"] : ["One", "Two", "Three"] {
                    _ = try opened.createTab(windowId: windowID, url: singleCheckURL ?? "data:text/html,<title>Ararat \(name)</title>")
                }
            }
            if seedLinkCheck {
                _ = try opened.createTab(windowId: windowID, url: "data:text/html,<a href='https://example.test/link' style='position:absolute;left:50px;top:50px;width:200px;height:60px'>Open link</a>")
            }
            store = opened
        }
    }

    public func attach(_ host: any ARWindowHostAPI) {
        precondition(Thread.isMainThread)
        self.host = host
        session.register(self, window: windowID)
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        if (host as AnyObject).responds(to: #selector(ARWindowHostAPI.window)) {
            let window = host.window()
            if window.isKeyWindow { session.noteKey(window: windowID) }
            keyWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { self.session.noteKey(window: self.windowID); self.takeRemoteSelection() } }
            }
        }
        card.postsFrameChangedNotifications = true
        if let cardResizeObserver { NotificationCenter.default.removeObserver(cardResizeObserver) }
        cardResizeObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: card, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelSplitDrag(); self?.layoutSplit(); self?.layoutFailures() }
        }
        let profile = queue.sync { self.shownProfileDirectory() }
        host.delegate = self
        queue.async { self.session.drainHistoryPurges() }
        if let profile { _ = host.setProfileDirectory(profile) }
        publish()
    }

    public func windowHost(_ host: any ARWindowHostAPI, performWorkspaceCommand command: String) {
        MainActor.assumeIsolated { onWorkspaceCommand?(command) }
    }

    public func windowHost(_ host: any ARWindowHostAPI, updateFindBar state: [String: Any]) {
        MainActor.assumeIsolated { onFindBar?(state) }
    }

    public func findBarHasFocus(forWindowHost host: any ARWindowHostAPI) -> Bool {
        MainActor.assumeIsolated { findBarHasFocus?() ?? false }
    }

    public func windowHost(_ host: any ARWindowHostAPI, findPageRectChanged rect: NSRect) {
        MainActor.assumeIsolated { onFindPageRect?(rect) }
    }

    public func restoreSelection() {
        precondition(Thread.isMainThread)
        let generation = selectionGeneration
        guard let host else { session.finishCrashRecovery?(); return }
        restoringSelection = true
        queue.async {
            guard let candidate = self.store?.restorationCandidate(windowId: self.windowID) else {
                DispatchQueue.main.async { self.finishCrashRecovery() }
                return
            }
            DispatchQueue.main.async {
                guard let current = self.host, (current as AnyObject) === (host as AnyObject),
                      !current.isClosing(), !current.isClosingAll(), self.selectionGeneration == generation else {
                    self.finishCrashRecovery()
                    return
                }
                self.select(id: candidate.id, url: candidate.url, restoring: candidate)
            }
        }
    }

    private func finishCrashRecovery() {
        guard restoringSelection else { return }
        restoringSelection = false
        recoveryDispatched = false
        restoringSplitCommands.removeAll()
        restoringSplitMoves.removeAll()
        restoringTargetCommand = nil
        restoringSplitPreparing = false
        session.finishCrashRecovery?()
    }

    public func select(id: String, url: String, restoring: RestorationCandidate? = nil) {
        precondition(Thread.isMainThread)
        invalidateSelection()
        let generation = selectionGeneration
        queue.async {
            do {
                guard let store = self.store else { return }
                if let restoring, store.restorationCandidate(windowId: self.windowID) != restoring { return }
                if restoring != nil { _ = try store.selectItem(windowId: self.windowID, id: id) }
                let snapshot = store.snapshot(windowId: self.windowID)
                let selectedSpace = snapshot.shownSpaceId
                let selectedProfile = snapshot.spaces.first(where: { $0.id == selectedSpace })?.profileName
                let needsOpen = store.liveTab(item: id) == nil
                if CommandLine.arguments.contains("--ararat-check=close") {
                    FileHandle.standardError.write(Data("ararat-trace: select-open=\(needsOpen)\n".utf8))
                }
                let command = try needsOpen
                    ? store.liveOpen(item: id, url: url)
                    : store.liveActivate(item: id)
                if !needsOpen { _ = store.liveSelectionIntent(commandId: command.id, windowId: self.windowID) }
                self.pendingSelectionCommands.insert(command.id)
                func leaves(_ pane: SplitPane) -> [SplitPane] {
                    if pane.kind == .tab { return [pane] }
                    return pane.children.flatMap(leaves)
                }
                let siblings = store.splitLayout(itemId: id).map { leaves($0).filter { $0.id != id } } ?? []
                DispatchQueue.main.async {
                    self.selectionDispatchForCheck("registered", command: command) {
                        guard self.selectionGeneration == generation,
                              self.queue.sync(execute: {
                                  self.store?.snapshot(windowId: self.windowID).shownSpaceId == selectedSpace &&
                                  (restoring == nil || self.store?.restorationCandidate(windowId: self.windowID) == restoring)
                              }) else {
                            self.cancelSelectionCommand(command)
                            return
                        }
                        self.checkSelectionCommand?(id, command.id, needsOpen)
                        if restoring != nil { self.recoveryDispatched = true; self.restoringTargetCommand = command.id }
                        let context = SelectionContext(generation: generation, space: selectedSpace, profile: selectedProfile, restoring: restoring)
                        if !siblings.isEmpty { self.pendingSplitOpens[command.id] = (id, context, siblings) }
                        self.execute(command, selection: context)
                    }
                }
            } catch {
                self.report(error)
            }
        }
    }

    public func invalidateSelection() {
        precondition(Thread.isMainThread)
        selectionGeneration += 1
        pendingSplitOpens.removeAll()
        let withdrawn = openingSelections.keys.filter { host?.cancelPendingOpen($0) == true }
        openingSelections.removeAll()
        queue.async {
            for id in withdrawn { _ = self.store?.liveCancel(commandId: id) }
            for id in self.pendingSelectionCommands { _ = self.store?.liveCancel(commandId: id) }
            self.pendingSelectionCommands.removeAll()
        }
    }

    public func openExternalURLs(_ urls: [(url: String, untrusted: Bool)]) {
        queue.async {
            do {
                guard let store = self.store else { return }
                var commands: [(LiveCommand, Bool)] = []
                var snapshot: WorkspaceSnapshot?
                for entry in urls {
                    let current = try store.createTab(windowId: self.windowID, url: entry.url)
                    if let id = current.selectedId {
                        let command = try store.liveOpen(item: id, url: entry.url)
                        self.pendingSelectionCommands.insert(command.id)
                        commands.append((command, entry.untrusted))
                    }
                    snapshot = current
                }
                DispatchQueue.main.async {
                    for (command, untrusted) in commands { self.execute(command, external: untrusted) }
                    if let snapshot { self.deliverIfCurrent(snapshot) }
                }
            } catch { self.report(error) }
        }
    }

    public func openCommandURL(_ url: String, expectedSpace: String?, profile: String) {
        queue.async {
            do {
                guard let store = self.store else { return }
                let current = store.snapshot(windowId: self.windowID)
                guard current.shownSpaceId == expectedSpace,
                      current.spaces.first(where: { $0.id == expectedSpace })?.profileName == profile else { return }
                let snapshot = try store.createTab(windowId: self.windowID, url: url)
                guard let item = snapshot.selectedId else { return }
                let command = try store.liveOpen(item: item, url: url)
                self.pendingSelectionCommands.insert(command.id)
                DispatchQueue.main.async {
                    self.execute(command)
                    self.deliverIfCurrent(snapshot)
                }
            } catch { self.report(error) }
        }
    }

    public func captureNavigationTarget() -> [String: Any]? {
        precondition(Thread.isMainThread)
        return host?.navigationTarget()
    }

    public func isCurrentNavigationTarget(_ target: [String: Any]) -> Bool {
        precondition(Thread.isMainThread)
        guard let host, !host.isClosing(), !host.isClosingAll(),
              let current = host.navigationTarget(),
              let item = target["item"] as? String, let live = target["live"] as? String,
              let epoch = target["epoch"] as? NSNumber, let profile = target["profile"] as? String,
              current["item"] as? String == item, current["live"] as? String == live,
              current["epoch"] as? NSNumber == epoch, current["profile"] as? String == profile else { return false }
        return queue.sync { store?.liveTab(item: item) == live }
    }

    @discardableResult
    public func navigateCommandURL(_ url: String, target: [String: Any]) -> Bool {
        precondition(Thread.isMainThread)
        guard let host, isCurrentNavigationTarget(target) else { return false }
        return host.navigateURL(url, target: target)
    }

    public func close(id: String, archive: Bool? = nil, expectedLive: String? = nil) {
        precondition(Thread.isMainThread)
        // Only the row-less ⌘W (a nil archive) resolves a split member to its split row; a
        // row's ✕/− acts on the row that showed it until U25c draws splits as one row.
        if archive == nil, queue.sync(execute: {
            guard let store, let selected = store.snapshot(windowId: windowID).selectedId else { return false }
            let rows = store.snapshot(windowId: windowID).spaces.flatMap { $0.today + $0.pinned + $0.favorites }
            return store.splitLayout(itemId: selected)?.id == splitOwner(id, rows: rows)
        }) { invalidateSelection() }
        queue.async { self.closeInQueue(id: id, archive: archive, expectedLive: expectedLive) }
    }

    // ⌘W with no sidebar row: the selection is read and the close is decided in one queue
    // block, so two quick presses act on the core's next tab (a read-then-enqueue split would
    // let both reads return the first selection and archive the pin the first press unloaded).
    public func closeSelected() {
        precondition(Thread.isMainThread)
        queue.async {
            guard let store = self.store, let selected = store.snapshot(windowId: self.windowID).selectedId else { return }
            let rows = store.snapshot(windowId: self.windowID).spaces.flatMap { $0.today + $0.pinned + $0.favorites }
            let item = splitOwner(selected, rows: rows)
            if store.splitLayout(itemId: selected)?.id == item { DispatchQueue.main.async { self.invalidateSelection() } }
            self.closeInQueue(id: item, archive: nil, expectedLive: nil)
        }
    }

    // Clear Today: one core batch with a Close in flight for every mapped live row, so the
    // engine's replies match commands; the caller closes the pages it returns (U25b D6).
    public func clearToday(spaceID: String, completion: @escaping @MainActor (LiveClearToday?) -> Void) {
        precondition(Thread.isMainThread)
        queue.async {
            defer { self.session.drainHistoryPurges() }
            do {
                guard let store = self.store else { DispatchQueue.main.async { completion(nil) }; return }
                let result = try store.liveClearToday(windowId: self.windowID, spaceId: spaceID)
                DispatchQueue.main.async {
                    for target in result.targets {
                        if let tab = self.session.tab(target.liveId) { tab.close(withCommandId: target.command.id) }
                        else if self.session.cancelPendingOpen(target.liveId) {
                            self.queue.async {
                                _ = self.store?.liveCancel(commandId: target.liveId)
                                _ = self.store?.liveSettleClose(commandId: target.command.id)
                            }
                        }
                        else {
                            // A target the engine no longer has: settle its Close so the row is not
                            // left pending for a later restore.
                            self.queue.async { _ = self.store?.liveSettleClose(commandId: target.command.id) }
                            self.report(CoreError.Live(message: "Cannot find live tab \(target.liveId) to close"))
                        }
                    }
                    self.deliverIfCurrent(result.snapshot)
                    completion(result)
                }
            } catch {
                self.report(error)
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    public func undoClearToday(_ batch: ClearTodayUndo, completion: @escaping @MainActor (WorkspaceSnapshot?) -> Void) {
        precondition(Thread.isMainThread)
        queue.async {
            do {
                guard let store = self.store else { DispatchQueue.main.async { completion(nil) }; return }
                let snapshot = try store.undoClearToday(windowId: self.windowID, undo: batch)
                DispatchQueue.main.async { self.deliverIfCurrent(snapshot, allowUnloadedSelection: true); completion(snapshot) }
            } catch {
                self.report(error)
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    // Runs on the adapter's queue. A nil archive applies R1/D2 to the row it reads.
    private func closeInQueue(id: String, archive: Bool?, expectedLive: String?) {
        defer { session.drainHistoryPurges() }
        do {
            guard let store = self.store else { return }
            if let expectedLive, store.liveTab(item: id) != expectedLive { return }
            let snapshot = store.snapshot(windowId: windowID)
            let rows = snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
            let item = archive == nil ? splitOwner(id, rows: rows) : id
            let row = rows.first { $0.id == item }
            let space = snapshot.spaces.first { $0.id == snapshot.shownSpaceId }
            let archive = archive ?? row.flatMap { row in space.map { rowCloseArchives(row, in: $0) } } ?? false
            if !archive, row?.kind == .split {
                let targets = try store.liveCloseSplit(item: item)
                let snapshot = store.snapshot(windowId: self.windowID)
                DispatchQueue.main.async {
                    for target in targets {
                        if let tab = self.session.tab(target.liveId) { tab.close(withCommandId: target.command.id) }
                        else if self.session.cancelPendingOpen(target.liveId) {
                            self.queue.async {
                                _ = self.store?.liveCancel(commandId: target.liveId)
                                _ = self.store?.liveSettleClose(commandId: target.command.id)
                            }
                        } else {
                            self.report(CoreError.Live(message: "Cannot find split member \(target.command.item) to close"))
                        }
                    }
                    self.deliverIfCurrent(snapshot)
                    self.onWorkspaceChange?()
                }
                return
            }
            guard let liveID = store.liveTab(item: item) else {
                let snapshot = try archive
                    ? store.archiveItem(windowId: self.windowID, id: item)
                    : store.closeItem(windowId: self.windowID, id: item)
                DispatchQueue.main.async { self.deliverIfCurrent(snapshot) }
                return
            }
            let command = try archive ? store.liveArchive(item: item) : store.liveClose(item: item)
            DispatchQueue.main.async { self.session.tab(liveID)?.close(withCommandId: command.id) }
        } catch { self.report(error) }
    }

    public func pageCard(forWindowHost host: any ARWindowHostAPI) -> NSView { card }
    public func checkPermissionDim(_ identifier: String) -> Bool { permissionDim.isVisible(identifier) }

    public func windowHost(_ host: any ARWindowHostAPI, permissionDim identifier: String,
                           container: NSView, frame: NSRect, visible: Bool) {
        permissionDim.update(identifier, container: container, frame: frame, visible: visible)
    }

    public func windowHost(_ host: any ARWindowHostAPI, pageFullscreenChanged fullscreen: Bool) {
        MainActor.assumeIsolated { onPageFullscreenChanged?(fullscreen) }
    }

    public func windowHost(_ host: any ARWindowHostAPI, windowFullscreenChanged fullscreen: Bool) {
        MainActor.assumeIsolated { onWindowFullscreenChanged?(fullscreen) }
    }

    public func windowHost(_ host: any ARWindowHostAPI, showProfile profile: String) {
        if host.isClosingAll() || host.isClosing() {
            _ = host.setClosePresentationProfile(profile)
            MainActor.assumeIsolated { onQuitProfileSwitch?() }
            return
        }
        let snapshot: WorkspaceSnapshot? = queue.sync {
            do {
                guard let store = self.store,
                      let space = store.recentSpaceForProfile(windowId: self.windowID, profile: profile == "Default" ? .default : .named(profile)) else { return nil }
                return try store.showSpaceSelecting(windowId: self.windowID, spaceId: space)
            } catch {
                self.report(error)
                return nil
            }
        }
        guard let snapshot else { return }
        invalidateSelection()
        guard host.setProfileDirectory(profile) else { return }
        MainActor.assumeIsolated { deliverIfCurrent(snapshot) }
        if let id = snapshot.selectedId,
           let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
           let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == id }),
           let url = row.url { select(id: id, url: url) }
    }

    public func windowHostWillBeginClosing(_ host: any ARWindowHostAPI) {
        handoffGeneration += 1
        invalidateSelection()
        MainActor.assumeIsolated { onCloseStarted?() }
    }

    public func windowHostClosingAllCancelled(_ host: any ARWindowHostAPI) {
        handoffGeneration += 1
        let profile = host.profileDirectory()
        let snapshot: WorkspaceSnapshot? = queue.sync {
            guard let store = self.store else { return nil }
            do { return try Self.snapshotAfterCloseCancellation(store: store, windowID: windowID, forcedProfile: profile) }
            catch { report(error); return store.snapshot(windowId: windowID) }
        }
        guard let snapshot, let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) else { return }
        host.setWorkspacePageHidden(true)
        guard host.setProfileDirectory(space.profileName) else { return }
        invalidateSelection()
        MainActor.assumeIsolated { deliverIfCurrent(snapshot) }
        if let id = snapshot.selectedId,
           let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == id }),
           let url = row.url { select(id: id, url: url) }
    }

    static func snapshotAfterCloseCancellation(store: WorkspaceStore, windowID: String, forcedProfile: String) throws -> WorkspaceSnapshot {
        let current = store.snapshot(windowId: windowID)
        let shown = current.spaces.first(where: { $0.id == current.shownSpaceId })?.profileName
        guard shown != forcedProfile,
              let space = store.recentSpaceForProfile(windowId: windowID, profile: forcedProfile == "Default" ? .default : .named(forcedProfile)) else { return current }
        return try store.showSpaceSelecting(windowId: windowID, spaceId: space)
    }

    public func windowHost(_ host: any ARWindowHostAPI, didReceiveTransaction value: [String: Any]) {
        guard let epoch = value["epoch"] as? NSNumber, let rev = value["rev"] as? NSNumber,
              let raw = value["strips"] as? [[String: Any]] else {
            invalidTransaction()
            return
        }
        let cause: LiveCause
        if let command = value["cause"] as? [String: String], command.count == 1, let id = command["Command"] {
            cause = .command(id)
            openingSelections.removeValue(forKey: id)
        } else if value["cause"] as? String == "Chrome" {
            cause = .chrome
        } else if value["cause"] as? String == "Engine" {
            cause = .engine
        } else {
            invalidTransaction()
            return
        }
        var strips: [LiveStrip] = []
        var crashedItems: Set<String> = []
        var navigatedLives: Set<String> = []
        for strip in raw {
            guard let window = strip["window"] as? String,
                  let tabs = strip["tabs"] as? [[String: Any]],
                  let active = strip["active"],
                  active is NSNull || active is String else {
                invalidTransaction()
                return
            }
            var parsedTabs: [LiveTab] = []
            for tab in tabs {
                guard let profile = tab["profile"] as? String, let live = tab["live_id"] as? String, let item = tab["item"],
                      let opener = tab["opener"], let url = tab["url"], let title = tab["title"],
                      let navigated = tab["navigated"] as? Bool,
                      let crashed = tab["crashed"] as? Bool,
                      item is NSNull || item is String,
                      opener is NSNull || opener is String, url is NSNull || url is String,
                      title is NSNull || title is String else {
                    invalidTransaction()
                    return
                }
                parsedTabs.append(LiveTab(profile: profile == "Default" ? .default : .named(profile), liveId: live, item: item as? String,
                                          opener: opener as? String, navigated: navigated, url: url as? String, title: title as? String))
                if crashed, let item = item as? String { crashedItems.insert(item) }
                if navigated { navigatedLives.insert(live) }
            }
            strips.append(LiveStrip(window: window, tabs: parsedTabs, active: active as? String))
        }
        let transaction = LiveTransaction(epoch: epoch.uint64Value, rev: rev.uint64Value, cause: cause, strips: strips)
        let crashed = crashedItems
        let navigated = navigatedLives
        queue.async {
            defer { self.session.drainHistoryPurges() }
            do {
                guard let store = self.store else { return }
                var previousOwners: [String: String] = [:]
                for strip in transaction.strips {
                    for tab in strip.tabs {
                        if let item = tab.item, let owner = store.liveWindow(item: item) { previousOwners[tab.liveId] = owner }
                    }
                }
                let outcome = try store.liveApply(transaction: transaction)
                if let error = outcome.persistenceError { self.report(CoreError.Store(message: error)) }
                for command in outcome.commands where command.kind == .activate || command.kind == .open {
                    self.pendingSelectionCommands.insert(command.id)
                }
                let snapshot = store.snapshot(windowId: self.windowID)
                let movedLives = transaction.strips.flatMap { strip in strip.tabs.compactMap { tab -> (String, String)? in
                    guard let item = tab.item, let before = previousOwners[tab.liveId],
                          let after = store.liveWindow(item: item), before != after else { return nil }
                    return (tab.liveId, after)
                } }
                DispatchQueue.main.async {
                    for (live, owner) in movedLives {
                        self.session.noteTransfer(live, destination: owner)
                        if owner == self.windowID { self.restoringSplitMoves.remove(live) }
                    }
                    for live in navigated { self.session.invalidateSnapshot(live) }
                    for adopted in outcome.adopted {
                        self.tab(adopted.liveId)?.itemId = adopted.item
                    }
                    for command in outcome.commands { self.execute(command) }
                    if case .command(let id) = transaction.cause {
                        self.restoringSplitCommands.remove(id)
                        if self.restoringTargetCommand == id { self.restoringTargetCommand = nil }
                    }
                    if case .command(let id) = transaction.cause, let pending = self.pendingSplitOpens.removeValue(forKey: id) {
                        if outcome.applied && snapshot.selectedId == pending.item && self.selectionGeneration == pending.context.generation,
                           self.queue.sync(execute: { self.store?.liveTab(item: pending.item) != nil }) {
                            self.openSplitSiblings(pending.panes, context: pending.context)
                        }
                    }
                    if outcome.applied {
                        self.crashedItems = crashed
                    }
                    self.maybeFinishCrashRecovery()
                    self.deliverIfCurrent(snapshot)
                    if let own = transaction.strips.first(where: { $0.window == self.windowID }),
                       let active = own.active, let tab = self.tab(active), let item = tab.itemId {
                        self.session.captureSnapshot(tab, item: item)
                    }
                    self.onTransaction?(transaction, outcome.applied)
                    if outcome.applied { self.onWorkspaceChange?() }
                }
            } catch { self.report(error) }
        }
    }

    public func shutdown() {
        precondition(Thread.isMainThread)
        for view in failureViews.values { view.uncover(restoreFocus: false); view.removeFromSuperview() }
        failureViews.removeAll()
        handoffGeneration += 1
        invalidateSelection()
        session.unregister(self, window: windowID)
        if let cardResizeObserver { NotificationCenter.default.removeObserver(cardResizeObserver) }
        cardResizeObserver = nil
        if let keyWindowObserver { NotificationCenter.default.removeObserver(keyWindowObserver) }
        keyWindowObserver = nil
        clearSplitHandles()
        host?.delegate = nil
        host = nil
        queue.sync {
            do { try store?.flush() } catch { report(error) }
        }
    }

    public func closeWindow(quitting: Bool) {
        queue.async {
            do { try self.store?.closeWindow(windowId: self.windowID, quitting: quitting) }
            catch { self.report(error) }
        }
    }

    public func windowHost(_ source: any ARWindowHostAPI, prepareCloseHandoff completion: @escaping (Bool) -> Void) {
        precondition(Thread.isMainThread)
        guard let current = host, (current as AnyObject) === (source as AnyObject), !source.isClosingAll() else { completion(true); return }
        let generation = handoffGeneration
        let plan = session.handoffs(from: self)
        guard !plan.isEmpty else { completion(true); return }
        func fail() {
            FileHandle.standardError.write(Data("engine adapter: close handoff failed; window remains open\n".utf8))
            completion(false)
        }
        for move in plan { move.target.host?.prepareTransferProfile(move.profile) }
        let deadline = DispatchTime.now() + 5
        func prepare() {
            guard self.handoffGeneration == generation, let current = self.host,
                  (current as AnyObject) === (source as AnyObject), !source.isClosingAll() else { fail(); return }
            for move in plan {
                guard let target = move.target.host, !target.isClosing(), !target.isClosingAll() else { fail(); return }
            }
            if plan.contains(where: { $0.target.host?.hasBrowser(forProfile: $0.profile) != true }) {
                guard DispatchTime.now() < deadline else { fail(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100), execute: prepare)
                return
            }
            let latest = self.session.handoffs(from: self)
            guard latest.count == plan.count,
                  plan.allSatisfy({ move in latest.contains { $0.live == move.live && $0.target === move.target && $0.activate == move.activate } }) else {
                fail(); return
            }
            for move in plan {
                guard let tab = self.tab(move.live), let target = move.target.host,
                      !target.isClosing(), !target.isClosingAll() else { fail(); return }
                self.session.beginTransfer(move.live, destination: move.target.windowID)
                self.session.captureSnapshot(tab, item: move.item)
                guard target.handoffTab(tab, activate: move.activate) else {
                    self.session.cancelTransfer(move.live, destination: move.target.windowID)
                    fail()
                    return
                }
            }
            completion(true)
        }
        prepare()
    }

    private func publish() {
        queue.async {
            guard let snapshot = self.store?.snapshot(windowId: self.windowID) else { return }
            DispatchQueue.main.async { self.deliverIfCurrent(snapshot) }
        }
    }

    @MainActor
    private func deliverIfCurrent(_ snapshot: WorkspaceSnapshot, skipNearSplitFrames: Bool = false, allowUnloadedSelection: Bool = false) {
        let current = queue.sync { () -> Bool in
            guard let store else { return false }
            let latest = store.snapshot(windowId: windowID)
            if latest == snapshot { return true }
            return allowUnloadedSelection && latest.selectedId == nil &&
                store.selectedItem(windowId: windowID) == snapshot.selectedId &&
                latest.shownSpaceId == snapshot.shownSpaceId && latest.spaces == snapshot.spaces && latest.archive == snapshot.archive
        }
        guard current else { return }
        guard host?.isClosing() != true, host?.isClosingAll() != true else { return }
        displayedSelection = snapshot.selectedId
        if dragBaseline == nil && !CommandLine.arguments.contains("--ararat-measure=split") {
            displayedSplit = snapshot.selectedId.flatMap { id in queue.sync { store?.splitLayout(itemId: id) } }
        }
        layoutSplit(skipNearSplitFrames: skipNearSplitFrames)
        layoutFailures(snapshot: snapshot)
        onSnapshot?(snapshot)
    }

    private func layoutFailures(snapshot supplied: WorkspaceSnapshot? = nil) {
        guard let host else { return }
        let frames: [String: NSRect]
        if let split = displayedSplit {
            frames = SplitGeometry(root: split, bounds: card.bounds).panes
        } else if let selected = displayedSelection {
            frames = [selected: card.bounds]
        } else {
            frames = [:]
        }
        let tabs = (host.tabs() as? [any ARTabAPI]) ?? []
        let failures = tabs.filter { tab in
            guard let id = tab.itemId else { return false }
            return frames[id] != nil && (tab.crashed || tab.networkError != 0)
        }
        let ids = Set(failures.compactMap(\.itemId))
        for id in failureViews.keys.filter({ !ids.contains($0) }) {
            guard let view = failureViews.removeValue(forKey: id) else { continue }
            view.uncover(restoreFocus: host.activeItemId() == id)
            view.removeFromSuperview()
        }
        guard !failures.isEmpty, let snapshot = supplied ?? queue.sync(execute: { store?.snapshot(windowId: windowID) }) else { return }
        for tab in failures {
            guard let id = tab.itemId, let frame = frames[id] else { continue }
            let view = failureViews[id] ?? PageFailureView(frame: frame)
            let archive = snapshot.spaces.flatMap(\.today).contains { $0.id == id }
            view.frame = frame
            view.update(crashed: tab.crashed, error: Int(tab.networkError), host: URL(string: tab.url)?.host ?? tab.url, archive: archive)
            view.onReload = { [weak tab] in tab?.reload() }
            view.onClose = { [weak self] in self?.close(id: id, archive: archive) }
            if view.superview !== card { card.addSubview(view, positioned: .above, relativeTo: nil) }
            view.cover(tab.view, focus: host.activeItemId() == id) { [weak tab] in tab?.focus() }
            failureViews[id] = view
        }
    }

    public func checkFailureState(item: String) -> [String: Any] { failureViews[item]?.checkState ?? [:] }
    public func checkFailurePress(item: String, secondary: Bool, screen: Bool) -> Bool {
        failureViews[item]?.checkPress(secondary: secondary, screen: screen) ?? false
    }

    private func layoutSplit(skipNearSplitFrames: Bool = false) {
        precondition(Thread.isMainThread)
        guard let host, (host as AnyObject).responds(to: #selector(ARWindowHostAPI.setSplitFrames(_:frozen:))) else { clearSplitHandles(); return }
        guard let split = displayedSplit else {
            clearSplitHandles()
            _ = host.setSplitFrames([:], frozen: false)
            appliedSplitFrames = [:]
            let remote = displayedSelection.flatMap { id in queue.sync { store?.liveWindow(item: id).map { ($0, store?.liveTab(item: id)) } } }
            let isRemote = remote.map { $0.0 != windowID } ?? false
            if (host as AnyObject).responds(to: #selector(ARWindowHostAPI.setWorkspaceRemote(_:))) { host.setWorkspaceRemote(isRemote) }
            if isRemote, let live = remote?.1 {
                let placeholder = RemotePlaceholderView(frame: card.bounds)
                placeholder.autoresizingMask = [.width, .height]
                placeholder.update(image: session.snapshot(live), message: "Shown in another window")
                card.addSubview(placeholder, positioned: .above, relativeTo: nil)
                splitPlaceholders[live] = placeholder
            }
            return
        }
        if (host as AnyObject).responds(to: #selector(ARWindowHostAPI.setWorkspaceRemote(_:))) { host.setWorkspaceRemote(false) }
        func leafTabs(_ pane: SplitPane) -> [String] {
            if pane.kind == .tab { return [pane.id] }
            return pane.children.flatMap(leafTabs)
        }
        let local = Set(((host.tabs() as? [any ARTabAPI]) ?? []).compactMap(\.itemId))
        let geometry = SplitGeometry(root: split, bounds: card.bounds)
        let frames = geometry.panes.mapValues { NSValue(rect: $0) }
        let nearPrevious = skipNearSplitFrames && dragBaseline == nil && appliedSplitFrames.count == geometry.panes.count &&
            geometry.panes.allSatisfy { id, frame in
                guard let previous = appliedSplitFrames[id] else { return false }
                return abs(frame.minX - previous.minX) < 0.5 && abs(frame.minY - previous.minY) < 0.5 &&
                    abs(frame.width - previous.width) < 0.5 && abs(frame.height - previous.height) < 0.5
            }
        guard nearPrevious || host.setSplitFrames(frames, frozen: dragBaseline != nil) else {
            clearSplitHandles()
            FileHandle.standardError.write(Data("engine adapter: split panes are not supported by this compositor\n".utf8))
            return
        }
        if !nearPrevious { appliedSplitFrames = geometry.panes }
        let tabs = Set(leafTabs(split))
        let missing = Set(geometry.panes.keys).subtracting(local)
        for key in splitPlaceholders.keys.filter({ !missing.contains($0) }) { splitPlaceholders.removeValue(forKey: key)?.removeFromSuperview() }
        for id in missing {
            guard let frame = geometry.panes[id] else { continue }
            let placeholder = splitPlaceholders[id] ?? RemotePlaceholderView(frame: frame)
            let remote = tabs.contains(id) ? queue.sync { store?.liveWindow(item: id).map { ($0, store?.liveTab(item: id)) } } : nil
            let isRemote = remote.map { $0.0 != windowID } ?? false
            placeholder.update(image: remote?.1.flatMap { session.snapshot($0) }, message: isRemote ? "Shown in another window" : "Page unavailable")
            placeholder.frame = frame
            if placeholder.superview !== card { card.addSubview(placeholder, positioned: .above, relativeTo: nil) }
            splitPlaceholders[id] = placeholder
        }
        let keys = Set(geometry.dividers.map { "\($0.split):\($0.index)" })
        for key in splitHandles.keys.filter({ !keys.contains($0) }) { splitHandles.removeValue(forKey: key)?.removeFromSuperview() }
        for divider in geometry.dividers {
            let key = "\(divider.split):\(divider.index)"
            let view = splitHandles[key] ?? SplitDividerView(frame: divider.frame)
            view.horizontal = divider.horizontal
            view.frame = divider.frame
            view.onMove = { [weak self] delta, finished in self?.dragSplitDivider(split: divider.split, index: divider.index, delta: delta, finished: finished) }
            if view.superview !== card { card.addSubview(view, positioned: .above, relativeTo: nil) }
            splitHandles[key] = view
        }
    }

    private func clearSplitHandles() {
        for view in splitHandles.values { view.removeFromSuperview() }
        splitHandles.removeAll()
        for view in splitPlaceholders.values { view.removeFromSuperview() }
        splitPlaceholders.removeAll()
    }

    private func cancelSplitDrag() {
        if let dragBaseline {
            displayedSplit = dragBaseline
            for handle in splitHandles.values { handle.cancelDrag() }
        }
        dragBaseline = nil
        dragFactors = nil
        dragSplit = nil
    }

    private func dragSplitDivider(split: String, index: Int, delta: CGFloat, finished: Bool) {
        guard let root = displayedSplit else { return }
        if delta != 0 {
            if dragBaseline == nil { dragBaseline = root; dragSplit = split }
            let geometry = SplitGeometry(root: root, bounds: card.bounds)
            if let factors = geometry.factorsAfterDragging(root: root, split: split, index: index, delta: delta) {
                func update(_ node: SplitPane) -> SplitPane {
                    var result = node
                    if node.id == split {
                        result.children = node.children.map { child in
                            var child = child
                            if let factor = factors.first(where: { $0.id == child.id }) { child.factor = factor.factor }
                            return child
                        }
                    } else { result.children = node.children.map(update) }
                    return result
                }
                displayedSplit = update(root)
                dragFactors = factors
                layoutSplit()
            }
        }
        if finished {
            let factors = dragFactors
            let split = dragSplit
            dragBaseline = nil; dragFactors = nil; dragSplit = nil
            layoutSplit()
            if let factors, let split, !CommandLine.arguments.contains("--ararat-measure=split") {
                queue.async {
                    do {
                        guard let store = self.store else { return }
                        try store.setSplitFactors(splitId: split, factors: factors)
                        let snapshot = store.snapshot(windowId: self.windowID)
                        DispatchQueue.main.async { self.deliverIfCurrent(snapshot, skipNearSplitFrames: true); self.onWorkspaceChange?() }
                    }
                    catch { self.report(error); self.publish() }
                }
            }
        }
    }

    public func windowHost(_ host: any ARWindowHostAPI, installSplitMeasurement count: UInt) -> Bool {
        precondition(Thread.isMainThread)
        guard CommandLine.arguments.contains("--ararat-measure=split"), count == 2 || count == 3 else { return false }
        let children = (0..<count).map { index in
            SplitPane(id: "measure-\(index)", factor: 1 / Double(count), kind: .tab, unloaded: false, url: nil, children: [])
        }
        cancelSplitDrag()
        displayedSplit = SplitPane(id: "measure-split", factor: 1, kind: .splitHorizontal, unloaded: false, url: nil, children: children)
        measurementDragOrigin = nil
        layoutSplit()
        return splitHandles.count == Int(count) - 1
    }

    public func windowHost(_ host: any ARWindowHostAPI, dragSplitMeasurement delta: CGFloat, finished: Bool) -> Bool {
        precondition(Thread.isMainThread)
        guard CommandLine.arguments.contains("--ararat-measure=split"), let divider = splitHandles["measure-split:0"] else { return false }
        if measurementDragOrigin == nil {
            let origin = card.convert(NSPoint(x: divider.frame.midX, y: divider.frame.midY), to: nil)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: origin, modifierFlags: [], timestamp: 0,
                                                windowNumber: host.window().windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            divider.mouseDown(with: down)
            measurementDragOrigin = origin
        }
        guard let origin = measurementDragOrigin,
              let event = NSEvent.mouseEvent(with: finished ? .leftMouseUp : .leftMouseDragged,
                                             location: NSPoint(x: origin.x + delta, y: origin.y), modifierFlags: [], timestamp: 0,
                                             windowNumber: host.window().windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
        if finished { divider.mouseUp(with: event); measurementDragOrigin = nil }
        else { divider.mouseDragged(with: event) }
        return true
    }

    public func refresh() { publish() }

    public func checkSelectionState() -> [String: Any] {
        precondition(Thread.isMainThread)
        let generation = selectionGeneration
        return queue.sync {
            ["generation": generation, "pending_commands": pendingSelectionCommands.sorted(),
             "dropped_transactions": store.map { $0.liveDropped() } as Any? ?? NSNull()]
        }
    }

    func tab(_ id: String) -> (any ARTabAPI)? {
        (host?.tabs() as? [any ARTabAPI])?.first { $0.liveId == id }
    }

    func cancelPendingOpen(_ id: String) -> Bool {
        guard host?.cancelPendingOpen(id) == true else { return false }
        openingSelections.removeValue(forKey: id)
        queue.async { self.pendingSelectionCommands.remove(id) }
        return true
    }

    private func cancelSelectionCommand(_ command: LiveCommand) {
        guard command.kind == .open || command.kind == .activate else { return }
        DispatchQueue.main.async {
            self.pendingSplitOpens.removeValue(forKey: command.id)
            if let live = self.queue.sync(execute: { self.store?.liveTab(item: command.item) }) {
                self.session.cancelTransfer(live, destination: self.windowID)
            }
            self.restoringSplitCommands.remove(command.id)
            if self.restoringTargetCommand == command.id { self.restoringTargetCommand = nil }
            self.maybeFinishCrashRecovery()
        }
        queue.async {
            self.pendingSelectionCommands.remove(command.id)
            _ = self.store?.liveCancel(commandId: command.id)
            self.publish()
        }
    }

    private func openSplitSiblings(_ panes: [SplitPane], context: SelectionContext) {
        precondition(Thread.isMainThread)
        if context.restoring != nil { restoringSplitPreparing = true }
        queue.async {
            var commands: [LiveCommand] = []
            var remote: [(String, String)] = []
            if let store = self.store {
                for pane in panes {
                    if let live = store.liveTab(item: pane.id) {
                        if let owner = store.liveWindow(item: pane.id), owner != self.windowID { remote.append((pane.id, live)) }
                        continue
                    }
                    guard let url = pane.url else { continue }
                    do {
                        let command = try store.liveOpen(item: pane.id, url: url)
                        self.pendingSelectionCommands.insert(command.id)
                        commands.append(command)
                    } catch { self.report(error) }
                }
            }
            let prepared = commands
            let remoteTabs = remote
            DispatchQueue.main.async {
                self.restoringSplitPreparing = false
                if self.selectionGeneration == context.generation {
                    if context.restoring != nil {
                        self.restoringSplitCommands.formUnion(prepared.map(\.id))
                        self.restoringSplitMoves.formUnion(remoteTabs.map { $0.1 })
                    }
                    for command in prepared { self.execute(command, selection: context, background: true) }
                    for (item, live) in remoteTabs {
                        self.session.beginTransfer(live, destination: self.windowID)
                        if let tab = self.session.tab(live) { self.session.captureSnapshot(tab, item: item) }
                        self.transferBackground(item: item, live: live, context: context, deadline: .now() + 5)
                    }
                } else {
                    for command in prepared { self.cancelSelectionCommand(command) }
                }
                self.maybeFinishCrashRecovery()
            }
        }
    }

    private func transferBackground(item: String, live: String, context: SelectionContext, deadline: DispatchTime) {
        precondition(Thread.isMainThread)
        guard selectionGeneration == context.generation, let host, !host.isClosing(), !host.isClosingAll(),
              host.profileDirectory() == context.profile,
              queue.sync(execute: { store?.liveTab(item: item) == live && store?.snapshot(windowId: windowID).shownSpaceId == context.space }) else {
            session.cancelTransfer(live, destination: windowID); restoringSplitMoves.remove(live); maybeFinishCrashRecovery(); return
        }
        if tab(live) != nil { restoringSplitMoves.remove(live); maybeFinishCrashRecovery(); return }
        if let remote = session.tab(live), (host as AnyObject).responds(to: #selector(ARWindowHostAPI.handoffTab(_:activate:))),
           host.handoffTab(remote, activate: false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if self.restoringSplitMoves.remove(live) != nil { self.maybeFinishCrashRecovery() }
            }
            return
        }
        guard DispatchTime.now() < deadline else { session.cancelTransfer(live, destination: windowID); restoringSplitMoves.remove(live); maybeFinishCrashRecovery(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.transferBackground(item: item, live: live, context: context, deadline: deadline)
        }
    }

    private func maybeFinishCrashRecovery() {
        if recoveryDispatched && restoringTargetCommand == nil && restoringSplitCommands.isEmpty && restoringSplitMoves.isEmpty && !restoringSplitPreparing {
            finishCrashRecovery()
        }
    }

    private func takeRemoteSelection() {
        precondition(Thread.isMainThread)
        guard !restoringSelection, let host, !host.isClosing(), !host.isClosingAll() else { return }
        let candidate: (String, String)? = queue.sync {
            guard let store else { return nil }
            let snapshot = store.snapshot(windowId: windowID)
            guard let id = snapshot.selectedId,
                  let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
                  let row = (space.today + space.pinned + space.favorites).first(where: { $0.id == id }),
                  let url = row.url else { return nil }
            func hasRemote(_ pane: SplitPane) -> Bool {
                if pane.kind == .tab, let owner = store.liveWindow(item: pane.id), owner != windowID { return true }
                return pane.children.contains(where: hasRemote)
            }
            let owner = store.liveWindow(item: id)
            let remoteSplit = store.splitLayout(itemId: id).map(hasRemote) ?? false
            return owner != windowID || remoteSplit ? (id, url) : nil
        }
        if let (id, url) = candidate { select(id: id, url: url) }
    }

    private func selectionDispatchForCheck(_ stage: String, command: LiveCommand, action: @escaping () -> Void) {
        if let checkSelectionDispatch, command.kind == .activate { checkSelectionDispatch(stage, command.id, action) }
        else { action() }
    }

    private func execute(_ command: LiveCommand, external: Bool? = nil, selection: SelectionContext? = nil, background: Bool = false) {
        precondition(Thread.isMainThread)
        guard let host else {
            cancelSelectionCommand(command)
            return
        }
        switch command.kind {
        case .open:
            let opening: (String, HistoryAdmission)? = queue.sync {
                guard self.pendingSelectionCommands.remove(command.id) != nil else { return nil }
                guard let store = self.store, let profile = store.itemProfile(itemId: command.item) else { return nil }
                let directory: String
                switch profile { case .default: directory = "Default"; case .named(let name): directory = name }
                return (directory, store.historyAdmission(item: command.item))
            }
            guard let (profile, admission) = opening, !host.isClosing(), !host.isClosingAll() else {
                cancelSelectionCommand(command)
                return
            }
            if let url = command.url {
                if let selection { openingSelections[command.id] = selection }
                for purge in admission.purges { session.submitHistoryPurge(purge) }
                let accepted: Bool
                if background {
                    accepted = (host as AnyObject).responds(to: #selector(ARWindowHostAPI.openBackgroundURL(_:commandId:itemId:profile:historyStamp:))) &&
                        host.openBackgroundURL(url, commandId: command.id, itemId: command.item, profile: profile, historyStamp: admission.stamp)
                } else {
                    accepted = host.openURL(url, commandId: command.id, itemId: command.item, profile: profile,
                                            external: external != nil, untrusted: external ?? false, historyStamp: admission.stamp)
                }
                if accepted { return }
                openingSelections.removeValue(forKey: command.id)
            }
            cancelSelectionCommand(command)
        case .activate, .close:
            if command.kind == .close,
               let target = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == command.item }) {
                target.close(withCommandId: command.id)
                return
            }
            queue.async {
                guard let id = self.store?.liveTab(item: command.item) else {
                    self.cancelSelectionCommand(command)
                    return
                }
                DispatchQueue.main.async {
                    if command.kind == .activate {
                        self.selectionDispatchForCheck("resolved", command: command) {
                            if self.tab(id) == nil, let remote = self.session.tab(id) {
                                self.session.beginTransfer(id, destination: self.windowID)
                                self.session.captureSnapshot(remote, item: command.item)
                            }
                            self.dispatchActivation(command, live: id, host: host, selection: selection,
                                                    deadline: .now() + 5, retrying: false)
                        }
                    } else { self.session.tab(id)?.close(withCommandId: command.id) }
                }
            }
        }
    }

    private func dispatchActivation(_ command: LiveCommand, live: String, host: any ARWindowHostAPI,
                                    selection: SelectionContext?, deadline: DispatchTime, retrying: Bool) {
        precondition(Thread.isMainThread)
        guard let current = self.host, (current as AnyObject) === (host as AnyObject),
              !current.isClosing(), !current.isClosingAll(),
              selection.map({ context in
                  self.selectionGeneration == context.generation && current.profileDirectory() == context.profile &&
                  self.queue.sync { self.store?.snapshot(windowId: self.windowID).shownSpaceId == context.space }
              }) ?? true,
              queue.sync(execute: { self.store?.liveTab(item: command.item) == live && self.pendingSelectionCommands.contains(command.id) })
        else { cancelSelectionCommand(command); return }
        if let local = tab(live) {
            queue.sync { _ = pendingSelectionCommands.remove(command.id) }
            checkSelectionActivated?(command.id)
            local.activate(withCommandId: command.id)
            return
        }
        let remote = session.tab(live)
        let supported = (current as AnyObject).responds(to: #selector(ARWindowHostAPI.transferTab(_:commandId:)))
        if let remote, supported, current.transferTab(remote, commandId: command.id) {
            queue.sync { _ = pendingSelectionCommands.remove(command.id) }
            checkSelectionActivated?(command.id)
            return
        }
        guard supported, (remote != nil || retrying), DispatchTime.now() < deadline else { cancelSelectionCommand(command); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
            self.dispatchActivation(command, live: live, host: host, selection: selection, deadline: deadline, retrying: true)
        }
    }

    public func windowHost(_ host: any ARWindowHostAPI, shouldOpenCommand commandId: String, itemId: String) -> Bool {
        precondition(Thread.isMainThread)
        guard let current = self.host, (current as AnyObject) === (host as AnyObject),
              !current.isClosing(), !current.isClosingAll() else { return false }
        let context = openingSelections[commandId]
        guard context.map({ $0.generation == selectionGeneration }) ?? true else { return false }
        return queue.sync {
            guard let store = self.store, store.liveTab(item: itemId) == commandId else { return false }
            guard let context else { return true }
            let snapshot = store.snapshot(windowId: self.windowID)
            return snapshot.shownSpaceId == context.space &&
                snapshot.spaces.first(where: { $0.id == context.space })?.profileName == context.profile &&
                (context.restoring == nil || store.restorationCandidate(windowId: self.windowID) == context.restoring)
        }
    }

    private func shownProfileDirectory() -> String? {
        guard let snapshot = store?.snapshot(windowId: windowID),
              let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) else { return nil }
        switch space.profile {
        case .default: return "Default"
        case .named(let name): return name
        }
    }

    private func report(_ error: Error) {
        FileHandle.standardError.write(Data("engine adapter: \(error)\n".utf8))
    }

    private func invalidTransaction() {
        FileHandle.standardError.write(Data("engine adapter: invalid transaction\n".utf8))
    }
}

// R1/D2: a loaded pin's ⌘W unloads it and keeps the pin; a Today tab or an unloaded pin
// archives; a favourite and a split close. The row's load state decides, never the selection.
public func rowCloseArchives(_ row: Row, in space: SpaceSnapshot) -> Bool {
    // archive_item takes tabs only: a split (or a duplicated, unloaded split) closes.
    if row.kind == .split { return false }
    if space.favorites.contains(where: { $0.id == row.id }) { return false }
    if row.unloaded { return true }
    if space.today.contains(where: { $0.id == row.id }) && row.kind == .tab { return true }
    return false
}

// A member of a split is closed through the split's row.
public func splitOwner(_ id: String, rows: [Row]) -> String {
    guard let row = rows.first(where: { $0.id == id }) else { return id }
    var current = row
    var parent = rows.first { $0.id == current.parentId }
    for _ in rows.indices {
        guard let ancestor = parent else { break }
        if ancestor.kind == .split { return ancestor.id }
        current = ancestor
        parent = rows.first { $0.id == current.parentId }
    }
    return id
}
