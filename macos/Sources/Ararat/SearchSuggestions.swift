import AraratEngineAPI
import AraratKit
import AraratUI

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
