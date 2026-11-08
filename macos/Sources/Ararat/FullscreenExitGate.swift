@MainActor
final class FullscreenExitGate {
  private(set) var armed = false
  private(set) var exited = false

  func arm() {
    exited = false
    armed = true
  }

  func didExit() {
    guard armed else { return }
    exited = true
    armed = false
  }

  func ready(transitioning: Bool?) -> Bool {
    exited && transitioning == false
  }
}
