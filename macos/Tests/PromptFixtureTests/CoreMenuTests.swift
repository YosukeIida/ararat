import AppKit
import AraratKit
import AraratEngineAPI
import ObjectiveC.runtime
import Testing
@testable import Ararat

// U27b: `installCoreMenu` builds the Ararat Commands menu from `Runtime.coreMenuCommandIDs`.
// A table command that is missing from the list keeps its Shortcuts row and the command bar's row
// but has no menu item, so a recorded key would never fire. Reading the list here is the only way
// to assert the menu without launching the app.
@Test @MainActor
func theAraratCommandsMenuCarriesClearCacheAndClearCookiesUnbound() throws {
    let table = defaultKeyBindings()
    for (id, title) in [("clear_cache_site", "Clear Cache"), ("clear_cookies_site", "Clear Cookies")] {
        #expect(Runtime.coreMenuCommandIDs.contains(id))
        let row = try #require(table.first { $0.command == id })
        #expect(row.title == title)
        #expect(row.key == nil && row.defaultKey == nil)
        #expect(row.customized == false)
    }
    // Every id the menu installs resolves to a table command, so no item is added half-built.
    for id in Runtime.coreMenuCommandIDs {
        #expect(table.contains { $0.command == id }, "\(id)")
    }
}

// The smallest host that survives the dispatcher's prologue: it answers the two closing
// questions and records what it was asked to run.
@MainActor private final class SiteCommandHost: NSObject {
    var commands: [String] = []
    @objc(isClosing) func isClosing() -> Bool { false }
    @objc(isClosingAll) func isClosingAll() -> Bool { false }
    @objc(runCommand:) func runCommand(_ command: String) -> Bool { commands.append(command); return true }
}

@Test @MainActor
func theDispatcherRunsBothSiteCommandsThroughTheHost() {
    // U27b: one dispatcher. The header … menu's ids, the Ararat Commands menu's items, the
    // command bar's rows and a recorded key all end in `performWorkspaceCommand`, and it hands
    // the same id to the engine's `runCommand`. The engine's own clear path is the header
    // check's `clear` and its `checkSiteClearResults`, so no new VM condition is needed here.
    _ = NSApplication.shared
    let runtime = Runtime(windowID: "core-menu-dispatch")
    class_addProtocol(SiteCommandHost.self, objc_getProtocol("ARWindowHostAPI")!)
    let host = SiteCommandHost()
    runtime.host = host as? any ARWindowHostAPI
    runtime.performWorkspaceCommand("clear_cache_site")
    runtime.performWorkspaceCommand("clear_cookies_site")
    #expect(host.commands == ["clear_cache_site", "clear_cookies_site"])
}
