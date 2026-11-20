import AppKit
import AraratEngineAPI
import os

@MainActor
final class PasswordPromptCheck {
    private enum Scenario: String, CaseIterable {
        case save, update, notNow, masterOff, offerOff, masterRevoked, offerRevoked
        case privateWindow, background, tabSwitch, crossHost, tabClose, never, neverAgain

        var expectsNoPrompt: Bool {
            self == .masterOff || self == .offerOff || self == .privateWindow || self == .neverAgain
        }
    }

    private enum Phase: String { case unlock, start, fill, submit, wait, capture, switchedAway, reshow, closed, store }

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
    private var captureDeadline: TimeInterval = 0
    private var previousCaptureSample: CaptureSample?

    private var phase = Phase.unlock
    private var remaining = Scenario.allCases[...]
    private var tab: (any ARTabAPI)?
    private var store: (any ARPasswordsAPI)?
    private var pending = false
    private var settled = 0
    private var notNowBeforeNavigation = 0
    private var conditions: [String: Bool] = [:]
    private var captures: [String: [String: Any]] = [:]
    private var rendererForm = "unprobed"
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
        let current: [String: Any] = [
            "case": remaining.first?.rawValue ?? "done", "step": phase.rawValue,
            "controller_state": target?.checkPasswordPromptState() ?? -1,
            "dialog_exists": target?.checkHasPasswordPrompt() ?? false,
            "dialog_visible": target?.checkPasswordPromptWindow() != nil,
            "fixture_page_state": page, "renderer_form": rendererForm,
            "callback_pending": pending,
        ]
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
         "failed_conditions": Scenario.allCases.map(\.rawValue).filter { conditions[$0] != true }]
    }

    func tick(_ runtime: Runtime, host: any ARWindowHostAPI) {
        guard let scenario = remaining.first, let port = runtime.promptFixturePort else { return }
        let fixture = "http://127.0.0.1:\(port)/password-login?case=\(scenario.rawValue)"
        let crossHostDestination = "http://localhost:\(port)/password-complete"
        let regularTabs = host.tabs() as? [any ARTabAPI] ?? []
        let privateHost = runtime.children.first(where: \.isPrivateWindow)?.host
        let privateTabs = privateHost?.tabs() as? [any ARTabAPI] ?? []
        let tabs = scenario == .privateWindow ? privateTabs : regularTabs
        updateDetails(tab ?? tabs.first(where: { $0.url == fixture }) ?? tabs.first)
        guard !pending else { return }

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
            phase = .fill
        case .fill:
            guard let target = tabs.first(where: { $0.url == fixture && !$0.isLoading }) else { return }
            tab = target
            pending = true
            let started = target.checkFillPasswordFixture { [weak self, weak runtime] result in
                MainActor.assumeIsolated {
                    guard let self, let runtime else { return }
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
            case .notNow:
                guard tab.checkPasswordPromptAction("cancel") else { record(false, runtime: runtime); return }
            case .background:
                guard tab.checkPasswordPromptAction("escape") else { record(false, runtime: runtime); return }
            case .masterOff, .offerOff, .privateWindow, .neverAgain:
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
        guard let scenario = remaining.first else { return }
        conditions[scenario.rawValue] = passed
        if passed { remaining = remaining.dropFirst() }
        if !passed || remaining.isEmpty {
            store?.invalidate()
            runtime.finishBrowserCheck(ok: passed, values: results())
            return
        }
        tab = nil
        rendererForm = "unprobed"
        settled = 0
        phase = .start
    }
}
