import AppKit
import AraratEngineAPI
import AraratKit
import AraratUI

/// p4checks (design, p4yab): the folder-upload row. A page's `<input webkitdirectory>` asks the
/// platform for a directory. The question Chrome shows after the panel returns ("Upload N
/// files?") is the app's later concern; this check covers the panel itself — that the click on
/// the page's own label reaches Chromium's file chooser, that the panel it opens belongs to our
/// window rather than to the hidden Browser (Yab's defect), and that cancelling it leaves the
/// page where it was. The click is a real mouse event on the page view, the page's own label.
@MainActor
final class FolderUploadCheckState {
    static let names = ["seed", "page_loaded", "click_sent", "chooser_opened", "chooser_ours",
                        "chooser_cancelled", "page_alive"]
    static let screens = ["capture_chooser"]

    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var details: [String: Any] = [:]
    var lastWait = ""
    var waitCount = 0
    var capturing = false
    var windowsBefore: [Int] = []
    var navigation: UInt = 0
    var panelClass = ""
    var panelParent = ""
    var panelWindow: NSWindow?

    func mark(_ name: String, _ value: Bool = true) {
        conditions[name] = value
        FileHandle.standardError.write(Data("ararat-trace: folder-upload \(name)=\(value)\n".utf8))
    }

    func wait(_ name: String, _ value: @autoclosure () -> String) {
        if lastWait != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: folder-upload wait=\(name) \(value())\n".utf8))
        }
        if lastWait != name { lastWait = name; waitCount = 0 }
        waitCount += 1
    }

    static func conditionNames(screen: Bool) -> [String] { names + (screen ? screens : []) }

    func diagnostics(screen: Bool) -> [String: Any] {
        let names = Self.conditionNames(screen: screen)
        return ["conditions": Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }),
                "failed_conditions": names.filter { conditions[$0] != true },
                "wait": lastWait, "images": images, "details": details,
                "panel_class": panelClass, "panel_parent": panelParent,
                "windows": NSApp.windows.map { window in
                    ["class": String(describing: type(of: window)), "title": window.title,
                     "visible": window.isVisible, "number": window.windowNumber,
                     "sheet_parent": window.sheetParent.map { String(describing: type(of: $0)) } ?? "",
                     "attached_sheet": window.attachedSheet.map { String(describing: type(of: $0)) } ?? ""]
                }]
    }
}

extension Runtime {
    func folderUploadCheckDiagnostics(screen: Bool) -> [String: Any] {
        (folderUploadCheck ?? FolderUploadCheckState()).diagnostics(screen: screen)
    }

    func folderUploadCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if folderUploadCheck == nil { folderUploadCheck = FolderUploadCheckState() }
        guard let check = folderUploadCheck, !check.capturing else { return }
        let window = host.window()
        func wait(_ name: String) {
            let tab = (host.tabs() as? [any ARTabAPI])?.first { $0.itemId == browserCheckSeedID }
            check.wait(name, "phase=\(browserCheckPhase) url=\(tab?.url ?? "nil") loading=\(tab?.isLoading ?? false) windows=\(NSApp.windows.count)")
        }
        func finish() {
            let result = check.diagnostics(screen: screen)
            finishBrowserCheck(ok: (result["failed_conditions"] as? [String] ?? ["invalid"]).isEmpty, values: result)
        }
        func panels() -> [NSWindow] {
            NSApp.windows.filter { window in
                let name = String(describing: type(of: window))
                return name.contains("OpenPanel") || name.contains("SavePanel") || name.contains("FileDialog")
                    || name.contains("SelectFileDialog")
            }
        }
        func capture(_ name: String, window target: NSWindow) -> Bool {
            guard screen else { return true }
            check.capturing = true; defer { check.capturing = false }
            guard let path = promptScreenScreenshot(target, name: "folder-upload-\(name)", withoutShadow: true) else { return false }
            check.images[name] = path
            return true
        }
        switch browserCheckPhase {
        case 0:
            guard let port = promptFixturePort,
                  let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first,
                  row.url != nil, window.isVisible else { wait("seed row"); return }
            check.details["seed"] = ["item": row.id, "url": row.url ?? "", "fixture": port]
            browserCheckSeedID = row.id
            selectCheckSeed(row)
            browserCheckPhase = 1
        case 1:
            guard let port = promptFixturePort, let id = browserCheckSeedID,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }) else { wait("seed tab"); return }
            guard snapshot.selectedId == id, host.activeItemId() == id, !tab.isLoading, tab.navigationCount > 0,
                  window.isVisible, !screen || window.isKeyWindow else { wait("active seed tab and key window"); return }
            check.mark("seed")
            host.checkNavigate("http://127.0.0.1:\(port)/folder-upload", disposition: "current")
            browserCheckPhase = 2
        case 2:
            guard let id = browserCheckSeedID,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }),
                  tab.url.hasSuffix("/folder-upload"), !tab.isLoading, tab.navigationCount > 0,
                  window.isVisible, !screen || window.isKeyWindow else { wait("folder-upload page"); return }
            check.mark("page_loaded")
            check.navigation = tab.navigationCount
            check.windowsBefore = NSApp.windows.map(\.windowNumber)
            // The page's own label sits at the page view's top-left: (70, 70) is inside it.
            guard let view = tab.view, let pageWindow = view.window else {
                check.mark("click_sent", false); finish(); return
            }
            let local = NSPoint(x: 70, y: view.isFlipped ? 70 : view.bounds.height - 70)
            let location = view.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: pageWindow.windowNumber, context: nil,
                                                  eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    NSApp.sendEvent(event)
                }
            }
            check.details["click"] = ["local": NSStringFromPoint(local), "window_point": NSStringFromPoint(location),
                                      "view_attached": true, "app_active": NSApp.isActive]
            check.mark("click_sent")
            browserCheckPhase = 3
        case 3:
            let found = panels()
            guard let panel = found.first else {
                // A modal loop would stop the tick here; the timeout diagnostics then list the
                // windows, which is how a panel owned by a hidden window is told apart.
                wait("file panel")
                return
            }
            check.panelClass = String(describing: type(of: panel))
            let parent = panel.sheetParent ?? panel.parent
            check.panelParent = parent.map { String(describing: type(of: $0)) } ?? "nil"
            check.panelWindow = panel
            check.mark("chooser_opened")
            // The panel must be attached to the window a person sees (ours), not to the Browser
            // Chromium keeps off screen.
            let ours = parent === window || window.attachedSheet === panel
            if !ours {
                check.details["panel_parent_frame"] = parent.map { NSStringFromRect($0.frame) } ?? "nil"
                check.details["host_frame"] = NSStringFromRect(window.frame)
            }
            check.mark("chooser_ours", ours)
            if screen {
                check.mark("capture_chooser", capture("chooser", window: panel))
            }
            // Cancel through the panel's own answer: the sheet's cancel, or the panel's close.
            if let parent = panel.sheetParent {
                parent.endSheet(panel, returnCode: .cancel)
            } else {
                panel.performClose(nil)
            }
            browserCheckPhase = 4
        case 4:
            guard panels().isEmpty else { wait("panel cancel"); return }
            check.mark("chooser_cancelled")
            guard let id = browserCheckSeedID,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }) else { wait("tab after cancel"); return }
            let alive = !tab.isLoading && tab.url.hasSuffix("/folder-upload") && tab.navigationCount == check.navigation
            check.mark("page_alive", alive)
            finish()
        default: break
        }
    }
}
