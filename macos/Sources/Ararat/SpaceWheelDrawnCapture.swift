import AppKit
import AraratUI
import ScreenCaptureKit
import CoreMedia
import Darwin

final class SpaceWheelDrawnCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    static let firstMotionLimit = 0.120
    struct Frame {
        let time: Double
        let bgra: [UInt8]
        var pixels: [UInt8] { stride(from: 0, to: bgra.count, by: 4).map { bgra[$0] } }

        var channels: [String: [String: Double]] {
            Dictionary(uniqueKeysWithValues: ["b", "g", "r", "a"].enumerated().map { index, name in
                let values = stride(from: index, to: bgra.count, by: 4).map { Double(bgra[$0]) }
                return (name, ["min": values.min() ?? 0, "max": values.max() ?? 0,
                               "mean": values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)])
            })
        }
    }
    struct Switch {
        let time: Double
        let source: Int
        let target: Int
        let pitch: Int
    }
    private let lock = NSLock()
    private var frames: [Frame] = []
    private var lastBuffer: [String: Int] = [:]
    @MainActor private var geometry: [String: Any] = [:]
    @MainActor private var stream: SCStream?
    let width: Int

    init(width: Int) { self.width = width }

    static func hostTime() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

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
        let sourceRect = Self.sourceRect(windowFrame: selected.frame, windowHeight: window.frame.height, row: row, displayFrame: display.frame)
        let configuration = Self.configuration(width: width, sourceRect: sourceRect)
        let filter = SCContentFilter(display: display, excludingWindows: [])
        geometry = ["window_id": selected.windowID, "window_frame_quartz": Self.rect(selected.frame),
                    "window_frame_appkit": Self.rect(window.frame), "window_row_rect": Self.rect(row),
                    "display_id": display.displayID, "display_frame": Self.rect(display.frame),
                    "display_pixel_width": display.width, "display_pixel_height": display.height,
                    "display_scale_x": Double(display.width) / display.frame.width,
                    "display_scale_y": Double(display.height) / display.frame.height,
                    "window_backing_scale": window.backingScaleFactor, "filter_point_pixel_scale": filter.pointPixelScale,
                    "display_capture_rect": Self.rect(sourceRect), "output_width": configuration.width,
                    "output_height": configuration.height, "preserves_aspect_ratio": configuration.preservesAspectRatio,
                    "pixel_format": configuration.pixelFormat]
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
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
        guard type == .screen, let clock = stream.synchronizationClock else { return }
        record(sample, clock: clock)
    }

    func record(_ sample: CMSampleBuffer, clock: CMClock) {
        guard let buffer = sample.imageBuffer else { return }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        lock.lock()
        lastBuffer = ["width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
                      "bytes_per_row": CVPixelBufferGetBytesPerRow(buffer), "pixel_format": Int(format)]
        lock.unlock()
        guard CVPixelBufferGetWidth(buffer) == width, format == kCVPixelFormatType_32BGRA else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return }
        let time = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
        guard time.isFinite else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let row = base.advanced(by: CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let bgra = Array(UnsafeBufferPointer(start: row, count: width * 4))
        lock.lock()
        frames.append(Frame(time: time, bgra: bgra))
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
            verdict["first_motion_within_120ms"] = frames.first.map { $0.t <= firstMotionLimit } ?? false
            if index + 1 < switches.count { verdict.removeValue(forKey: "landed") }
            conditions.merge(verdict) { $0 && $1 }
            let value: [String: Any] = ["trace": "space-wheel-drawn", "switch": index + 1,
                "start": step.time, "pitch": step.pitch, "clock": "sample-pts-in-host-clock",
                "first_drawn_change": frames.first.map { step.time + $0.t } as Any? ?? NSNull(),
                "event_to_first_motion_ms": frames.first.map { $0.t * 1000 } as Any? ?? NSNull(),
                "first_motion_limit_ms": firstMotionLimit * 1000,
                "source": step.source, "target": step.target, "conditions": verdict,
                "samples": frames.map { ["t": $0.t, "offset": $0.offset] }]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
                FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10]))
            }
        }
        return conditions
    }

    static func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }

    static func sourceRect(windowFrame: CGRect, windowHeight: Double, row: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(x: windowFrame.minX + row.minX - displayFrame.minX,
               y: windowFrame.minY + windowHeight - row.maxY - displayFrame.minY, width: row.width, height: row.height)
    }

    static func configuration(width: Int, sourceRect: CGRect) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = width
        configuration.height = 1
        // Why not preserve aspect ratio: a four-point strip compressed to one pixel would also shrink the barcode horizontally.
        configuration.preservesAspectRatio = false
        configuration.showsCursor = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 240)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        return configuration
    }

    static func resultDirectory() -> URL {
        var info = stat()
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(STDOUT_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              fcntl(STDOUT_FILENO, F_GETPATH, &path) != -1 else { return FileManager.default.temporaryDirectory }
        return URL(fileURLWithPath: String(cString: path)).deletingLastPathComponent()
    }

    @MainActor
    func diagnostics(source: Int, pitch: Int, directory: URL) -> [String: Any] {
        let samples = samples()
        lock.lock()
        let buffer = lastBuffer
        lock.unlock()
        let origin = samples.first?.time ?? Self.hostTime()
        var value: [String: Any] = ["drawn_sample_count": samples.count, "drawn_width": width,
            "drawn_source": source, "drawn_expected_pattern": (0..<width).map { SpaceWheelDrawnPattern.white(space: source, x: $0) ? 255 : 0 },
            "drawn_rows": samples.map { ["pts": $0.time, "channels": $0.channels,
                "baseline_matches": SpaceWheelDrawnPattern.offset(pixels: $0.pixels, source: source, target: source, pitch: pitch) != nil] as [String: Any] },
            "drawn_geometry": geometry, "drawn_last_buffer": buffer, "drawn_raw_time_origin": origin,
            "screen_capture_preflight": CGPreflightScreenCaptureAccess()]
        do { value["drawn_raw_path"] = try save(relativeTo: origin, directory: directory) }
        catch { value["drawn_raw_error"] = String(describing: error) }
        return value
    }

    func save(relativeTo time: Double, directory: URL) throws -> String {
        let path = directory.appendingPathComponent("ararat-wheel-drawn-\(UUID().uuidString).raw")
        var data = Data()
        for frame in samples() {
            var stamp = (frame.time - time) * 1000
            withUnsafeBytes(of: &stamp) { data.append(contentsOf: $0) }
            for index in stride(from: 0, to: frame.bgra.count, by: 4) {
                data.append(contentsOf: [frame.bgra[index + 2], frame.bgra[index + 1], frame.bgra[index]])
            }
        }
        try data.write(to: path, options: .atomic)
        return path.path
    }
}
