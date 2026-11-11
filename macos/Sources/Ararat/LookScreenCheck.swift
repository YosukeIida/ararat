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
    var initialPrepared = false
    var count = 0

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
        guard let control = element("Transparency") else { return nil }
        let frame = control.accessibilityFrame()
        guard frame.width > 32 && frame.height >= 30 else { return nil }
        return NSPoint(x: frame.minX + (frame.width - 32) * value, y: frame.minY + 15)
    }
    func mouse(_ type: NSEvent.EventType, position: Double) -> Bool {
        guard let point = trackPoint(position), let window = probe?.window else { return false }
        return event(type, screen: point, window: window)
    }
    func key(_ code: UInt16) -> Bool {
        guard let window = probe?.window else { return false }
        let character = String(UnicodeScalar(code == 126 ? NSUpArrowFunctionKey : NSDownArrowFunctionKey)!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { return false }
        window.sendEvent(event)
        return true
    }
    func focus(_ label: String) -> Bool {
        guard let control = element(label) else { return false }
        control.setAccessibilityFocused(true)
        return control.isAccessibilityFocused()
    }
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
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] note in
            guard let menu = note.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                self?.menuItems = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
                menu.cancelTracking()
            }
        }
    }
    deinit { if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) } }
}

extension Runtime {
    func lookCheckTick(_ host: any ARWindowHostAPI, screen: Bool) {
        if lookCheck == nil { lookCheck = LookScreenCheck() }
        guard let check = lookCheck, let sidebarContainer = container, let session = adapter?.session else { return }
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
            if !ok { finishBrowserCheck(ok: false, values: ["conditions": check.conditions, "failed_conditions": [name], "images": check.images]) }
            else { check.phase += 1; browserCheckPhase = check.phase }
        }
        switch check.phase {
        case 0:
            guard snapshot.shownSpaceId != nil, snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) != nil else { return }
            openSettings()
            (root ?? self).settings?.open(shownSpaceID: snapshot.shownSpaceId)
            check.phase = 1; browserCheckPhase = 1
        case 1:
            guard let settings = (root ?? self).settings, let probe = settings.openLookForCheck(), probe.window != nil else { return }
            check.probe = probe
            end(true, "open")
        case 2:
            guard let popup = check.probe?.window else { return }
            let all = check.elements(popup)
            let transparency = all.filter { $0.accessibilityLabel() == "Transparency" }
            let grain = all.filter { $0.accessibilityLabel() == "Grain" }
            let valid = transparency.count == 1 && grain.count == 1 && (transparency.first?.accessibilityValue() as? String) == "55 percent" && (grain.first?.accessibilityValue() as? String) == "5 percent"
            guard valid else { end(false, "accessibility"); return }
            if !check.initialPrepared {
                guard check.mouse(.leftMouseDown, position: 0.54), check.mouse(.leftMouseDragged, position: 0.55), check.mouse(.leftMouseUp, position: 0.55) else { end(false, "initial_preview_input"); return }
                check.initialPrepared = true
                return
            }
            guard let initial = stored(), !initial.glass, abs(initial.opacity - 0.45) < 0.01 else { return }
            let drawing = sidebarContainer.lookCheckRendering(reduced: false)
            guard abs(drawing.alpha - 0.45) < 0.01 && abs(drawing.grain - 0.05) < 0.001 else { return }
            guard capture("55") else { end(false, "capture_55"); return }
            check.watchMenu()
            guard let menu = check.element("Look options"), menu.accessibilityPerformPress() else { end(false, "menu_open"); return }
            end(check.menuItems == ["Use for All Spaces", "Reset Look"], "menu")
        case 3:
            end(check.mouse(.leftMouseDown, position: 0.55) && check.mouse(.leftMouseDragged, position: 1) && check.mouse(.leftMouseDragged, position: 1.03), "drag_detent_input")
        case 4:
            let ok = check.probe?.look?.glass == false && check.probe?.transparencyTag == "100% · Liquid Glass ›"
            guard capture("detent") else { end(false, "capture_detent"); return }
            end(ok, "detent")
        case 5:
            end(check.mouse(.leftMouseDragged, position: 1.09), "drag_glass_input")
        case 6:
            let ok = check.probe?.look?.glass == true && check.probe?.transparencyTag == "Liquid Glass" && check.probe?.haptics == 1
            guard capture("glass") else { end(false, "capture_glass"); return }
            end(ok && check.mouse(.leftMouseUp, position: 1.09), "glass")
        case 7:
            guard let look = stored(), look.glass && look.opacity == 0 else { return }
            let rendered = sidebarContainer.lookCheckRendering(reduced: false)
            let glass = if #available(macOS 26, *) { rendered.glass } else { rendered.vibrancy }
            guard glass else { return }
            end(true, "stored_glass")
        case 8:
            end(check.mouse(.leftMouseDown, position: 0.3) && check.mouse(.leftMouseUp, position: 0.3), "thirty_input")
        case 9:
            guard let look = stored(), !look.glass, abs(look.opacity - 0.7) < 0.01 else { return }
            end(check.mouse(.leftMouseDown, position: 1.09) && check.mouse(.leftMouseUp, position: 1.09), "socket_input")
        case 10:
            guard let look = stored(), !look.glass, look.opacity == 0, let count = check.journalCount(quitPath) else { return }
            check.count = count
            end(check.focus("Transparency") && check.key(126), "keyboard_up_input")
        case 11:
            guard let look = stored(), look.glass, let count = check.journalCount(quitPath) else { return }
            let one = count == check.count + 1
            check.count = count
            end(one && check.key(125), "keyboard_glass")
        case 12:
            guard let look = stored(), !look.glass, look.opacity == 0, let count = check.journalCount(quitPath) else { return }
            let one = count == check.count + 1
            check.count = count
            end(one && check.focus("Grain") && check.key(126), "keyboard_down")
        case 13:
            guard let look = stored(), abs(look.grain - 0.1) < 0.001, let count = check.journalCount(quitPath) else { return }
            let one = count == check.count + 1
            check.count = count
            end(one && check.focus("Transparency") && check.key(126), "keyboard_grain")
        case 14:
            guard let look = stored(), look.glass, look.opacity == 0, let count = check.journalCount(quitPath) else { return }
            let rendering = sidebarContainer.lookCheckRendering(reduced: true)
            end(count == check.count + 1 && rendering.vibrancy && !rendering.glass && rendering.grain > 0 && rendering.alpha == 0, "reduced_transparency")
        case 15:
            end(check.element("Transparency")?.accessibilityPerformDecrement() == true, "ax_transparency_input")
        case 16:
            guard let look = stored(), !look.glass, look.opacity == 0 else { return }
            end(check.element("Grain")?.accessibilityPerformIncrement() == true, "ax_grain_input")
        case 17:
            guard let look = stored(), abs(look.grain - 0.15) < 0.001 else { return }
            end(true, "adjustable_elements")
        case 18:
            finishBrowserCheck(ok: true, values: ["conditions": check.conditions, "failed_conditions": [], "images": check.images])
        default: break
        }
    }
}
