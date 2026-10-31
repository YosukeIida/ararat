import CoreGraphics
import Foundation
// scrollrec <seconds>: prints every scroll event system-wide, listen-only.
let t0 = DispatchTime.now().uptimeNanoseconds
let cb: CGEventTapCallBack = { _, _, e, _ in
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    print(String(format: "%.1f cont=%lld line=%lld,%lld pt=%lld,%lld fix=%.2f,%.2f phase=%lld mom=%lld inv=%lld",
        ms, e.getIntegerValueField(.scrollWheelEventIsContinuous),
        e.getIntegerValueField(.scrollWheelEventDeltaAxis1), e.getIntegerValueField(.scrollWheelEventDeltaAxis2),
        e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2),
        e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1), e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
        e.getIntegerValueField(.scrollWheelEventScrollPhase), e.getIntegerValueField(.scrollWheelEventMomentumPhase),
        e.getIntegerValueField(CGEventField(rawValue: 137)!)))
    fflush(stdout)
    return Unmanaged.passUnretained(e)
}
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                  eventsOfInterest: CGEventMask(1 << CGEventType.scrollWheel.rawValue), callback: cb, userInfo: nil) else {
    FileHandle.standardError.write(Data("cannot create event tap (Input Monitoring permission?)\n".utf8)); exit(1)
}
CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
CFRunLoopRunInMode(.defaultMode, Double(CommandLine.arguments[1])!, false)
