import AppKit
import AraratEngineAPI
import AraratKit
import ObjectiveC.runtime
import Testing
@testable import Ararat

@Test @MainActor
func chooserSettleTimeoutStopsWaitingAndFailsOnlyTheCapture() {
    let check = FolderUploadCheckState()
    for _ in 0..<119 { #expect(check.shouldWaitForChooser(settled: false)) }
    #expect(check.conditions["capture_chooser"] == nil)
    #expect(!check.shouldWaitForChooser(settled: false))
    #expect(check.chooserSettleTicks == 120)
    #expect(check.conditions == ["capture_chooser": false])
    #expect(check.details["capture_error"] as? String == "chooser_settle_timeout")
    let settled = FolderUploadCheckState()
    #expect(!settled.shouldWaitForChooser(settled: true))
    #expect(settled.chooserSettleTicks == 0 && settled.conditions.isEmpty)
}

@Test @MainActor
func chooserSettleRequiresStableOpaqueFrameAndANewOnscreenWindow() {
    let frame = NSRect(x: 100, y: 200, width: 600, height: 400)
    #expect(!FolderUploadCheckState.chooserSettled(frame: frame, previous: nil, alpha: 1, window: 42, previousWindow: 42))
    #expect(!FolderUploadCheckState.chooserSettled(frame: frame, previous: frame.offsetBy(dx: 1, dy: 0), alpha: 1, window: 42, previousWindow: 42))
    #expect(!FolderUploadCheckState.chooserSettled(frame: frame, previous: frame, alpha: 0.99, window: 42, previousWindow: 42))
    #expect(!FolderUploadCheckState.chooserSettled(frame: frame, previous: frame, alpha: 1, window: nil, previousWindow: nil))
    #expect(!FolderUploadCheckState.chooserSettled(frame: frame, previous: frame, alpha: 1, window: 42, previousWindow: nil))
    #expect(FolderUploadCheckState.chooserSettled(frame: frame, previous: frame, alpha: 1, window: 42, previousWindow: 42))
    var row: [String: Any] = [kCGWindowIsOnscreen as String: true, kCGWindowLayer as String: 0,
        kCGWindowNumber as String: 42, kCGWindowOwnerName as String: "Open and Save Panel Service", kCGWindowAlpha as String: 1.0,
        kCGWindowBounds as String: ["X": 100.0, "Y": 480.0, "Width": 600.0, "Height": 400.0]]
    #expect(FolderUploadCheckState.chooserWindow(frame: frame, screenTop: 1080, windows: [row], excluding: []) != nil)
    #expect(FolderUploadCheckState.chooserWindow(frame: frame, screenTop: 1080, windows: [row], excluding: [42]) == nil)
    row[kCGWindowIsOnscreen as String] = false
    #expect(FolderUploadCheckState.chooserWindow(frame: frame, screenTop: 1080, windows: [row], excluding: []) == nil)
    row[kCGWindowIsOnscreen as String] = true
    row[kCGWindowLayer as String] = 1
    #expect(FolderUploadCheckState.chooserWindow(frame: frame, screenTop: 1080, windows: [row], excluding: []) == nil)
    row[kCGWindowLayer as String] = 0
    row[kCGWindowAlpha as String] = 0.5
    #expect(FolderUploadCheckState.chooserWindow(frame: frame, screenTop: 1080, windows: [row], excluding: []) == nil)
}

@Test @MainActor
func chooserImageEvidenceRejectsUnchangedAndTinyPixelDifferences() throws {
    func image(patch: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: patch, height: patch))
        return try #require(context.makeImage())
    }
    let before = try image(patch: 0)
    let identical = try #require(FolderUploadCheckState.chooserDifference(before, before))
    #expect(identical.value == 0 && !identical.changed)
    let noise = try #require(FolderUploadCheckState.chooserDifference(before, image(patch: 1)))
    #expect(noise.value > 0 && !noise.changed)
    let panel = try #require(FolderUploadCheckState.chooserDifference(before, image(patch: 100)))
    #expect(panel.value == 1 && panel.changed)
    let source = NSRect(x: -100, y: 0, width: 100, height: 100)
    let crop = try #require(FolderUploadCheckState.cropBefore(before, source: source, region: source))
    #expect(crop.width == 100 && crop.height == 100)
    #expect(FolderUploadCheckState.cropBefore(before, source: source, region: source.offsetBy(dx: 1, dy: 0)) == nil)
}

@Test @MainActor
func chooserCaptureUsesThePanelRegionInGlobalTopDownPoints() {
    #expect(FolderUploadCheckState.chooserCaptureArguments(frame: NSRect(x: 100, y: 200, width: 600, height: 400), screenTop: 1080, path: "chooser.png")
        == ["-x", "-R100,480,600,400", "chooser.png"])
    #expect(FolderUploadCheckState.chooserCaptureArguments(frame: NSRect(x: -500, y: 1100, width: 400, height: 300), screenTop: 1080, path: "chooser.png")
        == ["-x", "-R-500,-320,400,300", "chooser.png"])
    #expect(FolderUploadCheckState.chooserCaptureArguments(frame: NSRect(x: 100.5, y: 200.5, width: 600, height: 400), screenTop: 1080, path: "chooser.png")
        == ["-x", "-R100,479,601,401", "chooser.png"])
}

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
