import AppKit
import Testing
@testable import AraratKit

@Test @MainActor
func switcherThumbnailCacheDropsDepartedMRUEntriesAndRejectsCallbacksFromTheirOldScope() throws {
    let home = SwitcherThumbnailCache.Scope(profile: "Default", space: "home")
    let work = SwitcherThumbnailCache.Scope(profile: "Work", space: "work")
    var cache = SwitcherThumbnailCache()
    let image = NSImage(size: NSSize(width: 156, height: 104))
    let items = ["close", "archive", "old-mru", "moved", "keep"]
    _ = cache.reconcile(Dictionary(uniqueKeysWithValues: items.map { ($0, home) }))
    for item in items {
        let key = try #require(cache.key(item: item, live: item))
        let pending = cache.begin(key)
        let request = try #require(pending)
        let duplicate = cache.begin(key)
        let stored = cache.finish(key, request: request, image: image)
        #expect(duplicate == nil)
        #expect(stored)
    }
    let previous = try #require(cache.key(item: "moved", live: "moved"))
    let pending = cache.begin(previous)
    let stale = try #require(pending)
    let removed = cache.reconcile(["moved": work, "keep": home])
    #expect(removed == ["close", "archive", "old-mru", "moved"])
    #expect(cache.image(item: "keep", live: "different-incarnation") == nil)
    #expect(cache.image(item: "keep", live: "keep") === image)
    let accepted = cache.finish(previous, request: stale, image: image)
    #expect(!accepted)
    #expect(cache.image(item: "moved", live: "moved") == nil)
}
