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
