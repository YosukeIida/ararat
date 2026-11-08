import AppKit
import AraratEngineAPI

public final class EngineAdapter: NSObject, ARWindowHostDelegate {
    public let session: WorkspaceSession
    private var queue: DispatchQueue { session.queue }
    private var store: WorkspaceStore? {
        get { session.store }
        set { session.store = newValue }
    }
    private let windowID: String
    private let card: NSView
    private weak var host: (any ARWindowHostAPI)?
    public var onSnapshot: (@MainActor (WorkspaceSnapshot) -> Void)?
    public var onTransaction: (@MainActor (LiveTransaction) -> Void)?
    public var onWorkspaceChange: (@MainActor () -> Void)?
    public var onQuitProfileSwitch: (@MainActor () -> Void)?
    public var onPageFullscreenChanged: (@MainActor (Bool) -> Void)?
    public var onWindowFullscreenChanged: (@MainActor (Bool) -> Void)?

    public init(path: String, windowID: String, card: NSView, seedCheck: Bool = false, seedSingleCheck: Bool = false, seedLinkCheck: Bool = false, seedProfiles: Bool = false, profileCheckURL: String = "about:blank", singleCheckURL: String? = nil, session: WorkspaceSession = WorkspaceSession()) throws {
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
                let json = """
                {"sidebar":{"containers":[{"global":{}},{"spaces":["default",{"id":"default","title":"Default","profile":{"default":true},"containerIDs":["pinned","pin-default","unpinned","today-default"]},"named",{"id":"named","title":"Profile 1","profile":{"custom":{"_0":{"directoryBasename":"Profile 1"}}},"containerIDs":["pinned","pin-named","unpinned","today-named"]}],"topAppsContainerIDs":[],"items":["pin-default",{"id":"pin-default","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"default"}}}}},"today-default",{"id":"today-default","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"default"}}}}},"pin-named",{"id":"pin-named","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"named"}}}}},"today-named",{"id":"today-named","parentID":null,"childrenIds":[],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"named"}}}}}]}]}}
                """
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

    public func select(id: String, url: String) {
        queue.async {
            do {
                guard let store = self.store else { return }
                let needsOpen = store.liveTab(item: id) == nil
                if CommandLine.arguments.contains("--ararat-check=close") {
                    FileHandle.standardError.write(Data("ararat-trace: select-open=\(needsOpen)\n".utf8))
                }
                let command = try needsOpen
                    ? store.liveOpen(item: id, url: url)
                    : store.liveActivate(item: id)
                DispatchQueue.main.async { self.execute(command) }
            } catch {
                self.report(error)
            }
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
                        commands.append((try store.liveOpen(item: id, url: entry.url), entry.untrusted))
                    }
                    snapshot = current
                }
                DispatchQueue.main.async {
                    for (command, untrusted) in commands { self.execute(command, external: untrusted) }
                    if let snapshot { self.onSnapshot?(snapshot) }
                }
            } catch { self.report(error) }
        }
    }

    public func close(id: String, archive: Bool = false) {
        queue.async {
            do {
                guard let store = self.store else { return }
                guard let liveID = store.liveTab(item: id) else {
                    let snapshot = try archive
                        ? store.archiveItem(windowId: self.windowID, id: id)
                        : store.closeItem(windowId: self.windowID, id: id)
                    DispatchQueue.main.async { self.onSnapshot?(snapshot) }
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
        if host.isClosingAll() {
            _ = host.setProfileDirectory(profile)
            MainActor.assumeIsolated { onQuitProfileSwitch?() }
            return
        }
        let snapshot: WorkspaceSnapshot? = queue.sync {
            do {
                guard let store = self.store,
                      let space = store.recentSpaceForProfile(windowId: self.windowID, profile: profile == "Default" ? .default : .named(profile)) else { return nil }
                try store.showSpace(windowId: self.windowID, spaceId: space)
                return store.snapshot(windowId: self.windowID)
            } catch { self.report(error); return nil }
        }
        guard let snapshot, host.setProfileDirectory(profile) else { return }
        MainActor.assumeIsolated { onSnapshot?(snapshot) }
    }

    public func windowHostClosingAllCancelled(_ host: any ARWindowHostAPI) {
        let profile = host.profileDirectory()
        guard queue.sync(execute: { shownProfileDirectory() }) != profile else { return }
        windowHost(host, showProfile: profile)
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
                let snapshot = store.snapshot(windowId: self.windowID)
                DispatchQueue.main.async {
                    for adopted in outcome.adopted {
                        self.tab(adopted.liveId)?.itemId = adopted.item
                    }
                    for command in outcome.commands { self.execute(command) }
                    self.onSnapshot?(snapshot)
                    self.onTransaction?(transaction)
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
            DispatchQueue.main.async { self.onSnapshot?(snapshot) }
        }
    }

    public func refresh() { publish() }

    private func tab(_ id: String) -> (any ARTabAPI)? {
        (host?.tabs() as? [any ARTabAPI])?.first { $0.liveId == id }
    }

    private func execute(_ command: LiveCommand, external: Bool? = nil) {
        precondition(Thread.isMainThread)
        guard let host else {
            if command.kind == .open {
                queue.async { _ = self.store?.liveCancel(commandId: command.id); self.publish() }
            }
            return
        }
        switch command.kind {
        case .open:
            let profile: String? = queue.sync {
                guard let profile = self.store?.itemProfile(itemId: command.item) else { return nil }
                switch profile { case .default: return "Default"; case .named(let name): return name }
            }
            guard let profile else {
                queue.async { _ = self.store?.liveCancel(commandId: command.id); self.publish() }
                return
            }
            if let url = command.url {
                let accepted = host.openURL(url, commandId: command.id, itemId: command.item, profile: profile,
                                            external: external != nil, untrusted: external ?? false)
                if accepted { return }
            }
            queue.async {
                _ = self.store?.liveCancel(commandId: command.id)
                self.publish()
            }
        case .activate, .close:
            if command.kind == .close,
               let target = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == command.item }) {
                target.close(withCommandId: command.id)
                return
            }
            queue.async {
                guard let id = self.store?.liveTab(item: command.item) else { return }
                DispatchQueue.main.async {
                    if command.kind == .activate { self.tab(id)?.activate(withCommandId: command.id) }
                    else { self.tab(id)?.close(withCommandId: command.id) }
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
