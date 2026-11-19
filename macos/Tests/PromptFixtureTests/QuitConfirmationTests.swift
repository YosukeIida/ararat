import AppKit
import AraratKit
import Carbon.HIToolbox
import Testing
@testable import Ararat

@Test func warnsForEveryKindOfVisibleBrowserWindow() {
    for kind in [QuitConfirmation.BrowserWindow.regular, .privateWindow, .littleWindow] {
        #expect(QuitConfirmation.shouldAsk(source: .user, warn: true, visible: [kind]))
    }
    #expect(!QuitConfirmation.shouldAsk(source: .user, warn: true, visible: []))
    #expect(!QuitConfirmation.shouldAsk(source: .user, warn: false, visible: [.regular]))
}

@Test func warnsForUserQuitsButSkipsSystemAndCheckQuits() {
    let cases: [(Bool, OSType?, Bool, QuitConfirmation.Source)] = [
        (false, nil, false, .user),
        (true, nil, false, .sessionEnd),
        (false, kAEReallyLogOut, false, .sessionEnd),
        (false, kAELogOut, false, .sessionEnd),
        (false, kAERestart, false, .sessionEnd),
        (false, kAEShutDown, false, .sessionEnd),
        (false, nil, true, .check),
    ]
    for (poweringOff, reason, check, expected) in cases {
        let source = QuitConfirmation.source(poweringOff: poweringOff, quitReason: reason,
                                             sparkleRelaunching: false, checkBypass: check)
        #expect(source == expected)
        #expect(QuitConfirmation.shouldAsk(source: source, warn: true, visible: [.regular]) == (expected == .user))
    }
}

@Test func quitConfirmationDescribesWhichTabsComeBack() {
    let regular = "Your tabs will be here when you come back."
    let privateWindows = "Private windows will close and their tabs will not come back."
    #expect(QuitConfirmation.message(for: [.regular]) == regular)
    #expect(QuitConfirmation.message(for: [.littleWindow]) == regular)
    #expect(QuitConfirmation.message(for: [.privateWindow, .privateWindow]) == privateWindows)
    #expect(QuitConfirmation.message(for: [.regular, .privateWindow]) == regular + "\n" + privateWindows)
    #expect(QuitConfirmation.message(for: [.privateWindow, .littleWindow]) == regular + "\n" + privateWindows)
}

@Test @MainActor func theReboundQuitShortcutConfirmsAndItsRepeatIsConsumed() throws {
    let rebound = KeyCombination(key: "k", command: true, control: false, option: false, shift: true)
    let original = try #require(defaultKeyBindings().first { $0.command == "quit" }?.key)
    func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags, repeats: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                    windowNumber: 0, context: nil, characters: characters,
                                    charactersIgnoringModifiers: characters, isARepeat: repeats, keyCode: code))
    }
    let oldKey = try key("q", code: 12, flags: .command)
    let newKey = try key("K", code: 40, flags: [.command, .shift])
    let repeatKey = try key("K", code: 40, flags: [.command, .shift], repeats: true)
    #expect(QuitConfirmation.shortcutAction(for: oldKey, binding: original) == .confirm)
    #expect(QuitConfirmation.shortcutAction(for: oldKey, binding: rebound) == .pass)
    #expect(QuitConfirmation.shortcutAction(for: newKey, binding: rebound) == .confirm)
    #expect(QuitConfirmation.shortcutAction(for: repeatKey, binding: rebound) == .consumeRepeat)
    #expect(QuitConfirmation.shortcutAction(for: oldKey, binding: nil) == .pass)
}

@Test func onlyAcceptedQuitDisablesWarning() {
    #expect(!QuitConfirmation.disablesWarning(accepted: false, checked: true))
    #expect(!QuitConfirmation.disablesWarning(accepted: true, checked: false))
    #expect(QuitConfirmation.disablesWarning(accepted: true, checked: true))
}
