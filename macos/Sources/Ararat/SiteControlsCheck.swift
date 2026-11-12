import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// U26e pass 4's check: the site-controls popover, permission rows through the engine, the
/// blocked dot, both captures to the pasteboard and the toast, and the certificate panel. The
/// VM has an empty accessibility tree and no real cursor, so every step reads the view tree,
/// the engine snapshot or a posted overlay drag.
@MainActor
final class SiteControlsCheck {
    static let common = ["fixture", "seed", "secure_page", "secure_security", "chain",
                         "actions", "popover_geometry", "permission_prompt", "permission_row",
                         "blocked_dot", "permission_change", "permission_reset", "menu_items",
                         "certificate_panel", "certificate_closed", "popover_dismiss",
                         "region_capture", "region_pasteboard", "region_toast", "region_cancel",
                         "full_page_capture", "full_page_pasteboard", "full_page_toast",
                         "insecure_security", "insecure_no_chain", "internal_page",
                         "voiceover_labels"]
    static let screens = ["capture_popover", "capture_overlay", "capture_certificate", "capture_toast"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var capturing = false
    var waitName = ""
    var waitCount = 0
    var item = ""
    var startData: Data?
    var startPasteboard: Data?
    var regionRect = NSRect(x: 40, y: 60, width: 200, height: 120)
    var toastGeneration = 0
    var permissionRow = 0
    var allowIndex = 0

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: site-controls \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: site-controls wait=\(name) current=\(value)\n".utf8))
        }
        if waitName != name { waitCount = 0; waitName = name }
        waitCount += 1
    }

    static func conditionNames(screen: Bool) -> [String] {
        common + (screen ? screens : [])
    }

    static func conditionResults(_ conditions: [String: Bool], screen: Bool) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(screen: screen)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                names.filter { conditions[$0] != true })
    }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                "failed_conditions": names.filter { conditions[$0] != true },
                "wait": waitName, "images": images, "item": item,
                "unverified": ["The full-page readback threshold and the tiling bound (VM measurement)",
                               "A too-large page's error toast (needs a page above the 16384 device px bound)",
                               "A split pane whose page view is offset (only the card is exercised)",
                               "Safe Browsing verdicts in the security footer",
                               "VoiceOver speech output; announcements and labels are observed"]]
    }
}

extension Runtime {
    func siteControlsCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if siteControlsCheck == nil { siteControlsCheck = SiteControlsCheck() }
        guard let check = siteControlsCheck, !check.capturing, let sidebar, let container else { return }
        let window = host.window()
        func wait(_ name: String) {
            let state = siteState
            check.wait(name, "phase=\(browserCheckPhase) key=\(window.isKeyWindow) shown=\(state?.document ?? "nil") security=\(state?.security ?? "nil") rows=\(state?.permissions.count ?? 0) dot=\(sidebar.checkSiteControlsDot) popover=\(siteControls?.isShown ?? false) overlay=\(siteOverlay != nil)")
        }
        func capture(_ name: String, window target: NSWindow? = nil) -> Bool {
            guard screen else { return true }
            check.capturing = true; defer { check.capturing = false }
            guard let path = promptScreenScreenshot(target ?? window, name: "site-controls-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        func fail(_ message: String) {
            var result = check.diagnostics(screen: screen); result["error"] = message
            finishBrowserCheck(ok: false, values: result)
        }
        func openPopover() {
            sidebar.checkClickSiteControls()
        }
        func fixturePorts() -> SiteFixtureServer.Ports? { siteFixturePorts }
        func activeTab() -> (any ARTabAPI)? {
            (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == snapshot.selectedId }
        }
        func isGrid(_ value: CGFloat) -> Bool { abs(value / 8 - (value / 8).rounded()) < 0.001 }

        switch browserCheckPhase {
        case 0:
            guard let ports = fixturePorts(), let space = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }),
                  let row = space.today.first, host.hasBrowser(), window.isVisible, window.isKeyWindow else {
                wait("seed, fixture and key window"); return
            }
            _ = ports
            check.mark("fixture")
            check.item = row.id
            browserCheckSeedID = row.id
            selectCheckSeed(row)
            browserCheckPhase = 1
        case 1:
            guard let ports = fixturePorts(), let id = browserCheckSeedID, snapshot.selectedId == id,
                  host.activeItemId() == id,
                  let tab = activeTab(), !tab.isLoading, tab.navigationCount > 0 else { wait("active seed tab"); return }
            check.mark("seed")
            host.checkNavigate("https://127.0.0.1:\(ports.secure)/site", disposition: "current")
            browserCheckPhase = 2
        case 2:
            guard let ports = fixturePorts(), let tab = activeTab(),
                  tab.url.hasPrefix("https://127.0.0.1:\(ports.secure)/site"), !tab.isLoading else { wait("secure fixture"); return }
            refreshSiteState()
            guard let state = siteState, state.document.count > 0, state.security != "none", !state.isInternal,
                  state.origin == "https://127.0.0.1:\(ports.secure)" else { wait("secure snapshot"); return }
            check.mark("secure_page")
            check.mark("secure_security", state.security == "secure")
            check.mark("chain", state.certificateChain.count >= 1)
            openPopover()
            guard let controls = siteControls, controls.isShown else { wait("site controls popover"); return }
            check.mark("actions", controls.checkActionTitles == ["Screenshot a region", "Capture the full page"])
            let size = controls.checkContentSize
            let frames = controls.checkActionFrames
            let rows = controls.checkPermissionRows
            let padded = frames.allSatisfy { $0.minX == controls.checkPadding && isGrid($0.height) }
            check.mark("popover_geometry", size.width == 262 && isGrid(size.height) && padded
                       && controls.checkPadding == 16 && controls.checkGap == 16 && rows.isEmpty)
            check.mark("voiceover_labels", controls.checkLabelsComplete)
            if screen {
                window.makeKeyAndOrderFront(nil)
                check.mark("capture_popover", capture("popover"))
            }
            // The fixture asks for location; the block decision is the same path a click takes.
            tab.checkRequestPermission(1)
            browserCheckPhase = 3
        case 3:
            guard let tab = activeTab(), tab.checkPermissionShownCount() > 0 else { wait("permission prompt"); return }
            check.mark("permission_prompt")
            guard tab.checkPermissionDecision(2) else { wait("permission decision"); return }
            browserCheckPhase = 4
        case 4:
            guard let tab = activeTab(), !tab.checkPermissionPending() else { wait("blocked permission"); return }
            refreshSiteState()
            guard let state = siteState,
                  let row = state.permissions.first(where: { $0.type == "geolocation" }) else { wait("permission row"); return }
            check.mark("permission_row", row.setting?.isBlock == true && row.mutable)
            check.mark("blocked_dot", state.blocked && sidebar.checkSiteControlsDot)
            guard let controls = siteControls, controls.isShown else { wait("popover after block"); return }
            let rows = controls.checkPermissionRows
            guard let index = rows.firstIndex(where: { $0.type == "geolocation" }) else { wait("popover permission row"); return }
            check.permissionRow = index
            let entry = rows[index]
            let allow = entry.items.firstIndex(of: "Allow") ?? -1
            check.allowIndex = allow
            check.mark("menu_items", entry.items.contains("Allow") && entry.items.contains("Block")
                       && entry.items.contains("Ask") && entry.items.contains("Reset") && entry.current == "Block")
            if screen { check.mark("capture_overlay", true) }
            guard allow >= 0, controls.checkChoosePermission(row: index, item: allow) else { wait("allow choice"); return }
            browserCheckPhase = 5
        case 5:
            refreshSiteState()
            guard let state = siteState, let row = state.permissions.first(where: { $0.type == "geolocation" }),
                  row.setting?.title == "Allow" else { wait("allowed permission"); return }
            check.mark("permission_change", !state.blocked)
            guard let controls = siteControls, controls.isShown,
                  controls.checkChoosePermission(row: check.permissionRow, item: -1) else { wait("reset choice"); return }
            browserCheckPhase = 6
        case 6:
            refreshSiteState()
            guard let state = siteState,
                  (state.permissions.first(where: { $0.type == "geolocation" })?.setting == nil) else { wait("reset permission"); return }
            check.mark("permission_reset")
            guard let controls = siteControls, controls.isShown, controls.checkFooterEnabled else { wait("certificate footer"); return }
            guard controls.checkClickFooter() else { wait("certificate click"); return }
            browserCheckPhase = 7
        case 7:
            guard let controls = siteControls, let sheet = controls.checkAttachedCertificateSheet else { wait("certificate sheet"); return }
            check.mark("certificate_panel", controls.checkCertificatePanelOpen && sheet.isVisible)
            if screen { check.mark("capture_certificate", capture("certificate", window: sheet)) }
            controls.checkCloseCertificatePanel()
            browserCheckPhase = 8
        case 8:
            guard let controls = siteControls, controls.checkAttachedCertificateSheet == nil else { wait("certificate dismissed"); return }
            check.mark("certificate_closed")
            controls.close()
            guard !controls.isShown else { wait("popover dismissed"); return }
            check.mark("popover_dismiss")
            check.startPasteboard = NSPasteboard.general.data(forType: .png)
            openPopover()
            guard let fresh = siteControls, fresh.isShown, fresh.checkClickAction("Screenshot a region") else { wait("region action"); return }
            browserCheckPhase = 9
        case 9:
            guard let overlay = siteOverlay, overlay.superview === container.pageCard else { wait("region overlay"); return }
            let frame = overlay.frame
            check.regionRect = NSRect(x: 40, y: 60, width: 200, height: 120)
            overlay.performCheckDrag(from: check.regionRect.origin,
                                     to: NSPoint(x: check.regionRect.maxX, y: check.regionRect.maxY))
            check.mark("region_capture", NSEqualRects(overlay.frame, frame))
            browserCheckPhase = 10
        case 10:
            let data = NSPasteboard.general.data(forType: .png)
            let toast = container.checkToastState
            guard siteOverlay == nil, let data, data != check.startPasteboard,
                  toast.visible, toast.message == "Screenshot copied" else { wait("region pasteboard and toast"); return }
            let image = NSImage(data: data)
            let scale = window.backingScaleFactor
            let expected = NSSize(width: (check.regionRect.width * scale).rounded(), height: (check.regionRect.height * scale).rounded())
            let size = image?.size ?? .zero
            check.mark("region_pasteboard", abs(size.width - expected.width) <= 2 && abs(size.height - expected.height) <= 2)
            check.mark("region_toast", toast.message == "Screenshot copied" && abs(toast.frame.midX - toast.page.midX) < 1)
            if screen { check.mark("capture_toast", capture("toast")) }
            check.toastGeneration = toast.generation
            browserCheckPhase = 11
        case 11:
            guard !container.checkToastState.visible else { wait("capture toast expiry"); return }
            guard let ports = fixturePorts(), let tab = activeTab() else { wait("capture fixture tab"); return }
            host.checkNavigate("https://127.0.0.1:\(ports.secure)/capture", disposition: "current")
            browserCheckPhase = 12
        case 12:
            guard let ports = fixturePorts(), let tab = activeTab(),
                  tab.url.hasPrefix("https://127.0.0.1:\(ports.secure)/capture"), !tab.isLoading,
                  tab.navigationCount > 0 else { wait("capture page"); return }
            check.startPasteboard = NSPasteboard.general.data(forType: .png)
            openPopover()
            guard let controls = siteControls, controls.isShown,
                  controls.checkClickAction("Capture the full page") else { wait("full page action"); return }
            browserCheckPhase = 13
        case 13:
            let data = NSPasteboard.general.data(forType: .png)
            let toast = container.checkToastState
            guard let data, data != check.startPasteboard, toast.visible,
                  toast.message == "Screenshot copied" else { wait("full page pasteboard and toast"); return }
            guard let image = NSImage(data: data), let tab = activeTab(), let page = tab.view else { wait("full page image"); return }
            let scale = window.backingScaleFactor
            check.mark("full_page_capture", image.size.height > page.bounds.height * scale + 200)
            check.mark("full_page_pasteboard", data.count > 1000)
            check.mark("full_page_toast", toast.message == "Screenshot copied")
            browserCheckPhase = 14
        case 14:
            guard !container.checkToastState.visible else { wait("full page toast expiry"); return }
            guard let ports = fixturePorts() else { wait("plain fixture"); return }
            host.checkNavigate("http://127.0.0.1:\(ports.plain)/clean", disposition: "current")
            browserCheckPhase = 15
        case 15:
            guard let ports = fixturePorts(), let tab = activeTab(),
                  tab.url.hasPrefix("http://127.0.0.1:\(ports.plain)/clean"), !tab.isLoading else { wait("insecure fixture"); return }
            refreshSiteState()
            guard let state = siteState, state.origin.hasPrefix("http://127.0.0.1:\(ports.plain)") else { wait("insecure snapshot"); return }
            check.mark("insecure_security", state.security == "not_secure")
            check.mark("insecure_no_chain", state.certificateChain.isEmpty)
            guard let controls = siteControls, controls.isShown else { wait("certificate footer disabled"); return }
            check.mark("insecure_no_chain", state.certificateChain.isEmpty && !controls.checkFooterEnabled)
            controls.close()
            host.checkNavigate("chrome://version", disposition: "current")
            browserCheckPhase = 16
        case 16:
            guard let tab = activeTab(), tab.url.hasPrefix("chrome://version"), !tab.isLoading else { wait("internal page"); return }
            refreshSiteState()
            guard let state = siteState else { wait("internal snapshot"); return }
            check.mark("internal_page", state.isInternal && state.permissions.isEmpty && state.security == "none")
            check.startPasteboard = NSPasteboard.general.data(forType: .png)
            openPopover()
            guard let controls = siteControls, controls.isShown else { wait("internal popover"); return }
            _ = controls
            browserCheckPhase = 17
        case 17:
            guard let controls = siteControls, controls.isShown, controls.checkPermissionRows.isEmpty else { wait("internal popover rows"); return }
            controls.close()
            guard let ports = fixturePorts() else { wait("region cancel fixture"); return }
            host.checkNavigate("https://127.0.0.1:\(ports.secure)/site", disposition: "current")
            browserCheckPhase = 18
        case 18:
            guard let ports = fixturePorts(), let tab = activeTab(),
                  tab.url.hasPrefix("https://127.0.0.1:\(ports.secure)/site"), !tab.isLoading else { wait("cancel fixture"); return }
            openPopover()
            guard let controls = siteControls, controls.isShown,
                  controls.checkClickAction("Screenshot a region") else { wait("cancel overlay"); return }
            browserCheckPhase = 19
        case 19:
            guard let overlay = siteOverlay else { wait("cancel overlay view"); return }
            overlay.cancel()
            browserCheckPhase = 20
        case 20:
            let data = NSPasteboard.general.data(forType: .png)
            guard siteOverlay == nil else { wait("overlay removed"); return }
            check.mark("region_cancel", data == check.startPasteboard && !container.checkToastState.visible)
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        default:
            break
        }
    }
}
