import AppKit
import AraratKit

public final class WorkspaceAdapter: @unchecked Sendable {
    public typealias Completion<T> = @MainActor @Sendable (Result<T, Error>) -> Void
    public typealias Change = (id: String?, snapshot: WorkspaceSnapshot)

    private let session: WorkspaceSession
    private var queue: DispatchQueue { session.queue }
    private let windowID: String
    public let isPrivate: Bool
    private let spaceSwitchLock = NSLock()
    private var spaceSwitchGeneration: UInt64 = 0
    @MainActor public var checkSpaceSwitchCompletion: ((String, @escaping () -> Void) -> Void)?
    @MainActor var checkLookCompletion: ((@escaping () -> Void) -> Void)?
    private var store: WorkspaceStore? {
        get { session.store }
        set { session.store = newValue }
    }

    public init(windowID: String, session: WorkspaceSession = WorkspaceSession(), private isPrivate: Bool = false) {
        self.windowID = windowID
        self.session = session
        self.isPrivate = isPrivate
    }

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () throws -> T, completion: @escaping Completion<T>) {
        queue.async {
            let result = Result(catching: operation)
            self.session.drainHistoryPurges()
            // Why not dispatch main: AppKit's terminateLater loop cannot reenter its drain.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    public func open(path: String, json: @escaping @Sendable () throws -> String, windowsJSON: @escaping @Sendable () -> String?, keyBindingsJSON: @escaping @Sendable () -> String?, linkRoutingJSON: @escaping @Sendable () -> String?, ownerProfile: Profile? = nil, onImport: @escaping @Sendable (ImportReport) -> Void = { _ in }, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({
            let opened = try WorkspaceStore.open(path: path)
            self.store = opened
            let snapshot = opened.snapshot(windowId: self.windowID)
            guard snapshot.spaces.isEmpty else { return snapshot }
            let imported = try opened.importArcSidebar(windowId: self.windowID, json: json(), windowsJson: windowsJSON(), keyBindingsJson: keyBindingsJSON(), linkRoutingJson: linkRoutingJSON(), ownerProfile: ownerProfile)
            onImport(imported.report)
            return imported.snapshot
        }, completion: completion)
    }

    // The edits write one op batch each and flush before the
    // fresh routing is returned, so a pane model always sees what a reopen would read.
    public func routing(completion: @escaping Completion<Routing>) {
        enqueue({ try self.opened().routing() }, completion: completion)
    }

    public func route(url: String, completion: @escaping Completion<RoutingDecision>) {
        enqueue({ try self.opened().route(url: url) }, completion: completion)
    }

    // The "Deleted space" menu items read the core's one answer, not a Swift-side compare.
    public func deletedSpaces(completion: @escaping Completion<[DeletedDestination]>) {
        enqueue({ try self.opened().deletedSpaceDestinations() }, completion: completion)
    }

    public func addRule(_ rule: Rule, completion: @escaping Completion<Routing>) {
        enqueue({
            let store = try self.opened()
            _ = try store.addRule(windowId: self.windowID, rule: rule)
            return store.routing()
        }, completion: completion)
    }

    public func editRule(_ rule: Rule, completion: @escaping Completion<Routing>) {
        enqueue({
            let store = try self.opened()
            _ = try store.editRule(windowId: self.windowID, rule: rule)
            return store.routing()
        }, completion: completion)
    }

    public func deleteRule(id: String, completion: @escaping Completion<Routing>) {
        enqueue({
            let store = try self.opened()
            _ = try store.deleteRule(windowId: self.windowID, id: id)
            return store.routing()
        }, completion: completion)
    }

    public func moveRule(id: String, to index: Int, completion: @escaping Completion<Routing>) {
        enqueue({
            let store = try self.opened()
            _ = try store.moveRule(windowId: self.windowID, id: id, index: UInt32(index))
            return store.routing()
        }, completion: completion)
    }

    public func setDefaultDestination(_ destination: Destination, completion: @escaping Completion<Routing>) {
        enqueue({
            let store = try self.opened()
            _ = try store.setDefaultDestination(windowId: self.windowID, destination: destination)
            return store.routing()
        }, completion: completion)
    }

    public func keyBindings(completion: @escaping Completion<[KeyBinding]>) {
        enqueue({ try self.opened().keyBindings() }, completion: completion)
    }

    public func setKeyBinding(command: String, key: KeyCombination?, completion: @escaping Completion<[KeyBinding]>) {
        enqueue({ try self.opened().setKeyBinding(command: command, key: key) }, completion: completion)
    }

    public func resetKeyBinding(command: String, completion: @escaping Completion<[KeyBinding]>) {
        enqueue({ try self.opened().resetKeyBinding(command: command) }, completion: completion)
    }

    public func resetAllKeyBindings(completion: @escaping Completion<[KeyBinding]>) {
        enqueue({ try self.opened().resetAllKeyBindings() }, completion: completion)
    }

    public func autoArchive(now: UInt64, completion: @escaping Completion<WorkspaceSnapshot?>) {
        enqueue({ try self.opened().autoArchive(windowId: self.windowID, now: now) }, completion: completion)
    }

    public func setArchiveAfter(spaceID: String, value: ArchiveAfter, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().setArchiveAfter(windowId: self.windowID, spaceId: spaceID, value: value) }, completion: completion)
    }

    public func snapshot(completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().snapshot(windowId: self.windowID) }, completion: completion)
    }

    public func move(id: String, container: String, index: Int, openFolder: Bool, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({
            let store = try self.opened()
            return try store.moveItem(windowId: self.windowID, id: id, container: container, index: UInt32(index), openFolder: openFolder)
        }, completion: completion)
    }

    public func firstFavorite(id: String, space: String, index: Int, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({
            let store = try self.opened()
            let snapshot = try store.ensureFavorites(windowId: self.windowID, spaceId: space, containerId: UUID().uuidString)
            guard let container = snapshot.spaces.first(where: { $0.id == space })?.favoritesId else { throw CoreError.Edit(message: "favorites container missing") }
            return try store.moveItem(windowId: self.windowID, id: id, container: container, index: UInt32(index), openFolder: false)
        }, completion: completion)
    }

    public func moveIfLive(id: String, container: String, index: Int, openFolder: Bool, expectedLive: String, completion: @escaping Completion<WorkspaceSnapshot?>) {
        enqueue({
            let store = try self.opened()
            guard store.liveTab(item: id) == expectedLive else { return nil }
            return try store.moveItem(windowId: self.windowID, id: id, container: container, index: UInt32(index), openFolder: openFolder)
        }, completion: completion)
    }

    public func openFolder(id: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().setFolderCollapsed(windowId: self.windowID, id: id, collapsed: false) }, completion: completion)
    }

    public func select(id: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().selectItem(windowId: self.windowID, id: id) }, completion: completion)
    }

    public func createSpace(name: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().createSpace(windowId: self.windowID, name: name, spaceId: UUID().uuidString) }, completion: completion)
    }

    public func deleteArchive(id: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().deleteArchiveItem(windowId: self.windowID, id: id) }, completion: completion)
    }

    public func restore(id: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().restoreItem(windowId: self.windowID, id: id) }, completion: completion)
    }

    public func showSpace(id: String, completion: @escaping Completion<Void>) {
        enqueue({ try self.opened().showSpace(windowId: self.windowID, spaceId: id) }, completion: completion)
    }

    public func showSpaceSelecting(id: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        let generation = spaceSwitchLock.withLock { spaceSwitchGeneration }
        enqueue({
            try self.spaceSwitchLock.withLock {
                guard self.spaceSwitchGeneration == generation else { throw CoreError.Edit(message: "space switch cancelled") }
                return try self.opened().showSpaceSelecting(windowId: self.windowID, spaceId: id)
            }
        }, completion: { result in
            if case .success = result, let check = self.checkSpaceSwitchCompletion { check("space", { completion(result) }) }
            else { completion(result) }
        })
    }

    public func showSpaceSelectingTab(id: String, item: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        let generation = spaceSwitchLock.withLock { spaceSwitchGeneration }
        enqueue({
            try self.spaceSwitchLock.withLock {
                guard self.spaceSwitchGeneration == generation else { throw CoreError.Edit(message: "space switch cancelled") }
                return try self.opened().showSpaceSelectingTab(windowId: self.windowID, spaceId: id, itemId: item)
            }
        }, completion: { result in
            if case .success = result, let check = self.checkSpaceSwitchCompletion { check("tab", { completion(result) }) }
            else { completion(result) }
        })
    }

    public func cancelPendingSpaceSwitches() {
        spaceSwitchLock.withLock { spaceSwitchGeneration &+= 1 }
    }

    /// The command bar's per-open session: the index is built once per open and dropped with it.
    /// A private window's session withholds history rows and marks its results (U23 D7).
    public func commandBarSession(privateWindow: Bool = false, completion: @escaping Completion<CommandBarSession>) {
        enqueue({ try self.opened().commandBarSession(windowId: self.windowID, privateWindow: privateWindow) }, completion: completion)
    }

    /// The shown space's most recently selected tabs, newest first: the ⌃Tab switcher's list.
    public func recentTabs(limit: UInt32 = 5, completion: @escaping Completion<[Suggestion]>) {
        enqueue({ try self.opened().recentTabs(windowId: self.windowID, limit: limit) }, completion: completion)
    }

    public func createTab(url: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().createTab(windowId: self.windowID, url: url) }, completion: completion)
    }

    public func setTabURL(id: String, url: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().setTabUrl(windowId: self.windowID, id: id, url: url) }, completion: completion)
    }

    public func close(id: String, completion: @escaping Completion<Change>) {
        enqueue({ (id, try self.opened().closeItem(windowId: self.windowID, id: id)) }, completion: completion)
    }

    public func archive(id: String, completion: @escaping Completion<Change>) {
        enqueue({ (id, try self.opened().archiveItem(windowId: self.windowID, id: id)) }, completion: completion)
    }

    public func closeSelected(completion: @escaping Completion<Change>) {
        enqueue({
            let store = try self.opened()
            let before = store.snapshot(windowId: self.windowID)
            guard let id = before.selectedId else { return (nil, before) }
            let rows = before.spaces.flatMap { $0.today + $0.pinned + $0.favorites }
            let item = splitOwner(id, rows: rows)
            let row = rows.first { $0.id == item }
            let space = before.spaces.first { $0.id == before.shownSpaceId }
            let archive = self.isPrivate ? false : (row.flatMap { row in space.map { rowCloseArchives(row, in: $0) } } ?? false)
            return (item, try archive ? store.archiveItem(windowId: self.windowID, id: item) : store.closeItem(windowId: self.windowID, id: item))
        }, completion: completion)
    }

    public func flush(completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({
            let store = try self.opened()
            try store.flush()
            return store.snapshot(windowId: self.windowID)
        }, completion: completion)
    }

    public func shutdown(completion: @escaping Completion<Void>) {
        enqueue({
            defer { self.store = nil }
            try self.store?.flush()
        }, completion: completion)
    }

    private func opened() throws -> WorkspaceStore {
        guard let store else { throw CoreError.Store(message: "workspace is not open") }
        return store
    }
}

extension WorkspaceAdapter {
    @MainActor
    public func setSpaceLook(id: String, look: Look?, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().setSpaceLook(windowId: self.windowID, spaceId: id, look: look) }) { result in
            if let hold = self.checkLookCompletion { hold { completion(result) } } else { completion(result) }
        }
    }

    public func renameSpace(id: String, name: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().renameSpace(windowId: self.windowID, spaceId: id, name: name) }, completion: completion)
    }
    public func setSpaceIcon(id: String, icon: String?, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().setSpaceIcon(windowId: self.windowID, spaceId: id, icon: icon) }, completion: completion)
    }
    public func moveSpace(id: String, index: Int, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().moveSpace(windowId: self.windowID, spaceId: id, index: UInt32(index)) }, completion: completion)
    }
    public func deleteSpace(id: String, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({ try self.opened().deleteSpace(windowId: self.windowID, spaceId: id) }, completion: completion)
    }
}

public enum SidebarItemEdit: Sendable {
    case duplicate(id: String)
    case createFolder(id: String, container: String, index: Int)
    case rename(id: String, title: String, folder: Bool)
    case collapse(id: String, collapsed: Bool)
    case deleteFolder(id: String)
    case collapseSection(spaceID: String, collapsed: Bool)
}

extension WorkspaceAdapter {
    public func edit(_ edit: SidebarItemEdit, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({
            let store = try self.opened()
            switch edit {
            case let .duplicate(id):
                return try store.duplicateItem(windowId: self.windowID, id: id)
            case let .createFolder(id, container, index):
                return try store.createFolder(windowId: self.windowID, id: id, name: "Untitled", container: container, index: UInt32(index), wrapping: [])
            case let .rename(id, title, folder):
                if folder { return try store.renameFolder(windowId: self.windowID, id: id, name: title) }
                return try store.renameTab(windowId: self.windowID, id: id, title: title)
            case let .collapse(id, collapsed):
                return try store.setFolderCollapsed(windowId: self.windowID, id: id, collapsed: collapsed)
            case let .deleteFolder(id):
                return try store.deleteFolder(windowId: self.windowID, id: id)
            case let .collapseSection(spaceID, collapsed):
                return try store.setSectionCollapsed(windowId: self.windowID, spaceId: spaceID, collapsed: collapsed)
            }
        }, completion: completion)
    }
}

extension WorkspaceAdapter {
    public func newTabRowShown(completion: @escaping Completion<Bool>) {
        enqueue({ try self.opened().settings().newTabRowShown }, completion: completion)
    }
}

extension WorkspaceAdapter {
    /// U27h: the profile's most recent space, the Little Window's default destination until
    /// U27i adds the setting.
    public func recentSpace(profile: String, completion: @escaping Completion<String?>) {
        enqueue({
            try self.opened().recentSpaceForProfile(windowId: self.windowID,
                                                    profile: profile == "Default" ? .default : .named(profile))
        }, completion: completion)
    }

    /// U27h D8: the Little Window's frame is a device record, read and written through the
    /// store so a reopen reads what the last close wrote.
    public func littleWindowFrame(completion: @escaping Completion<LittleWindowFrame?>) {
        enqueue({ try self.opened().littleWindowFrame() }, completion: completion)
    }

    public func setLittleWindowFrame(_ frame: LittleWindowFrame?, completion: @escaping Completion<Void> = { _ in }) {
        enqueue({ try self.opened().setLittleWindowFrame(frame: frame) }, completion: completion)
    }
}
