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

/// The mock's state 4: while the core runs, the button keeps the disabled fill and shows a small
/// spinner 7 pt before "Creating…", and Cancel is disabled too — cancelling is not supported by
/// the creation path, so an enabled Cancel would offer a press that does nothing. Both exits
/// (`finish`, on success and on failure) put the form back.
@Test @MainActor
func createSpacePageDrawsTheCreatingState() throws {
    _ = NSApplication.shared
    let view = CreateSpaceView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    view.active = true
    view.begin(profileName: "Default")
    view.onCreate = { _ in }
    view.checkType("Research")
    #expect(view.checkCreating.title == "Create Space")
    #expect(!view.checkCreating.spinnerShown)
    #expect(view.checkCreating.cancelEnabled)
    #expect(view.checkSubmit())
    #expect(view.checkCreating.title == "Creating…")
    #expect(view.checkCreating.spinnerShown)
    #expect(!view.checkCreating.cancelEnabled)
    #expect(!view.checkState.buttonEnabled)
    view.layoutSubtreeIfNeeded()
    let button = try #require(view.subviews.compactMap { $0 as? SidebarDockButton }.first { $0.accessibilityLabel() == "Create Space" })
    let spinner = try #require(button.subviews.compactMap { $0 as? NSProgressIndicator }.first)
    #expect(spinner.frame.width == SidebarMetrics.createSpaceSpinnerSize)
    #expect(spinner.frame.height == SidebarMetrics.createSpaceSpinnerSize)
    let titleWidth = ("Creating…" as NSString).size(withAttributes: [.font: button.font ?? .systemFont(ofSize: SidebarMetrics.createSpaceBodySize)]).width
    #expect(abs(spinner.frame.maxX + SidebarMetrics.createSpaceSpinnerGap - (button.bounds.midX - titleWidth / 2)) < 0.5)
    // The failure exit, the same one `creationFailed` takes.
    view.finish(error: "The space couldn’t be created. Try again.")
    #expect(view.checkCreating.title == "Create Space")
    #expect(!view.checkCreating.spinnerShown)
    #expect(view.checkCreating.cancelEnabled)
    // The success exit, the one `applyCreatedSpace` takes.
    #expect(view.checkSubmit())
    #expect(view.checkCreating.title == "Creating…")
    view.finish(error: nil)
    #expect(view.checkCreating.title == "Create Space")
    #expect(!view.checkCreating.spinnerShown)
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
