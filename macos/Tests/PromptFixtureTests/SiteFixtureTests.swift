import Foundation
import Security
import Testing
@testable import Ararat

/// The user's current default keychain path, for the "we never touched it" assertion.
private func defaultKeychainPath() -> String? {
    var keychain: SecKeychain?
    guard SecKeychainCopyDefault(&keychain) == errSecSuccess, let keychain else { return nil }
    var length: UInt32 = 1024
    var buffer = [CChar](repeating: 0, count: 1024)
    guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return nil }
    return String(cString: buffer)
}

@Test func siteFixtureIdentityDecodesAndLeavesTheDefaultKeychainAlone() throws {
    let path = SiteFixtureServer.scratchKeychainPath()
    defer { SiteFixtureServer.removeKeychain(at: path) }
    let before = defaultKeychainPath()
    let identity = try SiteFixtureServer.decodeIdentity(keychainPath: path)
    #expect(CFGetTypeID(identity) == SecIdentityGetTypeID())
    // The scratch keychain file exists while the identity is alive...
    #expect(FileManager.default.fileExists(atPath: path))
    // ...and the user's keychain set was neither read nor changed.
    #expect(defaultKeychainPath() == before)
    // Cleanup removes the file, and the identity survives until the caller drops it.
    #expect(SiteFixtureServer.removeKeychain(at: path))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func siteFixtureCleanupIsIdempotentAndLeavesNoFile() {
    let path = SiteFixtureServer.scratchKeychainPath()
    #expect(!FileManager.default.fileExists(atPath: path))
    #expect(SiteFixtureServer.removeKeychain(at: path))
    #expect(!FileManager.default.fileExists(atPath: path))
}

@Test func siteFixtureServerDeletesItsScratchKeychainOnStop() throws {
    let server = try SiteFixtureServer()
    let path = server.keychainPath
    #expect(FileManager.default.fileExists(atPath: path))
    server.stop()
    #expect(!FileManager.default.fileExists(atPath: path))
}
