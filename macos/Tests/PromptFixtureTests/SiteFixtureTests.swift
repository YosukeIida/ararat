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

/// The user's search list, in order: creating a keychain would insert one, deleting it would
/// remove it again, and a crash would leave it behind.
private func searchListPaths() -> [String] {
    var array: CFArray?
    guard SecKeychainCopySearchList(&array) == errSecSuccess,
          let list = array as? [SecKeychain] else { return [] }
    return list.map { keychain in
        var length: UInt32 = 1024
        var buffer = [CChar](repeating: 0, count: 1024)
        guard SecKeychainGetPath(keychain, &length, &buffer) == errSecSuccess else { return "?" }
        return String(cString: buffer)
    }
}

@Test func siteFixtureIdentityDecodesFromMemoryAndLeavesKeychainsAlone() throws {
    let beforeDefault = defaultKeychainPath()
    let beforeSearch = searchListPaths()
    let identity = try SiteFixtureServer.decodeIdentity()
    #expect(CFGetTypeID(identity) == SecIdentityGetTypeID())
    // kSecImportToMemoryOnly: no keychain file, no default or search-list change.
    #expect(defaultKeychainPath() == beforeDefault)
    #expect(searchListPaths() == beforeSearch)
}

@Test func siteFixtureServerCreatesNoKeychainFile() throws {
    let server = try SiteFixtureServer()
    server.stop()
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
    #expect(!leftovers.contains { $0.hasPrefix("ararat-site-fixture-") && $0.hasSuffix(".keychain") })
}
