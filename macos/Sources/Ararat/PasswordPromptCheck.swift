import AppKit
import AraratEngineAPI

@MainActor
final class PasswordPromptCheck {
    private enum Scenario: String, CaseIterable {
        case save, update, notNow, masterOff, offerOff, masterRevoked, offerRevoked
        case privateWindow, background, tabSwitch, crossHost, tabClose, never, neverAgain

        var expectsNoPrompt: Bool {
            self == .masterOff || self == .offerOff || self == .privateWindow || self == .neverAgain
        }
    }

    private enum Phase { case unlock, start, submit, wait, switchedAway, reshow, closed, store }
    private var phase = Phase.unlock
    private var remaining = Scenario.allCases[...]
    private var tab: (any ARTabAPI)?
    private var store: (any ARPasswordsAPI)?
    private var pending = false
    private var settled = 0
    private var notNowBeforeNavigation = 0
    private var conditions: [String: Bool] = [:]
    private var captures: [String: [String: Any]] = [:]

    func results() -> [String: Any] {
        ["conditions": conditions, "captures": captures,
         "scenario": remaining.first?.rawValue ?? "done",
         "failed_conditions": Scenario.allCases.map(\.rawValue).filter { conditions[$0] != true }]
    }

    func tick(_ runtime: Runtime, host: any ARWindowHostAPI) {
        guard !pending, let scenario = remaining.first, let port = runtime.promptFixturePort else { return }
        let fixture = "http://127.0.0.1:\(port)/password-login?case=\(scenario.rawValue)"
        let crossHostDestination = "http://localhost:\(port)/password-complete"
        let regularTabs = host.tabs() as? [any ARTabAPI] ?? []
        let privateHost = runtime.children.first(where: \.isPrivateWindow)?.host
        let privateTabs = privateHost?.tabs() as? [any ARTabAPI] ?? []

        switch phase {
        case .unlock:
            guard runtime.preparePromptFixture(host, name: "password-login") else { return }
            if store == nil { store = runtime.passwordsHandle(profile: host.profileDirectory()) }
            guard let store else { return }
            pending = true
            store.authenticate { [weak self, weak runtime] authorized in
                guard let self, let runtime else { return }
                self.pending = false
                if authorized {
                    self.phase = .start
                } else {
                    runtime.finishBrowserCheck(ok: false, values: ["error": "scratch store authorization"])
                }
            }
        case .start:
            guard let store, regularTabs.first?.isLoading == false else { return }
            guard store.setManagerEnabled(scenario != .masterOff) else {
                runtime.finishBrowserCheck(ok: false, values: ["error": "manager preference"])
                return
            }
            store.offersToSave = scenario != .offerOff
            let disposition: String
            switch scenario {
            case .background: disposition = "background"
            case .tabClose, .tabSwitch: disposition = "foreground"
            case .privateWindow: disposition = "private"
            default: disposition = "current"
            }
            host.checkNavigate(fixture, disposition: disposition)
            phase = .submit
        case .submit:
            let tabs = scenario == .privateWindow ? privateTabs : regularTabs
            guard let target = tabs.first(where: { $0.url == fixture && !$0.isLoading }),
                  target.checkSubmitPasswordFixture() else { return }
            tab = target
            phase = .wait
        case .wait:
            guard let tab, !tab.isLoading, tab.url == "http://127.0.0.1:\(port)/password-success" else { return }
            let dialog = tab.checkPasswordPromptWindow()
            if scenario.expectsNoPrompt {
                guard dialog == nil, !tab.checkIsDialogActive() else {
                    record(false, runtime: runtime)
                    return
                }
                settled += 1
                if settled == 30 {
                    if scenario == .privateWindow { privateHost?.close() }
                    phase = .store
                }
                return
            }
            if scenario == .background, settled < 10 {
                guard dialog == nil, !tab.checkIsDialogActive() else {
                    record(false, runtime: runtime)
                    return
                }
                settled += 1
                if settled == 10 { tab.activate(withCommandId: UUID().uuidString) }
                return
            }
            guard let dialog, tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
            let expectedTitle = scenario == .update ? "Update password?" : "Save password?"
            guard dialog.title == expectedTitle else { record(false, runtime: runtime); return }
            switch scenario {
            case .save, .update:
                guard let capture = runtime.promptScreenCapture(host, name: "password-\(scenario.rawValue)",
                                                                dialogWindow: dialog) else { return }
                captures[scenario.rawValue] = capture
                guard capture["centered"] as? Bool == true,
                      tab.checkPasswordPromptAction("accept") else { record(false, runtime: runtime); return }
            case .masterRevoked:
                guard store?.setManagerEnabled(false) == true else { record(false, runtime: runtime); return }
            case .offerRevoked:
                store?.offersToSave = false
            case .tabClose:
                tab.close(withCommandId: UUID().uuidString)
            case .tabSwitch:
                guard let other = regularTabs.first(where: { $0.liveId != tab.liveId }) else { return }
                other.activate(withCommandId: UUID().uuidString)
                phase = .switchedAway
                return
            case .crossHost:
                notNowBeforeNavigation = tab.checkPasswordPromptNotNowCount()
                guard notNowBeforeNavigation > 0 else { record(false, runtime: runtime); return }
                host.checkNavigate(crossHostDestination, disposition: "current")
            case .never:
                guard tab.checkPasswordPromptAction("never") else { record(false, runtime: runtime); return }
            case .notNow:
                guard tab.checkPasswordPromptAction("cancel") else { record(false, runtime: runtime); return }
            case .background:
                guard tab.checkPasswordPromptAction("escape") else { record(false, runtime: runtime); return }
            case .masterOff, .offerOff, .privateWindow, .neverAgain:
                return
            }
            phase = .closed
        case .switchedAway:
            guard let tab, tab.checkPasswordPromptWindow() == nil, !tab.checkIsDialogActive(),
                  regularTabs.allSatisfy({ !$0.checkIsDialogActive() }) else { return }
            tab.activate(withCommandId: UUID().uuidString)
            phase = .reshow
        case .reshow:
            guard let tab, tab.checkPasswordPromptWindow()?.title == "Save password?",
                  tab.checkIsDialogActive(), tab.checkDialogHostIsOurs() else { return }
            guard tab.checkPasswordPromptAction("escape") else { record(false, runtime: runtime); return }
            phase = .closed
        case .closed:
            guard let tab, tab.checkPasswordPromptWindow() == nil, !tab.checkIsDialogActive() else { return }
            if scenario == .tabClose && regularTabs.contains(where: { $0.liveId == tab.liveId }) { return }
            if scenario == .crossHost {
                guard tab.url == crossHostDestination, !tab.isLoading, !tab.checkHasPasswordPrompt() else { return }
                guard tab.checkPasswordPromptNotNowCount() == notNowBeforeNavigation else {
                    record(false, runtime: runtime)
                    return
                }
            }
            phase = .store
        case .store:
            guard let store else { return }
            pending = true
            store.snapshot { [weak self, weak runtime] state, rows in
                guard let self, let runtime else { return }
                self.pending = false
                if state == .loading { return }
                guard state == .ready else { self.record(false, runtime: runtime); return }
                if scenario == .save && rows.isEmpty { return }
                guard rows.count == 1, let row = rows.first, row.username == "fixture" else {
                    self.record(false, runtime: runtime)
                    return
                }
                guard scenario == .save || scenario == .update else { self.record(true, runtime: runtime); return }
                let expected = scenario == .save ? "fixture-initial-43" : "fixture-updated-72"
                self.pending = true
                store.revealRow(row.rowID) { [weak self, weak runtime] password, length in
                    guard let self, let runtime else { return }
                    self.pending = false
                    guard let password else { self.record(false, runtime: runtime); return }
                    if UnsafeBufferPointer(start: password, count: Int(length)).elementsEqual(expected.utf16) {
                        self.record(true, runtime: runtime)
                    }
                }
            }
        }
    }

    private func record(_ passed: Bool, runtime: Runtime) {
        guard let scenario = remaining.first else { return }
        conditions[scenario.rawValue] = passed
        if passed { remaining = remaining.dropFirst() }
        if !passed || remaining.isEmpty {
            store?.invalidate()
            runtime.finishBrowserCheck(ok: passed, values: results())
            return
        }
        tab = nil
        settled = 0
        phase = .start
    }
}
