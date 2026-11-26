import AraratEngineAPI
import AraratKit
import AraratUI
import Darwin

@MainActor
struct EngineSearchSuggestionsSettings {
    let isEnabled: () -> Bool
    let setEnabled: (Bool) -> Void

    private typealias GetEnabled = @convention(c) () -> Bool
    private typealias SetEnabled = @convention(c) (Bool) -> Void

    private static func symbol<T>(_ name: String) -> T {
        guard let symbol = dlsym(Launcher.handle, name) else {
            preconditionFailure("Missing search suggestions API: \(name)")
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static let getEnabled: GetEnabled = symbol("AraratSearchSuggestionsEnabled")
    private static let writeEnabled: SetEnabled = symbol("AraratSetSearchSuggestionsEnabled")

    static let live = Self(isEnabled: { getEnabled() }, setEnabled: { writeEnabled($0) })

    func write(_ enabled: Bool) -> Bool {
        setEnabled(enabled)
        return isEnabled()
    }
}

extension CommandBarPresenter {
    func connectSearchSuggestions(to host: any ARWindowHostAPI) {
        controller.privateWindow = host.isPrivateWindow()
        let profile = host.profileDirectory()
        controller.onSuggestionQuery = { [weak self, weak host] text, generation in
            guard let self, let host else { return }
            guard let text, host.profileDirectory() == profile, !self.controller.privateWindow else {
                host.cancelSearchSuggestions()
                return
            }
            host.querySearchSuggestions(text) { [weak self, weak host] rows in
                MainActor.assumeIsolated {
                    guard let self, host?.profileDirectory() == profile else { return }
                    let suggestions = rows.compactMap { row -> Suggestion? in
                        guard let title = row["title"], let url = row["url"] else { return nil }
                        return Suggestion(title: title, subtitle: "Search suggestion", url: nil, key: nil,
                                          target: .search(url: url), score: 0)
                    }
                    self.controller.updateSearchSuggestions(suggestions, generation: generation)
                }
            }
        }
    }
}
