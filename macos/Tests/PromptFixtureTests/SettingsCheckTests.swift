import AppKit
import AraratKit
import Testing
@testable import Ararat
@testable import AraratUI

@Test @MainActor
func defaultDestinationPressWaitsForTheRowMenusEndNotification() throws {
    _ = NSApplication.shared
    let runtime = Runtime(windowID: "atc-menu-order")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
                                   windowID: runtime.windowID, card: NSView(), seedSidebar: true)
    defer { adapter.shutdown() }
    runtime.adapter = adapter
    let workspace = WorkspaceAdapter(windowID: runtime.windowID, session: adapter.session)
    let model = SettingsModel(snapshot: adapter.session.store!.snapshot(windowId: runtime.windowID),
        adapter: workspace, publish: { _ in }, resetWidth: {}, keyBindings: KeyBindingsModel(adapter: workspace),
        airTraffic: AirTrafficModel(adapter: workspace))
    let settings = SettingsWindowController(model: model)
    runtime.settings = settings
    defer { settings.window?.contentViewController = nil }
    let probe = try #require(settings.checkProbe())
    let check = SettingsScreenCheck()
    check.phase = 8
    var waits: [String] = []
    func tick() {
        runtime.settingsAirTrafficTick(probe, check: check, note: { waits.append($0) },
            step: { _ in Issue.record("advanced before a stored route") },
            end: { _, _ in Issue.record("ended before a stored route") },
            finish: { Issue.record("finished before a stored route") },
            capture: { _ in Issue.record("captured before a stored route"); return false })
    }
    tick()
    let menu = NSMenu()
    check.watchAirTrafficRowMenuEnd(menu)
    tick()
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
    tick()
    #expect(waits == Array(repeating: "row menu tracking ended", count: 3))
    NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
    tick()
    #expect(waits.last == "row destination stored")
    #expect(check.phase == 8 && check.airTrafficMenuObserver == nil)
}

@Test @MainActor
func spaceNameCheckCanWaitForSelectionAfterClosingTheLookPopover() throws {
    _ = NSApplication.shared
    let runtime = Runtime(windowID: "space-name-check")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("workspace.sqlite").path,
        windowID: runtime.windowID, card: NSView(), seedSidebar: true, session: session)
    runtime.adapter = adapter
    var snapshot = try #require(session.store).snapshot(windowId: runtime.windowID)
    snapshot.selectedId = nil
    runtime.snapshot = snapshot
    let sidebar = SidebarView(snapshot: snapshot)
    let container = SidebarContainerView(sidebar: sidebar, page: NSView())
    sidebar.onCreatePageChanged = { [weak container] in container?.selectionChanged() }
    runtime.sidebar = sidebar
    runtime.container = container
    let check = SidebarCheck()
    check.phase = 61
    var steps: [Int] = []
    func tick() {
        runtime.spaceNameTickPhase(screen: false, check: check, note: { _ in }, trace: { _ in },
            step: { check.phase = $0; steps.append($0) }, finish: { Issue.record("finished before create") },
            capture: { _ in true }, click: { _, _ in false },
            row: { runtime.sidebarCheckRow(snapshot.spaces.first, $0) })
    }
    tick()
    #expect(sidebar.selectedRowID != nil)
    #expect(!sidebar.createSpaceOpen && steps.isEmpty)
    container.selectionChanged()
    tick()
    #expect(steps == [7] && sidebar.createSpaceOpen)
    #expect(check.selectionReady && runtime.sharedLookProbe == nil)
    tick()
    #expect(check.conditions["create_page_selection"] == true)
}

@Test @MainActor
func shortcutFallbackCannotPassWithOnlyDownstreamConditions() {
    var conditions = Dictionary(uniqueKeysWithValues: SettingsScreenCheck.conditionNames(.shortcuts).map { ($0, true) })
    for pressed in [nil, false, true] as [Bool?] {
        conditions["record_button_pressed"] = pressed
        let result = SettingsScreenCheck.conditionResults(conditions, mode: .shortcuts)
        #expect(result.values["record_button_pressed"] == (pressed == true))
        #expect(result.failed == (pressed == true ? [] : ["record_button_pressed"]))
    }
}

@Test @MainActor
func settingsWheelsExpireThePauseBeforeReversedPaging() throws {
    let unstamped = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: -5, wheel3: 0))
    #expect(try #require(NSEvent(cgEvent: unstamped)).timestamp == 0)
    let now = ProcessInfo.processInfo.systemUptime
    let live = try #require(SettingsScreenCheck.spaceWheelEvent())
    #expect(live.timestamp >= now && live.timestamp <= ProcessInfo.processInfo.systemUptime)
    var state = SpaceScrollState()
    var pause = -Double.infinity
    for (time, direction, expected) in [(100.0, SpaceScrollDirection.natural, 2), (100.25, .reversed, 0)] {
        let event = try #require(SettingsScreenCheck.spaceWheelEvent(time: time))
        #expect(event.timestamp == time)
        #expect(event.phase.isEmpty && event.momentumPhase.isEmpty)
        let input = SpaceScrollEvent(dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
                                     inverted: event.isDirectionInvertedFromDevice, time: event.timestamp)
        #expect(state.handle(input, index: 1, count: 3, pitch: 180, direction: direction,
                             wheelPausedUntil: &pause) == .settle(index: expected, offset: 0, switched: true))
        state = SpaceScrollState()
    }
}

// U27a: the `--ararat-screen=` argument reaches the mode through the same two steps `main.swift`
// uses — argument to `screenMode`, then `checkMode`, and every later site parses that check mode
// with `mode`. A name that never maps leaves every settings registration site dark, which is what
// happened before review 1's B1 fix.
@Test @MainActor
func aSettingsScreenArgumentReachesItsModeAndBackThroughTheCheckMode() {
    #expect(SettingsScreenCheck.Mode.screenMode("settings-tabs") == .tabs)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-about") == .about)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-passwords") == .passwords)
    #expect(SettingsScreenCheck.Mode.passwords.paneID == "passwords")
    #expect(SettingsScreenCheck.Mode.screenMode("passwords-real-auth") == .passwordsRealAuth)
    #expect(SettingsScreenCheck.Mode.passwordsRealAuth.paneID == "passwords")
    #expect(SettingsScreenCheck.conditionNames(.passwords).suffix(7) == [
        "fake_auth", "fixtures", "locked", "search", "detail", "discard_password_edit", "capture",
    ])
    #expect(SettingsScreenCheck.Mode.about.paneID == "about")
    #expect(SettingsScreenCheck.conditionNames(.about).suffix(2) == ["rows", "capture"])
    #expect(SettingsScreenCheck.Mode.screenMode("settings-shortcuts") == .shortcuts)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-air-traffic") == .airTraffic)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-appearance") == .appearance)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-spaces") == .spaces)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-little-window") == .littleWindow)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-frame") == .frame)
    #expect(SettingsScreenCheck.Mode.screenMode("settings-search") == .search)
    let checkMode = SettingsScreenCheck.Mode.screenMode("settings-tabs")?.checkMode
    #expect(checkMode == "screen-settings-tabs")
    #expect(checkMode.flatMap(SettingsScreenCheck.Mode.mode) == .tabs)
    // Every mode round-trips through both steps, so the argument, the mode and the check mode
    // cannot disagree.
    for mode in SettingsScreenCheck.Mode.allCases {
        #expect(mode.checkMode == "screen-" + mode.rawValue)
        #expect(SettingsScreenCheck.Mode.screenMode(mode.screenArgument) == mode)
        #expect(SettingsScreenCheck.Mode.mode(mode.checkMode) == mode)
        #expect(mode.screenArgument == mode.rawValue)
    }
    // A bare argument is not a check mode, another family's check mode is not a settings mode, and
    // a check mode is not an argument: the two forms stay apart.
    #expect(SettingsScreenCheck.Mode.mode("settings-tabs") == nil)
    #expect(SettingsScreenCheck.Mode.mode("screen-header") == nil)
    #expect(SettingsScreenCheck.Mode.screenMode("screen-settings-tabs") == nil)
    #expect(SettingsScreenCheck.Mode.screenMode("header") == nil)
}

@Test @MainActor
func systemPasswordSubmissionMapsToFailedOrUnverified() {
    let mode = SettingsScreenCheck.Mode.passwordsRealAuth
    let required = SettingsScreenCheck.conditionNames(mode).filter { $0 != "password_unlocks" }
    let passed = Dictionary(uniqueKeysWithValues: required.map { ($0, true) })

    var rejected = PasswordsAuthPrompt.Result()
    let closedAfterSubmission = rejected.recordSubmission(.submitted, waitForClose: { false })
    #expect(!closedAfterSubmission)
    #expect(rejected.actionError?.contains("stayed open after AXPress") == true)
    #expect(rejected.inputRefusal == nil)
    var conditions = passed
    conditions["password_unlocks"] = false
    let failed = SettingsScreenCheck.conditionResults(conditions, mode: mode)
    #expect(failed.failed == ["password_unlocks"])

    var refused = PasswordsAuthPrompt.Result()
    let closedAfterRefusal = refused.recordSubmission(.writeRefused(.cannotComplete)) {
        Issue.record("A refused AX write must not wait for submission")
        return false
    }
    #expect(!closedAfterRefusal)
    #expect(refused.actionError == nil)
    let unavailable = SettingsScreenCheck.conditionResults(
        passed, mode: mode, unverified: refused.inputRefusal.map { ["password_unlocks": $0] } ?? [:])
    #expect(unavailable.failed.isEmpty)
    #expect(unavailable.values["password_unlocks"] == nil)
}

@Test
func escapeCancellationRequiresTheAuthorizationWindowToClose() {
    let refusal = "AXCancelButton unavailable"
    #expect(PasswordsAuthPrompt.escapeCancellationError(after: refusal, windowClosed: true) == nil)
    #expect(PasswordsAuthPrompt.escapeCancellationError(after: refusal, windowClosed: false)
        == "AXCancelButton unavailable; the authorization window stayed open after process-directed Escape")
}
