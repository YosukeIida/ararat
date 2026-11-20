import AraratKit
import Foundation
import Testing
@testable import AraratUI

@Test(arguments: [
    (SettingsUpdateState.unavailable, "Updates are unavailable", nil as String?),
    (.notChecked, "No recent update check", "Check for Updates"),
    (.upToDate(Date()), "Ararat is up to date", "Check for Updates"),
    (.noCompatibleUpdate("Requires a newer macOS"), "No compatible update", "Check for Updates"),
    (.checking, "Checking for updates…", nil),
    (.available("1.2"), "Ararat 1.2 is available", "Check for Updates"),
    (.downloading("1.2", 0.45), "Downloading Ararat 1.2…", nil),
    (.ready("1.2"), "Ararat 1.2 is ready", "Restart to Update"),
    (.failed("Feed unavailable"), "Couldn’t update Ararat", "Try Again"),
])
func aboutUpdateStateMapsToTheRow(state: SettingsUpdateState, title: String, button: String?) {
    #expect(state.row.title == title)
    #expect(state.row.button == button)
    if case .failed(let detail) = state { #expect(state.row.detail == detail) }
    if case .upToDate = state { #expect(state.row.detail?.hasPrefix("Checked ") == true) }
}

@MainActor
private final class AboutUpdaterFixture: SettingsUpdater {
    let state = SettingsUpdateState.notChecked
    let canCheck = true
    var automaticallyChecks: Bool? = true
    func checkNow() {}
    func restartToUpdate() {}
}

@Test @MainActor
func aboutAutomaticCheckSwitchUsesTheUpdaterPreference() {
    let adapter = WorkspaceAdapter(windowID: "about")
    let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []),
                              adapter: adapter, publish: { _ in }, resetWidth: {},
                              keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
    let updater = AboutUpdaterFixture()
    model.aboutUpdater = updater
    let binding = SettingsAboutSection(model: model).automaticChecks
    #expect(binding.wrappedValue)
    binding.wrappedValue = false
    #expect(updater.automaticallyChecks == false)
    updater.automaticallyChecks = true
    #expect(binding.wrappedValue)
}
