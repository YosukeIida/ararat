import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U27h's check: the Little Window opened by the menu command on a real window — the bar's
/// geometry and colours, the profile menu, the space menu and its search, ⌘L's 504 pt command
/// bar, Copy Link's toast, the remembered frame, and Open in (⌘O and the ⌄ menu) landing the
/// page as a Today row with the same live tab and no reload.
@MainActor
final class LittleWindowCheckState {
    static let names = ["seed", "window_created", "bar_geometry", "dark_bar", "profile_chip",
                        "open_disabled", "profile_menu", "space_menu", "space_search",
                        "default_destination", "command_bar_key", "command_bar_width",
                        "command_bar_navigates", "origin_unchanged", "open_enabled", "copy_link", "extensions_button",
                        "frame_saved", "frame_remembered", "open_key", "open_in", "handoff_live",
                        "handoff_no_reload", "window_closed", "menu_destination", "menu_handoff",
                        "profile_switch"]
    static let screens = ["capture_bar", "capture_profile_menu", "capture_space_menu", "capture_command_bar"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var capturing = false
    var waitName = ""
    var waitCount = 0
    var phaseStart = 0
    var lastPhase = -1
    var seedItem = ""
    var originURL = ""
    var originNavigation: UInt = 0
    var pageURL = ""
    static func fixtureURL(port: UInt16) -> String { "http://127.0.0.1:\(port)/search?little-window" }
    var handoffLive = ""
    var handoffNavigation: UInt = 0
    var targetFrame = NSRect(x: 200, y: 150, width: 720, height: 480)
    var savedFrame: LittleWindowFrame?
    var commandBarViaKey = false
    var openViaKey = false
    var details: [String: Any] = [:]

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: little-window \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: @autoclosure () -> String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: little-window wait=\(name) \(value())\n".utf8))
        }
        if waitName != name { waitName = name; waitCount = 0 }
        waitCount += 1
    }

    static func conditionNames(screen: Bool) -> [String] {
        names + (screen ? screens : [])
    }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        var result: [String: Any] = ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                                     "failed_conditions": names.filter { conditions[$0] != true },
                                     "wait": waitName, "images": images, "details": details]
        if screen { result["unverified"] = [
            "The profile switch reopens the page in the chosen profile (the check lists the menu only)",
            "A Little Window with no extensions: the Extensions popover opens empty",
            "The hover and pressed fills (no cursor in the VM)",
        ] }
        return result
    }
}

@MainActor
extension Runtime {
    func littleWindowCheckDiagnostics(screen: Bool) -> [String: Any] {
        (littleWindowCheck ?? LittleWindowCheckState()).diagnostics(screen: screen)
    }

    func littleWindowCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if littleWindowCheck == nil { littleWindowCheck = LittleWindowCheckState() }
        guard let check = littleWindowCheck, !check.capturing else { return }
        let window = host.window()
        func wait(_ name: String) {
            check.wait(name, "phase=\(browserCheckPhase) key=\(window.isKeyWindow) little=\(littleWindows.count) shown=\(snapshot.shownSpaceId ?? "nil") selected=\(snapshot.selectedId ?? "nil") active=\(host.activeItemId() ?? "nil")")
        }
        func capture(_ target: NSWindow?, _ name: String) -> Bool {
            guard screen else { return true }
            guard let target else { return false }
            check.capturing = true
            defer { check.capturing = false }
            guard let path = promptScreenScreenshot(target, name: "little-window-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        if check.lastPhase != browserCheckPhase {
            check.lastPhase = browserCheckPhase
            check.phaseStart = browserCheckAttempts
        }
        func phaseTicks() -> Int { max(0, browserCheckAttempts - check.phaseStart) }
        func controller() -> LittleWindowController? { littleWindows.first }
        func popupWindow() -> NSWindow? { controller()?.window }
        func popupTab() -> (any ARTabAPI)? {
            (controller()?.popup.host?.tabs() as? [any ARTabAPI])?.first
        }
        func row(_ id: String) -> Row? {
            snapshot.spaces.flatMap { $0.today + $0.pinned + $0.favorites }.first { $0.id == id }
        }
        func finish() {
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        func key(_ code: UInt16, chars: String, flags: NSEvent.ModifierFlags) {
            guard let window = popupWindow(),
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil,
                                               characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: code) else { return }
            NSApp.sendEvent(event)
        }

        switch browserCheckPhase {
        case 0:
            guard let port = promptFixturePort else { wait("fixture server"); return }
            check.pageURL = LittleWindowCheckState.fixtureURL(port: port)
            guard let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first,
                  let url = row.url, url.hasPrefix("data:") else {
                if phaseTicks() > 200 { check.mark("seed", false); finish(); return }
                wait("seed row"); return
            }
            if host.activeItemId() != row.id || snapshot.selectedId != row.id {
                if check.seedItem != row.id {
                    check.seedItem = row.id
                    adapter?.select(id: row.id, url: url)
                }
                wait("seed selection"); return
            }
            guard let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == row.id }),
                  !tab.isLoading, tab.navigationCount > 0, window.isVisible, window.isKeyWindow else {
                if phaseTicks() > 200 { check.mark("seed", false); finish(); return }
                wait("seed page"); return
            }
            check.seedItem = row.id
            check.originURL = tab.url
            check.originNavigation = tab.navigationCount
            check.mark("seed")
            // The menu command, the same path the File > New Little Window item runs.
            openLittleWindow()
            browserCheckPhase = 1
        case 1:
            if !screen, let controller = controller(), controller.popup.host?.hasBrowser() == true,
               let popup = popupWindow(), !popup.isVisible {
                popup.makeKeyAndOrderFront(nil)
            }
            guard let controller = controller(), let popup = popupWindow(),
                  controller.popup.host?.hasBrowser() == true, popup.isVisible, popup.isKeyWindow,
                  controller.model.destination != nil,
                  let tab = popupTab(), tab.url == "about:blank", !tab.isLoading else {
                if phaseTicks() > 300 { check.mark("window_created", false); finish(); return }
                check.details["window_wait"] = ["browser": controller()?.popup.host?.hasBrowser() == true,
                    "visible": popupWindow()?.isVisible == true, "key": popupWindow()?.isKeyWindow == true,
                    "destination": controller()?.model.destination?.id ?? "nil",
                    "url": popupTab()?.url ?? "nil", "loading": popupTab()?.isLoading ?? false]
                wait("little window"); return
            }
            let bar = controller.bar
            controller.popup.rootView.layoutSubtreeIfNeeded()
            let content = popup.contentView?.bounds ?? .zero
            let barFrame = bar.convert(bar.bounds, to: popup.contentView)
            let cardFrame = controller.popup.card.convert(controller.popup.card.bounds, to: popup.contentView)
            check.details["bar"] = ["height": barFrame.height, "width": barFrame.width, "content": content.width]
            check.details["card"] = ["minY": cardFrame.minY, "maxY": cardFrame.maxY, "barMinY": barFrame.minY]
            check.mark("window_created")
            check.mark("bar_geometry", abs(barFrame.height - LittleWindowMetrics.barHeight) <= 0.5
                       && abs(barFrame.width - content.width) <= 1
                       && abs(barFrame.maxY - content.maxY) <= 1
                       && abs(cardFrame.maxY - barFrame.minY) <= 1)
            let barColor = bar.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
            let radius = controller.popup.rootView.layer?.cornerRadius ?? 0
            check.details["colour"] = barColor.map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent)" } ?? "nil"
            check.details["radius"] = radius
            check.mark("dark_bar", barColor.map { abs($0.redComponent - 0x23 / 255) < 0.01 && abs($0.greenComponent - 0x23 / 255) < 0.01
                && abs($0.blueComponent - 0x27 / 255) < 0.01 } == true && abs(radius - LittleWindowMetrics.contentRadius) <= 0.5)
            check.mark("profile_chip", bar.checkProfileTitle == "Default" && controller.model.profiles.count >= 2)
            check.mark("open_disabled", !bar.checkOpenEnabled && bar.checkOpenTitle == "Open in Work")
            check.mark("default_destination", controller.model.destination?.title == "Work")
            check.mark("capture_bar", capture(popup, "bar"))
            bar.checkClickProfile()
            browserCheckPhase = 2
        case 2:
            guard let controller = controller(), let panel = controller.checkProfilePanel else {
                if phaseTicks() > 60 { check.mark("profile_menu", false); browserCheckPhase = 3; return }
                wait("profile menu"); return
            }
            let titles = panel.checkRowTitles.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "✓ ")) }
            check.details["profile_menu"] = titles
            check.mark("profile_menu", titles.contains("Default") && titles.contains("Profile 1") && titles.count >= 2)
            check.mark("capture_profile_menu", capture(panel.window, "profile-menu"))
            controller.closeMenus()
            browserCheckPhase = 3
        case 3:
            guard let controller = controller(), controller.checkProfilePanel == nil else {
                wait("profile menu closed"); return
            }
            controller.bar.checkClickChevron()
            browserCheckPhase = 4
        case 4:
            guard let controller = controller(), let panel = controller.checkSpacePanel else {
                if phaseTicks() > 60 { check.mark("space_menu", false); browserCheckPhase = 5; return }
                wait("space menu"); return
            }
            let titles = panel.checkRowTitles.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "✓ ")) }
            check.details["space_menu"] = titles
            check.mark("space_menu", Set(["Work", "Personal", "Reading"]).isSubset(of: Set(titles))
                       && !titles.contains(where: { $0.localizedCaseInsensitiveContains("most recent") }))
            check.mark("capture_space_menu", capture(panel.window, "space-menu"))
            panel.checkTypeSearch("per")
            browserCheckPhase = 5
        case 5:
            guard let controller = controller(), let panel = controller.checkSpacePanel else {
                if phaseTicks() > 60 { check.mark("space_search", false); browserCheckPhase = 6; return }
                wait("space search"); return
            }
            let titles = panel.checkRowTitles.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "✓ ")) }
            check.details["space_search"] = titles
            check.mark("space_search", titles == ["Personal"])
            controller.closeMenus()
            browserCheckPhase = 6
        case 6:
            guard controller() != nil else { wait("little window"); return }
            // ⌘L's real key path: the local monitor opens the bar at 504 pt.
            check.commandBarViaKey = true
            key(37, chars: "l", flags: .command)
            browserCheckPhase = 7
        case 7:
            if let controller = controller(), controller.checkCommandBarOpen, let width = controller.checkCommandBarWidth {
                let panelWindow = controller.checkCommandBar?.panel
                check.details["command_bar"] = ["width": width, "parent": panelWindow?.parent.map { $0 === controller.window } ?? false,
                                                "key": check.commandBarViaKey]
                check.mark("command_bar_key", check.commandBarViaKey)
                check.mark("command_bar_width", abs(width - LittleWindowMetrics.commandBarWidth) <= 0.5)
                check.mark("capture_command_bar", capture(panelWindow, "command-bar"))
                controller.checkTypeCommandBar(check.pageURL)
                controller.checkCommitCommandBar()
                browserCheckPhase = 8
                return
            }
            // The posted event may not reach a local monitor in the VM; the same action runs
            // directly and the key path stays a named failure.
            if phaseTicks() > 40, let controller = controller(), !controller.checkCommandBarOpen {
                check.commandBarViaKey = false
                controller.openCommandBar()
                return
            }
            wait("command bar")
        case 8:
            guard let tab = popupTab(), !tab.isLoading, tab.url == check.pageURL, tab.navigationCount > 0 else {
                if phaseTicks() > 200 { check.mark("command_bar_navigates", false); finish(); return }
                wait("command bar navigation"); return
            }
            check.mark("command_bar_navigates")
            let originTab = (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == check.seedItem }
            check.mark("origin_unchanged", originTab?.url == check.originURL && originTab?.navigationCount == check.originNavigation)
            guard let controller = controller() else { wait("little window"); return }
            controller.update()
            check.mark("open_enabled", controller.bar.checkOpenEnabled)
            controller.bar.checkClickCopy()
            check.mark("copy_link", NSPasteboard.general.string(forType: .string) == check.pageURL
                       && controller.checkToastVisible && controller.checkToastMessage == "Link copied")
            controller.bar.checkClickExtensions()
            browserCheckPhase = 9
        case 9:
            guard let controller = controller(), let panel = controller.checkExtensionPanel else {
                if phaseTicks() > 60 { check.mark("extensions_button", false); browserCheckPhase = 10; return }
                wait("extensions popover"); return
            }
            check.mark("extensions_button")
            check.details["extension_items"] = panel.checkItems
            controller.closeMenus()
            // The frame survives a reopen: set one, close, reopen from the menu command.
            if let window = popupWindow() {
                window.setFrame(check.targetFrame, display: true)
                controller.saveFrame()
            }
            browserCheckPhase = 10
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.littleWindows.first?.close()
            }
        case 10:
            guard littleWindows.isEmpty else { wait("little window closed"); return }
            guard let adapter = workspace else { wait("adapter"); return }
            adapter.littleWindowFrame { [weak self] result in
                guard let self, let check = self.littleWindowCheck else { return }
                check.savedFrame = (try? result.get()) ?? nil
                let saved = check.savedFrame
                var details: [String: Any] = [:]
                if let saved { details = ["x": saved.x, "y": saved.y, "width": saved.width, "height": saved.height] }
                check.details["saved_frame"] = details
                let matches = saved.map { abs($0.width - check.targetFrame.width) <= 1 && abs($0.height - check.targetFrame.height) <= 1 } ?? false
                check.mark("frame_saved", matches)
                self.openLittleWindow()
                self.browserCheckPhase = 11
            }
        case 11:
            guard let controller = controller(), let window = popupWindow(), controller.popup.host?.hasBrowser() == true else {
                if phaseTicks() > 300 { check.mark("frame_remembered", false); finish(); return }
                wait("reopened little window"); return
            }
            let saved = check.savedFrame
            check.details["reopened_frame"] = ["x": window.frame.minX, "y": window.frame.minY,
                                               "width": window.frame.width, "height": window.frame.height]
            check.mark("frame_remembered", saved.map { frame in
                abs(window.frame.width - frame.width) <= 1 && abs(window.frame.height - frame.height) <= 1
            } == true)
            // Navigate the reopened window to the check page through the command bar.
            controller.openCommandBar()
            browserCheckPhase = 12
        case 12:
            guard let controller = controller(), controller.checkCommandBarOpen else { wait("command bar"); return }
            controller.checkTypeCommandBar(check.pageURL)
            controller.checkCommitCommandBar()
            browserCheckPhase = 13
        case 13:
            guard let tab = popupTab(), !tab.isLoading, tab.url == check.pageURL else {
                if phaseTicks() > 200 { check.mark("open_in", false); finish(); return }
                wait("reopened page"); return
            }
            check.handoffLive = tab.liveId
            check.handoffNavigation = tab.navigationCount
            // ⌘O's real key path.
            check.openViaKey = true
            key(31, chars: "o", flags: .command)
            browserCheckPhase = 14
        case 14:
            if let controller = controller(), !littleWindows.isEmpty, phaseTicks() > 40 {
                // The posted event may not reach a local monitor in the VM; the same action runs
                // directly and the key path stays a named failure.
                check.openViaKey = false
                controller.performOpenIn()
            }
            guard littleWindows.isEmpty, let controller = littleWindowCheckController else {
                if phaseTicks() > 300 { check.mark("open_in", false); finish(); return }
                wait("open in"); return
            }
            check.mark("open_key", check.openViaKey)
            let openedIn = controller.checkOpenedIn
            var todayRow: Row?
            if let openedIn { todayRow = row(openedIn.item) }
            let tab = (host.tabs() as? [any ARTabAPI])?.first { $0.liveId == check.handoffLive }
            let tabsWithLive = (host.tabs() as? [any ARTabAPI])?.filter { $0.liveId == check.handoffLive } ?? []
            var mapped: String?
            if let openedIn, let adapter {
                mapped = adapter.session.queue.sync { adapter.session.store?.liveTab(item: openedIn.item) }
            }
            var details: [String: Any] = [:]
            details["space"] = openedIn?.space ?? ""
            details["item"] = openedIn?.item ?? ""
            details["row"] = todayRow?.url ?? ""
            details["same_live"] = tab != nil
            details["tabs_with_live"] = tabsWithLive.count
            details["mapped_live"] = mapped ?? "nil"
            details["navigation"] = tab.map { Int($0.navigationCount) } ?? -1
            details["shown"] = snapshot.shownSpaceId ?? ""
            check.details["open_in"] = details
            check.mark("open_in", openedIn != nil && todayRow?.url == check.pageURL && snapshot.shownSpaceId == openedIn?.space)
            // L2: the live tab is the only tab with that id, and the core maps the row to it.
            check.mark("handoff_live", tab != nil && tabsWithLive.count == 1
                       && mapped == check.handoffLive)
            // A moved tab is a new ARTab wrapper in the destination, so its own navigation
            // count starts at zero: any count there would be a navigation the app made (the
            // reload this check rules out). The live id proves it is the same contents.
            check.mark("handoff_no_reload", tab != nil && tab?.navigationCount == 0
                       && check.handoffNavigation > 0)
            check.mark("window_closed", littleWindows.isEmpty)
            browserCheckPhase = 15
        case 15:
            // The ⌄ menu picks a destination for this page only: a third Little Window lands in
            // Reading through the menu's search.
            guard let row = snapshot.spaces.flatMap({ $0.today }).first(where: { $0.url == check.pageURL }),
                  let url = row.url else { wait("first handoff row"); return }
            openLittleWindow(url: url)
            browserCheckPhase = 16
        case 16:
            guard let controller = controller(), let tab = popupTab(), !tab.isLoading, tab.url == check.pageURL else {
                if phaseTicks() > 300 { check.mark("menu_handoff", false); finish(); return }
                wait("third little window"); return
            }
            controller.bar.checkClickChevron()
            browserCheckPhase = 17
        case 17:
            guard let controller = controller(), let panel = controller.checkSpacePanel else {
                if phaseTicks() > 60 { check.mark("menu_destination", false); finish(); return }
                wait("space menu"); return
            }
            panel.checkTypeSearch("read")
            browserCheckPhase = 18
        case 18:
            guard let controller = controller(), let panel = controller.checkSpacePanel else { wait("space search"); return }
            let titles = panel.checkRowTitles.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "✓ ")) }
            check.mark("menu_destination", titles == ["Reading"])
            check.handoffLive = popupTab()?.liveId ?? ""
            check.handoffNavigation = popupTab()?.navigationCount ?? 0
            panel.checkClickRow(controller.model.filteredSpaces.first(where: { $0.title == "Reading" })?.id ?? "")
            browserCheckPhase = 19
        case 19:
            guard littleWindows.isEmpty, let opened = littleWindowCheckController?.checkOpenedIn else {
                if phaseTicks() > 300 { check.mark("menu_handoff", false); finish(); return }
                wait("menu handoff"); return
            }
            let reading = snapshot.spaces.first { $0.title == "Reading" }
            let tab = (host.tabs() as? [any ARTabAPI])?.first { $0.liveId == check.handoffLive }
            let tabsWithLive = (host.tabs() as? [any ARTabAPI])?.filter { $0.liveId == check.handoffLive } ?? []
            var mapped: String?
            if let adapter {
                mapped = adapter.session.queue.sync { adapter.session.store?.liveTab(item: opened.item) }
            }
            var details: [String: Any] = [:]
            details["space"] = opened.space
            details["reading"] = reading?.id ?? ""
            details["row"] = row(opened.item)?.url ?? ""
            details["live"] = tab != nil
            details["tabs_with_live"] = tabsWithLive.count
            details["mapped_live"] = mapped ?? "nil"
            details["navigation"] = tab.map { Int($0.navigationCount) } ?? -1
            check.details["menu_handoff"] = details
            check.mark("menu_handoff", opened.space == reading?.id && row(opened.item)?.url == check.pageURL
                       && tab != nil && tab?.navigationCount == 0
                       && tabsWithLive.count == 1 && mapped == check.handoffLive)
            // The profile switch: the Little Window reopens in the chosen profile and the
            // origin window keeps its own profile (H1).
            openLittleWindow(url: check.pageURL)
            browserCheckPhase = 20
        case 20:
            guard let controller = controller(), let tab = popupTab(), !tab.isLoading,
                  tab.url == check.pageURL else {
                if phaseTicks() > 300 { check.mark("profile_switch", false); finish(); return }
                wait("fourth little window"); return
            }
            controller.bar.checkClickProfile()
            browserCheckPhase = 21
        case 21:
            guard let controller = controller(), let panel = controller.checkProfilePanel else {
                if phaseTicks() > 60 { check.mark("profile_switch", false); finish(); return }
                wait("profile menu"); return
            }
            let originProfile = host.profileDirectory()
            let before = littleWindows.count
            panel.checkClickRow("Profile 1")
            check.details["profile_switch"] = ["origin_before": originProfile, "windows_before": before]
            browserCheckPhase = 22
        case 22:
            // The old window stays until the new one exists; then only the Profile 1 one is left
            // and the origin window still shows Default.
            guard let controller = controller(), controller.profileName == "Profile 1",
                  let tab = popupTab(), !tab.isLoading, tab.url == check.pageURL,
                  littleWindows.count == 1 else {
                if phaseTicks() > 400 {
                    let names = littleWindows.map(\.profileName)
                    check.details["profile_switch_after"] = ["windows": names, "origin": host.profileDirectory()]
                    check.mark("profile_switch", false)
                    finish()
                    return
                }
                wait("profile switch"); return
            }
            var details = check.details["profile_switch"] as? [String: Any] ?? [:]
            details["origin_after"] = host.profileDirectory()
            details["new_profile"] = controller.profileName
            details["windows_after"] = littleWindows.count
            details["url"] = tab.url
            check.details["profile_switch"] = details
            check.mark("profile_switch", host.profileDirectory() == "Default"
                       && controller.profileName == "Profile 1" && tab.url == check.pageURL)
            finish()
        default:
            break
        }
    }

    /// The last Little Window the check opened (the list is empty once it closes).
    var littleWindowCheckController: LittleWindowController? { lastLittleWindow }
}
