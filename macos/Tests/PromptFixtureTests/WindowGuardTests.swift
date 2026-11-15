import Testing
import WindowGuard

@Test
func testProcessStaysWindowlessAtExit() {
    #expect(installWindowGuard() == 0)
}
