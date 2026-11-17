import AppKit
import AraratKit
import AraratUI

enum SettingsATCInput {
    static let conditions = ["post_permission", "new_route", "draft_not_stored", "rule_clean",
                             "row_destination", "default_stored", "default_routes", "command_bar_ime"]

    @MainActor
    static func menuItemIndex(in menu: NSMenu, title: String) -> Int? {
        menu.items.firstIndex { $0.title == title && $0.isEnabled && !$0.isHidden && !$0.isSeparatorItem }
    }

    static func events(code: CGKeyCode, text: String? = nil) -> [CGEvent]? {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { return nil }
        if let text, !text.isEmpty {
            let utf16 = Array(text.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
            }
        }
        return [down, up]
    }
}

extension SettingsScreenCheck {
    func watchAirTrafficRowMenuEnd(_ menu: NSMenu) {
        if let airTrafficRowMenuEndObserver { NotificationCenter.default.removeObserver(airTrafficRowMenuEndObserver) }
        airTrafficRowMenuTracking = true
        airTrafficRowMenuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification, object: menu, queue: nil
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.airTrafficRowMenuTracking = false
                self.traceAirTrafficMenu("row menu tracking ended", menu: notification.object as? NSMenu)
                if let observer = self.airTrafficRowMenuEndObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.airTrafficRowMenuEndObserver = nil
                }
            }
        }
    }

    func traceAirTrafficMenu(_ event: String, menu: NSMenu? = nil, values: [String: Any] = [:]) {
        guard (8...10).contains(phase) else { return }
        var entry = values
        entry["phase"] = phase
        entry["event"] = event
        if let menu {
            entry["menu_title"] = menu.title
            entry["items"] = menu.items.enumerated().map { index, item in
                ["index": index, "title": item.title, "enabled": item.isEnabled,
                 "hidden": item.isHidden, "separator": item.isSeparatorItem,
                 "selected": item.state == .on, "state": item.state.rawValue,
                 "highlighted": menu.highlightedItem === item] as [String: Any]
            }
        }
        var entries = details["atc_menu_trace"] as? [[String: Any]] ?? []
        entries.append(entry)
        details["atc_menu_trace"] = entries
        if let data = try? JSONSerialization.data(withJSONObject: ["atc_menu_trace": entry], options: [.sortedKeys]) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }

    func startAirTrafficMenuTrace() {
        guard airTrafficMenuTraceObserver == nil else { return }
        airTrafficMenuTraceObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                self?.traceAirTrafficMenu("tracking began", menu: menu)
            }
        }
    }

    func watchAirTrafficMenu(title: String) {
        stopWatchingAirTrafficMenu()
        let waitingPhase = phase
        airTrafficMenuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let menu = notification.object as? NSMenu else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.phase == waitingPhase else {
                    self.traceAirTrafficMenu("observer not matched", menu: menu,
                        values: ["reason": "phase changed", "waiting_phase": waitingPhase, "expected_title": title])
                    return
                }
                guard let index = SettingsATCInput.menuItemIndex(in: menu, title: title) else {
                    self.traceAirTrafficMenu("observer not matched", menu: menu,
                        values: ["reason": menu.items.contains { $0.title == title }
                            ? "exact title exists but is disabled, hidden, or a separator" : "no exact title",
                            "expected_title": title])
                    return
                }
                self.traceAirTrafficMenu("observer matched", menu: menu,
                    values: ["reason": "exact visible enabled item", "selected_index": index, "expected_title": title])
                if waitingPhase == 7 { self.watchAirTrafficRowMenuEnd(menu) }
                self.stopWatchingAirTrafficMenu()
                // Why not act in the notification: tracking has not entered its run loop yet.
                RunLoop.main.perform(inModes: [.eventTracking]) { [weak self, weak menu] in
                    MainActor.assumeIsolated {
                        guard let self, let menu else { return }
                        guard self.phase == waitingPhase else {
                            self.traceAirTrafficMenu("action skipped", menu: menu, values: ["reason": "phase changed"])
                            return
                        }
                        self.traceAirTrafficMenu("perform action", menu: menu, values: ["selected_index": index])
                        menu.performActionForItem(at: index)
                        self.traceAirTrafficMenu("action returned", menu: menu, values: ["selected_index": index])
                        menu.cancelTracking()
                        self.phase = waitingPhase + 1
                    }
                }
            }
        }
    }

    func stopWatchingAirTrafficMenu() {
        if let airTrafficMenuObserver {
            NotificationCenter.default.removeObserver(airTrafficMenuObserver)
            self.airTrafficMenuObserver = nil
        }
    }
}

extension Runtime {
    func settingsAirTrafficTick(_ probe: SettingsCheckProbe, check: SettingsScreenCheck,
                               note: (String) -> Void, step: (Int) -> Void, end: (String, Bool) -> Void,
                               finish: () -> Void, capture: (String) -> Bool) {
        guard let session = adapter?.session, let settings = (root ?? self).settings,
              let window = settings.window else { return }
        func post(_ code: CGKeyCode, _ text: String? = nil) -> Bool {
            guard let events = SettingsATCInput.events(code: code, text: text) else { return false }
            for event in events { event.post(tap: .cghidEventTap) }
            return true
        }
        func press(_ role: NSAccessibility.Role, _ label: String) -> Bool {
            check.details["atc_control_input"] = "window-server clicks at NSView markers; NSMenu action during tracking"
            let pressed = probe.pressAirTrafficElement(role: role, label: label) { values in
                var values = values
                values["row_menu_tracking"] = check.airTrafficRowMenuTracking as Any? ?? NSNull()
                check.traceAirTrafficMenu("control press geometry", values: values)
            }
            if !pressed {
                check.details["atc_ax_tree"] = probe.airTrafficAccessibilityTree
                note("control input missing role=\(role.rawValue) label=\(label)")
            }
            return pressed
        }
        let routing = session.queue.sync { session.store?.routing() }
        switch check.phase {
        case 2:
            guard probe.marker(SettingsModel.rowMarker(SettingsModel.airTrafficCardId)) != nil,
                  probe.marker(SettingsModel.rowMarker("atc-test")) != nil else { note("ATC layout"); return }
            check.report("rows", true)
            guard CGPreflightPostEventAccess() else { end("post_permission", false); return }
            check.report("post_permission", true)
            guard capture("settings-air-traffic") else { end("capture", false); return }
            guard routing?.rules.isEmpty == true else { end("draft_not_stored", false); return }
            guard press(.button, "New Route") else { return }
            step(3)
        case 3:
            guard probe.airTrafficRules.count == 1 else { note("new route row"); return }
            check.report("new_route", true)
            check.report("draft_not_stored", routing?.rules.isEmpty == true)
            guard probe.focusAirTrafficURL() else { note("URL focus"); return }
            step(4)
        case 4:
            guard window.isKeyWindow, window.firstResponder is NSTextView else { note("URL editor first responder"); return }
            guard post(0, "example."), post(102, "\u{10}"), post(0, "com") else { end("rule_clean", false); return }
            step(5)
        case 5:
            guard let text = probe.airTrafficURLText else { note("posted URL text"); return }
            check.details["atc_typed_scalars"] = text.unicodeScalars.map { Int($0.value) }
            guard text.hasSuffix("com") else { note("posted URL suffix"); return }
            guard text == "example.com" else { end("rule_clean", false); return }
            guard post(36) else { end("rule_clean", false); return }
            step(6)
        case 6:
            guard probe.airTrafficRules.first?.conditions.first?.text == "example.com" else {
                note("Return commits the URL"); return
            }
            step(7)
            check.watchAirTrafficMenu(title: "Most Recent Space")
            if !press(.popUpButton, "Route 1 destination") {
                check.stopWatchingAirTrafficMenu()
                step(6)
            }
        case 7:
            note("row destination menu action")
        case 8:
            check.startAirTrafficMenuTrace()
            guard check.airTrafficRowMenuTracking == false else { note("row menu tracking ended"); return }
            guard let rule = routing?.rules.first, rule.destination == .space(.mostRecent) else { note("row destination stored"); return }
            check.report("rule_clean", rule.conditions.first?.text == "example.com")
            check.report("row_destination", true)
            step(9)
            guard capture("settings-air-traffic-default-before-press") else { end("capture", false); return }
            check.watchAirTrafficMenu(title: "Most Recent Space")
            let pressed = press(.popUpButton, "Default destination")
            check.traceAirTrafficMenu("default popup press", values: ["pressed": pressed])
            if !pressed {
                check.stopWatchingAirTrafficMenu()
                step(8)
            }
        case 9:
            note("default destination menu action")
        case 10:
            guard routing?.default == .space(.mostRecent) else { note("default destination stored"); return }
            check.report("default_stored", true)
            let decision = session.queue.sync { session.store?.route(url: "https://atc-unmatched.test/") }
            let resolved = decision.flatMap { Self.externalDestination($0.destination, snapshot: snapshot) }
            guard let shown = snapshot.spaces.first(where: { $0.id == snapshot.shownSpaceId }) else { end("default_routes", false); return }
            guard decision?.ruleId == nil, resolved == .space(shown.id, shown.profileName) else { end("default_routes", false); return }
            check.details["atc_expected_space"] = shown.id
            (root ?? self).openURLs([("https://atc-unmatched.test/", false)])
            step(11)
        case 11:
            guard snapshot.shownSpaceId == (check.details["atc_expected_space"] as? String),
                  let selected = snapshot.spaces.flatMap(\.today).first(where: { $0.id == snapshot.selectedId }),
                  selected.url == "https://atc-unmatched.test/", host?.activeItemId() == selected.id else {
                note("non-matching link in Most Recent space"); return
            }
            check.report("default_routes", true)
            window.close()
            host?.window().makeKeyAndOrderFront(nil)
            openCommandBar(.newTab)
            step(12)
        case 12:
            guard let presenter = commandPresenter, presenter.controller.isOpen, presenter.panel.isKeyWindow,
                  presenter.panel.firstResponder is NSTextView else { note("command bar editor"); return }
            guard post(102, "\u{10}"), post(0, "abc") else { end("command_bar_ime", false); return }
            step(13)
        case 13:
            guard let presenter = commandPresenter else { end("command_bar_ime", false); return }
            let text = (presenter.view.field.currentEditor() as? NSTextView)?.string ?? presenter.view.field.stringValue
            guard !text.isEmpty else { note("command bar posted text"); return }
            check.details["atc_command_bar_scalars"] = text.unicodeScalars.map { Int($0.value) }
            check.report("command_bar_ime", text == "abc")
            presenter.controller.close()
            finish()
        default:
            end("rule_clean", false)
        }
    }
}
