import AraratKit
import Testing
@testable import Ararat

@Test @MainActor
func workspaceWindowTitleFollowsPresentedPageOrShownSpace() {
    func space(_ id: String, _ title: String) -> SpaceSnapshot {
        SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "pin-\(id)",
                      todayId: "today-\(id)", favoritesId: nil, archiveAfter: .hours12, profileName: "Default",
                      profile: .default, id: id, title: title, icon: nil, look: nil, pinnedCollapsed: false,
                      favorites: [], pinned: [], today: [])
    }

    let work = space("work", "Work")
    let home = space("home", "Home")
    let initial = WorkspaceSnapshot(archive: [], shownSpaceId: "work", selectedId: "parked", spaces: [home, work])
    let switched = WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: nil, spaces: [home, work])
    let renamed = WorkspaceSnapshot(archive: [], shownSpaceId: "home", selectedId: nil, spaces: [space("home", "Personal"), work])

    #expect(Runtime.workspaceWindowTitle(pageTitle: "Article", snapshot: initial) == "Article")
    #expect(Runtime.workspaceWindowTitle(pageTitle: nil, snapshot: initial) == "Work")
    #expect(Runtime.workspaceWindowTitle(pageTitle: nil, snapshot: switched) == "Home")
    #expect(Runtime.workspaceWindowTitle(pageTitle: nil, snapshot: renamed) == "Personal")
}
