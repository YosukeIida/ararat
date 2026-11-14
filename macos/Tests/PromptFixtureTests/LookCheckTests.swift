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
    let expected: Set<String> = ["open", "initial_preview_input", "menu_open", "menu", "drag_detent_input", "detent", "drag_glass_input", "glass", "stored_glass", "thirty_input", "socket_input", "keyboard_focus", "keyboard_up_input", "keyboard_glass", "keyboard_down_input", "keyboard_down", "grain_focus", "grain_up_input", "keyboard_grain", "transparency_focus_return", "transparency_up_input", "reduced_transparency", "picker_write", "picker_input", "picker_preview", "picker_one_write"]
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

@Test @MainActor
func grainStatsReadsTheSidebarBandAndIgnoresThePage() throws {
    // A 200 x 120 pt window at 2x: the sidebar's band on the left, a page with text on the right.
    // The sidebar is (51, 77, 153) with a one-pixel checker of +10, so its flat patches have
    // sd 5 and mean 98.67 code values; the page is white with a black band, which must not win.
    let width = 400, height = 240
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4, bitsPerPixel: 32))
    let bytes = try #require(rep.bitmapData)
    for y in 0..<height {
        for x in 0..<width {
            let index = (y * width + x) * 4
            let sidebar = x < 160
            let bright = sidebar && (x + y) % 2 == 0 ? 10 : 0
            let colour: (Int, Int, Int) = sidebar ? (51 + bright, 77 + bright, 153 + bright) : (y % 40 < 12 ? (0, 0, 0) : (255, 255, 255))
            bytes[index] = UInt8(colour.0)
            bytes[index + 1] = UInt8(colour.1)
            bytes[index + 2] = UInt8(colour.2)
            bytes[index + 3] = 255
        }
    }
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ararat-grain-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: url) }
    try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    // The sidebar is the left 80 pt; only its middle band is measured, as the check insets it.
    let stats = LookScreenCheck.grainStats(path: url.path, windowFrame: NSRect(x: 0, y: 0, width: 200, height: 120),
                                           panel: NSRect(x: 8, y: 8, width: 64, height: 52))
    #expect(stats.defect == nil)
    #expect(abs(stats.mean - (98.67)) < 1.5)
    #expect(abs(stats.sd - 5) < 1)
    #expect(abs(stats.chroma - 102) < 3)
    #expect(stats.patches > 20)
}

@Test @MainActor
func grainStatsReportsABandOutsideTheCapture() {
    let stats = LookScreenCheck.grainStats(path: "/nonexistent/capture.png", windowFrame: NSRect(x: 0, y: 0, width: 200, height: 120),
                                           panel: NSRect(x: 8, y: 8, width: 64, height: 52))
    #expect(stats.defect != nil)
    #expect(stats.sd == 0)
}

@Test @MainActor
func grainBandAcceptsTheLookAndRejectsWhatSitsOverIt() {
    // The first VM run's own numbers: the band measured the Look editor's popover (its child window
    // is composited into the browser window's capture), mean 220 and chroma 5, as if it were the
    // look's flat patch. Nothing but the look may pass the gate.
    #expect(!LookScreenCheck.showsLook(LookGrainStats(sd: 0.0004, mean: 220, chroma: 5.2, patches: 327, defect: nil)))
    #expect(!LookScreenCheck.showsLook(LookGrainStats(sd: 0, mean: 255, chroma: 0, patches: 400, defect: nil)))
    #expect(!LookScreenCheck.showsLook(LookGrainStats(sd: 0, mean: 0, chroma: 0, patches: 400, defect: nil)))
    #expect(!LookScreenCheck.showsLook(LookGrainStats(defect: "capture unreadable")))
    // Slate as the capture reads it, then the mock's grain over it at 5, 50 and 100 %: the mean
    // rises by 0.35·(255 − L′)·g and the chroma keeps most of its 89.
    #expect(LookScreenCheck.showsLook(LookGrainStats(sd: 0, mean: 38.67, chroma: 89, patches: 1523, defect: nil)))
    #expect(LookScreenCheck.showsLook(LookGrainStats(sd: 1.73, mean: 42.5, chroma: 87.5, patches: 1400, defect: nil)))
    #expect(LookScreenCheck.showsLook(LookGrainStats(sd: 17.3, mean: 76.5, chroma: 75, patches: 1400, defect: nil)))
    #expect(LookScreenCheck.showsLook(LookGrainStats(sd: 34.6, mean: 114.3, chroma: 60, patches: 1400, defect: nil)))
}
