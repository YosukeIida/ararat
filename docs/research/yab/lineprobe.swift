import AppKit
import CoreMedia
import ScreenCaptureKit

// lineprobe <out> <x> <y> <w> <h> <step>...  (w or h is 1)
// Saves every captured frame of the line as: f64 ms, then w*h RGB bytes. Steps, on the same clock:
//   m:x:y (pointer move)  w:ms (wait)  k:keycode[:cmd] (key down+up)
//   l:lines (wheel event, no phase, at the pointer)  p:px:phase:momentum (trackpad event at the pointer)
//   o:text (print a marker)  x:shell command (run, print start and end)
let a = CommandLine.arguments
let out = FileHandle(forWritingAtPath: { FileManager.default.createFile(atPath: a[1], contents: nil); return a[1] }())!
let x = Int(a[2])!, y = Int(a[3])!, w = Int(a[4])!, h = Int(a[5])!
let t0 = DispatchTime.now().uptimeNanoseconds
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }
var pointer = CGPoint(x: x, y: y)

final class Sink: NSObject, SCStreamOutput {
    let lock = NSLock()
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = sb.imageBuffer else { return }
        let t = now()
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(px)
        let p = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        var d = Data(count: 8 + w * h * 3)
        d.withUnsafeMutableBytes { b in
            b.storeBytes(of: t, as: Double.self)
            var i = 8
            for r in 0..<h { for c in 0..<w {
                let o = r * bpr + c * 4
                b[i] = p[o + 2]; b[i + 1] = p[o + 1]; b[i + 2] = p[o]; i += 3
            } }
        }
        lock.lock(); out.write(d); lock.unlock()
    }
}

let sem = DispatchSemaphore(value: 0)
var stream: SCStream!
let sink = Sink()
Task {
    let content = try await SCShareableContent.current
    let filter = SCContentFilter(display: content.displays.first!, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = CGRect(x: x, y: y, width: w, height: h)
    cfg.width = w; cfg.height = h
    cfg.showsCursor = false
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    cfg.pixelFormat = kCVPixelFormatType_32BGRA
    stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
    try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
    try await stream.startCapture()
    sem.signal()
}
sem.wait()
usleep(300_000)
func scroll(_ units: CGScrollEventUnit, _ d: Int32, cont: Bool, phase: Int64, mom: Int64) {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: 0, wheel2: d, wheel3: 0)!
    e.location = pointer
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: cont ? 1 : 0)
    if cont {
        e.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(d))
        e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(d))
    }
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: mom)
    e.post(tap: .cghidEventTap)
}
for s in a.dropFirst(6) {
    let f = s.split(separator: ":", maxSplits: 3).map(String.init)
    switch f[0] {
    case "m":
        pointer = CGPoint(x: Double(f[1])!, y: Double(f[2])!)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pointer, mouseButton: .left)!.post(tap: .cghidEventTap)
    case "w": usleep(UInt32(Double(f[1])! * 1000))
    case "k":
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(f[1])!, keyDown: down)!
            if f.count > 2 { e.flags = .maskCommand }
            e.post(tap: .cghidEventTap)
        }
    case "l": scroll(.line, Int32(f[1])!, cont: false, phase: 0, mom: 0)
    case "p": scroll(.pixel, Int32(f[1])!, cont: true, phase: Int64(f[2])!, mom: Int64(f[3])!)
    case "x":
        print(String(format: "x-start %.1f", now()))
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: "/bin/sh"); pr.arguments = ["-c", f.dropFirst().joined(separator: ":")]
        try! pr.run(); pr.waitUntilExit()
        print(String(format: "x-end %.1f", now()))
    case "o": print(String(format: "o %.1f %@", now(), f[1]))
    default: break
    }
    if !["w", "o", "x"].contains(f[0]) { print(String(format: "%@ %.1f", s, now())) }
}
usleep(100_000)
let done = DispatchSemaphore(value: 0)
Task { try? await stream.stopCapture(); done.signal() }
done.wait()
