import AraratUI
import Testing
import CoreMedia
import CoreVideo
import ScreenCaptureKit
@testable import Ararat

private func drawnPixels(source: Int, target: Int, pitch: Int, width: Int, offset: Int) -> [UInt8] {
    let from = (target - source) * pitch
    return (0..<width).map { x in
        let incoming = x - offset
        let outgoing = x + from - offset
        if (0..<width).contains(incoming) { return SpaceWheelDrawnPattern.white(space: target, x: incoming) ? 255 : 0 }
        if (0..<width).contains(outgoing) { return SpaceWheelDrawnPattern.white(space: source, x: outgoing) ? 255 : 0 }
        return 127
    }
}

private func drawnFrame(time: Double, pixels: [UInt8]) -> SpaceWheelDrawnCapture.Frame {
    SpaceWheelDrawnCapture.Frame(time: time, bgra: pixels.flatMap { [$0, $0, $0, 255] })
}

@Test
func capturedRowDecodesBothDirectionsAndRejectsUnrecognizedPixels() {
    for (source, target) in [(4, 3), (3, 4)] {
        let from = (target - source) * 260
        for part in [0, 10, 112, 210, 260] {
            let offset = from < 0 ? -part : part
            let pixels = drawnPixels(source: source, target: target, pitch: 260, width: 244, offset: offset)
            #expect(SpaceWheelDrawnPattern.offset(pixels: pixels, source: source, target: target, pitch: 260) == Double(offset))
        }
    }
    #expect(SpaceWheelDrawnPattern.offset(pixels: Array(repeating: 127, count: 244), source: 4, target: 3, pitch: 260) == nil)
}

@Test @MainActor
func drawnFrameGateRejectsPartialStartsAndAcceptsContinuousMotion() {
    let step = SpaceWheelDrawnCapture.Switch(time: 0, source: 4, target: 3, pitch: 260)
    let partial = [(0.0, -260), (0.09, -260), (0.11, -100), (0.15, -60), (0.2, -20), (0.3, 0)].map { time, offset in
        drawnFrame(time: time, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
    }
    let verdict = SpaceWheelDrawnCapture.conditions(partial, switches: [step])
    #expect(verdict["first_frame_full_offset"] == false)
    #expect(verdict["landed"] == true)
    let complete = [(0.0, -260), (0.09, -260), (0.1, -250), (0.1167, -220), (0.1334, -190),
                    (0.15, -150), (0.1667, -110), (0.1834, -80), (0.2, -55), (0.2167, -30),
                    (0.2334, -15), (0.25, -5), (0.3, 0)].map { time, offset in
        drawnFrame(time: time, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
    }
    #expect(SpaceWheelDrawnCapture.conditions(complete, switches: [step]).values.allSatisfy { $0 })
}


@Test @MainActor
func drawnFrameLatencyRejectsALateContinuousStartIncludingItsStillFrames() {
    let step = SpaceWheelDrawnCapture.Switch(time: 0, source: 4, target: 3, pitch: 260)
    func curve(firstMotion: Double) -> [SpaceWheelDrawnCapture.Frame] {
        let offsets = [-250, -220, -190, -150, -110, -80, -55, -30, -15, -5, 0]
        let still = drawnFrame(time: 0, pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: -260))
        return [still] + offsets.enumerated().map { index, offset in
            drawnFrame(time: firstMotion + Double(index) / 60,
                pixels: drawnPixels(source: 4, target: 3, pitch: 260, width: 244, offset: offset))
        }
    }
    let late = SpaceWheelDrawnCapture.conditions(curve(firstMotion: 0.1275), switches: [step])
    #expect(late.values.contains(false))
    #expect(late["first_motion_within_120ms"] == false)
    #expect(late.filter { $0.key != "first_motion_within_120ms" }.values.allSatisfy { $0 })
    #expect(SpaceWheelDrawnCapture.conditions(curve(firstMotion: 0.120), switches: [step]).values.allSatisfy { $0 })
    #expect(SpaceWheelDrawnCapture.conditions(curve(firstMotion: 0.100), switches: [step]).values.allSatisfy { $0 })
}

private func captureSample(bgra: [UInt8], time: CMTime, status: SCFrameStatus = .complete) throws -> CMSampleBuffer {
    var buffer: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, bgra.count / 4, 1, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
    let pixels = try #require(buffer)
    CVPixelBufferLockBaseAddress(pixels, [])
    if let base = CVPixelBufferGetBaseAddress(pixels) {
        bgra.withUnsafeBytes { bytes in
            base.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    CVPixelBufferUnlockBaseAddress(pixels, [])
    var description: CMVideoFormatDescription?
    #expect(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &description) == noErr)
    var timing = CMSampleTimingInfo(duration: .invalid,
        presentationTimeStamp: time, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    #expect(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
        formatDescription: try #require(description), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
    let result = try #require(sample)
    let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(result, createIfNecessary: true))
    let info = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    let values: [SCStreamFrameInfo: Any] = [.status: status.rawValue,
        .contentRect: CGRect(x: 1, y: 2, width: bgra.count / 4, height: 1).dictionaryRepresentation,
        .scaleFactor: 1.0, .contentScale: 1.0]
    for (key, value) in values {
        CFDictionarySetValue(info, Unmanaged.passUnretained(key.rawValue as NSString).toOpaque(),
            Unmanaged.passUnretained(value as AnyObject).toOpaque())
    }
    return result
}

@Test
func drawnFrameTimesUseTheSamplesPresentationTimeInTheHostClock() throws {
    let sample = try captureSample(bgra: Array(repeating: 0, count: 32), time: CMTime(value: 123456789, timescale: 1000000))
    let capture = SpaceWheelDrawnCapture(width: 8)
    capture.record(sample, clock: CMClockGetHostTimeClock())
    let frame = try #require(capture.samples().first)
    #expect(abs(frame.time - 123.456789) < 0.000001)
    #expect(abs(frame.time - SpaceWheelDrawnCapture.hostTime()) > 1)
}


@Test
func onePixelOutputKeepsTheWholeFourPointPatternStripWidth() {
    let source = CGRect(x: 10, y: 20, width: 224, height: 4)
    let configuration = SpaceWheelDrawnCapture.configuration(width: 224, sourceRect: source)
    #expect(configuration.sourceRect == source)
    #expect(configuration.width == 224 && configuration.height == 1)
    #expect(!configuration.preservesAspectRatio)
}

@Test
func captureRectUsesWindowBaseCoordinatesAndDisplayLogicalPoints() {
    let rect = SpaceWheelDrawnCapture.sourceRect(windowFrame: CGRect(x: 2100, y: 100, width: 800, height: 600),
        windowHeight: 600, row: CGRect(x: 8, y: 200, width: 224, height: 4),
        displayFrame: CGRect(x: 1920, y: 0, width: 1920, height: 1080))
    #expect(rect == CGRect(x: 188, y: 496, width: 224, height: 4))
}

@Test @MainActor
func baselineFailurePreservesRealChannelStatisticsExpectedPatternAndRawRows() throws {
    let capture = SpaceWheelDrawnCapture(width: 2)
    let sample = try captureSample(bgra: [10, 20, 30, 255, 50, 60, 70, 255], time: CMTime(value: 5, timescale: 1))
    capture.record(sample, clock: CMClockGetHostTimeClock())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = capture.diagnostics(source: 4, pitch: 16, directory: directory)
    #expect(diagnostics["drawn_sample_count"] as? Int == 1)
    let rows = try #require(diagnostics["drawn_rows"] as? [[String: Any]])
    let channels = try #require(rows.first?["channels"] as? [String: [String: Double]])
    #expect(channels["b"] == ["min": 10, "max": 50, "mean": 30])
    #expect(channels["g"] == ["min": 20, "max": 60, "mean": 40])
    #expect(channels["r"] == ["min": 30, "max": 70, "mean": 50])
    #expect(channels["a"] == ["min": 255, "max": 255, "mean": 255])
    #expect(diagnostics["drawn_expected_pattern"] as? [Int] == (0..<2).map { SpaceWheelDrawnPattern.white(space: 4, x: $0) ? 255 : 0 })
    let path = try #require(diagnostics["drawn_raw_path"] as? String)
    #expect(URL(fileURLWithPath: path).deletingLastPathComponent().path == directory.path)
    let raw = try Data(contentsOf: URL(fileURLWithPath: path))
    #expect(Array(raw.dropFirst(8)) == [30, 20, 10, 70, 60, 50])
    _ = try JSONSerialization.data(withJSONObject: diagnostics)
    let empty = SpaceWheelDrawnCapture(width: 2).diagnostics(source: 4, pitch: 16, directory: directory)
    #expect(empty["drawn_sample_count"] as? Int == 0)
    #expect((empty["drawn_rows"] as? [[String: Any]])?.isEmpty == true)
}


@Test @MainActor
func captureStatusKeepsIdlePixelsOnlyAfterACompleteFrameAndRejectsBlankOrSuspendedFrames() throws {
    let capture = SpaceWheelDrawnCapture(width: 2)
    let pixels: [UInt8] = [10, 20, 30, 255, 50, 60, 70, 255]
    for (index, status) in [SCFrameStatus.idle, .complete, .idle, .blank, .idle, .suspended, .started, .stopped].enumerated() {
        let sample = try captureSample(bgra: status == .idle ? Array(repeating: 0, count: 8) : pixels,
            time: CMTime(value: Int64(index + 1), timescale: 1), status: status)
        capture.record(sample, clock: CMClockGetHostTimeClock())
    }
    #expect(capture.samples().map(\.time) == [2, 3, 7])
    #expect(capture.samples().allSatisfy { $0.bgra == pixels })
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = capture.diagnostics(source: 0, pitch: 16, directory: directory)
    #expect(diagnostics["drawn_delivered_count"] as? Int == 8)
    #expect(diagnostics["drawn_status_counts"] as? [String: Int] == ["idle": 3, "complete": 1, "blank": 1, "suspended": 1, "started": 1, "stopped": 1])
    let deliveries = try #require(diagnostics["drawn_deliveries"] as? [[String: Any]])
    #expect(deliveries[0]["drop_reason"] as? String == "idle-without-reference")
    #expect(deliveries[4]["drop_reason"] as? String == "idle-without-reference")
    #expect(deliveries[1]["scale_factor"] as? Double == 1)
    #expect((deliveries[1]["content_rect"] as? [String: Any])?.isEmpty == false)
    _ = try JSONSerialization.data(withJSONObject: diagnostics)
}

@Test @MainActor
func captureDiagnosticsCountDeliveredBuffersEvenWithoutASynchronizationClock() throws {
    let capture = SpaceWheelDrawnCapture(width: 2, filter: .window)
    capture.record(try captureSample(bgra: Array(repeating: 0, count: 8), time: CMTime(value: 1, timescale: 1)), clock: nil)
    #expect(capture.samples().isEmpty)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = capture.diagnostics(source: 0, pitch: 16, directory: directory)
    #expect(diagnostics["drawn_delivered_count"] as? Int == 1)
    #expect(diagnostics["drawn_filter"] as? String == "window")
    let deliveries = try #require(diagnostics["drawn_deliveries"] as? [[String: Any]])
    #expect(deliveries[0]["clock_available"] as? Bool == false)
    let process = try #require(diagnostics["drawn_process"] as? [String: Any])
    #expect((process["parent"] as? [String: Any])?["pid"] as? Int32 == getppid())
}

@Test
func drawnFilterRequiresAnExplicitValidChoiceAndDefaultsToDisplay() throws {
    #expect(try SpaceWheelDrawnCapture.Filter.selected(arguments: []) == .display)
    #expect(try SpaceWheelDrawnCapture.Filter.selected(arguments: ["--ararat-drawn-filter=window"]) == .window)
    #expect(try SpaceWheelDrawnCapture.Filter.selected(arguments: ["--ararat-drawn-filter=display"]) == .display)
    #expect(throws: (any Error).self) { try SpaceWheelDrawnCapture.Filter.selected(arguments: ["--ararat-drawn-filter=other"]) }
}
