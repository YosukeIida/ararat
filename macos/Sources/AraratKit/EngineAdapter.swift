import AppKit
import AraratEngineAPI

public final class EngineAdapter: NSObject, ARWindowHostDelegate {
    private struct SelectionContext {
        let generation: Int
        let space: String?
        let profile: String?
    }
    public let session: WorkspaceSession
    private var queue: DispatchQueue { session.queue }
    private var store: WorkspaceStore? {
        get { session.store }
        set { session.store = newValue }
    }
    private let windowID: String
    private let card: NSView
    private weak var host: (any ARWindowHostAPI)?
    private var selectionGeneration = 0
    private var pendingSelectionCommands: Set<String> = []
    public var onSnapshot: (@MainActor (WorkspaceSnapshot) -> Void)?
    public var onTransaction: (@MainActor (LiveTransaction, Bool) -> Void)?
    public var onWorkspaceChange: (@MainActor () -> Void)?
    public var onQuitProfileSwitch: (@MainActor () -> Void)?
    public var onCloseStarted: (@MainActor () -> Void)?
    public var onUnsupportedSplit: (@MainActor () -> Void)?
    public var onPageFullscreenChanged: (@MainActor (Bool) -> Void)?
    public var onWindowFullscreenChanged: (@MainActor (Bool) -> Void)?
    public var onWorkspaceCommand: (@MainActor (String) -> Void)?
    public var onFindBar: (@MainActor ([String: Any]) -> Void)?
    public var findBarHasFocus: (@MainActor () -> Bool)?
    public var onFindPageRect: (@MainActor (NSRect) -> Void)?
    public var checkSelectionDispatch: ((String, String, @escaping () -> Void) -> Void)?
    public var checkSelectionActivated: ((String) -> Void)?
    public var checkSelectionCommand: ((String, String, Bool) -> Void)?

    public init(path: String, windowID: String, card: NSView, seedCheck: Bool = false, seedSingleCheck: Bool = false, seedLinkCheck: Bool = false, seedProfiles: Bool = false, seedSplitCheck: Bool = false, profileCheckURL: String = "about:blank", singleCheckURL: String? = nil, session: WorkspaceSession = WorkspaceSession()) throws {
        self.session = session
        self.windowID = windowID
        self.card = card
        super.init()
        try queue.sync {
            let opened = try store ?? WorkspaceStore.open(path: path)
            let empty = opened.snapshot(windowId: windowID).spaces.isEmpty
            if (seedCheck || seedSingleCheck || seedLinkCheck || seedProfiles) && !empty {
                throw NSError(domain: "Ararat.slice", code: 1)
            }
            if seedProfiles {
                var json = """
                {"sidebar":{"containers":[{"global":{}},{"spaces":["default",{"id":"default","title":"Default","profile":{"default":true},"containerIDs":["pinned","pin-default","unpinned","today-default"]},"named",{"id":"named","title":"Profile 1","profile":{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"containerIDs":["pinned","pin-named","unpinned","today-named"]}],"topAppsContainerIDs":[],"items":["pin-default",{"id":"pin-default","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"default"}}}}},"today-default",{"id":"today-default","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"default"}}}}},"pin-named",{"id":"pin-named","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"named"}}}}},"today-named",{"id":"today-named","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"named"}}}}}]}]}}
                """
                if seedSplitCheck {
                    let old = "\"pin-named\",{\"id\":\"pin-named\",\"parentID\":null,\"childrenIds\":[]"
                    let replacement = "\"pin-named\",{\"id\":\"pin-named\",\"parentID\":null,\"childrenIds\":[\"close-split\"]"
                    guard json.contains(old) else { throw NSError(domain: "Ararat.split-check", code: 1) }
                    json = json.replacingOccurrences(of: old, with: replacement)
                    let marker = "\"today-named\",{\"id\":\"today-named\""
                    let split = """
                    "close-split",{"id":"close-split","parentID":"pin-named","childrenIds":["close-split-a","close-split-b"],"data":{"splitView":{"layoutOrientation":"horizontal","itemWidthFactors":["close-split-a",0.5,"close-split-b",0.5]}}},"close-split-a",{"id":"close-split-a","parentID":"close-split","childrenIds":[],"data":{"tab":{"savedURL":"about:blank","savedTitle":"A"}}},"close-split-b",{"id":"close-split-b","parentID":"close-split","childrenIds":[],"data":{"tab":{"savedURL":"about:blank","savedTitle":"B"}}},
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
        let profile = queue.sync { self.shownProfileDirectory() }
        host.delegate = self
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

    public func select(id: String, url: String) {
        precondition(Thread.isMainThread)
        invalidateSelection()
        let generation = selectionGeneration
        queue.async {
            do {
                guard let store = self.store else { return }
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
                self.pendingSelectionCommands.insert(command.id)
                DispatchQueue.main.async {
                    self.selectionDispatchForCheck("registered", command: command) {
                        guard self.selectionGeneration == generation,
                              self.queue.sync(execute: { self.store?.snapshot(windowId: self.windowID).shownSpaceId == selectedSpace }) else {
                            self.cancelSelectionCommand(command)
                            return
                        }
                        self.checkSelectionCommand?(id, command.id, needsOpen)
                        self.execute(command, selection: SelectionContext(generation: generation, space: selectedSpace, profile: selectedProfile))
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
        queue.async {
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

    public func close(id: String, archive: Bool = false, expectedLive: String? = nil) {
        queue.async {
            do {
                guard let store = self.store else { return }
                if let expectedLive, store.liveTab(item: id) != expectedLive { return }
                guard let liveID = store.liveTab(item: id) else {
                    let snapshot = try archive
                        ? store.archiveItem(windowId: self.windowID, id: id)
                        : store.closeItem(windowId: self.windowID, id: id)
                    DispatchQueue.main.async { self.deliverIfCurrent(snapshot) }
                    return
                }
                let command = try archive ? store.liveArchive(item: id) : store.liveClose(item: id)
                DispatchQueue.main.async { self.tab(liveID)?.close(withCommandId: command.id) }
            } catch { self.report(error) }
        }
    }

    public func pageCard(forWindowHost host: any ARWindowHostAPI) -> NSView { card }

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
                if let coreError = error as? CoreError, case .UnsupportedSplit = coreError { DispatchQueue.main.async { self.onUnsupportedSplit?() } }
                else { self.report(error) }
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
        invalidateSelection()
        MainActor.assumeIsolated { onCloseStarted?() }
    }

    public func windowHostClosingAllCancelled(_ host: any ARWindowHostAPI) {
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
        do { return try store.showSpaceSelecting(windowId: windowID, spaceId: space) }
        catch CoreError.UnsupportedSplit { return current }
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
        } else if value["cause"] as? String == "Chrome" {
            cause = .chrome
        } else if value["cause"] as? String == "Engine" {
            cause = .engine
        } else {
            invalidTransaction()
            return
        }
        var strips: [LiveStrip] = []
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
                      item is NSNull || item is String,
                      opener is NSNull || opener is String, url is NSNull || url is String,
                      title is NSNull || title is String else {
                    invalidTransaction()
                    return
                }
                parsedTabs.append(LiveTab(profile: profile == "Default" ? .default : .named(profile), liveId: live, item: item as? String,
                                          opener: opener as? String, navigated: navigated, url: url as? String, title: title as? String))
            }
            strips.append(LiveStrip(window: window, tabs: parsedTabs, active: active as? String))
        }
        let transaction = LiveTransaction(epoch: epoch.uint64Value, rev: rev.uint64Value, cause: cause, strips: strips)
        queue.async {
            do {
                guard let store = self.store else { return }
                let outcome = try store.liveApply(transaction: transaction)
                for command in outcome.commands where command.kind == .activate || command.kind == .open {
                    self.pendingSelectionCommands.insert(command.id)
                }
                let snapshot = store.snapshot(windowId: self.windowID)
                DispatchQueue.main.async {
                    for adopted in outcome.adopted {
                        self.tab(adopted.liveId)?.itemId = adopted.item
                    }
                    for command in outcome.commands { self.execute(command) }
                    self.deliverIfCurrent(snapshot)
                    self.onTransaction?(transaction, outcome.applied)
                    if outcome.applied { self.onWorkspaceChange?() }
                }
            } catch { self.report(error) }
        }
    }

    public func shutdown() {
        precondition(Thread.isMainThread)
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

    private func publish() {
        queue.async {
            guard let snapshot = self.store?.snapshot(windowId: self.windowID) else { return }
            DispatchQueue.main.async { self.deliverIfCurrent(snapshot) }
        }
    }

    @MainActor
    private func deliverIfCurrent(_ snapshot: WorkspaceSnapshot) {
        guard queue.sync(execute: { store?.snapshot(windowId: windowID) == snapshot }) else { return }
        onSnapshot?(snapshot)
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

    private func tab(_ id: String) -> (any ARTabAPI)? {
        (host?.tabs() as? [any ARTabAPI])?.first { $0.liveId == id }
    }

    private func cancelSelectionCommand(_ command: LiveCommand) {
        guard command.kind == .open || command.kind == .activate else { return }
        queue.async {
            self.pendingSelectionCommands.remove(command.id)
            _ = self.store?.liveCancel(commandId: command.id)
            self.publish()
        }
    }

    private func selectionDispatchForCheck(_ stage: String, command: LiveCommand, action: @escaping () -> Void) {
        if let checkSelectionDispatch, command.kind == .activate { checkSelectionDispatch(stage, command.id, action) }
        else { action() }
    }

    private func execute(_ command: LiveCommand, external: Bool? = nil, selection: SelectionContext? = nil) {
        precondition(Thread.isMainThread)
        guard let host else {
            cancelSelectionCommand(command)
            return
        }
        switch command.kind {
        case .open:
            let profile: String? = queue.sync {
                guard self.pendingSelectionCommands.remove(command.id) != nil else { return nil }
                guard let profile = self.store?.itemProfile(itemId: command.item) else { return nil }
                switch profile { case .default: return "Default"; case .named(let name): return name }
            }
            guard let profile, !host.isClosing(), !host.isClosingAll() else {
                cancelSelectionCommand(command)
                return
            }
            if let url = command.url {
                let accepted = host.openURL(url, commandId: command.id, itemId: command.item, profile: profile,
                                            external: external != nil, untrusted: external ?? false)
                if accepted { return }
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
                            guard let current = self.host, (current as AnyObject) === (host as AnyObject),
                                  !current.isClosing(), !current.isClosingAll(),
                                  selection.map({ context in
                                    self.selectionGeneration == context.generation && current.profileDirectory() == context.profile &&
                                      self.queue.sync { self.store?.snapshot(windowId: self.windowID).shownSpaceId == context.space }
                                  }) ?? true,
                                  self.queue.sync(execute: { self.store?.liveTab(item: command.item) == id && self.pendingSelectionCommands.remove(command.id) != nil }),
                                  let tab = self.tab(id) else { self.cancelSelectionCommand(command); return }
                            self.checkSelectionActivated?(command.id)
                            tab.activate(withCommandId: command.id)
                        }
                    } else { self.tab(id)?.close(withCommandId: command.id) }
                }
            }
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
