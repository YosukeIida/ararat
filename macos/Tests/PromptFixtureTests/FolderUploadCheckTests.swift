import AppKit
import AraratEngineAPI
import AraratKit
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class FolderUploadSeedWindow: NSWindow {
    var reportedVisible = false
    override var isVisible: Bool { reportedVisible }
    override var isKeyWindow: Bool { reportedVisible }
}

@MainActor private final class FolderUploadSeedTab: NSObject {
    @objc dynamic var itemId: String?
    @objc dynamic var url = "data:text/html,<title>Ararat One</title>"
    @objc dynamic var isLoading = false
    @objc dynamic var navigationCount: UInt = 1
}

@MainActor private final class FolderUploadSeedHost: NSObject {
    let value = FolderUploadSeedWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [], backing: .buffered, defer: false)
    var tab: FolderUploadSeedTab?
    var navigations: [String] = []
    @objc func window() -> NSWindow { value }
    @objc func tabs() -> [Any] { tab.map { [$0] } ?? [] }
    @objc func activeItemId() -> String? { tab?.itemId }
    @objc(checkNavigate:disposition:) func navigate(_ url: String, disposition: String) {
        #expect(disposition == "current")
        navigations.append(url)
    }
}

@Test @MainActor
func folderUploadNavigatesTheLoadedSeedOnceTheWindowIsVisible() {
    _ = NSApplication.shared
    class_addProtocol(FolderUploadSeedHost.self, objc_getProtocol("ARWindowHostAPI")!)
    class_addProtocol(FolderUploadSeedTab.self, objc_getProtocol("ARTabAPI")!)
    for screen in [false, true] {
        let runtime = Runtime(windowID: "folder-upload")
        runtime.browserCheckPhase = 1
        runtime.browserCheckSeedID = "seed"
        runtime.snapshot.selectedId = "seed"
        runtime.promptFixturePort = 12345
        let host = FolderUploadSeedHost()
        let tab = FolderUploadSeedTab()
        tab.itemId = "seed"
        host.tab = tab
        runtime.folderUploadCheckTick(host as! any ARWindowHostAPI, screen: screen)
        #expect(runtime.browserCheckPhase == 1 && host.navigations.isEmpty)
        host.value.reportedVisible = true
        runtime.folderUploadCheckTick(host as! any ARWindowHostAPI, screen: screen)
        #expect(runtime.browserCheckPhase == 2)
        #expect(host.navigations == ["http://127.0.0.1:12345/folder-upload"])
        #expect(runtime.folderUploadCheck?.conditions["seed"] == true)
        #expect(tab.url == "data:text/html,<title>Ararat One</title>")
    }
}

@Test @MainActor
func folderUploadSelectsItsSeedBeforeTheBrowserWindowIsVisible() throws {
    _ = NSApplication.shared
    class_addProtocol(FolderUploadSeedHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for screen in [false, true] {
        let runtime = Runtime(windowID: "folder-upload")
        let session = WorkspaceSession()
        _ = try EngineAdapter(path: directory.appendingPathComponent("\(screen).sqlite").path,
            windowID: runtime.windowID, card: NSView(), seedSingleCheck: true, session: session)
        runtime.snapshot = try #require(session.store).snapshot(windowId: runtime.windowID)
        runtime.promptFixturePort = 12345
        let host = FolderUploadSeedHost()
        #expect(!host.value.isVisible)
        runtime.folderUploadCheckTick(host as! any ARWindowHostAPI, screen: screen)
        #expect(runtime.browserCheckPhase == 1)
        #expect(runtime.browserCheckSeedID == runtime.snapshot.spaces.first?.today.first?.id)
        #expect(runtime.folderUploadCheck?.details["seed"] != nil)
        #expect(runtime.folderUploadCheck?.conditions["seed"] == nil)
        #expect(!host.value.isVisible)
    }
}
