import AppKit

struct SwitcherThumbnailCache {
    struct Scope: Hashable {
        let profile: String
        let space: String
    }

    struct Key: Hashable {
        let scope: Scope
        let item: String
        let live: String
    }

    enum Source: String, Hashable { case prehide, reserve }
    private struct Capture: Hashable {
        let key: Key
        let source: Source
    }
    private struct Images {
        let key: Key
        var prehide: NSImage?
        var reserve: NSImage?
    }

    private var scopes: [String: Scope] = [:]
    private var images: [String: Images] = [:]
    private var requests: [Capture: UUID] = [:]
    private var inFlight: Set<UUID> = []
    private var scheduled: [Key: (id: UUID, retry: Bool)] = [:]
    private var lastReserve: [Key: TimeInterval] = [:]

    var hasImagesOrRequests: Bool { !images.isEmpty || !requests.isEmpty || !scheduled.isEmpty }

    mutating func reconcile(_ next: [String: Scope]) -> Set<String> {
        scopes = next
        let removed = Set(images.values.filter { next[$0.key.item] != $0.key.scope }.map { $0.key.item })
        for item in removed { images.removeValue(forKey: item) }
        requests = requests.filter { next[$0.key.key.item] == $0.key.key.scope }
        scheduled = scheduled.filter { next[$0.key.item] == $0.key.scope }
        lastReserve = lastReserve.filter { next[$0.key.item] == $0.key.scope }
        return removed
    }

    func key(item: String, live: String) -> Key? {
        scopes[item].map { Key(scope: $0, item: item, live: live) }
    }

    func image(item: String, live: String) -> NSImage? {
        guard let entry = images[item], entry.key.live == live else { return nil }
        return entry.prehide ?? entry.reserve
    }

    func source(item: String, live: String) -> String {
        guard let entry = images[item], entry.key.live == live else { return "favicon" }
        if entry.prehide != nil { return Source.prehide.rawValue }
        return entry.reserve != nil ? Source.reserve.rawValue : "favicon"
    }

    func canScheduleReserveRetry(_ key: Key, request: UUID) -> Bool {
        requests[Capture(key: key, source: .reserve)] == request && image(item: key.item, live: key.live) == nil
    }

    mutating func scheduleReserve(_ key: Key, now: TimeInterval, minimumDelay: TimeInterval = 0,
                                  retry: Bool = false) -> (id: UUID, delay: TimeInterval)? {
        guard scopes[key.item] == key.scope, scheduled[key].map({ retry && !$0.retry }) ?? true else { return nil }
        let delay = max(minimumDelay, lastReserve[key].map { $0 + 2 - now } ?? 0)
        let id = UUID()
        scheduled[key] = (id, retry)
        return (id, delay)
    }

    mutating func startReserve(_ key: Key, scheduled id: UUID, now: TimeInterval) -> UUID? {
        guard let pending = scheduled[key], pending.id == id else { return nil }
        scheduled.removeValue(forKey: key)
        guard !pending.retry || image(item: key.item, live: key.live) == nil,
              lastReserve[key].map({ now - $0 >= 2 }) ?? true,
              let request = begin(key, source: .reserve) else { return nil }
        lastReserve[key] = now
        return request
    }

    mutating func begin(_ key: Key, source: Source = .prehide) -> UUID? {
        let capture = Capture(key: key, source: source)
        guard scopes[key.item] == key.scope, requests[capture] == nil, inFlight.count < 4 else { return nil }
        let request = UUID()
        requests[capture] = request
        inFlight.insert(request)
        return request
    }

    mutating func finish(_ key: Key, request: UUID, image: NSImage?, source: Source = .prehide) -> Bool {
        let capture = Capture(key: key, source: source)
        guard inFlight.remove(request) != nil, requests[capture] == request else { return false }
        requests.removeValue(forKey: capture)
        let previous = self.image(item: key.item, live: key.live)
        var entry = images[key.item].flatMap { $0.key == key ? $0 : nil } ?? Images(key: key)
        switch source {
        case .prehide: entry.prehide = image
        case .reserve:
            if let image { entry.reserve = image }
        }
        if entry.prehide != nil || entry.reserve != nil { images[key.item] = entry }
        else if images[key.item]?.key == key { images.removeValue(forKey: key.item) }
        return previous !== self.image(item: key.item, live: key.live)
    }

    mutating func invalidate(live: String) -> Set<String> {
        let removed = Set(images.values.filter { $0.key.live == live }.map { $0.key.item })
        for item in removed { images.removeValue(forKey: item) }
        requests = requests.filter { $0.key.key.live != live }
        scheduled = scheduled.filter { $0.key.live != live }
        lastReserve = lastReserve.filter { $0.key.live != live }
        return removed
    }
}
