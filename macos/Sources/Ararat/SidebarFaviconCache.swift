import AppKit
import AraratKit

@MainActor
final class SidebarFaviconCache {
    private enum Entry {
        case pending(UUID)
        case resolved(NSImage?)
    }

    private var profile: String?
    private var entries: [String: Entry] = [:]
    private var unloadedItems: [String: String] = [:]

    func useProfile(_ profile: String?) {
        guard self.profile != profile else { return }
        reset()
        self.profile = profile
    }

    func reset() {
        profile = nil
        entries.removeAll()
        unloadedItems.removeAll()
    }

    func images(existing: [Row], shown: [Row], live: [String: NSImage?],
                request: (_ url: String, _ completion: @escaping (NSImage?) -> Void) -> Bool,
                changed: @escaping () -> Void) -> [String: NSImage] {
        var images = live.compactMapValues { $0 }
        guard profile != nil else { return images }

        for row in existing where !row.unloaded || live[row.id] != nil {
            guard let url = unloadedItems[row.id], case .resolved(nil)? = entries[url] else { continue }
            entries.removeValue(forKey: url)
        }
        unloadedItems.removeAll(keepingCapacity: true)
        for row in existing where row.unloaded && live[row.id] == nil {
            unloadedItems[row.id] = row.url
        }
        let urls = Set(unloadedItems.values)
        entries = entries.filter { urls.contains($0.key) }

        var unavailable: Set<String> = []
        for row in shown {
            guard let url = row.url, unloadedItems[row.id] == url else { continue }
            if entries[url] == nil, unavailable.insert(url).inserted {
                let token = UUID()
                entries[url] = .pending(token)
                let accepted = request(url) { [weak self] image in
                    guard let self, case .pending(token)? = self.entries[url] else { return }
                    self.entries[url] = .resolved(image)
                    if image != nil { changed() }
                }
                if !accepted { entries.removeValue(forKey: url) }
            }
        }
        for (id, url) in unloadedItems {
            if case .resolved(let image?)? = entries[url] { images[id] = image }
        }
        return images
    }
}
