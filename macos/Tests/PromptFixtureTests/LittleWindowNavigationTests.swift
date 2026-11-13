import AppKit
import AraratEngineAPI
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class LittleWindowNavigationHost: NSObject {
    let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
    var navigated: [String] = []
    @objc(window) func window() -> NSWindow { value }
    @objc(isClosing) func isClosing() -> Bool { true }
    @objc(navigationTarget) func navigationTarget() -> NSDictionary? { nil }
    @objc(navigateLittleWindow:) func navigateLittleWindow(_ url: String) -> Bool { navigated.append(url); return true }
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
