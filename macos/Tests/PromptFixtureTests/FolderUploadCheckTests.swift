import AppKit
import AraratEngineAPI
import AraratKit
import ObjectiveC.runtime
import Testing
@testable import Ararat

@MainActor private final class FolderUploadSeedHost: NSObject {
    let value = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [], backing: .buffered, defer: false)
    @objc func window() -> NSWindow { value }
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
