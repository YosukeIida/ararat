import AppKit
import AraratKit

@MainActor
public final class SidebarActions {
    public var onItemEdit: ((SidebarItemEdit, @escaping (WorkspaceSnapshot?) -> Void) -> Void)?
    public var confirmFolderDeletion: ((Row, @escaping (Bool) -> Void) -> Void)?
    public var onSelect: ((Row) -> Void)?
    public var onMove: ((String, String, Int, Bool, @escaping (WorkspaceSnapshot?) -> Void) -> Void)?
    var onFolderDragRows: ((String, @escaping ([Row]) -> Void) -> Void)?
    public var onClose: ((String) -> Void)?
    public var onCloseSelected: (() -> Void)?
    public var onArchive: ((String) -> Void)?
    public var onRemoveFavorite: ((String) -> Void)?
    public var onNewTab: (() -> Void)?
    public var onClearToday: (() -> Void)?
    public var onShowSpace: ((String) -> Void)?
    public var onRestore: ((String) -> Void)?
    public var onClearArchive: (() -> Void)?
    public var onArchiveDelete: ((String) -> Void)?
    public var onCreateSpace: ((String) -> Void)?
    public var onRenameSpace: ((String, String, @escaping (Bool) -> Void) -> Void)?
    public var onDeleteSpace: ((String) -> Void)?
    public var onSpaceSettings: ((String) -> Void)?
    public var lookSettings: SettingsModel?
    public var onCreatePageChanged: (() -> Void)?

    public init() {}

    public func configureEditing(adapter: WorkspaceAdapter,
                                 isActive: @escaping () -> Bool,
                                 window: @escaping () -> NSWindow?,
                                 show: @escaping (WorkspaceSnapshot) -> Void,
                                 record: @escaping (WorkspaceSnapshot) -> Void) {
        onItemEdit = { edit, completion in
            guard isActive() else { completion(nil); return }
            adapter.edit(edit) { result in
                switch result {
                case .success(let snapshot): record(snapshot); completion(snapshot); show(snapshot)
                case .failure(let error):
                    FileHandle.standardError.write(Data("cannot edit item: \(error)\n".utf8))
                    completion(nil)
                }
            }
        }
        confirmFolderDeletion = { row, completion in
            guard let window = window() else { completion(false); return }
            let alert = NSAlert()
            alert.messageText = "Delete your “\(row.title)” folder?"
            alert.informativeText = "Deleting this folder will archive the tabs inside it."
            let delete = alert.addButton(withTitle: "Delete Folder")
            delete.keyEquivalent = "\r"
            delete.hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            alert.beginSheetModal(for: window) { completion($0 == .alertFirstButtonReturn) }
        }
        onMove = { id, container, index, openFolder, completion in
            guard isActive() else { completion(nil); return }
            adapter.move(id: id, container: container, index: index, openFolder: openFolder) { result in
                switch result {
                case .success(let snapshot): record(snapshot); completion(snapshot); show(snapshot)
                case .failure(let error):
                    FileHandle.standardError.write(Data("cannot move item: \(error)\n".utf8))
                    completion(nil)
                }
            }
        }
        onFolderDragRows = { id, completion in
            guard isActive() else { completion([]); return }
            adapter.folderDragRows(id: id) { completion((try? $0.get()) ?? []) }
        }
    }

    public func bind(to sidebar: SidebarView) {
        sidebar.onRenameSpace = onRenameSpace
        sidebar.onDeleteSpace = onDeleteSpace
        sidebar.onSpaceSettings = onSpaceSettings
        sidebar.lookSettings = lookSettings
        sidebar.onItemEdit = onItemEdit
        sidebar.confirmFolderDeletion = confirmFolderDeletion
        sidebar.onSelect = onSelect
        sidebar.onMove = onMove
        sidebar.onFolderDragRows = onFolderDragRows
        sidebar.onClose = onClose
        sidebar.onCloseSelected = onCloseSelected
        sidebar.onArchive = onArchive
        sidebar.onRemoveFavorite = onRemoveFavorite
        sidebar.onNewTab = onNewTab
        sidebar.onClearToday = onClearToday
        sidebar.onShowSpace = onShowSpace
        sidebar.onRestore = onRestore
        sidebar.onArchiveDelete = onArchiveDelete
        sidebar.onClearArchive = onClearArchive
        sidebar.onCreateSpace = onCreateSpace
        sidebar.onCreatePageChanged = onCreatePageChanged
    }
}
