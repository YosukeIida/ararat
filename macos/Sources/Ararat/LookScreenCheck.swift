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

    static func conditionNames(screen: Bool) -> [String] {
        ["open", "initial_preview_input", "menu_open", "menu", "drag_detent_input", "detent", "drag_glass_input", "glass", "stored_glass", "thirty_input", "socket_input", "keyboard_focus", "keyboard_up_input", "keyboard_glass", "keyboard_down_input", "keyboard_down", "grain_focus", "grain_up_input", "keyboard_grain", "transparency_focus_return", "transparency_up_input", "reduced_transparency"] + (screen ? ["capture_55", "capture_detent", "capture_glass"] : [])
    }
    static func conditionResults(_ conditions: [String: Bool], screen: Bool) -> (values: [String: Bool], failed: [String]) {
        let names = conditionNames(screen: screen)
        return (Dictionary(uniqueKeysWithValues: names.map { ($0, conditions[$0] == true) }), names.filter { conditions[$0] != true })
    }
    static func lookFields(_ look: Look?) -> Any {
        guard let look else { return NSNull() }
        return ["opacity": look.opacity, "grain": look.grain, "glass": look.glass, "appearance": String(describing: look.appearance), "colors": look.colors.map { ["red": $0.red, "green": $0.green, "blue": $0.blue, "x": $0.x, "y": $0.y] }] as [String: Any]
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
            "popover_visible": window?.isVisible as Any? ?? NSNull(),
            "popover_key": window?.isKeyWindow as Any? ?? NSNull(),
            "settings_key": (root ?? self).settings?.window?.isKeyWindow as Any? ?? NSNull(),
            "app_active": NSApp.isActive,
            "first_responder": window?.firstResponder.map { NSStringFromClass(type(of: $0)) } as Any? ?? NSNull(),
            "ax_elements": ax,
            "transparency_frame": check?.element("Transparency").map { rectFields($0.accessibilityFrame()) } as Any? ?? NSNull(),
            "track_frame": check?.probe?.trackFrame.map { rectFields($0) } as Any? ?? NSNull(),
            "track_point_100": point.map { ["x": $0.x, "y": $0.y] } as Any? ?? NSNull(),
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
        case 19:
            finishBrowserCheck(ok: true, values: ["conditions": check.conditions, "failed_conditions": [], "images": check.images])
        default: break
        }
    }
}
