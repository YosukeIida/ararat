import AppKit
import AraratEngineAPI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor
private final class KeyboardProfileTab: NSObject {
    @objc dynamic var itemId: String? = "restored"
    @objc dynamic var url = "http://127.0.0.1:1234/keyboard"
    @objc dynamic var isLoading = false
    @objc dynamic var navigationCount = 1
}

@MainActor
private final class KeyboardProfileHost: NSObject {
    let tab = KeyboardProfileTab()
    var actions: [Int] = []
    var shortcutCount = 0
    @objc func profileDirectory() -> String { "Profile 1" }
    @objc(hasBrowserForProfile:) func hasBrowser(_ profile: String) -> Bool { true }
    @objc func activeItemId() -> String? { tab.itemId }
    @objc func tabs() -> [Any] { [tab] }
    @objc func extensionActions() -> [[String: Any]] { [["id": "kmgaadhbnkendcanjninlfmfgehagggl"]] }
    @objc(checkExtensionAction:) func checkAction(_ command: Int) { actions.append(command) }
    @objc func checkReassignedAction() -> Bool { shortcutCount += 1; return true }
    @objc func checkExtensionActionState() -> [String: Any] { [:] }
}

@Test @MainActor
func profileReloadShortcutWaitsForTheRequestedTabToFinishOpening() {
    class_addProtocol(KeyboardProfileHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(KeyboardProfileTab.self, objc_getProtocol("ARTabAPI")!)
    let fake = KeyboardProfileHost()
    let host = fake as! any ARWindowHostAPI
    let runtime = Runtime(windowID: "keyboard-profile-check")
    runtime.browserCheckPhase = 55

    func tickWaiting() {
        runtime.keyboardProfileCheckTick(host, port: 1234, screen: false)
        #expect(runtime.browserCheckPhase == 55)
        #expect(fake.actions.isEmpty)
        #expect(fake.shortcutCount == 0)
    }

    tickWaiting()
    fake.tab.itemId = "requested"
    fake.tab.url = "http://127.0.0.1:1234/keyboard?profile-reload"
    fake.tab.isLoading = true
    tickWaiting()
    fake.tab.isLoading = false
    fake.tab.navigationCount = 0
    tickWaiting()
    fake.tab.navigationCount = 1
    runtime.keyboardProfileCheckTick(host, port: 1234, screen: false)
    #expect(runtime.browserCheckPhase == 56)
    #expect(fake.actions == [5])
    #expect(fake.shortcutCount == 1)
}
