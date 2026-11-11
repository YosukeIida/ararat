import AraratKit

// The spaces the tests build by hand predate `pinned_collapsed`; a synthetic space is never
// collapsed, so this keeps their initialisers short. The app reads the real flag from the
// store's snapshot.
extension SpaceSnapshot {
    init(pinnedCount: UInt32, todayCount: UInt32, profileKey: String, pinnedId: String, todayId: String,
         favoritesId: String?, archiveAfter: ArchiveAfter, profileName: String, profile: Profile,
         id: String, title: String, icon: String?, look: Look?, favorites: [Row], pinned: [Row], today: [Row]) {
        self.init(pinnedCount: pinnedCount, todayCount: todayCount, profileKey: profileKey, pinnedId: pinnedId,
                  todayId: todayId, favoritesId: favoritesId, archiveAfter: archiveAfter, profileName: profileName,
                  profile: profile, id: id, title: title, icon: icon, look: look, pinnedCollapsed: false,
                  favorites: favorites, pinned: pinned, today: today)
    }
}
