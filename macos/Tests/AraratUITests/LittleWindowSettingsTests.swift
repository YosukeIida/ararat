import AppKit
import AraratKit
import Testing
@testable import AraratUI

// U27i: the Little Window pane's rows, the global shortcut's recorder rules and registration
// answers, and the Open-in destination a stored setting resolves to.

/// A registrar that answers what the test tells it to and counts the calls, so the center's
/// registration path is exercised without the system.
@MainActor
final class FakeHotKeyRegistrar: GlobalHotKeyRegistrar {
    var answer: GlobalHotKeyStatus = .registered
    private(set) var registered: [LittleWindowHotKey] = []
    private(set) var unregisterCount = 0

    func register(_ hotKey: LittleWindowHotKey, handler: @escaping () -> Void) -> GlobalHotKeyStatus {
        registered.append(hotKey)
        if answer == .registered { self.handler = handler }
        return answer
    }

    func unregister() {
        unregisterCount += 1
        handler = nil
    }

    func press() { handler?() }
    private var handler: (() -> Void)?
}

@MainActor
private func littleWindowTestModel(spaces: [SpaceSnapshot] = []) -> SettingsModel {
    SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: spaces.first?.id, selectedId: nil, spaces: spaces),
                  adapter: WorkspaceAdapter(windowID: "u27i-settings"), publish: { _ in }, resetWidth: {},
                  keyBindings: KeyBindingsModel(adapter: WorkspaceAdapter(windowID: "u27i-keys")),
                  airTraffic: AirTrafficModel(adapter: WorkspaceAdapter(windowID: "u27i-atc")))
}

@MainActor
private func littleWindowTestSpace(_ id: String, title: String, profile: Profile = .`default`,
                                   profileName: String = "Default") -> SpaceSnapshot {
    SpaceSnapshot(pinnedCount: 0, todayCount: 0, profileKey: profileName.lowercased(), pinnedId: "", todayId: "",
                  favoritesId: nil, archiveAfter: .hours12, profileName: profileName, profile: profile, id: id,
                  title: title, icon: nil, look: nil, favorites: [], pinned: [], today: [])
}

@MainActor
private func keyEvent(_ keyCode: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: characters,
                     isARepeat: false, keyCode: keyCode)!
}

/// The board's five rows and the values they read: the Open-in label names the named space, the
/// two switch rows carry no caption (as the board draws them), and a space of another profile
/// keeps its title instead of reading as a deleted one (L3).
@Test @MainActor
func theLittleWindowPaneListsTheBoardsRowsAndTheStoredValues() {
    let model = littleWindowTestModel(spaces: [littleWindowTestSpace("work", title: "Work"),
                                               littleWindowTestSpace("personal", title: "Personal")])
    #expect(SettingsRegistry.pane(.littleWindow)?.page == .littleWindow)
    #expect(SettingsRegistry.pane(.littleWindow)?.subtitle == "A small window for links from other apps.")
    let rows = model.rows.filter { $0.pane == .littleWindow }
    #expect(rows.map(\.id) == [SettingsModel.littleWindowLinkRowId, SettingsModel.littleWindowShortcutRowId,
                               SettingsModel.littleWindowOpenInRowId, SettingsModel.littleWindowCloseAfterRowId,
                               SettingsModel.littleWindowRememberRowId])
    #expect(rows[0].title == "Which links open in a Little Window")
    #expect(rows[1].title == "Open a Little Window from any app")
    #expect(rows[2].title == "“Open in” button sends the page to")
    #expect(rows[3].title == "Close the Little Window after opening in a space")
    #expect(rows[4].title == "Remember its size and place")
    // The built-in values: Most Recent Space, both switches on.
    #expect(model.littleWindowOpenInLabel == "Most Recent Space")
    #expect(rows[2].subtitle.hasSuffix("Most Recent Space"))
    #expect(rows[3].subtitle.isEmpty && rows[4].subtitle.isEmpty)
    // A named destination reads by name; a lost space is the only one that reads as deleted.
    model.littleWindowOpenIn = .space("personal")
    #expect(model.littleWindowOpenInLabel == "Personal")
    model.littleWindowOpenIn = .space("gone")
    #expect(model.littleWindowOpenInLabel == "Deleted space")
    // The menu offers the shown space's profile only.
    #expect(model.littleWindowSpaces.map(\.id) == ["work", "personal"])
    model.update(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: "other", selectedId: nil,
                                             spaces: [littleWindowTestSpace("work", title: "Work"),
                                                      littleWindowTestSpace("other", title: "Other", profile: .named("Profile 1"),
                                                                            profileName: "Profile 1")]))
    #expect(model.littleWindowSpaces.map(\.id) == ["other"])
    // L3: a destination in another profile is not deleted; the disabled menu item shows its title.
    model.littleWindowOpenIn = .space("work")
    #expect(model.littleWindowOpenInLabel == "Work")
}

/// The recorder's rules: a combination needs Command, Control or Option; Esc cancels; ⌫ turns it
/// off; the system's own keys are refused, screenshot keys by position.
@Test @MainActor
func theGlobalShortcutRecorderTakesCombinationsAndRefusesTheSystemsOwn() {
    let defaultKey = LittleWindowHotKeyRecorder.entry(for: keyEvent(45, "n", [.option, .command]))
    #expect(defaultKey == .key(LittleWindowHotKey(keyCode: 45, key: "n", command: true, control: false,
                                                  option: true, shift: false)))
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(40, "k", [.control, .option, .command]))
            == .key(LittleWindowHotKey(keyCode: 40, key: "k", command: true, control: true, option: true, shift: false)))
    // Esc cancels, ⌫ and ⌦ clear the shortcut.
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(53, "\u{1b}", [])) == .cancelled)
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(51, "\u{7f}", [])) == .cleared)
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(117, "\u{f728}", [])) == .cleared)
    // A bare key would be taken from every app; ⌘Q, ⌘H, ⌥⌘H, ⌃⌘Q and ⇧⌘3/4/5 are the system's.
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(45, "n", [])) == .refused(LittleWindowHotKeyRecorder.noModifierMessage))
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(12, "q", [.command])) == .refused(LittleWindowHotKeyRecorder.refusedMessage))
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(4, "h", [.command])) == .refused(LittleWindowHotKeyRecorder.refusedMessage))
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(4, "h", [.command, .option])) == .refused(LittleWindowHotKeyRecorder.refusedMessage))
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(12, "q", [.command, .control])) == .refused(LittleWindowHotKeyRecorder.refusedMessage))
    // ⇧⌘3 is the screenshot key by position whatever the layout prints for it.
    #expect(LittleWindowHotKeyRecorder.entry(for: keyEvent(20, "3", [.command, .shift])) == .refused(LittleWindowHotKeyRecorder.refusedMessage))
    // The caps follow the Shortcuts pane's rule.
    #expect(LittleWindowHotKeyRecorder.caps(LittleWindowHotKeyRecorder.defaultHotKey) == ["⌥", "⌘", "N"])
    #expect(LittleWindowHotKeyRecorder.caps(nil).isEmpty)
}

/// The app-wide center hands the stored key to the registrar and keeps the answer the row shows;
/// a key another app holds comes back as taken, and turning it off unregisters.
@Test @MainActor
func theHotKeyCenterRegistersRecountsAndShowsATakenKey() {
    let registrar = FakeHotKeyRegistrar()
    let center = LittleWindowHotKeyCenter(registrar: registrar)
    var fired = 0
    center.onTrigger = { fired += 1 }

    let status = center.apply(LittleWindowHotKeyRecorder.defaultHotKey)
    #expect(status == .registered && center.status == .registered)
    #expect(registrar.registered.last == LittleWindowHotKeyRecorder.defaultHotKey)
    registrar.press()
    #expect(fired == 1)
    #expect(SettingsModel.hotKeyMessage(for: center.status) == nil)

    registrar.answer = .taken
    let custom = LittleWindowHotKey(keyCode: 35, key: "p", command: true, control: false, option: true, shift: false)
    #expect(center.apply(custom) == .taken)
    #expect(center.status == .taken)
    #expect(SettingsModel.hotKeyMessage(for: center.status) == "Another app is already using this shortcut.")
    #expect(SettingsModel.hotKeyMessage(for: .failed("the system refused the shortcut (error 1)"))
            == "the system refused the shortcut (error 1)")

    let unregisters = registrar.unregisterCount
    #expect(center.apply(nil) == nil)
    #expect(center.status == nil && center.hotKey == nil)
    #expect(registrar.unregisterCount == unregisters + 1)
    #expect(SettingsModel.hotKeyMessage(for: nil) == nil)
}

/// D9: a stored destination that names a space of the window's profile is used; any other value
/// (the most recent space, a space of another profile, a deleted one) leaves the caller asking for
/// the profile's most recent space.
@Test @MainActor
func aStoredOpenInDestinationResolvesOnlyInsideTheWindowsProfile() {
    let spaces = [LittleWindowDestination(id: "work", title: "Work"),
                  LittleWindowDestination(id: "personal", title: "Personal")]
    #expect(LittleWindowBarModel.namedDestination(.space("personal"), spaces: spaces) == "personal")
    #expect(LittleWindowBarModel.namedDestination(.space("gone"), spaces: spaces) == nil)
    #expect(LittleWindowBarModel.namedDestination(.mostRecent, spaces: spaces) == nil)
    #expect(LittleWindowBarModel.namedDestination(.space("reading"), spaces: []) == nil)
}

/// U27i M2: a Carbon hot key is seen before any app's menus, so a combination Ararat's own table
/// uses is refused with the command named, and the stored shortcut stays as it was.
@Test @MainActor
func theRecorderRefusesACombinationAraratsOwnKeyBindingsUse() {
    let model = littleWindowTestModel()
    model.toggleLittleWindowHotKeyRecording()
    #expect(model.hotKeyRecording)
    model.handleLittleWindowHotKeyEvent(keyEvent(17, "t", [.command]))
    #expect(!model.hotKeyRecording)
    #expect(model.hotKeyMessage == "⌘T is New Tab in Ararat")
    #expect(model.littleWindowHotKey == LittleWindowHotKeyRecorder.defaultHotKey)
    // A combination the table does not hold is not refused as a conflict.
    model.toggleLittleWindowHotKeyRecording()
    model.handleLittleWindowHotKeyEvent(keyEvent(40, "k", [.control, .option, .command]))
    #expect(model.hotKeyMessage != "⌘T is New Tab in Ararat")
}

/// U27i L1/L8: starting the recorder pauses the app-wide registration, so the current shortcut can
/// be recorded again; cancelling, leaving the pane or a second toggle gives it back.
@Test @MainActor
func theRecorderPausesTheRegistrationAndGivesItBack() {
    let registrar = FakeHotKeyRegistrar()
    let center = LittleWindowHotKeyCenter(registrar: registrar)
    let model = littleWindowTestModel()
    model.hotKeyCenter = center
    center.apply(model.littleWindowHotKey)
    let unregisters = registrar.unregisterCount
    model.toggleLittleWindowHotKeyRecording()
    #expect(model.hotKeyRecording)
    #expect(registrar.unregisterCount == unregisters + 1)
    model.cancelLittleWindowHotKeyRecording()
    #expect(!model.hotKeyRecording)
    #expect(center.status == .registered)
    #expect(registrar.registered.last == model.littleWindowHotKey)
    // Leaving the pane ends it too (L8), and so does toggling the row off.
    model.toggleLittleWindowHotKeyRecording()
    model.navigate(.tabs)
    #expect(!model.hotKeyRecording && center.status == .registered)
    model.toggleLittleWindowHotKeyRecording()
    model.toggleLittleWindowHotKeyRecording()
    #expect(!model.hotKeyRecording && center.status == .registered)
}

/// U27i N1: the close button does not take first responder, so the recorder never resigns on a
/// close; the window's close must end the recording and register the stored key again, or the
/// shortcut stays dead until Settings reopens.
@Test @MainActor
func closingTheSettingsWindowEndsARecordingAndRestoresTheShortcut() throws {
    _ = NSApplication.shared
    let registrar = FakeHotKeyRegistrar()
    let center = LittleWindowHotKeyCenter(registrar: registrar)
    let model = littleWindowTestModel()
    model.hotKeyCenter = center
    center.apply(model.littleWindowHotKey)
    let controller = SettingsWindowController(model: model)
    let window = try #require(controller.window)
    defer { window.contentViewController = nil }
    let unregisters = registrar.unregisterCount
    model.toggleLittleWindowHotKeyRecording()
    #expect(model.hotKeyRecording)
    #expect(registrar.unregisterCount == unregisters + 1)
    window.close()
    #expect(!model.hotKeyRecording)
    #expect(center.status == .registered)
    #expect(registrar.registered.last == model.littleWindowHotKey)
}
