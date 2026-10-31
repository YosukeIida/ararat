import AppKit
import CoreMedia
import ScreenCaptureKit

let args = CommandLine.arguments
let winX = Int(args[1])!, rowY = Int(args[2])!, stripW = Int(args[3])!
let steps = Array(args.dropFirst(4))
let t0 = DispatchTime.now().uptimeNanoseconds
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 }

final class Sink: NSObject, SCStreamOutput {
    let lock = NSLock()
    var last = -1
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = sb.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        let w = CVPixelBufferGetWidth(px)
        let p = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
        func rgb(_ x: Int) -> (Int, Int, Int) { (Int(p[x * 4 + 2]), Int(p[x * 4 + 1]), Int(p[x * 4])) }
        let ref = rgb(w - 2)
        var edge = 0
        for x in 0..<w {
            let c = rgb(x)
            if abs(c.0 - ref.0) + abs(c.1 - ref.1) + abs(c.2 - ref.2) > 24 { edge = x + 1 }
            else if x - edge > 6 { break }
        }
        lock.lock(); defer { lock.unlock() }
        if edge != last { print(String(format: "f %.1f %d", now(), edge)); last = edge }
    }
}

let sem = DispatchSemaphore(value: 0)
var stream: SCStream!
let sink = Sink()
Task {
    let content = try await SCShareableContent.current
    let display = content.displays.first!
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let cfg = SCStreamConfiguration()
    cfg.sourceRect = CGRect(x: winX, y: rowY, width: stripW, height: 1)
    cfg.width = stripW
    cfg.height = 1
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
for s in steps {
    let f = s.split(separator: ":")
    switch f[0] {
    case "m":
        let pt = CGPoint(x: Double(f[1])!, y: Double(f[2])!)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left)!.post(tap: .cghidEventTap)
        print(String(format: "m %.1f %.0f %.0f", now(), pt.x, pt.y))
    case "w":
        usleep(UInt32(Double(f[1])! * 1000))
    default: break
    }
}
let done = DispatchSemaphore(value: 0)
Task { try? await stream.stopCapture(); done.signal() }
done.wait()
