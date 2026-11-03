import AppKit
import AraratKit

public final class WorkspaceAdapter: @unchecked Sendable {
    public typealias Completion<T> = @MainActor @Sendable (Result<T, Error>) -> Void
    public typealias Change = (id: String?, snapshot: WorkspaceSnapshot)

    private let queue = DispatchQueue(label: "Ararat.workspace")
    private let windowID: String
    private var store: WorkspaceStore?

    public init(windowID: String) { self.windowID = windowID }

    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () throws -> T, completion: @escaping Completion<T>) {
        queue.async {
            let result = Result(catching: operation)
            // Why not dispatch main: AppKit's terminateLater loop cannot reenter its drain.
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    public func open(path: String, json: @escaping @Sendable () throws -> String, windowsJSON: @escaping @Sendable () -> String?, onImport: @escaping @Sendable (ImportReport) -> Void = { _ in }, completion: @escaping Completion<WorkspaceSnapshot>) {
        enqueue({
            let opened = try WorkspaceStore.open(path: path)
            self.store = opened
            let snapshot = opened.snapshot(windowId: self.windowID)
            guard snapshot.spaces.isEmpty else { return snapshot }
            let imported = try opened.importArcSidebar(windowId: self.windowID, json: json(), windowsJson: windowsJSON())
            onImport(imported.report)
            return imported.snapshot
        }, completion: completion)
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
            return (id, try store.closeItem(windowId: self.windowID, id: id))
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
        enqueue({ try self.opened().setSpaceLook(windowId: self.windowID, spaceId: id, look: look) }, completion: completion)
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
            }
        }, completion: completion)
    }
}
