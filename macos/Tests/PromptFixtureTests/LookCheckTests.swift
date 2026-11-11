import AppKit
import Testing
@testable import Ararat

@Test @MainActor
func lookConditionResultsListMissingAndFailedConditions() {
    let result = LookScreenCheck.conditionResults(["open": true, "menu": false], screen: false)
    #expect(result.values["open"] == true)
    #expect(result.values["menu"] == false)
    #expect(result.failed.contains("menu") && result.failed.contains("keyboard_focus"))
    #expect(!result.failed.contains("open") && !result.failed.contains("capture_55"))
    let expected: Set<String> = ["open", "initial_preview_input", "menu_open", "menu", "drag_detent_input", "detent", "drag_glass_input", "glass", "stored_glass", "thirty_input", "socket_input", "keyboard_focus", "keyboard_up_input", "keyboard_glass", "keyboard_down_input", "keyboard_down", "grain_focus", "grain_up_input", "keyboard_grain", "transparency_focus_return", "transparency_up_input", "reduced_transparency"]
    #expect(Set(result.values.keys) == expected)
    for name in ["accessibility", "adjustable_elements", "ax_transparency_input", "ax_grain_input"] {
        #expect(result.values[name] == nil)
    }
    let screen = LookScreenCheck.conditionResults([:], screen: true)
    #expect(screen.failed.contains("capture_55") && screen.failed.contains("capture_detent") && screen.failed.contains("capture_glass"))
}

@Test @MainActor
func lookMenuObserverStopsAfterCapturingTheFirstMenu() {
    _ = NSApplication.shared
    let check = LookScreenCheck()
    let menu = NSMenu()
    menu.addItem(withTitle: "Use for All Spaces", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "Reset Look", action: nil, keyEquivalent: "")
    check.watchMenu()
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
    #expect(check.menuItems == ["Use for All Spaces", "Reset Look"])
    #expect(check.menuObserver == nil)
    let other = NSMenu()
    other.addItem(withTitle: "Other", action: nil, keyEquivalent: "")
    NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: other)
    #expect(check.menuItems == ["Use for All Spaces", "Reset Look"])
}

@Test @MainActor
func successfulKeyboardWriteRemainsRecordedWhenNextFocusFails() {
    let check = LookScreenCheck()
    check.report("keyboard_down", true)
    check.report("grain_focus", false)
    let result = LookScreenCheck.conditionResults(check.conditions, screen: false)
    #expect(result.values["keyboard_down"] == true)
    #expect(result.values["grain_focus"] == false)
    #expect(!result.failed.contains("keyboard_down"))
    #expect(result.failed.contains("grain_focus"))
    #expect(result.failed.contains("grain_up_input"))
}

@Test @MainActor
func lookCheckSendsKeysOnlyAfterFocusArrives() {
    var sends = 0
    let pending = LookScreenCheck.sendWhenFocused(false) { sends += 1; return true }
    #expect(pending == nil && sends == 0)
    let sent = LookScreenCheck.sendWhenFocused(true) { sends += 1; return true }
    #expect(sent == true && sends == 1)
}

@MainActor
private final class LookMenuRunLoopFixture {
    let menu = NSMenu()
}

@Test @MainActor
func lookMenuCancelsFromEventTrackingRunLoop() {
    _ = NSApplication.shared
    let check = LookScreenCheck()
    let fixture = LookMenuRunLoopFixture()
    let menu = fixture.menu
    menu.addItem(withTitle: "Use for All Spaces", action: nil, keyEquivalent: "")
    menu.addItem(withTitle: "Reset Look", action: nil, keyEquivalent: "")
    var cancelled = 0
    check.cancelMenu = { observed in
        #expect(observed === menu)
        cancelled += 1
    }
    check.watchMenu()
    RunLoop.main.perform(inModes: [.eventTracking]) {
        MainActor.assumeIsolated {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: fixture.menu)
            #expect(check.menuItems == ["Use for All Spaces", "Reset Look"])
            #expect(check.menuObserver == nil && cancelled == 0)
        }
    }
    let deadline = Date(timeIntervalSinceNow: 1)
    while cancelled == 0 && Date() < deadline {
        RunLoop.main.run(mode: .eventTracking, before: deadline)
    }
    #expect(cancelled == 1)
}
