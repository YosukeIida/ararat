import AppKit
import Testing
@testable import Ararat

@Test @MainActor
func commandBarTimeoutDiagnosticsAreSerializableWithoutAHost() throws {
    _ = NSApplication.shared
    let runtime = Runtime(windowID: "commandbar-diagnostics")
    runtime.browserCheckPhase = 11
    let diagnostics = runtime.commandBarCheckDiagnostics()
    #expect(diagnostics["phase"] as? Int == 11)
    #expect(diagnostics["bar_open"] as? Bool == false)
    #expect(diagnostics["switcher_open"] as? Bool == false)
    #expect(diagnostics["key_window"] != nil)
    #expect(diagnostics["first_responder"] != nil)
    #expect(diagnostics["bar_rows"] != nil)
    _ = try JSONSerialization.data(withJSONObject: diagnostics)
}
