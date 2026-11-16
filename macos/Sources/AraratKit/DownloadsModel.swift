import Foundation

public struct DownloadEntry: Equatable, Identifiable {
    public let id: String
    public let profile: String
    public let name: String
    public let url: String
    public let path: String
    public let paused: Bool
    public let state: Int
    public let running: Bool
    public let restored: Bool
    public let start: Double
    public let received: Int64
    public let total: Int64
    public let status: String
    public let actions: [String]

    public init?(_ value: [String: Any]) {
        guard let id = value["id"] as? String, let profile = value["profile"] as? String,
              let url = value["url"] as? String, let path = value["path"] as? String, let paused = value["paused"] as? Bool,
              let name = value["name"] as? String, let state = value["state"] as? Int, let running = value["running"] as? Bool, let restored = value["restored"] as? Bool,
              let start = value["start"] as? Double, let received = value["received"] as? Int64,
              let total = value["total"] as? Int64, let status = value["status"] as? String,
              let actions = value["actions"] as? [String] else { return nil }
        self.id = id; self.profile = profile; self.name = name; self.state = state; self.running = running; self.restored = restored
        self.url = url
        self.path = path
        self.paused = paused
        self.start = start; self.received = received; self.total = total
        self.status = status; self.actions = actions
    }
}

@MainActor
public final class DownloadsModel {
    public enum Progress: Equatable { case none, indeterminate, fraction(Double), paused(Double) }
    public private(set) var items: [DownloadEntry] = []
    public var onChange: (() -> Void)?
    public var onAction: ((String, String) -> Bool)?
    public init() {}
    public func update(_ values: [[String: Any]]) {
        items = values.compactMap(DownloadEntry.init).sorted {
            $0.start == $1.start ? $0.id < $1.id : $0.start > $1.start
        }
        onChange?()
    }
    public var progress: Progress {
        let running = items.filter { $0.running || ($0.state == 0 && $0.paused) }
        guard !running.isEmpty else { return .none }
        // Why not calculate a percentage for zero: Chromium uses zero for an unknown total.
        let paused = running.allSatisfy(\.paused)
        guard running.allSatisfy({ $0.total > 0 }) else { return paused ? .paused(0) : .indeterminate }
        let total = running.reduce(0.0) { $0 + Double($1.total) }
        let received = running.reduce(0.0) { $0 + Double(max(0, min($1.received, $1.total))) }
        return paused ? .paused(received / total) : .fraction(received / total)
    }
    public func filteredItems(_ query: String) -> [DownloadEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.url.localizedCaseInsensitiveContains(query) }
    }
    public var clearableItems: [DownloadEntry] { items.filter { [1, 2, 3].contains($0.state) && $0.actions.contains("remove") } }
    public func clearAll() {
        for item in clearableItems { perform("remove", id: item.id) }
    }
    public func dragFileURL(id: String) -> URL? {
        guard let item = items.first(where: { $0.id == id }), item.state == 1,
              item.actions.contains("open"), !item.path.isEmpty,
              FileManager.default.fileExists(atPath: item.path) else { return nil }
        return URL(fileURLWithPath: item.path)
    }
    public var hasSessionDownloads: Bool { items.contains { !$0.restored || ($0.state == 3 && $0.actions.contains("resume")) } }
    @discardableResult public func perform(_ action: String, id: String) -> Bool {
        guard items.contains(where: { $0.id == id && $0.actions.contains(action) }) else { return false }
        return onAction?(action, id) ?? false
    }
}
