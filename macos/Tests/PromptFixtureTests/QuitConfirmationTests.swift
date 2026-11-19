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

@Test func warnsForDockButSkipsSystemAndUpdateQuits() {
    let cases: [(Bool, OSType?, String?, Bool, QuitConfirmation.Source)] = [
        (false, nil, nil, false, .user),
        (false, nil, "com.apple.dock", false, .user),
        (true, nil, nil, false, .sessionEnd),
        (false, kAEReallyLogOut, nil, false, .sessionEnd),
        (false, kAELogOut, nil, false, .sessionEnd),
        (false, kAERestart, nil, false, .sessionEnd),
        (false, kAEShutDown, nil, false, .sessionEnd),
        (false, nil, "org.sparkle-project.Sparkle.Updater", false, .sparkle),
        (false, nil, nil, true, .check),
    ]
    for (poweringOff, reason, sender, check, expected) in cases {
        let source = QuitConfirmation.source(poweringOff: poweringOff, quitReason: reason,
                                             senderBundleID: sender, checkBypass: check)
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

@Test func onlyDeliberateQuitShortcutConfirmsAndOnlyQuitDisablesWarning() {
    #expect(QuitConfirmation.confirmsWithShortcut(shortcut: true, repeatKey: false))
    #expect(!QuitConfirmation.confirmsWithShortcut(shortcut: true, repeatKey: true))
    #expect(!QuitConfirmation.confirmsWithShortcut(shortcut: false, repeatKey: false))
    #expect(!QuitConfirmation.disablesWarning(accepted: false, checked: true))
    #expect(!QuitConfirmation.disablesWarning(accepted: true, checked: false))
    #expect(QuitConfirmation.disablesWarning(accepted: true, checked: true))
}
