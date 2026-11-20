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

@Test @MainActor
func switcherThumbnailReserveIsRateLimitedAndFallsBackWithoutCrossingDocuments() throws {
    let home = SwitcherThumbnailCache.Scope(profile: "Default", space: "home")
    var cache = SwitcherThumbnailCache()
    _ = cache.reconcile(["item": home])
    let key = try #require(cache.key(item: "item", live: "live"))
    let first = cache.scheduleReserve(key, now: 10)
    let schedule = try #require(first)
    #expect(schedule.delay == 0)
    let started = cache.startReserve(key, scheduled: schedule.id, now: 10)
    let reserveRequest = try #require(started)
    let reserve = NSImage(size: NSSize(width: 156, height: 104))
    _ = cache.finish(key, request: reserveRequest, image: reserve, source: .reserve)
    #expect(cache.source(item: "item", live: "live") == "reserve")

    let scheduledAtLoad = cache.scheduleReserve(key, now: 10.5)
    let load = try #require(scheduledAtLoad)
    #expect(load.delay == 1.5)
    let coalesced = cache.scheduleReserve(key, now: 11)
    #expect(coalesced == nil)
    let refreshing = cache.startReserve(key, scheduled: load.id, now: 12)
    let refreshRequest = try #require(refreshing)

    let hiding = cache.begin(key)
    let hideRequest = try #require(hiding)
    let prehide = NSImage(size: NSSize(width: 156, height: 104))
    _ = cache.finish(key, request: hideRequest, image: prehide)
    #expect(cache.image(item: "item", live: "live") === prehide)
    let hideAgain = cache.begin(key)
    _ = cache.finish(key, request: try #require(hideAgain), image: nil)
    #expect(cache.image(item: "item", live: "live") === reserve)
    #expect(cache.source(item: "item", live: "live") == "reserve")

    _ = cache.invalidate(live: "live")
    let arrivedLate = cache.finish(key, request: refreshRequest, image: reserve, source: .reserve)
    #expect(!arrivedLate)
    #expect(cache.source(item: "item", live: "live") == "favicon")
    let nextDocument = cache.scheduleReserve(key, now: 12.1)
    #expect(nextDocument?.delay == 0)
}
