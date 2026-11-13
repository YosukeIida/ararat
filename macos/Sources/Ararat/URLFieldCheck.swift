import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U25a pass 2's check: the URL field's content rule on a real window. A normal page shows the
/// host, a file URL its file name, `data:` just the scheme, `about:blank` and the new-tab page
/// the placeholder with both buttons, another internal page the gear with the full URL, and a
/// failed navigation the failed URL's host. A long host keeps its end (the label's trailing edge
/// at the text area's, the start off the leading edge under the fade). Copy Link's real click
/// copies the live URL, shows the toast and its tick, and leaves the first responder alone. The
/// no-tab state and the file/internal tail clipping are unit tests: they need a rowless window
/// and text metrics the VM's screen scale does not change.
@MainActor
final class URLFieldCheckState {
    static let names = ["fixture", "seed", "host", "file", "data", "about_blank", "new_tab",
                        "internal", "failed", "long_host", "long_host_narrow", "copy_states",
                        "copy_focus", "placeholder_buttons"]
    static let screens = ["capture_host", "capture_placeholder", "capture_internal", "capture_long_host",
                          "capture_long_host_narrow"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var capturing = false
    var waitName = ""
    var waitCount = 0
    var item = ""
    var live = ""
    var port: UInt16 = 0
    var fileURL = ""
    var longHost = ""
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
                               "The file and internal tail clipping (unit tests)",
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
        func onSeed() -> Bool {
            guard let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first(where: { $0.id == check.item }) else { return false }
            return snapshot.selectedId == row.id && host.activeItemId() == row.id
        }
        func loaded(_ prefix: String) -> Bool {
            guard let tab = tab(), !tab.isLoading else { return false }
            return tab.url.hasPrefix(prefix)
        }
        func navigate(_ url: String, next: Int) {
            host.checkNavigate(url, disposition: "current")
            browserCheckPhase = next
        }
        func finish() {
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        func setWidth(_ width: CGFloat) {
            container.resizeHandle.sidebarWidth = width
            container.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
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
            check.longHost = "averyveryveryverylongsubdomainname.docs.example.invalid"
            check.mark("fixture")
            browserCheckPhase = 1
        case 1:
            guard onSeed(), loaded("data:"), tab()?.navigationCount ?? 0 > 0 else {
                if phaseTicks() > 100 { check.mark("seed", false); finish(); return }
                wait("active seed tab"); return
            }
            check.live = tab()?.liveId ?? ""
            check.mark("seed")
            navigate("http://127.0.0.1:\(check.port)/keyboard", next: 2)
        case 2:
            guard onSeed(), loaded("http://127.0.0.1:\(check.port)/keyboard"),
                  sidebar.urlHostForCheck == "127.0.0.1", !sidebar.urlFieldShowsPlaceholder,
                  !sidebar.urlFieldShowsGear else {
                if phaseTicks() > 100 { check.mark("host", false); navigate(check.fileURL, next: 3); return }
                wait("host page"); return
            }
            check.mark("host", sidebar.urlFieldCopyLinkVisible && sidebar.urlFieldSiteControlsVisible
                       && sidebar.urlFieldCopyLinkEnabled)
            if screen { check.mark("capture_host", capture("host")) }
            navigate(check.fileURL, next: 3)
        case 3:
            guard onSeed(), loaded("file://"), tab()?.url == check.fileURL,
                  sidebar.urlHostForCheck == "ararat-urlfield-check.md",
                  !sidebar.urlFieldShowsPlaceholder, !sidebar.urlFieldShowsGear else {
                if phaseTicks() > 100 { check.mark("file", false); navigate("data:text/html,<title>urlfield</title>", next: 4); return }
                wait("file page"); return
            }
            check.mark("file")
            navigate("data:text/html,<title>urlfield</title>", next: 4)
        case 4:
            guard onSeed(), loaded("data:"), sidebar.urlHostForCheck == "data:",
                  !sidebar.urlFieldShowsPlaceholder, !sidebar.urlFieldShowsGear else {
                if phaseTicks() > 100 { check.mark("data", false); navigate("about:blank", next: 5); return }
                wait("data page"); return
            }
            check.mark("data", sidebar.checkURLFieldAccessibilityValue == "data:")
            navigate("about:blank", next: 5)
        case 5:
            guard onSeed(), loaded("about:blank"), tab()?.url == "about:blank",
                  sidebar.urlFieldShowsPlaceholder, sidebar.checkURLFieldAccessibilityValue == URLFieldContent.placeholderText else {
                if phaseTicks() > 100 { check.mark("about_blank", false); navigate("chrome://newtab/", next: 6); return }
                wait("about:blank"); return
            }
            check.mark("about_blank", sidebar.urlFieldCopyLinkVisible && sidebar.urlFieldSiteControlsVisible
                       && sidebar.urlFieldCopyLinkEnabled)
            check.mark("placeholder_buttons", sidebar.urlFieldShowsPlaceholder
                       && sidebar.urlFieldCopyLinkVisible && sidebar.urlFieldSiteControlsVisible)
            if screen { check.mark("capture_placeholder", capture("placeholder")) }
            navigate("chrome://newtab/", next: 6)
        case 6:
            guard onSeed(), loaded("chrome://newtab"), sidebar.urlFieldShowsPlaceholder,
                  sidebar.urlFieldCopyLinkVisible && sidebar.urlFieldSiteControlsVisible else {
                if phaseTicks() > 100 { check.mark("new_tab", false); navigate("chrome://settings/", next: 7); return }
                wait("new tab page"); return
            }
            check.mark("new_tab")
            navigate("chrome://settings/", next: 7)
        case 7:
            guard onSeed(), loaded("chrome://settings"), sidebar.urlFieldShowsGear,
                  !sidebar.urlFieldShowsPlaceholder, sidebar.urlHostForCheck.hasPrefix("chrome://settings"),
                  sidebar.checkURLFieldAccessibilityValue == sidebar.urlHostForCheck else {
                if phaseTicks() > 100 { check.mark("internal", false); navigate("http://localhost:1/urlfield", next: 8); return }
                wait("internal page"); return
            }
            check.mark("internal")
            if screen { check.mark("capture_internal", capture("internal")) }
            // Port 1 is restricted, so Chromium refuses the navigation with ERR_UNSAFE_PORT and
            // commits an error page; the field must still show the failed URL's host.
            navigate("http://localhost:1/urlfield", next: 8)
        case 8:
            guard onSeed(), loaded("http://localhost:1/"), !sidebar.urlFieldShowsPlaceholder,
                  !sidebar.urlFieldShowsGear, sidebar.urlHostForCheck == "localhost" else {
                if phaseTicks() > 150 {
                    check.mark("failed", false)
                    let result = check.diagnostics(screen: screen)
                    finishBrowserCheck(ok: false, values: result)
                    return
                }
                wait("failed navigation"); return
            }
            check.mark("failed")
            navigate("http://\(check.longHost)/urlfield", next: 9)
        case 9:
            guard onSeed(), loaded("http://\(check.longHost)/"), !sidebar.urlFieldShowsPlaceholder,
                  !sidebar.urlFieldShowsGear, sidebar.urlHostForCheck == check.longHost else {
                if phaseTicks() > 150 { check.mark("long_host", false); setWidth(164); browserCheckPhase = 10; return }
                wait("long host page"); return
            }
            sidebar.layoutSubtreeIfNeeded()
            let label = sidebar.checkHostLabelFrame
            let clip = sidebar.checkHostClipFrame
            check.mark("long_host", label.minX < clip.minX && abs(label.maxX - clip.maxX) <= 0.5
                       && sidebar.urlFieldHostHasLeadingFade)
            if screen { check.mark("capture_long_host", capture("long-host")) }
            setWidth(164)
            browserCheckPhase = 10
        case 10:
            guard onSeed(), sidebar.urlHostForCheck == check.longHost,
                  sidebar.checkHostLabelFrame.minX < sidebar.checkHostClipFrame.minX,
                  abs(sidebar.checkHostLabelFrame.maxX - sidebar.checkHostClipFrame.maxX) <= 0.5,
                  sidebar.urlFieldHostHasLeadingFade else {
                if phaseTicks() > 100 {
                    check.mark("long_host_narrow", false)
                    setWidth(sidebar.checkDefaultWidth)
                    browserCheckPhase = 11
                    return
                }
                wait("long host at 164"); return
            }
            check.mark("long_host_narrow")
            if screen { check.mark("capture_long_host_narrow", capture("long-host-narrow")) }
            setWidth(sidebar.checkDefaultWidth)
            browserCheckPhase = 11
        case 11:
            guard onSeed(), let tab = tab(), !tab.isLoading,
                  sidebar.urlFieldCopyLinkVisible, sidebar.urlFieldCopyLinkEnabled else {
                if phaseTicks() > 100 { check.mark("copy_states", false); check.mark("copy_focus", false); finish(); return }
                wait("copy link ready"); return
            }
            let url = tab.url
            let before = window.firstResponder
            let frame = sidebar.checkCopyButtonWindowFrame
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.midX, y: frame.midY),
                                   modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
            }
            if let down = mouse(.leftMouseDown), let up = mouse(.leftMouseUp) {
                NSApp.postEvent(up, atStart: false)
                NSApp.sendEvent(down)
            }
            check.mark("copy_states", NSPasteboard.general.string(forType: .string) == url
                       && container.checkToastState.visible && sidebar.urlFieldCopyIsTick)
            check.mark("copy_focus", window.firstResponder === before
                       && !sidebar.urlFieldCopyButton.showsFocusRing)
            finish()
        default:
            break
        }
    }
}
