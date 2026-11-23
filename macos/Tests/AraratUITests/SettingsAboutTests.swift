import AraratKit
import Foundation
import Testing
@testable import AraratUI

@Test(arguments: [
    ("0.0.1" as String?, "Version 0.0.1 · built on Chromium"),
    ("0.0.2-preview.1", "Version 0.0.2 Preview 1 · built on Chromium"),
    ("0.0.0-dev", "Development build · built on Chromium"),
    (nil, "Development build · built on Chromium"),
])
@MainActor
func aboutVersionSubtitleUsesTheBundleVersion(version: String?, subtitle: String) {
    #expect(SettingsModel.aboutVersionSubtitle(version) == subtitle)
}

@Test(arguments: [
    (SettingsUpdateState.unavailable, "Updates are unavailable", nil as String?),
    (.notChecked, "No recent update check", "Check for Updates"),
    (.upToDate(Date()), "Ararat is up to date", "Check for Updates"),
    (.noCompatibleUpdate("Requires a newer macOS"), "No compatible update", "Check for Updates"),
    (.checking, "Checking for updates…", nil),
    (.available("1.2"), "Ararat 1.2 is available", "Check for Updates"),
    (.downloading("1.2", 0.45), "Downloading Ararat 1.2…", nil),
    (.ready("1.2"), "Ararat 1.2 is ready", "Restart to Update"),
    (.failed("Feed unavailable"), "Couldn’t check for updates", "Try Again"),
])
func aboutUpdateStateMapsToTheRow(state: SettingsUpdateState, title: String, button: String?) {
    #expect(state.row.title == title)
    #expect(state.row.button == button)
    if case .ready = state { #expect(state.row.detail == "Restarting brings your windows back") }
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

@Test @MainActor
func aboutListsTheBundledThirdPartyNotices() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fileManager = FileManager.default
    let fixture = fileManager.temporaryDirectory.appendingPathComponent("about-notices-\(UUID()).bundle")
    let resources = fixture.appendingPathComponent("Contents/Resources")
    try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: fixture) }
    let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundlePackageType": "BNDL"], format: .xml, options: 0)
    try info.write(to: fixture.appendingPathComponent("Contents/Info.plist"))

    let notices = [
        (name: "Ardia GPL-3.0 Licence", file: "Ardia-LICENSE.txt", source: "third_party/ardia/LICENSE"),
        (name: "Ardia Apache-2.0 Licence", file: "Ardia-LICENSE.Apache-2.0.txt", source: "third_party/ardia/LICENSE.Apache-2.0"),
        (name: "Ardia NOTICE", file: "Ardia-NOTICE.txt", source: "third_party/ardia/NOTICE"),
        (name: "Cra MIT Licence", file: "Cra-LICENSE.txt", source: "third_party/cra/LICENSE"),
        (name: "Yab Apache-2.0 Licence", file: "Yab-LICENSE.txt", source: "third_party/yab/LICENSE"),
        (name: "Yab NOTICE", file: "Yab-NOTICE.txt", source: "third_party/yab/NOTICE"),
    ]
    for notice in notices {
        try fileManager.copyItem(at: repo.appendingPathComponent(notice.source), to: resources.appendingPathComponent(notice.file))
    }
    let bundle = try #require(Bundle(url: fixture))
    let listed = SettingsModel.aboutNotices(in: bundle)
    #expect(listed.map(\.name) == notices.map(\.name))
    #expect(listed.map { $0.url.lastPathComponent } == notices.map(\.file))
}
