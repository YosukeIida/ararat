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

    public init(path: String, windowID: String, card: NSView, seedCheck: Bool = false, seedSingleCheck: Bool = false, session: WorkspaceSession = WorkspaceSession()) throws {
        self.session = session
        self.windowID = windowID
        self.card = card
        super.init()
        try queue.sync {
            let opened = try WorkspaceStore.open(path: path)
            let empty = opened.snapshot(windowId: windowID).spaces.isEmpty
            if (seedCheck || seedSingleCheck) && !empty {
                throw NSError(domain: "Ararat.slice", code: 1)
            }
            if empty {
                _ = try opened.createSpace(windowId: windowID, name: "Space", spaceId: UUID().uuidString)
            }
            if seedCheck || seedSingleCheck {
                for name in seedSingleCheck ? ["One"] : ["One", "Two", "Three"] {
                    _ = try opened.createTab(windowId: windowID, url: "data:text/html,<title>Ararat \(name)</title>")
                }
            }
            store = opened
        }
    }

    public func attach(_ host: any ARWindowHostAPI) {
        precondition(Thread.isMainThread)
        self.host = host
        host.delegate = self
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
                guard let live = tab["live_id"] as? String, let item = tab["item"],
                      item is NSNull || item is String else {
                    invalidTransaction()
                    return
                }
                parsedTabs.append(LiveTab(liveId: live, item: item as? String))
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
            store = nil
        }
    }

    private func publish() {
        queue.async {
            guard let snapshot = self.store?.snapshot(windowId: self.windowID) else { return }
            DispatchQueue.main.async { self.onSnapshot?(snapshot) }
        }
    }

    private func tab(_ id: String) -> (any ARTabAPI)? {
        (host?.tabs() as? [any ARTabAPI])?.first { $0.liveId == id }
    }

    private func execute(_ command: LiveCommand) {
        precondition(Thread.isMainThread)
        guard let host else { return }
        switch command.kind {
        case .open:
            if let url = command.url, host.openURL(url, commandId: command.id, itemId: command.item) { return }
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

    private func report(_ error: Error) {
        FileHandle.standardError.write(Data("engine adapter: \(error)\n".utf8))
    }

    private func invalidTransaction() {
        FileHandle.standardError.write(Data("engine adapter: invalid transaction\n".utf8))
    }
}
