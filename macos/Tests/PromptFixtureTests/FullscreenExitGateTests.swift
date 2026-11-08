import Testing
@testable import Ararat

@Test @MainActor
func fullscreenExitGateRequiresNewExitAndTransitionCompletion() {
    let gate = FullscreenExitGate()
    gate.didExit()
    #expect(!gate.ready(transitioning: false))
    gate.arm()
    #expect(!gate.ready(transitioning: false))
    gate.didExit()
    #expect(!gate.ready(transitioning: nil))
    #expect(!gate.ready(transitioning: true))
    #expect(gate.ready(transitioning: false))
    gate.arm()
    #expect(!gate.ready(transitioning: false))
}
