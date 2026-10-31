import CoreGraphics
import Foundation
// scroll <x> <y> wheel <lines>            horizontal mouse-wheel lines (no phase)
// scroll <x> <y> pad <px per step> <steps> <momentum steps>   trackpad-style gesture with momentum
let a = CommandLine.arguments
let pt = CGPoint(x: Double(a[1])!, y: Double(a[2])!)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(100_000)
func post(_ units: CGScrollEventUnit, _ dx: Int32, phase: Int64 = 0, momentum: Int64 = 0, continuous: Bool) {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: 0, wheel2: dx, wheel3: 0)!
    e.location = pt
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
    if continuous {
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
    }
    if ProcessInfo.processInfo.environment["INV"] == "1" { e.setIntegerValueField(CGEventField(rawValue: 137)!, value: 1) }
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
    e.post(tap: .cghidEventTap)
}
if a[3] == "wheel" {
    let n = Int(a[4])!
    for _ in 0..<abs(n) { post(.line, n > 0 ? 1 : -1, continuous: false); usleep(30_000) }
} else {
    let px = Int32(a[4])!, steps = Int(a[5])!, mom = Int(a[6])!
    post(.pixel, 0, phase: 128, continuous: true)  // may-begin
    for i in 0..<steps { post(.pixel, px, phase: i == 0 ? 1 : 2, continuous: true); usleep(8_000) }
    post(.pixel, 0, phase: 4, continuous: true)
    var v = Double(px)
    for i in 0..<mom {
        v *= 0.93
        post(.pixel, Int32(v.rounded()), momentum: i == 0 ? 1 : (i == mom - 1 ? 3 : 2), continuous: true)
        usleep(8_000)
    }
}
