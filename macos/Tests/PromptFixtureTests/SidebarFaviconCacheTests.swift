import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor
private final class FaviconRequests {
    let cache = SidebarFaviconCache()
    var urls: [String] = []
    var replies: [(NSImage?) -> Void] = []
    var available = true
    var changes = 0

    init(profile: String? = "Default") {
        cache.useProfile(profile)
    }

    func images(_ existing: [Row], shown: [Row]? = nil, live: [String: NSImage?] = [:]) -> [String: NSImage] {
        cache.images(existing: existing, shown: shown ?? existing, live: live, request: { url, reply in
            self.urls.append(url)
            guard self.available else { return false }
            self.replies.append(reply)
            return true
        }, changed: { [weak self] in self?.changes += 1 })
    }
}

@MainActor
private final class FaviconHost: NSObject {
    var urls: [String] = []
    var profiles: [String] = []

    @objc func isClosing() -> Bool { false }
    @objc func isClosingAll() -> Bool { false }
    @objc func tabs() -> [Any] { [] }

    @objc(faviconForPageURL:profileDirectory:completion:)
    func favicon(_ url: String, profile: String, completion: @escaping (NSImage?) -> Void) -> Bool {
        urls.append(url)
        profiles.append(profile)
        completion(nil)
        return true
    }
}

private func faviconRow(_ id: String = "item", _ url: String = "https://example.test/", parent: String = "") -> Row {
    Row(folderHasTabs: false, parentId: parent, siblingIndex: 0, collapsed: false, id: id, title: id,
        url: url, depth: 0, kind: .tab, unloaded: true, lastSelectedAt: nil)
}

@Suite @MainActor
struct SidebarFaviconCacheTests {
    @Test func loadsPresentedRowsAndSharesTheirURL() {
        let requests = FaviconRequests()
        let row = faviconRow()
        let duplicate = faviconRow("other")
        let hidden = faviconRow("hidden", "https://hidden.test/")
        let existing = [row, duplicate, hidden]
        let shown = [row, duplicate]
        let icon = NSImage(size: NSSize(width: 16, height: 16))

        #expect(requests.images(existing, shown: shown).isEmpty)
        #expect(requests.images(existing, shown: shown).isEmpty)
        #expect(requests.urls == [row.url!])
        requests.replies[0](icon)
        let images = requests.images(existing, shown: shown)
        #expect(images[row.id] === icon)
        #expect(images[duplicate.id] === icon)
        #expect(images[hidden.id] == nil)
        #expect(requests.changes == 1)
    }

    @Test func cachesNilUntilTheItemGoesLive() {
        let requests = FaviconRequests()
        let row = faviconRow()
        let duplicate = faviconRow("other")
        let existing = [row, duplicate]
        _ = requests.images(existing)
        requests.replies[0](nil)

        #expect(requests.images(existing).isEmpty)
        #expect(requests.urls.count == 1)
        #expect(requests.images(existing, live: [row.id: nil]).isEmpty)
        #expect(requests.urls.count == 2)
    }

    @Test func liveTabWinsAndLateReplyIsIgnored() {
        let requests = FaviconRequests()
        let row = faviconRow()
        let previous = NSImage(size: NSSize(width: 16, height: 16))
        let current = NSImage(size: NSSize(width: 16, height: 16))
        _ = requests.images([row])
        requests.replies[0](previous)
        #expect(requests.images([row])[row.id] === previous)
        #expect(requests.images([row], live: [row.id: current])[row.id] === current)

        _ = requests.images([row])
        #expect(requests.images([row], live: [row.id: nil]).isEmpty)
        requests.replies[1](previous)
        #expect(requests.changes == 1)
        #expect(requests.images([row], live: [row.id: current])[row.id] === current)
    }

    @Test func archivingRemovesTheCachedURL() {
        let requests = FaviconRequests()
        let row = faviconRow()
        _ = requests.images([row])
        requests.replies[0](NSImage(size: NSSize(width: 16, height: 16)))

        #expect(requests.images([]).isEmpty)
        #expect(requests.images([row]).isEmpty)
        #expect(requests.urls.count == 2)
    }

    @Test func changingURLIgnoresOldReplyAndDropsTheOldEntry() {
        let requests = FaviconRequests()
        let row = faviconRow()
        let changed = faviconRow(row.id, "https://changed.test/")
        _ = requests.images([row])
        _ = requests.images([changed])
        requests.replies[0](NSImage(size: NSSize(width: 16, height: 16)))

        #expect(requests.images([changed]).isEmpty)
        #expect(requests.changes == 0)
        #expect(requests.images([row]).isEmpty)
        #expect(requests.urls == [row.url!, changed.url!, row.url!])
    }

    @Test(arguments: [false, true])
    func requestsUseThePresentedRowsAndProfile(privateWindow: Bool) {
        _ = NSApplication.shared
        class_addProtocol(FaviconHost.self, objc_getProtocol("ARWindowHostAPI")!)
        let host = FaviconHost()
        let pin = faviconRow("pin", "https://pin.test/")
        let favorite = faviconRow("favorite", "https://favorite.test/")
        let split = Row(folderHasTabs: false, parentId: "", siblingIndex: 0, collapsed: false,
                        id: "split", title: "", url: nil, depth: 0, kind: .split, unloaded: true, lastSelectedAt: nil)
        let pane = faviconRow("pane", "https://pane.test/", parent: split.id)
        let space = SpaceSnapshot(pinnedCount: 1, todayCount: 1, profileKey: "Work",
                                  pinnedId: "pinned", todayId: "today", favoritesId: "favorites",
                                  archiveAfter: .hours12, profileName: "Work", profile: .named("Work"),
                                  id: "work", title: "Work", icon: nil, look: nil, pinnedCollapsed: false,
                                  favorites: [favorite], pinned: [pin], today: [split, pane])
        let snapshot = WorkspaceSnapshot(archive: [], shownSpaceId: space.id, selectedId: nil, spaces: [space])
        let runtime = Runtime()
        runtime.host = host as? any ARWindowHostAPI
        runtime.isPrivateWindow = privateWindow
        runtime.snapshot = snapshot
        runtime.sidebar = SidebarView(snapshot: snapshot)
        runtime.refreshSidebarFavicons()

        let expected = privateWindow ? [] : [pin, favorite, pane].compactMap(\.url).sorted()
        #expect(host.urls.sorted() == expected)
        #expect(host.profiles == Array(repeating: "Work", count: expected.count))
    }

    @Test(arguments: [false, true])
    func previousProfileOrHostReplyCannotFillANewRequest(replaceHost: Bool) {
        let requests = FaviconRequests()
        let row = faviconRow()
        _ = requests.images([row])
        if replaceHost { requests.cache.reset() }
        else { requests.cache.useProfile("Work") }
        requests.cache.useProfile("Default")
        _ = requests.images([row])

        let icon = NSImage(size: NSSize(width: 16, height: 16))
        requests.replies[0](icon)
        #expect(requests.images([row]).isEmpty)
        #expect(requests.changes == 0)
        requests.replies[1](icon)
        #expect(requests.images([row])[row.id] === icon)
    }

    @Test func retriesAfterTheProfileBecomesAvailable() {
        let requests = FaviconRequests()
        let row = faviconRow()
        let duplicate = faviconRow("other")
        requests.available = false
        #expect(requests.images([row, duplicate]).isEmpty)
        #expect(requests.urls.count == 1)
        requests.available = true
        #expect(requests.images([row]).isEmpty)

        let icon = NSImage(size: NSSize(width: 16, height: 16))
        requests.replies[0](icon)
        #expect(requests.images([row])[row.id] === icon)
    }
}
