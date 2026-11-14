import Foundation
import AraratKit

/// O7: "Import from Arc…" is a command only, with no first-launch gate. Until the importer reads
/// real files the shipping build has no data source, so the app inserts the File menu item and
/// this command bar row only while a check runs. The row is not a core key-binding command: the
/// core's table would list it in the Shortcuts pane forever, and the entry must disappear in a
/// shipping build (hide, not disable).
@MainActor
public final class OnboardingCommandStore: CommandBarStore {
    public static let commandID = "import_from_arc"
    public static let title = "Import from Arc…"

    private let base: CommandBarStore

    public init(base: CommandBarStore) { self.base = base }

    /// The row matches "import", "arc", "from" and the whole title, so typing either word finds it.
    public static func matches(_ text: String) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return false }
        return title.lowercased().contains(query) || ["import", "from", "arc"].contains { $0.hasPrefix(query) }
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
