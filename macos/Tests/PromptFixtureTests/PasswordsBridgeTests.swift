import Foundation
import Testing
import AraratEngineAPI
@testable import Ararat

@MainActor
private final class TestPasswords: NSObject, ARPasswordsAPI {
    var enabled: Bool { true }
    var offersToSave = true
    var showsFillAuthentication = false
    var authenticatesBeforeFilling = false
    let checkUsesFakeAuthentication = false
    let checkHadBiometricsAvailable = false
    func setManagerEnabled(_ enabled: Bool) -> Bool { false }
    func setAuthenticatesBeforeFilling(_ enabled: Bool, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        completion(false)
    }
    func authenticate(_ completion: @escaping @MainActor @Sendable (Bool) -> Void) { completion(false) }
    func cancelAuthentication() {}
    func snapshot(_ completion: @escaping @MainActor @Sendable (ARPasswordsState, [any ARPasswordRowAPI]) -> Void) {
        completion(.ready, [])
    }
    func setChangedHandler(_ handler: (@MainActor @Sendable () -> Void)?) {}
    func addWebsite(_ website: String, username: String, password: UnsafePointer<unichar>, length: UInt) -> Bool { false }
    func editRow(_ rowID: String, username: String, password: UnsafePointer<unichar>?, length: UInt) -> Bool { false }
    func deleteRow(_ rowID: String) -> Bool { false }
    func revealRow(_ rowID: String, completion: @escaping @MainActor @Sendable (UnsafePointer<unichar>?, UInt) -> Void) {
        completion(nil, 0)
    }
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
        var callbacks = 0
        #expect(Runtime.openPasswords(symbol, profile: "Profile 1", loaded: {
            received = $0
            callbacks += 1
        }) == nil)
        #expect(received == nil)
        #expect(callbacks == 0)
        let passwords = TestPasswords()
        defer { Self.deferred = nil }
        Self.deferred?(nil)
        #expect(received == nil)
        #expect(callbacks == 1)
        Self.deferred?(passwords)
        #expect(received === passwords)
    }

    @Test func storeCheckRequiresAnUnambiguousScratchProfileAndMockKeychain() {
        let args = ["Ararat", "--ararat-check=passwords", "--use-mock-keychain",
                    "--user-data-dir=/tmp/pwswitch-test/profile", "--ararat-db=/tmp/pwswitch-test/workspace"]
        #expect(PasswordsStoreCheck.validArguments(args))
        #expect(!PasswordsStoreCheck.validArguments(args + ["--user-data-dir=/Users/example/Profile"]))
        #expect(!PasswordsStoreCheck.validArguments(args + ["--ararat-check=downloads"]))
        #expect(!PasswordsStoreCheck.validArguments(args.filter { $0 != "--use-mock-keychain" }))
        let screen = args.map { $0 == "--ararat-check=passwords" ? "--ararat-screen=settings-passwords" : $0 }
        #expect(PasswordsStoreCheck.validArguments(screen))
        #expect(!PasswordsStoreCheck.validArguments(screen + ["--ararat-check=passwords"]))
        #expect(!PasswordsStoreCheck.validArguments(screen + ["--ararat-db=/Users/example/workspace"]))
        #expect(!PasswordsStoreCheck.validArguments(screen.filter { $0 != "--use-mock-keychain" }))
    }

    @Test func passwordsGuardRecognizesBothChromiumSwitchPrefixes() {
        for mode in ["ararat-check=passwords", "ararat-screen=settings-passwords", "ararat-screen=password-prompt",
                     "ararat-screen=passwords-real-auth"] {
            for prefix in ["-", "--"] {
                let launch = ["Ararat", prefix + mode, prefix + "use-mock-keychain"]
                #expect(PasswordsStoreCheck.requiresScratchGuard(launch))
                #expect(!PasswordsStoreCheck.validArguments(launch))
                let scratch = launch + [prefix + "user-data-dir=/tmp/pwswitch-test/profile",
                                        prefix + "ararat-db=/tmp/pwswitch-test/workspace"]
                #expect(PasswordsStoreCheck.validArguments(scratch))
                #expect(!PasswordsStoreCheck.validArguments(scratch + ["-ararat-screen=settings-passwords"]))
                if mode == "ararat-screen=password-prompt" {
                    #expect(!PasswordsStoreCheck.validArguments(scratch + [prefix + "enable-automation"]))
                }
                #expect(!PasswordsStoreCheck.validArguments(scratch + ["-user-data-dir=/Users/example/Profile"]))
                let afterTerminator = ["Ararat", "--", prefix + mode]
                #expect(PasswordsStoreCheck.requiresScratchGuard(afterTerminator))
                #expect(!PasswordsStoreCheck.validArguments(afterTerminator))
                #expect(PasswordsStoreCheck.requiresScratchGuard(["Ararat", " " + prefix + mode + " "]))
            }
        }
    }
}
