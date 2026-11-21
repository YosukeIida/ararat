import AppKit
import AraratEngineAPI
import AraratUI

@MainActor
final class SettingsPasswordsTouchIDCheck {
    private let website = "https://touch-id-list.test/"
    private let username = "touch-id-fixture"
    private let password = "fixture-touch-id-58"
    private var listStore: (any ARPasswordsAPI)?
    private var fillStore: (any ARPasswordsAPI)?
    private var loadingFillProfile = false
    private var seeding = false
    private var pendingTicks = 0
    private var fieldReadPending = false
    private var fieldValues: [String]?
    private var focusResult: Bool?
    private var nextKeyAt = 0.0

    func tick(_ runtime: Runtime, probe: SettingsCheckProbe, check: SettingsScreenCheck,
              note: (String) -> Void, step: (Int) -> Void, end: (String, Bool) -> Void,
              finish: () -> Void, capture: (String) -> Bool) {
        guard let port = runtime.promptFixturePort, let host = runtime.host else {
            note("waiting for the loopback fixture and browser window"); return
        }
        let origin = "http://127.0.0.1:\(port)/"
        let login = origin + "password-login?case=touch-id"
        func locked() -> Bool { probe.passwordsLocked && probe.passwordWebsites == nil }
        func arm(_ outcome: ARTouchIDCheckOutcome, store: (any ARPasswordsAPI)?) -> Bool {
            store?.checkArmTouchID?(outcome) == true
        }

        switch check.phase {
        case 2:
            guard probe.isVisible, locked(), let owner = (runtime.root ?? runtime).settings,
                  owner.passwordsProfile == "Default" else {
                note("waiting for the locked Default profile Passwords pane"); return
            }
            if listStore == nil {
                guard let store = runtime.passwordsHandle(profile: "Default") else { return }
                guard !store.checkUsesFakeAuthentication else { end("fake_auth_off", false); return }
                check.report("fake_auth_off", true)
                guard store.checkStartTouchID?() == true, store.checkTouchIDWasActivated == true,
                      store.checkHadBiometricsAvailable, store.showsFillAuthentication else {
                    end("fill_switch_visible", false); return
                }
                listStore = store
                probe.refreshPasswordPreferences()
            }
            if let listStore { seed(listStore, website: website, condition: "list_fixture", check: check) }
            guard let seeded = check.conditions["list_fixture"] else { return }
            end("list_fixture", seeded)
        case 3:
            guard locked(), probe.marker("row-password-fill")?.isEmpty == false,
                  probe.marker("passwords-unlock")?.isEmpty == false else {
                note("waiting for the Fill passwords with Touch ID row"); return
            }
            check.report("fill_switch_visible", true)
            guard capture("locked") else { end("capture", false); return }
            guard arm(.failure, store: listStore) else { end("failure_keeps_locked", false); return }
            step(4)
            probe.unlockPasswords()
        case 4:
            guard !probe.passwordsAuthenticationPending else { return }
            guard locked(), probe.passwordsAuthenticationFailed,
                  listStore?.checkTouchIDConsumedPrompt == true else {
                end("failure_keeps_locked", false); return
            }
            check.report("failure_keeps_locked", true)
            guard arm(.unresolved, store: listStore) else { end("unresolved_keeps_locked", false); return }
            step(5)
            probe.unlockPasswords()
        case 5:
            guard locked(), probe.passwordsAuthenticationPending,
                  listStore?.checkTouchIDConsumedPrompt == true else {
                end("unresolved_keeps_locked", false); return
            }
            pendingTicks += 1
            guard pendingTicks >= 3 else { return }
            check.report("unresolved_keeps_locked", true)
            step(6)
            probe.lockPasswordsForCheck()
        case 6:
            guard locked(), !probe.passwordsAuthenticationPending,
                  listStore?.checkTouchIDConsumedPrompt == true else {
                end("cancel_keeps_locked", false); return
            }
            check.report("cancel_keeps_locked", true)
            guard arm(.success, store: listStore) else { end("success_unlocks", false); return }
            step(7)
            probe.unlockPasswords()
        case 7:
            guard !probe.passwordsAuthenticationPending else { return }
            guard !locked(), listStore?.checkTouchIDConsumedPrompt == true else {
                end("success_unlocks", false); return
            }
            guard probe.passwordWebsites == [website],
                  probe.marker("passwords-result")?.isEmpty == false else {
                note("waiting for the unlocked fixture row"); return
            }
            check.report("success_unlocks", true)
            guard capture("unlocked") else { end("capture", false); return }
            (runtime.root ?? runtime).settings?.window?.orderOut(nil)
            step(8)
            runtime.switchWorkspaceSpace("named")
        case 8:
            guard runtime.snapshot.shownSpaceId == "named",
                  host.profileDirectory() == "Profile 1", runtime.adapter != nil else {
                note("waiting for the second scratch profile"); return
            }
            if fillStore == nil, !loadingFillProfile {
                loadingFillProfile = true
                fillStore = runtime.passwordsHandle(profile: "Profile 1") { [weak self] store in
                    self?.fillStore = store
                }
            }
            guard let fillStore else { return }
            if check.conditions["fill_fixture"] == nil {
                guard fillStore.checkStartTouchID?() == true, !fillStore.checkUsesFakeAuthentication,
                      fillStore.checkEnableTouchIDFillPreference?() == true,
                      fillStore.authenticatesBeforeFilling else { end("fill_fixture", false); return }
                seed(fillStore, website: origin, condition: "fill_fixture", check: check)
            }
            guard let seeded = check.conditions["fill_fixture"] else { return }
            guard seeded else { end("fill_fixture", false); return }
            step(9)
            runtime.adapter?.openCommandURL(login + "&attempt=refusal", expectedSpace: "named", profile: "Profile 1")
        case 9...16:
            guard let fillStore else { return }
            let success = check.phase >= 13
            let url = login + (success ? "&attempt=success" : "&attempt=refusal")
            let condition = success ? "fill_success" : "fill_refusal"
            guard host.profileDirectory() == "Profile 1",
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == host.activeItemId() }),
                  tab.url == url, !tab.isLoading else { note("waiting for the \(condition) page"); return }
            let phase = success ? check.phase - 4 : check.phase
            let window = host.window()
            switch phase {
            case 9:
                if let focusResult {
                    guard focusResult else { end(condition, false); return }
                    nextKeyAt = 0
                    step(check.phase + 1)
                    return
                }
                guard !fieldReadPending else { return }
                window.makeKeyAndOrderFront(nil)
                tab.focusCheckPage()
                fieldReadPending = true
                if tab.checkTouchIDFixture?(url, focus: true, completion: { [weak self] reply in
                    self?.fieldReadPending = false
                    self?.focusResult = self?.decodeFields(reply) == ["", ""]
                }) != true { end(condition, false) }
            case 10:
                let now = ProcessInfo.processInfo.systemUptime
                guard now >= nextKeyAt else { return }
                runtime.promptScreenKey(window, code: 125, characters: "\u{f701}")
                if tab.checkTouchIDPasswordSuggestion?(url, accept: false) == true {
                    nextKeyAt = now + 0.6
                    step(check.phase + 1)
                } else {
                    note("waiting for the Chromium password suggestion")
                    nextKeyAt = now + 0.3
                }
            case 11:
                guard ProcessInfo.processInfo.systemUptime >= nextKeyAt else { return }
                guard tab.checkTouchIDPasswordSuggestion?(url, accept: false) == true,
                      arm(success ? .success : .failure, store: fillStore) else { end(condition, false); return }
                pendingTicks = 0
                fieldValues = nil
                step(check.phase + 1)
                guard tab.checkTouchIDPasswordSuggestion?(url, accept: true) == true else { end(condition, false); return }
            case 12:
                guard fillStore.checkTouchIDConsumedPrompt == true else {
                    note("waiting for Chromium to consume the \(condition) prompt")
                    _ = tab.checkTouchIDPasswordSuggestion?(url, accept: true)
                    return
                }
                if let values = fieldValues {
                    fieldValues = nil
                    pendingTicks += 1
                    if success {
                        guard values != ["", ""] || pendingTicks < 10 else { end(condition, false); return }
                        guard values != ["", ""] else { return }
                        guard values == [username, password] else { end(condition, false); return }
                    } else {
                        guard values == ["", ""] else { end(condition, false); return }
                        guard pendingTicks >= 3 else { return }
                    }
                    check.report(condition, true)
                    check.capturing = true
                    let image = runtime.promptScreenScreenshot(window, name: "passwords-touch-id-\(condition)", withoutShadow: true)
                    check.capturing = false
                    guard let image else { end("capture", false); return }
                    check.images[condition] = image
                    if success {
                        finish()
                    } else {
                        focusResult = nil
                        step(13)
                        runtime.adapter?.openCommandURL(login + "&attempt=success", expectedSpace: "named", profile: "Profile 1")
                    }
                    return
                }
                guard !fieldReadPending else { return }
                fieldReadPending = true
                if tab.checkTouchIDFixture?(url, focus: false, completion: { [weak self] reply in
                    self?.fieldReadPending = false
                    self?.fieldValues = self?.decodeFields(reply)
                }) != true { end(condition, false) }
            default:
                break
            }
        default:
            break
        }
    }

    private func decodeFields(_ reply: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(reply.utf8))) ?? []
    }

    private func seed(_ store: any ARPasswordsAPI, website: String, condition: String, check: SettingsScreenCheck) {
        guard check.conditions[condition] == nil, !seeding else { return }
        seeding = true
        store.snapshot { [weak self] state, rows in
            guard let self else { return }
            self.seeding = false
            guard state != .loading else { return }
            let added = state == .ready && rows.isEmpty && Array(self.password.utf16).withUnsafeBufferPointer {
                guard let address = $0.baseAddress else { return false }
                return store.addWebsite(website, username: self.username, password: address, length: UInt($0.count))
            }
            check.report(condition, added)
        }
    }
}
