import AraratEngineAPI
import AraratUI

extension Runtime {
    func settingsPasswordsTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                               note: (String) -> Void, step: (Int) -> Void, end: (String, Bool) -> Void,
                               finish: () -> Void, capture: (String) -> Bool) {
        let fixtures = [
            (website: "https://calendar.example/", username: "calendar-user", password: "Fixture-calendar-123"),
            (website: "https://news.example/", username: "news-user", password: "Fixture-news-456"),
        ]
        let target = fixtures[0]
        func hasMarker(_ id: String) -> Bool { probe.marker(id)?.isEmpty == false }

        guard probe.isVisible, probe.paneID == "passwords" else {
            note("waiting for the Passwords pane"); return
        }
        switch check.phase {
        case 2:
            guard probe.passwordsLocked, let profile = (root ?? self).settings?.passwordsProfile,
                  let handle = passwordsHandle(profile: profile) else {
                note("waiting for the locked pane and its profile"); return
            }
            step(3)
            handle.authenticate { ok in
                probe.refreshPasswordPreferences()
                check.report("fake_auth", ok && handle.showsFillAuthentication)
            }
        case 3:
            guard let authenticated = check.conditions["fake_auth"] else {
                note("waiting for mock authentication"); return
            }
            guard authenticated else { finish(); return }
            if check.conditions["fixtures"] == nil {
                guard !check.passwordSnapshotPending, let profile = (root ?? self).settings?.passwordsProfile,
                      let handle = passwordsHandle(profile: profile) else { return }
                check.passwordSnapshotPending = true
                note("waiting for the empty scratch password store")
                handle.snapshot { state, rows in
                    check.passwordSnapshotPending = false
                    guard state != .loading else { return }
                    let added = state == .ready && rows.isEmpty && fixtures.allSatisfy { fixture in
                        Array(fixture.password.utf16).withUnsafeBufferPointer {
                            guard let password = $0.baseAddress else { return false }
                            return handle.addWebsite(fixture.website, username: fixture.username,
                                                     password: password, length: UInt($0.count))
                        }
                    }
                    check.report("fixtures", added)
                }
                return
            }
            guard check.conditions["fixtures"] == true else { finish(); return }
            guard probe.passwordsLocked, hasMarker("passwords-unlock"), hasMarker("row-password-fill"),
                  !hasMarker("passwords-search"), !hasMarker("passwords-result") else {
                note("waiting for the locked list and Fill passwords row"); return
            }
            check.report("locked", true)
            guard capture("locked") else { end("capture", false); return }
            probe.unlockPasswords()
            step(4)
        case 4:
            guard probe.passwordWebsites?.sorted() == fixtures.map(\.website).sorted() else {
                note("waiting for both fixture sign-ins in the unlocked list"); return
            }
            probe.searchPasswords("calendar")
            step(5)
        case 5:
            guard probe.passwordWebsites == [target.website], hasMarker("passwords-search"),
                  probe.markers(prefix: "passwords-result").filter({ !$0.frame.isEmpty }).count == 1,
                  hasMarker("row-password-fill"), !hasMarker("passwords-unlock") else {
                note("waiting for the filtered list to show just the calendar result"); return
            }
            check.report("search", true)
            guard capture("search") else { end("capture", false); return }
            probe.revealPassword(for: target.website)
            step(6)
        case 6:
            guard probe.isShowingRevealedPassword(for: target.website, matching: target.password),
                  hasMarker("passwords-revealed"), !hasMarker("passwords-search"), !hasMarker("passwords-result") else {
                note("waiting for the detail with the revealed fixture password"); return
            }
            check.report("detail", true)
            guard capture("detail") else { end("capture", false); return }
            finish()
        default:
            break
        }
    }
}
