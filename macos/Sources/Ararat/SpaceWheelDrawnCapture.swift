import AppKit
import AraratUI
import ScreenCaptureKit
import CoreMedia
import Darwin
import Security

final class SpaceWheelDrawnCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let firstMotionLimit = 0.120
    enum Filter: String {
        case display, window

        static func selected(arguments: [String]) throws -> Filter {
            guard let argument = arguments.first(where: { $0.hasPrefix("--ararat-drawn-filter=") }) else { return .display }
            let value = String(argument.dropFirst("--ararat-drawn-filter=".count))
            guard let filter = Filter(rawValue: value) else {
                throw SpaceWheelMotionCheck.Failure(description: "drawn_filter value=\(value) expected=window|display")
            }
            return filter
        }
    }
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
    private var delivered: [[String: Any]] = []
    private var statusCounts: [String: Int] = [:]
    private var streamError: NSError?
    private var lastImage: [UInt8]?
    @MainActor private var geometry: [String: Any] = [:]
    @MainActor private var stream: SCStream?
    let width: Int
    let filterMode: Filter

    init(width: Int, filter: Filter = .display) { self.width = width; self.filterMode = filter }

    static func hostTime() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func samples() -> [Frame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    private func stoppedError() -> NSError? {
        lock.lock()
        defer { lock.unlock() }
        return streamError
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
        let displayRect = Self.sourceRect(windowFrame: selected.frame, windowHeight: window.frame.height, row: row, displayFrame: display.frame)
        let windowRect = CGRect(x: row.minX, y: window.frame.height - row.maxY, width: row.width, height: row.height)
        let sourceRect = filterMode == .display ? displayRect : windowRect
        let configuration = Self.configuration(width: width, sourceRect: sourceRect)
        let filter = filterMode == .display ? SCContentFilter(display: display, excludingWindows: [])
            : SCContentFilter(desktopIndependentWindow: selected)
        geometry = ["filter": filterMode.rawValue, "filter_content_rect": Self.rect(filter.contentRect),
                    "window_capture_rect": Self.rect(windowRect), "source_rect": Self.rect(sourceRect), "window_id": selected.windowID, "window_frame_quartz": Self.rect(selected.frame),
                    "window_frame_appkit": Self.rect(window.frame), "window_row_rect": Self.rect(row),
                    "display_id": display.displayID, "display_frame": Self.rect(display.frame),
                    "display_pixel_width": display.width, "display_pixel_height": display.height,
                    "display_scale_x": Double(display.width) / display.frame.width,
                    "display_scale_y": Double(display.height) / display.frame.height,
                    "window_backing_scale": window.backingScaleFactor, "filter_point_pixel_scale": filter.pointPixelScale,
                    "display_capture_rect": Self.rect(displayRect), "output_width": configuration.width,
                    "output_height": configuration.height, "preserves_aspect_ratio": configuration.preservesAspectRatio,
                    "pixel_format": configuration.pixelFormat]
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "ararat.wheel-drawn-frames"))
        self.stream = stream
        try await stream.startCapture()
        for _ in 0..<200 {
            if !samples().isEmpty { return }
            if let error = stoppedError() { throw error }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw SpaceWheelMotionCheck.Failure(description: "drawn_capture_frames count=0")
    }

    @MainActor
    func stop() async { try? await stream?.stopCapture(); stream = nil }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let error = error as NSError
        lock.lock()
        streamError = error
        lock.unlock()
        let value: [String: Any] = ["trace": "space-wheel-stream-stop", "domain": error.domain, "code": error.code,
                                     "description": error.localizedDescription, "filter": filterMode.rawValue]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10]))
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        record(sample, clock: stream.synchronizationClock)
    }

    func record(_ sample: CMSampleBuffer, clock: CMClock?) {
        let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first ?? [:]
        let rawStatus = (info[.status] as? NSNumber)?.intValue
        let status = rawStatus.flatMap(SCFrameStatus.init(rawValue:))
        let name: String
        switch status {
        case .complete: name = "complete"
        case .idle: name = "idle"
        case .blank: name = "blank"
        case .suspended: name = "suspended"
        case .started: name = "started"
        case .stopped: name = "stopped"
        default: name = rawStatus.map { "unknown-\($0)" } ?? "missing"
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let time = clock.flatMap { pts.isNumeric ? CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()).seconds : nil }
        var row: [String: Any] = ["status": name, "status_raw": rawStatus as Any? ?? NSNull(),
            "pts": time.flatMap { $0.isFinite ? $0 : nil } as Any? ?? NSNull(),
            "clock_available": clock != nil, "image_buffer": sample.imageBuffer != nil,
            "scale_factor": (info[.scaleFactor] as? NSNumber) as Any? ?? NSNull(),
            "content_scale": (info[.contentScale] as? NSNumber) as Any? ?? NSNull()]
        row["content_rect"] = info[.contentRect] as? [String: Any] ?? [:]
        lock.lock()
        defer { lock.unlock() }
        statusCounts[name, default: 0] += 1
        defer { delivered.append(row) }
        guard status == .complete || status == .started || status == .idle else {
            lastImage = nil
            row["accepted"] = false
            return
        }
        guard let time, time.isFinite else {
            lastImage = nil
            row["accepted"] = false
            row["drop_reason"] = "clock-or-pts"
            return
        }
        if status == .idle {
            // Why not read an idle image: no new image was generated, so only the preceding complete pixels are authoritative.
            guard let image = lastImage else {
                row["accepted"] = false
                row["drop_reason"] = "idle-without-reference"
                return
            }
            frames.append(Frame(time: time, bgra: image))
            row["accepted"] = true
            return
        }
        lastImage = nil
        guard let buffer = sample.imageBuffer else {
            row["accepted"] = false
            row["drop_reason"] = "no-image"
            return
        }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        lastBuffer = ["width": CVPixelBufferGetWidth(buffer), "height": CVPixelBufferGetHeight(buffer),
                      "bytes_per_row": CVPixelBufferGetBytesPerRow(buffer), "pixel_format": Int(format)]
        guard CVPixelBufferGetWidth(buffer) == width, format == kCVPixelFormatType_32BGRA else {
            row["accepted"] = false
            row["drop_reason"] = "image-format-or-width"
            return
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { row["accepted"] = false; return }
        let pixels = base.advanced(by: CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer))
            .assumingMemoryBound(to: UInt8.self)
        let bgra = Array(UnsafeBufferPointer(start: pixels, count: width * 4))
        lastImage = bgra
        frames.append(Frame(time: time, bgra: bgra))
        row["accepted"] = true
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
        let deliveries = delivered
        let counts = statusCounts
        let error = streamError
        lock.unlock()
        let origin = samples.first?.time ?? Self.hostTime()
        var value: [String: Any] = ["drawn_sample_count": samples.count, "drawn_width": width,
            "drawn_source": source, "drawn_expected_pattern": (0..<width).map { SpaceWheelDrawnPattern.white(space: source, x: $0) ? 255 : 0 },
            "drawn_rows": samples.map { ["pts": $0.time, "channels": $0.channels,
                "baseline_matches": SpaceWheelDrawnPattern.offset(pixels: $0.pixels, source: source, target: source, pitch: pitch) != nil] as [String: Any] },
            "drawn_geometry": geometry, "drawn_filter": filterMode.rawValue,
            "drawn_delivered_count": deliveries.count, "drawn_deliveries": deliveries, "drawn_status_counts": counts,
            "drawn_stream_error": error.map { ["domain": $0.domain, "code": $0.code, "description": $0.localizedDescription] as [String: Any] } as Any? ?? NSNull(),
            "drawn_last_buffer": buffer, "drawn_raw_time_origin": origin,
            "drawn_process": Self.processInfo(), "screen_capture_preflight": CGPreflightScreenCaptureAccess()]
        do { value["drawn_raw_path"] = try save(relativeTo: origin, directory: directory) }
        catch { value["drawn_raw_error"] = String(describing: error) }
        return value
    }

    static func processInfo() -> [String: Any] {
        func process(_ pid: pid_t) -> [String: Any] {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let size = proc_pidpath(pid, &path, UInt32(path.count))
            let executable = size > 0 ? String(cString: path) : "unavailable"
            return ["pid": pid, "path": executable, "name": URL(fileURLWithPath: executable).lastPathComponent]
        }
        var value: [String: Any] = ["self": process(getpid()), "parent": process(getppid()),
                                     "bundle_id": Bundle.main.bundleIdentifier as Any? ?? NSNull()]
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var status = SecCodeCopySelf([], &code)
        if status == errSecSuccess, let code { status = SecCodeCopyStaticCode(code, [], &staticCode) }
        if status == errSecSuccess, let staticCode {
            status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        }
        value["signing_status"] = status
        if let info = info as? [String: Any] {
            value["signing_identifier"] = info[kSecCodeInfoIdentifier as String]
            value["signing_flags"] = info[kSecCodeInfoFlags as String]
            value["cdhash"] = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        }
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
