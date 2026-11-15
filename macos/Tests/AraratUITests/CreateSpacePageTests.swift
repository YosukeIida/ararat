import AppKit
import Testing
@testable import AraratUI

/// P4 item 6: the owner's Return in Create a Space did nothing but grey the button, because the
/// app never answered the page. The page itself must refuse a second press while the core has
/// not answered, whatever the app does with the first.
@Test @MainActor
func createSpacePageSubmitsOncePerPress() throws {
    _ = NSApplication.shared
    let view = CreateSpaceView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    view.active = true
    view.begin(profileName: "Default")
    var calls: [String] = []
    view.onCreate = { calls.append($0) }
    view.checkType("Research")
    #expect(view.checkState.buttonEnabled)
    #expect(view.checkSubmit())
    #expect(!view.checkSubmit())
    #expect(calls == ["Research"])
    #expect(view.checkState.submitting)
    #expect(!view.checkState.buttonEnabled)
    // A refused creation re-enables the page with the mock's line, and the next press submits
    // again — nothing is stuck.
    view.finish(error: "The space couldn’t be created. Try again.")
    #expect(!view.checkState.submitting && view.checkState.buttonEnabled)
    #expect(view.checkState.errorShown)
    #expect(view.checkSubmit())
    #expect(calls == ["Research", "Research"])
}

@Test @MainActor
func createSpacePageRefusesAnEmptyName() {
    _ = NSApplication.shared
    let view = CreateSpaceView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    view.active = true
    view.begin(profileName: "Default")
    var calls: [String] = []
    view.onCreate = { calls.append($0) }
    view.checkType("   ")
    #expect(!view.checkState.buttonEnabled)
    #expect(!view.checkSubmit())
    #expect(calls.isEmpty)
    view.checkType(" Work ")
    #expect(view.checkSubmit())
    #expect(calls == ["Work"])
}
