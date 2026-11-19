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

@Test @MainActor
func clearToastReplacesAndReleasesItsUndo() async throws {
    final class Batch {}
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    var calls = 0
    var first: Batch? = Batch()
    weak var released = first
    container.showTabsCleared { [batch = first!] in _ = batch; calls += 1 }
    first = nil
    #expect(released != nil)
    container.showTabsCleared { calls += 10 }
    #expect(released == nil)
    container.checkUndoToast()
    #expect(calls == 10)
    #expect(!container.checkToastState.visible)
    var last: Batch? = Batch()
    weak var expired = last
    container.showTabsCleared { [batch = last!] in _ = batch }
    last = nil
    try await Task.sleep(for: .seconds(5.3))
    #expect(expired == nil)
    try await waitUntil { !container.checkToastState.visible }
}

@Test @MainActor
func toastLabelsPassHitsAndUndoButtonReceivesThem() {
    _ = NSApplication.shared
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
    container.layoutSubtreeIfNeeded()
    container.showLinkCopied()
    #expect(!container.toastIcon.isHidden && container.toastIcon.image != nil)
    #expect(container.toastIcon.alignmentRect(forFrame: container.toastIcon.frame).size == NSSize(width: 14, height: 14))
    #expect(container.checkToastHits().labelPasses)
    container.showTabsCleared(undo: {})
    #expect(container.toastIcon.isHidden)
    let hits = container.checkToastHits()
    #expect(hits.labelPasses && hits.undoReceives)
}

@Test @MainActor
func failedHistoryCardShowsWarningCopyAndKeepsBothActions() throws {
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    sidebar.frame = NSRect(x: 0, y: 0, width: 164, height: 600)
    sidebar.showHistoryFailure(true)
    sidebar.layoutSubtreeIfNeeded()
    let card = sidebar.historyBanner
    #expect(!card.isHidden)
    #expect(abs(card.frame.width - 148) < 1)
    let labels = textFields(in: card)
    #expect(labels.map(\.stringValue) == [
        "History not fully deleted", "Some history files could not be removed. Ararat will try again.",
    ])
    #expect(labels.allSatisfy { card.bounds.contains(card.convert($0.bounds, from: $0)) })
    #expect((labels.last?.bounds.height ?? 0) > 24)
    let warning = try #require(card.subviews.compactMap { $0 as? NSImageView }.first)
    #expect(warning.image != nil)
    for (name, expected) in [
        (NSAppearance.Name.aqua, NSColor(srgbRed: 178 / 255, green: 80 / 255, blue: 0, alpha: 1)),
        (.darkAqua, NSColor(srgbRed: 1, green: 179 / 255, blue: 64 / 255, alpha: 1)),
    ] {
        sidebar.appearance = try #require(NSAppearance(named: name))
        warning.effectiveAppearance.performAsCurrentDrawingAppearance {
            #expect(warning.contentTintColor?.usingColorSpace(.sRGB) == expected)
        }
    }
    #expect(card.subviews.contains { ($0 as? NSButton)?.accessibilityLabel() == "Dismiss" })
    var actions: [String] = []
    sidebar.onRetryHistory = { actions.append("retry") }
    sidebar.onDismissHistory = { actions.append("dismiss") }
    sidebar.checkClickHistoryRetry()
    sidebar.checkClickHistoryDismiss()
    #expect(actions == ["retry", "dismiss"])
}

private func textFields(in view: NSView) -> [NSTextField] {
    (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
}

private func controls(in view: NSView) -> [NSButton] {
    (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(controls(in:))
}

@Test @MainActor
func historyFailureCardKeepsIconTitleBodyAndActionInOneColumn() throws {
    let sidebar = SidebarView(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []))
    sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 600)
    sidebar.showHistoryFailure(true)
    sidebar.layoutSubtreeIfNeeded()
    sidebar.layoutSubtreeIfNeeded()
    let card = sidebar.historyBanner
    let icon = try #require(card.subviews.compactMap { $0 as? NSImageView }.first)
    let fields = textFields(in: card)
    let title = try #require(fields.first)
    let message = try #require(fields.last)
    let buttons = controls(in: card)
    let retry = try #require(buttons.first { $0.title == "Try Again" })
    let dismiss = try #require(buttons.first { $0.accessibilityLabel() == "Dismiss" })
    // The frames of text fields and buttons carry AppKit's alignment insets; the layout rect is
    // where the stack places them and where the text and bezel draw.
    func layoutRect(_ view: NSView) -> NSRect {
        let rect = view.alignmentRect(forFrame: view.frame)
        return view.superview.map { card.convert(rect, from: $0) } ?? rect
    }
    let iconFrame = layoutRect(icon), titleFrame = layoutRect(title), messageFrame = layoutRect(message)
    let retryFrame = layoutRect(retry), dismissFrame = layoutRect(dismiss)
    #expect(iconFrame.minX == 8)
    #expect(titleFrame.minX == 32 && messageFrame.minX == 32)
    #expect(abs(retryFrame.minX - 32) <= 0.5)
    #expect(title.alignment == .left && message.alignment == .left)
    #expect(titleFrame.width >= card.bounds.width - 65)
    #expect(abs(titleFrame.width - messageFrame.width) <= 0.5)
    #expect(titleFrame.minX >= iconFrame.maxX)
    #expect(card.bounds.insetBy(dx: -1, dy: -1).contains(messageFrame))
    #expect(retryFrame.maxY <= messageFrame.minY)
    let iconTop = card.isFlipped ? iconFrame.minY - card.bounds.minY : card.bounds.maxY - iconFrame.maxY
    let dismissTop = card.isFlipped ? dismissFrame.minY - card.bounds.minY : card.bounds.maxY - dismissFrame.maxY
    #expect(abs(iconTop - 8) <= 1)
    #expect(abs(dismissTop - 4) <= 1)
    #expect(abs(card.bounds.maxX - dismissFrame.maxX - 4) <= 1)
}
