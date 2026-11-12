import Foundation

// R7: the unread dot is app state from the live strip — a loaded tab the window is not showing
// gets one when its title changes, showing it clears it, and an id that leaves the strip is
// forgotten with its title. Nothing here is stored or synced.
public struct UnreadTracker {
    public private(set) var unread: Set<String> = []
    private var titles: [String: String] = [:]

    public init() {}

    public mutating func apply(strip: LiveStrip) {
        let ids = Set(strip.tabs.compactMap(\.item))
        unread.formIntersection(ids)
        titles = titles.filter { ids.contains($0.key) }
        let active = strip.active.flatMap { live in strip.tabs.first { $0.liveId == live }?.item }
        for tab in strip.tabs {
            guard let item = tab.item, let title = tab.title else { continue }
            if let previous = titles[item], previous != title, item != active { unread.insert(item) }
            titles[item] = title
        }
        if let active { unread.remove(active) }
    }
}
