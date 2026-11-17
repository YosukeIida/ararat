import AppKit
import AraratKit
import AraratUI

enum SettingsATCInput {
    static let conditions = ["post_permission", "new_route", "draft_not_stored", "rule_clean",
                             "row_destination", "default_stored", "default_routes", "command_bar_ime"]

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
            let pressed = probe.pressAirTrafficElement(role: role, label: label)
            if !pressed {
                check.details["atc_ax_tree"] = probe.airTrafficAccessibilityTree
                note("AXPress missing role=\(role.rawValue) label=\(label)")
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
            if !press(.popUpButton, "Route 1 destination") { step(6) }
        case 7:
            guard press(.menuItem, "Most Recent Space") else { return }
            step(8)
        case 8:
            guard let rule = routing?.rules.first, rule.destination == .space(.mostRecent) else { note("row destination stored"); return }
            check.report("rule_clean", rule.conditions.first?.text == "example.com")
            check.report("row_destination", true)
            step(9)
            if !press(.popUpButton, "Default destination") { step(8) }
        case 9:
            guard press(.menuItem, "Most Recent Space") else { return }
            step(10)
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
