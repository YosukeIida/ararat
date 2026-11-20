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

    private var scopes: [String: Scope] = [:]
    private var images: [String: (key: Key, image: NSImage)] = [:]
    private var requests: [Key: UUID] = [:]
    private var inFlight: Set<UUID> = []

    var hasImagesOrRequests: Bool { !images.isEmpty || !requests.isEmpty }

    mutating func reconcile(_ next: [String: Scope]) -> Set<String> {
        scopes = next
        let removed = Set(images.values.filter { next[$0.key.item] != $0.key.scope }.map { $0.key.item })
        for item in removed { images.removeValue(forKey: item) }
        requests = requests.filter { next[$0.key.item] == $0.key.scope }
        return removed
    }

    func key(item: String, live: String) -> Key? {
        scopes[item].map { Key(scope: $0, item: item, live: live) }
    }

    func image(item: String, live: String) -> NSImage? {
        guard let entry = images[item], entry.key.live == live else { return nil }
        return entry.image
    }

    mutating func begin(_ key: Key) -> UUID? {
        guard scopes[key.item] == key.scope, requests[key] == nil, inFlight.count < 4 else { return nil }
        let request = UUID()
        requests[key] = request
        inFlight.insert(request)
        return request
    }

    mutating func finish(_ key: Key, request: UUID, image: NSImage?) -> Bool {
        guard inFlight.remove(request) != nil, requests[key] == request else { return false }
        requests.removeValue(forKey: key)
        if let image {
            images[key.item] = (key, image)
            return true
        }
        guard images[key.item]?.key == key else { return false }
        images.removeValue(forKey: key.item)
        return true
    }

    mutating func invalidate(live: String) -> Set<String> {
        let removed = Set(images.values.filter { $0.key.live == live }.map { $0.key.item })
        for item in removed { images.removeValue(forKey: item) }
        requests = requests.filter { $0.key.live != live }
        return removed
    }
}
