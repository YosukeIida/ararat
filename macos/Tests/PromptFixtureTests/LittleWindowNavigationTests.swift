import AppKit
import AraratEngineAPI
import AraratKit
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class LittleWindowNavigationHost: NSObject {
    @objc dynamic weak var delegate: AnyObject?
    let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    var navigated: [String] = []
    var pageURL = "https://example.test/"
    var opened: [String] = []
    var closing = true
    @objc(window) func window() -> NSWindow { value }
    @objc(isClosing) func isClosing() -> Bool { closing }
    @objc(isClosingAll) func isClosingAll() -> Bool { false }
    @objc(profileDirectory) func profileDirectory() -> String { "Default" }
    @objc(tabs) func tabs() -> [Any] { [] }
    @objc(setProfileDirectory:) func setProfileDirectory(_ profile: String) -> Bool { true }
    @objc(extensionManagementURL:) func extensionManagementURL(_ id: String) -> String? { "chrome://extensions/?id=\(id)" }
    @objc(navigationTarget) func navigationTarget() -> NSDictionary? { nil }
    @objc(navigateLittleWindow:) func navigateLittleWindow(_ url: String) -> Bool { navigated.append(url); pageURL = url; return true }
    @objc(openURL:commandId:itemId:profile:external:untrusted:historyStamp:)
    func openURL(_ url: String, commandId: String, itemId: String, profile: String, external: Bool, untrusted: Bool, historyStamp: UInt64) -> Bool {
        opened.append(url)
        return true
    }
}

@Test @MainActor
func managingAnExtensionOpensAnOriginTabAndKeepsTheLittleWindowPage() async throws {
    _ = NSApplication.shared
    class_addProtocol(LittleWindowNavigationHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let session = WorkspaceSession()
    let adapter = try EngineAdapter(path: directory.appendingPathComponent("db").path, windowID: "origin", card: NSView(), seedCheck: true, session: session)
    let originHost = LittleWindowNavigationHost()
    originHost.closing = false
    let origin = Runtime(windowID: "origin")
    origin.host = originHost as? any ARWindowHostAPI
    origin.adapter = adapter
    adapter.attach(origin.host!)
    origin.snapshot = try session.queue.sync { try #require(session.store).snapshot(windowId: "origin") }

    let popupHost = LittleWindowNavigationHost()
    let popup = PopupHost()
    popup.rootView.addSubview(popup.card)
    popup.host = popupHost as? any ARWindowHostAPI
    let controller = LittleWindowController(popup: popup, origin: origin, profile: "Default", frame: .zero, url: nil)
    defer { controller.close(); popup.littleWindow = nil }
    let item = NSMenuItem()
    item.representedObject = "extension-id"
    controller.perform(NSSelectorFromString("menuManageExtension:"), with: item)
    for _ in 0..<100 where originHost.opened.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(originHost.opened == ["chrome://extensions/?id=extension-id"])
    #expect(popupHost.pageURL == "https://example.test/")
}

@Test @MainActor
func littleWindowNavigatesItsOwnPopupWithoutAWorkspaceTarget() {
    _ = NSApplication.shared
    class_addProtocol(LittleWindowNavigationHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = LittleWindowNavigationHost()
    let popup = PopupHost()
    popup.rootView.addSubview(popup.card)
    popup.host = host as? any ARWindowHostAPI
    let origin = Runtime(windowID: "origin")
    let controller = LittleWindowController(popup: popup, origin: origin, profile: "Default", frame: .zero, url: nil)
    defer { controller.close(); popup.littleWindow = nil }
    controller.navigate(to: "https://example.test/")
    #expect(host.navigated == ["https://example.test/"])
}
