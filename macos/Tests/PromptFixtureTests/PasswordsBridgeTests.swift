import Foundation
import Testing
import AraratEngineAPI
@testable import Ararat

private final class TestPasswords: NSObject, ARPasswordsAPI {
    var enabled: Bool { true }
    func setManagerEnabled(_ enabled: Bool) -> Bool { false }
    func snapshot(_ completion: @escaping (ARPasswordsState, [any ARPasswordRowAPI]) -> Void) {
        completion(.ready, [])
    }
    func setChangedHandler(_ handler: (() -> Void)?) {}
    func addWebsite(_ website: String, username: String, password: UnsafePointer<unichar>, length: UInt) -> Bool { false }
    func editRow(_ rowID: String, username: String, password: UnsafePointer<unichar>?, length: UInt) -> Bool { false }
    func deleteRow(_ rowID: String) -> Bool { false }
    func invalidate() {}
}

@Suite @MainActor
struct PasswordsBridgeTests {
    private static var deferred: (((any ARPasswordsAPI)?) -> Void)?

    @Test func forwardsNullableBlockAcrossCABI() {
        let fixture: AraratPasswordsFunction = { profile, loaded in
            if profile == "Default" {
                #expect(loaded == nil)
                return TestPasswords()
            }
            Self.deferred = loaded
            return nil
        }
        let symbol = unsafeBitCast(fixture, to: UnsafeMutableRawPointer.self)

        #expect(Runtime.openPasswords(symbol, profile: "Default", loaded: nil)?.enabled == true)
        var received: (any ARPasswordsAPI)?
        #expect(Runtime.openPasswords(symbol, profile: "Profile 1", loaded: { received = $0 }) == nil)
        #expect(received == nil)
        let passwords = TestPasswords()
        defer { Self.deferred = nil }
        Self.deferred?(nil)
        #expect(received == nil)
        Self.deferred?(passwords)
        #expect(received === passwords)
    }
}
