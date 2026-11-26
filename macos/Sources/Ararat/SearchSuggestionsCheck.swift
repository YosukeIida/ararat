import AraratEngineAPI
import AraratUI
import Foundation

@MainActor
final class SearchSuggestionsCheck {
    static let mode = "search-suggestions"

    private let fixture: PromptFixtureServer?
    private var port: UInt16?
    private var fixtureFailed = false
    private var waitUntil = Date.distantPast
    private var expectedQueries: [String] = []
    private var conditions: [String: Bool] = [:]

    init() {
        fixture = try? PromptFixtureServer()
        fixture?.start { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let port): self?.port = port
                case .failure: self?.fixtureFailed = true
                }
            }
        }
    }

    func tick(_ runtime: Runtime) {
        runtime.browserCheckAttempts += 1
        let requests = fixture?.suggestRequests()
        func finish(_ failure: String? = nil) {
            fixture?.stop()
            var values: [String: Any] = ["conditions": conditions, "suggest_requests": requests?.suggestions ?? [],
                                         "search_requests": requests?.searches ?? []]
            if let failure { values["error"] = failure }
            runtime.finishBrowserCheck(ok: failure == nil, values: values)
        }
        guard fixture != nil, !fixtureFailed, runtime.browserCheckAttempts < 200 else {
            finish("Fixture unavailable or check timed out")
            return
        }
        guard let host = runtime.host, let port, let requests else { return }
        let bar = runtime.commandPresenter?.controller
        func submit(_ text: String, waitForSilence: Bool = false) {
            bar?.update(query: text)
            if waitForSilence {
                waitUntil = Date().addingTimeInterval(0.7)
            } else {
                expectedQueries.append(text)
            }
            runtime.browserCheckPhase += 1
        }
        func hasSuggestions(_ titles: [String], in bar: CommandBarController?) -> Bool {
            guard let bar else { return false }
            return bar.result.rows.dropFirst(bar.localRowCount).map(\.title) == titles
        }

        switch runtime.browserCheckPhase {
        case 0:
            guard host.hasBrowser(), host.checkUseSearchSuggestionFixture(port) else { return }
            guard EngineSearchSuggestionsSettings.live.isEnabled() else { finish("Fresh preference is off"); return }
            runtime.openCommandBar(.newTab)
            runtime.browserCheckPhase = 1
        case 1:
            guard let bar, bar.isOpen else { return }
            submit("どらえもん")
        case 2:
            guard let bar, hasSuggestions(["ドラえもん", "ドラえもん映画"], in: bar) else { return }
            conditions["suggestions_after_local_rows"] = bar.localRowCount > 0 && bar.selectedIndex == 0
            let firstSuggestion = bar.localRowCount
            bar.moveSelection(by: firstSuggestion)
            conditions["arrow_previews_suggestion"] = bar.previewText == "ドラえもん"
            bar.commit(forceNewTab: false)
            runtime.browserCheckPhase = 3
        case 3:
            guard requests.searches == ["ドラえもん"] else { return }
            conditions["return_searches_with_default_engine"] = true
            runtime.openSettings()
            guard let probe = runtime.settings?.checkProbe(), probe.searchSuggestionsEnabled else {
                finish("Settings did not read the enabled preference")
                return
            }
            probe.setSearchSuggestionsEnabled(false)
            guard !EngineSearchSuggestionsSettings.live.isEnabled(), !probe.searchSuggestionsEnabled else {
                finish("Settings did not turn off the engine preference")
                return
            }
            runtime.openCommandBar(.newTab)
            runtime.browserCheckPhase = 4
        case 4:
            guard bar?.isOpen == true else { return }
            submit("disabled query", waitForSilence: true)
        case 5:
            guard Date() >= waitUntil else { return }
            conditions["off_sends_no_request"] = requests.suggestions == expectedQueries && hasSuggestions([], in: bar)
            runtime.openSettings()
            guard let probe = runtime.settings?.checkProbe(), !probe.searchSuggestionsEnabled else {
                finish("Reopening Settings did not read the disabled preference")
                return
            }
            probe.setSearchSuggestionsEnabled(true)
            guard EngineSearchSuggestionsSettings.live.isEnabled() else { finish("Settings did not turn suggestions back on"); return }
            submit("private.example/path", waitForSilence: true)
        case 6:
            guard Date() >= waitUntil else { return }
            conditions["url_sends_no_request"] = requests.suggestions == expectedQueries && hasSuggestions([], in: bar)
            submit("~/Secret Notes/draft.txt", waitForSilence: true)
        case 7:
            guard Date() >= waitUntil else { return }
            conditions["file_path_sends_no_request"] = requests.suggestions == expectedQueries && hasSuggestions([], in: bar)
            bar?.update(query: "debounced query")
            submit("slow query")
        case 8:
            guard requests.suggestions.contains("slow query") else { return }
            submit("fresh query")
            waitUntil = Date().addingTimeInterval(1.2)
        case 9:
            guard Date() >= waitUntil else { return }
            conditions["debounce_and_stale_response"] = requests.suggestions == expectedQueries
                && hasSuggestions(["fresh query fixture"], in: bar)
            bar?.update(query: "closed query")
            runtime.commandPresenter?.close(restoreFocus: false)
            waitUntil = Date().addingTimeInterval(0.7)
            runtime.browserCheckPhase = 10
        case 10:
            guard Date() >= waitUntil else { return }
            conditions["closed_bar_cancels_request"] = requests.suggestions == expectedQueries
            host.checkCreateIncognito()
            runtime.browserCheckPhase = 11
        case 11:
            guard let child = runtime.children.first(where: { $0.isPrivateWindow && $0.host?.hasBrowser() == true }),
                  let privateHost = child.host else { return }
            child.openCommandBar(.newTab)
            guard let privateBar = child.commandPresenter?.controller, privateBar.privateWindow else { return }
            privateBar.update(query: "private query")
            privateHost.querySearchSuggestions("private engine query") { _ in }
            waitUntil = Date().addingTimeInterval(0.7)
            runtime.browserCheckPhase = 12
        case 12:
            guard Date() >= waitUntil else { return }
            let child = runtime.children.first(where: \.isPrivateWindow)
            conditions["private_sends_no_request"] = requests.suggestions == expectedQueries
                && hasSuggestions([], in: child?.commandPresenter?.controller)
            child?.commandPresenter?.close(restoreFocus: false)
            let failed = conditions.filter { !$0.value }.keys.sorted()
            finish(failed.isEmpty ? nil : failed.joined(separator: ", "))
        default: break
        }
    }
}
