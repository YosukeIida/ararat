import AppKit
import AraratEngineAPI
import os

@MainActor
final class PasswordPromptCheck {
    enum Scenario: String, CaseIterable {
        case save, update, notNow, masterOff, offerOff, masterRevoked, offerRevoked
        case privateWindow, background, tabSwitch, crossHost, tabClose, never, neverAgain
        case implicitClose, suppressed, newerSubmission, littleWindow, confirmation

        var expectsNoPrompt: Bool {
            self == .masterOff || self == .offerOff || self == .privateWindow || self == .neverAgain
        }

        var usesBlocklistFixture: Bool { self == .never || self == .neverAgain }

        func fixturePort(primary: UInt16, blocklist: UInt16?) -> UInt16? {
            usesBlocklistFixture ? blocklist : primary
        }
    }

    private enum Phase: String {
        case unlock, start, fill, submit, wait, capture, switchedAway, reshow, closed, reopen, reopened, store
    }

    struct CaptureSample: Equatable {
        let window: Int
        let frame: NSRect
        let alpha: Double?

        func isSettled(after previous: Self?) -> Bool {
            alpha == 1 && !frame.isEmpty && self == previous
        }

        var diagnostics: [String: Any] {
            ["window": window, "frame": NSStringFromRect(frame), "alpha": alpha as Any? ?? NSNull()]
        }
    }

    private static let captureTimeout: TimeInterval = 2
    private static let caseTimeout: TimeInterval = 15
    private var captureDeadline: TimeInterval = 0
    private var caseDeadline: TimeInterval?
    private var previousCaptureSample: CaptureSample?

    private var phase = Phase.unlock
    private var remaining = Scenario.allCases[...]
    private var tab: (any ARTabAPI)?
    private var store: (any ARPasswordsAPI)?
    private var pending = false
    private var finished = false
    private var blocklistFixture: PromptFixtureServer?
    private var blocklistPort: UInt16?
    private var settled = 0
    private var notNowBeforeNavigation = 0
    private var suppressionDismissals = 0
    private var priorOffer: UInt = 0
    private var didReopen = false
    private var confirmationUnavailable: String?
    private var conditions: [String: Bool] = [:]
    private var captures: [String: [String: Any]] = [:]
    private var rendererForm = "unprobed"
    private var failedAction: String?
    private var details: [String: Any] = [:]
    private nonisolated static let latestDetails = OSAllocatedUnfairLock(initialState: Data())

    nonisolated static func watchdogDetails() -> [String: Any] {
        let data = latestDetails.withLock { $0 }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [
            "case": "save", "step": "startup", "controller_state": -1,
            "dialog_exists": false, "fixture_page_state": "unavailable",
        ]
    }

    private func updateDetails(_ target: (any ARTabAPI)?) {
        let path = target.flatMap { URL(string: $0.url)?.path }
        let page: String
        if target?.isLoading == true {
            page = "loading"
        } else {
            switch path {
            case "/password-login": page = "login"
            case "/password-success": page = "success"
            case "/password-complete": page = "cross_host"
            default: page = target == nil ? "unavailable" : "other"
            }
        }
        var current: [String: Any] = [
            "case": remaining.first?.rawValue ?? "done", "step": phase.rawValue,
            "controller_state": target?.checkPasswordPromptState() ?? -1,
            "dialog_exists": target?.checkHasPasswordPrompt() ?? false,
            "dialog_visible": target?.checkPasswordPromptWindow() != nil,
            "fixture_page_state": page, "renderer_form": rendererForm,
            "callback_pending": pending,
        ]
        if let failedAction { current["failed_action"] = failedAction }
        if !NSDictionary(dictionary: current).isEqual(to: details),
           let data = try? JSONSerialization.data(withJSONObject: current, options: [.sortedKeys]) {
            details = current
            Self.latestDetails.withLock { $0 = data }
            FileHandle.standardError.write(Data("ararat-trace: password-check ".utf8) + data + Data([10]))
        }
    }

    func results() -> [String: Any] {
        ["conditions": conditions, "captures": captures, "details": details,
         "scenario": remaining.first?.rawValue ?? "done",
         "unverified": confirmationUnavailable.map { ["automatic_confirmation": $0] } ?? [:],
         "failed_conditions": Scenario.allCases.filter { conditions[$0.rawValue] != true &&
             !($0 == .confirmation && confirmationUnavailable != nil) }.map(\.rawValue)]
    }

    func tick(_ runtime: Runtime, host: any ARWindowHostAPI) {
        guard !finished, let scenario = remaining.first else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = caseDeadline ?? now + Self.caseTimeout
        caseDeadline = deadline
        guard now < deadline else {
            fail("timeout_\(phase.rawValue)", runtime: runtime)
            return
        }
        guard !pending, let primary = runtime.promptFixturePort else { return }
        if scenario.usesBlocklistFixture && blocklistFixture == nil {
            startBlocklistFixture(runtime)
            return
        }
        guard let port = scenario.fixturePort(primary: primary, blocklist: blocklistPort) else { return }
        let fixture = "http://127.0.0.1:\(port)/password-login?case=\(scenario.rawValue)" +
            (scenario == .newerSubmission && priorOffer != 0 ? "&variant=2" : "")
        let crossHostDestination = "http://localhost:\(port)/password-complete"
        let regularTabs = host.tabs() as? [any ARTabAPI] ?? []
        let privateHost = runtime.children.first(where: \.isPrivateWindow)?.host
        let privateTabs = privateHost?.tabs() as? [any ARTabAPI] ?? []
        let little = scenario == .littleWindow ? runtime.littleWindows.first : nil
        let tabs = scenario == .privateWindow ? privateTabs :
            scenario == .littleWindow ? [little?.checkPasswordTab].compactMap { $0 } : regularTabs
        updateDetails(tab ?? tabs.first(where: { $0.url == fixture }) ?? tabs.first)

        switch phase {
        case .unlock:
            guard runtime.preparePromptFixture(host, name: "password-login") else { return }
            if store == nil { store = runtime.passwordsHandle(profile: host.profileDirectory()) }
            guard let store else { return }
            pending = true
            store.authenticate { [weak self, weak runtime] authorized in
                guard let self, let runtime, !self.finished else { return }
                self.pending = false
                if authorized {
                    self.phase = .start
                } else {
                    self.fail("scratch_store_authorization", runtime: runtime)
                }
            }
        case .start:
            guard let store, regularTabs.first?.isLoading == false else { return }
            guard store.setManagerEnabled(scenario != .masterOff) else {
                fail("manager_preference", runtime: runtime)
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
            if scenario == .littleWindow {
                runtime.openLittleWindow(url: fixture)
            } else {
                host.checkNavigate(fixture, disposition: disposition)
            }
            phase = .fill
        case .fill:
            guard let target = tabs.first(where: { $0.url == fixture && !$0.isLoading }) else { return }
            tab = target
            pending = true
            if scenario == .confirmation {
                if !target.checkStartPasswordConfirmation({ [weak self] result in
                    MainActor.assumeIsolated {
                        guard let self, !self.finished else { return }
                        self.pending = false
                        if result != "started" { self.confirmationUnavailable = "Credential Management API unavailable" }
                        self.phase = .wait
                    }
                }) { pending = false }
                return
            }
            let started = target.checkFillPasswordFixture { [weak self, weak runtime] result in
                MainActor.assumeIsolated {
                    guard let self, let runtime, !self.finished else { return }
                    self.pending = false
                    switch result {
                    case "filled", "missing_form", "missing_field", "missing_script", "edit_failed", "no_renderer_result":
                        self.rendererForm = result
                    default: self.rendererForm = "unexpected_renderer_result"
                    }
                    self.updateDetails(self.tab)
                    if result == "filled" { self.phase = .submit }
                    else { self.record(false, runtime: runtime) }
                }
            }
            if !started { pending = false }
        case .submit:
            guard let tab, tab.checkSubmitPasswordFixture() else { return }
            phase = .wait
            updateDetails(tab)
        case .wait:
            if scenario == .confirmation {
                guard let tab else { return }
                if let dialog = tab.checkPasswordPromptWindow() {
                    guard dialog.title.lowercased() == "password updated",
                          tab.checkDialogHostIsOurs(),
                          tab.checkPasswordPromptAction("accept") else { record(false, runtime: runtime); return }
                    phase = .closed
                } else if confirmationUnavailable != nil || settled == 40 {
                    if tab.checkHasPasswordPrompt() { record(false, runtime: runtime); return }
                    confirmationUnavailable = confirmationUnavailable ?? "Chromium did not enter confirmation"
                    phase = .store
                } else { settled += 1 }
                return
            }
            guard let tab, !tab.isLoading, tab.url == "http://127.0.0.1:\(port)/password-success" else { return }
            let dialog = tab.checkPasswordPromptWindow()
            if scenario == .suppressed, suppressionDismissals == 3 {
                guard dialog == nil, !tab.checkIsDialogActive() else {
                    record(false, runtime: runtime); return
                }
                if tab.passwordOffer.generation != 0 {
                    settled += 1
                    if settled == 10 { phase = .reopen }
                } else {
                    settled = 0
                }
                return
            }
            if scenario.expectsNoPrompt {
                guard dialog == nil, !tab.checkIsDialogActive(), tab.passwordOffer.generation == 0 else {
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
                if scenario == .save {
                    for action in ["clearPassword", "editPassword"] {
                        guard tab.checkPasswordPromptAction(action) else {
                            fail(action, runtime: runtime)
                            return
                        }
                    }
                }
                captureDeadline = ProcessInfo.processInfo.systemUptime + Self.captureTimeout
                previousCaptureSample = nil
                phase = .capture
                return
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
            case .notNow, .suppressed, .newerSubmission, .littleWindow:
                guard tab.checkPasswordPromptAction("cancel") else { record(false, runtime: runtime); return }
            case .implicitClose:
                guard tab.checkPasswordPromptAction("close") else { record(false, runtime: runtime); return }
            case .background:
                guard tab.checkPasswordPromptAction("escape") else { record(false, runtime: runtime); return }
            case .masterOff, .offerOff, .privateWindow, .neverAgain, .confirmation:
                return
            }
            phase = .closed
        case .capture:
            let dialog = tab?.checkPasswordPromptWindow()
            let sample = dialog.map(Self.captureSample)
            let previous = previousCaptureSample
            previousCaptureSample = sample
            let settled = sample?.isSettled(after: previous) == true
            guard ProcessInfo.processInfo.systemUptime < captureDeadline else {
                captures[scenario.rawValue] = [
                    "error": "capture_timeout", "timeout_seconds": Self.captureTimeout,
                    "settled": settled, "current": sample?.diagnostics as Any? ?? NSNull(),
                    "previous": previous?.diagnostics as Any? ?? NSNull(),
                ]
                record(false, runtime: runtime)
                return
            }
            guard settled, let tab, let dialog, tab.checkIsDialogActive(), tab.checkDialogHostIsOurs(),
                  let capture = runtime.promptScreenCapture(host, name: "password-\(scenario.rawValue)",
                                                            dialogWindow: dialog) else { return }
            captures[scenario.rawValue] = capture
            guard capture["centered"] as? Bool == true,
                  tab.checkPasswordPromptAction("accept") else { record(false, runtime: runtime); return }
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
            if scenario == .masterRevoked {
                guard store?.setManagerEnabled(true) == true else { record(false, runtime: runtime); return }
            } else if scenario == .offerRevoked {
                store?.offersToSave = true
            }
            if [.masterRevoked, .offerRevoked, .crossHost, .never, .tabClose].contains(scenario),
               tab.passwordOffer.generation != 0 { record(false, runtime: runtime); return }
            if scenario == .suppressed, !didReopen {
                suppressionDismissals += 1
                phase = .start
                return
            }
            if scenario == .newerSubmission {
                let generation = tab.passwordOffer.generation
                guard generation != 0 else { return }
                if priorOffer == 0 {
                    priorOffer = generation
                    phase = .start
                    return
                }
                guard generation != priorOffer, !tab.reopenPasswordOffer(priorOffer) else {
                    record(false, runtime: runtime); return
                }
            }
            if [.notNow, .tabSwitch, .implicitClose, .littleWindow].contains(scenario), !didReopen {
                phase = .reopen
                return
            }
            phase = .store
        case .reopen:
            guard let tab, tab.passwordOffer.generation != 0,
                  let button = scenario == .littleWindow ? little?.checkPasswordOfferButton :
                    runtime.sidebar?.checkPasswordOfferButton,
                  !button.isHidden, button.frame.width == 24 else { return }
            if scenario == .notNow || scenario == .littleWindow {
                guard let window = button.window,
                      let path = runtime.promptScreenScreenshot(window, name: "password-key-\(scenario.rawValue)") else { return }
                captures["key_\(scenario.rawValue)"] = ["screenshot": path]
            }
            didReopen = true
            button.performClick(nil)
            phase = .reopened
        case .reopened:
            guard let tab, tab.checkPasswordPromptWindow()?.title == "Save password?",
                  tab.checkDialogHostIsOurs() else { return }
            guard tab.checkPasswordPromptAction("close") else { record(false, runtime: runtime); return }
            if scenario == .littleWindow { little?.close(archive: false) }
            phase = .closed
        case .store:
            guard let store else { return }
            pending = true
            store.snapshot { [weak self, weak runtime] state, rows in
                guard let self, let runtime, !self.finished else { return }
                self.pending = false
                if state == .loading { return }
                guard state == .ready else { self.record(false, runtime: runtime); return }
                if scenario == .save && rows.isEmpty { return }
                guard rows.count == 1, let row = rows.first, row.username == "fixture" else {
                    self.record(false, runtime: runtime)
                    return
                }
                guard scenario == .save || scenario == .update || scenario == .confirmation else {
                    self.record(true, runtime: runtime); return
                }
                let expected = scenario == .save ? "fixture-edited-56" :
                    scenario == .update ? "fixture-updated-72" : "fixture-confirmed-39"
                self.pending = true
                store.revealRow(row.rowID) { [weak self, weak runtime] password, length in
                    guard let self, let runtime, !self.finished else { return }
                    self.pending = false
                    guard let password else { self.record(false, runtime: runtime); return }
                    let value = UnsafeBufferPointer(start: password, count: Int(length))
                    if scenario == .confirmation && self.confirmationUnavailable != nil {
                        self.record(value.elementsEqual("fixture-updated-72".utf16), runtime: runtime)
                    } else if value.elementsEqual(expected.utf16) {
                        self.record(true, runtime: runtime)
                    }
                }
            }
        }
    }

    private func startBlocklistFixture(_ runtime: Runtime) {
        // Never persists for the whole origin, including submissions with a different username.
        do {
            let fixture = try PromptFixtureServer(tracePasswordPrompt: true)
            blocklistFixture = fixture
            pending = true
            fixture.start { [weak self, weak runtime] result in
                DispatchQueue.main.async {
                    guard let self, let runtime, !self.finished else { return }
                    self.pending = false
                    switch result {
                    case .success(let port):
                        self.blocklistPort = port
                    case .failure:
                        self.fail("blocklist_fixture_start", runtime: runtime)
                    }
                }
            }
        } catch {
            fail("blocklist_fixture_init", runtime: runtime)
        }
    }

    private static func captureSample(_ dialog: NSWindow) -> CaptureSample {
        // Chromium applies the show fade and warp in WindowServer, bypassing NSWindow.alphaValue.
        let number = dialog.windowNumber
        let rows = CGWindowID(exactly: number).flatMap {
            CGWindowListCopyWindowInfo(.optionIncludingWindow, $0) as? [[String: Any]]
        }
        let row = rows?.first { $0[kCGWindowNumber as String] as? Int == number &&
                                $0[kCGWindowIsOnscreen as String] as? Bool == true }
        return CaptureSample(window: number, frame: dialog.frame, alpha: row?[kCGWindowAlpha as String] as? Double)
    }

    private func record(_ passed: Bool, runtime: Runtime) {
        guard !finished, let scenario = remaining.first else { return }
        if scenario == .confirmation && !passed { confirmationUnavailable = nil }
        if scenario != .confirmation || confirmationUnavailable == nil {
            conditions[scenario.rawValue] = passed
        }
        if passed { remaining = remaining.dropFirst() }
        if !passed || remaining.isEmpty {
            finished = true
            blocklistFixture?.stop()
            store?.invalidate()
            runtime.finishBrowserCheck(ok: passed, values: results())
            return
        }
        tab = nil
        rendererForm = "unprobed"
        settled = 0
        didReopen = false
        caseDeadline = nil
        phase = .start
    }

    private func fail(_ action: String, runtime: Runtime) {
        failedAction = action
        updateDetails(tab)
        record(false, runtime: runtime)
    }
}
