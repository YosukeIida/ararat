import Foundation
import AraratKit

// Why not use a core key-binding command: it would appear in Shortcuts even without Arc installed.
@MainActor
public final class OnboardingCommandStore: CommandBarStore {
    public static let commandID = "import_from_arc"
    public static let title = "Import from Arc…"

    private let base: CommandBarStore

    public init(base: CommandBarStore) { self.base = base }

    /// The core's matcher (`command_bar.rs`): a title prefix or a word prefix, never a substring.
    public static func matches(_ text: String) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return false }
        let title = title.lowercased()
        return title.hasPrefix(query) || title.split(separator: " ").contains { $0.hasPrefix(query) }
    }

    public func query(_ text: String, history: [HistoryEntry]) -> CommandBarResult {
        var result = base.query(text, history: history)
        guard Self.matches(text) else { return result }
        let row = Suggestion(title: Self.title, subtitle: "Command", url: nil, key: nil,
                             target: .command(id: Self.commandID), score: 0)
        result.rows.insert(row, at: min(1, result.rows.count))
        if result.rows.count > 5 { result.rows.removeLast() }
        return result
    }

    public func searchURL(_ text: String) -> String { base.searchURL(text) }
}
