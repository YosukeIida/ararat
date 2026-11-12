import AraratKit
import Testing
import AppKit
@testable import AraratUI

@Test @MainActor
func historyPurgeFailuresAreScopedAndOnlyTheRetriedPurgeClears() async throws {
    let session = WorkspaceSession()
    var succeeds = false
    session.purgeHistory = { _, _, _, completion in completion(succeeds) }
    let first = HistoryPurge(id: "one", profile: .default, item: "one", changedAt: 1)
    let second = HistoryPurge(id: "two", profile: .default, item: "two", changedAt: 1)
    let other = HistoryPurge(id: "other", profile: .named("Profile 1"), item: "other", changedAt: 1)
    session.submitHistoryPurge(first)
    session.submitHistoryPurge(second)
    session.submitHistoryPurge(other)
    try await waitUntil { session.historyPurgeFailed(profile: "Default") && session.historyPurgeFailed(profile: "Profile 1") }
    succeeds = true
    session.submitHistoryPurge(first)
    session.queue.sync {}
    #expect(session.historyPurgeFailed(profile: "Default"))
    session.submitHistoryPurge(second)
    try await waitUntil { !session.historyPurgeFailed(profile: "Default") }
    #expect(session.historyPurgeFailed(profile: "Profile 1"))
    session.dismissHistoryPurgeFailure(profile: "Profile 1")
    try await waitUntil { !session.historyPurgeFailed(profile: "Profile 1") }
}

@Test @MainActor
func historyFailureAppearsInBothWindowsOfOnlyItsProfile() async throws {
    _ = NSApplication.shared
    func sidebar(_ profile: Profile, _ name: String) -> SidebarView {
        let space = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: name, pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: name, profile: profile, id: name, title: name, icon: nil, look: nil, favorites: [], pinned: [], today: [])
        let defaultSpace = SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: "default", pinnedId: "", todayId: "", favoritesId: nil, archiveAfter: .hours12, profileName: "Default", profile: .default, id: "Default", title: "Default", icon: nil, look: nil, favorites: [], pinned: [], today: [])
        let view = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
        view.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: name, selectedId: nil, spaces: name == "Default" ? [defaultSpace] : [defaultSpace, space]))
        return view
    }
    let session = WorkspaceSession()
    let first = sidebar(.default, "Default"), second = sidebar(.default, "Default")
    let other = sidebar(.named("Profile 1"), "Profile 1")
    var otherAnnouncements = 0
    other.checkHistoryAnnouncement = { _ in otherAnnouncements += 1 }
    for view in [first, second, other] { view.observeHistoryFailures(session) }
    session.purgeHistory = { _, _, _, completion in completion(false) }
    session.submitHistoryPurge(HistoryPurge(id: "one", profile: .default, item: "one", changedAt: 1))
    try await waitUntil { first.historyFailureVisible && second.historyFailureVisible }
    #expect(!other.historyFailureVisible)
    #expect(other.checkHistoryContext.profile == "Profile 1")
    #expect(otherAnnouncements == 0)
    first.onDismissHistory?()
    try await waitUntil { !first.historyFailureVisible && !second.historyFailureVisible }
}

@Test @MainActor
func dismissKeepsRetriesSilentUntilANewPurgeFails() async throws {
    let session = WorkspaceSession()
    var succeeds = false
    session.purgeHistory = { _, _, _, completion in completion(succeeds) }
    let first = HistoryPurge(id: "first", profile: .default, item: "first", changedAt: 1)
    let second = HistoryPurge(id: "second", profile: .default, item: "second", changedAt: 1)
    session.submitHistoryPurge(first)
    try await waitUntil { session.historyPurgeFailed(profile: "Default") }
    session.dismissHistoryPurgeFailure(profile: "Default")
    session.queue.sync {}
    session.submitHistoryPurge(first)
    session.queue.sync {}
    #expect(!session.historyPurgeFailed(profile: "Default"))
    session.submitHistoryPurge(second)
    try await waitUntil { session.historyPurgeFailed(profile: "Default") }
    succeeds = true
    session.submitHistoryPurge(first)
    session.submitHistoryPurge(second)
    try await waitUntil { !session.historyPurgeFailed(profile: "Default") }
    succeeds = false
    session.submitHistoryPurge(first)
    try await waitUntil { session.historyPurgeFailed(profile: "Default") }
}

@Test @MainActor
func replacementToastOutlivesTheFirstExpiry() async throws {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.showLinkCopied()
    try await Task.sleep(for: .seconds(1))
    container.showLinkCopied()
    try await Task.sleep(for: .seconds(1.3))
    #expect(container.checkToastState.visible)
    try await waitUntil { !container.checkToastState.visible }
}
