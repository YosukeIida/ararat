import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U25a pass 2's check: the URL field's content rule on a real window. A normal page shows the
/// host, a file URL its file name, `data:` just the scheme, `about:blank` and the new-tab page
/// the placeholder with both buttons, another internal page the gear with the full URL, and a
/// failed navigation the failed URL's host. Copy Link copies the live URL, shows the toast and
/// its tick. The no-tab state (placeholder, no buttons) and the long-host fade are unit tests:
/// they need a rowless window and a text width that the VM's screen scale does not change.
@MainActor
final class URLFieldCheckState {
    static let names = ["fixture", "seed", "host", "file", "data", "about_blank", "new_tab",
                        "internal", "failed", "copy_states", "placeholder_buttons"]
    static let screens = ["capture_host", "capture_placeholder", "capture_internal"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var capturing = false
    var waitName = ""
    var waitCount = 0
    var item = ""
    var live = ""
    var port: UInt16 = 0
    var fileURL = ""
    var phaseStart = 0
    var lastPhase = -1

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: urlfield \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: @autoclosure () -> String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: urlfield wait=\(name) \(value())\n".utf8))
        }
        if waitName != name { waitName = name; waitCount = 0 }
        waitCount += 1
    }

    static func conditionNames(screen: Bool) -> [String] {
        names + (screen ? screens : [])
    }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                "failed_conditions": names.filter { conditions[$0] != true },
                "wait": waitName, "images": images, "item": item, "live": live,
                "unverified": ["The no-tab placeholder and the hidden buttons (unit tests)",
                               "The long-host leading fade (unit tests)",
                               "The button hover and pressed fills (unit tests; no cursor in the VM)"]]
    }
}

@MainActor
extension Runtime {
    func urlFieldCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if urlFieldCheck == nil { urlFieldCheck = URLFieldCheckState() }
        guard let check = urlFieldCheck, !check.capturing, let sidebar, let container else { return }
        let window = host.window()
        func wait(_ name: String) {
            check.wait(name, "phase=\(browserCheckPhase) key=\(window.isKeyWindow) selected=\(snapshot.selectedId ?? "nil") active=\(host.activeItemId() ?? "nil") url=\((host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == snapshot.selectedId })?.url ?? "nil") host=\(sidebar.urlHostForCheck) placeholder=\(sidebar.urlFieldShowsPlaceholder) gear=\(sidebar.urlFieldShowsGear) copy=\(sidebar.urlFieldCopyLinkVisible)/\(sidebar.urlFieldCopyLinkEnabled) site=\(sidebar.urlFieldSiteControlsVisible)")
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            check.capturing = true
            defer { check.capturing = false }
            guard let path = promptScreenScreenshot(window, name: "urlfield-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        if check.lastPhase != browserCheckPhase {
            check.lastPhase = browserCheckPhase
            check.phaseStart = browserCheckAttempts
        }
        func phaseTicks() -> Int { max(0, browserCheckAttempts - check.phaseStart) }
        func tab() -> (any ARTabAPI)? {
            (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == snapshot.selectedId }
        }
        func navigate(_ url: String, next: Int) {
            host.checkNavigate(url, disposition: "current")
            browserCheckPhase = next
        }
        func active() -> Bool {
            guard let id = snapshot.selectedId else { return false }
            return host.activeItemId() == id
        }

        switch browserCheckPhase {
        case 0:
            guard let ports = promptFixturePort, ports != 0,
                  let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first,
                  row.url != nil, host.hasBrowser(), window.isVisible, window.isKeyWindow else {
                wait("fixture and key window"); return
            }
            check.port = ports
            check.item = row.id
            browserCheckSeedID = row.id
            selectCheckSeed(row)
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ararat-urlfield-check.md")
            try? "URL field check".write(to: file, atomically: true, encoding: .utf8)
            check.fileURL = file.absoluteString
            check.mark("fixture")
            browserCheckPhase = 1
        case 1:
            guard let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first(where: { $0.id == check.item }),
                  snapshot.selectedId == row.id, active(),
                  let tab = tab(), !tab.isLoading, tab.navigationCount > 0 else { wait("active seed tab"); return }
            check.live = tab.liveId
            check.mark("seed")
            navigate("http://127.0.0.1:\(check.port)/keyboard", next: 2)
        case 2:
            guard let tab = tab(), !tab.isLoading, tab.url.hasPrefix("http://127.0.0.1:\(check.port)/keyboard"),
                  !sidebar.urlFieldShowsPlaceholder, !sidebar.urlFieldShowsGear else {
                if phaseTicks() > 100 { check.mark("host", false); asyncFieldTrace(sidebar); browserCheckPhase = 3; return }
                wait("host page"); return
            }
            check.mark("host", sidebar.urlHostForCheck == "127.0.0.1"
                       && sidebar.urlFieldCopyLinkVisible && sidebar.urlFieldSiteControlsVisible
                       && sidebar.urlFieldCopyLinkEnabled)
            if screen { check.mark("capture_host", capture("host")) }
            navigate(check.fileURL, next: 3)
        case 3:
            guard let tab = tab(), !tab.isLoading, tab.url == check.fileURL else {
                if phaseTicks() > 100 { check.mark("file", false); browserCheckPhase = 4; return }
                wait("file page"); return
            }
            check.mark("file", sidebar.urlHostForCheck == "ararat-urlfield-check.md"
                       && !sidebar.urlFieldShowsPlaceholder && !sidebar.urlFieldShowsGear)
            navigate("data:text/html,<title>urlfield</title>", next: 4)
        case 4:
            guard let tab = tab(), !tab.isLoading, tab.url.hasPrefix("data:") else {
                if phaseTicks() > 100 { check.mark("data", false); browserCheckPhase = 5; return }
                wait("data page"); return
            }
            check.mark("data", sidebar.urlHostForCheck == "data:" && !sidebar.urlFieldShowsPlaceholder
                       && !sidebar.urlFieldShowsGear)
            navigate("about:blank", next: 5)
        case 5:
            guard let tab = tab(), !tab.isLoading, tab.url == "about:blank" else {
                if phaseTicks() > 100 { check.mark("about_blank", false); browserCheckPhase = 6; return }
                wait("about:blank"); return
            }
            check.mark("about_blank", sidebar.urlFieldShowsPlaceholder
                       && sidebar.urlFieldCopyLinkVisible && sidebar.urlFieldSiteControlsVisible
                       && sidebar.urlFieldCopyLinkEnabled)
            check.mark("placeholder_buttons", sidebar.urlFieldShowsPlaceholder
                       && sidebar.urlFieldCopyLinkVisible && sidebar.urlFieldSiteControlsVisible)
            if screen { check.mark("capture_placeholder", capture("placeholder")) }
            navigate("chrome://newtab/", next: 6)
        case 6:
            guard let tab = tab(), !tab.isLoading, tab.url.hasPrefix("chrome://newtab") else {
                if phaseTicks() > 100 { check.mark("new_tab", false); browserCheckPhase = 7; return }
                wait("new tab page"); return
            }
            check.mark("new_tab", sidebar.urlFieldShowsPlaceholder && sidebar.urlFieldCopyLinkVisible
                       && sidebar.urlFieldSiteControlsVisible)
            navigate("chrome://settings/", next: 7)
        case 7:
            guard let tab = tab(), !tab.isLoading, tab.url.hasPrefix("chrome://settings") else {
                if phaseTicks() > 100 { check.mark("internal", false); browserCheckPhase = 8; return }
                wait("internal page"); return
            }
            check.mark("internal", sidebar.urlFieldShowsGear && !sidebar.urlFieldShowsPlaceholder
                       && sidebar.urlHostForCheck.hasPrefix("chrome://settings"))
            if screen { check.mark("capture_internal", capture("internal")) }
            // Port 1 is closed: the navigation fails and the field must show the failed URL's
            // host, not the error page's internal name.
            navigate("http://localhost:1/urlfield", next: 8)
        case 8:
            guard let tab = tab(), !tab.isLoading, tab.url.hasPrefix("http://localhost:1/") else {
                if phaseTicks() > 150 { check.mark("failed", false); browserCheckPhase = 9; return }
                wait("failed navigation"); return
            }
            check.mark("failed", sidebar.urlHostForCheck == "localhost" && !sidebar.urlFieldShowsPlaceholder
                       && !sidebar.urlFieldShowsGear)
            let url = tab.url
            sidebar.copySelectedLinkForCommand()
            let copied = NSPasteboard.general.string(forType: .string) == url
            check.mark("copy_states", copied && sidebar.urlFieldCopyIsTick
                       && container.checkToastState.visible)
            let failed = check.diagnostics(screen: screen)["failed_conditions"] as? [String] ?? ["invalid"]
            finishBrowserCheck(ok: failed.isEmpty, values: check.diagnostics(screen: screen))
        default:
            break
        }
    }

    private func asyncFieldTrace(_ sidebar: SidebarView) {
        FileHandle.standardError.write(Data("ararat-trace: urlfield host-timeout host=\(sidebar.urlHostForCheck) placeholder=\(sidebar.urlFieldShowsPlaceholder) gear=\(sidebar.urlFieldShowsGear)\n".utf8))
    }
}
