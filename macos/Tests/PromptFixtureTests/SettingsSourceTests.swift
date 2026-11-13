import AraratUI
import Testing
@testable import Ararat

// U27d review 1 M2: the synced settings record lives in the regular workspace, so a private
// window (whose own workspace always starts from the built-in values) reads the regular one —
// for a window opened after the switch as much as for one already open.
@Test @MainActor
func aPrivateWindowReadsTheSettingsRecordFromTheRegularWorkspace() {
    let root = Runtime()
    let regular = WorkspaceAdapter(windowID: "u27d-settings-root")
    root.workspace = regular

    let privateWindow = Runtime()
    privateWindow.root = root
    privateWindow.isPrivateWindow = true
    privateWindow.workspace = WorkspaceAdapter(windowID: "u27d-settings-private")
    #expect(privateWindow.settingsSource() === regular)

    // A regular window reads its own workspace's record, and so does the root.
    let ordinary = Runtime()
    ordinary.root = root
    let own = WorkspaceAdapter(windowID: "u27d-settings-own")
    ordinary.workspace = own
    #expect(ordinary.settingsSource() === own)
    #expect(root.settingsSource() === regular)

    // With no regular owner to borrow from, a private window falls back to its own adapter
    // rather than reading nothing.
    let orphan = Runtime()
    orphan.isPrivateWindow = true
    let ownPrivate = WorkspaceAdapter(windowID: "u27d-settings-orphan")
    orphan.workspace = ownPrivate
    #expect(orphan.settingsSource() === ownPrivate)
}
