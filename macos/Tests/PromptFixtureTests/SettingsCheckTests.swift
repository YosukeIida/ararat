import Testing
@testable import Ararat

// U27a: the `--ararat-screen=` argument reaches the mode through the same two steps `main.swift`
// uses — argument to `screenMode`, then `checkMode`, and every later site parses that check mode
// with `mode`. A name that never maps leaves every settings registration site dark, which is what
// happened before review 1's B1 fix.
@Test @MainActor
func aSettingsScreenArgumentReachesItsModeAndBackThroughTheCheckMode() {
    #expect(SettingsScreenCheck.Mode.screenMode("settings-tabs") == .tabs)
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
