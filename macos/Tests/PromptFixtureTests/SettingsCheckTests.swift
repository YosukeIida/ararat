import AppKit
import AraratKit
import Testing
@testable import Ararat
@testable import AraratUI

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
