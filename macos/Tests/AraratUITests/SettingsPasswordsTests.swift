import AppKit
import AraratEngineAPI
import AraratKit
import Testing
@testable import AraratUI

private final class PasswordRow: NSObject, ARPasswordRowAPI {
    let rowID: String
    let website: String
    let username: String

    init(_ rowID: String, _ website: String, _ username: String) {
        self.rowID = rowID
        self.website = website
        self.username = username
    }
}

@MainActor
private final class PasswordsFixture: NSObject, ARPasswordsAPI {
    var enabled = true
    var offersToSave = true
    var authenticatesBeforeFilling = false
    var invalidated = false
    var auth: ((Bool) -> Void)?
    var snapshots: [(ARPasswordsState, [any ARPasswordRowAPI]) -> Void] = []
    var changed: (() -> Void)?
    var reveal: ((UnsafePointer<unichar>?, UInt) -> Void)?
    var added: (website: String, username: String, length: UInt)?

    func setManagerEnabled(_ enabled: Bool) -> Bool { self.enabled = enabled; return true }
    func authenticate(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) { auth = completion }
    func cancelAuthentication() {}
    func snapshot(_ completion: @escaping @MainActor @Sendable (ARPasswordsState, [any ARPasswordRowAPI]) -> Void) {
        snapshots.append(completion)
    }
    func setChangedHandler(_ handler: (@MainActor @Sendable () -> Void)?) { changed = handler }
    func addWebsite(_ website: String, username: String, password: UnsafePointer<unichar>, length: UInt) -> Bool {
        added = (website, username, length)
        return true
    }
    func editRow(_ rowID: String, username: String, password: UnsafePointer<unichar>?, length: UInt) -> Bool { false }
    func deleteRow(_ rowID: String) -> Bool { false }
    func revealRow(_ rowID: String, completion: @escaping @MainActor @Sendable (UnsafePointer<unichar>?, UInt) -> Void) { reveal = completion }
    func copyRow(_ rowID: String, completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(false) }
    func invalidate() { invalidated = true }
}

@Suite @MainActor
struct SettingsPasswordsTests {
    @Test func authenticationGatesSnapshotsAndSearchMatchesWebsiteAndUserName() {
        let model = SettingsPasswordsModel()
        let engine = PasswordsFixture()
        model.configure(profile: "Default", openWebsite: { _ in }) { $0(engine) }

        #expect(model.state == .locked)
        #expect(engine.snapshots.isEmpty)
        model.unlock()
        engine.auth?(false)
        #expect(model.state == .locked)
        #expect(engine.snapshots.isEmpty)
        model.unlock()
        engine.auth?(true)
        #expect(model.state == .loading)

        engine.snapshots.last?(.loading, [])
        #expect(model.state == .loading)
        engine.changed?()
        engine.snapshots.last?(.failed, [])
        #expect(model.state == .failed)
        engine.changed?()
        engine.snapshots.last?(.ready, [])
        #expect(model.state == .empty)

        engine.changed?()
        engine.snapshots.last?(.ready, [
            PasswordRow("1", "https://calendar.test", "Sam"),
            PasswordRow("2", "https://news.test", "Alex"),
        ])
        #expect(model.state == .ready)
        model.query = " CALENDAR "
        #expect(model.filtered.map(\.rowID) == ["1"])
        model.query = "alex"
        #expect(model.filtered.map(\.rowID) == ["2"])
        model.query = "unmatched"
        #expect(model.filtered.isEmpty)
    }

    @Test func retargetAndCloseDiscardLoadsAuthenticationAndSnapshots() throws {
        _ = NSApplication.shared
        let adapter = WorkspaceAdapter(windowID: "settings-password-tests")
        let model = SettingsModel(snapshot: WorkspaceSnapshot(archive: [], shownSpaceId: nil, selectedId: nil, spaces: []),
            adapter: adapter, publish: { _ in }, resetWidth: {},
            keyBindings: KeyBindingsModel(adapter: adapter), airTraffic: AirTrafficModel(adapter: adapter))
        let controller = SettingsWindowController(model: model, orderWindowFront: { _ in Issue.record("Unexpected window ordering") })
        let window = try #require(controller.window)
        var firstLoad: (((any ARPasswordsAPI)?) -> Void)?
        controller.configurePasswords(profile: "First") { firstLoad = $0 }
        let current = PasswordsFixture()
        controller.configurePasswords(profile: "Second") { $0(current) }
        firstLoad?(PasswordsFixture())
        controller.prepare(shownSpaceID: nil, passwords: true)
        #expect(controller.isShowingPasswords())
        #expect(model.passwords.handle === current)

        model.passwords.unlock()
        let third = PasswordsFixture()
        controller.configurePasswords(profile: "Third") { $0(third) }
        current.auth?(true)
        #expect(current.invalidated)
        #expect(current.snapshots.isEmpty)
        #expect(model.passwords.state == .locked)

        model.passwords.unlock()
        third.auth?(true)
        #expect(third.snapshots.count == 1)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        third.snapshots.last?(.ready, [PasswordRow("3", "https://late.test", "Pat")])
        #expect(third.invalidated)
        #expect(model.passwords.state == .locked)
        #expect(model.passwords.rows.isEmpty)
        #expect(controller.passwordsProfile == nil)
    }

    @Test func ignoresOutOfOrderSnapshotsAndClearsTheAppKitReveal() throws {
        _ = NSApplication.shared
        let model = SettingsPasswordsModel()
        let engine = PasswordsFixture()
        let row = PasswordRow("1", "https://calendar.test", "Sam")
        model.configure(profile: "Default", openWebsite: { _ in }) { $0(engine) }
        model.unlock()
        engine.auth?(true)
        engine.changed?()
        engine.snapshots.last?(.ready, [row])
        engine.snapshots.first?(.failed, [])
        #expect(model.state == .ready)

        model.detail(row)
        model.toggleReveal()
        let text = Array("fixture".utf16)
        let reply = try #require(engine.reveal)
        text.withUnsafeBufferPointer { reply($0.baseAddress, UInt($0.count)) }
        #expect(model.showingPassword)
        #expect(model.revealed.stringValue == "fixture")
        model.lock()
        #expect(!model.showingPassword)
        #expect(model.revealed.stringValue.isEmpty)

        text.withUnsafeBufferPointer { reply($0.baseAddress, UInt($0.count)) }
        #expect(!model.showingPassword)
        #expect(model.revealed.stringValue.isEmpty)
    }

    @Test func addClearsTheSecureFieldAfterWriting() {
        _ = NSApplication.shared
        let model = SettingsPasswordsModel()
        let engine = PasswordsFixture()
        model.configure(profile: "Default", openWebsite: { _ in }) { $0(engine) }
        model.unlock()
        engine.auth?(true)
        engine.snapshots.last?(.ready, [])
        model.add()
        model.website = "https://example.test"
        model.username = "Sam"
        model.input.stringValue = "fixture"
        model.write()
        #expect(engine.added?.website == "https://example.test")
        #expect(engine.added?.username == "Sam")
        #expect(engine.added?.length == 7)
        #expect(model.input.stringValue.isEmpty)
        #expect(model.page == .list)
    }
}
