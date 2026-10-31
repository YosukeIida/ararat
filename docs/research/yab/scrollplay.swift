import CoreGraphics
import Foundation
// scrollplay <rec> <fromMs> <toMs> <x> <y>: re-posts recorded scroll events (scrollrec format) with their timing.
let a = CommandLine.arguments
let from = Double(a[2])!, to = Double(a[3])!
let pt = CGPoint(x: Double(a[4])!, y: Double(a[5])!)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
usleep(100_000)
func pair(_ s: Substring) -> (String, String) { let p = s.split(separator: "=")[1].split(separator: ","); return (String(p[0]), String(p[1])) }
var prev: Double? = nil
for line in try! String(contentsOfFile: a[1], encoding: .utf8).split(separator: "\n") {
    let f = line.split(separator: " ")
    let t = Double(f[0])!
    if t < from || t > to { continue }
    if let p = prev { usleep(useconds_t(max(0, (t - p) * 1000))) }
    prev = t
    let v = Dictionary(uniqueKeysWithValues: f.dropFirst().map { ($0.split(separator: "=")[0], $0) })
    let cont = v["cont"]!.hasSuffix("=1")
    let (l1, l2) = pair(v["line"]!), (p1, p2) = pair(v["pt"]!), (x1, x2) = pair(v["fix"]!)
    let e = CGEvent(scrollWheelEvent2Source: nil, units: cont ? .pixel : .line, wheelCount: 2,
                    wheel1: Int32(cont ? p1 : l1)!, wheel2: Int32(cont ? p2 : l2)!, wheel3: 0)!
    e.location = pt
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: cont ? 1 : 0)
    e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(l1)!)
    e.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(l2)!)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(p1)!)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(p2)!)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(x1)!)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(x2)!)
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(v["phase"]!.split(separator: "=")[1])!)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(v["mom"]!.split(separator: "=")[1])!)
    e.setIntegerValueField(CGEventField(rawValue: 137)!, value: Int64(v["inv"]!.split(separator: "=")[1])!)
    e.post(tap: .cghidEventTap)
}
