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
    var previousPanelFrame: NSRect?
    var previousPanelWindow: Int?
    var beforeFrame = NSRect.zero
    var cgWindowsBefore = Set<Int>()

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

    static func chooserCaptureArguments(frame: NSRect, screenTop: CGFloat, path: String) -> [String] {
        let region = NSRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height).integral
        return ["-x", "-R\(Int(region.minX)),\(Int(region.minY)),\(Int(region.width)),\(Int(region.height))", path]
    }

    static func chooserWindow(frame: NSRect, screenTop: CGFloat, windows: [[String: Any]], excluding: Set<Int>) -> [String: Any]? {
        let target = NSRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height)
        return windows.first { row in
            guard row[kCGWindowIsOnscreen as String] as? Bool == true,
                  row[kCGWindowLayer as String] as? Int == 0,
                  row[kCGWindowAlpha as String] as? Double == 1,
                  let number = row[kCGWindowNumber as String] as? Int, !excluding.contains(number),
                  let bounds = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            return abs(rect.minX - target.minX) <= 2 && abs(rect.minY - target.minY) <= 2
                && abs(rect.width - target.width) <= 2 && abs(rect.height - target.height) <= 2
        }
    }

    static func chooserSettled(frame: NSRect, previous: NSRect?, alpha: CGFloat, window: Int?, previousWindow: Int?) -> Bool {
        !frame.isEmpty && frame == previous && alpha == 1 && window != nil && window == previousWindow
    }

    static func cropBefore(_ image: CGImage, source: NSRect, region: NSRect) -> CGImage? {
        let region = region.integral
        guard source.contains(region), !source.isEmpty else { return nil }
        let sx = CGFloat(image.width) / source.width, sy = CGFloat(image.height) / source.height
        return image.cropping(to: CGRect(x: (region.minX - source.minX) * sx, y: (source.maxY - region.maxY) * sy,
                                        width: region.width * sx, height: region.height * sy))
    }

    static func chooserDifference(_ before: CGImage, _ after: CGImage) -> (value: Double, changed: Bool)? {
        let width = min(before.width, after.width), height = min(before.height, after.height)
        func pixels(_ image: CGImage) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            return drawn ? bytes : nil
        }
        guard let a = pixels(before), let b = pixels(after) else { return nil }
        var sum = 0
        for index in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<3 { sum += abs(Int(a[index + channel]) - Int(b[index + channel])) }
        }
        let difference = Double(sum) / Double(width * height * 3 * 255)
        return (difference, difference > 0.01)
    }

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
        func panels() -> [NSSavePanel] {
            // The chooser is a stock NSSavePanel (NSOpenPanel inherits it), on screen, and new
            // since the click: any other NSPanel (the command bar's, for one) or a retained
            // panel from an earlier phase must not stand in for it.
            NSApp.windows.compactMap { $0 as? NSSavePanel }.filter {
                $0.isVisible && !check.windowsBefore.contains($0.windowNumber)
            }
        }
        func capture(_ name: String, frame: NSRect) -> Bool {
            guard screen else { return true }
            check.capturing = true; defer { check.capturing = false }
            guard let screenTop = NSScreen.screens.first?.frame.maxY, !frame.isEmpty else {
                FileHandle.standardError.write(Data("ararat-trace: folder-upload capture way=region error=missing-screen-or-frame frame=\(frame)\n".utf8))
                return false
            }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("ararat-folder-upload-\(name)-\(UUID().uuidString).png").path
            let task = Process()
            let error = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = FolderUploadCheckState.chooserCaptureArguments(frame: frame, screenTop: screenTop, path: path)
            task.standardError = error
            check.details["capture"] = ["way": "region", "frame": NSStringFromRect(frame), "arguments": task.arguments ?? []]
            do { try task.run(); task.waitUntilExit() } catch {
                FileHandle.standardError.write(Data("ararat-trace: folder-upload capture way=region error=\(error)\n".utf8))
                return false
            }
            let message = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let image = (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { NSBitmapImageRep(data: $0) }
            let written = task.terminationStatus == 0 && image != nil
            FileHandle.standardError.write(Data("ararat-trace: folder-upload capture way=region frame=\(frame) screen_top=\(screenTop) status=\(task.terminationStatus) written=\(written) error=\(message)\n".utf8))
            check.details["capture_status"] = task.terminationStatus
            check.details["capture_error"] = message
            guard written else { return false }
            check.images[name] = path
            return true
        }
        func cgWindows() -> [[String: Any]] {
            CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        }
        func chooserWindow(_ frame: NSRect) -> [String: Any]? {
            guard let top = NSScreen.screens.first?.frame.maxY else { return nil }
            return FolderUploadCheckState.chooserWindow(frame: frame, screenTop: top, windows: cgWindows(), excluding: check.cgWindowsBefore)
        }
        func image(_ name: String) -> CGImage? {
            guard let path = check.images[name], let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            return NSBitmapImageRep(data: data)?.cgImage
        }
        switch browserCheckPhase {
        case 0:
            guard let port = promptFixturePort,
                  let row = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId })?.today.first,
                  row.url != nil else { wait("seed row"); return }
            check.details["seed"] = ["item": row.id, "url": row.url ?? "", "fixture": port]
            FileHandle.standardError.write(Data("ararat-trace: folder-upload seed-select item=\(row.id) url=\(row.url ?? "nil") visible=\(window.isVisible)\n".utf8))
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
            if screen {
                check.beforeFrame = NSScreen.screens.map(\.frame).reduce(NSRect.null) { $0.union($1) }.integral
                check.details["before_frame"] = NSStringFromRect(check.beforeFrame)
                guard capture("before-screen", frame: check.beforeFrame) else { check.mark("capture_chooser", false); finish(); return }
                check.cgWindowsBefore = Set(cgWindows().compactMap { $0[kCGWindowNumber as String] as? Int })
            }
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
            if check.conditions["chooser_opened"] == nil { check.mark("chooser_opened") }
            // The panel must be attached to the window a person sees (ours), not to the Browser
            // Chromium keeps off screen.
            let ours = parent === window || window.attachedSheet === panel
            if !ours {
                check.details["panel_parent_frame"] = parent.map { NSStringFromRect($0.frame) } ?? "nil"
                check.details["host_frame"] = NSStringFromRect(window.frame)
            }
            if check.conditions["chooser_ours"] == nil { check.mark("chooser_ours", ours) }
            if screen {
                let frame = panel.frame
                let cgWindow = chooserWindow(frame)
                let number = cgWindow?[kCGWindowNumber as String] as? Int
                let settled = FolderUploadCheckState.chooserSettled(frame: frame, previous: check.previousPanelFrame,
                    alpha: panel.alphaValue, window: number, previousWindow: check.previousPanelWindow)
                check.previousPanelFrame = frame
                check.previousPanelWindow = number
                guard settled else {
                    FileHandle.standardError.write(Data("ararat-trace: folder-upload wait=chooser-settle frame=\(frame) alpha=\(panel.alphaValue) cg_window=\(cgWindow?[kCGWindowNumber as String] ?? "nil")\n".utf8))
                    return
                }
                let captured = capture("chooser", frame: frame)
                let stillOnScreen = chooserWindow(frame)?[kCGWindowNumber as String] as? Int == cgWindow?[kCGWindowNumber as String] as? Int
                    && panel.frame == frame && panel.alphaValue == 1
                var changed = false
                if captured, let before = image("before-screen"), let after = image("chooser"),
                   let crop = FolderUploadCheckState.cropBefore(before, source: check.beforeFrame, region: frame),
                   let data = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]),
                   let difference = FolderUploadCheckState.chooserDifference(crop, after) {
                    let path = FileManager.default.temporaryDirectory.appendingPathComponent("ararat-folder-upload-before-\(UUID().uuidString).png")
                    do {
                        try data.write(to: path)
                        check.images["before-chooser"] = path.path
                        check.details["image_difference"] = difference.value
                        check.details["image_difference_threshold"] = 0.01
                        changed = difference.changed
                    } catch { FileHandle.standardError.write(Data("ararat-trace: folder-upload capture baseline-crop error=\(error)\n".utf8)) }
                }
                check.details["chooser_cg_window"] = cgWindow
                check.details["chooser_on_screen_at_capture"] = stillOnScreen
                FileHandle.standardError.write(Data("ararat-trace: folder-upload capture evidence on_screen=\(stillOnScreen) changed=\(changed) difference=\(check.details["image_difference"] ?? "nil") before=\(check.images["before-chooser"] ?? "nil") after=\(check.images["chooser"] ?? "nil")\n".utf8))
                check.mark("capture_chooser", captured && stillOnScreen && changed)
            }
            // Cancel through the panel's own action (its Cancel button's selector), the answer
            // a person's click sends, whether it is a sheet or a free panel.
            panel.cancel(nil)
            browserCheckPhase = 4
        case 4:
            guard panels().isEmpty else { wait("panel cancel"); return }
            check.mark("chooser_cancelled")
            // Our layer has no page-script read, so the fixture's own `cancel` dataset entry is not
            // observable here; `page_alive` is the "nothing broke on cancel" half.
            guard let id = browserCheckSeedID,
                  let tab = (host.tabs() as? [any ARTabAPI])?.first(where: { $0.itemId == id }) else { wait("tab after cancel"); return }
            let alive = !tab.isLoading && tab.url.hasSuffix("/folder-upload") && tab.navigationCount == check.navigation
            check.mark("page_alive", alive)
            finish()
        default: break
        }
    }
}
