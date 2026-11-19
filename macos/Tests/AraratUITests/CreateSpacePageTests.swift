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

/// The mock's state 4, with the find bar's rule on top: a creation that answers within 250 ms never
/// shows it. Once shown, the button keeps the disabled fill, the spinner and "Creating…" are one
/// centred group (14 pt, 7 pt, the title), and Cancel is disabled too — cancelling is not
/// supported by the creation path, so an enabled Cancel would offer a press that does nothing.
/// Both exits (`finish`, on success and on failure) end the state at once.
@Test @MainActor
func createSpacePageShowsTheCreatingStateOnlyAfterTheDelay() throws {
    _ = NSApplication.shared
    let view = CreateSpaceView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    view.active = true
    view.begin(profileName: "Default")
    view.onCreate = { _ in }
    var starts: [(delay: TimeInterval, work: DispatchWorkItem)] = []
    view.scheduleCreatingStart = { delay, work in starts.append((delay, work)) }
    func takeStart() throws -> DispatchWorkItem {
        let next = starts.popLast()
        let start = try #require(next)
        #expect(start.delay == 0.25)
        return start.work
    }

    let button = try #require(view.subviews.compactMap { $0 as? SidebarDockButton }.first { $0.accessibilityLabel() == "Create Space" })
    let spinner = try #require(button.subviews.compactMap { $0 as? NSProgressIndicator }.first)

    // Still running at 250 ms: the state shows.
    view.checkType("Research")
    #expect(view.checkSubmit())
    #expect(view.checkCreating.title == "Create Space")
    #expect(!view.checkCreating.spinnerShown)
    #expect(!view.checkState.buttonEnabled)
    try takeStart().perform()
    #expect(view.checkCreating.title == "Creating…")
    #expect(view.checkCreating.spinnerShown)
    #expect(!view.checkCreating.cancelEnabled)
    #expect(!view.checkState.buttonEnabled)

    // One centred group: spinner slot (14 + 7) before the title, its centre on the button's.
    view.layoutSubtreeIfNeeded()
    let title = try #require(button.cell).titleRect(forBounds: button.bounds)
    let slot = SidebarMetrics.createSpaceSpinnerSize + SidebarMetrics.createSpaceSpinnerGap
    let textWidth = ("Creating…" as NSString).size(withAttributes: [.font: button.font ?? .systemFont(ofSize: SidebarMetrics.createSpaceBodySize)]).width
    #expect(spinner.frame.width == SidebarMetrics.createSpaceSpinnerSize)
    #expect(spinner.frame.height == SidebarMetrics.createSpaceSpinnerSize)
    // The cell lays the title out on whole points.
    #expect(abs(spinner.frame.minX - title.minX) < 1)
    #expect(abs(title.width - (slot + textWidth)) < 1)
    #expect(abs((spinner.frame.minX + title.maxX) / 2 - button.bounds.midX) < 1)
    #expect(abs(title.minX + slot - spinner.frame.maxX - SidebarMetrics.createSpaceSpinnerGap) < 1)

    // The failure exit, the same one `creationFailed` takes, ends it at once.
    view.finish(error: "The space couldn’t be created. Try again.")
    #expect(view.checkCreating.title == "Create Space")
    #expect(!view.checkCreating.spinnerShown)
    #expect(view.checkCreating.cancelEnabled)
    // The success exit, the one `applyCreatedSpace` takes.
    #expect(view.checkSubmit())
    try takeStart().perform()
    #expect(view.checkCreating.spinnerShown)
    view.finish(error: nil)
    #expect(view.checkCreating.title == "Create Space")
    #expect(!view.checkCreating.spinnerShown)
}

@Test @MainActor
func createSpacePageNeverShowsCreatingWhenTheAnswerBeatsTheDelay() throws {
    _ = NSApplication.shared
    let view = CreateSpaceView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
    view.active = true
    view.begin(profileName: "Default")
    var calls = 0
    view.onCreate = { _ in calls += 1 }
    var starts: [DispatchWorkItem] = []
    view.scheduleCreatingStart = { _, work in starts.append(work) }
    view.checkType("Research")
    #expect(view.checkSubmit())
    let next = starts.popLast()
    let slow = try #require(next)
    view.finish(error: nil)
    #expect(slow.isCancelled)
    slow.perform()
    #expect(view.checkCreating.title == "Create Space")
    #expect(!view.checkCreating.spinnerShown)
    #expect(view.checkCreating.cancelEnabled)
    #expect(calls == 1)
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
