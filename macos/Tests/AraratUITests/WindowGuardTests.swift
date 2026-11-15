import CoreGraphics
import Testing
@testable import WindowGuard

@Test
func testProcessStaysWindowlessAtExit() {
    #expect(installWindowGuard() == 0)
    let windows: [[String: Any]] = [
        [kCGWindowOwnerPID as String: 123, kCGWindowIsOnscreen as String: true, kCGWindowName as String: "Leak"],
        [kCGWindowOwnerPID as String: 123, kCGWindowIsOnscreen as String: false],
        [kCGWindowOwnerPID as String: 456, kCGWindowIsOnscreen as String: true],
    ]
    #expect(ownOnscreenWindows(windows, pid: 123) == ["Leak (#?)"])
}
