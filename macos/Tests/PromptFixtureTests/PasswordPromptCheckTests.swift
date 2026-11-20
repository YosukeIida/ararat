import Foundation
import Testing
@testable import Ararat

@Test @MainActor
func passwordCaptureRequiresTwoMatchingOpaqueSamples() {
    let frame = CGRect(x: 100, y: 200, width: 448, height: 204)
    typealias Sample = PasswordPromptCheck.CaptureSample
    let opaque = Sample(window: 42, frame: frame, alpha: 1)
    #expect(!opaque.isSettled(after: nil))
    #expect(!opaque.isSettled(after: Sample(window: 42, frame: frame, alpha: nil)))
    #expect(!opaque.isSettled(after: Sample(window: 42, frame: frame, alpha: 0.99)))
    #expect(!opaque.isSettled(after: Sample(window: 42, frame: frame.offsetBy(dx: 0, dy: 1), alpha: 1)))
    #expect(!opaque.isSettled(after: Sample(window: 43, frame: frame, alpha: 1)))
    let transparent = Sample(window: 42, frame: frame, alpha: 0.99)
    #expect(!transparent.isSettled(after: transparent))
    #expect(opaque.isSettled(after: opaque))
}
