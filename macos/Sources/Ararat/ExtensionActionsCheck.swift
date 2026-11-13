import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U26e pass 5's check: the pinned action's badge (per tab, live), pin/unpin through Chrome's
/// per-profile prefs, the context menu (Pin/Unpin, Manage Extension, Remove… with cancel), and
/// the 32 pt overflow row when the URL field would drop below 64 pt.
@MainActor
final class ExtensionActionsCheck {
    static let common = ["fixture", "seed", "pin", "pin_shown", "menu_items", "manage_enabled",
                         "remove_enabled", "badge_text", "badge_icon", "badge_per_tab", "badge_live",
                         "overflow_row", "overflow_geometry", "overflow_restores", "unpin",
                         "repin", "action_anchor", "action_popup", "menu_autoenable_off", "ext_actions_labels", "remove_cancel",
                         "multi_fixtures", "pin_three", "fit_three_240", "fit_three_232",
                         "fit_two_232", "fit_two_199", "fit_two_164", "icons16", "gaps4",
                         "favourite_shift", "multi_restores"]
    static let screens = ["capture_action", "capture_overflow", "capture_three_actions"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var capturing = false
    var waitName = ""
    var waitCount = 0
    var fixtureID = ""
    var secondID = ""
    var thirdID = ""
    var viewport240: CGFloat = 0
    var seedRow: Row?
    var iconBefore: Data?
    var secondTab = ""
    var badgeTab = ""
    var removeStarted = false
    var removeResult = ""
    var removeAttempts = 0
    var actionAnchor: NSRect?
    var lastPhase = -1
    var phaseStart = 0

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: ext-actions \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: ext-actions wait=\(name) current=\(value)\n".utf8))
        }
        if waitName != name { waitCount = 0; waitName = name }
        waitCount += 1
    }

    static func conditionNames(screen: Bool) -> [String] {
        common + (screen ? screens : [])
    }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                "failed_conditions": names.filter { conditions[$0] != true },
                "wait": waitName, "images": images, "fixture_id": fixtureID,
                "remove_result": removeResult,
                "unverified": ["A force-pinned (policy) refusal: the scratch profile has no policy",
                               "An incognito refusal: extensions are disabled in the private profile here",
                               "The uninstall sheet's cancel path when the browser-modal sheet is not findable"]]
    }
}

extension Runtime {
    func extensionActionsCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if extensionActionsCheck == nil { extensionActionsCheck = ExtensionActionsCheck() }
        guard let check = extensionActionsCheck, !check.capturing, let sidebar, let container else { return }
        let window = host.window()
        func wait(_ name: String) {
            let item = extensionItems.first { $0.id == check.fixtureID }
            check.wait(name, "phase=\(browserCheckPhase) key=\(window.isKeyWindow) fixture=\(check.fixtureID.isEmpty ? "nil" : check.fixtureID) items=\(extensionItems.count) pinned=\(item?.pinned ?? false) badge=\(item?.badgeText ?? "-") focused_tab=\(item?.focusedTabId ?? -1) in_field=\(sidebar.checkInFieldActionIDs) row=\(sidebar.checkRowActionIDs) selected=\(snapshot.selectedId ?? "nil") host_active=\(host.activeItemId() ?? "nil") first=\(check.badgeTab) second=\(check.secondTab)")
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            check.capturing = true; defer { check.capturing = false }
            guard let path = promptScreenScreenshot(window, name: "ext-actions-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        func item() -> ExtensionActionItem? { extensionItems.first { $0.id == check.fixtureID } }
        if check.lastPhase != browserCheckPhase {
            check.lastPhase = browserCheckPhase
            check.phaseStart = browserCheckAttempts
        }
        func phaseTicks() -> Int { max(0, browserCheckAttempts - check.phaseStart) }
        func activeTab() -> (any ARTabAPI)? {
            (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == snapshot.selectedId }
        }
        func iconHash(_ item: ExtensionActionItem) -> Data? { item.icon.tiffRepresentation }
        func setWidth(_ width: CGFloat) {
            container.resizeHandle.sidebarWidth = width
            container.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        // Startup self-checks: the loopback fixture and the extension fixture name their
        // failure in a condition with the error text rather than failing the process.
        if let error = siteFixtureError {
            check.mark("fixture", false)
            var values = check.diagnostics(screen: screen)
            values["error"] = "site fixture: \(error)"
            values["fixture_error"] = error
            finishBrowserCheck(ok: false, values: values)
            return
        }
        if siteFixturePorts == nil, browserCheckAttempts > 100 {
            check.mark("fixture", false)
            var values = check.diagnostics(screen: screen)
            values["error"] = "site fixture did not report ports in 10 s"
            values["fixture_error"] = promptFixtureError ?? ""
            finishBrowserCheck(ok: false, values: values)
            return
        }
        if extensionItems.isEmpty, browserCheckAttempts > 100 {
            check.mark("fixture", false)
            var values = check.diagnostics(screen: screen)
            values["error"] = "extension fixture action missing; load test_extensions/windows with --load-extension"
            finishBrowserCheck(ok: false, values: values)
            return
        }

        switch browserCheckPhase {
        case 0:
            guard let ports = siteFixturePorts, let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
                  let row = space.today.first, host.hasBrowser(), window.isVisible, window.isKeyWindow else {
                wait("fixture, seed and key window"); return
            }
            // The windows fixture is loaded by --load-extension; its id is the one the other
            // extension checks use.
            let id = "kmgaadhbnkendcanjninlfmfgehagggl"
            guard extensionItems.contains(where: { $0.id == id }) else { wait("extension fixture action"); return }
            _ = ports
            check.fixtureID = id
            check.mark("fixture")
            check.seedRow = row
            browserCheckSeedID = row.id
            selectCheckSeed(row)
            browserCheckPhase = 1
        case 1:
            guard let id = browserCheckSeedID, snapshot.selectedId == id, host.activeItemId() == id,
                  let tab = activeTab(), !tab.isLoading, tab.navigationCount > 0,
                  let item = item() else { wait("active seed tab"); return }
            check.mark("seed")
            // The multi-action fixtures may load pinned by default; the single-action phases
            // below assume the fixture is the only pinned action, so unpin the others first.
            if extensionItems.contains(where: { $0.id != check.fixtureID && $0.pinned }) {
                for other in extensionItems where other.id != check.fixtureID && other.pinned {
                    _ = adapter?.setExtensionPinned(other.id, pinned: false)
                }
                refreshExtensionActions()
                wait("other actions unpinned")
                return
            }
            if item.pinned {
                check.mark("pin")
            } else if !["done", "unchanged"].contains(adapter?.setExtensionPinned(check.fixtureID, pinned: true) ?? "") {
                wait("pin command"); return
            }
            browserCheckPhase = 2
        case 2:
            guard let item = item(), item.pinned else { wait("pinned action"); return }
            refreshExtensionActions()
            check.mark("pin", true)
            let shown = sidebar.checkInFieldActionIDs.contains(check.fixtureID) || sidebar.checkRowActionIDs.contains(check.fixtureID)
            check.mark("pin_shown", shown)
            guard let menu = sidebar.checkExtensionMenu(check.fixtureID) else { wait("context menu"); return }
            let titles = menu.items.map(\.title)
            let pin = menu.items.first(where: { $0.title == "Unpin" })
            let manage = menu.items.first(where: { $0.title == "Manage Extension" })
            let remove = menu.items.first(where: { $0.title == "Remove…" })
            check.mark("menu_items", titles.contains("Unpin") && titles.contains("Manage Extension") && titles.contains("Remove…"))
            check.mark("manage_enabled", manage?.isEnabled == true
                       && adapter?.extensionManagementURL(check.fixtureID) != nil)
            check.mark("remove_enabled", remove?.isEnabled == true && item.removable && pin?.isEnabled == true)
            menu.update()
            let staysDisabled = menu.autoenablesItems == false
                && pin?.isEnabled == item.pinMutable && remove?.isEnabled == item.removable
            check.mark("menu_autoenable_off", staysDisabled)
            check.mark("ext_actions_labels", sidebar.checkActionLabelsComplete)
            check.iconBefore = iconHash(item)
            if screen { check.mark("capture_action", capture("action")) }
            guard let ports = siteFixturePorts else { wait("badge fixture"); return }
            host.checkNavigate("http://127.0.0.1:\(ports.plain)/clean?badge=7", disposition: "current")
            browserCheckPhase = 3
        case 3:
            guard let ports = siteFixturePorts, let tab = activeTab(),
                  tab.url.contains("127.0.0.1:\(ports.plain)/clean?badge=7"), !tab.isLoading,
                  let item = item(), item.badgeText == "7" else { wait("badge text"); return }
            check.mark("badge_text")
            let changed = check.iconBefore.map { iconHash(item) != $0 } ?? false
            check.mark("badge_icon", changed && iconHash(item)?.isEmpty == false && item.badgeBackgroundColor != 0 && item.badgeTextColor != 0)
            // A second tab through the shown space's open path (a core row plus a live open):
            // the badge is per tab, so the fixture's tab keeps 7 and the new one shows none.
            check.badgeTab = snapshot.selectedId ?? ""
            guard let ports = siteFixturePorts else { wait("second tab fixture"); return }
            adapter?.openCommandURL("http://127.0.0.1:\(ports.plain)/clean",
                                    expectedSpace: snapshot.shownSpaceId,
                                    profile: host.profileDirectory())
            browserCheckPhase = 4
        case 4:
            if let ports = siteFixturePorts, !check.badgeTab.isEmpty,
               let second = snapshot.selectedId, second != check.badgeTab,
               host.activeItemId() == second,
               let tab = activeTab(), tab.url.hasPrefix("http://127.0.0.1:\(ports.plain)/clean"), !tab.isLoading,
               let item = item(), item.badgeText.isEmpty {
                check.mark("badge_per_tab")
                check.secondTab = second
                if let row = check.seedRow { selectCheckSeed(row) }
                browserCheckPhase = 5
                return
            }
            // A failing badge must not hide the later phases: give it 5 s, name it, move on.
            if phaseTicks() > 50 {
                check.mark("badge_per_tab", false)
                if let row = check.seedRow { selectCheckSeed(row) }
                browserCheckPhase = 5
                return
            }
            wait("second tab")
        case 5:
            if let row = check.seedRow, snapshot.selectedId == row.id, host.activeItemId() == row.id,
               let item = item(), item.badgeText == "7" {
                check.mark("badge_live")
                setWidth(164)
                browserCheckPhase = 6
                return
            }
            if phaseTicks() > 50 {
                check.mark("badge_live", false)
                setWidth(164)
                browserCheckPhase = 6
                return
            }
            wait("badge tab again")
        case 6:
            let rowFrame = sidebar.checkActionsRowFrame
            let rowHeight = sidebar.checkActionsRowHeight
            let tile = sidebar.checkActionButton(check.fixtureID)?.frame.width ?? 0
            let expectedTile = sidebar.checkActionTileExpectedWidth
            guard sidebar.checkInFieldActionIDs.isEmpty,
                  sidebar.checkRowActionIDs == [check.fixtureID],
                  rowHeight == 32 else { wait("overflow row"); return }
            check.mark("overflow_row")
            check.mark("overflow_geometry", abs(tile - expectedTile) <= 1 && rowFrame.height == 32)
            if screen { check.mark("capture_overflow", capture("overflow")) }
            setWidth(sidebar.checkDefaultWidth)
            browserCheckPhase = 7
        case 7:
            guard sidebar.checkInFieldActionIDs.contains(check.fixtureID),
                  sidebar.checkRowActionIDs.isEmpty else { wait("in-field actions"); return }
            check.mark("overflow_restores")
            guard sidebar.checkPerformMenuCommand(check.fixtureID, title: "Unpin") else { wait("unpin command"); return }
            browserCheckPhase = 8
        case 8:
            guard let item = item(), !item.pinned else { wait("unpinned action"); return }
            refreshExtensionActions()
            check.mark("unpin", !sidebar.checkInFieldActionIDs.contains(check.fixtureID)
                       && !sidebar.checkRowActionIDs.contains(check.fixtureID))
            guard sidebar.checkPerformMenuCommand(check.fixtureID, title: "Pin") else { wait("pin command"); return }
            browserCheckPhase = 9
        case 9:
            guard let item = item(), item.pinned,
                  sidebar.checkInFieldActionIDs.contains(check.fixtureID),
                  let button = sidebar.checkActionButton(check.fixtureID) else { wait("repinned action"); return }
            check.mark("repin")
            // M2/S9: the anchor is set before the action runs, and the action's popup opens.
            check.actionAnchor = button.anchorInWindow
            sidebar.checkPerformExtensionAction(check.fixtureID)
            browserCheckPhase = 10
        case 10:
            guard let expected = check.actionAnchor else { wait("action anchor recorded"); return }
            let anchored = lastExtensionAnchor.map {
                abs($0.midX - expected.midX) < 1 && abs($0.midY - expected.midY) < 1
            } ?? false
            if anchored { check.mark("action_anchor") }
            // An action popup is an ExtensionPopup bubble, not a Browser window, so the engine's
            // seam (not the Runtime popups list) is what says it opened.
            let popupState = host.checkExtensionActionPopup()
            let popupShown = popupState["shown"] as? Bool == true
            if popupShown {
                check.mark("action_popup")
                FileHandle.standardError.write(Data("ararat-trace: ext-actions action popup shown class=\(popupState["class"] as? String ?? "-")\n".utf8))
                host.checkDismissExtensionActionPopup()
                guard host.checkExtensionActionPopup()["shown"] as? Bool != true else { wait("action popup closed"); return }
            } else if !popups.isEmpty {
                check.mark("action_popup")
                for popup in popups { popup.host?.close() }
                guard popups.isEmpty else { wait("action popup closed"); return }
            } else if phaseTicks() <= 50 {
                wait("action popup")
                return
            } else {
                // Keep the later phases reachable and name the missing part.
                check.mark("action_anchor", anchored)
                check.mark("action_popup", false)
                FileHandle.standardError.write(Data("ararat-trace: ext-actions action popup missing after \(phaseTicks()) ticks state=\(popupState)\n".utf8))
            }
            // Remove… last: the uninstall sheet is Chrome's browser-modal fallback.
            check.removeStarted = true
            check.removeAttempts = 0
            _ = sidebar.checkPerformMenuCommand(check.fixtureID, title: "Remove…")
            browserCheckPhase = 11
        case 11:
            check.removeAttempts += 1
            if !check.removeResult.isEmpty {
                check.mark("remove_cancel", check.removeResult == "notRemoved")
                browserCheckPhase = 12
                return
            }
            // The dialog is a sheet or a modal child of the host window; closing it is the
            // cancel path, and the engine reports notRemoved afterwards. S9: close only a
            // window that looks like the uninstall dialog.
            let candidates = [window.attachedSheet].compactMap { $0 }
                + (window.childWindows ?? []).filter { $0 !== window && $0.isVisible }
            let sheet = candidates.first { candidate in
                let name = String(describing: type(of: candidate)).lowercased()
                return candidate === window.attachedSheet
                    || name.contains("dialog") || name.contains("uninstall") || name.contains("browser")
                    || candidate.title.lowercased().contains("remove")
            }
            if let sheet {
                FileHandle.standardError.write(Data("ararat-trace: ext-actions remove sheet=\(sheet.title) class=\(type(of: sheet))\n".utf8))
                window.endSheet(sheet)
                sheet.performClose(nil)
            } else if check.removeAttempts > 60 {
                check.mark("remove_cancel", false)
                let result = check.diagnostics(screen: screen)
                finishBrowserCheck(ok: false, values: result)
                return
            }
            wait("uninstall dialog")
        case 12:
            let names = ["Ararat URL field action one", "Ararat URL field action two"]
            let found = names.compactMap { name in extensionItems.first { $0.name == name } }
            guard found.count == 2 else {
                if phaseTicks() > 100 {
                    check.mark("multi_fixtures", false)
                    var values = check.diagnostics(screen: screen)
                    values["error"] = "the 2- and 3-action cases need test_extensions/urlfield-one and urlfield-two loaded with --load-extension"
                    finishBrowserCheck(ok: false, values: values)
                    return
                }
                wait("two action fixtures"); return
            }
            check.secondID = found[0].id
            check.thirdID = found[1].id
            check.mark("multi_fixtures")
            for id in [check.fixtureID, check.secondID, check.thirdID]
            where extensionItems.first(where: { $0.id == id })?.pinned != true {
                _ = adapter?.setExtensionPinned(id, pinned: true)
            }
            refreshExtensionActions()
            browserCheckPhase = 13
        case 13:
            let ids = [check.fixtureID, check.secondID, check.thirdID]
            let all = extensionItems.filter { ids.contains($0.id) }
            guard all.count == 3, all.allSatisfy(\.pinned),
                  sidebar.checkInFieldActionIDs.count == 3 || sidebar.checkRowActionIDs.count == 3 else {
                wait("three pinned actions"); return
            }
            check.mark("pin_three")
            setWidth(240)
            browserCheckPhase = 14
        case 14:
            let ids = [check.fixtureID, check.secondID, check.thirdID]
            guard Set(sidebar.checkInFieldActionIDs) == Set(ids) else {
                if phaseTicks() > 100 {
                    check.mark("fit_three_240", false)
                    setWidth(232)
                    browserCheckPhase = 15
                    return
                }
                wait("three in the field at 240"); return
            }
            check.mark("fit_three_240")
            let buttons = ids.compactMap { sidebar.checkActionButton($0) }
            check.mark("icons16", buttons.count == 3
                       && buttons.allSatisfy { $0.checkIconSize == NSSize(width: 16, height: 16) })
            let xs = sidebar.checkInFieldFrames.values.map(\.minX).sorted()
            check.mark("gaps4", xs.count == 3
                       && abs((xs[1] - xs[0]) - 28) < 0.01 && abs((xs[2] - xs[1]) - 28) < 0.01
                       && abs(sidebar.checkURLFieldCopyFrame.minX - sidebar.checkInFieldActionsFrame.maxX - 4) < 0.01)
            check.viewport240 = sidebar.checkSpaceViewportFrame.maxY
            if screen { check.mark("capture_three_actions", capture("three-actions")) }
            setWidth(232)
            browserCheckPhase = 15
        case 15:
            let ids = [check.fixtureID, check.secondID, check.thirdID]
            guard sidebar.checkInFieldActionIDs.isEmpty, Set(sidebar.checkRowActionIDs) == Set(ids),
                  sidebar.checkActionsRowHeight == 32 else {
                if phaseTicks() > 100 {
                    check.mark("fit_three_232", false)
                    browserCheckPhase = 16
                    return
                }
                wait("three in the row at 232"); return
            }
            check.mark("fit_three_232")
            let tiles = ids.compactMap { sidebar.checkActionButton($0) }
            check.mark("icons16", check.conditions["icons16"] == true
                       && tiles.count == 3 && tiles.allSatisfy { $0.checkIconSize == NSSize(width: 16, height: 16) })
            check.mark("favourite_shift", abs((check.viewport240 - sidebar.checkSpaceViewportFrame.maxY) - 40) < 0.01)
            _ = adapter?.setExtensionPinned(check.thirdID, pinned: false)
            refreshExtensionActions()
            browserCheckPhase = 16
        case 16:
            let two = Set([check.fixtureID, check.secondID])
            guard extensionItems.first(where: { $0.id == check.thirdID })?.pinned == false,
                  Set(sidebar.checkInFieldActionIDs) == two else {
                if phaseTicks() > 100 {
                    check.mark("fit_two_232", false)
                    setWidth(199)
                    browserCheckPhase = 17
                    return
                }
                wait("two in the field at 232"); return
            }
            check.mark("fit_two_232")
            setWidth(199)
            browserCheckPhase = 17
        case 17:
            let two = Set([check.fixtureID, check.secondID])
            guard sidebar.checkInFieldActionIDs.isEmpty, Set(sidebar.checkRowActionIDs) == two else {
                if phaseTicks() > 100 {
                    check.mark("fit_two_199", false)
                    setWidth(164)
                    browserCheckPhase = 18
                    return
                }
                wait("two in the row at 199"); return
            }
            check.mark("fit_two_199")
            setWidth(164)
            browserCheckPhase = 18
        case 18:
            let two = Set([check.fixtureID, check.secondID])
            guard sidebar.checkInFieldActionIDs.isEmpty, Set(sidebar.checkRowActionIDs) == two else {
                if phaseTicks() > 100 {
                    check.mark("fit_two_164", false)
                    browserCheckPhase = 19
                    return
                }
                wait("two in the row at 164"); return
            }
            check.mark("fit_two_164")
            _ = adapter?.setExtensionPinned(check.secondID, pinned: false)
            refreshExtensionActions()
            setWidth(sidebar.checkDefaultWidth)
            browserCheckPhase = 19
        case 19:
            guard extensionItems.first(where: { $0.id == check.secondID })?.pinned == false,
                  sidebar.checkInFieldActionIDs == [check.fixtureID], sidebar.checkRowActionIDs.isEmpty else {
                wait("the original pin restored"); return
            }
            check.mark("multi_restores")
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        default:
            break
        }
    }
}
