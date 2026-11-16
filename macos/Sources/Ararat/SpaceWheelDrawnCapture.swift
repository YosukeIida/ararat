import AppKit
import AraratUI
import ScreenCaptureKit
import CoreMedia

final class SpaceWheelDrawnCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    struct Frame {
        let time: Double
        let pixels: [UInt8]
    }
    struct Switch {
        let time: Double
        let source: Int
        let target: Int
        let pitch: Int
    }
    private let lock = NSLock()
    private var frames: [Frame] = []
    @MainActor private var stream: SCStream?
    let width: Int

    init(width: Int) { self.width = width }

    func samples() -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    @MainActor
    func start(window: NSWindow, row: NSRect) async throws {
        let content = try await SCShareableContent.current
        guard let selected = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw SpaceWheelMotionCheck.Failure(description: "drawn_capture_window missing id=\(window.windowNumber)")
        }
        let center = CGPoint(x: selected.frame.midX, y: selected.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) else {
            throw SpaceWheelMotionCheck.Failure(description: "drawn_capture_display missing window=\(selected.frame)")
        }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: selected.frame.minX + row.minX - display.frame.minX,
            y: selected.frame.minY + window.frame.height - row.maxY - display.frame.minY, width: row.width, height: row.height)
        configuration.width = width
        configuration.height = 1
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ararat.wheel-drawn-frames"))
        self.stream = stream
        try await stream.startCapture()
        for _ in 0..<200 {
            if !samples().isEmpty { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SpaceWheelMotionCheck.Failure(description: "drawn_capture_frames count=0")
    }

    @MainActor
    func stop() async { try? await stream?.stopCapture(); stream = nil }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buffer = sample.imageBuffer, CVPixelBufferGetWidth(buffer) == width else { return }
        let time = CACurrentMediaTime()
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let row = base.advanced(by: CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let pixels = (0..<width).map { row[$0 * 4] }
        lock.lock()
        frames.append(Frame(time: time, pixels: pixels))
        lock.unlock()
    }

    @MainActor
    static func conditions(_ samples: [Frame], switches: [Switch]) -> [String: Bool] {
        var conditions: [String: Bool] = [:]
        for (index, step) in switches.enumerated() {
            let end = switches.indices.contains(index + 1) ? switches[index + 1].time : .infinity
            let from = Double((step.target - step.source) * step.pitch)
            var frames: [SpaceWheelMotionCurve.Frame] = []
            for sample in samples where sample.time >= step.time && sample.time < end {
                guard let offset = SpaceWheelDrawnPattern.offset(pixels: sample.pixels, source: step.source, target: step.target, pitch: step.pitch) else { continue }
                if frames.isEmpty && abs(offset - from) <= 2 { continue }
                frames.append(.init(t: sample.time - step.time, offset: offset))
            }
            var verdict = SpaceWheelMotionCurve.conditions(frames: frames, from: from, pitch: Double(step.pitch))
            if index + 1 < switches.count { verdict.removeValue(forKey: "landed") }
            conditions.merge(verdict) { $0 && $1 }
            let value: [String: Any] = ["trace": "space-wheel-drawn", "switch": index + 1,
                "start": step.time, "pitch": step.pitch, "clock": "capture-callback-uptime",
                "source": step.source, "target": step.target, "conditions": verdict,
                "samples": frames.map { ["t": $0.t, "offset": $0.offset] }]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10]))
            }
        }
        return conditions
    }

    func save(relativeTo time: Double) throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ararat-wheel-drawn-\(UUID().uuidString).raw")
        var data = Data()
        for frame in samples() {
            var stamp = (frame.time - time) * 1000
            withUnsafeBytes(of: &stamp) { data.append(contentsOf: $0) }
            for pixel in frame.pixels { data.append(contentsOf: [pixel, pixel, pixel]) }
        }
        try data.write(to: path, options: .atomic)
        return path.path
    }
}
