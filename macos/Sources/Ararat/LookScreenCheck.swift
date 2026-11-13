import AppKit
import AraratKit
import AraratUI
import AraratEngineAPI
import SQLite3

@MainActor
final class LookScreenCheck {
    var probe: LookCheckProbe?
    var phase = 0
    var conditions: [String: Bool] = [:]
    var images: [String: String] = [:]
    var menuItems: [String]?
    var menuObserver: NSObjectProtocol?
    var menuSending = false
    var menuSkipLogged = false
    var cancelMenu: (NSMenu) -> Void = { $0.cancelTracking() }
    var initialPrepared = false
    var count = 0
    var capturing = false
    var waitName = ""
    var waitCount = 0
    var grainWritten = ""
    var grainStats: [String: LookGrainStats] = [:]
    var grainBand: CGRect?
    var grainExpected: [String: Double] = [:]
    var grainTries = 0
    var pickerWritten = false

    /// U24b: the grain's drawing rule, measured on the real sidebar. `L′` comes from each run's own
    /// grain-0 capture, so the tolerances need no colour constant; the numbers below are the mock's.
    static let grainConditionNames = ["grain_0_flat", "grain_5", "grain_50", "grain_100", "grain_100_keeps_colour", "grain_never_darkens", "grain_linear"]
    /// The four probe steps: the layer's opacity is the stored grain, and the capture's name doubles
    /// as the diagnostics' key.
    static let grainSteps: [(capture: String, grain: Double, condition: String)] = [
        ("grain0", 0, "grain_0_flat"), ("grain5", 0.05, "grain_5"), ("grain50", 0.5, "grain_50"), ("grain100", 1, "grain_100")
    ]
    /// The probe's Slate as a capture of it reads: the flat patch's mean and chroma in 0…255 code
    /// values. The first VM run accepted a band that measured the Look editor's popover (mean 220,
    /// chroma 5) as the look's "flat" patch, so the band now has to show Slate before any grain is
    /// judged (`grain_0_flat`), and a capture that does not is retried and then named.
    static let probeMean: Double = (0 + 27.0 + 89.0) / 3
    static let probeChroma: Double = 89
    /// Whether a capture's band is the look at all: Slate or one of the grain steps over it, whose
    /// mean rises to about 114 at 100 %, while the colour keeps most of its chroma.
    static func showsLook(_ stats: LookGrainStats) -> Bool {
        let top = probeMean + 0.35 * (255 - probeMean)
        return (probeMean - 8)...(top + 8) ~= stats.mean && stats.chroma >= 0.55 * probeChroma
    }
    /// How many captures a band that does not show the look is waited out: the VM's compositor can
    /// hand back the previous frame, which this many 0.1 s ticks covers.
    static let grainBandTries = 20
    /// U24 part 2 pass B: the polar picker's drag and its single write. The names run in both the
    /// hidden and the screen check, because the picker needs no capture.
    static let pickerConditionNames = ["picker_write", "picker_input", "picker_preview", "picker_one_write"]
    static func conditionNames(screen: Bool) -> [String] {
        ["open", "initial_preview_input", "menu_open", "menu", "drag_detent_input", "detent", "drag_glass_input", "glass", "stored_glass", "thirty_input", "socket_input", "keyboard_focus", "keyboard_up_input", "keyboard_glass", "keyboard_down_input", "keyboard_down", "grain_focus", "grain_up_input", "keyboard_grain", "transparency_focus_return", "transparency_up_input", "reduced_transparency"] + pickerConditionNames + (screen ? ["capture_55", "capture_detent", "capture_glass"] + grainConditionNames : [])
    }
    static func conditionResults(_ conditions: [String: Bool], screen: Bool) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(screen: screen)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }), names.filter { conditions[$0] != true })
    }
    static func lookFields(_ look: Look?) -> Any {
        guard let look else { return NSNull() }
        return ["opacity": look.opacity, "grain": look.grain, "glass": look.glass, "appearance": String(describing: look.appearance), "colors": look.colors.map { ["red": $0.red, "green": $0.green, "blue": $0.blue, "x": $0.x, "y": $0.y] }] as [String: Any]
    }
    /// The grain phases' fixed probe: one colour, Light, Transparency 0 (the colour layer is opaque
    /// and the grain sits on it). The mock's Slate keeps the noise's contrast large: with L′ ≈ 0.152
    /// the mock's sd is about 1.7, 17.3 and 34.6 code values at 5, 50 and 100 %.
    static func probeLook(grain: Double) -> Look {
        Look(colors: [LookColor(red: 0, green: 27.0 / 255, blue: 89.0 / 255, x: 220.0 / 360, y: 0.5)],
             opacity: 1, grain: grain, glass: false, appearance: .light)
    }
    static func isProbe(_ look: Look, grain: Double) -> Bool {
        abs(look.grain - grain) < 0.001 && abs(look.opacity - 1) < 0.001 && !look.glass && look.appearance == .light
            && look.colors.count == 1 && abs(look.colors[0].blue - 89.0 / 255) < 0.01
    }
    static func isProbeColour(_ color: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB) ?? color
        return abs(c.redComponent) < 0.01 && abs(c.greenComponent - 27.0 / 255) < 0.01
            && abs(c.blueComponent - 89.0 / 255) < 0.01 && c.alphaComponent > 0.99
    }
    /// One line per wait, naming what is waited for and what the app currently shows.
    func wait(_ name: String, _ value: String) {
        if waitName != name || waitCount % 20 == 0 {
            FileHandle.standardError.write(Data("ararat-trace: look wait=\(name) current=\(value)\n".utf8))
        }
        if waitName != name { waitCount = 0; waitName = name }
        waitCount += 1
    }
    func elements(_ element: NSAccessibilityProtocol) -> [NSAccessibilityProtocol] {
        let children = NSAccessibility.unignoredChildren(from: element.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
        return children + children.flatMap { elements($0) }
    }
    func element(_ label: String) -> NSAccessibilityProtocol? {
        guard let window = probe?.window else { return nil }
        return elements(window).first { $0.accessibilityLabel() == label }
    }
    func event(_ type: NSEvent.EventType, screen: NSPoint, window: NSWindow) -> Bool {
        guard let event = NSEvent.mouseEvent(with: type, location: window.convertPoint(fromScreen: screen), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else { return false }
        window.sendEvent(event)
        return true
    }
    func trackPoint(_ value: Double) -> NSPoint? {
        guard let frame = probe?.trackFrame else { return nil }
        guard frame.width > 32 && frame.height >= 30 else { return nil }
        return NSPoint(x: frame.minX + (frame.width - 32) * value, y: frame.midY)
    }
    func mouse(_ type: NSEvent.EventType, position: Double) -> Bool {
        guard let point = trackPoint(position), let window = probe?.window else { return false }
        return event(type, screen: point, window: window)
    }
    static func sendWhenFocused(_ focused: Bool, send: () -> Bool) -> Bool? {
        guard focused else { return nil }
        return send()
    }
    func key(_ code: UInt16) -> Bool {
        guard let window = probe?.window else { return false }
        let character = String(UnicodeScalar(code == 126 ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { return false }
        window.sendEvent(event)
        return true
    }
    func focus(_ label: String) -> Bool { probe?.focus(label) == true }
    func journalCount(_ path: String?) -> Int? {
        guard let path else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { if let db { sqlite3_close(db) }; return nil }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM journal WHERE kind = 'space'", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }
    func report(_ name: String, _ ok: Bool) {
        conditions[name] = ok
        if let data = try? JSONSerialization.data(withJSONObject: ["check": "look", "phase": name, "ok": ok], options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        }
    }
    func watchMenu() {
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                let items = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
                self?.menuItems = items
                FileHandle.standardError.write(Data("ararat-trace: look-menu began items=\(String(reflecting: items))\n".utf8))
                self?.stopWatchingMenu()
                RunLoop.main.perform(inModes: [.eventTracking]) { [weak self, weak menu] in
                    MainActor.assumeIsolated {
                        if let self, let menu {
                            self.cancelMenu(menu)
                            FileHandle.standardError.write(Data("ararat-trace: look-menu cancel ran\n".utf8))
                        }
                    }
                }
            }
        }
    }
    func stopWatchingMenu() {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver); self.menuObserver = nil }
    }
    deinit { if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) } }
}

/// What one capture says about the sidebar's grain, in 0…255 code values.
struct LookGrainStats {
    var sd: Double = 0
    var mean: Double = 0
    var chroma: Double = 0
    var patches: Int = 0
    var defect: String?
}

extension LookScreenCheck {
    /// Measures the grain in a capture of the window: the *modal* patch's standard deviation is the
    /// drawn noise's contrast, and that patch's mean and chroma are the colour under it. Text,
    /// tiles, row fills and the field land in the sd histogram's tail, the sidebar's background —
    /// where the grain is drawn — in its peak; the dominant flat colour is then taken from those
    /// patches' means, so a large flat element such as the URL field cannot move L′.
    ///
    /// `panel` is the sidebar's rect in screen points and `windowFrame` the window's; the capture's
    /// own pixel-to-point ratio comes from its width, so the band maps at any display scale. A
    /// vertical offset (a capture that leaves out the title bar) only moves the band inside the
    /// sidebar, which the statistic does not mind.
    static func grainStats(path: String, windowFrame: NSRect, panel: NSRect, patch: CGFloat = 8) -> LookGrainStats {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let rep = NSBitmapImageRep(data: data),
              let image = rep.cgImage, rep.pixelsWide > 8, rep.pixelsHigh > 8, windowFrame.width > 0 else {
            return LookGrainStats(defect: "capture unreadable at \(path)")
        }
        let width = rep.pixelsWide
        let height = rep.pixelsHigh
        let ratio = CGFloat(width) / windowFrame.width
        let band = CGRect(x: (panel.minX - windowFrame.minX) * ratio,
                          y: (windowFrame.maxY - panel.maxY) * ratio,
                          width: panel.width * ratio,
                          height: panel.height * ratio).intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let step = max(2, Int((patch * ratio).rounded()))
        guard band.width >= CGFloat(step * 2), band.height >= CGFloat(step * 2) else {
            return LookGrainStats(defect: "band \(Int(band.width))x\(Int(band.height)) px outside \(width)x\(height) for panel \(Int(panel.width))x\(Int(panel.height)) pt")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return LookGrainStats(defect: "capture not drawn") }
        var deviations: [Double] = []
        var means: [Double] = []
        var colours: [(Double, Double, Double)] = []
        var y = Int(band.minY)
        while y + step <= Int(band.maxY) {
            var x = Int(band.minX)
            while x + step <= Int(band.maxX) {
                var sum = 0.0, squares = 0.0, reds = 0.0, greens = 0.0, blues = 0.0
                for row in y..<(y + step) {
                    for column in x..<(x + step) {
                        let index = (row * width + column) * 4
                        let red = Double(pixels[index]) / 255
                        let green = Double(pixels[index + 1]) / 255
                        let blue = Double(pixels[index + 2]) / 255
                        let value = (red + green + blue) / 3 * 255
                        sum += value
                        squares += value * value
                        reds += red
                        greens += green
                        blues += blue
                    }
                }
                let count = Double(step * step)
                let mean = sum / count
                deviations.append(max(0, squares / count - mean * mean).squareRoot())
                means.append(mean)
                colours.append((reds / count, greens / count, blues / count))
                x += step
            }
            y += step
        }
        guard !deviations.isEmpty else { return LookGrainStats(defect: "no patches in the band") }
        // The noise's own contrast: the sd histogram's peak (0.5 code value bins).
        var histogram: [Int: Int] = [:]
        for deviation in deviations { histogram[Int((deviation / 0.5).rounded()), default: 0] += 1 }
        let peak = histogram.max { $0.value < $1.value }?.key ?? 0
        let noisy = deviations.indices.filter { abs(deviations[$0] - Double(peak) * 0.5) <= 0.3 }
        // The dominant flat colour among those patches, so the URL field or a tile cannot win.
        var flat: [Int: Int] = [:]
        for index in noisy { flat[Int(means[index].rounded()), default: 0] += 1 }
        let colour = flat.max { $0.value < $1.value }?.key ?? 0
        let chosen = noisy.filter { abs(means[$0] - Double(colour)) <= 1.5 }
        guard !chosen.isEmpty else { return LookGrainStats(defect: "no flat patches") }
        let count = Double(chosen.count)
        let mean = chosen.map { means[$0] }.reduce(0, +) / count
        let reds = chosen.map { colours[$0].0 }.reduce(0, +) / count
        let greens = chosen.map { colours[$0].1 }.reduce(0, +) / count
        let blues = chosen.map { colours[$0].2 }.reduce(0, +) / count
        return LookGrainStats(sd: chosen.map { deviations[$0] }.reduce(0, +) / count,
                              mean: mean, chroma: (max(reds, greens, blues) - min(reds, greens, blues)) * 255,
                              patches: chosen.count)
    }
}

extension Runtime {
    func lookCheckDiagnostics(screen: Bool) -> [String: Any] {
        let check = lookCheck
        let result = LookScreenCheck.conditionResults(check?.conditions ?? [:], screen: screen)
        let window = check?.probe?.window
        let stored = adapter?.session.queue.sync {
            adapter?.session.store?.snapshot(windowId: windowID).spaces.first { $0.id == snapshot.shownSpaceId }?.look
        }
        let ax: [[String: Any]] = window.map { window in
            (check?.elements(window) ?? []).map { element in
                let value = element.accessibilityValue()
                return ["label": element.accessibilityLabel() as Any? ?? NSNull(),
                        "value": value.map { String(describing: $0) } as Any? ?? NSNull(),
                        "frame": rectFields(element.accessibilityFrame())]
            }
        } ?? []
        let point = check?.trackPoint(1)
        let probe: [String: Any] = ["look": LookScreenCheck.lookFields(check?.probe?.look),
            "editing": check?.probe?.editing as Any? ?? NSNull(),
            "transparency_tag": check?.probe?.transparencyTag as Any? ?? NSNull(),
            "haptics": check?.probe?.haptics as Any? ?? NSNull(),
            "transparency_has_focus": check?.probe?.hasFocus("Transparency") as Any? ?? NSNull(),
            "grain_has_focus": check?.probe?.hasFocus("Grain") as Any? ?? NSNull()]
        return ["conditions": result.values, "failed_conditions": result.failed,
            "phase": check?.phase ?? browserCheckPhase, "menu_items": check?.menuItems as Any? ?? NSNull(),
            "probe": probe, "stored_look": LookScreenCheck.lookFields(stored ?? nil),
            "journal_count": check?.journalCount(quitPath) as Any? ?? NSNull(),
            "journal_baseline": check?.count as Any? ?? NSNull(), "database_path": quitPath as Any? ?? NSNull(),
            "popover_window_number": window?.windowNumber as Any? ?? NSNull(),
            "popover_frame": window.map { rectFields($0.frame) } as Any? ?? NSNull(),
            "popover_alpha": window?.alphaValue as Any? ?? NSNull(),
            "popover_visible": window?.isVisible as Any? ?? NSNull(),
            "popover_key": window?.isKeyWindow as Any? ?? NSNull(),
            "settings_key": (root ?? self).settings?.window?.isKeyWindow as Any? ?? NSNull(),
            "app_active": NSApp.isActive,
            "first_responder": window?.firstResponder.map { NSStringFromClass(type(of: $0)) } as Any? ?? NSNull(),
            "ax_elements": ax,
            "transparency_frame": check?.element("Transparency").map { rectFields($0.accessibilityFrame()) } as Any? ?? NSNull(),
            "track_frame": check?.probe?.trackFrame.map { rectFields($0) } as Any? ?? NSNull(),
            "track_point_100": point.map { ["x": $0.x, "y": $0.y] } as Any? ?? NSNull(),
            "wait": check?.waitName ?? "",
            "grain_stats": (check?.grainStats ?? [:]).mapValues { stats -> [String: Any] in
                ["sd": stats.sd, "mean": stats.mean, "chroma": stats.chroma, "patches": stats.patches, "defect": stats.defect ?? ""]
            } as [String: Any],
            "grain_expected": check?.grainExpected as Any? ?? NSNull(),
            "grain_band": check?.grainBand.map { rectFields($0) } as Any? ?? NSNull(),
            "grain_tries": check?.grainTries as Any? ?? NSNull(),
            "images": check?.images ?? [:]]
    }
    func lookCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if lookCheck == nil { lookCheck = LookScreenCheck() }
        guard let check = lookCheck else { return }
        if check.menuSending {
            if !check.menuSkipLogged {
                check.menuSkipLogged = true
                FileHandle.standardError.write(Data("ararat-trace: look tick skipped while menu open\n".utf8))
            }
            return
        }
        guard let sidebarContainer = container, let session = adapter?.session else { return }
        guard !check.capturing else { return }
        func stored() -> Look? {
            session.queue.sync { session.store?.snapshot(windowId: windowID).spaces.first { $0.id == snapshot.shownSpaceId }?.look }
        }
        func capture(_ name: String) -> Bool {
            guard screen else { return true }
            guard let popup = check.probe?.window,
                  let p = promptScreenScreenshot(popup, name: "look-\(name)-popover", withoutShadow: true),
                  let s = promptScreenScreenshot(host.window(), name: "look-\(name)-sidebar", withoutShadow: true) else { return false }
            check.images["\(name)_popover"] = p; check.images["\(name)_sidebar"] = s
            return true
        }
        /// U24b's grain captures only the window: the popover is not part of the band. The Look
        /// editor's popover is a child window of the browser window, though, so the window's capture
        /// composites it over the sidebar — in the first VM run its flat background won the
        /// estimator's modal patch (mean 220, chroma 5, both grain steps identical). The capture is
        /// of the sidebar, so the editor is made invisible for it and put back in the same tick; its
        /// window, model, focus and size are untouched.
        func captureSidebar(_ name: String) -> Bool {
            guard screen else { return true }
            check.capturing = true
            defer { check.capturing = false }
            let popover = check.probe?.window
            let alpha = popover?.alphaValue
            popover?.alphaValue = 0
            defer { if let alpha { popover?.alphaValue = alpha } }
            FileHandle.standardError.write(Data("ararat-trace: look capturing \(name) popover_hidden=\(popover != nil)\n".utf8))
            guard let path = promptScreenScreenshot(host.window(), name: "look-\(name)-sidebar", withoutShadow: true) else { return false }
            check.images["\(name)_sidebar"] = path
            return true
        }
        func end(_ ok: Bool, _ name: String) {
            check.report(name, ok)
            if !ok { finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)) }
            else { check.phase += 1; browserCheckPhase = check.phase }
        }
        switch check.phase {
        case 0:
            guard snapshot.shownSpaceId != nil, snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) != nil else { return }
            check.phase = 1; browserCheckPhase = 1
        case 1:
            // Preflight check 9: the probe moves to the space name row's Edit Look…, which
            // opens the same popover the right-click path does (no Settings window needed).
            guard let probe = sidebar?.openLookForCheck(), probe.window != nil else { return }
            check.probe = probe
            end(true, "open")
        case 2:
            guard let popup = check.probe?.window, let menuFrame = check.probe?.menuFrame, check.probe?.trackFrame != nil else { return }
            if !check.initialPrepared {
                guard check.mouse(.leftMouseDown, position: 0.54), check.mouse(.leftMouseUp, position: 0.54),
                      check.mouse(.leftMouseDown, position: 0.55), check.mouse(.leftMouseUp, position: 0.55) else { end(false, "initial_preview_input"); return }
                check.report("initial_preview_input", true)
                check.initialPrepared = true
                return
            }
            guard let initial = stored(), !initial.glass, abs(initial.opacity - 0.45) < 0.01 else { return }
            let drawing = sidebarContainer.lookCheckRendering(reduced: false)
            guard abs(drawing.alpha - 0.45) < 0.01 && abs(drawing.grain - 0.05) < 0.001 else { return }
            guard capture("55") else { end(false, "capture_55"); return }
            if screen { check.report("capture_55", true) }
            check.watchMenu()
            check.menuSending = true
            defer { check.menuSending = false }
            let point = NSPoint(x: menuFrame.midX, y: menuFrame.midY)
            let down = check.event(.leftMouseDown, screen: point, window: popup)
            let up = down && check.event(.leftMouseUp, screen: point, window: popup)
            FileHandle.standardError.write(Data("ararat-trace: look-menu click returned down=\(down) up=\(up)\n".utf8))
            guard down && up else { check.stopWatchingMenu(); end(false, "menu_open"); return }
            end(true, "menu_open")
        case 3:
            guard let items = check.menuItems else { return }
            end(items == ["Use for All Spaces", "Reset Look"], "menu")
        case 4:
            end(check.mouse(.leftMouseDown, position: 0.55) && check.mouse(.leftMouseDragged, position: 1) && check.mouse(.leftMouseDragged, position: 1.03), "drag_detent_input")
        case 5:
            let ok = check.probe?.look?.glass == false && check.probe?.transparencyTag == "100% · Liquid Glass ›"
            guard capture("detent") else { end(false, "capture_detent"); return }
            if screen { check.report("capture_detent", true) }
            end(ok, "detent")
        case 6:
            end(check.mouse(.leftMouseDragged, position: 1.09), "drag_glass_input")
        case 7:
            let ok = check.probe?.look?.glass == true && check.probe?.transparencyTag == "Liquid Glass" && check.probe?.haptics == 1
            guard capture("glass") else { end(false, "capture_glass"); return }
            if screen { check.report("capture_glass", true) }
            end(ok && check.mouse(.leftMouseUp, position: 1.09), "glass")
        case 8:
            guard let look = stored(), look.glass && look.opacity == 0 else { return }
            let rendered = sidebarContainer.lookCheckRendering(reduced: false)
            let glass = if #available(macOS 26, *) { rendered.glass } else { rendered.vibrancy }
            guard glass else { return }
            end(true, "stored_glass")
        case 9:
            end(check.mouse(.leftMouseDown, position: 0.3) && check.mouse(.leftMouseUp, position: 0.3), "thirty_input")
        case 10:
            guard let look = stored(), !look.glass, abs(look.opacity - 0.7) < 0.01 else { return }
            end(check.mouse(.leftMouseDown, position: 1.09) && check.mouse(.leftMouseUp, position: 1.09), "socket_input")
        case 11:
            guard let look = stored(), !look.glass, look.opacity == 0, let count = check.journalCount(quitPath) else { return }
            check.count = count
            guard check.focus("Transparency") else { check.report("keyboard_focus", false); finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return }
            check.phase += 1; browserCheckPhase = check.phase
        case 12:
            guard let sent = LookScreenCheck.sendWhenFocused(check.probe?.hasFocus("Transparency") == true, send: {
                check.report("keyboard_focus", true)
                return check.key(126)
            }) else { return }
            end(sent, "keyboard_up_input")
        case 13:
            guard let look = stored(), look.glass, let count = check.journalCount(quitPath) else { return }
            let one = count == check.count + 1
            check.report("keyboard_glass", one)
            guard one else { finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return }
            check.count = count
            end(check.key(125), "keyboard_down_input")
        case 14:
            guard let look = stored(), !look.glass, look.opacity == 0, let count = check.journalCount(quitPath) else { return }
            let one = count == check.count + 1
            check.report("keyboard_down", one)
            guard one else { finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return }
            check.count = count
            guard check.focus("Grain") else { check.report("grain_focus", false); finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return }
            check.phase += 1; browserCheckPhase = check.phase
        case 15:
            guard let sent = LookScreenCheck.sendWhenFocused(check.probe?.hasFocus("Grain") == true, send: {
                check.report("grain_focus", true)
                return check.key(126)
            }) else { return }
            end(sent, "grain_up_input")
        case 16:
            guard let look = stored(), abs(look.grain - 0.1) < 0.001, let count = check.journalCount(quitPath) else { return }
            let one = count == check.count + 1
            check.report("keyboard_grain", one)
            guard one else { finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return }
            check.count = count
            guard check.focus("Transparency") else { check.report("transparency_focus_return", false); finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return }
            check.phase += 1; browserCheckPhase = check.phase
        case 17:
            guard let sent = LookScreenCheck.sendWhenFocused(check.probe?.hasFocus("Transparency") == true, send: {
                check.report("transparency_focus_return", true)
                return check.key(126)
            }) else { return }
            end(sent, "transparency_up_input")
        case 18:
            guard let look = stored(), look.glass, look.opacity == 0, let count = check.journalCount(quitPath) else { return }
            let rendering = sidebarContainer.lookCheckRendering(reduced: true)
            end(count == check.count + 1 && rendering.vibrancy && !rendering.glass && rendering.grain > 0 && rendering.alpha == 0, "reduced_transparency")
        case 19 where !screen:
            // The grain phases capture the window and measure its pixels, which only screen-look
            // does; a hidden run must not record conditions it never measured (review S2).
            check.phase = 23; browserCheckPhase = 23
        case 19, 20, 21, 22:
            // U24b's grain: one fixed probe at four settings. Each capture's flat-patch sd is the
            // drawn noise's contrast, calibrated by that run's own grain-0 capture (L′), so the
            // conditions hold the drawing to the mock's rule rather than to a hard-coded colour.
            let step = LookScreenCheck.grainSteps[check.phase - 19]
            guard let probe = check.probe else {
                check.report(step.condition, false); finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return
            }
            if check.grainWritten != step.capture {
                if check.phase == 19 { probe.setLook { $0 = LookScreenCheck.probeLook(grain: 0) } }
                else { probe.setLook { $0.grain = step.grain } }
                check.grainWritten = step.capture
                check.wait("\(step.capture)_write", "stored=\(stored().map { "\($0.grain)" } ?? "nil") step=\(step.grain)")
                return
            }
            let rendering = sidebarContainer.lookCheckRendering(reduced: false)
            let drawn = rendering.color
            let drawnColour = drawn.map { "\($0.redComponent),\($0.greenComponent),\($0.blueComponent),\($0.alphaComponent)" } ?? "nil"
            let ready = stored().map { LookScreenCheck.isProbe($0, grain: step.grain) } == true
                && abs(rendering.grain - Float(step.grain)) < 0.001
                && (drawn.map(LookScreenCheck.isProbeColour) ?? false)
                && abs(rendering.alpha - 1) < 0.001
            guard ready else {
                check.wait("\(step.capture)_ready", "stored=\(stored().map { "\($0.grain)" } ?? "nil") grain=\(rendering.grain) alpha=\(rendering.alpha) colour=\(drawnColour)")
                return
            }
            guard captureSidebar(step.capture) else { end(false, step.condition); return }
            guard screen else { end(true, step.condition); return }
            guard let path = check.images["\(step.capture)_sidebar"], let panel = sidebarContainer.panelRectForCheck else {
                check.report(step.condition, false); finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return
            }
            // The band keeps clear of the header (44 pt from the top) and the panel's edges.
            let band = NSRect(x: panel.minX + 8, y: panel.minY + 8, width: max(0, panel.width - 16), height: max(0, panel.height - 52))
            let stats = LookScreenCheck.grainStats(path: path, windowFrame: host.window().frame, panel: band)
            // A band that is not the look is the previous frame (the VM presents coarse or no
            // frames) or something else over the sidebar; both are waited out, then named with the
            // numbers, so a capture of the wrong pixels can never pass as the look.
            guard LookScreenCheck.showsLook(stats) else {
                check.grainTries += 1
                check.grainStats[step.capture] = stats
                check.grainBand = band
                check.wait("\(step.capture)_band", "mean=\(stats.mean) chroma=\(stats.chroma) patches=\(stats.patches) defect=\(stats.defect ?? "") try=\(check.grainTries)")
                guard check.grainTries < LookScreenCheck.grainBandTries else {
                    check.report(step.condition, false); finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return
                }
                return
            }
            check.grainTries = 0
            check.grainStats[step.capture] = stats
            check.grainBand = band
            if let defect = stats.defect { FileHandle.standardError.write(Data("ararat-trace: look grain \(step.capture) defect=\(defect)\n".utf8)) }
            func stats0() -> LookGrainStats { check.grainStats["grain0"] ?? LookGrainStats(defect: "no grain-0 capture") }
            let base = stats0()
            let luminance = base.mean / 255
            let chroma0 = base.chroma
            func expected(_ grain: Double) -> Double { 0.16 * grain * (1 - luminance) * 255 }
            func within(_ value: Double, _ target: Double, _ low: Double, _ high: Double) -> Bool {
                target > 0.01 && value >= low * target && value <= high * target
            }
            switch check.phase {
            case 19:
                check.grainExpected["grain0_mean"] = base.mean
                // The band has to be the probe's own colour, flat: this is what tells the sidebar's
                // body from the editor's popover, a page or the window's background.
                end(base.defect == nil && abs(base.mean - LookScreenCheck.probeMean) <= 8
                    && base.chroma >= 0.85 * LookScreenCheck.probeChroma && base.sd <= 0.5, "grain_0_flat")
            case 20:
                check.grainExpected["grain5_expected"] = expected(0.05)
                end(stats.defect == nil && within(stats.sd, expected(0.05), 0.5, 2.2), "grain_5")
            case 21:
                check.grainExpected["grain50_expected"] = expected(0.5)
                end(stats.defect == nil && within(stats.sd, expected(0.5), 0.70, 1.40), "grain_50")
            default:
                check.grainExpected["grain100_expected"] = expected(1)
                let sd100 = stats.sd
                let sd50 = check.grainStats["grain50"]?.sd ?? 0
                let sd5 = check.grainStats["grain5"]?.sd ?? 0
                check.report("grain_100", stats.defect == nil && within(sd100, expected(1), 0.70, 1.40))
                check.report("grain_100_keeps_colour", stats.defect == nil && chroma0 > 1 && stats.chroma >= 0.55 * chroma0)
                check.report("grain_never_darkens", LookScreenCheck.grainSteps.allSatisfy { (check.grainStats[$0.capture]?.mean ?? 0) >= base.mean - 1 })
                check.report("grain_linear", sd100 > 0.01 && (0.40...0.60).contains(sd50 / sd100) && (0.02...0.09).contains(sd5 / sd100))
                let failed = ["grain_100", "grain_100_keeps_colour", "grain_never_darkens", "grain_linear"].filter { check.conditions[$0] != true }
                if failed.isEmpty { check.phase = 23; browserCheckPhase = 23 }
                else { finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)) }
            }
        case 23:
            // U24 part 2 pass B, the polar picker. A fixed two-colour split look on one radius (the
            // probe look is written through the editor's commit path), then phase 24 turns the first
            // handle a quarter turn outward. The drag must turn the whole group, set the shared
            // radius from the pointer, preview the sidebar while the button is down, and write once
            // on release.
            guard let probe = check.probe else {
                check.report("picker_write", false); finishBrowserCheck(ok: false, values: lookCheckDiagnostics(screen: screen)); return
            }
            if !check.pickerWritten {
                // The journal count before the write, so the drag's "no write" and the release's
                // "one write" are both counted from a row this check has seen (the engine lands the
                // store change and its journal row together, but not necessarily in this tick).
                guard let before = check.journalCount(quitPath) else { return }
                check.count = before
                probe.setLook { look in
                    look.colors = [LookCheckProbe.colour(x: 0.4, y: 0.5), LookCheckProbe.colour(x: 0.9, y: 0.5)]
                    look.opacity = 1
                    look.grain = 0
                    look.glass = false
                    look.appearance = .light
                }
                check.pickerWritten = true
                check.wait("picker_write", "stored=\(stored().map { "\($0.colors.count) colours" } ?? "nil") count=\(before)")
                return
            }
            guard let look = stored(), probe.look == look, look.colors.count == 2,
                  abs(look.colors[0].x - 0.4) < 0.001, abs(look.colors[1].x - 0.9) < 0.001 else {
                check.wait("picker_stored", "stored=\(stored().map { "\($0.colors.map(\.x))" } ?? "nil") probe=\(String(describing: probe.look?.colors.map(\.x)))")
                return
            }
            guard let count = check.journalCount(quitPath) else { return }
            guard count > check.count else {
                check.wait("picker_journal", "count=\(count) expected=\(check.count + 1)")
                return
            }
            check.count = count
            end(true, "picker_write")
        case 24:
            guard let probe = check.probe, let look = probe.look, look.colors.count == 2, let window = probe.window,
                  let from = probe.fieldPoint(x: look.colors[0].x, y: look.colors[0].y),
                  let target = probe.fieldPoint(hue: 0.65, radius: 80) else {
                check.wait("picker_points", "frame=\(String(describing: check.probe?.fieldFrame))")
                return
            }
            let down = check.event(.leftMouseDown, screen: from, window: window)
            let start = down && check.event(.leftMouseDragged, screen: from, window: window)
            let drag = start && check.event(.leftMouseDragged, screen: target, window: window)
            end(drag, "picker_input")
        case 25:
            guard let probe = check.probe, let look = probe.look, look.colors.count == 2 else {
                check.wait("picker_model", "look=\(String(describing: check.probe?.look?.colors.count))"); return
            }
            let shared = LookCheckProbe.storedY(radius: 80)
            let turned = abs(look.colors[0].x - 0.65) < 0.005 && abs(look.colors[1].x - 0.15) < 0.005
                && look.colors.allSatisfy { abs($0.y - shared) < 0.005 }
            let noWrite = (check.journalCount(quitPath) ?? -1) == check.count
            let previewed = sidebarContainer.lookPreviewForCheck == look
            // Why the preview is read before the release: the up ends the editor's gesture, which
            // clears `editing` and commits the look, so read after it the preview is always gone
            // (the first VM run failed exactly here, with the drag itself correct).
            let editing = probe.editing
            let up = probe.window.flatMap { window in
                probe.fieldPoint(hue: 0.65, radius: 80).map { check.event(.leftMouseUp, screen: $0, window: window) }
            } ?? false
            end(turned && noWrite && previewed && editing && up, "picker_preview")
        case 26:
            guard let probe = check.probe, let model = probe.look, !probe.editing else {
                check.wait("picker_release", "editing=\(String(describing: check.probe?.editing))"); return
            }
            guard let committed = stored(), committed == model, let count = check.journalCount(quitPath) else {
                check.wait("picker_commit", "stored=\(stored().map { "\($0.colors.map(\.x))" } ?? "nil") count=\(check.journalCount(quitPath) ?? -1) expected=\(check.count + 1)")
                return
            }
            end(count == check.count + 1, "picker_one_write")
        case 27:
            // A passing run carries the measured numbers too (pass A's review S1): the VM reads
            // grain_stats, grain_expected, grain_band and wait back from the diagnostics.
            finishBrowserCheck(ok: true, values: lookCheckDiagnostics(screen: screen))
        default: break
        }
    }
}
